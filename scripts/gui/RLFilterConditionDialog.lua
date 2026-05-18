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

-- Field types this dialog can render. P1-4a covered number + bool; P1-4b
-- (2026-05-18) extends to enum (gender / subType single-pick) and string
-- (name contains / notcontains). Multi-value editor for in/notin deferred
-- to P1-4b-2 / RLRM-274.
local SUPPORTED_TYPES_DIALOG = { number = true, bool = true, enum = true, string = true }

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
    self.valueEnumPicker  = self:getDescendantById("valueEnumPicker")
    self.valueStringInput = self:getDescendantById("valueStringInput")
    self.hintText         = self:getDescendantById("hintText")
    self.okButton         = self:getDescendantById("okButton")

    local missing = {}
    if self.fieldPicker      == nil then table.insert(missing, "fieldPicker") end
    if self.cmpPicker        == nil then table.insert(missing, "cmpPicker") end
    if self.valueNumberInput == nil then table.insert(missing, "valueNumberInput") end
    if self.valueBoolPicker  == nil then table.insert(missing, "valueBoolPicker") end
    if self.valueEnumPicker  == nil then table.insert(missing, "valueEnumPicker") end
    if self.valueStringInput == nil then table.insert(missing, "valueStringInput") end
    if self.hintText         == nil then table.insert(missing, "hintText") end
    if #missing > 0 then
        Log:warning("RLFilterConditionDialog:onGuiSetupFinished: missing elements: %s",
            table.concat(missing, ","))
    else
        Log:trace("RLFilterConditionDialog:onGuiSetupFinished: all elements resolved")
    end
end

-- =============================================================================
-- Hint surface (P1-4b)
-- =============================================================================

--- Show a translated hint in the dialog's hintText element. Called by reject
--- paths (empty-string commit, unsupported coercion transition). Logged at
--- DEBUG so a manual playtest can confirm the hint fired.
---@param l10nKey string
function RLFilterConditionDialog:showHint(l10nKey)
    if self.hintText == nil then
        Log:warning("RLFilterConditionDialog:showHint: hintText element missing; cannot surface key=%s",
            tostring(l10nKey))
        return
    end
    local text = (g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(l10nKey))
                 and g_i18n:getText(l10nKey)
                 or tostring(l10nKey)
    self.hintText:setText(text)
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(true) end
    Log:debug("RLFilterConditionDialog:showHint: key=%s text='%s'",
        tostring(l10nKey), tostring(text))
end

--- Clear the hint surface. Called on field change + cmp change so a stale
--- reject hint doesn't persist across user input.
function RLFilterConditionDialog:clearHint()
    if self.hintText == nil then return end
    self.hintText:setText("")
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(false) end
    Log:trace("RLFilterConditionDialog:clearHint")
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
    -- types (number, bool, enum, string). Enum fields whose domain resolves
    -- empty are dropped here so the picker never offers an unpickable option
    -- (subType when animalType=nil or scoped type has zero subtypes; gender
    -- domain is always non-empty in practice).
    local catalogFields = RLFilterFieldCatalog.getAllForAnimalType(
        self.animalType, SUPPORTED_TYPES_DIALOG)
    self.fieldOptions = {}
    for _, f in ipairs(catalogFields) do
        if f.type == "enum" then
            local domain = RLFilterFieldDisplay.getEnumDomain(f.key, self.animalType)
            if domain ~= nil and #domain > 0 then
                table.insert(self.fieldOptions, f)
            else
                Log:trace("RLFilterConditionDialog:onOpen: excluding enum field=%s (empty domain for animalType=%s)",
                    tostring(f.key), tostring(self.animalType))
            end
        else
            table.insert(self.fieldOptions, f)
        end
    end
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
        -- P1-4b: enum default value is domain-driven (catalog returns nil for
        -- enum; RLFilterFieldDisplay owns the domain). Seed domain[1] when the
        -- starting field is enum so refreshValueWidget has something to render.
        if firstField.type == "enum" then
            self.workingValue = self:resolveDefaultEnumValue(firstField.key)
        end
        Log:trace("RLFilterConditionDialog:onOpen: defaults field=%s cmp=%s value=%s",
            tostring(self.workingField), tostring(self.workingCmp), tostring(self.workingValue))
    end

    -- Reset hint surface so a previous reject hint doesn't bleed across dialogs.
    self:clearHint()

    self:refreshFieldPicker()
    self:refreshCmpPicker()
    self:refreshValueWidget()
