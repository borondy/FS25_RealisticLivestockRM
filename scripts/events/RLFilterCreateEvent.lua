--[[
    RLFilterCreateEvent.lua
    Network event for creating a saveable filter record.

    Pattern A (caller-mutates-first + rebroadcast-from-run with
    ignoreConnection=sender). The caller (RLFilterService:create) MUST mutate
    local state BEFORE calling sendEvent. This event's run() applies the
    mutation on every receiver that is NOT the original sender.

    Server-side validation:
      1. getHasPlayerPermission("tradeAnimals", connection)
      2. If filter.farmId ~= nil: sender's farm must match filter.farmId
      3. Reject if a filter with the same id already exists (pathological)

    Pattern reference: HusbandryMessageDeleteEvent.
]]

RLFilterCreateEvent = {}
local RLFilterCreateEvent_mt = Class(RLFilterCreateEvent, Event)

InitEventClass(RLFilterCreateEvent, "RLFilterCreateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLFilterCreateEvent.emptyNew()
    Log:trace("RLFilterCreateEvent.emptyNew")
    local self = Event.new(RLFilterCreateEvent_mt)
    return self
end

--- Construct a new event carrying a whole filter record.
---@param filter table filter record (with id populated -- client-assigned via Utils.getUniqueId)
---@return table self
function RLFilterCreateEvent.new(filter)
    Log:trace("RLFilterCreateEvent.new: id=%s name=%s",
        tostring(filter and filter.id), tostring(filter and filter.name))
    local self = RLFilterCreateEvent.emptyNew()
    self.filter = filter
    return self
end

--- Serialize via the shared RLFilterWire codec.
function RLFilterCreateEvent:writeStream(streamId, connection)
    if self.filter == nil then
        Log:warning("RLFilterCreateEvent:writeStream: nil filter payload (nothing to write)")
        return
    end
    Log:trace("RLFilterCreateEvent:writeStream: id=%s", tostring(self.filter.id))
    RLFilterWire.writeFilter(streamId, self.filter)
end

--- Deserialize + run on this machine.
function RLFilterCreateEvent:readStream(streamId, connection)
    self.filter = RLFilterWire.readFilter(streamId)
    Log:trace("RLFilterCreateEvent:readStream: id=%s name=%s",
        tostring(self.filter and self.filter.id), tostring(self.filter and self.filter.name))
    self:run(connection)
end

--- Log user context for warning-path decisions.
---@param connection table
---@return string userName, any userId
local function getUserContext(connection)
    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"
    return userName, userId
end

--- Execute the event on the receiver (Pattern A).
---
--- Flow:
---   1. Guard against a malformed payload (nil or empty id).
---   2. If server receiving from remote client, validate permission + farm
---      scope + no-duplicate-id. On failure, log :warning and drop. On
---      success, rebroadcast with ignoreConnection=sender.
---   3. Apply the mutation on this receiver unless this machine is the
---      original sender (handled by ignoreConnection=sender exclusion).
function RLFilterCreateEvent:run(connection)
    local filter = self.filter
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterCreateEvent:run: malformed payload (id=%s); aborting",
            tostring(filter and filter.id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("RLFilterCreateEvent:run: permission 'tradeAnimals' denied for user '%s' (userId=%s) filter id=%s",
                tostring(userName), tostring(userId), tostring(filter.id))
            return
        end

        if filter.farmId ~= nil then
            local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
            if userFarm == nil or userFarm.farmId == nil then
                Log:warning("RLFilterCreateEvent:run: no farm lookup for user '%s' (userId=%s); aborting create id=%s",
                    tostring(userName), tostring(userId), tostring(filter.id))
                return
            end
            if userFarm.farmId ~= filter.farmId then
                Log:warning("RLFilterCreateEvent:run: farm-scope mismatch for user '%s' (userId=%s, userFarmId=%s) filter id=%s farmId=%s",
                    tostring(userName), tostring(userId), tostring(userFarm.farmId),
                    tostring(filter.id), tostring(filter.farmId))
                return
            end
        end

        -- Pathological: payload id collides with an existing record. Reject.
        -- Uses _rawGetById to avoid an unnecessary deep-clone on this read-only check.
        if g_rlFilterService ~= nil and g_rlFilterService:_rawGetById(filter.id) ~= nil then
            Log:warning("RLFilterCreateEvent:run: duplicate id '%s' for user '%s' (userId=%s); rejecting create",
                tostring(filter.id), tostring(userName), tostring(userId))
            return
        end

        -- Rebroadcast to everyone except the sender (sender already mutated
        -- locally before sendEvent and must not receive an echo).
        g_server:broadcastEvent(
            RLFilterCreateEvent.new(filter),
            nil, connection, nil)

        Log:debug("RLFilterCreateEvent:run: validated create from user '%s', rebroadcasting id=%s",
            tostring(userName), tostring(filter.id))
    end

    -- Apply mutation on this receiver (server-received-from-remote or client
    -- receiving the rebroadcast). Sender never enters run() thanks to
    -- ignoreConnection=sender in the rebroadcast above (and its own
    -- broadcastEvent sends only remotely).
    if g_rlFilterService == nil then
        Log:warning("RLFilterCreateEvent:run: g_rlFilterService is nil; skipping apply for id=%s",
            tostring(filter.id))
        return
    end

    -- Apply unconditionally. Previously a `_rawGetById ~= nil` guard skipped
    -- the apply as "defense in depth" for a server-originator same-machine
    -- double-apply, but that scenario cannot occur: `g_server:broadcastEvent`
    -- does not re-run locally, and the sender is always excluded from the
    -- rebroadcast via ignoreConnection. The only real trigger for a
    -- receiver-has-local-record state is cross-client divergence, where
    -- the AUTHORITATIVE server payload must overwrite the stale local
    -- record. `applyIncomingCreate` already emits a :warning on
    -- existing-id overwrite which is the correct convergence signal.
    g_rlFilterService:applyIncomingCreate(filter)
    Log:debug("RLFilterCreateEvent:run: applied create id=%s name=%s",
        tostring(filter.id), tostring(filter.name))

    -- Spec B fanout: notify the four consumer frames (Info/Buy/Sell/Move) so
    -- their chip + animal list stay in sync with the remote mutation. Each
    -- frame's onRemoteFilterChange id-match-gates against its own activeFilterId
    -- so non-active remote changes are cheap no-ops (no chip / list churn).
    -- Nil-guarded for the same reasons as the settingsFrame:refreshIfOpen
    -- block below: g_rlMenu may not exist during early lifecycle; frame
    -- fields may be nil pre-menu-open or on a dedicated server.
    Log:trace("RLFilterCreateEvent:run: fanout to consumer frames, id=%s",
        tostring(filter.id))
    if g_rlMenu ~= nil then
        -- Iterate frame NAMES (a no-nil string array) and look up the field
        -- on g_rlMenu. An array-of-frame-references like
        -- `{g_rlMenu.infoFrame, ..., g_rlMenu.moveFrame}` would break ipairs:
        -- Lua stops at the first nil, so any nil frame field (dedi, pre-menu-
        -- open, partial-rollback) would silently skip every later frame.
        for _, frameName in ipairs({"infoFrame", "buyFrame", "sellFrame", "moveFrame"}) do
            local f = g_rlMenu[frameName]
            if f ~= nil and f.onRemoteFilterChange ~= nil then
                f:onRemoteFilterChange(filter.id, "create")
            end
        end
    end

    -- Refresh the Settings frame if it is currently open on this machine.
    -- Nil-guarded: g_rlMenu may not exist during early lifecycle,
    -- settingsFrame may be nil if the menu was never opened.
    if g_rlMenu ~= nil and g_rlMenu.settingsFrame ~= nil
       and g_rlMenu.settingsFrame.refreshIfOpen ~= nil then
        g_rlMenu.settingsFrame:refreshIfOpen()
    end

    -- F7: a remote filter create can change rule filter-summaries, so an open Herdsman menu
    -- frame is a filter consumer that needs the same full reload (NOT the id-gated
    -- onRemoteFilterChange fanout above). Same nil-guards as the settingsFrame block.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Thin dispatch: broadcast to clients if we are the server, otherwise
--- upload to the server. Caller (service) MUST have already mutated local
--- state before calling this.
---
--- Guards on `g_server` / `g_client` so offline or early-lifecycle paths
--- (e.g. mod tests, service constructor wiring) stay safe.
---@param filter table filter record (with id populated)
function RLFilterCreateEvent.sendEvent(filter)
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterCreateEvent.sendEvent: invalid payload (id=%s); skipping",
            tostring(filter and filter.id))
        return
    end

    Log:trace("RLFilterCreateEvent.sendEvent: dispatching id=%s", tostring(filter.id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLFilterCreateEvent.new(filter))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLFilterCreateEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(filter.id))
            return
        end
        conn:sendEvent(RLFilterCreateEvent.new(filter))
    else
        Log:trace("RLFilterCreateEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
