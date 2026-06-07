-- RLHerdsmanFilterPickerDialog.lua
-- Single-select modal that binds ONE saved filter to a herdsman rule. The Herdsman
-- frame computes the operation-scoped, alpha-sorted candidate list and passes it in;
-- this dialog is presentation-only - it renders the list, tracks the selection, and
-- returns the chosen filterId (or nil on cancel) to the caller.
--
-- Mirrors AnimalMoveDestinationDialog's single-select list+OK SHAPE (setDataSource,
-- getSelectedIndexInSection on confirm, confirm-disabled-on-empty) with
-- RLFilterValueSetDialog's RL conventions (register-on-show singleton, RmLogging, LuaDoc).
-- The only comparison it makes is the preselect match (filters[i].id == currentFilterId);
-- scoping and sorting are the frame's job, so the dialog renders the list as given.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanFilterPickerDialog = {}

local RLHerdsmanFilterPickerDialog_mt = Class(RLHerdsmanFilterPickerDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

function RLHerdsmanFilterPickerDialog.register()
    local dialog = RLHerdsmanFilterPickerDialog.new()
    g_gui:loadGui(modDirectory .. "gui/rlHerdsmanFilterPickerDialog.xml",
                  "RLHerdsmanFilterPickerDialog", dialog)
    RLHerdsmanFilterPickerDialog.INSTANCE = dialog
    Log:debug("RLHerdsmanFilterPickerDialog.register: dialog registered")
end

function RLHerdsmanFilterPickerDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLHerdsmanFilterPickerDialog_mt)

    self.filters         = {}
    self.callback        = nil
    self.callbackTarget  = nil
    self.currentFilterId = nil
    self.selectedIndex   = nil

    return self
end

