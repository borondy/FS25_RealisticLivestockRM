-- RLHerdsmanRulePresenter.lua
-- Pure view-model for the Herdsman rule menu frame (M-Frame F1, RLRM-382).
--
-- The single home for every list / detail / visibility / validation decision the
-- Herdsman frame needs, so the frame `.lua` stays bind-only (read element -> call a
-- presenter function -> write the element). This is the deliberate counter-move to
-- the Filters subtab (RLMenuSettingsFrame), which inlines that logic in the frame and
-- is the anti-example for wiring thickness.
--
-- PURITY CONTRACT (hard):
--   * Every function takes plain data (plus injected resolver / label deps) and
--     returns plain data: tables / strings / booleans.
--   * ZERO g_* globals, ZERO element refs, ZERO setText/setVisible/SmoothList,
--     ZERO XML, ZERO RLFilterService / placeableSystem.
--   * Game-state reads arrive through INJECTED resolvers (resolveName, resolveFilter);
--     the frame layer owns wiring those to g_currentMission.placeableSystem and
--     RLFilterService.
--   * Sibling pure-module constants ARE referenced directly: RLFilterUsage.* for the
--     allowed-usage map, and RLHerdsmanRuleService.OPERATIONS for the operation
--     validity set (the canonical set lives there; the presenter does not duplicate
--     it). These are pure constant tables, not game state.
--
-- Mirrors RLFilterFieldCatalog's SHAPE (top-level table, module-local Log, module
-- constants, LuaDoc + logging on every function). 100% dual-run: in-game
-- RLHerdsmanRulePresenterTests + headless herdsman_rule_presenter_suite.lua.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRulePresenter = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Canonical run / visual order for rule sections (D3 "visual order = run order";
--- SS7). Sell frees space before Buy fills it, matching legacy onDayChanged order.
--- Presenter-owned: the service deliberately does NOT own ordering. The operation
--- VALIDITY set still comes from RLHerdsmanRuleService.OPERATIONS (no duplication).
RLHerdsmanRulePresenter.OPERATION_ORDER = { "sell", "buy", "castrate", "naming", "ai" }

--- operation -> rank, derived from OPERATION_ORDER for O(1) section placement and
--- "is this one of the five orderable operations" membership.
local OPERATION_RANK = {}
for rank, op in ipairs(RLHerdsmanRulePresenter.OPERATION_ORDER) do
    OPERATION_RANK[op] = rank
end

--- Stable key order for the param-visibility map. Every getParamVisibility result
--- carries exactly these keys (defaulting false) so callers can key-test safely.
local PARAM_KEYS = { "filter", "maxAnimals", "budget", "mark", "convention", "previous", "semen" }

--- operation -> set of VISIBLE detail-pane params (true). Grounded in the SS10
--- legacy-parity matrix (AIAnimalManager.new settings defaults): Sell maxAnimals+mark;
--- Buy budget+maxAnimals; Castrate mark (no cap); Naming convention+previous (no
--- filter, no cap); AI maxAnimals+mark+semen. `filter` shows for every operation
--- except naming. Params absent from a set default to false (hidden).
local PARAM_VISIBILITY = {
    sell     = { filter = true, maxAnimals = true, mark = true },
    buy      = { filter = true, maxAnimals = true, budget = true },
    castrate = { filter = true, mark = true },
    naming   = { convention = true, previous = true },
    ai       = { filter = true, maxAnimals = true, mark = true, semen = true },
}

--- operation -> allowed filter-usage membership map (D7). Buy draws from the dealer
--- pool ({ANY, DEALER}); every owned-herd operation draws from owned ({ANY, OWNED}).
--- Built against the RLFilterUsage constants (never inline strings). Naming's set is
--- inert (its filter row is hidden + validateEdit requires nil filterId) but kept
--- ticket-faithful at {ANY, OWNED}.
local ALLOWED_USAGES = {
    sell     = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    buy      = { [RLFilterUsage.ANY] = true, [RLFilterUsage.DEALER] = true },
    castrate = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    naming   = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    ai       = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
}

-- -----------------------------------------------------------------------------
-- Param value domains
-- -----------------------------------------------------------------------------
-- The detail-pane MultiTextOption widgets consume the *_VALUES (via the fresh-array
-- accessors below); validateParams checks membership via the derived *_SET tables.
-- Grounded in the legacy herdsman option value-lists (the binary convention /
-- budget-type options + the 28-value budget-percentage list) and the rule serializer
-- field types (maxAnimals Int, budget.fixed Int, budget.percentage Float).

