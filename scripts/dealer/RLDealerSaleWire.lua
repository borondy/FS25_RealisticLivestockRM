-- RLDealerSaleWire.lua
-- Byte-level wire codec shared by the dealer sale-availability MP events.
--
-- ONE record shape carries both an authoritative override and a reconcile op, so
-- there is one validation rule, one cap and one round-trip unit for both events:
--
--   writeRecord(streamId, rec):
--     streamWriteString(rec.subTypeName)
--     streamWriteUInt16(rec.minAge)
--     streamWriteBool  (rec.isSet)
--     streamWriteBool  (rec.canBeBought)
--
-- All four fields are ALWAYS written, in that order. `isSet = true` is a registry
-- override carrying its desired value; `isSet = false` is a clear op, whose
-- `canBeBought` slot is written `false` and ignored on read. `minAge` is an
-- animal-stage month age bounded by the dealer's max buy age, so UInt16 is ample.
--
--   writeList(streamId, list):
--     streamWriteUInt16(count)      -- count = validated-then-clamped survivors
--     for i = 1, count do writeRecord(streamId, survivors[i]) end
--
-- Set-level framing (the count prefix, the cap and the loop) lives HERE rather
-- than in the state event, deliberately deviating from the sibling filter and
-- herdsman codecs, which put the count on their single state event. Two events
-- share this payload, so duplicating count + cap + loop per event would invite a
-- one-sided drift.
--
-- Writer validates and CLAMPS; reader validates and SKIPS:
--   * `writeList` first builds the writable list, dropping (with a WARNING naming
--     the key) any record whose name / minAge / booleans fail the shared
--     predicate, then CLAMPS the survivors to MAX_RECORD_COUNT with a WARNING,
--     and only then writes the count and exactly that many records. A `minAge` is
--     never truncated into range - that would re-key the override onto a
--     different animal stage.
--   * `readList` reads the count and drops the WHOLE payload (returns `{}, true`,
--     reading no records) when it exceeds MAX_RECORD_COUNT.
--   * `readRecord` always consumes all four fields BEFORE judging, so a skipped
--     record never disturbs framing; `readList` returns a COMPACTED array.
--
-- Writer and reader share ONE predicate per key field, so the writer can never
-- emit a name or age the reader rejects - an asymmetric rule would silently drop
-- state the sender never logged as bad. The key fields are re-checked on read; the
-- two boolean slots are not, because streamReadBool cannot return a non-boolean.
-- The same `minAge` ceiling is the registry's own MAX_MIN_AGE, so a key that can be
-- STORED can always be TRANSPORTED.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleWire = {}

--- Upper sanity bound on the wire-side record count. Any registry that ever
--- accumulates 10,000 stage overrides is pathological; the real purpose of the
--- cap is to defend the reader against a desynced upstream stream that could
--- produce a count up to 65535 and spin the reader to a session-timing-out
--- crash. It is a desync defense, NOT an authorization control - a tighter
--- domain-sized bound would risk refusing a legitimately large modded subtype
--- set. Exceeding it drops the payload and leaves the receiver in its prior state.
RLDealerSaleWire.MAX_RECORD_COUNT = 10000

--- Widest value the UInt16 minAge slot carries, taken from the registry so storage
--- and transport share ONE domain - a key the registry accepted but this codec
--- could not carry would be applied on the server and dropped from every client
--- snapshot, diverging them permanently. Load order enforces the dependency:
--- main.lua sources the registry well before this module.
---
--- Out-of-range is a DROP, never a clamp: the engine's streamWriteUInt16 throws
--- above this, and truncating would silently re-key the override onto a different
--- animal stage.
local MAX_MIN_AGE = RLDealerSaleRegistry.MAX_MIN_AGE

--- True when `subTypeName` can key a stage: a non-empty string, matching the
--- registry's own key rule so writer and reader never disagree about a name.
---@param subTypeName any
---@return boolean
local function isValidSubTypeName(subTypeName)
    return type(subTypeName) == "string" and subTypeName ~= ""
end

--- True when `minAge` fits the UInt16 slot: a non-NaN integer in [0, MAX_MIN_AGE].
--- The upper bound excludes +inf and the lower bound excludes -inf, so both
--- infinities are refused without an explicit test.
---@param minAge any
---@return boolean
local function isValidMinAge(minAge)
    return type(minAge) == "number"
        and minAge == minAge
        and minAge >= 0
        and minAge <= MAX_MIN_AGE
        and math.floor(minAge) == minAge
end

--- Judge one record for the wire. Returns nil when it is writable, else a reason
--- string for the drop WARNING. The two KEY rules (name, minAge) run on the read
--- side too, so a record the writer emits always decodes.
---@param rec any
---@return string|nil reason
local function rejectReason(rec)
    if type(rec) ~= "table" then
        return "record is not a table (" .. type(rec) .. ")"
    end
    if not isValidSubTypeName(rec.subTypeName) then
        return "invalid subTypeName=" .. tostring(rec.subTypeName) .. " (need a non-empty string)"
    end
    if not isValidMinAge(rec.minAge) then
        return "invalid minAge=" .. tostring(rec.minAge)
            .. " (need an integer in [0, " .. MAX_MIN_AGE .. "])"
    end
    if type(rec.isSet) ~= "boolean" then
        return "invalid isSet=" .. tostring(rec.isSet) .. " (need a boolean)"
    end
    if type(rec.canBeBought) ~= "boolean" then
        return "invalid canBeBought=" .. tostring(rec.canBeBought) .. " (need a boolean)"
    end
    return nil
end

-- =============================================================================
-- Record IO
-- =============================================================================