end

--- Resolve domain[1] for an enum field via RLFilterFieldDisplay. Returns nil
--- when the domain is empty (e.g. subType when animalType=nil or has zero
--- subtypes). Caller decides whether nil is fatal (subType refuse-to-edit
--- path) or just leaves the picker at "no options" (gender is always
--- non-empty so this branch is subType-only in practice).
---@param fieldKey string
---@return string|nil
function RLFilterConditionDialog:resolveDefaultEnumValue(fieldKey)
    local domain = RLFilterFieldDisplay.getEnumDomain(fieldKey, self.animalType)
    if domain == nil or #domain == 0 then
        Log:trace("RLFilterConditionDialog:resolveDefaultEnumValue: empty domain for fieldKey=%s animalType=%s",
            tostring(fieldKey), tostring(self.animalType))
        return nil
    end
    return domain[1]
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

--- Hide every value widget. Helper for the widget swap in refreshValueWidget
--- so each type branch only has to show its own widget. Cheaper than
--- per-branch hide of all-other-widgets and avoids the "forgot one" bug
--- when a fifth widget gets added later.
function RLFilterConditionDialog:_hideAllValueWidgets()
    if self.valueNumberInput ~= nil then self.valueNumberInput:setVisible(false) end
    if self.valueBoolPicker  ~= nil then self.valueBoolPicker:setVisible(false)  end
    if self.valueEnumPicker  ~= nil then self.valueEnumPicker:setVisible(false)  end
    if self.valueStringInput ~= nil then self.valueStringInput:setVisible(false) end
end

