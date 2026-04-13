--[[
    RLDetailPaneHelper.lua
    Shared rendering logic for the pen column + animal column detail pane.

    Both RLMenuInfoFrame and RLMenuMoveFrame (and later Buy/Sell) include
    identical pen + animal column XML in their frame XMLs. This helper
    provides the Lua rendering code so it is not duplicated per frame.

    All functions take a `frame` parameter (the TabbedMenuFrameElement
    instance) which owns the auto-bound element IDs from the XML. The
    helper is stateless -- it reads element references from the frame and
    display data from RLAnimalInfoService.

    FS25 GUI XML has no <Include> mechanism, so each frame owns its own
    XML copy. This helper ensures the Lua rendering stays in one place.
]]

local Log = RmLogging.getLogger("RLRM")

RLDetailPaneHelper = {}

-- =============================================================================
-- Constants (shared across all frames that use the detail pane)
-- =============================================================================

RLDetailPaneHelper.GENETICS_COLOR = {
    infertile      = { 1.00, 0.00, 0.00, 1 },
    extremelyLow   = { 1.00, 0.00, 0.00, 1 },
    veryLow        = { 1.00, 0.20, 0.00, 1 },
    low            = { 1.00, 0.52, 0.00, 1 },
    average        = { 1.00, 1.00, 0.00, 1 },
    high           = { 0.52, 1.00, 0.00, 1 },
    veryHigh       = { 0.20, 1.00, 0.00, 1 },
    extremelyHigh  = { 0.00, 1.00, 0.00, 1 },
}

RLDetailPaneHelper.GENETICS_COLOR_NEUTRAL = { 1.00, 1.00, 1.00, 1 }

-- Number of pre-allocated XML row slots per stack
RLDetailPaneHelper.NUM_CONDITION_ROWS = 5
RLDetailPaneHelper.NUM_FOOD_ROWS      = 5
RLDetailPaneHelper.NUM_STAT_ROWS      = 10
RLDetailPaneHelper.NUM_GENETICS_ROWS  = 6
RLDetailPaneHelper.NUM_DISEASE_ROWS   = 5
RLDetailPaneHelper.NUM_INPUT_ROWS     = 3
RLDetailPaneHelper.NUM_OUTPUT_ROWS    = 5


-- =============================================================================
-- Status bar helper
-- =============================================================================

--- Apply a value/ratio + invertedBar/disabled to a single status bar element,
--- mirroring base-game InGameMenuAnimalsFrame:setStatusBarValue.
--- @param statusBarElement table|nil
--- @param value number|nil ratio in [0..1]
--- @param invertedBar boolean|nil
--- @param disabled boolean|nil
function RLDetailPaneHelper.setStatusBarValue(statusBarElement, value, invertedBar, disabled)
    if statusBarElement == nil then return end
    value = math.max(0, math.min(1, value or 0))

    if statusBarElement.parent ~= nil and statusBarElement.parent.size ~= nil then
        local fullWidth = statusBarElement.parent.size[1] - (statusBarElement.margin and statusBarElement.margin[1] * 2 or 0)
        local minSize = 0
        if statusBarElement.startSize ~= nil then
            minSize = statusBarElement.startSize[1] + statusBarElement.endSize[1]
        end
        statusBarElement:setSize(math.max(minSize, fullWidth * math.min(1, value)), nil)
    end

    if statusBarElement.setDisabled ~= nil then
        statusBarElement:setDisabled(disabled or false)
    end
end


-- =============================================================================
-- Money display
-- =============================================================================

