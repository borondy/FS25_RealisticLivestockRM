--[[
    RLDiseaseStatus.lua
    What one disease record tells the player: whether a naming surface lists it, its status
    label key, the whole months of an immune or vaccinated label, its card icon token, and whether it groups
    the animal as diseased. An incubating non-carrier record resolves exactly as a healthy animal does.
    isDiseased and iconOf are the per-record rules the Animal display predicates and the filter
    catalog read; resolve composes them. rowGroup and sortRows order the Diseases dialog's rows by
    how urgently each calls for action, numbered by ROW_GROUP, most urgent first; rowSeverity maps
    a row's group to the severity its icon shows.

    Pure: no setting, no g_*, no GUI - callers gate diseasesEnabled. Reads Disease.isVisibleToPlayer,
    RLDiseaseRecord.STATE, RLDiseaseProgression.COMPLETION_EPSILON and RLConstants.SEVERITY at CALL
    time only; nothing here reads them at file scope.
]]

RLDiseaseStatus = {}

local Log = RmLogging.getLogger("RLRM")


--- The status label keys `resolve` can return. READ-ONLY by contract.
RLDiseaseStatus.KEY = {
    ["BEING_TREATED"] = "rl_ui_beingTreated",
    ["IMMUNE"] = "rl_ui_immune",
    ["VACCINATED"] = "rl_ui_vaccinated",
    ["TREATMENT_PAUSED"] = "rl_ui_treatmentPaused",
    ["CARRIER"] = "rl_ui_carrier",
    ["NOT_TREATED"] = "rl_ui_notTreated"
}

--- The three card icon tokens `resolve` can return. READ-ONLY by contract.
RLDiseaseStatus.ICON = {
    ["UNTREATED"] = "untreated",
    ["TREATED"] = "treated",
    ["CARRIER"] = "carrier"
}

--- The Diseases dialog's row groups, most urgent first. READ-ONLY by contract.
RLDiseaseStatus.ROW_GROUP = {
    ["SICK_NO_TREATMENT"] = 1,
    ["NOT_TREATED"] = 2,
    ["TREATMENT_PAUSED"] = 3,
    ["NOT_VACCINATED"] = 4,
    ["BEING_TREATED"] = 5,
    ["IMMUNE"] = 6,
    ["CARRIER"] = 7,
    ["OTHER"] = 8
}


--- The presentation of an animal with no record, and of any record a naming surface hides.
---@return table presentation A fresh table.
local function healthy()
    return { ["visible"] = false, ["diseased"] = false }
end


--- Whole months left on a count-down counter, rounded UP across the completion epsilon. Unlogged: per-frame.
---@param months number Months remaining, possibly fractional and codec-quantised.
---@return number whole Whole months, at least 1 above the epsilon and exactly 0 at or below it.
function RLDiseaseStatus.wholeMonthsRemaining(months)
    local whole = math.ceil(months - RLDiseaseProgression.COMPLETION_EPSILON)

    -- A branch rather than math.max, which can return a negative zero that renders as "-0".
    if whole <= 0 then return 0 end

    return whole
end


--- Whole months elapsed on a count-up counter, rounded DOWN across the completion epsilon. Unlogged: per-frame.
---@param months number Months elapsed, possibly fractional and codec-quantised.
---@return number whole Whole months, never below 0.
function RLDiseaseStatus.wholeMonthsElapsed(months)
    local whole = math.floor(months + RLDiseaseProgression.COMPLETION_EPSILON)

    -- Only a hand-edited save can hand this a negative counter.
    if whole < 0 then return 0 end

    return whole
end


--- Whether one record groups its animal as diseased: INFECTIOUS only. Unlogged: per-comparison callers.
---@param record table A disease record.
---@return boolean diseased True iff the record is at INFECTIOUS.
function RLDiseaseStatus.isDiseased(record)
    return record.state == RLDiseaseRecord.STATE.INFECTIOUS
end


--- The card icon token for one record, carrier first; nil when it lights none. Unlogged: per-comparison callers.
---@param record table A disease record.
---@return string|nil icon An `ICON` token, or nil.
function RLDiseaseStatus.iconOf(record)
    local ICON = RLDiseaseStatus.ICON

    if record.isCarrier then return ICON.CARRIER end

    if record.state == RLDiseaseRecord.STATE.INFECTIOUS then
        return record.treatmentRunning and ICON.TREATED or ICON.UNTREATED
    end

    return nil
end


