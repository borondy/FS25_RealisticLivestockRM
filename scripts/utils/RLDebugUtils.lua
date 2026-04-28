-- RLDebugUtils.lua
-- Read-only debug helpers for RLRM. Currently: effective-settings dump.

RLDebugUtils = {}

RLDebugUtils._dumped = false


--- Resolve the runtime role string for the dump header.
--- Order matters: dedicated server is also a "server" so check it first.
---@return string role  one of: "dedi", "SP", "host", "client"
local function resolveRole()
    if g_dedicatedServer ~= nil then return "dedi" end

    local mp = g_currentMission ~= nil
        and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer

    if not mp then return "SP" end
    if g_server ~= nil then return "host" end
    return "client"
end


--- Format a single setting line. Guards against an out-of-range state.
---@param name string
---@param setting table  one entry from RLSettings.SETTINGS
---@return string line   "<name> = <value> (state=N/M)"
local function formatSettingLine(name, setting)
    local state = setting.state or setting.default
    local maxState = #setting.values
    local value

    if state == nil or maxState == nil or state < 1 or state > maxState then
        value = "<out-of-range>"
    else
        value = tostring(setting.values[state])
    end

    return string.format("%s = %s (state=%s/%s)",
        name, value, tostring(state), tostring(maxState))
end


--- Dump effective RLSettings to the log at INFO level.
--- Every line is prefixed "RLSettings: " so a single grep extracts the snapshot.
--- Skips entries with `ignore = true` (Buttons / non-stateful UI affordances) -
--- matches the filter applied by RL_BroadcastSettingsEvent.
--- Always re-fires when called; use dumpSettingsOnce() for startup paths.
function RLDebugUtils.dumpSettings()
    Log:trace("RLDebugUtils.dumpSettings: enter")

    if RLSettings == nil or RLSettings.SETTINGS == nil then
        Log:warning("RLDebugUtils.dumpSettings: RLSettings.SETTINGS not loaded - skipping dump")
        return
    end

    local role = resolveRole()
    Log:info("RLSettings: --- %s ---", role)

    -- Iterate in stable index order, matching RLSettings.initialize lines 396-402.
    local maxIndex = 0
    for _, setting in pairs(RLSettings.SETTINGS) do
        if setting.index ~= nil and setting.index > maxIndex then maxIndex = setting.index end
    end

    for i = 1, maxIndex do
        for name, setting in pairs(RLSettings.SETTINGS) do
            if setting.index == i and not setting.ignore then
                Log:info("RLSettings: %s", formatSettingLine(name, setting))
            end
        end
    end

    -- Custom-animals breakdown: only when the toggle is on.
    local customSetting = RLSettings.SETTINGS.useCustomAnimals
    if customSetting ~= nil and customSetting.state == 2 then
        if RLSettings.animalsXMLPath ~= nil then
            Log:info("RLSettings: animalsXMLPath = %s", tostring(RLSettings.animalsXMLPath))
        end

        if RLSettings.customAnimals == nil then
            Log:info("RLSettings: customAnimals = <not validated yet>")
        else
            Log:info("RLSettings: customAnimals.basePath = %s", tostring(RLSettings.customAnimals.basePath))
            Log:info("RLSettings: customAnimals.animals = %s", tostring(RLSettings.customAnimals.animals))
            Log:info("RLSettings: customAnimals.fillTypes = %s", tostring(RLSettings.customAnimals.fillTypes))
            Log:info("RLSettings: customAnimals.translations = %s", tostring(RLSettings.customAnimals.translations))
            Log:info("RLSettings: customAnimals.override = %s", tostring(RLSettings.customAnimals.override))
        end
    end

    Log:info("RLSettings: ---END---")
end


--- One-shot wrapper around dumpSettings() for startup paths.
--- The first call dumps; subsequent calls no-op. Server startup hook
--- (RealisticLivestock_FSBaseMission.onStartMission) and client startup hook
--- (RL_BroadcastSettingsEvent:run readAll branch) both call this so SP - which
--- runs both paths - does not double-print.
function RLDebugUtils.dumpSettingsOnce()
    Log:trace("RLDebugUtils.dumpSettingsOnce: enter (already dumped=%s)", tostring(RLDebugUtils._dumped))

    if RLDebugUtils._dumped then return end

    RLDebugUtils._dumped = true
    RLDebugUtils.dumpSettings()
end
