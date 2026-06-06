--[[
    RLMenuHerdsmanFrame.lua
    RL Tabbed Menu Herdsman tab - rule list (master) + rule editor (detail).

    Shell only: the rule list binds to an empty data source so its empty
    state renders, and onFrameOpen measures the list / editor containers
    (against the header baseline) so the master-detail placement under the
    header - with the subcategory tab bar stripped - is verified from the
    log rather than eyeballed. Rule rows, editor widgets, dialogs, and the
    action bar are later herdsman frame slices.

    Bind-only by design: the herdsman view-model RLHerdsmanRulePresenter owns
    every list / detail / validation decision, so this frame carries no
    sort / filter / format / validation logic - only element wiring,
    nil-guards, and measurement logging.
]]

RLMenuHerdsmanFrame = {}
local RLMenuHerdsmanFrame_mt = Class(RLMenuHerdsmanFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

-- Store mod directory at source time (g_currentModDirectory only valid during source())
local modDirectory = g_currentModDirectory

-- operation -> section-header i18n key. Localization wiring for the multi-section
-- list: the presenter stays key-free, so the frame owns the label map. A value
-- lookup, not decision logic (no sort/filter/format/validation). Operations are
-- RLHerdsmanRulePresenter's canonical OPERATION_ORDER set.
local OPERATION_TITLE_KEY = {
    sell     = "rl_menu_herdsman_section_sell",
    buy      = "rl_menu_herdsman_section_buy",
    castrate = "rl_menu_herdsman_section_castrate",
    naming   = "rl_menu_herdsman_section_naming",
    ai       = "rl_menu_herdsman_section_ai",
}

--- Construct a new RLMenuHerdsmanFrame instance.
--- Called once by setupGui() during mod load.
--- @return table self The new frame instance
function RLMenuHerdsmanFrame.new()
    local self = RLMenuHerdsmanFrame:superClass().new(nil, RLMenuHerdsmanFrame_mt)
    self.name = "RLMenuHerdsmanFrame"
    self.isFrameOpen = false
    -- One-shot guard for the layout measurement: reset on every onFrameOpen,
    -- flipped once the stretched containers report settled sizes (see update).
    self.didMeasureLayout = false
    -- Sectioned rule model (RLHerdsmanRulePresenter output), the current selection
    -- id, and a one-shot guard for the first-row populate log (re-armed each open).
    self.sections = {}
    self.selectedRuleId = nil
    self.didMeasureFirstRow = false
    Log:trace("RLMenuHerdsmanFrame.new: instance created")
    return self
end

--- Load the herdsman frame XML and register the frame with g_gui.
--- Called from RLMenu.setupGui() before the menu XML is loaded so that
--- rlMenu.xml's FrameReference ref="RLMenuHerdsmanFrame" resolves.
function RLMenuHerdsmanFrame.setupGui()
    local frame = RLMenuHerdsmanFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/herdsmanFrame.xml", modDirectory),
        "RLMenuHerdsmanFrame",
        frame,
        true  -- frame-only load
    )
    Log:debug("RLMenuHerdsmanFrame.setupGui: registered")
end

--- Resolve element references and bind the rule list to its (empty) data
--- source after XML parsing completes. The shell renders an empty list so
--- the empty-state text shows; the presenter-backed sectioned data source
--- replaces this binding in a later slice.
function RLMenuHerdsmanFrame:onGuiSetupFinished()
    RLMenuHerdsmanFrame:superClass().onGuiSetupFinished(self)

    self.rulesList           = self:getDescendantById("rulesList")
    self.rulesListContainer  = self:getDescendantById("rulesListContainer")
    self.rulesSliderBox      = self:getDescendantById("rulesSliderBox")
    self.ruleEditorContainer = self:getDescendantById("ruleEditorContainer")
    self.rulesEmptyState     = self:getDescendantById("rulesEmptyState")
    self.headerPanel         = self:getDescendantById("headerPanel")

    local missing = {}
    if self.rulesList == nil then table.insert(missing, "rulesList") end
    if self.rulesListContainer == nil then table.insert(missing, "rulesListContainer") end
    if self.rulesSliderBox == nil then table.insert(missing, "rulesSliderBox") end
    if self.ruleEditorContainer == nil then table.insert(missing, "ruleEditorContainer") end
    if self.rulesEmptyState == nil then table.insert(missing, "rulesEmptyState") end
    if self.headerPanel == nil then table.insert(missing, "headerPanel") end
    if #missing > 0 then
        Log:warning("RLMenuHerdsmanFrame:onGuiSetupFinished: missing elements: %s",
            table.concat(missing, ", "))
    end

    if self.rulesList ~= nil then
        self.rulesList:setDataSource(self)
        self.rulesList:setDelegate(self)
        Log:trace("RLMenuHerdsmanFrame:onGuiSetupFinished: rulesList bound")
    end
