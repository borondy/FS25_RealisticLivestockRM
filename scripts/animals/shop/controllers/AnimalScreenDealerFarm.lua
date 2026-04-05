local Log = RmLogging.getLogger("RLRM")

RL_AnimalScreenDealerFarm = {}

function RL_AnimalScreenDealerFarm:initTargetItems(_)

    self.targetItems = {}
    local animals = self.husbandry:getClusters()

    if animals ~= nil then
        for _, animal in pairs(animals) do
            local item = AnimalItemStock.new(animal)
            table.insert(self.targetItems, item)
        end
    end

end

AnimalScreenDealerFarm.initTargetItems = Utils.overwrittenFunction(AnimalScreenDealerFarm.initTargetItems, RL_AnimalScreenDealerFarm.initTargetItems)


function RL_AnimalScreenDealerFarm:initSourceItems(_)

    local animalTypeIndex = self.husbandry:getAnimalTypeIndex()
    local animals = g_currentMission.animalSystem:getSaleAnimalsByTypeIndex(animalTypeIndex)
    
    self.sourceItems = { [animalTypeIndex] = {} }

    for _, animal in pairs(animals) do
        local item = AnimalItemNew.new(animal)
        table.insert(self.sourceItems[animalTypeIndex], item)
    end

end

AnimalScreenDealerFarm.initSourceItems = Utils.overwrittenFunction(AnimalScreenDealerFarm.initSourceItems, RL_AnimalScreenDealerFarm.initSourceItems)


function RL_AnimalScreenDealerFarm:getSourceMaxNumAnimals(_, _)

    return 1

end

AnimalScreenDealerFarm.getSourceMaxNumAnimals = Utils.overwrittenFunction(AnimalScreenDealerFarm.getSourceMaxNumAnimals, RL_AnimalScreenDealerFarm.getSourceMaxNumAnimals)


function RL_AnimalScreenDealerFarm:applySource(_, animalTypeIndex, animalIndex)

    self.sourceAnimals = nil

    local item = self.sourceItems[animalTypeIndex][animalIndex]
    local husbandry = self.husbandry
    local ownerFarmId = husbandry:getOwnerFarmId()

    local price = -item:getPrice()
	local transportationFee = -item:getTranportationFee(1)

    local errorCode = AnimalBuyEvent.validate(husbandry, item:getSubTypeIndex(), item:getAge(), 1, price, transportationFee, ownerFarmId)

    if errorCode ~= nil then
		local error = AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING[errorCode]
		self.errorCallback(g_i18n:getText(error.text))
		return false
	end

    local animal = item.animal

    self.sourceAnimals = { animal }

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_SOURCE, g_i18n:getText(AnimalScreenDealerFarm.L10N_SYMBOL.BUYING))
    g_messageCenter:subscribe(AnimalBuyEvent, self.onAnimalBought, self)
	g_client:getServerConnection():sendEvent(AnimalBuyEvent.new(husbandry, self.sourceAnimals, price, transportationFee))

    self.husbandry:addRLMessage("BOUGHT_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(math.abs(price + transportationFee), 2, true, true) })

    return true

end

AnimalScreenDealerFarm.applySource = Utils.overwrittenFunction(AnimalScreenDealerFarm.applySource, RL_AnimalScreenDealerFarm.applySource)


function RL_AnimalScreenDealerFarm:onAnimalBought(errorCode)

    if errorCode == AnimalBuyEvent.BUY_SUCCESS and self.sourceAnimals ~= nil then

        for _, animal in pairs(self.sourceAnimals) do g_currentMission.animalSystem:removeSaleAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId) end

    end

end

AnimalScreenDealerFarm.onAnimalBought = Utils.prependedFunction(AnimalScreenDealerFarm.onAnimalBought, RL_AnimalScreenDealerFarm.onAnimalBought)


