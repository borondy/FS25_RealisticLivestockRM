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

--- Sentinel marking an explicit "clear to Any" in the pendingChanges overlay
--- for the animalType field. Lua removes nil values from tables, so
--- pendingChanges[id].animalType = nil is indistinguishable from "no pending
--- change". A unique-table marker lets overlayPending distinguish three states:
---   (a) no pending change          (overlay.animalType == nil)
---   (b) pending change to concrete (overlay.animalType is an integer typeIndex)
---   (c) pending change to Any      (overlay.animalType == ANIMAL_TYPE_ANY)
--- Flush converts the sentinel back to nil before service:update so storage
--- + wire never see it. Mirrors Fresh's MAXBENEFIT_CLEAR pattern.
RLMenuSettingsFrame.ANIMAL_TYPE_ANY = {}

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

    -- P1-3 editor pane measure log flag. Once-per-process (NOT once-per-open):
    -- RLMenuSettingsFrame.new() runs once at setupGui() time and the clone is
    -- reused across every menu open (RLMenu.lua:88-138). Pane geometry doesn't
    -- change after first measurement so measuring once is sufficient.
    self.didMeasureEditorPane = false

    -- Pending-changes overlay keyed by filter id. Each value is a partial
    -- table {name?=string, animalType?=integer|ANIMAL_TYPE_ANY, op?="AND"|"OR",
    -- usage?=string (canonical RLFilterUsage value)}. Widget callbacks write
    -- into this; service:update is NOT called per keystroke.
    -- flushPendingChanges drains the table on onFrameClose. The per-id
    -- sub-table is created lazily on first write. Unlike animalType, the
    -- usage axis is a 3-state enum where every state has a canonical string
    -- value, so no sentinel is needed - absence-of-key means "no change",
    -- presence means "change to this value".
    self.pendingChanges = {}

    -- AnimalType selector state cache. Populated by seedAnimalTypeStates on
    -- every renderEditor call (cheap, ~5-10 types). Each entry is
    -- {label=string, typeIndex=integer|nil}; index 1 is always the "Any" row
    -- with typeIndex=nil.
    self.animalTypeStates = {}

    -- Custom footer buttons: Back always; New filter + Duplicate + Delete
    -- conditionally appended by updateButtonVisibility.
    -- hasCustomMenuButtons=true forces the first page-switch to use
    -- self.menuButtonInfo rather than RLMenu's default back-only set,
    -- preventing a one-frame flicker.
    self.hasCustomMenuButtons = true

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
    }
    -- [New filter] unparked in P1-3. Callback wired to the live handler
    -- shipped in P1-2 (onClickNewFilter). Visibility gated by
    -- updateButtonVisibility on tradeAnimals permission + farmId presence.
    self.newFilterButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_filters_new_button"),
        callback = function() self:onClickNewFilter() end,
    }
    -- [Duplicate] clones the currently selected filter (overlay-merged so
    -- in-flight edits are duplicated too). MENU_EXTRA_2 is the conventional
    -- second extra slot; mirrors RLMenuMessagesFrame's deleteAllButtonInfo
    -- usage pattern.
    self.duplicateButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_menu_filters_duplicate_button"),
        callback = function() self:onClickDuplicate() end,
    }
    -- [Delete] prompts YesNoDialog then dispatches service:delete on Yes.
    -- MENU_CANCEL keeps the destructive action on the cancel/red slot,
    -- matching RLMenuMessagesFrame.lua:41 convention.
    self.deleteButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_filters_delete_button"),
        callback = function() self:onClickDelete() end,
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

    -- Cache editor widget refs (P1-3). getDescendantById walks the tree once
    -- here so renderEditor / flushPendingChanges / widget callbacks can hit
    -- direct field references without repeating the descend on every call.
    -- Per-widget nil-guards downstream: any missing ref logs Log:warning and
    -- skips that widget rather than crashing the frame.
    self.filterEditorContainer  = self:getDescendantById("filterEditorContainer")
    self.filterEditorEmpty      = self:getDescendantById("filterEditorEmpty")
    self.filterEditorLayout     = self:getDescendantById("filterEditorLayout")
    self.filterEditorSliderBox  = self:getDescendantById("filterEditorSliderBox")
    self.filterNameInput        = self:getDescendantById("filterNameInput")
    self.filterAnimalTypeSelector = self:getDescendantById("filterAnimalTypeSelector")
    self.filterOpSelector       = self:getDescendantById("filterOpSelector")
    self.filterUsageSelector    = self:getDescendantById("filterUsageSelector")

    local missing = {}
    if self.filterEditorContainer  == nil then table.insert(missing, "filterEditorContainer")  end
    if self.filterEditorEmpty      == nil then table.insert(missing, "filterEditorEmpty")      end
    if self.filterEditorLayout     == nil then table.insert(missing, "filterEditorLayout")     end
    if self.filterEditorSliderBox  == nil then table.insert(missing, "filterEditorSliderBox")  end
    if self.filterNameInput        == nil then table.insert(missing, "filterNameInput")        end
    if self.filterAnimalTypeSelector == nil then table.insert(missing, "filterAnimalTypeSelector") end
    if self.filterOpSelector       == nil then table.insert(missing, "filterOpSelector")       end
    if self.filterUsageSelector    == nil then table.insert(missing, "filterUsageSelector")    end
    if #missing > 0 then
        Log:warning("RLMenuSettingsFrame:onGuiSetupFinished: editor widget(s) missing: %s",
            table.concat(missing, ", "))
    else
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: editor widgets cached (8/8)")
    end

    -- Seed the AND/OR op selector texts once at setup (static, locale-baked
    -- at l10n load time). AnimalType selector is reseeded per renderEditor
    -- because it depends on animal-system state.
    if self.filterOpSelector ~= nil then
        self.filterOpSelector:setTexts({
            g_i18n:getText("rl_menu_filters_op_and"),
            g_i18n:getText("rl_menu_filters_op_or"),
        })
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: filterOpSelector texts set (AND/OR)")
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

    -- P1-3 editor focus chain: list <-> editor row 1 <-> row 2 <-> row 3.
    -- RIGHT/LEFT crosses the list-editor boundary; DOWN/UP chains within
    -- the editor AND falls through from list-bottom into the editor's
    -- Name input (so the full path tab -> list -> name -> animalType -> op
    -- works with DOWN arrow alone). Each link is nil-guarded so a missing
    -- widget downgrades cleanly to the partial chain (warning already
    -- logged in onGuiSetupFinished).
    if self.filtersList ~= nil and self.filterNameInput ~= nil then
        FocusManager:linkElements(self.filtersList,    FocusManager.RIGHT,  self.filterNameInput)
        FocusManager:linkElements(self.filterNameInput, FocusManager.LEFT,  self.filtersList)
        FocusManager:linkElements(self.filtersList,    FocusManager.BOTTOM, self.filterNameInput)
        FocusManager:linkElements(self.filterNameInput, FocusManager.TOP,   self.filtersList)
    end
    if self.filterNameInput ~= nil and self.filterAnimalTypeSelector ~= nil then
        FocusManager:linkElements(self.filterNameInput,         FocusManager.BOTTOM, self.filterAnimalTypeSelector)
        FocusManager:linkElements(self.filterAnimalTypeSelector, FocusManager.TOP,   self.filterNameInput)
    end
    if self.filterAnimalTypeSelector ~= nil and self.filterOpSelector ~= nil then
        FocusManager:linkElements(self.filterAnimalTypeSelector, FocusManager.BOTTOM, self.filterOpSelector)
        FocusManager:linkElements(self.filterOpSelector,         FocusManager.TOP,   self.filterAnimalTypeSelector)
    end
    if self.filterOpSelector ~= nil and self.filterUsageSelector ~= nil then
        FocusManager:linkElements(self.filterOpSelector,    FocusManager.BOTTOM, self.filterUsageSelector)
        FocusManager:linkElements(self.filterUsageSelector, FocusManager.TOP,    self.filterOpSelector)
    end
    Log:trace("RLMenuSettingsFrame:onFrameOpen: editor focus chain linked")

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
--- Clears isFrameOpen so refreshIfOpen becomes a no-op, then drains the
--- pendingChanges overlay to service:update.
---
--- Ordering invariant: isFrameOpen=false BEFORE flushPendingChanges. The
--- service dispatches RLFilterUpdateEvent on the server side after each
--- update; a remote rebroadcast arriving mid-flush would re-enter our
--- frame via refreshIfOpen and call refreshData() recursively, fighting
--- the flush loop. Clearing the flag first makes refreshIfOpen early-return
--- and closes the re-entry window.
function RLMenuSettingsFrame:onFrameClose()
    RLMenuSettingsFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    Log:debug("RLMenuSettingsFrame:onFrameClose")
    self:flushPendingChanges()
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

    -- P1-3 editor pane measure log. Once-per-process (NOT once-per-open) per
    -- spec F3 fix - frame instance is reused across reopens. Target dimensions
    -- ~1088 x 783 px (parent pane width minus the 410px left list). If the
    -- runtime measurement diverges materially from that target, the inline
    -- size="100% 100%" absoluteSizeOffset="-410px 0px" override on the
    -- filterEditorContainer isn't producing the expected stretch and the
    -- layout needs investigation (see Ask First in the spec).
    if idx == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and not self.didMeasureEditorPane
       and self.filterEditorContainer ~= nil
       and self.filterEditorContainer.size ~= nil
       and self.filterEditorContainer.size[1] ~= nil
       and self.filterEditorContainer.size[2] ~= nil then
        Log:debug("RLMenuSettingsFrame: filterEditorContainer measured: %.2fpx x %.2fpx",
            self.filterEditorContainer.size[1] * 1920,
            self.filterEditorContainer.size[2] * 1080)
        self.didMeasureEditorPane = true
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

    -- Alphabetical case-insensitive sort with stable id tie-break. Sort
    -- runs on refreshData boundaries only; mid-edit name callbacks do NOT
    -- re-sort (writes go to pendingChanges + reloadData reads the overlay
    -- in populateCellForItemInSection, keeping row positions stable while
    -- the user is typing).
    table.sort(self.rows, function(a, b)
        local an = (a.name or ""):lower()
        local bn = (b.name or ""):lower()
        if an == bn then
            return (a.id or "") < (b.id or "")
        end
        return an < bn
    end)

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

    -- Tail renderEditor so the right pane reflects the new selection (or
    -- the empty-state branch) every time the list refreshes. resolveSelectionById
    -- may have cleared self.selectedFilterId for an orphaned id; renderEditor
    -- handles that branch.
    self:renderEditor()
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

    -- P1-3 unpark: [New filter] gate restored. Only appended on [Filters]
    -- when the player has a farm AND the tradeAnimals permission. Duplicate
    -- and Delete additionally require a selection.
    local hasSelection = (self.selectedFilterId ~= nil)
    local appended = {}

    self.menuButtonInfo = { self.backButtonInfo }
    if activeSubtab == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and hasFarm and hasPerm then
        table.insert(self.menuButtonInfo, self.newFilterButtonInfo)
        table.insert(appended, "New")
        if hasSelection then
            table.insert(self.menuButtonInfo, self.duplicateButtonInfo)
            table.insert(self.menuButtonInfo, self.deleteButtonInfo)
            table.insert(appended, "Duplicate")
            table.insert(appended, "Delete")
        end
    end
    Log:debug("RLMenuSettingsFrame:updateButtonVisibility: appended=[%s] (hasFarm=%s hasPerm=%s hasSelection=%s)",
        table.concat(appended, ","), tostring(hasFarm), tostring(hasPerm), tostring(hasSelection))
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
        usage      = RLFilterUsage.ANY,
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

