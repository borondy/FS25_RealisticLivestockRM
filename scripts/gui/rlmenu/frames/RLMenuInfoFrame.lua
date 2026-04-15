--[[
    RLMenuInfoFrame.lua
    RL Tabbed Menu - Info tab.

    Left-sidebar husbandry picker with dot indicators, multi-section
    SmoothList of animal cards, and right-hand detail pane.
]]

RLMenuInfoFrame = {}
local RLMenuInfoFrame_mt = Class(RLMenuInfoFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory

-- Detail pane constants + rendering logic live in RLDetailPaneHelper (shared
-- with RLMenuMoveFrame and future Buy/Sell frames). This frame delegates
-- pen/animal column rendering to that helper.

-- Mark uses MENU_EXTRA_1 (X), Castrate uses MENU_EXTRA_2 (C) to avoid
-- key conflicts with the TabbedMenu defaults on those same keys.
-- Other mutations use custom RL_* actions.

---Construct a new RLMenuInfoFrame instance. Called once by setupGui.
---@return table self
function RLMenuInfoFrame.new()
    local self = RLMenuInfoFrame:superClass().new(nil, RLMenuInfoFrame_mt)
    self.name = "RLMenuInfoFrame"

    self.sortedHusbandries = {}
    self.selectedHusbandry = nil
    self.items             = {}
    self.filters           = {}
    self.farmId            = nil

    self.sectionOrder      = {}
    self.itemsBySection    = {}
    self.titlesBySection   = {}

    self.selectedIdentity  = nil  -- { farmId, uniqueId, country }

    -- Track husbandry's animal type so we can clear filters on type change
    -- (cow filters reference fields a sheep doesn't have and would drop every row).
    self.activeAnimalTypeIndex = nil

    self.isFrameOpen = false

    self.hasCustomMenuButtons = true
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
    self.filterButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_info_filter_button"),
        callback = function() self:onClickFilter() end,
    }
    self.markButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_ui_mark"),
        callback = function() self:onClickMark() end,
    }
    self.monitorButtonInfo = {
        inputAction = InputAction.RL_MONITOR,
        text = g_i18n:getText("rl_ui_applyMonitor"),
        callback = function() self:onClickMonitor() end,
    }
    self.renameButtonInfo = {
        inputAction = InputAction.RL_RENAME,
        text = g_i18n:getText("rl_ui_rename"),
        callback = function() self:onClickRename() end,
    }
    self.diseasesButtonInfo = {
        inputAction = InputAction.RL_DISEASES,
        text = g_i18n:getText("rl_diseases"),
        callback = function() self:onClickDiseases() end,
    }
    self.castrateButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_ui_castrate"),
        callback = function() self:onClickCastrate() end,
    }
    self.inseminateButtonInfo = {
        inputAction = InputAction.RL_AI,
        text = g_i18n:getText("rl_ui_artificialInsemination"),
        callback = function() self:onClickInseminate() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end

---Load the info frame XML and register it with g_gui so the host menu's
---FrameReference can resolve it.
function RLMenuInfoFrame.setupGui()
    local frame = RLMenuInfoFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/infoFrame.xml", modDirectory),
        "RLMenuInfoFrame",
        frame,
        true
    )
    Log:debug("RLMenuInfoFrame.setupGui: registered")
end

--- Bind the SmoothList datasource/delegate. Must not mutate the element
--- tree here: this hook fires on both the frame-only load instance AND
--- the clone resolveFrameReference creates, and tree mutation on the
--- first instance leaves the clone without what it needs. Tree mutation
--- lives in `initialize()` below, called by the host menu on the clone.
function RLMenuInfoFrame:onGuiSetupFinished()
    RLMenuInfoFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuInfoFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end

--- One-time per-clone setup. Called explicitly by RLMenu:setupMenuPages
--- after the page is registered.
function RLMenuInfoFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuInfoFrame:initialize: subCategoryDotTemplate missing - dots will not render")
    end
end

-- =============================================================================
-- Lifecycle
-- =============================================================================

