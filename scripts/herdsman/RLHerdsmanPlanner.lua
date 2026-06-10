-- RLHerdsmanPlanner.lua
-- Pure herdsman day-tick planner (M-Tick T1 RLRM-389 + T2a Sell/Buy RLRM-390) - the
-- keystone of M-Tick.
--
-- `planActions(rules, ctx)` decides WHICH animals each enabled rule acts on, in run
-- order, threading cross-rule claims + a farm-scoped money ledger, and returns ordered
-- intended-action records. The surprising part - sequential state threading across rules
-- - is isolated here in one 100% headless module: data in, data out. `planActions` reads
-- no `g_*` and MUST NOT mutate `rules`, `ctx`, or any animal table (internal bookkeeping
-- copies only). The ONLY engine calls are the REAL price primitives reached through the
-- injected `ctx.animalSystem` + the passed-in Animal (`animal:getSellPrice()`,
-- `ctx.animalSystem:getAnimalTransportFee(...)`) - dependency injection, not a `g_*` read.
-- Castrate + Naming + AI per-op params are T2b; event dispatch is T3; the day-tick hook is T4.
--
-- ctx contract (T4 builds it in-game; tests fabricate it from real Animals):
--   ctx = {
--     husbandries         = { [uniqueId] = { animalTypeIndex = n, animals = { Animal, ... } } },
--     dealerAnimalsByType = { [animalTypeIndex] = { Animal, ... } },
--     filtersById         = { [filterId] = filterRecord },
--     animalSystem        = <real AnimalSystem>,           -- getAnimalTransportFee (DI; T2a)
--     farmBalanceByFarmId = { [farmId] = balance },        -- ledger seed, farm-scoped (T2a)
--   }
-- The caller (T4) farm-scopes BOTH `rules` and `ctx.husbandries`, and excludes legacy
-- `reserved` dealer animals from `dealerAnimalsByType` (coexistence: legacy AIAnimalManager
-- claims dealer animals via `animal.reserved`). The planner filters `enabled` itself.
--
-- Action records, emitted in run order (operation rank, then within an op
-- `compareRulesByName`; within a rule, targets in lexicographic uniqueId order):
--   sell { ruleId, operation="sell", husbandryId, animals=<price desc>, mark, wage, amountGained? }
--        (`amountGained` present iff `mark==false`; a marked sell is advisory - no money/event)
--   buy  { ruleId, operation="buy",  husbandryId, animals=<price asc>,  amountSpent, wage }
--   castrate/naming/ai { ruleId, operation, husbandryId, animals } (T1 shape; per-op params T2b)
--
-- Run order = operation order (RLHerdsmanRuleService.OPERATION_ORDER: sell -> buy ->
-- castrate -> naming -> ai) then RLHerdsmanRuleService.compareRulesByName within an op
-- (mirrors legacy AIAnimalManager:onDayChanged - sell frees herd space + funds buys before
-- buy fills the space / spends the proceeds).
--
-- Candidate match is RLFilterEvaluator.evaluate (pure, fails closed: a nil / deleted
-- filter selects nothing, never raises - D16). Naming carries no filter and selects ALL
-- remaining animals in its targets (T1 intake 3a; T2b narrows to unnamed-only).

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanPlanner = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every planner log line (the per-(rule, husbandry) DEBUG summary
--- lines are the verification surface; the evaluator already emits per-animal DEBUG lines).
local LOG_PREFIX = "[planActions]"

--- Buy applies a 7.5% dealer markup on the sell price before adding transport (the buy leg
--- of legacy AIAnimalManager:onDayChanged); sell uses the raw price (1.0, the sell leg).
local SELL_MARKUP = 1.0
local BUY_MARKUP = 1.075

--- Per-operation claim traits - the explicit table that drives how each operation threads
--- state across the sequential rule passes (the two-level claim model, intake 1a):
---   * `removesFromHerd` (sell) - an END-TASK op: a selected animal leaves the owned pool,
---     so it is absent from EVERY later rule's candidates (global claim).
---   * `sourcesFromDealer` + `addsToHerd` (buy) - candidates come from the dealer pool, NOT
---     the owned herd; a bought animal joins the destination husbandry's owned pool so later
---     cross-op rules (castrate / naming / ai) see it.
---   * `noFilter` (naming) - no filter is evaluated; naming selects ALL remaining animals in
---     its targets (T1).
--- Every operation ALSO claims same-operation (two rules of one op never pick the same
--- animal); that is enforced uniformly by the per-op claimed set, independent of these traits.
--- An operation with an empty traits table (castrate / ai) is a plain owned-herd, non-end-task,
--- filtered op.
RLHerdsmanPlanner.OPERATION_TRAITS = {
    sell     = { removesFromHerd = true },
    buy      = { sourcesFromDealer = true, addsToHerd = true },
    castrate = {},
    naming   = { noFilter = true },
    ai       = {},
}

