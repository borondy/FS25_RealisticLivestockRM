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
    -- [New filter] is parked (visible-but-greyed) until the filter editor
    -- ships in a future phase. Setting `disabled = true` greys the button
    -- in the footer; nulling the callback is defense-in-depth so the action
    -- is fully inert. The onClickNewFilter method is retained for the
    -- unparking restore later.
    self.newFilterButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_filters_new_button"),
        callback = nil,
        disabled = true,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    -- General subtab control registry. Keyed by RLSettings.SETTINGS name;
    -- value is the BinaryOption/MultiTextOption/Button widget. Tooltip
    -- child Text refs live in self.tooltips[name]. Both populated by
    -- populateGeneralSubtab() during initialize() (per-clone, one-shot).
    -- The new page deliberately does NOT touch RLSettings.SETTINGS[*].element
    -- - that ref belongs to the legacy in-game settings page and the
    -- RL_BroadcastSettingsEvent path. Each page owns its own widget refs.
    self.controls          = {}
    self.tooltips          = {}
    self.didMeasureGeneralPane = false

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
--- live clone (not the original) after registerPage. Populates the
--- General subtab's settings rows (look up XML element refs, set option
--- texts, register controls). Tree mutation forbidden in onGuiSetupFinished
--- (fires on both original and clone) so we do it here.
---
--- Per-row state push (setState) and cascade run on every onFrameOpen via
--- refreshGeneralSubtab(); this initialize() handles the once-per-clone
--- bindings only.
function RLMenuSettingsFrame:initialize()
    Log:debug("RLMenuSettingsFrame:initialize")
    self:populateGeneralSubtab()
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
    -- Reset the first-visibility measure flags so the runtime-measure logs
    -- fire once per frame-open cycle (Filters one-shot in updateSubCategoryPages,
    -- General one-shot below).
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)
    self.didMeasureFiltersPane = false
    self.didMeasureGeneralPane = false

    -- Push current RLSettings state into General subtab widgets and run
    -- the per-row admin gate + dependency cascade. State may have changed
    -- between opens (legacy page edit, MP broadcast); re-read every time.
    self:refreshGeneralSubtab()

    -- One-shot first-visibility measure log for the General layout. Mirrors
    -- the Filters pane measure at updateSubCategoryPages line 244-254 - GUI
    -- positioning is computed from profiles but VERIFIED with runtime
    -- measurement before iterating (session rule 4). nil-guards on .size /
    -- size[1] / size[2] cover the case where a stretched layout is briefly
    -- present without committed axes until the next layout pass.
    local genLayout = self:getDescendantById("generalSettingsLayout")
    if genLayout ~= nil and genLayout.size ~= nil
       and genLayout.size[1] ~= nil and genLayout.size[2] ~= nil
       and not self.didMeasureGeneralPane then
        Log:debug("RLMenuSettingsFrame: generalSettingsLayout measured: %.2fpx x %.2fpx",
            genLayout.size[1] * 1920, genLayout.size[2] * 1080)
        self.didMeasureGeneralPane = true
    end

    -- Tint each visible row container with an alternating dark shade so the
    -- light-cream row title text reads against a dark backing. Without this,
    -- rows fall back to the default white tint of `gui.colorPreset` from the
    -- baseReference profile and titles are invisible on the new menu chrome.
    -- Runs AFTER refreshGeneralSubtab so the per-row disabled cascade has
    -- settled.
    self:updateAlternatingElements(genLayout)

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