function RLFilterConditionDialog:refreshValueWidget()
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field == nil then
        Log:warning("RLFilterConditionDialog:refreshValueWidget: workingField=%s not in catalog",
            tostring(self.workingField))
        return
    end

    self:_hideAllValueWidgets()

    if field.type == "number" then
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
    elseif field.type == "enum" then
        -- P1-4b: enum picker (gender / subType). Domain + display name resolve
        -- via RLFilterFieldDisplay; storage uses stable internal key only.
        local domain = RLFilterFieldDisplay.getEnumDomain(self.workingField, self.animalType)
        self.valueEnumDomain = domain or {}
        if #self.valueEnumDomain == 0 then
            -- Empty domain: gender always non-empty in practice, so this is
            -- the subType-when-animalType-nil / scoped-with-zero-subtypes
            -- path. The settings frame's field-picker exclusion should
            -- prevent this from showing up at all, but guard just in case
            -- a legacy condition reaches here.
            Log:warning("RLFilterConditionDialog:refreshValueWidget: enum domain empty for field=%s animalType=%s",
                tostring(self.workingField), tostring(self.animalType))
            self:showHint("rl_menu_filters_subtypeRequiresAnimalType")
            return
        end
        if self.valueEnumPicker ~= nil then
            self.valueEnumPicker:setVisible(true)
            local labels = {}
            for i, key in ipairs(self.valueEnumDomain) do
                labels[i] = RLFilterFieldDisplay.getEnumValueDisplayName(
                    self.workingField, key, self.animalType)
            end
            self.valueEnumPicker:setTexts(labels)
            -- Seed selection: prefer workingValue's domain index; fall back
            -- to 1 (also covers the workingValue=nil case from the catalog's
            -- enum-divergence reseed where the dialog patches in domain[1]).
            local selectedIdx = 1
            local foundInDomain = false
            for i, key in ipairs(self.valueEnumDomain) do
                if key == self.workingValue then
                    selectedIdx = i
                    foundInDomain = true
                    break
                end
            end
            -- If workingValue isn't in the domain (legacy condition with a
            -- renamed subType, map-bridge drift, hand-edited XML, etc.), do
            -- NOT silently mutate workingValue. Mark the dialog as drifted
            -- and surface a hint; onClickOk refuses commit until the user
            -- explicitly picks via onValueEnumChanged (which clears the flag).
            -- The picker visually shows the first domain entry (setState
            -- clamps to range) so the row isn't blank; the stale workingValue
            -- is preserved for logging until the user replaces it.
            if not foundInDomain then
                self.enumValueDrifted = true
                Log:warning("RLFilterConditionDialog:refreshValueWidget: enum workingValue=%s not in domain for field=%s; require explicit pick",
                    tostring(self.workingValue), tostring(self.workingField))
                self:showHint("rl_menu_filters_enumValueDrifted")
            end
            self.valueEnumPicker:setState(selectedIdx, false)
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: enum field=%s domainSize=%d selected='%s'",
            tostring(self.workingField), #self.valueEnumDomain, tostring(self.workingValue))
    elseif field.type == "string" then
        if self.valueStringInput ~= nil then
            self.valueStringInput:setVisible(true)
            local text = self.workingValue
            if text == nil then text = "" end
            self.valueStringInput:setText(tostring(text))
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: string, text='%s'",
            tostring(self.workingValue))
    else
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
    -- P1-4b adds "value" to the clear set when the catalog's enum-divergence
    -- path can't seed a default (enum default is domain-driven). After the
    -- clear the dialog patches in domain[1] via resolveDefaultEnumValue so
    -- refreshValueWidget has something to render.
    if result.clearKeys ~= nil then
        for _, k in ipairs(result.clearKeys) do
            if     k == "rawText" then self.workingRawText = nil
            elseif k == "value"   then self.workingValue   = nil
            end
        end
    end

    -- P1-4b: when divergence cleared value AND the new type is enum, patch
    -- in domain[1] so the picker starts on a real value. For string, the
    -- catalog already returns "" via getDefaultValueForType. For number /
    -- bool, the catalog returns 0 / false directly.
    if self.workingValue == nil and newField.type == "enum" then
        self.workingValue = self:resolveDefaultEnumValue(newField.key)
        Log:trace("RLFilterConditionDialog:onFieldChanged: seeded enum default value=%s for field=%s",
            tostring(self.workingValue), tostring(newField.key))
    end

    -- Reset hint so a stale reject hint doesn't bleed across user input.
    -- Clear the enum-drift flag too; the catalog coercion above already
    -- wrote a fresh defaulted value (or domain[1] via the dialog's
    -- resolveDefaultEnumValue patch), so any prior drift state is stale.
    self.enumValueDrifted = false
    self:clearHint()

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
    -- Reset hint so a stale reject hint doesn't bleed across user input
    -- (matches the clearHint helper's own contract at :148).
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onCmpChanged: cmp=%s", tostring(self.workingCmp))
end

function RLFilterConditionDialog:onValueBoolChanged(state, _widget)
    -- State 1 = No (false), 2 = Yes (true). Matches the order set in refreshValueWidget.
    self.workingValue = (state == 2)
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onValueBoolChanged: value=%s",
        tostring(self.workingValue))
end

--- P1-4b post-triage: any keystroke in the value TextInput (number or
--- string variant) clears the reject hint so it tracks current input.
--- Both XML elements wire `onTextChanged="onTextChanged"`.
function RLFilterConditionDialog:onTextChanged(_element, _text)
    self:clearHint()
end

