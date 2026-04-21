--[[
    RLMenuMoveFrame.lua
    RL Tabbed Menu - Move tab (Phase 3).

    Left-sidebar husbandry picker with dot indicators, multi-section
    SmoothList of animal cards with checkboxes for multi-select, and
    right-hand detail pane (pen column + animal column via RLDetailPaneHelper).

    Provides two move paths:
    - "Move" button: moves the currently focused animal (single)
    - "Move Selected (N)" button: moves all checked animals (bulk)

    Both paths converge at startMoveFlow(animals) -> destination dialog ->
    validation -> confirmation -> event -> refresh.
]]

RLMenuMoveFrame = {}
local RLMenuMoveFrame_mt = Class(RLMenuMoveFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuMoveFrame instance.
--- @return table self
function RLMenuMoveFrame.new()
    local self = RLMenuMoveFrame:superClass().new(nil, RLMenuMoveFrame_mt)
    self.name = "RLMenuMoveFrame"

    self.sortedHusbandries = {}
    self.selectedHusbandry = nil
    self.items             = {}
    self.filters           = {}
    self.farmId            = nil

    self.sectionOrder      = {}
    self.itemsBySection    = {}
    self.titlesBySection   = {}

    self.selectedIdentity  = nil   -- { farmId, uniqueId, country }
    self.selectedAnimals   = {}    -- keyed by RLAnimalUtil.toKey identity string

    self.isFrameOpen = false
    self.hasCustomMenuButtons = true

    self.activeAnimalTypeIndex = nil

    -- Pending move state (set between destination dialog and confirmation)
    self.pendingMoveAnimals     = nil
    self.pendingMoveDestination = nil

    -- Back button (always present, must be explicit with hasCustomMenuButtons)
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }

    -- Action bar button definitions
    self.filterButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_info_filter_button"),
        callback = function() self:onClickFilter() end,
    }
    self.moveButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_ui_moveSingle"),
        callback = function() self:onClickMove() end,
    }
    self.moveSelectedButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_ui_moveSelected"),
        callback = function() self:onClickMoveSelected() end,
    }
    self.selectButtonInfo = {
        inputAction = InputAction.RL_SELECT,
        text = g_i18n:getText("button_select"),
        callback = function() self:onClickSelect() end,
    }
    self.selectAllButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("rl_ui_selectAll"),
        callback = function() self:onClickSelectAll() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end


--- Load the move frame XML and register it with g_gui.
function RLMenuMoveFrame.setupGui()
    local frame = RLMenuMoveFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/moveFrame.xml", modDirectory),
        "RLMenuMoveFrame",
        frame,
        true
    )
    Log:debug("RLMenuMoveFrame.setupGui: registered")
end


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
function RLMenuMoveFrame:onGuiSetupFinished()
    RLMenuMoveFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuMoveFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup. Unlinks the dot template from the element tree
--- so it can be cloned at runtime. Called by RLMenu:setupMenuPages.
function RLMenuMoveFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuMoveFrame:initialize: subCategoryDotTemplate missing")
    end
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active.
function RLMenuMoveFrame:onFrameOpen()
    RLMenuMoveFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true

    -- Import shared selection from sibling frame (Info <-> Move <-> Sell)
    if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil then
        local shared = g_rlMenu.sharedSelection
        if shared.animalIdentity ~= nil then
            self.selectedIdentity = shared.animalIdentity
        end
        Log:debug("RLMenuMoveFrame:onFrameOpen: imported shared selection (husbandry=%s animal=%s/%s)",
            tostring(shared.husbandry ~= nil and shared.husbandry:getName() or "nil"),
            tostring(shared.animalIdentity and shared.animalIdentity.farmId),
            tostring(shared.animalIdentity and shared.animalIdentity.uniqueId))
    end

    -- Reset SmoothList's selection sentinels to 0 (the "no selection"
    -- sentinel value) so the chained captureCurrentSelection during
    -- refreshHusbandries -> reloadAnimalList short-circuits via its
    -- sectionOrder guard instead of overwriting the just-imported
    -- selectedIdentity. Must be 0, not nil - SmoothList expects numeric
    -- indices and crashes on nil.
    if self.animalList ~= nil then
        self.animalList.selectedSectionIndex = 0
        self.animalList.selectedIndex = 0
    end

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


