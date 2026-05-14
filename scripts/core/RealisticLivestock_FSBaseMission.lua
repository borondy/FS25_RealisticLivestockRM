RealisticLivestock_FSBaseMission = {}
local modDirectory = g_currentModDirectory
local modSettingsDirectory = g_currentModSettingsDirectory
local Log = RmLogging.getLogger("RLRM")


--[[
    Pure builder for the startup dialog queue. No globals read, no side effects.
    Takes a context table (assembled by the caller from globals + RLMapBridge state)
    and returns an ordered array of {kind=..., text?=...} items.

    Ordering and rules:
    - conflict (block-tier) wins over migration when both flags are set, because
      doRestart will reload everything anyway and the user must address the blocker
      first. Conflict has NO isServer guard - a joining client with a bad host
      modlist needs to fire its own dialog and doRestart out of the broken session
      (FS25 enforces identical mod sets in MP). On a headless dedicated server the
      InfoDialog primitive no-ops; the Log:error in checkModCompatibility is the
      admin-visible surface.
    - migration is server-only because RmMigrationDialog references the savegame.
    - warn and bridge are suppressed on dedicated servers because there is no GUI
      to render them; their log lines (in checkModCompatibility / RLMapBridge)
      are the dediserver-visible surfaces.

    Exposed as a module-table field (not local) so the test suite can call it
    directly with a synthetic ctx and assert on queue shape.

    @param ctx table {isServer, isDedicatedServer, hasConflict, hasMigration,
        hasWarn, hasBridgeWarning, bridgeText}
    @return table Ordered array of queue items.
]]
function RealisticLivestock_FSBaseMission._buildStartupQueue(ctx)
    local q = {}

    if ctx.hasConflict then
        table.insert(q, { kind = "conflict" })
    elseif ctx.isServer and ctx.hasMigration then
        table.insert(q, { kind = "migration" })
    end

    if ctx.hasWarn and not ctx.isDedicatedServer then
        table.insert(q, { kind = "warn" })
    end

    if ctx.hasBridgeWarning and not ctx.isDedicatedServer then
        table.insert(q, { kind = "bridge", text = ctx.bridgeText })
    end

    return q
end


