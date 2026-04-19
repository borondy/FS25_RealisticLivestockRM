--[[
    RLMenuAIFrame.lua
    RL Tabbed Menu - AI (Artificial Insemination) tab.

    Top-of-column species cycler with dot indicators (cow / pig / sheep & goats /
    horse / chicken), multi-section SmoothList of AI-stock bull cards with the
    overall-quality label in the "price" slot (legacy parity at
    AnimalScreen.lua:2200-2217 - NOT money), middle column `aiPurchasePanel`
    with Average Success + Quantity + stepper + total price, and a right-hand
    detail pane reusing RLDetailPaneHelper (bulls have no husbandry).

    Phase 1 shell: browsable read-only frame with disabled/no-op Favourite +
    Buy footer buttons. Phase 2 wires:
      - quantity stepper state-change -> recompute total price
      - Favourite toggle (local, no network event; RLRM-172 tracks MP bug)
      - Buy action (SemenBuyEvent dispatch + PlacementUtil spawn + InfoDialog)

    The stepper's state CYCLES on click in Phase 1 (default widget behavior
    since no callback is bound), but the displayed price does NOT update -
    Phase 2 binds the callback and recomputes on every state change.

    Selection is isolated: no read/write of g_rlMenu.sharedSelection (AI bulls
    are not farm-owned).
]]

RLMenuAIFrame = {}
local RLMenuAIFrame_mt = Class(RLMenuAIFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuAIFrame instance.
--- @return table self
function RLMenuAIFrame.new()
    local self = RLMenuAIFrame:superClass().new(nil, RLMenuAIFrame_mt)
    self.name = "RLMenuAIFrame"

    self.sortedSpecies        = {}    -- array of animal type entries from animalSystem:getTypes
    self.items                = {}    -- wrapped AI bulls for the active species
    self.farmId               = nil   -- set per-onFrameOpen via refreshSpecies; consumed by RLDetailPaneHelper.updateMoneyDisplay

    self.sectionOrder         = {}
    self.itemsBySection       = {}
    self.titlesBySection      = {}

    self.selectedIdentity     = nil   -- { farmId, uniqueId, country } for focused bull
    self.isFrameOpen          = false
    self.hasCustomMenuButtons = true

    self.activeSpeciesTypeIndex = nil

    -- Back button (always present, required with hasCustomMenuButtons)
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }

    -- Action bar button definitions.
    -- Phase 1: no-op TRACE stub callbacks. Buttons are enabled when a bull
    -- is focused (mirrors legacy at AnimalScreen.lua:630-641 which gates
    -- purely on selection state). Phase 2 replaces these callbacks with
    -- real toggleFavourite + onClickBuy handlers.
    self.favouriteButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_ui_favourite"),
        callback = function() self:onClickFavourite() end,
    }
    self.buyButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = g_i18n:getText("button_buy"),
        callback = function() self:onClickBuy() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end


--- Load the AI frame XML and register it with g_gui.
function RLMenuAIFrame.setupGui()
    local frame = RLMenuAIFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/aiFrame.xml", modDirectory),
        "RLMenuAIFrame",
        frame,
        true
    )
    Log:debug("RLMenuAIFrame.setupGui: registered")
end


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
function RLMenuAIFrame:onGuiSetupFinished()
    RLMenuAIFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuAIFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup. Unlinks the dot template from the element tree