--- Apply an alternating dark tint to each visible row container in the
--- given ScrollingLayout so the light-cream row title text reads against a
--- dark backing. Walks `layout.elements` in source order:
---   - elements named "sectionHeader" (our 20px gap spacers) reset the
---     alternation flag so each section restarts at the darker shade.
---   - other visible elements get tinted via setImageColor(nil, r, g, b, a)
---     with the rgba pulled at runtime from the
---     `InGameMenuSettingsFrame.COLOR_ALTERNATING` runtime global. The flag
---     toggles after each tint so adjacent rows alternate.
---   - hidden elements are skipped entirely (no toggle, no tint).
--- Disabled rows (e.g. dependency-cascade greyed) are still tinted; the
--- disabled-state styling is a separate channel layered on top.
--- @param layout table The ScrollingLayout whose child elements to tint
function RLMenuSettingsFrame:updateAlternatingElements(layout)
    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: enter")

    if layout == nil or layout.elements == nil then
        Log:warning("RLMenuSettingsFrame:updateAlternatingElements: layout or layout.elements is nil; skipping tint pass (rows will remain unreadable)")
        return
    end

    local colorTable = InGameMenuSettingsFrame ~= nil and InGameMenuSettingsFrame.COLOR_ALTERNATING or nil
    if colorTable == nil or colorTable[true] == nil or colorTable[false] == nil then
        Log:warning("RLMenuSettingsFrame:updateAlternatingElements: InGameMenuSettingsFrame.COLOR_ALTERNATING unavailable; skipping tint pass (rows will remain unreadable)")
        return
    end

    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: layout id=%s, %d child element(s)",
        tostring(layout.id), #layout.elements)

    local alternate = true
    local tintedCount = 0
    local resetCount = 0

    -- ipairs (not pairs) so traversal follows authored XML order strictly.
    -- Section reset and parity toggle both depend on positional order.
    for _, row in ipairs(layout.elements) do
        if row.name == "sectionHeader" then
            alternate = true
            resetCount = resetCount + 1
        elseif row.visible and row.setImageColor ~= nil then
            row:setImageColor(nil, unpack(colorTable[alternate]))
            alternate = not alternate
            tintedCount = tintedCount + 1
        end
    end

    layout:invalidateLayout()
    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: tinted=%d resets=%d", tintedCount, resetCount)
    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: exit")
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

    -- [New filter] is parked: visible-but-greyed on Filters subtab regardless
    -- of farm / tradeAnimals permission. The button info already has
    -- disabled=true + callback=nil set at construction, so the gate that
    -- previously skipped the append for non-permitted players is dropped
    -- here. hasFarm / hasPerm are still computed and logged so an unparking
    -- restore (re-introducing the gate) lands trivially.
    self.menuButtonInfo = { self.backButtonInfo }
    if activeSubtab == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS then
        Log:trace("RLMenuSettingsFrame:updateButtonVisibility: appending parked [New filter] button (disabled=true) hasFarm=%s hasPerm=%s",
            tostring(hasFarm), tostring(hasPerm))
        table.insert(self.menuButtonInfo, self.newFilterButtonInfo)
    end
    self:setMenuButtonInfoDirty()
end

--- UX-side permission gate for New filter. The authoritative boundary is
--- the server-side validation inside RLFilter{Create,Update,Delete}Event:run;
--- this check only controls button visibility and the early
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
--- N identical rows while the inline editor is still in flight. Base is the
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
--- local farm with an empty AND expression (vacuous-true),
--- sets selectedFilterId so refreshData auto-selects the new row via
--- resolveSelectionById, then refreshes.
---
--- Nil-guard on create(): service returns nil on malformed input (programming
--- error, service-side contract at RLFilterService.lua:162-165). Remote
--- MP-rejection rollback is deferred to a future iteration.
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

-- =============================================================================
-- General subtab: populate, refresh, cascade, click dispatch
-- =============================================================================

--- Build the per-row option-text arrays a state-row widget needs:
---   binaryType=offOn -> {"Off", "On"} (localized)
---   valueType=int    -> { "20", "30", "40", ... }
---   valueType=float  -> { "0%", "10%", "20%", ... }
---   else             -> l10n keys "rl_settings_<name>_texts_<i>"
--- Mirrors RLSettings.initialize:425-443 - same source of truth.
--- @param name string Setting key in RLSettings.SETTINGS
--- @param setting table The setting entry
--- @return table The texts array indexed by state
local function buildSettingTexts(name, setting)
    local texts = {}
    local prefix = "rl_settings_" .. name .. "_"

    if setting.binaryType == "offOn" then
        texts[1] = g_i18n:getText("rl_settings_off")
        texts[2] = g_i18n:getText("rl_settings_on")
    else
        for i, value in pairs(setting.values) do
            if setting.valueType == "int" then
                texts[i] = tostring(value)
            elseif setting.valueType == "float" then
                texts[i] = string.format("%.0f%%", value * 100)
            else
                texts[i] = g_i18n:getText(prefix .. "texts_" .. i)
            end
        end
    end

    return texts
end