--- Called by the Paging element when this tab is deactivated.
function RLMenuMoveFrame:onFrameClose()
    -- Export selection to shared state for sibling frames
    self:captureCurrentSelection()
    if g_rlMenu ~= nil then
        g_rlMenu.sharedSelection = {
            husbandry      = self.selectedHusbandry,
            animalIdentity = self.selectedIdentity,
        }
        Log:debug("RLMenuMoveFrame:onFrameClose: exported shared selection (husbandry=%s animal=%s/%s)",
            tostring(self.selectedHusbandry ~= nil and self.selectedHusbandry:getName() or "nil"),
            tostring(self.selectedIdentity and self.selectedIdentity.farmId),
            tostring(self.selectedIdentity and self.selectedIdentity.uniqueId))
    end

    RLMenuMoveFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end


-- =============================================================================
-- Husbandry selector
-- =============================================================================

--- Repopulate the husbandry selector + dot indicators for the player's farm.
function RLMenuMoveFrame:refreshHusbandries()
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    self.farmId = farmId

    self.sortedHusbandries = RLAnimalQuery.listHusbandriesForFarm(farmId)
    Log:debug("RLMenuMoveFrame:refreshHusbandries: farmId=%s husbandries=%d",
        tostring(farmId), #self.sortedHusbandries)

    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end

    if #self.sortedHusbandries == 0 then
        Log:trace("RLMenuMoveFrame:refreshHusbandries: no husbandries, showing empty state")
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(true) end
        if self.subCategoryDotBox ~= nil then self.subCategoryDotBox:setVisible(false) end
        if self.subCategorySelector ~= nil then self.subCategorySelector:setTexts({}) end
        self.selectedHusbandry = nil
        self.items = {}
        self.selectedAnimals = {}
        if self.animalList ~= nil then self.animalList:reloadData() end
        self:updateEmptyState()
        self:updateButtonVisibility()
        RLDetailPaneHelper.updateMoneyDisplay(self)
        RLDetailPaneHelper.clearDetail(self)
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
        Log:trace("RLMenuMoveFrame:refreshHusbandries: shared husbandry resolved to state=%d", initialState)
    end

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(names)
        self.subCategorySelector:setState(initialState, true)
    else
        self:onHusbandryChanged(initialState)
    end
end


--- MultiTextOption onClick callback. Clears filters + selections on animal-type change.
--- @param state number 1-based husbandry index
function RLMenuMoveFrame:onHusbandryChanged(state)
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
        Log:debug("RLMenuMoveFrame:onHusbandryChanged: animal type changed, clearing filters")
        self.filters = {}
    end
    self.activeAnimalTypeIndex = newTypeIndex

    -- Clear selections on husbandry switch (new animal set)
    self.selectedAnimals = {}

    Log:debug("RLMenuMoveFrame:onHusbandryChanged: state=%d husbandry='%s'",
        state,
        (self.selectedHusbandry ~= nil and self.selectedHusbandry.getName ~= nil
            and self.selectedHusbandry:getName()) or "?")

    self:reloadAnimalList()
    RLDetailPaneHelper.updatePenDisplay(self, self.selectedHusbandry, self.farmId)
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


--- SmoothList delegate: fired when the user picks a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuMoveFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuMoveFrame:onListSelectionChanged: section=%d index=%d", section, index)

    local key = self.sectionOrder[section]
    if key == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end
    local items = self.itemsBySection[key]
    if items == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end
    local item = items[index]
    if item == nil or item.cluster == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end

    RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, self.selectedHusbandry)
    self:updateButtonVisibility()
end


-- =============================================================================
-- Animal list
-- =============================================================================

--- Requery the current husbandry, group into sections, refresh the SmoothList,
--- restore selection by identity.
function RLMenuMoveFrame:reloadAnimalList()
    Log:trace("RLMenuMoveFrame:reloadAnimalList: begin")
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


--- Capture the currently highlighted animal's identity.
function RLMenuMoveFrame:captureCurrentSelection()
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


--- Re-highlight the previously selected animal. Falls back to (1, 1).
function RLMenuMoveFrame:restoreSelection()
    if self.animalList == nil then return end

    if #self.sectionOrder == 0 then
        self.selectedIdentity = nil
        RLDetailPaneHelper.clearAnimalDetail(self)
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

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item ~= nil and item.cluster ~= nil then
        RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, self.selectedHusbandry)
    end
