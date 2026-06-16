--[[
    RLMenuTransferFrame.lua
    RL Tabbed Menu - Transfer tab (Phase 8, pen/world trailer placements).

    One frame for every trailer placement. The left sidebar is a fixed two-entry
    source picker - the counterpart (a pen/world endpoint) and the trailer - each
    labelled `name (used/total)`. Selecting a side lists that side's animals in a
    multi-select SmoothList (checkbox cell, shared detail pane on the right). A
    single footer action button (Load / Unload by side) routes the checked
    animals to the counterpart adapter.

    Where the counterpart's animals come from and what a confirmed transfer does
    is the adapter's job (RLTransferAdapter); the frame only talks to that seam.
    This shell ships the NULL adapter: the counterpart side lists nothing and the
    action is a logged no-op (no mutation). Concrete pen/world adapters + the
    trigger redirects land in later slices.

    Chrome mirrors RLMenuInfoFrame (sidebar + list container); the multi-select
    data row + footer mirror RLMenuMoveFrame (checkbox cell, onClickSelect /
    onClickSelectAll, the populateCell checkbox callback). The pen + animal detail
    columns reuse RLDetailPaneHelper unchanged; the pen column stays hidden while
    no side supplies a husbandry.
]]

RLMenuTransferFrame = {}
local RLMenuTransferFrame_mt = Class(RLMenuTransferFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuTransferFrame instance.
--- @return table self
function RLMenuTransferFrame.new()
    local self = RLMenuTransferFrame:superClass().new(nil, RLMenuTransferFrame_mt)
    self.name = "RLMenuTransferFrame"

    -- Trailer context, read from g_rlMenu on open.
    self.trailer           = nil
    self.counterpart       = nil
    self.adapter           = RLTransferAdapter.NULL
    self.context           = nil   -- { trailer, counterpart, counterpartHandle }
    self.currentSide       = RLTransferAdapter.SIDE_COUNTERPART
    self.farmId            = nil

    -- List + section state (rebuilt per side).
    self.items             = {}
    self.sectionOrder      = {}
    self.itemsBySection    = {}
    self.titlesBySection   = {}

    -- Multi-select state, keyed by RLAnimalUtil.toKey. Cleared on every side
    -- switch (the two sides are different animal universes).
    self.selectedAnimals   = {}

    -- In-flight lock: a transfer is a server round-trip in MP, so the action
    -- button (selection-gated, not request-gated) is locked between dispatch and
    -- onTransferComplete to block a duplicate submit. Re-initialized on every open.
    self.movePending       = false

    self.isFrameOpen = false
    self.hasCustomMenuButtons = true

    -- Footer buttons. Back is always present; Select / SelectAll show when the
    -- side has rows; the single Action button (Load/Unload) is selection-gated.
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
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
    self.actionButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText(RLTransferAdapter.LOAD_LABEL_KEY),
        callback = function() self:onClickAction() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end


--- Load the transfer frame XML and register it with g_gui so the host menu's
--- FrameReference can resolve it.
function RLMenuTransferFrame.setupGui()
    local frame = RLMenuTransferFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/transferFrame.xml", modDirectory),
        "RLMenuTransferFrame",
        frame,
        true
    )
    Log:debug("RLMenuTransferFrame.setupGui: registered")
end


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
function RLMenuTransferFrame:onGuiSetupFinished()
    RLMenuTransferFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuTransferFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup. Unlinks the dot template from the element tree so
