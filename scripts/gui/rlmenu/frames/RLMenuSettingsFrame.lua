--[[
    RLMenuSettingsFrame.lua
    RL Tabbed Menu Settings tab.

    Horizontal subcategory tab bar with two content panes:
      [General] - placeholder for future non-filter settings.
      [Filters] - single-section SmoothList of saved filters backed by
                  g_rlFilterService:listAvailable, a footer New filter
                  button, and a branched empty-state.

    Tab highlight, pager texts, and focus are seeded in
    initializeSubCategoryPages() called from onFrameOpen on every open,
    so closures stay bound to the live frame instance across opens.

    Selection is id-authoritative: self.selectedFilterId is the source of
    truth, the list's selectedIndex is derived from it on every reload.
    This keeps the cached id consistent with the highlighted row under
    the service's undefined-pairs-order reloads.
]]

RLMenuSettingsFrame = {}
local RLMenuSettingsFrame_mt = Class(RLMenuSettingsFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

-- Store mod directory at source time (g_currentModDirectory only valid during source())
local modDirectory = g_currentModDirectory

--- Subcategory enum. Indices match XML subCategoryTabs[] and subCategoryPages[].
RLMenuSettingsFrame.SUB_CATEGORY = {
    GENERAL = 1,
    FILTERS = 2,
}

--- Construct a new RLMenuSettingsFrame instance.
--- Called once by setupGui() during mod load.
--- @return table self The new frame instance
function RLMenuSettingsFrame.new()
    local self = RLMenuSettingsFrame:superClass().new(nil, RLMenuSettingsFrame_mt)
    self.name = "RLMenuSettingsFrame"

    -- Filter list state. Rows are cloned snapshots from the service so
    -- frame-side mutation stays contract-safe; selection is id-authoritative
    -- (selectedFilterId is the source of truth, list.selectedIndex is
    -- derived on every reload via resolveSelectionById).
    self.rows              = {}
    self.farmId            = nil
    self.isFrameOpen       = false
    self.selectedFilterId  = nil

    -- Guard flag: true while refreshData reconciles selection after a
    -- reload. SmoothList:reloadData fires our onListSelectionChanged
    -- delegate synchronously during its internal clamp. Without this
    -- flag, that callback would overwrite self.selectedFilterId with
    -- whatever row lands at the post-clamp index BEFORE resolveSelectionById
    -- runs, silently breaking the id-authoritative contract.
    -- onListSelectionChanged checks this flag and early-returns.
    self.isReconciling     = false

    -- One-shot flag for the first-visibility measure log on [Filters]. Reset
    -- per frame-open cycle by living on the instance (frames are cloned per
    -- paging lifecycle; see RLMenu:setupMenuPages).
    self.didMeasureFiltersPane = false

    -- Custom footer buttons: Back always, New filter only on [Filters] with
    -- a farm and tradeAnimals permission. hasCustomMenuButtons=true forces
    -- the first page-switch to use self.menuButtonInfo rather than RLMenu's
    -- default back-only set, preventing a one-frame flicker.
    self.hasCustomMenuButtons = true

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
    }
    self.newFilterButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_filters_new_button"),
        callback = function() self:onClickNewFilter() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    Log:trace("RLMenuSettingsFrame.new: instance created")
    return self
end

--- Load the settings frame XML and register the frame with g_gui.
--- Called from RLMenu.setupGui() before the menu XML is loaded so that
--- rlMenu.xml's FrameReference ref="RLMenuSettingsFrame" resolves.
function RLMenuSettingsFrame.setupGui()
    local frame = RLMenuSettingsFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/settingsFrame.xml", modDirectory),
        "RLMenuSettingsFrame",
        frame,
        true  -- frame-only load
    )
    Log:debug("RLMenuSettingsFrame.setupGui: registered")
end