-- =============================================================================
-- Filter editor: helpers (file-local)
-- =============================================================================

--- Resolve a localized label for an animal type. Delegates to the canonical
--- helper RLAnimalUtil.getAnimalTypeDisplayName which already handles the
--- groupTitle -> title -> ui_<name>s -> name -> "?" cascade, including the
--- hasText guard that distinguishes a real l10n hit from FS25's
--- "Missing '<key>' in l10n.xml" miss-stringification.
---@param at table animalType entry from animalSystem:getTypes()
---@return string label
local function resolveAnimalTypeLabel(at)
    if RLAnimalUtil ~= nil and RLAnimalUtil.getAnimalTypeDisplayName ~= nil then
        return RLAnimalUtil.getAnimalTypeDisplayName(at)
    end
    -- Defensive fallback if RLAnimalUtil is unavailable for any reason.
    Log:warning("resolveAnimalTypeLabel: RLAnimalUtil.getAnimalTypeDisplayName unavailable; using local fallback")
    if at == nil then return "?" end
    return at.groupTitle or at.name or "?"
end

--- Apply a pending overlay onto a stored filter, producing a merged snapshot.
--- Immutable fields (id, farmId, version) are copied from stored unchanged so
--- service:update never sees a divergence. animalType has three-state semantics
--- via the ANIMAL_TYPE_ANY sentinel (see module head).
---@param stored table cloned snapshot from getById (never nil at this point)
---@param overlay table|nil per-id partial overlay or nil for "no pending"
---@return table merged shallow-cloned filter with overlay applied
local function overlayPending(stored, overlay)
    -- Stale stored.usage = nil defense (P1-3b code-review patch). Every
    -- normal entry point (create/update/serialization/wire/applyIncoming)
    -- normalises to a canonical string post-2026-05-17. Defending here
    -- ensures that if a stale record ever slips through (test fixture,
    -- future direct hand-built record), the editor's flush degrades to a
    -- successful service:update instead of triggering #14 nil-rejection
    -- which would silently drop every other pending edit on that filter.
    local mergedUsage = stored.usage or RLFilterUsage.ANY
    local merged = {
        id         = stored.id,
        farmId     = stored.farmId,
        version    = stored.version,
        name       = stored.name,
        animalType = stored.animalType,
        usage      = mergedUsage,
        expression = stored.expression,
    }
    if overlay == nil then
        return merged
    end
    if overlay.name ~= nil then
        merged.name = overlay.name
    end
    if overlay.animalType == RLMenuSettingsFrame.ANIMAL_TYPE_ANY then
        -- Sentinel marks an explicit "clear to Any"; converts to nil for
        -- service:update + storage + wire.
        merged.animalType = nil
    elseif overlay.animalType ~= nil then
        merged.animalType = overlay.animalType
    end
    if overlay.usage ~= nil then
        -- 3-state enum, no sentinel needed; presence means "change to this
        -- canonical value" (one of RLFilterUsage.ANY/OWNED/DEALER).
        merged.usage = overlay.usage
    end
    if overlay.op ~= nil then
        -- Build a fresh root group with the new op; preserve any nested
        -- children so a filter authored with sub-groups (Phase 2 / API /
        -- peer) keeps its structure when the user flips the root match
        -- mode in P1-3's UI.
        local stored_children = (stored.expression and stored.expression.children) or {}
        local copied = {}
        for i, child in ipairs(stored_children) do copied[i] = child end
        merged.expression = { op = overlay.op, children = copied }
    end
    return merged