end

--- Called by the Paging element when this tab becomes active.
--- Reloads the (empty) list, logs the layout measurements, and focuses the
--- list for keyboard/gamepad navigation.
function RLMenuHerdsmanFrame:onFrameOpen()
    RLMenuHerdsmanFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    -- Re-arm the one-shot layout + first-row measurements; update() emits the
    -- layout one on the first frame the stretched containers report settled sizes
    -- (which onFrameOpen is typically too early for).
    self.didMeasureLayout = false
    self.didMeasureFirstRow = false

    -- Build the sectioned rule model from the rule registry (the real read path:
    -- F4 edits and F7 create/delete write back through the same
    -- g_rlHerdsmanRuleService, and MP syncs through it). RLHerdsmanRulePresenter
    -- owns all grouping/order/sort; this frame only binds the result. Dev rules
    -- are seeded with the rlHerdsmanRuleCreate console command (SP).
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local rules = {}
    if farmId == nil or farmId == 0 then
        -- 0 is the spectator/unowned farm (real farms start at 1, SP player is 1);
        -- no farm -> empty list + empty-state.
        Log:debug("RLMenuHerdsmanFrame:onFrameOpen: no farm (farmId=%s); empty rule list", tostring(farmId))
    elseif g_rlHerdsmanRuleService == nil then
        Log:warning("RLMenuHerdsmanFrame:onFrameOpen: g_rlHerdsmanRuleService is nil; empty rule list (load-order regression?)")
    else
        rules = g_rlHerdsmanRuleService:listForFarm(farmId)
    end
    self.sections = RLHerdsmanRulePresenter.buildSections(rules)
    Log:debug("RLMenuHerdsmanFrame:onFrameOpen: farmId=%s, %d rule(s) -> %d section(s)", tostring(farmId), #rules, #self.sections)

    -- Reload the rows, toggle the empty-state, THEN seed the selection.
    -- reloadData does NOT reliably fire onListSelectionChanged on open: it only
    -- notifies when the clamped section is empty (SmoothListElement:reloadData),
    -- so selectInitialRule highlights row 1 and drives the detail seam explicitly.
    -- No isReconciling gate is needed (F3 keeps no cross-reload selection to
    -- protect); that + id-authoritative re-selection arrive with refresh-while-open
    -- in RLRM-396.
    if self.rulesList ~= nil then
        self.rulesList:reloadData()
    end
    self:updateEmptyState()
    self:selectInitialRule()

    -- Explicit focus for multi-tab TabbedMenu navigation (Fresh pattern):
    -- without it FocusManager auto-layout can resolve arrow keys into
    -- another tab's frame.
    if self.rulesList ~= nil then
        FocusManager:setFocus(self.rulesList)
    end
end

--- Called by the Paging element when this tab is deactivated.
function RLMenuHerdsmanFrame:onFrameClose()
    RLMenuHerdsmanFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    Log:trace("RLMenuHerdsmanFrame:onFrameClose")
end

--- Per-frame hook. Emits the one-shot layout measurement once the stretched
--- list/editor containers have settled (logLayoutMeasurements returns true);
--- the guard resets on each onFrameOpen so reopening re-measures. Mirrors the
--- Settings pane's "measure only once sizes are populated" retry, adapted to a
--- frame with no subtab event to drive it.
function RLMenuHerdsmanFrame:update(dt)
    RLMenuHerdsmanFrame:superClass().update(self, dt)
    if not self.didMeasureLayout and self:logLayoutMeasurements() then
        self.didMeasureLayout = true
    end
end

-- =============================================================================
-- LAYOUT MEASUREMENT (verification only - no layout decisions)
-- =============================================================================

--- Log the size + top edge of the list + editor containers plus the header
--- panel's bottom edge as the baseline, so the space reclaimed by stripping
--- the subcategory tab bar is provable from the log (the list top should sit
--- just below the header, higher than the Settings frame's equivalent
--- container, which sits below that tab bar). Returns true once BOTH stretched containers report settled,
--- non-zero sizes and the measurement was emitted; false while the layout has
--- not settled, so update()'s one-shot guard retries on a later frame. The
--- non-zero check is stronger than the Settings pane's non-nil guard because
--- update() fires from frame one, before the stretch resolves. absPosition is
--- the element's bottom edge (FS25 Y-up), so top = bottom + height; reference
--- screen is 1920x1080.
--- @return boolean measured true once the one-shot measurement was emitted
function RLMenuHerdsmanFrame:logLayoutMeasurements()
    local function settled(e)
        return e ~= nil and e.size ~= nil and e.absPosition ~= nil
            and e.size[1] ~= nil and e.size[1] > 0
            and e.size[2] ~= nil and e.size[2] > 0
    end
    if not (settled(self.rulesListContainer) and settled(self.ruleEditorContainer)) then
        return false
    end

    local function logBox(name, e)
        Log:debug("RLMenuHerdsmanFrame: %s measured: %.1fpx x %.1fpx, top=%.1fpx",
            name,
            e.size[1] * g_referenceScreenWidth,
            e.size[2] * g_referenceScreenHeight,
            (e.absPosition[2] + e.size[2]) * g_referenceScreenHeight)
    end
    logBox("rulesListContainer", self.rulesListContainer)
    logBox("ruleEditorContainer", self.ruleEditorContainer)

    if self.headerPanel ~= nil and self.headerPanel.absPosition ~= nil then
        Log:debug("RLMenuHerdsmanFrame: header baseline bottom=%.1fpx",
            self.headerPanel.absPosition[2] * g_referenceScreenHeight)
    end
    return true
end

-- =============================================================================
-- SMOOTHLIST DATA SOURCE / DELEGATE (multi-section, presenter-backed)
--
-- Bind-only: every method indexes self.sections (RLHerdsmanRulePresenter output)
-- by (section, index). No sort / filter / format / validation here - that all
-- lives in the presenter. The data-source getters run at draw frequency and are
-- deliberately untraced (mirrors RLMenuSettingsFrame); the build log, the
-- selection log, and a one-shot first-row log cover the render lifecycle.
-- =============================================================================

--- Number of sections (one per operation that has >=1 rule).
--- @param list table
--- @return number
function RLMenuHerdsmanFrame:getNumberOfSections(list)
    if list ~= self.rulesList then return 0 end
    return #self.sections
end

--- Localized section-header title = the operation label, via OPERATION_TITLE_KEY
--- (localization wiring, not decision logic).
--- @param list table
--- @param section number
--- @return string|nil
function RLMenuHerdsmanFrame:getTitleForSectionHeader(list, section)
    if list ~= self.rulesList then return nil end
    local sec = self.sections[section]
    if sec == nil then return nil end
    local key = OPERATION_TITLE_KEY[sec.operation]
    if key == nil then return nil end
    return g_i18n:getText(key)
end

--- Number of rule rows in a section.
--- @param list table
--- @param section number
--- @return number
function RLMenuHerdsmanFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.rulesList then return 0 end
    local sec = self.sections[section]
    return sec ~= nil and #sec.rules or 0
end

--- Populate one rule row from self.sections[section].rules[index]. Mirrors the
--- RLMenuSettingsFrame cell-population shape: read the named cell, setText.
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuHerdsmanFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.rulesList then return end
    local sec = self.sections[section]
    if sec == nil then return end
    local rule = sec.rules[index]
    if rule == nil then return end

    local nameCell = cell:getAttribute("ruleName")
    if nameCell ~= nil then
        nameCell:setText(rule.name)
    end

    -- One-shot first-row geometry/value log. The data-source protocol is
    -- draw-frequency, so only the first row is logged (mirrors the Settings
    -- frame's cell measurement), never per draw.
    if not self.didMeasureFirstRow then
        self.didMeasureFirstRow = true
        local cellW = (cell.size and cell.size[1] or 0) * g_referenceScreenWidth
        local cellH = (cell.size and cell.size[2] or 0) * g_referenceScreenHeight
        Log:debug("RLMenuHerdsmanFrame:populateCellForItemInSection: first row (s=%d,i=%d) cell=%.1fx%.1fpx name=%q",
            section, index, cellW, cellH, tostring(rule.name))
    end
end

--- Selection delegate: store the selected rule id and refresh the detail pane.
--- Out-of-range (no rule at the index) clears the cached id so nothing stale
--- lingers. reloadData's programmatic clamp-and-notify also routes here - that is
--- how row 1 is selected on open.
--- @param list table
--- @param section number
--- @param index number
function RLMenuHerdsmanFrame:onListSelectionChanged(list, section, index)
    if list ~= self.rulesList then return end

    local sec = self.sections[section]
    local rule = sec ~= nil and sec.rules[index] or nil
    if rule == nil then
        self.selectedRuleId = nil
        Log:debug("RLMenuHerdsmanFrame:onListSelectionChanged: section=%s index=%s out of range; selection cleared",
            tostring(section), tostring(index))
        self:refreshRuleDetail(nil)
        return
    end

    self.selectedRuleId = rule.id
    Log:debug("RLMenuHerdsmanFrame:onListSelectionChanged: section=%d index=%d -> ruleId=%s name=%q",
        section, index, tostring(rule.id), tostring(rule.name))
    self:refreshRuleDetail(rule)
end

--- Detail-pane refresh seam. F3 only logs the current selection; F4 (RLRM-385)
--- replaces the body with the rule-editor widget population. The editor
--- empty-state is left untouched here (no editor widgets yet).
--- @param rule table|nil the selected rule record, or nil when the selection cleared
function RLMenuHerdsmanFrame:refreshRuleDetail(rule)
    if rule == nil then
        Log:debug("RLMenuHerdsmanFrame:refreshRuleDetail: no selection; detail pane stays empty-state")
        return
    end
    Log:debug("RLMenuHerdsmanFrame:refreshRuleDetail: ruleId=%s name=%q operation=%s (F4 populates the editor)",
        tostring(rule.id), tostring(rule.name), tostring(rule.operation))
end

--- Seed the initial selection on open. reloadData does NOT fire
--- onListSelectionChanged when the clamped section already has items
--- (SmoothListElement:reloadData), and setSelectedItem applies the highlight
--- unconditionally but only fires the callback when the index changes - so on a
--- first open (index already (1,1)) it would highlight row 1 yet leave
--- selectedRuleId nil. Mirror RLMenuInfoFrame:restoreSelection: highlight row 1
--- programmatically AND drive the detail seam by hand. No rules -> clear the
--- cached id and the list's visual selection so no stale row lingers.
--- id-authoritative re-selection across a mid-session reload is F7's
--- refresh-while-open concern (RLRM-396).
function RLMenuHerdsmanFrame:selectInitialRule()
    if self.rulesList == nil then return end

    local section = self.sections[1]
    local rule = section ~= nil and section.rules[1] or nil
    if rule == nil then
        self.selectedRuleId = nil
        self.rulesList.selectedSectionIndex = 0
        self.rulesList.selectedIndex = 0
        Log:debug("RLMenuHerdsmanFrame:selectInitialRule: no rules; selection cleared")
        self:refreshRuleDetail(nil)
        return
    end

    -- forceChangeEvent=false (matches RLMenuInfoFrame): applyElementSelection
    -- highlights row 1, but the callback may not fire (no-change case), so seed
    -- selectedRuleId + the detail seam manually here.
    self.rulesList:setSelectedItem(1, 1, false, true)
    self.selectedRuleId = rule.id
    Log:debug("RLMenuHerdsmanFrame:selectInitialRule: row 1 -> ruleId=%s name=%q",
        tostring(rule.id), tostring(rule.name))
    self:refreshRuleDetail(rule)
end

--- Toggle list + slider vs empty-state visibility: >=1 section shows the list
--- (and its slider) and hides the empty text; 0 sections does the reverse. The
--- slider box is a sibling of the SmoothList, so it must be toggled explicitly or
--- an orphaned scrollbar lingers beside the empty text (mirrors
--- RLMenuSettingsFrame:updateEmptyState). selectInitialRule clears the SmoothList
--- cached selection indices on the empty path; id-authoritative re-selection across
--- a mid-session reload is the F7 refresh-while-open concern (RLRM-396).
function RLMenuHerdsmanFrame:updateEmptyState()
    local hasRules = #self.sections > 0
    Log:debug("RLMenuHerdsmanFrame:updateEmptyState: sections=%d hasRules=%s", #self.sections, tostring(hasRules))
    if self.rulesList ~= nil then
        self.rulesList:setVisible(hasRules)
    end
    if self.rulesSliderBox ~= nil then
        self.rulesSliderBox:setVisible(hasRules)
    end
    if self.rulesEmptyState ~= nil then
        self.rulesEmptyState:setVisible(not hasRules)
    end
end
