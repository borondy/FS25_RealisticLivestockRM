-- RLFilterFieldCatalog.lua
-- Declarative registry of fields usable in saveable filters.
--
-- Single source of truth consumed by:
--   - RLFilterEvaluator: read field value off animal via `getter(animal)`
--   - P2 RLFilterSerialization: `type` drives wire/XML encoding
--   - P1+ UI editor: `cmps`, `animalTypes`, `type` drive the field picker
--
-- Field entry shape:
--   {
--     key          = "<stable string, also stored in filters>",
--     type         = "number" | "bool" | "enum" | "string",
--     cmps         = { "<", "<=", "==", "!=", ">=", ">", "in", "notin", "contains", "notcontains" },
--     animalTypes  = "all" | { "COW", "SHEEP", ... },  -- stable string names;
--                                                       -- resolved at runtime via AnimalType[name]
--                                                       -- (AnimalType global is populated by AnimalSystem
--                                                       -- after our source-time load).
--     getter       = function(animal) -> value | nil,
--     monitorGated = true | false,   -- true means getter requires monitor.active
--     scale        = "0-99" | nil,   -- presentation scale hint for UI
--   }
--
-- Canonical genetics scale is 0-99 via RLScaleHelper.scaleToNinetyNine.
-- All enum values use STABLE INTERNAL KEYS (e.g. "male"/"female"), NOT
-- translated strings. UI translates at render time.

local Log = RmLogging.getLogger("RLRM")

RLFilterFieldCatalog = {}

-- =============================================================================
-- Comparator sets
-- =============================================================================

-- Per-type comparator sets:
--   * `!=` kept for number + enum (leaf-level negation primitive since the
--     AST has no NOT operator yet); dropped for bool (redundant with `==`).
--   * `between` intentionally omitted - expressed as AND of two conditions.
--   * string: substring match only. `==`/`!=` deliberately excluded so the
--     op set stays disjoint from enum (both are strings at the Lua-type
--     level). Callers can use `contains <fullName>` for exact match if needed.
local NUMBER_CMPS = { "<", "<=", "==", "!=", ">=", ">", "in", "notin" }
local BOOL_CMPS   = { "==" }
local ENUM_CMPS   = { "==", "!=", "in", "notin" }
local STRING_CMPS = { "contains", "notcontains" }

-- Per-type default comparator used by the conditions editor when adding a new
-- row or coercing the cmp on a field-type change. Picked to produce a row that
-- "matches every animal at the default value" so the user can tighten from
-- there: NUMBER -> `>=` (the naive cmps[1] is `<`, which would default to
-- `age < 0` matching nothing); BOOL -> `==` (the only sensible bool cmp);
-- ENUM / STRING fall back to `cmps[1]` for now (P1-4b widens the editor).
local DEFAULT_CMP_BY_TYPE = {
    number = ">=",
    bool   = "==",
}

-- =============================================================================
-- Getter helpers
-- =============================================================================

--- Process-lifetime flag: emit the helper-missing warning exactly once so
--- a load-order regression is visible in logs without spamming every genetics
--- getter call.
local _warnedHelperMissing = false

--- Return the numeric value scaled to 0-99, or nil if the raw value is nil.
--- Emits a one-shot warning if RLScaleHelper is unavailable so load-order
--- regressions are diagnosable; otherwise falls through to the evaluator's
--- generic nil-value trace branch.
local function scaled(rawValue)
    if rawValue == nil then return nil end
    if RLScaleHelper == nil or RLScaleHelper.scaleToNinetyNine == nil then
        if not _warnedHelperMissing then
            Log:warning("RLFilterFieldCatalog.scaled: RLScaleHelper unavailable, genetics getters returning nil (check main.lua SECTION 2b load order)")
            _warnedHelperMissing = true
        end
        return nil
    end
    return RLScaleHelper.scaleToNinetyNine(rawValue)
end

--- True when the animal's monitor is active (weight/health values are
--- only meaningful when the monitor is running). Returns false if the
--- monitor record is missing or the animal was flagged as removed.
local function monitorActive(animal)
    return animal ~= nil
        and animal.monitor ~= nil
        and animal.monitor.active == true
        and animal.monitor.removed ~= true
end

-- =============================================================================
-- Field registry
-- =============================================================================

