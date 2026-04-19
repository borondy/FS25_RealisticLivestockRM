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

    -- Selection-identity dedupe cache. Set after each successful
    -- onBullSelectionChanged run; checked on entry to early-return when the
    -- same bull re-selects (e.g. when a Favourite reloadData re-fires the
    -- SmoothList selection callback). Prevents stepper state + price from
    -- resetting on spurious re-fires. Cache key is 4-field (farmId, uniqueId,
    -- country, speciesTypeIndex) so cross-species identity collisions do not
    -- suppress render. Cleared on frame open and on post-buy reload.
    self.lastSelectedBullIdentity = nil

    -- Reentrancy flag for Buy. Set when the handler commits to opening a
    -- result InfoDialog; cleared when the dialog callback runs (or on frame
    -- open / no-spawn-slot early-return). Prevents a rapid second Enter
    -- press from double-dispatching SemenBuyEvent + double-consuming spawn
    -- slots while the modal dialog is pending.
    self.buyInFlight = false

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
    -- Clear selection-identity dedupe cache so the first onBullSelectionChanged
    -- after a fresh open always renders (no stale cache from previous session).
    self.lastSelectedBullIdentity = nil
    -- Belt-and-suspenders clear of the Buy reentrancy flag. The callback path
    -- normally clears it, but a stale-frame guard in onPostSemenBuy can skip
    -- the clear; resetting here guarantees Buy is usable on every frame open.
    self.buyInFlight = false
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
--- Phase 2: selection-identity dedupe cache prevents spurious stepper resets.
--- onClickFavourite calls animalList:reloadData to refresh the orange tint
--- (legacy parity at AnimalScreen.lua:724). Bare reloadData usually preserves
--- the highlight without refiring the selection callback, but if it ever
--- does, the cache check here early-returns before touching the stepper or
--- the detail pane. Also covers the RLRM-162 class of spurious re-fires.
function RLMenuAIFrame:onBullSelectionChanged()
    local animal = self:getSelectedAnimal()

    if animal == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        if self.aiPurchasePanel ~= nil then self.aiPurchasePanel:setVisible(false) end
        self.lastSelectedBullIdentity = nil
        self:updateButtonVisibility()
        Log:trace("RLMenuAIFrame:onBullSelectionChanged: no animal focused")
        return
    end

    local country = (animal.birthday ~= nil and animal.birthday.country) or ""
    local speciesTypeIndex = self.activeSpeciesTypeIndex
    local cached = self.lastSelectedBullIdentity
    if cached ~= nil
        and cached.farmId           == animal.farmId
        and cached.uniqueId         == animal.uniqueId
        and cached.country          == country
        and cached.speciesTypeIndex == speciesTypeIndex then
        Log:trace("RLMenuAIFrame:onBullSelectionChanged: dedupe hit farmId=%s uniqueId=%s species=%s - skipping re-render",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(speciesTypeIndex))
        return
    end

    Log:trace("RLMenuAIFrame:onBullSelectionChanged: farmId=%s uniqueId=%s country=%s species=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(country),
        tostring(speciesTypeIndex))

    -- AI bulls have no source husbandry; the helper tolerates nil.
    RLDetailPaneHelper.updateAnimalDisplay(self, animal, nil)

    -- Middle column (Phase 2 routes price through onQuantityStateChanged so
    -- bull change + stepper click share one render path).
    self:updateMiddleColumn(animal)

    -- Favourite button label (legacy parity at AnimalScreen.lua:645).
    self:refreshFavouriteButtonLabel(animal)

    self:updateButtonVisibility()

    -- Cache the identity for the next call's dedupe check. 4-field key
    -- (farmId, uniqueId, country, speciesTypeIndex) so an AI bull in one
    -- species sharing id fields with a bull in another species does not
    -- suppress render when the species cycler moves between them.
    self.lastSelectedBullIdentity = {
        farmId           = animal.farmId,
        uniqueId         = animal.uniqueId,
        country          = country,
        speciesTypeIndex = speciesTypeIndex,
    }
end