--- Naming convention domain (binary: random | alphabetical).
local CONVENTION_VALUES = { "random", "alphabetical" }

--- Buy budget-type domain (binary: fixed | percentage).
local BUDGET_TYPE_VALUES = { "fixed", "percentage" }

--- Buy budget-percentage domain: the 28-value legacy whitelist. A percentage is
--- valid ONLY as a member of this list, never as a free numeric value.
local BUDGET_PERCENTAGE_VALUES = {
    0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 8, 9, 10, 12.5, 15, 17.5, 20, 25, 30, 35,
    40, 45, 50, 60, 70, 80, 90, 100,
}

--- Derived O(1) membership sets. Single source of truth is the *_VALUES array;
--- the set is rebuilt from it so the two can never drift.
local CONVENTION_SET = {}
for _, value in ipairs(CONVENTION_VALUES) do CONVENTION_SET[value] = true end
local BUDGET_TYPE_SET = {}
for _, value in ipairs(BUDGET_TYPE_VALUES) do BUDGET_TYPE_SET[value] = true end
local BUDGET_PERCENTAGE_SET = {}
for _, value in ipairs(BUDGET_PERCENTAGE_VALUES) do BUDGET_PERCENTAGE_SET[value] = true end

--- maxAnimals integer bounds (inclusive); the serializer writes it as an Int.
RLHerdsmanRulePresenter.MAXANIMALS_MIN = 1
RLHerdsmanRulePresenter.MAXANIMALS_MAX = 9999

--- The "any dewar" semen sentinel. The frame prepends this as its own option with an
--- i18n label; formatSemenOption (real dewars only) never emits it.
RLHerdsmanRulePresenter.SEMEN_ANY = "any"

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Process-lifetime flag: warn exactly once if RLHerdsmanRuleService (the canonical
--- operation-validity set) is unreachable, so a load-order regression is visible in
--- logs without spamming every validateEdit call.
local _warnedOperationsMissing = false

--- True when `operation` is one of the canonical rule operations. Prefers the
--- service's authoritative OPERATIONS set (single source of truth, not duplicated
--- here); falls back to OPERATION_RANK membership (the same five ops, presenter-owned
--- ordering data) with a one-shot warning if the service global is somehow unloaded.
---@param operation any
---@return boolean
local function isKnownOperation(operation)
    if type(operation) ~= "string" then return false end
    if RLHerdsmanRuleService ~= nil and RLHerdsmanRuleService.OPERATIONS ~= nil then
        return RLHerdsmanRuleService.OPERATIONS[operation] == true
    end
    if not _warnedOperationsMissing then
        Log:warning("RLHerdsmanRulePresenter.isKnownOperation: RLHerdsmanRuleService.OPERATIONS unavailable; falling back to OPERATION_ORDER membership (check main.lua SECTION 11h load order)")
        _warnedOperationsMissing = true
    end
    return OPERATION_RANK[operation] ~= nil
end

