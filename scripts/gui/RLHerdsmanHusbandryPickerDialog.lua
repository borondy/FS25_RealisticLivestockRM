-- RLHerdsmanHusbandryPickerDialog.lua
-- Multi-select modal that picks the husbandry targets for a herdsman rule (F6).
-- The Herdsman frame computes the animalType-gated, name-sorted candidate descriptors and
-- the rule's current targets, then passes both in; this dialog is presentation-only - it
-- renders the checkbox list, tracks selection keyed by the descriptor's stable target key, and
-- returns the chosen key array (or nil on cancel) to the caller. That key is an opaque unique
-- string - a placeable uniqueId on server/host, its net-object-id on a pure client (see
-- RLHusbandryTargetKey) - which this dialog never interprets, so the same code serves both.
--
-- ADAPTS (does not verbatim-mirror) RLFilterValueSetDialog: the checkbox cell binding,
-- select-all, the RL_SELECT/MENU_ACTIVATE action events + onClose cleanup, the
-- RmSafeUtils.safeCall on OK, the domain-order commit, and the empty-reject-via-hintText.
-- Its OWN show signature carries a DYNAMIC uniqueId domain (live husbandries) with
-- live-getName() labels, and - critically - its OWN drift policy: where the value-set
-- dialog DRIFT-STRIPS keys outside the resolved domain on commit, this dialog PRESERVES
-- checked-but-out-of-scope and unresolvable targets (protects the (missing) repair
-- affordance + MP transient-divergence). Only nil / empty uniqueIds are dropped.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanHusbandryPickerDialog = {}

local RLHerdsmanHusbandryPickerDialog_mt = Class(RLHerdsmanHusbandryPickerDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

function RLHerdsmanHusbandryPickerDialog.register()
    local dialog = RLHerdsmanHusbandryPickerDialog.new()
    g_gui:loadGui(modDirectory .. "gui/rlHerdsmanHusbandryPickerDialog.xml",
                  "RLHerdsmanHusbandryPickerDialog", dialog)
    RLHerdsmanHusbandryPickerDialog.INSTANCE = dialog
    Log:debug("RLHerdsmanHusbandryPickerDialog.register: dialog registered")
end

function RLHerdsmanHusbandryPickerDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLHerdsmanHusbandryPickerDialog_mt)

    self.candidates     = {}    -- ordered array of { uniqueId, animalType, name } descriptors (the visible domain)
    self.currentTargets = {}    -- the rule's current target uniqueIds (preserve-order for out-of-scope commit)
    self.callback       = nil
    self.callbackTarget = nil
    self.selected       = {}    -- map keyed by uniqueId, value=true when checked

    return self
end

