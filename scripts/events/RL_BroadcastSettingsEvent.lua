RL_BroadcastSettingsEvent = {}

local RL_BroadcastSettingsEvent_mt = Class(RL_BroadcastSettingsEvent, Event)
InitEventClass(RL_BroadcastSettingsEvent, "RL_BroadcastSettingsEvent")


function RL_BroadcastSettingsEvent.emptyNew()
    local self = Event.new(RL_BroadcastSettingsEvent_mt)
    return self
end


function RL_BroadcastSettingsEvent.new(setting)

    local self = RL_BroadcastSettingsEvent.emptyNew()

    self.setting = setting

    return self

end


function RL_BroadcastSettingsEvent:readStream(streamId, connection)

    local readAll = streamReadBool(streamId)

    Log:debug("RL_BroadcastSettingsEvent:readStream: received settings event over wire (readAll=%s)", tostring(readAll))

    -- Deserialize wire pairs onto self.pending but do NOT commit them here.
    -- The state commit is deferred to run() so the master-user gate
    -- can reject a non-admin event before any mutation reaches RLSettings.SETTINGS
    -- (Pattern A: mutate-after-validate). A locally-constructed send keeps
    -- self.pending nil - its state is already live in SETTINGS.
    self.pending = {}

    if readAll then

        for _, setting in pairs(RLSettings.SETTINGS) do

            if setting.ignore then continue end

            local name = streamReadString(streamId)
            local state = streamReadUInt8(streamId)

            self.pending[#self.pending + 1] = { name = name, state = state }

        end

    else

        local name = streamReadString(streamId)
        local state = streamReadUInt8(streamId)

        self.setting = name
        self.pending[#self.pending + 1] = { name = name, state = state }

    end

    Log:debug("RL_BroadcastSettingsEvent:readStream: deserialized %d pending pair(s) (branch=%s); deferring commit to run()",
        #self.pending, self.setting == nil and "full-set" or "single")

    self:run(connection)

end


function RL_BroadcastSettingsEvent:writeStream(streamId, connection)

    streamWriteBool(streamId, self.setting == nil)

    Log:debug("RL_BroadcastSettingsEvent:writeStream: sending settings event over wire (readAll=%s)", tostring(self.setting == nil))

    if self.setting == nil then

        for name, setting in pairs(RLSettings.SETTINGS) do
            if setting.ignore then continue end
            streamWriteString(streamId, name)
            streamWriteUInt8(streamId, setting.state)
        end

    else

        local setting = RLSettings.SETTINGS[self.setting]
        streamWriteString(streamId, self.setting)
        streamWriteUInt8(streamId, setting.state)

    end

end


function RL_BroadcastSettingsEvent:run(connection)

    local branch = self.setting == nil and "full-set" or "single"

    Log:debug("RL_BroadcastSettingsEvent:run: branch=%s g_server=%s hasConnection=%s",
        branch, tostring(g_server ~= nil), tostring(connection ~= nil))

    -- Server receiving a client-originated event: validate sender authority
    -- BEFORE any mutation. connection:getIsServer() is false only when
    -- WE are the server and the event arrived from a remote client; on a client
    -- receiving the server's broadcast (or the late-join full-set push) it is
    -- true, so the gate and relay below are both skipped. Mirrors
    -- RL_ResetDealerEvent:run master-user-from-connection check.
    local isFromRemoteClient = connection ~= nil and not connection:getIsServer()

    if isFromRemoteClient then

        local userName = "unknown"
        local user = g_currentMission.userManager:getUserByConnection(connection)
        if user ~= nil then userName = user.nickname or userName end

        if not g_currentMission.userManager:getIsConnectionMasterUser(connection) then
            Log:warning("RL_BroadcastSettingsEvent:run: sender '%s' is not master/admin (branch=%s); dropping - no commit, no relay",
                tostring(userName), branch)
            return
        end

        Log:debug("RL_BroadcastSettingsEvent:run: sender '%s' authorized as master (branch=%s)", tostring(userName), branch)

    end

    -- Commit the deferred wire state now that validation has passed. self.pending
    -- is set only by readStream (event received over the wire); a locally-built
    -- event (host sendEvent, or the relay below) has self.pending == nil and its
    -- state is already live in RLSettings.SETTINGS.
    if self.pending ~= nil then
        for i = 1, #self.pending do
            local p = self.pending[i]
            RLSettings.SETTINGS[p.name].state = p.state
        end
        Log:debug("RL_BroadcastSettingsEvent:run: committed %d pending pair(s)", #self.pending)
    end

    -- Pattern A relay: rebroadcast the validated client change to the OTHER
    -- clients (ignoreConnection = sender) so their widgets update live. Server
    -- only; the relayed payload reads committed state from SETTINGS, so the
    -- commit above must precede this. Reference HusbandryMessageDeleteEvent:run.
    if isFromRemoteClient then
        Log:debug("RL_BroadcastSettingsEvent:run: relaying %s event to other clients (sender excluded)", branch)
        g_server:broadcastEvent(RL_BroadcastSettingsEvent.new(self.setting), nil, connection, nil)
    end

    -- Apply: push committed state to widgets + fire callbacks + tooltip + cascade.
    if self.setting == nil then

        for name, setting in pairs(RLSettings.SETTINGS) do
            if setting.ignore then continue end
            if setting.element ~= nil then setting.element:setState(setting.state) end
            if setting.callback ~= nil then setting.callback(name, setting.values[setting.state]) end
        end

        RLDebugUtils.dumpSettingsOnce()

    else

        local setting = RLSettings.SETTINGS[self.setting]
        if setting.element ~= nil then setting.element:setState(setting.state) end
        if setting.callback ~= nil then setting.callback(self.setting, setting.values[setting.state]) end

        if setting.dynamicTooltip and setting.element ~= nil then setting.element.elements[1]:setText(g_i18n:getText("rl_settings_" .. self.setting .. "_tooltip_" .. setting.state)) end

        Log:trace("RL_BroadcastSettingsEvent:run: dependency cascade for '%s' state=%s", self.setting, tostring(setting.state))
        for _, s in pairs(RLSettings.SETTINGS) do
            if s.dependancy and s.dependancy.name == self.setting and s.element ~= nil then
                s.element:setDisabled(s.dependancy.state ~= setting.state)
            end
        end

        if g_server ~= nil then
            Log:debug("RL_BroadcastSettingsEvent:run: g_server present -> RLSettings.saveToXMLFile() to persist single change")
            RLSettings.saveToXMLFile()
        end

    end

    -- Refresh the RL Tabbed Menu Settings -> General subtab if it is open.
    -- Mirrors the filter-event refresh hook pattern in RLFilter*Event:run.
    -- No-op if g_rlMenu is not constructed yet or the frame is not the active
    -- tab. Triggers on both branches: the initial-connect/legacy full-set sync
    -- and the single-setting per-click broadcast (the RLMenu fix).
    if g_rlMenu ~= nil and g_rlMenu.settingsFrame ~= nil
       and g_rlMenu.settingsFrame.refreshIfGeneralOpen ~= nil then
        Log:trace("RL_BroadcastSettingsEvent:run: notifying RL menu Settings/General subtab")
        g_rlMenu.settingsFrame:refreshIfGeneralOpen()
    end

end


function RL_BroadcastSettingsEvent.sendEvent(setting)
	if g_server ~= nil then
		Log:debug("RL_BroadcastSettingsEvent.sendEvent: g_server present -> broadcastEvent to all clients (setting=%s)", tostring(setting))
		g_server:broadcastEvent(RL_BroadcastSettingsEvent.new(setting))
	else
		Log:debug("RL_BroadcastSettingsEvent.sendEvent: client -> sendEvent to server connection (setting=%s)", tostring(setting))
		g_client:getServerConnection():sendEvent(RL_BroadcastSettingsEvent.new(setting))
	end
end