--- One-shot per-clone wiring of the General subtab. Looks up each row's
--- widget via getDescendantById, builds option-text arrays for state rows,
--- and stores element + tooltip refs in self.controls / self.tooltips.
--- onClick attributes already wire each widget to the instance methods
--- (onClickGeneralSetting / onClickGeneralAction) at XML load time, so no
--- manual binding is needed.
---
--- Logs Log:error and bails (loud, not silent) if generalSettingsLayout is
--- missing. Per-row missing widgets log Log:warning and are skipped; refresh
--- subsequently no-ops on the missing entry.
function RLMenuSettingsFrame:populateGeneralSubtab()
    Log:debug("RLMenuSettingsFrame:populateGeneralSubtab: enter")

    local layout = self:getDescendantById("generalSettingsLayout")
    if layout == nil then
        Log:error("RLMenuSettingsFrame:populateGeneralSubtab: generalSettingsLayout missing from XML; General subtab will be empty")
        return
    end

    local count = 0
    for name, setting in pairs(RLSettings.SETTINGS) do
        local widget = self:getDescendantById("rlmenuSetting_" .. name)
        if widget == nil then
            Log:warning("RLMenuSettingsFrame:populateGeneralSubtab: widget rlmenuSetting_%s missing", name)
        else
            self.controls[name] = widget

            local tooltip = widget:getDescendantByName("tooltip")
            if tooltip == nil then
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: '%s' has no tooltip child", name)
            else
                self.tooltips[name] = tooltip
            end

            -- Stateful rows need their option-text arrays populated; action
            -- rows (setting.ignore == true) keep the static $l10n_..._text
            -- already set in XML.
            if not setting.ignore then
                widget:setTexts(buildSettingTexts(name, setting))
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: bound state row '%s'", name)
            else
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: bound action row '%s'", name)
            end

            -- Static tooltip text: write once at populate so action rows
            -- (which refreshGeneralSubtab skips) get tooltip text too. Dynamic
            -- tooltips for state rows seed at the default state here and are
            -- updated per-state in refreshGeneralSubtab. Mirrors legacy
            -- RLSettings.initialize:448-452 ordering.
            if tooltip ~= nil then
                local tooltipKey
                if setting.dynamicTooltip then
                    local seedState = setting.state or setting.default
                    tooltipKey = "rl_settings_" .. name .. "_tooltip_" .. seedState
                else
                    tooltipKey = "rl_settings_" .. name .. "_tooltip"
                end
                tooltip:setText(g_i18n:getText(tooltipKey))
            end

            count = count + 1
        end
    end

    -- Aggregate sanity check: did we bind every setting? Per-row missing
    -- widget already logs Log:warning, but the totals make a partial-bind
    -- (XML drift, renamed setting, etc.) loud at a glance.
    local expected = 0
    for _ in pairs(RLSettings.SETTINGS) do expected = expected + 1 end
    if count ~= expected then
        Log:warning("RLMenuSettingsFrame:populateGeneralSubtab: bound %d/%d rows; XML/SETTINGS drift?", count, expected)
    else
        Log:debug("RLMenuSettingsFrame:populateGeneralSubtab: bound %d/%d row(s)", count, expected)
    end
end

--- Push current RLSettings state into widgets, refresh tooltip text
--- (static or dynamic per setting.dynamicTooltip), then re-run the
--- dependency cascade. Called from onFrameOpen() and from refreshIfGeneralOpen()
--- after MP broadcasts. Click handlers also call this after delegating to
--- RLSettings.applyChange so the widget reflects whatever state.callback
--- side effects produced.
---
--- setState uses forceEvent=false to avoid re-entering onClickGeneralSetting
--- during the programmatic push.
function RLMenuSettingsFrame:refreshGeneralSubtab()
    Log:debug("RLMenuSettingsFrame:refreshGeneralSubtab: enter")

    for name, setting in pairs(RLSettings.SETTINGS) do
        local widget = self.controls[name]
        if widget ~= nil and not setting.ignore then
            local state = setting.state or setting.default
            widget:setState(state, false)

            local tooltip = self.tooltips[name]
            if tooltip ~= nil then
                local key
                if setting.dynamicTooltip then
                    key = "rl_settings_" .. name .. "_tooltip_" .. state
                else
                    key = "rl_settings_" .. name .. "_tooltip"
                end
                tooltip:setText(g_i18n:getText(key))
            end
        end
    end

    self:updateReadonlyState()
end