end

--- Populate self.animalTypeStates with the canonical "Any" row at index 1 and
--- one row per type returned by animalSystem:getTypes(). Reseeded on every
--- renderEditor call (cheap, ~5-10 types). g_currentMission is guaranteed
--- non-nil here: every settings page is registered behind basePredicate at
--- RLMenu.lua:89, so this code path is unreachable pre-mission.
---@param self table frame instance
local function seedAnimalTypeStates(self)
    local entries = {
        { label = g_i18n:getText("rl_menu_filters_animal_type_any"), typeIndex = nil },
    }
    if g_currentMission ~= nil and g_currentMission.animalSystem ~= nil then
        local types = g_currentMission.animalSystem:getTypes()
        if types ~= nil then
            -- getTypes() is keyed by typeIndex (sparse-map shape), not a dense
            -- 1-N array. ipairs would stop at the first gap and silently drop
            -- exotic / map-bridge types. Mirror RLDealerQuery.listDealerTypes:
            -- collect with pairs(), guard against nil entries / missing
            -- typeIndex, then sort by typeIndex for stable ordering.
            local collected = {}
            for _, at in pairs(types) do
                if at ~= nil and at.typeIndex ~= nil then
                    table.insert(collected, at)
                end
            end
            table.sort(collected, function(a, b)
                return (a.typeIndex or 0) < (b.typeIndex or 0)
            end)
            for _, at in ipairs(collected) do
                table.insert(entries, {
                    label = resolveAnimalTypeLabel(at),
                    typeIndex = at.typeIndex,
                })
            end
        end
    end
    self.animalTypeStates = entries

    -- Push labels into the selector. setTexts clamps state to #texts so an
    -- earlier setState(largeIndex) survives a shrink (defense-in-depth).
    if self.filterAnimalTypeSelector ~= nil then
        local labels = {}
        for i, entry in ipairs(entries) do labels[i] = entry.label end
        self.filterAnimalTypeSelector:setTexts(labels)
    end
    Log:trace("seedAnimalTypeStates: %d state(s) seeded", #entries)
end

--- Push the 3-state Usage selector labels (Any / Owned / Dealer) into the
--- MultiTextOption widget. State 1 = ANY, state 2 = OWNED, state 3 = DEALER.
--- Idempotent and cheap; called from renderEditor on every render to mirror
--- seedAnimalTypeStates. No state cache needed because the mapping is
--- constant (3 fixed strings, no runtime variation).
---@param self table frame instance
local function seedUsageSelector(self)
    if self.filterUsageSelector == nil then
        return
    end
    self.filterUsageSelector:setTexts({
        g_i18n:getText("rl_menu_filters_usage_any"),
        g_i18n:getText("rl_menu_filters_usage_owned"),
        g_i18n:getText("rl_menu_filters_usage_dealer"),
    })
    Log:trace("seedUsageSelector: 3 state(s) seeded")
end

-- =============================================================================
-- Filter editor: render + widget callbacks
-- =============================================================================

--- Drive the right-pane editor widgets from the current selection + pending
--- overlay. Called from refreshData (tail), onListSelectionChanged (tail), and
--- after Duplicate/Delete-Yes mutations. Empty-state branch hides the layout
--- and slider; selected branch builds a merged snapshot via overlayPending
--- and pushes values into the three widgets with callback-suppress flags so
--- the programmatic push doesn't re-enter the click handlers.
function RLMenuSettingsFrame:renderEditor()
    if self.selectedFilterId == nil then
        if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(true) end
        if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(false) end
        if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(false) end
        Log:debug("RLMenuSettingsFrame:renderEditor: no selection")
        return
    end

    -- Hydrate AnimalType selector states first so the index resolution below
    -- maps against the live label set.
    seedAnimalTypeStates(self)

    -- Seed the 3-state Usage selector labels. Constant mapping (Any/Owned/
    -- Dealer); idempotent re-seed is cheap.
    seedUsageSelector(self)

    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:renderEditor: g_rlFilterService is nil; aborting render")
        return
    end

    local stored = g_rlFilterService:getById(self.selectedFilterId)
    if stored == nil then
        -- Selected id no longer present (race with remote delete, or a
        -- pending edit reference that survived a refresh). Drop the
        -- selection and fall back to the empty-state branch on the next
        -- render pass. resolveSelectionById will catch this on the next
        -- refreshData but we guard here too.
        Log:debug("RLMenuSettingsFrame:renderEditor: id=%s not in service, falling back to empty",
            tostring(self.selectedFilterId))
        self.selectedFilterId = nil
        if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(true) end
        if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(false) end
        if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(false) end
        return
    end

    local merged = overlayPending(stored, self.pendingChanges[self.selectedFilterId])

    if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(false) end
    if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(true)  end
    if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(true) end

    -- Tint the editor rows so the cream title text reads against a dark
    -- backing. Same fix P1-1 applied to the General subtab rows -
    -- without it, rows fall back to the default white tint of
    -- gui.colorPreset from baseReference and titles are invisible on the
    -- new menu chrome. updateAlternatingElements skips hidden rows, so
    -- this MUST run after the setVisible(true) above. Idempotent / cheap
    -- to re-run on every render.
    if self.filterEditorLayout ~= nil then
        self:updateAlternatingElements(self.filterEditorLayout)
    end

    -- Name: programmatic setText is callback-safe (the onTextChanged
    -- callback fires only on actual user keystrokes, not on this push).
    -- HOWEVER, the input control resets the caret to text-end on every
    -- programmatic value push - including no-ops. When a remote
    -- RLFilterUpdateEvent triggers refreshIfOpen -> refreshData ->
    -- renderEditor while the user is editing in the middle of the field,
    -- that setText stomps the caret. Skip the push when the input owns
    -- focus AND the text is unchanged (the user is editing it now and
    -- the overlay already captures their pending edits).
    if self.filterNameInput ~= nil then
        local desired = merged.name or ""
        local isFocused = self.filterNameInput.getIsFocused ~= nil
            and self.filterNameInput:getIsFocused()
        local current = self.filterNameInput.getText ~= nil
            and self.filterNameInput:getText() or nil
        if isFocused and current == desired then
            Log:trace("RLMenuSettingsFrame:renderEditor: skipping setText (focused + unchanged) for id=%s",
                tostring(merged.id))
        else
            self.filterNameInput:setText(desired)
        end
    end

    -- AnimalType: walk animalTypeStates to find the entry matching the
    -- merged animalType (nil for Any). Fallback to state 1 = Any when no
    -- match (covers a stored type the local mission doesn't define, e.g.
    -- a peer save-game with a bridge mod we don't have loaded).
    local atStateIndex = 1
    for i, entry in ipairs(self.animalTypeStates) do
        if entry.typeIndex == merged.animalType then
            atStateIndex = i
            break
        end
    end
    if self.filterAnimalTypeSelector ~= nil then
        self.filterAnimalTypeSelector:setState(atStateIndex, false)
    end

    -- Op: 1 = AND, 2 = OR. Default to AND when expression has no root op.
    local opStateIndex = 1
    if merged.expression ~= nil and merged.expression.op == "OR" then
        opStateIndex = 2
    end
    if self.filterOpSelector ~= nil then
        self.filterOpSelector:setState(opStateIndex, false)
    end

    -- Usage: 1 = ANY, 2 = OWNED, 3 = DEALER. Default to state 1 for any value
    -- that doesn't match OWNED or DEALER (covers ANY, nil-from-legacy, and
    -- defensive against an un-normalised in-memory record).
    local usageStateIndex = 1
    if merged.usage == RLFilterUsage.OWNED then
        usageStateIndex = 2
    elseif merged.usage == RLFilterUsage.DEALER then
        usageStateIndex = 3
    end
    if self.filterUsageSelector ~= nil then
        self.filterUsageSelector:setState(usageStateIndex, false)
    end

    Log:debug("RLMenuSettingsFrame:renderEditor: id=%s name=%s animalType=%s op=%s usage=%s",
        tostring(merged.id), tostring(merged.name),
        tostring(merged.animalType),
        tostring(merged.expression and merged.expression.op),
        tostring(merged.usage))
end

--- TextInput onTextChanged callback. The widget raises this with
--- (target, element, text); with colon-bound `self` absorbing the
--- target, our explicit args are (element, text).
---
--- Per-keystroke flow:
---   1. Stash the typed value into pendingChanges[id].name (lazy sub-table).
---   2. reloadData on the SmoothList so the left-pane cell text reflects
---      the live edit (populateCellForItemInSection reads the overlay).
---   3. Wrap reloadData in isReconciling so the synchronous selection
---      delegate fired by SmoothList:reloadData doesn't tail-call
---      renderEditor and stomp the caret mid-typing (P1-3 spec F6 fix).
--- @param element table The TextInput element
--- @param _text string The new text (read from element for consistency)
function RLMenuSettingsFrame:onFilterNameChanged(element, _text)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onFilterNameChanged: no selection, ignoring")
        return
    end
    if element == nil then
        Log:trace("RLMenuSettingsFrame:onFilterNameChanged: nil element, ignoring")
        return
    end
    local typed = element:getText() or ""
    local id = self.selectedFilterId
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    self.pendingChanges[id].name = typed
    Log:debug("RLMenuSettingsFrame:onFilterNameChanged: id=%s value='%s'", tostring(id), typed)

    -- Reload the left list so the cell shows the pending name. isReconciling
    -- gate prevents the synchronous onListSelectionChanged from re-entering
    -- renderEditor (which would call setText and stomp the caret).
    if self.filtersList ~= nil then
        self.isReconciling = true
        self.filtersList:reloadData()
        self.isReconciling = false
    end
end

--- MultiTextOption onClick callback. The widget raises this with
--- (target, state, widget, isLeftButtonEvent); with colon-bound `self`
--- absorbing the target, our explicit args are (state, widget).
---
--- state == 1 maps to the "Any" row (typeIndex = nil), persisted into the
--- overlay as the ANIMAL_TYPE_ANY sentinel so flush can distinguish
--- "explicit clear" from "no pending change".
--- @param state number 1-based selector state
--- @param _widget table The widget that was clicked
function RLMenuSettingsFrame:onAnimalTypeChanged(state, _widget)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onAnimalTypeChanged: no selection, ignoring (state=%s)",
            tostring(state))
        return
    end
    local entry = self.animalTypeStates[state]
    if entry == nil then
        Log:warning("RLMenuSettingsFrame:onAnimalTypeChanged: state=%s out of range (%d state(s) seeded); ignoring",
            tostring(state), #self.animalTypeStates)
        return
    end
    local id = self.selectedFilterId
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    if entry.typeIndex == nil then
        self.pendingChanges[id].animalType = RLMenuSettingsFrame.ANIMAL_TYPE_ANY
    else
        self.pendingChanges[id].animalType = entry.typeIndex
    end
    Log:debug("RLMenuSettingsFrame:onAnimalTypeChanged: id=%s state=%d typeIndex=%s",
        tostring(id), state, tostring(entry.typeIndex))
end

--- MultiTextOption onClick callback for the AND/OR root op selector.
--- state == 1 -> AND, state == 2 -> OR.
--- @param state number 1-based selector state
--- @param _widget table The widget that was clicked
function RLMenuSettingsFrame:onOpChanged(state, _widget)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onOpChanged: no selection, ignoring (state=%s)",
            tostring(state))
        return
    end
    local id = self.selectedFilterId
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    local op = (state == 2) and "OR" or "AND"
    self.pendingChanges[id].op = op
    Log:debug("RLMenuSettingsFrame:onOpChanged: id=%s state=%d op=%s",
        tostring(id), state, op)
