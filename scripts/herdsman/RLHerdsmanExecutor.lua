-- RLHerdsmanExecutor.lua
-- M-Tick T3 (RLRM-391) - the in-game executor wall. Turns the pure plan from
-- RLHerdsmanPlanner.planActions (T1/T2) into the SAME mutations legacy
-- AIAnimalManager:onDayChanged performs (MUTATION PARITY): it dispatches the SAME
-- events (AIAnimalSellEvent / AIAnimalBuyEvent / AIAnimalInseminationEvent), applies
-- castrate + naming as direct server-side field writes AND broadcasts AnimalCastrateEvent /
-- AnimalNameChangeEvent per animal (caller-mutates-first, no sendLocal) so those writes sync
-- to clients, sets the AI_MANAGER_* mark for mark-mode actions (broadcasting AnimalMarkEvent
-- per animal, caller-mutates-first, no sendLocal, so marks sync to clients too) instead of
-- executing, persists the naming cursor, and deducts the herdsman wage once per farm
-- via MoneyType.HERDSMAN_WAGES.
--
-- T3 makes NO candidate decisions: the plan is authoritative. The executor obeys
-- action.mark / action.wage / action.animals verbatim; it never selects, caps, sorts,
-- computes wage, or reorders. It also does NOT clear stale marks (that is T4, the
-- clear-before-execute ordering) and emits NO player notifications (that is T5/RLRM-408 -
-- the returned summary carries the per-action data T5 needs).
--
-- Dependency injection (Rule C), no g_* reads. The dispatch boundary arrives through
-- `ctx`, so the executor's DECISIONS are dual-run (the suite injects fakes/spies; T4 wires
-- the real globals - the calls are byte-identical to legacy):
--   ctx = {
--     server                  = g_server,                        -- broadcastEvent(event, true)
--     mission                 = g_currentMission,                -- addMoney (wage)
--     husbandryPlaceablesById = { [uniqueId] = <placeable> },    -- event object, getOwnerFarmId, getNumOfFreeAnimalSlots
--     ruleService             = <RLHerdsmanRuleService>,         -- setNamingCursor(id, previous)
--     animalNameSystem        = <real AnimalNameSystem>,         -- getRandomName(gender) (reused from T2)
--   }
-- T3 does NOT read ctx.husbandries (clear-stale-marks is T4, decision 1b).
--
-- summary (return value, consumed by T4 wage readout + T5 messages):
--   summary = {
--     wageByFarm = { [farmId] = number },         -- one deduction per farm with > 0
--     results    = { <one row per plan action, in plan order> },
--   }
-- A result row: { ruleId, husbandryId, farmId, operation, count, mark, amountGained,
--   amountSpent, dispatched, skipReason }. `dispatched` is true iff the event broadcast /
--   direct mutation was applied; `skipReason` is nil when dispatched, else one of
--   "no-space" | "no-money" | "mark-mode" | "missing-placeable" | "bad-data".
--
-- Parity anchors in AIAnimalManager:onDayChanged: Sell broadcast / Buy broadcast /
-- Castrate field writes + event / Naming walk + event / AI broadcast; wage in
-- RealisticLivestock_FSBaseMission:onDayChanged. T3 SETS marks for mark-mode; clear-stale
-- is T4.
--
-- T3 ships DORMANT: it wires NO MessageCenter subscription and NO day-tick hook (T4). The
-- legacy AIAnimalManager tick is still live, so a live T3 tick would double-dispatch +
-- double-charge HERDSMAN_WAGES. Until T4 lands, in-game verification is via rlTest only.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanExecutor = {}

-- =============================================================================
-- Constants
-- =============================================================================

local LOG_PREFIX = "[executeActions]"

local MARK_BY_OPERATION = {
    sell     = "AI_MANAGER_SELL",
    castrate = "AI_MANAGER_CASTRATE",
    ai       = "AI_MANAGER_INSEMINATE",
}

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Finite-number guard: rejects nil / non-number / NaN / +-inf. Used to fail closed on
--- amounts that would crash the event's validate arithmetic and on a malformed wage.
---@param v any
---@return boolean
local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Resolve the herdsman wage contribution for an action, failing closed: a non-finite /
--- non-number wage is treated as 0 (with a WARNING), never raising.
---@param action table
---@return number
local function resolveWage(action)
    if isFiniteNumber(action.wage) then return action.wage end
    Log:warning("%s rule=%s op=%s: non-number wage (%s) - treating as 0",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.wage))
    return 0
end

