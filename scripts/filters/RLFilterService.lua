-- RLFilterService.lua
-- Singleton CRUD service for saveable filter records (Phase 0 P2 + P3).
--
-- Owns the in-memory filter registry `self.filtersById`, assigns stable
-- ids on create via base-game `Utils.getUniqueId`, and handles the XML
-- round-trip into the `rm_RlSettings.xml` save file under the
-- `<filters>` block.
--
-- Expected lifecycle: `g_rlFilterService = RLFilterService.new()` at
-- `RealisticLivestock.loadMap`, alongside `g_diseaseManager`. The
-- RLSettings save/load hooks call `:saveToXMLFile` / `:loadFromXMLFile`
-- with the canonical base key `rm_RlSettings.filters`.
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
--
-- P3 additions (MP events):
--   * `create`/`update`/`delete` dispatch RLFilter{Create,Update,Delete}Event
--     AFTER the local mutation (Pattern A caller-mutates-first).
--   * Events land back through `applyIncoming{Create,Update,Delete}` which
--     bypass dispatch so `run()` never re-fires another event.
--   * `RLFilterService._send{Create,Update,Delete}Event` are swappable hooks
--     so tests can capture payloads without a real network (mirrors
--     RLMessageService._sendDeleteEvent at [RLMessageService.lua:218]).
--
-- Ownership contract (P2 review carryover, tightened in P3):
--   * Every boundary into/out of the registry performs a defensive deep
--     copy of the filter record (top-level shallow + recursive deep clone
--     of the `expression` AST). Callers cannot mutate stored state by
--     retaining a reference to a returned record. Applies to:
--       - `create`  (clone input before storing)
--       - `getById` (clone stored before returning)
--       - `list` / `listAvailable` (clone each record)
--       - `applyIncoming*` (clone the wire-decoded payload before storing)
--   * Internal calls that need the live reference use `_rawGetById`.

local Log = RmLogging.getLogger("RLRM")

RLFilterService = {}
local RLFilterService_mt = { __index = RLFilterService }

--- Prefix used by `Utils.getUniqueId` for filter ids. Follows the base-game
--- `UNIQUE_ID_PREFIX` convention (plan §4.7).
RLFilterService.UNIQUE_ID_PREFIX = "rlFilter_"

--- Canonical XML base key for the filters block inside `rm_RlSettings.xml`.
--- Both the RLSettings load hook and save hook MUST reference this constant
--- rather than hardcoding the literal so load/save paths stay in sync across
--- future refactors (plan §4.4 / P2 review P1).
RLFilterService.XML_BASE_KEY = "rm_RlSettings.filters"

-- =============================================================================
-- Deep copy (P2 review carryover / P3 ownership hardening)
-- =============================================================================

--- Recursively clone an AST node (`group` or `condition`). Group children
--- are cloned in array order. Condition `value` is shallow-copied when it
--- is a list (`in`/`notin`); scalars are passed by value.
---
--- Group classification: any node with non-nil `op` is treated as a group,
--- with `children = node.children or {}`. Protects against a degenerate
--- `{op="AND", children=nil}` being mis-classified as a condition and
--- silently destroyed (review finding). A bare-condition node (no `op`)
--- falls through to the condition branch.
---@param node any
---@return any clone
local function cloneNode(node)
    if type(node) ~= "table" then return node end

    if node.op ~= nil then
        local children = {}
        for i, child in ipairs(node.children or {}) do
            children[i] = cloneNode(child)
        end
        return { op = node.op, children = children }
    end

    -- condition node
    local value = node.value
    if type(value) == "table" then
        local list = {}
        for i, v in ipairs(value) do list[i] = v end
        value = list
    end
    return { field = node.field, cmp = node.cmp, value = value }
end

--- Shallow-clone the filter's top-level scalars and deep-clone its
--- expression. Matches the P2 review carryover ownership contract.
---@param f table|nil
---@return table|nil clone
local function cloneFilter(f)
    if f == nil then return nil end
    return {
        id         = f.id,
        name       = f.name,
        animalType = f.animalType,
        farmId     = f.farmId,
        version    = f.version,
        expression = cloneNode(f.expression),
    }
end