--- Called by the GUI manager after all element references are wired.
--- Do NOT mutate the tree here (fires on both the original and the clone).
--- Closure binding + setTexts live in initializeSubCategoryPages() and are
--- invoked from onFrameOpen() to keep per-clone state fresh on every open.
---
--- Binds the filters SmoothList data source + delegate. Binding here is
--- safe (non-mutating) and necessary so both the original and the clone
--- resolve their own data paths.
function RLMenuSettingsFrame:onGuiSetupFinished()
    RLMenuSettingsFrame:superClass().onGuiSetupFinished(self)
    Log:trace("RLMenuSettingsFrame:onGuiSetupFinished")

    if self.filtersList ~= nil then
        self.filtersList:setDataSource(self)
        self.filtersList:setDelegate(self)
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: filtersList bound")
    else
        Log:warning("RLMenuSettingsFrame:onGuiSetupFinished: filtersList missing from XML")
    end
end

--- Per-clone setup. Called explicitly by RLMenu:setupMenuPages() on the
--- live clone (not the original) after registerPage. No-op in P1-1 -
--- there is no tree mutation to perform; kept as a convention marker for
--- future phases that may need per-clone unlink/teardown.
function RLMenuSettingsFrame:initialize()
    Log:debug("RLMenuSettingsFrame:initialize")
end

--- Called by the Paging element when this tab becomes active.
--- Rebinds tab selection closures, seeds paging texts, resets to General,
--- and parks focus on the tab bar. Rebinding every open (rather than once
--- in onGuiSetupFinished) keeps closures captured against the live frame
--- instance and survives repeated opens.
function RLMenuSettingsFrame:onFrameOpen()
    RLMenuSettingsFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    Log:debug("RLMenuSettingsFrame:onFrameOpen")

    self:initializeSubCategoryPages()

    -- Default to [General] on every open - deliberate, no persistence in P1-1.
    -- Reset the first-visibility measure flag so the log fires once per
    -- frame-open cycle when the user first switches to [Filters].
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)
    self.didMeasureFiltersPane = false

    -- Pull filter rows + seed empty-state + footer buttons for whichever
    -- subtab ends up active. Safe to call even though [General] is the
    -- initial pane; rows are cached for when the user switches to [Filters].
    self:refreshData()

    -- Explicit focus edges between the tab bar and the filters list so
    -- DOWN from the tab bar reaches the list and UP from the list returns
    -- to the tab bar. Mirrors the linkElements pattern used by Info/Buy/
    -- Sell/Move/AI frames; without these, FocusManager auto-layout can
    -- resolve arrow keys to elements in other frames.
    if self.subCategoryPaging ~= nil and self.filtersList ~= nil then
        FocusManager:linkElements(self.subCategoryPaging, FocusManager.BOTTOM, self.filtersList)
        FocusManager:linkElements(self.filtersList, FocusManager.TOP, self.subCategoryPaging)
    end

    -- Initial focus on the tab bar - [General] is the active pane and has
    -- no content to focus. updateSubCategoryPages shifts focus to the list
    -- when the user switches to [Filters].
    FocusManager:setFocus(self.subCategoryPaging)
end

--- Called by the Paging element when this tab is deactivated.
--- Clears isFrameOpen so refreshIfOpen becomes a no-op until the tab
--- reopens; matches the Messages frame convention.
function RLMenuSettingsFrame:onFrameClose()
    RLMenuSettingsFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    Log:debug("RLMenuSettingsFrame:onFrameClose")
end

