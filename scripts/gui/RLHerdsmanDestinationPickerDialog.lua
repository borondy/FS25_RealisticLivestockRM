-- RLHerdsmanDestinationPickerDialog.lua
-- SINGLE-select modal that binds ONE destination husbandry to a move rule. The Herdsman frame
-- computes the type-gated, source-excluded, alpha-sorted candidate list and passes it in; this
-- dialog is presentation-only - it renders the husbandry-name list, tracks the selection, and
-- returns the chosen husbandry uniqueId (or nil on cancel) to the caller.
--
-- The husbandry-name row CONTENT of the husbandry picker with the single-select SHAPE of the
-- filter picker (setDataSource, getSelectedIndexInSection on confirm, confirm-disabled-on-empty,
-- the currentUnavailable preselect guard). It is single-select, so - unlike the multi-select
-- husbandry picker - it registers NO RL_SELECT action event and needs NO onClose cleanup.
-- The only comparison it makes is the preselect match (candidates[i].uniqueId == currentKey);
-- gating and sorting are the frame's job, so the dialog renders the list as given.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanDestinationPickerDialog = {}

local RLHerdsmanDestinationPickerDialog_mt = Class(RLHerdsmanDestinationPickerDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

--- Load + register the singleton dialog instance. Called EAGERLY from the explicit dialog
--- registration block in RealisticLivestock_FSBaseMission (RLRM-386: a lazy register-on-show
--- never produces a showable dialog, so onOpen would not fire).
function RLHerdsmanDestinationPickerDialog.register()
    local dialog = RLHerdsmanDestinationPickerDialog.new()
    g_gui:loadGui(modDirectory .. "gui/rlHerdsmanDestinationPickerDialog.xml",
                  "RLHerdsmanDestinationPickerDialog", dialog)
    RLHerdsmanDestinationPickerDialog.INSTANCE = dialog
    Log:debug("RLHerdsmanDestinationPickerDialog.register: dialog registered")
end

--- Construct a fresh dialog instance (state reset each show()).
---@param target table|nil
---@param customMt table|nil
---@return table dialog
function RLHerdsmanDestinationPickerDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLHerdsmanDestinationPickerDialog_mt)

    self.candidates           = {}
    self.callback             = nil
    self.callbackTarget       = nil
    self.currentDestinationKey = nil
    self.currentUnavailable   = false  -- stored dest dropped from the type-gated list
    self.selectedIndex        = nil

    return self
end

