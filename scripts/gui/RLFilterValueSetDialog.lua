-- RLFilterValueSetDialog.lua
-- P1-4b-2 multi-select dialog opened from RLFilterConditionDialog's value
-- row when cmp = `in`/`notin`. User toggles per-row checkmarks; OK commits
-- an array of stable internal keys back to the condition dialog. Empty-set
-- on OK is rejected (mirrors the empty-string reject in the condition
-- dialog). Drifted stored values are stripped on commit + WARN-logged.
--
-- Mirrors the AnimalMoveDestinationDialog modal-with-SmoothList pattern and
-- the Sell/Buy/Move-frame row-checkmark binding: cell:getAttribute("checkbox")
-- + cell:getAttribute("check") populated in populateCellForItemInSection,
-- mouse click hits checkbox.onClickCallback, RL_SELECT (KEY_a) toggles the
-- focused row, MENU_ACTIVATE (Space) toggles-all. Action-bar buttons declare
-- the input bindings via profile so the visible button text doubles as the
-- input-help-bar prompt.
--
-- Author: Ritter

local Log = RmLogging.getLogger("RLRM")

RLFilterValueSetDialog = {}

local RLFilterValueSetDialog_mt = Class(RLFilterValueSetDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

function RLFilterValueSetDialog.register()
    local dialog = RLFilterValueSetDialog.new()
    g_gui:loadGui(modDirectory .. "gui/rlFilterValueSetDialog.xml",
                  "RLFilterValueSetDialog", dialog)
    RLFilterValueSetDialog.INSTANCE = dialog
    Log:debug("RLFilterValueSetDialog.register: dialog registered")
end

function RLFilterValueSetDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLFilterValueSetDialog_mt)

    self.callback       = nil
    self.callbackTarget = nil
    self.fieldKey       = nil       -- "gender" / "subType"
    self.animalType     = nil       -- AnimalType index or nil for ANY
    self.domain         = {}        -- ordered array of stable internal keys
    self.labels         = {}        -- domain-aligned display labels (i18n + fallback)
    self.selected       = {}        -- map keyed by internal key, value=true when checked

    return self
end