--- Comparator for rules within a section: alphabetical by name (case-insensitive),
--- nil-safe `tostring(id)` tie-break. Persisted list rules always carry an id, so the
--- tie-break is deterministic (mirrors RLHerdsmanRuleService:saveToXMLFile's id sort).
---@param a table rule record
---@param b table rule record
---@return boolean
local function compareRulesByName(a, b)
    local an = string.lower(tostring(a.name or ""))
    local bn = string.lower(tostring(b.name or ""))
    if an ~= bn then return an < bn end
    return tostring(a.id) < tostring(b.id)
end

-- =============================================================================
-- List model
-- =============================================================================

--- Group a farm's rule list into ordered, per-operation sections for the
--- multi-section SmoothList. Sections appear in OPERATION_ORDER (Sell -> Buy ->
--- Castrate -> Naming -> AI); only operations with >= 1 rule produce a section;
--- within a section rules are alphabetical by name (case-insensitive) with a nil-safe
--- id tie-break. A rule whose operation is not one of the five is skipped + warned.
---@param rules table[]|nil array of rule records (farm-scoped by the caller)
---@return table[] sections array of `{ operation = string, rules = table[] }` in run order
function RLHerdsmanRulePresenter.buildSections(rules)
    local buckets = {}
    local count = 0
    if type(rules) == "table" then
        for _, rule in ipairs(rules) do
            local op = type(rule) == "table" and rule.operation or nil
            if op ~= nil and OPERATION_RANK[op] ~= nil then
                if buckets[op] == nil then buckets[op] = {} end
                table.insert(buckets[op], rule)
                count = count + 1
            else
                Log:warning("RLHerdsmanRulePresenter.buildSections: skipping rule with unknown operation '%s' (id=%s)",
                    tostring(op), tostring(type(rule) == "table" and rule.id or nil))
            end
        end
    end

    local sections = {}
    for _, op in ipairs(RLHerdsmanRulePresenter.OPERATION_ORDER) do
        local bucket = buckets[op]
        if bucket ~= nil and #bucket > 0 then
            table.sort(bucket, compareRulesByName)
            sections[#sections + 1] = { operation = op, rules = bucket }
        end
    end

    Log:trace("RLHerdsmanRulePresenter.buildSections: %d rule(s) -> %d section(s)", count, #sections)
    return sections
end

-- =============================================================================
-- Detail-pane param visibility
-- =============================================================================

--- Boolean visibility map for the detail-pane operation params. Every result carries
--- the full PARAM_KEYS set so callers can key-test without nil-checking. Unknown
--- operation -> all-false + warning.
---@param operation any rule operation key
---@return table map keyed by filter|maxAnimals|budget|mark|convention|previous|semen (all boolean)
function RLHerdsmanRulePresenter.getParamVisibility(operation)
    local visible = PARAM_VISIBILITY[operation]
    if visible == nil then
        Log:warning("RLHerdsmanRulePresenter.getParamVisibility: unknown operation '%s'; all params hidden", tostring(operation))
    end

    local out = {}
    for _, key in ipairs(PARAM_KEYS) do
        out[key] = visible ~= nil and visible[key] == true
    end

    Log:trace("RLHerdsmanRulePresenter.getParamVisibility: operation=%s filter=%s maxAnimals=%s budget=%s mark=%s convention=%s previous=%s semen=%s",
        tostring(operation), tostring(out.filter), tostring(out.maxAnimals), tostring(out.budget),
        tostring(out.mark), tostring(out.convention), tostring(out.previous), tostring(out.semen))
    return out
end

-- =============================================================================
-- Detail-pane param value domains, defaults + validation
-- =============================================================================

--- Fresh ordered copy of the naming-convention domain (random | alphabetical). A new
--- array per call so the frame's MultiTextOption state list can never mutate the
--- module constant.
---@return string[]
function RLHerdsmanRulePresenter.getConventionValues()
    local out = {}
    for i, value in ipairs(CONVENTION_VALUES) do out[i] = value end
    return out
end

--- Fresh ordered copy of the buy budget-type domain (fixed | percentage).
---@return string[]
function RLHerdsmanRulePresenter.getBudgetTypeValues()
    local out = {}
    for i, value in ipairs(BUDGET_TYPE_VALUES) do out[i] = value end
    return out
end

--- Fresh ordered copy of the buy budget-percentage whitelist (28 values).
---@return number[]
function RLHerdsmanRulePresenter.getBudgetPercentageValues()
    local out = {}
    for i, value in ipairs(BUDGET_PERCENTAGE_VALUES) do out[i] = value end
    return out
end

--- Which budget sub-field the buy detail pane shows for a given budget type: a fixed
--- amount XOR a herd-value percentage. Exactly one true for a known type; both false
--- for an unknown / nil type (fail-closed, so the frame hides both rather than
--- guessing).
---@param budgetType any "fixed" | "percentage" | other
---@return table { fixed = boolean, percentage = boolean }
function RLHerdsmanRulePresenter.getBudgetFieldVisibility(budgetType)
    local out = { fixed = budgetType == "fixed", percentage = budgetType == "percentage" }
    Log:trace("RLHerdsmanRulePresenter.getBudgetFieldVisibility: budgetType=%s -> fixed=%s percentage=%s",
        tostring(budgetType), tostring(out.fixed), tostring(out.percentage))
    return out
end

--- Fresh per-operation default params, used by the frame to (re)seed `params` when the
--- operation changes. Carries exactly the serializer's required keys with legacy-grounded
--- values; every default passes validateParams AND the serializer codec validate.
--- Naming carries NO `previous` key - that is the tick's internal alphabetical cursor,
--- not a setting (absent until the tick sets it). Every call builds a brand-new table
--- (including buy's nested `budget`) so callers can mutate the result freely. Unknown
--- operation -> empty table + warning.
---@param operation any rule operation key
---@return table params fresh default params table (empty for an unknown operation)
function RLHerdsmanRulePresenter.defaultParamsForOperation(operation)
    local params
    if operation == "sell" then
        params = { maxAnimals = 5, mark = false }
    elseif operation == "buy" then
        params = { maxAnimals = 5, budget = { type = "fixed", fixed = 5000, percentage = 1 } }
    elseif operation == "castrate" then
        params = { mark = false }
    elseif operation == "naming" then
        params = { convention = "random" }
    elseif operation == "ai" then
        params = { maxAnimals = 5, mark = false, semen = RLHerdsmanRulePresenter.SEMEN_ANY }
    else
        Log:warning("RLHerdsmanRulePresenter.defaultParamsForOperation: unknown operation '%s'; returning empty params", tostring(operation))
        return {}
    end

    Log:trace("RLHerdsmanRulePresenter.defaultParamsForOperation: operation=%s -> fresh defaults", tostring(operation))
    return params
end

--- Per-field value-domain checks. Each takes the raw param value and returns true only
--- when it is present AND in-domain (so an absent value is always false).

--- maxAnimals: an integer within [MAXANIMALS_MIN, MAXANIMALS_MAX].
---@param value any
---@return boolean
local function isValidMaxAnimals(value)
    return type(value) == "number" and value == math.floor(value)
        and value >= RLHerdsmanRulePresenter.MAXANIMALS_MIN
        and value <= RLHerdsmanRulePresenter.MAXANIMALS_MAX
end

--- mark: a boolean.
---@param value any
---@return boolean
local function isValidMark(value)
    return type(value) == "boolean"
end

--- convention: a member of the convention domain.
---@param value any
---@return boolean
local function isValidConvention(value)
    return type(value) == "string" and CONVENTION_SET[value] == true
end

--- budget.type: a member of the budget-type domain.
---@param value any
---@return boolean
local function isValidBudgetType(value)
    return type(value) == "string" and BUDGET_TYPE_SET[value] == true
end

--- budget.fixed: a non-negative integer (serializer setInt).
---@param value any
---@return boolean
local function isValidBudgetFixed(value)
    return type(value) == "number" and value == math.floor(value) and value >= 0
end

--- budget.percentage: a member of the 28-value whitelist.
---@param value any
---@return boolean
local function isValidBudgetPercentage(value)
    return type(value) == "number" and BUDGET_PERCENTAGE_SET[value] == true
end

--- semen: a non-empty string ("any" sentinel or a real dewar uniqueId).
---@param value any
---@return boolean
local function isValidSemen(value)
    return type(value) == "string" and value ~= ""
end

--- Per-operation USED-param descriptors: the ordered list of fields validateParams
--- reports on, each with how to read it from `params` and its domain check. The key
--- set per operation matches the serializer's required-field set exactly (the
--- codec-parity test asserts no drift); buy's nested budget sub-fields flatten to the
--- budgetType / budgetFixed / budgetPercentage result keys.
local PARAM_VALIDATORS = {
    sell = {
        { field = "maxAnimals", get = function(p) return p.maxAnimals end, check = isValidMaxAnimals },
        { field = "mark",       get = function(p) return p.mark end,       check = isValidMark },
    },
    buy = {
        { field = "maxAnimals",       get = function(p) return p.maxAnimals end,                     check = isValidMaxAnimals },
        { field = "budgetType",       get = function(p) return p.budget and p.budget.type end,       check = isValidBudgetType },
        { field = "budgetFixed",      get = function(p) return p.budget and p.budget.fixed end,      check = isValidBudgetFixed },
        { field = "budgetPercentage", get = function(p) return p.budget and p.budget.percentage end, check = isValidBudgetPercentage },
    },
    castrate = {
        { field = "mark", get = function(p) return p.mark end, check = isValidMark },
    },
    naming = {
        { field = "convention", get = function(p) return p.convention end, check = isValidConvention },
    },
    ai = {
        { field = "maxAnimals", get = function(p) return p.maxAnimals end, check = isValidMaxAnimals },
        { field = "mark",       get = function(p) return p.mark end,       check = isValidMark },
        { field = "semen",      get = function(p) return p.semen end,      check = isValidSemen },
    },
}

--- Process-lifetime flag: warn exactly once if validateParams is called with an unknown
--- operation. validateEdit calls this on every live draft validation, so a transient
--- invalid op in the editor must not spam the log (the spec's one-shot contract).
local _warnedValidateParamsUnknownOp = false

--- Validate an operation's params against their value domains, returning a per-field
--- boolean map plus an overall `ok`. `fields` carries one boolean per param the
--- operation USES (e.g. sell -> maxAnimals, mark; buy -> maxAnimals, budgetType,
--- budgetFixed, budgetPercentage); each is (present AND in-domain). `ok` is true only
--- when every used field is true, which guarantees the rule is serializer/wire-writable.
--- `previous` is never a field (it is the tick's cursor, not validated input). A nil /
--- non-table `params` is treated as empty (every field false). Unknown operation ->
--- `{ ok = false, fields = {} }` + a one-shot `:warning` (fail-closed return, like the
--- sister helpers; warned once per process so the live-validation caller cannot spam).
---@param operation any rule operation key
---@param params table|nil operation params table
---@return table { ok = boolean, fields = table<string, boolean> }
function RLHerdsmanRulePresenter.validateParams(operation, params)
    local validators = isKnownOperation(operation) and PARAM_VALIDATORS[operation] or nil
    if validators == nil then
        if not _warnedValidateParamsUnknownOp then
            Log:warning("RLHerdsmanRulePresenter.validateParams: unknown operation '%s'; not ok (empty field map)", tostring(operation))
            _warnedValidateParamsUnknownOp = true
        end
        return { ok = false, fields = {} }
    end

    local p = type(params) == "table" and params or {}
    local fields = {}
    local parts = {}
    local ok = true
    for _, validator in ipairs(validators) do
        local fieldOk = validator.check(validator.get(p)) == true
        fields[validator.field] = fieldOk
        parts[#parts + 1] = string.format("%s=%s", validator.field, tostring(fieldOk))
        if not fieldOk then ok = false end
    end

    Log:trace("RLHerdsmanRulePresenter.validateParams: operation=%s %s -> ok=%s",
        tostring(operation), table.concat(parts, " "), tostring(ok))
    return { ok = ok, fields = fields }
end

--- Process-lifetime flag: warn exactly once if RLConstants.AREA_CODES is unreachable
--- (a load-order regression), so the area-code lookup degrading to "?" is visible in
--- logs without spamming every option formatted.
local _warnedAreaCodesMissing = false

--- Format ONE real dewar's AI semen option label for the detail-pane picker, in the
--- legacy shape `"<areaCode> <farmId> <uniqueId> (<straws> <strawLabel>)"`. The area
--- code comes from RLConstants.AREA_CODES[country].code; the straw word is the injected
--- `labels.strawSingular` (straws == 1) or `labels.strawPlural` (the frame wires those
--- to the straw i18n strings). Real dewars only - it does NOT handle the "any" sentinel
--- (the frame prepends that as its own option). Unknown / nil country -> a "?" area-code
--- segment + a trace (deterministic, never crashes).
---@param country any animal country index into RLConstants.AREA_CODES
---@param farmId any owning farm id (rendered verbatim)
---@param uniqueId any dewar animal uniqueId (rendered verbatim)
---@param straws any straw count (drives singular/plural and rendered verbatim)
---@param labels table { strawSingular = string, strawPlural = string }
---@return string option
function RLHerdsmanRulePresenter.formatSemenOption(country, farmId, uniqueId, straws, labels)
    local areaCodes = RLConstants ~= nil and RLConstants.AREA_CODES or nil
    if areaCodes == nil and not _warnedAreaCodesMissing then
        Log:warning("RLHerdsmanRulePresenter.formatSemenOption: RLConstants.AREA_CODES unavailable; area codes will read '?' (check main.lua constants load order)")
        _warnedAreaCodesMissing = true
    end

    local entry = areaCodes ~= nil and areaCodes[country] or nil
    local code
    if entry ~= nil and type(entry.code) == "string" then
        code = entry.code
    else
        code = "?"
        Log:trace("RLHerdsmanRulePresenter.formatSemenOption: unknown country '%s' -> '?' area code", tostring(country))
    end

    local strawLabel = (straws == 1) and labels.strawSingular or labels.strawPlural
    local option = string.format("%s %s %s (%s %s)",
        code, tostring(farmId), tostring(uniqueId), tostring(straws), tostring(strawLabel))

    Log:trace("RLHerdsmanRulePresenter.formatSemenOption: country=%s farmId=%s uniqueId=%s straws=%s -> '%s'",
        tostring(country), tostring(farmId), tostring(uniqueId), tostring(straws), option)
    return option
end

-- =============================================================================
-- Filter-usage scoping
-- =============================================================================

--- Allowed filter-usage membership map for an operation (D7). Returns a fresh copy
--- (callers must not mutate the module table). Keys are RLFilterUsage constants;
--- callers key-test with `result[usage]`. Unknown operation -> empty map + warning.
---@param operation any rule operation key
---@return table membership map, e.g. { [RLFilterUsage.ANY] = true, [RLFilterUsage.DEALER] = true }
function RLHerdsmanRulePresenter.getAllowedFilterUsages(operation)
    local allowed = ALLOWED_USAGES[operation]
    if allowed == nil then
        Log:warning("RLHerdsmanRulePresenter.getAllowedFilterUsages: unknown operation '%s'; empty usage set", tostring(operation))
        return {}
    end

    local out = {}
    for usage, ok in pairs(allowed) do
        out[usage] = ok
    end

    Log:trace("RLHerdsmanRulePresenter.getAllowedFilterUsages: operation=%s any=%s owned=%s dealer=%s",
        tostring(operation), tostring(out[RLFilterUsage.ANY] == true),
        tostring(out[RLFilterUsage.OWNED] == true), tostring(out[RLFilterUsage.DEALER] == true))
    return out
end

--- True when `usage` is allowed for `operation` (D5: lets F4 clear a filter on
--- op-change when its usage no longer fits). Equivalent to membership in
--- getAllowedFilterUsages(operation). Unknown operation -> false + warning; nil
--- usage -> false.
---@param operation any rule operation key
---@param usage any RLFilterUsage value to test
---@return boolean
function RLHerdsmanRulePresenter.isFilterUsageAllowed(operation, usage)
    if usage == nil then
        Log:trace("RLHerdsmanRulePresenter.isFilterUsageAllowed: nil usage -> false (operation=%s)", tostring(operation))
        return false
    end

    local allowed = ALLOWED_USAGES[operation]
    if allowed == nil then
        Log:warning("RLHerdsmanRulePresenter.isFilterUsageAllowed: unknown operation '%s'; usage '%s' -> false",
            tostring(operation), tostring(usage))
        return false
    end

    local ok = allowed[usage] == true
    Log:trace("RLHerdsmanRulePresenter.isFilterUsageAllowed: operation=%s usage=%s -> %s",
        tostring(operation), tostring(usage), tostring(ok))
    return ok
end

--- The single usage to scope the filter PICKER by for an operation (D7). Derived from
--- ALLOWED_USAGES so it cannot drift from getAllowedFilterUsages: each non-naming entry is
--- exactly { ANY, X }, and this returns that one non-ANY member (buy -> DEALER; sell /
--- castrate / ai -> OWNED). The picker passes it as the `usage` scope to
--- RLFilterService:listAvailable, where ANY/nil filters fold in automatically - so a single
--- non-nil usage yields exactly the operation's { ANY, X } pool. Naming has no Filter row
--- (the picker never opens) -> nil; unknown operation -> nil + warning. nil here means "do
--- NOT open" to the caller (a nil usage would be a list-everything WILDCARD in listAvailable).
---@param operation any rule operation key
---@return string|nil RLFilterUsage value to scope by, or nil when no picker applies
function RLHerdsmanRulePresenter.getFilterPickerUsage(operation)
    if operation == "naming" then
        Log:trace("RLHerdsmanRulePresenter.getFilterPickerUsage: naming has no filter row -> nil")
        return nil
    end

    local allowed = ALLOWED_USAGES[operation]
    if allowed == nil then
        Log:warning("RLHerdsmanRulePresenter.getFilterPickerUsage: unknown operation '%s'; nil scope", tostring(operation))
        return nil
    end

    local scope = nil
    for usage, ok in pairs(allowed) do
        if ok and usage ~= RLFilterUsage.ANY then
            if scope ~= nil then
                -- ALLOWED_USAGES entries are exactly { ANY, X }; a 2nd non-ANY member means the
                -- table drifted and the picker scope would be a pairs-order coin-flip. Fail loud.
                Log:warning("RLHerdsmanRulePresenter.getFilterPickerUsage: operation '%s' has >1 non-ANY usage (%s, %s); scope is ambiguous - expected exactly { ANY, X }",
                    tostring(operation), tostring(scope), tostring(usage))
            end
            scope = usage
        end
    end

    Log:trace("RLHerdsmanRulePresenter.getFilterPickerUsage: operation=%s -> %s", tostring(operation), tostring(scope))
    return scope
end

--- Alphabetical-by-name ordering of a filter list for the picker (case-insensitive, nil-safe
--- id tie-break). Returns a SORTED COPY; the input array is never mutated (the caller owns the
--- service-cloned list). Reuses the same compareRulesByName comparator the rule list sorts by,
--- so filters and rules order identically and the rule cannot drift.
---@param filters table[]|nil array of filter records (each with `name` + `id`)
---@return table[] sorted shallow copy (empty table for nil / non-table input)
function RLHerdsmanRulePresenter.sortFiltersByName(filters)
    local out = {}
    if type(filters) == "table" then
        for i, f in ipairs(filters) do out[i] = f end
    end
    table.sort(out, compareRulesByName)
    Log:trace("RLHerdsmanRulePresenter.sortFiltersByName: %d filter(s) sorted", #out)
    return out
end

-- =============================================================================
-- Read-only summaries
-- =============================================================================

--- Human-readable husbandry summary for the detail pane. Resolves each target
--- uniqueId to a placeable name via the injected `resolveName(uid) -> string|nil`,
--- joining resolved names with ", " in list order. An entry the resolver cannot
--- resolve (nil / non-string / empty) reads `labels.missing`; an empty / nil target
--- list reads `labels.none`; a nil resolver makes every entry `labels.missing`.
---@param targetHusbandries table|nil array of placeable uniqueId strings
---@param resolveName function|nil function(uid) -> name string|nil (frame wires the placeableSystem lookup)
---@param labels table { missing = string, none = string }
---@return string summary
function RLHerdsmanRulePresenter.getHusbandrySummary(targetHusbandries, resolveName, labels)
    if type(targetHusbandries) ~= "table" or #targetHusbandries == 0 then
        Log:trace("RLHerdsmanRulePresenter.getHusbandrySummary: empty/nil targets -> none")
        return labels.none
    end

    local names = {}
    local missing = 0
    for i, uid in ipairs(targetHusbandries) do
        local resolved = nil
        if resolveName ~= nil then resolved = resolveName(uid) end
        if type(resolved) == "string" and resolved ~= "" then
            names[i] = resolved
        else
            names[i] = labels.missing
            missing = missing + 1
        end
    end

    Log:trace("RLHerdsmanRulePresenter.getHusbandrySummary: %d target(s), %d unresolved", #targetHusbandries, missing)
    return table.concat(names, ", ")
end

--- Human-readable filter summary for the detail pane. Resolves `filterId` via the
--- injected `resolveFilter(filterId) -> filter|nil` and returns the resolved filter's
--- name. `filterId == nil` -> `labels.none` (naming rules / unset); a non-nil id the
--- resolver cannot resolve (deleted filter) -> `labels.missing` (D16 orphan state); a
--- nil resolver with a non-nil id -> `labels.missing`.
---@param filterId any saved-filter id (string) or nil
---@param resolveFilter function|nil function(filterId) -> filter table|nil (frame wires RLFilterService:getById)
---@param labels table { missing = string, none = string }
---@return string summary
function RLHerdsmanRulePresenter.getFilterSummary(filterId, resolveFilter, labels)
    if filterId == nil then
        Log:trace("RLHerdsmanRulePresenter.getFilterSummary: nil filterId -> none")
        return labels.none
    end

    local filter = nil
    if resolveFilter ~= nil then filter = resolveFilter(filterId) end
    if type(filter) ~= "table" or type(filter.name) ~= "string" or filter.name == "" then
        Log:trace("RLHerdsmanRulePresenter.getFilterSummary: filterId=%s unresolved -> missing", tostring(filterId))
        return labels.missing
    end

    Log:trace("RLHerdsmanRulePresenter.getFilterSummary: filterId=%s -> '%s'", tostring(filterId), filter.name)
    return filter.name
end

-- =============================================================================
-- Legacy-active banner (D13)
-- =============================================================================

--- Coexistence banner predicate (D13). Read-only over the legacy per-husbandry AI
--- settings: a husbandry is "legacy active" when ANY of its five operations is
--- `enabled == true`. Returns `(active, affectedNames)` where affectedNames lists, in
--- input order, the names of husbandries with >= 1 enabled operation. nil / non-table
--- entries -> `(false, {})`; a missing `settings` table or operation entry -> treated
--- as not-enabled. Read-only: never reorders or "fixes" legacy execution.
---@param entries table|nil array of `{ name = string, settings = { buy = { enabled }, sell = ..., castrate = ..., naming = ..., ai = ... } }`
---@return boolean active true when any husbandry has any enabled legacy operation
---@return table affectedNames string[] of names with >= 1 enabled operation (input order)
function RLHerdsmanRulePresenter.isLegacyActive(entries)
    local active = false
    local affectedNames = {}
    if type(entries) ~= "table" then
        Log:trace("RLHerdsmanRulePresenter.isLegacyActive: nil/non-table entries -> false")
        return false, affectedNames
    end

    for _, entry in ipairs(entries) do
        local settings = type(entry) == "table" and entry.settings or nil
        local entryActive = false
        if type(settings) == "table" then
            for _, op in ipairs(RLHerdsmanRulePresenter.OPERATION_ORDER) do
                local opSettings = settings[op]
                if type(opSettings) == "table" and opSettings.enabled == true then
                    entryActive = true
                    break
                end
            end
        end
        if entryActive then
            active = true
            affectedNames[#affectedNames + 1] = entry.name
        end
    end

    Log:trace("RLHerdsmanRulePresenter.isLegacyActive: active=%s affected=%d", tostring(active), #affectedNames)
    return active, affectedNames
end

-- =============================================================================
-- Edit validation (pre-submit; stricter than the service floor on targets)
-- =============================================================================

--- Validate an in-progress rule draft for the detail pane (pre-submit). Returns a
--- per-field boolean breakdown plus an overall `valid`. Deliberately STRICTER than
--- RLHerdsmanRuleService's validity floor on targets: the service accepts an empty
--- target list (inert rule), but the editor requires >= 1 so a saved rule actually
--- does something. Re-asserts the naming-filterId-nil and operation-enum rules so the
--- UI never green-lights a draft the service rejects on save. The animalType
--- target-gate + castrate chicken-exclusion stay out of scope (-> RLRM-388/F6):
---   * nameOk        - `name` is a non-blank string (not all-whitespace)
---   * operationOk   - `operation` is in the canonical RLHerdsmanRuleService.OPERATIONS set
---   * filterOk      - naming: `filterId == nil`; non-naming: non-blank string `filterId`
---   * husbandriesOk - `#targetHusbandries >= 1`
---   * paramsOk      - `validateParams(operation, params).ok` (per-op param value domains)
---   * valid         - all five
--- nil / non-table draft -> all-false.
---@param draft table|nil { name, operation, filterId, targetHusbandries, params }
---@return table { valid, nameOk, operationOk, filterOk, husbandriesOk, paramsOk } (all boolean)
function RLHerdsmanRulePresenter.validateEdit(draft)
    if type(draft) ~= "table" then
        Log:trace("RLHerdsmanRulePresenter.validateEdit: nil/non-table draft -> all false")
        return { valid = false, nameOk = false, operationOk = false, filterOk = false, husbandriesOk = false, paramsOk = false }
    end

    local nameOk = type(draft.name) == "string" and draft.name:gsub("%s", "") ~= ""
    local operationOk = isKnownOperation(draft.operation)

    local filterOk
    if draft.operation == "naming" then
        filterOk = draft.filterId == nil
    else
        filterOk = type(draft.filterId) == "string" and draft.filterId:gsub("%s", "") ~= ""
    end

    local husbandriesOk = type(draft.targetHusbandries) == "table" and #draft.targetHusbandries >= 1

    local paramsOk = RLHerdsmanRulePresenter.validateParams(draft.operation, draft.params).ok

    local valid = nameOk and operationOk and filterOk and husbandriesOk and paramsOk

    Log:trace("RLHerdsmanRulePresenter.validateEdit: nameOk=%s operationOk=%s filterOk=%s husbandriesOk=%s paramsOk=%s -> valid=%s",
        tostring(nameOk), tostring(operationOk), tostring(filterOk), tostring(husbandriesOk), tostring(paramsOk), tostring(valid))
    return { valid = valid, nameOk = nameOk, operationOk = operationOk, filterOk = filterOk, husbandriesOk = husbandriesOk, paramsOk = paramsOk }
end

Log:debug("RLHerdsmanRulePresenter: loaded (%d operations)", #RLHerdsmanRulePresenter.OPERATION_ORDER)