--- Seed the subcategory tab bar: bind getIsSelected closures on each tab
--- Button and its background ThreePartBitmap, populate subCategoryPaging
--- texts with stringified indices, and size the pager to the tab box.
---
--- The closures resolve via `tonumber(self.subCategoryPaging.texts[state])`
--- rather than `subCategoryPaging:getState()` directly because `.texts`
--- is the authoritative visible-index-to-semantic-index map - needed so
--- highlight stays correct if tab visibility ever becomes dynamic.
function RLMenuSettingsFrame:initializeSubCategoryPages()
    Log:debug("RLMenuSettingsFrame:initializeSubCategoryPages: binding %d tab(s)",
        #self.subCategoryTabs)

    local subCategories = {}

    for index, button in ipairs(self.subCategoryTabs) do
        -- Tab Button's highlight (outer click surface)
        button.getIsSelected = function()
            return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
        end

        -- Tab background ThreePartBitmap (renders the selected/unselected slices)
        local bg = button:getDescendantByName("background")
        if bg ~= nil then
            bg.getIsSelected = function()
                return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
            end
        else
            Log:warning("RLMenuSettingsFrame:initializeSubCategoryPages: tab %d missing 'background' descendant",
                index)
        end

        table.insert(subCategories, tostring(index))
    end

    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(subCategories)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)
end

--- Pager state-change callback (XML onClick on subCategoryPaging). Resolves
--- visible state to a semantic index via .texts and toggles pane visibility.
--- Nil-guards the .texts lookup - the map is briefly out-of-sync with the
--- state during setTexts, and an early return keeps the pane set stable.
---
--- P1-2 tails: one-shot first-visibility measure log for the Filters pane
--- (size is only reliable after the pane becomes visible and layout has
--- settled) + a footer rebuild so the New filter button appears/disappears
--- in lockstep with the active subtab.
--- @param state number The paging state index (1..#texts)
function RLMenuSettingsFrame:updateSubCategoryPages(state)
    local idx = tonumber(self.subCategoryPaging.texts[state])
    if idx == nil then
        Log:trace("RLMenuSettingsFrame:updateSubCategoryPages: state=%s resolved to nil idx, skipping",
            tostring(state))
        return
    end

    Log:debug("RLMenuSettingsFrame:updateSubCategoryPages: state=%d idx=%d", state, idx)

    for index, page in ipairs(self.subCategoryPages) do
        page:setVisible(index == idx)
    end

    -- First-visibility measure log. One-shot per frame-open cycle so the
    -- log doesn't spam on every subtab click. Measures after the visibility
    -- toggle above so the layout engine has settled the stretched size.
    -- Guards on size[1] / size[2] nil: a profile-driven stretch can leave
    -- the table present but component axes nil until the next layout pass.
    if idx == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and not self.didMeasureFiltersPane
       and self.filtersListContainer ~= nil
       and self.filtersListContainer.size ~= nil
       and self.filtersListContainer.size[1] ~= nil
       and self.filtersListContainer.size[2] ~= nil then
        Log:debug("RLMenuSettingsFrame: filtersListContainer measured: %.2fpx x %.2fpx",
            self.filtersListContainer.size[1] * 1920,
            self.filtersListContainer.size[2] * 1080)
        self.didMeasureFiltersPane = true
    end

    -- Rebuild the footer menu buttons so New filter appears only on
    -- [Filters] with farm + tradeAnimals; [General] collapses to Back.
    self:updateButtonVisibility()

    -- Focus shift on subtab change. On [Filters] focus lands on the list
    -- so gamepad/keyboard users can immediately arrow through rows;
    -- on [General] focus returns to the tab bar (empty pane, no list).
    -- Matches the linkElements + setFocus pattern used across Info/Buy/
    -- Sell/Move/AI frames.
    if idx == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS and self.filtersList ~= nil then
        FocusManager:setFocus(self.filtersList)
    elseif self.subCategoryPaging ~= nil then
        FocusManager:setFocus(self.subCategoryPaging)
    end
end

--- XML onClick handler for the [General] tab button.
function RLMenuSettingsFrame:onClickGeneralTab()
    Log:trace("RLMenuSettingsFrame:onClickGeneralTab")
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)
end

--- XML onClick handler for the [Filters] tab button.
function RLMenuSettingsFrame:onClickFiltersTab()
    Log:trace("RLMenuSettingsFrame:onClickFiltersTab")
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.FILTERS, true)
end

-- =============================================================================
-- Filter list: data + lifecycle
-- =============================================================================

