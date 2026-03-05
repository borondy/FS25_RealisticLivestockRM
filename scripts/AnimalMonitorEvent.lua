AnimalMonitorEvent = {}

local AnimalMonitorEvent_mt = Class(AnimalMonitorEvent, Event)
InitEventClass(AnimalMonitorEvent, "AnimalMonitorEvent")


function AnimalMonitorEvent.emptyNew()
    local self = Event.new(AnimalMonitorEvent_mt)
    return self
end


function AnimalMonitorEvent.new(object, animal, active, removed)

    local self = AnimalMonitorEvent.emptyNew()

    self.object = object
    self.animal = animal
    self.active = active
    self.removed = removed

    return self

end


function AnimalMonitorEvent:readStream(streamId, connection)

    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    self.active = streamReadBool(streamId)
    self.removed = streamReadBool(streamId)

    self:run(connection)

end


function AnimalMonitorEvent:writeStream(streamId, connection)

    NetworkUtil.writeNodeObject(streamId, self.object)
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

    streamWriteBool(streamId, self.active)
    streamWriteBool(streamId, self.removed)

end


function AnimalMonitorEvent:run(connection)

    local identifiers = self.animal
    local clusterSystem = self.object:getClusterSystem()

    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        animal.monitor.active = self.active
        animal.monitor.removed = self.removed
        Log:trace("MonitorEvent:run updated %s active=%s removed=%s",
            tostring(identifiers.uniqueId), tostring(self.active), tostring(self.removed))
    else
        Log:trace("MonitorEvent:run animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end

end


function AnimalMonitorEvent.sendEvent(object, animal, active, removed)

    if g_server ~= nil then
        g_server:broadcastEvent(AnimalMonitorEvent.new(object, animal, active, removed))
    else
        g_client:getServerConnection():sendEvent(AnimalMonitorEvent.new(object, animal, active, removed))
    end

end