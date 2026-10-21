--[[
    RLAnimalExport.lua
    Builds the lines of the animal CSV export: which pens are exported, and one row per animal.

    Data in, data out: no g_* read, no GUI and no file I/O. The caller passes the placeables and a
    ctx { animalSystem, isMultiplayer }; FarmManager, RLConstants, RLGeneticsFormatter and
    RmSafeUtils are read at call time only. Rows follow the walk order of the lists it is handed,
    which it never reorders.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalExport = {}

--- The header cells, in column order.
RLAnimalExport.COLUMNS = {
    "Owner Farm", "Husbandry", "Type", "Subtype", "Gender", "Name", "Country", "Farm Id", "Unique Id",
    "Mother Id", "Father Id", "Birth Date", "Age", "Health", "Weight", "Value", "Value / kg", "Pregnant",
    "Expected Offspring", "Lactating", "Food", "Water", "Straw", "Product", "Manure", "Liquid Manure",
    "Genetics Overall", "Genetics Metabolism", "Genetics Health", "Genetics Fertility", "Genetics Meat",
    "Genetics Productivity",
}

local GENETICS_CELLS = 6
local HOURS_PER_PERIOD_FIGURE = 24


--- Round half up and format as a whole number.
---@param value number
---@return string
local function whole(value)
    return string.format("%d", math.floor(value + 0.5))
end


--- Format with exactly two decimals.
---@param value number
---@return string
local function twoDecimals(value)
    return string.format("%.2f", value)
end


--- Whether a pen with this owner farm is exported: farm 1 in singleplayer, a real player farm in multiplayer.
---@param ownerFarmId any the pen's game farm number
---@param isMultiplayer boolean
---@return boolean
function RLAnimalExport.isExportedFarm(ownerFarmId, isMultiplayer)
    if not isMultiplayer then
        Log:trace("RLAnimalExport.isExportedFarm: SP owner=%s", tostring(ownerFarmId))
        return ownerFarmId == 1
    end
    Log:trace("RLAnimalExport.isExportedFarm: MP owner=%s", tostring(ownerFarmId))
    return type(ownerFarmId) == "number" and ownerFarmId > 0 and ownerFarmId <= FarmManager.MAX_NUM_FARMS
end


--- One CSV cell: nil is empty, and text holding a comma, quote, CR or LF is quoted with inner quotes doubled.
---@param value any
---@return string
function RLAnimalExport.escapeCell(value)
    if value == nil then
        Log:trace("RLAnimalExport.escapeCell: nil -> empty cell")
        return ""
    end
    local text = tostring(value)
    if text:find('[,"\r\n]') == nil then
        Log:trace("RLAnimalExport.escapeCell: '%s' needs no quoting", text)
        return text
    end
    Log:trace("RLAnimalExport.escapeCell: quoting '%s'", text)
    return '"' .. (text:gsub('"', '""')) .. '"'
end


--- The six genetics cells on the 0-99 display scale, empty where the formatter gives no row or value.
---@param genetics table|nil
---@param animalTypeIndex number|nil
---@param subTypeName string|nil
---@param isCastrated boolean|nil true reads the fertility cell as 0
---@return table cells six strings
function RLAnimalExport.geneticsCells(genetics, animalTypeIndex, subTypeName, isCastrated)
    local rows = RLGeneticsFormatter.format(genetics, animalTypeIndex, subTypeName, isCastrated)
    local cells = {}
    for i = 1, GENETICS_CELLS do
        local row = rows[i]
        if row ~= nil and row.numericValue ~= nil then
            cells[i] = string.format("%d", row.numericValue)
        else
            Log:trace("RLAnimalExport.geneticsCells: cell %d empty (no formatter row or value)", i)
            cells[i] = ""
        end
    end
    return cells
end


--- A parent id cell: the stored id, empty for an unknown parent.
---@param id string|nil
---@return string
local function parentCell(id)
    if id == nil or id == "-1" then
        Log:trace("RLAnimalExport.parentCell: unknown parent (%s) -> empty cell", tostring(id))
        return ""
    end
    return RLAnimalExport.escapeCell(id)
end


--- One CSV line (no trailing newline) for `animal` in `pen`.
---@param animal table an RLRM Animal
---@param pen table the husbandry placeable holding it
---@param ctx table { animalSystem, isMultiplayer }
---@return string line
function RLAnimalExport.formatRow(animal, pen, ctx)
    local hasMonitor = animal.monitor.active or animal.monitor.removed
    local birthday = animal.birthday
    local area = RLConstants.AREA_CODES[birthday.country]
    local value = animal:getSellPrice()

    local offspring = 0
    if animal.pregnancy ~= nil and animal.pregnancy.pregnancies ~= nil then
        offspring = #animal.pregnancy.pregnancies
    end

    local cells = {
        whole(pen:getOwnerFarmId()),
        RLAnimalExport.escapeCell(pen:getName()),
        RLAnimalExport.escapeCell(ctx.animalSystem.types[animal.animalTypeIndex].name),
        RLAnimalExport.escapeCell(animal.subType),
        RLAnimalExport.escapeCell(animal.gender),
        RLAnimalExport.escapeCell(animal.name),
        RLAnimalExport.escapeCell(area ~= nil and area.code or nil),
        RLAnimalExport.escapeCell(animal.farmId),
        RLAnimalExport.escapeCell(animal.uniqueId),
        parentCell(animal.motherId),
        parentCell(animal.fatherId),
        RLAnimalExport.escapeCell(string.format("%04d-%02d-%02d", RLConstants.START_YEAR.FULL + birthday.year,
            birthday.month, birthday.day)),
        whole(animal.age),
    }

    if hasMonitor then
        local perPeriod = HOURS_PER_PERIOD_FIGURE
        local milk = animal:getOutput("milk") * perPeriod
        local pallets = animal:getOutput("pallets") * perPeriod
        cells[#cells + 1] = whole(animal.health)
        cells[#cells + 1] = twoDecimals(animal.weight)
        cells[#cells + 1] = whole(value)
        cells[#cells + 1] = twoDecimals(value / animal.weight)
        cells[#cells + 1] = RLAnimalExport.escapeCell(animal.isPregnant and "yes" or "no")
        cells[#cells + 1] = string.format("%d", offspring)
        cells[#cells + 1] = RLAnimalExport.escapeCell(animal.isLactating and "yes" or "no")
        cells[#cells + 1] = twoDecimals(animal:getInput("food") * perPeriod)
        cells[#cells + 1] = twoDecimals(animal:getInput("water") * perPeriod)
        cells[#cells + 1] = twoDecimals(animal:getInput("straw") * perPeriod)
        cells[#cells + 1] = twoDecimals(milk > pallets and milk or pallets)
        cells[#cells + 1] = twoDecimals(animal:getOutput("manure") * perPeriod)
        cells[#cells + 1] = twoDecimals(animal:getOutput("liquidManure") * perPeriod)
    else
        cells[#cells + 1] = ""
        cells[#cells + 1] = ""
        cells[#cells + 1] = whole(value)
        cells[#cells + 1] = ""
        cells[#cells + 1] = RLAnimalExport.escapeCell(animal.isPregnant and "yes" or "no")
        cells[#cells + 1] = string.format("%d", offspring)
        for _ = 1, 7 do cells[#cells + 1] = "" end
    end

    for _, cell in ipairs(RLAnimalExport.geneticsCells(animal.genetics, animal.animalTypeIndex, animal.subType,
        animal.isCastrated)) do
        cells[#cells + 1] = cell
    end

    Log:trace("RLAnimalExport.formatRow: animal=%s farmId=%s monitor=%s cells=%d", tostring(animal.uniqueId),
        tostring(animal.farmId), tostring(hasMonitor), #cells)
    return table.concat(cells, ",")
end


--- The header, then one row per animal of every exported pen; a raising animal costs only its own row.
---@param placeables table husbandry placeables (getOwnerFarmId, getName, getClusters)
---@param ctx table { animalSystem, isMultiplayer }
---@return table lines lines[1] is the header
---@return table stats { rows, rowsFailed, pensExported, pensSkipped }
function RLAnimalExport.buildLines(placeables, ctx)
    local lines = { table.concat(RLAnimalExport.COLUMNS, ",") }
    local stats = { rows = 0, rowsFailed = 0, pensExported = 0, pensSkipped = 0 }
    Log:trace(">>> RLAnimalExport.buildLines(pens=%d, isMultiplayer=%s)", #placeables, tostring(ctx.isMultiplayer))

    for _, pen in ipairs(placeables) do
        local owner = pen:getOwnerFarmId()
        if not RLAnimalExport.isExportedFarm(owner, ctx.isMultiplayer) then
            stats.pensSkipped = stats.pensSkipped + 1
            Log:debug("RLAnimalExport: pen '%s' owner=%s skipped", tostring(pen:getName()), tostring(owner))
        else
            stats.pensExported = stats.pensExported + 1
            local before = stats.rows
            for _, animal in ipairs(pen:getClusters()) do
                local line = RmSafeUtils.safeAnimalCall(animal, "RLAnimalExport.formatRow", function()
                    return RLAnimalExport.formatRow(animal, pen, ctx)
                end, { nil })
                if line ~= nil then
                    lines[#lines + 1] = line
                    stats.rows = stats.rows + 1
                else
                    stats.rowsFailed = stats.rowsFailed + 1
                    Log:trace("RLAnimalExport: no row for animal %s (row build failed)", tostring(animal.uniqueId))
                end
            end
            Log:debug("RLAnimalExport: pen '%s' owner=%s exported, %d row(s)", tostring(pen:getName()),
                tostring(owner), stats.rows - before)
        end
    end

    Log:trace("<<< RLAnimalExport.buildLines = rows=%d failed=%d pensExported=%d pensSkipped=%d", stats.rows,
        stats.rowsFailed, stats.pensExported, stats.pensSkipped)
    return lines, stats
end


Log:trace("RLAnimalExport: loaded")