--- Set an AI_MANAGER_* mark on every animal of a mark-mode action AND broadcast AnimalMarkEvent
--- per animal (caller-mutates-first, no sendLocal) so the mark syncs to MP clients - the same
--- shape the player path (@see RLAnimalInfoService.markAnimal) and the castrate / naming exec legs
--- use. setMarked is fully real headless (the visual-marker call self-no-ops with no visual
--- instance). Fails CLOSED on a nil markKey: AnimalMarkEvent treats key=nil as a destructive
--- clear-ALL-marks (@see AnimalMarkEvent.new), so a nil key skips the whole action (no setMarked,
--- no broadcast) rather than wiping every mark on every client.
---@param ctx table dispatch context (ctx.server:broadcastEvent)
---@param placeable table husbandry placeable owning the animals' cluster system (the event object)
---@param action table the mark-mode action (animals + ruleId / operation / husbandryId for the log row)
---@param markKey string the AI_MANAGER_* mark to set + broadcast
---@param farmId number owning farm (log context)
local function setMarkOnAll(ctx, placeable, action, markKey, farmId)
    if markKey == nil then
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s: nil mark key - skipped (no setMarked, no broadcast; nil key is AnimalMarkEvent clear-all)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId), tostring(farmId))
        return
    end
    for _, animal in ipairs(action.animals) do
        animal:setMarked(markKey, true)
        -- MP sync: broadcast WITHOUT sendLocal. AnimalMarkEvent:run applies setMarked on server AND
        -- client, so the server already marked above; sendLocal would re-run run() locally (redundant
        -- re-mark, possible double broadcast). @see RLAnimalInfoService.markAnimal.
        ctx.server:broadcastEvent(AnimalMarkEvent.new(placeable, animal, markKey, true))
        Log:debug("%s rule=%s op=%s husbandry=%s farm=%s: broadcast AnimalMarkEvent uniqueId=%s key=%s",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId),
            tostring(farmId), tostring(animal.uniqueId), tostring(markKey))
    end
end

