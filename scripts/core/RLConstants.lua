-- RLConstants.lua
-- Purpose: Shared constants used across the mod (area codes, days per month, marks, etc.)
--          Extracted from RealisticLivestock.lua to break reverse dependency.
-- Author: Ritter

RLConstants = {}

local Log = RmLogging.getLogger("RLRM")


RLConstants.MARKS = {
    ["AI_MANAGER_SELL"] = {
        ["key"] = "AI_MANAGER_SELL",
        ["active"] = false,
        ["priority"] = 3,
        ["text"] = "aiManager_sell"
    },
    ["AI_MANAGER_CASTRATE"] = {
        ["key"] = "AI_MANAGER_CASTRATE",
        ["active"] = false,
        ["priority"] = 5,
        ["text"] = "aiManager_castrate"
    },
    ["AI_MANAGER_DISEASE"] = {
        ["key"] = "AI_MANAGER_DISEASE",
        ["active"] = false,
        ["priority"] = 2,
        ["text"] = "aiManager_disease"
    },
    ["AI_MANAGER_INSEMINATE"] = {
        ["key"] = "AI_MANAGER_INSEMINATE",
        ["active"] = false,
        ["priority"] = 4,
        ["text"] = "aiManager_ai"
    },
    ["PLAYER"] = {
        ["key"] = "PLAYER",
        ["active"] = false,
        ["priority"] = 1,
        ["text"] = "player"
    }
}


RLConstants.MAP_TO_AREA_CODE = {
    ["Riverbend Springs"] = 2,
    ["Hutan Pantai"] = 3,
    ["Zielonka"] = 5,
    ["Zacieczki"] = 5,
    ["Szpakowo"] = 5,
    ["Pallegney"] = 4,
    ["Oberschwaben"] = 6,
    ["Starowies"] = 5,
    ["Lipinki"] = 5,
    ["Rhönplateu"] = 6,
    ["Schwesing Bahnhof"] = 6,
    ["Riverview"] = 1,
    ["Sobolewo"] = 5,
    ["Tässi Farm"] = 8,
    ["HORSCH AgroVation"] = 10,
    ["New Bartelshagenn"] = 6,
    ["HermannsHausen"] = 5,
    ["Oak Bridge Farm"] = 1,
    ["Calmsden Farm"] = 1,
    ["Frankenmuth Farming Map"] = 2,
    ["North Frisian 25"] = 6,
    ["Alma, Missouri"] = 2,
    ["Michigan Map"] = 2
}

RLConstants.AREA_CODES = {
    [1] = {
        ["code"] = "UK",
        ["country"] = "United Kingdom"
    },
    [2] = {
        ["code"] = "US",
        ["country"] = "United States"
    },
    [3] = {
        ["code"] = "CH",
        ["country"] = "China"
    },
    [4] = {
        ["code"] = "FR",
        ["country"] = "France"
    },
    [5] = {
        ["code"] = "PL",
        ["country"] = "Poland"
    },
    [6] = {
        ["code"] = "DE",
        ["country"] = "Germany"
    },
    [7] = {
        ["code"] = "CA",
        ["country"] = "Canada"
    },
    [8] = {
        ["code"] = "EE",
        ["country"] = "Estonia"
    },
    [9] = {
        ["code"] = "IT",
        ["country"] = "Italy"
    },
    [10] = {
        ["code"] = "CZ",
        ["country"] = "Czech Republic"
    },
    [11] = {
        ["code"] = "RU",
        ["country"] = "Russia"
    },
    [12] = {
        ["code"] = "SW",
        ["country"] = "Sweden"
    },
    [13] = {
        ["code"] = "NO",
        ["country"] = "Norway"
    },
    [14] = {
        ["code"] = "FI",
        ["country"] = "Finland"
    },
    [15] = {
        ["code"] = "JP",
        ["country"] = "Japan"
    },
    [16] = {
        ["code"] = "SP",
        ["country"] = "Spain"
    }
}


RLConstants.DAYS_PER_MONTH = {
    [1] = 31,
    [2] = 28,
    [3] = 31,
    [4] = 30,
    [5] = 31,
    [6] = 30,
    [7] = 31,
    [8] = 31,
    [9] = 30,
    [10] = 31,
    [11] = 30,
    [12] = 31
}


RLConstants.START_YEAR = {
    ["FULL"] = 2024,
    ["PARTIAL"] = 24
}


Log:info("RLConstants loaded")
