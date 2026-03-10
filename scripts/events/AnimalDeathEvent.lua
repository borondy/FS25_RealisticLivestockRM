AnimalDeathEvent = {}

local AnimalDeathEvent_mt = Class(AnimalDeathEvent, Event)
InitEventClass(AnimalDeathEvent, "AnimalDeathEvent")


function AnimalDeathEvent.emptyNew()
    local self = Event.new(AnimalDeathEvent_mt)
    return self
end


function AnimalDeathEvent.new(object, animal)

    local self = AnimalDeathEvent.emptyNew()

    self.object = object
    self.animal = animal

    return self

end


function AnimalDeathEvent:readStream(streamId, connection)

    local hasObject = streamReadBool(streamId)

    self.object = hasObject and NetworkUtil.readNodeObject(streamId) or nil
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    self:run(connection)

end


function AnimalDeathEvent:writeStream(streamId, connection)

    streamWriteBool(streamId, self.object ~= nil)

    if self.object ~= nil then NetworkUtil.writeNodeObject(streamId, self.object) end
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

end


--- Remove dead animal from herd. Uses findAndRemove for non-cluster path (animalSystem)
--- or removeCluster with toKeyFromIdentifiers for cluster path (husbandry).
function AnimalDeathEvent:run(connection)

    local identifiers = self.animal

    if self.object == nil then
        local animals = g_currentMission.animalSystem.animals[identifiers.animalTypeIndex]
        RLAnimalUtil.findAndRemove(animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)
    else
        self.object:getClusterSystem():removeCluster(RLAnimalUtil.toKeyFromIdentifiers(identifiers))
    end

    Log:trace("DeathEvent:run removed uniqueId=%s cluster=%s", tostring(identifiers.uniqueId), tostring(self.object ~= nil))

end