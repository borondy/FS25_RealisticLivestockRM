-- RLHusbandryTargetKey.lua
-- Context-keyed identity for a herdsman rule's husbandry targets across the MP wire.
--
-- A husbandry target is stored as a unique STRING on every machine, but the string's key space
-- depends on the machine's network authority:
--   * server / host / dedi (g_server ~= nil): the placeable's persisted getUniqueId().
--   * a pure client (g_server == nil): tostring(NetworkUtil.getObjectId(placeable)) - the
--     node-object id the engine already transmits per placeable, present the instant
--     readNodeObject resolves the object, identical across machines, unique.
--
-- Why the split: getUniqueId() is a SAVEGAME identifier. The engine streams it to a client ONLY
-- for preplaced placeables; a player-BOUGHT husbandry streams none, so a pure client regenerates a
-- non-matching local uniqueId and a uniqueId-keyed target can never match. The node-object id is
-- the universal cross-machine handle, so a client keys uniformly by it for BOTH barn origins (one
-- key space, no mixed scheme). The wire itself still transports targets ONLY as node-objects
-- (RLHerdsmanRuleWire); this module is the single home for the key<->object mapping at the four
-- boundary sites (the wire read/write, the picker descriptor enumeration, the frame name resolver).
--
-- g_server is a per-machine AUTHORITY constant after load (FS25 has no host migration), so a given
-- machine evaluates keyFor/resolve on the SAME side for read and write - a rule's decoded targets
-- and the picker candidates therefore share one key space, which is what makes the picker pre-check
-- match the decoded targets.

local Log = RmLogging.getLogger("RLRM")

RLHusbandryTargetKey = {}

--- Derive the stable target key for a live husbandry placeable, branched on network authority.
--- Server/host/dedi key by the persisted uniqueId; a pure client keys by the node-object id (the
--- only handle that survives the join stream for a bought barn). Fails CLOSED: returns nil (never a
--- "nil"/"0" string) + :warning when the side-appropriate id is missing, so an unkeyable target is
--- skipped rather than stored under a bogus key.
---@param placeable table|nil a live husbandry placeable (from a readNodeObject decode or the picker enumeration)
---@return string|nil key the uniqueId (server) or net-object-id (client) string, or nil if unkeyable
function RLHusbandryTargetKey.keyFor(placeable)
    if placeable == nil then
        Log:warning("RLHusbandryTargetKey.keyFor: nil placeable; no key")
        return nil
    end

    if g_server ~= nil then
        local uniqueId = placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
        if type(uniqueId) ~= "string" or uniqueId == "" then
            Log:warning("RLHusbandryTargetKey.keyFor: server placeable '%s' has nil/empty uniqueId; skipping target",
                tostring(placeable.getName ~= nil and placeable:getName() or "?"))
            return nil
        end
        Log:trace("RLHusbandryTargetKey.keyFor: server key=%s (uniqueId)", uniqueId)
        return uniqueId
    end

    -- Pure-client keying routes through the g_client node-object registry (NetworkUtil falls to it
    -- when g_server is nil). Fail CLOSED if it is somehow absent rather than indexing a nil global -
    -- symmetric with the server branch's placeableSystem nil-guard in resolve.
    if g_client == nil then
        Log:warning("RLHusbandryTargetKey.keyFor: client context but g_client is nil; cannot key '%s'",
            tostring(placeable.getName ~= nil and placeable:getName() or "?"))
        return nil
    end

    -- Pure client: the net-object-id is the wire-stable handle. nil/0 means unregistered, which can
    -- never round-trip, so skip (never emit "nil"/"0" as a key string).
    local objectId = NetworkUtil.getObjectId(placeable)
    if objectId == nil or objectId == 0 then
        Log:warning("RLHusbandryTargetKey.keyFor: client placeable '%s' has nil/0 net-object-id; skipping target",
            tostring(placeable.getName ~= nil and placeable:getName() or "?"))
        return nil
    end
    local key = tostring(objectId)
    Log:trace("RLHusbandryTargetKey.keyFor: client key=%s (net-object-id)", key)
    return key
end