end

--- MultiTextOption onClick callback for the Usage scope selector.
--- state 1 -> ANY, state 2 -> OWNED, state 3 -> DEALER (matches the wire-byte
--- order 0/1/2 minus one for cognitive parity with the codec).
---
--- Out-of-range states (4+) are unreachable in practice because the widget
--- is seeded with exactly 3 labels; we log at TRACE and no-op as defence
--- against future label changes.
--- @param state number 1-based selector state
--- @param _widget table The widget that was clicked
function RLMenuSettingsFrame:onUsageChanged(state, _widget)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onUsageChanged: no selection, ignoring (state=%s)",
            tostring(state))
        return
    end
    local newUsage
    if state == 1 then
        newUsage = RLFilterUsage.ANY
    elseif state == 2 then
        newUsage = RLFilterUsage.OWNED
    elseif state == 3 then
        newUsage = RLFilterUsage.DEALER
    else
        Log:trace("RLMenuSettingsFrame:onUsageChanged: state=%s out of range; ignoring",
            tostring(state))
        return
    end
    local id = self.selectedFilterId
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    self.pendingChanges[id].usage = newUsage
    Log:debug("RLMenuSettingsFrame:onUsageChanged: id=%s state=%d usage=%s",
        tostring(id), state, newUsage)
end