--- Write one four-field record. Trusts caller validation: `writeList` is the
--- single production entry and rejects a bad record BEFORE the count is written,
--- because a record refused mid-list would leave the count disagreeing with the
--- payload.
---@param streamId number
---@param rec table { subTypeName=, minAge=, isSet=, canBeBought= }
function RLDealerSaleWire.writeRecord(streamId, rec)
    streamWriteString(streamId, rec.subTypeName)
    streamWriteUInt16(streamId, rec.minAge)
    streamWriteBool(streamId, rec.isSet)
    streamWriteBool(streamId, rec.canBeBought)

    Log:trace("RLDealerSaleWire.writeRecord: %s@%d isSet=%s canBeBought=%s",
        rec.subTypeName, rec.minAge, tostring(rec.isSet), tostring(rec.canBeBought))
end

--- Read one four-field record. ALWAYS consumes all four fields before judging, so
--- a skipped record leaves the surrounding list byte-aligned.
---@param streamId number
---@return table|nil rec nil when the record is skipped
function RLDealerSaleWire.readRecord(streamId)
    local subTypeName = streamReadString(streamId)
    local minAge = streamReadUInt16(streamId)
    local isSet = streamReadBool(streamId)
    local canBeBought = streamReadBool(streamId)

    if not isValidSubTypeName(subTypeName) then
        Log:warning("RLDealerSaleWire.readRecord: invalid subTypeName='%s' (need a non-empty string); record SKIPPED, that stage keeps the receiver's current flag",
            tostring(subTypeName))
        return nil
    end

    if not isValidMinAge(minAge) then
        Log:warning("RLDealerSaleWire.readRecord: invalid minAge=%s for '%s'; record SKIPPED, that stage keeps the receiver's current flag",
            tostring(minAge), tostring(subTypeName))
        return nil
    end

    Log:trace("RLDealerSaleWire.readRecord: %s@%d isSet=%s canBeBought=%s",
        subTypeName, minAge, tostring(isSet), tostring(canBeBought))

    return {
        subTypeName = subTypeName,
        minAge      = minAge,
        isSet       = isSet,
        canBeBought = canBeBought,
    }
end

-- =============================================================================
-- List IO (count-prefixed framing)
-- =============================================================================

--- Write a whole record list: validate, clamp, then write the count and exactly
--- that many records.
---@param streamId number
---@param list any array of records; a non-table writes an empty set
---@return integer written number of records actually put on the wire
function RLDealerSaleWire.writeList(streamId, list)
    local writable = {}
    local dropped = 0

    if type(list) ~= "table" then
        Log:warning("RLDealerSaleWire.writeList: list is not a table (%s); writing an empty set, so the receiver sees no overrides at all",
            type(list))
    else
        for i = 1, #list do
            local rec = list[i]
            local reason = rejectReason(rec)
            if reason == nil then
                writable[#writable + 1] = rec
            else
                dropped = dropped + 1
                -- Resolve the key for the log with an explicit branch, never
                -- `cond and rec.subTypeName or "?"` - that idiom renders a `false`
                -- name as "?" and hides which record was actually dropped.
                local key = "?"
                if type(rec) == "table" then key = tostring(rec.subTypeName) end
                Log:warning("RLDealerSaleWire.writeList: dropping record %d (%s) - %s; that stage is NOT carried on the wire and the receiver keeps its current flag",
                    i, key, reason)
            end
        end
    end

    local count = #writable
    if count > RLDealerSaleWire.MAX_RECORD_COUNT then
        -- On the snapshot path the consequence is stronger than "not sent": the
        -- receiver REBUILDS its registry from exactly what arrives, so a clamped-off
        -- override is reset to its shipped default on every client rather than merely
        -- going unseen. Say so, because this line is the only signal that it happened.
        Log:warning("RLDealerSaleWire.writeList: %d writable record(s) exceed MAX_RECORD_COUNT=%d; CLAMPING - the surplus overrides are not sent, and on a full-set snapshot every receiver will RESET those stages to their shipped defaults",
            count, RLDealerSaleWire.MAX_RECORD_COUNT)
        count = RLDealerSaleWire.MAX_RECORD_COUNT
    end

    streamWriteUInt16(streamId, count)
    for i = 1, count do
        RLDealerSaleWire.writeRecord(streamId, writable[i])
    end

    Log:debug("RLDealerSaleWire.writeList: wrote %d record(s) (%d dropped as invalid)", count, dropped)
    return count
end

--- Read a whole record list. Returns the COMPACTED survivors plus a `dropped`
--- flag: when the count breaches the cap the payload is refused wholesale and NO
--- records are read, so the caller must not treat the empty list as authoritative
--- state.
---@param streamId number
---@return table[] records compacted (no nil holes)
---@return boolean dropped true when the whole payload was refused
function RLDealerSaleWire.readList(streamId)
    local count = streamReadUInt16(streamId)

    if count > RLDealerSaleWire.MAX_RECORD_COUNT then
        Log:warning("RLDealerSaleWire.readList: count=%d exceeds MAX_RECORD_COUNT=%d (stream desync?); DROPPING the whole payload - no records are read and the receiver keeps its prior state",
            count, RLDealerSaleWire.MAX_RECORD_COUNT)
        return {}, true
    end

    local out = {}
    local skipped = 0
    for _ = 1, count do
        local rec = RLDealerSaleWire.readRecord(streamId)
        if rec ~= nil then
            out[#out + 1] = rec
        else
            skipped = skipped + 1
        end
    end

    Log:debug("RLDealerSaleWire.readList: read %d record(s), kept %d (%d skipped as invalid)",
        count, #out, skipped)
    return out, false
end

Log:debug("RLDealerSaleWire: loaded")
