VisualAnimalsDialog = {}

local visualAnimalsDialog_mt = Class(VisualAnimalsDialog, YesNoDialog)
local modDirectory = g_currentModDirectory
local modSettingsDirectory = g_currentModSettingsDirectory

function VisualAnimalsDialog.register()
    local dialog = VisualAnimalsDialog.new()
    g_gui:loadGui(modDirectory .. "gui/VisualAnimalsDialog.xml", "VisualAnimalsDialog", dialog)
    VisualAnimalsDialog.INSTANCE = dialog
end


function VisualAnimalsDialog.show()

    -- rawget the OWN INSTANCE: VisualAnimalsDialog is a Class() of YesNoDialog
    -- whose base carries a non-nil INSTANCE, so a plain read would fall through
    -- __index and never report a failed eager registration. Eager registration
    -- in RealisticLivestock_FSBaseMission is the sole contract.
    local instance = rawget(VisualAnimalsDialog, "INSTANCE")

    if instance ~= nil then
        local profile = Utils.getPerformanceClassId()

        local recommendedAnimals = (profile == GS_PROFILE_VERY_LOW and 8) or (profile == GS_PROFILE_LOW and 10) or (profile == GS_PROFILE_MEDIUM and 16) or (profile == GS_PROFILE_HIGH and 20) or (profile == GS_PROFILE_VERY_HIGH and 25) or (profile == GS_PROFILE_ULTRA and 25) or 8
        local maxHusbandries = RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES

        local currentMaxAnimals = 1 * maxHusbandries
        local maxAnimals = recommendedAnimals * 8

        instance.recommendedAnimals = recommendedAnimals

        instance:setQuantity(maxAnimals)
        instance.quantityElement:setState(maxHusbandries)

        g_gui:showDialog("VisualAnimalsDialog")
    end
end


function VisualAnimalsDialog.new(target, customMt)
    local dialog = YesNoDialog.new(target, customMt or visualAnimalsDialog_mt)
    dialog.areButtonsDisabled = false
    dialog.recommendedAnimals = 8
    return dialog
end


function VisualAnimalsDialog.createFromExistingGui(gui, _)

    VisualAnimalsDialog.register()
    VisualAnimalsDialog.show()

end


function VisualAnimalsDialog:onOpen()

    VisualAnimalsDialog:superClass().onOpen(self)
    FocusManager:setFocus(self.itemsElement)

end


function VisualAnimalsDialog:onClose()
    VisualAnimalsDialog:superClass().onClose(self)
end


function VisualAnimalsDialog:onRecommended()

    if self.areButtonsDisabled then return true end

    self.quantityElement:setState(self.recommendedAnimals * 2)

    return false

end


--- Apply the chosen visual-animal cap. When the value changed, updates
--- RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES and refreshes pen
--- visuals; then persists the value per-machine to modSettings/Settings.xml on
--- THIS peer. The write is client-local by design - it runs on every peer
--- (including a pure MP client) and targets machine-local modSettings, never the
--- savegame, so it carries no g_server guard - and sits OUTSIDE the change-only
--- branch so re-applying the same value still persists. Same file + key shape as
--- RealisticLivestock_PlaceableSystem.saveToXML (loadIfExists-then-create): the
--- host keeps its save-hook fallback and this write is additive.
---@return boolean true when buttons are disabled (block close); false to close
function VisualAnimalsDialog:onYes()

    if self.areButtonsDisabled then return true end

    local maxHusbandries = RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES
    local newMaxHusbandries = self.quantityElement:getState()

    local husbandrySystem = g_currentMission.husbandrySystem

    if maxHusbandries ~= newMaxHusbandries then

        Log:debug("VisualAnimalsDialog:onYes: maxHusbandries %d -> %d; refreshing pen visuals", maxHusbandries, newMaxHusbandries)

        RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES = newMaxHusbandries
        for _, clusterHusbandry in ipairs(husbandrySystem.clusterHusbandries) do
            clusterHusbandry.nextUpdateClusters = clusterHusbandry.placeable.spec_husbandryAnimals.clusterSystem:getAnimals()
            clusterHusbandry:updateVisuals(maxHusbandries > newMaxHusbandries)
        end

    else
        Log:trace("VisualAnimalsDialog:onYes: value unchanged (%d); no visual refresh, still persisting", newMaxHusbandries)
    end

    -- Persist per-machine so this peer keeps its own value across launches.
    createFolder(modSettingsDirectory)
    local path = modSettingsDirectory .. "Settings.xml"
    local xmlFile = XMLFile.loadIfExists("RealisticLivestock", path)

    if xmlFile == nil then xmlFile = XMLFile.create("RealisticLivestock", path, "Settings") end

    if xmlFile ~= nil then
        xmlFile:setInt("Settings.setting(0)#maxHusbandries", RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES)
        local saved = xmlFile:save(false, true)
        xmlFile:delete()

        if saved then
            Log:info("VisualAnimalsDialog:onYes: persisted maxHusbandries=%d to %s", RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES, path)
        else
            Log:error("VisualAnimalsDialog:onYes: XMLFile:save reported failure for %s; value applies this session only", path)
        end
    else
        Log:error("VisualAnimalsDialog:onYes: could not open or create %s (engine IO sandbox?); value applies this session only", path)
    end

    self:close()

    return false

end


function VisualAnimalsDialog:onNo(_, _)

    self:close()
    return false

end


function VisualAnimalsDialog:setQuantity(quantity)

    if quantity < 1 then quantity = 1 end
    self.maxQuantity = quantity

    local texts = {}

    for i=1, quantity do
        local text = tostring(i)
        table.insert(texts, text)
    end

    self.quantityElement:setTexts(texts)

end


function VisualAnimalsDialog:setButtonDisabled(disabled)
    self.areButtonsDisabled = disabled
    self.yesButton:setDisabled(disabled)
end