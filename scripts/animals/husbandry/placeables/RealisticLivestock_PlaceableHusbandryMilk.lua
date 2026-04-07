RealisticLivestock_PlaceableHusbandryMilk = {}


function RealisticLivestock_PlaceableHusbandryMilk.registerOverwrittenFunctions(placeable)
	SpecializationUtil.registerOverwrittenFunction(placeable, "updateInputAndOutput", PlaceableHusbandryMilk.updateInputAndOutput)
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
	end
end

PlaceableHusbandryMilk.onHusbandryAnimalsUpdate = Utils.overwrittenFunction(PlaceableHusbandryMilk.onHusbandryAnimalsUpdate, RealisticLivestock_PlaceableHusbandryMilk.onHusbandryAnimalsUpdate)


function PlaceableHusbandryMilk:updateInputAndOutput(superFunc, animals)

    superFunc(self, animals)

    local spec = self.spec_husbandryMilk

    for fillType, _ in pairs(spec.litersPerHour) do
        spec.litersPerHour[fillType] = 0
    end

    spec.activeFillTypes = {}

    for _, animal in pairs(animals) do

        local subType = animal:getSubType()

        if subType ~= nil then

            local milk = subType.output.milk

            if milk ~= nil then

                if spec.litersPerHour[milk.fillType] ~= nil then
                    spec.litersPerHour[milk.fillType] = spec.litersPerHour[milk.fillType] + animal:getOutput("milk")
                    table.addElement(spec.activeFillTypes, milk.fillType)
                else
                    Log:debug("Milk: fillType %s (index=%s) for subType '%s' not in building's litersPerHour - output dropped",
                        tostring(g_fillTypeManager:getFillTypeNameByIndex(milk.fillType)),
                        tostring(milk.fillType),
                        tostring(subType.name))
                end

            end

        end

    end

end