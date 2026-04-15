function AnimalSellEvent.new(object, animals, price, transportPrice)

	local event = AnimalSellEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.price = price
	event.transportPrice = transportPrice

	return event

end


function AnimalSellEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, 3)

	else

		self.object = NetworkUtil.readNodeObject(streamId)
		local numAnimals = streamReadUInt16(streamId)

		self.animals = {}

		for i = 1, numAnimals do

			local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
			table.insert(self.animals, identifiers)

		end

		self.price = streamReadFloat32(streamId)
		self.transportPrice = streamReadFloat32(streamId)

	end

	self:run(connection)

end


function AnimalSellEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		streamWriteUIntN(streamId, self.errorCode, 3)
		return
	end

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for i, animal in pairs(self.animals) do
		RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection)
	end

	streamWriteFloat32(streamId, self.price)
	streamWriteFloat32(streamId, self.transportPrice)

end


function AnimalSellEvent:run(connection)

	if connection:getIsServer() then

		g_messageCenter:publish(AnimalSellEvent, self.errorCode)
		return

	end

	if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then

		connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_ERROR_NO_PERMISSION))
		return

	end

	local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
	local farmId = g_farmManager:getFarmForUniqueUserId(userId).farmId

	local clusterSystem = self.object:getClusterSystem()

	Log:trace("SellEvent:run selling %d animals", #self.animals)

	-- Pass 1: pre-validate all animals before removing any (prevents partial removal on blocked batch)
	for i, identifier in pairs(self.animals) do
		local key = RLAnimalUtil.toKeyFromIdentifiers(identifier)
		Log:trace("SellEvent:run pass1 [%d] key=%s", i, tostring(key))
		if key ~= nil then
			local animal = self.object:getClusterById(key)
			Log:trace("SellEvent:run pass1 [%d] found=%s name=%s canBeSold=%s getCanBeSold=%s",
				i, tostring(animal ~= nil), animal and (animal.name or "?") or "nil",
				tostring(animal and animal.canBeSold), tostring(animal and animal:getCanBeSold()))
			if animal ~= nil and not animal:getCanBeSold() then
				Log:warning("SellEvent:run blocked sell of non-sellable animal (name=%s, uniqueId=%s, farmId=%s)",
					animal.name or "?", animal.uniqueId or "?", animal.farmId or "?")
				connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD))
				return
			end
		end
	end

	-- Pass 2: all animals validated, now remove
	for i, identifier in pairs(self.animals) do
		local key = RLAnimalUtil.toKeyFromIdentifiers(identifier)
		if key ~= nil then
			clusterSystem:removeCluster(key)
		end
	end

	g_currentMission:addMoney(self.price + self.transportPrice, farmId, MoneyType.SOLD_ANIMALS, true, true)
	connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_SUCCESS))

	if g_server ~= nil and not g_server.netIsRunning then return end

	if #self.animals == 1 then
        self.object:addRLMessage("SOLD_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(math.abs(self.price + self.transportPrice), 2, true, true) })
    elseif #self.animals > 0 then
        self.object:addRLMessage("SOLD_ANIMALS_MULTIPLE", nil, { #self.animals, g_i18n:formatMoney(math.abs(self.price + self.transportPrice), 2, true, true) })
    end

end