function RL_AnimalScreenDealerFarm:applyTarget(_, animalTypeIndex, animalIndex)

    self.targetAnimals = nil

    local item = self.targetItems[animalIndex]
    local husbandry = self.husbandry
    local ownerFarmId = husbandry:getOwnerFarmId()

    local price = item:getPrice()
	local transportationFee = -item:getTranportationFee(1)

    local animal = item.animal or item.cluster

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_TARGET, g_i18n:getText(AnimalScreenDealerFarm.L10N_SYMBOL.SELLING))

    self.targetAnimals = { animal }

    g_messageCenter:subscribe(AnimalSellEvent, self.onAnimalSold, self)
	g_client:getServerConnection():sendEvent(AnimalSellEvent.new(husbandry, self.targetAnimals, price, transportationFee))

    self.husbandry:addRLMessage("SOLD_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(price + transportationFee, 2, true, true) })

    return true

end

AnimalScreenDealerFarm.applyTarget = Utils.overwrittenFunction(AnimalScreenDealerFarm.applyTarget, RL_AnimalScreenDealerFarm.applyTarget)


function RL_AnimalScreenDealerFarm:getSourcePrice(_, animalTypeIndex, animalIndex, _)

    if self.sourceItems[animalTypeIndex] ~= nil then

        local item = self.sourceItems[animalTypeIndex][animalIndex]

        if item ~= nil then

	        local price = item:getPrice()
	        local transportationFee = item:getTranportationFee(1)
	        return true, price, transportationFee, price + transportationFee

        end

    end

    return false, 0, 0, 0

end

AnimalScreenDealerFarm.getSourcePrice = Utils.overwrittenFunction(AnimalScreenDealerFarm.getSourcePrice, RL_AnimalScreenDealerFarm.getSourcePrice)


function RL_AnimalScreenDealerFarm:getTargetPrice(_, _, animalIndex, _)

    local item = self.targetItems[animalIndex]

    if item ~= nil then

        local price = item:getPrice()
        local transportationFee = -item:getTranportationFee(1)
        return true, price, transportationFee, price + transportationFee

    end

    return false, 0, 0, 0

end

AnimalScreenDealerFarm.getTargetPrice = Utils.overwrittenFunction(AnimalScreenDealerFarm.getTargetPrice, RL_AnimalScreenDealerFarm.getTargetPrice)


function RL_AnimalScreenDealerFarm:getTargetMaxNumAnimals(_, animalIndex)

    local item = self.targetItems[animalIndex]

    if item ~= nil then
        return item:getNumAnimals()
    end

    return 0

end

AnimalScreenDealerFarm.getTargetMaxNumAnimals = Utils.overwrittenFunction(AnimalScreenDealerFarm.getTargetMaxNumAnimals, RL_AnimalScreenDealerFarm.getTargetMaxNumAnimals)


--- Pre-validate a single buy item before the confirmation dialog.
--- @param animalTypeIndex number The animal type index
--- @param itemIndex number The item index in sourceItems
--- @return number|nil errorCode from AnimalBuyEvent.validate, or nil if valid
function AnimalScreenDealerFarm:preValidateBuyItem(animalTypeIndex, itemIndex)
    local sourceItems = self.sourceItems[animalTypeIndex]
    if sourceItems == nil then return nil end
    local sourceItem = sourceItems[itemIndex]
    if sourceItem == nil then return nil end

    local animal = sourceItem.animal
    local price = -sourceItem:getPrice()
    local transportationFee = -sourceItem:getTranportationFee(1)

    return AnimalBuyEvent.validate(self.husbandry, animal.subTypeIndex, animal.age, 1, price, transportationFee, self.husbandry:getOwnerFarmId())
end


function AnimalScreenDealerFarm:applySourceBulk(animalTypeIndex, items)

    self.sourceAnimals = {}

    local husbandry = self.husbandry
    local ownerFarmId = husbandry:getOwnerFarmId()

    local sourceItems = self.sourceItems[animalTypeIndex]
    local totalPrice = 0
    local totalTransportPrice = 0
    local totalBoughtAnimals = 0
    local skippedCount = 0
    local firstErrorCode = nil

    for _, item in pairs(items) do

        if sourceItems[item] ~= nil then

            local sourceItem = sourceItems[item]
            local animal = sourceItem.animal
            local price = -sourceItem:getPrice()
            local transportationFee = -sourceItem:getTranportationFee(1)

            local errorCode = AnimalBuyEvent.validate(husbandry, animal.subTypeIndex, animal.age, 1, price, transportationFee, ownerFarmId)

            if errorCode ~= nil then
                skippedCount = skippedCount + 1
                if firstErrorCode == nil then firstErrorCode = errorCode end
                Log:trace("DealerFarm.applySourceBulk: skipping '%s' (errorCode=%d)",
                    animal.name or animal.uniqueId or "?", errorCode)
                continue
            end

            totalBoughtAnimals = totalBoughtAnimals + 1
            totalPrice = totalPrice + price
            totalTransportPrice = totalTransportPrice + transportationFee

            table.insert(self.sourceAnimals, animal)

        end

    end

    Log:debug("DealerFarm.applySourceBulk: %d of %d passed validation, %d skipped",
        totalBoughtAnimals, totalBoughtAnimals + skippedCount, skippedCount)

    if totalBoughtAnimals == 0 and skippedCount > 0 then
        Log:debug("DealerFarm.applySourceBulk: all %d items rejected (firstError=%d)", skippedCount, firstErrorCode)
        local mapping = AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING[firstErrorCode]
        if mapping ~= nil and self.errorCallback ~= nil then
            self.errorCallback(g_i18n:getText(mapping.text))
        end
        return
    end

    if skippedCount > 0 then
        Log:warning("DealerFarm.applySourceBulk: %d items skipped (firstError=%d)", skippedCount, firstErrorCode)
    end

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_SOURCE, g_i18n:getText(AnimalScreenDealerFarm.L10N_SYMBOL.BUYING))
    g_messageCenter:subscribe(AnimalBuyEvent, self.onAnimalBought, self)
    g_client:getServerConnection():sendEvent(AnimalBuyEvent.new(husbandry, self.sourceAnimals, totalPrice, totalTransportPrice))

    if totalBoughtAnimals == 1 then
        self.husbandry:addRLMessage("BOUGHT_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(math.abs(totalPrice + totalTransportPrice), 2, true, true) })
    elseif totalBoughtAnimals > 0 then
        self.husbandry:addRLMessage("BOUGHT_ANIMALS_MULTIPLE", nil, { totalBoughtAnimals, g_i18n:formatMoney(math.abs(totalPrice + totalTransportPrice), 2, true, true) })
    end

end


function AnimalScreenDealerFarm:applyTargetBulk(animalTypeIndex, items)

    self.targetAnimals = {}

    local husbandry = self.husbandry
    local ownerFarmId = husbandry:getOwnerFarmId()

    local targetItems = self.targetItems
    local totalPrice = 0
    local totalTransportPrice = 0
    local totalSoldAnimals = 0
    local skippedCount = 0
    local firstErrorCode = nil

    for _, item in pairs(items) do

        if targetItems[item] ~= nil then

            local targetItem = targetItems[item]
            local animal = targetItem.animal or targetItem.cluster
            local price = targetItem:getPrice()
            local transportationFee = -targetItem:getTranportationFee(1)

            local errorCode = AnimalSellEvent.validate(husbandry, targetItem:getClusterId(), 1, price, transportationFee)

            if errorCode ~= nil then
                skippedCount = skippedCount + 1
                if firstErrorCode == nil then firstErrorCode = errorCode end
                Log:trace("DealerFarm.applyTargetBulk: skipping '%s' (errorCode=%d)",
                    animal.name or animal.uniqueId or "?", errorCode)
                continue
            end

            totalSoldAnimals = totalSoldAnimals + 1
            totalPrice = totalPrice + price
            totalTransportPrice = totalTransportPrice + transportationFee

            table.insert(self.targetAnimals, animal)

        end

    end

    Log:debug("DealerFarm.applyTargetBulk: %d of %d passed validation, %d skipped",
        totalSoldAnimals, totalSoldAnimals + skippedCount, skippedCount)

    if totalSoldAnimals == 0 and skippedCount > 0 then
        Log:debug("DealerFarm.applyTargetBulk: all %d items rejected (firstError=%d)", skippedCount, firstErrorCode)
        local mapping = AnimalScreenDealerFarm.SELL_ERROR_CODE_MAPPING[firstErrorCode]
        if mapping ~= nil and self.errorCallback ~= nil then
            self.errorCallback(g_i18n:getText(mapping.text))
        end
        return
    end

    if skippedCount > 0 then
        Log:warning("DealerFarm.applyTargetBulk: %d items skipped (firstError=%d)", skippedCount, firstErrorCode)
    end

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_SOURCE, g_i18n:getText(AnimalScreenDealerFarm.L10N_SYMBOL.SELLING))
    g_messageCenter:subscribe(AnimalSellEvent, self.onAnimalSold, self)
    g_client:getServerConnection():sendEvent(AnimalSellEvent.new(husbandry, self.targetAnimals, totalPrice, totalTransportPrice))

    if totalSoldAnimals == 1 then
        self.husbandry:addRLMessage("SOLD_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(totalPrice + totalTransportPrice, 2, true, true) })
    elseif totalSoldAnimals > 0 then
        self.husbandry:addRLMessage("SOLD_ANIMALS_MULTIPLE", nil, { totalSoldAnimals, g_i18n:formatMoney(totalPrice + totalTransportPrice, 2, true, true) })
    end

end