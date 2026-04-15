local Log = RmLogging.getLogger("RLRM")

RL_AnimalScreenTrailer = {}


function RL_AnimalScreenTrailer:initSourceItems(_)

    self.sourceItems = {}
    self.clusterToVehicle = {}
    local rideables = self.trailer:getRideablesInTrigger()
    if rideables == nil then return end

    for _, rideable in ipairs(rideables) do
        local cluster = rideable:getCluster()
        if cluster == nil then continue end

        if cluster.numAnimals ~= nil and cluster.numAnimals < 1 then
            Log:debug("initSourceItems: skipping rideable with numAnimals=%d (non-loadable, e.g. riding mission horse)", cluster.numAnimals)
            continue
        end

        if cluster.isIndividual == nil then
            local subType = g_currentMission.animalSystem:getSubTypeByIndex(cluster.subTypeIndex)
            if subType == nil then
                Log:warning("initSourceItems: skipping rideable with unknown subTypeIndex=%s", tostring(cluster.subTypeIndex))
                continue
            end

            local ownerFarmId = rideable:getOwnerFarmId()
            local farm = g_farmManager.farmIdToFarm[ownerFarmId]
            local farmHerdId = farm and farm.stats and farm.stats.statistics.farmId or ownerFarmId
            if farmHerdId == nil then
                farmHerdId = math.random(100000, 999999)
                if farm and farm.stats then farm.stats.statistics.farmId = farmHerdId end
            end
            local animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(cluster.subTypeIndex)
            local rawId = farm and farm.stats and farm.stats:getNextAnimalId(animalTypeIndex) or math.random(1, 99999)
            local uniqueId = RLAnimalUtil.generateUniqueId(farmHerdId, rawId)

            local animal = Animal.new({
                age = cluster.age,
                health = cluster.health,
                gender = subType.gender,
                subTypeIndex = cluster.subTypeIndex,
                name = cluster:getName(),
                dirt = cluster.dirt,
                fitness = cluster.fitness,
                riding = cluster.riding,
                farmId = tostring(farmHerdId),
                uniqueId = uniqueId,
            })

            Log:debug("initSourceItems: converted vanilla cluster to RLRM Animal (subType=%s, uniqueId=%s, name=%s)",
                subType.name, uniqueId, animal.name or "nil")

            rideable:setCluster(animal)
            cluster = animal
        end

        local animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(cluster.subTypeIndex)
        local item = AnimalItemStock.new(cluster)
        if self.sourceItems[animalTypeIndex] == nil then self.sourceItems[animalTypeIndex] = {} end
        table.insert(self.sourceItems[animalTypeIndex], item)
        self.clusterToVehicle[cluster] = rideable
    end

end

AnimalScreenTrailer.initSourceItems = Utils.overwrittenFunction(AnimalScreenTrailer.initSourceItems, RL_AnimalScreenTrailer.initSourceItems)


function RL_AnimalScreenTrailer:initTargetItems(_)

    self.targetItems = {}
    local animals = self.trailer:getClusters()

    if animals ~= nil then
        for _, animal in pairs(animals) do
            local item = AnimalItemStock.new(animal)
            table.insert(self.targetItems, item)
        end
    end

end

AnimalScreenTrailer.initTargetItems = Utils.overwrittenFunction(AnimalScreenTrailer.initTargetItems, RL_AnimalScreenTrailer.initTargetItems)


function RL_AnimalScreenTrailer:getApplySourceConfirmationText(_, animalTypeIndex, index, numAnimals)

    local text = "Do you want to move %d animals to the trailer?"

	return string.format(text, numAnimals)

end

AnimalScreenTrailer.getApplySourceConfirmationText = Utils.overwrittenFunction(AnimalScreenTrailer.getApplySourceConfirmationText, RL_AnimalScreenTrailer.getApplySourceConfirmationText)