--- so it can be cloned at runtime, hides pen-info elements (inherited from
--- buyFrame.xml for XML-parity but AI has no pen concept), populates the
--- quantity stepper labels (legacy pattern at AnimalScreen.lua:325-329), and
--- hides the aiPurchasePanel until a bull is selected.
---
--- Called by RLMenu:setupMenuPages.
function RLMenuAIFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuAIFrame:initialize: subCategoryDotTemplate missing")
    end

    -- Hide inherited pen-info row (AI has no pen concept)
    if self.penInformationHeader ~= nil then self.penInformationHeader:setVisible(false) end
    if self.penNameText         ~= nil then self.penNameText:setVisible(false) end
    if self.penCountText        ~= nil then self.penCountText:setVisible(false) end
    if self.penIcon             ~= nil then self.penIcon:setVisible(false) end

    -- Populate quantity stepper labels from DEWAR_QUANTITIES. Copy of legacy
    -- at AnimalScreen.lua:325-329. State resets to 1 here so a fresh frame
    -- open shows "1 Straw" regardless of the last value left in the element.
    if self.aiQuantitySelector ~= nil
        and AnimalScreen ~= nil
        and AnimalScreen.DEWAR_QUANTITIES ~= nil then
        local texts = {}
        for _, quantity in pairs(AnimalScreen.DEWAR_QUANTITIES) do
            table.insert(texts, string.format("%s %s",
                quantity,
                g_i18n:getText("rl_ui_straw" .. (quantity == 1 and "Single" or "Multiple"))))
        end
        self.aiQuantitySelector:setTexts(texts)
        self.aiQuantitySelector:setState(1)
    else
        Log:warning("RLMenuAIFrame:initialize: aiQuantitySelector or DEWAR_QUANTITIES unavailable")
    end

    -- Middle column hidden until a bull is selected (mirrors legacy
    -- aiInfoContainer at AnimalScreen.lua:629).
    if self.aiPurchasePanel ~= nil then
        self.aiPurchasePanel:setVisible(false)
    end

    Log:debug("RLMenuAIFrame:initialize: template unlinked, pen-info hidden, quantity stepper seeded, aiPurchasePanel hidden")
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active.
--- Isolated selection - does NOT import or export g_rlMenu.sharedSelection.
function RLMenuAIFrame:onFrameOpen()
    RLMenuAIFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    Log:debug("RLMenuAIFrame:onFrameOpen")

    self:refreshSpecies()

    -- Subscribe to MONEY_CHANGED so the header balance refreshes when an
    -- MP balance update arrives asynchronously. Matches the pattern Buy/Sell/
    -- Info use (RLRM-170 context).
    g_messageCenter:subscribe(MessageType.MONEY_CHANGED, self.onMoneyChanged, self)

    -- Explicit focus links. Without these, FocusManager auto-layout can
    -- trap focus in other frames' cloned elements (multiple frames share
    -- the same sidebar + SmoothList structure).
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end
end


--- Called by the Paging element when this tab is deactivated.
function RLMenuAIFrame:onFrameClose()
    Log:debug("RLMenuAIFrame:onFrameClose")
    g_messageCenter:unsubscribe(MessageType.MONEY_CHANGED, self)
    RLMenuAIFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end


--- MessageType.MONEY_CHANGED handler. Fires on both server and client
--- contexts; subscribing lets the AI frame refresh its header balance in MP
--- without polling. Delegates to RLDetailPaneHelper for the actual update.
function RLMenuAIFrame:onMoneyChanged()
    if not self.isFrameOpen then return end
    Log:trace("RLMenuAIFrame:onMoneyChanged: refreshing money display")
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


-- =============================================================================
-- Species cycler
-- =============================================================================

