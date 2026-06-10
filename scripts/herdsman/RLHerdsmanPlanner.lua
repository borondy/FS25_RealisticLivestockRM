-- RLHerdsmanPlanner.lua
-- Pure herdsman day-tick planner (M-Tick T1, RLRM-389) - the keystone of M-Tick.
--
-- `planActions(rules, ctx)` decides WHICH animals each enabled rule acts on, in run
-- order, threading cross-rule claims, and returns ordered intended-action records. The
-- surprising part - sequential state threading across rules - is isolated here in one
-- 100% headless module: data in, data out. `planActions` reads no `g_*`, makes no engine
-- calls, and MUST NOT mutate `rules`, `ctx`, or any animal table (internal bookkeeping
-- copies only). Per-op params / caps / sort / wage / mark are T2 (RLRM-390); event
-- dispatch is T3; the day-tick hook is T4.
--
-- ctx contract (T4 builds it in-game; tests fabricate it):
--   ctx = {
--     husbandries         = { [uniqueId] = { animalTypeIndex = n, animals = { Animal, ... } } },
--     dealerAnimalsByType = { [animalTypeIndex] = { Animal, ... } },
--     filtersById         = { [filterId] = filterRecord },
--   }
-- The caller (T4) farm-scopes BOTH `rules` and `ctx.husbandries`, and excludes legacy
-- `reserved` dealer animals from `dealerAnimalsByType` (coexistence: legacy AIAnimalManager
-- claims dealer animals via `animal.reserved`). The planner filters `enabled` itself.
--
-- Action record - one per (rule x target-husbandry) that selects >= 1 animal, emitted in
-- run order (operation rank, then within an op `compareRulesByName`; within a rule, targets
-- in lexicographic uniqueId order):
--   { ruleId = string, operation = string, husbandryId = string, animals = { animalRef, ... } }
-- `animals` preserves source-array order (load-bearing only once T2 adds caps/sort).
--
-- Run order = operation order (RLHerdsmanRuleService.OPERATION_ORDER: sell -> buy ->
-- castrate -> naming -> ai) then RLHerdsmanRuleService.compareRulesByName within an op
-- (mirrors legacy AIAnimalManager:onDayChanged - sell frees herd space before buy fills it).
--
-- Candidate match is RLFilterEvaluator.evaluate (pure, fails closed: a nil / deleted
-- filter selects nothing, never raises - D16). Naming carries no filter and selects ALL
-- remaining animals in its targets (T1 intake 3a; T2 narrows to unnamed-only).

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanPlanner = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every planner log line (the per-(rule, husbandry) DEBUG summary
--- lines are the verification surface; the evaluator already emits per-animal DEBUG lines).
local LOG_PREFIX = "[planActions]"

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
--- countries distinct.
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

-- =============================================================================
-- Public entry point
-- =============================================================================

