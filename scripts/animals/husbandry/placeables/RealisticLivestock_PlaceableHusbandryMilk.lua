RealisticLivestock_PlaceableHusbandryMilk = {}


function RealisticLivestock_PlaceableHusbandryMilk.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryMilk.updateInputAndOutput)
	-- RLRM-264 diagnostics: wrap the base milk deposit (PlaceableHusbandryMilk:updateOutput)
	-- to log the production factors and the actual liters deposited. Registered AFTER the
	-- base spec's own updateOutput registration (this fn is appended to
	-- PlaceableHusbandryMilk.registerOverwrittenFunctions), so the RL wrapper is outermost
	-- and its superFunc is the base deposit. Behaviour-preserving (always calls superFunc).
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateOutput", RealisticLivestock_PlaceableHusbandryMilk.updateOutput)
end

PlaceableHusbandryMilk.registerOverwrittenFunctions = Utils.appendedFunction(PlaceableHusbandryMilk.registerOverwrittenFunctions, RealisticLivestock_PlaceableHusbandryMilk.registerOverwrittenFunctions)


function RealisticLivestock_PlaceableHusbandryMilk:onHusbandryAnimalsUpdate(superFunc, clusters)
	-- Skip superFunc (no base game cluster-based litersPerHour calculation)
	-- But populate activeFillTypes for UI display on both server and client
	local spec = self.spec_husbandryMilk
	if spec.hasMilkProduction then
		spec.activeFillTypes = {}
		for _, animal in ipairs(clusters) do
			local subType = animal:getSubType()
			if subType ~= nil then
				local milk = subType.output.milk
				if milk ~= nil and spec.litersPerHour[milk.fillType] ~= nil then
					table.addElement(spec.activeFillTypes, milk.fillType)
				end
			end
		end
		-- RLRM-264 diagnostics: this fires on every herd change (birth/buy/sell/move)
		-- on BOTH server and client. Confirms the event reaches a dedicated server and
		-- shows how many milk fillTypes are active for UI. It does NOT recompute
		-- litersPerHour (that is server-only, in updateInputAndOutput each hour).
		Log:debug("Milk[%s]: onHusbandryAnimalsUpdate clusters=%d activeFillTypes=%d hasMilkProduction=%s isServer=%s",
			(self.getName ~= nil and self:getName()) or "?", #clusters, #spec.activeFillTypes,
			tostring(spec.hasMilkProduction), tostring(self.isServer))
	end
end

PlaceableHusbandryMilk.onHusbandryAnimalsUpdate = Utils.overwrittenFunction(PlaceableHusbandryMilk.onHusbandryAnimalsUpdate, RealisticLivestock_PlaceableHusbandryMilk.onHusbandryAnimalsUpdate)


function PlaceableHusbandryMilk:updateInputAndOutput(superFunc, animals)

    superFunc(self, animals)

    local spec = self.spec_husbandryMilk
    local penName = (self.getName ~= nil and self:getName()) or "?"

    for fillType, _ in pairs(spec.litersPerHour) do
        spec.litersPerHour[fillType] = 0
    end

    spec.activeFillTypes = {}

    -- RLRM-264 diagnostics: pre-compute the registered litersPerHour keys once so a
    -- "dropped" line can show which fillTypes the building actually accepts. An empty
    -- key set means the base onLoad registered no milk fillType (load-order / data
    -- problem) and NO milk can ever be summed for this pen.
    local litersPerHourKeys = RealisticLivestock_PlaceableHusbandryMilk._fillTypeKeyList(spec.litersPerHour)

    -- Per-pen counters: the summary line usually reveals the failure mode at a glance.
    local numCows, numLactating, numProducing, numDropped = 0, 0, 0, 0

    for _, animal in pairs(animals) do

        local subType = animal:getSubType()

        if subType ~= nil then

            local milk = subType.output.milk

            if milk ~= nil then

                numCows = numCows + 1
                local milkPerHour = animal:getOutput("milk")
                if animal.isLactating then numLactating = numLactating + 1 end
                if milkPerHour > 0 then numProducing = numProducing + 1 end

                if spec.litersPerHour[milk.fillType] ~= nil then
                    spec.litersPerHour[milk.fillType] = spec.litersPerHour[milk.fillType] + milkPerHour
                    table.addElement(spec.activeFillTypes, milk.fillType)

                    Log:trace("Milk[%s]: cow=%s/%s subType=%s age=%d isLactating=%s isParent=%s months=%s productivity=%.3f -> milk=%.4f l/h fillType=%s",
                        penName, tostring(animal.farmId), tostring(animal.uniqueId), tostring(subType.name),
                        animal.age or -1, tostring(animal.isLactating), tostring(animal.isParent),
                        tostring(animal.monthsSinceLastBirth),
                        (animal.genetics and animal.genetics.productivity) or -1,
                        milkPerHour, tostring(g_fillTypeManager:getFillTypeNameByIndex(milk.fillType)))

                    -- Client shows lactating, server contributes nothing: RLRM-264 symptom.
                    if animal.isLactating and milkPerHour <= 0 then
                        Log:debug("Milk[%s]: cow=%s/%s is LACTATING but contributes 0 l/h (age=%d isParent=%s months=%s) - see Animal:updateOutput[milk] gate log",
                            penName, tostring(animal.farmId), tostring(animal.uniqueId), animal.age or -1,
                            tostring(animal.isParent), tostring(animal.monthsSinceLastBirth))
                    end
                else
                    numDropped = numDropped + 1
                    Log:debug("Milk[%s]: fillType %s (index=%s) for subType '%s' not in building's litersPerHour {%s} - output DROPPED",
                        penName,
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(milk.fillType)),
                        tostring(milk.fillType),
                        tostring(subType.name),
                        litersPerHourKeys)
                end

            end

        end

    end

    -- Per-pen summary (DEBUG so it surfaces at the default dev log level).
    local litersSummary = {}
    for fillType, liters in pairs(spec.litersPerHour) do
        table.insert(litersSummary, string.format("%s=%.3f",
            tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType)), liters))
    end
    Log:debug("Milk[%s]: updateInputAndOutput summary cows=%d lactating=%d producing>0=%d dropped=%d | litersPerHour{%s} activeFillTypes=%d isServer=%s",
        penName, numCows, numLactating, numProducing, numDropped,
        table.concat(litersSummary, ", "), #spec.activeFillTypes, tostring(self.isServer))

    -- The exact RLRM-264 fingerprint: cows lactating, but total production is zero.
    if numLactating > 0 and numProducing == 0 then
        Log:warning("Milk[%s]: %d cow(s) lactating but NONE producing milk (litersPerHour all 0) - enable TRACE for per-cow gate values.",
            penName, numLactating)
    end

end


--- Build a comma-separated list of fillType names present as keys in a litersPerHour
--- table. RLRM-264 diagnostics helper: an empty result means the base husbandry onLoad
--- registered no milk fillType for this pen, so nothing can ever be summed/deposited.
--- @param litersPerHour table fillTypeIndex -> liters map
--- @return string names Comma-separated fillType names ("<none>" if empty)
function RealisticLivestock_PlaceableHusbandryMilk._fillTypeKeyList(litersPerHour)
    local names = {}
    for fillTypeIndex, _ in pairs(litersPerHour or {}) do
        table.insert(names, tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)))
    end
    if #names == 0 then return "<none>" end
    return table.concat(names, ",")
