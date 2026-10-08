--[[
    RLSeverityIcon.lua
    Severity icon for a list cell: resolve picks the profile and colour for a severity
    (RLConstants.SEVERITY_STYLE), apply writes them onto a Bitmap.

    resolve is pure (data in, data out) so it runs headless; apply and readColorBlindMode
    touch the GUI and the game settings and run in-game only. Nothing here reads an engine
    global at file scope.
]]

RLSeverityIcon = {}

local Log = RmLogging.getLogger("RLRM")

--- Resolve a severity to its icon profile and colour; nil for a severity with no icon.
--- @param severity string|nil RLConstants.SEVERITY value
--- @param isColorBlindMode boolean|nil Only exactly true selects the colour-blind colour
--- @return string|nil profile Profile name, or nil when the severity shows no icon
--- @return table|nil color {r, g, b, a}, shared and read-only
function RLSeverityIcon.resolve(severity, isColorBlindMode)
    local style = RLConstants.SEVERITY_STYLE[severity]
    if style == nil then
        Log:trace("RLSeverityIcon.resolve: severity=%s -> no icon", tostring(severity))
        return nil
    end

    local colorBlind = isColorBlindMode == true
    Log:trace("RLSeverityIcon.resolve: severity=%s colorBlind=%s -> profile=%s",
        tostring(severity), tostring(colorBlind), tostring(style.profile))
    return style.profile, style.color[colorBlind]
end

--- Show the severity icon on a Bitmap, or hide it for a severity with no icon.
--- @param element table|nil Bitmap element; nil is a no-op
--- @param severity string|nil RLConstants.SEVERITY value
--- @param isColorBlindMode boolean|nil Colour-blind state read by the caller
--- @return boolean shown True when the icon is visible after the call
function RLSeverityIcon.apply(element, severity, isColorBlindMode)
    if element == nil then
        Log:trace("RLSeverityIcon.apply: no element, severity=%s", tostring(severity))
        return false
    end

    local profile, color = RLSeverityIcon.resolve(severity, isColorBlindMode)
    if profile == nil then
        element:setVisible(false)
        return false
    end

    -- applyProfile reloads every per-state colour from the profile, so the tint follows it.
    element:applyProfile(profile)
    local r, g, b, a = color[1], color[2], color[3], color[4]
    element:setImageColor(GuiOverlay.STATE_NORMAL, r, g, b, a)
    element:setImageColor(GuiOverlay.STATE_SELECTED, r, g, b, a)
    element:setImageColor(GuiOverlay.STATE_HIGHLIGHTED, r, g, b, a)
    element:setVisible(true)
    return true
end

--- Read the game's colour-blind setting as a real boolean (nil or odd values read false).
--- @return boolean isColorBlindMode
function RLSeverityIcon.readColorBlindMode()
    local raw = g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE)
    Log:trace("RLSeverityIcon.readColorBlindMode: raw=%s", tostring(raw))
    return Utils.getNoNil(raw, false) == true
end
