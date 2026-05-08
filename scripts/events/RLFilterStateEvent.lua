--[[
    RLFilterStateEvent.lua
    Full-state filter snapshot (Phase 0 P4).

    Server -> client only. Dispatched from `sendInitialClientState` for every
    connecting client so late-joiners converge with the authoritative server
    state. Also serves as the reconciliation path when a Pattern A delta
    mutation is rejected server-side -- the next state event
    wipes and re-applies, which reconciles divergent local state.

    Wire format (recursive §4.5 codec via RLFilterWire):
        streamWriteUInt16(count)
        for i = 1, count do writeFilter(streamId, filter) end

    Receiver flow (`run`):
      1. `g_rlFilterService:clear()` -- drop stale local state.
      2. For each received filter, invoke `applyIncomingCreate` which does
         NOT dispatch further events (the receiver apply is not a local
         mutation that should re-broadcast) AND deep-clones the wire payload
         (P2 carryover ownership contract).

    Empty-set (count=0) is a valid state event -- a server with zero filters
    still sends, giving clients a deterministic "clear-to-empty" signal.

    Pattern references:
      - AnimalSystemStateEvent.lua (send-per-connection state snapshot)
      - HusbandryMessageStateEvent.lua (wiring site in sendInitialClientState)
      - RLFilterCreateEvent.lua (§4.5 wire conventions + validation style)
]]

RLFilterStateEvent = {}
local RLFilterStateEvent_mt = Class(RLFilterStateEvent, Event)