--- Herdsman daily wage per animal, by animalTypeIndex (reproduced EXACTLY from legacy
--- `AIAnimalManager.ANIMAL_TYPE_TO_WAGE`; M-Tick open item 3 resolved -> reproduce). Keyed
--- by the runtime AnimalType.* index so it matches `husbandry.animalTypeIndex`. A type
--- absent from this table falls back to DEFAULT_WAGE (legacy `... or 5`).
local DEFAULT_WAGE = 5
local WAGE_BY_NAME = { COW = 20, SHEEP = 12.5, PIG = 10, HORSE = 25, CHICKEN = 2 }

--- The daily wage rate for an animalType (legacy `ANIMAL_TYPE_TO_WAGE[idx] or 5`). The
--- index->wage table is built at RUNTIME (first call), NOT at module load: in-game `AnimalType`
--- is not yet populated when this module is sourced (SECTION 11i), so a load-time build keys
--- off nil and every wage collapses to DEFAULT_WAGE. Legacy builds it inside
--- `AIAnimalManager.new()` (runtime) for the same reason. We memoize, but only cache once
--- `AnimalType` is actually populated, so a too-early call retries instead of poisoning the cache.
---@param animalTypeIndex any
---@return number wage rate
local wageByTypeIndex = nil
local function wageFor(animalTypeIndex)
    if wageByTypeIndex == nil and type(AnimalType) == "table" then
        local t = {}
        for name, w in pairs(WAGE_BY_NAME) do
            local idx = AnimalType[name]
            if idx ~= nil then t[idx] = w end
        end
        if next(t) ~= nil then wageByTypeIndex = t end
    end
    return (wageByTypeIndex and wageByTypeIndex[animalTypeIndex]) or DEFAULT_WAGE
end

--- operation -> run-order rank, derived from the service's OPERATION_ORDER (the single
--- source of truth; the service loads first in main.lua SECTION 11h, before this module's
--- SECTION 11i). Used to skip unknown-operation rules before sorting and to rank the run.
local OPERATION_RANK = {}
for rank, op in ipairs(RLHerdsmanRuleService.OPERATION_ORDER) do
    OPERATION_RANK[op] = rank
end

-- =============================================================================
-- Internal helpers (pure)
-- =============================================================================

--- Build the claim-set / dedup key for an animal from its identity triple
--- (`RLAnimalUtil.toKey`, mirroring `RLAnimalUtil.compare`: farmId + uniqueId +
--- birthday.country). Returns nil when ANY identity field is nil - `toKey`'s string
--- concat would otherwise raise - so the caller skips the animal + WARNs instead of
--- crashing. The three-field key keeps two animals that share a uniqueId across farms /
--- countries distinct, and is the deterministic tie-break for equal-price sorts.
---@param animal table|nil
---@return string|nil key, or nil when an identity field is missing
local function animalKey(animal)
    if type(animal) ~= "table" then return nil end
    local farmId, uniqueId = animal.farmId, animal.uniqueId
    -- Gate the birthday read on table type: a malformed scalar `birthday` must yield a
    -- nil key (skip + WARN), never an index-a-scalar raise.
    local country = type(animal.birthday) == "table" and animal.birthday.country or nil
    if farmId == nil or uniqueId == nil or country == nil then
        return nil
    end
    return RLAnimalUtil.toKey(farmId, uniqueId, country)
end