--- Repopulate the species cycler + dot indicators from RLAIStockService.
--- Shows every registered species, not only species with stock (species with
--- zero stock render the empty-animals text).
function RLMenuAIFrame:refreshSpecies()
    -- Cache the current farm id so RLDetailPaneHelper.updateMoneyDisplay
    -- can resolve the balance via frame.farmId. Mirrors Buy frame's
    -- pattern at RLMenuBuyFrame.lua:202-203 (refreshTypes). Without this,
    -- the helper sees nil farmId -> nil balance -> hides the moneyBox entirely.
    self.farmId = RLAnimalInfoService.getCurrentFarmId()

    self.sortedSpecies = RLAIStockService.listSpecies()
    Log:debug("RLMenuAIFrame:refreshSpecies: farmId=%s species=%d",
        tostring(self.farmId), #self.sortedSpecies)

    -- Clean out any previously-cloned dots (onFrameOpen may be called multiple
    -- times in a session; without cleanup dots accumulate).
    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end

    if #self.sortedSpecies == 0 then
        Log:trace("RLMenuAIFrame:refreshSpecies: no species, showing empty state")
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(true) end
        if self.subCategoryDotBox ~= nil then self.subCategoryDotBox:setVisible(false) end
        if self.subCategorySelector ~= nil then self.subCategorySelector:setTexts({}) end
        self.activeSpeciesTypeIndex = nil
        self.items = {}
        self.sectionOrder    = {}
        self.itemsBySection  = {}
        self.titlesBySection = {}
        if self.animalList ~= nil then self.animalList:reloadData() end
        self:updateEmptyState()
        self:updateButtonVisibility()
        RLDetailPaneHelper.updateMoneyDisplay(self)
        RLDetailPaneHelper.clearAnimalDetail(self)
        if self.aiPurchasePanel ~= nil then self.aiPurchasePanel:setVisible(false) end
        return
    end

    if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(false) end

    local names = {}
    for index, animalType in ipairs(self.sortedSpecies) do
        names[index] = RLMenuAIFrame._formatSpeciesLabel(animalType)

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

    -- Always start on species 1. No shared-selection import.
    local initialState = 1

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(names)
        self.subCategorySelector:setState(initialState, true)
    else
        self:onSpeciesChanged(initialState)
    end
end


--- Format an animal species for the cycler label. Legacy uses
--- animalType.groupTitle (AnimalScreen.lua:512) - prefer that first; fall
--- back to a derived i18n key; finally the internal name.
--- @param animalType table
--- @return string
function RLMenuAIFrame._formatSpeciesLabel(animalType)
    if animalType == nil then return "?" end
    if animalType.groupTitle ~= nil and animalType.groupTitle ~= "" then
        return animalType.groupTitle
    end
    if animalType.name ~= nil and g_i18n ~= nil then
        local key = "ui_" .. string.lower(animalType.name) .. "s"
        if g_i18n:hasText(key) then
            return g_i18n:getText(key)
        end
        return animalType.name
    end
    return "?"
end


--- MultiTextOption onClick callback. Fires on species change.
--- @param state number 1-based species index
function RLMenuAIFrame:onSpeciesChanged(state)
    if state == nil or state < 1 or state > #self.sortedSpecies then return end

    local animalType = self.sortedSpecies[state]
    local newTypeIndex = animalType and animalType.typeIndex or nil
    self.activeSpeciesTypeIndex = newTypeIndex

    Log:debug("RLMenuAIFrame:onSpeciesChanged: state=%d typeIndex=%s", state, tostring(newTypeIndex))

    self:reloadBullList()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


--- SmoothList delegate: fired when the user picks a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuAIFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuAIFrame:onListSelectionChanged: section=%d index=%d", section, index)
    self:onBullSelectionChanged()
end


-- =============================================================================
-- Bull list
-- =============================================================================

--- Requery AI stock for the active species, group into sections, refresh
--- the SmoothList, restore selection by identity.
function RLMenuAIFrame:reloadBullList()
    Log:trace("RLMenuAIFrame:reloadBullList: begin")
    self:captureCurrentSelection()

    if self.activeSpeciesTypeIndex == nil then
        self.items = {}
    else
        self.items = RLAIStockService.listBullsForSpecies(self.activeSpeciesTypeIndex)
    end

    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLAIStockService.buildSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:restoreSelection()
    self:updateEmptyState()
    self:updateButtonVisibility()
end


--- Capture the currently highlighted bull's identity.
function RLMenuAIFrame:captureCurrentSelection()
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


--- Re-highlight the previously selected bull. Falls back to (1, 1).
function RLMenuAIFrame:restoreSelection()
    if self.animalList == nil then return end

    if #self.sectionOrder == 0 then
        self.selectedIdentity = nil
        RLDetailPaneHelper.clearAnimalDetail(self)
        if self.aiPurchasePanel ~= nil then self.aiPurchasePanel:setVisible(false) end
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
    -- setSelectedItem does not always fire onListSelectionChanged, so
    -- force the middle-column + detail-pane refresh explicitly.
    self:onBullSelectionChanged()
end


-- =============================================================================
-- Bull selection change: updates detail pane + middle column + Favourite label
-- =============================================================================

--- Refresh dependent UI for the currently-focused bull. Central entry point
--- called from onListSelectionChanged, restoreSelection, refreshSpecies.
---
--- Phase 1: updates detail pane, middle column (Average Success + price for
--- 1 straw), Favourite button label, button visibility. Phase 2 adds: reset
--- stepper to position 1, recompute price on quantity change, selection-
--- identity dedupe.
function RLMenuAIFrame:onBullSelectionChanged()
    local animal = self:getSelectedAnimal()

    if animal == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        if self.aiPurchasePanel ~= nil then self.aiPurchasePanel:setVisible(false) end
        self:updateButtonVisibility()
        Log:trace("RLMenuAIFrame:onBullSelectionChanged: no animal focused")
        return
    end

    Log:trace("RLMenuAIFrame:onBullSelectionChanged: farmId=%s uniqueId=%s country=%s",
        tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(animal.birthday and animal.birthday.country))

    -- AI bulls have no source husbandry; the helper tolerates nil.
    RLDetailPaneHelper.updateAnimalDisplay(self, animal, nil)

    -- Middle column
    self:updateMiddleColumn(animal)

    -- Favourite button label (read-only in Phase 1 - mirrors legacy at
    -- AnimalScreen.lua:645).
    self:refreshFavouriteButtonLabel(animal)

    self:updateButtonVisibility()
end


--- Populate the middle-column elements for the given bull. Phase 1 uses
--- quantity = 1 for the price display; Phase 2 calls this on stepper change
--- with the current DEWAR_QUANTITIES value.
--- @param animal table Raw Animal
function RLMenuAIFrame:updateMiddleColumn(animal)
    if animal == nil then return end

    if self.aiPurchasePanel ~= nil then
        self.aiPurchasePanel:setVisible(true)
    end

    -- Reset stepper to position 1 on every bull-selection change. Legacy
    -- parity at AnimalScreen.lua:688-689. `setState(state)` called without
    -- the second `forceEvent` arg silently updates state, so the TRACE
    -- onClick stub does NOT fire on the reset. Prevents a previously
    -- selected "750 STRAWS" leaking across bull / species changes.
    if self.aiQuantitySelector ~= nil and self.aiQuantitySelector.setState ~= nil then
        self.aiQuantitySelector:setState(1)
    end

    -- Average Success: legacy pattern at AnimalScreen.lua:649.
    -- math.round (not %d) matches DewarData.lua:401 and AnimalAIDialog.lua:154.
    if self.averageSuccessValue ~= nil then
        local successPct = math.round((animal.success or 0) * 100)
        self.averageSuccessValue:setText(string.format("%s%%", tostring(successPct)))
    end

    -- Total price: Phase 1 locks to quantity 1. Phase 2 reads the stepper
    -- state and recomputes on every click.
    if self.aiQuantityPrice ~= nil then
        local price = RLAIStockService.getPriceForQuantity(animal, 1)
        self.aiQuantityPrice:setText(g_i18n:formatMoney(price, 2, true, true))
    end
end


--- Set the Favourite button label from the bull's current favourite state.
--- Read-only in Phase 1 (legacy parity at AnimalScreen.lua:645 - the
--- selection-change site reads a local `uniqueUserId` that IS in scope;
--- the toggle site's buggy global read is separately addressed in Phase 2).
--- @param animal table Raw Animal
function RLMenuAIFrame:refreshFavouriteButtonLabel(animal)
    if animal == nil or self.favouriteButtonInfo == nil then return end

    local uniqueUserId = g_localPlayer ~= nil and g_localPlayer:getUniqueId() or nil
    local isFavourite = false
    if uniqueUserId ~= nil
        and type(animal.favouritedBy) == "table"
        and animal.favouritedBy[uniqueUserId] == true then
        isFavourite = true
    end

    self.favouriteButtonInfo.text = g_i18n:getText(isFavourite and "rl_ui_unFavourite" or "rl_ui_favourite")
    Log:trace("RLMenuAIFrame:refreshFavouriteButtonLabel: isFavourite=%s", tostring(isFavourite))
end


-- =============================================================================
-- Empty state / buttons
-- =============================================================================

--- Toggle empty-state text based on the current data.
function RLMenuAIFrame:updateEmptyState()
    local hasSpecies = #self.sortedSpecies > 0
    local hasItems = #self.items > 0

    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(hasSpecies and not hasItems)
    end
end


--- Get the currently focused bull from the list.
--- @return table|nil cluster
function RLMenuAIFrame:getSelectedAnimal()
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


--- Rebuild the footer button info. Back always; Favourite + Buy ALWAYS
--- present in the footer, toggled between enabled (bull focused) and
--- disabled (no bull focused / empty species). The `disabled = true` state
--- renders the button greyed-out with the callback suppressed - matching
--- the shell-spec I/O matrix wording ("Button disabled; click consumed...")
--- and legacy `AnimalScreen.lua:630-631, 640-641` semantics (setDisabled
--- toggles state rather than removing the element).
--- Phase 1: both wired to no-op TRACE stub callbacks.
--- Phase 2 adds client-side tradeAnimals-permission disable for Buy
--- (intentional UX divergence from legacy's click-time permission check).
function RLMenuAIFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local focusedAnimal = self:getSelectedAnimal()
    local hasBull = focusedAnimal ~= nil

    self.favouriteButtonInfo.disabled = not hasBull
    self.buyButtonInfo.disabled = not hasBull
    table.insert(self.menuButtonInfo, self.favouriteButtonInfo)
    table.insert(self.menuButtonInfo, self.buyButtonInfo)

    Log:trace("RLMenuAIFrame:updateButtonVisibility: %d buttons, focused=%s, disabled=%s",
        #self.menuButtonInfo, tostring(hasBull), tostring(not hasBull))
    self:setMenuButtonInfoDirty()
end


-- =============================================================================
-- Quantity stepper: Phase 1 TRACE-only handler (no price recompute)
-- =============================================================================

--- MultiTextOption onClick callback for aiQuantitySelector. Phase 1 logs
--- the state change but does NOT recompute the displayed price - Phase 2
--- replaces this handler to call RLAIStockService.getPriceForQuantity and
--- update aiQuantityPrice on every state change. Logging the state in Phase 1
--- gives the test walkthrough an observable signal that the stepper cycles.
--- @param state number 1-based DEWAR_QUANTITIES index
function RLMenuAIFrame:onQuantityStateChanged(state)
    local quantity = nil
    if AnimalScreen ~= nil and AnimalScreen.DEWAR_QUANTITIES ~= nil and state ~= nil then
        quantity = AnimalScreen.DEWAR_QUANTITIES[state]
    end
    Log:trace("RLMenuAIFrame:onQuantityStateChanged: state=%s quantity=%s (Phase 1 TRACE-only; price NOT recomputed)",
        tostring(state), tostring(quantity))
end


-- =============================================================================
-- Phase 1 placeholder footer callbacks (TRACE stubs, no side effects)
-- =============================================================================

--- Favourite button callback (Phase 1 stub). Phase 2 replaces with
--- toggleFavourite + reloadData + button-label refresh.
function RLMenuAIFrame:onClickFavourite()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onClickFavourite: no animal focused (Phase 1 stub)")
        return
    end
    Log:trace("RLMenuAIFrame:onClickFavourite: Phase 1 no-op stub (farmId=%s uniqueId=%s)",
        tostring(animal.farmId), tostring(animal.uniqueId))
end


--- Buy button callback (Phase 1 stub). Phase 2 replaces with spawn-slot
--- lookup + SemenBuyEvent dispatch + InfoDialog.
function RLMenuAIFrame:onClickBuy()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onClickBuy: no animal focused (Phase 1 stub)")
        return
    end
    Log:trace("RLMenuAIFrame:onClickBuy: Phase 1 no-op stub (farmId=%s uniqueId=%s)",
        tostring(animal.farmId), tostring(animal.uniqueId))
end


-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

--- @param list table
--- @return number
function RLMenuAIFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuAIFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuAIFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. Differs from Buy/Sell's populate in two ways:
---   1. The "price" cell text is the overall-quality label (legacy parity
---      at AnimalScreen.lua:2200-2217), NOT a money amount.
---   2. Favourited bulls tint the cell background orange (1, 0.2, 0);
---      mirrors legacy at AnimalScreen.lua:2224-2238.
--- No checkbox column (single-bull selection only in the AI tab).
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuAIFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.animalList then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item == nil then return end

    local cluster = item.cluster
    if cluster == nil then return end

    -- Row fields mirror the general Animal row format; reuse the shared
    -- formatter for id / name / icon so layout matches Buy/Sell/Info rows.
    local row = RLAnimalQuery.formatAnimalRow(item)

    -- Cell tint. Favourite (orange) takes priority over the default.
    -- AI bulls are never diseased or marked in normal play, but we respect
    -- those tints defensively.
    local uniqueUserId = g_localPlayer ~= nil and g_localPlayer:getUniqueId() or nil
    local isFavourite = uniqueUserId ~= nil
        and type(cluster.favouritedBy) == "table"
        and cluster.favouritedBy[uniqueUserId] == true

    local tintBranch
    if cell.setImageColor ~= nil then
        if isFavourite then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.2, 0)
            tintBranch = "favourite"
        elseif row.tint == RLAnimalQuery.TINT_DISEASE then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.08, 0)
            tintBranch = "disease"
        elseif row.tint == RLAnimalQuery.TINT_MARKED then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.2, 0)
            tintBranch = "marked"
        else
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 1, 1)
            tintBranch = "normal"
        end
    end
    Log:trace("RLMenuAIFrame:populateCellForItemInSection: uniqueId=%s tint=%s isFavourite=%s",
        tostring(cluster.uniqueId), tostring(tintBranch), tostring(isFavourite))

    local iconCell = cell:getAttribute("icon")
    if iconCell ~= nil then
        if row.icon ~= nil then
            iconCell:setImageFilename(row.icon)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    -- Name split (id/name vs id-without-name)
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

    -- "price" cell: overall-quality label (legacy parity, not money).
    local priceCell = cell:getAttribute("price")
    if priceCell ~= nil then
        local qualityKey = RLAIStockService.getQualityLabel(cluster)
        priceCell:setText(g_i18n:getText(qualityKey))
        Log:trace("RLMenuAIFrame:populateCellForItemInSection: uniqueId=%s qualityKey=%s",
            tostring(cluster.uniqueId), qualityKey)
    end
end
