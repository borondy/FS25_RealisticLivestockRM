RL_FarmManager = {}

local Log = RmLogging.getLogger("RLRM")

function RL_FarmManager:loadFromXMLFile(superFunc, path)

    -- Migration detection runs server-only because RmMigrationDialog and shouldMigrate()
    -- both reference the savegame directory, which is server-authoritative (clients have
    -- savegameDir=nil). Mod-compatibility detection (block + warn) lives in
    -- RealisticLivestock_FSBaseMission:onStartMission so it runs on every peer using
    -- g_modIsLoaded. Early migration of
    -- items.xml / handTools.xml is owned by RmItemSystemMigration's ItemSystem hook,
    -- which runs before this point.
    if g_currentMission:getIsServer() then
        Log:info("FarmManager: Checking migration state...")

        -- Create migration manager if RmItemSystemMigration didn't already.
        -- Idempotent with the lazy-create at the top of FSBaseMission:onStartMission
        -- (which covers the pure-client path that never reaches FarmManager).
        if g_rmMigrationManager == nil then
            Log:info("FarmManager: Creating RmMigrationManager instance")
            g_rmMigrationManager = RmMigrationManager.new()
        end

        if not g_rmPendingMigration and g_rmMigrationManager:shouldMigrate() then
            -- Migration needed but wasn't handled by RmItemSystemMigration (shouldn't happen normally).
            -- Fallback in case the ItemSystem hook didn't run.
            Log:info("FarmManager: Migration needed (fallback path)")
            g_rmPendingMigration = true
        else
            Log:debug("FarmManager: shouldMigrate=false or already pending (g_rmPendingMigration=%s)",
                tostring(g_rmPendingMigration))
        end

        Log:info("FarmManager: g_rmPendingMigration = %s", tostring(g_rmPendingMigration))
    else
        Log:debug("FarmManager: Not running on server, skipping migration check")
    end

    local returnValue = superFunc(self, path)

    local animalSystem = g_currentMission.animalSystem
    animalSystem:initialiseCountries()

    if g_currentMission:getIsServer() then
        local hasData = animalSystem:loadFromXMLFile()
        animalSystem:validateFarms(hasData)
    end

    return returnValue

end

FarmManager.loadFromXMLFile = Utils.overwrittenFunction(FarmManager.loadFromXMLFile, RL_FarmManager.loadFromXMLFile)
