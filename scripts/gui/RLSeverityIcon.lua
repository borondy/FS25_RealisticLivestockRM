--[[
    RLSeverityIcon.lua
    Severity icon for a list cell: resolve picks the profile and colour for a severity
    (RLConstants.SEVERITY_STYLE), apply writes them onto a Bitmap. A caller whose rows need
    another icon size passes its own profiles keyed by the style's shape; the glyph choice
    stays in SEVERITY_STYLE.

    resolve is pure (data in, data out) so it runs headless; apply and readColorBlindMode
    touch the GUI and the game settings and run in-game only. Nothing here reads an engine
    global at file scope.
]]

RLSeverityIcon = {}

local Log = RmLogging.getLogger("RLRM")

--- Resolve a severity to its icon profile, colour and selected-row colour; nil for a severity with no icon.
--- @param severity string|nil RLConstants.SEVERITY value
--- @param isColorBlindMode boolean|nil Only exactly true selects the colour-blind colour
--- @param profiles table|nil Shape -> profile name; replaces the style's profile when it holds the shape
--- @return string|nil profile Profile name, or nil when the severity shows no icon
--- @return table|nil color {r, g, b, a}, shared and read-only
--- @return table|nil selectedColor {r, g, b, a} for a selected row, read-only; falls back to color
function RLSeverityIcon.resolve(severity, isColorBlindMode, profiles)
    local style = RLConstants.SEVERITY_STYLE[severity]
    if style == nil then
        Log:trace("RLSeverityIcon.resolve: severity=%s -> no icon", tostring(severity))
        return nil
    end

    local profile = style.profile
    if profiles ~= nil and profiles[style.shape] ~= nil then
        profile = profiles[style.shape]
    end

    local colorBlind = isColorBlindMode == true
    local selectedSource = style.selectedColor ~= nil and "selectedColor" or "color"
    Log:trace("RLSeverityIcon.resolve: severity=%s colorBlind=%s shape=%s -> profile=%s selected=%s",
        tostring(severity), tostring(colorBlind), tostring(style.shape), tostring(profile), selectedSource)
    return profile, style.color[colorBlind], (style.selectedColor or style.color)[colorBlind]
end

--- Show the severity icon on a Bitmap, or hide it for a severity with no icon.
--- @param element table|nil Bitmap element; nil is a no-op
--- @param severity string|nil RLConstants.SEVERITY value
--- @param isColorBlindMode boolean|nil Colour-blind state read by the caller
--- @param profiles table|nil Shape -> profile name, passed through to resolve
--- @return boolean shown True when the icon is visible after the call
function RLSeverityIcon.apply(element, severity, isColorBlindMode, profiles)
    if element == nil then
        Log:trace("RLSeverityIcon.apply: no element, severity=%s", tostring(severity))
        return false
    end

    local profile, color, selectedColor = RLSeverityIcon.resolve(severity, isColorBlindMode, profiles)
    if profile == nil then
        element:setVisible(false)
        return false
    end

    -- applyProfile reloads every per-state colour from the profile, so the tint follows it.
    element:applyProfile(profile)
    local r, g, b, a = color[1], color[2], color[3], color[4]
    element:setImageColor(GuiOverlay.STATE_NORMAL, r, g, b, a)
    element:setImageColor(GuiOverlay.STATE_SELECTED,
        selectedColor[1], selectedColor[2], selectedColor[3], selectedColor[4])
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
