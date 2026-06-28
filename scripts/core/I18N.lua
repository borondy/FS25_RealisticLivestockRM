RL_I18N = {}
local modName = g_currentModName
local isGithubVersion = true

-- Keys that come in with `modEnv == nil` even though they belong to this
-- mod's translation environment. Routing them through `modName` lets the
-- caller's lookup resolve from our texts table.
--
-- Two flavours per custom finance category:
--   * `rl_ui_<stat>`   - the user-facing key passed to `MoneyType.register`.
--   * `finance_<stat>` - what the Finance overview queries for each
--                        registered stat name.
-- Both must appear here for every entry added to `FinanceStats.statNames`
-- (see `scripts/core/RealisticLivestock.lua` and
-- `scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua`) or the
-- Finance row renders the `Missing '<key>' in l10n_en.xml` fallback.
local MOD_ROUTED_KEYS = {
    rl_ui_monitorSubscriptions = true,
    finance_monitorSubscriptions = true,
    rl_ui_herdsmanWages = true,
    finance_herdsmanWages = true,
    rl_ui_semenPurchase = true,
    finance_semenPurchase = true,
    rl_ui_medicine = true,
    finance_medicine = true,
}

-- I18N is a singleton overwrite (not a spec-chain method), so the
-- `Utils.overwrittenFunction` superFunc-arg-drop gotcha does not apply here.
function RL_I18N:getText(superFunc, text, modEnv)

    -- Defensive: a nil key can reach this global override when a caller looks up a missing
    -- localization key; delegate it to the base implementation rather than crash in
    -- string.contains below, which requires a string. WARNING so a real nil-key bug stays
    -- visible (revisit the level if other mods make this noisy).
    if text == nil then
        Log:warning("I18N: nil key passed to getText override; delegating to base implementation")
        return superFunc(self, text, modEnv)
    end

    if modEnv == nil and MOD_ROUTED_KEYS[text] then
        Log:trace("I18N: routing modless lookup '%s' through mod env", text)
        return superFunc(self, text, modName)
    end

    if isGithubVersion and string.contains(text, "rl_") then

        local env = self.modEnvironments[modName]

        if env == nil then return superFunc(self, text, modEnv) end

        if env.texts[text .. "_github"] ~= nil then return env.texts[text .. "_github"] end

    end

    return superFunc(self, text, modEnv)

end

I18N.getText = Utils.overwrittenFunction(I18N.getText, RL_I18N.getText)