--- Exposed for tests + event handlers that need to clone wire-decoded payloads.
RLFilterService._cloneFilter = cloneFilter

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
-- Internal raw accessor (no clone)
-- =============================================================================

--- Return the stored record WITHOUT cloning. Internal use only -- callers
--- must not mutate the returned table. Used by the validation paths in
--- `update` / `delete` where a clone would just be thrown away.
---@param id string|nil
---@return table|nil stored
function RLFilterService:_rawGetById(id)
    if id == nil then return nil end
    return self.filtersById[id]
end

-- =============================================================================
-- CRUD
-- =============================================================================

--- Create a new filter, assigning a unique `id` via `Utils.getUniqueId`
--- with the shared mapping table so collisions are retried. Sets
--- `version = 1` when caller did not supply one. The caller's table is
--- not stored; a defensive clone is inserted into the registry instead
--- (P2 review carryover -- callers cannot tamper with stored state by
--- retaining a reference to their input).
---
--- Returns a cloned snapshot of the stored record on success (with `id`
--- populated) or nil when the input was nil.
---
--- P3: after the local mutation, dispatches `RLFilterCreateEvent` via the
--- `_sendCreateEvent` hook so other peers converge. SP / offline paths
--- are safe because the hook itself nil-guards on `g_server` / `g_client`.
---@param filter table filter record (without id)
---@return table|nil filter cloned snapshot of the stored record
function RLFilterService:create(filter)
    if filter == nil then
        Log:warning("RLFilterService:create: nil filter; rejecting")
        return nil
    end

    -- Assign id on the caller's table so `Utils.getUniqueId`'s collision
    -- table semantics work, then clone into the registry.
    filter.id = Utils.getUniqueId(filter, self.filtersById, RLFilterService.UNIQUE_ID_PREFIX)
    filter.version = filter.version or 1

    local stored = cloneFilter(filter)
    self.filtersById[stored.id] = stored

    Log:debug("RLFilterService:create: id=%s name=%s animalType=%s farmId=%s",
        tostring(stored.id), tostring(stored.name),
        tostring(stored.animalType), tostring(stored.farmId))

    -- P3: dispatch the Create event AFTER local mutation (Pattern A).
    RLFilterService._sendCreateEvent(stored)

    return cloneFilter(stored)
end

--- Look up a filter by id. Returns a cloned snapshot of the stored
--- record (P2 review carryover) so callers cannot mutate state via
--- the returned reference.
---@param id string
---@return table|nil
function RLFilterService:getById(id)
    local f = self.filtersById[id]
    Log:trace("RLFilterService:getById: id=%s found=%s", tostring(id), tostring(f ~= nil))
    return cloneFilter(f)
end

--- Apply an update. Mutates only `name`, `animalType`, `expression`.
--- Rejects the call (and logs `:warning`) when id is unknown, when
--- `payload.id ~= id`, or when `payload.farmId` / `payload.version`
--- differ from the stored record -- those fields are immutable
--- post-create (plan §4.6). Returns a cloned snapshot of the new stored
--- record on success.
---
--- P3: after successful local mutation, dispatches `RLFilterUpdateEvent`
--- via the `_sendUpdateEvent` hook.
---@param id string lookup id
---@param payload table whole-object replacement payload
---@return table|nil updated cloned snapshot of the stored record
function RLFilterService:update(id, payload)
    if id == nil or payload == nil then
        Log:warning("RLFilterService:update: nil id or payload; rejecting")
        return nil
    end

    local existing = self:_rawGetById(id)
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

    -- Build the new stored record. `cloneFilter(payload)` handles the
    -- expression deep-clone; immutable fields are re-pinned from the
    -- existing record so even if the payload differed we could not
    -- persist the divergence.
    local stored = cloneFilter(payload)
    stored.id      = id
    stored.farmId  = existing.farmId
    stored.version = existing.version

    self.filtersById[id] = stored

    Log:debug("RLFilterService:update: id=%s applied (name=%s animalType=%s)",
        id, tostring(stored.name), tostring(stored.animalType))

    -- P3: dispatch the Update event AFTER local mutation (Pattern A).
    RLFilterService._sendUpdateEvent(stored)

    return cloneFilter(stored)
end

