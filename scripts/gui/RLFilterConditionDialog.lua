-- RLFilterConditionDialog.lua
-- Modal editor for a single saveable-filter condition (field / cmp / value).
-- Invoked from RLMenuSettingsFrame.lua (Filters subtab). Mirrors the
-- AnimalMoveDestinationDialog pattern: static show(callback, target, ...)
-- entry point, callback-and-target stored on the instance, no global frame
-- references. Calling frame passes itself as `target` and receives the
-- coerced condition table on OK or nil on Cancel.
--
-- Field-change coercion delegates to RLFilterFieldCatalog.coerceConditionOnFieldChange
-- (legacy parity with RLMenuSettingsFrame.lua:1769-1840 pre-v2). All number
-- value validation (tonumber + NaN/Inf reject) happens at OK click.
--
-- Author: Ritter

local Log = RmLogging.getLogger("RLRM")

RLFilterConditionDialog = {}

local RLFilterConditionDialog_mt = Class(RLFilterConditionDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- Editor-side cmp gate. P1-4a deferred multi-value editor to P1-4b; the
-- dialog filters in/notin out of pickers but keeps them in catalog cmps[]
-- so the helper's cmp-validity check honors the caller's editable list.
local UNSUPPORTED_CMPS_DIALOG = { ["in"] = true, ["notin"] = true }

-- Field types this dialog can render. Mirrors SUPPORTED_TYPES in the frame
-- (P1-4a editor); P1-4b extends to enum + string.
local SUPPORTED_TYPES_DIALOG = { number = true, bool = true }

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

function RLFilterConditionDialog.register()
    local dialog = RLFilterConditionDialog.new()
    g_gui:loadGui(modDirectory .. "gui/rlFilterConditionDialog.xml",
                  "RLFilterConditionDialog", dialog)
    RLFilterConditionDialog.INSTANCE = dialog
    Log:debug("RLFilterConditionDialog.register: dialog registered")
end

function RLFilterConditionDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLFilterConditionDialog_mt)

    self.callback         = nil
    self.callbackTarget   = nil
    self.initialCondition = nil
    self.rowIndex         = nil
    self.animalType       = nil

    -- Working state (mutated by widget callbacks; flushed to caller on OK).
    self.workingField   = nil
    self.workingCmp     = nil
    self.workingValue   = nil
    self.workingRawText = nil

    -- Cached widget input data (rebuilt per onOpen and per onFieldChanged).
    self.fieldOptions = {}
    self.cmpOptions   = {}

    return self
end

--- Static entry point. Mirrors AnimalMoveDestinationDialog.show.
---@param callback function fn(target, newCondition|nil, rowIndex)
---@param target table callback target (the calling frame)
---@param initialCondition table|nil {field, cmp, value, rawText?} or nil for new
---@param rowIndex number|nil 1-based row index for edit; nil for new
---@param animalType number|nil AnimalType index or nil for ANY
function RLFilterConditionDialog.show(callback, target, initialCondition, rowIndex, animalType)
    if RLFilterConditionDialog.INSTANCE == nil then
        RLFilterConditionDialog.register()
    end

    local dialog = RLFilterConditionDialog.INSTANCE
    dialog.callback         = callback
    dialog.callbackTarget   = target
    dialog.initialCondition = initialCondition
    dialog.rowIndex         = rowIndex
    dialog.animalType       = animalType

    Log:debug("RLFilterConditionDialog.show: rowIndex=%s initialField=%s animalType=%s",
        tostring(rowIndex),
        initialCondition and tostring(initialCondition.field) or "nil(new)",
        tostring(animalType))

    g_gui:showDialog("RLFilterConditionDialog")
end

-- =============================================================================
-- Element resolution (once per clone, before first onOpen)
-- =============================================================================