--- Emit the single uniform greppable per-action trace row, read from the result table so EVERY
--- exit path (including the early fail-closed skips) logs exactly one identical DEBUG row.
---@param result table
local function logActionRow(result)
    Log:debug("%s rule=%s op=%s husbandry=%s farm=%s count=%d mark=%s dispatched=%s amountGained=%s amountSpent=%s skipReason=%s",
        LOG_PREFIX, tostring(result.ruleId), tostring(result.operation), tostring(result.husbandryId),
        tostring(result.farmId), result.count, tostring(result.mark), tostring(result.dispatched),
        tostring(result.amountGained), tostring(result.amountSpent), tostring(result.skipReason))
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Apply the planned actions in-game (server-only), mirroring legacy
--- AIAnimalManager:onDayChanged. Per action: dispatch the SAME event legacy does (sell /
--- buy / ai), apply castrate + naming directly THEN broadcast AnimalCastrateEvent /
--- AnimalNameChangeEvent per animal so clients sync, OR set the AI_MANAGER_* mark for
--- a mark-mode action AND broadcast AnimalMarkEvent per animal so the mark syncs to clients;
--- accumulate the herdsman wage per farm and deduct it once per farm at
--- the end. Fails LOUD on a missing STRUCTURAL ctx dep (a T4-wiring bug), fails CLOSED
--- (skip + WARNING, never raise) on a per-action data problem. Reads no g_*; the dispatch
--- boundary is injected via ctx.
---@param plan table|nil ordered action records from RLHerdsmanPlanner.planActions
---@param ctx table dispatch context (server, mission, husbandryPlaceablesById, ruleService, animalNameSystem)
---@return table summary { wageByFarm = { [farmId]=number }, results = { <row per action> } }
function RLHerdsmanExecutor.executeActions(plan, ctx)
    local summary = { wageByFarm = {}, results = {} }

    -- Server-only: a dedicated server has g_server ~= nil, so guarding on ctx.server (= g_server)
    -- correctly includes dedis. T4 only ticks server-side; the executor still guards.
    if ctx == nil or ctx.server == nil then
        Log:debug("%s not server (ctx.server==nil) - no dispatch / mutation / money; empty summary", LOG_PREFIX)
        return summary
    end

    -- Fail LOUD on a missing STRUCTURAL dep the executor unconditionally needs: a missing one
    -- is a T4-wiring bug, never a silent no-op that would hide a broken day-tick.
    if ctx.mission == nil or ctx.ruleService == nil or ctx.animalNameSystem == nil
        or ctx.husbandryPlaceablesById == nil then
        error(string.format(
            "%s missing structural ctx dep (T4 wiring bug): mission=%s ruleService=%s animalNameSystem=%s husbandryPlaceablesById=%s",
            LOG_PREFIX, tostring(ctx.mission ~= nil), tostring(ctx.ruleService ~= nil),
            tostring(ctx.animalNameSystem ~= nil), tostring(ctx.husbandryPlaceablesById ~= nil)))
    end

    if plan == nil then
        Log:trace("%s nil plan - empty summary", LOG_PREFIX)
        return summary
    end

    -- First-seen farm order so the per-farm wage deduction is deterministic across runners
    -- (pairs() order is undefined); per-farm deductions are otherwise independent.
    local wageFarmOrder = {}

    for _, action in ipairs(plan) do
        local result = RLHerdsmanExecutor._executeOne(action, ctx, summary, wageFarmOrder)
        summary.results[#summary.results + 1] = result
    end

    -- One HERDSMAN_WAGES deduction per farm with a positive accrued wage (parity with
    -- RealisticLivestock_FSBaseMission:onDayChanged), in first-seen plan order.
    for _, farmId in ipairs(wageFarmOrder) do
        local wage = summary.wageByFarm[farmId]
        if wage ~= nil and wage > 0 then
            ctx.mission:addMoney(-wage, farmId, MoneyType.HERDSMAN_WAGES, true, true)
            Log:debug("%s wage deducted farmId=%s wage=%.2f", LOG_PREFIX, tostring(farmId), wage)
        end
    end

    return summary
end

-- =============================================================================
-- Per-action execution
-- =============================================================================

--- Resolve one action and apply it, accumulating any farm-attributed wage into
--- summary.wageByFarm. Returns the result row. Never raises (per-action problems fail closed).
---@param action table
---@param ctx table
---@param summary table
---@param wageFarmOrder table first-seen farmId order for deterministic wage deduction
---@return table result
function RLHerdsmanExecutor._executeOne(action, ctx, summary, wageFarmOrder)
    local result = {
        ruleId       = action.ruleId,
        husbandryId  = action.husbandryId,
        farmId       = nil,
        operation    = action.operation,
        count        = 0,
        mark         = action.mark == true,
        amountGained = action.amountGained,
        amountSpent  = action.amountSpent,
        dispatched   = false,
        skipReason   = nil,
    }

    -- Per-action resolution: the records carry only husbandryId (never farmId).
    local placeable = ctx.husbandryPlaceablesById[action.husbandryId]
    if placeable == nil then
        result.skipReason = "missing-placeable"
        Log:warning("%s rule=%s op=%s husbandry=%s: husbandry not in ctx - dropped (no dispatch, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId))
        logActionRow(result)
        return result
    end

    local farmId = placeable:getOwnerFarmId()
    if farmId == nil then
        result.skipReason = "missing-placeable"
        Log:warning("%s rule=%s op=%s husbandry=%s: getOwnerFarmId() nil - dropped (unattributable, no dispatch, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId))
        logActionRow(result)
        return result
    end
    result.farmId = farmId

    local animals = action.animals
    local count = (type(animals) == "table") and #animals or 0
    result.count = count
    if count == 0 then
        result.skipReason = "bad-data"
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s: zero animals - skipped before validate (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId), tostring(farmId))
        logActionRow(result)
        return result
    end

    -- Dispatch by operation. Each branch returns (chargeWage, dispatched, skipReason); a
    -- data-skip returns chargeWage=false (the action is dropped). chargeWage=true charges the
    -- wage regardless of dispatch outcome (mark, exec, OR validate-rejected) - legacy charges
    -- self.wage before/independent of dispatch.
    local op = action.operation
    local chargeWage, dispatched, skipReason
    if op == "sell" then
        chargeWage, dispatched, skipReason = RLHerdsmanExecutor._doSell(action, ctx, placeable, farmId, count)
    elseif op == "buy" then
        chargeWage, dispatched, skipReason = RLHerdsmanExecutor._doBuy(action, ctx, placeable, farmId, count)
    elseif op == "castrate" then
        chargeWage, dispatched, skipReason = RLHerdsmanExecutor._doCastrate(action, ctx, placeable, farmId, count)
    elseif op == "naming" then
        chargeWage, dispatched, skipReason = RLHerdsmanExecutor._doNaming(action, ctx, placeable, farmId, count)
    elseif op == "ai" then
        chargeWage, dispatched, skipReason = RLHerdsmanExecutor._doAi(action, ctx, placeable, farmId, count)
    else
        chargeWage, dispatched, skipReason = false, false, "bad-data"
        Log:warning("%s rule=%s husbandry=%s farm=%s: unknown operation '%s' - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(op))
    end

    result.dispatched = dispatched
    result.skipReason = skipReason

    if chargeWage then
        if summary.wageByFarm[farmId] == nil then
            summary.wageByFarm[farmId] = 0
            wageFarmOrder[#wageFarmOrder + 1] = farmId
        end
        summary.wageByFarm[farmId] = summary.wageByFarm[farmId] + resolveWage(action)
    end

    logActionRow(result)
    return result
end

--- Sell: exec broadcasts AIAnimalSellEvent (the event deducts MoneyType.SOLD_ANIMALS on the
--- server's cluster-batch success); mark sets AI_MANAGER_SELL. Wage charged either way.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
function RLHerdsmanExecutor._doSell(action, ctx, placeable, farmId, count)
    if action.mark == true then
        setMarkOnAll(ctx, placeable, action, MARK_BY_OPERATION.sell, farmId)
        return true, false, "mark-mode"
    end

    if not isFiniteNumber(action.amountGained) then
        Log:warning("%s rule=%s op=sell husbandry=%s farm=%s: non-number amountGained (%s) - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.amountGained))
        return false, false, "bad-data"
    end

    -- AIAnimalSellEvent.validate returns non-nil ONLY on object == nil, which the
    -- missing-placeable guard already caught; this branch is defensive.
    local errorCode = AIAnimalSellEvent.validate(placeable, count, action.amountGained, farmId)
    if errorCode ~= nil then
        Log:warning("%s rule=%s op=sell husbandry=%s farm=%s: validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "missing-placeable"
    end

    ctx.server:broadcastEvent(AIAnimalSellEvent.new(placeable, action.animals, action.amountGained), true)
    return true, true, nil
end

--- Buy (no mark param): exec runs AIAnimalBuyEvent.validate (the REAL runtime gate - free
--- slots + money) then broadcasts AIAnimalBuyEvent (removeSaleAnimal + addAnimals + deducts
--- MoneyType.NEW_ANIMALS_COST). A validate rejection skips dispatch but STILL charges wage.
--- Note: validate's money check reads the GLOBAL g_currentMission:getMoney (not ctx.mission), so
--- in production ctx.mission MUST be g_currentMission - T4 cannot point ctx.mission elsewhere
--- without the buy money-gate silently diverging from the wage ledger.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
function RLHerdsmanExecutor._doBuy(action, ctx, placeable, farmId, count)
    if not isFiniteNumber(action.amountSpent) then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s: non-number amountSpent (%s) - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.amountSpent))
        return false, false, "bad-data"
    end

    local errorCode = AIAnimalBuyEvent.validate(placeable, count, action.amountSpent, farmId)
    if errorCode == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_SPACE then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s count=%d: not enough space - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
        return true, false, "no-space"
    elseif errorCode == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s amountSpent=%.2f: not enough money - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), action.amountSpent)
        return true, false, "no-money"
    elseif errorCode ~= nil then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s: validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "missing-placeable"
    end

    ctx.server:broadcastEvent(AIAnimalBuyEvent.new(placeable, action.animals, action.amountSpent), true)
    return true, true, nil
end

--- Castrate: exec sets isCastrated + zeroes genetics.fertility per animal AND broadcasts
--- AnimalCastrateEvent per animal (caller-mutates-first, no sendLocal) so clients sync; mark
--- sets AI_MANAGER_CASTRATE.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
function RLHerdsmanExecutor._doCastrate(action, ctx, placeable, farmId, count)
    if action.mark == true then
        setMarkOnAll(ctx, placeable, action, MARK_BY_OPERATION.castrate, farmId)
        return true, false, "mark-mode"
    end

    -- Validate EVERY animal's genetics table BEFORE mutating, so a malformed animal drops the
    -- whole action (fail closed) instead of castrating a prefix then raising on a nil index. The
    -- planner already hard-skips nil-genetics castrate candidates; this guards a corrupt action.
    for _, animal in ipairs(action.animals) do
        if type(animal.genetics) ~= "table" then
            Log:warning("%s rule=%s op=castrate husbandry=%s farm=%s: animal has no genetics table - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
            return false, false, "bad-data"
        end
    end

    for _, animal in ipairs(action.animals) do
        animal.isCastrated = true
        animal.genetics.fertility = 0
        -- MP sync: broadcast WITHOUT sendLocal. AnimalCastrateEvent:run applies the castrate on
        -- server AND client, so the server already mutated above; sendLocal would re-run run()
        -- locally (redundant re-mutation, possible double broadcast). @see RLAnimalInfoService.castrateAnimal.
        ctx.server:broadcastEvent(AnimalCastrateEvent.new(placeable, animal))
        Log:debug("%s rule=%s op=castrate husbandry=%s farm=%s: broadcast AnimalCastrateEvent uniqueId=%s",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(animal.uniqueId))
    end
    return true, true, nil
end

--- Naming: alphabetical writes the planner-assigned names + advances the server-only cursor
--- via ruleService:setNamingCursor; random generates a fresh name per animal and never advances
--- the cursor. Each named animal broadcasts AnimalNameChangeEvent (caller-mutates-first, no
--- sendLocal) so clients sync. Naming has no mark param. Wage always charged.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
function RLHerdsmanExecutor._doNaming(action, ctx, placeable, farmId, count)
    if action.convention == "random" then
        for _, animal in ipairs(action.animals) do
            -- Capture the generated name into a local so the field write and the broadcast carry
            -- the SAME value (an empty name list -> getRandomName nil -> name cleared on both sides).
            local name = ctx.animalNameSystem:getRandomName(animal.gender)
            animal.name = name
            ctx.server:broadcastEvent(AnimalNameChangeEvent.new(placeable, animal, name))
            Log:debug("%s rule=%s op=naming(random) husbandry=%s farm=%s: broadcast AnimalNameChangeEvent uniqueId=%s name=%s",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(animal.uniqueId), tostring(name))
        end
        return true, true, nil
    end

    -- Alphabetical: the planner carries the resolved { animal, name } assignments. Validate EVERY
    -- entry BEFORE writing any name, so a malformed entry drops the whole action (fail closed)
    -- instead of naming a prefix then raising on the bad one (no partial mutation).
    if type(action.assignments) ~= "table" then
        Log:warning("%s rule=%s op=naming husbandry=%s farm=%s: alphabetical action missing assignments - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data"
    end
    for _, entry in ipairs(action.assignments) do
        if type(entry) ~= "table" or type(entry.animal) ~= "table" or type(entry.name) ~= "string" then
            Log:warning("%s rule=%s op=naming husbandry=%s farm=%s: malformed assignment entry - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
            return false, false, "bad-data"
        end
    end

    -- Broadcast inside the SAME validated loop that writes (assignments validated above; the
    -- planner guarantees assignments <-> animals 1:1), so mutation count == broadcast count.
    for _, entry in ipairs(action.assignments) do
        entry.animal.name = entry.name
        ctx.server:broadcastEvent(AnimalNameChangeEvent.new(placeable, entry.animal, entry.name))
        Log:debug("%s rule=%s op=naming(alpha) husbandry=%s farm=%s: broadcast AnimalNameChangeEvent uniqueId=%s name=%s",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(entry.animal.uniqueId), tostring(entry.name))
    end

    -- Persist the advanced cursor once per rule (server-only, no broadcast - clients never
    -- run the naming day-tick). previousOut is present iff >= 1 animal was named alphabetically.
    if action.previousOut ~= nil then
        ctx.ruleService:setNamingCursor(action.ruleId, action.previousOut)
    end
    return true, true, nil
end

--- AI (insemination): exec zips the parallel animals + dewars arrays into the event's
--- { animal, dewar } items and broadcasts AIAnimalInseminationEvent (the event applies
--- setInsemination + dewar:changeStraws(-1) itself - T3 does NOT decrement straws). NO
--- validate (legacy has none). mark sets AI_MANAGER_INSEMINATE.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
function RLHerdsmanExecutor._doAi(action, ctx, placeable, farmId, count)
    if action.mark == true then
        setMarkOnAll(ctx, placeable, action, MARK_BY_OPERATION.ai, farmId)
        return true, false, "mark-mode"
    end

    -- A nil / empty dewar would zip into the event and silently match nothing
    -- (dewar:getUniqueId() == item.dewar matches no dewar), inseminating nothing - fail closed.
    local dewars = action.dewars
    if type(dewars) ~= "table" or #dewars ~= count then
        Log:warning("%s rule=%s op=ai husbandry=%s farm=%s: animals/dewars length mismatch (%d vs %s) - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
            count, tostring(type(dewars) == "table" and #dewars or dewars))
        return false, false, "bad-data"
    end

    local items = {}
    for i = 1, count do
        local dewar = dewars[i]
        if type(dewar) ~= "string" or dewar == "" then
            Log:warning("%s rule=%s op=ai husbandry=%s farm=%s: dewar[%d] not a non-empty string (%s) - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), i, tostring(dewar))
            return false, false, "bad-data"
        end
        items[i] = { animal = action.animals[i], dewar = dewar }
    end

    ctx.server:broadcastEvent(AIAnimalInseminationEvent.new(placeable, items), true)
    return true, true, nil
end
