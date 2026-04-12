--[[
    RLGeneticsFormatter.lua
    Pure genetics display formatter for the RL Tabbed Menu detail pane.

    Converts Animal genetics + type into a list of display-ready rows:
      { { labelKey, valueKey, colorKey }, ... }

    Thresholds match Animal:addGeneticsInfo. Pure module - no logging,
    no GUI calls, no g_* access. Unit-testable without a running mission.
]]

RLGeneticsFormatter = {}

-- =============================================================================
-- Tier label keys (localization keys resolved by the frame, not here)
-- =============================================================================

--- Keys used by the stat rows that lean "high = good": metabolism, health,
--- fertility, meat quality, productivity. Ordered highest-first so a linear
--- scan stops at the first threshold the value meets.
RLGeneticsFormatter.HIGH_TIER_KEYS = {
    "rl_ui_genetics_extremelyHigh",
    "rl_ui_genetics_veryHigh",
    "rl_ui_genetics_high",
    "rl_ui_genetics_average",
    "rl_ui_genetics_low",
    "rl_ui_genetics_veryLow",
    "rl_ui_genetics_extremelyLow",
}

--- Thresholds for the HIGH_TIER_KEYS ladder, one per key in the same order.
--- Value >= thresholds[i] selects keys[i]; values below the last threshold
--- fall through to "extremelyLow".
RLGeneticsFormatter.HIGH_TIER_THRESHOLDS = { 1.65, 1.4, 1.1, 0.9, 0.7, 0.35 }

--- Keys used by the Overall row, which leans "high = good" but uses a
--- separate "good/bad" vocabulary distinct from the other stats.
RLGeneticsFormatter.OVERALL_TIER_KEYS = {
    "rl_ui_genetics_extremelyGood",
    "rl_ui_genetics_veryGood",
    "rl_ui_genetics_good",
    "rl_ui_genetics_average",
    "rl_ui_genetics_bad",
    "rl_ui_genetics_veryBad",
    "rl_ui_genetics_extremelyBad",
}

--- Thresholds for the OVERALL_TIER_KEYS ladder. Matches
--- Animal:addGeneticsInfo thresholds.
RLGeneticsFormatter.OVERALL_TIER_THRESHOLDS = { 0.95, 0.8, 0.6, 0.4, 0.2, 0.05 }

--- Fertility has a special "infertile" tier at value == 0.
RLGeneticsFormatter.FERTILITY_INFERTILE_KEY = "rl_ui_genetics_infertile"

-- =============================================================================
-- Color keys (consumed by frame; frame maps key -> RGBA tuple for setTextColor)
-- =============================================================================

--- Color keys grouped by tier. Returned from format() as row.colorKey.
--- Frame maps color keys to RGBA tuples; no GUI profiles needed.
RLGeneticsFormatter.COLOR_KEY = {
    INFERTILE     = "infertile",     -- red
    EXTREMELY_LOW = "extremelyLow",  -- red
    VERY_LOW      = "veryLow",       -- red-orange
    LOW           = "low",           -- orange
    AVERAGE       = "average",       -- yellow
    HIGH          = "high",          -- yellow-green
    VERY_HIGH     = "veryHigh",      -- green
    EXTREMELY_HIGH = "extremelyHigh",-- bright green
}

--- Map from value-key suffix to display color key.
RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY = {
    rl_ui_genetics_infertile      = RLGeneticsFormatter.COLOR_KEY.INFERTILE,
    rl_ui_genetics_extremelyLow   = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_LOW,
    rl_ui_genetics_extremelyBad   = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_LOW,
    rl_ui_genetics_veryLow        = RLGeneticsFormatter.COLOR_KEY.VERY_LOW,
    rl_ui_genetics_veryBad        = RLGeneticsFormatter.COLOR_KEY.VERY_LOW,
    rl_ui_genetics_low            = RLGeneticsFormatter.COLOR_KEY.LOW,
    rl_ui_genetics_bad            = RLGeneticsFormatter.COLOR_KEY.LOW,
    rl_ui_genetics_average        = RLGeneticsFormatter.COLOR_KEY.AVERAGE,
    rl_ui_genetics_high           = RLGeneticsFormatter.COLOR_KEY.HIGH,
    rl_ui_genetics_good           = RLGeneticsFormatter.COLOR_KEY.HIGH,
    rl_ui_genetics_veryHigh       = RLGeneticsFormatter.COLOR_KEY.VERY_HIGH,
    rl_ui_genetics_veryGood       = RLGeneticsFormatter.COLOR_KEY.VERY_HIGH,
    rl_ui_genetics_extremelyHigh  = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_HIGH,
    rl_ui_genetics_extremelyGood  = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_HIGH,
}

-- =============================================================================
-- Tier resolution
-- =============================================================================