--- Per-row admin gate + dependency cascade. Operates on self.controls
--- (this frame's element registry), not on the legacy setting.element ref.
--- Per-row admin gating, not blanket non-admin disable: only rows flagged
--- setting.adminOnly==true are disabled for non-admins; the rest stay
--- enabled with their dependency cascade applied.
---
--- Admin check: g_server ~= nil OR g_currentMission.isMasterUser == true.
function RLMenuSettingsFrame:updateReadonlyState()
    local isAdmin = (g_server ~= nil) or (g_currentMission ~= nil and g_currentMission.isMasterUser == true)
    Log:trace("RLMenuSettingsFrame:updateReadonlyState: isAdmin=%s", tostring(isAdmin))

    for name, setting in pairs(RLSettings.SETTINGS) do
        local widget = self.controls[name]
        if widget ~= nil then
            local disabled = false

            if setting.adminOnly and not isAdmin then
                disabled = true
            elseif setting.dependancy ~= nil then
                local parent = RLSettings.SETTINGS[setting.dependancy.name]
                if parent ~= nil then
                    local parentState = parent.state or parent.default
                    disabled = (parentState ~= setting.dependancy.state)
                end
            end

            widget:setDisabled(disabled)
            Log:trace("RLMenuSettingsFrame:updateReadonlyState: '%s' disabled=%s", name, tostring(disabled))
        end
    end
end

--- Refresh the General subtab if the frame is open. Called from
--- RL_BroadcastSettingsEvent:run after the legacy element sync so the new
--- page reflects MP-synced state changes without requiring frame reopen.
--- No-op when the frame is closed - matches the refreshIfOpen convention
--- used by the filter-event hooks elsewhere on this branch.
function RLMenuSettingsFrame:refreshIfGeneralOpen()
    if not self.isFrameOpen then
        Log:trace("RLMenuSettingsFrame:refreshIfGeneralOpen: frame closed, skipping")
        return
    end
    Log:debug("RLMenuSettingsFrame:refreshIfGeneralOpen: frame open, refreshing")
    self:refreshGeneralSubtab()
end

--- XML onClick handler for state rows (BinaryOption / MultiTextOption).
--- Extracts the setting name from the widget's id (rlmenuSetting_<name>),
--- delegates to RLSettings.applyChange (single write path shared with the
--- legacy in-game settings page), then refreshes our widgets so the cascade
--- and dynamic-tooltip state stay current.
---
--- The colon syntax binds `self` implicitly; the GUI loader's raiseCallback
--- chain raises onClickCallback for state-row widgets with
--- (target, state, widget, isLeftButtonEvent), and target arrives as `self`
--- here. So the explicit args are (state, widget) - state is the post-click
--- state index, widget is the BinaryOption/MultiTextOption that was clicked.
---
--- Defensive `widget == nil then widget = state` mirrors RLSettings.onSettingChanged
--- so an accidental cross-wire from a Button (which raises with only
--- (target, widget)) still resolves to a sensible widget reference for
--- the early-return guard below; the ignore-flag check then redirects.
--- @param state number 1-based new state from the widget post-click
--- @param widget table The widget that was clicked
function RLMenuSettingsFrame:onClickGeneralSetting(state, widget)
    if widget == nil then widget = state end
    -- type-check after the shuffle: if `state` was passed as a number (the
    -- documented MultiTextOption case where only state arrives without
    -- widget), the shuffle would otherwise leave `widget` as a number and
    -- the next line would crash on `widget.id`.
    if type(widget) ~= "table" or widget.id == nil then return end

    local name = widget.id:match("^rlmenuSetting_(.+)$")
    if name == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralSetting: id '%s' did not match rlmenuSetting_<name>", tostring(widget.id))
        return
    end

    local setting = RLSettings.SETTINGS[name]
    if setting == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralSetting: unknown setting '%s'", name)
        return
    end
    if setting.ignore then
        Log:warning("RLMenuSettingsFrame:onClickGeneralSetting: '%s' is an action row; misrouted click", name)
        return
    end

    -- The widget already advanced its own state on click; read off the
    -- widget for safety (the state arg is also the new value for
    -- MultiTextOption-derived elements per their raiseCallback chain).
    local newState = widget:getState()
    Log:debug("RLMenuSettingsFrame:onClickGeneralSetting: name='%s' newState=%d", name, newState)

    RLSettings.applyChange(name, newState)
    self:refreshGeneralSubtab()
end

--- XML onClick handler for action rows (Button). Resolves the setting name
--- from the button's id and invokes its setting.callback - same handler
--- the legacy in-game page wires for the same buttons (RLSettings.initialize:457
--- registers RLSettings.onSettingChanged which routes ignored buttons to
--- setting.callback() with no args).
---
--- ButtonElement.raiseCallback delivers two args (`target, button`), so
--- the colon-bound `self` absorbs the target and the explicit `button`
--- arg lands at the right slot.
---
--- No state mutation, no cascade refresh - actions are fire-and-forget
--- (open dialog / export / reset).
--- @param button table The Button widget that was clicked
function RLMenuSettingsFrame:onClickGeneralAction(button)
    if button == nil or button.id == nil then return end

    local name = button.id:match("^rlmenuSetting_(.+)$")
    if name == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: id '%s' did not match rlmenuSetting_<name>", tostring(button.id))
        return
    end

    local setting = RLSettings.SETTINGS[name]
    if setting == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: unknown setting '%s'", name)
        return
    end
    if not setting.ignore then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: '%s' is a state row; misrouted click", name)
        return
    end
    if setting.callback == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: '%s' has no callback registered", name)
        return
    end

    Log:debug("RLMenuSettingsFrame:onClickGeneralAction: invoking callback for '%s'", name)
    setting.callback()
end
