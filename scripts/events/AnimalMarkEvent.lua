AnimalMarkEvent = {}

local AnimalMarkEvent_mt = Class(AnimalMarkEvent, Event)
InitEventClass(AnimalMarkEvent, "AnimalMarkEvent")


--- @return table self
function AnimalMarkEvent.emptyNew()
    local self = Event.new(AnimalMarkEvent_mt)
    return self
end


--- Mark or unmark an animal. Pass key=nil to clear all marks (by design).
--- @param object table Husbandry placeable (animal.clusterSystem.owner)
--- @param animal table Animal object or identifiers table
--- @param key string|nil Mark key ("PLAYER") or nil for clear-all
--- @param active boolean Whether to activate or deactivate the mark
--- @return table self
function AnimalMarkEvent.new(object, animal, key, active)
    local self = AnimalMarkEvent.emptyNew()
    self.object = object
    self.animal = animal
    self.key = key
    self.active = active
    return self
end


--- Wire format: nodeObject + identifiers + hasKey(bool) + [key(string)] + active(bool).
--- @param streamId number
--- @param connection table
function AnimalMarkEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

    local hasKey = self.key ~= nil
    streamWriteBool(streamId, hasKey)
    if hasKey then
        streamWriteString(streamId, self.key)
    end
    streamWriteBool(streamId, self.active)
end


--- @param streamId number
--- @param connection table
function AnimalMarkEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    local hasKey = streamReadBool(streamId)
    if hasKey then
        self.key = streamReadString(streamId)
    else
        self.key = nil
    end
    self.active = streamReadBool(streamId)

    self:run(connection)
end


--- Apply mark mutation. Rebroadcasts from server to other clients.
--- @param connection table Network connection the event arrived on
function AnimalMarkEvent:run(connection)
    if self.object == nil then
        Log:warning("AnimalMarkEvent:run: nil object (stale husbandry?), aborting")
        return
    end

    if not connection:getIsServer() then
        g_server:broadcastEvent(
            AnimalMarkEvent.new(self.object, self.animal, self.key, self.active),
            nil, connection, nil)
        Log:debug("AnimalMarkEvent:run: rebroadcasting mark change to other clients")
    end

    local identifiers = self.animal
    local clusterSystem = self.object:getClusterSystem()
    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        animal:setMarked(self.key, self.active)
        Log:trace("AnimalMarkEvent:run: uniqueId=%s key=%s active=%s",
            tostring(identifiers.uniqueId), tostring(self.key), tostring(self.active))
    else
        Log:warning("AnimalMarkEvent:run: animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end
end


--- Broadcast (server) or send to server (client). Caller must mutate locally first.
--- @param object table Husbandry placeable
--- @param animal table Animal object
--- @param key string|nil Mark key or nil for clear-all
--- @param active boolean
function AnimalMarkEvent.sendEvent(object, animal, key, active)
    if g_server ~= nil then
        g_server:broadcastEvent(AnimalMarkEvent.new(object, animal, key, active))
    else
        g_client:getServerConnection():sendEvent(AnimalMarkEvent.new(object, animal, key, active))
    end
end