--- Map of catalog key -> field entry. Declared as an ordered array first so
--- that field order is deterministic; then also indexed by key for O(1)
--- lookup via RLFilterFieldCatalog.get().
---@type table[]
RLFilterFieldCatalog.FIELDS = {
    -- ---------- Age / identity flags ----------
    {
        key         = "age",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.age end,
        monitorGated = false,
    },
    {
        key         = "gender",
        type        = "enum",
        cmps        = ENUM_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.gender end,
        monitorGated = false,
    },
    {
        key         = "isCastrated",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.isCastrated == true end,
        monitorGated = false,
    },
    {
        key         = "isPregnant",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.isPregnant == true end,
        monitorGated = false,
    },
    {
        key         = "isLactating",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = { "COW" },
        getter      = function(animal) return animal.isLactating == true end,
        monitorGated = false,
    },
    {
        key         = "hasName",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        getter      = function(animal)
            if animal.getHasName ~= nil then return animal:getHasName() end
            return animal.name ~= nil and animal.name ~= ""
        end,
        monitorGated = false,
    },
    {
        key         = "hasAnyDisease",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        getter      = function(animal)
            if animal.getHasAnyDisease ~= nil then return animal:getHasAnyDisease() end
            return animal.diseases ~= nil and #animal.diseases > 0
        end,
        monitorGated = false,
    },
    {
        key         = "hasAnyMark",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        -- Mirrors Animal:getMarked() with no key (RealisticLivestock_Animal.lua:1494-1504):
        -- true iff at least one entry in animal.marks has active=true. Fallback path
        -- walks the raw table so tests can use plain-table fake animals. Generic
        -- "any mark" only; per-mark-kind fields (PLAYER / AI_MANAGER_*) deferred.
        getter      = function(animal)
            if animal.getMarked ~= nil then return animal:getMarked() == true end
            if animal.marks == nil then return false end
            for _, mark in pairs(animal.marks) do
                if mark.active then return true end
            end
            return false
        end,
        monitorGated = false,
    },
    {
        key         = "name",
        type        = "string",
        cmps        = STRING_CMPS,
        animalTypes = "all",
        -- Free-text animal name. Returns "" (not nil) for unset / empty-string
        -- names so notcontains gets the right semantic for unnamed animals:
        -- an empty name vacuously does not contain any needle -> notcontains
        -- is true. If we returned nil, the evaluator's blanket nil-guard would
        -- collapse notcontains to false, which silently excludes every
        -- unnamed animal from a "name notcontains X" filter (the symptom that
        -- turned up when testing chicken/sheep butcher filters where most
        -- animals are unnamed).
        getter      = function(animal)
            if animal.name == nil then return "" end
            return animal.name
        end,
        monitorGated = false,
    },

    -- ---------- Monitor-gated metrics ----------
    {
        key         = "weight",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        monitorGated = true,
        getter      = function(animal)
            if not monitorActive(animal) then return nil end
            return animal.weight
        end,
    },
    {
        key         = "health",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        monitorGated = true,
        getter      = function(animal)
            if not monitorActive(animal) then return nil end
            return animal.health
        end,
    },

    -- ---------- Genetics (0-99 scale) ----------
    {
        key         = "genetics.metabolism",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.metabolism) or nil
        end,
        monitorGated = false,
    },
    {
        key         = "genetics.health",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.health) or nil
        end,
        monitorGated = false,
    },
    {
        key         = "genetics.fertility",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.fertility) or nil
        end,
        monitorGated = false,
    },
    {
        key         = "genetics.quality",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.quality) or nil
        end,
        monitorGated = false,
    },
    {
        key         = "genetics.productivity",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = { "COW", "SHEEP", "CHICKEN" },
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.productivity) or nil
        end,
        monitorGated = false,
    },
    {
        key         = "genetics.overall",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        -- Overall = scaleToNinetyNine(avg of present stats). Matches the
        -- name-tag convention at AnimalScreenBase.formatDisplayName.
        getter      = function(animal)
            if animal.genetics == nil then return nil end
            local total, count = 0, 0
            for _, v in pairs(animal.genetics) do
                if v ~= nil then
                    total = total + v
                    count = count + 1
                end
            end
            if count == 0 then return nil end
            return scaled(total / count)
        end,
        monitorGated = false,
    },

    -- ---------- Subtype / breed ----------
    {
        key         = "subType",
        type        = "enum",
        cmps        = ENUM_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.subType end,
        monitorGated = false,
    },
}