---Called by the Paging element when this tab becomes active.
function RLMenuInfoFrame:onFrameOpen()
    RLMenuInfoFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true

    -- Import shared selection from sibling frame (Info <-> Move <-> Sell)
    if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil then
        local shared = g_rlMenu.sharedSelection
        if shared.animalIdentity ~= nil then
            self.selectedIdentity = shared.animalIdentity
        end
        Log:debug("RLMenuInfoFrame:onFrameOpen: imported shared selection (husbandry=%s animal=%s/%s)",
            tostring(shared.husbandry ~= nil and shared.husbandry:getName() or "nil"),
            tostring(shared.animalIdentity and shared.animalIdentity.farmId),
            tostring(shared.animalIdentity and shared.animalIdentity.uniqueId))
    end

    -- refreshHusbandries owns chrome state for both populated and empty
    -- husbandry cases. Do NOT clearDetail here: refreshHusbandries auto-
    -- selects state 1, which fires onHusbandryChanged -> updatePenDisplay,
    -- and a trailing clearDetail would wipe the pen we just rendered.
    self:refreshHusbandries()

    -- Explicit focus links for keyboard navigation (Fresh RmSettingsFrame
    -- pattern). Required because multiple frames share the same sidebar +
    -- SmoothList structure, and FocusManager auto-layout resolves to
    -- elements in other frames when element positions/IDs overlap.
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end
end

---Called by the Paging element when this tab is deactivated.
function RLMenuInfoFrame:onFrameClose()
    -- Export selection to shared state for sibling frames
    self:captureCurrentSelection()
    if g_rlMenu ~= nil then
        g_rlMenu.sharedSelection = {
            husbandry      = self.selectedHusbandry,
            animalIdentity = self.selectedIdentity,
        }
        Log:debug("RLMenuInfoFrame:onFrameClose: exported shared selection (husbandry=%s animal=%s/%s)",
            tostring(self.selectedHusbandry ~= nil and self.selectedHusbandry:getName() or "nil"),
            tostring(self.selectedIdentity and self.selectedIdentity.farmId),
            tostring(self.selectedIdentity and self.selectedIdentity.uniqueId))
    end

    RLMenuInfoFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end

-- =============================================================================
-- Husbandry selector
-- =============================================================================