-- =============================================================================
-- Filter editor: flush
-- =============================================================================

--- Drain self.pendingChanges to service:update. Called from onFrameClose AFTER
--- isFrameOpen is cleared (so a mid-flush remote RLFilterUpdateEvent rebroadcast
--- early-returns through refreshIfOpen, closing the re-entry window).
---
--- For each pending id:
---   - fetch stored via getById; skip + DEBUG-log if nil (orphan id, e.g.
---     deleted by another client while we held an edit)
---   - overlay pending onto stored to produce the merged record
---   - enforce flush-time name boundary: trim whitespace; revert to stored
---     name + WARNING if the trimmed result is empty (widget callbacks are
---     permissive mid-typing; flush is the enforcement point)
---   - call service:update(id, merged); WARNING on nil return
---
--- service:update dispatches RLFilterUpdateEvent (Pattern A); MP convergence
--- is the service's responsibility.
function RLMenuSettingsFrame:flushPendingChanges()
    local idsIn = 0
    for _ in pairs(self.pendingChanges) do idsIn = idsIn + 1 end
    if idsIn == 0 then
        Log:debug("RLMenuSettingsFrame:flushPendingChanges: count=0")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:flushPendingChanges: g_rlFilterService is nil; %d pending change(s) dropped",
            idsIn)
        self.pendingChanges = {}
        return
    end

    local updated, skipped = 0, 0
    for id, overlay in pairs(self.pendingChanges) do
        local stored = g_rlFilterService:getById(id)
        if stored == nil then
            Log:debug("RLMenuSettingsFrame:flushPendingChanges: skipped orphan id=%s", tostring(id))
            skipped = skipped + 1
        else
            local merged = overlayPending(stored, overlay)
            -- Flush-time name boundary enforcement (spec F9 fix).
            local trimmed = (merged.name or ""):match("^%s*(.-)%s*$")
            if trimmed == "" then
                merged.name = stored.name
                Log:warning("RLMenuSettingsFrame:flushPendingChanges: empty/whitespace name for id=%s reverted to stored '%s'",
                    tostring(id), tostring(stored.name))
            else
                merged.name = trimmed
            end
            local result = g_rlFilterService:update(id, merged)
            if result == nil then
                Log:warning("RLMenuSettingsFrame:flushPendingChanges: service:update returned nil for id=%s (validation rejection?)",
                    tostring(id))
            else
                Log:debug("RLMenuSettingsFrame:flushPendingChanges: applied id=%s name='%s' animalType=%s op=%s usage=%s",
                    tostring(id), tostring(merged.name),
                    tostring(merged.animalType),
                    tostring(merged.expression and merged.expression.op),
                    tostring(merged.usage))
                updated = updated + 1
            end
        end
    end
    Log:debug("RLMenuSettingsFrame:flushPendingChanges: count=%d updated=%d skipped=%d",
        idsIn, updated, skipped)
    self.pendingChanges = {}
