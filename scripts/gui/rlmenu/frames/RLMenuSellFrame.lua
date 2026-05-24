--[[
    RLMenuSellFrame.lua
    RL Tabbed Menu - Sell tab (Phase 4, shell).

    Left-sidebar husbandry picker with dot indicators, multi-section
    SmoothList of animal cards with checkboxes for multi-select, and
    right-hand detail pane (pen column + animal column via RLDetailPaneHelper).

    Phase 1 (shell): browsable frame with shared selection, canBeSold filter,
    and disabled Sell/Sell Selected placeholder buttons.
    Phase 2 adds cart display in pen column.
    Phase 3 wires actual sell logic via RLAnimalSellService.
]]

RLMenuSellFrame = {}
local RLMenuSellFrame_mt = Class(RLMenuSellFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuSellFrame instance.
--- @return table self
function RLMenuSellFrame.new()
    local self = RLMenuSellFrame:superClass().new(nil, RLMenuSellFrame_mt)
    self.name = "RLMenuSellFrame"

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

    -- Saved-filter session state.
    self.activeFilterId = nil
    self.activeFilter   = nil

    -- Back button (always present, must be explicit with hasCustomMenuButtons)
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }

    -- Action bar button definitions
    self.filterButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_info_filter_button"),
        callback = function() self:onClickFilter() end,
    }
    self.sellButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("button_sell"),
        callback = function() self:onClickSell() end,
    }
    self.sellSelectedButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_ui_sellSelected"),
        callback = function() self:onClickSellSelected() end,
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
    self.cycleFilterButtonInfo = {
        inputAction = InputAction.RL_CYCLE_FILTER,
        text = g_i18n:getText("rl_menu_cycle_filter_button"),
        callback = function() self:onCycleFilter() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end


--- Load the sell frame XML and register it with g_gui.
function RLMenuSellFrame.setupGui()
    local frame = RLMenuSellFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/sellFrame.xml", modDirectory),
        "RLMenuSellFrame",
        frame,
        true
    )
    Log:debug("RLMenuSellFrame.setupGui: registered")
end


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
function RLMenuSellFrame:onGuiSetupFinished()
    RLMenuSellFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuSellFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup. Unlinks the dot template from the element tree
