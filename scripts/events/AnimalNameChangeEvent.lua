AnimalNameChangeEvent = {}

local AnimalNameChangeEvent_mt = Class(AnimalNameChangeEvent, Event)
InitEventClass(AnimalNameChangeEvent, "AnimalNameChangeEvent")


function AnimalNameChangeEvent.emptyNew()
    local self = Event.new(AnimalNameChangeEvent_mt)
    return self
end


function AnimalNameChangeEvent.new(object, animal, name)

    local self = AnimalNameChangeEvent.emptyNew()

    self.object = object
    self.animal = animal
    self.name = name

    return self

end


function AnimalNameChangeEvent:readStream(streamId, connection)

    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    local hasName = streamReadBool(streamId)

    if hasName then self.name = streamReadString(streamId) end

    self:run(connection)

end


function AnimalNameChangeEvent:writeStream(streamId, connection)

    NetworkUtil.writeNodeObject(streamId, self.object)
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

    streamWriteBool(streamId, self.name ~= nil and self.name ~= "")

    if self.name ~= nil and self.name ~= "" then streamWriteString(streamId, self.name) end

end


function AnimalNameChangeEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(
            AnimalNameChangeEvent.new(self.object, self.animal, self.name),
            nil, connection, nil)
        Log:debug("AnimalNameChangeEvent:run: rebroadcasting name change to other clients")
    end

    local identifiers = self.animal
    local clusterSystem = self.object:getClusterSystem()
    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        animal.name = self.name
        Log:trace("AnimalNameChangeEvent:run: renamed uniqueId=%s to '%s'", tostring(identifiers.uniqueId), tostring(self.name))
    else
        Log:warning("AnimalNameChangeEvent:run: animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end
end


function AnimalNameChangeEvent.sendEvent(object, animal, name)

    if g_server ~= nil then
        g_server:broadcastEvent(AnimalNameChangeEvent.new(object, animal, name))
    else
        g_client:getServerConnection():sendEvent(AnimalNameChangeEvent.new(object, animal, name))
    end

end