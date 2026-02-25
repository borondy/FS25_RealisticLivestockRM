local Log = RmLogging.getLogger("RLRM")

RL_AnimalScreenTrailerFarm = {}

function RL_AnimalScreenTrailerFarm:initTargetItems(_)

    self.targetItems = {}
    local animals = self.husbandry:getClusters()

    if animals ~= nil then
        for _, animal in pairs(animals) do
            local item = AnimalItemStock.new(animal)
            table.insert(self.targetItems, item)
        end
    end

end

AnimalScreenTrailerFarm.initTargetItems = Utils.overwrittenFunction(AnimalScreenTrailerFarm.initTargetItems, RL_AnimalScreenTrailerFarm.initTargetItems)


function RL_AnimalScreenTrailerFarm:initSourceItems(_)

    self.sourceItems = {}

    local animalType = self.trailer:getCurrentAnimalType()
    if animalType == nil then return end

    local animals = self.trailer:getClusters()

    if animals ~= nil then
        for _, animal in pairs(animals) do
            local item = AnimalItemStock.new(animal)

            if self.sourceItems[animalType.typeIndex] == nil then self.sourceItems[animalType.typeIndex] = {} end

            table.insert(self.sourceItems[animalType.typeIndex], item)
        end
    end


end

AnimalScreenTrailerFarm.initSourceItems = Utils.overwrittenFunction(AnimalScreenTrailerFarm.initSourceItems, RL_AnimalScreenTrailerFarm.initSourceItems)


function AnimalScreenTrailerFarm:applySourceBulk(animalTypeIndex, items)

    self.sourceAnimals = {}

    local trailer = self.trailer
    local husbandry = self.husbandry
    local ownerFarmId = trailer:getOwnerFarmId()

    local sourceItems = self.sourceItems[animalTypeIndex]
    local totalMovedAnimals = 0

    -- EPP age constraints (butchers with minimumAge/maximumAge)
    local eppTypeData = husbandry.animalsTypeData ~= nil and husbandry.animalsTypeData[animalTypeIndex] or nil

    if eppTypeData ~= nil then
        Log:debug("applySourceBulk: EPP age constraints found for typeIndex=%d (minAge=%s, maxAge=%s)",
            animalTypeIndex, tostring(eppTypeData.minimumAge), tostring(eppTypeData.maximumAge))
    end

    for _, item in pairs(items) do

        if sourceItems[item] ~= nil then

            local sourceItem = sourceItems[item]
            local animal = sourceItem.animal or sourceItem.cluster

            local errorCode = AnimalMoveEvent.validate(trailer, husbandry, ownerFarmId, animal.subTypeIndex)

            if errorCode ~= nil then
                Log:trace("applySourceBulk: skipping '%s' (validate error=%d)", animal.name or "?", errorCode)
                continue
            end

            if eppTypeData ~= nil then
                local age = animal.age or 0
                local minAge = eppTypeData.minimumAge or 0
                local maxAge = eppTypeData.maximumAge or 60
                Log:trace("applySourceBulk: checking '%s' age=%d against allowed=%d-%d", animal.name or "?", age, minAge, maxAge)
                if age < minAge or age > maxAge then
                    Log:debug("applySourceBulk: REJECTED '%s' (age=%d, allowed=%d-%d)", animal.name or "?", age, minAge, maxAge)
                    continue
                end
                Log:trace("applySourceBulk: PASSED '%s' age check", animal.name or "?")
            end

            if husbandry:getNumOfFreeAnimalSlots(animal.subTypeIndex) <= totalMovedAnimals then
                Log:trace("applySourceBulk: skipping '%s' (no free slots, already queued=%d)", animal.name or "?", totalMovedAnimals)
                continue
            end

            totalMovedAnimals = totalMovedAnimals + 1

            table.insert(self.sourceAnimals, animal)

        end

    end

    if #self.sourceAnimals == 0 then
        Log:debug("applySourceBulk: no animals passed validation, skipping event")
        return
    end

    Log:debug("applySourceBulk: sending %d of %d selected animals", totalMovedAnimals, #items)

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_SOURCE, g_i18n:getText(AnimalScreenTrailerFarm.L10N_SYMBOL.MOVE_TO_FARM))
	g_messageCenter:subscribe(AnimalMoveEvent, self.onAnimalMovedToFarm, self)
	g_client:getServerConnection():sendEvent(AnimalMoveEvent.new(trailer, husbandry, self.sourceAnimals, "TARGET"))

    if husbandry.addRLMessage ~= nil then
        if totalMovedAnimals == 1 then
            husbandry:addRLMessage("MOVED_ANIMALS_TARGET_SINGLE", nil, { trailer:getName() })
        elseif totalMovedAnimals > 0 then
            husbandry:addRLMessage("MOVED_ANIMALS_TARGET_MULTIPLE", nil, { totalMovedAnimals, trailer:getName() })
        end
    end