--- Repopulate the husbandry selector + dot indicators for the player's farm.
function RLMenuInfoFrame:refreshHusbandries()
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    self.farmId = farmId

    self.sortedHusbandries = RLAnimalQuery.listHusbandriesForFarm(farmId)
    Log:debug("RLMenuInfoFrame:refreshHusbandries: farmId=%s husbandries=%d",
        tostring(farmId), #self.sortedHusbandries)

    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end

    if #self.sortedHusbandries == 0 then
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(true) end
        if self.subCategoryDotBox ~= nil then self.subCategoryDotBox:setVisible(false) end
        if self.subCategorySelector ~= nil then self.subCategorySelector:setTexts({}) end
        self.selectedHusbandry = nil
        self.items = {}
        if self.animalList ~= nil then self.animalList:reloadData() end
        self:updateEmptyState()
        self:updateButtonVisibility()
        -- Hide pen + animal chrome on the empty path; in the populated
        -- branch onHusbandryChanged renders them via updatePenDisplay.
        self:updateMoneyDisplay()
        self:clearDetail()
        return
    end

    if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(false) end

    local names = {}
    for index, husbandry in ipairs(self.sortedHusbandries) do
        names[index] = RLAnimalQuery.formatHusbandryLabel(husbandry, index)

        if self.subCategoryDotTemplate ~= nil and self.subCategoryDotBox ~= nil then
            local dot = self.subCategoryDotTemplate:clone(self.subCategoryDotBox)
            local dotIndex = index
            function dot.getIsSelected()
                return self.subCategorySelector ~= nil
                    and self.subCategorySelector:getState() == dotIndex
            end
        end
    end

    if self.subCategoryDotBox ~= nil then
        self.subCategoryDotBox:invalidateLayout()
        self.subCategoryDotBox:setVisible(1 < #names)
    end

    -- Resolve initial husbandry: match shared selection by placeable reference,
    -- fall back to state 1 if not found or no shared state.
    local initialState = 1
    if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil
        and g_rlMenu.sharedSelection.husbandry ~= nil then
        for i, h in ipairs(self.sortedHusbandries) do
            if h == g_rlMenu.sharedSelection.husbandry then
                initialState = i
                break
            end
        end
        Log:trace("RLMenuInfoFrame:refreshHusbandries: shared husbandry resolved to state=%d", initialState)
    end

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(names)
        self.subCategorySelector:setState(initialState, true)
    else
        self:onHusbandryChanged(initialState)
    end
end

--- MultiTextOption onClick callback. Clears filters on animal-type change
--- so filter fields from the previous type can't reference missing data.
--- @param state number 1-based husbandry index
function RLMenuInfoFrame:onHusbandryChanged(state)
    if state == nil or state < 1 or state > #self.sortedHusbandries then return end

    self.selectedHusbandry = self.sortedHusbandries[state]
    local newTypeIndex
    if self.selectedHusbandry ~= nil and self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        newTypeIndex = self.selectedHusbandry:getAnimalTypeIndex()
    end

    if self.activeAnimalTypeIndex ~= nil
        and newTypeIndex ~= nil
        and newTypeIndex ~= self.activeAnimalTypeIndex
        and next(self.filters) ~= nil then
        Log:debug("RLMenuInfoFrame:onHusbandryChanged: animal type changed (%s -> %s), clearing filters",
            tostring(self.activeAnimalTypeIndex), tostring(newTypeIndex))
        self.filters = {}
    end
    self.activeAnimalTypeIndex = newTypeIndex

    Log:debug("RLMenuInfoFrame:onHusbandryChanged: state=%d husbandry='%s'",
        state,
        (self.selectedHusbandry ~= nil and self.selectedHusbandry.getName ~= nil
            and self.selectedHusbandry:getName()) or "?")

    self:reloadAnimalList()
    self:updatePenDisplay()
    self:updateMoneyDisplay()
    -- Do NOT clearAnimalDetail() here. reloadAnimalList -> restoreSelection
    -- now actively seeds the animal column for the auto-selected first row
    -- A trailing clear would wipe what restoreSelection just rendered.
    -- The empty-husbandry case is handled inside restoreSelection itself.
end

---SmoothList delegate: fired when the user picks a different row.
---@param list table
---@param section number
---@param index number
function RLMenuInfoFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuInfoFrame:onListSelectionChanged: section=%d index=%d", section, index)

    local key = self.sectionOrder[section]
    if key == nil then
        self:clearAnimalDetail()
        return
    end
    local items = self.itemsBySection[key]
    if items == nil then
        self:clearAnimalDetail()
        return
    end
    local item = items[index]
    if item == nil or item.cluster == nil then
        self:clearAnimalDetail()
        return
    end

    self:updateAnimalDisplay(item.cluster)
    self:updateButtonVisibility()
end

-- =============================================================================
-- Animal list
-- =============================================================================

--- Requery the current husbandry, group into sections, refresh the SmoothList,
--- restore selection by (farmId, uniqueId, country) identity.
function RLMenuInfoFrame:reloadAnimalList()
    self:captureCurrentSelection()

    if self.selectedHusbandry == nil then
        self.items = {}
    else
        self.items = RLAnimalQuery.listAnimalsForHusbandry(self.selectedHusbandry, self.filters)
    end

    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLAnimalQuery.buildSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:restoreSelection()
    self:updateEmptyState()
    self:updateButtonVisibility()
end

--- Capture the currently highlighted animal's identity so it can be re-selected
--- after the next reload.
function RLMenuInfoFrame:captureCurrentSelection()
    if self.animalList == nil then return end
    local section = self.animalList.selectedSectionIndex
    local index   = self.animalList.selectedIndex
    if section == nil or index == nil then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local list = self.itemsBySection[key]
    if list == nil or index < 1 or index > #list then return end

    local item = list[index]
    if item == nil or item.cluster == nil then return end

    local cluster = item.cluster
    local country = ""
    if cluster.birthday ~= nil then country = cluster.birthday.country or "" end
    self.selectedIdentity = {
        farmId   = cluster.farmId or 0,
        uniqueId = cluster.uniqueId or 0,
        country  = country,
    }
end

--- Re-highlight the previously selected animal. Falls back to (1, 1) when
--- the previous animal is no longer present.
function RLMenuInfoFrame:restoreSelection()
    if self.animalList == nil then return end

    if #self.sectionOrder == 0 then
        self.selectedIdentity = nil
        -- Husbandry has no animals: explicitly clear the animal column so
        -- stale data from a previous husbandry doesn't linger on screen.
        self:clearAnimalDetail()
        return
    end

    local section, index
    if self.selectedIdentity ~= nil then
        section, index = RLAnimalQuery.findSectionedItemByIdentity(
            self.sectionOrder,
            self.itemsBySection,
            self.selectedIdentity.farmId,
            self.selectedIdentity.uniqueId,
            self.selectedIdentity.country
        )
    end

    if section == nil or index == nil then
        section, index = 1, 1
    end

    self.animalList:setSelectedItem(section, index, false, true)

    -- SmoothList:setSelectedItem is programmatic and does NOT fire
    -- onListSelectionChanged. Seed the animal column manually so the
    -- auto-selected first row populates the right pane on initial open.
    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item ~= nil and item.cluster ~= nil then
        self:updateAnimalDisplay(item.cluster)
    end
end

-- =============================================================================
-- Empty state / buttons
-- =============================================================================

---Toggle empty-state text + list chrome based on the current data.
function RLMenuInfoFrame:updateEmptyState()
    local hasHusbandries = #self.sortedHusbandries > 0
    local hasItems = #self.items > 0

    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(hasHusbandries and not hasItems)
    end
    if self.noHusbandriesText ~= nil then
        self.noHusbandriesText:setVisible(not hasHusbandries)
    end
    if self.animalList ~= nil then
        self.animalList:setVisible(hasItems)
    end
end

---Resolve the currently selected animal from the list on demand.
---@return table|nil
function RLMenuInfoFrame:getSelectedAnimal()
    if self.animalList == nil then return nil end
    local section = self.animalList.selectedSectionIndex
    local index   = self.animalList.selectedIndex
    if section == nil or index == nil then return nil end

    local key = self.sectionOrder[section]
    if key == nil then return nil end
    local items = self.itemsBySection[key]
    if items == nil then return nil end
    local item = items[index]
    if item == nil then return nil end
    return item.cluster
end

---Rebuild the footer button info. Back is always shown; Filter only when
---at least one husbandry is available to filter. Mutation buttons are
---added conditionally based on the currently selected animal.
function RLMenuInfoFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }
    if #self.sortedHusbandries > 0 then
        table.insert(self.menuButtonInfo, self.filterButtonInfo)
    end

    local animal = self:getSelectedAnimal()
    if animal ~= nil then
        -- Mark - always shown, text toggles
        local isMarked = animal.getMarked ~= nil and animal:getMarked()
        self.markButtonInfo.text = g_i18n:getText(isMarked and "rl_ui_unmark" or "rl_ui_mark")
        table.insert(self.menuButtonInfo, self.markButtonInfo)

        -- Monitor - always shown, 3-state text + disabled
        local monitor = animal.monitor
        if monitor ~= nil then
            local monitorText = monitor.removed and "removing" or (monitor.active and "remove" or "apply")
            self.monitorButtonInfo.text = g_i18n:getText("rl_ui_" .. monitorText .. "Monitor")
            self.monitorButtonInfo.disabled = monitor.removed
        else
            self.monitorButtonInfo.text = g_i18n:getText("rl_ui_applyMonitor")
            self.monitorButtonInfo.disabled = false
        end
        table.insert(self.menuButtonInfo, self.monitorButtonInfo)

        -- Rename - always shown
        table.insert(self.menuButtonInfo, self.renameButtonInfo)

        -- Diseases - always shown
        table.insert(self.menuButtonInfo, self.diseasesButtonInfo)

        -- Castrate - males only, not chickens
        if animal.gender == "male" and animal.animalTypeIndex ~= AnimalType.CHICKEN then
            self.castrateButtonInfo.disabled = animal.isCastrated
            table.insert(self.menuButtonInfo, self.castrateButtonInfo)
        end

        -- Inseminate - females only, disabled per conditions
        if animal.gender == "female" then
            local cannotInseminate = animal.pregnancy ~= nil
                or animal.isPregnant
                or animal.insemination ~= nil
                or (animal.getSubType ~= nil
                    and animal.age < animal:getSubType().reproductionMinAgeMonth)
                or (animal.isParent and animal.monthsSinceLastBirth ~= nil
                    and animal.monthsSinceLastBirth <= 2)
            self.inseminateButtonInfo.disabled = cannotInseminate
            table.insert(self.menuButtonInfo, self.inseminateButtonInfo)
        end
    end

    -- DEBUG: log button count and each action for keybinding diagnosis
    Log:debug("RLMenuInfoFrame:updateButtonVisibility: %d buttons in menuButtonInfo", #self.menuButtonInfo)
    for i, info in ipairs(self.menuButtonInfo) do
        Log:trace("  button[%d]: action=%s text=%s disabled=%s",
            i, tostring(info.inputAction), tostring(info.text), tostring(info.disabled))
    end

    self:setMenuButtonInfoDirty()
end

---Refresh list rows, detail pane, and button bar after a mutation.
---Called by mutation handlers to ensure the UI reflects the new state.
function RLMenuInfoFrame:refreshAfterMutation()
    -- Reload list rows (mark tint, name text may have changed)
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    -- Re-render the animal detail pane
    local animal = self:getSelectedAnimal()
    if animal ~= nil then
        Log:trace("RLMenuInfoFrame:refreshAfterMutation: re-rendering detail for farmId=%s uniqueId=%s",
            tostring(animal.farmId), tostring(animal.uniqueId))
        self:updateAnimalDisplay(animal)
    else
        Log:trace("RLMenuInfoFrame:refreshAfterMutation: no animal selected after reload")
    end
    -- Rebuild button bar (text, disabled states)
    self:updateButtonVisibility()
end

-- =============================================================================
-- Filter button
-- =============================================================================

---Open AnimalFilterDialog for the current husbandry's animals.
function RLMenuInfoFrame:onClickFilter()
    if self.selectedHusbandry == nil then return end
    if AnimalFilterDialog == nil or AnimalFilterDialog.show == nil then
        Log:warning("RLMenuInfoFrame:onClickFilter: AnimalFilterDialog unavailable")
        return
    end

    local animalTypeIndex
    if self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        animalTypeIndex = self.selectedHusbandry:getAnimalTypeIndex()
    end

    Log:debug("RLMenuInfoFrame:onClickFilter: opening dialog for %d items, animalTypeIndex=%s",
        #self.items, tostring(animalTypeIndex))

    AnimalFilterDialog.show(self.items, animalTypeIndex, self.onFilterApplied, self, false)
end

---AnimalFilterDialog callback fired on OK. Stores filters and re-queries.
---@param filters table
---@param _items table unused; we re-query via reloadAnimalList
function RLMenuInfoFrame:onFilterApplied(filters, _items)
    Log:debug("RLMenuInfoFrame:onFilterApplied: %d filter(s) active",
        (filters ~= nil and #filters) or 0)
    self.filters = filters or {}
    self:reloadAnimalList()
end

-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

---SmoothList data source: number of sections in the list.
---@param list table
---@return number
function RLMenuInfoFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

---SmoothList data source: title for the given section header cell.
---@param list table
---@param section number
---@return string|nil
function RLMenuInfoFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

---SmoothList data source: number of items in the given section.
---@param list table
---@param section number
---@return number
function RLMenuInfoFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

---SmoothList delegate: populate one data cell from the item at (section, index).
---@param list table
---@param section number
---@param index number
---@param cell table
function RLMenuInfoFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.animalList then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item == nil then return end

    local row = RLAnimalQuery.formatAnimalRow(item)

    -- Cell tint: disease red, marked orange, normal otherwise.
    if cell.setImageColor ~= nil then
        if row.tint == RLAnimalQuery.TINT_DISEASE then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.08, 0)
        elseif row.tint == RLAnimalQuery.TINT_MARKED then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.2, 0)
        else
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 1, 1)
        end
    end

    local iconCell = cell:getAttribute("icon")
    if iconCell ~= nil then
        if row.icon ~= nil then
            iconCell:setImageFilename(row.icon)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    -- Name split: baseName empty -> show idNoName only; else show id + name.
    local idNoNameCell = cell:getAttribute("idNoName")
    local idCell       = cell:getAttribute("id")
    local nameCell     = cell:getAttribute("name")
    local hasBaseName  = row.baseName ~= ""
    if idNoNameCell ~= nil then
        idNoNameCell:setText(row.displayIdentifier)
        idNoNameCell:setVisible(not hasBaseName)
    end
    if idCell ~= nil then
        idCell:setText(row.identifier)
        idCell:setVisible(hasBaseName)
    end
    if nameCell ~= nil then
        nameCell:setText(row.displayName)
        nameCell:setVisible(hasBaseName)
    end

    local priceCell = cell:getAttribute("price")
    if priceCell ~= nil then
        if priceCell.setValue ~= nil then
            priceCell:setValue(row.price)
        else
            priceCell:setText(tostring(row.price))
        end
    end

    local descriptor = cell:getAttribute("herdsmanPurchase")
    if descriptor ~= nil then
        descriptor:setVisible(row.descriptorVisible)
        if row.descriptorVisible then
            descriptor:setText(row.descriptorText)
        end
    end

    -- Status icons: resolve from row state, right-justify into slots 4..1.
    local icons = RLAnimalQuery.resolveStatusIcons(row)
    local SLOT_NAMES = { "statusIcon1", "statusIcon2", "statusIcon3", "statusIcon4" }
    local slotCount = #SLOT_NAMES
    for i = 1, slotCount do
        local slot = cell:getAttribute(SLOT_NAMES[i])
        if slot ~= nil then
            local iconIndex = i - (slotCount - #icons)
            local def = icons[iconIndex]
            if def ~= nil then
                slot:setImageSlice(GuiOverlay.STATE_NORMAL, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_SELECTED, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_HIGHLIGHTED, def.slice)
                slot:setImageColor(GuiOverlay.STATE_NORMAL, def.r, def.g, def.b)
                slot:setImageColor(GuiOverlay.STATE_SELECTED, 0.015, 0.017, 0.015)
                slot:setImageColor(GuiOverlay.STATE_HIGHLIGHTED, 0.015, 0.017, 0.015)
                slot:setVisible(true)
            else
                slot:setVisible(false)
            end
        end
    end
end

-- =============================================================================
-- Detail pane
-- =============================================================================

--- Delegate to RLDetailPaneHelper.updateMoneyDisplay.
function RLMenuInfoFrame:updateMoneyDisplay()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end

--- Delegate to RLDetailPaneHelper.updatePenDisplay.
function RLMenuInfoFrame:updatePenDisplay()
    RLDetailPaneHelper.updatePenDisplay(self, self.selectedHusbandry, self.farmId)
end

--- Delegate to RLDetailPaneHelper.updateAnimalDisplay.
--- @param animal table|nil
function RLMenuInfoFrame:updateAnimalDisplay(animal)
    RLDetailPaneHelper.updateAnimalDisplay(self, animal, self.selectedHusbandry)
end

--- Delegate to RLDetailPaneHelper.clearDetail.
function RLMenuInfoFrame:clearDetail()
    RLDetailPaneHelper.clearDetail(self)
end

--- Delegate to RLDetailPaneHelper.clearAnimalDetail.
function RLMenuInfoFrame:clearAnimalDetail()
    RLDetailPaneHelper.clearAnimalDetail(self)
end

-- =============================================================================
-- Mutation handlers
-- =============================================================================

---Toggle player mark. Delegates to RLAnimalInfoService (mutation + MP event).
function RLMenuInfoFrame:onClickMark()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuInfoFrame:onClickMark: no animal selected, early return")
        return
    end

    local wasMarked = animal.getMarked ~= nil and animal:getMarked()
    local isMarked = not wasMarked
    Log:trace("RLMenuInfoFrame:onClickMark: farmId=%s uniqueId=%s wasMarked=%s -> isMarked=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(wasMarked), tostring(isMarked))

    local key = isMarked and "PLAYER" or nil
    RLAnimalInfoService.markAnimal(animal, key, isMarked)

    Log:debug("RLMenuInfoFrame:onClickMark: farmId=%s uniqueId=%s marked=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(isMarked))
    self:refreshAfterMutation()
end

---Toggle monitor. Delegates to RLAnimalInfoService.
function RLMenuInfoFrame:onClickMonitor()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuInfoFrame:onClickMonitor: no animal selected, early return")
        return
    end

    Log:trace("RLMenuInfoFrame:onClickMonitor: farmId=%s uniqueId=%s monitor.active=%s monitor.removed=%s",
        tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(animal.monitor and animal.monitor.active), tostring(animal.monitor and animal.monitor.removed))

    local active, removed = RLAnimalInfoService.toggleMonitor(animal)

    Log:debug("RLMenuInfoFrame:onClickMonitor: farmId=%s uniqueId=%s -> active=%s removed=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(active), tostring(removed))
    self:refreshAfterMutation()
end

---Open rename dialog. Pre-fills with current name or a random one.
function RLMenuInfoFrame:onClickRename()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuInfoFrame:onClickRename: no animal selected, early return")
        return
    end

    local name = animal.name
    if name == nil and g_currentMission ~= nil
        and g_currentMission.animalNameSystem ~= nil then
        name = g_currentMission.animalNameSystem:getRandomName(animal.gender)
        Log:trace("RLMenuInfoFrame:onClickRename: no existing name, generated random: %s", tostring(name))
    else
        Log:trace("RLMenuInfoFrame:onClickRename: existing name: %s", tostring(name))
    end

    Log:debug("RLMenuInfoFrame:onClickRename: farmId=%s uniqueId=%s opening dialog, prefill=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(name))
    NameInputDialog.show(self.onRenameDone, self, name, nil, 30, nil, animal.gender)
end

---NameInputDialog callback. Delegates to RLAnimalInfoService.
---@param text string
---@param clickOk boolean
function RLMenuInfoFrame:onRenameDone(text, clickOk)
    if not clickOk then
        Log:trace("RLMenuInfoFrame:onRenameDone: user cancelled dialog")
        return
    end

    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuInfoFrame:onRenameDone: no animal selected, early return")
        return
    end

    Log:debug("RLMenuInfoFrame:onRenameDone: farmId=%s uniqueId=%s newName=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(text))
    RLAnimalInfoService.renameAnimal(animal, text)
    self:refreshAfterMutation()
end

---Open disease treatment dialog.
function RLMenuInfoFrame:onClickDiseases()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuInfoFrame:onClickDiseases: no animal selected, early return")
        return
    end
    if DiseaseDialog == nil or DiseaseDialog.show == nil then
        Log:warning("RLMenuInfoFrame:onClickDiseases: DiseaseDialog unavailable")
        return
    end

    Log:debug("RLMenuInfoFrame:onClickDiseases: farmId=%s uniqueId=%s opening dialog",
        tostring(animal.farmId), tostring(animal.uniqueId))
    DiseaseDialog.show(animal, self.refreshAfterMutation, self)
end

---Open insemination dialog.
function RLMenuInfoFrame:onClickInseminate()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuInfoFrame:onClickInseminate: no animal selected, early return")
        return
    end
    if g_localPlayer == nil then
        Log:trace("RLMenuInfoFrame:onClickInseminate: g_localPlayer nil, early return")
        return
    end

    Log:debug("RLMenuInfoFrame:onClickInseminate: farmId=%s uniqueId=%s typeIndex=%s opening dialog",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.animalTypeIndex))
    AnimalAIDialog.show(self.selectedHusbandry, g_localPlayer.farmId,
        animal.animalTypeIndex, animal, self.refreshAfterMutation, self)
end

---Castrate the selected animal. Delegates to RLAnimalInfoService (mutation + MP event).
function RLMenuInfoFrame:onClickCastrate()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuInfoFrame:onClickCastrate: no animal selected, early return")
        return
    end

    Log:trace("RLMenuInfoFrame:onClickCastrate: farmId=%s uniqueId=%s isCastrated=%s fertility=%.2f",
        tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(animal.isCastrated), animal.genetics and animal.genetics.fertility or -1)

    RLAnimalInfoService.castrateAnimal(animal)

    Log:debug("RLMenuInfoFrame:onClickCastrate: farmId=%s uniqueId=%s castrated via service",
        tostring(animal.farmId), tostring(animal.uniqueId))
    self:refreshAfterMutation()
end
