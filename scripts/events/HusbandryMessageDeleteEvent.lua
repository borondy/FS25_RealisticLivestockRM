--[[
    HusbandryMessageDeleteEvent.lua
    Network event for deleting one or more RL messages from a husbandry.

    Implements the canonical FS25 client-to-server-to-all-clients sync pattern
    (Pattern A, caller-mutates-first + rebroadcast-from-run with ignoreConnection=sender).

    The caller (RLMessageService.deleteMessages) MUST mutate local state BEFORE
    calling sendEvent. This event's run() applies the mutation on every receiver
    that is NOT the original sender. The sender skips run() because its own
    broadcastEvent with ignoreConnection=sender does not echo back.

    Server-side validation (permission + farm scope) is the authoritative
    security boundary - never trust the client. The frame-side UI gate in
    RLMenuMessagesFrame is a secondary UX helper only.
]]

HusbandryMessageDeleteEvent = {}
local HusbandryMessageDeleteEvent_mt = Class(HusbandryMessageDeleteEvent, Event)

InitEventClass(HusbandryMessageDeleteEvent, "HusbandryMessageDeleteEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during event deserialization.
--- @return table self
function HusbandryMessageDeleteEvent.emptyNew()
    Log:trace("HusbandryMessageDeleteEvent.emptyNew")
    local self = Event.new(HusbandryMessageDeleteEvent_mt)
    return self
end

--- Construct a new event carrying a husbandry and the list of uniqueIds to delete.
--- @param husbandry table Husbandry placeable (must have spec_husbandryAnimals)
--- @param uniqueIds table Array of message uniqueIds (int, UInt16 on the wire)
--- @return table self
function HusbandryMessageDeleteEvent.new(husbandry, uniqueIds)
    Log:trace("HusbandryMessageDeleteEvent.new: %d id(s)",
        (uniqueIds ~= nil and #uniqueIds) or 0)
    local self = HusbandryMessageDeleteEvent.emptyNew()
    self.husbandry = husbandry
    self.uniqueIds = uniqueIds or {}
    return self
end

--- Serialize the event for network transmission.
--- Wire format: nodeObject(husbandry) + UInt16(count) + count * UInt16(uniqueId).
--- The UInt16 id width matches the existing HusbandryMessageStateEvent format.
--- @param streamId number Network stream id
--- @param connection table Network connection (unused, required by Event API)
function HusbandryMessageDeleteEvent:writeStream(streamId, connection)
    local count = #self.uniqueIds
    Log:trace("HusbandryMessageDeleteEvent:writeStream: %d id(s) for husbandry '%s'",
        count, tostring(self.husbandry ~= nil and self.husbandry:getName() or "nil"))

    NetworkUtil.writeNodeObject(streamId, self.husbandry)
    streamWriteUInt16(streamId, count)

    for i = 1, count do
        streamWriteUInt16(streamId, self.uniqueIds[i])
    end
end

--- Deserialize the event from the network and run it on this machine.
--- @param streamId number Network stream id
--- @param connection table Network connection (passed through to run)
function HusbandryMessageDeleteEvent:readStream(streamId, connection)
    self.husbandry = NetworkUtil.readNodeObject(streamId)

    local count = streamReadUInt16(streamId)
    self.uniqueIds = {}

    for i = 1, count do
        self.uniqueIds[i] = streamReadUInt16(streamId)
    end

    Log:trace("HusbandryMessageDeleteEvent:readStream: %d id(s) for husbandry '%s'",
        count, tostring(self.husbandry ~= nil and self.husbandry:getName() or "nil"))

    self:run(connection)
end

--- Execute the event on the receiver.
---
--- Pattern A flow:
---   1. Guard against invalid husbandry (stale node id or wrong object type).
---   2. If this receiver is the SERVER receiving from a REMOTE CLIENT
---      (`not connection:getIsServer()`), run authoritative validation
---      (permission + farm scope). On failure, abort silently. On success,
---      rebroadcast with ignoreConnection=sender so the sender does not
---      receive an echo (it already mutated locally before sendEvent).
---   3. Apply the mutation: loop uniqueIds, call placeable:deleteRLMessage
---      for each. Idempotent: unknown ids are a no-op.
---   4. Refresh the Messages frame if it is currently open.
---
--- Does NOT mutate on the original sender (sender runs the caller-side
--- mutation synchronously before sendEvent). Does NOT refresh the frame
--- if validation fails.
--- @param connection table Network connection the event arrived on
function HusbandryMessageDeleteEvent:run(connection)
    -- Guard 1: valid husbandry. NetworkUtil.readNodeObject can return nil
    -- (stale id) or a non-husbandry object that happens to share an id
    -- during a sell-placeable race. The spec_husbandryAnimals check verifies
    -- this is actually a livestock husbandry placeable.
    if self.husbandry == nil or self.husbandry.spec_husbandryAnimals == nil then
        Log:warning("HusbandryMessageDeleteEvent:run: invalid husbandry (nil or not a livestock placeable), aborting")
        return
    end

    if not connection:getIsServer() then
        -- Server received from a remote client: authoritative validation.
        -- Server is the primary security boundary; never trust the client.
        local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
        local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"

        if not g_currentMission:getHasPlayerPermission("updateFarm", connection) then
            Log:warning("HusbandryMessageDeleteEvent:run: permission denied for user '%s' (userId=%s) on husbandry '%s'",
                tostring(userName), tostring(userId), tostring(self.husbandry:getName()))
            return
        end

        local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
        if userFarm == nil or userFarm.farmId == nil then
            Log:warning("HusbandryMessageDeleteEvent:run: no farm lookup for user '%s' (userId=%s) on husbandry '%s', aborting",
                tostring(userName), tostring(userId), tostring(self.husbandry:getName()))
            return
        end

        local husbandryFarmId = self.husbandry:getOwnerFarmId()
        if userFarm.farmId ~= husbandryFarmId then
            Log:warning("HusbandryMessageDeleteEvent:run: farm scope mismatch for user '%s' (userId=%s, user farmId=%s) on husbandry '%s' (farmId=%s), aborting",
                tostring(userName), tostring(userId), tostring(userFarm.farmId),
                tostring(self.husbandry:getName()), tostring(husbandryFarmId))
            return
        end

        -- Validation passed: rebroadcast to everyone EXCEPT the sender.
        -- Sender already mutated locally before sendEvent and must not receive an echo.
        g_server:broadcastEvent(
            HusbandryMessageDeleteEvent.new(self.husbandry, self.uniqueIds),
            nil, connection, nil)

        Log:debug("HusbandryMessageDeleteEvent:run: validated client delete, rebroadcasting %d id(s) to other clients",
            #self.uniqueIds)
    end

    -- Apply mutation on this receiver.
    -- Paths that reach here:
    --   * server receiving from a remote client (after successful validation above)
    --   * any client receiving the rebroadcast/broadcast from the server
    -- The original sender does NOT enter run() - it mutated locally before
    -- sendEvent and is excluded from the rebroadcast via ignoreConnection.
    for i = 1, #self.uniqueIds do
        self.husbandry:deleteRLMessage(self.uniqueIds[i])
    end

    Log:debug("HusbandryMessageDeleteEvent:run: applied %d delete(s) to husbandry '%s'",
        #self.uniqueIds, tostring(self.husbandry:getName()))

    -- Refresh the Messages frame if it is currently open on this machine.
    -- Nil-guarded: g_rlMenu may not exist during early lifecycle,
    -- messagesFrame may be nil if the menu was never opened.
    if g_rlMenu ~= nil and g_rlMenu.messagesFrame ~= nil
       and g_rlMenu.messagesFrame.refreshIfOpen ~= nil then
        g_rlMenu.messagesFrame:refreshIfOpen()
    end
end

--- Thin dispatch: broadcast to clients if we are the server, otherwise
--- send to the server. The caller (RLMessageService.deleteMessages) MUST
--- have already mutated local state before calling this.
--- @param husbandry table Husbandry placeable
--- @param uniqueIds table Array of uniqueIds to delete
function HusbandryMessageDeleteEvent.sendEvent(husbandry, uniqueIds)
    if husbandry == nil or uniqueIds == nil or #uniqueIds == 0 then
        Log:warning("HusbandryMessageDeleteEvent.sendEvent: invalid args, skipping")
        return
    end

    Log:trace("HusbandryMessageDeleteEvent.sendEvent: dispatching %d id(s)", #uniqueIds)

    if g_server ~= nil then
        g_server:broadcastEvent(HusbandryMessageDeleteEvent.new(husbandry, uniqueIds))
    else
        g_client:getServerConnection():sendEvent(HusbandryMessageDeleteEvent.new(husbandry, uniqueIds))
    end
end
