-- RLDealerSaleSelectorDialog.lua
-- Dealer sale-availability selector (B2/RLRM-545): a sectioned icon + age-range checkbox
-- list. One SECTION per catalog subType, one ROW per age stage (icon + age-range text +
-- checkbox, checked = currently buyable). A plain SELECTION-OUT control:
-- OK returns the checked in-scope for-sale set, Back returns nil. It never mutates the
-- registry / store, applies, or dispatches MP - the caller (B3/C1) reconciles the returned
-- set against baseline and owns the persistence side.
--
-- MERGES the RLHerdsmanHusbandryPickerDialog skeleton (MessageDialog lifecycle, in-place
-- checkbox toggle, RL_SELECT wiring, select-all, OK/Back callback, RmSafeUtils.safeCall)
-- with an engine-sectioned SmoothList (a listSectionHeader name-keyed header cell + row
-- cells), driven by the three-parallel-table delegate model (sectionOrder / itemsBySection
-- / titlesBySection).
--
-- The off-by-one-prone section/collect logic lives in the pure, dual-run
-- RLDealerSaleSelectorModel; this file is thin GUI wiring over it: buildSectionModel on
-- show, buildResult on OK.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleSelectorDialog = {}

local RLDealerSaleSelectorDialog_mt = Class(RLDealerSaleSelectorDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

function RLDealerSaleSelectorDialog.register()
    local dialog = RLDealerSaleSelectorDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RLDealerSaleSelectorDialog.xml",
                  "RLDealerSaleSelectorDialog", dialog)
    RLDealerSaleSelectorDialog.INSTANCE = dialog
    Log:debug("RLDealerSaleSelectorDialog.register: dialog registered")
end

function RLDealerSaleSelectorDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLDealerSaleSelectorDialog_mt)

    self.model          = nil   -- { sectionOrder, itemsBySection, titlesBySection, initialSelected, keyMeta }
    self.selected       = {}    -- working copy: map composite-key -> true (nil = unchecked)
    self.callback       = nil
    self.callbackTarget = nil

    return self
end

--- Static entry point. The caller passes the B1 catalog view-model; the dialog FULLY
--- rebuilds its per-session state (section model + selection seeded from initial buyability)
--- on EVERY call, so a prior open's toggles never leak into this one.
---@param callback function fn(target, result) - result is the checked in-scope for-sale set (array of {subTypeName, minAge}, possibly {}) on OK, or nil on cancel
---@param target table|nil callback target (the caller frame); may be nil
---@param catalog table|nil B1 catalog: RLDealerSaleCatalog.enumerate() result
function RLDealerSaleSelectorDialog.show(callback, target, catalog)
    if RLDealerSaleSelectorDialog.INSTANCE == nil then
        RLDealerSaleSelectorDialog.register()
    end

    local dialog = RLDealerSaleSelectorDialog.INSTANCE
    dialog:setData(callback, target, catalog)
    g_gui:showDialog("RLDealerSaleSelectorDialog")
end

