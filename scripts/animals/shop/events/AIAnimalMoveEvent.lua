-- AIAnimalMoveEvent.lua
-- Server-authoritative herdsman MOVE: relocate animals between two husbandry pens on the
-- owning farm. The player AnimalMoveEvent is a request/response event (asymmetric stream,
-- farmId derived from the requesting connection) and cannot be server-broadcast for an
-- AI-origin move; this AI variant follows the AI* family's broadcast discipline instead - a
-- symmetric stream and a g_server-gated :run that mutates only on the authority, with pure
-- clients converging through the cluster system's own AnimalClusterUpdateEvent flush.
--
-- Transfer parity: :run resolves each animal's LIVE source cluster by three-field identity and
-- relocates it through the SAME husbandry delivery primitive the player move uses
-- (AnimalMoveEvent._dispatchTargetDelivery), source-first - the ordering invariant that keeps the
-- source husbandry's visual-count bookkeeping correct before the target reassigns idFull.

local Log = RmLogging.getLogger("RLRM")

AIAnimalMoveEvent = {}

local AIAnimalMoveEvent_mt = Class(AIAnimalMoveEvent, Event)
InitEventClass(AIAnimalMoveEvent, "AIAnimalMoveEvent")


function AIAnimalMoveEvent.emptyNew()
    local self = Event.new(AIAnimalMoveEvent_mt)
    return self
end


--- @param sourceObject table source husbandry placeable (the pen the animals leave)
--- @param targetObject table destination husbandry placeable (owner-farm, guaranteed by the executor)
--- @param animals table array of animal identifier records (RLAnimalUtil identity fields)
--- @return table event
function AIAnimalMoveEvent.new(sourceObject, targetObject, animals)
    local event = AIAnimalMoveEvent.emptyNew()
    event.sourceObject = sourceObject
    event.targetObject = targetObject
    event.animals = animals
    return event
end


--- Symmetric read: two node-objects + the animals as identity records (the AI-family form -
--- distinct from the player event, which streams full Animal entities and branches on direction).
--- @param streamId number
--- @param connection table
function AIAnimalMoveEvent:readStream(streamId, connection)
    self.sourceObject = NetworkUtil.readNodeObject(streamId)
    self.targetObject = NetworkUtil.readNodeObject(streamId)

    local numAnimals = streamReadUInt16(streamId)
    self.animals = {}
    for i = 1, numAnimals do
        table.insert(self.animals, RLAnimalUtil.readStreamIdentifiers(streamId, connection))
    end

    Log:trace("AIAnimalMoveEvent:readStream: numAnimals=%d source=%s target=%s",
        numAnimals, tostring(self.sourceObject), tostring(self.targetObject))

    self:run(connection)
end


