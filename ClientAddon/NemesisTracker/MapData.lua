NemesisTracker = NemesisTracker or {}
local NT = NemesisTracker

NT.MapData = NT.MapData or {}
local MapData = NT.MapData

MapData.tileColumns = 4
MapData.tileRows = 3
MapData.tileCount = 12

local byZoneId = {
    [17] = { file = "Barrens" },
    [36] = { file = "Alterac" },
    [40] = { file = "Westfall" },
    [41] = { file = "DeadwindPass" },
    [44] = { file = "RedRidge" },
    [45] = { file = "Arathi" },
    [46] = { file = "BurningSteppes" },
    [47] = { file = "Hinterlands" },
    [51] = { file = "SearingGorge" },
    [85] = { file = "Tirisfal" },
    [130] = { file = "Silverpine" },
    [139] = { file = "EasternPlaguelands" },
    [141] = { file = "Teldrassil" },
    [148] = { file = "Darkshore" },
    [209] = { file = "StonetalonMountains" },
    [215] = { file = "Mulgore" },
    [267] = { file = "Hilsbrad" },
    [331] = { file = "Ashenvale" },
    [357] = { file = "Feralas" },
    [361] = { file = "Felwood" },
    [400] = { file = "ThousandNeedles" },
    [405] = { file = "Desolace" },
    [406] = { file = "StonetalonMountains" },
    [440] = { file = "Tanaris" },
    [490] = { file = "UnGoroCrater" },
    [493] = { file = "Moonglade" },
    [618] = { file = "Winterspring" },
    [8] = { file = "SwampOfSorrows" },
    [10] = { file = "Duskwood" },
    [11] = { file = "Wetlands" },
    [12] = { file = "Elwynn" },
    [14] = { file = "Durotar" },
    [15] = { file = "Dustwallow" },
    [28] = { file = "WesternPlaguelands" },
    [33] = { file = "Stranglethorn" },
    [38] = { file = "LochModan" },
    [1519] = { file = "Stormwind" },
    [1537] = { file = "Ironforge" },
    [1637] = { file = "Orgrimmar" },
    [1638] = { file = "ThunderBluff" },
    [1497] = { file = "Undercity" },
    [3430] = { file = "EversongWoods" },
    [3433] = { file = "Ghostlands" },
    [3524] = { file = "AzuremystIsle" },
    [3525] = { file = "BloodmystIsle" },
    [3483] = { file = "Hellfire" },
    [3518] = { file = "Nagrand" },
    [3519] = { file = "TerokkarForest" },
    [3520] = { file = "ShadowmoonValley" },
    [3521] = { file = "Zangarmarsh" },
    [3522] = { file = "BladesEdgeMountains" },
    [3523] = { file = "Netherstorm" },
    [3537] = { file = "BoreanTundra" },
    [65] = { file = "Dragonblight" },
    [394] = { file = "GrizzlyHills" },
    [66] = { file = "ZulDrak" },
    [67] = { file = "StormPeaks" },
    [418] = { file = "HowlingFjord" },
    [210] = { file = "IcecrownGlacier" },
    [3711] = { file = "SholazarBasin" },
    [495] = { file = "CrystalsongForest" },
    [2817] = { file = "CrystalsongForest" },
    [4395] = { file = "Dalaran1_" },
}

local byZoneName = {
    ["Badlands"] = { file = "Badlands" },
    ["Arathi Highlands"] = { file = "Arathi" },
    ["Burning Steppes"] = { file = "BurningSteppes" },
    ["Dun Morogh"] = { file = "DunMorogh" },
    ["Elwynn Forest"] = { file = "Elwynn" },
    ["Stranglethorn Vale"] = { file = "Stranglethorn" },
    ["Vale of Trials"] = { file = "Durotar" },
    ["The Barrens"] = { file = "Barrens" },
    ["Western Plaguelands"] = { file = "WesternPlaguelands" },
    ["Eastern Plaguelands"] = { file = "EasternPlaguelands" },
    ["Ashenvale"] = { file = "Ashenvale" },
    ["Stonetalon Mountains"] = { file = "StonetalonMountains" },
    ["Hillsbrad Foothills"] = { file = "Hilsbrad" },
    ["Wetlands"] = { file = "Wetlands" },
    ["Westfall"] = { file = "Westfall" },
    ["Tanaris"] = { file = "Tanaris" },
    ["Dustwallow Marsh"] = { file = "Dustwallow" },
    ["Feralas"] = { file = "Feralas" },
    ["Felwood"] = { file = "Felwood" },
    ["Howling Fjord"] = { file = "HowlingFjord" },
    ["Dragonblight"] = { file = "Dragonblight" },
    ["Icecrown"] = { file = "IcecrownGlacier" },
    ["Sholazar Basin"] = { file = "SholazarBasin" },
    ["Borean Tundra"] = { file = "BoreanTundra" },
    ["Zul'Drak"] = { file = "ZulDrak" },
}

local function sanitizeZoneName(zoneName)
    local sanitized = string.gsub(zoneName or "", "[^A-Za-z0-9]", "")
    if sanitized == "" then
        return nil
    end
    return sanitized
end

function MapData:GetZone(zoneId, zoneName)
    local zone = zoneId and byZoneId[zoneId] or nil
    if zone then
        return zone
    end

    zone = zoneName and byZoneName[zoneName] or nil
    if zone then
        return zone
    end

    local sanitized = sanitizeZoneName(zoneName)
    if sanitized then
        return { file = sanitized }
    end

    return nil
end

function MapData:GetTileTexture(zoneId, zoneName, index)
    local zone = self:GetZone(zoneId, zoneName)
    if not zone or not zone.file then
        return nil
    end

    return string.format("Interface\\WorldMap\\%s\\%s%d", zone.file, zone.file, index)
end