--- Static entry point. The frame passes the already-scoped, already-sorted candidate list
--- and the rule's current filterId for preselection.
---@param callback function fn(target, filterId|nil) - chosen filter id on OK, nil on cancel
---@param target table callback target (the Herdsman frame)
---@param filters table[] candidate filter records (each with id + name), scoped + sorted by the frame
---@param currentFilterId string|nil the rule's current filter id, preselected when present in the list
function RLHerdsmanFilterPickerDialog.show(callback, target, filters, currentFilterId)
    if RLHerdsmanFilterPickerDialog.INSTANCE == nil then
        RLHerdsmanFilterPickerDialog.register()
    end

    local dialog = RLHerdsmanFilterPickerDialog.INSTANCE
    dialog.filters         = filters or {}
    dialog.callback        = callback
    dialog.callbackTarget  = target
    dialog.currentFilterId = currentFilterId
    dialog.selectedIndex   = nil

    Log:debug("RLHerdsmanFilterPickerDialog.show: %d candidate(s), currentFilterId=%s",
        #dialog.filters, tostring(currentFilterId))
    g_gui:showDialog("RLHerdsmanFilterPickerDialog")
end

-- =============================================================================
-- Element resolution + datasource wiring
-- =============================================================================

function RLHerdsmanFilterPickerDialog:onGuiSetupFinished()
    RLHerdsmanFilterPickerDialog:superClass().onGuiSetupFinished(self)

    self.filterList     = self:getDescendantById("filterList")
    self.emptyListText  = self:getDescendantById("emptyListText")
    self.confirmButton  = self:getDescendantById("confirmButton")
    self.filterSliderBox = self:getDescendantById("filterSliderBox")

    if self.filterList ~= nil then
        self.filterList:setDataSource(self)
    end

    -- Warn loudly on any missing critical element so an XML id drift is caught at load, not as
    -- silent mis-behavior (e.g. a missing confirmButton would leave OK un-disable-able on empty).
    local missing = {}
    if self.filterList == nil then table.insert(missing, "filterList") end
    if self.emptyListText == nil then table.insert(missing, "emptyListText") end
    if self.confirmButton == nil then table.insert(missing, "confirmButton") end
    if #missing > 0 then
        Log:warning("RLHerdsmanFilterPickerDialog:onGuiSetupFinished: missing elements: %s", table.concat(missing, ", "))
    end

    Log:trace("RLHerdsmanFilterPickerDialog:onGuiSetupFinished: elements resolved (list=%s empty=%s confirm=%s)",
        tostring(self.filterList ~= nil), tostring(self.emptyListText ~= nil), tostring(self.confirmButton ~= nil))
end

-- =============================================================================
-- onOpen: visibility + preselect
-- =============================================================================

--- Resolve visibility, reload the list, and preselect the row whose filter id matches the
--- rule's current binding (row 1 when absent / nil / out-of-scope). Empty list -> empty text
--- + disabled OK (mirrors AnimalMoveDestinationDialog:onOpen).
function RLHerdsmanFilterPickerDialog:onOpen()
    RLHerdsmanFilterPickerDialog:superClass().onOpen(self)

    local hasEntries = #self.filters > 0
    if self.filterList ~= nil then self.filterList:setVisible(hasEntries) end
    if self.filterSliderBox ~= nil then self.filterSliderBox:setVisible(hasEntries) end
    if self.emptyListText ~= nil then self.emptyListText:setVisible(not hasEntries) end
    if self.confirmButton ~= nil then self.confirmButton:setDisabled(not hasEntries) end

    if hasEntries and self.filterList ~= nil then
        self.filterList:reloadData()

        -- Preselect by id (NOT mirrored from the move dialog, which forces row 1): find the
        -- candidate whose id equals the rule's current filter; default to row 1 when the id
        -- is nil / deleted / out-of-scope. setSelectedItem highlights without firing a change
        -- event (forceChangeEvent=false); confirm reads the row via getSelectedIndexInSection.
        local idx = 1
        local matched = false
        if self.currentFilterId ~= nil then
            for i, f in ipairs(self.filters) do
                if f.id == self.currentFilterId then idx = i; matched = true; break end
            end
        end
        self.filterList:setSelectedItem(1, idx, false, true)
        self.selectedIndex = idx

        Log:debug("RLHerdsmanFilterPickerDialog:onOpen: %d candidate(s), preselect idx=%d (matched=%s currentFilterId=%s)",
            #self.filters, idx, tostring(matched), tostring(self.currentFilterId))
    else
        Log:debug("RLHerdsmanFilterPickerDialog:onOpen: empty candidate list; OK disabled")
    end
end

-- =============================================================================
-- SmoothList DataSource
-- =============================================================================

function RLHerdsmanFilterPickerDialog:getNumberOfSections()
    return 1
end

function RLHerdsmanFilterPickerDialog:getNumberOfItemsInSection(_list, _section)
    return #self.filters
end

function RLHerdsmanFilterPickerDialog:getTitleForSectionHeader(_list, _section)
    return ""
end

--- Populate one row with the filter NAME only (no secondary descriptor - there is no
--- formatting contract for one). Mirrors AnimalMoveDestinationDialog:populateCell.
function RLHerdsmanFilterPickerDialog:populateCellForItemInSection(list, _section, index, cell)
    if list ~= self.filterList then return end
    local filter = self.filters[index]
    if filter == nil then return end

    local nameElement = cell:getAttribute("filterName")
    if nameElement ~= nil then
        nameElement:setText(filter.name or "")
    end

    Log:trace("RLHerdsmanFilterPickerDialog:populateCell: index=%d id=%s name=%q",
        index, tostring(filter.id), tostring(filter.name))
end

-- =============================================================================
-- Selection + OK / Back
-- =============================================================================

--- Row click moves the selection + (re)enables OK. Keyboard / gamepad nav is read on confirm
--- via getSelectedIndexInSection (mirror AnimalMoveDestinationDialog:onListClick).
function RLHerdsmanFilterPickerDialog:onListClick(_list, _section, index, _cell)
    self.selectedIndex = index
    if self.confirmButton ~= nil then self.confirmButton:setDisabled(false) end
    Log:trace("RLHerdsmanFilterPickerDialog:onListClick: selected index=%d", index)
end

--- Confirm: read the live SmoothList selection (tracks keyboard / gamepad nav), resolve it to
--- a filterId, close, and hand it back. No valid selection -> nil (the caller treats nil as a
--- no-op, same as cancel).
function RLHerdsmanFilterPickerDialog:onClickConfirm()
    local selectedIndex = self.filterList ~= nil and self.filterList:getSelectedIndexInSection() or nil
    -- Fall back to the click/open-tracked index when the list reports no live selection on a
    -- non-empty list (focus navigated off the ends), so OK on a populated list never silently
    -- no-ops as a phantom cancel.
    if (selectedIndex == nil or selectedIndex <= 0) and #self.filters > 0 then
        selectedIndex = self.selectedIndex
    end
    local filter = nil
    if selectedIndex ~= nil and selectedIndex > 0 then
        filter = self.filters[selectedIndex]
    end
    local filterId = filter ~= nil and filter.id or nil

    Log:debug("RLHerdsmanFilterPickerDialog:onClickConfirm: selectedIndex=%s -> filterId=%s",
        tostring(selectedIndex), tostring(filterId))

    self:close()
    if self.callback ~= nil then
        if self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, filterId)
        else
            self.callback(filterId)
        end
    end
end

--- Cancel: close + return nil (rule unchanged).
function RLHerdsmanFilterPickerDialog:onClickCancel()
    Log:debug("RLHerdsmanFilterPickerDialog:onClickCancel")
    self:close()
    if self.callback ~= nil then
        if self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil)
        else
            self.callback(nil)
        end
    end
end

Log:debug("RLHerdsmanFilterPickerDialog: loaded")