--- Remove the filter with the given id. Returns true on success,
--- false when the id was unknown (logged at `:warning`).
---
--- P3: after successful local mutation, dispatches `RLFilterDeleteEvent`
--- via the `_sendDeleteEvent` hook.
---@param id string
---@return boolean removed
function RLFilterService:delete(id)
    if id == nil or self:_rawGetById(id) == nil then
        Log:warning("RLFilterService:delete: unknown id '%s'; no-op", tostring(id))
        return false
    end

    self.filtersById[id] = nil
    Log:debug("RLFilterService:delete: id=%s removed", tostring(id))

    -- P3: dispatch the Delete event AFTER local mutation (Pattern A).
    RLFilterService._sendDeleteEvent(id)

    return true
end

-- =============================================================================
-- Queries
-- =============================================================================

--- All stored filters as an array. Order is undefined (Lua `pairs`).
--- Returned records are defensive clones (P2 review carryover) -- callers
--- may freely mutate them without affecting stored state.
---@return table[] filters cloned snapshots
function RLFilterService:list()
    local out = {}
    for _, f in pairs(self.filtersById) do
        table.insert(out, cloneFilter(f))
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
--- Returned records are defensive clones (P2 review carryover).
---@param animalType integer|nil AnimalType int index to match against
---@param farmId integer|nil farm id to match against
---@return table[] filters cloned snapshots
function RLFilterService:listAvailable(animalType, farmId)
    local out = {}
    for _, f in pairs(self.filtersById) do
        local typeMatch = f.animalType == nil or animalType == nil or f.animalType == animalType
        local farmMatch = f.farmId == nil or farmId == nil or f.farmId == farmId
        if typeMatch and farmMatch then
            table.insert(out, cloneFilter(f))
        end
    end
    Log:trace("RLFilterService:listAvailable: animalType=%s farmId=%s #=%d",
        tostring(animalType), tostring(farmId), #out)
    return out
end

-- =============================================================================
-- P3: Incoming-event apply paths
-- =============================================================================
--
-- These methods land wire-decoded payloads into the registry WITHOUT firing
-- another event. Used by RLFilter{Create,Update,Delete}Event:run() after
-- permission + farm-scope + immutability validation (plan §4.10).
--
-- Each method defensive-copies the payload (P2 review carryover) so the
-- event object's reference to the wire-decoded table cannot mutate stored
-- state after apply.
--
-- Contrast with :create / :update / :delete which take a TRUSTED caller
-- path, mutate locally, AND dispatch.

--- Store a wire-decoded filter record received via RLFilterCreateEvent.
--- Server is expected to have validated permission + farm-scope + no-
--- duplicate-id before this is called; client receivers apply blindly
--- because the server's rebroadcast is authoritative.
---@param filter table wire-decoded filter record
---@return boolean applied
function RLFilterService:applyIncomingCreate(filter)
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterService:applyIncomingCreate: malformed payload (id=%s); dropping",
            tostring(filter and filter.id))
        return false
    end

    -- Review finding (P5): surface silent-clobber. Server-authoritative state
    -- wins, but an unexpected existing record means something is wrong
    -- upstream (id collision, duplicate rebroadcast, state event after create).
    if self.filtersById[filter.id] ~= nil then
        Log:warning("RLFilterService:applyIncomingCreate: id=%s already present locally; overwriting with authoritative payload (possible id collision or duplicate broadcast)",
            tostring(filter.id))
    end

    self.filtersById[filter.id] = cloneFilter(filter)
    Log:debug("RLFilterService:applyIncomingCreate: id=%s name=%s animalType=%s farmId=%s",
        tostring(filter.id), tostring(filter.name),
        tostring(filter.animalType), tostring(filter.farmId))
    return true
end