end


-- =============================================================================
-- Empty state / buttons
-- =============================================================================

--- Toggle empty-state text + list chrome based on the current data.
function RLMenuMoveFrame:updateEmptyState()
    local hasHusbandries = #self.sortedHusbandries > 0
    local hasItems = #self.items > 0

    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(hasHusbandries and not hasItems)
    end
end


--- Get the currently focused animal from the list.
--- @return table|nil cluster
function RLMenuMoveFrame:getSelectedAnimal()
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


--- Count the number of checked animals.
--- @return number
function RLMenuMoveFrame:getSelectedCount()
    local count = 0
    for _, selected in pairs(self.selectedAnimals) do
        if selected then
            count = count + 1
        end
    end
    return count
end


--- Rebuild the footer button info. Back + Filter always; Move/MoveSelected/Select/SelectAll
--- conditional on state.
function RLMenuMoveFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local hasHusbandries = #self.sortedHusbandries > 0
    local hasItems = #self.items > 0
    local animal = self:getSelectedAnimal()
    local selectedCount = self:getSelectedCount()

    if hasHusbandries then
        table.insert(self.menuButtonInfo, self.filterButtonInfo)
    end

    if hasItems then
        -- Select (toggle focused animal's checkbox)
        table.insert(self.menuButtonInfo, self.selectButtonInfo)

        -- Select All / Deselect All
        self.selectAllButtonInfo.text = g_i18n:getText(
            selectedCount > 0 and "rl_ui_selectNone" or "rl_ui_selectAll")
        table.insert(self.menuButtonInfo, self.selectAllButtonInfo)
    end

    -- Move Selected (N) - disabled when 0 checked
    if hasItems then
        local moveSelText = g_i18n:getText("rl_ui_moveSelected")
        if selectedCount > 0 then
            moveSelText = moveSelText .. " (" .. selectedCount .. ")"
        end
        self.moveSelectedButtonInfo.text = moveSelText
        self.moveSelectedButtonInfo.disabled = selectedCount == 0
        table.insert(self.menuButtonInfo, self.moveSelectedButtonInfo)
    end

    -- Move (single focused animal) - disabled when no animal focused
    if hasItems then
        self.moveButtonInfo.disabled = animal == nil
        table.insert(self.menuButtonInfo, self.moveButtonInfo)
    end

    Log:debug("RLMenuMoveFrame:updateButtonVisibility: %d buttons, selectedCount=%d",
        #self.menuButtonInfo, selectedCount)
    self:setMenuButtonInfoDirty()
end


-- =============================================================================
-- Checkbox / multi-select
-- =============================================================================

--- Toggle the focused animal's checkbox.
function RLMenuMoveFrame:onClickSelect()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuMoveFrame:onClickSelect: no animal focused")
        return
    end

    local key = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId,
        animal.birthday and animal.birthday.country or "")
    self.selectedAnimals[key] = not self.selectedAnimals[key]
    Log:trace("RLMenuMoveFrame:onClickSelect: key=%s -> %s", key, tostring(self.selectedAnimals[key]))

    -- Reload to re-render checkmarks. Do NOT restoreSelection - SmoothList
    -- preserves focus across reloadData. Calling restoreSelection would
    -- reset the highlight to (1,1) via setSelectedItem.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
end


--- Toggle all animals: if any are checked, uncheck all; otherwise check all.
function RLMenuMoveFrame:onClickSelectAll()
    local hasSelection = self:getSelectedCount() > 0

    if hasSelection then
        -- Deselect all
        self.selectedAnimals = {}
        Log:debug("RLMenuMoveFrame:onClickSelectAll: deselected all")
    else
        -- Select all visible animals
        for _, key in ipairs(self.sectionOrder) do
            local items = self.itemsBySection[key]
            if items ~= nil then
                for _, item in ipairs(items) do
                    if item.cluster ~= nil then
                        local cluster = item.cluster
                        local identityKey = RLAnimalUtil.toKey(cluster.farmId, cluster.uniqueId,
                            cluster.birthday and cluster.birthday.country or "")
                        self.selectedAnimals[identityKey] = true
                    end
                end
            end
        end
        Log:debug("RLMenuMoveFrame:onClickSelectAll: selected all (%d)", self:getSelectedCount())
    end

    -- Reload to re-render checkmarks. Do NOT restoreSelection.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
end


-- =============================================================================
-- Filter
-- =============================================================================

--- Open AnimalFilterDialog for the current husbandry's animals.
function RLMenuMoveFrame:onClickFilter()
    if self.selectedHusbandry == nil then return end
    if AnimalFilterDialog == nil or AnimalFilterDialog.show == nil then
        Log:warning("RLMenuMoveFrame:onClickFilter: AnimalFilterDialog unavailable")
        return
    end

    local animalTypeIndex
    if self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        animalTypeIndex = self.selectedHusbandry:getAnimalTypeIndex()
    end

    Log:debug("RLMenuMoveFrame:onClickFilter: opening dialog for %d items", #self.items)
    AnimalFilterDialog.show(self.items, animalTypeIndex, self.onFilterApplied, self, false)
end


--- AnimalFilterDialog callback. Stores filters, clears selections (matching
--- legacy onApplyFilters at AnimalScreen.lua:2830), and re-queries.
--- @param filters table
--- @param _items table unused
function RLMenuMoveFrame:onFilterApplied(filters, _items)
    Log:debug("RLMenuMoveFrame:onFilterApplied: clearing selections + applying filters")
    self.filters = filters or {}
    self.selectedAnimals = {}
    self:reloadAnimalList()
end


-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

--- @param list table
--- @return number
function RLMenuMoveFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuMoveFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuMoveFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. Mirrors Info tab pattern + adds checkbox rendering.
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuMoveFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.animalList then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item == nil then return end

    local row = RLAnimalQuery.formatAnimalRow(item)

    -- Cell tint
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

    -- Name split
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
            -- Right-justify: icon N fills slot (slotCount - #icons + N).
            local iconIndex = i - (slotCount - #icons)
            local def = icons[iconIndex]
            if def ~= nil then
                slot:setImageSlice(GuiOverlay.STATE_NORMAL, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_SELECTED, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_HIGHLIGHTED, def.slice)
                slot:setImageColor(GuiOverlay.STATE_NORMAL, def.r, def.g, def.b)
                -- Bitmap gamma workaround: 0.015/0.017/0.015 produces #212321
                -- matching card text (preset_fs25_colorMainDark renders #0E0E0D via bitmaps).
                slot:setImageColor(GuiOverlay.STATE_SELECTED, 0.015, 0.017, 0.015)
                slot:setImageColor(GuiOverlay.STATE_HIGHLIGHTED, 0.015, 0.017, 0.015)
                slot:setVisible(true)
            else
                slot:setVisible(false)
            end
        end
    end

    -- Checkbox: show check mark + wire onClick callback for direct clicking.
    -- Mirrors legacy AnimalScreen.lua:2421 onClickCallback pattern.
    local checkbox = cell:getAttribute("checkbox")
    local check = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            local identityKey = RLAnimalUtil.toKey(row.farmId, row.uniqueId, row.country)
            check:setVisible(self.selectedAnimals[identityKey] == true)

            checkbox.onClickCallback = function()
                self.selectedAnimals[identityKey] = not self.selectedAnimals[identityKey]
                check:setVisible(self.selectedAnimals[identityKey] == true)
                self:updateButtonVisibility()
                Log:trace("RLMenuMoveFrame checkbox click: key=%s -> %s",
                    identityKey, tostring(self.selectedAnimals[identityKey]))
            end
        end
    end
end


-- =============================================================================
-- Move operations
-- =============================================================================

--- Move the currently focused (highlighted) animal.
function RLMenuMoveFrame:onClickMove()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuMoveFrame:onClickMove: no animal focused")
        return
    end

    Log:debug("RLMenuMoveFrame:onClickMove: single move for farmId=%s uniqueId=%s",
        tostring(animal.farmId), tostring(animal.uniqueId))
    self:startMoveFlow({ animal })
end


--- Move all checked animals.
function RLMenuMoveFrame:onClickMoveSelected()
    local animals = {}
    for _, key in ipairs(self.sectionOrder) do
        local items = self.itemsBySection[key]
        if items ~= nil then
            for _, item in ipairs(items) do
                if item.cluster ~= nil then
                    local cluster = item.cluster
                    local identityKey = RLAnimalUtil.toKey(cluster.farmId, cluster.uniqueId,
                        cluster.birthday and cluster.birthday.country or "")
                    if self.selectedAnimals[identityKey] then
                        table.insert(animals, cluster)
                    end
                end
            end
        end
    end

    if #animals == 0 then
        Log:trace("RLMenuMoveFrame:onClickMoveSelected: no animals checked")
        return
    end

    Log:debug("RLMenuMoveFrame:onClickMoveSelected: bulk move for %d animals", #animals)
    self:startMoveFlow(animals)
end


--- Shared move flow for single + bulk. Gets destinations, opens dialog.
--- Bulk uses first animal's subTypeIndex for destination filtering (legacy parity).
--- @param animals table Array of cluster objects to move
function RLMenuMoveFrame:startMoveFlow(animals)
    if self.selectedHusbandry == nil or #animals == 0 then return end

    -- Single-move pre-validation (legacy parity: applyMoveTarget line 215)
    -- Bulk skips client-side pre-validation (legacy: applyMoveTargetBulk line 244)
    local firstAnimal = animals[1]
    local subTypeIndex = firstAnimal.subTypeIndex
    if subTypeIndex == nil then
        Log:warning("RLMenuMoveFrame:startMoveFlow: first animal has nil subTypeIndex")
        return
    end

    local farmId = self.selectedHusbandry:getOwnerFarmId()
    local entries = RLAnimalMoveService.getValidDestinations(self.selectedHusbandry, farmId, subTypeIndex)

    if #entries == 0 then
        Log:debug("RLMenuMoveFrame:startMoveFlow: no destinations available")
        InfoDialog.show(g_i18n:getText("rl_ui_moveNoDestinations"))
        return
    end

    Log:debug("RLMenuMoveFrame:startMoveFlow: %d animals, %d destinations, subTypeIndex=%d",
        #animals, #entries, subTypeIndex)

    -- Store pending state for the destination callback
    self.pendingMoveAnimals = animals
    AnimalMoveDestinationDialog.show(self.onMoveDestinationSelected, self, entries)
end


--- Callback from AnimalMoveDestinationDialog.
--- @param entry table|nil Selected destination entry, or nil if cancelled
function RLMenuMoveFrame:onMoveDestinationSelected(entry)
    if entry == nil then
        Log:trace("RLMenuMoveFrame:onMoveDestinationSelected: cancelled")
        self.pendingMoveAnimals = nil
        return
    end

    if self.pendingMoveAnimals == nil or #self.pendingMoveAnimals == 0 then
        Log:debug("RLMenuMoveFrame:onMoveDestinationSelected: no pending animals")
        return
    end

    Log:trace("RLMenuMoveFrame:onMoveDestinationSelected: dest='%s' (%d/%d)",
        entry.name, entry.currentCount, entry.maxCount)

    -- Get animalTypeIndex from first animal for validation
    local firstAnimal = self.pendingMoveAnimals[1]
    local subType = g_currentMission.animalSystem:getSubTypeByIndex(firstAnimal.subTypeIndex)
    local animalTypeIndex = subType ~= nil and subType.typeIndex or 0

    local validationResult = RLAnimalMoveService.buildMoveValidationResult(
        self.pendingMoveAnimals, entry, animalTypeIndex)

    -- Count rejections by reason
    local ageTooYoung, ageTooOld, noCapacity = 0, 0, 0
    for _, r in ipairs(validationResult.rejected) do
        if r.reason == "AGE_TOO_YOUNG" then ageTooYoung = ageTooYoung + 1
        elseif r.reason == "AGE_TOO_OLD" then ageTooOld = ageTooOld + 1
        elseif r.reason == "NO_CAPACITY" then noCapacity = noCapacity + 1
        end
    end

    -- All rejected: show reason and abort
    if #validationResult.valid == 0 then
        local lines = { g_i18n:getText("rl_ui_moveAllRejected") }
        if ageTooYoung + ageTooOld > 0 and entry.minAge ~= nil and entry.maxAge ~= nil then
            table.insert(lines, string.format(g_i18n:getText("rl_ui_moveRejectedAge"),
                ageTooYoung + ageTooOld, entry.minAge, entry.maxAge))
        end
        if noCapacity > 0 then
            table.insert(lines, string.format(g_i18n:getText("rl_ui_moveRejectedCapacity"), noCapacity))
        end
        InfoDialog.show(table.concat(lines, "\n"))
        Log:debug("RLMenuMoveFrame:onMoveDestinationSelected: all %d rejected", #validationResult.rejected)
        self.pendingMoveAnimals = nil
        return
    end

    -- Store for confirmation callback
    self.pendingMoveDestination = entry.placeable
    self.pendingMoveAnimals = validationResult.valid

    -- Build confirmation text
    local confirmLines = {}
    table.insert(confirmLines, string.format(g_i18n:getText("rl_ui_moveValidSummary"), #validationResult.valid))

    if #validationResult.rejected > 0 then
        if ageTooYoung + ageTooOld > 0 and entry.minAge ~= nil and entry.maxAge ~= nil then
            table.insert(confirmLines, string.format(g_i18n:getText("rl_ui_moveRejectedAge"),
                ageTooYoung + ageTooOld, entry.minAge, entry.maxAge))
        end
        if noCapacity > 0 then
            table.insert(confirmLines, string.format(g_i18n:getText("rl_ui_moveRejectedCapacity"), noCapacity))
        end
    end

    local confirmText = table.concat(confirmLines, "\n")
    YesNoDialog.show(self.onMoveConfirmed, self, confirmText, g_i18n:getText("rl_ui_moveBulkConfirmTitle"))

    Log:trace("RLMenuMoveFrame:onMoveDestinationSelected: confirming %d valid, %d rejected",
        #validationResult.valid, #validationResult.rejected)
end


--- Callback from YesNoDialog confirmation.
--- @param clickYes boolean
function RLMenuMoveFrame:onMoveConfirmed(clickYes)
    Log:debug("RLMenuMoveFrame:onMoveConfirmed: clickYes=%s", tostring(clickYes))

    if not clickYes then
        self.pendingMoveAnimals = nil
        self.pendingMoveDestination = nil
        return
    end

    if self.pendingMoveAnimals == nil or self.pendingMoveDestination == nil then
        Log:debug("RLMenuMoveFrame:onMoveConfirmed: nil pending state")
        return
    end

    local animals = self.pendingMoveAnimals
    local destination = self.pendingMoveDestination

    Log:debug("RLMenuMoveFrame:onMoveConfirmed: moving %d animals to '%s'",
        #animals, tostring(destination.getName and destination:getName()))

    -- Single-move pre-validation (legacy parity)
    if #animals == 1 then
        local farmId = self.selectedHusbandry:getOwnerFarmId()
        local errorCode = RLAnimalMoveService.preValidateSingleMove(
            self.selectedHusbandry, destination, farmId, animals[1].subTypeIndex)
        if errorCode ~= nil then
            InfoDialog.show(RLAnimalMoveService.getErrorText(errorCode))
            Log:debug("RLMenuMoveFrame:onMoveConfirmed: single pre-validation failed, errorCode=%d", errorCode)
            self.pendingMoveAnimals = nil
            self.pendingMoveDestination = nil
            return
        end
    end

    RLAnimalMoveService.moveAnimals(
        self.selectedHusbandry, destination, animals, "SOURCE",
        self.onMoveComplete, self)

    -- Clear selections before dispatching: bulk clears all, single removes only the moved animal
    if #animals > 1 then
        self.selectedAnimals = {}
    else
        for _, animal in ipairs(animals) do
            local key = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId,
                animal.birthday and animal.birthday.country or "")
            self.selectedAnimals[key] = nil
        end
    end
    self.pendingMoveAnimals = nil
    self.pendingMoveDestination = nil
end


--- Callback from RLAnimalMoveService after server responds.
--- @param errorCode number
function RLMenuMoveFrame:onMoveComplete(errorCode)
    -- Stale-frame guard: if menu closed or husbandry changed mid-flight
    if self.selectedHusbandry == nil then
        Log:trace("RLMenuMoveFrame:onMoveComplete: stale frame, ignoring")
        return
    end

    if errorCode ~= AnimalMoveEvent.MOVE_SUCCESS then
        InfoDialog.show(RLAnimalMoveService.getErrorText(errorCode))
        Log:debug("RLMenuMoveFrame:onMoveComplete: move failed, errorCode=%d", errorCode)
    else
        Log:info("RLMenuMoveFrame:onMoveComplete: move succeeded")
    end

    -- Refresh list + pen column + animal column (post-move parity)
    self:reloadAnimalList()
    RLDetailPaneHelper.updatePenDisplay(self, self.selectedHusbandry, self.farmId)
end