--- Static entry point. The frame passes the already type-gated, source-excluded, alpha-sorted
--- candidate descriptors and the rule's current destination key for preselection.
--- `currentUnavailable` is true when the rule HAS a stored destination that the gate dropped from
--- the list (e.g. its type left the filter scope): the dialog then refuses to silently preselect
--- row 1, shows a hint, and requires an explicit pick before OK commits.
---@param callback function fn(target, uniqueId|nil) - chosen husbandry uniqueId on OK, nil on cancel
---@param target table callback target (the Herdsman frame)
---@param candidates table[] candidate husbandry descriptors { uniqueId, animalType, name }, gated + sorted by the frame
---@param currentDestinationKey string|nil the rule's current destination key, preselected when present in the list
---@param currentUnavailable boolean|nil true -> stored dest is not in the list; require an explicit pick
function RLHerdsmanDestinationPickerDialog.show(callback, target, candidates, currentDestinationKey, currentUnavailable)
    if RLHerdsmanDestinationPickerDialog.INSTANCE == nil then
        RLHerdsmanDestinationPickerDialog.register()
    end

    local dialog = RLHerdsmanDestinationPickerDialog.INSTANCE
    dialog.candidates           = candidates or {}
    dialog.callback             = callback
    dialog.callbackTarget       = target
    dialog.currentDestinationKey = currentDestinationKey
    dialog.currentUnavailable   = currentUnavailable == true
    dialog.selectedIndex        = nil

    Log:debug("RLHerdsmanDestinationPickerDialog.show: %d candidate(s), currentDestinationKey=%s currentUnavailable=%s",
        #dialog.candidates, tostring(currentDestinationKey), tostring(dialog.currentUnavailable))
    g_gui:showDialog("RLHerdsmanDestinationPickerDialog")
end

-- =============================================================================
-- Setup + open
-- =============================================================================

--- Resolve the named elements + wire the list data source. Warns loudly on any missing critical
--- element so an XML id drift is caught at load, not as silent mis-behavior.
function RLHerdsmanDestinationPickerDialog:onGuiSetupFinished()
    RLHerdsmanDestinationPickerDialog:superClass().onGuiSetupFinished(self)

    self.dialogElement        = self:getDescendantById("dialogElement")
    self.destinationList      = self:getDescendantById("destinationList")
    self.emptyListText        = self:getDescendantById("emptyListText")
    self.confirmButton        = self:getDescendantById("confirmButton")
    self.destinationSliderBox = self:getDescendantById("destinationSliderBox")
    self.hintText             = self:getDescendantById("hintText")

    if self.destinationList ~= nil then
        self.destinationList:setDataSource(self)
    end

    local missing = {}
    if self.destinationList == nil then table.insert(missing, "destinationList") end
    if self.emptyListText == nil then table.insert(missing, "emptyListText") end
    if self.confirmButton == nil then table.insert(missing, "confirmButton") end
    if #missing > 0 then
        Log:warning("RLHerdsmanDestinationPickerDialog:onGuiSetupFinished: missing elements: %s", table.concat(missing, ", "))
    end

    Log:trace("RLHerdsmanDestinationPickerDialog:onGuiSetupFinished: elements resolved (list=%s empty=%s confirm=%s hint=%s)",
        tostring(self.destinationList ~= nil), tostring(self.emptyListText ~= nil),
        tostring(self.confirmButton ~= nil), tostring(self.hintText ~= nil))
end

--- One-shot screen-space geometry of the key elements, so the dialog layout is provable from the
--- log (no debugger). Reference screen 1920x1080; per-instance guard.
function RLHerdsmanDestinationPickerDialog:logGeometryOnce()
    if self.didMeasure then return end
    self.didMeasure = true
    local refW = g_referenceScreenWidth or 1920
    local refH = g_referenceScreenHeight or 1080
    local function px(el, label)
        if el ~= nil and el.size ~= nil then
            Log:debug("RLHerdsmanDestinationPickerDialog geometry: %s size=%.1fx%.1f px",
                label, el.size[1] * refW, el.size[2] * refH)
        end
    end
    px(self.dialogElement, "dialogElement")
    px(self.destinationList, "destinationList")
    px(self.confirmButton, "confirmButton")
end

--- Visibility (list vs empty-state), preselect-by-key (or the currentUnavailable hint), geometry log.
function RLHerdsmanDestinationPickerDialog:onOpen()
    RLHerdsmanDestinationPickerDialog:superClass().onOpen(self)

    local hasEntries = #self.candidates > 0
    if self.destinationList ~= nil then self.destinationList:setVisible(hasEntries) end
    if self.destinationSliderBox ~= nil then self.destinationSliderBox:setVisible(hasEntries) end
    if self.emptyListText ~= nil then self.emptyListText:setVisible(not hasEntries) end
    if self.confirmButton ~= nil then self.confirmButton:setDisabled(not hasEntries) end
    self:clearHint()
    self:logGeometryOnce()

    if hasEntries and self.destinationList ~= nil then
        self.destinationList:reloadData()

        if self.currentUnavailable then
            -- The rule's stored destination is not in the gated list (e.g. its type left the filter
            -- scope). Do NOT preselect row 1 - that would silently rebind on OK. Clear the list
            -- selection + keep selectedIndex nil so an immediate OK reads no row and no-ops as a
            -- cancel; surface a hint to direct an explicit pick. Keyboard-safe: OK stays enabled.
            self.destinationList.selectedSectionIndex = 0
            self.destinationList.selectedIndex = 0
            self.selectedIndex = nil
            self:showHint("rl_menu_herdsman_destination_picker_currentUnavailable")
            Log:debug("RLHerdsmanDestinationPickerDialog:onOpen: %d candidate(s), stored dest unavailable; no preselect, hint shown (currentDestinationKey=%s)",
                #self.candidates, tostring(self.currentDestinationKey))
        else
            -- Preselect by uniqueId: find the candidate whose key equals the rule's current dest;
            -- default to row 1 when the key is nil / not in the list. setSelectedItem highlights
            -- without firing a change event; confirm reads the row via getSelectedIndexInSection.
            local idx = 1
            local matched = false
            if self.currentDestinationKey ~= nil then
                for i, c in ipairs(self.candidates) do
                    if c.uniqueId == self.currentDestinationKey then idx = i; matched = true; break end
                end
            end
            self.destinationList:setSelectedItem(1, idx, false, true)
            self.selectedIndex = idx

            Log:debug("RLHerdsmanDestinationPickerDialog:onOpen: %d candidate(s), preselect idx=%d (matched=%s currentDestinationKey=%s)",
                #self.candidates, idx, tostring(matched), tostring(self.currentDestinationKey))
        end
    else
        Log:debug("RLHerdsmanDestinationPickerDialog:onOpen: empty candidate list; OK disabled")
    end
end

--- Surface the "stored destination unavailable" hint (localised, falls back to the raw key).
---@param l10nKey string
function RLHerdsmanDestinationPickerDialog:showHint(l10nKey)
    if self.hintText == nil then
        Log:warning("RLHerdsmanDestinationPickerDialog:showHint: hintText element missing; cannot surface key=%s",
            tostring(l10nKey))
        return
    end
    local text = (g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(l10nKey))
                 and g_i18n:getText(l10nKey)
                 or tostring(l10nKey)
    self.hintText:setText(text)
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(true) end
    Log:debug("RLHerdsmanDestinationPickerDialog:showHint: key=%s", tostring(l10nKey))
end

--- Clear + hide the hint text.
function RLHerdsmanDestinationPickerDialog:clearHint()
    if self.hintText == nil then return end
    self.hintText:setText("")
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(false) end
    Log:trace("RLHerdsmanDestinationPickerDialog:clearHint")
end

-- =============================================================================
-- DataSource (1 section, name-only cell)
-- =============================================================================

---@return number
function RLHerdsmanDestinationPickerDialog:getNumberOfSections()
    return 1
end

---@return number
function RLHerdsmanDestinationPickerDialog:getNumberOfItemsInSection(_list, _section)
    return #self.candidates
end

---@return string
function RLHerdsmanDestinationPickerDialog:getTitleForSectionHeader(_list, _section)
    return ""
end

--- Render one candidate's husbandry name into the cell (uniqueId fallback if unnamed).
function RLHerdsmanDestinationPickerDialog:populateCellForItemInSection(list, _section, index, cell)
    if list ~= self.destinationList then return end
    local descriptor = self.candidates[index]
    if descriptor == nil then return end

    local nameElement = cell:getAttribute("destinationName")
    if nameElement ~= nil then
        nameElement:setText(descriptor.name or tostring(descriptor.uniqueId))
    end

    Log:trace("RLHerdsmanDestinationPickerDialog:populateCell: index=%d uniqueId=%s name=%q",
        index, tostring(descriptor.uniqueId), tostring(descriptor.name))
end

-- =============================================================================
-- Selection + commit
-- =============================================================================

--- Track the clicked row + enable OK; an explicit pick resolves the currentUnavailable state.
function RLHerdsmanDestinationPickerDialog:onListClick(_list, _section, index, _cell)
    self.selectedIndex = index
    if self.confirmButton ~= nil then self.confirmButton:setDisabled(false) end
    self.currentUnavailable = false
    self:clearHint()
    Log:trace("RLHerdsmanDestinationPickerDialog:onListClick: selected index=%d", index)
end

--- Commit: read the live list selection (fall back to the click-tracked index on a populated list
--- so OK never silently no-ops), return the chosen husbandry uniqueId (or nil) to the caller.
function RLHerdsmanDestinationPickerDialog:onClickConfirm()
    -- Guard the commit + callback so a callback-side error is logged, not torn through the GUI flow
    -- (mirrors the husbandry picker's onClickOk).
    RmSafeUtils.safeCall("RLHerdsmanDestinationPickerDialog:onClickConfirm", function()
        local selectedIndex = self.destinationList ~= nil and self.destinationList:getSelectedIndexInSection() or nil
        if (selectedIndex == nil or selectedIndex <= 0) and #self.candidates > 0 then
            selectedIndex = self.selectedIndex
        end
        local descriptor = nil
        if selectedIndex ~= nil and selectedIndex > 0 then
            descriptor = self.candidates[selectedIndex]
        end
        local uniqueId = descriptor ~= nil and descriptor.uniqueId or nil

        Log:debug("RLHerdsmanDestinationPickerDialog:onClickConfirm: selectedIndex=%s -> uniqueId=%s",
            tostring(selectedIndex), tostring(uniqueId))

        self:close()
        if self.callback ~= nil then
            if self.callbackTarget ~= nil then
                self.callback(self.callbackTarget, uniqueId)
            else
                self.callback(uniqueId)
            end
        end
    end)
end

--- Cancel: return nil (rule unchanged).
function RLHerdsmanDestinationPickerDialog:onClickCancel()
    Log:debug("RLHerdsmanDestinationPickerDialog:onClickCancel")
    self:close()
    if self.callback ~= nil then
        if self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil)
        else
            self.callback(nil)
        end
    end
end
