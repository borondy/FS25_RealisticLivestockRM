-- RLDealerSaleSerialization.lua
-- Flat XML codec for dealer sale-availability overrides, plus the shared
-- g_rlDealerSaleRegistry singleton bootstrap.
--
-- Canonical XML key contract (under RLDealerSaleSerialization.XML_BASE_KEY =
-- "rm_RlSettings.dealerSaleOverrides"):
--
--   rm_RlSettings.dealerSaleOverrides.override(i)
--     @subType(string)   -- verbatim subType.name, used as-is (no name<->index step)
--     @minAge(int)       -- >= 0
--     @canBeBought(bool)  -- either polarity is a valid override
--     @version(int)       -- migration seam (writes/reads 1)
--
-- Structural sibling of RLFilterSerialization / RLHerdsmanRuleSerialization
-- MINUS all recursion: an override is a flat scalar record, so there is no
-- nested-group/target-list machinery here. Because the dealer "state holder" is
-- the pure RLDealerSaleRegistry (which owns no XML), this module additionally
-- hosts the iteration wrappers (saveToXMLFile / loadFromXMLFile) that on the
-- filter/herdsman side live on their services.
--
-- Data in / data out: both seams take an ALREADY-OPEN XMLFile and do the whole
-- encode/decode in memory. They NEVER open a file, flush to disk, or touch disk -
-- the disk transport lives only in the RLSettings save/load wrappers, exactly as
-- the filter/herdsman codecs are split. An in-game disk round-trip inside a codec
-- fails silently under the engine's sandbox.
--
-- Defensive contract (fail-closed; mirrors the filter/herdsman "required fields
-- read with NO default; a nil read signals corruption" rule):
--  * readOverride skips a record (returns nil + :warning) when @subType is
--    absent/empty/whitespace-only, @minAge is absent, or @canBeBought is absent.
--    Presence, not truthiness, on @canBeBought: a stored false is a valid payload
--    and round-trips as false; only a genuinely absent attribute is "corrupt".
--  * loadFromXMLFile is ADDITIVE (set-only): the RLSettings loader reconstructs
--    the singleton before calling, so there is no clear-all here (the pure
--    registry owns none). A returned record still passes through registry:set,
--    which re-validates the key and drops a present-but-invalid value (e.g.
--    minAge=-1) with its own warning - a belt-and-suspenders second gate.
--  * the load loop is pcall-wrapped as a LAST-RESORT backstop for an unexpected
--    engine throw; expected corruption returns nil and never throws, so the
--    coarse pcall does not swallow the tail in normal operation.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleSerialization = {}

--- Sub-tree root under RLSettings' rm_RlSettings save root. Shared by both seams
--- and the RLSettings wrappers; the codec never hard-codes it internally.
RLDealerSaleSerialization.XML_BASE_KEY = "rm_RlSettings.dealerSaleOverrides"

--- On-disk record schema version. A future override-shape change bumps this; A2
--- writes and (implicitly) reads 1. Kept as a named constant so the migration
--- seam is one edit, not a scattered literal.
local RECORD_VERSION = 1

-- =============================================================================
-- Per-record IO (file-local)
-- =============================================================================

--- Write one override record at `overrideKey`. Every field is a validated scalar
--- (the caller only ever passes `registry:enumerate()` records), so - unlike the
--- herdsman/filter writers - there is no fail-closed branch: a valid record
--- cannot produce malformed XML, and an invalid one never reaches here.
---@param xmlFile table XMLFile handle
---@param overrideKey string path prefix for this record, e.g. `"...dealerSaleOverrides.override(0)"`
---@param record table `{ subTypeName=string, minAge=integer, canBeBought=boolean }`
local function writeOverride(xmlFile, overrideKey, record)
    xmlFile:setString(overrideKey .. "#subType", record.subTypeName)
    xmlFile:setInt(overrideKey .. "#minAge", record.minAge)
    xmlFile:setBool(overrideKey .. "#canBeBought", record.canBeBought)
    xmlFile:setInt(overrideKey .. "#version", RECORD_VERSION)
    Log:trace("RLDealerSaleSerialization.writeOverride: %s subType=%s minAge=%d canBeBought=%s version=%d",
        overrideKey, tostring(record.subTypeName), record.minAge, tostring(record.canBeBought), RECORD_VERSION)
end

--- Read one override record from `overrideKey`. Returns the record on success, or
--- nil + :warning (the record is SKIPPED) when fail-closed: @subType absent,
--- empty, or whitespace-only; @minAge absent; or @canBeBought absent. Those three
--- required attributes are read with NO default - a nil read is corruption, never
--- a silent default. @canBeBought is tested against nil (presence), NOT
--- truthiness, so a legitimately stored `false` reads back as `false`. @version is
--- the sole defaulted attribute (default 1): the migration seam A2 reads and
--- accepts as v1, mirroring the filter/herdsman readers (`getInt(..#version, 1)`).
--- A2 only records it (trace); the registry record carries no version, so it is
--- read for diagnostics + the forward-compat contract, not returned.
---@param xmlFile table XMLFile handle
---@param overrideKey string path prefix for this record
---@return table|nil record `{ subTypeName=, minAge=, canBeBought= }`, or nil when corrupt
local function readOverride(xmlFile, overrideKey)
    local subType = xmlFile:getString(overrideKey .. "#subType")
    local minAge = xmlFile:getInt(overrideKey .. "#minAge")
    local canBeBought = xmlFile:getBool(overrideKey .. "#canBeBought")  -- NO default: nil => corrupt, not false
    local version = xmlFile:getInt(overrideKey .. "#version", 1)         -- tolerated-absent -> v1 (migration seam)

    if subType == nil or subType:gsub("%s", "") == "" or minAge == nil or canBeBought == nil then
        Log:warning("RLDealerSaleSerialization.readOverride: incomplete record at %s (subType=%s minAge=%s canBeBought=%s); skipping",
            tostring(overrideKey), tostring(subType), tostring(minAge), tostring(canBeBought))
        return nil
    end

    Log:trace("RLDealerSaleSerialization.readOverride: %s subType=%s minAge=%d canBeBought=%s version=%d",
        overrideKey, subType, minAge, tostring(canBeBought), version)
    return { subTypeName = subType, minAge = minAge, canBeBought = canBeBought }
end

-- =============================================================================
-- Iteration wrappers (public seams)
-- =============================================================================

--- Serialize every override in `registry` under `baseKey`. Writes records in
--- `registry:enumerate()` order (already sorted by (subTypeName, minAge), an A1
--- contract), so `override(0)`, `override(1)`, ... are deterministic across save
--- cycles. Memory-only: never opens a file or writes to disk. Nil-guarded so a
--- load-order regression WARN-skips rather than crashing the surrounding
--- RLSettings.saveToXMLFile. No pcall: it emits only pre-validated scalar records
--- and cannot throw on valid data.
---@param xmlFile table XMLFile handle (already open)
---@param baseKey string e.g. `RLDealerSaleSerialization.XML_BASE_KEY`
---@param registry table an RLDealerSaleRegistry instance
function RLDealerSaleSerialization.saveToXMLFile(xmlFile, baseKey, registry)
    if xmlFile == nil then
        Log:warning("RLDealerSaleSerialization.saveToXMLFile: nil xmlFile; skipping")
        return
    end
    if registry == nil then
        Log:warning("RLDealerSaleSerialization.saveToXMLFile: nil registry; skipping")
        return
    end

    local records = registry:enumerate()
    for i, record in ipairs(records) do
        writeOverride(xmlFile, string.format("%s.override(%d)", baseKey, i - 1), record)
    end

    Log:debug("RLDealerSaleSerialization.saveToXMLFile: baseKey=%s wrote=%d overrides", baseKey, #records)
end

--- Deserialize every override under `baseKey` into `registry` via `readOverride`
--- + `registry:set`. ADDITIVE (set-only): the RLSettings loader reconstructs the
--- singleton before calling, so `registry` arrives fresh and no clear is needed
--- (the pure registry owns none). A corrupt record is skipped by `readOverride`
--- (nil), and a present-but-invalid value is rejected by `registry:set` (its own
--- warning); neither aborts the loop. Duplicate `(subType, minAge)` records
--- upsert last-write-wins, so `loaded` may exceed the deduped override count on a
--- hand-corrupted file. Memory-only; nil-guarded. The `iterate` is pcall-wrapped
--- as a last-resort backstop for an unexpected engine throw - expected corruption
--- never throws, so the coarse pcall does not swallow the tail in normal use.
---@param xmlFile table XMLFile handle (already open)
---@param baseKey string e.g. `RLDealerSaleSerialization.XML_BASE_KEY`
---@param registry table an RLDealerSaleRegistry instance (freshly reconstructed by the caller)
function RLDealerSaleSerialization.loadFromXMLFile(xmlFile, baseKey, registry)
    if xmlFile == nil then
        Log:warning("RLDealerSaleSerialization.loadFromXMLFile: nil xmlFile; skipping")
        return
    end
    if registry == nil then
        Log:warning("RLDealerSaleSerialization.loadFromXMLFile: nil registry; skipping")
        return
    end

    local loaded = 0
    local ok, err = pcall(function()
        xmlFile:iterate(baseKey .. ".override", function(_, overrideKey)
            local rec = readOverride(xmlFile, overrideKey)  -- expected corruption -> nil, no throw
            if rec ~= nil and registry:set(rec.subTypeName, rec.minAge, rec.canBeBought) then
                loaded = loaded + 1
            end
        end)
    end)

    if not ok then
        Log:warning("RLDealerSaleSerialization.loadFromXMLFile: iterate errored after %d loaded; partial state kept (%s)",
            loaded, tostring(err))
    end

    Log:debug("RLDealerSaleSerialization.loadFromXMLFile: baseKey=%s loaded=%d overrides", baseKey, loaded)
end

-- =============================================================================
-- Shared singleton bootstrap
-- =============================================================================

-- Eager create, mirroring g_rlFilterService / g_rlHerdsmanRuleService. A1
-- deliberately deferred the global to whichever persistence hook first needed a
-- handle; this is that hook. The g_* write belongs to the persistence layer, not
-- the pure registry. `or`-guarded so a re-source cannot clobber a live instance.
g_rlDealerSaleRegistry = g_rlDealerSaleRegistry or RLDealerSaleRegistry.new()

Log:trace("RLDealerSaleSerialization: loaded")
