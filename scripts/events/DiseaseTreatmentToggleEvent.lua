DiseaseTreatmentToggleEvent = {}
local DiseaseTreatmentToggleEvent_mt = Class(DiseaseTreatmentToggleEvent, Event)
InitEventClass(DiseaseTreatmentToggleEvent, "DiseaseTreatmentToggleEvent")

function DiseaseTreatmentToggleEvent.emptyNew()
    local self = Event.new(DiseaseTreatmentToggleEvent_mt)
    return self
end

function DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, beingTreated)
    local self = DiseaseTreatmentToggleEvent.emptyNew()
    self.object = object
    self.animal = animal
    self.diseaseTitle = diseaseTitle
    self.beingTreated = beingTreated
    return self
end

function DiseaseTreatmentToggleEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
    self.diseaseTitle = streamReadString(streamId)
    self.beingTreated = streamReadBool(streamId)
    self:run(connection)
end

function DiseaseTreatmentToggleEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
    streamWriteString(streamId, self.diseaseTitle)
    streamWriteBool(streamId, self.beingTreated)
end

function DiseaseTreatmentToggleEvent:run(connection)
    local identifiers = self.animal
    local clusterSystem = self.object:getClusterSystem()

    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        for _, disease in pairs(animal.diseases) do
            if disease.type.title == self.diseaseTitle then
                disease.beingTreated = self.beingTreated
                Log:trace("DiseaseTreatmentToggleEvent:run %s treatment=%s",
                    self.diseaseTitle, tostring(self.beingTreated))
                return
            end
        end
        Log:trace("DiseaseTreatmentToggleEvent:run disease '%s' not found on %s", self.diseaseTitle, tostring(identifiers.uniqueId))
    else
        Log:trace("DiseaseTreatmentToggleEvent:run animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end
end

function DiseaseTreatmentToggleEvent.sendEvent(object, animal, diseaseTitle, beingTreated)
    if g_server ~= nil then
        g_server:broadcastEvent(DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, beingTreated))
    else
        g_client:getServerConnection():sendEvent(DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, beingTreated))
    end
end