--- Dedupe a rule's target uniqueIds and return them in lexicographic order, plus the
--- number of duplicates dropped. The service stores `targetHusbandries` order-insensitively
--- (multiset equality), so list order carries no semantics; a deterministic lexicographic
--- order makes the plan reproducible (and pins "first target takes all" for multi-target buy).
--- nil entries are dropped.
---@param targetHusbandries table|nil array of placeable uniqueId strings
---@return string[] ordered deduped uniqueIds
---@return number dupes count of duplicate entries dropped
local function dedupeSortedTargets(targetHusbandries)
    local seen, out, dupes = {}, {}, 0
    if type(targetHusbandries) == "table" then
        for _, uid in ipairs(targetHusbandries) do
            if uid ~= nil then
                if seen[uid] then
                    dupes = dupes + 1
                else
                    seen[uid] = true
                    out[#out + 1] = uid
                end
            end
        end
    end
    table.sort(out, function(x, y) return tostring(x) < tostring(y) end)
    return out, dupes
end

--- Coerce a rule's `maxAnimals` param to a positive integer count, or nil when the rule
--- must not run. Distinguishes (legacy gate `(maxAnimals or 0) > 0`, plus the fail-closed
--- contract): nil -> no-op (DEBUG, never configured); non-number -> fail closed (WARN,
--- corrupt data); a number -> floored to an integer count, then `<= 0` -> no-op (DEBUG).
---@param rule table
---@param params table
---@return number|nil maxN positive integer, or nil (caller emits no action)
local function normalizeMaxAnimals(rule, params)
    local m = params.maxAnimals
    if m == nil then
        Log:debug("%s rule=%s op=%s no-op: maxAnimals nil (never runs)", LOG_PREFIX, tostring(rule.id), tostring(rule.operation))
        return nil
    end
    if type(m) ~= "number" then
        Log:warning("%s rule=%s op=%s skipped: non-number maxAnimals (%s) - fail closed",
            LOG_PREFIX, tostring(rule.id), tostring(rule.operation), tostring(m))
        return nil
    end
    m = math.floor(m)
    if m <= 0 then
        Log:debug("%s rule=%s op=%s no-op: maxAnimals <= 0 (%d)", LOG_PREFIX, tostring(rule.id), tostring(rule.operation), m)
        return nil
    end
    return m
end

--- Validate a Buy rule's `budget` param, failing closed on corrupt data (never coerce-and-
--- execute). Returns (type, fixed, percentage, bad): `bad == true` means the caller skips
--- the rule (a WARNING is already logged). For type "fixed" only `fixed` must be a number;
--- for "percentage" only `percentage` must be (mirrors legacy's actual data dependency).
---@param rule table
---@param params table
---@return string|nil budgetType
---@return number|nil budgetFixed
---@return number|nil budgetPercentage
---@return boolean bad true -> skip the rule
local function validateBuyBudget(rule, params)
    local b = params.budget
    if type(b) ~= "table" then
        Log:warning("%s rule=%s op=buy skipped: missing/invalid budget table - fail closed", LOG_PREFIX, tostring(rule.id))
        return nil, nil, nil, true
    end
    local t = b.type
    if t ~= "fixed" and t ~= "percentage" then
        Log:warning("%s rule=%s op=buy skipped: unknown budget.type '%s' (not fixed/percentage) - fail closed",
            LOG_PREFIX, tostring(rule.id), tostring(t))
        return nil, nil, nil, true
    end
    if t == "fixed" and type(b.fixed) ~= "number" then
        Log:warning("%s rule=%s op=buy skipped: non-number budget.fixed (%s) - fail closed", LOG_PREFIX, tostring(rule.id), tostring(b.fixed))
        return nil, nil, nil, true
    end
    if t == "percentage" and type(b.percentage) ~= "number" then
        Log:warning("%s rule=%s op=buy skipped: non-number budget.percentage (%s) - fail closed", LOG_PREFIX, tostring(rule.id), tostring(b.percentage))
        return nil, nil, nil, true
    end
    return t, b.fixed, b.percentage, false
end

-- =============================================================================
-- Public entry point
-- =============================================================================

--- Plan the herdsman day-tick: which animals each enabled rule acts on, in run order,
--- with the locked two-level claim model + the farm-scoped money ledger threaded across
--- sequential rule passes. Pure: `rules`, `ctx`, and every animal table are left unmutated
--- (internal pool / claim / ledger copies only).
---
--- Algorithm:
---   1. Filter to runnable rules: `enabled == true`; operation in OPERATION_ORDER (else
---      skip + WARN); non-naming with `filterId == nil` is an incomplete draft -> skip +
---      DEBUG (RLRM-404). Disabled rules skip + DEBUG.
---   2. Sort runnable rules by operation rank, then `compareRulesByName`.
---   3. Per rule, dedupe + lexicographically order its targets, then per target select
---      candidates from the internal REMAINING pools (one `evalCtx` per call), apply the
---      per-operation pricing / cap / wage / claim, and emit an action when >= 1 selected.
---
--- Per-operation selection (T2a Sell/Buy; T1 shape for castrate/naming/ai):
---   * Sell: shortlist = filter-match AND `getCanBeSold()`; price = real getSellPrice +
---     transport; sort price DESC (toKey tie-break); take top `maxAnimals`; wage per the
---     legacy formula; CLAIM the selected set globally (mark OR exec) - remove from the
---     owned pool; an executed (mark==false) sell credits its proceeds to the farm ledger.
---   * Buy: budget resolved against the running ledger (fail closed on bad params / nil
---     balance; `<= 0` -> no-op); shortlist = filter-match AND affordable (price <= budget,
---     buy markup); sort price ASC; consume cheapest until the next price exceeds the
---     remaining budget (strict `>`) or `maxAnimals`; claim from the dealer pool, append to
---     the destination owned pool, and DEBIT the farm ledger.
---   * Castrate / naming / ai: T1 behavior preserved - select ALL filter-matched (naming:
---     all remaining), claim same-op, no cap / sort / wage (T2b).
---
--- Claim mechanics (the two-level model): owned ops draw from a per-husbandry owned pool
--- (shallow copy of `ctx.husbandries[uid].animals`); sell removes its CAPPED selected set
--- (capped-out matches stay candidates for a later same-op rule); castrate/naming/ai keep
--- selected animals in the pool (cross-op visible) but record the per-op claim so a later
--- SAME-op rule cannot re-pick them; buy removes its selected set from the dealer pool and
--- appends it to the destination owned pool.
---
--- Edge handling (never raises except the nil-arg guard): an unresolvable / malformed target
--- husbandry is skipped + WARN (once per uid per call); an animal with a nil identity field is
--- skipped + WARN; a deleted / nil filter selects nothing (evaluator fails closed); a missing
--- `ctx.animalSystem` fails a sell/buy rule closed (WARN); an empty target list / selection
--- emits no record (+ DEBUG).
---
---@param rules table[] farm-scoped rule records (the planner filters `enabled`)
---@param ctx table { husbandries, dealerAnimalsByType, filtersById, animalSystem, farmBalanceByFarmId }
---@return table[] actions ordered action records (see the file header for per-op shapes)
function RLHerdsmanPlanner.planActions(rules, ctx)
    if rules == nil or ctx == nil then
        -- T4 owns construction; a nil top-level arg is a programmer error - fail loud.
        error(string.format("RLHerdsmanPlanner.planActions: rules and ctx are required (got rules=%s, ctx=%s)",
            tostring(rules), tostring(ctx)))
    end

    local husbandries = type(ctx.husbandries) == "table" and ctx.husbandries or {}
    local dealerByType = type(ctx.dealerAnimalsByType) == "table" and ctx.dealerAnimalsByType or {}
    local filtersById = type(ctx.filtersById) == "table" and ctx.filtersById or {}
    local animalSystem = ctx.animalSystem
    local farmBalanceByFarmId = type(ctx.farmBalanceByFarmId) == "table" and ctx.farmBalanceByFarmId or {}

    -- One evalCtx per planActions call: RLFilterEvaluator.evaluate MUTATES its third arg
    -- (per-call warning / type-mismatch dedup sets), so NEVER pass the planner's input ctx
    -- through - allocate a planner-internal table dedicated to that.
    local evalCtx = { warnedFields = {}, typeMismatchFields = {} }

    -- Internal mutable bookkeeping (copies; ctx is never touched):
    --   remainingByHusbandry[uid] - owned animals still available for a husbandry (after
    --     sell removals + buy appends); shallow array copy, built lazily.
    --   dealerRemaining[typeIdx]  - dealer animals still available for a type; shallow array
    --     copy, built lazily.
    --   claimedByOp[op]           - set of claimed animal keys for an op (same-op claim).
    --   ledger[farmId]            - running farm balance projection; seeded once from
    --     ctx.farmBalanceByFarmId, credited by executed sells, debited by buys (run order).
    --   ledgerSeeded[farmId]      - distinguishes "not yet seeded" from "seeded to nil"
    --     (a non-number / absent balance leaves ledger[farmId] nil -> buy fails closed).
    --   warnedHusbandries[uid]    - per-call dedup for the unresolvable/malformed WARNING.
    --   warnedAnimals[animal]     - per-call dedup for the nil/invalid-identity WARNING
    --     (keyed by the animal value, since the same pool entry is re-scanned by each op).
    local remainingByHusbandry = {}
    local dealerRemaining = {}
    local claimedByOp = {}
    local ledger = {}
    local ledgerSeeded = {}
    local warnedHusbandries = {}
    local warnedAnimals = {}

    --- Resolve a target husbandry record, or nil (+ WARN once per uid) when it is absent or
    --- malformed (missing `animals` or `animalTypeIndex`).
    ---@param uid string
    ---@return table|nil husbandry
    local function resolveHusbandry(uid)
        local h = husbandries[uid]
        if type(h) ~= "table" or type(h.animals) ~= "table" or h.animalTypeIndex == nil then
            if not warnedHusbandries[uid] then
                Log:warning("%s unresolvable/malformed husbandry uid=%s (absent, or missing animals/animalTypeIndex); target skipped",
                    LOG_PREFIX, tostring(uid))
                warnedHusbandries[uid] = true
            end
            return nil
        end
        return h
    end

    --- The remaining owned-animal pool for a husbandry, lazily shallow-copied from ctx
    --- (never the live array). nil when the husbandry is unresolvable / malformed.
    ---@param uid string
    ---@return table|nil pool array of animal refs
    local function ownedPool(uid)
        local pool = remainingByHusbandry[uid]
        if pool ~= nil then return pool end
        local h = resolveHusbandry(uid)
        if h == nil then return nil end
        pool = {}
        for i, a in ipairs(h.animals) do pool[i] = a end
        remainingByHusbandry[uid] = pool
        return pool
    end

    --- The remaining dealer pool for an animalType, lazily shallow-copied from ctx. A
    --- missing / non-table entry yields an empty pool (no candidates), never a raise.
    ---@param typeIdx any animalType index
    ---@return table pool array of animal refs
    local function dealerPool(typeIdx)
        local pool = dealerRemaining[typeIdx]
        if pool ~= nil then return pool end
        pool = {}
        local src = dealerByType[typeIdx]
        if type(src) == "table" then
            for i, a in ipairs(src) do pool[i] = a end
        end
        dealerRemaining[typeIdx] = pool
        return pool
    end

    --- Seed the running ledger for a farm exactly once from ctx.farmBalanceByFarmId. A
    --- non-number / absent balance leaves ledger[farmId] nil (buy then fails closed; sell
    --- cannot thread its credit). Idempotent so credits / debits are never overwritten.
    ---@param farmId any
    local function seedLedger(farmId)
        if not ledgerSeeded[farmId] then
            ledgerSeeded[farmId] = true
            local v = farmBalanceByFarmId[farmId]
            if type(v) == "number" then ledger[farmId] = v end
        end
    end

    --- Real per-animal price: the REAL getSellPrice (markup 1.0 sell / 1.075 buy) plus the
    --- REAL transport fee - the SAME calls as legacy AIAnimalManager:onDayChanged (mutation
    --- parity), no mock, no re-derivation. Caller guarantees `animalSystem` is usable
    --- (sell/buy fail closed when it is missing).
    ---@param animal table
    ---@param markup number
    ---@return number price
    local function priceOf(animal, markup)
        return animal:getSellPrice() * markup
            + animalSystem:getAnimalTransportFee(animal.subTypeIndex, animal.age)
    end

    --- Walk a candidate pool, returning the ordered animals that (a) carry a resolvable
    --- identity, (b) are not already claimed by this op, and (c) match (noFilter -> all
    --- remaining; else RLFilterEvaluator.evaluate, fails closed). Does NOT claim or mutate
    --- the pool - the caller prices / caps / claims the post-match set (T2a defers the claim
    --- past the cap so capped-out matches stay candidates for a later same-op rule).
    ---@param pool table array of animal refs
    ---@param filter table|nil filter record / node, or nil (deleted -> selects nothing)
    ---@param noFilter boolean true for naming (match every remaining unclaimed animal)
    ---@param claimed table per-op claimed-key set (read only)
    ---@return table[] matched ordered candidate list
    local function matchFromPool(pool, filter, noFilter, claimed)
        local matched = {}
        for _, animal in ipairs(pool) do
            local key = animalKey(animal)
            if key == nil then
                -- Skip + WARN on a malformed candidate (nil identity field, OR a non-table
                -- entry) WITHOUT indexing a non-table - the planner never raises on bad data.
                -- Deduped per call (warnedAnimals): the same pool entry is re-scanned by each op.
                if not warnedAnimals[animal] then
                    local fid, aUid, acountry
                    if type(animal) == "table" then
                        fid, aUid = animal.farmId, animal.uniqueId
                        if type(animal.birthday) == "table" then acountry = animal.birthday.country end
                    end
                    Log:warning("%s skipping animal with nil/invalid identity (farmId=%s uniqueId=%s country=%s)",
                        LOG_PREFIX, tostring(fid), tostring(aUid), tostring(acountry))
                    warnedAnimals[animal] = true
                end
            elseif not claimed[key] then
                local match = noFilter or RLFilterEvaluator.evaluate(filter, animal, evalCtx)
                if match then
                    matched[#matched + 1] = animal
                end
            end
        end
        return matched
    end

    --- Record each animal's key in a per-op claimed set (same-op claim across rules /
    --- targets). nil-keyed animals never reach here (matchFromPool dropped them).
    ---@param claimed table
    ---@param animals table[]
    local function claimAll(claimed, animals)
        for _, a in ipairs(animals) do
            local k = animalKey(a)
            if k ~= nil then claimed[k] = true end
        end
    end

    --- Rebuild a pool array excluding the selected keys (order preserved). Shared by sell's
    --- owned-pool removal and buy's dealer-pool removal.
    ---@param pool table[]
    ---@param selectedKeys table set keyed by animal key
    ---@return table[] newPool
    local function poolMinus(pool, selectedKeys)
        local newPool = {}
        for _, a in ipairs(pool) do
            local k = animalKey(a)
            if k == nil or not selectedKeys[k] then newPool[#newPool + 1] = a end
        end
        return newPool
    end

    --- True when a matched candidate exposes the REAL Animal price methods the Sell/Buy path
    --- invokes (`getSellPrice`, and for Sell `getCanBeSold`). A row can pass `matchFromPool`'s
    --- identity gate yet be a non-Animal data table without these methods; pricing it would be
    --- a call-on-nil-method raise. The planner's contract is "never raises except the nil-arg
    --- guard", so the caller skips + WARNs such a row (deduped) instead - the same fail-closed
    --- posture as the nil-identity skip. Owned non-price ops (castrate/naming/ai) never reach here.
    ---@param animal table identity-valid candidate
    ---@param needsCanBeSold boolean true for Sell (also needs getCanBeSold)
    ---@return boolean priceable
    local function isPriceableAnimal(animal, needsCanBeSold)
        if type(animal.getSellPrice) ~= "function" then return false end
        if needsCanBeSold and type(animal.getCanBeSold) ~= "function" then return false end
        return true
    end

    --- Skip + WARN (deduped via warnedAnimals) a matched candidate that lacks the real-Animal
    --- price methods, keeping the planner's never-raises contract on the price path.
    ---@param animal table
    local function warnNotPriceable(animal)
        if not warnedAnimals[animal] then
            Log:warning("%s skipping candidate without real-Animal price methods (uniqueId=%s) - not an Animal instance",
                LOG_PREFIX, tostring(type(animal) == "table" and animal.uniqueId or animal))
            warnedAnimals[animal] = true
        end
    end

    -- ---- 1. Filter to runnable rules. ----
    local runnable = {}
    for _, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            Log:warning("%s skipping non-table rule entry", LOG_PREFIX)
        elseif rule.enabled ~= true then
            Log:debug("%s skip rule=%s: disabled", LOG_PREFIX, tostring(rule.id))
        elseif OPERATION_RANK[rule.operation] == nil then
            Log:warning("%s skip rule=%s: unknown operation '%s' (not in OPERATION_ORDER)",
                LOG_PREFIX, tostring(rule.id), tostring(rule.operation))
        elseif rule.operation ~= "naming" and rule.filterId == nil then
            Log:debug("%s skip rule=%s op=%s: nil filterId (RLRM-404 incomplete draft, never runs)",
                LOG_PREFIX, tostring(rule.id), tostring(rule.operation))
        else
            runnable[#runnable + 1] = rule
        end
    end

    -- ---- 2. Sort by operation rank, then within-op name comparator. ----
    table.sort(runnable, function(a, b)
        local ra, rb = OPERATION_RANK[a.operation], OPERATION_RANK[b.operation]
        if ra ~= rb then return ra < rb end
        return RLHerdsmanRuleService.compareRulesByName(a, b)
    end)

    -- ---- 3. Per rule, select candidates per target and emit actions. ----
    local actions = {}
    for _, rule in ipairs(runnable) do
        local op = rule.operation
        local traits = RLHerdsmanPlanner.OPERATION_TRAITS[op]
        local params = type(rule.params) == "table" and rule.params or {}
        local filter = rule.filterId ~= nil and filtersById[rule.filterId] or nil

        if op == "naming" and rule.filterId ~= nil then
            -- The service floor forbids a naming filterId; a stray one (stale / migrated data)
            -- is ignored - naming selects ALL in T1 - but surface it so the mis-tag is visible.
            Log:debug("%s rule=%s op=naming carries a non-nil filterId=%s; ignored (naming selects all in T1)",
                LOG_PREFIX, tostring(rule.id), tostring(rule.filterId))
        end

        local claimed = claimedByOp[op]
        if claimed == nil then claimed = {}; claimedByOp[op] = claimed end

        local targets, dupes = dedupeSortedTargets(rule.targetHusbandries)
        if dupes > 0 then
            Log:debug("%s rule=%s op=%s: deduped %d duplicate target(s)", LOG_PREFIX, tostring(rule.id), op, dupes)
        end
        if #targets == 0 then
            Log:debug("%s rule=%s op=%s: empty targets, no action", LOG_PREFIX, tostring(rule.id), op)
        end

        if op == "sell" then
            -- Sell needs the real price path; a missing animalSystem is a T4 wiring error -
            -- fail closed (skip + WARN) rather than crash the whole tick.
            if type(animalSystem) ~= "table" then
                Log:warning("%s rule=%s op=sell skipped: ctx.animalSystem missing (T4 wiring)", LOG_PREFIX, tostring(rule.id))
            else
                local maxN = normalizeMaxAnimals(rule, params)
                if maxN ~= nil then
                    local mark = params.mark == true
                    for _, uid in ipairs(targets) do
                        local h = resolveHusbandry(uid)
                        if h ~= nil then
                            local pool = ownedPool(uid)
                            local candidates = #pool
                            -- Shortlist = filter-matched AND sellable (getCanBeSold, RLRM-151;
                            -- nil counts as a skip, matching legacy `not getCanBeSold()`). S =
                            -- shortlist size, pre-cap (the wage's `min(S, n*5)` operand).
                            local matched = matchFromPool(pool, filter, false, claimed)
                            local shortlist = {}
                            for _, a in ipairs(matched) do
                                if not isPriceableAnimal(a, true) then
                                    warnNotPriceable(a)
                                elseif a:getCanBeSold() then
                                    shortlist[#shortlist + 1] = { animal = a, price = priceOf(a, SELL_MARKUP), key = animalKey(a) }
                                end
                            end
                            local S = #shortlist
                            -- Price DESC; equal prices break by the three-field identity key
                            -- (deterministic, and decides which animals a tie straddling the cap takes).
                            table.sort(shortlist, function(x, y)
                                if x.price ~= y.price then return x.price > y.price end
                                return x.key < y.key
                            end)
                            local selected, selectedKeys, amountGained = {}, {}, 0
                            for i = 1, math.min(maxN, S) do
                                local item = shortlist[i]
                                selected[i] = item.animal
                                selectedKeys[item.key] = true
                                amountGained = amountGained + item.price
                            end
                            local n = #selected
                            local W = wageFor(h.animalTypeIndex)
                            local wage = W * n * (mark and 0.35 or 1) + W * math.min(S, n * 5) * 0.15 * (mark and 0.35 or 1)
                            Log:debug("%s rule=%s op=sell husbandry=%s candidates=%d shortlist=%d selected=%d mark=%s amountGained=%.2f wage=%.2f",
                                LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, S, n, tostring(mark), amountGained, wage)
                            if n > 0 then
                                -- Global claim (UNCONDITIONAL, mark OR exec): the selected set
                                -- leaves the owned pool, so no later rule (sell now; castrate/
                                -- naming/ai in T2b) can touch it. Capped-out matches are NOT
                                -- claimed - they stay candidates for a later same-op sell rule.
                                remainingByHusbandry[uid] = poolMinus(pool, selectedKeys)
                                claimAll(claimed, selected)
                                local action = { ruleId = rule.id, operation = "sell", husbandryId = uid,
                                    animals = selected, mark = mark, wage = wage }
                                if not mark then
                                    -- Executed sell: carry proceeds + credit the farm ledger so a
                                    -- later same-farm buy can spend them (a marked sell is advisory
                                    -- only - no amountGained, no money, no event; T3 sets the mark).
                                    action.amountGained = amountGained
                                    seedLedger(rule.farmId)
                                    if type(ledger[rule.farmId]) == "number" then
                                        ledger[rule.farmId] = ledger[rule.farmId] + amountGained
                                    end
                                end
                                actions[#actions + 1] = action
                            end
                        end
                    end
                end
            end

        elseif op == "buy" then
            if type(animalSystem) ~= "table" then
                Log:warning("%s rule=%s op=buy skipped: ctx.animalSystem missing (T4 wiring)", LOG_PREFIX, tostring(rule.id))
            else
                local maxN = normalizeMaxAnimals(rule, params)
                -- Gate on maxAnimals FIRST (frozen Buy boundary); validate budget only for a rule
                -- that would actually run, so a maxAnimals-dead rule stays quiet (no spurious WARN).
                local budgetType, budgetFixed, budgetPct, badBudget
                if maxN ~= nil then
                    budgetType, budgetFixed, budgetPct, badBudget = validateBuyBudget(rule, params)
                end
                if maxN ~= nil and not badBudget then
                    for _, uid in ipairs(targets) do
                        local h = resolveHusbandry(uid)
                        if h ~= nil then
                            seedLedger(rule.farmId)
                            local balance = ledger[rule.farmId]
                            if type(balance) ~= "number" then
                                -- nil farm balance -> fail closed (mirror T1's nil-identity posture).
                                Log:warning("%s rule=%s op=buy husbandry=%s skipped: nil farm balance (ledger[%s])",
                                    LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(rule.farmId))
                            elseif balance <= 0 then
                                -- Zero / negative balance -> no-op. MUST gate BEFORE math.clamp:
                                -- the real engine math.clamp RAISES on max < min (clamp(_, 0, <0)),
                                -- so a negative balance must never reach it (the headless IMPL is
                                -- lenient and masked this; filed as a lib-fidelity follow-up).
                                Log:debug("%s rule=%s op=buy husbandry=%s no-op: balance <= 0 (%.2f)",
                                    LOG_PREFIX, tostring(rule.id), tostring(uid), balance)
                            else
                                local budget = (budgetType == "percentage")
                                    and math.floor(balance * budgetPct / 100) or budgetFixed
                                budget = math.clamp(budget, 0, balance)   -- balance > 0 here -> clamp safe
                                if budget <= 0 then
                                    -- A 0% percentage (or a fixed budget that floors to 0) on a
                                    -- positive balance -> no-op this target.
                                    Log:debug("%s rule=%s op=buy husbandry=%s no-op: budget <= 0 (balance=%.2f)",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), balance)
                                else
                                    local typeIdx = h.animalTypeIndex
                                    local pool = dealerPool(typeIdx)
                                    local candidates = #pool   -- BEFORE filter + affordability
                                    local matched = matchFromPool(pool, filter, false, claimed)
                                    -- Affordable shortlist (price <= budget); S = shortlist size.
                                    local shortlist = {}
                                    for _, a in ipairs(matched) do
                                        if not isPriceableAnimal(a, false) then
                                            warnNotPriceable(a)
                                        else
                                            local p = priceOf(a, BUY_MARKUP)
                                            if p <= budget then
                                                shortlist[#shortlist + 1] = { animal = a, price = p, key = animalKey(a) }
                                            end
                                        end
                                    end
                                    local S = #shortlist
                                    table.sort(shortlist, function(x, y)
                                        if x.price ~= y.price then return x.price < y.price end
                                        return x.key < y.key
                                    end)
                                    local selected, selectedKeys, amountSpent = {}, {}, 0
                                    local remaining = budget
                                    for _, item in ipairs(shortlist) do
                                        -- Strict `>`: a candidate priced exactly at the remainder IS bought.
                                        if item.price > remaining or #selected >= maxN then break end
                                        selected[#selected + 1] = item.animal
                                        selectedKeys[item.key] = true
                                        amountSpent = amountSpent + item.price
                                        remaining = remaining - item.price
                                    end
                                    local n = #selected
                                    local W = wageFor(typeIdx)
                                    local wage = W * n + W * math.min(S, n * 5) * 0.15
                                    -- `matched` distinguishes the three Buy no-op causes (T8.1):
                                    -- matched=0 filter-empty; matched>0 & affordable=0 all-unaffordable;
                                    -- affordable>0 & selected<cap budget-consumed mid-loop.
                                    Log:debug("%s rule=%s op=buy husbandry=%s candidates=%d matched=%d affordable=%d selected=%d budgetAtEntry=%.2f amountSpent=%.2f wage=%.2f",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, #matched, S, n, budget, amountSpent, wage)
                                    if n > 0 then
                                        -- Remove bought from the dealer pool; claim same-op; append
                                        -- to the destination owned pool (cross-op visible); debit the
                                        -- ledger so a later same-farm buy can't double-spend.
                                        dealerRemaining[typeIdx] = poolMinus(pool, selectedKeys)
                                        claimAll(claimed, selected)
                                        local destPool = ownedPool(uid)
                                        if destPool ~= nil then
                                            for _, a in ipairs(selected) do destPool[#destPool + 1] = a end
                                        end
                                        ledger[rule.farmId] = ledger[rule.farmId] - amountSpent
                                        actions[#actions + 1] = { ruleId = rule.id, operation = "buy", husbandryId = uid,
                                            animals = selected, amountSpent = amountSpent, wage = wage }
                                    end
                                end
                            end
                        end
                    end
                end
            end

        else
            -- Castrate / naming / ai: T1 behavior preserved (select ALL matched, claim same-op,
            -- cross-op visible; no cap / sort / wage / mark yet - T2b). Action carries the T1 shape.
            for _, uid in ipairs(targets) do
                local pool = ownedPool(uid)
                if pool ~= nil then
                    local candidates = #pool
                    local selected = matchFromPool(pool, filter, traits.noFilter == true, claimed)
                    claimAll(claimed, selected)
                    Log:debug("%s rule=%s op=%s husbandry=%s candidates=%d selected=%d",
                        LOG_PREFIX, tostring(rule.id), op, tostring(uid), candidates, #selected)
                    if #selected > 0 then
                        actions[#actions + 1] = {
                            ruleId = rule.id,
                            operation = op,
                            husbandryId = uid,
                            animals = selected,
                        }
                    end
                end
            end
        end
    end

    Log:debug("%s planned %d action(s) from %d runnable rule(s) (of %d input)",
        LOG_PREFIX, #actions, #runnable, type(rules) == "table" and #rules or 0)
    return actions
end

Log:trace("RLHerdsmanPlanner: loaded")
