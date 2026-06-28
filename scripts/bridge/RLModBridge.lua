--[[
    RLModBridge.lua
    Lightweight mod-compat bridge for RealisticLivestockRM.

    Sibling to RLMapBridge but deliberately scoped down: no compat.xml schema,
    no version-spec gating, no console command, no third-party scanning. Used
    where RLRM needs to coexist with a single foreign mod that overlaps the
    same hooks (current target: FS25_SeasonalWoolProduction).

    Two-phase install:
    - Module-load phase  (runModuleLoadPhase): runs when this file is sourced
      from main.lua. Iterates SUPPORTED_MODS and source()s each shim file
      unconditionally on the server. Required for shims whose hooks must be
      installed before SpecializationUtil captures function references at
      spec-init time. g_modIsLoaded is not yet populated for mods that load
      alphabetically after RLRM at this point, so source-load cannot gate on
      mod presence; per-shim safeCall isolates failures.
    - Deferred phase     (runDeferredPhase): appended to
      Mission00.loadMission00Finished. Iterates the registry again, checks
      g_modIsLoaded[mod], invokes the shim's lateInstall(bridge) for state
      population + late-binding patches (foreign class tables exist by now).

    Observable state:
    - activeShims[modName] = true     -- shim's hourly hook is wired and the
                                         required foreign methods are callable
    - shimErrors[modName] = "<reason>" -- WARN companion; lets tests assert
                                         on state instead of log spies
    - originalRefs[modName]            -- saved foreign-function references
                                         for restoreOriginals(modName)
]]

RLModBridge = {}

local Log = RmLogging.getLogger("RLRM")
local modDirectory = g_currentModDirectory

--- Registry of compat shims.
--- Each entry: { modName = "FS25_...", shimPath = "mod_support/.../*.lua",
---               shimGlobal = "ShimXxx", name = "Human-readable name" }
--- shimGlobal is the global table name the shim exports; the deferred phase
--- looks up _G[shimGlobal].lateInstall(bridge). No naming convention magic.
RLModBridge.SUPPORTED_MODS = {
    {
        modName = "FS25_SeasonalWoolProduction",
        shimPath = "mod_support/FS25_SeasonalWoolProduction/FS25_SeasonalWoolProduction.lua",
        shimGlobal = "ShimWoolCompat",
        name = "Seasonal Wool Production"
    }
}

RLModBridge.activeShims = {}
RLModBridge.shimErrors = {}
RLModBridge.originalRefs = {}
RLModBridge._sourced = false
RLModBridge._deferredRan = false

--- Server-context check, factored out so tests can swap it without mutating
--- root g_* globals.
--- @return boolean true if this process is acting as a server
function RLModBridge.isServer()
    return g_server ~= nil
end

--- Indirect handle on the global `source` function. Tests swap this to a
--- counting/throwing stub so the source-load loop can be exercised without
--- actually loading lua files (and without mutating the global `source`).
RLModBridge._sourceLoader = source

--- Source-load every shim file once. Safe to call multiple times: second and
--- later calls are no-ops via _sourced. Server-only - clients have no need
--- for compat hooks since RLRM's wool path is server-side.
function RLModBridge.runModuleLoadPhase()
    if RLModBridge._sourced then
        Log:trace("RLModBridge: runModuleLoadPhase already ran, skipping")
        return
    end
    RLModBridge._sourced = true

    if not RLModBridge.isServer() then
        Log:info("RLModBridge: client context, skipping shim source-load")
        return
    end

    for _, entry in ipairs(RLModBridge.SUPPORTED_MODS) do
        local ctx = "RLModBridge.source:" .. entry.modName
        local ok = RmSafeUtils.safeCall(ctx, function()
            RLModBridge._sourceLoader(modDirectory .. entry.shimPath)
        end)
        if not ok then
            RLModBridge.shimErrors[entry.modName] = "source-load failed"
            Log:warning("RLModBridge: source-load failed for %s (%s); other shims unaffected",
                entry.name, entry.modName)
        else
            Log:debug("RLModBridge: sourced shim %s", entry.modName)
        end
    end
end

--- State-population + late-binding-patch phase. Fires from
--- Mission00.loadMission00Finished. Idempotent via _deferredRan.
--- Server-only at first line so client bookkeeping stays empty.
function RLModBridge.runDeferredPhase()
    if not g_currentMission:getIsServer() then return end

    if RLModBridge._deferredRan then
        Log:trace("RLModBridge: runDeferredPhase already ran, skipping")
        return
    end
    RLModBridge._deferredRan = true

    for _, entry in ipairs(RLModBridge.SUPPORTED_MODS) do
        if not g_modIsLoaded[entry.modName] then
            Log:info("RLModBridge: skipped %s (mod not loaded)", entry.modName)
        else
            local shim = _G[entry.shimGlobal]
            if shim == nil or type(shim.lateInstall) ~= "function" then
                RLModBridge.shimErrors[entry.modName] = "shim global or lateInstall missing"
                Log:warning("RLModBridge: shim %s (%s) has no lateInstall; activeShims left nil",
                    entry.shimGlobal, entry.modName)
            else
                local ctx = "RLModBridge.lateInstall:" .. entry.modName
                local ok = RmSafeUtils.safeCall(ctx, function()
                    shim.lateInstall(RLModBridge)
                end)
                if not ok then
                    RLModBridge.shimErrors[entry.modName] = "lateInstall threw"
                    Log:warning("RLModBridge: lateInstall threw for %s; check error log above",
                        entry.modName)
                end
            end
        end
    end
end

--- Restore originals saved by a shim's lateInstall. Used by tests (between
--- cases) and could be used by a future runtime toggle. Idempotent: a second
--- restore after originalRefs has been cleared is a no-op.
--- @param modName string e.g. "FS25_SeasonalWoolProduction"
function RLModBridge.restoreOriginals(modName)
    local refs = RLModBridge.originalRefs[modName]
    if refs == nil then return end
    local restoreMap = refs._restoreMap
    if restoreMap ~= nil then
        for fieldName, location in pairs(restoreMap) do
            local saved = refs[fieldName]
            if location.table ~= nil and saved ~= nil then
                location.table[location.key] = saved
            end
        end
    end
    RLModBridge.originalRefs[modName] = nil
    RLModBridge.activeShims[modName] = nil
    Log:info("RLModBridge: restored originals for %s", modName)
end

-- ============================================================
-- Module-load + deferred-phase wiring
-- ============================================================

RLModBridge.runModuleLoadPhase()

Mission00.loadMission00Finished = Utils.appendedFunction(
    Mission00.loadMission00Finished,
    function()
        RLModBridge.runDeferredPhase()
    end
)