--- Populate the middle-column elements for the given bull. Resets the stepper
--- to position 1 (legacy parity at AnimalScreen.lua:688-689) and routes the
--- price display through onQuantityStateChanged so bull change and stepper
--- click share a single render path.
--- @param animal table Raw Animal
function RLMenuAIFrame:updateMiddleColumn(animal)
    if animal == nil then return end

    if self.aiPurchasePanel ~= nil then
        self.aiPurchasePanel:setVisible(true)
    end

    -- Reset stepper to position 1 on every bull-selection change. `setState`
    -- called without the second `forceEvent` arg silently updates state
    -- without firing the onClick callback, so we invoke onQuantityStateChanged
    -- explicitly below to recompute the price for the newly-selected bull.
    -- Legacy parity at AnimalScreen.lua:688-689.
    if self.aiQuantitySelector ~= nil and self.aiQuantitySelector.setState ~= nil then
        self.aiQuantitySelector:setState(1)
    end

    -- Average Success: legacy pattern at AnimalScreen.lua:649.
    -- math.round (not %d) matches DewarData.lua:401 and AnimalAIDialog.lua:154.
    if self.averageSuccessValue ~= nil then
        local successPct = math.round((animal.success or 0) * 100)
        self.averageSuccessValue:setText(string.format("%s%%", tostring(successPct)))
    end

    -- Price: canonical path through the stepper handler so selection-change
    -- and stepper clicks run through the exact same recompute + render.
    self:onQuantityStateChanged(1)
end


--- Set the Favourite button label from the bull's current favourite state.
--- Called on selection change (read-only). Routes through the service's
--- getFavouriteButtonText so selection-change and toggle-site (Phase 2's
--- onClickFavourite) share one i18n-key mapping.
--- @param animal table Raw Animal
function RLMenuAIFrame:refreshFavouriteButtonLabel(animal)
    if animal == nil or self.favouriteButtonInfo == nil then return end

    local uniqueUserId = g_localPlayer ~= nil and g_localPlayer:getUniqueId() or nil
    local isFavourite = uniqueUserId ~= nil
        and type(animal.favouritedBy) == "table"
        and animal.favouritedBy[uniqueUserId] == true

    self.favouriteButtonInfo.text =
        g_i18n:getText(RLAIStockService.getFavouriteButtonText(isFavourite))
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
--- present in the footer. Favourite disables on no-bull only. Buy disables
--- on no-bull OR no tradeAnimals permission.
---
--- Legacy parity (AnimalScreen.lua:628-645) gates both buttons SOLELY on
--- selection. Intentional UX divergence: Phase 2 adds a client-side
--- tradeAnimals gate for Buy so MP clients never see an active Buy button
--- they cannot actually use. Legacy's click-time check at
--- AnimalScreen.lua:553-554 stays in place as defense in depth.
function RLMenuAIFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local focusedAnimal = self:getSelectedAnimal()
    local hasBull = focusedAnimal ~= nil

    -- Client-side tradeAnimals gate for Buy only. Favourite is a purely local
    -- mark with no permission requirement.
    local hasTradePermission = g_currentMission ~= nil
        and g_currentMission.getHasPlayerPermission ~= nil
        and g_currentMission:getHasPlayerPermission("tradeAnimals") == true

    self.favouriteButtonInfo.disabled = not hasBull
    self.buyButtonInfo.disabled = not hasBull or not hasTradePermission
    table.insert(self.menuButtonInfo, self.favouriteButtonInfo)
    table.insert(self.menuButtonInfo, self.buyButtonInfo)

    Log:trace("RLMenuAIFrame:updateButtonVisibility: buttons=%d hasBull=%s tradePerm=%s favDisabled=%s buyDisabled=%s",
        #self.menuButtonInfo, tostring(hasBull), tostring(hasTradePermission),
        tostring(self.favouriteButtonInfo.disabled), tostring(self.buyButtonInfo.disabled))
    self:setMenuButtonInfoDirty()
end


-- =============================================================================
-- Quantity stepper: recompute displayed total price for current state
-- =============================================================================