--- Refresh the money box from the current farm balance. Hides the box when
--- the farm is missing or no farm context is available.
--- @param frame table Frame with moneyBox, moneyBoxBg, balanceText elements and farmId field
function RLDetailPaneHelper.updateMoneyDisplay(frame)
    if frame.moneyBox == nil and frame.balanceText == nil then return end

    local balance
    if frame.farmId ~= nil then
        balance = RLAnimalInfoService.getFarmBalance(frame.farmId)
    end

    Log:debug("RLDetailPaneHelper.updateMoneyDisplay: farmId=%s balance=%s",
        tostring(frame.farmId), tostring(balance))

    local visible = balance ~= nil
    if frame.moneyBox ~= nil and frame.moneyBox.setVisible ~= nil then
        frame.moneyBox:setVisible(visible)
    end
    if frame.moneyBoxBg ~= nil and frame.moneyBoxBg.setVisible ~= nil then
        frame.moneyBoxBg:setVisible(visible)
    end

    if not visible then return end

    if frame.balanceText ~= nil then
        frame.balanceText:setText(g_i18n:formatMoney(balance, 0, true, false))
        if balance < 0 and ShopMenu ~= nil and ShopMenu.GUI_PROFILE ~= nil then
            frame.balanceText:applyProfile(ShopMenu.GUI_PROFILE.SHOP_MONEY_NEGATIVE, nil, true)
        elseif ShopMenu ~= nil and ShopMenu.GUI_PROFILE ~= nil then
            frame.balanceText:applyProfile(ShopMenu.GUI_PROFILE.SHOP_MONEY, nil, true)
        end
    end

    if frame.moneyBox ~= nil and frame.moneyBox.invalidateLayout ~= nil then
        frame.moneyBox:invalidateLayout()
    end
end


-- =============================================================================
-- Pen column rendering
-- =============================================================================

--- Refresh the pen column from a husbandry display object. Hides the pen box
--- when display is nil.
--- @param frame table Frame with penBox, penNameText, penCountText, penIcon, conditionRow/Label/Value/StatusBar, foodRow/Label/Value/StatusBar etc.
--- @param husbandry table|nil The selected husbandry placeable
--- @param farmId number|nil The owning farm ID
function RLDetailPaneHelper.updatePenDisplay(frame, husbandry, farmId)
    if frame.penBox == nil then return end

    local display
    if husbandry ~= nil then
        display = RLAnimalInfoService.getHusbandryDisplay(husbandry, farmId)
    end

    if display == nil then
        frame.penBox:setVisible(false)
        Log:trace("RLDetailPaneHelper.updatePenDisplay: no husbandry, pen hidden")
        return
    end

    Log:debug("RLDetailPaneHelper.updatePenDisplay: husbandry='%s' count=%s",
        display.name, display.countText)
    frame.penBox:setVisible(true)

    if frame.penNameText ~= nil then frame.penNameText:setText(display.name) end
    if frame.penCountText ~= nil then frame.penCountText:setText(display.countText) end
    if frame.penIcon ~= nil then
        if display.penImageFilename ~= nil then
            frame.penIcon:setImageFilename(display.penImageFilename)
            frame.penIcon:setVisible(true)
        else
            frame.penIcon:setVisible(false)
        end
    end

    -- Conditions: show up to NUM_CONDITION_ROWS, hide unused
    if frame.conditionRow ~= nil then
        for index = 1, RLDetailPaneHelper.NUM_CONDITION_ROWS do
            local row = frame.conditionRow[index]
            local info = display.conditionInfos[index]
            if row ~= nil then row:setVisible(info ~= nil) end
            if info ~= nil and row ~= nil then
                local valueText = info.valueText
                if valueText == nil then
                    valueText = g_i18n:formatVolume(info.value or 0, 0, info.customUnitText)
                end
                if frame.conditionLabel and frame.conditionLabel[index] then
                    frame.conditionLabel[index]:setText(info.title or "")
                end
                if frame.conditionValue and frame.conditionValue[index] then
                    frame.conditionValue[index]:setText(valueText)
                end
                if frame.conditionStatusBar and frame.conditionStatusBar[index] then
                    RLDetailPaneHelper.setStatusBarValue(frame.conditionStatusBar[index], info.ratio, info.invertedBar, info.disabled)
                end
            end
        end
    end

    -- Food rows
    if frame.foodRow ~= nil then
        for index = 1, RLDetailPaneHelper.NUM_FOOD_ROWS do
            local row = frame.foodRow[index]
            local info = display.foodInfos[index]
            if row ~= nil then row:setVisible(info ~= nil) end
            if info ~= nil and row ~= nil then
                local valueText = g_i18n:formatVolume(info.value or 0, 0)
                if frame.foodLabel and frame.foodLabel[index] then
                    frame.foodLabel[index]:setText(info.title or "")
                end
                if frame.foodValue and frame.foodValue[index] then
                    frame.foodValue[index]:setText(valueText)
                end
                if frame.foodStatusBar and frame.foodStatusBar[index] then
                    RLDetailPaneHelper.setStatusBarValue(frame.foodStatusBar[index], info.ratio, info.invertedBar, info.disabled)
                end
            end
        end
    end

    -- Hide food chrome when this husbandry has no food mixes
    local hasFood = #display.foodInfos > 0
    if frame.foodRowTotal ~= nil then frame.foodRowTotal:setVisible(hasFood) end
    if frame.penFoodHeader ~= nil then frame.penFoodHeader:setVisible(hasFood) end

    if hasFood then
        if frame.foodRowTotalValue ~= nil then
            frame.foodRowTotalValue:setText(g_i18n:formatVolume(display.foodTotalValue, 0))
        end
        if frame.foodRowTotalStatusBar ~= nil then
            RLDetailPaneHelper.setStatusBarValue(frame.foodRowTotalStatusBar, display.foodTotalRatio, false)
        end
        if frame.foodHeader ~= nil then
            frame.foodHeader:setText(string.format("%s (%s)",
                g_i18n:getText("ui_silos_totalCapacity"),
                g_i18n:getText("animals_foodMixEffectiveness")))
        end
    end

    if frame.penRequirementsLayout ~= nil and frame.penRequirementsLayout.invalidateLayout ~= nil then
        frame.penRequirementsLayout:invalidateLayout()
    end
