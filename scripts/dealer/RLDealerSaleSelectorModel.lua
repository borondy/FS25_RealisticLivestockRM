-- RLDealerSaleSelectorModel.lua
-- Pure, dual-run core for the dealer sale-availability selector dialog (B2). Turns the
-- B1 catalog view-model into the sectioned checkbox model the dialog renders, and
-- collects the checked rows back into a caller-facing for-sale set. Data in / data out:
-- no g_*, GUI, XML, or engine natives - only the RmLogging stub is reached, so the same
-- file runs under in-game rlTest and the headless harness.
--
-- Two functions, mirroring the catalog's build/enumerate split (here both are pure -
-- the GUI wiring lives in RLDealerSaleSelectorDialog):
--   * buildSectionModel(catalog) - one SECTION per catalog subType (dropping any that
--     yields no keyable row), each row keyed by a composite (subTypeName, minAge) string.
--   * buildResult(selected, keyMeta, sectionOrder, itemsBySection) - the checked in-scope
--     rows as a deduped, section/row-ordered array of {subTypeName, minAge}.
--
-- Composite key scheme: `subTypeName .. U+001F .. tostring(minAge)`. U+001F (unit
-- separator) cannot occur in a subType identifier, so the join is unambiguous. The key
-- is an INTERNAL handle (it drives selected / initialSelected / keyMeta); the PUBLIC row
-- identity the dialog and caller see stays the decomposed (subTypeName, minAge) pair.
--
-- Selection-out only: this model never mutates the registry, the store, or the catalog,
-- and never round-trips out-of-scope keys - it only knows the in-scope catalog it was
-- handed (absent-subType overrides are pruned downstream, not here).

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleSelectorModel = {}

-- The composite-key separator: ASCII unit separator (U+001F). Cannot appear in a subType
-- identifier, so `subTypeName .. SEP .. tostring(minAge)` is a lossless, collision-free join.
local KEY_SEP = "\31"

--- Build the internal composite key for a (subTypeName, minAge) row.
---@param subTypeName any
---@param minAge any
---@return string
local function rowKey(subTypeName, minAge)
    return tostring(subTypeName) .. KEY_SEP .. tostring(minAge)
end

--- Section title with the spec's fallback chain: the resolved subTypeLabel, else the raw
--- subTypeName, else "?". A non-string / empty value at a level falls through to the next.
---@param subTypeLabel any
---@param subTypeName any
---@return string
local function titleOf(subTypeLabel, subTypeName)
    if type(subTypeLabel) == "string" and subTypeLabel ~= "" then return subTypeLabel end
    if type(subTypeName) == "string" and subTypeName ~= "" then return subTypeName end
    return "?"
end

-- =============================================================================
-- buildSectionModel - catalog view-model -> sectioned checkbox model
-- =============================================================================