end

-- =============================================================================
-- Filter editor: Duplicate
-- =============================================================================

--- Compute a non-colliding duplicate name. Walks self.rows resolving each
--- row's display name via the pending overlay (so renames in flight on
--- OTHER rows still count toward the collision check). Appends the
--- localized `rl_menu_filters_duplicate_suffix` on the first duplicate;
--- subsequent duplicates use `rl_menu_filters_duplicate_suffix_n`, a
--- format string carrying the language's own word order / punctuation
--- around `%d` (e.g. " (copy %d)" in EN). Detection of existing dupes
--- builds a Lua pattern from the same localized template so the count
--- form is recognized regardless of how the translator phrased it.
--- @param baseName string Source filter's merged name
--- @return string
function RLMenuSettingsFrame:computeDuplicateName(baseName)
    local base = baseName or ""
    local suffixFirst = g_i18n:getText("rl_menu_filters_duplicate_suffix")
    local suffixNFmt  = g_i18n:getText("rl_menu_filters_duplicate_suffix_n")
    local first = base .. suffixFirst

    -- Build a detection pattern from the localized numbered template.
    -- Swap the %d placeholder for a sentinel byte first, escape all Lua
    -- pattern specials in the surrounding literal text, then swap the
    -- sentinel back for the (%d+) capture. Escaping `%` is required - it
    -- is Lua's pattern escape char - which is why we cannot escape the
    -- raw format string directly without first lifting the placeholder.
    local function escapePattern(s)
        return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
    end
    local placeholder = "\1"
    local templatePat = escapePattern((suffixNFmt:gsub("%%d", placeholder)))
        :gsub(placeholder, "(%%d+)")
    local countPattern = "^" .. escapePattern(base) .. templatePat .. "$"

    local count = 0
    for _, row in ipairs(self.rows) do
        local pending = self.pendingChanges[row.id]
        local name = (pending and pending.name) or row.name or ""
        if name == first or name:match(countPattern) then
            count = count + 1
        end
    end
    local result
    if count == 0 then
        result = first
    else
        result = base .. suffixNFmt:format(count + 1)
    end
    Log:trace("RLMenuSettingsFrame:computeDuplicateName: base='%s' count=%d result='%s'",
        base, count, result)
    return result
