-- RLAnimalDisplayHelper.lua
-- Display helpers for the animal list surfaces (name tag + sort order).
--
-- Owns the two presentation helpers every animal list shares:
--   * formatDisplayName - append the genetics tag to a name per the player's
--     geneticsDisplay / geneticsPosition settings.
--   * sortAnimals       - the table.sort comparator (disease-first, subtype,
--     optional genetics, age).
--
-- A utils home (loads early, neutral to every consumer tree) so the rlmenu
-- services, the kept page-4 frame, and the shop item models can all reach one
-- copy of this behavior.

local Log = RmLogging.getLogger("RLRM")

RLAnimalDisplayHelper = {}

--- Apply the genetics name tag to a display name per the player's geneticsDisplay
--- / geneticsPosition settings.
---
--- Mode (RLSettings.SETTINGS.geneticsDisplay.state): 1/nil = off (name returned
--- unchanged); 2 = compact `[NN]` average only; 3 = full `[NN-MM:HH:FF:QQ(:PP)]`
--- per-stat tag (productivity appended only when the species carries it).
--- Position (geneticsPosition.state == 2) puts the tag after the name, otherwise
--- before. An empty/nil name yields the bare tag. Missing / empty / non-table
--- genetics returns the name untouched (and never divides by zero).
---@param name string|nil display name to tag
---@param animal table|nil animal carrying a `genetics` sub-table
---@return string tagged name (or the original when tagging does not apply)
function RLAnimalDisplayHelper.formatDisplayName(name, animal)
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
        tag = string.format("[%02d]", RLScaleHelper.scaleToNinetyNine(avg))
    else
        local m = genetics.metabolism and RLScaleHelper.scaleToNinetyNine(genetics.metabolism) or 0
        local h = genetics.health and RLScaleHelper.scaleToNinetyNine(genetics.health) or 0
        local f = genetics.fertility and RLScaleHelper.scaleToNinetyNine(genetics.fertility) or 0
        local q = genetics.quality and RLScaleHelper.scaleToNinetyNine(genetics.quality) or 0

        if genetics.productivity ~= nil then
            local p = RLScaleHelper.scaleToNinetyNine(genetics.productivity)
            tag = string.format("[%02d-%02d:%02d:%02d:%02d:%02d]", RLScaleHelper.scaleToNinetyNine(avg), m, h, f, q, p)
        else
            tag = string.format("[%02d-%02d:%02d:%02d:%02d]", RLScaleHelper.scaleToNinetyNine(avg), m, h, f, q)
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

--- Comparator for the animal list (passed to table.sort). Orders diseased animals
--- first, then ascending subTypeIndex, then - when RLSettings.SETTINGS.sortByGenetics
--- is on (state 2) - descending cached average genetics, and finally ascending age.
---
--- Operates on list ITEMS shaped `{ cluster = <cluster>, cachedAvgGenetics = <n> }`:
--- the cluster must expose `getHasAnyDisease()`, `subTypeIndex`, and `age`. A nil
--- cluster on either side sorts as `false` (intentionally asymmetric - safe inside
--- table.sort, where the caller supplies well-formed items).
---@param a table list item carrying a `.cluster`
---@param b table list item carrying a `.cluster`
---@return boolean aBeforeB true when `a` sorts before `b`
function RLAnimalDisplayHelper.sortAnimals(a, b)

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

Log:trace("RLAnimalDisplayHelper: loaded")
