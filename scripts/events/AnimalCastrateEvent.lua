AnimalCastrateEvent = {}

local AnimalCastrateEvent_mt = Class(AnimalCastrateEvent, Event)
InitEventClass(AnimalCastrateEvent, "AnimalCastrateEvent")


--- @return table self
function AnimalCastrateEvent.emptyNew()
    local self = Event.new(AnimalCastrateEvent_mt)
    return self
end


--- Castrate an animal (set isCastrated=true, fertility=0).
--- @param object table Husbandry placeable (animal.clusterSystem.owner)
--- @param animal table Animal object or identifiers table
--- @return table self
function AnimalCastrateEvent.new(object, animal)
    local self = AnimalCastrateEvent.emptyNew()
    self.object = object
    self.animal = animal
    return self
end


--- Wire format: nodeObject + identifiers.
--- @param streamId number
--- @param connection table
function AnimalCastrateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
end


--- @param streamId number
--- @param connection table
function AnimalCastrateEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
    self:run(connection)
end


--- Apply castration mutation. Rebroadcasts from server to other clients.
--- @param connection table Network connection the event arrived on
function AnimalCastrateEvent:run(connection)
    if self.object == nil then
        Log:warning("AnimalCastrateEvent:run: nil object (stale husbandry?), aborting")
        return
    end

    if not connection:getIsServer() then
        g_server:broadcastEvent(
            AnimalCastrateEvent.new(self.object, self.animal),
            nil, connection, nil)
        Log:debug("AnimalCastrateEvent:run: rebroadcasting castrate to other clients")
    end

    local identifiers = self.animal
    local clusterSystem = self.object:getClusterSystem()
    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        animal.isCastrated = true
        if animal.genetics ~= nil then
            animal.genetics.fertility = 0
        end
        Log:trace("AnimalCastrateEvent:run: castrated uniqueId=%s", tostring(identifiers.uniqueId))
    else
        Log:warning("AnimalCastrateEvent:run: animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end
end


--- Broadcast (server) or send to server (client). Caller must mutate locally first.
--- @param object table Husbandry placeable
--- @param animal table Animal object
function AnimalCastrateEvent.sendEvent(object, animal)
    if g_server ~= nil then
        g_server:broadcastEvent(AnimalCastrateEvent.new(object, animal))
    else
        g_client:getServerConnection():sendEvent(AnimalCastrateEvent.new(object, animal))
    end
end