--- Static entry point. The frame passes the already animalType-gated + name-sorted candidate
--- descriptors and the rule's current target keys (pre-checked; targets not in the candidate list -
--- out-of-scope or unresolvable - render no row but are PRESERVED on commit).
---@param callback function fn(target, keys|nil) - chosen target-key array on OK, nil on cancel
---@param target table callback target (the Herdsman frame)
---@param candidates table[] candidate descriptors { uniqueId, animalType, name } (uniqueId = stable target key), scoped + sorted by the frame
---@param currentTargets table|nil the rule's current target keys (pre-checked)
function RLHerdsmanHusbandryPickerDialog.show(callback, target, candidates, currentTargets)
    if RLHerdsmanHusbandryPickerDialog.INSTANCE == nil then
        RLHerdsmanHusbandryPickerDialog.register()
    end

    local dialog = RLHerdsmanHusbandryPickerDialog.INSTANCE
    dialog.candidates     = candidates or {}
    dialog.currentTargets = type(currentTargets) == "table" and currentTargets or {}
    dialog.callback       = callback
    dialog.callbackTarget = target
    dialog.selected       = {}
    for _, uid in ipairs(dialog.currentTargets) do
        dialog.selected[uid] = true
    end

    Log:debug("RLHerdsmanHusbandryPickerDialog.show: %d candidate(s), %d current target(s)",
        #dialog.candidates, #dialog.currentTargets)
    g_gui:showDialog("RLHerdsmanHusbandryPickerDialog")
end

-- =============================================================================
-- Element resolution + datasource wiring
-- =============================================================================

function RLHerdsmanHusbandryPickerDialog:onGuiSetupFinished()
    RLHerdsmanHusbandryPickerDialog:superClass().onGuiSetupFinished(self)

    self.husbandryList    = self:getDescendantById("husbandryList")
    self.emptyListText    = self:getDescendantById("emptyListText")
    self.hintText         = self:getDescendantById("hintText")
    self.okButton         = self:getDescendantById("okButton")
    self.selectButton     = self:getDescendantById("selectButton")
    self.selectAllButton  = self:getDescendantById("selectAllButton")
    self.husbandrySliderBox = self:getDescendantById("husbandrySliderBox")

    if self.husbandryList ~= nil then
        self.husbandryList:setDataSource(self)
    end

    -- Warn loudly on any missing critical element so an XML id drift is caught at load, not as
    -- silent mis-behavior (a missing okButton would leave OK un-disable-able on empty; a missing
    -- hintText would silently no-op the empty-selection reject).
    local missing = {}
    if self.husbandryList == nil then table.insert(missing, "husbandryList") end
    if self.emptyListText == nil then table.insert(missing, "emptyListText") end
    if self.hintText == nil then table.insert(missing, "hintText") end
    if self.okButton == nil then table.insert(missing, "okButton") end
    if #missing > 0 then
        Log:warning("RLHerdsmanHusbandryPickerDialog:onGuiSetupFinished: missing elements: %s", table.concat(missing, ", "))
    end

    Log:trace("RLHerdsmanHusbandryPickerDialog:onGuiSetupFinished: elements resolved (list=%s empty=%s hint=%s ok=%s)",
        tostring(self.husbandryList ~= nil), tostring(self.emptyListText ~= nil),
        tostring(self.hintText ~= nil), tostring(self.okButton ~= nil))
end

-- =============================================================================
-- Hint surface (mirrors RLFilterValueSetDialog:showHint / clearHint)
-- =============================================================================

function RLHerdsmanHusbandryPickerDialog:showHint(l10nKey)
    if self.hintText == nil then
        Log:warning("RLHerdsmanHusbandryPickerDialog:showHint: hintText element missing; cannot surface key=%s",
            tostring(l10nKey))
        return
    end
    local text = (g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(l10nKey))
                 and g_i18n:getText(l10nKey)
                 or tostring(l10nKey)
    self.hintText:setText(text)
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(true) end
    Log:debug("RLHerdsmanHusbandryPickerDialog:showHint: key=%s", tostring(l10nKey))
end

function RLHerdsmanHusbandryPickerDialog:clearHint()
    if self.hintText == nil then return end
    self.hintText:setText("")
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(false) end
    Log:trace("RLHerdsmanHusbandryPickerDialog:clearHint")
end

-- =============================================================================
-- onOpen: visibility + action events + geometry log
-- =============================================================================

--- Toggle the list vs the empty-candidate text + OK-disabled state (mirror the filter
--- picker), register the RL_SELECT action event (keyboard routing needs an explicit
--- registerActionEvent in this dialog context, like the value-set dialog), refresh the
--- select-all label, reload, then emit a one-shot screen-space geometry log so the dialog
--- + list + hint placement is provable from the log (no eyeballing).
function RLHerdsmanHusbandryPickerDialog:onOpen()
    RLHerdsmanHusbandryPickerDialog:superClass().onOpen(self)

    local hasCandidates = #self.candidates > 0
    if self.husbandryList ~= nil then self.husbandryList:setVisible(hasCandidates) end
    if self.husbandrySliderBox ~= nil then self.husbandrySliderBox:setVisible(hasCandidates) end
    if self.emptyListText ~= nil then self.emptyListText:setVisible(not hasCandidates) end
    if self.okButton ~= nil then self.okButton:setDisabled(not hasCandidates) end
    -- Select / Select-all are inert on an empty candidate list (nothing to toggle) - disable them
    -- so the empty state advertises only Back (mirror okButton).
    if self.selectButton ~= nil then self.selectButton:setDisabled(not hasCandidates) end
    if self.selectAllButton ~= nil then self.selectAllButton:setDisabled(not hasCandidates) end

    self:clearHint()
    self:_refreshSelectAllLabel()

    -- RL_SELECT (KEY_a): custom mod actions do not fire from a profile binding alone in this
    -- dialog context; register explicitly + clean up in onClose (mirror the value-set dialog).
    -- Only when there are candidate rows to toggle (no point binding against an empty list).
    if hasCandidates and g_inputBinding ~= nil and InputAction ~= nil then
        g_inputBinding:registerActionEvent(
            InputAction.RL_SELECT, self, self.onClickSelect,
            false, true, false, true)
        Log:trace("RLHerdsmanHusbandryPickerDialog:onOpen: registered RL_SELECT action event")
    end

    if hasCandidates and self.husbandryList ~= nil then
        self.husbandryList:reloadData()
    end

    local preCheckedCount = 0
    for _ in pairs(self.selected) do preCheckedCount = preCheckedCount + 1 end

    Log:debug("RLHerdsmanHusbandryPickerDialog:onOpen: %d candidate(s), %d pre-checked%s",
        #self.candidates, preCheckedCount,
        hasCandidates and "" or " (empty candidate list; OK disabled)")

    -- One-shot geometry log: screen-space bounding box of the list, the hint surface, and the
    -- action-bar buttons so the layout is provable from the log (1920x1080 reference; FS25
    -- Y-up, so top = absPos.y + height).
    local function _logElem(name, e)
        if e == nil then
            Log:debug("RLHerdsmanHusbandryPickerDialog._geom: %s == nil", name); return
        end
        local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
        local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
        local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
        local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
        Log:debug("RLHerdsmanHusbandryPickerDialog._geom: %s absPos=(%.1f,%.1f) size=(%.1fx%.1f) top=%.1f bottom=%.1f left=%.1f right=%.1f",
            name, ax, ay, sw, sh, ay + sh, ay, ax, ax + sw)
    end
    _logElem("husbandryList",   self.husbandryList)
    _logElem("hintText",        self.hintText)
    _logElem("okButton",        self.okButton)
    _logElem("selectAllButton", self.selectAllButton)
end

--- onClose: unregister any action events registered with self as target (mirror the
--- value-set dialog). Without this, the RL_SELECT binding leaks across dialog opens.
function RLHerdsmanHusbandryPickerDialog:onClose()
    RLHerdsmanHusbandryPickerDialog:superClass().onClose(self)
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEventsByTarget(self)
        Log:trace("RLHerdsmanHusbandryPickerDialog:onClose: removed action events by target")
    end
end

-- =============================================================================
-- SmoothList DataSource
-- =============================================================================

function RLHerdsmanHusbandryPickerDialog:getNumberOfSections()
    return 1
end

function RLHerdsmanHusbandryPickerDialog:getNumberOfItemsInSection(_list, _section)
    return #self.candidates
end

function RLHerdsmanHusbandryPickerDialog:getTitleForSectionHeader(_list, _section)
    return ""
end

--- Populate one row: husbandry name label + checkbox reflecting the per-uniqueId selection.
--- Mirrors RLFilterValueSetDialog:populateCellForItemInSection (checkbox.onClickCallback
--- toggles + re-renders without restoreSelection - SmoothList preserves focus across reload).
function RLHerdsmanHusbandryPickerDialog:populateCellForItemInSection(list, _section, index, cell)
    if list ~= self.husbandryList then return end
    local descriptor = self.candidates[index]
    if descriptor == nil then return end
    local uid = descriptor.uniqueId

    local labelCell = cell:getAttribute("label")
    if labelCell ~= nil then
        labelCell:setText(descriptor.name or tostring(uid))
    end

    local checkbox = cell:getAttribute("checkbox")
    local check    = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            check:setVisible(self.selected[uid] == true)
            checkbox.onClickCallback = function()
                self.selected[uid] = not self.selected[uid]
                check:setVisible(self.selected[uid] == true)
                self:clearHint()
                self:_refreshSelectAllLabel()
                Log:trace("RLHerdsmanHusbandryPickerDialog: checkbox click uniqueId=%s -> %s",
                    tostring(uid), tostring(self.selected[uid]))
            end
        end
    end
end

-- =============================================================================
-- Action handlers (wired via XML onClick on profile-bound buttons)
-- =============================================================================

--- Toggle the focused row's selection. Triggered by RL_SELECT (KEY_a) or the Select button.
function RLHerdsmanHusbandryPickerDialog:onClickSelect()
    if self.husbandryList == nil then
        Log:trace("RLHerdsmanHusbandryPickerDialog:onClickSelect: no list")
        return
    end
    local index = self.husbandryList:getSelectedIndexInSection()
    if index == nil or index <= 0 then
        Log:trace("RLHerdsmanHusbandryPickerDialog:onClickSelect: no focused row")
        return
    end
    local descriptor = self.candidates[index]
    if descriptor == nil then
        Log:trace("RLHerdsmanHusbandryPickerDialog:onClickSelect: index=%d out of candidates (size=%d)",
            index, #self.candidates)
        return
    end
    local uid = descriptor.uniqueId
    self.selected[uid] = not self.selected[uid]
    self:clearHint()
    self:_refreshSelectAllLabel()
    -- Reload to re-render checkmarks; do NOT restoreSelection (SmoothList preserves focus
    -- across reloadData - same reason the value-set dialog avoids it).
    self.husbandryList:reloadData()
    Log:debug("RLHerdsmanHusbandryPickerDialog:onClickSelect: uniqueId=%s -> %s",
        tostring(uid), tostring(self.selected[uid]))
end

--- Count currently-selected CANDIDATE rows (the visible domain). Out-of-scope preserved
--- targets are not visible rows and do not factor into the select-all toggle decision.
function RLHerdsmanHusbandryPickerDialog:_getSelectedCount()
    local count = 0
    for _, descriptor in ipairs(self.candidates) do
        if self.selected[descriptor.uniqueId] == true then count = count + 1 end
    end
    return count
end

--- Update the SELECT ALL / SELECT NONE button label (mirror the value-set dialog).
function RLHerdsmanHusbandryPickerDialog:_refreshSelectAllLabel()
    if self.selectAllButton == nil or g_i18n == nil then return end
    local key = self:_getSelectedCount() > 0 and "rl_ui_selectNone" or "rl_ui_selectAll"
    self.selectAllButton:setText(g_i18n:getText(key))
end

--- Toggle every CANDIDATE row. Any visible row selected -> deselect all candidates; else
--- (zero) select all candidates (mirror RLFilterValueSetDialog: mixed states deselect first).
--- Only the visible domain is touched - preserved out-of-scope targets are untouched.
function RLHerdsmanHusbandryPickerDialog:onClickSelectAll()
    local hasSelection = self:_getSelectedCount() > 0

    if hasSelection then
        for _, descriptor in ipairs(self.candidates) do
            self.selected[descriptor.uniqueId] = nil
        end
        Log:debug("RLHerdsmanHusbandryPickerDialog:onClickSelectAll: deselected all candidates")
    else
        for _, descriptor in ipairs(self.candidates) do
            self.selected[descriptor.uniqueId] = true
        end
        Log:debug("RLHerdsmanHusbandryPickerDialog:onClickSelectAll: selected all candidates (%d)", #self.candidates)
    end

    self:clearHint()
    self:_refreshSelectAllLabel()
    if self.husbandryList ~= nil then self.husbandryList:reloadData() end
end

--- List row clicked. Moves focus only - selection toggles via the Select action or the
--- checkbox onClickCallback (matches the value-set / sell-frame UX).
function RLHerdsmanHusbandryPickerDialog:onListClick(_list, _section, index, _cell)
    Log:trace("RLHerdsmanHusbandryPickerDialog:onListClick: focus index=%d", index)
end

-- =============================================================================
-- OK / Back
-- =============================================================================

--- Commit the current selection. PRESERVE-on-commit (the deliberate divergence from the
--- value-set dialog's drift-strip): emit checked CANDIDATES in domain order FIRST, then
--- APPEND any checked uniqueId that is NOT in the candidate domain - a checked-but-out-of-
--- scope or unresolvable target - in its original currentTargets order. Only nil / empty
--- uniqueIds are dropped (the commit yields non-empty strings only). An empty result is
--- rejected (showHint, dialog stays open - distinct from the empty-candidate OK-disabled state).
function RLHerdsmanHusbandryPickerDialog:onClickOk()
    RmSafeUtils.safeCall("RLHerdsmanHusbandryPickerDialog:onClickOk", function()
        local kept = {}
        local emitted = {}
        local candidateSet = {}
        for _, descriptor in ipairs(self.candidates) do candidateSet[descriptor.uniqueId] = true end

        -- In-domain checked, domain order.
        for _, descriptor in ipairs(self.candidates) do
            local uid = descriptor.uniqueId
            if self.selected[uid] == true and type(uid) == "string" and uid ~= "" and not emitted[uid] then
                kept[#kept + 1] = uid
                emitted[uid] = true
            end
        end

        -- Preserved: checked targets outside the candidate domain (out-of-scope / unresolvable),
        -- in original currentTargets order. NEVER drift-stripped.
        local preserved = 0
        for _, uid in ipairs(self.currentTargets) do
            if self.selected[uid] == true and not candidateSet[uid]
                and type(uid) == "string" and uid ~= "" and not emitted[uid] then
                kept[#kept + 1] = uid
                emitted[uid] = true
                preserved = preserved + 1
            end
        end

        if #kept == 0 then
            Log:warning("RLHerdsmanHusbandryPickerDialog:onClickOk: refusing empty-set commit")
            self:showHint("rl_menu_herdsman_husbandry_emptyRejected")
            return
        end

        Log:debug("RLHerdsmanHusbandryPickerDialog:onClickOk: committing %d target(s) (%d preserved out-of-scope/unresolvable)",
            #kept, preserved)

        self:close()
        if self.callback ~= nil then
            if self.callbackTarget ~= nil then
                self.callback(self.callbackTarget, kept)
            else
                self.callback(kept)
            end
        end
    end)
end

--- Cancel: close + return nil (rule unchanged; current targets preserved verbatim).
function RLHerdsmanHusbandryPickerDialog:onClickBack()
    Log:debug("RLHerdsmanHusbandryPickerDialog:onClickBack: cancel")
    self:close()
    if self.callback ~= nil then
        if self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil)
        else
            self.callback(nil)
        end
    end
end

Log:debug("RLHerdsmanHusbandryPickerDialog: loaded")