-- =============================================================================
-- Indexed lookup
-- =============================================================================

--- key -> field entry for O(1) lookup.
---@type table<string, table>
RLFilterFieldCatalog._BY_KEY = {}
for _, field in ipairs(RLFilterFieldCatalog.FIELDS) do
    RLFilterFieldCatalog._BY_KEY[field.key] = field
end

--- Look up a field entry by key. Returns nil when the key is unknown
--- (evaluator warns on its behalf; catalog stays silent).
---@param key string
---@return table|nil field entry
function RLFilterFieldCatalog.get(key)
    return RLFilterFieldCatalog._BY_KEY[key]
end

--- Process-lifetime flag: emit the AnimalType-missing warning exactly once.
--- Distinct from _warnedHelperMissing so each load-order regression is
--- reported independently.
local _warnedAnimalTypeMissing = false

--- True when the given field is valid for a given animalTypeIndex.
--- Missing animalTypeIndex is treated as "all types" for tooling.
--- `field.animalTypes` holds stable string names ("COW", "SHEEP", ...)
--- which we resolve via `AnimalType[name]` at call time, since the global
--- is populated by `AnimalSystem:loadAnimals` AFTER our source-time load.
---@param field table entry from FIELDS
---@param animalTypeIndex number|nil
---@return boolean
function RLFilterFieldCatalog.isAvailableForType(field, animalTypeIndex)
    if field == nil then return false end
    if field.animalTypes == "all" then return true end
    if animalTypeIndex == nil then return true end
    if _G.AnimalType == nil then
        if not _warnedAnimalTypeMissing then
            Log:warning("RLFilterFieldCatalog.isAvailableForType: AnimalType global is nil; allowing all type-scoped fields through (check AnimalSystem load order)")
            _warnedAnimalTypeMissing = true
        end
        return true
    end
    for _, allowedName in ipairs(field.animalTypes) do
        if _G.AnimalType[allowedName] == animalTypeIndex then return true end
    end
    return false
end

