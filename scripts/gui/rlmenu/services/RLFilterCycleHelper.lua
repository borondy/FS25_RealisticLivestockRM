-- Saveable-filter cycle + apply helper shared by the four consumer frames
-- (Info / Buy / Sell / Move). Pure table operations; no GUI state.

RLFilterCycleHelper = {}

local Log = RmLogging.getLogger("RLRM")

-- Sentinel returned by applyFilter when an item has no animal handle. Logged
-- once per call so catalog-getter surprises are visible without spam.
local UNWRAP_MISS_TRACE_PREFIX = "RLFilterCycleHelper.applyFilter: item without .animal or .cluster dropped"

--- Return saved filters visible in the caller's scope, sorted alphabetically
--- (case-insensitive) with a stable id tie-break. Wraps the service's nil-or-
--- equal rule for animalType + farmId.
---
---@param animalTypeIndex number|nil AnimalType int to scope-filter; nil = any
---@param farmId number|nil farm id to scope-filter; nil = global
---@return table array of filter clones, alphabetical by name
function RLFilterCycleHelper.getAvailableFilters(animalTypeIndex, farmId)
    if g_rlFilterService == nil then
        Log:warning("RLFilterCycleHelper.getAvailableFilters: g_rlFilterService unavailable")
        return {}
    end

    local result = g_rlFilterService:listAvailable(animalTypeIndex, farmId) or {}

    table.sort(result, function(a, b)
        local an = (a.name or ""):lower()
        local bn = (b.name or ""):lower()
        if an == bn then
            return (a.id or "") < (b.id or "")
        end
        return an < bn
    end)

    Log:trace("RLFilterCycleHelper.getAvailableFilters: animalType=%s farmId=%s count=%d",
        tostring(animalTypeIndex), tostring(farmId), #result)
    return result
end

--- Compute the next filter id for an F-cycle step.
---
--- Cycle: nil -> availableFilters[1].id -> ... -> availableFilters[N].id -> nil -> ...
--- Stale currentId (filter deleted or scope-drifted out) resets to the first id;
--- empty availability returns nil.
---
---@param currentId string|nil
---@param availableFilters table array from getAvailableFilters
---@return string|nil nextId
function RLFilterCycleHelper.cycleFilterId(currentId, availableFilters)
    local count = availableFilters and #availableFilters or 0
    if count == 0 then
        Log:trace("RLFilterCycleHelper.cycleFilterId: empty availability, returning nil")
        return nil
    end

    if currentId == nil then
        Log:trace("RLFilterCycleHelper.cycleFilterId: nil -> %s", tostring(availableFilters[1].id))
        return availableFilters[1].id
    end

    for i, f in ipairs(availableFilters) do
        if f.id == currentId then
            if i == count then
                Log:trace("RLFilterCycleHelper.cycleFilterId: %s (last) -> nil", tostring(currentId))
                return nil
            end
            Log:trace("RLFilterCycleHelper.cycleFilterId: %s -> %s",
                tostring(currentId), tostring(availableFilters[i + 1].id))
            return availableFilters[i + 1].id
        end
    end

    -- currentId not in list: stale id recovery - reset to first
    Log:trace("RLFilterCycleHelper.cycleFilterId: stale currentId=%s, resetting to %s",
        tostring(currentId), tostring(availableFilters[1].id))
    return availableFilters[1].id
end

--- Filter a list of AnimalItemStock wrappers through the evaluator.
--- Unwraps via `item.animal or item.cluster` per the canonical
--- AnimalFilterDialog idiom. Shared ctx dedupes unknown-field warnings.
---
---@param items table array of AnimalItemStock wrappers
---@param filter table|nil filter record (with .expression) or nil to short-circuit
---@return table filtered items (new array)
function RLFilterCycleHelper.applyFilter(items, filter)
    if filter == nil or items == nil or #items == 0 then
        return items
    end
    if RLFilterEvaluator == nil or RLFilterEvaluator.evaluate == nil then
        Log:warning("RLFilterCycleHelper.applyFilter: RLFilterEvaluator unavailable; returning input unchanged")
        return items
    end

    local ctx = { warnedFields = {}, typeMismatchFields = {} }
    local kept = {}
    local dropped = 0
    local unwrapMissLogged = false

    for _, item in ipairs(items) do
        local animal = item.animal or item.cluster
        if animal == nil then
            if not unwrapMissLogged then
                Log:trace("%s (filter.id=%s)", UNWRAP_MISS_TRACE_PREFIX, tostring(filter.id))
                unwrapMissLogged = true
            end
            dropped = dropped + 1
        elseif RLFilterEvaluator.evaluate(filter, animal, ctx) then
            table.insert(kept, item)
        else
            dropped = dropped + 1
        end
    end

    Log:debug("RLFilterCycleHelper.applyFilter: filter=%s in=%d out=%d dropped=%d",
        tostring(filter.id), #items, #kept, dropped)
    return kept
end