end


-- =============================================================================
-- Animal column rendering
-- =============================================================================

--- Render the per-animal stat rows as a 2x5 grid of plain label/value text
--- pairs (no status bars). Variable count handled by hide-unused.
--- @param frame table Frame with statRow/statLabel/statValue[1..NUM_STAT_ROWS]
--- @param statRows table list of {title, valueText, value, customUnitText}
function RLDetailPaneHelper.updateAnimalStats(frame, statRows)
    if frame.statRow == nil then return end
    for index = 1, RLDetailPaneHelper.NUM_STAT_ROWS do
        local row = frame.statRow[index]
        local info = statRows[index]
        if row ~= nil then row:setVisible(info ~= nil) end
        if info ~= nil then
            local valueText = info.valueText
            if valueText == nil and info.value ~= nil then
                valueText = g_i18n:formatVolume(info.value, 0, info.customUnitText)
            end
            if frame.statLabel and frame.statLabel[index] then
                frame.statLabel[index]:setText(info.title or "")
            end
            if frame.statValue and frame.statValue[index] then
                frame.statValue[index]:setText(valueText or "")
            end
        end
    end
end


--- Render one parent pedigree row (mother or father).
--- @param textElement table|nil
--- @param row table|nil {labelKey, idText|nil, unknownKey|nil}
function RLDetailPaneHelper._renderPedigreeRow(textElement, row)
    if textElement == nil or row == nil then return end
    local label = g_i18n:getText(row.labelKey)
    local valueText
    if row.idText ~= nil then
        valueText = string.format("%s (%s)", label, row.idText)
    else
        valueText = string.format("%s (%s)", label, g_i18n:getText(row.unknownKey or "rl_ui_unknown"))
    end
    textElement:setText(valueText)
end