--- Return the ordered subset of FIELDS that pass `isAvailableForType` for
--- `animalTypeIndex` and (optionally) match `typeFilter` against `field.type`.
---
--- `typeFilter` is either nil (no type filter), a string ("number"), or a set
--- table `{ number = true, bool = true }`. Ordering follows the canonical
--- FIELDS array (declaration order), which the editor relies on to keep the
--- field picker stable across re-renders.
---@param animalTypeIndex number|nil
---@param typeFilter string|table|nil
---@return table[] filtered ordered field entries
function RLFilterFieldCatalog.getAllForAnimalType(animalTypeIndex, typeFilter)
    local out = {}
    local filterSet
    if type(typeFilter) == "string" then
        filterSet = { [typeFilter] = true }
    elseif type(typeFilter) == "table" then
        filterSet = typeFilter
    end
    for _, field in ipairs(RLFilterFieldCatalog.FIELDS) do
        local typeOk = (filterSet == nil) or (filterSet[field.type] == true)
        if typeOk and RLFilterFieldCatalog.isAvailableForType(field, animalTypeIndex) then
            table.insert(out, field)
        end
    end
    Log:trace("RLFilterFieldCatalog.getAllForAnimalType: animalTypeIndex=%s typeFilter=%s -> %d field(s)",
        tostring(animalTypeIndex), tostring(typeFilter), #out)
    return out
end

--- Return the per-type default value used when seeding a new condition row or
--- coercing on a field-type change. Mirrors the cmp default rule: NUMBER -> 0,
--- BOOL -> false; unknown types fall back to nil and the caller's
--- defensive-default branch.
---@param fieldType string|nil
---@return any default value (nil for unknown types)
function RLFilterFieldCatalog.getDefaultValueForType(fieldType)
    if fieldType == "number" then return 0 end
    if fieldType == "bool"   then return false end
    return nil
end

--- Return the default cmp for the given field. Consults
--- `DEFAULT_CMP_BY_TYPE` first; on miss falls back to `field.cmps[1]` so a
--- future field type (e.g. enum / string when P1-4b extends the editor)
--- still gets a deterministic default. Returns nil only when the field has
--- neither a default-by-type entry nor any cmps configured (treated as a
--- catalog defect; logged at TRACE).
---@param field table entry from FIELDS
---@return string|nil cmp
function RLFilterFieldCatalog.getDefaultCmpForField(field)
    if field == nil then return nil end
    local byType = DEFAULT_CMP_BY_TYPE[field.type]
    if byType ~= nil then return byType end
    if field.cmps ~= nil and field.cmps[1] ~= nil then
        Log:trace("RLFilterFieldCatalog.getDefaultCmpForField: no DEFAULT_CMP_BY_TYPE for type=%s, falling back to cmps[1]=%s",
            tostring(field.type), tostring(field.cmps[1]))
        return field.cmps[1]
    end
    Log:trace("RLFilterFieldCatalog.getDefaultCmpForField: field key=%s has no DEFAULT_CMP_BY_TYPE entry and no cmps",
        tostring(field.key))
    return nil
end

-- Exposed for tests that need to inspect the default table directly.
RLFilterFieldCatalog._DEFAULT_CMP_BY_TYPE = DEFAULT_CMP_BY_TYPE

--- Coerce a condition row when the field has just changed. Pure data; no GUI
--- or state side effects. Encodes the legacy invariants from the inline-widget
--- editor's onConditionFieldChanged (RLMenuSettingsFrame.lua pre-v2-modal):
---   1. The cmp survives if the new field still accepts it; otherwise it
---      resets to getDefaultCmpForField(newField).
---   2. When the field's type diverges (number <-> bool, etc.), the value
---      resets to getDefaultValueForType(newField.type) AND the stale
---      `rawText` (the in-flight TextInput buffer for number rows) is added
---      to the clearKeys list. F2 lesson: nil-valued keys in a table literal
---      vanish during construction, so callers MUST explicitly clear rather
---      than rely on `patch.rawText = nil`.
---   3. Number -> Number (or bool -> bool) preserves value + rawText.
---
--- Caller decides what "editable" means for cmp validity: the editor strips
--- multi-value cmps (`in`, `notin`) until P1-4b lands a multi-value widget,
--- so the caller passes its filtered list via `editableCmps`. When nil, the
--- helper falls back to newField.cmps (all catalog cmps).
---
---@param oldCond table {field=string, cmp=string, value=any, rawText=string?}
---@param newFieldKey string the field the user just selected
---@param editableCmps string[]|nil whitelist of cmps the caller's editor renders
---@return table {patch=table, clearKeys=string[]|nil}
---   patch always carries `field`. `cmp` is present only when reset.
---   `value` is present only when types diverge.
---   `clearKeys` is `{"rawText"}` when types diverge, nil otherwise.
function RLFilterFieldCatalog.coerceConditionOnFieldChange(oldCond, newFieldKey, editableCmps)
    if oldCond == nil or newFieldKey == nil then
        Log:warning("RLFilterFieldCatalog.coerceConditionOnFieldChange: nil oldCond=%s newFieldKey=%s",
            tostring(oldCond), tostring(newFieldKey))
        return { patch = {}, clearKeys = nil }
    end
    local newField = RLFilterFieldCatalog.get(newFieldKey)
    if newField == nil then
        Log:warning("RLFilterFieldCatalog.coerceConditionOnFieldChange: unknown newFieldKey=%s; returning identity patch",
            tostring(newFieldKey))
        return { patch = { field = newFieldKey }, clearKeys = nil }
    end
    local oldField = RLFilterFieldCatalog.get(oldCond.field)
    local patch = { field = newField.key }

    local cmps = editableCmps
    if cmps == nil then cmps = newField.cmps end
    local cmpStillValid = false
    if cmps ~= nil then
        for _, c in ipairs(cmps) do
            if c == oldCond.cmp then cmpStillValid = true; break end
        end
    end
    if not cmpStillValid then
        patch.cmp = RLFilterFieldCatalog.getDefaultCmpForField(newField)
    end

    local clearKeys = nil
    local typesDiverge = (oldField == nil or oldField.type ~= newField.type)
    if typesDiverge then
        patch.value = RLFilterFieldCatalog.getDefaultValueForType(newField.type)
        clearKeys = { "rawText" }
    end

    Log:trace("RLFilterFieldCatalog.coerceConditionOnFieldChange: oldField=%s newField=%s typesDiverge=%s cmpReset=%s",
        tostring(oldCond.field), tostring(newField.key),
        tostring(typesDiverge), tostring(patch.cmp ~= nil))
    return { patch = patch, clearKeys = clearKeys }
end

Log:debug("RLFilterFieldCatalog: loaded %d fields", #RLFilterFieldCatalog.FIELDS)
