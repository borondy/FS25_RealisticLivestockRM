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

-- Editor-side cmp gate. P1-4b-2 lifts `in`/`notin` to ENUM fields (multi-value
-- editor via RLFilterValueSetDialog). STRING fields stay scalar-only;
-- `STRING_CMPS` already excludes `in`/`notin` upstream in the catalog so this
-- gate is defensive belt-and-suspenders for the string branch.
local UNSUPPORTED_CMPS_BY_TYPE = {
    number = { ["in"] = true, ["notin"] = true },  -- multi-value numeric editor never specced
    bool   = {},                                    -- BOOL_CMPS = {"=="} only; no exclusions needed
    enum   = {},                                    -- P1-4b-2: in/notin now editable
    string = { ["in"] = true, ["notin"] = true },  -- substring cmps only
}

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
    self.valueSetButton   = self:getDescendantById("valueSetButton")
    self.hintText         = self:getDescendantById("hintText")
    self.okButton         = self:getDescendantById("okButton")
    -- RLRM-280 measurement: resolve label elements too so onOpen can log
    -- their rendered geometry for position/width math.
    self.fieldLabel       = self:getDescendantById("fieldLabel")
    self.cmpLabel         = self:getDescendantById("cmpLabel")
    self.valueLabel       = self:getDescendantById("valueLabel")

    local missing = {}
    if self.fieldPicker      == nil then table.insert(missing, "fieldPicker") end
    if self.cmpPicker        == nil then table.insert(missing, "cmpPicker") end
    if self.valueNumberInput == nil then table.insert(missing, "valueNumberInput") end
    if self.valueBoolPicker  == nil then table.insert(missing, "valueBoolPicker") end
    if self.valueEnumPicker  == nil then table.insert(missing, "valueEnumPicker") end
    if self.valueStringInput == nil then table.insert(missing, "valueStringInput") end
    if self.valueSetButton   == nil then table.insert(missing, "valueSetButton") end
    if self.hintText         == nil then table.insert(missing, "hintText") end
    if #missing > 0 then
        Log:warning("RLFilterConditionDialog:onGuiSetupFinished: missing elements: %s",
            table.concat(missing, ","))
    else
        Log:trace("RLFilterConditionDialog:onGuiSetupFinished: all elements resolved")
    end
end

-- =============================================================================
-- RLRM-280 measurement helper. Logs absolute on-screen geometry for a list of
-- (name, element) pairs at DEBUG. Coordinates are scaled to a 1920x1080
-- reference (matches the `element.size * 1920` pattern from session rule 4).
-- Used once per dialog open to ground position math in actual rendered values.
-- =============================================================================
function RLFilterConditionDialog:_logGeometry(label, items)
    if Log == nil or Log.debug == nil then return end
    for _, pair in ipairs(items) do
        local name, e = pair[1], pair[2]
        if e ~= nil then
            local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
            local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
            local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
            local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
            Log:debug("RLFilterConditionDialog._logGeometry[%s]: %s absPos=(%.1f,%.1f) size=(%.1fx%.1f) leftEdge=%.1f rightEdge=%.1f topEdge=%.1f bottomEdge=%.1f",
                label, name, ax, ay, sw, sh, ax, ax + sw, ay + sh, ay)
        else
            Log:debug("RLFilterConditionDialog._logGeometry[%s]: %s == nil", label, name)
        end
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