end

--- Footer Duplicate handler. Gated on selection + permission + farm.
--- Clones the source filter (overlay-merged so in-flight edits are
--- duplicated too), assigns a non-colliding name, and creates via the
--- same g_rlFilterService:create call onClickNewFilter uses. Auto-selects
--- the new id via the existing resolveSelectionById path on refreshData.
function RLMenuSettingsFrame:onClickDuplicate()
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onClickDuplicate: no selection, aborting")
        return
    end
    if not self:hasCreatePermission() then
        Log:trace("RLMenuSettingsFrame:onClickDuplicate: no tradeAnimals permission, aborting")
        return
    end
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSettingsFrame:onClickDuplicate: no farm, aborting")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onClickDuplicate: g_rlFilterService is nil; aborting")
        return
    end

    local stored = g_rlFilterService:getById(self.selectedFilterId)
    if stored == nil then
        Log:warning("RLMenuSettingsFrame:onClickDuplicate: getById returned nil for id=%s; aborting",
            tostring(self.selectedFilterId))
        return
    end

    local merged = overlayPending(stored, self.pendingChanges[self.selectedFilterId])
    local dupName = self:computeDuplicateName(merged.name)

    -- _cloneFilter deep-clones the expression (P2 carryover ownership
    -- contract). The service ALSO deep-clones internally; double-clone is
    -- a correctness belt-and-suspenders honoured throughout Phase 0.
    -- Preserve the source filter's scope. A global filter (farmId == nil)
    -- stays global; a farm-scoped filter keeps its farmId. Using
    -- self.farmId here would narrow a global copy down to the active
    -- farm.
    local cloned = RLFilterService._cloneFilter(merged)
    local newFilter = g_rlFilterService:create({
        name       = dupName,
        animalType = merged.animalType,
        farmId     = merged.farmId,
        usage      = merged.usage,
        expression = cloned.expression,
    })
    if newFilter == nil then
        Log:warning("RLMenuSettingsFrame:onClickDuplicate: service rejected create (nil return) for source id=%s",
            tostring(self.selectedFilterId))
        return
    end

    Log:debug("RLMenuSettingsFrame:onClickDuplicate: source=%s name='%s' farmId=%s usage=%s -> new id=%s",
        tostring(self.selectedFilterId), tostring(dupName), tostring(merged.farmId),
        tostring(merged.usage), tostring(newFilter.id))
    self.selectedFilterId = newFilter.id
    self:refreshData()