--- Pull filter rows from the service for the local player's farm and
--- reload the SmoothList. Rebuilds empty-state, footer buttons, and
--- re-resolves the id-authoritative selection against the new rows.
function RLMenuSettingsFrame:refreshData()
    local farmId
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    self.farmId = farmId

    local hasFarm = (farmId ~= nil and farmId ~= 0)
    if hasFarm and g_rlFilterService ~= nil then
        -- animalType=nil: settings UI is type-agnostic.
        -- farmId=localFarmId: nil-or-equal returns globals + own-farm only,
        -- never other farms' per-farm filters.
        self.rows = g_rlFilterService:listAvailable(nil, farmId)
    else
        self.rows = {}
    end

    Log:debug("RLMenuSettingsFrame:refreshData: farmId=%s rows=%d",
        tostring(farmId), #self.rows)

    -- isReconciling gate: reloadData synchronously fires onListSelectionChanged
    -- via SmoothList's setSelectedItem(..., true) after clamping; block the
    -- delegate from overwriting selectedFilterId mid-flight. resolveSelectionById
    -- also calls setSelectedIndex which re-enters the delegate; same gate.
    self.isReconciling = true
    if self.filtersList ~= nil then
        self.filtersList:reloadData()
    end
    self:resolveSelectionById()
    self.isReconciling = false

    self:updateEmptyState()
    self:updateButtonVisibility()
end

--- Refresh only when the frame is currently open. Called by the three
--- RLFilter*Event:run handlers so remote create/update/delete mutations
--- rerender the list without requiring the user to reopen the menu.
function RLMenuSettingsFrame:refreshIfOpen()
    if self.isFrameOpen then
        Log:debug("RLMenuSettingsFrame:refreshIfOpen: refreshing")
        self:refreshData()
    else
        Log:debug("RLMenuSettingsFrame:refreshIfOpen: frame closed, skipping")
    end
end

--- Id-authoritative selection. Walks self.rows for self.selectedFilterId
--- and re-derives list.selectedIndex; clears the cached id (and the list
--- selection) if the id is no longer present. Called from refreshData so
--- undefined pairs-order reloads never silently desync the highlighted
--- row from the cached id that P1-3's editor will consume.
function RLMenuSettingsFrame:resolveSelectionById()
    if self.filtersList == nil then return end

    if self.selectedFilterId == nil then
        -- Clear both fields (not just selectedIndex) to match the Info
        -- frame clear pattern. SmoothList expects numeric indices; nil
        -- would crash. The null branch is not a state transition, log
        -- at TRACE.
        self.filtersList.selectedSectionIndex = 0
        self.filtersList.selectedIndex = 0
        Log:trace("RLMenuSettingsFrame:resolveSelectionById: no id cached, cleared")
        return
    end

    for i, row in ipairs(self.rows) do
        if row.id == self.selectedFilterId then
            self.filtersList:setSelectedIndex(i)
            Log:debug("RLMenuSettingsFrame:resolveSelectionById: id=%s resolved to index=%d",
                tostring(self.selectedFilterId), i)
            return
        end
    end

    Log:debug("RLMenuSettingsFrame:resolveSelectionById: id=%s no longer in rows, clearing",
        tostring(self.selectedFilterId))
    self.selectedFilterId = nil
    self.filtersList.selectedSectionIndex = 0
    self.filtersList.selectedIndex = 0
end

--- Toggle the branched empty-state text + list/slider visibility. Branches
--- the empty-state copy on whether the player has a farm at all; mirrors
--- the Messages frame pattern.
function RLMenuSettingsFrame:updateEmptyState()
    local hasRows = #self.rows > 0
    local hasFarm = (self.farmId ~= nil and self.farmId ~= 0)
    Log:debug("RLMenuSettingsFrame:updateEmptyState: hasFarm=%s hasRows=%s",
        tostring(hasFarm), tostring(hasRows))

    if self.filtersEmptyState ~= nil then
        if not hasFarm then
            self.filtersEmptyState:setText(g_i18n:getText("rl_menu_filters_empty_no_farm"))
        else
            self.filtersEmptyState:setText(g_i18n:getText("rl_menu_filters_empty"))
        end
        self.filtersEmptyState:setVisible(not hasRows)
    end

    if self.filtersList ~= nil then
        self.filtersList:setVisible(hasRows)
    end

    -- Toggle the slider box alongside the list so the empty states don't
    -- leave an orphaned scrollbar next to the "No saved filters" / "You
    -- need a farm" text. Honors the spec's "slider box visibility follows
    -- the list" contract explicitly rather than relying on layout.
    if self.filtersSliderBox ~= nil then
        self.filtersSliderBox:setVisible(hasRows)
    end
end

--- Rebuild the footer menu button array. Back is always present; New filter
--- joins only when the active subtab is [Filters] AND the player has a farm
--- AND they hold the tradeAnimals permission. setMenuButtonInfoDirty so
--- TabbedMenu re-renders the footer on the next tick.
function RLMenuSettingsFrame:updateButtonVisibility()
    local activeSubtab
    if self.subCategoryPaging ~= nil then
        activeSubtab = self.subCategoryPaging:getState()
    end
    local hasFarm = (self.farmId ~= nil and self.farmId ~= 0)
    local hasPerm = self:hasCreatePermission()

    Log:debug("RLMenuSettingsFrame:updateButtonVisibility: subtab=%s hasFarm=%s hasPerm=%s",
        tostring(activeSubtab), tostring(hasFarm), tostring(hasPerm))

    self.menuButtonInfo = { self.backButtonInfo }
    if activeSubtab == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and hasFarm
       and hasPerm then
        table.insert(self.menuButtonInfo, self.newFilterButtonInfo)
    end
    self:setMenuButtonInfoDirty()
end

--- UX-side permission gate for New filter. The authoritative boundary is
--- the server-side validation inside RLFilter{Create,Update,Delete}Event:run
--- (plan §4.10); this check only controls button visibility and the early
--- abort in onClickNewFilter. Mirrors RLMenuMessagesFrame:hasDeletePermission
--- with "updateFarm" swapped for "tradeAnimals".
function RLMenuSettingsFrame:hasCreatePermission()
    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        return false
    end
    return g_currentMission:getHasPlayerPermission("tradeAnimals") == true
end

-- =============================================================================
-- Filter list: create handler
-- =============================================================================

--- Disambiguated default name so repeated [New filter] clicks don't produce
--- N identical rows while the P1-3 editor is still in flight. Base is the
--- localized "New filter" string; the " (N)" suffix is numeric so locales
--- can keep the base and get a universal index. "New filter", "New filter (2)",
--- "New filter (3)" in English.
--- @return string
function RLMenuSettingsFrame:computeDefaultFilterName()
    local base = g_i18n:getText("rl_menu_filters_default_name")
    -- Match "<base> (N)" where N is one or more digits, anchored end-to-end
    -- (Lua patterns: %( and %) are literal parens, (%d+) captures digits).
    local pattern = "^" .. base:gsub("(%W)", "%%%1") .. " %((%d+)%)$"
    local count = 0
    for _, row in ipairs(self.rows) do
        local name = row.name or ""
        if name == base or name:match(pattern) then
            count = count + 1
        end
    end
    local result
    if count == 0 then
        result = base
    else
        result = string.format("%s (%d)", base, count + 1)
    end
    Log:trace("RLMenuSettingsFrame:computeDefaultFilterName: base='%s' count=%d result='%s'",
        base, count, result)
    return result
end

--- Footer New filter handler. Creates a placeholder filter scoped to the
--- local farm with an empty AND expression (vacuous-true per plan §4.3),
--- sets selectedFilterId so refreshData auto-selects the new row via
--- resolveSelectionById, then refreshes.
---
--- Nil-guard on create(): service returns nil on malformed input (programming
--- error, service-side contract at RLFilterService.lua:162-165). Remote
--- MP-rejection rollback is out of scope per RLRM-182 / RLRM-183.
function RLMenuSettingsFrame:onClickNewFilter()
    if not self:hasCreatePermission() then
        Log:trace("RLMenuSettingsFrame:onClickNewFilter: no tradeAnimals permission, aborting")
        return
    end
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSettingsFrame:onClickNewFilter: no farm, aborting")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onClickNewFilter: g_rlFilterService is nil; aborting")
        return
    end

    local name = self:computeDefaultFilterName()
    Log:debug("RLMenuSettingsFrame:onClickNewFilter: creating filter name='%s' farmId=%s",
        name, tostring(self.farmId))

    local created = g_rlFilterService:create({
        name       = name,
        animalType = nil,
        farmId     = self.farmId,
        expression = { op = "AND", children = {} },
    })
    if created == nil then
        Log:warning("RLMenuSettingsFrame:onClickNewFilter: service rejected create (nil return)")
        return
    end

    -- Set the id BEFORE refresh so resolveSelectionById auto-selects the
    -- new row without a separate walk.
    self.selectedFilterId = created.id
    Log:debug("RLMenuSettingsFrame:onClickNewFilter: created id=%s name='%s'",
        tostring(created.id), tostring(created.name))

    self:refreshData()
