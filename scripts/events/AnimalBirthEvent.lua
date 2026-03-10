AnimalBirthEvent = {}

local AnimalBirthEvent_mt = Class(AnimalBirthEvent, Event)
InitEventClass(AnimalBirthEvent, "AnimalBirthEvent")


function AnimalBirthEvent.emptyNew()
    local self = Event.new(AnimalBirthEvent_mt)
    return self
end


function AnimalBirthEvent.new(object, animal, children, parentDied)

    local self = AnimalBirthEvent.emptyNew()

    self.object = object
    self.animal = animal
    self.children = children or {}
    self.parentDied = parentDied or false

    return self

end


function AnimalBirthEvent:readStream(streamId, connection)

    local hasObject = streamReadBool(streamId)

    self.object = hasObject and NetworkUtil.readNodeObject(streamId) or nil
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    local numChildren = streamReadUInt8(streamId)
    self.children = {}

    for i = 1, numChildren do
        local child = Animal.new()
        child:readStream(streamId, connection)
        table.insert(self.children, child)
    end

    self.parentDied = streamReadBool(streamId)

    self:run(connection)

end


function AnimalBirthEvent:writeStream(streamId, connection)

    streamWriteBool(streamId, self.object ~= nil)

    if self.object ~= nil then NetworkUtil.writeNodeObject(streamId, self.object) end
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

    streamWriteUInt8(streamId, #self.children)

    for _, child in pairs(self.children) do child:writeStream(streamId, connection) end

    streamWriteBool(streamId, self.parentDied)

end


--- Process birth on receiving end: add children to herd, update parent state (clear pregnancy,
--- set lactating for cows/goats), and optionally remove parent if she died during birth.
--- Handles both cluster path (husbandry) and non-cluster path (animalSystem) independently.
function AnimalBirthEvent:run(connection)

    local identifiers = self.animal

    local country = identifiers.country or identifiers.birthday.country

    Log:trace("BirthEvent:run uniqueId=%s children=%d parentDied=%s cluster=%s",
        tostring(identifiers.uniqueId), #self.children, tostring(self.parentDied), tostring(self.object ~= nil))

    if self.object == nil then

        local animals = g_currentMission.animalSystem.animals[identifiers.animalTypeIndex]

        for _, child in pairs(self.children) do table.insert(animals, child) end

        local parent = RLAnimalUtil.find(animals, identifiers.farmId, identifiers.uniqueId, country)

        if parent ~= nil then
            parent.isParent = true
            parent.monthsSinceLastBirth = 0
            parent.pregnancy = nil
            parent.impregnatedBy = nil
            parent.isPregnant = false
            parent.reproduction = 0

            if parent.animalTypeIndex == AnimalType.COW or parent.subType == "GOAT" then parent.isLactating = true end

            if self.parentDied then RLAnimalUtil.findAndRemove(animals, identifiers.farmId, identifiers.uniqueId, country) end
        else
            Log:trace("BirthEvent:run parent not found uniqueId=%s", tostring(identifiers.uniqueId))
        end

    else

        local clusterSystem = self.object:getClusterSystem()

        for _, child in pairs(self.children) do clusterSystem:addCluster(child) end

        local parent = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, country)

        if parent ~= nil then
            parent.isParent = true
            parent.monthsSinceLastBirth = 0
            parent.pregnancy = nil
            parent.impregnatedBy = nil
            parent.isPregnant = false
            parent.reproduction = 0

            if parent.animalTypeIndex == AnimalType.COW or parent.subType == "GOAT" then parent.isLactating = true end
        else
            Log:trace("BirthEvent:run parent not found uniqueId=%s (cluster)", tostring(identifiers.uniqueId))
        end

        if self.parentDied then clusterSystem:removeCluster(RLAnimalUtil.toKeyFromIdentifiers(identifiers)) end

    end

end