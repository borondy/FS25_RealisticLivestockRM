--[[
    RLTransferWorldAdapter.lua
    The WORLD counterpart adapter behind the RLTransferAdapter seam (Phase 8 M4).

    When a livestock/horse trailer is triggered standalone (no pen, no dealer - the
    LivestockTrailerActivatable walk-up), the Transfer frame's "other side" is the free
    rideables in the trailer's trigger zone. This adapter ROUTES the 4-method seam to
    RLTrailerWorldService - it never builds events or mutates state itself:
      * getDisplayData -> the world sidebar entry (resolved name + the rideable count).
      * enumerate      -> RLTrailerWorldService.buildSourceItems (the converted-Animal
                          source list), storing the cluster -> rideable map on the
                          context so dispatch can recover each rideable.
      * actionLabel    -> the pure RLTransferAdapter.worldActionLabelKey.
      * dispatch       -> RLTrailerWorldService.loadRideables / unloadClusters (the
                          SAME base-game AnimalLoadEvent / AnimalUnloadEvent the legacy
                          AnimalScreenTrailer fired; mutation parity, never a new event).

    Tier: IN-GAME. Its methods deref RLTrailerWorldService + g_i18n + the engine getters,
    so it is NOT headless. The parity-critical pure bits (worldActionLabelKey, the
    conversion + error mapping inside the service) dual-run; this module only maps the
    resolved direction onto the real objects.

    Stateless: a plain table whose methods take self via `:` and read everything from
    the passed context (no instance fields). Registered at load into
    RLTransferAdapter._adapters[RLMenuTabPolicy.WORLD] so forCounterpart("world")
    resolves it in-game. The headless harness never sources this file, so the seam stays
    NULL there - which keeps the pure RLTransferAdapterTests true in both runners (the
    concrete world -> adapter assertion lives in the in-game-only RLTransferWorldAdapterTests).
]]

RLTransferWorldAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- Display data for the world counterpart sidebar entry: the resolved "nearby
--- animals" name and the rideable count. The world side has no bounded capacity, so
--- used == total == the number of rideables enumerate would EMIT (derived from the
--- same builder, so the count cannot diverge from the list). The world adapter is
--- in-game tier, so it resolves the i18n KEY itself and returns an ENGINE STRING used
--- verbatim by the frame (the frame getTexts only the NULL adapter's KEY). Nil /
--- missing trailer -> { name = <resolved>, used = 0, total = 0 }.
--- @param context table  { trailer = <livestock trailer>, ... }
--- @return table display  { name, used, total }
function RLTransferWorldAdapter:getDisplayData(context)
    local name = g_i18n:getText(RLTransferAdapter.WORLD_NAME_KEY)
    local trailer = context ~= nil and context.trailer or nil
    if trailer == nil then
        Log:trace("RLTransferWorldAdapter:getDisplayData: nil trailer -> empty count")
        return { name = name, used = 0, total = 0 }
    end
    local n = RLTrailerWorldService.countSourceItems(trailer)
    Log:trace("RLTransferWorldAdapter:getDisplayData: name='%s' count=%d", tostring(name), n)
    return { name = name, used = n, total = n }
end

--- Enumerate the trigger rideables as AnimalItemStock items (each exposes .cluster =
--- the converted Animal), via RLTrailerWorldService.buildSourceItems. REPLACES
--- context.clusterToVehicle with this build's cluster -> rideable map each call, so
--- dispatch recovers each rideable from the CURRENT build (selection and map stay in
--- lockstep across a re-enumerate). Nil / no-trigger trailer -> {}.
--- @param context table  { trailer = <livestock trailer>, ... }
--- @return table items
function RLTransferWorldAdapter:enumerate(context)
    local trailer = context ~= nil and context.trailer or nil
    if trailer == nil then
        Log:trace("RLTransferWorldAdapter:enumerate: nil trailer -> {}")
        return {}
    end
    local items, clusterToVehicle = RLTrailerWorldService.buildSourceItems(trailer)
    if context ~= nil then
        context.clusterToVehicle = clusterToVehicle
    end
    Log:trace("RLTransferWorldAdapter:enumerate: %d item(s)", #items)
    return items
end

--- The footer action-label i18n KEY for a direction (legacy text parity):
--- "shop_moveToTrailer" loading, "shop_moveToSpawnPlace" unloading. Delegates to the
--- pure worldActionLabelKey; the frame resolves the returned KEY.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferWorldAdapter:actionLabel(direction)
    return RLTransferAdapter.worldActionLabelKey(direction)
end

--- Route the selected world animals to RLTrailerWorldService for the direction's plan.
--- Fail-closed (log + return false, NO dispatch, NO completion) when the plan is nil,
--- the trailer is missing, or nothing is selected. Loading (DIR_INTO_TRAILER) maps each
--- selected cluster back to its rideable via context.clusterToVehicle - selection comes
--- from the CURRENT enumerate build (which rebuilt the map), so a miss is an INVARIANT
--- BREACH (logged at WARNING, that item dropped), not a normal condition. Unloading
--- (DIR_OUT_OF_TRAILER) maps each selected cluster to its RESOLVED wire id via
--- RLAnimalUtil.resolveClusterId (the 3-part identity toKey for an individual, not the
--- never-updated "0-0" placeholder cluster.id), dropping any cluster whose id is
--- unresolvable. Returns true only
--- when the service is engaged - and a true return GUARANTEES the service fires
--- context.onComplete EXACTLY ONCE. If the mapped list is empty after dropping
--- unrecoverable items, returns false (no completion) so the frame releases movePending.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @param animals table  the selected clusters (current-build .cluster refs)
--- @param context table  { trailer, clusterToVehicle, onComplete, ... }
--- @return boolean routed
function RLTransferWorldAdapter:dispatch(direction, animals, context)
    local plan = RLTransferAdapter.resolveMovePlan(direction)
    local trailer = context ~= nil and context.trailer or nil

    if plan == nil or trailer == nil or animals == nil or #animals == 0 then
        Log:debug("RLTransferWorldAdapter:dispatch: no-op (plan=%s, trailer=%s, animals=%d)",
            tostring(plan), tostring(trailer), animals ~= nil and #animals or 0)
        return false
    end

    if direction == RLTransferAdapter.DIR_INTO_TRAILER then
        local map = (context ~= nil and context.clusterToVehicle) or {}
        local rideables = {}
        for _, cluster in ipairs(animals) do
            local rideable = map[cluster]
            if rideable ~= nil then
                rideables[#rideables + 1] = rideable
            else
                Log:warning("RLTransferWorldAdapter:dispatch: cluster '%s' has no rideable mapping (invariant breach), dropping it",
                    tostring(cluster ~= nil and cluster.uniqueId or cluster))
            end
        end
        if #rideables == 0 then
            Log:debug("RLTransferWorldAdapter:dispatch: load mapped to 0 rideables after drops, no-op")
            return false
        end
        Log:debug("RLTransferWorldAdapter:dispatch: load %d rideable(s) into trailer", #rideables)
        RLTrailerWorldService.loadRideables(trailer, rideables, context.onComplete)
        return true
    end

    -- DIR_OUT_OF_TRAILER: unload the selected trailer clusters by their RESOLVED wire id
    -- (toKey for an individual - what getClusterById matches - not the "0-0" cluster.id).
    local clusterIds = {}
    for _, cluster in ipairs(animals) do
        local id = RLAnimalUtil.resolveClusterId(cluster)
        if id ~= nil then
            clusterIds[#clusterIds + 1] = id
        else
            Log:warning("RLTransferWorldAdapter:dispatch: unload cluster '%s' has no resolvable id, dropping it",
                tostring(cluster ~= nil and cluster.uniqueId or cluster))
        end
    end
    if #clusterIds == 0 then
        Log:debug("RLTransferWorldAdapter:dispatch: unload mapped to 0 cluster ids after drops, no-op")
        return false
    end
    Log:debug("RLTransferWorldAdapter:dispatch: unload %d cluster(s) from trailer", #clusterIds)
    RLTrailerWorldService.unloadClusters(trailer, clusterIds, context.onComplete)
    return true
end

-- Register at load so forCounterpart("world") resolves this adapter in-game. The
-- registry is a plain Lua table (assigning into it is registration ceremony, not game
-- state - the sanctioned load-time escape). Keyed by RLMenuTabPolicy.WORLD, which
-- equals g_rlMenu.trailerCounterpart for the world (activatable) redirect.
RLTransferAdapter._adapters[RLMenuTabPolicy.WORLD] = RLTransferWorldAdapter

Log:debug("RLTransferWorldAdapter: loaded and registered for counterpart '%s'", tostring(RLMenuTabPolicy.WORLD))