end

-- =============================================================================
-- Filter editor: Delete
-- =============================================================================

--- Footer Delete handler. Opens a YesNoDialog with the selected filter's
--- name; on Yes calls service:delete via onDeleteConfirmed. No state
--- mutation until the user confirms (mirrors RLMenuMessagesFrame:onClickDeleteAll
--- at lines 301-338).
function RLMenuSettingsFrame:onClickDelete()
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onClickDelete: no selection, aborting")
        return
    end
    if not self:hasCreatePermission() then
        Log:trace("RLMenuSettingsFrame:onClickDelete: no tradeAnimals permission, aborting")
        return
    end
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSettingsFrame:onClickDelete: no farm, aborting")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onClickDelete: g_rlFilterService is nil; aborting")
        return
    end

    if g_gui:getIsDialogVisible() then
        Log:trace("RLMenuSettingsFrame:onClickDelete: dialog already open, ignoring re-entry")
        return
    end

    local stored = g_rlFilterService:getById(self.selectedFilterId)
    if stored == nil then
        Log:warning("RLMenuSettingsFrame:onClickDelete: getById returned nil for id=%s; aborting",
            tostring(self.selectedFilterId))
        return
    end

    local confirmText = string.format(
        g_i18n:getText("rl_menu_filters_delete_confirm_text"),
        tostring(stored.name or ""))

    Log:debug("RLMenuSettingsFrame:onClickDelete: opening YesNoDialog for id=%s name='%s'",
        tostring(stored.id), tostring(stored.name))

    -- YesNoDialog passes (target, yesValue, callbackArgs) to its callback;
    -- with target=self the colon-bound `self` absorbs it and we receive
    -- (yes, id) explicitly. Mirrors RLMenuMessagesFrame's onDeleteAll flow.
    YesNoDialog.show(
        self.onDeleteConfirmed,
        self,
        confirmText,
        g_i18n:getText("ui_attention"),
        nil, nil, nil, nil, nil,
        stored.id
    )
end

--- YesNoDialog confirmation callback for Delete. Yields when the user
--- clicked No. On Yes: call service:delete FIRST and only react on its
--- return - on ok=true clear pending edits + selection; on ok=false
--- (stale id / race with another client) preserve pending edits + selection
--- and log WARNING so the user can retry / observe the next refresh event
--- resolving the divergence. No destructive local cleanup before confirming
--- the service applied the mutation.
--- @param yes boolean True when the user clicked Yes
--- @param id string The filter id captured at click time
function RLMenuSettingsFrame:onDeleteConfirmed(yes, id)
    Log:trace("RLMenuSettingsFrame:onDeleteConfirmed: yes=%s id=%s", tostring(yes), tostring(id))
    if not yes then return end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onDeleteConfirmed: g_rlFilterService is nil; aborting")
        return
    end
    local ok = g_rlFilterService:delete(id)
    if ok then
        self.pendingChanges[id] = nil
        if self.selectedFilterId == id then
            self.selectedFilterId = nil
        end
        Log:debug("RLMenuSettingsFrame:onDeleteConfirmed: deleted id=%s", tostring(id))
        self:refreshData()
    else
        Log:warning("RLMenuSettingsFrame:onDeleteConfirmed: service:delete returned false for id=%s; preserving pending edits + selection (stale id or race with another client)",
            tostring(id))
    end
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
        -- Rerender the editor (-> empty state) + rebuild footer so Duplicate
        -- and Delete drop with the now-cleared selection. Without these the
        -- right pane keeps showing the previous filter's content and the
        -- destructive buttons stay live until some later refresh reconciles.
        self:renderEditor()
        self:updateButtonVisibility()
        return
    end

    self.selectedFilterId = row.id
    Log:debug("RLMenuSettingsFrame:onListSelectionChanged: index=%d id=%s",
        index, tostring(row.id))

    -- Selection changed: rerender the right pane against the new id and
    -- rebuild the footer so Duplicate/Delete toggle with selection.
    self:renderEditor()
    self:updateButtonVisibility()
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

    -- Resolve display name through the pending overlay so live edits show
    -- in the left list immediately. Sort key (row.name) stays untouched so
    -- row position remains stable mid-edit.
    local pending = self.pendingChanges[row.id]
    local displayName = (pending and pending.name) or row.name or ""

    local nameCell = cell:getAttribute("filterName")
    if nameCell ~= nil then
        nameCell:setText(displayName)
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
