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
    self.ruleEditorContainer = self:getDescendantById("ruleEditorContainer")
    self.headerPanel         = self:getDescendantById("headerPanel")

    local missing = {}
    if self.rulesList == nil then table.insert(missing, "rulesList") end
    if self.rulesListContainer == nil then table.insert(missing, "rulesListContainer") end
    if self.ruleEditorContainer == nil then table.insert(missing, "ruleEditorContainer") end
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
    -- Re-arm the one-shot layout measurement; update() emits it on the first
    -- frame the stretched containers report settled sizes (which onFrameOpen
    -- is typically too early for).
    self.didMeasureLayout = false
    Log:debug("RLMenuHerdsmanFrame:onFrameOpen")

    if self.rulesList ~= nil then
        self.rulesList:reloadData()
    end

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
-- SMOOTHLIST DATA SOURCE (empty shell - presenter-backed sections land later)
-- =============================================================================

--- Number of rule rows in a section. The shell holds none; the presenter
--- supplies real sections in a later slice.
--- @return number always 0
function RLMenuHerdsmanFrame:getNumberOfItemsInSection(_list, _section)
    return 0
end

--- Populate a rule row. Unreachable while the list is empty; present so the
--- SmoothList data-source contract is satisfied.
function RLMenuHerdsmanFrame:populateCellForItemInSection(_list, _section, _index, _cell)
end
