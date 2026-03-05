AnimalInseminationResultEvent = {}

local AnimalInseminationResultEvent_mt = Class(AnimalInseminationResultEvent, Event)
InitEventClass(AnimalInseminationResultEvent, "AnimalInseminationResultEvent")


function AnimalInseminationResultEvent.emptyNew()

    local self = Event.new(AnimalInseminationResultEvent_mt)
    return self

end


function AnimalInseminationResultEvent.new(object, animal, success)

	local event = AnimalInseminationResultEvent.emptyNew()

	event.object = object
	event.animal = animal
	event.success = success

	return event

end


function AnimalInseminationResultEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
	self.success = streamReadBool(streamId)

	self:run(connection)

end


function AnimalInseminationResultEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)
	RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
	streamWriteBool(streamId, self.success)

end


function AnimalInseminationResultEvent:run(connection)

	if g_server ~= nil and not g_server.netIsRunning then return end

	local clusterSystem = self.object:getClusterSystem()
	local identifiers = self.animal

	local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

	if animal ~= nil then
		animal:addMessage(string.format("INSEMINATION_%s", self.success and "SUCCESS" or "FAIL"))
		Log:trace("InseminationResultEvent:run %s success=%s", tostring(identifiers.uniqueId), tostring(self.success))
	else
		Log:trace("InseminationResultEvent:run animal not found uniqueId=%s", tostring(identifiers.uniqueId))
	end

end