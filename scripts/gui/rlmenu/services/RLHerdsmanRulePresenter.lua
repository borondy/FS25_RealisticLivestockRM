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
--- UI never green-lights a draft the service rejects on save. Covers only the four
--- cross-cutting checks (per-op param completeness -> RLRM-385/F4; the animalType
--- target-gate + castrate chicken-exclusion -> RLRM-388/F6):
---   * nameOk        - `name` is a non-blank string (not all-whitespace)
---   * operationOk   - `operation` is in the canonical RLHerdsmanRuleService.OPERATIONS set
---   * filterOk      - naming: `filterId == nil`; non-naming: non-blank string `filterId`
---   * husbandriesOk - `#targetHusbandries >= 1`
---   * valid         - all four
--- nil / non-table draft -> all-false.
---@param draft table|nil { name, operation, filterId, targetHusbandries }
---@return table { valid, nameOk, operationOk, filterOk, husbandriesOk } (all boolean)
function RLHerdsmanRulePresenter.validateEdit(draft)
    if type(draft) ~= "table" then
        Log:trace("RLHerdsmanRulePresenter.validateEdit: nil/non-table draft -> all false")
        return { valid = false, nameOk = false, operationOk = false, filterOk = false, husbandriesOk = false }
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

    local valid = nameOk and operationOk and filterOk and husbandriesOk

    Log:trace("RLHerdsmanRulePresenter.validateEdit: nameOk=%s operationOk=%s filterOk=%s husbandriesOk=%s -> valid=%s",
        tostring(nameOk), tostring(operationOk), tostring(filterOk), tostring(husbandriesOk), tostring(valid))
    return { valid = valid, nameOk = nameOk, operationOk = operationOk, filterOk = filterOk, husbandriesOk = husbandriesOk }
end

Log:debug("RLHerdsmanRulePresenter: loaded (%d operations)", #RLHerdsmanRulePresenter.OPERATION_ORDER)