--- Full per-open rebuild: derive the section model from the catalog and seed the working
--- selection from each row's initial (effective) buyability. Never reuses prior state.
function RLDealerSaleSelectorDialog:setData(callback, target, catalog)
    self.callback       = callback
    self.callbackTarget = target
    self.model          = RLDealerSaleSelectorModel.buildSectionModel(catalog)

    self.selected = {}
    for key, checked in pairs(self.model.initialSelected) do
        if checked == true then self.selected[key] = true end
    end

    Log:debug("RLDealerSaleSelectorDialog:setData: %d section(s), %d initially-checked",
        #self.model.sectionOrder, self:_countSelected())
end

-- =============================================================================
-- Element resolution + datasource / delegate wiring
-- =============================================================================

function RLDealerSaleSelectorDialog:onGuiSetupFinished()
    RLDealerSaleSelectorDialog:superClass().onGuiSetupFinished(self)

    self.dealerSaleList      = self:getDescendantById("dealerSaleList")
    self.emptyListText       = self:getDescendantById("emptyListText")
    self.okButton            = self:getDescendantById("okButton")
    self.selectButton        = self:getDescendantById("selectButton")
    self.selectAllButton     = self:getDescendantById("selectAllButton")
    self.dealerSaleSliderBox = self:getDescendantById("dealerSaleSliderBox")

    if self.dealerSaleList ~= nil then
        self.dealerSaleList:setDataSource(self)
        self.dealerSaleList:setDelegate(self)
    end

    -- Warn loudly on any missing critical element so an XML id drift is caught at load, not
    -- as silent mis-behaviour (a missing list = no rows; a missing okButton = un-disable-able
    -- OK on the empty state).
    local missing = {}
    if self.dealerSaleList == nil then table.insert(missing, "dealerSaleList") end
    if self.emptyListText == nil then table.insert(missing, "emptyListText") end
    if self.okButton == nil then table.insert(missing, "okButton") end
    if #missing > 0 then
        Log:warning("RLDealerSaleSelectorDialog:onGuiSetupFinished: missing elements: %s", table.concat(missing, ", "))
    end

    Log:trace("RLDealerSaleSelectorDialog:onGuiSetupFinished: elements resolved (list=%s empty=%s ok=%s)",
        tostring(self.dealerSaleList ~= nil), tostring(self.emptyListText ~= nil), tostring(self.okButton ~= nil))
end

-- =============================================================================
-- onOpen: visibility + action events + per-open geometry log
-- =============================================================================

--- Toggle the list vs the empty-state text + OK/Select/SelectAll disabled state, register
--- the RL_SELECT action event (only with rows to toggle - keyboard routing needs an explicit
--- registerActionEvent in this dialog context), refresh the section-local select-all label,
--- reload, then emit a PER-OPEN screen-space geometry log so the sectioned-list-in-a-modal
--- layout is provable from the log (the RLRM-545 S12 spike verification).
function RLDealerSaleSelectorDialog:onOpen()
    RLDealerSaleSelectorDialog:superClass().onOpen(self)

    local hasRows = self.model ~= nil and #self.model.sectionOrder > 0
    if self.dealerSaleList ~= nil then self.dealerSaleList:setVisible(hasRows) end
    if self.dealerSaleSliderBox ~= nil then self.dealerSaleSliderBox:setVisible(hasRows) end
    if self.emptyListText ~= nil then self.emptyListText:setVisible(not hasRows) end
    if self.okButton ~= nil then self.okButton:setDisabled(not hasRows) end
    if self.selectButton ~= nil then self.selectButton:setDisabled(not hasRows) end
    if self.selectAllButton ~= nil then self.selectAllButton:setDisabled(not hasRows) end

    -- RL_SELECT (KEY_a): custom mod actions do not fire from a profile binding alone in a
    -- dialog context; register explicitly + clean up in onClose. Only with rows to toggle.
    if hasRows and g_inputBinding ~= nil and InputAction ~= nil then
        g_inputBinding:registerActionEvent(
            InputAction.RL_SELECT, self, self.onClickSelect,
            false, true, false, true)
        Log:trace("RLDealerSaleSelectorDialog:onOpen: registered RL_SELECT action event")
    end

    if hasRows and self.dealerSaleList ~= nil then
        self.dealerSaleList:reloadData()
        -- Re-anchor focus to the first section/row on EACH open. The singleton reuses the
        -- SmoothList across opens; without this a prior open's focused section leaks in
        -- (reloadData only clamps a stale index into range, it does not reset it). This is the
        -- sanctioned reset-to-(1,1) on OPEN - distinct from the post-toggle restore the toggle
        -- paths avoid (SmoothList preserves focus across a toggle reload).
        self.dealerSaleList:setSelectedItem(1, 1)
    end

    -- Refresh the section-local select-all label AFTER the reload + re-anchor so it reflects
    -- the freshly focused section 1, never a stale prior-open section.
    self:_refreshSelectAllLabel()

    Log:debug("RLDealerSaleSelectorDialog:onOpen: %d section(s), %d checked%s",
        self.model ~= nil and #self.model.sectionOrder or 0, self:_countSelected(),
        hasRows and "" or " (empty catalog; OK disabled)")

    -- Per-open geometry log (screen-space, 1920x1080 reference). Skipped when empty - there
    -- is no list to measure. FS25 is Y-up, so top = absPos.y + height.
    if hasRows then
        self:_logGeometry()
    end
end

--- onClose: unregister any action events registered with self as target. Without this the
--- RL_SELECT binding leaks across dialog opens.
function RLDealerSaleSelectorDialog:onClose()
    RLDealerSaleSelectorDialog:superClass().onClose(self)
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEventsByTarget(self)
        Log:trace("RLDealerSaleSelectorDialog:onClose: removed action events by target")
    end
end

--- Per-open screen-space geometry of the top-level list container + slider + OK button, so
--- the modal-context layout of the sectioned list is provable from the log (not eyeballed).
function RLDealerSaleSelectorDialog:_logGeometry()
    local function logElem(name, e)
        if e == nil then
            Log:debug("RLDealerSaleSelectorDialog._geom: %s == nil", name); return
        end
        local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
        local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
        local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
        local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
        Log:debug("RLDealerSaleSelectorDialog._geom: %s size=(%.1fx%.1f) absPos=(%.1f,%.1f) top=%.1f bottom=%.1f",
            name, sw, sh, ax, ay, ay + sh, ay)
    end
    logElem("dealerSaleList",      self.dealerSaleList)
    logElem("dealerSaleSliderBox", self.dealerSaleSliderBox)
    logElem("okButton",            self.okButton)
end

-- =============================================================================
-- SmoothList DataSource (sectioned)
-- =============================================================================

function RLDealerSaleSelectorDialog:getNumberOfSections(list)
    if list ~= self.dealerSaleList or self.model == nil then return 0 end
    return #self.model.sectionOrder
end

function RLDealerSaleSelectorDialog:getNumberOfItemsInSection(list, section)
    if list ~= self.dealerSaleList or self.model == nil then return 0 end
    local key = self.model.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.model.itemsBySection[key]
    return items ~= nil and #items or 0
end

function RLDealerSaleSelectorDialog:getTitleForSectionHeader(list, section)
    if list ~= self.dealerSaleList or self.model == nil then return nil end
    local key = self.model.sectionOrder[section]
    return key and self.model.titlesBySection[key] or nil
end

--- Populate one data row: icon (hidden on nil OR empty), subType label (self-identifying
--- while scrolling), age-range text, and a checkbox reflecting the per-key selection. The
--- checkbox onClickCallback toggles in place and re-renders without reloadData (SmoothList
--- preserves focus; mirror the picker / buy-frame).
function RLDealerSaleSelectorDialog:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.dealerSaleList or self.model == nil then return end
    local sectionKey = self.model.sectionOrder[section]
    if sectionKey == nil then return end
    local items = self.model.itemsBySection[sectionKey]
    if items == nil then return end
    local row = items[index]
    if row == nil then return end

    local iconCell = cell:getAttribute("icon")
    if iconCell ~= nil then
        if row.iconFilename ~= nil and row.iconFilename ~= "" then
            iconCell:setImageFilename(row.iconFilename)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    -- Row label = the age band ("N-M months"); the subType is named by the section header, so it
    -- is not repeated per row (few rows per subType - repetition beside the header reads as clutter).
    -- Reuses the shared rl_ui_formatMonths ("%s months") key; age bands are always plural ranges.
    local ageCell = cell:getAttribute("ageRange")
    if ageCell ~= nil then
        local text = row.ageRangeLabel or ""
        if text ~= "" and g_i18n ~= nil then
            text = string.format(g_i18n:getText("rl_ui_formatMonths"), row.ageRangeLabel)
        end
        ageCell:setText(text)
    end

    local checkbox = cell:getAttribute("checkbox")
    local check    = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            local cellKey = row.key
            -- Log the DECOMPOSED (subTypeName, minAge) - never the composite key, whose U+001F
            -- separator has no glyph in the console texture font ("Character '31' not found").
            local rowSubType, rowMinAge = row.subTypeName, row.minAge
            check:setVisible(self.selected[cellKey] == true)
            checkbox.onClickCallback = function()
                self:_toggle(cellKey)
                check:setVisible(self.selected[cellKey] == true)
                self:_refreshSelectAllLabel()
                Log:debug("RLDealerSaleSelectorDialog: checkbox toggle %s @%s -> %s",
                    tostring(rowSubType), tostring(rowMinAge), tostring(self.selected[cellKey] == true))
            end
        end
    end
end

--- Delegate hook the SmoothList fires on focus change (and on reload). Refresh the
--- section-LOCAL select-all label so it reflects the newly focused section.
function RLDealerSaleSelectorDialog:onListSelectionChanged(list, section, index)
    if list ~= self.dealerSaleList then return end
    self:_refreshSelectAllLabel()
    Log:trace("RLDealerSaleSelectorDialog:onListSelectionChanged: section=%s index=%s",
        tostring(section), tostring(index))
end

--- List row clicked: moves focus only - selection toggles via the Select action or the
--- checkbox onClickCallback (matches the picker / sell-frame UX).
function RLDealerSaleSelectorDialog:onListClick(_list, section, index, _cell)
    Log:trace("RLDealerSaleSelectorDialog:onListClick: focus section=%s index=%s",
        tostring(section), tostring(index))
end

-- =============================================================================
-- Selection helpers
-- =============================================================================

--- Flip one key's checked state, keeping the map to true / nil (never false).
function RLDealerSaleSelectorDialog:_toggle(key)
    if self.selected[key] == true then
        self.selected[key] = nil
    else
        self.selected[key] = true
    end
end

--- Total checked keys (for the open/debug log). Only `true` values count.
function RLDealerSaleSelectorDialog:_countSelected()
    local n = 0
    for _, v in pairs(self.selected) do
        if v == true then n = n + 1 end
    end
    return n
end

--- Rows of the currently focused section (selectedSectionIndex inits to 1, so a pre-focus
--- press acts on section 1), or nil if there is no such section.
function RLDealerSaleSelectorDialog:_focusedSectionRows()
    if self.dealerSaleList == nil or self.model == nil then return nil end
    local section = self.dealerSaleList.selectedSectionIndex or 1
    local key = self.model.sectionOrder[section]
    return key and self.model.itemsBySection[key] or nil, section, key
end

--- True when any row in the FOCUSED section is checked.
function RLDealerSaleSelectorDialog:_focusedSectionHasSelection()
    local rows = self:_focusedSectionRows()
    if rows == nil then return false end
    for _, row in ipairs(rows) do
        if self.selected[row.key] == true then return true end
    end
    return false
end

--- Update the SELECT ALL / SELECT NONE button label - SECTION-LOCAL (reflects the focused
--- section). Reuses the shared rl_ui_selectAll / rl_ui_selectNone keys.
function RLDealerSaleSelectorDialog:_refreshSelectAllLabel()
    if self.selectAllButton == nil or g_i18n == nil then return end
    local key = self:_focusedSectionHasSelection() and "rl_ui_selectNone" or "rl_ui_selectAll"
    self.selectAllButton:setText(g_i18n:getText(key))
end

-- =============================================================================
-- Action handlers
-- =============================================================================

--- Toggle the focused row's selection. Triggered by RL_SELECT (KEY_a) or the Select button.
--- SECTION-AWARE: resolve BOTH the focused section and the row within it (a single flat
--- index is wrong once there are multiple sections). Reload to re-render the checkmark; do
--- NOT restoreSelection (SmoothList preserves focus across reloadData).
function RLDealerSaleSelectorDialog:onClickSelect()
    if self.dealerSaleList == nil or self.model == nil then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: no list/model")
        return
    end
    local section = self.dealerSaleList.selectedSectionIndex
    local index   = self.dealerSaleList:getSelectedIndexInSection()
    if section == nil or index == nil or index <= 0 then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: no focused row (section=%s index=%s)",
            tostring(section), tostring(index))
        return
    end
    local key  = self.model.sectionOrder[section]
    local rows = key and self.model.itemsBySection[key]
    local row  = rows and rows[index]
    if row == nil then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: (section=%s,index=%s) out of range",
            tostring(section), tostring(index))
        return
    end

    self:_toggle(row.key)
    self:_refreshSelectAllLabel()
    self.dealerSaleList:reloadData()
    -- Decomposed, not the composite key (its U+001F separator is a non-glyph in the console font).
    Log:debug("RLDealerSaleSelectorDialog:onClickSelect: %s @%s -> %s",
        tostring(row.subTypeName), tostring(row.minAge), tostring(self.selected[row.key] == true))