--- so it can be cloned at runtime. Called by RLMenu:setupMenuPages.
function RLMenuSellFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuSellFrame:initialize: subCategoryDotTemplate missing")
    end
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active.
function RLMenuSellFrame:onFrameOpen()
    RLMenuSellFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    Log:debug("RLMenuSellFrame:onFrameOpen")

    -- Import shared selection from sibling frame (Info <-> Move <-> Sell)
    if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil then
        local shared = g_rlMenu.sharedSelection
        if shared.animalIdentity ~= nil then
            self.selectedIdentity = shared.animalIdentity
        end
        -- Saved-filter sharing across Info/Move/Sell (tab-switch
        -- preservation fix). BuyFrame is isolated and never touches this.
        if shared.activeFilterId ~= nil then
            self.activeFilterId = shared.activeFilterId
            self.activeFilter = g_rlFilterService ~= nil
                and g_rlFilterService:getById(shared.activeFilterId) or nil
            Log:debug("RLMenuSellFrame:onFrameOpen: imported shared activeFilterId=%s",
                tostring(shared.activeFilterId))
        end
        Log:debug("RLMenuSellFrame:onFrameOpen: imported shared selection (husbandry=%s animal=%s/%s)",
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

    -- Subscribe to MONEY_CHANGED so the header balance refreshes when a
    -- post-sell balance update arrives asynchronously (MP) or when any
    -- other code path credits/debits the farm while this frame is open.
    -- SP is unaffected because the change is synchronous there.
    g_messageCenter:subscribe(MessageType.MONEY_CHANGED, self.onMoneyChanged, self)

    -- Explicit focus links for keyboard navigation. Required because multiple
    -- frames share the same sidebar + SmoothList structure, and FocusManager
    -- auto-layout resolves to elements in other frames when element
    -- positions/IDs overlap.
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end

    -- Revalidate active saved filter against current scope + render chip.
    self:revalidateActiveFilter()
    self:updateFilterChip()
end


--- Called by the Paging element when this tab is deactivated.
function RLMenuSellFrame:onFrameClose()
    -- Export selection to shared state for sibling frames
    self:captureCurrentSelection()
    if g_rlMenu ~= nil then
        g_rlMenu.sharedSelection = {
            husbandry      = self.selectedHusbandry,
            animalIdentity = self.selectedIdentity,
            activeFilterId = self.activeFilterId,
        }
        Log:debug("RLMenuSellFrame:onFrameClose: exported shared selection (husbandry=%s animal=%s/%s filter=%s)",
            tostring(self.selectedHusbandry ~= nil and self.selectedHusbandry:getName() or "nil"),
            tostring(self.selectedIdentity and self.selectedIdentity.farmId),
            tostring(self.selectedIdentity and self.selectedIdentity.uniqueId),
            tostring(self.activeFilterId))
    end

    -- Quick filter is a per-frame session affordance;
    -- clear it on tab close so a sibling tab open starts clean. Log only
    -- when something was actually cleared to keep tab-switch traffic quiet.
    if next(self.filters) ~= nil then
        local count = 0
        for _ in pairs(self.filters) do count = count + 1 end
        Log:debug("RLMenuSellFrame:onFrameClose: cleared %d Quick filter condition(s)", count)
        self.filters = {}
    end

    g_messageCenter:unsubscribe(MessageType.MONEY_CHANGED, self)
    RLMenuSellFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end


--- MessageType.MONEY_CHANGED handler. Fires on both server and client
--- contexts: on clients, the message is published locally after the farm
--- balance is updated from a server stream, so subscribing lets the Sell
--- frame refresh its header balance in MP without polling. No farmId
--- gating here because updateMoneyDisplay reads the current player's farm
--- internally.
function RLMenuSellFrame:onMoneyChanged()
    if not self.isFrameOpen then return end
    Log:trace("RLMenuSellFrame:onMoneyChanged: refreshing money display")
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


-- =============================================================================
-- Husbandry selector
-- =============================================================================

--- Repopulate the husbandry selector + dot indicators for the player's farm.
function RLMenuSellFrame:refreshHusbandries()
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    self.farmId = farmId

    self.sortedHusbandries = RLAnimalQuery.listHusbandriesForFarm(farmId)
    Log:debug("RLMenuSellFrame:refreshHusbandries: farmId=%s husbandries=%d",
        tostring(farmId), #self.sortedHusbandries)

    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end

    if #self.sortedHusbandries == 0 then
        Log:trace("RLMenuSellFrame:refreshHusbandries: no husbandries, showing empty state")
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(true) end
        if self.subCategoryDotBox ~= nil then self.subCategoryDotBox:setVisible(false) end
        if self.subCategorySelector ~= nil then self.subCategorySelector:setTexts({}) end
        self.selectedHusbandry = nil
        self.items = {}
        self.selectedAnimals = {}
        -- Clear section state BEFORE reloadData so SmoothList's section-count
        -- callback does not read stale keys from a prior populated husbandry.
        -- Mirrors the fix applied to RLMenuBuyFrame:refreshTypes on 2026-04-18.
        self.sectionOrder    = {}
        self.itemsBySection  = {}
        self.titlesBySection = {}
        if self.animalList ~= nil then self.animalList:reloadData() end
        self:updateEmptyState()
        self:updateButtonVisibility()
        self:updateCartDisplay()
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
        Log:trace("RLMenuSellFrame:refreshHusbandries: shared husbandry resolved to state=%d", initialState)
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
function RLMenuSellFrame:onHusbandryChanged(state)
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
        Log:debug("RLMenuSellFrame:onHusbandryChanged: animal type changed, clearing filters")
        self.filters = {}
    end
    self.activeAnimalTypeIndex = newTypeIndex

    -- Saved-filter scope revalidation (mirrors ad-hoc clear above).
    self:revalidateActiveFilter()
    self:updateFilterChip()

    -- Clear selections on husbandry switch (new animal set)
    self.selectedAnimals = {}

    Log:debug("RLMenuSellFrame:onHusbandryChanged: state=%d husbandry='%s'",
        state,
        (self.selectedHusbandry ~= nil and self.selectedHusbandry.getName ~= nil
            and self.selectedHusbandry:getName()) or "?")

    self:reloadAnimalList()
    self:updatePenHeader()
    self:updateCartDisplay()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


--- SmoothList delegate: fired when the user picks a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuSellFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuSellFrame:onListSelectionChanged: section=%d index=%d", section, index)

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

--- Build the dialog source list for the Quick filter dialog.
--- Mirrors reloadAnimalList's universe construction MINUS the Quick filter:
--- query without Quick filter -> strip unsellable -> apply saved filter.
--- Sellability stripping is load-bearing: otherwise the slider range would
--- widen to include animals the player can never actually sell.
--- Parity with reloadAnimalList is enforceable by eye (the two are stacked).
---@return table base     full unfiltered husbandry universe
---@return table sellable base after dropping cluster:getCanBeSold()==false
---@return table narrowed sellable after saved-filter layer
function RLMenuSellFrame:buildDialogSourceList()
    if self.selectedHusbandry == nil then return {}, {}, {} end
    local base = RLAnimalQuery.listAnimalsForHusbandry(self.selectedHusbandry, nil)
    local sellable = {}
    for _, item in ipairs(base) do
        if item.cluster ~= nil and item.cluster:getCanBeSold() then
            table.insert(sellable, item)
        end
    end
    local narrowed = RLFilterCycleHelper.applyFilter(sellable, self.activeFilter)
    return base, sellable, narrowed
end


--- Requery the current husbandry, filter unsellable animals, group into
--- sections, refresh the SmoothList, restore selection by identity.
function RLMenuSellFrame:reloadAnimalList()
    Log:trace("RLMenuSellFrame:reloadAnimalList: begin")
    self:captureCurrentSelection()

    if self.selectedHusbandry == nil then
        self.items = {}
    else
        self.items = RLAnimalQuery.listAnimalsForHusbandry(self.selectedHusbandry, self.filters)
    end

    -- Filter out unsellable animals (sell frame only)
    local sellableItems = {}
    for _, item in ipairs(self.items) do
        if item.cluster ~= nil and item.cluster:getCanBeSold() then
            table.insert(sellableItems, item)
        end
    end
    local filteredCount = #self.items - #sellableItems
    if filteredCount > 0 then
        Log:debug("RLMenuSellFrame:reloadAnimalList: filtered %d unsellable animals", filteredCount)
    end
    self.items = sellableItems

    -- Saved-filter narrowing (AND with ad-hoc + sellable filter above).
    if self.activeFilter ~= nil then
        self.items = RLFilterCycleHelper.applyFilter(self.items, self.activeFilter)
    end

    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLAnimalQuery.buildSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:restoreSelection()
    self:updateEmptyState()
    self:updateButtonVisibility()
    self:updateCartDisplay()
end


--- Capture the currently highlighted animal's identity.
function RLMenuSellFrame:captureCurrentSelection()
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
function RLMenuSellFrame:restoreSelection()
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
function RLMenuSellFrame:updateEmptyState()
    local hasHusbandries = #self.sortedHusbandries > 0
    local hasItems = #self.items > 0

    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(hasHusbandries and not hasItems)
    end
end


--- Get the currently focused animal from the list.
--- @return table|nil cluster
function RLMenuSellFrame:getSelectedAnimal()
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
function RLMenuSellFrame:getSelectedCount()
    local count = 0
    for _, selected in pairs(self.selectedAnimals) do
        if selected then
            count = count + 1
        end
    end
    return count
end


--- Rebuild the footer button info. Back + Filter always; Sell/SellSelected/Select/SelectAll
--- conditional on state.
function RLMenuSellFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local hasHusbandries = #self.sortedHusbandries > 0
    local hasItems = #self.items > 0
    local animal = self:getSelectedAnimal()
    local selectedCount = self:getSelectedCount()

    if hasHusbandries then
        table.insert(self.menuButtonInfo, self.filterButtonInfo)
    end

    -- Cycle-filter button: always visible when farm is present.
    if self.farmId ~= nil and self.farmId ~= 0 then
        table.insert(self.menuButtonInfo, self.cycleFilterButtonInfo)
    end

    if hasItems then
        -- Select (toggle focused animal's checkbox)
        table.insert(self.menuButtonInfo, self.selectButtonInfo)

        -- Select All / Deselect All
        self.selectAllButtonInfo.text = g_i18n:getText(
            selectedCount > 0 and "rl_ui_selectNone" or "rl_ui_selectAll")
        table.insert(self.menuButtonInfo, self.selectAllButtonInfo)
    end

    -- Sell Selected (N) - enabled when checked animals exist
    if hasItems then
        local sellSelText = g_i18n:getText("rl_ui_sellSelected")
        if selectedCount > 0 then
            sellSelText = sellSelText .. " (" .. selectedCount .. ")"
        end
        self.sellSelectedButtonInfo.text = sellSelText
        self.sellSelectedButtonInfo.disabled = selectedCount == 0
        table.insert(self.menuButtonInfo, self.sellSelectedButtonInfo)
    end

    -- Sell (single focused animal) - enabled when an animal is focused
    if hasItems then
        self.sellButtonInfo.disabled = animal == nil
        table.insert(self.menuButtonInfo, self.sellButtonInfo)
    end

    Log:trace("RLMenuSellFrame:updateButtonVisibility: %d buttons, selectedCount=%d",
        #self.menuButtonInfo, selectedCount)
    self:setMenuButtonInfoDirty()
end


-- =============================================================================
-- Pen header + cart display
-- =============================================================================

--- Populate the pen header (name, count, icon) directly from husbandry display
--- data. Replaces RLDetailPaneHelper.updatePenDisplay for the sell frame since
--- the conditions/food XML was replaced with cart elements.
function RLMenuSellFrame:updatePenHeader()
    if self.penBox == nil then return end

    local display
    if self.selectedHusbandry ~= nil then
        display = RLAnimalInfoService.getHusbandryDisplay(self.selectedHusbandry, self.farmId)
    end

    if display == nil then
        self.penBox:setVisible(false)
        Log:trace("RLMenuSellFrame:updatePenHeader: no husbandry, pen hidden")
        return
    end

    self.penBox:setVisible(true)
    if self.penNameText ~= nil then self.penNameText:setText(display.name) end
    if self.penCountText ~= nil then self.penCountText:setText(display.countText) end
    if self.penIcon ~= nil then
        if display.penImageFilename ~= nil then
            self.penIcon:setImageFilename(display.penImageFilename)
            self.penIcon:setVisible(true)
        else
            self.penIcon:setVisible(false)
        end
    end

    Log:trace("RLMenuSellFrame:updatePenHeader: '%s' %s", display.name, display.countText)
end


--- Compute cart totals from checked animals.
--- Fee sign convention: getTranportationFee(1) returns positive; negate before summing.
--- @return number totalPrice Sum of getSellPrice() for checked animals
--- @return number totalFee Sum of getTranportationFee(1) for checked animals (positive)
--- @return number count Number of checked animals
function RLMenuSellFrame:computeCartTotals()
    local totalPrice = 0
    local totalFee = 0
    local count = 0

    for _, sectionKey in ipairs(self.sectionOrder) do
        local items = self.itemsBySection[sectionKey]
        if items ~= nil then
            for _, item in ipairs(items) do
                if item.cluster ~= nil then
                    local cluster = item.cluster
                    local identityKey = RLAnimalUtil.toKey(cluster.farmId, cluster.uniqueId,
                        cluster.birthday and cluster.birthday.country or "")
                    if self.selectedAnimals[identityKey] then
                        totalPrice = totalPrice + (cluster:getSellPrice() or 0)
                        totalFee = totalFee + (cluster:getTranportationFee(1) or 0)
                        count = count + 1
                    end
                end
            end
        end
    end

    Log:trace("RLMenuSellFrame:computeCartTotals: count=%d price=%.0f fee=%.0f total=%.0f",
        count, totalPrice, totalFee, totalPrice - totalFee)
    return totalPrice, totalFee, count
end


--- Update the cart display elements with current totals.
function RLMenuSellFrame:updateCartDisplay()
    local totalPrice, totalFee, count = self:computeCartTotals()

    if self.cartCountValue ~= nil then
        self.cartCountValue:setText(tostring(count))
    end
    if self.cartPriceValue ~= nil then
        self.cartPriceValue:setText(g_i18n:formatMoney(totalPrice, 0, true, true))
    end
    if self.cartFeeValue ~= nil then
        self.cartFeeValue:setText(g_i18n:formatMoney(-totalFee, 0, true, true))
    end
    if self.cartTotalValue ~= nil then
        self.cartTotalValue:setText(g_i18n:formatMoney(totalPrice - totalFee, 0, true, true))
    end

    if self.cartLayout ~= nil and self.cartLayout.invalidateLayout ~= nil then
        self.cartLayout:invalidateLayout()
    end

    Log:trace("RLMenuSellFrame:updateCartDisplay: %d selected, price=%s fee=%s total=%s",
        count,
        g_i18n:formatMoney(totalPrice, 0, true, true),
        g_i18n:formatMoney(-totalFee, 0, true, true),
        g_i18n:formatMoney(totalPrice - totalFee, 0, true, true))
end


-- =============================================================================
-- Checkbox / multi-select
-- =============================================================================

--- Toggle the focused animal's checkbox.
function RLMenuSellFrame:onClickSelect()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuSellFrame:onClickSelect: no animal focused")
        return
    end

    local key = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId,
        animal.birthday and animal.birthday.country or "")
    self.selectedAnimals[key] = not self.selectedAnimals[key]
    Log:trace("RLMenuSellFrame:onClickSelect: key=%s -> %s", key, tostring(self.selectedAnimals[key]))

    -- Reload to re-render checkmarks. Do NOT restoreSelection - SmoothList
    -- preserves focus across reloadData. Calling restoreSelection would
    -- reset the highlight to (1,1) via setSelectedItem.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
    self:updateCartDisplay()
end


--- Toggle all animals: if any are checked, uncheck all; otherwise check all.
function RLMenuSellFrame:onClickSelectAll()
    local hasSelection = self:getSelectedCount() > 0

    if hasSelection then
        -- Deselect all
        self.selectedAnimals = {}
        Log:debug("RLMenuSellFrame:onClickSelectAll: deselected all")
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
        Log:debug("RLMenuSellFrame:onClickSelectAll: selected all (%d)", self:getSelectedCount())
    end

    -- Reload to re-render checkmarks. Do NOT restoreSelection.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
    self:updateCartDisplay()
end


-- =============================================================================
-- Filter
-- =============================================================================

--- Open AnimalFilterDialog for the current husbandry's animals.
--- Source list is built from the render universe MINUS the Quick filter so
--- slider ranges always reflect the full pen (sellability-stripped, then
--- saved-filter-narrowed), never the already-Quick-filtered subset.
function RLMenuSellFrame:onClickFilter()
    if self.selectedHusbandry == nil then return end
    if AnimalFilterDialog == nil or AnimalFilterDialog.show == nil then
        Log:warning("RLMenuSellFrame:onClickFilter: AnimalFilterDialog unavailable")
        return
    end

    local animalTypeIndex
    if self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        animalTypeIndex = self.selectedHusbandry:getAnimalTypeIndex()
    end

    local base, sellable, narrowed = self:buildDialogSourceList()
    Log:debug("RLMenuSellFrame:onClickFilter: opening dialog (savedFilterId=%s, base=%d, sellable=%d, narrowed=%d, animalTypeIndex=%s)",
        tostring(self.activeFilterId), #base, #sellable, #narrowed, tostring(animalTypeIndex))

    AnimalFilterDialog.show(narrowed, animalTypeIndex, self.onFilterApplied, self, false)
end


--- AnimalFilterDialog callback. Stores filters, clears selections, and re-queries.
--- @param filters table
--- @param _items table unused
function RLMenuSellFrame:onFilterApplied(filters, _items)
    Log:debug("RLMenuSellFrame:onFilterApplied: clearing selections + applying filters")
    self.filters = filters or {}
    self.selectedAnimals = {}
    self:updateFilterChip()
    self:reloadAnimalList()
end


-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

--- @param list table
--- @return number
function RLMenuSellFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuSellFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuSellFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. Mirrors Move tab pattern + checkbox rendering.
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuSellFrame:populateCellForItemInSection(list, section, index, cell)
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
                self:updateCartDisplay()
                Log:trace("RLMenuSellFrame checkbox click: key=%s -> %s",
                    identityKey, tostring(self.selectedAnimals[identityKey]))
            end
        end
    end
end


-- =============================================================================
-- Sell operations
-- =============================================================================

--- Sell the currently focused (highlighted) animal.
function RLMenuSellFrame:onClickSell()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuSellFrame:onClickSell: no animal focused")
        return
    end

    local price, fee, _ = RLAnimalSellService.computeSellPrice(animal)
    local confirmText = RLAnimalSellService.buildSingleConfirmationText(animal, price, fee)

    Log:debug("RLMenuSellFrame:onClickSell: single sell for farmId=%s uniqueId=%s price=%.0f fee=%.0f",
        tostring(animal.farmId), tostring(animal.uniqueId), price, fee)

    -- Store pending state for confirmation callback
    self.pendingSellAnimals = { animal }
    self.pendingSellPrice = price
    self.pendingSellFee = fee

    YesNoDialog.show(self.onSellConfirmed, self, confirmText, g_i18n:getText("ui_attention"))
end


--- Sell all checked animals.
function RLMenuSellFrame:onClickSellSelected()
    local animals = {}
    for _, sectionKey in ipairs(self.sectionOrder) do
        local items = self.itemsBySection[sectionKey]
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
        Log:trace("RLMenuSellFrame:onClickSellSelected: no animals checked")
        return
    end

    local totalPrice, totalFee, _, count = RLAnimalSellService.computeBulkTotal(animals)
    local confirmText = RLAnimalSellService.buildBulkConfirmationText(count, totalPrice, totalFee)

    Log:debug("RLMenuSellFrame:onClickSellSelected: bulk sell %d animals, price=%.0f fee=%.0f",
        count, totalPrice, totalFee)

    -- Store pending state for confirmation callback
    self.pendingSellAnimals = animals
    self.pendingSellPrice = totalPrice
    self.pendingSellFee = totalFee

    YesNoDialog.show(self.onSellConfirmed, self, confirmText, g_i18n:getText("ui_attention"))
end


--- Callback from YesNoDialog confirmation.
--- @param clickYes boolean
function RLMenuSellFrame:onSellConfirmed(clickYes)
    Log:debug("RLMenuSellFrame:onSellConfirmed: clickYes=%s", tostring(clickYes))

    if not clickYes then
        self.pendingSellAnimals = nil
        self.pendingSellPrice = nil
        self.pendingSellFee = nil
        return
    end

    if self.pendingSellAnimals == nil or self.selectedHusbandry == nil then
        Log:debug("RLMenuSellFrame:onSellConfirmed: nil pending state")
        return
    end

    local animals = self.pendingSellAnimals
    local price = self.pendingSellPrice
    local fee = self.pendingSellFee

    -- Clear selections BEFORE dispatching: bulk clears all, single removes only the sold animal
    if #animals > 1 then
        self.selectedAnimals = {}
    else
        for _, animal in ipairs(animals) do
            local key = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId,
                animal.birthday and animal.birthday.country or "")
            self.selectedAnimals[key] = nil
        end
    end
    self.pendingSellAnimals = nil
    self.pendingSellPrice = nil
    self.pendingSellFee = nil

    RLAnimalSellService.sellAnimals(
        self.selectedHusbandry, animals, price, fee,
        self.onSellComplete, self)
end


--- Callback from RLAnimalSellService after server responds.
--- Stale-frame guard: skips refresh if the frame has closed (tab-switch /
--- menu-close mid-dispatch) OR if the husbandry context was cleared.
--- `isFrameOpen` is cleared in onFrameClose; `selectedHusbandry` guards
--- against a husbandry-less state (e.g., farm has no husbandries).
--- @param errorCode number
function RLMenuSellFrame:onSellComplete(errorCode)
    if not self.isFrameOpen or self.selectedHusbandry == nil then
        Log:trace("RLMenuSellFrame:onSellComplete: stale frame (isFrameOpen=%s husbandry=%s), ignoring",
            tostring(self.isFrameOpen), tostring(self.selectedHusbandry ~= nil))
        return
    end

    if errorCode ~= AnimalSellEvent.SELL_SUCCESS then
        InfoDialog.show(RLAnimalSellService.getErrorText(errorCode))
        Log:debug("RLMenuSellFrame:onSellComplete: sell failed, errorCode=%d", errorCode)
    else
        Log:info("RLMenuSellFrame:onSellComplete: sell succeeded")
    end

    -- Refresh list + cart + pen header + money display (post-sell)
    self:reloadAnimalList()
    self:updatePenHeader()
    self:updateCartDisplay()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end

-- =============================================================================
-- Saved-filter cycle + chip
-- =============================================================================

function RLMenuSellFrame:onCycleFilter()
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSellFrame:onCycleFilter: no farm, aborting")
        return
    end

    local animalTypeIndex = nil
    if self.selectedHusbandry ~= nil and self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        animalTypeIndex = self.selectedHusbandry:getAnimalTypeIndex()
    end

    local filters = RLFilterCycleHelper.getAvailableFilters(animalTypeIndex, self.farmId, RLFilterCycleHelper.USAGE.OWNED)
    if #filters == 0 then
        if self.activeFilterId ~= nil then
            self.activeFilterId = nil
            self.activeFilter = nil
        end
        Log:trace("RLMenuSellFrame:onCycleFilter: no filters available, chip reset")
        self:updateFilterChip()
        self:reloadAnimalList()
        return
    end

    local nextId = RLFilterCycleHelper.cycleFilterId(self.activeFilterId, filters)
    local prevId = self.activeFilterId
    self.activeFilterId = nextId
    self.activeFilter = (nextId ~= nil and g_rlFilterService ~= nil
        and g_rlFilterService:getById(nextId)) or nil

    Log:debug("RLMenuSellFrame:onCycleFilter: from=%s to=%s (count=%d)",
        tostring(prevId), tostring(nextId), #filters)

    self:updateFilterChip()
    self:reloadAnimalList()
end

--- Render the filterChip Text element to reflect the combined Quick filter
--- + saved filter state. Delegates branch resolution to the
--- shared RLFilterChipHelper so all four RL Menu frames render consistently.
--- No-op + WARNING if the XML element is missing.
function RLMenuSellFrame:updateFilterChip()
    local chip = self.filterChip
    if chip == nil then
        Log:warning("RLMenuSellFrame:updateFilterChip: filterChip element missing from XML")
        return
    end

    local s = RLFilterChipHelper.composeChipState(self.filters, self.activeFilter)
    chip:setVisible(s.visible)
    if s.visible then
        if s.savedName ~= nil then
            chip:setText(string.format(g_i18n:getText(s.textKey), s.savedName))
        else
            chip:setText(g_i18n:getText(s.textKey))
        end
    end

    local branch
    if not s.visible then
        branch = "hidden"
    elseif s.textKey == "rl_menu_filter_chip_quick" then
        branch = "quick-only"
    elseif s.textKey == "rl_menu_filter_chip_active" then
        branch = "saved-only"
    else
        branch = "quick+saved"
    end
    Log:trace("RLMenuSellFrame:updateFilterChip: branch=%s saved=%s",
        branch, tostring(s.savedName))

    if chip.absPosition ~= nil and chip.size ~= nil then
        Log:debug("RLMenuSellFrame:updateFilterChip: absPos=(%.0f,%.0f)px size=(%.0f,%.0f)px",
            chip.absPosition[1] * 1920, chip.absPosition[2] * 1080,
            (chip.size[1] or 0) * 1920, (chip.size[2] or 0) * 1080)
    end
end

function RLMenuSellFrame:revalidateActiveFilter()
    if self.activeFilterId == nil then return end

    if self.farmId == nil or self.farmId == 0 then
        self.activeFilterId = nil
        self.activeFilter = nil
        Log:debug("RLMenuSellFrame:revalidateActiveFilter: no farm, cleared")
        return
    end

    local animalTypeIndex = nil
    if self.selectedHusbandry ~= nil and self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        animalTypeIndex = self.selectedHusbandry:getAnimalTypeIndex()
    end

    local available = RLFilterCycleHelper.getAvailableFilters(animalTypeIndex, self.farmId, RLFilterCycleHelper.USAGE.OWNED)
    local stillInScope = false
    for _, f in ipairs(available) do
        if f.id == self.activeFilterId then
            stillInScope = true
            break
        end
    end

    if not stillInScope then
        Log:debug("RLMenuSellFrame:revalidateActiveFilter: id=%s out of scope, cleared",
            tostring(self.activeFilterId))
        self.activeFilterId = nil
        self.activeFilter = nil
    else
        if g_rlFilterService ~= nil then
            self.activeFilter = g_rlFilterService:getById(self.activeFilterId)
        end
        Log:trace("RLMenuSellFrame:revalidateActiveFilter: id=%s still in scope, snapshot refreshed",
            tostring(self.activeFilterId))
    end
end

--- Remote-change fanout hook fired from RLFilter{Create,Update,Delete}Event:run
--- when a peer mutates a saved filter. Id-match gate short-circuits when the
--- changed filter is not this frame's active filter, preserving user selection
--- and detail-pane state. Otherwise re-runs revalidateActiveFilter +
--- updateFilterChip + reloadAnimalList so the displayed list reflects the
--- new active-filter state. Clears g_rlMenu.sharedSelection.activeFilterId
--- when revalidate cleared the active filter (Sell participates in shared
--- selection alongside Info + Move; Buy is isolated).
---@param filterId string  -- id of the filter that was created/updated/deleted on the network
---@param changeType string  -- "create" | "update" | "delete"
function RLMenuSellFrame:onRemoteFilterChange(filterId, changeType)
    Log:trace("RLMenuSellFrame:onRemoteFilterChange: id=%s change=%s activeId=%s isFrameOpen=%s",
        tostring(filterId), tostring(changeType), tostring(self.activeFilterId), tostring(self.isFrameOpen))

    if self.isFrameOpen ~= true then
        Log:trace("RLMenuSellFrame:onRemoteFilterChange: frame not open, deferring to onFrameOpen")
        return
    end

    if filterId ~= self.activeFilterId then
        Log:trace("RLMenuSellFrame:onRemoteFilterChange: no-op (non-active change)")
        return
    end

    self:revalidateActiveFilter()
    self:updateFilterChip()
    self:reloadAnimalList()

    if self.activeFilter == nil then
        if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil then
            g_rlMenu.sharedSelection.activeFilterId = nil
            Log:trace("RLMenuSellFrame:onRemoteFilterChange: sharedSelection.activeFilterId cleared")
        end
        Log:debug("RLMenuSellFrame:onRemoteFilterChange: active filter cleared (delete or scope-narrow)")
    else
        Log:debug("RLMenuSellFrame:onRemoteFilterChange: active filter snapshot refreshed")
    end
end
