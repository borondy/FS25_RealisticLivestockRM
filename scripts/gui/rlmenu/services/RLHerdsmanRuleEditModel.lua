-- RLHerdsmanRuleEditModel.lua
-- Pure edit-state model for the Herdsman rule detail pane (M-Frame F4b, RLRM-385).
--
-- The two pure edit-transition functions the detail pane needs, extracted OUT of the
-- frame (Codex F4b triage C2) so they are dual-run rather than inline-and-untested:
--   * overlayRule(stored, pending)               -> merged whole-record for live render + the flush payload
--   * reshapeParamsForOperation(currentParams, op) -> reshaped params when the operation changes
--
-- PURITY CONTRACT (hard, like RLHerdsmanRulePresenter):
--   * Plain data in / plain data out: tables / strings / booleans.
--   * ZERO g_* globals, ZERO element refs, ZERO setText/setVisible/SmoothList, ZERO XML.
--   * The ONE sibling dep is RLHerdsmanRulePresenter (pure) for the per-operation default
--     params - the single source of truth, never duplicated here.
--
-- Mirrors RLHerdsmanRulePresenter's SHAPE (top-level table, module-local Log, module
-- constants, LuaDoc + logging on every function). 100% dual-run: in-game
-- RLHerdsmanRuleEditModelTests + headless herdsman_rule_editmodel_suite.lua.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleEditModel = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Sentinel an overlay field can carry to mean "set the merged field to nil". A sparse
--- pending table cannot otherwise distinguish "no override (keep stored)" from "clear to
--- nil": an absent key is the former, this sentinel is the latter. F4b's only user is the
--- D5 op-change filterId clear (`pending.filterId = RLHerdsmanRuleEditModel.CLEAR`). A
--- unique table so it can never collide with a real field value.
RLHerdsmanRuleEditModel.CLEAR = {}

--- The whole-record fields an overlay may replace. Immutable identity (id/farmId/version)
--- is intentionally absent - the service re-pins those on update, and the frame never
--- edits them. `params` is replaced WHOLESALE (the frame keeps pending.params complete),
--- never shallow-merged, so a buy rule's nested budget never loses siblings.
local OVERLAY_FIELDS = { "name", "operation", "enabled", "filterId", "params", "targetHusbandries" }

--- Cross-operation scalar params that may carry over an operation change. Op-specific
--- params (buy's nested `budget`, naming `convention`, ai `semen`) are NEVER carried -
--- they take the new operation's defaults (budget reshaped wholesale).
local CARRY_OVER_FIELDS = { "maxAnimals", "mark" }

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Deep-copy a plain-data value (tables recursively via pairs(), scalars as-is) so the
--- merged record / reshaped params never alias the caller's `stored` or `pending` (the
--- live render must not mutate the cached stored record). Assumes acyclic plain data -
--- rule records are; no metatables are preserved.
---@param value any
---@return any copy
local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deepCopy(v)
    end
    return out
end

-- =============================================================================
-- Overlay (live render + flush payload)
-- =============================================================================

