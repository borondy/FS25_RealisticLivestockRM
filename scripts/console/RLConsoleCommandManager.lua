RLConsoleCommandManager = {}

local rlConsoleCommandManager_mt = Class(RLConsoleCommandManager)

function RLConsoleCommandManager.new()

	local self = setmetatable({}, rlConsoleCommandManager_mt)

	self.husbandrySystem = g_currentMission.husbandrySystem
	self.animalSystem = g_currentMission.animalSystem
	self.animal = nil
	self.placeable = nil

    if g_currentMission:getIsServer() and not g_currentMission.missionDynamicInfo.isMultiplayer then
        addConsoleCommand("rlSetTargetAnimal", "Set the target animal for future console commands", "setAnimal", self, "[type] [farmId] [uniqueId]")
        addConsoleCommand("rlSetAnimalGenetics", "Set the genetics of the targeted animal", "setGenetics", self, "[geneticType] [value]")
        addConsoleCommand("rlSetAnimalInput", "Set the input of the targeted animal", "setInput", self, "[inputType] [value]")
        addConsoleCommand("rlSetAnimalOutput", "Set the output of the targeted animal", "setOutput", self, "[outputType] [value]")
        -- Saveable filters (Phase 0 P2) -- dev commands for manual save/load verification.
        -- Scope hardcoded to COW/farm 1 because the goal is round-trip smoke testing,
        -- not real-world filter authoring (Phase 1 UI).
        addConsoleCommand("rlFilterCreate", "Create a sample saveable filter (age>=48 AND isPregnant==false, COW/farm 1)", "createFilter", self, "[name]")
        addConsoleCommand("rlFilterList", "List all saveable filters currently in memory", "listFilters", self, "")
        addConsoleCommand("rlFilterClear", "Clear all saveable filters (SP diagnostic only)", "clearFilters", self, "")
    end

    -- Read-only debug commands - safe on SP, MP host, and MP client.
    addConsoleCommand("rlDumpSettings", "Dump effective RL settings to the log", "dumpSettings", self, "")

	return self

end


--- Console handler for rlDumpSettings. Read-only; safe in any context.
---@return string  confirmation message printed to the console
function RLConsoleCommandManager:dumpSettings()
    Log:debug("rlDumpSettings: invoked")
    RLDebugUtils.dumpSettings()
    return "rlDumpSettings: see log.txt"
end


function RLConsoleCommandManager:setAnimal(animalType, farmId, uniqueId)

	self.animal = nil
	self.placeable = nil

	if animalType == nil or type(animalType) ~= "string" then

		print("rlSetTargetAnimal: no animal type given, accepted types:")

		for name, index in pairs(AnimalType) do print("|--- " .. name) end

		return

	end

	if farmId == nil then return "rlSetTargetAnimal: no farmId given" end
	
	if uniqueId == nil then return "rlSetTargetAnimal: no uniqueId given" end

	local animalTypeIndex = AnimalType[animalType:upper()]

	for _, placeable in pairs(self.husbandrySystem.placeables) do

		if placeable:getAnimalTypeIndex() ~= animalTypeIndex then continue end

		local animals = placeable:getClusters()
		
		for _, animal in pairs(animals) do

			if animal.farmId == farmId and animal.uniqueId == uniqueId then

				self.animal = animal
				self.placeable = placeable

				return "rlSetTargetAnimal: animal set successfully"

			end

		end

	end


	for _, trailer in pairs(self.husbandrySystem.livestockTrailers) do

		local trailerType = trailer:getCurrentAnimalType()

		if trailerType == nil or trailerType.typeIndex ~= animalTypeIndex then continue end

		local animals = trailer:getClusters()
		
		for _, animal in pairs(animals) do

			if animal.farmId == farmId and animal.uniqueId == uniqueId then

				self.animal = animal

				return "rlSetTargetAnimal: animal set successfully"

			end

		end

	end

	return "rlSetTargetAnimal: animal not found"

end


function RLConsoleCommandManager:setGenetics(geneticType, value)

	if self.animal == nil then return "rlSetAnimalGenetics: no targeted animal" end

	if geneticType == nil or type(geneticType) ~= "string" or self.animal.genetics[geneticType] == nil then
		
		print("rlSetAnimalGenetics: invalid genetic type given, accepted types:")

		for key, _ in pairs(self.animal.genetics) do print("|--- " .. key) end

		return
		
	end

	if value == nil then return "rlSetAnimalGenetics: no value given" end

	value = tonumber(value)

	if value == nil then return "rlSetAnimalGenetics: invalid value given" end

	if value < 0.25 or value > 1.75 then return "rlSetAnimalGenetics: invalid value given, must be in range 0.25 - 1.75" end

	self.animal.genetics[geneticType] = value

	return "rlSetAnimalGenetics: animal genetics set successfully"

end


