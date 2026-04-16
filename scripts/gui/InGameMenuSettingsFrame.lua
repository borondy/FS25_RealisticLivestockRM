RL_InGameMenuSettingsFrame = {}


function RL_InGameMenuSettingsFrame:onFrameOpen(_)

	local isAdmin = g_currentMission.isMasterUser or g_server ~= nil

	for name, setting in pairs(RLSettings.SETTINGS) do

		if setting.adminOnly and setting.element ~= nil then
			setting.element:setDisabled(not isAdmin)
		end

		if setting.dependancy then
			local dependancy = RLSettings.SETTINGS[setting.dependancy.name]
			if dependancy ~= nil and setting.element ~= nil then setting.element:setDisabled(dependancy.state ~= setting.dependancy.state) end
		end

	end

end

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, RL_InGameMenuSettingsFrame.onFrameOpen)


function RL_InGameMenuSettingsFrame:onFrameClose()

	if g_server ~= nil then RLSettings.saveToXMLFile() end

	RL_BroadcastSettingsEvent.sendEvent()

end

InGameMenuSettingsFrame.onFrameClose = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameClose, RL_InGameMenuSettingsFrame.onFrameClose)