--- Symmetric write: mirror of readStream (no server/client direction branch).
--- @param streamId number
--- @param connection table
function AIAnimalMoveEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.sourceObject)
    NetworkUtil.writeNodeObject(streamId, self.targetObject)

    streamWriteUInt16(streamId, #self.animals)
    for _, animal in pairs(self.animals) do
        RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection)
    end

    Log:trace("AIAnimalMoveEvent:writeStream: numAnimals=%d source=%s target=%s",
        #self.animals, tostring(self.sourceObject), tostring(self.targetObject))
end


--- Relocate the resolved source animals to the target husbandry (server-only). A pure client
--- returns immediately and syncs through the cluster system's AnimalClusterUpdateEvent flush; the
--- pending cluster API asserts isServer, so a client must skip the mutation block entirely.
--- @param connection table
function AIAnimalMoveEvent:run(connection)
    RmSafeUtils.safeCall("AIAnimalMoveEvent:run", function()
        Log:trace("AIAnimalMoveEvent:run moving %d animals server=%s",
            #self.animals, tostring(g_server ~= nil))

        if g_server == nil then return end

        -- A herdsman dest is always a husbandry (spec_husbandryAnimals ~= nil), so the delivery
        -- primitive's EPP branch must never run here. If a dest is somehow EPP-shaped, refuse to
        -- mutate rather than exercise an out-of-contract path.
        if self.targetObject.animalsTypeData ~= nil
            and type(self.targetObject.addCluster) == "function"
            and self.targetObject.spec_husbandryAnimals == nil then
            Log:error("AIAnimalMoveEvent:run: target is EPP-shaped, not a husbandry - refusing move (no mutation)")
            return
        end

        local sourceClusterSystem = self.sourceObject:getClusterSystem()
        local targetClusterSystem = self.targetObject:getClusterSystem()

        -- Resolve each animal's LIVE source cluster by three-field identity; a missing one is logged
        -- and dropped (an animal that left the pen since planning). In RLRM a cluster IS the Animal
        -- entity, so the resolved object is both the source-remove handle and the entity delivered to
        -- the target - relocating the live animal with its real genetics/health.
        local transferList = {}
        for _, identifier in pairs(self.animals) do
            local key = RLAnimalUtil.toKeyFromIdentifiers(identifier)
            local cluster = sourceClusterSystem:getClusterById(key)
            if cluster ~= nil then
                table.insert(transferList, { animal = cluster, sourceCluster = cluster })
            else
                Log:warning("AIAnimalMoveEvent:run: source cluster not found for key=%s (skipping)", tostring(key))
            end
        end

        -- Source-first: remove + flush the source BEFORE delivering to the target. The target's
        -- updateClusters tail-calls updateVisualAnimals which reassigns idFull on the shared entity,
        -- so source bookkeeping must read its handles first (the husbandry ordering invariant).
        local ok1, err1 = pcall(function()
            for _, entry in ipairs(transferList) do
                sourceClusterSystem:addPendingRemoveCluster(entry.sourceCluster)
            end
        end)
        local ok2, err2 = pcall(function() sourceClusterSystem:updateNow() end)

        -- Husbandry delivery primitive (reused, not re-rolled): keeps the source-first ordering +
        -- visual-count bookkeeping identical to the player move path.
        local okTarget, errTarget = AnimalMoveEvent._dispatchTargetDelivery(
            self.targetObject, transferList, targetClusterSystem)

        if ok1 and ok2 and okTarget then
            local farmId = self.targetObject:getOwnerFarmId()
            Log:debug("AIAnimalMoveEvent:run: moved %d animals to farmId=%s",
                #transferList, tostring(farmId))
        else
            Log:error("AIAnimalMoveEvent:run: transfer failed N=%d sourceQueue=%s sourceFlush=%s target=%s",
                #transferList, tostring(err1), tostring(err2), tostring(errTarget))
        end
    end)
end


--- Type-level validation for a husbandry->husbandry move. A husbandry supports an animal TYPE (not
--- specific subtypes), and getNumOfFreeAnimalSlots() returns a total count, so one representative
--- subtype answers type-support + total-room for the whole single-type source pen - no per-subtype
--- loop. Omits the player path's
--- canFarmAccess: the herdsman is server-authoritative and both pens are owner-farm, so the
--- permission gate is structurally always-true; omitting it keeps the executor's decision path free
--- of g_* reads for dual-running. Reuses the base-game AnimalMoveEvent.MOVE_ERROR_* constants.
--- @param source table source husbandry placeable
--- @param target table destination husbandry placeable
--- @param count number number of animals to move (total free-slot gate)
--- @param subTypeIndex number one representative subtype of the single-type source pen
--- @return number|nil errorCode an AnimalMoveEvent.MOVE_ERROR_* constant, or nil when valid
function AIAnimalMoveEvent.validate(source, target, count, subTypeIndex)
    if source == nil then return AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST end
    if target == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end
    if not target:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end
    if target:getNumOfFreeAnimalSlots() < count then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end
    return nil
end