end


function AnimalScreenTrailerFarm:applyTargetBulk(animalTypeIndex, items)

    self.targetAnimals = {}

    local trailer = self.trailer
    local husbandry = self.husbandry
    local ownerFarmId = trailer:getOwnerFarmId()

    local targetItems = self.targetItems
    local totalMovedAnimals = 0

    for _, item in pairs(items) do

        if targetItems[item] ~= nil then

            local targetItem = targetItems[item]
            local animal = targetItem.animal or targetItem.cluster

            local errorCode = AnimalMoveEvent.validate(husbandry, trailer, ownerFarmId, animal.subTypeIndex)

            if errorCode ~= nil then continue end

            if trailer:getNumOfFreeAnimalSlots(animal.subTypeIndex) <= totalMovedAnimals then continue end

            totalMovedAnimals = totalMovedAnimals + 1

            table.insert(self.targetAnimals, animal)

        end

    end

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_TARGET, g_i18n:getText(AnimalScreenTrailerFarm.L10N_SYMBOL.MOVE_TO_TRAILER))
	g_messageCenter:subscribe(AnimalMoveEvent, self.onAnimalMovedToTrailer, self)
	g_client:getServerConnection():sendEvent(AnimalMoveEvent.new(husbandry, trailer, self.targetAnimals, "SOURCE"))

    if husbandry.addRLMessage ~= nil then
        if totalMovedAnimals == 1 then
            husbandry:addRLMessage("MOVED_ANIMALS_SOURCE_SINGLE", nil, { trailer:getName() })
        elseif totalMovedAnimals > 0 then
            husbandry:addRLMessage("MOVED_ANIMALS_SOURCE_MULTIPLE", nil, { totalMovedAnimals, trailer:getName() })
        end
    end

end


function RL_AnimalScreenTrailerFarm:applyTarget(_, _, animalIndex)

    self.targetAnimals = nil

    local trailer = self.trailer
    local husbandry = self.husbandry
    local ownerFarmId = trailer:getOwnerFarmId()
    local item = self.targetItems[animalIndex]

    local animal = item.animal or item.cluster

	local errorCode = AnimalMoveEvent.validate(husbandry, trailer, ownerFarmId, animal.subTypeIndex)

    if errorCode ~= nil then
		self.errorCallback(g_i18n:getText(AnimalScreenTrailerFarm.MOVE_TO_TRAILER_ERROR_CODE_MAPPING[errorCode].text))
		return false
	end

    self.targetAnimals = { animal }

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_TARGET, g_i18n:getText(AnimalScreenTrailerFarm.L10N_SYMBOL.MOVE_TO_TRAILER))
	g_messageCenter:subscribe(AnimalMoveEvent, self.onAnimalMovedToTrailer, self)
	g_client:getServerConnection():sendEvent(AnimalMoveEvent.new(husbandry, trailer, self.targetAnimals))

    if husbandry.addRLMessage ~= nil then
        husbandry:addRLMessage("MOVED_ANIMALS_SOURCE_SINGLE", nil, { trailer:getName() })
    end

    return true

end

AnimalScreenTrailerFarm.applyTarget = Utils.overwrittenFunction(AnimalScreenTrailerFarm.applyTarget, RL_AnimalScreenTrailerFarm.applyTarget)


function RL_AnimalScreenTrailerFarm:applySource(_, animalTypeIndex, animalIndex)

    self.sourceAnimals = nil

    local trailer = self.trailer
    local husbandry = self.husbandry
    local ownerFarmId = trailer:getOwnerFarmId()

    local sourceItems = self.sourceItems[animalTypeIndex]
    local item = sourceItems[animalIndex]
    local animal = item.animal or item.cluster

	local errorCode = AnimalMoveEvent.validate(trailer, husbandry, ownerFarmId, animal.subTypeIndex)

    if errorCode ~= nil then
		self.errorCallback(g_i18n:getText(AnimalScreenTrailerFarm.MOVE_TO_FARM_ERROR_CODE_MAPPING[errorCode].text))
		return false
	end

    self.sourceAnimals = { animal }

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_SOURCE, g_i18n:getText(AnimalScreenTrailerFarm.L10N_SYMBOL.MOVE_TO_FARM))
	g_messageCenter:subscribe(AnimalMoveEvent, self.onAnimalMovedToFarm, self)
	g_client:getServerConnection():sendEvent(AnimalMoveEvent.new(trailer, husbandry, self.sourceAnimals))

    if husbandry.addRLMessage ~= nil then
        husbandry:addRLMessage("MOVED_ANIMALS_TARGET_SINGLE", nil, { trailer:getName() })
    end

    return true

end

AnimalScreenTrailerFarm.applySource = Utils.overwrittenFunction(AnimalScreenTrailerFarm.applySource, RL_AnimalScreenTrailerFarm.applySource)