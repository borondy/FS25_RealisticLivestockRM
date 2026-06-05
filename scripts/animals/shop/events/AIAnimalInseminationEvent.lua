AIAnimalInseminationEvent = {}

local AIAnimalInseminationEvent_mt = Class(AIAnimalInseminationEvent, Event)
InitEventClass(AIAnimalInseminationEvent, "AIAnimalInseminationEvent")


function AIAnimalInseminationEvent.emptyNew()

    local self = Event.new(AIAnimalInseminationEvent_mt)
    return self

end


function AIAnimalInseminationEvent.new(object, items)

	local event = AIAnimalInseminationEvent.emptyNew()

	event.object = object
	event.items = items

	return event

end


function AIAnimalInseminationEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	local numItems = streamReadUInt16(streamId)

	self.items = {}

	for i = 1, numItems do

		local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
		local dewarUniqueId = streamReadString(streamId)

		table.insert(self.items, { ["animal"] = identifiers, ["dewar"] = dewarUniqueId })

	end

	self:run(connection)

end


function AIAnimalInseminationEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.items)

	for _, item in pairs(self.items) do
		
		RLAnimalUtil.writeStreamIdentifiers(item.animal, streamId, connection)
		streamWriteString(streamId, item.dewar)
		Log:trace("AIInseminationEvent:writeStream dewar=%s", tostring(item.dewar))

	end

end


--- Execute the event on the receiver.
---
--- Pattern A flow (caller-mutates-first + rebroadcast-from-run + ignoreConnection=sender):
---   * Caller (AnimalAIDialog:onClickOk) mutates local dewar + animal BEFORE sendEvent.
---   * Server branch (`not connection:getIsServer()`): validate dewar match per item,
---     decouple dewar decrement from animal lookup, apply idempotency
---     guard, then rebroadcast to other clients with ignoreConnection=sender.
---   * Client branch (`connection:getIsServer()`): apply mutation locally, no rebroadcast.
---@param connection table Network connection the event arrived on
function AIAnimalInseminationEvent:run(connection)

	RmSafeUtils.safeCall("AIAnimalInseminationEvent:run", function()

		local clusterSystem = self.object:getClusterSystem()
		local farmId = self.object:getOwnerFarmId()
		local farmDewars = g_dewarManager:getDewarsByFarm(farmId)

		if farmDewars == nil then
			Log:debug("AIInseminationEvent:run no dewars for farmId=%s, aborting", tostring(farmId))
			return
		end

		local isServerBranch = not connection:getIsServer()
		Log:trace("AIInseminationEvent:run branch=%s items=%d", isServerBranch and "server" or "client", #self.items)

		for _, item in pairs(self.items) do

			local dewars = farmDewars[item.animal.animalTypeIndex]

			if dewars == nil or #dewars == 0 then continue end

			local identifiers = item.animal

			for _, dewar in pairs(dewars) do

				if dewar:getUniqueId() == item.dewar then

					local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

					if isServerBranch then
						-- Server: dewar uniqueId match confirms straw was spent.
						-- Decrement is decoupled from animal lookup.
						if animal == nil then
							Log:warning("AIInseminationEvent:run animal not found uniqueId=%s (still decrementing dewar=%s)",
								tostring(identifiers.uniqueId), tostring(item.dewar))
							dewar:changeStraws(-1)
						elseif animal.isInseminated then
							Log:debug("AIInseminationEvent:run skipping (already inseminated) uniqueId=%s",
								tostring(identifiers.uniqueId))
						else
							animal:setInsemination(dewar.animal)
							dewar:changeStraws(-1)
							Log:info("AIInseminationEvent:run applied uniqueId=%s dewar=%s",
								tostring(identifiers.uniqueId), tostring(item.dewar))
						end
					else
						-- Client (rebroadcast from server): apply mutation locally.
						if animal ~= nil and not animal.isInseminated then
							animal:setInsemination(dewar.animal)
							dewar:changeStraws(-1)
							Log:debug("AIInseminationEvent:run client-applied uniqueId=%s dewar=%s",
								tostring(identifiers.uniqueId), tostring(item.dewar))
						else
							Log:trace("AIInseminationEvent:run client-skip animal=%s inseminated=%s",
								tostring(animal), tostring(animal and animal.isInseminated))
						end
					end

					break

				end

			end

		end

		if isServerBranch then
			-- Rebroadcast to other clients excluding sender (Pattern A).
			-- Sender mutated locally before sendEvent and must not receive an echo.
			g_server:broadcastEvent(
				AIAnimalInseminationEvent.new(self.object, self.items),
				nil, connection, nil)
			Log:trace("AIInseminationEvent:run rebroadcast ignoreConnection=sender items=%d", #self.items)
		end

	end)

end


--- Thin dispatch: broadcast to clients if we are the server, otherwise
--- send to the server. The caller (AnimalAIDialog:onClickOk) MUST have
--- already mutated local state (dewar + animal) before calling this.
---@param object table Husbandry placeable
---@param items table Array of {animal=identifiers, dewar=uniqueId} pairs
function AIAnimalInseminationEvent.sendEvent(object, items)
    if g_server ~= nil then
        g_server:broadcastEvent(AIAnimalInseminationEvent.new(object, items))
    else
        g_client:getServerConnection():sendEvent(AIAnimalInseminationEvent.new(object, items))
    end
end