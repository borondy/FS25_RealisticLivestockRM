--[[
    RLAnimalSellService.lua
    Stateless service for animal sell operations in the RL Tabbed Menu.

    Wraps AnimalSellEvent dispatch with the same subscription pattern as
    RLAnimalMoveService. All sells route through AnimalSellEvent (both
    single and bulk), fixing the legacy single-sell MoneyType bug where
    AnimalScreenDealer.applyTarget used direct removeCluster + addMoney
    with MoneyType.NEW_ANIMALS_COST instead of SOLD_ANIMALS.

    Fee sign convention: Animal:getTranportationFee(1) returns a positive
    number. This service stores fees as positive internally and negates
    when passing to AnimalSellEvent (which expects negative transportPrice).

    RL messages are handled server-side by AnimalSellEvent:run() -- the
    service does NOT add them (unlike RLAnimalMoveService which adds
    move messages client-side).

    All methods are static (module-level functions). The service does not
    hold state between calls; the messageCenter subscription for sell
    responses is scoped to each sellAnimals() invocation via closure.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalSellService = {}


--- Compute sell price, transportation fee, and net total for a single animal.
--- @param animal table Animal/cluster object
--- @return number price Sell price (positive)
--- @return number fee Transportation fee (positive)
--- @return number total Net proceeds (price - fee)
function RLAnimalSellService.computeSellPrice(animal)
    if animal == nil then
        Log:warning("RLAnimalSellService.computeSellPrice: nil animal")
        return 0, 0, 0
    end

    local price = animal:getSellPrice() or 0
    local fee = animal:getTranportationFee(1) or 0
    local total = price - fee

    Log:trace("RLAnimalSellService.computeSellPrice: price=%.0f fee=%.0f total=%.0f",
        price, fee, total)
    return price, fee, total
end


--- Compute aggregate sell totals for an array of animals.
--- @param animals table Array of Animal/cluster objects
--- @return number totalPrice Sum of sell prices (positive)
--- @return number totalFee Sum of transportation fees (positive)
--- @return number total Net proceeds (totalPrice - totalFee)
--- @return number count Number of animals
function RLAnimalSellService.computeBulkTotal(animals)
    if animals == nil or #animals == 0 then
        return 0, 0, 0, 0
    end

    local totalPrice = 0
    local totalFee = 0
    for _, animal in ipairs(animals) do
        totalPrice = totalPrice + (animal:getSellPrice() or 0)
        totalFee = totalFee + (animal:getTranportationFee(1) or 0)
    end

    local total = totalPrice - totalFee
    Log:debug("RLAnimalSellService.computeBulkTotal: %d animals, price=%.0f fee=%.0f total=%.0f",
        #animals, totalPrice, totalFee, total)
    return totalPrice, totalFee, total, #animals
end


--- Get the animal's breed/type title (e.g., "Holstein", "Landrace").
--- @param animal table Animal/cluster object
--- @return string Type title, or empty string if unavailable
function RLAnimalSellService.getAnimalTypeTitle(animal)
    if animal == nil then return "" end

    local subTypeIndex = animal.subTypeIndex
    if subTypeIndex == nil and animal.getSubTypeIndex ~= nil then
        subTypeIndex = animal:getSubTypeIndex()
    end
    if subTypeIndex == nil then return "" end

    local animalSystem = g_currentMission and g_currentMission.animalSystem
    if animalSystem == nil then return "" end

    local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
    if subType == nil then return "" end

    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeTitleByIndex ~= nil then
        return g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex) or ""
    end
    return ""
end


--- Get the animal's custom name (e.g., "Bessie").
--- @param animal table Animal/cluster object
--- @return string Custom name, or empty string if none
function RLAnimalSellService.getAnimalName(animal)
    if animal == nil or animal.getName == nil then return "" end
    return animal:getName() or ""
end


--- Build the single-animal confirmation text using base-game namedFormat pattern.
--- Packs type + name into {animalType} to match AnimalScreenDealerFarm:getApplyTargetConfirmationText.
--- @param animal table Animal/cluster object
--- @param price number Sell price (positive)
--- @param fee number Transportation fee (positive)
--- @return string Formatted confirmation text
function RLAnimalSellService.buildSingleConfirmationText(animal, price, fee)
    local typeTitle = RLAnimalSellService.getAnimalTypeTitle(animal)
    local animalName = RLAnimalSellService.getAnimalName(animal)

    local animalType
    if animalName ~= "" then
        animalType = typeTitle .. ", " .. animalName
    else
        animalType = typeTitle
    end

    local total = price - fee
    local formattedPrice = g_i18n:formatMoney(math.abs(total), 0, true, true)

    local text = g_i18n:getText("shop_doYouWantToSellAnimalsSingular")
    return string.namedFormat(text, "numAnimals", 1, "animalType", animalType, "price", formattedPrice)
end


--- Build the bulk sell confirmation text.
--- @param count number Number of animals
--- @param totalPrice number Sum of sell prices (positive)
--- @param totalFee number Sum of transportation fees (positive)
--- @return string Formatted confirmation text
function RLAnimalSellService.buildBulkConfirmationText(count, totalPrice, totalFee)
    local total = totalPrice - totalFee
    local formattedTotal = g_i18n:formatMoney(math.abs(total), 0, true, true)
    return string.format(g_i18n:getText("rl_ui_sellConfirmation"), count, formattedTotal)
end


--- Send the sell event to the server and subscribe to the response.
--- Mirrors RLAnimalMoveService.moveAnimals subscription pattern.
--- The callback fires once with (target, errorCode) when the server responds.
--- @param husbandry table The source husbandry placeable
--- @param animals table Array of Animal/cluster objects to sell
--- @param totalPrice number Sum of sell prices (positive)
--- @param totalFee number Sum of transportation fees (positive)
--- @param callback function Callback function(target, errorCode)
--- @param target table Callback target (typically the frame)
function RLAnimalSellService.sellAnimals(husbandry, animals, totalPrice, totalFee, callback, target)
    if animals == nil or #animals == 0 then
        Log:debug("RLAnimalSellService.sellAnimals: no animals, skipping")
        return
    end

    Log:debug("RLAnimalSellService.sellAnimals: %d animals from '%s' (price=%.0f fee=%.0f)",
        #animals,
        tostring(husbandry and husbandry.getName and husbandry:getName()),
        totalPrice, totalFee)

    -- Subscription handler: unsubscribe immediately on response, then fire caller's callback.
    -- Uses a unique table as subscription identity to avoid cross-fire with other subscribers.
    local subscriptionId = {}
    local function onSellResponse(_self, errorCode)
        Log:trace("RLAnimalSellService.onSellResponse: errorCode=%s", tostring(errorCode))
        g_messageCenter:unsubscribe(AnimalSellEvent, subscriptionId)

        if errorCode ~= AnimalSellEvent.SELL_SUCCESS then
            Log:debug("RLAnimalSellService.onSellResponse: sell failed, errorCode=%d", errorCode)
        else
            Log:info("RLAnimalSellService.onSellResponse: sell succeeded (%d animals)", #animals)
        end

        if callback ~= nil then
            if target ~= nil then
                callback(target, errorCode)
            else
                callback(errorCode)
            end
        end
    end

    g_messageCenter:subscribe(AnimalSellEvent, onSellResponse, subscriptionId)
    Log:trace("RLAnimalSellService.sellAnimals: subscribed to AnimalSellEvent, sending event")

    -- AnimalSellEvent expects transportPrice as NEGATIVE (fee sign convention)
    g_client:getServerConnection():sendEvent(
        AnimalSellEvent.new(husbandry, animals, totalPrice, -totalFee)
    )
    Log:trace("RLAnimalSellService.sellAnimals: sendEvent returned")
end


--- Map an AnimalSellEvent error code to a localized error string.
--- @param errorCode number The error code from AnimalSellEvent
--- @return string Localized error text, or a generic fallback for unknown codes
function RLAnimalSellService.getErrorText(errorCode)
    local mapping = AnimalScreenDealerFarm.SELL_ERROR_CODE_MAPPING[errorCode]
    if mapping ~= nil and mapping.text ~= nil then
        Log:trace("RLAnimalSellService.getErrorText: code=%d -> key='%s'", errorCode, mapping.text)
        return g_i18n:getText(mapping.text)
    end
    Log:warning("RLAnimalSellService.getErrorText: unknown errorCode=%s, using fallback", tostring(errorCode))
    return g_i18n:getText("shop_messageCannotSellAnimal")
end
