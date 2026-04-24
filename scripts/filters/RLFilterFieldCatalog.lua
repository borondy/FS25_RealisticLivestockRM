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

Log:debug("RLFilterFieldCatalog: loaded %d fields", #RLFilterFieldCatalog.FIELDS)
