--[[
    RLSelectionKey.lua
    GUI-local nil-safe selection-key builder for the RL Tabbed Menu multi-select
    frames (Buy / Move / Sell / Transfer).

    The frames key their selectedAnimals set by a 3-part identity string. The global
    RLAnimalUtil.toKey is the repo-wide identity primitive (cluster scan, AnimalMoveEvent,
    herdsman planner) and concatenates unconditionally - a nil farmId/uniqueId would
    produce a colliding/garbage key or a nil-concat crash. Rather than change that shared
    primitive's contract (blast radius across many callers), this GUI-local builder hardens
    exactly the selection paths: it returns nil (+ a warning) when farmId or uniqueId is
    missing so the caller skips the write as "no selection", and coerces a nil country to ""
    (the same collapse the frames already applied inline). On the happy path it DELEGATES to
    RLAnimalUtil.toKey, so the key is byte-identical to the keys already in selectedAnimals -
    read and write paths stay compatible.

    Pure logic (data in / data out; no g_*, GUI, or XML - its only dependency is the pure
    RLAnimalUtil.toKey): dual-runnable. See tests/headless/selection_key_suite.lua.
]]

local Log = RmLogging.getLogger("RLRM")

RLSelectionKey = {}

--- Build a nil-safe 3-part selection key from identity fields.
--- Returns nil (+ a warning) when farmId or uniqueId is missing, so the caller skips the
--- write as "no selection" instead of indexing selectedAnimals with a bad key. A nil country
--- coerces to "" (matching the frames' inline `birthday.country or ""`), so on the happy path
--- the key equals RLAnimalUtil.toKey(farmId, uniqueId, country) exactly.
--- @param farmId string|number|nil Farm ID
--- @param uniqueId string|number|nil Unique ID
--- @param country string|number|nil Birthday country index (nil -> "")
--- @return string|nil key "farmId uniqueId country", or nil when farmId/uniqueId is missing
function RLSelectionKey.build(farmId, uniqueId, country)
    if farmId == nil or uniqueId == nil then
        -- DEBUG, not WARNING: the caller treats a nil key as "no selection" and skips it - this
        -- is expected, handled control flow, and build is called once per cluster in select-all /
        -- render loops, so a WARNING here would flood on the very condition the guard exists for.
        Log:debug("RLSelectionKey.build: missing identity (farmId=%s uniqueId=%s), returning nil (treated as no selection)",
            tostring(farmId), tostring(uniqueId))
        return nil
    end
    return RLAnimalUtil.toKey(farmId, uniqueId, country or "")
end

Log:debug("RLSelectionKey: loaded")
