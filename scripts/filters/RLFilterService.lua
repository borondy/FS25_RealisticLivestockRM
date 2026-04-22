-- RLFilterService.lua
-- Singleton CRUD service for saveable filter records (Phase 0 P2).
--
-- Owns the in-memory filter registry `self.filtersById`, assigns stable
-- ids on create via base-game `Utils.getUniqueId`, and handles the XML
-- round-trip into the existing `rm_RlAnimalSystem.xml` save file under
-- the new `<filters>` block. No MP events in this phase -- Create/Update
-- /Delete events arrive in P3 (saveable-filters-plan.md §8).
--
-- Expected lifecycle: `g_rlFilterService = RLFilterService.new()` at
-- `RealisticLivestock.loadMap`, alongside `g_diseaseManager`. The
-- AnimalSystem save/load hooks call `:saveToXMLFile` / `:loadFromXMLFile`
-- with the canonical base key `rm_RlAnimalSystem.filters`.
--
-- Immutability (plan §4.6):
--   * `id`, `farmId`, `version` are frozen after create.
--   * `name`, `animalType`, `expression` are mutable via `update`.
--   * Violations are rejected with `:warning` and leave state unchanged.
--
-- Scope matching (`listAvailable`):
--   * `nil-or-equal` on both `animalType` and `farmId` -- a filter with
--     `farmId = nil` is global and appears for every farm; a filter with
--     `animalType = nil` appears for every animal type.

local Log = RmLogging.getLogger("RLRM")

RLFilterService = {}
local RLFilterService_mt = { __index = RLFilterService }

--- Prefix used by `Utils.getUniqueId` for filter ids. Follows the base-game
--- `UNIQUE_ID_PREFIX` convention (plan §4.7).
RLFilterService.UNIQUE_ID_PREFIX = "rlFilter_"

--- Canonical XML base key for the filters block inside `rm_RlAnimalSystem.xml`.
--- Both the AnimalSystem load hook and save hook MUST reference this constant
--- rather than hardcoding the literal so load/save paths stay in sync across
--- future refactors (plan §4.4 / P2 review P1).
RLFilterService.XML_BASE_KEY = "rm_RlAnimalSystem.filters"

-- =============================================================================
-- Construction
-- =============================================================================

--- Construct a new, empty service instance. There is conceptually one
--- per game session (`g_rlFilterService`), but the constructor is
--- instance-safe so tests can spin up isolated services.
---@return table instance
function RLFilterService.new()
    local self = setmetatable({}, RLFilterService_mt)
    self.filtersById = {}
    Log:debug("RLFilterService.new: fresh instance")
    return self
end

-- =============================================================================
-- CRUD
-- =============================================================================

--- Create a new filter, assigning a unique `id` via `Utils.getUniqueId`
--- with the shared mapping table so collisions are retried. Sets
--- `version = 1` when caller did not supply one.
---
--- Returns the filter record on success (same table, with `id` populated)
--- or nil when the input was nil.
---@param filter table filter record (without id)
---@return table|nil filter the stored record
function RLFilterService:create(filter)
    if filter == nil then
        Log:warning("RLFilterService:create: nil filter; rejecting")
        return nil
    end

    filter.id = Utils.getUniqueId(filter, self.filtersById, RLFilterService.UNIQUE_ID_PREFIX)
    filter.version = filter.version or 1
    self.filtersById[filter.id] = filter

    Log:debug("RLFilterService:create: id=%s name=%s animalType=%s farmId=%s",
        tostring(filter.id), tostring(filter.name),
        tostring(filter.animalType), tostring(filter.farmId))
    return filter
end

--- Look up a filter by id. Returns nil when unknown.
---@param id string
---@return table|nil
function RLFilterService:getById(id)
    local f = self.filtersById[id]
    Log:trace("RLFilterService:getById: id=%s found=%s", tostring(id), tostring(f ~= nil))
    return f
end

--- Apply an update. Mutates only `name`, `animalType`, `expression`.
--- Rejects the call (and logs `:warning`) when id is unknown, when
--- `payload.id ~= id`, or when `payload.farmId` / `payload.version`
--- differ from the stored record -- those fields are immutable
--- post-create (plan §4.6). Returns the new stored record on success.
---@param id string lookup id
---@param payload table whole-object replacement payload
---@return table|nil updated
function RLFilterService:update(id, payload)
    if id == nil or payload == nil then
        Log:warning("RLFilterService:update: nil id or payload; rejecting")
        return nil
    end

    local existing = self.filtersById[id]
    if existing == nil then
        Log:warning("RLFilterService:update: unknown id '%s'; rejecting", tostring(id))
        return nil
    end

    if payload.id ~= id then
        Log:warning("RLFilterService:update: payload.id='%s' does not match lookup id='%s'; rejecting (id is immutable)",
            tostring(payload.id), tostring(id))
        return nil
    end

    if payload.farmId ~= existing.farmId then
        Log:warning("RLFilterService:update: payload.farmId=%s does not match stored farmId=%s; rejecting (farmId is immutable)",
            tostring(payload.farmId), tostring(existing.farmId))
        return nil
    end

    if payload.version ~= existing.version then
        Log:warning("RLFilterService:update: payload.version=%s does not match stored version=%s; rejecting (version is immutable)",
            tostring(payload.version), tostring(existing.version))
        return nil
    end

    -- Completeness guard (P2 review P3): `update` is whole-object replacement
    -- per plan §4.1 (mutable fields = name, animalType, expression). A partial
    -- payload that omits `name` or `expression` would silently nil those fields
    -- and collapse the filter into a nameless, match-everything record on the
    -- next evaluate. `animalType` is allowed to be nil (global-scope filter).
    if payload.name == nil then
        Log:warning("RLFilterService:update: payload.name is nil for id=%s; rejecting (whole-object replacement requires name)",
            tostring(id))
        return nil
    end
    if payload.expression == nil then
        Log:warning("RLFilterService:update: payload.expression is nil for id=%s; rejecting (whole-object replacement requires expression)",
            tostring(id))
        return nil
    end

    local updated = {
        id         = id,
        name       = payload.name,
        animalType = payload.animalType,
        farmId     = existing.farmId,
        expression = payload.expression,
        version    = existing.version,
    }
    self.filtersById[id] = updated

    Log:debug("RLFilterService:update: id=%s applied (name=%s animalType=%s)",
        id, tostring(updated.name), tostring(updated.animalType))
    return updated
