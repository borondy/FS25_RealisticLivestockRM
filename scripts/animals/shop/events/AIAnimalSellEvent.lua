AIAnimalSellEvent = {}

local AIAnimalSellEvent_mt = Class(AIAnimalSellEvent, Event)
InitEventClass(AIAnimalSellEvent, "AIAnimalSellEvent")


function AIAnimalSellEvent.emptyNew()

    local self = Event.new(AIAnimalSellEvent_mt)
    return self

end


function AIAnimalSellEvent.new(object, animals, price)

	local event = AIAnimalSellEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.price = price

	return event

end


function AIAnimalSellEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	local numAnimals = streamReadUInt16(streamId)

	self.animals = {}

	for i = 1, numAnimals do

		local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
		table.insert(self.animals, identifiers)

	end

	self.price = streamReadFloat32(streamId)

	self:run(connection)

end


function AIAnimalSellEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for _, animal in pairs(self.animals) do RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection) end

	streamWriteFloat32(streamId, self.price)

end


function AIAnimalSellEvent:run(connection)

	Log:trace("AIAnimalSellEvent:run selling %d animals server=%s",
		#self.animals, tostring(g_server ~= nil))

	-- Server-only: clients sync via the AnimalClusterUpdateEvent broadcast that fires
	-- from the server's updateNow flush. The pending API asserts isServer, so clients
	-- must skip the whole cluster mutation block to avoid crashing.
	if g_server == nil then return end

	local clusterSystem = self.object:getClusterSystem()

	-- Resolve cluster references up front; missing entries are logged once and dropped.
	local clustersToRemove = {}
	for _, identifier in pairs(self.animals) do
		local key = RLAnimalUtil.toKeyFromIdentifiers(identifier)
		local cluster = clusterSystem:getClusterById(key)
		if cluster ~= nil then
			table.insert(clustersToRemove, cluster)
		else
			Log:warning("AIAnimalSellEvent:run: cluster not found for key=%s", tostring(key))
		end
	end

	local ok, err = pcall(function()
		for _, cluster in ipairs(clustersToRemove) do
			clusterSystem:addPendingRemoveCluster(cluster)
		end
	end)
	local ok2, err2 = pcall(function() clusterSystem:updateNow() end)

	if ok and ok2 then
		local farmId = self.object:getOwnerFarmId()
		g_currentMission:addMoney(self.price, farmId, MoneyType.SOLD_ANIMALS, true, true)

		Log:debug("AIAnimalSellEvent:run: sold %d animals farmId=%s price=%s",
			#clustersToRemove, tostring(farmId), tostring(self.price))
	else
		Log:error("AIAnimalSellEvent:run: batch failed N=%d queue=%s flush=%s",
			#clustersToRemove, tostring(err), tostring(err2))
	end

end


function AIAnimalSellEvent.validate(object, numAnimals, price, farmId)

	if object == nil then return AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST end
	
	return nil

end