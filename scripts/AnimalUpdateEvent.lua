AnimalUpdateEvent = {}

local AnimalUpdateEvent_mt = Class(AnimalUpdateEvent, Event)
InitEventClass(AnimalUpdateEvent, "AnimalUpdateEvent")


function AnimalUpdateEvent.emptyNew()
    local self = Event.new(AnimalUpdateEvent_mt)
    return self
end


function AnimalUpdateEvent.new(object, animal, trait, value)

    local self = AnimalUpdateEvent.emptyNew()

    self.object = object
    self.animal = animal
    self.trait = trait
    self.value = value

    return self

end


function AnimalUpdateEvent:readStream(streamId, connection)

    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    self.trait = streamReadString(streamId)
    local valueType = streamReadString(streamId)

    if valueType == "number" then
        self.value = streamReadFloat32(streamId)
    elseif valueType == "string" then
        self.value = streamReadString(streamId)
    else
        self.value = streamReadBool(streamId)
    end

    self:run(connection)

end


function AnimalUpdateEvent:writeStream(streamId, connection)

    NetworkUtil.writeNodeObject(streamId, self.object)
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
    streamWriteString(streamId, self.trait)
    
    local valueType = type(self.value)
    streamWriteString(streamId, valueType)

    if valueType == "number" then
        streamWriteFloat32(streamId, self.value)
    elseif valueType == "string" then
        streamWriteString(streamId, self.value)
    else
        streamWriteBool(streamId, self.value)
    end

end


function AnimalUpdateEvent:run(connection)

    local clusterSystem = self.object:getClusterSystem()
    local identifiers = self.animal

    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil and animal.animalTypeIndex == identifiers.animalTypeIndex then
        animal[self.trait] = self.value
        Log:trace("UpdateEvent:run set %s.%s=%s", tostring(identifiers.uniqueId), tostring(self.trait), tostring(self.value))
    else
        Log:trace("UpdateEvent:run animal not found or type mismatch uniqueId=%s", tostring(identifiers.uniqueId))
    end

end