--[[
    RLAnimalMoveService.lua
    Stateless service for animal move operations in the RL Tabbed Menu.

    Wraps existing AnimalScreenMoveFarm static methods and AnimalMoveEvent
    dispatch. Provides the same code paths as the legacy AnimalScreen move
    flow without coupling to the legacy controller's instance state.

    All methods are static (module-level functions). The service does not
    hold state between calls; the messageCenter subscription for move
    responses is scoped to each moveAnimals() invocation via closure.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalMoveService = {}

--- Error code to i18n key mapping, mirroring AnimalScreenMoveFarm.MOVE_ERROR_CODE_MAPPING.
RLAnimalMoveService.ERROR_CODE_MAPPING = {
    [AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST] = "rl_ui_moveErrorNotSupported",
    [AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST] = "rl_ui_moveErrorNotSupported",
    [AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION]                = "rl_ui_moveErrorNoPermission",
    [AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED]         = "rl_ui_moveErrorNotSupported",
    [AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE]             = "rl_ui_moveErrorNoSpace",
}


--- Enumerate valid move destinations for a given source husbandry and animal subtype.
--- Delegates to AnimalScreenMoveFarm.getValidDestinations (static).
---
--- Nil `sourceHusbandry` is a supported use case for dealer-buy flows: the
--- delegate's `placeable ~= sourceHusbandry` exclusion check becomes a no-op,
--- so every farm-owned placeable supporting the subtype is returned.
--- @param sourceHusbandry table|nil The source husbandry placeable (excluded from results; nil for dealer-buy)
--- @param farmId number The owning farm ID
--- @param animalSubTypeIndex number The animal subtype that destinations must support
--- @return table Array of destination entries ({placeable, name, currentCount, maxCount, freeSlots, isEPP, minAge?, maxAge?})
function RLAnimalMoveService.getValidDestinations(sourceHusbandry, farmId, animalSubTypeIndex)
    if farmId == nil or farmId == 0 then
        Log:warning("RLAnimalMoveService.getValidDestinations: invalid farmId=%s", tostring(farmId))
        return {}
    end
    if sourceHusbandry == nil then
        Log:trace("RLAnimalMoveService.getValidDestinations: nil source (dealer-buy path)")
    end
    Log:debug("RLAnimalMoveService.getValidDestinations: farmId=%d subTypeIndex=%d source=%s",
        farmId, animalSubTypeIndex, tostring(sourceHusbandry ~= nil))
    return AnimalScreenMoveFarm.getValidDestinations(sourceHusbandry, farmId, animalSubTypeIndex)
end


--- Validate animals against a destination, categorizing valid vs rejected.
--- Delegates to AnimalScreenMoveFarm.buildMoveValidationResult (static).
--- @param animals table Array of Animal/cluster objects to validate
--- @param destination table Destination entry from getValidDestinations
--- @param animalTypeIndex number The animal type index
--- @return table Validation result {valid = {}, rejected = {animal, reason}, destination}
function RLAnimalMoveService.buildMoveValidationResult(animals, destination, animalTypeIndex)
    if animals == nil or #animals == 0 then
        Log:trace("RLAnimalMoveService.buildMoveValidationResult: empty animals, returning empty result")
        return { valid = {}, rejected = {}, destination = destination }
    end
    if destination == nil then
        Log:warning("RLAnimalMoveService.buildMoveValidationResult: nil destination")
        return { valid = {}, rejected = {}, destination = destination }
    end
    Log:debug("RLAnimalMoveService.buildMoveValidationResult: %d animals, dest='%s'", #animals, destination.name or "?")
    return AnimalScreenMoveFarm.buildMoveValidationResult(animals, destination, animalTypeIndex)
end


--- Client-side pre-validation for a single animal move.
--- Mirrors legacy AnimalScreenMoveFarm:applyMoveTarget line 215 which calls
--- AnimalMoveEvent.validate() before sending the event.
--- @param sourceHusbandry table The source husbandry placeable
--- @param destination table The destination placeable (entry.placeable)
--- @param farmId number The owning farm ID
--- @param animalSubTypeIndex number The animal subtype index
--- @return number|nil errorCode Nil if validation passes, error code if it fails
function RLAnimalMoveService.preValidateSingleMove(sourceHusbandry, destination, farmId, animalSubTypeIndex)
    Log:trace("RLAnimalMoveService.preValidateSingleMove: farmId=%d subTypeIndex=%d", farmId, animalSubTypeIndex)
    local errorCode = AnimalMoveEvent.validate(sourceHusbandry, destination, farmId, animalSubTypeIndex)
    if errorCode ~= nil then
        Log:debug("RLAnimalMoveService.preValidateSingleMove: failed, errorCode=%d", errorCode)
    else
        Log:trace("RLAnimalMoveService.preValidateSingleMove: passed")
    end
    return errorCode
end


--- Send the move event to the server and subscribe to the response.
--- Mirrors legacy AnimalScreenMoveFarm:applyMoveTarget/applyMoveTargetBulk:
--- subscribe to messageCenter, sendEvent, add RL messages to source husbandry.
--- The callback fires once with (target, errorCode) when the server responds.
--- @param sourceHusbandry table The source husbandry placeable
--- @param destination table The destination placeable (entry.placeable from getValidDestinations)
--- @param animals table Array of Animal/cluster objects to move
--- @param moveType string "SOURCE" (from move screen) or "TARGET"
--- @param callback function Callback function(target, errorCode)
--- @param target table Callback target (typically the frame)
function RLAnimalMoveService.moveAnimals(sourceHusbandry, destination, animals, moveType, callback, target)
    if animals == nil or #animals == 0 then
        Log:debug("RLAnimalMoveService.moveAnimals: no animals, skipping")
        return
    end

    Log:debug("RLAnimalMoveService.moveAnimals: %d animals to '%s' (moveType=%s)",
        #animals, tostring(destination and destination.getName and destination:getName()),
        tostring(moveType))

    -- Subscription handler: unsubscribe immediately on response, then fire caller's callback.
    -- Uses a unique table as subscription identity to avoid cross-fire with other subscribers.
    local subscriptionId = {}
    local function onMoveResponse(_self, errorCode)
        -- _self is subscriptionId passed by messageCenter as the callback target
        Log:trace("RLAnimalMoveService.onMoveResponse: errorCode=%s", tostring(errorCode))
        g_messageCenter:unsubscribe(AnimalMoveEvent, subscriptionId)

        if errorCode ~= AnimalMoveEvent.MOVE_SUCCESS then
            Log:debug("RLAnimalMoveService.onMoveResponse: move failed, errorCode=%d", errorCode)
        else
            Log:debug("RLAnimalMoveService.onMoveResponse: move succeeded")
        end

        if callback ~= nil then
            if target ~= nil then
                callback(target, errorCode)
            else
                callback(errorCode)
            end
        end
    end

    g_messageCenter:subscribe(AnimalMoveEvent, onMoveResponse, subscriptionId)
    Log:trace("RLAnimalMoveService.moveAnimals: subscribed to AnimalMoveEvent, sending event")

    g_client:getServerConnection():sendEvent(
        AnimalMoveEvent.new(sourceHusbandry, destination, animals, moveType)
    )
    Log:trace("RLAnimalMoveService.moveAnimals: sendEvent returned")

    -- Add RL messages to source husbandry (matching legacy applyMoveTarget/Bulk lines 234-264)
    if sourceHusbandry.addRLMessage ~= nil then
        if #animals == 1 then
            sourceHusbandry:addRLMessage("MOVED_ANIMALS_SOURCE_SINGLE", nil, { destination:getName() })
        else
            sourceHusbandry:addRLMessage("MOVED_ANIMALS_SOURCE_MULTIPLE", nil, { #animals, destination:getName() })
        end
        Log:trace("RLAnimalMoveService.moveAnimals: RL message added to source husbandry")
    end
end


--- Map an AnimalMoveEvent error code to a localized error string.
--- @param errorCode number The error code from AnimalMoveEvent
--- @return string Localized error text, or a generic fallback for unknown codes
function RLAnimalMoveService.getErrorText(errorCode)
    local key = RLAnimalMoveService.ERROR_CODE_MAPPING[errorCode]
    if key ~= nil then
        Log:trace("RLAnimalMoveService.getErrorText: code=%d -> key='%s'", errorCode, key)
        return g_i18n:getText(key)
    end
    Log:warning("RLAnimalMoveService.getErrorText: unknown errorCode=%s, using fallback", tostring(errorCode))
    return g_i18n:getText("rl_ui_moveErrorNotSupported")
end
