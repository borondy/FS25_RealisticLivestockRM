--[[
    RLTransferEppAdapter.lua
    The EPP (butcher) counterpart adapter behind the RLTransferAdapter seam (RLRM-495, Phase 9).

    When a third-party EPP butcher trigger (boucherie / MeatProcessingPlant /
    Butcher_Table) direct-opens the vanilla AnimalScreen with its own controller,
    RLAnimalScreenBridge's onOpen redirect reroutes it into RLMenu MODE_TRAILER with
    this EPP counterpart. The butcher is a pure SINK: you DELIVER a loaded trailer to
    it, you never pull animals back out. So this adapter is ONE-WAY:
      * getDisplayData -> the butcher sidebar entry (owning-placeable name + free slots).
      * enumerate      -> {} ALWAYS (nothing lists on the butcher side; the frame
                          already tolerates an empty counterpart - empty-state text,
                          no action button - exactly as the NULL adapter proves).
      * actionLabel    -> the pure RLTransferAdapter.eppActionLabelKey ("Deliver").
      * dispatch       -> guards the reverse (DIR_INTO_TRAILER -> false BEFORE any
                          move), then routes deliver to RLAnimalMoveService.moveAnimals
                          (trailer, pp, animals, "TARGET") - the SAME AnimalMoveEvent EPP
                          delivery leg the vanilla EPP screen fires (whose
                          _dispatchTargetDelivery primitive the RLRM-489 herdsman
                          AIAnimalMoveEvent path also reuses); mutation parity, never a
                          new event class.

    context.counterpartHandle IS the production point (the EPP loading trigger sets
    controller.husbandry = the pp itself). moveAnimals auto-detects a pp target by its
    animalsTypeData and age/type-filters CLIENT-side before dispatch (server rechecks),
    so no new validation lives here; this module only maps the deliver onto the real
    objects.

    Tier: IN-GAME. Its methods deref RLAnimalMoveService / RLTrailerEndpointService and
    the engine pp getters, so it is NOT headless. The parity-critical pure bit
    (RLTransferAdapter.eppActionLabelKey) dual-runs. The headless harness never sources
    this file, so the seam stays NULL there - which keeps the pure RLTransferAdapterTests
    true in both runners (the concrete epp -> adapter / one-way-sink assertions live in
    the in-game-only RLTransferEppAdapterTests).

    Stateless: a plain table whose methods take self via `:` and read everything from
    the passed context (no instance fields). Registered at load into
    RLTransferAdapter._adapters[RLMenuTabPolicy.EPP] so forCounterpart("epp") resolves
    it in-game.
]]

RLTransferEppAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- Resolve the subtype the trailer is carrying so the butcher's per-subtype free-slot
--- count can be read. The EPP trigger only activates with a loaded trailer, so a real
--- subtype is normally present; scans the live contents for the first animal with a
--- real subTypeIndex (all animals aboard share one type). nil when empty / unreadable.
--- @param trailer table|nil
--- @return number|nil subTypeIndex
local function resolveTrailerSubTypeIndex(trailer)
    if trailer == nil then
        return nil
    end
    local contents = RLTrailerEndpointService.getContents(trailer)
    for _, animal in ipairs(contents) do
        if animal.subTypeIndex ~= nil then
            return animal.subTypeIndex
        end
    end
    return nil
end