function RLFilterConditionDialog:onGuiSetupFinished()
    RLFilterConditionDialog:superClass().onGuiSetupFinished(self)

    self.fieldPicker      = self:getDescendantById("fieldPicker")
    self.cmpPicker        = self:getDescendantById("cmpPicker")
    self.valueNumberInput = self:getDescendantById("valueNumberInput")
    self.valueBoolPicker  = self:getDescendantById("valueBoolPicker")
    self.okButton         = self:getDescendantById("okButton")

    local missing = {}
    if self.fieldPicker      == nil then table.insert(missing, "fieldPicker") end
    if self.cmpPicker        == nil then table.insert(missing, "cmpPicker") end
    if self.valueNumberInput == nil then table.insert(missing, "valueNumberInput") end
    if self.valueBoolPicker  == nil then table.insert(missing, "valueBoolPicker") end
    if #missing > 0 then
        Log:warning("RLFilterConditionDialog:onGuiSetupFinished: missing elements: %s",
            table.concat(missing, ","))
    else
        Log:trace("RLFilterConditionDialog:onGuiSetupFinished: all elements resolved")
    end
end

-- =============================================================================
-- Helpers (pure-ish; read/write working state)
-- =============================================================================

--- Filter newField.cmps down to the editable subset (drops in/notin).
local function editableCmpsFor(field)
    local out = {}
    if field == nil or field.cmps == nil then return out end
    for _, c in ipairs(field.cmps) do
        if not UNSUPPORTED_CMPS_DIALOG[c] then
            table.insert(out, c)
        end
    end
    return out
end

--- Resolve the index of `field.key` in `self.fieldOptions`. Returns nil if absent.
local function indexOfFieldOption(self, key)
    for i, f in ipairs(self.fieldOptions) do
        if f.key == key then return i end
    end
    return nil
end

--- Resolve the index of `cmp` in `self.cmpOptions`. Returns nil if absent.
local function indexOfCmpOption(self, cmp)
    for i, c in ipairs(self.cmpOptions) do
        if c == cmp then return i end
    end
    return nil
end

-- =============================================================================
-- onOpen: populate widgets from initialCondition (or defaults for new)
-- =============================================================================

function RLFilterConditionDialog:onOpen()
    RLFilterConditionDialog:superClass().onOpen(self)

    -- Build field options for the active animalType, filtered to supported
    -- types (number + bool). P1-4b extends SUPPORTED_TYPES_DIALOG.
    self.fieldOptions = RLFilterFieldCatalog.getAllForAnimalType(
        self.animalType, SUPPORTED_TYPES_DIALOG)
    if #self.fieldOptions == 0 then
        Log:warning("RLFilterConditionDialog:onOpen: zero field options for animalType=%s; closing",
            tostring(self.animalType))
        self:close()
        return
    end

    -- Seed working state from initialCondition or per-type defaults.
    if self.initialCondition ~= nil then
        self.workingField   = self.initialCondition.field
        self.workingCmp     = self.initialCondition.cmp
        self.workingValue   = self.initialCondition.value
        self.workingRawText = self.initialCondition.rawText
        Log:trace("RLFilterConditionDialog:onOpen: seeded from initialCondition field=%s cmp=%s value=%s",
            tostring(self.workingField), tostring(self.workingCmp), tostring(self.workingValue))
    else
        local firstField = self.fieldOptions[1]
        self.workingField   = firstField.key
        self.workingCmp     = RLFilterFieldCatalog.getDefaultCmpForField(firstField)
        self.workingValue   = RLFilterFieldCatalog.getDefaultValueForType(firstField.type)
        self.workingRawText = nil
        Log:trace("RLFilterConditionDialog:onOpen: defaults field=%s cmp=%s value=%s",
            tostring(self.workingField), tostring(self.workingCmp), tostring(self.workingValue))
    end

    self:refreshFieldPicker()
    self:refreshCmpPicker()
    self:refreshValueWidget()
end

-- =============================================================================
-- Picker refreshers (rebuild widget contents from working state)
-- =============================================================================

--- Resolve a localized field label using the existing P1-4a key namespace.
--- Falls back to the raw key when no l10n entry exists (P1-4b extends).
local function resolveFieldLabel(key)
    if key == nil then return "" end
    local safe = key:gsub("%.", "_")
    local lookup = "rl_menu_filters_field_" .. safe
    if g_i18n:hasText(lookup) then
        return g_i18n:getText(lookup)
    end
    return key
end

