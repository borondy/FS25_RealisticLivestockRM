--[[
    RLAIStockService.lua
    Read-only query + presentation service for the RL Tabbed Menu AI tab:
      * list every registered animal species (no stock filter)
      * list AI stock bulls for a given species
      * group into SmoothList sections (per-subtype; no "Diseased" section -
        AI stock bulls are never sick in normal play)
      * overall-quality label computation for the row (carries forward legacy
        behavior at AnimalScreen.lua:2200-2217 - overall-quality label in
        the "price" slot of each row)
      * per-quantity semen price computation for the middle-column display
        (Phase 1 uses quantity = 1; Phase 2 wires the quantity stepper)

    Disjoint from RLAnimalQuery / RLDealerQuery: AI stock comes from
    animalSystem:getAIAnimalsByTypeIndex, not from husbandries or dealer stock.
]]

RLAIStockService = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Species enumeration
-- =============================================================================

--- Return every registered animal species (cow / pig / sheep & goats / horse /
--- chicken), sorted ascending by typeIndex for deterministic ordering.
---
--- Legacy AI screen at AnimalScreen.lua:508-518 uses a `pairs()` loop which
--- does NOT guarantee order across Lua versions - Lua 5.1's pairs happens to
--- iterate integer-keyed tables in insertion order for this specific table
--- shape, so legacy's output happens to match typeIndex-ascending in practice.
--- This service is explicit: collect + table.sort by typeIndex.
---
--- Does NOT filter by current stock - zero-stock species still appear in the
--- cycler with an empty list body (matches how the rest of the RL Menu frames
--- handle empty-stock / empty-husbandry states).
--- @return table types  Array of animal type entries from animalSystem:getTypes()
function RLAIStockService.listSpecies()
    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLAIStockService.listSpecies: animalSystem unavailable")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getTypes == nil then
        Log:warning("RLAIStockService.listSpecies: animalSystem.getTypes unavailable")
        return {}
    end

    local rawTypes = animalSystem:getTypes()
    if rawTypes == nil then return {} end

    local result = {}
    for _, animalType in pairs(rawTypes) do
        if animalType ~= nil and animalType.typeIndex ~= nil then
            table.insert(result, animalType)
        end
    end

    table.sort(result, function(a, b)
        return (a.typeIndex or 0) < (b.typeIndex or 0)
    end)

    Log:trace("RLAIStockService.listSpecies: returned %d species (sorted by typeIndex)", #result)
    return result
end

-- =============================================================================
-- AI bulls for a species
-- =============================================================================

--- Wrap an AI stock bull in an AnimalItemStock - the same base-game wrapper
--- Sell/Move/Info/Buy use via the other query services. Gives us
--- `getFilename()` (animal portrait), `title`, and `.cluster` for free.
--- Exposed as a field so tests can swap in a lightweight stub.
--- @param animal table  Animal object from animalSystem:getAIAnimalsByTypeIndex
--- @return table|nil item
function RLAIStockService._wrapBull(animal)
    if animal == nil then return nil end
    if AnimalItemStock == nil or AnimalItemStock.new == nil then return nil end
    return AnimalItemStock.new(animal)
end

--- Return AI-stock items for the given species, sorted by subTypeIndex
--- ascending then age descending (mirrors legacy comparator at
--- AnimalScreen.lua:511). Empty for unknown / empty species.
--- @param typeIndex number
--- @return table items
function RLAIStockService.listBullsForSpecies(typeIndex)
    if typeIndex == nil then return {} end

    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLAIStockService.listBullsForSpecies: animalSystem unavailable")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getAIAnimalsByTypeIndex == nil then
        Log:warning("RLAIStockService.listBullsForSpecies: getAIAnimalsByTypeIndex unavailable")
        return {}
    end

    local animals = animalSystem:getAIAnimalsByTypeIndex(typeIndex)
    if animals == nil then
        Log:trace("RLAIStockService.listBullsForSpecies: typeIndex=%s no animals", tostring(typeIndex))
        return {}
    end

    local items = {}
    for _, animal in pairs(animals) do
        local wrapped = RLAIStockService._wrapBull(animal)
        if wrapped ~= nil then
            table.insert(items, wrapped)
        end
    end

    -- Legacy comparator at AnimalScreen.lua:511:
    --   (a.subTypeIndex == b.subTypeIndex) and (a.age > b.age) or (a.subTypeIndex < b.subTypeIndex)
    -- Same subtype -> older first; different subtype -> lower subtype first.
    table.sort(items, function(a, b)
        local aSub = a.cluster and a.cluster.subTypeIndex or 0
        local bSub = b.cluster and b.cluster.subTypeIndex or 0
        if aSub == bSub then
            local aAge = a.cluster and a.cluster.age or 0
            local bAge = b.cluster and b.cluster.age or 0
            return aAge > bAge
        end
        return aSub < bSub
    end)

    Log:trace("RLAIStockService.listBullsForSpecies: typeIndex=%s items=%d",
        tostring(typeIndex), #items)
    return items
end

-- =============================================================================
-- Section grouping (SmoothList multi-section data source)
-- =============================================================================

--- Group bull items into sections, one section per distinct subTypeIndex.
---
--- No "Diseased" section: AI stock bulls are fresh dealer-generated animals
--- with no disease state in normal play. (If that assumption ever breaks,
--- diseased AI bulls would end up in whichever subtype section they belong
--- to, which is acceptable degradation.)
---
--- Sections are created in the order they are encountered during iteration,
--- so listBullsForSpecies guarantees they appear in ascending subTypeIndex
--- order (via its comparator).
---
--- Parallel tables:
---   sectionOrder[]   : opaque section keys in display order
---   itemsBySection   : key -> items array
---   titlesBySection  : key -> localized title (via g_fillTypeManager)
---
--- Empty items -> all three tables empty. Drives the empty-animals text.
--- Pure function on the items array.
--- @param items table
--- @return table sectionOrder, table itemsBySection, table titlesBySection
function RLAIStockService.buildSections(items)
    Log:trace("RLAIStockService.buildSections: items=%d",
        (items ~= nil and #items) or 0)

    local sectionOrder    = {}
    local itemsBySection  = {}
    local titlesBySection = {}

    if items == nil or #items == 0 then
        return sectionOrder, itemsBySection, titlesBySection
    end

    for _, item in ipairs(items) do
        local cluster = item.cluster
        if cluster ~= nil then
            local key = "subtype_" .. tostring(cluster.subTypeIndex or 0)
            local title = item.title
            if (title == nil or title == "") and g_currentMission ~= nil
                and g_currentMission.animalSystem ~= nil then
                local subType = g_currentMission.animalSystem:getSubTypeByIndex(
                    cluster.subTypeIndex)
                if subType ~= nil and subType.fillTypeIndex ~= nil
                    and g_fillTypeManager ~= nil then
                    title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)
                end
            end
            if title == nil or title == "" then title = "?" end

            if itemsBySection[key] == nil then
                table.insert(sectionOrder, key)
                itemsBySection[key] = {}
                titlesBySection[key] = title
            end
            table.insert(itemsBySection[key], item)
        end
    end

    return sectionOrder, itemsBySection, titlesBySection
end

-- =============================================================================
-- Overall-quality label (row "price" slot)
-- =============================================================================

--- Compute the overall-quality i18n key for a bull based on its average
--- genetics. Thresholds and label strings mirror legacy exactly at
--- AnimalScreen.lua:2200-2215 - the same computation legacy writes into the
--- row's "price" cell via `cell:getAttribute("price"):setText(...)`.
---
---   avgGenetics >= 1.65 -> extremelyGood
---   avgGenetics >= 1.35 -> veryGood
---   avgGenetics >= 1.15 -> good
---   avgGenetics >= 0.85 -> average
---   avgGenetics >= 0.65 -> bad
---   avgGenetics >= 0.35 -> veryBad
---   else                 -> extremelyBad
---
--- Returned string is the full i18n key (e.g. "rl_ui_genetics_veryGood") so
--- callers can pass it straight to `g_i18n:getText`.
--- @param animal table  Raw Animal (not wrapped) - needs `animal.genetics` table
--- @return string i18nKey
function RLAIStockService.getQualityLabel(animal)
    if animal == nil or animal.genetics == nil then
        Log:trace("RLAIStockService.getQualityLabel: nil animal or genetics -> extremelyBad")
        return "rl_ui_genetics_extremelyBad"
    end

    local genetics = 0
    local numGenetics = 0
    for _, value in pairs(animal.genetics) do
        genetics = genetics + value
        numGenetics = numGenetics + 1
    end

    local avgGenetics = (numGenetics > 0 and genetics / numGenetics) or 0
    local label = "extremelyBad"

    if avgGenetics >= 1.65 then
        label = "extremelyGood"
    elseif avgGenetics >= 1.35 then
        label = "veryGood"
    elseif avgGenetics >= 1.15 then
        label = "good"
    elseif avgGenetics >= 0.85 then
        label = "average"
    elseif avgGenetics >= 0.65 then
        label = "bad"
    elseif avgGenetics >= 0.35 then
        label = "veryBad"
    end

    Log:trace("RLAIStockService.getQualityLabel: uniqueId=%s avg=%.3f -> %s",
        tostring(animal.uniqueId), avgGenetics, label)
    return "rl_ui_genetics_" .. label
end

-- =============================================================================
-- Semen price (middle-column total-price display)
-- =============================================================================

--- Compute the total semen purchase price for the given bull and straw
--- quantity. Returns the FINAL price including PRICE_PER_STRAW - not an
--- intermediate. Matches `AnimalScreen.lua:547` ordering verbatim:
---
---   price = getFarmSemenPrice(country, farmId)
---         * quantity
---         * PRICE_PER_STRAW
---         * animal.success
---         * 2.25
---         * product(animal.genetics)
---
--- Legacy has a second display-side computation at `AnimalScreen.lua:699 + 703`
--- that splits PRICE_PER_STRAW into the `setText` call; math is equivalent,
--- but this service returns the complete price for clarity. Phase 1 callers
--- pass quantity = 1; Phase 2 wires the stepper to call with any DEWAR_QUANTITIES
--- value.
--- @param animal table  Raw Animal with `.birthday.country`, `.farmId`, `.success`, `.genetics`
--- @param quantity number  Positive integer straw count
--- @return number price
function RLAIStockService.getPriceForQuantity(animal, quantity)
    if animal == nil or quantity == nil or quantity <= 0 then
        return 0
    end

    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLAIStockService.getPriceForQuantity: animalSystem unavailable")
        return 0
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getFarmSemenPrice == nil then
        Log:warning("RLAIStockService.getPriceForQuantity: getFarmSemenPrice unavailable")
        return 0
    end

    local country = (animal.birthday ~= nil and animal.birthday.country) or 0
    local farmId  = animal.farmId or 0

    local pricePerStraw = (DewarData ~= nil and DewarData.PRICE_PER_STRAW) or 0.85
    local success = animal.success or 0

    local price = animalSystem:getFarmSemenPrice(country, farmId)
        * quantity
        * pricePerStraw
        * success
        * 2.25

    if type(animal.genetics) == "table" then
        for _, value in pairs(animal.genetics) do
            price = price * value
        end
    end

    Log:trace("RLAIStockService.getPriceForQuantity: uniqueId=%s quantity=%d price=%.2f",
        tostring(animal.uniqueId), quantity, price)
    return price
end
