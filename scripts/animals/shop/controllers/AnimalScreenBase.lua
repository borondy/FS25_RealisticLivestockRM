local Log = RmLogging.getLogger("RLRM")

RL_AnimalScreenBase = {}

function RL_AnimalScreenBase:getTargetItems(_)
    return self.targetItems
end

AnimalScreenBase.getTargetItems = Utils.overwrittenFunction(AnimalScreenBase.getTargetItems, RL_AnimalScreenBase.getTargetItems)


AnimalScreenBase.setCurrentHusbandry = Utils.appendedFunction(AnimalScreenBase.setCurrentHusbandry, function(self)
    RL_AnimalScreenBase.sortItems(self)
end)


-- Delegation alias: the name-tag formatter now lives in RLAnimalDisplayHelper
-- (scripts/utils, sourced before this controller). Kept so the legacy screen and
-- its callers keep working until this controller retires.
RL_AnimalScreenBase.formatDisplayName = RLAnimalDisplayHelper.formatDisplayName


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


-- Delegation alias: the sort comparator now lives in RLAnimalDisplayHelper
-- (scripts/utils, sourced before this controller). sortItems / sortSaleAnimals
-- below resolve it through this alias at call time.
RL_AnimalScreenBase.sortAnimals = RLAnimalDisplayHelper.sortAnimals


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