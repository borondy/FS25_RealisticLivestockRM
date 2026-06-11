-- RLHerdsmanMessages.lua
-- M-Tick T5 (RLRM-408) - the player-notification readout for the new rule-driven herdsman
-- day-tick. T3 (RLHerdsmanExecutor.executeActions) applies the planned mutations and returns a
-- per-action summary.results but, by decision 1a, emits NO notifications. Legacy
-- AIAnimalManager:onDayChanged surfaced every executed/marked op as an AI_MANAGER_* message via
-- husbandry:addRLMessage + one AIBulkMessageEvent broadcast per husbandry. This module restores
-- that readout (the SAME AI_MANAGER_* ids + args legacy used, per executed/marked op), driven off
-- summary.results instead of re-deriving it. Parity is on the id/args mapping, NOT a byte-identical
-- wire order: intra-husbandry message order follows PLAN order, and the new multi-rule model can
-- emit more than one message per husbandry per op where legacy (one settings block) emitted one -
-- both intended; summary mode folds the duplicates into the daily summary.
--
-- Two halves, split on the dual-run seam (the SAME split T3/T4 use):
--   * buildMessages(results, formatMoney) is PURE (data in / data out): it maps each result row
--     to the SAME AI_MANAGER_* id(s) + args legacy used, with NO g_* reads, NO mutation of the
--     input, and NO logging (logging is emit's job - M1). It takes an injected formatMoney closure
--     so the money formatting is testable without g_i18n, and returns { records, skips } so emit
--     can both emit the records and log every dropped row.
--   * emit(summary, ctx) is the thin in-game wiring: it reads g_i18n (to build the real
--     formatMoney closure) + g_server, groups the records by husbandry in first-seen order,
--     resolves each placeable via ctx.husbandryPlaceablesById (the SAME handle T3 dispatched its
--     events against), drives the dual sink (server-local addRLMessage PLUS one AIBulkMessageEvent
--     broadcast per husbandry), and logs every emission decision + skip cause.
--
-- Parity anchors: AIAnimalManager:onDayChanged - its per-operation emission legs (the SELL / BUY /
-- CASTRATE / NAMING / AI sections) each do `husbandry:addRLMessage(id, nil, args)` for the local
-- sink AND `table.insert(messages, { id = id, args = args })` for the wire, then fire ONE
-- `g_server:broadcastEvent(AIBulkMessageEvent.new(husbandry, messages))` per husbandry at the end.
-- That broadcast passes NO sendLocal arg (see Server:broadcastEvent): the host's own copy comes
-- from the local addRLMessage, so omitting sendLocal prevents a host double-emit. The wire messages
-- list is the per-op {id, args} records ALWAYS, independent of summary mode (the aggregator decision
-- affects only the local sink on each side, never what goes on the wire).
--
-- Summary mode (decision 1b): every message goes through placeable:addRLMessage so the aggregator
-- decides individual-vs-summary. RLMessageAggregator is extended (separately) so castrate / named /
-- inseminated / mark also aggregate into new daily-summary categories (sold / bought already did).
-- This module is unaware of the mode - it always calls addRLMessage; the aggregator owns the fork.
--
-- Server-only: emit is called from RLHerdsmanDayTick.run, which already returns when g_server is
-- nil, so emit runs server-side only. The broadcast is additionally guarded on g_server.netIsRunning
-- (SP has no network, so SP emits the server-local message only - no broadcast).

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanMessages = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every message log line (emit's emission / skip / broadcast rows are the
--- verification surface; the mutation-parity trace lives in the executor's [executeActions] rows).
local LOG_PREFIX = "[herdsmanMessages]"

--- operation -> the AI_MANAGER_* id families legacy emits. `exec` is the executed-op family (and,
--- for sell/buy, carries the money amount field name); `mark` is the mark-mode family (count-only;
--- nil for buy/naming, which have no mark family - T3 never sets mark on them, but a corrupt row
--- that does is WARNed + skipped before the id lookup). Mirrors AIAnimalManager:onDayChanged exactly.
local ID_FAMILY = {
    sell = {
        exec = { single = "AI_MANAGER_SOLD_SINGLE",   multiple = "AI_MANAGER_SOLD_MULTIPLE",   amountField = "amountGained" },
        mark = { single = "AI_MANAGER_MARK_SELL_SINGLE", multiple = "AI_MANAGER_MARK_SELL_MULTIPLE" },
    },
    buy = {
        exec = { single = "AI_MANAGER_BOUGHT_SINGLE", multiple = "AI_MANAGER_BOUGHT_MULTIPLE", amountField = "amountSpent" },
        mark = nil,
    },
    castrate = {
        exec = { single = "AI_MANAGER_CASTRATED_SINGLE",      multiple = "AI_MANAGER_CASTRATED_MULTIPLE" },
        mark = { single = "AI_MANAGER_MARK_CASTRATE_SINGLE",  multiple = "AI_MANAGER_MARK_CASTRATE_MULTIPLE" },
    },
    naming = {
        exec = { single = "AI_MANAGER_NAMED_SINGLE", multiple = "AI_MANAGER_NAMED_MULTIPLE" },
        mark = nil,
    },
    ai = {
        exec = { single = "AI_MANAGER_INSEMINATED_SINGLE",      multiple = "AI_MANAGER_INSEMINATED_MULTIPLE" },
        mark = { single = "AI_MANAGER_MARK_INSEMINATED_SINGLE", multiple = "AI_MANAGER_MARK_INSEMINATED_MULTIPLE" },
    },
}

-- =============================================================================
-- Internal helpers (pure)
-- =============================================================================

--- Finite-number guard: rejects nil / non-number / NaN / +-inf. Mirrors the executor's guard
--- (@see RLHerdsmanExecutor isFiniteNumber); used to fail-soft on a corrupt money amount (format 0).
---@param v any
---@return boolean
local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Shallow-copy an args array. emit hands the LOCAL sink its own copy because in INDIVIDUAL mode
--- placeable:addRLMessage forwards to PlaceableHusbandryAnimals:addRLMessageDirect, which
--- tostring-coerces its args IN PLACE; the wire record must keep the pristine args (count as a
--- NUMBER, legacy parity), so the two sinks must never share one table - exactly as
--- AIAnimalManager:onDayChanged builds two separate arg literals per op. (In SUMMARY mode the
--- aggregator buckets the message and never calls addRLMessageDirect, so the copy is a harmless
--- no-op there; the copy is load-bearing only on the individual-mode path.)
---@param args table
---@return table
local function copyArgs(args)
    local out = {}
    for i = 1, #args do out[i] = args[i] end
    return out
end

-- Exposed for the dual-run suite (test the predicate's helpers in isolation if needed).
RLHerdsmanMessages._isFiniteNumber = isFiniteNumber
RLHerdsmanMessages._copyArgs       = copyArgs
RLHerdsmanMessages.ID_FAMILY       = ID_FAMILY

-- =============================================================================
-- Pure builder (data in / data out - no g_*, no logging, no input mutation)
-- =============================================================================

--- Map T3's summary.results rows to the legacy AI_MANAGER_* message records (in plan order).
--- PURE: reads only `results` + the injected `formatMoney`, mutates nothing, logs nothing. emit
--- consumes the return: `records` are emitted (and logged) in order; `skips` are logged by emit so
--- a dropped row is never silent. Each record carries the emission payload (husbandryId, id, args)
--- plus diagnostics (mark, count, warn) that emit logs but never puts on the wire / sink.
---
--- Predicate per row (mark precedence is load-bearing):
---   1. no husbandryId            -> skip (nowhere to emit; defensive - T3 always sets it)
---   2. unmapped / nil operation  -> skip (no nil-index)
---   3. mark == true              -> the MARK id family (subsumes T3's skipReason="mark-mode"
---                                   rows, which carry mark=true, before any skip check); a mark
---                                   on buy/naming (no mark family) -> skip
---   4. elseif dispatched == true -> the EXEC id family
---   5. else                      -> genuine skip (no record)
--- then count-normalize: n = tonumber(count); nil/non-number or n < 1 -> skip; floor(n) == 1 ->
--- _SINGLE else _MULTIPLE. Args: sell/buy exec carry money (SINGLE {money}, MULTIPLE {count,money});
--- all others SINGLE {}, MULTIPLE {count}; count is a NUMBER (legacy parity).
---@param results table|nil T3 summary.results (array of executor result rows)
---@param formatMoney fun(amount:number):string injected money formatter (g_i18n:formatMoney closure)
---@return table built { records = {{husbandryId,id,args,mark,count,warn}, ...}, skips = {{row,reason,level}, ...} }
function RLHerdsmanMessages.buildMessages(results, formatMoney)
    local records, skips = {}, {}

    local function addSkip(row, reason, level)
        skips[#skips + 1] = { row = row, reason = reason, level = level }
    end

    for _, row in ipairs(results or {}) do
        local op = row.operation
        local family = op ~= nil and ID_FAMILY[op] or nil

        if row.husbandryId == nil then
            -- Nowhere to emit (a nil group key would also crash emit's grouping). Defensive: T3
            -- always copies action.husbandryId onto the row.
            addSkip(row, "no-husbandryId", "warn")
        elseif family == nil then
            -- Unmapped / nil operation: WARN + skip rather than nil-index ID_FAMILY[op].
            addSkip(row, "unmapped-operation:" .. tostring(op), "warn")
        else
            local mark = row.mark == true
            local idSet, isMoney

            if mark then
                if family.mark == nil then
                    -- mark on buy/naming: contract violation (T3 never sets it) - WARN + skip
                    -- BEFORE the id lookup so there is no nil-index.
                    addSkip(row, "mark-on-no-mark-op:" .. tostring(op), "warn")
                else
                    idSet, isMoney = family.mark, false
                end
            elseif row.dispatched == true then
                idSet, isMoney = family.exec, (family.exec.amountField ~= nil)
            else
                -- Genuine skip (dispatched=false, mark~=true): no message. Carries T3's skipReason
                -- (no-space / no-money / missing-placeable / bad-data). Expected, so DEBUG.
                addSkip(row, "genuine-skip:" .. tostring(row.skipReason), "debug")
            end

            if idSet ~= nil then
                local n = tonumber(row.count)
                if n == nil then
                    addSkip(row, "count-not-a-number:" .. tostring(row.count), "warn")
                elseif n < 1 then
                    -- 0 / negative count: nothing to report. Expected-ish, so DEBUG.
                    addSkip(row, "count-below-one:" .. tostring(row.count), "debug")
                else
                    local count = math.floor(n)         -- fractional (corrupt) -> floor; legacy counts are integers
                    local single = count == 1
                    local id = single and idSet.single or idSet.multiple
                    local args, warn

                    if isMoney then
                        local amount = row[family.exec.amountField]
                        local money
                        if isFiniteNumber(amount) then
                            money = formatMoney(amount)
                        else
                            -- Defensive: T3 fail-closes non-finite amounts before dispatch
                            -- (@see RLHerdsmanExecutor._doSell / ._doBuy), so a dispatched sell/buy
                            -- always has a finite amount; format 0 + flag for emit to WARN.
                            money = formatMoney(0)
                            warn = "nil/non-number amount on dispatched " .. tostring(op)
                                .. " (husbandry=" .. tostring(row.husbandryId) .. ") - formatted 0"
                        end
                        args = single and { money } or { count, money }
                    else
                        args = single and {} or { count }
                    end

                    records[#records + 1] = {
                        husbandryId = row.husbandryId,
                        id          = id,
                        args        = args,
                        mark        = mark,
                        count       = count,
                        warn        = warn,
                    }
                end
            end
        end
    end

    return { records = records, skips = skips }
end

-- =============================================================================
-- In-game wiring (reads g_* - the only non-dual-run layer)
-- =============================================================================

--- Emit the herdsman day-tick's notifications from T3's summary. Builds the records via the pure
--- buildMessages (with the REAL g_i18n:formatMoney closure - bound to g_i18n so `self` is not
--- dropped), logs every skip, then per husbandry (in first-seen plan order) resolves the placeable
--- and drives the dual sink: the server-local placeable:addRLMessage (so the aggregator decides
--- individual-vs-summary) PLUS one AIBulkMessageEvent broadcast carrying the per-op {id, args}
--- records (guarded #messages > 0 and g_server.netIsRunning, NO sendLocal - parity with
--- AIAnimalManager:onDayChanged's per-husbandry broadcast). Reads no summary fields beyond results;
--- never mutates summary.
---@param summary table|nil T3 executor summary ({ results = {...} })
---@param ctx table executor ctx; only ctx.husbandryPlaceablesById ({ [uniqueId] = placeable }) is read
function RLHerdsmanMessages.emit(summary, ctx)
    local results = (summary ~= nil and summary.results) or {}
    -- Bind to g_i18n so formatMoney keeps its `self` (g_i18n.formatMoney unbound would drop it).
    local formatMoney = function(amount) return g_i18n:formatMoney(amount, 2, true, true) end

    local built = RLHerdsmanMessages.buildMessages(results, formatMoney)
    Log:trace("%s built %d record(s), %d skip(s) from %d result row(s)",
        LOG_PREFIX, #built.records, #built.skips, #results)

    -- Log every dropped row so a missing message is never silent (M1: logging is emit's job).
    for _, skip in ipairs(built.skips) do
        if skip.level == "warn" then
            Log:warning("%s skipped row: %s (rule=%s husbandry=%s op=%s)", LOG_PREFIX, skip.reason,
                tostring(skip.row.ruleId), tostring(skip.row.husbandryId), tostring(skip.row.operation))
        else
            Log:debug("%s skipped row: %s (rule=%s husbandry=%s op=%s)", LOG_PREFIX, skip.reason,
                tostring(skip.row.ruleId), tostring(skip.row.husbandryId), tostring(skip.row.operation))
        end
    end

    -- Group records by husbandryId, preserving first-seen (plan) order - NOT pairs(), which is
    -- nondeterministic; husbandries broadcast in the order their first record appeared.
    local order, groups = {}, {}
    for _, rec in ipairs(built.records) do
        if groups[rec.husbandryId] == nil then
            groups[rec.husbandryId] = {}
            order[#order + 1] = rec.husbandryId
        end
        local g = groups[rec.husbandryId]
        g[#g + 1] = rec
    end

    local placeablesById = (ctx ~= nil and ctx.husbandryPlaceablesById) or {}

    for _, husbandryId in ipairs(order) do
        local recs = groups[husbandryId]
        local placeable = placeablesById[husbandryId]

        if placeable == nil then
            -- The SAME handle T3 dispatched against is absent - skip the husbandry, no broadcast.
            Log:warning("%s husbandry '%s' not in ctx.husbandryPlaceablesById - %d message(s) dropped, no broadcast",
                LOG_PREFIX, tostring(husbandryId), #recs)
        elseif placeable.addRLMessage == nil then
            -- Wrong-type object (lacks the husbandryAnimals spec) - mirror AIBulkMessageEvent:run's guard.
            Log:warning("%s husbandry '%s' placeable lacks addRLMessage (wrong-type object) - %d message(s) dropped, no broadcast",
                LOG_PREFIX, tostring(husbandryId), #recs)
        else
            local wireMessages = {}
            for _, rec in ipairs(recs) do
                -- Local sink gets its OWN args copy (addRLMessageDirect mutates in place); the wire
                -- record keeps the pristine args (count as a NUMBER) - legacy's two-table pattern.
                placeable:addRLMessage(rec.id, nil, copyArgs(rec.args))
                wireMessages[#wireMessages + 1] = { id = rec.id, args = rec.args }

                Log:debug("%s emit husbandry=%s id=%s count=%d mark=%s",
                    LOG_PREFIX, tostring(husbandryId), rec.id, rec.count, tostring(rec.mark))
                if rec.warn ~= nil then
                    Log:warning("%s %s", LOG_PREFIX, rec.warn)
                end
            end

            -- One AIBulkMessageEvent per husbandry (parity AIAnimalManager:onDayChanged). SP has no
            -- network (netIsRunning false) -> server-local sink only, no broadcast.
            local netIsRunning = g_server ~= nil and g_server.netIsRunning == true
            if #wireMessages > 0 and netIsRunning then
                g_server:broadcastEvent(AIBulkMessageEvent.new(placeable, wireMessages))
                Log:debug("%s broadcast husbandry=%s messages=%d netIsRunning=true",
                    LOG_PREFIX, tostring(husbandryId), #wireMessages)
            else
                Log:debug("%s no broadcast husbandry=%s messages=%d netIsRunning=%s",
                    LOG_PREFIX, tostring(husbandryId), #wireMessages, tostring(netIsRunning))
            end
        end
    end
end