function RLFilterConditionDialog:refreshFieldPicker()
    if self.fieldPicker == nil then return end
    local labels = {}
    for i, f in ipairs(self.fieldOptions) do
        labels[i] = resolveFieldLabel(f.key)
    end
    self.fieldPicker:setTexts(labels)
    local idx = indexOfFieldOption(self, self.workingField) or 1
    self.fieldPicker:setState(idx, false)
    Log:trace("RLFilterConditionDialog:refreshFieldPicker: %d options, selected=%d (%s)",
        #labels, idx, tostring(self.workingField))
end

function RLFilterConditionDialog:refreshCmpPicker()
    if self.cmpPicker == nil then return end
    local field = RLFilterFieldCatalog.get(self.workingField)
    self.cmpOptions = editableCmpsFor(field)
    self.cmpPicker:setTexts(self.cmpOptions)
    local idx = indexOfCmpOption(self, self.workingCmp) or 1
    self.cmpPicker:setState(idx, false)
    Log:trace("RLFilterConditionDialog:refreshCmpPicker: %d cmps, selected=%d (%s)",
        #self.cmpOptions, idx, tostring(self.workingCmp))
end

function RLFilterConditionDialog:refreshValueWidget()
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field == nil then
        Log:warning("RLFilterConditionDialog:refreshValueWidget: workingField=%s not in catalog",
            tostring(self.workingField))
        return
    end

    if field.type == "number" then
        if self.valueBoolPicker ~= nil then self.valueBoolPicker:setVisible(false) end
        if self.valueNumberInput ~= nil then
            self.valueNumberInput:setVisible(true)
            local text = self.workingRawText
            if text == nil then
                if self.workingValue == nil then text = "" else text = tostring(self.workingValue) end
            end
            self.valueNumberInput:setText(text)
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: number, text='%s'",
            tostring(self.workingRawText or self.workingValue))
    elseif field.type == "bool" then
        if self.valueNumberInput ~= nil then self.valueNumberInput:setVisible(false) end
        if self.valueBoolPicker ~= nil then
            self.valueBoolPicker:setVisible(true)
            self.valueBoolPicker:setTexts({
                g_i18n:getText("ui_no"),
                g_i18n:getText("ui_yes"),
            })
            local boolState = (self.workingValue == true) and 2 or 1
            self.valueBoolPicker:setState(boolState, false)
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: bool, value=%s",
            tostring(self.workingValue))
    else
        if self.valueNumberInput ~= nil then self.valueNumberInput:setVisible(false) end
        if self.valueBoolPicker  ~= nil then self.valueBoolPicker:setVisible(false)   end
        Log:warning("RLFilterConditionDialog:refreshValueWidget: unsupported type=%s (workingField=%s)",
            tostring(field.type), tostring(self.workingField))
    end
end

-- =============================================================================
-- Widget callbacks (MultiTextOption onClick / TextInput passes through)
-- =============================================================================

