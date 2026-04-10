--[[
    DewarTypeRegistration.lua

    Registers the DewarData vehicle specialization and the rlDewar vehicle
    type (extending base-game "pallet") purely in Lua, replacing the
    <specializations> and <vehicleTypes> blocks that previously lived in
    modDesc.xml.

    Rationale: declaring rlDewar via modDesc <vehicleTypes> caused a benign
    but noisy "Can't load resource dataS/scripts/vehicles/Vehicle.lua" error
    at mod load time, because FS25's XML type loader inherits the pallet
    parent's filename and unconditionally prepends the mod directory
    (Utils.getFilename path). Doing the registration in Lua lets us rely on
    the mod env metatable fallback (modEnv.Vehicle -> _G.Vehicle via
    __index = _G) for class resolution without triggering the broken path
    prepend.
]]

local modDirectory = g_currentModDirectory
local modName = g_currentModName
local dewarDataPath = Utils.getFilename("scripts/insemination/DewarData.lua", modDirectory)

-- Register the DewarData specialization.
-- The mod-scoped addSpecialization proxy sees the absolute filename and
-- auto-prefixes name/className with modName, so the spec is registered as
-- "FS25_RealisticLivestockRM.dewarData" / "FS25_RealisticLivestockRM.DewarData".
g_specializationManager:addSpecialization(
    "dewarData",
    "DewarData",
    dewarDataPath,
    nil
)

-- Register the rlDewar vehicle type.
-- We reuse DewarData.lua as the type's script filename (re-sourcing it is
-- idempotent - the file contains only class/method definitions, no state).
-- The proxy auto-prefixes className to "FS25_RealisticLivestockRM.Vehicle",
-- which ClassUtil.getClassObject resolves to the global Vehicle class via
-- modEnv's metatable fallback (__index = _G).
-- The proxy's addType takes no parent argument, so we manually inherit the
-- pallet type's specialization list afterwards (same pattern TypeManager uses
-- when loading from XML).
g_vehicleTypeManager:addType(
    "rlDewar",
    "Vehicle",
    dewarDataPath,
    nil
)

local fullTypeName = modName .. ".rlDewar"
local palletType = g_vehicleTypeManager:getTypeByName("pallet")
if palletType ~= nil then
    for _, specName in ipairs(palletType.specializationNames) do
        g_vehicleTypeManager:addSpecialization(fullTypeName, specName)
    end
else
    Log:error("DewarTypeRegistration: pallet type not found - rlDewar will be missing base specializations")
end

-- Add our DewarData spec on top of the inherited pallet specs.
g_vehicleTypeManager:addSpecialization(fullTypeName, "dewarData")

Log:info("DewarTypeRegistration: registered rlDewar vehicle type with dewarData specialization")
