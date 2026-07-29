local Log = RmLogging.getLogger("RLRM")

AnimalScreenMoveFarm = {}

AnimalScreenMoveFarm.MOVE_ERROR_CODE_MAPPING = {
    [AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST] = { text = "rl_ui_moveErrorNotSupported" },
    [AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST] = { text = "rl_ui_moveErrorNotSupported" },
    [AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION] = { text = "rl_ui_moveErrorNoPermission" },
    [AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED] = { text = "rl_ui_moveErrorNotSupported" },
    [AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE] = { text = "rl_ui_moveErrorNoSpace" },
}


function AnimalScreenMoveFarm.new(husbandry)
    local self = {}
    setmetatable(self, { __index = AnimalScreenMoveFarm })

    self.husbandry = husbandry
    self.targetItems = {}
    self.animalsChangedCallback = nil
    self.actionTypeCallback = nil
    self.errorCallback = nil

    return self
end


function AnimalScreenMoveFarm:initTargetItems()
    self.targetItems = {}
    local animals = self.husbandry:getClusters()

    if animals ~= nil then
        for _, animal in pairs(animals) do
            local item = AnimalItemStock.new(animal)
            table.insert(self.targetItems, item)
        end
    end

    RL_AnimalScreenBase.sortItems(self)

    Log:trace("AnimalScreenMoveFarm:initTargetItems: populated %d items", #self.targetItems)
end


function AnimalScreenMoveFarm:getTargetItems()
    return self.targetItems
end


function AnimalScreenMoveFarm:setAnimalsChangedCallback(callback, target)
    function self.animalsChangedCallback()
        callback(target)
    end
end


function AnimalScreenMoveFarm:setActionTypeCallback(callback, target)
    function self.actionTypeCallback(actionType, text)
        callback(target, actionType, text)
    end
end


function AnimalScreenMoveFarm:setErrorCallback(callback, target)
    function self.errorCallback(text)
        callback(target, text)
    end
end


-- Delegation alias: destination enumeration now lives in RLMoveDestinationHelper
-- (scripts/utils, sourced before this controller). Kept so the legacy Move tab and
-- its callers keep working until this controller retires.
AnimalScreenMoveFarm.getValidDestinations = RLMoveDestinationHelper.getValidDestinations


-- Delegation alias: move validation now lives in RLMoveDestinationHelper
-- (scripts/utils, sourced before this controller). Kept so the legacy Move tab and
-- its callers keep working until this controller retires.
AnimalScreenMoveFarm.buildMoveValidationResult = RLMoveDestinationHelper.buildMoveValidationResult


--- Execute single animal move
function AnimalScreenMoveFarm:applyMoveTarget(animalTypeIndex, animal, destination)
    Log:debug("applyMoveTarget: animal='%s' subType=%s dest='%s'",
        animal.name or animal.uniqueId or "?",
        tostring(animal.subTypeIndex),
        destination:getName())

    local ownerFarmId = self.husbandry:getOwnerFarmId()
    Log:trace("applyMoveTarget: validating (ownerFarmId=%d)", ownerFarmId)
    local errorCode = AnimalMoveEvent.validate(self.husbandry, destination, ownerFarmId, animal.subTypeIndex)

    if errorCode ~= nil then
        local mapping = AnimalScreenMoveFarm.MOVE_ERROR_CODE_MAPPING[errorCode]
        if mapping ~= nil and self.errorCallback ~= nil then
            self.errorCallback(g_i18n:getText(mapping.text))
        end
        Log:debug("applyMoveTarget: validation failed, errorCode=%d", errorCode)
        return false
    end

    Log:trace("applyMoveTarget: validation passed, dispatching event")
    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_TARGET, g_i18n:getText("rl_ui_moveTab"))
    g_messageCenter:subscribe(AnimalMoveEvent, self.onAnimalMoved, self)

    Log:trace("applyMoveTarget: calling sendEvent")
    g_client:getServerConnection():sendEvent(AnimalMoveEvent.new(self.husbandry, destination, { animal }, "SOURCE"))
    Log:trace("applyMoveTarget: sendEvent returned")

    if self.husbandry.addRLMessage ~= nil then
        self.husbandry:addRLMessage("MOVED_ANIMALS_SOURCE_SINGLE", nil, { destination:getName() })
    end

    Log:debug("applyMoveTarget: complete for 1 animal to '%s'", destination:getName())
    return true
end


--- Execute bulk animal move
function AnimalScreenMoveFarm:applyMoveTargetBulk(animalTypeIndex, animals, destination)
    Log:debug("applyMoveTargetBulk: %d animals to '%s'", #animals, destination:getName())

    if #animals == 0 then
        Log:debug("applyMoveTargetBulk: no animals to move, skipping")
        return
    end

    self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_TARGET, g_i18n:getText("rl_ui_moveTab"))
    g_messageCenter:subscribe(AnimalMoveEvent, self.onAnimalMoved, self)

    Log:trace("applyMoveTargetBulk: calling sendEvent")
    g_client:getServerConnection():sendEvent(AnimalMoveEvent.new(self.husbandry, destination, animals, "SOURCE"))
    Log:trace("applyMoveTargetBulk: sendEvent returned")

    if self.husbandry.addRLMessage ~= nil then
        if #animals == 1 then
            self.husbandry:addRLMessage("MOVED_ANIMALS_SOURCE_SINGLE", nil, { destination:getName() })
        else
            self.husbandry:addRLMessage("MOVED_ANIMALS_SOURCE_MULTIPLE", nil, { #animals, destination:getName() })
        end
    end

    Log:debug("applyMoveTargetBulk: complete for %d animals to '%s'", #animals, destination:getName())
end


function AnimalScreenMoveFarm:onAnimalMoved(errorCode)
    Log:trace("onAnimalMoved: errorCode=%s", tostring(errorCode))

    if errorCode ~= AnimalMoveEvent.MOVE_SUCCESS then
        local mapping = AnimalScreenMoveFarm.MOVE_ERROR_CODE_MAPPING[errorCode]
        if mapping ~= nil and self.errorCallback ~= nil then
            self.errorCallback(g_i18n:getText(mapping.text))
        end
    end

    g_messageCenter:unsubscribe(AnimalMoveEvent, self)

    -- Dismiss the spinner overlay (nil text hides the MessageDialog)
    if self.actionTypeCallback ~= nil then
        self.actionTypeCallback(AnimalScreenBase.ACTION_TYPE_NONE, nil)
    end

    if self.animalsChangedCallback ~= nil then
        self.animalsChangedCallback()
    end
end