--- Static entry point. Caller passes the current list value (an array of
--- internal keys, possibly containing drifted values not in the resolved
--- domain - those render unchecked and are stripped on OK commit).
---@param callback function fn(target, list|nil) - list of selected internal keys, nil on cancel
---@param target table callback target (the condition dialog)
---@param fieldKey string "gender" or "subType"
---@param animalType number|nil filter scope; nil triggers cross-species union for subType
---@param initialList table|nil array of internal keys to pre-check (drift-tolerant)
function RLFilterValueSetDialog.show(callback, target, fieldKey, animalType, initialList)
    if RLFilterValueSetDialog.INSTANCE == nil then
        RLFilterValueSetDialog.register()
    end

    local dialog = RLFilterValueSetDialog.INSTANCE
    dialog.callback       = callback
    dialog.callbackTarget = target
    dialog.fieldKey       = fieldKey
    dialog.animalType     = animalType
    dialog.selected       = {}
    if type(initialList) == "table" then
        for _, key in ipairs(initialList) do
            dialog.selected[key] = true
        end
    end

    Log:debug("RLFilterValueSetDialog.show: fieldKey=%s animalType=%s initialList=%d",
        tostring(fieldKey), tostring(animalType),
        type(initialList) == "table" and #initialList or 0)

    g_gui:showDialog("RLFilterValueSetDialog")
end

-- =============================================================================
-- Element resolution + datasource wiring
-- =============================================================================

function RLFilterValueSetDialog:onGuiSetupFinished()
    RLFilterValueSetDialog:superClass().onGuiSetupFinished(self)

    self.valueList       = self:getDescendantById("valueList")
    self.hintText        = self:getDescendantById("hintText")
    self.okButton        = self:getDescendantById("okButton")
    self.selectAllButton = self:getDescendantById("selectAllButton")

    if self.valueList ~= nil then
        self.valueList:setDataSource(self)
    else
        Log:warning("RLFilterValueSetDialog:onGuiSetupFinished: valueList missing")
    end

    Log:trace("RLFilterValueSetDialog:onGuiSetupFinished: elements resolved (list=%s hint=%s)",
        tostring(self.valueList ~= nil), tostring(self.hintText ~= nil))
end

-- =============================================================================
-- Hint surface (mirrors RLFilterConditionDialog:showHint / clearHint)
-- =============================================================================

function RLFilterValueSetDialog:showHint(l10nKey)
    if self.hintText == nil then
        Log:warning("RLFilterValueSetDialog:showHint: hintText element missing; cannot surface key=%s",
            tostring(l10nKey))
        return
    end
    local text = (g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(l10nKey))
                 and g_i18n:getText(l10nKey)
                 or tostring(l10nKey)
    self.hintText:setText(text)
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(true) end
    Log:debug("RLFilterValueSetDialog:showHint: key=%s", tostring(l10nKey))
end

function RLFilterValueSetDialog:clearHint()
    if self.hintText == nil then return end
    self.hintText:setText("")
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(false) end
    Log:trace("RLFilterValueSetDialog:clearHint")
end

-- =============================================================================
-- onOpen: resolve domain + labels, refresh list
-- =============================================================================

function RLFilterValueSetDialog:onOpen()
    RLFilterValueSetDialog:superClass().onOpen(self)

    -- Resolve domain. animalType==nil triggers the cross-species union path
    -- for subType (per P1-4b-2 design decision #3); gender stays fixed and
    -- ignores the scope.
    if self.fieldKey == "subType" and self.animalType == nil then
        self.domain = RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
    else
        self.domain = RLFilterFieldDisplay.getEnumDomain(self.fieldKey, self.animalType)
    end
    if self.domain == nil then self.domain = {} end

    -- Resolve display labels in lockstep with the domain so populateCell can
    -- index by row position. For the cross-species subType union, prepend
    -- the animal-type i18n for cross-type disambiguation (per spec line 29).
    self.labels = {}
    for i, key in ipairs(self.domain) do
        self.labels[i] = self:_resolveLabel(key)
    end

    self:clearHint()
    self:_refreshSelectAllLabel()

    -- Register RL_SELECT (KEY_a) as an explicit dialog action event. Profile-
    -- bound inputAction on rlButtonSelect handles the mouse-click + button-bar
    -- prompt rendering, but in this dialog context custom mod actions like
    -- RL_SELECT don't fire from a profile binding alone - the keyboard
    -- routing requires an explicit registerActionEvent. Same hybrid pattern
    -- the EarTagColourPickerDialog uses for its custom AXIS actions.
    if g_inputBinding ~= nil and InputAction ~= nil then
        g_inputBinding:registerActionEvent(
            InputAction.RL_SELECT, self, self.onClickSelect,
            false, true, false, true)
        Log:trace("RLFilterValueSetDialog:onOpen: registered RL_SELECT action event")
    end

    if self.valueList ~= nil then
        self.valueList:reloadData()
    end

    local preCheckedCount = 0
    for _ in pairs(self.selected) do preCheckedCount = preCheckedCount + 1 end

    Log:debug("RLFilterValueSetDialog:onOpen: fieldKey=%s animalType=%s domain=%d preChecked=%d",
        tostring(self.fieldKey), tostring(self.animalType),
        #self.domain, preCheckedCount)

    -- RLRM-280 one-shot geometry log. Computes the screen-space bounding box
    -- of the value list, the hint surface, and the action-bar buttons so the
    -- hint position can be placed between list-bottom and action-bar-top
    -- without guessing.
    local function _logElem(name, e)
        if e == nil then
            Log:debug("RLFilterValueSetDialog._geom: %s == nil", name); return
        end
        local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
        local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
        local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
        local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
        Log:debug("RLFilterValueSetDialog._geom: %s absPos=(%.1f,%.1f) size=(%.1fx%.1f) top=%.1f bottom=%.1f left=%.1f right=%.1f",
            name, ax, ay, sw, sh, ay + sh, ay, ax, ax + sw)
    end
    _logElem("valueList",       self.valueList)
    _logElem("hintText",        self.hintText)
    _logElem("okButton",        self.okButton)
    _logElem("selectAllButton", self.selectAllButton)
end

--- onClose: unregister any action events registered with self as target.
--- Mirrors EarTagColourPickerDialog.lua:113 cleanup pattern. Without this,
--- the RL_SELECT binding leaks across dialog opens.
function RLFilterValueSetDialog:onClose()
    RLFilterValueSetDialog:superClass().onClose(self)
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEventsByTarget(self)
        Log:trace("RLFilterValueSetDialog:onClose: removed action events by target")
    end
end

--- Resolve a row label. For the unscoped subType union, prefix the animal-
--- type i18n so two species with name-different breeds disambiguate at a
--- glance ("COW: Holstein", "PIG: Yorkshire"). Subtype names are globally
--- unique (the AnimalSystem XML loader rejects duplicates), so the prefix
--- is decorative, not a key-collision fix.
function RLFilterValueSetDialog:_resolveLabel(internalKey)
    if self.fieldKey == "subType" and self.animalType == nil then
        local base = RLFilterFieldDisplay.getEnumValueDisplayName("subType", internalKey, nil)
        local prefix = self:_resolveAnimalTypePrefixFor(internalKey)
        if prefix ~= nil and prefix ~= "" then
            return string.format("%s: %s", prefix, base)
        end
        return base
    end
    return RLFilterFieldDisplay.getEnumValueDisplayName(self.fieldKey, internalKey, self.animalType)
end

--- Look up which animalType owns a given subType.name. Walks the global
--- subTypes array (each subType carries a `.typeIndex` linking it to its
--- then delegates label resolution to RLAnimalUtil.getAnimalTypeDisplayName
--- (cascade: groupTitle -> title -> ui_<name>s -> name -> "?"). Same helper
--- used by AnimalScreen, sell service, dewar data, AI straw inspector.
function RLFilterValueSetDialog:_resolveAnimalTypePrefixFor(subTypeName)
    if g_currentMission == nil or g_currentMission.animalSystem == nil then return "" end
    local subTypes = g_currentMission.animalSystem.subTypes or {}
    local typeIndex = nil
    for _, st in ipairs(subTypes) do
        if st ~= nil and st.name == subTypeName then
            typeIndex = st.typeIndex
            break
        end
    end
    if typeIndex == nil then return "" end
    local animalSystem = g_currentMission.animalSystem
    if animalSystem.types ~= nil then
        for _, at in pairs(animalSystem.types) do
            if at ~= nil and at.typeIndex == typeIndex then
                return RLAnimalUtil.getAnimalTypeDisplayName(at)
            end
        end
    end
    return ""
end

-- =============================================================================
-- SmoothList DataSource
-- =============================================================================

function RLFilterValueSetDialog:getNumberOfSections()
    return 1
end

function RLFilterValueSetDialog:getNumberOfItemsInSection(_list, _section)
    return #self.domain
end

function RLFilterValueSetDialog:getTitleForSectionHeader(_list, _section)
    return ""
end

--- Populate one row. Mirrors RLMenuSellFrame.lua:927-944 verbatim for the
--- checkbox wiring: check:setVisible reflects current state, and
--- checkbox.onClickCallback toggles + re-renders without restoreSelection
--- (SmoothList preserves focus across reloadData).
function RLFilterValueSetDialog:populateCellForItemInSection(list, _section, index, cell)
    if list ~= self.valueList then return end
    local key   = self.domain[index]
    local label = self.labels[index]
    if key == nil then return end

    local labelCell = cell:getAttribute("label")
    if labelCell ~= nil then
        labelCell:setText(label or tostring(key))
    end

    local checkbox = cell:getAttribute("checkbox")
    local check    = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            check:setVisible(self.selected[key] == true)
            checkbox.onClickCallback = function()
                self.selected[key] = not self.selected[key]
                check:setVisible(self.selected[key] == true)
                self:clearHint()
                self:_refreshSelectAllLabel()
                Log:trace("RLFilterValueSetDialog: checkbox click key=%s -> %s",
                    tostring(key), tostring(self.selected[key]))
            end
        end
    end
end

-- =============================================================================
-- Action handlers (wired via XML onClick on profile-bound buttons)
-- =============================================================================

--- Toggle the focused row's selection. Triggered by RL_SELECT (KEY_a) via
--- the rlButtonSelect profile, or by clicking the Select button in the
--- action bar.
function RLFilterValueSetDialog:onClickSelect()
    if self.valueList == nil then
        Log:trace("RLFilterValueSetDialog:onClickSelect: no list")
        return
    end
    local index = self.valueList:getSelectedIndexInSection()
    if index == nil or index <= 0 then
        Log:trace("RLFilterValueSetDialog:onClickSelect: no focused row")
        return
    end
    local key = self.domain[index]
    if key == nil then
        Log:trace("RLFilterValueSetDialog:onClickSelect: index=%d out of domain (size=%d)",
            index, #self.domain)
        return
    end
    self.selected[key] = not self.selected[key]
    self:clearHint()
    self:_refreshSelectAllLabel()
    -- Reload to re-render checkmarks. Do NOT restoreSelection / setSelectedItem
    -- - SmoothList preserves focus across reloadData; calling restoreSelection
    -- would reset focus to (1,1) (see RLMenuSellFrame.lua:717-719).
    self.valueList:reloadData()
    Log:debug("RLFilterValueSetDialog:onClickSelect: key=%s -> %s",
        tostring(key), tostring(self.selected[key]))
end

--- Count currently-selected rows in domain order. Used by the select-all
--- toggle + the dynamic button-label refresh.
function RLFilterValueSetDialog:_getSelectedCount()
    local count = 0
    for _, key in ipairs(self.domain) do
        if self.selected[key] == true then count = count + 1 end
    end
    return count
end

--- Update the SELECT ALL / SELECT NONE button label to reflect the current
--- selection state. Mirrors RLMenuSellFrame's selectAllButtonInfo pattern
--- (sellFrame.lua:572-573): selected>0 -> "Select none", else "Select all".
--- Translation keys both already shipped (sell-frame uses them).
function RLFilterValueSetDialog:_refreshSelectAllLabel()
    if self.selectAllButton == nil or g_i18n == nil then return end
    local key = self:_getSelectedCount() > 0 and "rl_ui_selectNone" or "rl_ui_selectAll"
    self.selectAllButton:setText(g_i18n:getText(key))
end

--- Toggle every row. If any row is currently selected, deselect all;
--- otherwise (zero selected) select all. Mirrors RLMenuSellFrame:onClickSelectAll
--- (sellFrame.lua:729-751): mixed states deselect first (one Space press
--- clears the list rather than committing to "all on" which a player
--- mid-curation would not want). Triggered by MENU_ACTIVATE (Space) via the
--- rlButtonMenuActivate profile, or by clicking the Select all button.
function RLFilterValueSetDialog:onClickSelectAll()
    local hasSelection = self:_getSelectedCount() > 0

    if hasSelection then
        for _, key in ipairs(self.domain) do
            self.selected[key] = nil
        end
        Log:debug("RLFilterValueSetDialog:onClickSelectAll: deselected all")
    else
        for _, key in ipairs(self.domain) do
            self.selected[key] = true
        end
        Log:debug("RLFilterValueSetDialog:onClickSelectAll: selected all (%d)", #self.domain)
    end

    self:clearHint()
    self:_refreshSelectAllLabel()
    if self.valueList ~= nil then self.valueList:reloadData() end
end

--- List row clicked. Moves focus only - selection toggle happens via the
--- Select action or the checkbox onClickCallback. Matches sell-frame UX
--- (row click = focus, NOT a checkbox toggle - prevents accidental selects
--- when the user just wants to navigate).
function RLFilterValueSetDialog:onListClick(_list, _section, index, _cell)
    Log:trace("RLFilterValueSetDialog:onListClick: focus index=%d", index)
end

-- =============================================================================
-- OK / Back
-- =============================================================================

--- Commit the current selection. Builds an array of internal keys in domain
--- order (deterministic). Drifted keys in self.selected (those no longer in
--- the resolved domain) are stripped here + WARN-logged - this is the
--- explicit re-commit path that clears the condition dialog's valueDrifted
--- flag (per spec finding #4 fix).
function RLFilterValueSetDialog:onClickOk()
    RmSafeUtils.safeCall("RLFilterValueSetDialog:onClickOk", function()
        -- Collect selected keys that survive the domain check (drift-strip).
        local kept = {}
        local domainSet = {}
        for _, key in ipairs(self.domain) do domainSet[key] = true end

        for _, key in ipairs(self.domain) do
            if self.selected[key] == true then
                table.insert(kept, key)
            end
        end

        -- Identify drifted keys (in self.selected but not in current domain).
        local dropped = {}
        for key, sel in pairs(self.selected) do
            if sel == true and not domainSet[key] then
                table.insert(dropped, key)
            end
        end
        if #dropped > 0 then
            Log:warning("RLFilterValueSetDialog:onClickOk: dropping %d drifted key(s): %s",
                #dropped, table.concat(dropped, ", "))
        end

        if #kept == 0 then
            Log:warning("RLFilterValueSetDialog:onClickOk: refusing empty-set commit (fieldKey=%s)",
                tostring(self.fieldKey))
            self:showHint("rl_menu_filters_emptyValueRejected")
            return
        end

        Log:debug("RLFilterValueSetDialog:onClickOk: committing %d key(s) (fieldKey=%s)",
            #kept, tostring(self.fieldKey))

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

function RLFilterValueSetDialog:onClickBack()
    Log:debug("RLFilterValueSetDialog:onClickBack: cancel (fieldKey=%s)",
        tostring(self.fieldKey))
    self:close()
    if self.callback ~= nil then
        if self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil)
        else
            self.callback(nil)
        end
    end
end

Log:debug("RLFilterValueSetDialog: loaded")