--- it can be cloned at runtime. Called by RLMenu:setupMenuPages on the clone.
function RLMenuTransferFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuTransferFrame:initialize: subCategoryDotTemplate missing - dots will not render")
    end
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active. Reads the trailer
--- context from g_rlMenu, picks the counterpart adapter, builds the two-entry
--- source picker, and seeds the side via the emptiness heuristic.
function RLMenuTransferFrame:onFrameOpen()
    RLMenuTransferFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true

    if g_rlMenu ~= nil then
        self.trailer     = g_rlMenu.trailerVehicle
        self.counterpart = g_rlMenu.trailerCounterpart
        -- counterpartHandle is the engine ref a concrete adapter enumerates; the
        -- trigger-redirect slices populate it. nil here (the shell ignores it).
        self.context = {
            trailer           = self.trailer,
            counterpart       = self.counterpart,
            counterpartHandle = g_rlMenu.trailerCounterpartHandle,
        }
    else
        self.context = { trailer = nil, counterpart = nil, counterpartHandle = nil }
    end

    self.adapter = RLTransferAdapter.forCounterpart(self.counterpart)
    self.farmId  = RLAnimalInfoService.getCurrentFarmId()
    self.selectedAnimals = {}
    self.movePending = false

    -- Completion callback handed to the move service via the adapter. The closure
    -- captures BOTH the trailer and the counterpart (pen) at open time - the
    -- stale-callback guard: if the frame is closed, OR reopened on a different
    -- trailer, OR reopened on the SAME trailer at a different pen before the server
    -- responds, onTransferComplete drops the callback (no repaint of a reopened
    -- session - the counterpart handle is what varies per session, like the Move
    -- frame's selectedHusbandry identity).
    local dispatchedTrailer = self.trailer
    local dispatchedCounterpart = self.context.counterpartHandle
    self.context.onComplete = function(errorCode)
        self:onTransferComplete(errorCode, dispatchedTrailer, dispatchedCounterpart)
    end

    local trailerName = RLTrailerEndpointService.getDisplayData(self.trailer).name
    Log:info("RLMenuTransferFrame:onFrameOpen: counterpart=%s trailer='%s'",
        tostring(self.counterpart), tostring(trailerName))

    -- Reset SmoothList selection sentinels to 0 (the "no selection" sentinel) so
    -- a stale focus index does not leak into the first reload.
    if self.animalList ~= nil then
        self.animalList.selectedSectionIndex = 0
        self.animalList.selectedIndex = 0
    end

    self:refreshSources()

    -- Explicit focus links for keyboard navigation (shared sidebar/list structure
    -- across frames; FocusManager auto-layout otherwise resolves to other frames).
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end
end


--- Called by the Paging element when this tab is deactivated. Transfer has no
--- sibling tab in MODE_TRAILER, so there is no shared-selection export.
function RLMenuTransferFrame:onFrameClose()
    RLMenuTransferFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end


-- =============================================================================
-- Source picker (two fixed entries: counterpart, trailer)
-- =============================================================================

--- Recompute the two sidebar entry labels (counterpart + trailer) as
--- `name (used/total)` and push them to the selector WITHOUT re-seeding the side.
--- Keeps the NULL discrimination: a concrete adapter's display NAME is an engine
--- string used verbatim, while the NULL adapter returns an i18n KEY the frame must
--- resolve. Called on open (via refreshSources) and after a transfer completes
--- (counts refresh in place; the active side is preserved - no heuristic re-seed).
--- @return string cpLabel, string trLabel  the composed labels (for logging)
function RLMenuTransferFrame:updateSourceLabels()
    -- Counterpart entry. context-aware getDisplayData so a concrete adapter knows
    -- its pen; NULL accepts and ignores the context.
    local cpData = self.adapter:getDisplayData(self.context)
    local cpName = cpData.name
    if self.adapter == RLTransferAdapter.NULL then
        cpName = g_i18n:getText(cpData.name)
    end
    local cpLabel = RLTransferAdapter.formatCapacityLabel(cpName, cpData.used, cpData.total)

    -- Trailer entry (engine name string from the endpoint service).
    local trData = RLTrailerEndpointService.getDisplayData(self.trailer)
    local trLabel = RLTransferAdapter.formatCapacityLabel(trData.name, trData.used, trData.total)

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts({ cpLabel, trLabel })
    end
    Log:trace("RLMenuTransferFrame:updateSourceLabels: counterpart='%s' trailer='%s'", cpLabel, trLabel)
    return cpLabel, trLabel
end


--- Rebuild the two-entry sidebar selector + dots and seed the initial side.
--- Entry 1 = counterpart (adapter), entry 2 = trailer (endpoint service). Each
--- label is `name (used/total)`. Label compute + setTexts live in updateSourceLabels.
function RLMenuTransferFrame:refreshSources()
    local cpLabel, trLabel = self:updateSourceLabels()
    local labels = { cpLabel, trLabel }

    -- Clear existing dot clones, then clone one dot per entry.
    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end
    for index = 1, #labels do
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
        self.subCategoryDotBox:setVisible(1 < #labels)
    end

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(labels)
    end

    -- Seed the side via the pure heuristic: empty trailer -> counterpart (load),
    -- loaded -> trailer (unload).
    local trailerEmpty = RLTrailerEndpointService.isEmpty(self.trailer)
    local side = RLTransferAdapter.initialSourceSide(trailerEmpty)
    local seedIndex = (side == RLTransferAdapter.SIDE_TRAILER) and 2 or 1
    Log:info("RLMenuTransferFrame:refreshSources: counterpart='%s' trailer='%s' trailerEmpty=%s -> seed side=%s (index %d)",
        cpLabel, trLabel, tostring(trailerEmpty), side, seedIndex)

    if self.subCategorySelector ~= nil then
        -- setState(_, true) fires the onClick (onSourceChanged) UNCONDITIONALLY:
        -- the forced-event flag raises the callback whether or not the index
        -- changed, so this seeds the side in one call for both the index-1 and
        -- index-2 cases (mirrors the Info/Move husbandry seed, which likewise rely
        -- on the forced event and add no no-change branch).
        self.subCategorySelector:setState(seedIndex, true)
    else
        self:onSourceChanged(seedIndex)
    end
end


--- MultiTextOption onClick callback. Switches the active side, clears the
--- cross-side selection, and rebuilds the list + detail + buttons.
--- @param state number 1 = counterpart, 2 = trailer
function RLMenuTransferFrame:onSourceChanged(state)
    if state == nil or state < 1 or state > 2 then return end

    self.currentSide = (state == 2) and RLTransferAdapter.SIDE_TRAILER
        or RLTransferAdapter.SIDE_COUNTERPART

    -- Two sides are different animal universes - clear any checkbox selection so
    -- it cannot leak across the switch.
    self.selectedAnimals = {}

    Log:debug("RLMenuTransferFrame:onSourceChanged: state=%d side=%s (selection cleared)",
        state, self.currentSide)

    self:reloadAnimalList()
    self:updatePenDisplay()
    self:updateButtonVisibility()
end


-- =============================================================================
-- Animal list
-- =============================================================================

--- Build the item list for the active side, group into sections, refresh the
--- SmoothList, and seed the detail pane for the first row.
function RLMenuTransferFrame:reloadAnimalList()
    self.items = self:buildSideItems(self.currentSide)
    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLAnimalQuery.buildSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:seedDetailForFirstRow()
    self:updateEmptyState()
end


--- Build the list items for a side. Trailer side: wrap + validate the trailer's
--- live contents. Counterpart side: the adapter enumerates (NULL -> {}).
--- @param side string SIDE_COUNTERPART | SIDE_TRAILER
--- @return table items
function RLMenuTransferFrame:buildSideItems(side)
    if side == RLTransferAdapter.SIDE_TRAILER then
        return self:buildTrailerItems()
    end
    local items = self.adapter:enumerate(self.context) or {}
    Log:debug("RLMenuTransferFrame:buildSideItems: counterpart side -> %d item(s)", #items)
    return items
end


--- Wrap the trailer's live contents into AnimalItemStock items, skipping
--- non-loadable clusters (numAnimals < 1, e.g. riding-mission horses) and
--- unresolvable subtypes (props / vanilla items) - mirrors the legacy
--- AnimalScreenTrailer:initSourceItems validity gate.
--- @return table items
function RLMenuTransferFrame:buildTrailerItems()
    local refs = RLTrailerEndpointService.getContents(self.trailer)
    local items = {}
    local skipped = 0
    for _, ref in ipairs(refs) do
        if self:isLoadableTrailerCluster(ref) then
            local wrapped = RLAnimalQuery._wrapCluster(ref)
            if wrapped ~= nil then
                items[#items + 1] = wrapped
            else
                skipped = skipped + 1
            end
        else
            skipped = skipped + 1
        end
    end
    Log:debug("RLMenuTransferFrame:buildTrailerItems: %d item(s), %d skipped (invalid cluster)",
        #items, skipped)
    return items
end


--- Whether a trailer cluster is a loadable animal (legacy initSourceItems
--- parity). Rejects numAnimals < 1 and an unresolvable subTypeIndex.
--- @param ref table|nil  a live cluster from getContents
--- @return boolean loadable
function RLMenuTransferFrame:isLoadableTrailerCluster(ref)
    if ref == nil then return false end

    if ref.numAnimals ~= nil and ref.numAnimals < 1 then
        Log:trace("RLMenuTransferFrame:isLoadableTrailerCluster: skip numAnimals=%s", tostring(ref.numAnimals))
        return false
    end

    local subTypeIndex = (ref.getSubTypeIndex ~= nil and ref:getSubTypeIndex()) or ref.subTypeIndex
    if subTypeIndex == nil then
        Log:trace("RLMenuTransferFrame:isLoadableTrailerCluster: skip nil subTypeIndex")
        return false
    end

    if g_currentMission ~= nil and g_currentMission.animalSystem ~= nil
        and g_currentMission.animalSystem.getSubTypeByIndex ~= nil then
        if g_currentMission.animalSystem:getSubTypeByIndex(subTypeIndex) == nil then
            Log:trace("RLMenuTransferFrame:isLoadableTrailerCluster: skip unresolvable subTypeIndex=%s",
                tostring(subTypeIndex))
            return false
        end
    end

    return true
end


--- Seed the detail pane for the auto-selected first row (setSelectedItem does
--- NOT fire onListSelectionChanged). Clears the animal column when the side is
--- empty.
function RLMenuTransferFrame:seedDetailForFirstRow()
    if self.animalList == nil then return end

    if #self.sectionOrder == 0 then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end

    self.animalList:setSelectedItem(1, 1, false, true)

    local key = self.sectionOrder[1]
    local items = key and self.itemsBySection[key] or nil
    local item = items and items[1] or nil
    if item ~= nil and item.cluster ~= nil then
        RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, self:detailHusbandry())
    end
end


--- The husbandry to pass to the detail-pane animal renderer. Side-aware: the
--- counterpart (pen) side returns context.counterpartHandle so the pen detail
--- column populates; the trailer side returns nil (the trailer has no husbandry,
--- so the pen column stays hidden - the invariant). getAnimalDisplay /
--- updatePenDisplay both tolerate nil.
--- @return table|nil
function RLMenuTransferFrame:detailHusbandry()
    if self.currentSide == RLTransferAdapter.SIDE_COUNTERPART then
        return self.context ~= nil and self.context.counterpartHandle or nil
    end
    return nil
end


--- SmoothList delegate: fired when the user focuses a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuTransferFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuTransferFrame:onListSelectionChanged: section=%d index=%d", section, index)

    local key = self.sectionOrder[section]
    if key == nil then RLDetailPaneHelper.clearAnimalDetail(self); return end
    local items = self.itemsBySection[key]
    if items == nil then RLDetailPaneHelper.clearAnimalDetail(self); return end
    local item = items[index]
    if item == nil or item.cluster == nil then RLDetailPaneHelper.clearAnimalDetail(self); return end

    RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, self:detailHusbandry())
    self:updateButtonVisibility()
end


-- =============================================================================
-- Empty state / detail pane
-- =============================================================================

--- Toggle the empty-state text when the active side has no rows. Both sides
--- always have a sidebar entry, so the text gates on rows alone. The list itself
--- stays visible (an empty SmoothList renders no rows but remains a valid focus
--- target, which onFrameOpen sets focus to) - mirrors RLMenuMoveFrame.
function RLMenuTransferFrame:updateEmptyState()
    local hasItems = #self.items > 0
    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(not hasItems)
    end
end


--- Refresh the pen detail column. Shell: no side supplies a husbandry, so the
--- pen column stays hidden (updatePenDisplay hides penBox on nil husbandry).
function RLMenuTransferFrame:updatePenDisplay()
    RLDetailPaneHelper.updatePenDisplay(self, self:detailHusbandry(), self.farmId)
end


-- =============================================================================
-- Multi-select
-- =============================================================================

--- The currently focused row's animal, or nil.
--- @return table|nil cluster
function RLMenuTransferFrame:getSelectedAnimal()
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


--- Count the checked animals.
--- @return number
function RLMenuTransferFrame:getSelectedCount()
    local count = 0
    for _, selected in pairs(self.selectedAnimals) do
        if selected then count = count + 1 end
    end
    return count
end


--- Collect the checked animals into an array (display order).
--- @return table animals
function RLMenuTransferFrame:collectSelectedAnimals()
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
    return animals
end


--- Toggle the focused animal's checkbox.
function RLMenuTransferFrame:onClickSelect()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuTransferFrame:onClickSelect: no animal focused")
        return
    end

    local key = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId,
        animal.birthday and animal.birthday.country or "")
    self.selectedAnimals[key] = not self.selectedAnimals[key]
    Log:trace("RLMenuTransferFrame:onClickSelect: key=%s -> %s", key, tostring(self.selectedAnimals[key]))

    -- Reload to re-render checkmarks; SmoothList preserves focus across reloadData
    -- so do NOT re-seed the selection (that would reset focus to (1,1)).
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
end


--- Toggle all rows: if any are checked, clear; otherwise check all on this side.
function RLMenuTransferFrame:onClickSelectAll()
    local hasSelection = self:getSelectedCount() > 0

    if hasSelection then
        self.selectedAnimals = {}
        Log:debug("RLMenuTransferFrame:onClickSelectAll: deselected all")
    else
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
        Log:debug("RLMenuTransferFrame:onClickSelectAll: selected all (%d)", self:getSelectedCount())
    end

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
end


-- =============================================================================
-- Footer action (Load / Unload)
-- =============================================================================

--- Rebuild the footer button info. Back always; Select/SelectAll when the side
--- has rows; the single Action button (Load/Unload) only when at least one
--- animal is checked (selection-gated visibility).
function RLMenuTransferFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local hasItems = #self.items > 0
    local selectedCount = self:getSelectedCount()

    if hasItems then
        table.insert(self.menuButtonInfo, self.selectButtonInfo)
        self.selectAllButtonInfo.text = g_i18n:getText(
            selectedCount > 0 and "rl_ui_selectNone" or "rl_ui_selectAll")
        table.insert(self.menuButtonInfo, self.selectAllButtonInfo)
    end

    if selectedCount > 0 then
        local direction = RLTransferAdapter.directionForSide(self.currentSide)
        self.actionButtonInfo.text = g_i18n:getText(self.adapter:actionLabel(direction))
        table.insert(self.menuButtonInfo, self.actionButtonInfo)
    end

    Log:debug("RLMenuTransferFrame:updateButtonVisibility: %d buttons, side=%s selectedCount=%d",
        #self.menuButtonInfo, tostring(self.currentSide), selectedCount)
    self:setMenuButtonInfoDirty()
end


--- Footer action handler. Routes the checked animals to the adapter's dispatch
--- for the current side's direction. A concrete adapter routes to the move service
--- (async in MP); completion (onTransferComplete) owns the refresh + lock release.
--- The shell NULL adapter logs + returns false, so the frame leaves all state
--- unchanged (no event, no list change).
function RLMenuTransferFrame:onClickAction()
    -- Duplicate-submit guard: the action button is selection-gated, not
    -- request-gated, so block a second dispatch while a move is in flight.
    if self.movePending then
        Log:debug("RLMenuTransferFrame:onClickAction: a transfer is already in flight, ignoring")
        return
    end

    local animals = self:collectSelectedAnimals()
    local direction = RLTransferAdapter.directionForSide(self.currentSide)
    Log:debug("RLMenuTransferFrame:onClickAction: side=%s direction=%s selected=%d",
        tostring(self.currentSide), direction, #animals)

    if #animals == 0 then
        Log:trace("RLMenuTransferFrame:onClickAction: no animals selected, no-op")
        return
    end

    -- Set the in-flight lock BEFORE dispatch: in SP the move service fires
    -- onTransferComplete SYNCHRONOUSLY inside dispatch (clearing the lock), so
    -- setting it afterwards would strand it true. A `false` return (NULL/world
    -- shell, or a fail-closed guard) means NO completion callback will fire, so
    -- release the lock here.
    self.movePending = true
    local handled = self.adapter:dispatch(direction, animals, self.context)
    if not handled then
        self.movePending = false
        Log:debug("RLMenuTransferFrame:onClickAction: dispatch returned false, state unchanged (shell no-op)")
        return
    end

    -- Routed to the move service: completion (onTransferComplete) owns the refresh
    -- + lock release. Do NOT reload synchronously - the move is a server round-trip
    -- in MP and a synchronous reload would show stale contents / miss server errors.
    Log:debug("RLMenuTransferFrame:onClickAction: dispatched, awaiting completion")
end


--- Completion callback for an async transfer (mirrors RLMenuMoveFrame:onMoveComplete).
--- The move is a server round-trip in MP, so error surfacing + the refresh MUST
--- happen here, not synchronously after dispatch. Guarded against a stale callback
--- on the FULL dispatch context: ignored when the frame is closed, the trailer
--- changed, OR the same trailer reopened on a different pen (the counterpart handle
--- is the per-session identity, like the Move frame's selectedHusbandry) - a delayed
--- callback from session A must not repaint a reopened session B. On error shows an
--- InfoDialog; either way it clears the selection + the in-flight lock, refreshes the
--- (used/total) labels in place (active side preserved - no heuristic re-seed), and
--- reloads the list + pen column + buttons.
--- @param errorCode number  AnimalMoveEvent.MOVE_SUCCESS or an error code
--- @param dispatchedTrailer table  the trailer captured at dispatch time (stale guard)
--- @param dispatchedCounterpart table|nil  the counterpart (pen) captured at dispatch (stale guard)
function RLMenuTransferFrame:onTransferComplete(errorCode, dispatchedTrailer, dispatchedCounterpart)
    if not self.isFrameOpen or self.trailer ~= dispatchedTrailer
        or self.context == nil or self.context.counterpartHandle ~= dispatchedCounterpart then
        Log:debug("RLMenuTransferFrame:onTransferComplete: stale callback (frameOpen=%s, sameTrailer=%s, sameCounterpart=%s), ignoring",
            tostring(self.isFrameOpen), tostring(self.trailer == dispatchedTrailer),
            tostring(self.context ~= nil and self.context.counterpartHandle == dispatchedCounterpart))
        return
    end

    if errorCode ~= nil and errorCode ~= AnimalMoveEvent.MOVE_SUCCESS then
        InfoDialog.show(RLAnimalMoveService.getErrorText(errorCode))
        Log:debug("RLMenuTransferFrame:onTransferComplete: transfer failed, errorCode=%d", errorCode)
    else
        Log:info("RLMenuTransferFrame:onTransferComplete: transfer succeeded")
    end

    self.selectedAnimals = {}
    self.movePending = false
    self:updateSourceLabels()
    self:reloadAnimalList()
    self:updatePenDisplay()
    self:updateButtonVisibility()
end


-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

--- @param list table
--- @return number
function RLMenuTransferFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuTransferFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuTransferFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. Mirrors the Move tab pattern (animal row + status
--- icons + the multi-select checkbox).
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuTransferFrame:populateCellForItemInSection(list, section, index, cell)
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

    -- Checkbox: show the tick when this row's identity is checked; wire the
    -- direct-click toggle (mirrors the Move tab onClickCallback pattern).
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
                Log:trace("RLMenuTransferFrame checkbox click: key=%s -> %s",
                    identityKey, tostring(self.selectedAnimals[identityKey]))
            end
        end
    end
end