--- Filter newField.cmps down to the editable subset per field type.
--- P1-4b-2: ENUM now exposes `in`/`notin`; STRING and NUMBER keep the
--- multi-value cmps gated. The catalog has full cmp lists per field type;
--- this gate is the dialog's view of what it can actually edit.
local function editableCmpsFor(field)
    local out = {}
    if field == nil or field.cmps == nil then return out end
    local excludeSet = UNSUPPORTED_CMPS_BY_TYPE[field.type] or {}
    for _, c in ipairs(field.cmps) do
        if not excludeSet[c] then
            table.insert(out, c)
        end
    end
    Log:trace("RLFilterConditionDialog.editableCmpsFor: type=%s cmps=%d (excluded %d)",
        tostring(field.type), #out, #field.cmps - #out)
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
            -- P1-4b-2: subType under animalType=nil routes through the
            -- cross-species union helper (the value-set dialog can now
            -- author cross-type lists). gender + scoped subType still go
            -- through the scoped getEnumDomain. The empty-domain exclusion
            -- still applies to both paths (loadOrder gap, zero subtypes).
            local domain
            if f.key == "subType" and self.animalType == nil then
                domain = RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
            else
                domain = RLFilterFieldDisplay.getEnumDomain(f.key, self.animalType)
            end
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
    -- P1-4b-2 triage fix #2: also reset the drift flag at open. The dialog
    -- is a singleton; without this reset, a cancelled drifted edit would
    -- leak its flag into the next valid edit and refuse OK on a clean row.
    self.valueDrifted = false

    self:refreshFieldPicker()
    self:refreshCmpPicker()
    self:refreshValueWidget()

    -- RLRM-280 one-shot geometry log so position math is grounded in actual
    -- rendered values. Logged on every onOpen (cheap, DEBUG level, only when
    -- dialog is opened).
    self:_logGeometry("onOpen", {
        {"fieldLabel",       self.fieldLabel},
        {"cmpLabel",         self.cmpLabel},
        {"valueLabel",       self.valueLabel},
        {"fieldPicker",      self.fieldPicker},
        {"cmpPicker",        self.cmpPicker},
        {"valueNumberInput", self.valueNumberInput},
        {"valueStringInput", self.valueStringInput},
        {"valueBoolPicker",  self.valueBoolPicker},
        {"valueEnumPicker",  self.valueEnumPicker},
        {"valueSetButton",   self.valueSetButton},
        {"hintText",         self.hintText},
        {"okButton",         self.okButton},
    })
end

--- Resolve domain[1] for an enum field. Routes subType-under-unscoped-filter
--- through the cross-species union helper so the scalar default seed matches
--- the field-picker exposure (P1-4b-2: triage fix #1). Returns nil when the
--- domain is empty.
---@param fieldKey string
---@return string|nil
function RLFilterConditionDialog:resolveDefaultEnumValue(fieldKey)
    local domain
    if fieldKey == "subType" and self.animalType == nil then
        domain = RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
    else
        domain = RLFilterFieldDisplay.getEnumDomain(fieldKey, self.animalType)
    end
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
    if self.valueSetButton   ~= nil then self.valueSetButton:setVisible(false)   end
end

--- Resolve the active enum domain for the current working field, honoring
--- the P1-4b-2 subType cross-species union when animalType=nil. Used by the
--- enum picker + list-mode drift check + summary widget.
function RLFilterConditionDialog:_resolveActiveEnumDomain()
    if self.workingField == "subType" and self.animalType == nil then
        return RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
    end
    return RLFilterFieldDisplay.getEnumDomain(self.workingField, self.animalType)
end

--- Update the summary button text to reflect the current list length.
--- P1-4b-2 design decision #6: count-only ("N selected"), no label suffix
--- (the label list lives one click away in the value-set dialog). Reads
--- workingValue directly so callers can invoke this after any list mutation.
function RLFilterConditionDialog:refreshValueSetSummary()
    if self.valueSetButton == nil then return end
    local n = 0
    if type(self.workingValue) == "table" then n = #self.workingValue end
    local text
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText("rl_menu_filters_valueSet_summary") then
        text = string.format(g_i18n:getText("rl_menu_filters_valueSet_summary"), n)
    else
        text = string.format("%d selected", n)
    end
    self.valueSetButton:setText(text)
    Log:trace("RLFilterConditionDialog:refreshValueSetSummary: n=%d text='%s'",
        n, tostring(text))
end

function RLFilterConditionDialog:refreshValueWidget()
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field == nil then
        Log:warning("RLFilterConditionDialog:refreshValueWidget: workingField=%s not in catalog",
            tostring(self.workingField))
        return
    end

    self:_hideAllValueWidgets()

    -- P1-4b-2 triage fix #2: clear drift flag at the top of every refresh.
    -- The drift checks below re-set it only when the current value actually
    -- falls outside the live domain. Without this reset a stale flag from
    -- an earlier widget swap or session could leak into a clean refresh.
    self.valueDrifted = false

    -- P1-4b-2: list-shape branch. When cmp is `in`/`notin` on an enum field,
    -- show the summary button instead of the per-type scalar widget. Drift
    -- detection runs against the resolved domain (same data source as the
    -- scalar enum picker), and any value in workingValue not in the domain
    -- sets self.valueDrifted so onClickOk refuses commit until the user
    -- explicitly re-commits via the value-set dialog (which strips drifted
    -- keys; mirrors P1-4b's scalar drift contract).
    if field.type == "enum" and (self.workingCmp == "in" or self.workingCmp == "notin") then
        local domain = self:_resolveActiveEnumDomain() or {}
        self.valueEnumDomain = domain
        if #domain == 0 then
            Log:warning("RLFilterConditionDialog:refreshValueWidget: enum domain empty for list-mode field=%s animalType=%s",
                tostring(self.workingField), tostring(self.animalType))
            self:showHint("rl_menu_filters_subtypeRequiresAnimalType")
            return
        end
        -- List-shape drift check: any element of workingValue not in domain
        -- trips valueDrifted. workingValue may be a scalar (e.g. user just
        -- coerced from == to in via cmp change; coerce wraps the scalar so
        -- it's already a table by this point) or nil (fresh in/notin).
        if type(self.workingValue) == "table" then
            local domainSet = {}
            for _, k in ipairs(domain) do domainSet[k] = true end
            local drifted = {}
            for _, v in ipairs(self.workingValue) do
                if not domainSet[v] then table.insert(drifted, tostring(v)) end
            end
            if #drifted > 0 then
                self.valueDrifted = true
                Log:warning("RLFilterConditionDialog:refreshValueWidget: list-mode drift; %d value(s) not in domain: %s",
                    #drifted, table.concat(drifted, ", "))
                self:showHint("rl_menu_filters_enumValueDrifted")
            end
        end
        if self.valueSetButton ~= nil then
            self.valueSetButton:setVisible(true)
            self:refreshValueSetSummary()
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: list-mode field=%s cmp=%s domainSize=%d valueCount=%d drifted=%s",
            tostring(self.workingField), tostring(self.workingCmp),
            #domain,
            type(self.workingValue) == "table" and #self.workingValue or 0,
            tostring(self.valueDrifted == true))
        return
    end

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
        -- P1-4b-2 triage fix #1: route through _resolveActiveEnumDomain so
        -- subType under animalType=nil uses the cross-species union (matches
        -- the field-picker exposure + list-mode branch).
        local domain = self:_resolveActiveEnumDomain()
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
                self.valueDrifted = true
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
    self.valueDrifted = false
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
    if cmp == self.workingCmp then
        -- No-op: picker fires onClick even when state is unchanged (e.g. after
        -- onOpen seed). Skip the coerce pass to avoid logging churn.
        self:clearHint()
        return
    end

    -- P1-4b-2: route cmp transitions through the catalog coerce helper so
    -- scalar<->list shape changes wrap/unwrap the value consistently.
    -- Substring<->list / scalar<->substring cross-shape transitions are
    -- caught by the catalog helper's illegal-transition branch and clear
    -- value+rawText (defensive; shouldn't happen given editableCmpsFor's
    -- per-type gate).
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field ~= nil then
        local oldCond = {
            field   = self.workingField,
            cmp     = self.workingCmp,
            value   = self.workingValue,
            rawText = self.workingRawText,
        }
        local result = RLFilterFieldCatalog.coerceConditionOnCmpChange(oldCond, cmp, field)
        if result.patch.value ~= nil then
            self.workingValue = result.patch.value
        end
        if result.clearKeys ~= nil then
            for _, k in ipairs(result.clearKeys) do
                if     k == "rawText" then self.workingRawText = nil
                elseif k == "value"   then self.workingValue   = nil
                end
            end
        end

        -- P1-4b-2 triage fix #3: drift-aware list->scalar collapse. The
        -- catalog is pure-data and cannot consult the live domain; it
        -- returns value[1] verbatim. We apply the spec's "skip drifted
        -- values during collapse" rule here at the dialog layer where
        -- the live domain is accessible. On list->scalar transition,
        -- walk the source list and pick the first element actually in
        -- the resolved domain. If none survives, clear value and set
        -- valueDrifted so onClickOk refuses until the user picks.
        local oldIsList = (oldCond.cmp == "in" or oldCond.cmp == "notin")
        local newIsScalar = (cmp == "==" or cmp == "!=")
        if oldIsList and newIsScalar and field.type == "enum"
           and type(oldCond.value) == "table" and #oldCond.value > 0 then
            local domain = self:_resolveActiveEnumDomain() or {}
            local domainSet = {}
            for _, k in ipairs(domain) do domainSet[k] = true end
            local survivor = nil
            for _, v in ipairs(oldCond.value) do
                if domainSet[v] then survivor = v; break end
            end
            if survivor ~= nil then
                if self.workingValue ~= survivor then
                    Log:debug("RLFilterConditionDialog:onCmpChanged: drift-aware collapse picked '%s' over catalog's '%s'",
                        tostring(survivor), tostring(self.workingValue))
                end
                self.workingValue = survivor
            else
                Log:warning("RLFilterConditionDialog:onCmpChanged: all list values drifted (%d); clearing scalar value + setting valueDrifted",
                    #oldCond.value)
                self.workingValue = nil
                self.valueDrifted = true
            end
        end
    end

    self.workingCmp = cmp
    -- Reset hint so a stale reject hint doesn't bleed across user input
    -- (matches the clearHint helper's own contract at :148).
    self:clearHint()
    -- Refresh value widget AND cmp picker labels - the widget swaps when the
    -- cmp shape changes (scalar enum picker <-> list summary button). Also
    -- re-run drift check (refreshValueWidget owns that for both modes).
    self:refreshValueWidget()
    Log:debug("RLFilterConditionDialog:onCmpChanged: cmp=%s workingValueType=%s",
        tostring(self.workingCmp), type(self.workingValue))
end

-- =============================================================================
-- P1-4b-2: value-set dialog handoff
-- =============================================================================

--- Open RLFilterValueSetDialog for the current field + value list. Passes
--- workingValue (a table for in/notin or nil for fresh) as the initial
--- selection; the value-set dialog tolerates drift on initial render and
--- strips drifted keys on commit (the explicit re-commit path that clears
--- valueDrifted).
function RLFilterConditionDialog:onClickOpenValueSet()
    Log:debug("RLFilterConditionDialog:onClickOpenValueSet: field=%s animalType=%s currentCount=%d",
        tostring(self.workingField), tostring(self.animalType),
        type(self.workingValue) == "table" and #self.workingValue or 0)
    local initialList = type(self.workingValue) == "table" and self.workingValue or nil
    RLFilterValueSetDialog.show(
        self.onValueSetCommitted, self,
        self.workingField, self.animalType, initialList)
end

--- Value-set dialog committed back. nil = cancel; non-nil = array of
--- internal keys (drifted keys already stripped by the value-set dialog).
--- Clears valueDrifted on a non-nil commit (the explicit re-commit
--- contract: only an explicit OK from the value-set dialog can clear the
--- drift flag, per spec Boundaries Always #4).
function RLFilterConditionDialog:onValueSetCommitted(list)
    if list == nil then
        Log:trace("RLFilterConditionDialog:onValueSetCommitted: cancel")
        return
    end
    self.workingValue = list
    -- Explicit re-commit through the value-set dialog clears the unified
    -- drift flag (only path that does so for list-mode; scalar mode clears
    -- via onValueEnumChanged at :535).
    self.valueDrifted = false
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onValueSetCommitted: %d key(s)", #list)
    self:refreshValueSetSummary()
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
    self.valueDrifted = false
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onValueEnumChanged: value=%s (state=%d)",
        tostring(self.workingValue), state)
end

-- =============================================================================
-- OK / Cancel
-- =============================================================================

--- Validate working state, build coerced newCondition, deliver to caller, close.
---
--- Note: an earlier draft of RLRM-280 intercepted Enter-on-valueSetButton
--- here via a focused-element check, but that guard could also hijack a
--- real mouse click on OK when focus had not yet moved off the button. The
--- guard has been removed; Enter on the multi-value picker button relies
--- on FocusManager's default activation. If that doesn't activate the
--- button in-game, the case is tracked as a follow-up enhancement.
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
        -- Refuse close when the domain is empty - the field-picker exclusion
        -- should already prevent this case from reaching OK, but guard
        -- against legacy rows.
        local domain = self.valueEnumDomain or {}
        if #domain == 0 then
            Log:warning("RLFilterConditionDialog:onClickOk: enum domain empty for field=%s; refusing commit",
                tostring(self.workingField))
            self:showHint("rl_menu_filters_subtypeRequiresAnimalType")
            return
        end
        -- Drift refuse-commit (unified valueDrifted covers scalar + list).
        -- Scalar mode clears via onValueEnumChanged (user picks via picker);
        -- list mode clears via onValueSetCommitted (user re-commits via the
        -- value-set dialog, which strips drifted keys). Silently snapping
        -- would rewrite stored keys to a different value.
        if self.valueDrifted then
            Log:warning("RLFilterConditionDialog:onClickOk: refusing commit, value drifted (workingValue=%s, field=%s, cmp=%s); pick a replacement",
                tostring(self.workingValue), tostring(self.workingField), tostring(self.workingCmp))
            self:showHint("rl_menu_filters_enumValueDrifted")
            return
        end

        -- P1-4b-2: list-shape commit for in/notin. workingValue is a table
        -- of stable internal keys (committed via onValueSetCommitted, or
        -- coerceConditionOnCmpChange wrapped a scalar on cmp swap). Empty
        -- list reject mirrors the value-set dialog's own empty-set reject.
        if self.workingCmp == "in" or self.workingCmp == "notin" then
            if type(self.workingValue) ~= "table" or #self.workingValue == 0 then
                Log:warning("RLFilterConditionDialog:onClickOk: refusing empty list commit (field=%s cmp=%s)",
                    tostring(self.workingField), tostring(self.workingCmp))
                self:showHint("rl_menu_filters_emptyValueRejected")
                return
            end
            -- Defensive validation: every element must be in domain. The
            -- value-set dialog strips drifted keys on its OK commit, so
            -- post-onValueSetCommitted this should always hold; if not
            -- it's a real bug, not user data.
            local domainSet = {}
            for _, k in ipairs(domain) do domainSet[k] = true end
            for _, v in ipairs(self.workingValue) do
                if not domainSet[v] then
                    Log:warning("RLFilterConditionDialog:onClickOk: list element %s not in domain post-drift-check; refusing commit",
                        tostring(v))
                    self:showHint("rl_menu_filters_enumValueDrifted")
                    return
                end
            end
            newCondition.value = self.workingValue
            Log:debug("RLFilterConditionDialog:onClickOk: list commit field=%s cmp=%s n=%d",
                tostring(self.workingField), tostring(self.workingCmp), #self.workingValue)
        else
            -- Scalar enum commit (==/!=). Defensive: workingValue must be a
            -- domain key (initial seed from initialCondition or
            -- resolveDefaultEnumValue; onValueEnumChanged only writes
            -- domain[state]; drift caught above).
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
        end
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

--- Dialog-level input event override.
---
--- Without this override, Enter on a focused Value TextInput or
--- `valueSetButton` commits the dialog (via the OK button) instead of
--- activating the focused widget. This intercept routes MENU_ACCEPT to
--- `onFocusActivate` for the three value widgets so the keyboard path
--- matches the mouse path.
---
--- Gates (all required, in order):
---   1. `not eventUsed`                                  upstream layer hasn't claimed it
---   2. `action == InputAction.MENU_ACCEPT`              only Enter, never affects other actions
---   3. focused element is `valueNumberInput` /          only the three value widgets that need it;
---      `valueStringInput` / `valueSetButton`            every other focused widget falls through
---   4a. TextInput case: `not focused.forcePressed`      skip when IME is already active so the
---                                                       existing IME-Enter (commit) path is not
---                                                       interrupted by a forcePressed toggle
---   4b. Button case: `focused:getIsActive() and         guarantee activation will fire a
---                    focused.onClickCallback ~= nil`    callback (no dead-key activation)
---
--- On match: DEBUG log + `focused:onFocusActivate()` + return true.
--- On any miss: fall through via super so the dialog's default Enter
--- handling (OK button commit) is preserved for every Field / Compare /
--- bool / enum picker and for the dialog-open "Enter to accept" shortcut.
---
--- Standard Lua class-method override; not new input-action registration.
---
---@param action number InputAction enum value
---@param value any axis / digital value passed by the dispatcher
---@param eventUsed boolean true when an upstream layer already consumed
---@return boolean true to consume MENU_ACCEPT here, otherwise the super result
function RLFilterConditionDialog:inputEvent(action, value, eventUsed)
    local focused = FocusManager ~= nil
                    and FocusManager.getFocusedElement ~= nil
                    and FocusManager:getFocusedElement()
                    or nil
    Log:trace("RLFilterConditionDialog:inputEvent: entry action=%s eventUsed=%s focusedId=%s",
        tostring(action),
        tostring(eventUsed),
        focused ~= nil and tostring(focused.id) or "nil")

    if not eventUsed and action == InputAction.MENU_ACCEPT then
        local intercept = false
        if focused == self.valueNumberInput or focused == self.valueStringInput then
            -- TextInput: only intercept when (a) the widget is visible /
            -- enabled (getIsActive guards stale identity if focus survives
            -- a refreshValueWidget swap) and (b) IME is inactive. When
            -- the IME is already active, Enter is delivered through the
            -- TextInput's own callback path (our onEnterPressed handler).
            intercept = focused ~= nil
                        and focused.getIsActive ~= nil
                        and focused:getIsActive()
                        and not focused.forcePressed
        elseif focused == self.valueSetButton then
            -- Button: only intercept when activation will actually fire a
            -- callback. Guard against transient inactive states (e.g.
            -- visibility toggled mid-frame, callback dropped during reload).
            intercept = focused ~= nil
                        and focused.getIsActive ~= nil
                        and focused:getIsActive()
                        and focused.onClickCallback ~= nil
        end

        if intercept then
            Log:debug("RLFilterConditionDialog:inputEvent: routing MENU_ACCEPT to onFocusActivate on id=%s",
                tostring(focused.id))
            focused:onFocusActivate()
            return true
        end
    end

    return RLFilterConditionDialog:superClass().inputEvent(self, action, value, eventUsed)
end

--- Enter raised by a TextInputElement callback. `dismiss=true` is the
--- IME-closing gesture (suppresses commit so the user can review the
--- typed value); `dismiss=false`/`nil` is the IME-complete commit path.
--- Mirrors NameInputDialog.lua:135-137.
---@param _ any unused (the TextInputElement raising the callback)
---@param dismiss boolean|nil true on IME-close gesture, false/nil on commit
---@return boolean true to consume the event, false to fall through
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