--- Display data for the butcher counterpart sidebar entry: the owning placeable's
--- engine name and its free-slot count for the trailer's subtype. `used` is 0 (a
--- butcher exposes no meaningful current-animal count - deliveries are consumed) and
--- `total` is the free slots, so a FULL butcher renders (0/0) and a confirmed deliver
--- then surfaces the capacity error. The name is an ENGINE STRING used verbatim by the
--- frame (the frame getTexts only the NULL adapter's KEY). Nil pp / missing getters ->
--- (0/0) defensively (the redirect always supplies a live pp).
--- @param context table  { counterpartHandle = <production point>, trailer = <trailer>, ... }
--- @return table display  { name, used, total }
function RLTransferEppAdapter:getDisplayData(context)
    local pp = context ~= nil and context.counterpartHandle or nil
    if pp == nil then
        Log:trace("RLTransferEppAdapter:getDisplayData: nil pp -> empty display")
        return { name = "", used = 0, total = 0 }
    end

    local placeable = pp.owningPlaceable
    local name = (placeable ~= nil and placeable.getName ~= nil and placeable:getName()) or ""

    local free = 0
    local subTypeIndex = resolveTrailerSubTypeIndex(context ~= nil and context.trailer or nil)
    if subTypeIndex ~= nil and pp.getNumOfFreeAnimalSlots ~= nil then
        free = pp:getNumOfFreeAnimalSlots(subTypeIndex) or 0
    end

    Log:trace("RLTransferEppAdapter:getDisplayData: name='%s' subTypeIndex=%s free=%d",
        tostring(name), tostring(subTypeIndex), free)
    return { name = name, used = 0, total = free }
end

--- The butcher side lists NOTHING - it is a sink, you never pull animals out of it.
--- Always returns {} (the frame renders empty-state text and hides the action button
--- on this side, the same as the NULL adapter). Nil-safe by construction.
--- @param _context table  ignored
--- @return table items  always empty
function RLTransferEppAdapter:enumerate(_context)
    Log:trace("RLTransferEppAdapter:enumerate: sink -> {} (butcher lists nothing)")
    return {}
end

--- The footer action-label i18n KEY for a direction. Delegates to the pure
--- eppActionLabelKey ("Deliver"); the frame resolves the returned KEY.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferEppAdapter:actionLabel(direction)
    return RLTransferAdapter.eppActionLabelKey(direction)
end

--- Deliver the selected trailer animals to the butcher production point. ONE-WAY:
--- the reverse (DIR_INTO_TRAILER - pulling FROM the butcher) is refused BEFORE any
--- plan resolution or moveAnimals call, so the sink can never mutate the trailer from
--- the butcher side. For the deliver direction, routes to
--- RLAnimalMoveService.moveAnimals(trailer, pp, animals, "TARGET") - the SAME
--- AnimalMoveEvent EPP leg the vanilla EPP screen fires (whose _dispatchTargetDelivery
--- primitive the RLRM-489 herdsman AIAnimalMoveEvent path also reuses); mutation
--- parity. The move-service errorCode result (incl. the all-rejected firstErrorCode,
--- fired synchronously) is wrapped here into the frame's uniform (success, errorText)
--- completion contract; the accept/reject bool propagates so the frame releases
--- movePending on a false return. Returns false WITHOUT dispatching on the reverse
--- guard, a nil plan, or a missing pp / trailer (fail-closed).
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @param animals table  the selected trailer animals (clusters)
--- @param context table  { trailer, counterpartHandle = <pp>, onComplete, ... }
--- @return boolean routed
function RLTransferEppAdapter:dispatch(direction, animals, context)
    -- One-way sink: NEVER pull animals FROM the butcher back into the trailer. Guard
    -- the reverse direction FIRST, before resolving a plan or touching moveAnimals.
    if direction == RLTransferAdapter.DIR_INTO_TRAILER then
        Log:debug("RLTransferEppAdapter:dispatch: reverse (into-trailer) refused - butcher is a sink, no move")
        return false
    end

    local plan = RLTransferAdapter.resolveMovePlan(direction)
    local pp = context ~= nil and context.counterpartHandle or nil
    local trailer = context ~= nil and context.trailer or nil

    if plan == nil or pp == nil or trailer == nil then
        Log:debug("RLTransferEppAdapter:dispatch: no-op (plan=%s, pp=%s, trailer=%s)",
            tostring(plan), tostring(pp), tostring(trailer))
        return false
    end

    -- Deliver: source is the trailer, target is the production point (pp). moveAnimals
    -- auto-detects the pp target via its animalsTypeData and age/type-filters
    -- CLIENT-side before dispatch (server rechecks); ONE request dispatches only when
    -- survivors exist; the callback fires exactly once (may be synchronous when all
    -- selected are rejected). Wrap that errorCode into the frame's (success, errorText)
    -- contract - mutation parity holds (still routes to moveAnimals).
    Log:debug("RLTransferEppAdapter:dispatch: deliver %d animal(s) trailer -> butcher '%s' (moveType=%s)",
        animals ~= nil and #animals or 0,
        tostring(pp.owningPlaceable ~= nil and pp.owningPlaceable.getName ~= nil and pp.owningPlaceable:getName()),
        plan.moveType)

    local accepted = RLAnimalMoveService.moveAnimals(trailer, pp, animals, plan.moveType, function(errorCode)
        local success = (errorCode == nil or errorCode == AnimalMoveEvent.MOVE_SUCCESS)
        local errorText = (not success) and RLAnimalMoveService.getErrorText(errorCode) or nil
        if context.onComplete ~= nil then
            context.onComplete(success, errorText)
        end
    end)
    if not accepted then
        Log:debug("RLTransferEppAdapter:dispatch: move service rejected the dispatch (returning false so the frame releases movePending)")
    end
    return accepted
end

-- Register at load so forCounterpart("epp") resolves this adapter in-game. The registry
-- is a plain Lua table (assigning into it is registration ceremony, not game state - the
-- sanctioned load-time escape). Keyed by RLMenuTabPolicy.EPP, which equals
-- g_rlMenu.trailerCounterpart for the EPP onOpen redirect.
RLTransferAdapter._adapters[RLMenuTabPolicy.EPP] = RLTransferEppAdapter

Log:debug("RLTransferEppAdapter: loaded and registered for counterpart '%s'", tostring(RLMenuTabPolicy.EPP))