end

--- Remove the filter with the given id. Returns true on success,
--- false when the id was unknown (logged at `:warning`).
---@param id string
---@return boolean removed
function RLFilterService:delete(id)
    if id == nil or self.filtersById[id] == nil then
        Log:warning("RLFilterService:delete: unknown id '%s'; no-op", tostring(id))
        return false
    end

    self.filtersById[id] = nil
    Log:debug("RLFilterService:delete: id=%s removed", tostring(id))
    return true
end

-- =============================================================================
-- Queries
-- =============================================================================

--- All stored filters as an array. Order is undefined (Lua `pairs`).
---@return table[] filters
function RLFilterService:list()
    local out = {}
    for _, f in pairs(self.filtersById) do
        table.insert(out, f)
    end
    Log:trace("RLFilterService:list: #=%d", #out)
    return out
end

--- Filters that match the given scope via nil-or-equal rules on both
--- `animalType` and `farmId` (plan §4 overall rule). A filter is
--- "available" for a given call when:
---   * filter.animalType is nil (any type) OR equals the passed type
---   * filter.farmId     is nil (global)   OR equals the passed farmId
---
--- Passing nil for a scope parameter means "I don't care" for that axis.
---@param animalType integer|nil AnimalType int index to match against
---@param farmId integer|nil farm id to match against
---@return table[] filters
function RLFilterService:listAvailable(animalType, farmId)
    local out = {}
    for _, f in pairs(self.filtersById) do
        local typeMatch = f.animalType == nil or animalType == nil or f.animalType == animalType
        local farmMatch = f.farmId == nil or farmId == nil or f.farmId == farmId
        if typeMatch and farmMatch then
            table.insert(out, f)
        end
    end
    Log:trace("RLFilterService:listAvailable: animalType=%s farmId=%s #=%d",
        tostring(animalType), tostring(farmId), #out)
    return out
end

--- Empty the registry. Called explicitly by `loadFromXMLFile` before
--- reading so successive save loads in the same process cannot leak
--- state across games (plan §8 P0 exit criterion).
function RLFilterService:clear()
    self.filtersById = {}
    Log:debug("RLFilterService:clear: state emptied")
end

-- =============================================================================
-- XML IO
-- =============================================================================

--- Serialize every stored filter under `baseKey` via
--- `RLFilterSerialization.writeFilter`. No-op when xmlFile is nil
--- (defensive; the AnimalSystem hook already guards).
---
--- Filters are sorted by id before writing so the on-disk key order
--- (`filter(0)`, `filter(1)`, ...) is deterministic across save cycles
--- (P2 review P8). Matches the sorted-iteration pattern used elsewhere
--- in the surrounding AnimalSystem save code.
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `"rm_RlAnimalSystem.filters"`
function RLFilterService:saveToXMLFile(xmlFile, baseKey)
    if xmlFile == nil then
        Log:warning("RLFilterService:saveToXMLFile: nil xmlFile; skipping")
        return
    end

    local filters = self:list()
    table.sort(filters, function(a, b) return tostring(a.id) < tostring(b.id) end)

    for i, f in ipairs(filters) do
        local filterKey = string.format("%s.filter(%d)", baseKey, i - 1)
        RLFilterSerialization.writeFilter(xmlFile, filterKey, f)
    end

    Log:debug("RLFilterService:saveToXMLFile: baseKey=%s wrote=%d filters (sorted by id)", baseKey, #filters)
end

--- Clear existing state then deserialize every filter under `baseKey`
--- via `RLFilterSerialization.readFilter`. Filters missing their id
--- are skipped (the serializer logs the warning).
---
--- Iterate is wrapped in `pcall` (P2 review P7): a malformed filter that
--- crashes deep inside the serializer must not propagate out and abort
--- the surrounding `AnimalSystem:loadFromXMLFile`. Partial state is
--- preserved; the warning surfaces the specific failure.
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `"rm_RlAnimalSystem.filters"`
function RLFilterService:loadFromXMLFile(xmlFile, baseKey)
    if xmlFile == nil then
        Log:warning("RLFilterService:loadFromXMLFile: nil xmlFile; skipping")
        return
    end

    self:clear()
    local loaded = 0

    local ok, err = pcall(function()
        xmlFile:iterate(baseKey .. ".filter", function(_, filterKey)
            local f = RLFilterSerialization.readFilter(xmlFile, filterKey)
            if f ~= nil then
                self.filtersById[f.id] = f
                loaded = loaded + 1
            end
        end)
    end)

    if not ok then
        Log:warning("RLFilterService:loadFromXMLFile: iterate errored after %d filters loaded; keeping partial state (%s)",
            loaded, tostring(err))
    end

    Log:debug("RLFilterService:loadFromXMLFile: baseKey=%s loaded=%d filters", baseKey, loaded)
end

Log:trace("RLFilterService: loaded")