--- Compose the sectioned checkbox model from a B1 catalog view-model.
---
--- One SECTION per catalog subType; the section key is the subTypeName. Each catalog
--- visual (age stage) becomes one ROW `{subTypeName, minAge, ageRangeLabel, iconFilename,
--- key}`; `key` is the composite (subTypeName, minAge). A row whose composite key was
--- already emitted (a duplicate (subTypeName, minAge) across this whole build) is SKIPPED
--- so no checkbox aliasing / keyMeta overwrite occurs. A visual with a non-numeric minAge
--- is skipped (it cannot be keyed). A catalog subType that yields ZERO keyable rows (empty
--- visuals, all-non-numeric minAge, or every row a duplicate) emits NO section - never a
--- headed, row-less section.
---
--- `initialSelected[key] = (visual.buyable == true)` - the initial checkbox state equals
--- the catalog's effective buyability. `keyMeta[key] = {subTypeName, minAge}` decodes a key
--- back to its public pair for buildResult. Order is catalog order for sections and visual
--- order within a section - stable, never sorted here (B1 already ordered).
---
---@param catalog table|nil B1 catalog: array of { subTypeName, subTypeLabel, visuals=[{minAge, ageRangeLabel, iconFilename, buyable}] }
---@return table model { sectionOrder=[key], itemsBySection={key->rows}, titlesBySection={key->title}, initialSelected={key->bool}, keyMeta={key->{subTypeName,minAge}} }
function RLDealerSaleSelectorModel.buildSectionModel(catalog)
    local model = {
        sectionOrder    = {},
        itemsBySection  = {},
        titlesBySection = {},
        initialSelected = {},
        keyMeta         = {},
    }

    if type(catalog) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.buildSectionModel: catalog is not a table (%s); empty model", type(catalog))
        return model
    end

    local counters = { entriesSkipped = 0, rowsSkipped = 0, dupSkipped = 0 }

    for _, entry in ipairs(catalog) do
        if type(entry) ~= "table" then
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: dropped a non-table catalog entry")
        elseif type(entry.subTypeName) ~= "string" or entry.subTypeName == "" then
            -- Sections are keyed by subTypeName; a nil/empty/non-string name cannot key a
            -- section (t[nil] would crash) and buildResult would reject its rows anyway. Drop
            -- it like every other malformed shape rather than crash the whole build.
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: dropped an entry with nil/empty subTypeName (%s)",
                tostring(entry.subTypeName))
        elseif type(entry.visuals) ~= "table" then
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s has nil/non-table visuals; skipped",
                tostring(entry.subTypeName))
        elseif model.itemsBySection[entry.subTypeName] ~= nil then
            -- Two catalog entries share a subTypeName. Skip the later one BEFORE building its
            -- rows - registering it would overwrite the first entry's rows and double-append the
            -- section key; deferring the row build keeps keyMeta / initialSelected free of the
            -- skipped entry's stray keys.
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: duplicate section key %s; later entry skipped",
                tostring(entry.subTypeName))
        else
            local subTypeName = entry.subTypeName
            local rows = {}
            for _, visual in ipairs(entry.visuals) do
                if type(visual) ~= "table" or type(visual.minAge) ~= "number" then
                    counters.rowsSkipped = counters.rowsSkipped + 1
                    Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s dropped a row with non-numeric minAge (%s)",
                        tostring(subTypeName), tostring(type(visual) == "table" and visual.minAge or visual))
                else
                    local key = rowKey(subTypeName, visual.minAge)
                    if model.keyMeta[key] ~= nil then
                        counters.dupSkipped = counters.dupSkipped + 1
                        Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s dropped a duplicate key row (%s @%s)",
                            tostring(subTypeName), tostring(subTypeName), tostring(visual.minAge))
                    else
                        rows[#rows + 1] = {
                            subTypeName   = subTypeName,
                            minAge        = visual.minAge,
                            ageRangeLabel = visual.ageRangeLabel,
                            iconFilename  = visual.iconFilename,
                            key           = key,
                        }
                        model.keyMeta[key]         = { subTypeName = subTypeName, minAge = visual.minAge }
                        model.initialSelected[key] = visual.buyable == true
                    end
                end
            end

            if #rows == 0 then
                counters.entriesSkipped = counters.entriesSkipped + 1
                Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s yielded no keyable row; section dropped",
                    tostring(subTypeName))
            else
                model.sectionOrder[#model.sectionOrder + 1] = subTypeName
                model.itemsBySection[subTypeName]           = rows
                model.titlesBySection[subTypeName]          = titleOf(entry.subTypeLabel, subTypeName)
            end
        end
    end

    Log:debug("RLDealerSaleSelectorModel.buildSectionModel: %d section(s); %d entr(ies), %d row(s), %d dup(s) skipped",
        #model.sectionOrder, counters.entriesSkipped, counters.rowsSkipped, counters.dupSkipped)
    return model
end

-- =============================================================================
-- buildResult - checked rows -> caller-facing for-sale set
-- =============================================================================

--- Collect the checked in-scope rows into the caller's for-sale set: an array of
--- `{subTypeName, minAge}` for every row whose composite key is checked in `selected`,
--- in section then row order, deduped by key. Order and dedup come from walking
--- `sectionOrder` x `itemsBySection` (the rows are already unique by key from
--- buildSectionModel; the emitted-set guard is defence-in-depth). A checked key whose
--- meta is missing or malformed (subTypeName not a non-empty string, or minAge not a
--- number) is dropped with a TRACE, never emitted.
---
--- May return `{}` (nothing checked) - the caller treats an empty array as a legitimate
--- "nothing for sale", distinct from the dialog's nil (cancel).
---
---@param selected table {key->true} checked composite keys
---@param keyMeta table {key->{subTypeName, minAge}} from buildSectionModel
---@param sectionOrder table [key] section order from buildSectionModel
---@param itemsBySection table {key->rows} from buildSectionModel
---@return table[] result array of {subTypeName, minAge}
function RLDealerSaleSelectorModel.buildResult(selected, keyMeta, sectionOrder, itemsBySection)
    local result = {}
    if type(selected) ~= "table" or type(keyMeta) ~= "table"
        or type(sectionOrder) ~= "table" or type(itemsBySection) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.buildResult: malformed args; empty result")
        return result
    end

    local emitted = {}
    for _, sectionKey in ipairs(sectionOrder) do
        local rows = itemsBySection[sectionKey]
        if type(rows) == "table" then
            for _, row in ipairs(rows) do
                local key = row.key
                if selected[key] == true and not emitted[key] then
                    local meta = keyMeta[key]
                    if type(meta) == "table"
                        and type(meta.subTypeName) == "string" and meta.subTypeName ~= ""
                        and type(meta.minAge) == "number" then
                        emitted[key] = true
                        result[#result + 1] = { subTypeName = meta.subTypeName, minAge = meta.minAge }
                    else
                        -- Sanitize the composite key for logging: its U+001F separator has no
                        -- glyph in the console texture font (would warn "Character '31' not found").
                        Log:trace("RLDealerSaleSelectorModel.buildResult: dropped checked key with malformed meta (%s)",
                            (tostring(key):gsub("\31", "|")))
                    end
                end
            end
        end
    end

    Log:debug("RLDealerSaleSelectorModel.buildResult: %d checked in-scope row(s)", #result)
    return result
end

Log:debug("RLDealerSaleSelectorModel: loaded")