end

--- Select-all / none over the FOCUSED section only. Any row in that section selected ->
--- clear the section; else select the whole section. Other sections are untouched.
function RLDealerSaleSelectorDialog:onClickSelectAll()
    local rows, section, key = self:_focusedSectionRows()
    if rows == nil then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelectAll: no focused section")
        return
    end

    local hasSelection = self:_focusedSectionHasSelection()
    local newState = not hasSelection
    for _, row in ipairs(rows) do
        self.selected[row.key] = newState and true or nil
    end

    self:_refreshSelectAllLabel()
    if self.dealerSaleList ~= nil then self.dealerSaleList:reloadData() end
    Log:debug("RLDealerSaleSelectorDialog:onClickSelectAll: section=%d (%s) -> %s %d row(s)",
        section, tostring(key), hasSelection and "cleared" or "selected", #rows)
end

--- Commit: collect the checked in-scope rows and return them. NO empty-set reject - an
--- all-unchecked commit returns {} ("nothing for sale" is legitimate). The dialog is free
--- of registry / apply / MP knowledge - it returns a set, full stop.
function RLDealerSaleSelectorDialog:onClickOk()
    RmSafeUtils.safeCall("RLDealerSaleSelectorDialog:onClickOk", function()
        -- Empty-catalog defence-in-depth: OK is setDisabled on the empty state, but do not rely
        -- solely on the disabled button routing MENU_ACCEPT - ignore an OK with no sections.
        if self.model == nil or #self.model.sectionOrder == 0 then
            Log:debug("RLDealerSaleSelectorDialog:onClickOk: empty catalog; ignoring OK (no commit)")
            return
        end

        local result = RLDealerSaleSelectorModel.buildResult(
            self.selected, self.model.keyMeta, self.model.sectionOrder, self.model.itemsBySection)

        Log:debug("RLDealerSaleSelectorDialog:onClickOk: committing %d in-scope row(s) (no empty reject)", #result)

        self:close()
        if self.callback ~= nil then
            self.callback(self.callbackTarget, result)
        end
    end)
end

--- Cancel: close + return nil (the caller treats nil as "no change").
function RLDealerSaleSelectorDialog:onClickBack()
    Log:debug("RLDealerSaleSelectorDialog:onClickBack: cancel")
    self:close()
    if self.callback ~= nil then
        self.callback(self.callbackTarget, nil)
    end
end

Log:debug("RLDealerSaleSelectorDialog: loaded")