--[[
    Assemble queue, log it, and dispatch the first item. Each presenter takes
    `showNext` as its close callback so the chain advances on dismissal. The
    conflict path's callback is intentionally never invoked - doRestart ends
    the Lua state, and the queue is abandoned at that point.

    Each presenter is responsible for its own Timer.createOneshot(100, ...) -
    the 100ms guards against the loading->gameplay transition swallowing the
    dialog. RmMigrationDialog's onClickContinue closes BEFORE invoking the
    callback,
    so two startup dialogs are never on screen simultaneously.
]]
local function _showStartupDialogs(self)
    -- Atomic capture-and-clear of bridge warning (mirrors prior pattern that
    -- sat at this exact location pre-refactor).
    local bridgeText = RLMapBridge.pendingVersionWarning
    RLMapBridge.pendingVersionWarning = nil

    local queue = RealisticLivestock_FSBaseMission._buildStartupQueue({
        isServer            = self:getIsServer(),
        isDedicatedServer   = (g_dedicatedServer ~= nil),
        hasConflict         = g_rmMigrationConflict,
        hasMigration        = g_rmPendingMigration,
        hasWarn             = g_rmPendingModWarning,
        -- Filter empty string in addition to nil; an empty bridge warning
        -- would otherwise enqueue a bridge-kind item with empty body, rendering
        -- a blank InfoDialog. Defensive against future producers - RLMapBridge
        -- itself only writes string.format results today.
        hasBridgeWarning    = (bridgeText ~= nil and bridgeText ~= ""),
        bridgeText          = bridgeText,
    })

    Log:debug("startup dialog queue: %d items (conflict=%s migration=%s warn=%s bridge=%s)",
        #queue, tostring(g_rmMigrationConflict), tostring(g_rmPendingMigration),
        tostring(g_rmPendingModWarning), tostring(bridgeText ~= nil))

    if #queue == 0 then return end

    local function showNext()
        local item = table.remove(queue, 1)
        if item == nil then
            Log:debug("startup dialog queue: drained")
            return
        end
        Log:debug("startup dialog queue: presenting kind=%s (remaining=%d)",
            item.kind, #queue)
        if item.kind == "conflict" then
            -- callback never fires; doRestart ends the chain
            g_rmMigrationManager:showConflictDialog(showNext)
        elseif item.kind == "migration" then
            g_rmMigrationManager:showMigrationDialog(showNext)
        elseif item.kind == "warn" then
            g_rmMigrationManager:showWarningDialog(showNext)
        elseif item.kind == "bridge" then
            -- Bridge presenter wraps its own 100ms Timer here (the other
            -- presenter kinds wrap inside their own RmMigrationManager methods).
            -- The 100ms guard preserves the loading->gameplay transition behaviour
            -- the pre-refactor inline block had at this site.
            Timer.createOneshot(100, function()
                -- Mid-startup unload guard (symmetric with RmMigrationManager
                -- presenters): if the user backed out during the 100ms window,
                -- advance the queue rather than calling InfoDialog against a
                -- torn-down GUI.
                if g_currentMission == nil or g_gui == nil then
                    Log:debug("bridge presenter timer fired post-unload; advancing queue")
                    showNext()
                    return
                end
                Log:info("Showing bridge version warning dialog")
                InfoDialog.show(item.text, function()
                    Log:info("User dismissed bridge version warning")
                    showNext()
                end)
            end)
        else
            Log:warning("startup dialog queue: unknown kind '%s', skipping", tostring(item.kind))
            showNext()
        end
    end

    showNext()
end


local function fixInGameMenu(frame, pageName, uvs, position, predicateFunc)

	local inGameMenu = g_gui.screenControllers[InGameMenu]
	position = position or #inGameMenu.pagingElement.pages + 1

	for k, v in pairs({pageName}) do
		inGameMenu.controlIDs[v] = nil
	end

	for i = 1, #inGameMenu.pagingElement.elements do
		local child = inGameMenu.pagingElement.elements[i]
		if child == inGameMenu.pageAnimals then
			position = i
            break
		end
	end
	
	inGameMenu[pageName] = frame
	inGameMenu.pagingElement:addElement(inGameMenu[pageName])

	inGameMenu:exposeControlsAsFields(pageName)

	for i = 1, #inGameMenu.pagingElement.elements do
		local child = inGameMenu.pagingElement.elements[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.elements, i)
			table.insert(inGameMenu.pagingElement.elements, position, child)
			break
		end
	end

	for i = 1, #inGameMenu.pagingElement.pages do
		local child = inGameMenu.pagingElement.pages[i]
		if child.element == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.pages, i)
			table.insert(inGameMenu.pagingElement.pages, position, child)
			break
		end
	end

	inGameMenu.pagingElement:updateAbsolutePosition()
	inGameMenu.pagingElement:updatePageMapping()
	
	inGameMenu:registerPage(inGameMenu[pageName], position, predicateFunc)
	inGameMenu:addPageTab(inGameMenu[pageName], modDirectory .. "gui/icons.dds", GuiUtils.getUVs(uvs))

	for i = 1, #inGameMenu.pageFrames do
		local child = inGameMenu.pageFrames[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pageFrames, i)
			table.insert(inGameMenu.pageFrames, position, child)
			break
		end
	end

	inGameMenu:rebuildTabList()

end


