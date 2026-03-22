local addonName = ...

local existingNamespace = NemesisTracker or {}

NemesisTracker = LibStub("AceAddon-3.0"):NewAddon("NemesisTracker", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")
local NT = NemesisTracker

NT.MapData = existingNamespace.MapData or NT.MapData or {}
NT.UI = existingNamespace.UI or NT.UI or {}

local RELATION_ORDER = { own = 1, party = 2, guild = 3, public = 4 }

NT.prefix = "Nemesis"
NT.db = NemesisTrackerDB or {}
NT.data = NT.data or {
    nemeses = {},
    ordered = {},
    chunks = {},
    selectedSpawnId = nil,
    displayedZoneId = nil,
    displayedZoneName = nil,
    displayedZoneKey = nil,
    snapshotExpected = 0,
    snapshotActive = false,
    lastSyncAt = 0,
    lastServerTime = 0,
    connectionState = "idle",
    currentFilter = "all",
    currentScope = "all",
    currentSearch = "",
    page = 1,
    filteredCount = 0,
}

local function splitPreserveEmpty(message, delimiter)
    local result = {}
    if message == nil then
        return result
    end

    local startIndex = 1
    while true do
        local delimiterIndex = string.find(message, delimiter, startIndex, true)
        if not delimiterIndex then
            table.insert(result, string.sub(message, startIndex))
            break
        end

        table.insert(result, string.sub(message, startIndex, delimiterIndex - 1))
        startIndex = delimiterIndex + string.len(delimiter)

        if startIndex > string.len(message) + 1 then
            table.insert(result, "")
            break
        end
    end

    return result
end

local function shouldIncludeNemesis(nemesis)
    local filter = NT.data.currentFilter or "all"
    if filter ~= "all" and nemesis.relation ~= filter then
        return false
    end

    local search = string.lower(NT.data.currentSearch or "")
    if search ~= "" then
        local name = string.lower(nemesis.name or "")
        local zone = string.lower(nemesis.zoneName or "")
        local rankTier = string.lower(nemesis.rankTier or "")
        if not string.find(name, search, 1, true) and
            not string.find(zone, search, 1, true) and
            not string.find(rankTier, search, 1, true) then
            return false
        end
    end

    if (NT.data.currentScope or "all") == "zone" then
        return nemesis.zoneKey and nemesis.zoneKey == NT.data.displayedZoneKey
    end

    return true
end

local function sortNemeses()
    wipe(NT.data.ordered)
    for _, nemesis in pairs(NT.data.nemeses) do
        if shouldIncludeNemesis(nemesis) then
            table.insert(NT.data.ordered, nemesis)
        end
    end

    NT.data.filteredCount = #NT.data.ordered

    table.sort(NT.data.ordered, function(a, b)
        if a.relation ~= b.relation then
            return (RELATION_ORDER[a.relation] or 99) < (RELATION_ORDER[b.relation] or 99)
        end

        if a.rank ~= b.rank then
            return a.rank > b.rank
        end

        if a.lastSeenAt ~= b.lastSeenAt then
            return a.lastSeenAt > b.lastSeenAt
        end

        return (a.name or "") < (b.name or "")
    end)

    local maxPage = NT:GetMaxPage()
    if NT.data.page > maxPage then
        NT.data.page = maxPage
    end
end

local function normalizeRelation(value)
    if value == "own" or value == "party" or value == "guild" then
        return value
    end

    return "public"
end

function NT:GetNow()
    return time()
end

function NT:GetSelectedNemesis()
    if not self.data.selectedSpawnId then
        return nil
    end

    return self.data.nemeses[self.data.selectedSpawnId]
end

function NT:GetVisibleRows()
    if self.db and self.db.compactList then
        return 24
    end

    return 18
end

function NT:GetMaxPage()
    local rows = self:GetVisibleRows()
    return math.max(1, math.ceil((#self.data.ordered) / rows))
end

function NT:GetPagedNemesis(index)
    local offset = ((self.data.page or 1) - 1) * self:GetVisibleRows()
    return self.data.ordered[offset + index]
end

local function zoneKey(zoneId, zoneName)
    if NT.MapData and type(NT.MapData.GetZoneKey) == "function" then
        local key = NT.MapData:GetZoneKey(zoneId, zoneName)
        if key then
            return key
        end
    end

    return string.format("%s:%s", tostring(zoneId or 0), zoneName or "")
end

function NT:GetAvailableZones()
    local zones = {}
    local seen = {}
    local filter = self.data.currentFilter or "all"

    for _, nemesis in pairs(self.data.nemeses) do
        if filter == "all" or nemesis.relation == filter then
            local key = zoneKey(nemesis.zoneId, nemesis.zoneName)
            if not seen[key] then
                seen[key] = true
                table.insert(zones, {
                    zoneId = nemesis.zoneId,
                    zoneName = nemesis.zoneName or "Unknown",
                    zoneKey = key,
                })
            end
        end
    end

    table.sort(zones, function(a, b)
        if (a.zoneName or "") ~= (b.zoneName or "") then
            return (a.zoneName or "") < (b.zoneName or "")
        end

        return (a.zoneId or 0) < (b.zoneId or 0)
    end)

    return zones
end

function NT:SetDisplayedZone(zoneId, zoneName, zoneMapKey)
    self.data.displayedZoneId = zoneId
    self.data.displayedZoneName = zoneName
    self.data.displayedZoneKey = zoneMapKey or zoneKey(zoneId, zoneName)
end

function NT:EnsureDisplayedZone()
    local zones = self:GetAvailableZones()
    if #zones == 0 then
        self:SetDisplayedZone(nil, nil)
        return nil, nil
    end

    local currentKey = zoneKey(self.data.displayedZoneId, self.data.displayedZoneName)
    for _, zone in ipairs(zones) do
        if zone.zoneKey == currentKey or zone.zoneKey == self.data.displayedZoneKey then
            self:SetDisplayedZone(zone.zoneId, zone.zoneName, zone.zoneKey)
            return zone.zoneId, zone.zoneName
        end
    end

    local selected = self:GetSelectedNemesis()
    if selected then
        local selectedKey = zoneKey(selected.zoneId, selected.zoneName)
        for _, zone in ipairs(zones) do
            if zone.zoneKey == selectedKey then
                self:SetDisplayedZone(zone.zoneId, zone.zoneName, zone.zoneKey)
                return zone.zoneId, zone.zoneName
            end
        end
    end

    self:SetDisplayedZone(zones[1].zoneId, zones[1].zoneName, zones[1].zoneKey)
    return zones[1].zoneId, zones[1].zoneName
end

function NT:ChangeDisplayedZone(delta)
    local zones = self:GetAvailableZones()
    if #zones == 0 then
        return
    end

    local currentKey = zoneKey(self.data.displayedZoneId, self.data.displayedZoneName)
    local currentIndex = 1
    for index, zone in ipairs(zones) do
        if zone.zoneKey == currentKey or zone.zoneKey == self.data.displayedZoneKey then
            currentIndex = index
            break
        end
    end

    local targetIndex = currentIndex + delta
    if targetIndex < 1 then
        targetIndex = #zones
    elseif targetIndex > #zones then
        targetIndex = 1
    end

    self:SelectDisplayedZone(zones[targetIndex].zoneId, zones[targetIndex].zoneName, zones[targetIndex].zoneKey)
end

function NT:SetFilter(filter)
    self.data.currentFilter = filter or "all"
    self.data.page = 1
    sortNemeses()
    if self.data.selectedSpawnId and not self.data.nemeses[self.data.selectedSpawnId] then
        self.data.selectedSpawnId = nil
    end
    if self.data.selectedSpawnId and not shouldIncludeNemesis(self.data.nemeses[self.data.selectedSpawnId]) then
        self.data.selectedSpawnId = nil
    end
    if not self.data.selectedSpawnId and self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:SetSearch(search)
    self.data.currentSearch = string.lower(search or "")
    self.data.page = 1
    sortNemeses()
    if self.data.selectedSpawnId and not self.data.nemeses[self.data.selectedSpawnId] then
        self.data.selectedSpawnId = nil
    end
    if self.data.selectedSpawnId and not shouldIncludeNemesis(self.data.nemeses[self.data.selectedSpawnId]) then
        self.data.selectedSpawnId = nil
    end
    if not self.data.selectedSpawnId and self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:SetScope(scope)
    if scope ~= "zone" then
        scope = "all"
    end

    self.data.currentScope = scope
    self.data.page = 1
    sortNemeses()
    if self.data.selectedSpawnId and not self.data.nemeses[self.data.selectedSpawnId] then
        self.data.selectedSpawnId = nil
    end
    if self.data.selectedSpawnId and not shouldIncludeNemesis(self.data.nemeses[self.data.selectedSpawnId]) then
        self.data.selectedSpawnId = nil
    end
    if not self.data.selectedSpawnId and self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:SelectDisplayedZone(zoneId, zoneName, zoneMapKey)
    self:SetDisplayedZone(zoneId, zoneName, zoneMapKey)
    if (self.data.currentScope or "all") == "zone" then
        self.data.page = 1
        sortNemeses()
        if self.data.selectedSpawnId and not self.data.nemeses[self.data.selectedSpawnId] then
            self.data.selectedSpawnId = nil
        end
        if self.data.selectedSpawnId and not shouldIncludeNemesis(self.data.nemeses[self.data.selectedSpawnId]) then
            self.data.selectedSpawnId = nil
        end
        if not self.data.selectedSpawnId and self.data.ordered[1] then
            self.data.selectedSpawnId = self.data.ordered[1].spawnId
        end
    end
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:ChangePage(delta)
    local targetPage = math.min(self:GetMaxPage(), math.max(1, (self.data.page or 1) + delta))
    if targetPage == self.data.page then
        return
    end

    self.data.page = targetPage
    if self.UI then
        self.UI:RefreshList()
        self.UI:RefreshStatus()
    end
end

function NT:CenterOnNemesis(spawnId)
    local nemesis = spawnId and self.data.nemeses[spawnId] or nil
    if not nemesis then
        return
    end

    self:SetDisplayedZone(nemesis.zoneId, nemesis.zoneName)
end

function NT:SelectNemesis(spawnId)
    if spawnId and self.data.nemeses[spawnId] then
        self.data.selectedSpawnId = spawnId
    elseif not self.data.selectedSpawnId and self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end

    if self.data.selectedSpawnId then
        self:CenterOnNemesis(self.data.selectedSpawnId)
    end

    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:ResetSnapshot(count)
    wipe(self.data.nemeses)
    wipe(self.data.ordered)
    self:SetDisplayedZone(nil, nil)
    self.data.snapshotExpected = tonumber(count) or 0
    self.data.snapshotActive = true
    self.data.connectionState = "syncing"
    self.data.page = 1
    self.data.filteredCount = 0
end

function NT:FinalizeSnapshot()
    self.data.snapshotActive = false
    self.data.connectionState = "live"
    sortNemeses()
    if not self.data.selectedSpawnId and self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:UpsertNemesis(fields)
    local spawnId = tonumber(fields[3])
    if not spawnId then
        return
    end

    local nemesis = self.data.nemeses[spawnId] or {}
    nemesis.spawnId = spawnId
    nemesis.creatureEntry = tonumber(fields[4]) or 0
    nemesis.name = fields[5] or "Unknown"
    nemesis.mapId = tonumber(fields[6]) or 0
    nemesis.zoneId = tonumber(fields[7]) or 0
    nemesis.zoneName = fields[8] or "Unknown"
    nemesis.zoneKey = zoneKey(nemesis.zoneId, nemesis.zoneName)
    nemesis.x = tonumber(fields[9]) or 0
    nemesis.y = tonumber(fields[10]) or 0
    nemesis.z = tonumber(fields[11]) or 0
    nemesis.mapX = tonumber(fields[12]) or 0.5
    nemesis.mapY = tonumber(fields[13]) or 0.5
    nemesis.level = tonumber(fields[14]) or 0
    nemesis.rank = tonumber(fields[15]) or 1
    nemesis.rankTier = fields[16] or "Marked"
    nemesis.affixMask = tonumber(fields[17]) or 0
    nemesis.affixText = fields[18] or "None"
    nemesis.targetGuid = tonumber(fields[19]) or 0
    nemesis.targetName = fields[20] or ""
    nemesis.relation = normalizeRelation(fields[21])
    nemesis.rewardClass = fields[22] or "none"
    nemesis.threatClass = fields[23] or "low"
    nemesis.lastSeenAt = tonumber(fields[24]) or 0
    nemesis.removeReason = nil
    self.data.nemeses[spawnId] = nemesis

    if not self.data.selectedSpawnId then
        self.data.selectedSpawnId = spawnId
    end

    sortNemeses()
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:RemoveNemesis(spawnId, reason)
    if not spawnId then
        return
    end

    local old = self.data.nemeses[spawnId]
    if old then
        old.removeReason = reason
    end

    self.data.nemeses[spawnId] = nil
    if self.data.selectedSpawnId == spawnId then
        self.data.selectedSpawnId = nil
    end
    sortNemeses()
    if not self.data.selectedSpawnId and self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:HandleChunk(message)
    local first = string.find(message, ":", 1, true)
    if not first then
        return
    end
    local second = string.find(message, ":", first + 1, true)
    if not second then
        return
    end
    local third = string.find(message, ":", second + 1, true)
    if not third then
        return
    end
    local fourth = string.find(message, ":", third + 1, true)
    if not fourth then
        return
    end

    local chunkId = string.sub(message, first + 1, second - 1)
    local part = tonumber(string.sub(message, second + 1, third - 1)) or 0
    local total = tonumber(string.sub(message, third + 1, fourth - 1)) or 0
    local payload = string.sub(message, fourth + 1)

    if not self.data.chunks[chunkId] then
        self.data.chunks[chunkId] = { total = total, parts = {} }
    end

    local state = self.data.chunks[chunkId]
    state.parts[part] = payload

    local count = 0
    for _ in pairs(state.parts) do
        count = count + 1
    end

    if count < state.total then
        return
    end

    local rebuilt = ""
    for index = 1, state.total do
        rebuilt = rebuilt .. (state.parts[index] or "")
    end

    self.data.chunks[chunkId] = nil
    self:ParsePayload(rebuilt)
end

function NT:ParsePayload(payload)
    if not payload or payload == "" then
        return
    end

    local fields = splitPreserveEmpty(payload, ":")
    local opcode = fields[2]
    if not opcode then
        return
    end

    if opcode == "CHUNK" then
        self:HandleChunk(payload)
        return
    end

    if opcode == "HELLO" then
        self.data.lastSyncAt = self:GetNow()
        self.data.connectionState = "connected"
        self.data.lastServerTime = tonumber(fields[5]) or 0
        if self.UI then
            self.UI:RefreshStatus()
        end
        return
    end

    if opcode == "SNAPSHOT_BEGIN" then
        self:ResetSnapshot(fields[3])
        if self.UI then
            self.UI:RefreshStatus()
        end
        return
    end

    if opcode == "SNAPSHOT_ENTRY" or opcode == "UPSERT" then
        self:UpsertNemesis(fields)
        return
    end

    if opcode == "SNAPSHOT_END" then
        self:FinalizeSnapshot()
        return
    end

    if opcode == "REMOVE" then
        self:RemoveNemesis(tonumber(fields[3]), fields[4])
        return
    end
end

function NT:HandleSystemMessage(message)
    if not message then
        return
    end

    local prefix = self.prefix .. "\t"
    if string.sub(message, 1, string.len(prefix)) ~= prefix then
        return
    end

    self:ParsePayload(string.sub(message, string.len(prefix) + 1))
end

function NT:BuildSyncChannel()
    if IsInGuild and IsInGuild() then
        return "GUILD"
    end

    if GetNumPartyMembers and GetNumPartyMembers() > 0 then
        return "PARTY"
    end

    return "SAY"
end

function NT:RequestSync()
    self.data.connectionState = "requesting"
    self.data.lastSyncAt = self:GetNow()
    if self.UI then
        self.UI:RefreshStatus()
    end
    SendChatMessage(".nemesis addon sync", self:BuildSyncChannel())
end

function NT:ToggleWindow()
    if not self.UI or not self.UI.frame then
        return
    end

    if self.UI.frame:IsShown() then
        self.UI.frame:Hide()
    else
        self.UI.frame:Show()
        self.UI:RefreshAll()
    end
end

function NT:InitializeDatabase()
    local defaults = {
        profile = {
            window = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0, width = 980, height = 640 },
            compactList = false,
        },
    }

    self.database = LibStub("AceDB-3.0"):New("NemesisTrackerDB", defaults, true)
    self.db = self.database.profile
end

function NT:ToggleCompactList()
    self.db.compactList = not self.db.compactList
    self.data.page = 1
    sortNemeses()
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:SlashCommand(input)
    input = string.lower(input or "")
    if input == "sync" then
        self:RequestSync()
        return
    end

    self:ToggleWindow()
end

function NT:RefreshVisibleUI()
    if self.UI and self.UI.frame and self.UI.frame:IsShown() then
        self.UI:RefreshStatus()
        self.UI:RefreshList()
        self.UI:RefreshDetails()
    end
end

function NT:OnInitialize()
    self:InitializeDatabase()
    if self.UI then
        self.UI:Create()
        self.UI:RefreshAll()
    end

    self:RegisterChatCommand("nemesistracker", "SlashCommand")
    self:RegisterChatCommand("ntrack", "SlashCommand")

    if RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(self.prefix)
    end
end

function NT:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("CHAT_MSG_SYSTEM")
    self:RegisterEvent("CHAT_MSG_ADDON")
    self.refreshTimer = self:ScheduleRepeatingTimer("RefreshVisibleUI", 1)
end

function NT:OnDisable()
    if self.refreshTimer then
        self:CancelTimer(self.refreshTimer)
        self.refreshTimer = nil
    end
end

function NT:PLAYER_ENTERING_WORLD()
    self:ScheduleTimer(function()
        self:RequestSync()
    end, 2)
end

function NT:CHAT_MSG_SYSTEM(_, message)
    self:HandleSystemMessage(message)
end

function NT:CHAT_MSG_ADDON(_, prefix, message)
    if prefix == self.prefix then
        self:ParsePayload(message)
    end
end