--- Field picker advanced. Coerce cmp + value via the shared catalog helper.
function RLFilterConditionDialog:onFieldChanged(state, _widget)
    local newField = self.fieldOptions[state]
    if newField == nil then
        Log:warning("RLFilterConditionDialog:onFieldChanged: state=%d out of range (%d options)",
            state, #self.fieldOptions)
        return
    end

    local oldCond = {
        field   = self.workingField,
        cmp     = self.workingCmp,
        value   = self.workingValue,
        rawText = self.workingRawText,
    }
    local editableCmps = editableCmpsFor(newField)
    local result = RLFilterFieldCatalog.coerceConditionOnFieldChange(
        oldCond, newField.key, editableCmps)

    -- Apply patch.
    self.workingField = result.patch.field
    if result.patch.cmp   ~= nil then self.workingCmp   = result.patch.cmp   end
    if result.patch.value ~= nil then self.workingValue = result.patch.value end

    -- Apply clearKeys (F2 lesson: nil-valued keys vanish in patch tables).
    if result.clearKeys ~= nil then
        for _, k in ipairs(result.clearKeys) do
            if k == "rawText" then self.workingRawText = nil end
        end
    end

    Log:debug("RLFilterConditionDialog:onFieldChanged: field=%s cmp=%s value=%s rawText=%s",
        tostring(self.workingField), tostring(self.workingCmp),
        tostring(self.workingValue), tostring(self.workingRawText))

    self:refreshCmpPicker()
    self:refreshValueWidget()
end

function RLFilterConditionDialog:onCmpChanged(state, _widget)
    local cmp = self.cmpOptions[state]
    if cmp == nil then
        Log:warning("RLFilterConditionDialog:onCmpChanged: state=%d out of range (%d cmps)",
            state, #self.cmpOptions)
        return
    end
    self.workingCmp = cmp
    Log:debug("RLFilterConditionDialog:onCmpChanged: cmp=%s", tostring(self.workingCmp))
end

function RLFilterConditionDialog:onValueBoolChanged(state, _widget)
    -- State 1 = No (false), 2 = Yes (true). Matches the order set in refreshValueWidget.
    self.workingValue = (state == 2)
    Log:debug("RLFilterConditionDialog:onValueBoolChanged: value=%s",
        tostring(self.workingValue))
end

-- =============================================================================
-- OK / Cancel
-- =============================================================================

--- Validate working state, build coerced newCondition, deliver to caller, close.
function RLFilterConditionDialog:onClickOk()
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field == nil then
        Log:warning("RLFilterConditionDialog:onClickOk: workingField=%s not in catalog; closing as cancel",
            tostring(self.workingField))
        self:close()
        if self.callback ~= nil and self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil, self.rowIndex)
        end
        return
    end

    local newCondition = {
        field = self.workingField,
        cmp   = self.workingCmp,
    }

    if field.type == "number" then
        -- Pull live text from TextInput (handles in-flight keystrokes the
        -- workingRawText cache may not have seen yet if the user typed and
        -- clicked OK before any onChange fired).
        local text = self.valueNumberInput ~= nil
                     and self.valueNumberInput.getText ~= nil
                     and self.valueNumberInput:getText()
                     or self.workingRawText
                     or tostring(self.workingValue or "")
        local num = tonumber(text)
        if num == nil then
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting non-numeric value '%s' for field=%s",
                tostring(text), tostring(self.workingField))
            -- Stay open so user can correct. Keep workingRawText in sync.
            self.workingRawText = text
            return
        end
        -- NaN+Inf reject: NaN != NaN, Inf == math.huge.
        if num ~= num or num == math.huge or num == -math.huge then
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting NaN/Inf value '%s' for field=%s",
                tostring(text), tostring(self.workingField))
            self.workingRawText = text
            return
        end
        newCondition.value = num
        -- rawText carried through so the populate trace sees what the user typed.
        if text ~= tostring(num) then
            newCondition.rawText = text
        end
    elseif field.type == "bool" then
        newCondition.value = (self.workingValue == true)
    else
        Log:warning("RLFilterConditionDialog:onClickOk: unsupported field.type=%s for workingField=%s; closing as cancel",
            tostring(field.type), tostring(self.workingField))
        self:close()
        if self.callback ~= nil and self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil, self.rowIndex)
        end
        return
    end

    Log:debug("RLFilterConditionDialog:onClickOk: committing rowIndex=%s field=%s cmp=%s value=%s",
        tostring(self.rowIndex), tostring(newCondition.field),
        tostring(newCondition.cmp), tostring(newCondition.value))

    self:close()
    if self.callback ~= nil and self.callbackTarget ~= nil then
        self.callback(self.callbackTarget, newCondition, self.rowIndex)
    end
end

function RLFilterConditionDialog:onClickBack()
    Log:debug("RLFilterConditionDialog:onClickBack: cancel (rowIndex=%s)",
        tostring(self.rowIndex))
    self:close()
    if self.callback ~= nil and self.callbackTarget ~= nil then
        self.callback(self.callbackTarget, nil, self.rowIndex)
    end
end

--- Enter pressed while the TextInput is focused. Routes through the
--- canonical RLRM dialog pattern from NameInputDialog.lua:135-137: when
--- `dismiss` is truthy, the Enter event is the IME-closing gesture
--- (TextInputElement raises this with dismiss=true) and we suppress
--- form-commit so the user can see their typed value first. When dismiss
--- is falsy, treat as a form-commit and route to onClickOk.
function RLFilterConditionDialog:onEnterPressed(_, dismiss)
    Log:trace("RLFilterConditionDialog:onEnterPressed: dismiss=%s", tostring(dismiss))
    return dismiss and true or self:onClickOk()
end

--- Esc pressed while the TextInput is focused. Routes to onClickBack
--- per the NameInputDialog.lua:140-142 pattern.
function RLFilterConditionDialog:onEscPressed(_)
    Log:trace("RLFilterConditionDialog:onEscPressed")
    return self:onClickBack()
end
