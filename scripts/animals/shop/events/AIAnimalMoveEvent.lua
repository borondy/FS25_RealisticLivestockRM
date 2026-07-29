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

        -- Resolve the TARGET shape BEFORE the cluster-system prologue. A herdsman dest is
        -- a husbandry OR an owner-farm EPP (butcher). An EPP placeable has no real cluster system (its
        -- internal one is a placeholder), so self.targetObject:getClusterSystem() must NOT run for it -
        -- it would crash. Unwrap the production point here; getClusterSystem moves into the husbandry
        -- branch, keeping the husbandry path byte-identical.
        local eppSpec = self.targetObject.spec_extendedProductionPoint
        local targetPP = eppSpec ~= nil and eppSpec.productionPoint or nil
        local isEPPTarget = targetPP ~= nil

        local sourceClusterSystem = self.sourceObject:getClusterSystem()

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

        if isEPPTarget then
            -- EPP (butcher) delivery. Defensive age backstop on the RESOLVED live cluster (the cluster
            -- IS the Animal, carrying .age) - the wire payload is identity-only, so age is read here,
            -- never off the stream. The executor already age-filtered before dispatch; this
            -- guards a late age change / a future direct caller against delivering an out-of-window
            -- animal to the butcher. Then deliver target-first per-animal-atomic via the SHIPPED
            -- player-path primitive (which expects the PP), and stage source-flush for delivered only
            -- (duplication-over-loss - a per-animal failure leaves undelivered animals in source).
            local typeIndex = self.sourceObject.getAnimalTypeIndex ~= nil and self.sourceObject:getAnimalTypeIndex() or nil
            local typeData = (typeIndex ~= nil and type(targetPP.animalsTypeData) == "table") and targetPP.animalsTypeData[typeIndex] or nil
            local minAge = (typeData ~= nil and typeData.minimumAge) or 0
            local maxAge = (typeData ~= nil and typeData.maximumAge) or 999

            local eligible = {}
            local skippedAge = 0
            for _, entry in ipairs(transferList) do
                local age = (entry.animal ~= nil and entry.animal.age) or 0
                if age >= minAge and age <= maxAge then
                    eligible[#eligible + 1] = entry
                else
                    skippedAge = skippedAge + 1
                    Log:trace("AIAnimalMoveEvent:run: EPP age backstop skipping uniqueId=%s age=%s (window %d-%d)",
                        tostring(entry.animal ~= nil and entry.animal.uniqueId), tostring(age), minAge, maxAge)
                end
            end
            if skippedAge > 0 then
                Log:debug("AIAnimalMoveEvent:run: EPP age backstop removed %d of %d resolved animal(s) (window %d-%d)",
                    skippedAge, #transferList, minAge, maxAge)
            end

            local okTarget, errTarget, deliveredList = AnimalMoveEvent._dispatchTargetDelivery(targetPP, eligible, nil)
            local ok1, err1 = pcall(function()
                AnimalMoveEvent._stageSourceFlushForDelivered(sourceClusterSystem, deliveredList)
            end)
            local ok2, err2 = pcall(function() sourceClusterSystem:updateNow() end)

            if okTarget and ok1 and ok2 then
                local farmId = self.targetObject.getOwnerFarmId ~= nil and self.targetObject:getOwnerFarmId() or nil
                Log:debug("AIAnimalMoveEvent:run: delivered %d animal(s) to EPP butcher farmId=%s (skippedAge=%d)",
                    #(deliveredList or {}), tostring(farmId), skippedAge)
            else
                Log:error("AIAnimalMoveEvent:run: EPP transfer failed delivered=%d target=%s sourceFlush=%s sourceUpdate=%s",
                    #(deliveredList or {}), tostring(errTarget), tostring(err1), tostring(err2))
            end
            return
        end

        -- Husbandry target (unchanged). Source-first: remove + flush the source BEFORE delivering to
        -- the target. The target's updateClusters tail-calls updateVisualAnimals which reassigns idFull
        -- on the shared entity, so source bookkeeping must read its handles first (the husbandry
        -- ordering invariant). getClusterSystem is resolved HERE (never on the EPP branch above).
        local targetClusterSystem = self.targetObject:getClusterSystem()
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


--- Type-level validation for a herdsman move to a husbandry OR an EPP (butcher) destination. A
--- husbandry supports an animal TYPE (not specific subtypes), and getNumOfFreeAnimalSlots() returns a
--- total count, so one representative subtype answers type-support + total-room for the whole
--- single-type source pen - no per-subtype loop. An EPP destination (spec_extendedProductionPoint)
--- delegates to its production point: the support + free-slot methods live on the pp, and the
--- free-slot gate is subtype-arg'd (player-path parity). Omits the player path's
--- canFarmAccess: the herdsman is server-authoritative and both source + dest are owner-farm, so the
--- permission gate is structurally always-true; omitting it keeps the executor's decision path free
--- of g_* reads for dual-running. Reuses the base-game AnimalMoveEvent.MOVE_ERROR_* constants.
--- @param source table source husbandry placeable
--- @param target table destination placeable (husbandry OR EPP)
--- @param count number number of animals to move (free-slot gate)
--- @param subTypeIndex number one representative subtype of the single-type source pen
--- @return number|nil errorCode an AnimalMoveEvent.MOVE_ERROR_* constant, or nil when valid
function AIAnimalMoveEvent.validate(source, target, count, subTypeIndex)
    if source == nil then return AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST end
    if target == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end

    -- EPP (butcher) dest: unwrap the production point (support + capacity methods live on it, not the
    -- placeable) and gate subtype-arg'd, matching the player move path. Defensive against a missing pp
    -- (fail closed as target-does-not-exist rather than nil-index a spec that lost its productionPoint).
    local eppSpec = target.spec_extendedProductionPoint
    if eppSpec ~= nil then
        local pp = eppSpec.productionPoint
        if pp == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end
        if not pp:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end
        if pp:getNumOfFreeAnimalSlots(subTypeIndex) < count then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end
        return nil
    end

    if not target:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end
    if target:getNumOfFreeAnimalSlots() < count then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end
    return nil
end