--- P1-4b: enum picker advanced. Maps the picker state index to the stable
--- internal key from the cached domain. Never stores the translated label;
--- domain[state] is always a stable key (e.g. "male", "<subtype-name>").
function RLFilterConditionDialog:onValueEnumChanged(state, _widget)
    local domain = self.valueEnumDomain or {}
    local key = domain[state]
    if key == nil then
        Log:warning("RLFilterConditionDialog:onValueEnumChanged: state=%d out of range (%d values in domain)",
            state, #domain)
        return
    end
    self.workingValue = key
    -- User picked a real domain key, so the drift flag clears. Any user
    -- widget interaction also clears the stale reject hint.
    self.enumValueDrifted = false
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onValueEnumChanged: value=%s (state=%d)",
        tostring(self.workingValue), state)
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
            -- Stay open so user can correct; surface translated hint and
            -- keep workingRawText in sync.
            self.workingRawText = text
            self:showHint("rl_menu_filters_invalidNumber")
            return
        end
        -- NaN+Inf reject: NaN != NaN, Inf == math.huge.
        if num ~= num or num == math.huge or num == -math.huge then
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting NaN/Inf value '%s' for field=%s",
                tostring(text), tostring(self.workingField))
            self.workingRawText = text
            self:showHint("rl_menu_filters_invalidNumber")
            return
        end
        newCondition.value = num
        -- rawText carried through so the populate trace sees what the user typed.
        if text ~= tostring(num) then
            newCondition.rawText = text
        end
    elseif field.type == "bool" then
        newCondition.value = (self.workingValue == true)
    elseif field.type == "enum" then
        -- Stable internal key (workingValue is the domain entry, never the
        -- translated label). Refuse close when the domain is empty - the
        -- settings frame's field-picker exclusion should already prevent
        -- this case from reaching OK, but guard against legacy rows.
        local domain = self.valueEnumDomain or {}
        if #domain == 0 then
            Log:warning("RLFilterConditionDialog:onClickOk: enum domain empty for field=%s; refusing commit",
                tostring(self.workingField))
            self:showHint("rl_menu_filters_subtypeRequiresAnimalType")
            return
        end
        -- If refreshValueWidget detected drift (workingValue not in the
        -- current domain) the dialog set enumValueDrifted=true and asked the
        -- user to explicitly pick. onClickOk refuses commit until the user
        -- picks (onValueEnumChanged clears the flag). Silently snapping to
        -- domain[1] would rewrite stored subType keys to a different breed.
        if self.enumValueDrifted then
            Log:warning("RLFilterConditionDialog:onClickOk: refusing commit, enum value drifted (workingValue=%s, field=%s); pick a replacement",
                tostring(self.workingValue), tostring(self.workingField))
            self:showHint("rl_menu_filters_enumValueDrifted")
            return
        end
        -- Defensive: workingValue must be a domain key by this point because
        -- (a) initial seed comes from the initialCondition or resolveDefaultEnumValue,
        -- (b) onValueEnumChanged only writes domain[state], (c) drift is caught above.
        -- If this ever fails it's a real bug, not user data.
        local valid = false
        for _, key in ipairs(domain) do
            if key == self.workingValue then valid = true; break end
        end
        if not valid then
            Log:warning("RLFilterConditionDialog:onClickOk: enum workingValue=%s not in domain post-drift-check; refusing commit",
                tostring(self.workingValue))
            self:showHint("rl_menu_filters_enumValueDrifted")
            return
        end
        newCondition.value = self.workingValue
    elseif field.type == "string" then
        -- Pull live text from TextInput (handles in-flight keystrokes; matches
        -- the number branch's same pattern). Store verbatim - no trim, no
        -- quote-strip, no case-fold (case-fold lives in the evaluator at
        -- match time per RLFilterEvaluator.lua substring path).
        local text = self.valueStringInput ~= nil
                     and self.valueStringInput.getText ~= nil
                     and self.valueStringInput:getText()
                     or self.workingValue
                     or ""
        if text == "" then
            -- Empty needle reject mirrors RLFilterEvaluator.lua:72 - committing
            -- an empty contains/notcontains needle silently produces a no-op
            -- filter. Refuse close, surface hint, WARN. Keeps working state
            -- so the user can correct without re-opening.
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting empty string for field=%s cmp=%s",
                tostring(self.workingField), tostring(self.workingCmp))
            self.workingValue = ""
            self:showHint("rl_menu_filters_emptyValueRejected")
            return
        end
        newCondition.value = text
        -- Keep workingValue in sync with what we committed (so a re-edit
        -- without close-and-reopen starts from the same state).
        self.workingValue = text
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
