local Log = RmLogging.getLogger("RLRM")

--- Log a one-line snapshot of a cluster husbandry's visual-count state.
--- Used by AnimalMoveEvent:run to make source/target visual-count drift
--- observable in the log on every move (RLRM-213).
--- Trailer cluster systems have no clusterHusbandry; logged as "no clusterHusbandry".
--- @param side string "source" | "target"
--- @param stage string "before" | "after"
--- @param clusterSystem table The cluster system to inspect
function AnimalMoveEvent._logVisualCountSnapshot(side, stage, clusterSystem)
	local owner = clusterSystem and clusterSystem.owner
	local spec = owner and owner.spec_husbandryAnimals
	local clusterHusbandry = spec and spec.clusterHusbandry
	local ownerName = owner and owner.getName and owner:getName() or tostring(owner)

	if clusterHusbandry == nil then
		Log:debug("AnimalMoveEvent snapshot: side=%s stage=%s owner=%s (no clusterHusbandry)",
			side, stage, tostring(ownerName))
		return
	end

	local visualCount = clusterHusbandry.visualAnimalCount or 0
	local slotsParts = {}
	if type(clusterHusbandry.husbandryIdsToVisualAnimalCount) == "table" then
		for engineId, count in pairs(clusterHusbandry.husbandryIdsToVisualAnimalCount) do
			table.insert(slotsParts, string.format("%s=%s", tostring(engineId), tostring(count)))
		end
	end
	Log:debug("AnimalMoveEvent snapshot: side=%s stage=%s owner=%s visualCount=%d slots=[%s]",
		side, stage, tostring(ownerName), visualCount, table.concat(slotsParts, ","))
end

function AnimalMoveEvent.new(sourceObject, targetObject, animals, moveType)

	local event = AnimalMoveEvent.emptyNew()

	event.sourceObject = sourceObject
	event.targetObject = targetObject
	event.animals = animals
	event.moveType = moveType

	return event

end


function AnimalMoveEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, 3)
		Log:trace("AnimalMoveEvent:readStream (client): errorCode=%d", self.errorCode)

	else

		self.moveType = streamReadString(streamId)

		self.sourceObject = NetworkUtil.readNodeObject(streamId)
		self.targetObject = NetworkUtil.readNodeObject(streamId)

		local numAnimals = streamReadUInt16(streamId)
		Log:trace("AnimalMoveEvent:readStream (server): moveType='%s' numAnimals=%d source=%s target=%s",
			tostring(self.moveType), numAnimals,
			tostring(self.sourceObject), tostring(self.targetObject))

		self.animals = {}

		for i = 1, numAnimals do

			local animal = Animal.new()
			local success = animal:readStream(streamId, connection)
			table.insert(self.animals, animal)
			Log:trace("AnimalMoveEvent:readStream: animal %d read success=%s id='%s'",
				i, tostring(success), tostring(animal.uniqueId))

		end

	end

	self:run(connection)

end


function AnimalMoveEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		Log:trace("AnimalMoveEvent:writeStream (server→client): errorCode=%d", self.errorCode)
		streamWriteUIntN(streamId, self.errorCode, 3)
		return
	end

	Log:trace("AnimalMoveEvent:writeStream (client→server): moveType='%s' numAnimals=%d",
		tostring(self.moveType), #self.animals)

	streamWriteString(streamId, self.moveType)

	NetworkUtil.writeNodeObject(streamId, self.sourceObject)
	NetworkUtil.writeNodeObject(streamId, self.targetObject)

	streamWriteUInt16(streamId, #self.animals)

	for i, animal in pairs(self.animals) do
		Log:trace("AnimalMoveEvent:writeStream: writing animal %d id='%s'", i, tostring(animal.uniqueId))
		local success = animal:writeStream(streamId, connection)
		Log:trace("AnimalMoveEvent:writeStream: animal %d write success=%s", i, tostring(success))
	end

end


function AnimalMoveEvent:run(connection)

	if connection:getIsServer() then
		Log:trace("AnimalMoveEvent:run (client): publishing errorCode=%d", self.errorCode)
		g_messageCenter:publish(AnimalMoveEvent, self.errorCode)
		return

	end

	RmSafeUtils.safeCall("AnimalMoveEvent:run", function()

		Log:debug("AnimalMoveEvent:run (server): moveType='%s' animals=%d source=%s target=%s",
			tostring(self.moveType), #self.animals,
			tostring(self.sourceObject and self.sourceObject.getName and self.sourceObject:getName()),
			tostring(self.targetObject and self.targetObject.getName and self.targetObject:getName()))

		local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
		local farmId = g_farmManager:getFarmForUniqueUserId(userId).farmId
		Log:trace("AnimalMoveEvent:run: userId=%s farmId=%d", tostring(userId), farmId)

		local validatedCount = 0

		for i, animal in pairs(self.animals) do

			Log:trace("AnimalMoveEvent:run: validating animal %d subTypeIndex=%s", i, tostring(animal.subTypeIndex))
			local errorCode = AnimalMoveEvent.validate(self.sourceObject, self.targetObject, farmId, animal.subTypeIndex)

			if errorCode ~= nil then
				Log:debug("AnimalMoveEvent:run: validation failed for animal %d, errorCode=%d", i, errorCode)
				connection:sendEvent(AnimalMoveEvent.newServerToClient(errorCode))
				return
			end

			validatedCount = validatedCount + 1

			if self.targetObject:getNumOfFreeAnimalSlots(animal.subTypeIndex) < validatedCount then
				Log:debug("AnimalMoveEvent:run: not enough space at target (need=%d)", validatedCount)
				connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE))
				return
			end

		end

		Log:debug("AnimalMoveEvent:run: all %d animals validated, starting transfer", validatedCount)

		local clusterSystemSource = self.sourceObject:getClusterSystem()
		Log:trace("AnimalMoveEvent:run: got source cluster system: %s", tostring(clusterSystemSource))

		-- Check for EPP age constraints on target
		local eppTypeData = nil
		if self.targetObject.animalsTypeData ~= nil and #self.animals > 0 then
			local subType = g_currentMission.animalSystem:getSubTypeByIndex(self.animals[1].subTypeIndex)
			if subType ~= nil then
				eppTypeData = self.targetObject.animalsTypeData[subType.typeIndex]
			end
			Log:trace("AnimalMoveEvent:run: EPP typeData=%s", tostring(eppTypeData))
		end

		-- Pass 1: EPP filter + source-cluster lookup. Pre-resolving source references here
		-- avoids a second linear scan inside addPendingRemoveCluster, and skipping EPP-failed
		-- animals at this stage keeps them out of both pending queues entirely.
		local targetClusterSystem = self.targetObject:getClusterSystem()
		local transferList = {}
		for i, animal in pairs(self.animals) do
			Log:trace("AnimalMoveEvent:run: processing animal %d id='%s' age=%s",
				i, tostring(animal.uniqueId), tostring(animal.age))

			local skip = false
			if eppTypeData ~= nil then
				local age = animal.age or 0
				local minAge = eppTypeData.minimumAge or 0
				local maxAge = eppTypeData.maximumAge or 999
				if age < minAge or age > maxAge then
					Log:trace("AnimalMoveEvent:run: skipping animal '%s' age=%d (EPP range %d-%d)",
						animal.uniqueId or "?", age, minAge, maxAge)
					skip = true
				end
			end

			if not skip then
				local clusterId = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country)
				local sourceCluster = clusterSystemSource:getClusterById(clusterId)
				if sourceCluster ~= nil then
					table.insert(transferList, { animal = animal, sourceCluster = sourceCluster })
				else
					Log:warning("AnimalMoveEvent:run: source cluster not found for clusterId='%s' (skipping)",
						tostring(clusterId))
				end
			end
		end

		-- Pass 2: source-first flush order is mandatory (RLRM-213). Target's updateClusters
		-- tail-calls updateVisualAnimals, which reassigns animal.idFull on the shared Animal
		-- entity for any animal target visualizes. If we flushed target first, source's
		-- removeCluster would read target's engine handle and miss its own
		-- husbandryIdsToVisualAnimalCount lookup, leaving source's visualCount stuck and
		-- source's engine-side visual chickens never freed (visual leak + add-back failure).
		-- Order: queue source -> flush source (source's idFull is still source's) -> clear
		-- stale id/idFull -> queue target -> flush target. Independent pcalls so a flush
		-- failure on one cluster system does not skip the other, otherwise the queued
		-- mutation auto-flushes on the next frame's update(dt) and the move appears
		-- non-atomic during the gap. Snapshot logging makes drift observable in the log.
		local ok1, err1 = pcall(function()
			for _, entry in ipairs(transferList) do
				clusterSystemSource:addPendingRemoveCluster(entry.sourceCluster)
			end
		end)
		AnimalMoveEvent._logVisualCountSnapshot("source", "before", clusterSystemSource)
		local ok2, err2 = pcall(function() clusterSystemSource:updateNow() end)
		AnimalMoveEvent._logVisualCountSnapshot("source", "after", clusterSystemSource)

		local ok3, err3 = pcall(function()
			for _, entry in ipairs(transferList) do
				entry.animal.id, entry.animal.idFull = nil, nil
				targetClusterSystem:addPendingAddCluster(entry.animal)
			end
		end)
		AnimalMoveEvent._logVisualCountSnapshot("target", "before", targetClusterSystem)
		local ok4, err4 = pcall(function() targetClusterSystem:updateNow() end)
		AnimalMoveEvent._logVisualCountSnapshot("target", "after", targetClusterSystem)

		local okAll = ok1 and ok2 and ok3 and ok4

		if okAll then
			Log:debug("AnimalMoveEvent:run: transfer complete N=%d source=%s target=%s, sending success",
				#transferList,
				tostring(self.sourceObject and self.sourceObject.getName and self.sourceObject:getName()),
				tostring(self.targetObject and self.targetObject.getName and self.targetObject:getName()))
			connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_SUCCESS))
		else
			Log:error("AnimalMoveEvent:run: batch failed N=%d sourceQueue=%s sourceFlush=%s targetQueue=%s targetFlush=%s",
				#transferList, tostring(err1), tostring(err2), tostring(err3), tostring(err4))
			connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_ERROR_INVALID_CLUSTER))
			return
		end

		if g_server ~= nil and not g_server.netIsRunning then return end

		local husbandry, trailer

		if self.moveType == "SOURCE" then
			husbandry, trailer = self.sourceObject, self.targetObject
		else
			husbandry, trailer = self.targetObject, self.sourceObject
		end

		if husbandry.addRLMessage ~= nil then
			if #self.animals == 1 then
				husbandry:addRLMessage(string.format("MOVED_ANIMALS_%s_SINGLE", self.moveType), nil, { trailer:getName() })
			elseif #self.animals > 0 then
				husbandry:addRLMessage(string.format("MOVED_ANIMALS_%s_MULTIPLE", self.moveType), nil, { #self.animals, trailer:getName() })
			end
		end

		Log:debug("AnimalMoveEvent:run: complete")

	end)

end


function AnimalMoveEvent.validate(sourceObject, targetObject, farmId, subTypeIndex)

	if sourceObject == nil then return AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST end

	if targetObject == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end

	if not g_currentMission.accessHandler:canFarmAccess(farmId, sourceObject) or not g_currentMission.accessHandler:canFarmAccess(farmId, targetObject) then return AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION end

	if not targetObject:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end

	if targetObject:getNumOfFreeAnimalSlots(subTypeIndex) < 1 then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end

	return nil

end
