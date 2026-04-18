--[[
    RLAnimalBuyService.lua
    Stateless service for dealer-buy operations in the RL Tabbed Menu.

    Wraps AnimalBuyEvent dispatch with the same subscription pattern as
    RLAnimalSellService / RLAnimalMoveService. All buys route through
    AnimalBuyEvent (server-authoritative at
    scripts/animals/shop/events/AnimalBuyEvent.lua:65-113): the server calls
    animalSystem:removeSaleAnimal, self.object:addAnimals, and addMoney.
    The client MUST NOT mutate dealer stock, husbandry contents, or farm
    money directly - MUTATION PARITY with legacy AnimalScreenDealer.

    Sign convention (CRITICAL - see Design Notes in
    _bmad-output/implementation-artifacts/spec-rlmenu-buy-frame-logic.md):
    AnimalBuyEvent:run calls
        g_currentMission:addMoney(buyPrice + transportPrice, ...)
    so both values MUST be dispatched as NEGATIVE numbers. addMoney adds
    the value to the balance; the MoneyType is a statistics label and does
    not change the sign. Legacy `AnimalScreenDealer.lua:143-144` negates
    both values before dispatch, and the server abs()-wraps them at
    AnimalBuyEvent.lua:109 & 111 purely for display - confirming it expects
    stored values to be negative. A positive dispatch credits the farm.

    Price markup: dealer sell price = cluster:getSellPrice() * 1.075
    (see AnimalItemNew.lua:158-160).

    Error mapping: delegates to AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING
    (shape `[code] = { warning = bool, text = i18n_key }`). Do NOT define a
    parallel table - the base-game map already covers every
    AnimalBuyEvent error code and is shared by AnimalScreenDealer,
    AnimalScreenDealerFarm, and AnimalScreenDealerTrailer.

    All methods are static (module-level functions). The service does not
    hold state between calls; the messageCenter subscription for buy
    responses is scoped to each buyAnimals() invocation via closure.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalBuyService = {}


--- Compute the dealer-marked-up buy price for a single animal.
--- @param animal table Animal/cluster object
--- @return number price Dealer buy price (positive): getSellPrice() * 1.075
function RLAnimalBuyService.computeBuyPrice(animal)
    if animal == nil then
        Log:warning("RLAnimalBuyService.computeBuyPrice: nil animal")
        return 0
    end

    -- 1.075 dealer markup: scripts/animals/shop/AnimalItemNew.lua:158-160
    local price = (animal:getSellPrice() or 0) * 1.075
    Log:trace("RLAnimalBuyService.computeBuyPrice: price=%.0f", price)
    return price
end


--- Compute aggregate buy totals for an array of animals.
--- Buy adds fee to price (player pays both), opposite of Sell which
--- subtracts fee from price.
--- @param animals table Array of Animal/cluster objects
--- @return number totalPrice Sum of dealer buy prices (positive)
--- @return number totalFee Sum of transportation fees (positive)
--- @return number total Gross cost (totalPrice + totalFee)
--- @return number count Number of animals
function RLAnimalBuyService.computeBulkTotal(animals)
    if animals == nil or #animals == 0 then
        return 0, 0, 0, 0
    end

    local totalPrice = 0
    local totalFee = 0
    for _, animal in ipairs(animals) do
        totalPrice = totalPrice + (animal:getSellPrice() or 0) * 1.075
        totalFee = totalFee + (animal:getTranportationFee(1) or 0)
    end

    local total = totalPrice + totalFee
    Log:debug("RLAnimalBuyService.computeBulkTotal: %d animals, price=%.0f fee=%.0f total=%.0f",
        #animals, totalPrice, totalFee, total)
    return totalPrice, totalFee, total, #animals
end


--- Build the single-animal confirmation text using existing rl_ui_buyConfirmation.
--- Format: "Are you sure you want to buy %s animals for %s?" (count, total-money).
--- @param _animal table Animal/cluster object (unused today; reserved for future naming)
--- @param price number Dealer buy price (positive)
--- @param fee number Transportation fee (positive)
--- @return string Formatted confirmation text
function RLAnimalBuyService.buildSingleConfirmationText(_animal, price, fee)
    local total = (price or 0) + (fee or 0)
    local formatted = g_i18n:formatMoney(total, 0, true, true)
    return string.format(g_i18n:getText("rl_ui_buyConfirmation"), 1, formatted)
end


--- Build the bulk buy confirmation text.
--- @param count number Number of animals
--- @param totalPrice number Sum of buy prices (positive)
--- @param totalFee number Sum of transportation fees (positive)
--- @return string Formatted confirmation text
function RLAnimalBuyService.buildBulkConfirmationText(count, totalPrice, totalFee)
    local total = (totalPrice or 0) + (totalFee or 0)
    local formatted = g_i18n:formatMoney(total, 0, true, true)
    return string.format(g_i18n:getText("rl_ui_buyConfirmation"), count, formatted)
end


--- Build the partial-confirmation text for a destination that cannot accept every
--- selected animal (capacity or EPP age rejection). The dialog text uses
--- validCount + totalCount + total-price only (existing key
--- `rl_ui_buyPartialConfirmation`). The `rejected` array (full {animal, reason}
--- tuples from AnimalScreenMoveFarm.buildMoveValidationResult) is accepted for
--- future UX enhancement (RLRM-159); today it is iterated for grouped TRACE
--- logging only.
--- @param validCount number Number of animals that passed validation
--- @param totalCount number Number of animals originally selected
--- @param rejected table Array of { animal, reason } rejection tuples
--- @param totalPrice number Sum of buy prices for the valid subset (positive)
--- @param totalFee number Sum of transportation fees for the valid subset (positive)
--- @return string Formatted confirmation text
function RLAnimalBuyService.buildPartialConfirmationText(validCount, totalCount, rejected, totalPrice, totalFee)
    validCount = validCount or 0
    totalCount = totalCount or 0
    totalPrice = totalPrice or 0
    totalFee = totalFee or 0

    -- Group rejection reasons for TRACE-level diagnostics (RLRM-159 future).
    if rejected ~= nil and #rejected > 0 then
        local counts = {}
        for _, entry in ipairs(rejected) do
            local reason = entry and entry.reason or "UNKNOWN"
            counts[reason] = (counts[reason] or 0) + 1
        end
        for reason, c in pairs(counts) do
            Log:trace("RLAnimalBuyService.buildPartialConfirmationText: rejection reason %s x%d",
                tostring(reason), c)
        end
    end

    local total = totalPrice + totalFee
    local formatted = g_i18n:formatMoney(total, 0, true, true)
    return string.format(g_i18n:getText("rl_ui_buyPartialConfirmation"),
        validCount, totalCount, formatted)
end


--- Send the buy event to the server and subscribe to the response.
--- Mirrors RLAnimalSellService.sellAnimals subscription pattern.
--- The callback fires once with (target, errorCode) when the server responds.
---
--- CRITICAL SIGN CONVENTION: AnimalBuyEvent.lua:103 server-side does
---   g_currentMission:addMoney(buyPrice + transportPrice, ...)
--- so BOTH values are dispatched as NEGATIVE numbers (matches legacy
--- AnimalScreenDealer.lua:143-144). A positive dispatch credits the farm.
--- @param destination table The destination placeable (entry.placeable from getValidDestinations)
--- @param animals table Array of Animal/cluster objects to buy
--- @param totalPrice number Sum of buy prices (POSITIVE input; negated on dispatch)
--- @param totalFee number Sum of transportation fees (POSITIVE input; negated on dispatch)
--- @param callback function Callback function(target, errorCode)
--- @param target table Callback target (typically the frame)
function RLAnimalBuyService.buyAnimals(destination, animals, totalPrice, totalFee, callback, target)
    if animals == nil or #animals == 0 then
        Log:debug("RLAnimalBuyService.buyAnimals: no animals, skipping")
        return
    end
    if destination == nil then
        Log:warning("RLAnimalBuyService.buyAnimals: nil destination")
        return
    end

    Log:debug("RLAnimalBuyService.buyAnimals: %d animals to '%s' (price=%.0f fee=%.0f)",
        #animals,
        tostring(destination.getName and destination:getName()),
        totalPrice or 0, totalFee or 0)

    -- Subscription handler: unsubscribe immediately on response, then fire
    -- caller's callback. Unique table as subscription identity to avoid
    -- cross-fire with other subscribers.
    local subscriptionId = {}
    local function onBuyResponse(_self, errorCode)
        Log:trace("RLAnimalBuyService.onBuyResponse: errorCode=%s", tostring(errorCode))
        g_messageCenter:unsubscribe(AnimalBuyEvent, subscriptionId)

        if errorCode == AnimalBuyEvent.BUY_SUCCESS then
            Log:info("RLAnimalBuyService.onBuyResponse: buy succeeded (%d animals)", #animals)

            -- MP client-side sale-list mirror. Server did the authoritative
            -- removal at AnimalBuyEvent.lua:97 before firing this response,
            -- but in MP the client's local g_currentMission.animalSystem.animals
            -- list is never auto-synced - so the buying client would see the
            -- just-bought animals reappear on reloadAnimalList until some
            -- other sync. Legacy mirrors this exact loop in
            -- RL_AnimalScreenDealerFarm:onAnimalBought at
            -- AnimalScreenDealerFarm.lua:84-92.
            if g_currentMission ~= nil
                and g_currentMission.animalSystem ~= nil
                and g_currentMission.animalSystem.removeSaleAnimal ~= nil then
                for _, animal in ipairs(animals) do
                    if animal.animalTypeIndex ~= nil
                        and animal.birthday ~= nil
                        and animal.birthday.country ~= nil then
                        g_currentMission.animalSystem:removeSaleAnimal(
                            animal.animalTypeIndex,
                            animal.birthday.country,
                            animal.farmId,
                            animal.uniqueId)
                        Log:trace("RLAnimalBuyService.onBuyResponse: local removeSaleAnimal typeIdx=%s farmId=%s uniqueId=%s",
                            tostring(animal.animalTypeIndex),
                            tostring(animal.farmId),
                            tostring(animal.uniqueId))
                    end
                end
            end
        else
            Log:debug("RLAnimalBuyService.onBuyResponse: buy failed, errorCode=%d", errorCode)
        end

        if callback ~= nil then
            if target ~= nil then
                callback(target, errorCode)
            else
                callback(errorCode)
            end
        end
    end

    g_messageCenter:subscribe(AnimalBuyEvent, onBuyResponse, subscriptionId)
    Log:trace("RLAnimalBuyService.buyAnimals: subscribed to AnimalBuyEvent, sending event")

    -- Pre-negate both price and fee. See file header for full rationale.
    local negPrice = -(totalPrice or 0)
    local negFee = -(totalFee or 0)
    Log:trace("RLAnimalBuyService.buyAnimals: dispatching AnimalBuyEvent price=%.0f fee=%.0f",
        negPrice, negFee)
    g_client:getServerConnection():sendEvent(
        AnimalBuyEvent.new(destination, animals, negPrice, negFee)
    )
    Log:trace("RLAnimalBuyService.buyAnimals: sendEvent returned")
end


--- Map an AnimalBuyEvent error code to a localized error string.
--- Delegates to AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING (shape
--- `[code] = { warning = bool, text = i18n_key }`).
--- @param errorCode number The error code from AnimalBuyEvent
--- @return string Localized error text, or a generic fallback for unknown codes
function RLAnimalBuyService.getErrorText(errorCode)
    local mapping = AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING[errorCode]
    if mapping ~= nil and mapping.text ~= nil then
        Log:trace("RLAnimalBuyService.getErrorText: code=%s -> key='%s'",
            tostring(errorCode), mapping.text)
        return g_i18n:getText(mapping.text)
    end
    Log:warning("RLAnimalBuyService.getErrorText: unknown errorCode=%s, using fallback",
        tostring(errorCode))
    return g_i18n:getText("shop_messageNoPermissionToTradeAnimals")
end
