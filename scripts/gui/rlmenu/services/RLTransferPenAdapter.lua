--[[
    RLTransferPenAdapter.lua
    The PEN counterpart adapter behind the RLTransferAdapter seam (Phase 8 M2).

    When a livestock trailer is triggered at an animal pen, the Transfer frame's
    "other side" is that pen. This adapter reads the pen husbandry from the open
    context (context.counterpartHandle) and routes a confirmed transfer to
    RLAnimalMoveService.moveAnimals - the SAME AnimalMoveEvent the legacy
    trailer-at-pen controller fired (mutation parity). It ROUTES; it never
    constructs the event or mutates state itself.

    Tier: IN-GAME. Its methods deref RLAnimalQuery / RLAnimalMoveService and the
    engine husbandry getters, so it is NOT headless. The parity-critical pure bits
    (RLTransferAdapter.resolveMovePlan / penActionLabelKey) dual-run; this module
    only maps the resolved sides onto the real objects.

    Stateless: a plain table whose methods take self via `:` and read everything
    from the passed context (no instance fields). Registered at load into
    RLTransferAdapter._adapters[RLMenuTabPolicy.PEN] so forCounterpart("pen")
    resolves it in-game. The headless harness never sources this file, so the seam
    stays NULL there - which is what keeps the pure RLTransferAdapterTests true in
    both runners (the concrete pen -> adapter assertion lives in the in-game-only
    RLTransferPenAdapterTests).
]]

RLTransferPenAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- Display data for the pen counterpart sidebar entry: the pen's engine name and
--- its used / total animal counts. `total` is `used + getNumOfFreeAnimalSlots()`
--- (the no-arg per-pen free total) - one definition, not the subtype-sensitive
--- getMaxNumOfAnimals form. The name is an ENGINE STRING used verbatim by the
--- frame (the frame getText's only the NULL adapter's KEY). Nil / handle-missing
--- -> { name = "", used = 0, total = 0 } (defensive; the redirect always supplies
--- a live husbandry).
--- @param context table  { counterpartHandle = <husbandry placeable>, ... }
--- @return table display  { name, used, total }
function RLTransferPenAdapter:getDisplayData(context)
    local husbandry = context ~= nil and context.counterpartHandle or nil
    if husbandry == nil then
        Log:trace("RLTransferPenAdapter:getDisplayData: nil husbandry -> empty display")
        return { name = "", used = 0, total = 0 }
    end

    local name = (husbandry.getName ~= nil and husbandry:getName()) or ""
    local used = (husbandry.getNumOfAnimals ~= nil and husbandry:getNumOfAnimals()) or 0
    local free = (husbandry.getNumOfFreeAnimalSlots ~= nil and husbandry:getNumOfFreeAnimalSlots()) or 0
    local total = used + free
    Log:trace("RLTransferPenAdapter:getDisplayData: name='%s' used=%d free=%d total=%d",
        tostring(name), used, free, total)
    return { name = name, used = used, total = total }
end

--- Enumerate the pen's animals as sorted AnimalItemStock items (each exposes
--- .cluster) via the same helper the shipped Move frame uses. No pre-filter by
--- the trailer's locked type (legacy initTargetItems parity - the move service is
--- the type/capacity gate). Nil / no-spec handle -> {} (listAnimalsForHusbandry
--- hard-requires spec_husbandryAnimals).
--- @param context table  { counterpartHandle = <husbandry placeable>, ... }
--- @return table items
function RLTransferPenAdapter:enumerate(context)
    local husbandry = context ~= nil and context.counterpartHandle or nil
    if husbandry == nil then
        Log:trace("RLTransferPenAdapter:enumerate: nil husbandry -> {}")
        return {}
    end
    local items = RLAnimalQuery.listAnimalsForHusbandry(husbandry, nil) or {}
    Log:trace("RLTransferPenAdapter:enumerate: %d item(s)", #items)
    return items
end

--- The footer action-label i18n KEY for a direction (legacy text parity):
--- "shop_moveToTrailer" loading, "shop_moveToFarm" unloading. Delegates to the
--- pure penActionLabelKey; the frame resolves the returned KEY.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferPenAdapter:actionLabel(direction)
    return RLTransferAdapter.penActionLabelKey(direction)
end

--- Route the selected animals to RLAnimalMoveService.moveAnimals for the
--- direction's move plan. Resolves the (source, target, moveType) via the pure
--- resolveMovePlan, maps the sides onto the real objects (SIDE_COUNTERPART ->
--- context.counterpartHandle, SIDE_TRAILER -> context.trailer), and dispatches.
--- Returns true when routed to the move service (which owns the filter pipeline +
--- survivor dispatch + single broadcast). The move-service errorCode result - incl.
--- the all-rejected firstErrorCode - is wrapped here into the frame's uniform
--- (success, errorText) completion contract, so the frame stays adapter-agnostic;
--- mutation parity holds (still routes to moveAnimals). Returns false WITHOUT
--- dispatching when the plan is nil or either endpoint is missing (fail-closed);
--- the frame then leaves its state unchanged.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @param animals table  the selected animals (clusters)
--- @param context table  { trailer, counterpartHandle, onComplete, ... }
--- @return boolean routed
function RLTransferPenAdapter:dispatch(direction, animals, context)
    local plan = RLTransferAdapter.resolveMovePlan(direction)
    local counterpart = context ~= nil and context.counterpartHandle or nil
    local trailer = context ~= nil and context.trailer or nil

    if plan == nil or counterpart == nil or trailer == nil then
        Log:debug("RLTransferPenAdapter:dispatch: no-op (plan=%s, counterpart=%s, trailer=%s)",
            tostring(plan), tostring(counterpart), tostring(trailer))
        return false
    end

    local source = (plan.sourceSide == RLTransferAdapter.SIDE_COUNTERPART) and counterpart or trailer
    local target = (plan.targetSide == RLTransferAdapter.SIDE_COUNTERPART) and counterpart or trailer

    Log:debug("RLTransferPenAdapter:dispatch: direction=%s moveType=%s source='%s' target='%s' animals=%d",
        tostring(direction), plan.moveType,
        tostring(source and source.getName and source:getName()),
        tostring(target and target.getName and target:getName()),
        animals ~= nil and #animals or 0)

    -- Wrap the move-service errorCode callback into the frame's generalized
    -- (success, errorText) completion contract (RLRM-431). Mutation parity is
    -- preserved - this still routes to moveAnimals; only the result space is adapted.
    -- moveAnimals fires the callback with MOVE_SUCCESS / an error code (incl. the
    -- all-rejected firstErrorCode), never nil, so the nil success branch is defensive.
    RLAnimalMoveService.moveAnimals(source, target, animals, plan.moveType, function(errorCode)
        local success = (errorCode == nil or errorCode == AnimalMoveEvent.MOVE_SUCCESS)
        local errorText = (not success) and RLAnimalMoveService.getErrorText(errorCode) or nil
        if context.onComplete ~= nil then
            context.onComplete(success, errorText)
        end
    end)
    return true
end

-- Register at load so forCounterpart("pen") resolves this adapter in-game. The
-- registry is a plain Lua table (assigning into it is registration ceremony, not
-- game state - the sanctioned load-time escape). Keyed by RLMenuTabPolicy.PEN,
-- which equals g_rlMenu.trailerCounterpart for the pen redirect.
RLTransferAdapter._adapters[RLMenuTabPolicy.PEN] = RLTransferPenAdapter

Log:debug("RLTransferPenAdapter: loaded and registered for counterpart '%s'", tostring(RLMenuTabPolicy.PEN))