--- Plan the herdsman day-tick: which animals each enabled rule acts on, in run order,
--- with the locked two-level claim model threaded across sequential rule passes. Pure:
--- `rules`, `ctx`, and every animal table are left unmutated (internal pool / claim copies
--- only).
---
--- Algorithm:
---   1. Filter to runnable rules: `enabled == true`; operation in OPERATION_ORDER (else
---      skip + WARN); non-naming with `filterId == nil` is an incomplete draft -> skip +
---      DEBUG (RLRM-404). Disabled rules skip + DEBUG.
---   2. Sort runnable rules by operation rank, then `compareRulesByName`.
---   3. Per rule, dedupe + lexicographically order its targets, then per target select
---      candidates from the internal REMAINING pools (one `evalCtx` per call), apply claims,
---      and emit an action record when >= 1 animal is selected.
---
--- Claim mechanics (the two-level model):
---   * Owned ops (sell / castrate / naming / ai) draw from a per-husbandry owned pool
---     (shallow copy of `ctx.husbandries[uid].animals`).
---   * Sell (end-task) REMOVES selected animals from the owned pool -> global claim.
---   * Castrate / naming / ai keep selected animals in the pool (cross-op visible) but record
---     them in the per-op claimed set so a later SAME-op rule cannot re-pick them.
---   * Buy draws from a per-type dealer pool (shallow copy of `ctx.dealerAnimalsByType[type]`);
---     selected dealer animals are recorded in buy's claimed set (same-op claim across rules /
---     targets) AND appended to the destination husbandry's owned pool (cross-op visibility).
---
--- Edge handling (never raises except the nil-arg guard): an unresolvable / malformed target
--- husbandry is skipped + WARN (once per uid per call); an animal with a nil identity field is
--- skipped + WARN; a deleted / nil filter selects nothing (evaluator fails closed); an empty
--- target list / selection emits no record (+ DEBUG).
---
---@param rules table[] farm-scoped rule records (the planner filters `enabled`)
---@param ctx table { husbandries, dealerAnimalsByType, filtersById } - see the file header
---@return table[] actions ordered `{ ruleId, operation, husbandryId, animals }` records
function RLHerdsmanPlanner.planActions(rules, ctx)
    if rules == nil or ctx == nil then
        -- T4 owns construction; a nil top-level arg is a programmer error - fail loud.
        error(string.format("RLHerdsmanPlanner.planActions: rules and ctx are required (got rules=%s, ctx=%s)",
            tostring(rules), tostring(ctx)))
    end

    local husbandries = type(ctx.husbandries) == "table" and ctx.husbandries or {}
    local dealerByType = type(ctx.dealerAnimalsByType) == "table" and ctx.dealerAnimalsByType or {}
    local filtersById = type(ctx.filtersById) == "table" and ctx.filtersById or {}

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
    --   warnedHusbandries[uid]    - per-call dedup for the unresolvable/malformed WARNING.
    --   warnedAnimals[animal]     - per-call dedup for the nil/invalid-identity WARNING
    --     (keyed by the animal value, since the same pool entry is re-scanned by each op).
    local remainingByHusbandry = {}
    local dealerRemaining = {}
    local claimedByOp = {}
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

    --- Walk a candidate pool, selecting animals that (a) carry a resolvable identity, (b) are
    --- not already claimed by this op, and (c) match (noFilter -> all remaining; else
    --- RLFilterEvaluator.evaluate, fails closed). Marks each selected key in `claimed`. Does
    --- NOT mutate the pool (the caller threads pool removals / appends). Returns the ordered
    --- selected list + the set of selected keys.
    ---@param pool table array of animal refs
    ---@param filter table|nil filter record / node, or nil (deleted -> selects nothing)
    ---@param noFilter boolean true for naming (select every remaining unclaimed animal)
    ---@param claimed table per-op claimed-key set (mutated)
    ---@return table[] selected
    ---@return table selectedKeys set keyed by animal key
    local function selectFromPool(pool, filter, noFilter, claimed)
        local selected, selectedKeys = {}, {}
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
                    selected[#selected + 1] = animal
                    selectedKeys[key] = true
                    claimed[key] = true
                end
            end
        end
        return selected, selectedKeys
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

        for _, uid in ipairs(targets) do
            local selected, selectedKeys = {}, {}
            local candidates = 0

            if traits.sourcesFromDealer then
                -- Buy: candidates come from the dealer pool keyed by the destination
                -- husbandry's type. Selected dealer animals LEAVE the dealer pool (so a later
                -- buy target / rule sees the true remaining pool and `candidates` stays
                -- truthful) AND join the dest owned pool (cross-op visibility for the later
                -- castrate / naming / ai rules).
                local h = resolveHusbandry(uid)
                if h ~= nil then
                    local typeIdx = h.animalTypeIndex
                    local pool = dealerPool(typeIdx)
                    candidates = #pool
                    selected, selectedKeys = selectFromPool(pool, filter, false, claimed)
                    if #selected > 0 then
                        -- Remove the bought animals from the dealer pool (rebuild preserves
                        -- order); claimedByOp.buy still guards same-op re-picks redundantly.
                        local newDealer = {}
                        for _, a in ipairs(pool) do
                            local k = animalKey(a)
                            if k == nil or not selectedKeys[k] then
                                newDealer[#newDealer + 1] = a
                            end
                        end
                        dealerRemaining[typeIdx] = newDealer
                        local destPool = ownedPool(uid)
                        if destPool ~= nil then
                            for _, a in ipairs(selected) do destPool[#destPool + 1] = a end
                        end
                    end
                end
            else
                -- Owned ops (sell / castrate / naming / ai): candidates from the owned pool.
                local pool = ownedPool(uid)
                if pool ~= nil then
                    candidates = #pool
                    selected, selectedKeys = selectFromPool(pool, filter, traits.noFilter == true, claimed)
                    if traits.removesFromHerd and #selected > 0 then
                        -- End-task global claim: drop the selected animals from the owned pool
                        -- so later owned-op rules cannot re-pick them. Rebuild preserves order.
                        local newPool = {}
                        for _, a in ipairs(pool) do
                            local k = animalKey(a)
                            if k == nil or not selectedKeys[k] then
                                newPool[#newPool + 1] = a
                            end
                        end
                        remainingByHusbandry[uid] = newPool
                    end
                end
            end

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

    Log:debug("%s planned %d action(s) from %d runnable rule(s) (of %d input)",
        LOG_PREFIX, #actions, #runnable, type(rules) == "table" and #rules or 0)
    return actions
end

Log:trace("RLHerdsmanPlanner: loaded")