--- MultiTextOption onClick callback for aiQuantitySelector. Legacy parity at
--- AnimalScreen.lua:694-705 (onClickChangeAIQuantity): read quantity for the
--- new state, compute total price, format as money, update aiQuantityPrice.
--- Also invoked from updateMiddleColumn(animal) on bull-selection change with
--- state=1 so the canonical price render path is shared.
--- @param state number 1-based DEWAR_QUANTITIES index
function RLMenuAIFrame:onQuantityStateChanged(state)
    if state == nil then
        Log:warning("RLMenuAIFrame:onQuantityStateChanged: nil state")
        return
    end
    if AnimalScreen == nil or AnimalScreen.DEWAR_QUANTITIES == nil then
        Log:warning("RLMenuAIFrame:onQuantityStateChanged: DEWAR_QUANTITIES unavailable")
        return
    end
    local quantity = AnimalScreen.DEWAR_QUANTITIES[state]
    if quantity == nil then
        Log:warning("RLMenuAIFrame:onQuantityStateChanged: unknown state %s", tostring(state))
        return
    end

    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onQuantityStateChanged: state=%d quantity=%d no animal focused",
            state, quantity)
        return
    end

    local price = RLAIStockService.getPriceForQuantity(animal, quantity)
    if self.aiQuantityPrice ~= nil then
        self.aiQuantityPrice:setText(g_i18n:formatMoney(price, 2, true, true))
    end
    Log:trace("RLMenuAIFrame:onQuantityStateChanged: state=%d quantity=%d price=%.2f farmId=%s uniqueId=%s",
        state, quantity, price, tostring(animal.farmId), tostring(animal.uniqueId))
end


-- =============================================================================
-- Favourite + Buy handlers
-- =============================================================================

