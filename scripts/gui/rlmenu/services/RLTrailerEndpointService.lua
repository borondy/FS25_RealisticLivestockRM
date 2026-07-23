--[[
    RLTrailerEndpointService.lua
    Read-only query service: reads a base-game livestock trailer as an
    animal-collection endpoint for the RL Tabbed Menu transfer slices
    (pen / dealer / world).

    Wraps the LivestockTrailer getters into plain shapes - numbers, booleans,
    strings, and live Animal-ref arrays - that every later slice consumes.
    Stateless module table, no .new; the trailer is passed in as a parameter, so
    nothing reaches g_*, GUI, or XML at load OR call time (project-context Rule
    A/C) - that is what makes the primitives dual-runnable against a mock trailer.

    Contract (each primitive is nil-safe and returns the per-row default rather
    than crashing - see the spec I/O matrix):
      * getContents(trailer)                              -> array of live Animal refs (engine order)
      * getCurrentType(trailer)                           -> animal-type table | nil  (lock concept)
      * supportsType(trailer, typeIndex)                  -> boolean                  (structural support)
      * trailerHasFreeSlot(trailer, subTypeIndex, queued) -> boolean                  (free > queued)
      * getDisplayData(trailer)                           -> { name, used, total }
      * isEmpty(trailer) / isFull(trailer)                -> boolean
      * hasRoom(freeSlots, alreadyQueued)                 -> boolean                  (pure predicate, shared with M2+)

    Structural support (getSupportsAnimalType) and the current-load lock
    (getCurrentAnimalType) are kept as two DISTINCT concepts: a trailer can
    structurally support a type it is not currently locked to. The fit predicate
    mirrors legacy applySourceBulk exactly (reject when free <= queued).

    Transfer keystone: trailer-scoped, no GUI / events /
    routing, zero behavior change. Loaded by main.lua but invoked by no shipped
    path until the M2 transfer frame consumes it.
    Mirrors the pcall-per-getter + level-logging house pattern of
    RLAnimalInfoService.getHusbandryDisplay.
]]

RLTrailerEndpointService = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Internal helper
-- =============================================================================

--- Call a single engine getter on the trailer under pcall, mirroring the
--- per-getter guard in RLAnimalInfoService.getHusbandryDisplay. Returns
--- `(true, value)` on a clean call and `(false, nil)` when the trailer is nil,
--- the method is absent or not callable, or the call itself errors. The caller
--- type-checks `value` and maps to its own default - one malformed getter never
--- propagates a crash through the service.
--- @param trailer table|nil
--- @param methodName string
--- @param arg any|nil  single optional argument (every wrapped getter takes 0 or 1)
--- @return boolean ok, any value
local function callGetter(trailer, methodName, arg)
    if trailer == nil or type(trailer[methodName]) ~= "function" then
        return false, nil
    end
    local ok, result = pcall(trailer[methodName], trailer, arg)
    if not ok then
        return false, nil
    end
    return true, result
end

-- =============================================================================
-- Pure predicate (shared with the M2+ husbandry side)
-- =============================================================================

--- Capacity predicate: room exists when free slots strictly exceed the
--- already-queued running count. The operator is `>` (NOT `>=`): legacy
--- AnimalScreenTrailerFarm:applySourceBulk rejects when `free <= queued`, so the
--- slot a queued item will occupy is not offered to the next item. Endpoint-agnostic
--- by design - the pen (husbandry) side reuses this with its own free-slot read.
--- @param freeSlots number
--- @param alreadyQueued number
--- @return boolean room
function RLTrailerEndpointService.hasRoom(freeSlots, alreadyQueued)
    return (freeSlots or 0) > (alreadyQueued or 0)
end

-- =============================================================================
-- Read-only primitives
-- =============================================================================

