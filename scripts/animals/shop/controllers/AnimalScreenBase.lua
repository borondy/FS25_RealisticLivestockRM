local Log = RmLogging.getLogger("RLRM")

RL_AnimalScreenBase = {}

function RL_AnimalScreenBase:getTargetItems(_)
    return self.targetItems
end

AnimalScreenBase.getTargetItems = Utils.overwrittenFunction(AnimalScreenBase.getTargetItems, RL_AnimalScreenBase.getTargetItems)


AnimalScreenBase.setCurrentHusbandry = Utils.appendedFunction(AnimalScreenBase.setCurrentHusbandry, function(self)
    RL_AnimalScreenBase.sortItems(self)
end)


function RL_AnimalScreenBase.scaleToNinetyNine(value)
    local scaled = math.floor(((value - 0.25) / 1.5) * 99 + 0.5)
    if scaled < 0 then return 0 end
    if scaled > 99 then return 99 end
    return scaled
end


function RL_AnimalScreenBase.formatDisplayName(name, animal)
    if animal == nil or animal.genetics == nil then return name end

    local displaySetting = RLSettings.SETTINGS.geneticsDisplay
    if displaySetting == nil or displaySetting.state == nil or displaySetting.state == 1 then return name end

    Log:trace("AnimalScreen: formatDisplayName mode=%d name='%s'", displaySetting.state, name or "")

    local genetics = animal.genetics
    if type(genetics) ~= "table" then return name end

    local total = 0
    local count = 0

    for _, value in pairs(genetics) do
        if value ~= nil then
            total = total + value
            count = count + 1
        end
    end

    if count == 0 then return name end

    local avg = total / count
    local tag

    if displaySetting.state == 2 then
        tag = string.format("[%02d]", RL_AnimalScreenBase.scaleToNinetyNine(avg))
    else
        local m = genetics.metabolism and RL_AnimalScreenBase.scaleToNinetyNine(genetics.metabolism) or 0
        local h = genetics.health and RL_AnimalScreenBase.scaleToNinetyNine(genetics.health) or 0
        local f = genetics.fertility and RL_AnimalScreenBase.scaleToNinetyNine(genetics.fertility) or 0
        local q = genetics.quality and RL_AnimalScreenBase.scaleToNinetyNine(genetics.quality) or 0

        if genetics.productivity ~= nil then
            local p = RL_AnimalScreenBase.scaleToNinetyNine(genetics.productivity)
            tag = string.format("[%02d-%02d:%02d:%02d:%02d:%02d]", RL_AnimalScreenBase.scaleToNinetyNine(avg), m, h, f, q, p)
        else
            tag = string.format("[%02d-%02d:%02d:%02d:%02d]", RL_AnimalScreenBase.scaleToNinetyNine(avg), m, h, f, q)
        end
    end

    local positionSetting = RLSettings.SETTINGS.geneticsPosition
    local isPostfix = positionSetting ~= nil and positionSetting.state == 2

    if name == nil or name == "" then
        return tag
    elseif isPostfix then
        return name .. " " .. tag
    else
        return tag .. " " .. name
    end
end


function RL_AnimalScreenBase.sortItems(controller)
    local targetCount = controller.targetItems ~= nil and #controller.targetItems or 0
    local sourceGroupCount = 0

    if controller.targetItems ~= nil then
        table.sort(controller.targetItems, RL_AnimalScreenBase.sortAnimals)
    end

    if controller.sourceItems == nil then
        Log:debug("AnimalScreen: sortItems target=%d source=none", targetCount)
        return
    end

    for _, items in pairs(controller.sourceItems) do
        sourceGroupCount = sourceGroupCount + 1
        if items[1] ~= nil and items[1].animal ~= nil then
            table.sort(items, RL_AnimalScreenBase.sortSaleAnimals)
        else
            table.sort(items, RL_AnimalScreenBase.sortAnimals)
        end
    end

    local sortByGenetics = RLSettings.SETTINGS.sortByGenetics
    Log:debug("AnimalScreen: sortItems target=%d sourceGroups=%d sortByGenetics=%s",
        targetCount, sourceGroupCount, sortByGenetics ~= nil and sortByGenetics.state == 2)
end