--- Refresh the animal column from a cluster/animal. Hides the animal box
--- when no animal is supplied.
--- @param frame table Frame with animalBox, animalDetailTypeImage, animalDetailTypeNameText, statRow/Label/Value, geneticsRow/Label/Value, diseaseRow/Name/Status, pedigree*, monitor* elements
--- @param animal table|nil The animal cluster to display
--- @param husbandry table|nil The selected husbandry (for getAnimalDisplay context)
function RLDetailPaneHelper.updateAnimalDisplay(frame, animal, husbandry)
    if frame.animalBox == nil then return end

    local display
    if animal ~= nil then
        display = RLAnimalInfoService.getAnimalDisplay(animal, husbandry)
    end

    if display == nil then
        frame.animalBox:setVisible(false)
        Log:trace("RLDetailPaneHelper.updateAnimalDisplay: no animal, animal box hidden")
        return
    end

    Log:debug("RLDetailPaneHelper.updateAnimalDisplay: farmId=%s uniqueId=%s",
        tostring(animal.farmId), tostring(animal.uniqueId))
    frame.animalBox:setVisible(true)

    if frame.animalDetailTypeNameText ~= nil then
        frame.animalDetailTypeNameText:setText(display.typeName)
    end
    if frame.animalDetailTypeImage ~= nil then
        if display.animalImageFilename ~= nil then
            frame.animalDetailTypeImage:setImageFilename(display.animalImageFilename)
            frame.animalDetailTypeImage:setVisible(true)
        else
            frame.animalDetailTypeImage:setVisible(false)
        end
    end

    -- Stat rows from husbandry:getAnimalInfos
    RLDetailPaneHelper.updateAnimalStats(frame, display.statRows or {})

    if frame.animalDescriptionText ~= nil then
        frame.animalDescriptionText:setText(display.description or "")
    end

    -- Pedigree
    RLDetailPaneHelper._renderPedigreeRow(frame.pedigreeMotherText, display.pedigreeMother)
    RLDetailPaneHelper._renderPedigreeRow(frame.pedigreeFatherText, display.pedigreeFather)
    if frame.pedigreeChildrenText ~= nil and display.pedigreeChildren ~= nil then
        frame.pedigreeChildrenText:setText(string.format("%s: %d",
            g_i18n:getText(display.pedigreeChildren.labelKey), display.pedigreeChildren.count))
    end

    -- Genetics rows
    if frame.geneticsRow ~= nil then
        for index = 1, RLDetailPaneHelper.NUM_GENETICS_ROWS do
            local row = frame.geneticsRow[index]
            local data = display.geneticsRows[index]
            if row ~= nil then row:setVisible(data ~= nil) end
            if data ~= nil and row ~= nil then
                if frame.geneticsLabel and frame.geneticsLabel[index] then
                    frame.geneticsLabel[index]:setText(g_i18n:getText(data.labelKey))
                end
                if frame.geneticsValue and frame.geneticsValue[index] then
                    frame.geneticsValue[index]:setText(g_i18n:getText(data.valueKey))
                end
                local color = RLDetailPaneHelper.GENETICS_COLOR[data.colorKey]
                    or RLDetailPaneHelper.GENETICS_COLOR_NEUTRAL
                if frame.geneticsLabel and frame.geneticsLabel[index] and frame.geneticsLabel[index].setTextColor then
                    frame.geneticsLabel[index]:setTextColor(unpack(color))
                end
                if frame.geneticsValue and frame.geneticsValue[index] and frame.geneticsValue[index].setTextColor then
                    frame.geneticsValue[index]:setTextColor(unpack(color))
                end
            end
        end
    end

    -- Disease rows
    local hasDiseases = #display.diseaseRows > 0
    if frame.diseaseColumn ~= nil then
        frame.diseaseColumn:setVisible(hasDiseases)
    end
    if hasDiseases and frame.diseaseRow ~= nil then
        for index = 1, RLDetailPaneHelper.NUM_DISEASE_ROWS do
            local row = frame.diseaseRow[index]
            local data = display.diseaseRows[index]
            if row ~= nil then row:setVisible(data ~= nil) end
            if data ~= nil and row ~= nil then
                if frame.diseaseName and frame.diseaseName[index] then
                    frame.diseaseName[index]:setText(data.name or "")
                end
                if frame.diseaseStatus and frame.diseaseStatus[index] then
                    frame.diseaseStatus[index]:setText(data.status or "")
                end
            end
        end
    end

    -- Monitor input/output rows
    local hasMonitor = display.hasMonitor or false
    if frame.monitorColumnsRow ~= nil then
        frame.monitorColumnsRow:setVisible(hasMonitor)
    end
    if hasMonitor then
        if frame.inputRow ~= nil then
            for index = 1, RLDetailPaneHelper.NUM_INPUT_ROWS do
                local row = frame.inputRow[index]
                local data = display.inputRows[index]
                if row ~= nil then row:setVisible(data ~= nil) end
                if data ~= nil and row ~= nil then
                    if frame.inputLabel and frame.inputLabel[index] then
                        frame.inputLabel[index]:setText(data.title or "")
                    end
                    if frame.inputValue and frame.inputValue[index] then
                        frame.inputValue[index]:setText(data.valueText or "")
                    end
                end
            end
        end
        if frame.outputRow ~= nil then
            for index = 1, RLDetailPaneHelper.NUM_OUTPUT_ROWS do
                local row = frame.outputRow[index]
                local data = display.outputRows[index]
                if row ~= nil then row:setVisible(data ~= nil) end
                if data ~= nil and row ~= nil then
                    if frame.outputLabel and frame.outputLabel[index] then
                        frame.outputLabel[index]:setText(data.title or "")
                    end
                    if frame.outputValue and frame.outputValue[index] then
                        frame.outputValue[index]:setText(data.valueText or "")
                    end
                end
            end
        end
        if frame.inputColumn ~= nil and frame.inputColumn.invalidateLayout ~= nil then
            frame.inputColumn:invalidateLayout()
        end
        if frame.outputColumn ~= nil and frame.outputColumn.invalidateLayout ~= nil then
            frame.outputColumn:invalidateLayout()
        end
    end

    -- Invalidate BoxLayouts in the scrollable area
    if frame.pedigreeColumn ~= nil and frame.pedigreeColumn.invalidateLayout ~= nil then
        frame.pedigreeColumn:invalidateLayout()
    end
    if frame.geneticsColumn ~= nil and frame.geneticsColumn.invalidateLayout ~= nil then
        frame.geneticsColumn:invalidateLayout()
    end
    if hasDiseases and frame.diseaseColumn ~= nil and frame.diseaseColumn.invalidateLayout ~= nil then
        frame.diseaseColumn:invalidateLayout()
    end
    if frame.animalColumnsRow ~= nil and frame.animalColumnsRow.invalidateLayout ~= nil then
        frame.animalColumnsRow:invalidateLayout()
    end
    if hasMonitor and frame.monitorColumnsRow ~= nil and frame.monitorColumnsRow.invalidateLayout ~= nil then
        frame.monitorColumnsRow:invalidateLayout()
    end
    if frame.animalScrollLayout ~= nil and frame.animalScrollLayout.invalidateLayout ~= nil then
        frame.animalScrollLayout:invalidateLayout()
    end
end


-- =============================================================================
-- Clear helpers
-- =============================================================================

--- Hide the pen and animal boxes. Header + money stay visible.
--- @param frame table Frame with penBox and animalBox elements
function RLDetailPaneHelper.clearDetail(frame)
    Log:trace("RLDetailPaneHelper.clearDetail")
    if frame.penBox ~= nil then frame.penBox:setVisible(false) end
    RLDetailPaneHelper.clearAnimalDetail(frame)
end

--- Hide just the animal box.
--- @param frame table Frame with animalBox element
function RLDetailPaneHelper.clearAnimalDetail(frame)
    Log:trace("RLDetailPaneHelper.clearAnimalDetail")
    if frame.animalBox ~= nil then frame.animalBox:setVisible(false) end
end