--- The trailer's live contents as an array of Animal refs in engine order.
--- In RLRM each element of `getClusters()` IS a live Animal (legacy wraps each
--- straight into AnimalItemStock); the M2+ mutation events need those raw refs,
--- so this does not project to a display descriptor. Consumers must NOT assume
--- positional stability across reads.
--- @param trailer table|nil
--- @return table animals  array of Animal refs ({} when empty / unreadable)
function RLTrailerEndpointService.getContents(trailer)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.getContents: nil trailer -> {}")
        return {}
    end

    local ok, clusters = callGetter(trailer, "getClusters")
    if not ok then
        Log:warning("RLTrailerEndpointService.getContents: getClusters missing/errored -> {}")
        return {}
    end
    if type(clusters) ~= "table" then
        Log:trace("RLTrailerEndpointService.getContents: no clusters -> {}")
        return {}
    end

    local contents = {}
    for _, animal in ipairs(clusters) do
        contents[#contents + 1] = animal
    end
    Log:trace("RLTrailerEndpointService.getContents: %d animal(s)", #contents)
    return contents
end

--- The trailer's current-load type lock, or nil when empty / unlocked. This is
--- the LOCK concept (what is aboard now), distinct from structural support
--- (supportsType). The lock follows the type of the first loaded cluster.
--- @param trailer table|nil
--- @return table|nil animalType  type table (`.typeIndex` guaranteed) or nil
function RLTrailerEndpointService.getCurrentType(trailer)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.getCurrentType: nil trailer -> nil")
        return nil
    end

    local ok, animalType = callGetter(trailer, "getCurrentAnimalType")
    if not ok then
        Log:warning("RLTrailerEndpointService.getCurrentType: getCurrentAnimalType missing/errored -> nil")
        return nil
    end
    if animalType == nil then
        Log:trace("RLTrailerEndpointService.getCurrentType: empty/unlocked -> nil")
        return nil
    end
    if type(animalType) ~= "table" or animalType.typeIndex == nil then
        Log:warning("RLTrailerEndpointService.getCurrentType: malformed type table (no .typeIndex) -> nil")
        return nil
    end

    Log:debug("RLTrailerEndpointService.getCurrentType: locked to typeIndex=%s", tostring(animalType.typeIndex))
    return animalType
end

--- Whether the trailer STRUCTURALLY supports a type (its store config has a
--- place for it), independent of what is currently aboard. Support != lock: a
--- multi-capable empty trailer supports several types; once loaded it stays
--- structurally supporting them all while getCurrentType locks to one.
--- @param trailer table|nil
--- @param typeIndex number
--- @return boolean supported
function RLTrailerEndpointService.supportsType(trailer, typeIndex)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.supportsType: nil trailer -> false")
        return false
    end

    local ok, supported = callGetter(trailer, "getSupportsAnimalType", typeIndex)
    if not ok or type(supported) ~= "boolean" then
        Log:warning("RLTrailerEndpointService.supportsType: malformed trailer/result (typeIndex=%s) -> false",
            tostring(typeIndex))
        return false
    end
    Log:trace("RLTrailerEndpointService.supportsType: typeIndex=%s -> %s", tostring(typeIndex), tostring(supported))
    return supported
end

--- Whether a subtype can still be added given a running queued count. Wraps
--- `getNumOfFreeAnimalSlots(subTypeIndex)` (the trailer returns a number - 0 for
--- an unsupported subtype, never nil) through the pure hasRoom predicate, so
--- this is exact legacy applySourceBulk parity. `alreadyQueued` is the
--- cumulative-ledger hook the M3 mutation slice drives per subtype.
--- @param trailer table|nil
--- @param subTypeIndex number
--- @param alreadyQueued number|nil  running count already committed this transfer (default 0)
--- @return boolean hasRoom
function RLTrailerEndpointService.trailerHasFreeSlot(trailer, subTypeIndex, alreadyQueued)
    alreadyQueued = alreadyQueued or 0

    if trailer == nil then
        Log:trace("RLTrailerEndpointService.trailerHasFreeSlot: nil trailer -> false")
        return false
    end

    local ok, freeSlots = callGetter(trailer, "getNumOfFreeAnimalSlots", subTypeIndex)
    if not ok or type(freeSlots) ~= "number" then
        Log:warning("RLTrailerEndpointService.trailerHasFreeSlot: malformed trailer/result (subTypeIndex=%s) -> false",
            tostring(subTypeIndex))
        return false
    end

    local room = RLTrailerEndpointService.hasRoom(freeSlots, alreadyQueued)
    Log:debug("RLTrailerEndpointService.trailerHasFreeSlot: subTypeIndex=%s free=%d queued=%d -> %s",
        tostring(subTypeIndex), freeSlots, alreadyQueued, tostring(room))
    return room
end

--- Display payload for a trailer row: name plus the used / total slot counts.
--- `total` is `getMaxNumOfAnimals(getCurrentType())`, which is the engine truth
--- of 0 for an empty / unlocked trailer (capacity is per-type and there is no
--- single global slot count) - NOT a bug; how an empty trailer renders is the
--- frame's call.
--- @param trailer table|nil
--- @return table display  { name = string, used = number, total = number }
function RLTrailerEndpointService.getDisplayData(trailer)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.getDisplayData: nil trailer -> defaults")
        return { name = "", used = 0, total = 0 }
    end

    local name = ""
    local okName, n = callGetter(trailer, "getName")
    if okName and type(n) == "string" then name = n end

    local used = 0
    local okUsed, u = callGetter(trailer, "getNumOfAnimals")
    if okUsed and type(u) == "number" then used = u end

    -- total is keyed to the current lock; getMaxNumOfAnimals(nil) is 0 when unlocked.
    local total = 0
    local currentType = RLTrailerEndpointService.getCurrentType(trailer)
    local okTotal, t = callGetter(trailer, "getMaxNumOfAnimals", currentType)
    if okTotal and type(t) == "number" then total = t end

    Log:trace("RLTrailerEndpointService.getDisplayData: name='%s' used=%d total=%d", name, used, total)
    return { name = name, used = used, total = total }
end

--- Whether the trailer holds zero animals. A nil / unreadable trailer reads as
--- empty (the safe default for callers gating on contents).
--- @param trailer table|nil
--- @return boolean empty
function RLTrailerEndpointService.isEmpty(trailer)
    local ok, used = callGetter(trailer, "getNumOfAnimals")
    if not ok or type(used) ~= "number" then
        Log:trace("RLTrailerEndpointService.isEmpty: invalid trailer -> true")
        return true
    end
    return used == 0
end

--- Whether the trailer is at capacity for its current load. An empty / unlocked
--- trailer is never full (no current type to measure against). For the locked
--- type, free = total - used, so `free <= 0` is exactly `used >= total`; this
--- computes the same result as `getNumOfFreeAnimalSlots(currentSubType) <= 0`
--- without needing a current-subtype handle (which would require reaching the
--- animalSystem this service deliberately never touches).
--- @param trailer table|nil
--- @return boolean full
function RLTrailerEndpointService.isFull(trailer)
    local currentType = RLTrailerEndpointService.getCurrentType(trailer)
    if currentType == nil then
        Log:trace("RLTrailerEndpointService.isFull: empty/unlocked -> false")
        return false
    end

    local okUsed, used = callGetter(trailer, "getNumOfAnimals")
    local okTotal, total = callGetter(trailer, "getMaxNumOfAnimals", currentType)
    if not okUsed or type(used) ~= "number" or not okTotal or type(total) ~= "number" then
        Log:warning("RLTrailerEndpointService.isFull: invalid trailer -> false")
        return false
    end

    local full = used >= total
    Log:debug("RLTrailerEndpointService.isFull: used=%d total=%d -> %s", used, total, tostring(full))
    return full
end