function RL_AnimalScreenBase.sortAnimals(a, b)

    if a.cluster == nil or b.cluster == nil then return false end

    local aDisease, bDisease = a.cluster:getHasAnyDisease(), b.cluster:getHasAnyDisease()

    if aDisease or bDisease then

        if aDisease and not bDisease then return true end
        if bDisease and not aDisease then return false end

    end

    if a.cluster.subTypeIndex ~= b.cluster.subTypeIndex then
        return a.cluster.subTypeIndex < b.cluster.subTypeIndex
    end

    local sortByGenetics = RLSettings.SETTINGS.sortByGenetics
    if sortByGenetics ~= nil and sortByGenetics.state == 2 then
        local aGen = a.cachedAvgGenetics or 0
        local bGen = b.cachedAvgGenetics or 0
        if aGen ~= bGen then return aGen > bGen end
    end

    return a.cluster.age < b.cluster.age

end


function RL_AnimalScreenBase.sortSaleAnimals(a, b)

    if a.animal == nil or b.animal == nil then return false end

    local aDisease, bDisease = a.animal:getHasAnyDisease(), b.animal:getHasAnyDisease()

    if aDisease or bDisease then

        if aDisease and not bDisease then return true end
        if bDisease and not aDisease then return false end

    end

    if a.animal.subTypeIndex ~= b.animal.subTypeIndex then
        return a.animal.subTypeIndex < b.animal.subTypeIndex
    end

    local sortByGenetics = RLSettings.SETTINGS.sortByGenetics
    if sortByGenetics ~= nil and sortByGenetics.state == 2 then
        local aGen = a.cachedAvgGenetics or 0
        local bGen = b.cachedAvgGenetics or 0
        if aGen ~= bGen then return aGen > bGen end
        return a.animal.age < b.animal.age
    end

    local aValue = a.cachedSellPrice or 0
    local bValue = b.cachedSellPrice or 0

    if aValue == bValue then return a.animal.age < b.animal.age end

    return aValue > bValue

end


function RL_AnimalScreenBase:onAnimalsChanged(_)
    if self.trailer == nil then return end
    self:initItems()
    self.animalsChangedCallback()
    self.trailer:updateAnimals()
end

AnimalScreenTrailerFarm.onAnimalMovedToTrailer = Utils.appendedFunction(AnimalScreenTrailerFarm.onAnimalMovedToTrailer, RL_AnimalScreenBase.onAnimalsChanged)
AnimalScreenTrailerFarm.onAnimalMovedToFarm = Utils.appendedFunction(AnimalScreenTrailerFarm.onAnimalMovedToFarm, RL_AnimalScreenBase.onAnimalsChanged)
AnimalScreenTrailerFarm.onAnimalsChanged = Utils.appendedFunction(AnimalScreenTrailerFarm.onAnimalsChanged, RL_AnimalScreenBase.onAnimalsChanged)
AnimalScreenDealerTrailer.onAnimalBought = Utils.appendedFunction(AnimalScreenDealerTrailer.onAnimalBought, RL_AnimalScreenBase.onAnimalsChanged)
AnimalScreenDealerTrailer.onAnimalSold = Utils.appendedFunction(AnimalScreenDealerTrailer.onAnimalSold, RL_AnimalScreenBase.onAnimalsChanged)
AnimalScreenDealerTrailer.onAnimalsChanged = Utils.appendedFunction(AnimalScreenDealerTrailer.onAnimalsChanged, RL_AnimalScreenBase.onAnimalsChanged)
AnimalScreenTrailer.onAnimalLoadedToTrailer = Utils.appendedFunction(AnimalScreenTrailer.onAnimalLoadedToTrailer, RL_AnimalScreenBase.onAnimalsChanged)
AnimalScreenTrailer.onAnimalsChanged = Utils.appendedFunction(AnimalScreenTrailer.onAnimalsChanged, RL_AnimalScreenBase.onAnimalsChanged)


function AnimalScreenBase:setSourceBulkActionFinishedCallback(callback, target)

    function self.sourceBulkActionFinished(error, text, indexes)

        callback(target, error, text, indexes)

    end

end


function AnimalScreenBase:setTargetBulkActionFinishedCallback(callback, target)

    function self.targetBulkActionFinished(error, text, indexes)

        callback(target, error, text, indexes)

    end

end