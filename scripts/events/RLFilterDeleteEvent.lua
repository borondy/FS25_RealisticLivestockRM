--[[
    RLFilterDeleteEvent.lua
    Network event for deleting a saveable filter by id.

    Pattern A (caller-mutates-first). Caller (RLFilterService:delete) mutates
    local state BEFORE calling sendEvent.

    Server-side validation:
      1. getHasPlayerPermission("tradeAnimals", connection)
      2. stored = g_rlFilterService:getById(id) on SERVER. If unknown -> log
         :warning + drop (no mutation, no rebroadcast); I/O matrix row
         "Client delete, unknown id".
      3. Farm-scope: if stored.farmId ~= nil, sender's farmId must match.

    Note: the payload is just the id. farmId for the scope check is derived
    from the server's stored record, which is the authoritative source.

    Pattern reference: HusbandryMessageDeleteEvent.
]]

RLFilterDeleteEvent = {}
local RLFilterDeleteEvent_mt = Class(RLFilterDeleteEvent, Event)

InitEventClass(RLFilterDeleteEvent, "RLFilterDeleteEvent")

local Log = RmLogging.getLogger("RLRM")

function RLFilterDeleteEvent.emptyNew()
    Log:trace("RLFilterDeleteEvent.emptyNew")
    local self = Event.new(RLFilterDeleteEvent_mt)
    return self
end

function RLFilterDeleteEvent.new(id)
    Log:trace("RLFilterDeleteEvent.new: id=%s", tostring(id))
    local self = RLFilterDeleteEvent.emptyNew()
    self.id = id
    return self
end

function RLFilterDeleteEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.id or "")
    Log:trace("RLFilterDeleteEvent:writeStream: id=%s", tostring(self.id))
end

function RLFilterDeleteEvent:readStream(streamId, connection)
    self.id = streamReadString(streamId)
    Log:trace("RLFilterDeleteEvent:readStream: id=%s", tostring(self.id))
    self:run(connection)
end

local function getUserContext(connection)
    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"
    return userName, userId
end

function RLFilterDeleteEvent:run(connection)
    local id = self.id
    if id == nil or id == "" then
        Log:warning("RLFilterDeleteEvent:run: malformed payload (id=%s); aborting", tostring(id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("RLFilterDeleteEvent:run: permission 'tradeAnimals' denied for user '%s' (userId=%s) filter id=%s",
                tostring(userName), tostring(userId), tostring(id))
            return
        end

        if g_rlFilterService == nil then
            Log:warning("RLFilterDeleteEvent:run: g_rlFilterService is nil on server; cannot validate id=%s",
                tostring(id))
            return
        end

        -- _rawGetById avoids an unnecessary deep-clone on this read-only check.
        local stored = g_rlFilterService:_rawGetById(id)
        if stored == nil then
            -- I/O matrix: "Client delete, unknown id -> :warning, no-op".
            Log:warning("RLFilterDeleteEvent:run: unknown id '%s' from user '%s' (userId=%s); no-op",
                tostring(id), tostring(userName), tostring(userId))
            return
        end

        if stored.farmId ~= nil then
            local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
            if userFarm == nil or userFarm.farmId == nil then
                Log:warning("RLFilterDeleteEvent:run: no farm lookup for user '%s' (userId=%s); aborting delete id=%s",
                    tostring(userName), tostring(userId), tostring(id))
                return
            end
            if userFarm.farmId ~= stored.farmId then
                Log:warning("RLFilterDeleteEvent:run: farm-scope mismatch for user '%s' (userId=%s, userFarmId=%s) filter id=%s storedFarmId=%s",
                    tostring(userName), tostring(userId), tostring(userFarm.farmId),
                    tostring(id), tostring(stored.farmId))
                return
            end
        end

        g_server:broadcastEvent(
            RLFilterDeleteEvent.new(id),
            nil, connection, nil)

        Log:debug("RLFilterDeleteEvent:run: validated delete from user '%s', rebroadcasting id=%s",
            tostring(userName), tostring(id))
    end

    if g_rlFilterService == nil then
        Log:warning("RLFilterDeleteEvent:run: g_rlFilterService is nil; skipping apply for id=%s",
            tostring(id))
        return
    end

    -- Branch log on apply outcome so an "applied" line only appears when a
    -- record was actually removed. The "already gone" path downgrades to
    -- :trace since it's a legitimate late-join / reconnect scenario.
    local applied = g_rlFilterService:applyIncomingDelete(id)
    if applied then
        Log:debug("RLFilterDeleteEvent:run: applied delete id=%s", tostring(id))
    else
        Log:trace("RLFilterDeleteEvent:run: no-op delete id=%s (already gone)", tostring(id))
    end

    -- Spec B fanout: notify the four consumer frames (Info/Buy/Sell/Move) so
    -- their chip + animal list stay in sync with the remote mutation. Each
    -- frame's onRemoteFilterChange id-match-gates against its own activeFilterId
    -- so non-active remote changes are cheap no-ops (no chip / list churn).
    -- Fires on both the applied and already-gone branches: a fanout on the
    -- already-gone path means a peer's prior delete reached us out of order;
    -- our local frame may still hold a stale activeFilterId pointing at the
    -- just-removed filter, and the per-frame revalidate will clear it.
    -- Nil-guarded for the same reasons as the settingsFrame:refreshIfOpen
    -- block below: g_rlMenu may not exist during early lifecycle; frame
    -- fields may be nil pre-menu-open or on a dedicated server.
    Log:trace("RLFilterDeleteEvent:run: fanout to consumer frames, id=%s", tostring(id))
    if g_rlMenu ~= nil then
        -- Iterate frame NAMES (no-nil string array); see RLFilterCreateEvent
        -- for the ipairs-nil rationale.
        for _, frameName in ipairs({"infoFrame", "buyFrame", "sellFrame", "moveFrame"}) do
            local f = g_rlMenu[frameName]
            if f ~= nil and f.onRemoteFilterChange ~= nil then
                f:onRemoteFilterChange(id, "delete")
            end
        end
    end

    -- Refresh the Settings frame if it is currently open on this machine.
    -- Called after the branched if/else end so both applied and no-op
    -- paths trigger the refresh - the no-op path means the id was already
    -- gone locally (late-join reconcile or redundant rebroadcast), and a
    -- pass through refreshData still costs little and keeps the UI
    -- consistent with any concurrent events that may have landed.
    -- Nil-guarded: g_rlMenu may not exist during early lifecycle,
    -- settingsFrame may be nil if the menu was never opened.
    if g_rlMenu ~= nil and g_rlMenu.settingsFrame ~= nil
       and g_rlMenu.settingsFrame.refreshIfOpen ~= nil then
        g_rlMenu.settingsFrame:refreshIfOpen()
    end
end

--- Thin dispatch. Caller MUST have mutated local state first.
---@param id string filter id to delete
function RLFilterDeleteEvent.sendEvent(id)
    if id == nil or id == "" then
        Log:warning("RLFilterDeleteEvent.sendEvent: invalid id=%s; skipping", tostring(id))
        return
    end

    Log:trace("RLFilterDeleteEvent.sendEvent: dispatching id=%s", tostring(id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLFilterDeleteEvent.new(id))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLFilterDeleteEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(id))
            return
        end
        conn:sendEvent(RLFilterDeleteEvent.new(id))
    else
        Log:trace("RLFilterDeleteEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