--- Pick a tier key from a value against a thresholds+keys ladder. Ladders
--- always have one more key than thresholds; values below the last threshold
--- fall through to the last key.
--- @param value number
--- @param thresholds table list of thresholds, highest first
--- @param keys table list of tier keys, same order as thresholds + 1
--- @return string key
function RLGeneticsFormatter.resolveTier(value, thresholds, keys)
    for i, threshold in ipairs(thresholds) do
        if value >= threshold then return keys[i] end
    end
    return keys[#keys]
end

--- Resolve a fertility value to its tier key, honoring the special
--- "infertile" case at value == 0.
--- @param fertility number
--- @return string key
function RLGeneticsFormatter.resolveFertilityTier(fertility)
    if fertility ~= nil and fertility <= 0 then
        return RLGeneticsFormatter.FERTILITY_INFERTILE_KEY
    end
    return RLGeneticsFormatter.resolveTier(
        fertility or 0,
        RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
        RLGeneticsFormatter.HIGH_TIER_KEYS
    )
end

-- =============================================================================
-- Productivity label per species
-- =============================================================================

--- Return the productivity row label key for an animal type, or nil when
--- the type has no productivity row.
--- @param animalTypeIndex number|nil
--- @return string|nil labelKey
function RLGeneticsFormatter.getProductivityLabelKey(animalTypeIndex)
    if animalTypeIndex == nil or AnimalType == nil then return nil end
    if animalTypeIndex == AnimalType.COW then return "rl_ui_milk" end
    if animalTypeIndex == AnimalType.SHEEP then return "rl_ui_wool" end
    if animalTypeIndex == AnimalType.CHICKEN then return "rl_ui_eggs" end
    return nil
end

-- =============================================================================
-- Public entry point
-- =============================================================================

--- Format an animal's genetics into display-ready rows.
---
--- Returns 5 rows for animals without a productivity stat (pigs, horses,
--- bulls) and 6 rows for cow/sheep/chicken. Rows are:
---   [1] Overall     ("good/bad" scale)
---   [2] Metabolism  ("high/low" scale)
---   [3] Health      ("high/low" scale)
---   [4] Fertility   ("high/low" scale, + infertile at 0)
---   [5] Meat        ("high/low" scale)
---   [6] Productivity (optional, species-dependent label Milk/Wool/Eggs)
---
--- Each row is `{ labelKey = string, valueKey = string, colorKey = string }`.
--- All values are localization keys; the frame resolves text, the color key
--- is mapped to an RGBA tuple by the frame.
---
--- Pure function: no side effects, no GUI, no g_* access.
---
--- @param genetics table|nil
--- @param animalTypeIndex number|nil
--- @return table rows
function RLGeneticsFormatter.format(genetics, animalTypeIndex)
    if genetics == nil then return {} end

    -- An empty / all-nil-stats genetics table is treated as no data.
    -- Avoids rendering five "Extremely Bad / Extremely Low" rows for animals
    -- with a zero-init genetics table (e.g. fresh imports, pallet animals).
    if genetics.metabolism == nil
        and genetics.health == nil
        and genetics.fertility == nil
        and genetics.quality == nil
        and genetics.productivity == nil then
        return {}
    end

    local rows = {}

    -- Row 1: Overall. Sums the five stats against 1.75 per best-slot.
    local productivity = genetics.productivity
    local metabolism   = genetics.metabolism or 0
    local quality      = genetics.quality or 0
    local health       = genetics.health or 0
    local fertility    = genetics.fertility or 0
    local hasProductivity = productivity ~= nil

    local overallSum = metabolism + quality + health + fertility + (hasProductivity and productivity or 0)
    local overallBest = 1.75 * (hasProductivity and 5 or 4)
    local overallFactor = (overallBest > 0) and (overallSum / overallBest) or 0
    local overallKey = RLGeneticsFormatter.resolveTier(
        overallFactor,
        RLGeneticsFormatter.OVERALL_TIER_THRESHOLDS,
        RLGeneticsFormatter.OVERALL_TIER_KEYS
    )
    table.insert(rows, {
        labelKey = "rl_ui_overall",
        valueKey = overallKey,
        colorKey = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[overallKey],
    })

    -- Row 2: Metabolism
    local metabolismKey = RLGeneticsFormatter.resolveTier(
        metabolism,
        RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
        RLGeneticsFormatter.HIGH_TIER_KEYS
    )
    table.insert(rows, {
        labelKey = "rl_ui_metabolism",
        valueKey = metabolismKey,
        colorKey = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[metabolismKey],
    })

    -- Row 3: Health
    local healthKey = RLGeneticsFormatter.resolveTier(
        health,
        RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
        RLGeneticsFormatter.HIGH_TIER_KEYS
    )
    table.insert(rows, {
        labelKey = "rl_ui_health",
        valueKey = healthKey,
        colorKey = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[healthKey],
    })

    -- Row 4: Fertility (with special infertile case)
    local fertilityKey = RLGeneticsFormatter.resolveFertilityTier(fertility)
    table.insert(rows, {
        labelKey = "rl_ui_fertility",
        valueKey = fertilityKey,
        colorKey = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[fertilityKey],
    })

    -- Row 5: Meat (quality)
    local meatKey = RLGeneticsFormatter.resolveTier(
        quality,
        RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
        RLGeneticsFormatter.HIGH_TIER_KEYS
    )
    table.insert(rows, {
        labelKey = "rl_ui_meat",
        valueKey = meatKey,
        colorKey = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[meatKey],
    })

    -- Row 6 (optional): Productivity — species-specific label
    local productivityLabel = RLGeneticsFormatter.getProductivityLabelKey(animalTypeIndex)
    if hasProductivity and productivityLabel ~= nil then
        local productivityKey = RLGeneticsFormatter.resolveTier(
            productivity,
            RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
            RLGeneticsFormatter.HIGH_TIER_KEYS
        )
        table.insert(rows, {
            labelKey = productivityLabel,
            valueKey = productivityKey,
            colorKey = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[productivityKey],
        })
    end

    return rows
end