--- Overlay a sparse `pending` edit table onto a `stored` rule record, returning a NEW
--- merged whole-record for the live list/detail render AND the flush payload. The result
--- is a deep copy - it never aliases `stored` or `pending`, so rendering the overlay can
--- never mutate the cached stored record. Each `OVERLAY_FIELDS` entry present in `pending`
--- replaces the stored value (deep-copied); a field set to `CLEAR` maps to nil (the only
--- way a sparse overlay can remove a field - F4b's D5 filterId clear). `params` is taken
--- wholesale from `pending.params` when present (never shallow-merged), so nested budget
--- siblings survive. nil / non-table `pending` -> a deep copy of `stored` unchanged.
---@param stored table the stored rule record
---@param pending table|nil sparse field overrides; a field == CLEAR nils it
---@return table merged deep-copied merged record
function RLHerdsmanRuleEditModel.overlayRule(stored, pending)
    local merged = deepCopy(stored)
    if type(pending) ~= "table" then
        Log:trace("RLHerdsmanRuleEditModel.overlayRule: no pending for id=%s -> stored copy",
            tostring(type(stored) == "table" and stored.id or nil))
        return merged
    end

    local applied = {}
    for _, field in ipairs(OVERLAY_FIELDS) do
        local v = pending[field]
        if v == RLHerdsmanRuleEditModel.CLEAR then
            merged[field] = nil
            applied[#applied + 1] = field .. "=nil"
        elseif v ~= nil then
            merged[field] = deepCopy(v)
            applied[#applied + 1] = field
        end
    end

    Log:trace("RLHerdsmanRuleEditModel.overlayRule: id=%s applied=[%s]",
        tostring(type(stored) == "table" and stored.id or nil), table.concat(applied, ","))
    return merged
end

-- =============================================================================
-- Operation-change param reshape (carry-over)
-- =============================================================================

--- Reshape `currentParams` for a new operation: start from the operation's fresh defaults
--- (`RLHerdsmanRulePresenter.defaultParamsForOperation` - the single source of truth) and
--- carry over each cross-operation scalar field (maxAnimals, mark) that BOTH the new
--- operation uses (present in its defaults) AND the current params carried, preserving the
--- user's value across the switch. Op-specific params (buy's nested budget, naming
--- convention, ai semen) are NOT carried - they take the new defaults (budget reshaped
--- wholesale). The result is a complete, fresh params table (safe to mutate; never aliases
--- the defaults or `currentParams`). An unknown `newOperation` yields the presenter's empty
--- table + its one-shot warning. Carried values are passed through as-is; out-of-domain
--- values are caught at flush time by validateParams, not here.
---@param currentParams table|nil the params before the operation change
---@param newOperation any the operation being switched to
---@return table params complete reshaped params for newOperation
function RLHerdsmanRuleEditModel.reshapeParamsForOperation(currentParams, newOperation)
    local reshaped = RLHerdsmanRulePresenter.defaultParamsForOperation(newOperation)
    local carried = {}
    if type(currentParams) == "table" then
        for _, field in ipairs(CARRY_OVER_FIELDS) do
            if reshaped[field] ~= nil and currentParams[field] ~= nil then
                reshaped[field] = currentParams[field]
                carried[#carried + 1] = field
            end
        end
    end

    Log:trace("RLHerdsmanRuleEditModel.reshapeParamsForOperation: newOp=%s carried=[%s]",
        tostring(newOperation), table.concat(carried, ","))
    return reshaped
end

-- =============================================================================
-- Duplicate (F7 lifecycle)
-- =============================================================================

--- Deep-clone a STORED rule record into a fresh create-ready duplicate: a new name plus the
--- source's content - operation / enabled / filterId carried as-is; `targetHusbandries`
--- array-copied; `params` deep-copied; the source's immutable `farmId` carried. No id /
--- version - the service assigns the id and defaults the version on create. A dangling source
--- filterId is carried as-is (the clone is inert until repaired, same as the source). Pure:
--- the result never aliases `source` (mutating the clone never touches the stored record).
---@param source table the stored source rule record
---@param newName string the collision-free duplicate name
---@return table rule a create-ready duplicate record (no id/version)
function RLHerdsmanRuleEditModel.duplicateRule(source, newName)
    local rule = {
        name              = newName,
        operation         = source.operation,
        farmId            = source.farmId,
        enabled           = source.enabled,
        filterId          = source.filterId,
        targetHusbandries = deepCopy(source.targetHusbandries) or {},
        params            = deepCopy(source.params) or {},
    }
    Log:trace("RLHerdsmanRuleEditModel.duplicateRule: source.id=%s newName=%q operation=%s enabled=%s filterId=%s targets=%d",
        tostring(source.id), tostring(newName), tostring(rule.operation), tostring(rule.enabled),
        tostring(rule.filterId), #rule.targetHusbandries)
    return rule
end

Log:debug("RLHerdsmanRuleEditModel: loaded")