end


--- RLRM-264 diagnostics: behaviour-preserving wrapper around the base milk deposit
--- (PlaceableHusbandryMilk:updateOutput). The deposit is scaled down by the pen's
--- feeding and production factors, so a lactating herd with litersPerHour > 0 can still
--- store zero milk when any of those factors collapses (or the store is full). There is
--- no debugger; this logs each factor, litersPerHour, and free capacity so the suppressor
--- is visible in the log, and fillLevel across ticks shows whether milk is accumulating.
--- All logging runs inside RmSafeUtils.safeCall so a logging fault can never break milk
--- production; the deposit itself always runs via superFunc.
--- @param superFunc function Base milk deposit (runs the actual production)
--- @param foodFactor number Feeding factor for this tick
--- @param productionFactor number Production factor for this tick
--- @param globalProductionFactor number Accumulated 0-1 production factor
function RealisticLivestock_PlaceableHusbandryMilk:updateOutput(superFunc, foodFactor, productionFactor, globalProductionFactor)

    local spec = self.spec_husbandryMilk

    if spec ~= nil and spec.hasMilkProduction and self.isServer then
        RmSafeUtils.safeCall("PlaceableHusbandryMilk:updateOutput.diagnostics", function()
            local penName = (self.getName ~= nil and self:getName()) or "?"
            local fillTypes = spec.fillTypes or {}

            if #fillTypes == 0 then
                Log:warning("MilkDeposit[%s]: spec.fillTypes is EMPTY - no milk fillType registered at onLoad; no milk can EVER be deposited for this pen", penName)
            end

            for _, fillTypeIndex in ipairs(fillTypes) do
                local litersPerHour = spec.litersPerHour[fillTypeIndex] or 0
                local freeCapacity = self:getHusbandryFreeCapacity(fillTypeIndex)
                local fillLevel = self:getHusbandryFillLevel(fillTypeIndex)

                Log:debug("MilkDeposit[%s]: fillType=%s foodFactor=%.3f productionFactor=%.3f globalProductionFactor=%.3f litersPerHour=%.3f | freeCap=%.1f fillLevel=%.1f",
                    penName, tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)),
                    foodFactor or -1, productionFactor or -1, globalProductionFactor or -1,
                    litersPerHour, freeCapacity, fillLevel)

                -- Rate exists but nothing can land: a zero feeding/production factor or a
                -- full store suppresses production. Watch fillLevel across ticks to confirm
                -- whether milk is actually accumulating.
                if litersPerHour > 0 and ((productionFactor or 0) <= 0 or (globalProductionFactor or 0) <= 0 or freeCapacity <= 0) then
                    Log:warning("MilkDeposit[%s]: litersPerHour=%.3f but production is suppressed (productionFactor=%.3f globalProductionFactor=%.3f freeCapacity=%.1f)",
                        penName, litersPerHour, productionFactor or -1, globalProductionFactor or -1, freeCapacity)
                end
            end
        end)
    end

    superFunc(self, foodFactor, productionFactor, globalProductionFactor)

end