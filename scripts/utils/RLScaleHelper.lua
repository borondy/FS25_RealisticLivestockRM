-- RLScaleHelper.lua
-- Canonical 0-99 genetics scale for the RLRM mod.
--
-- Extracted from AnimalScreenBase.lua for reuse outside of shop UI.
-- Consumers: RLAnimalDisplayHelper (name tag), RLGeneticsFormatter (Info frame),
-- RLFilterFieldCatalog (Phase 0 saveable filters).
--
-- Do NOT duplicate this math - always call RLScaleHelper.scaleToNinetyNine.

local Log = RmLogging.getLogger("RLRM")

RLScaleHelper = {}

--- Convert a raw 0.25..1.75 genetics value into an integer 0..99.
---
--- 0.25 -> 0, 1.0 -> 50, 1.75 -> 99. Values outside the range are clamped.
--- Nil inputs are not accepted - caller must nil-guard.
---@param value number Raw genetics value in [0.25, 1.75]
---@return integer scaled 0..99
function RLScaleHelper.scaleToNinetyNine(value)
    local scaled = math.floor(((value - 0.25) / 1.5) * 99 + 0.5)
    if scaled < 0 then return 0 end
    if scaled > 99 then return 99 end
    return scaled
end

Log:trace("RLScaleHelper: loaded")