end

--- SmoothList delegate: fired when the user picks a different row. Gated
--- on the list identity so we don't confuse other SmoothLists in the host
--- TabbedMenu. Caches the row's filter id so P1-3's editor reads a stable
--- reference even if the row index drifts on the next reload.
--- @param list table The SmoothList instance asking
--- @param _section number Section index (single-section, ignored)
--- @param index number 1-based row index
function RLMenuSettingsFrame:onListSelectionChanged(list, _section, index)
    if list ~= self.filtersList then return end
    if index == nil then return end

    -- Suppress overwrite during reconciliation. refreshData's reloadData +
    -- resolveSelectionById both fire this delegate synchronously via
    -- SmoothList's clamp-and-notify + our own setSelectedIndex call. The
    -- id we'd capture under those paths is the post-clamp row's id, not
    -- the user's intent; the outer path already knows the correct id.
    if self.isReconciling then
        Log:trace("RLMenuSettingsFrame:onListSelectionChanged: suppressed during reconcile (index=%s)",
            tostring(index))
        return
    end

    local row = self.rows[index]
    if row == nil then
        self.selectedFilterId = nil
        Log:debug("RLMenuSettingsFrame:onListSelectionChanged: index=%s out of range, cleared",
            tostring(index))
        return
    end

    self.selectedFilterId = row.id
    Log:debug("RLMenuSettingsFrame:onListSelectionChanged: index=%d id=%s",
        index, tostring(row.id))
end

-- =============================================================================
-- SmoothList data source protocol
--
-- Deliberately NOT logged. SmoothList calls these at draw frequency; tracing
-- them would swamp the log. refreshData + updateEmptyState + the selection
-- path are already logged and cover the render lifecycle.
-- =============================================================================

--- How many items the list should render (single-section flat list).
--- @param list table
--- @param _section number Ignored
--- @return number
function RLMenuSettingsFrame:getNumberOfItemsInSection(list, _section)
    if list == self.filtersList then
        return #self.rows
    end
    return 0
end

--- Populate one data cell from the row at the given index.
--- @param list table
--- @param _section number Ignored
--- @param index number 1-based row index
--- @param cell table The ListItem cell to populate
function RLMenuSettingsFrame:populateCellForItemInSection(list, _section, index, cell)
    if list ~= self.filtersList then return end

    local row = self.rows[index]
    if row == nil then return end

    local nameCell = cell:getAttribute("filterName")
    if nameCell ~= nil then
        nameCell:setText(row.name or "")
    end
end
