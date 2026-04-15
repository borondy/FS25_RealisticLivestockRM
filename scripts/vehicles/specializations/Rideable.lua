RL_Rideable = {}


function RL_Rideable:onLoad(save)

	if save == nil then return end

	local animal = Animal.loadFromXMLFile(save.xmlFile, save.key .. ".rideable.animal")

	if animal ~= nil and animal.uniqueId ~= nil then
		Log:debug("Rideable:onLoad: loaded RLRM animal (uniqueId=%s)", animal.uniqueId)
		self:setCluster(animal)
	else
		Log:debug("Rideable:onLoad: no RLRM data found, keeping base-game cluster")
	end

end

Rideable.onLoad = Utils.appendedFunction(Rideable.onLoad, RL_Rideable.onLoad)


--- Guard against Rideable:getName() throwing when cluster is not yet assigned.
--- Complex rideable vehicle types (e.g. horseExtended) can trigger this during
--- async vehicle loading, producing 'attempt to index nil with getName' in the log.
Rideable.getName = Utils.overwrittenFunction(Rideable.getName, function(self, superFunc)
	local spec = self.spec_rideable
	if spec == nil or spec.cluster == nil then
		return ""
	end
	return superFunc(self)
end)