InitEventClass(RLFilterStateEvent, "RLFilterStateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLFilterStateEvent.emptyNew()
    Log:trace("RLFilterStateEvent.emptyNew")
    local self = Event.new(RLFilterStateEvent_mt)
    return self
end

--- Construct a new event carrying a list of whole filter records.
---@param filters table[]|nil list of filter records (typically from `g_rlFilterService:list()`)
---@return table self
function RLFilterStateEvent.new(filters)
    local self = RLFilterStateEvent.emptyNew()
    self.filters = filters or {}
    Log:trace("RLFilterStateEvent.new: #filters=%d", #self.filters)
    return self
end

--- Upper sanity bound on the wire-side filter count. Any server that ever
--- accumulates 10,000 user-defined filters is pathological; the real
--- purpose of this cap is to defend the reader against a desynced upstream
--- stream (e.g. unbounded-recursion readGroup walking into the
--- next event's bytes) that could produce a count up to 65535 and spin
--- the reader to a session-timing-out crash. Exceeding the cap drops the
--- event and leaves the receiver in its prior state.
RLFilterStateEvent.MAX_FILTER_COUNT = 10000

--- Serialize via the shared §4.5 codec with a UInt16 count prefix.
---
--- Counts contiguous 1..N entries via `ipairs` rather than `#self.filters`
--- so a future `list()` refactor that yields a sparse / map-shaped table
--- surfaces as :warning rather than a silent under-count on the wire.
function RLFilterStateEvent:writeStream(streamId, connection)
    local filters = self.filters or {}

    local count = 0
    for _, _ in ipairs(filters) do count = count + 1 end

    -- Surface any divergence between the sequence-count (`ipairs`) and a
    -- raw `pairs` sweep. Normal `g_rlFilterService:list()` input produces
    -- equal counts because it builds via `table.insert`.
    local pairCount = 0
    for _, _ in pairs(filters) do pairCount = pairCount + 1 end
    if pairCount ~= count then
        Log:warning("RLFilterStateEvent:writeStream: filter list is not a contiguous sequence (ipairs=%d pairs=%d); writing only the sequential prefix",
            count, pairCount)
    end

    streamWriteUInt16(streamId, count)
    Log:trace("RLFilterStateEvent:writeStream: #filters=%d", count)
    for i = 1, count do
        RLFilterWire.writeFilter(streamId, filters[i])
    end
end

--- Deserialize + run on this machine.
---
--- Defends against a desynced / corrupted stream by capping the count at
--- `MAX_FILTER_COUNT`. If exceeded, the event is dropped -- receiver stays
--- in its prior state rather than spinning the reader through up to 65535
--- invalid filters.
function RLFilterStateEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    if count > RLFilterStateEvent.MAX_FILTER_COUNT then
        Log:warning("RLFilterStateEvent:readStream: count=%d exceeds MAX_FILTER_COUNT=%d (stream desync?); dropping event",
            count, RLFilterStateEvent.MAX_FILTER_COUNT)
        self.filters = {}
        self.dropped = true
        return
    end

    local list = {}
    for i = 1, count do
        list[i] = RLFilterWire.readFilter(streamId)
    end
    self.filters = list
    Log:trace("RLFilterStateEvent:readStream: #filters=%d", count)
    self:run(connection)
end

--- Apply the received state on the client.
---
--- Flow:
---   1. Server-authoritative-receive guard: drop the event if this machine
---      is running a server. The state event is strictly server-to-client;
---      a malicious or modded client that crafts + emits one would
---      otherwise cause the server's `run()` to `clear()` and replace
---      authoritative state from a client payload. Mirrors P3's receive-
---      side Pattern A validation (validate on receive, not just on send).
---   2. Nil-guard `g_rlFilterService`. Unlikely (loadMap runs before
---      sendInitialClientState) but cheap and explicit.
---   3. `clear()` to drop any stale local state (e.g. filters created
---      optimistically before the server rejected the mutation).
---   4. Apply each wire-decoded filter via `applyIncomingCreate`, which:
---      - does not dispatch further events (receiver apply is not a local
---        mutation that should re-broadcast)
---      - deep-clones the payload before storing (ownership contract)
---      The method's existing-id :warning cannot fire post-clear.
function RLFilterStateEvent:run(connection)
    local filters = self.filters or {}
    local count = #filters

    if g_server ~= nil then
        Log:warning("RLFilterStateEvent:run: received on server; state event is server-authoritative send-only, dropping (#filters=%d)",
            count)
        return
    end

    if g_rlFilterService == nil then
        Log:warning("RLFilterStateEvent:run: g_rlFilterService is nil; skipping apply (#filters=%d)",
            count)
        return
    end

    g_rlFilterService:clear()

    local applied = 0
    for i = 1, count do
        local f = filters[i]
        if f == nil or f.id == nil or f.id == "" then
            Log:warning("RLFilterStateEvent:run: skipping malformed filter at index %d (id=%s)",
                i, tostring(f and f.id))
        else
            if g_rlFilterService:applyIncomingCreate(f) then
                applied = applied + 1
            end
        end
    end

    Log:debug("RLFilterStateEvent:run: received %d filter(s), applied %d (registry cleared first)",
        count, applied)
end

--- Server-only dispatcher. Sends the full filter state to a single target
--- connection. Clients that call this get a `:warning` drop per plan §4.10
--- (server-authoritative). This is the SINGLE dispatch path -- both the
--- primary wiring in `RealisticLivestock_FSBaseMission:sendInitialClientState`
--- and any future admin-triggered resend route through here, so the
--- `g_server == nil` + nil-connection guards below cover every send site.
---@param filters table[] list of filter records
---@param connection table target connection (single client)
function RLFilterStateEvent.sendEvent(filters, connection)
    if g_server == nil then
        Log:warning("RLFilterStateEvent.sendEvent: client cannot emit state event; dropping")
        return
    end
    if connection == nil then
        Log:warning("RLFilterStateEvent.sendEvent: nil connection; dropping (#filters=%d)",
            filters ~= nil and #filters or 0)
        return
    end

    local count = filters ~= nil and #filters or 0
    Log:trace("RLFilterStateEvent.sendEvent: dispatching #filters=%d", count)
    connection:sendEvent(RLFilterStateEvent.new(filters))
end

Log:trace("RLFilterStateEvent: loaded")