--- Replace a stored record with the wire-decoded payload (whole-object
--- replace per plan §4.6). Server has already enforced immutability on
--- id/farmId/version; client receivers trust the rebroadcast.
---@param filter table wire-decoded filter record
---@return boolean applied
function RLFilterService:applyIncomingUpdate(filter)
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterService:applyIncomingUpdate: malformed payload (id=%s); dropping",
            tostring(filter and filter.id))
        return false
    end

    -- Review finding (P5): surface update-acting-as-upsert. Server logic
    -- rejects updates on unknown ids, so a client applying one means the
    -- client missed the original create. Audible in logs.
    if self.filtersById[filter.id] == nil then
        Log:warning("RLFilterService:applyIncomingUpdate: id=%s unknown locally; acting as upsert (possible missed create)",
            tostring(filter.id))
    end

    self.filtersById[filter.id] = cloneFilter(filter)
    Log:debug("RLFilterService:applyIncomingUpdate: id=%s name=%s",
        tostring(filter.id), tostring(filter.name))
    return true
end

--- Remove a record in response to RLFilterDeleteEvent. No-op when the id
--- is unknown (logged at `:trace` since the server already authoritatively
--- validated; an unknown id here just means the client never had it).
---@param id string
---@return boolean applied
function RLFilterService:applyIncomingDelete(id)
    if id == nil or id == "" then
        Log:warning("RLFilterService:applyIncomingDelete: nil/empty id; dropping")
        return false
    end

    if self.filtersById[id] == nil then
        Log:trace("RLFilterService:applyIncomingDelete: id=%s not present locally (already gone)",
            tostring(id))
        return false
    end

    self.filtersById[id] = nil
    Log:debug("RLFilterService:applyIncomingDelete: id=%s removed", tostring(id))
    return true
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
--- (defensive; the RLSettings caller already guards).
---
--- Filters are sorted by id before writing so the on-disk key order
--- (`filter(0)`, `filter(1)`, ...) is deterministic across save cycles
--- (P2 review P8).
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `"rm_RlSettings.filters"`
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
--- the surrounding `RLSettings.loadFromXMLFile`. Partial state is
--- preserved; the warning surfaces the specific failure.
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `"rm_RlSettings.filters"`
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

-- =============================================================================
-- P3: Dispatch hooks (swappable for tests)
-- =============================================================================
--
-- Production paths fire the corresponding RLFilter{Create,Update,Delete}Event
-- via .sendEvent(). Tests can reassign these fields to capture payloads
-- without requiring a real network. Mirrors RLMessageService._sendDeleteEvent
-- at [RLMessageService.lua:218].
--
-- Nil-guards on the event class so service source-time ordering (service
-- loaded before events in main.lua SECTION 11g) does not crash if a
-- call happens before the events are sourced (e.g. unit tests that only
-- pull in the service).

---@param filter table
RLFilterService._sendCreateEvent = function(filter)
    if RLFilterCreateEvent == nil then
        Log:trace("RLFilterService._sendCreateEvent: RLFilterCreateEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLFilterCreateEvent.sendEvent(filter)
end

---@param filter table
RLFilterService._sendUpdateEvent = function(filter)
    if RLFilterUpdateEvent == nil then
        Log:trace("RLFilterService._sendUpdateEvent: RLFilterUpdateEvent not loaded; no dispatch")
        return
    end
    RLFilterUpdateEvent.sendEvent(filter)
end

---@param id string
RLFilterService._sendDeleteEvent = function(id)
    if RLFilterDeleteEvent == nil then
        Log:trace("RLFilterService._sendDeleteEvent: RLFilterDeleteEvent not loaded; no dispatch")
        return
    end
    RLFilterDeleteEvent.sendEvent(id)
end

-- Eager source-time singleton. The filter save path runs from
-- RLSettings.saveToXMLFile, which can fire on settings changes early in
-- the mission lifecycle (and definitely before AnimalSystem savegame
-- load completes). Constructing the service at source-time means every
-- consumer sees a live registry regardless of the order in which load
-- hooks happen to wire up. The actual on-disk filter LOAD is invoked
-- separately from AnimalSystem:loadFromXMLFile (via
-- RLSettings.loadFiltersFromXMLFile) so AnimalType is populated before
-- RLFilterSerialization resolves animalType=string -> index.
-- main.lua's source order (RmLogging first; utilities, constants,
-- services before consumers) guarantees this line runs before any
-- consumer; RealisticLivestock.loadMap keeps an idempotent fallback so
-- accidental nilling elsewhere can't break filter persistence.
g_rlFilterService = RLFilterService.new()

Log:trace("RLFilterService: loaded")