function RealisticLivestock_FSBaseMission:onStartMission()

    g_gui.guis.AnimalScreen:delete()
    g_gui:loadGui(modDirectory .. "gui/AnimalScreen.xml", "AnimalScreen", g_animalScreen)

    local xmlFile = XMLFile.loadIfExists("RealisticLivestock", modSettingsDirectory .. "Settings.xml")
    if xmlFile ~= nil then
        local maxHusbandries = xmlFile:getInt("Settings.setting(0)#maxHusbandries", 2)
        RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES = maxHusbandries
        xmlFile:delete()
    end

    -- Logged at INFO so support reports always carry this cap value
    -- (lives in modSettings/.../Settings.xml, otherwise invisible).
    Log:info("Maximum number of visual animals: %d", RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES)

    AnimalAIDialog.register()
    AnimalInfoDialog.register()
    DiseaseDialog.register()
    FileExplorerDialog.register()
    ProfileDialog.register()
    NameInputDialog.register()
    EarTagColourPickerDialog.register()
    AnimalFilterDialog.register()
    AnimalMoveDestinationDialog.register()
    RmMigrationDialog.register()

    -- Mod-compatibility detection runs on every peer (g_modIsLoaded is authoritative
    -- per peer). The lazy-create is idempotent with FarmManager.lua:15's existing
    -- nil-check; on a server the singleton is already created with savegameDir set,
    -- on a pure client it's a thin singleton with savegameDir=nil - safe because
    -- the methods reachable via the queue (showConflictDialog / showWarningDialog /
    -- checkModCompatibility) never touch savegameDir.
    if g_rmMigrationManager == nil then
        Log:debug("FSBaseMission: lazy-creating RmMigrationManager (client path)")
        g_rmMigrationManager = RmMigrationManager.new()
    end
    g_rmMigrationManager:checkModCompatibility()

    -- Build and dispatch the startup-dialog queue (migration / mod-warning / bridge).
    -- Replaces three previously-independent if-blocks that could race for
    -- g_gui:showDialog. The pure _buildStartupQueue is exposed for unit tests.
    _showStartupDialogs(self)

    RLSettings.applyDefaultSettings()
    RLDebugUtils.dumpSettingsOnce()
    RLMessageAggregator.initialize()

    local temp = self.environment.weather.temperatureUpdater.currentMin or 20
	local isServer = self:getIsServer()
    local fallbackRepairCount = 0

    for _, placeable in pairs(self.husbandrySystem.placeables) do

        local animals = placeable:getClusters()

        for _, animal in pairs(animals) do
            -- Repair animals that got fallback IDs due to load-order race:
            -- Placeables load before FarmManager:loadFromXMLFile, so farm lookup
            -- in Animal.new returns nil for first-time RL installs on existing saves.
            -- By onStartMission everything is initialized, so setUniqueId works.
            if isServer and animal.uniqueId == "1" and animal.farmId == "1" then
                animal:setUniqueId()
                Log:debug("Fallback ID repair: 1/1 -> %s/%s (subType=%s)",
                    animal.farmId, animal.uniqueId, animal.subType or "?")
                fallbackRepairCount = fallbackRepairCount + 1
            end

            animal:updateInput()
            animal:updateOutput(temp)
        end

        if isServer then placeable:updateInputAndOutput(animals) end

    end

    if fallbackRepairCount > 0 then
        Log:info("onStartMission: repaired %d animal(s) with fallback IDs (load-order race)", fallbackRepairCount)
    end

    local guiOk, guiErr = pcall(function()
        local realisticLivestockFrame = RealisticLivestockFrame.new()
        g_gui:loadGui(modDirectory .. "gui/RealisticLivestockFrame.xml", "RealisticLivestockFrame", realisticLivestockFrame, true)
        fixInGameMenu(realisticLivestockFrame, "realisticLivestockFrame", {260,0,256,256}, 4, function() return true end)
        realisticLivestockFrame:initialize()
    end)
    if not guiOk then
        Log:warning("GUI setup failed (expected on dedicated server): %s", tostring(guiErr))
    end

end

FSBaseMission.onStartMission = Utils.prependedFunction(FSBaseMission.onStartMission, RealisticLivestock_FSBaseMission.onStartMission)


function RealisticLivestock_FSBaseMission:sendInitialClientState(connection, _, _)

    local animalSystem = g_currentMission.animalSystem

	for _, setting in pairs(RLSettings.SETTINGS) do
		if not setting.ignore then setting.state = setting.state or setting.default end
	end

    connection:sendEvent(RL_BroadcastSettingsEvent.new())
    connection:sendEvent(AnimalSystemStateEvent.new(animalSystem.countries, animalSystem.animals, animalSystem.aiAnimals))
    connection:sendEvent(HusbandryMessageStateEvent.new(g_currentMission.husbandrySystem.placeables))

end

FSBaseMission.sendInitialClientState = Utils.prependedFunction(FSBaseMission.sendInitialClientState, RealisticLivestock_FSBaseMission.sendInitialClientState)


function RealisticLivestock_FSBaseMission:onDayChanged()
	RmSafeUtils.safeCall("RealisticLivestock_FSBaseMission:onDayChanged", function()

		if not self:getIsServer() then return end

		local husbandrySystem = self.husbandrySystem

		for _, farm in pairs(g_farmManager:getFarms()) do

			local husbandries = husbandrySystem:getPlaceablesByFarm(farm.farmId)
			local wages = 0

			for _, husbandry in pairs(husbandries) do

				local aiManager = husbandry:getAIManager()

				if aiManager ~= nil then wages = wages + (aiManager.wage or 0) end

			end

			if wages > 0 then self:addMoney(-wages, farm.farmId, MoneyType.HERDSMAN_WAGES, true, true) end

		end

	end)
end

FSBaseMission.onDayChanged = Utils.appendedFunction(FSBaseMission.onDayChanged, RealisticLivestock_FSBaseMission.onDayChanged)