--- Favourite footer action. Delegates to RLAIStockService.toggleFavourite
--- (local-only; no network event; RLRM-172 tracks the MP persistence gap)
--- and refreshes the row tint + button label on success.
---
--- Legacy parity at AnimalScreen.lua:708-726. Binds the post-toggle button
--- label from the fresh return value, NOT from the latent-bug `uniqueUserId`
--- global at legacy line 722 (always nil, so legacy's button always read
--- "Favourite" regardless of state).
function RLMenuAIFrame:onClickFavourite()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onClickFavourite: no animal focused")
        return
    end

    local isFav = RLAIStockService.toggleFavourite(animal)
    if isFav == nil then
        -- Service logged the WARNING; skip UI updates so the button label
        -- does not lie about the state we failed to write.
        Log:debug("RLMenuAIFrame:onClickFavourite: toggle failed (service returned nil)")
        return
    end

    -- Refresh the row tint via reloadData. Legacy parity at
    -- AnimalScreen.lua:724. Bare reloadData usually preserves the selection
    -- highlight without re-firing the SmoothList selection callback; if it
    -- ever does re-fire, the lastSelectedBullIdentity dedupe in
    -- onBullSelectionChanged catches it.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    -- Label refresh. Fixes legacy's latent bug by binding from the fresh
    -- return value. menuButtonInfo is marked dirty so the footer redraws.
    if self.favouriteButtonInfo ~= nil then
        self.favouriteButtonInfo.text =
            g_i18n:getText(RLAIStockService.getFavouriteButtonText(isFav))
        self:setMenuButtonInfoDirty()
    end

    Log:debug("RLMenuAIFrame:onClickFavourite: farmId=%s bullUid=%s isFavourite=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(isFav))
end


--- Buy footer action. Mirrors legacy onClickBuyAI at
--- AnimalScreen.lua:526-564 line-by-line. Step ordering preserved INCLUDING
--- the known pre-existing bug at line 542 (markPlaceUsed BEFORE the
--- permission/money checks leaks the store slot on failed pre-flight;
--- tracked separately as RLRM-173 and out of scope for Phase 2 per
--- MUTATION PARITY rule).
---
--- No-spawn-slot UX extension: legacy silently returns on `x == nil` at
--- line 538-540; Phase 2 shows a warning dialog with `shop_messageNoSpace`
--- to close the "why didn't anything happen?" gap. No event is dispatched.
function RLMenuAIFrame:onClickBuy()
    -- Reentrancy guard: InfoDialog is async, so a second Enter press between
    -- dispatch and dialog-dismiss would double-fire SemenBuyEvent and
    -- double-consume store spawn slots. Clear in onPostSemenBuy + onFrameOpen.
    if self.buyInFlight == true then
        Log:trace("RLMenuAIFrame:onClickBuy: buy in flight, ignoring re-entry")
        return
    end

    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onClickBuy: no animal focused")
        return
    end

    -- farmId sanity. Guard BEFORE markPlaceUsed so a spectator / no-farm click
    -- does not leak a store spawn slot. Legacy at AnimalScreen.lua:544 reads
    -- g_localPlayer.farmId unconditionally (crashes on nil); Phase 2 declines
    -- gracefully with a WARNING.
    if g_localPlayer == nil
        or g_localPlayer.farmId == nil
        or g_localPlayer.farmId == 0 then
        Log:warning("RLMenuAIFrame:onClickBuy: no valid local player farm (player=%s farmId=%s)",
            tostring(g_localPlayer), tostring(g_localPlayer and g_localPlayer.farmId))
        return
    end

    -- Step 1: spawn-slot lookup. Legacy line 534-536.
    local spawnPlaces = g_currentMission and g_currentMission.storeSpawnPlaces
    local usedPlaces  = g_currentMission and g_currentMission.usedStorePlaces
    if spawnPlaces == nil or usedPlaces == nil then
        Log:warning("RLMenuAIFrame:onClickBuy: storeSpawnPlaces / usedStorePlaces unavailable")
        return
    end

    local x, y, z, place, width = PlacementUtil.getPlace(
        spawnPlaces,
        { width = 1, height = 2.5, length = 1, widthOffset = 0.5, lengthOffset = 0.5 },
        usedPlaces,
        true, true, false, true
    )

    if x == nil then
        Log:warning("RLMenuAIFrame:onClickBuy: no free spawn slot")
        -- Reuse the vanilla Shop's "delivery space blocked" text so the
        -- no-space warning matches the rest of the vanilla Shop UX and
        -- comes pre-localized in every base-game language.
        InfoDialog.show(g_i18n:getText("shop_messageNoSpace"),
            nil, nil, DialogElement.TYPE_WARNING)
        return
    end

    -- Step 2: mark the slot as used. Legacy line 542.
    -- NOTE: This runs BEFORE the permission/money checks so a failed
    -- pre-flight leaks the slot. Legacy bug mirrored per MUTATION PARITY;
    -- tracked as RLRM-173.
    PlacementUtil.markPlaceUsed(usedPlaces, place, width)

    -- Commit to opening a result dialog. Flag blocks reentrant Enter clicks.
    self.buyInFlight = true

    -- Step 3: compute quantity + price. Legacy line 544-549.
    local farmId = g_localPlayer.farmId
    local state = (self.aiQuantitySelector ~= nil and self.aiQuantitySelector:getState()) or 1
    local quantity = (AnimalScreen ~= nil and AnimalScreen.DEWAR_QUANTITIES ~= nil
        and AnimalScreen.DEWAR_QUANTITIES[state]) or 1
    local price = RLAIStockService.getPriceForQuantity(animal, quantity)

    Log:debug("RLMenuAIFrame:onClickBuy: pre-flight farmId=%d state=%d quantity=%d price=%.2f spawn=(%.2f,%.2f,%.2f)",
        farmId, state, quantity, price, x, y, z)

    -- Step 4 + 5: permission + money. Legacy lines 551-560.
    -- Money compare uses `getMoney(farmId) + price < 0` verbatim from legacy
    -- at AnimalScreen.lua:555 (with `price` as the positive computed value
    -- per legacy). This form is functionally dead in normal play - with a
    -- positive balance and a positive price the sum is always >= 0, so the
    -- check only fires when the farm is already deep in debt (balance <
    -- -price). This is a legacy bug; Phase 2 mirrors it per MUTATION PARITY.
    -- Separate follow-up work would replace with `getMoney(farmId) - price < 0`.
    local errorCode
    if not g_currentMission:getHasPlayerPermission("tradeAnimals") then
        errorCode = AnimalBuyEvent.BUY_ERROR_NO_PERMISSION
        Log:warning("RLMenuAIFrame:onClickBuy: no tradeAnimals permission")
    elseif g_currentMission:getMoney(farmId) + price < 0 then
        errorCode = AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY
        Log:warning("RLMenuAIFrame:onClickBuy: legacy money-check triggered (balance+price<0) price=%.2f",
            price)
    else
        -- Step 6: dispatch. Legacy line 559.
        errorCode = AnimalBuyEvent.BUY_SUCCESS
        g_client:getServerConnection():sendEvent(
            SemenBuyEvent.new(animal, quantity, -price, farmId, { x, y, z }, { 0, 0, 0 }),
            true)
        Log:info("RLMenuAIFrame:onClickBuy: SemenBuyEvent dispatched farmId=%d bullUid=%s quantity=%d price=%.2f",
            farmId, tostring(animal.uniqueId), quantity, price)
    end

    -- Step 7: always render the result dialog. Legacy line 562.
    self:onBuyComplete(errorCode)
end


--- Client-side pre-flight completion handler. Mirrors legacy onSemenBought
--- at AnimalScreen.lua:567-585 - maps the pre-flight errorCode to a text +
--- dialog type and opens an InfoDialog.
---
--- NAME NOTE: "onBuyComplete" refers to client-side pre-flight branching
--- having chosen an errorCode, NOT to server-confirmed completion. A
--- BUY_SUCCESS here means the event was DISPATCHED, not that the dewar
--- spawned. See Design Notes in the spec for the asymmetry.
--- @param errorCode number  One of AnimalBuyEvent.BUY_* constants
function RLMenuAIFrame:onBuyComplete(errorCode)
    local dialogType = DialogElement.TYPE_INFO
    local text = "rl_ui_semenPurchase_successful"

    if errorCode == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY then
        dialogType = DialogElement.TYPE_WARNING
        text = "rl_ui_semenPurchaseNoMoney"
    elseif errorCode == AnimalBuyEvent.BUY_ERROR_NO_PERMISSION then
        dialogType = DialogElement.TYPE_WARNING
        text = "rl_ui_semenPurchaseNoPermission"
    elseif errorCode ~= AnimalBuyEvent.BUY_SUCCESS then
        dialogType = DialogElement.TYPE_WARNING
        text = "rl_ui_semenPurchase_unsuccessful"
    end

    Log:debug("RLMenuAIFrame:onBuyComplete: errorCode=%s text=%s",
        tostring(errorCode), text)

    -- Full positional InfoDialog.show signature mirrored from legacy at
    -- AnimalScreen.lua:583. The trailing `true` is a legacy positional
    -- artifact - the callback functions declare no params and ignore it.
    -- Kept verbatim per MUTATION PARITY rule.
    InfoDialog.show(g_i18n:getText(text), self.onPostSemenBuy, self,
        dialogType, nil, nil, true)
end


--- InfoDialog dismissal callback. Legacy parity at AnimalScreen.lua:588-592
--- (postSemenBought) which calls `self.aiList:reloadData()`. Phase 2 reloads
--- the whole bull list so stock changes reflect immediately.
---
--- Stale-frame guard mirrors Buy/Sell/Info's RLRM-170 pattern: the
--- InfoDialog is modal but survives frame teardown, so the user can press
--- Buy -> close the menu -> dismiss the dialog and we would otherwise call
--- reloadBullList on a torn-down frame. `activeSpeciesTypeIndex` is set in
--- onSpeciesChanged and intentionally NOT cleared in onFrameClose (matches
--- Buy/Sell's activeAnimalTypeIndex lifecycle).
function RLMenuAIFrame:onPostSemenBuy()
    -- Always clear the reentrancy flag regardless of frame state, so a stale
    -- callback on a torn-down frame does not leave Buy permanently disabled
    -- when the frame is reopened. onFrameOpen defensively clears it too.
    self.buyInFlight = false

    if not self.isFrameOpen or self.activeSpeciesTypeIndex == nil then
        Log:trace("RLMenuAIFrame:onPostSemenBuy: stale frame (isFrameOpen=%s speciesTypeIndex=%s); skipping",
            tostring(self.isFrameOpen), tostring(self.activeSpeciesTypeIndex))
        return
    end

    -- Invalidate the dedupe cache before reloadBullList. Without this the
    -- same-identity focused bull would hit the dedupe check after reload and
    -- skip re-rendering, leaving stale stock/price in the middle column.
    self.lastSelectedBullIdentity = nil

    Log:debug("RLMenuAIFrame:onPostSemenBuy: reloading bull list")
    self:reloadBullList()
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