function RLConsoleCommandManager:setInput(inputType, value)

	if self.animal == nil then return "rlSetAnimalInput: no targeted animal" end

	if inputType == nil or type(inputType) ~= "string" or self.animal.input[inputType] == nil then
		
		print("rlSetAnimalInput: invalid input type given, accepted types:")

		for key, _ in pairs(self.animal.input) do print("|--- " .. key) end

		return
		
	end

	if value == nil then return "rlSetAnimalInput: no value given" end

	value = tonumber(value)

	if value == nil then return "rlSetAnimalInput: invalid value given" end

	if value < 0 then return "rlSetAnimalInput: invalid value given, must be higher than or equal to 0" end

	self.animal.input[inputType] = value
	if self.placeable ~= nil then self.placeable:updateInputAndOutput(self.placeable:getClusters()) end

	return "rlSetAnimalInput: animal input set successfully"

end


function RLConsoleCommandManager:setOutput(outputType, value)

	if self.animal == nil then return "rlSetAnimalOutput: no targeted animal" end

	if outputType == nil or type(outputType) ~= "string" or self.animal.output[outputType] == nil then
		
		print("rlSetAnimalOutput: invalid output type given, accepted types:")

		for key, _ in pairs(self.animal.output) do print("|--- " .. key) end

		return
		
	end

	if value == nil then return "rlSetAnimalOutput: no value given" end

	value = tonumber(value)

	if value == nil then return "rlSetAnimalOutput: invalid value given" end

	if value < 0 then return "rlSetAnimalOutput: invalid value given, must be higher than or equal to 0" end

	self.animal.output[outputType] = value
	if self.placeable ~= nil then self.placeable:updateInputAndOutput(self.placeable:getClusters()) end

	return "rlSetAnimalOutput: animal output set successfully"

end


-- =============================================================================
-- Saveable filters (Phase 0 P2) -- dev commands for manual save/load verification.
-- These are intentionally minimal: the goal is to smoke-test the save file
-- round-trip by creating a filter in one game session, saving, quitting,
-- reloading, and confirming the filter is still there. The UI path lives
-- in Phase 1.
-- =============================================================================


--- Create a canned filter (age>=48 AND isPregnant==false, COW/farm 1) so the
--- player can prove the save/load round-trip without having to hand-construct
--- an AST. The returned id is printed and usable with `rlFilterList`.
---@param name string|nil optional filter name (defaults to "rlFilter_test")
---@return string user-facing result
function RLConsoleCommandManager:createFilter(name)

	if g_rlFilterService == nil then
		return "rlFilterCreate: g_rlFilterService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local filterName = (type(name) == "string" and name ~= "") and name or "rlFilter_test"

	local filter = g_rlFilterService:create({
		name = filterName,
		animalType = AnimalType.COW,
		farmId = 1,
		expression = {
			op = "AND",
			children = {
				{ field = "age",        cmp = ">=", value = 48 },
				{ field = "isPregnant", cmp = "==", value = false },
			},
		},
	})

	if filter == nil then
		return "rlFilterCreate: create returned nil (see log for details)"
	end

	Log:info("rlFilterCreate: created id=%s name=%s (total=%d)",
		filter.id, filter.name, #g_rlFilterService:list())

	return string.format("rlFilterCreate: ok id=%s", filter.id)

end


--- Dump every filter currently held by the service. One line per filter,
--- plus a total at the end. Readable in the dev console and also the log.
---@return string user-facing result
function RLConsoleCommandManager:listFilters()

	if g_rlFilterService == nil then
		return "rlFilterList: g_rlFilterService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local filters = g_rlFilterService:list()

	if #filters == 0 then
		Log:info("rlFilterList: no filters in memory")
		return "rlFilterList: 0 filters"
	end

	for _, f in ipairs(filters) do
		local animalType = tostring(f.animalType)
		local farmId = tostring(f.farmId)
		local op = (f.expression and f.expression.op) or "?"
		local numChildren = (f.expression and f.expression.children and #f.expression.children) or 0
		local line = string.format("|--- id=%s name=%s animalType=%s farmId=%s version=%s op=%s #children=%d",
			tostring(f.id), tostring(f.name), animalType, farmId, tostring(f.version), op, numChildren)
		print(line)
		Log:info("rlFilterList: %s", line)
	end

	return string.format("rlFilterList: %d filters", #filters)

end


--- Wipe the in-memory filter registry. Does NOT touch the save file; the
--- next save cycle will persist the cleared state. SP-only by the outer
--- registration guard (P2 has no MP events yet).
---@return string user-facing result
function RLConsoleCommandManager:clearFilters()

	if g_rlFilterService == nil then
		return "rlFilterClear: g_rlFilterService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local before = #g_rlFilterService:list()
	g_rlFilterService:clear()
	Log:info("rlFilterClear: cleared %d filters from in-memory registry", before)
	return string.format("rlFilterClear: cleared %d filters", before)

end