-- The label arms keep the shipped order: a running course, RECOVERED (vaccinated or immune), a paused
-- course, a carrier, then the fallback. The icon is carrier-first and ignores a pause, so card and pane can differ.
--- Resolve what one record tells the player. A fresh table every call. Unlogged: per-frame callers.
---@param record table|nil A disease record, or nil for an animal without one.
---@return table presentation `visible`, `statusKey`, `months` (RECOVERED arm only), `icon` and `diseased`.
function RLDiseaseStatus.resolve(record)
    if record == nil or not Disease.isVisibleToPlayer(record) then
        return healthy()
    end

    local STATE = RLDiseaseRecord.STATE
    local KEY = RLDiseaseStatus.KEY

    local presentation = {
        ["visible"] = true,
        ["diseased"] = RLDiseaseStatus.isDiseased(record)
    }

    if record.treatmentRunning then
        presentation.statusKey = KEY.BEING_TREATED
    elseif record.state == STATE.RECOVERED then
        presentation.statusKey = record.vaccinated == true and KEY.VACCINATED or KEY.IMMUNE
        presentation.months = RLDiseaseStatus.wholeMonthsRemaining(record.immunityMonthsRemaining)
    -- This record's own counter alone; `or 0` tolerates a partially-deserialized record.
    elseif (record.treatmentMonthsRemaining or 0) > 0 then
        presentation.statusKey = KEY.TREATMENT_PAUSED
    elseif record.isCarrier then
        presentation.statusKey = KEY.CARRIER
    else
        presentation.statusKey = KEY.NOT_TREATED
    end

    presentation.icon = RLDiseaseStatus.iconOf(record)

    return presentation
end


-- Keyed on state: the treatment counter is read only on an INFECTIOUS record, so a DEAD record
-- holding a stale counter groups as OTHER where resolve would label it paused.
--- How urgently one dialog row calls for action. Unlogged: per-comparison callers.
---@param record table|nil The row's visible record, nil on a vaccine row.
---@param model table The row's registry entry.
---@return number group A `ROW_GROUP` value; lower is more urgent.
function RLDiseaseStatus.rowGroup(record, model)
    local GROUP = RLDiseaseStatus.ROW_GROUP

    if record == nil then return GROUP.NOT_VACCINATED end

    if RLDiseaseStatus.isDiseased(record) then
        if record.treatmentRunning then return GROUP.BEING_TREATED end
        if model.treatment == nil then return GROUP.SICK_NO_TREATMENT end
        if (record.treatmentMonthsRemaining or 0) > 0 then return GROUP.TREATMENT_PAUSED end
        return GROUP.NOT_TREATED
    end

    -- Before the carrier test, so an immune carrier groups as immune.
    if record.state == RLDiseaseRecord.STATE.RECOVERED then return GROUP.IMMUNE end

    if record.isCarrier then return GROUP.CARRIER end

    return GROUP.OTHER
end


--- The severity one dialog row's icon shows, from its `rowGroup`. Unlogged: per-row callers.
---@param record table|nil The row's visible record, nil on a vaccine row.
---@param model table The row's registry entry.
---@return string severity An `RLConstants.SEVERITY` value; INFO shows no icon.
function RLDiseaseStatus.rowSeverity(record, model)
    local GROUP = RLDiseaseStatus.ROW_GROUP
    local SEVERITY = RLConstants.SEVERITY
    local group = RLDiseaseStatus.rowGroup(record, model)

    if group == GROUP.SICK_NO_TREATMENT or group == GROUP.NOT_TREATED or group == GROUP.TREATMENT_PAUSED then
        return SEVERITY.WARNING
    end
    if group == GROUP.NOT_VACCINATED then return SEVERITY.NOTICE end
    if group == GROUP.IMMUNE then return SEVERITY.SUCCESS end

    return SEVERITY.INFO
end


--- The dialog's rows in a fresh array, by `rowGroup` then the disease's internal key; the input is untouched.
---@param rows table Array of `{ record = <visible record or nil>, model = <registry entry> }`.
---@return table sorted A fresh array holding the input's own entry tables.
function RLDiseaseStatus.sortRows(rows)
    local sorted = {}
    for i, row in ipairs(rows) do sorted[i] = row end

    -- Explicit branches: a false group compare must never fall through to the title compare.
    table.sort(sorted, function(a, b)
        local groupA = RLDiseaseStatus.rowGroup(a.record, a.model)
        local groupB = RLDiseaseStatus.rowGroup(b.record, b.model)
        if groupA ~= groupB then return groupA < groupB end
        return a.model.title < b.model.title
    end)

    Log:trace("RLDiseaseStatus.sortRows: %s row(s) sorted", tostring(#sorted))

    return sorted
end


Log:trace("RLDiseaseStatus: loaded")