--- Resolve a stored target key back to its live placeable, branched on network authority. Server/
--- host/dedi look the uniqueId up in the placeable system (no shape gate - a server target key is
--- authored only from live picker candidates); a pure client tonumber-guards the net-id key,
--- resolves it via the node-object registry, then confirms the resolved object has a SHAPE the
--- caller admits (a reused/stale net-id could land on something else). The admitted shape is the
--- ONLY husbandry-vs-EPP gate on the pure-client path: `allowEPP` false keeps it husbandry-only (the
--- rule-TARGETS wire leg, where an EPP must never enter targetHusbandries); `allowEPP` true also
--- admits an EPP-shaped placeable (`spec_extendedProductionPoint ~= nil`) for the move-DESTINATION
--- sites. A MALFORMED key (non-numeric client key, or a resolved shape the caller rejects) is a
--- fail-CLOSED :warning + nil; a key that simply resolves to nothing right now returns nil QUIETLY,
--- so the caller chooses the loudness (a display fallback stays quiet; a flush that drops a target
--- shouts - see RLHerdsmanRuleWire).
---@param key string|nil the stored target key (uniqueId on server, net-object-id on client)
---@param allowEPP boolean|nil admit an EPP-shaped placeable on the pure-client path (move-dest sites only)
---@return table|nil placeable the live placeable, or nil if it does not resolve to an admitted shape
local function resolveInternal(key, allowEPP)
    if type(key) ~= "string" or key == "" then
        return nil
    end

    if g_server ~= nil then
        local mission = g_currentMission
        local ps = mission ~= nil and mission.placeableSystem or nil
        if ps == nil or ps.getPlaceableByUniqueId == nil then
            return nil
        end
        local placeable = ps:getPlaceableByUniqueId(key)
        Log:trace("RLHusbandryTargetKey.resolve: server key=%s allowEPP=%s -> resolved=%s",
            key, tostring(allowEPP == true), tostring(placeable ~= nil))
        return placeable
    end

    -- Pure-client resolve routes through the g_client node-object registry; fail CLOSED if absent
    -- (symmetric with the server branch's placeableSystem nil-guard above).
    if g_client == nil then
        Log:warning("RLHusbandryTargetKey.resolve: client context but g_client is nil; cannot resolve key '%s'", tostring(key))
        return nil
    end

    -- Pure client: the key is a net-object-id string - keyFor emits exactly tostring(positive int),
    -- so it is a run of digits. Anything else is malformed (the key space crossed, or a crafted /
    -- corrupt key); fail closed loudly. The digit-run guard also rejects tonumber-accepted forms
    -- ("1e3", "0x64", " 12 ") that could alias a different net-id. A numeric id that resolves to a
    -- shape the caller rejects (stale/reused net-id) is caught further down.
    if key:match("^%d+$") == nil then
        Log:warning("RLHusbandryTargetKey.resolve: client key '%s' is not a numeric net-object-id; skipping", tostring(key))
        return nil
    end
    local objectId = tonumber(key)
    local object = NetworkUtil.getObject(objectId)
    if object == nil then
        Log:trace("RLHusbandryTargetKey.resolve: client key=%s -> no live object (transient/deleted)", key)
        return nil
    end
    -- Shape gate: a husbandry always admits; an EPP-shaped placeable admits ONLY for the move-dest
    -- opt-in. A stale/reused net-id landing on any other object type is rejected either way.
    local isHusbandry = object.spec_husbandryAnimals ~= nil
    local isEPP = object.spec_extendedProductionPoint ~= nil
    if not isHusbandry and not (allowEPP == true and isEPP) then
        Log:warning("RLHusbandryTargetKey.resolve: client key=%s resolved a non-admitted object (husbandry=%s epp=%s allowEPP=%s); skipping",
            key, tostring(isHusbandry), tostring(isEPP), tostring(allowEPP == true))
        return nil
    end
    Log:trace("RLHusbandryTargetKey.resolve: client key=%s -> placeable (husbandry=%s epp=%s)",
        key, tostring(isHusbandry), tostring(isEPP))
    return object
end

--- Resolve a stored TARGET key to its live husbandry placeable (the rule-targets wire leg + the
--- targets name display). Husbandry-only on the pure client: this is the shape gate that keeps an
--- EPP out of targetHusbandries. @see resolveInternal.
---@param key string|nil the stored target key (uniqueId on server, net-object-id on client)
---@return table|nil placeable the live husbandry placeable, or nil if it does not resolve
function RLHusbandryTargetKey.resolve(key)
    return resolveInternal(key, false)
end

--- Resolve a stored move-DESTINATION key to its live placeable, admitting an EPP butcher in addition
--- to a husbandry on the pure client (the explicit opt-in that widens the shape gate for move-dest
--- sites ONLY - the targets leg keeps `resolve`'s husbandry-only gate). @see resolveInternal.
---@param key string|nil the stored destination key (uniqueId on server, net-object-id on client)
---@return table|nil placeable the live husbandry or EPP placeable, or nil if it does not resolve
function RLHusbandryTargetKey.resolveDestination(key)
    return resolveInternal(key, true)
end

Log:trace("RLHusbandryTargetKey: loaded")
