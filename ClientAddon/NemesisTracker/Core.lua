local addonName = ...

local existingNamespace = NemesisTracker or {}

NemesisTracker = LibStub("AceAddon-3.0"):NewAddon("NemesisTracker", "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0", "AceComm-3.0")
local NT = NemesisTracker

NT.MapData = existingNamespace.MapData or NT.MapData or {}
NT.UI = existingNamespace.UI or NT.UI or {}

local RELATION_ORDER = { own = 1, party = 2, guild = 3, public = 4 }
local SOURCE_ORDER = { ["peer-sync"] = 1, ["local-cache"] = 1, ["server-bootstrap"] = 2, ["rank5-broadcast"] = 3, ["server-validated"] = 4 }

NT.prefix = "Nemesis"
NT.peerPrefix = "NemesisV2P"
NT.db = NemesisTrackerDB or {}
NT.data = NT.data or {
    nemeses = {},
    ordered = {},
    chunks = {},
    selectedSpawnId = nil,
    displayedZoneId = nil,
    displayedZoneName = nil,
    displayedZoneKey = nil,
    bootstrapExpected = 0,
    bootstrapActive = false,
    lastSyncAt = 0,
    lastServerTime = 0,
    connectionState = "idle",
    currentFilter = "all",
    currentScope = "all",
    currentSearch = "",
    page = 1,
    filteredCount = 0,
    lastReportBySpawnId = {},
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

local function shortName(name)
    return string.match(name or "", "^[^-]+") or (name or "")
end

local function sanitizeField(value)
    value = tostring(value or "")
    value = string.gsub(value, ":", ";")
    value = string.gsub(value, "|", "/")
    value = string.gsub(value, "\t", " ")
    value = string.gsub(value, "\r", " ")
    value = string.gsub(value, "\n", " ")
    return value
end

local function normalizeRelation(value)
    if value == "own" or value == "party" or value == "guild" then
        return value
    end

    return "public"
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

local function parseSpawnIdFromGuid(guid)
    if not guid then
        return nil
    end

    local low = string.match(guid, "(%x+)$")
    if not low then
        return nil
    end

    if string.len(low) > 8 then
        low = string.sub(low, -8)
    end

    return tonumber(low, 16)
end

function NT:GetNow()
    return time()
end

function NT:GetAge(lastSeenAt)
    if not lastSeenAt or lastSeenAt <= 0 then
        return math.huge
    end

    return math.max(0, self:GetNow() - lastSeenAt)
end

function NT:GetStalenessState(nemesis)
    if not nemesis then
        return "unknown"
    end

    local age = self:GetAge(nemesis.lastSeenAt)
    if age >= (self.db.hideAfterSeconds or 7200) then
        return "hidden"
    end
    if age >= (self.db.staleAfterSeconds or 1800) then
        return "stale"
    end
    if age >= (self.db.fadeAfterSeconds or 600) then
        return "fading"
    end

    return "fresh"
end

function NT:GetVisibilityAlpha(nemesis)
    local state = self:GetStalenessState(nemesis)
    if state == "hidden" then
        return 0.0
    end
    if state == "stale" then
        return 0.35
    end
    if state == "fading" then
        return 0.6
    end

    return 1.0
end

function NT:ShouldHideNemesis(nemesis)
    return self:GetStalenessState(nemesis) == "hidden"
end

local function shouldIncludeNemesis(nemesis)
    if not nemesis or NT:ShouldHideNemesis(nemesis) then
        return false
    end

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

        if (a.rank or 1) ~= (b.rank or 1) then
            return (a.rank or 1) > (b.rank or 1)
        end

        if (a.lastSeenAt or 0) ~= (b.lastSeenAt or 0) then
            return (a.lastSeenAt or 0) > (b.lastSeenAt or 0)
        end

        return (a.name or "") < (b.name or "")
    end)

    local maxPage = NT:GetMaxPage()
    if NT.data.page > maxPage then
        NT.data.page = maxPage
    end
end

function NT:GetSelectedNemesis()
    if not self.data.selectedSpawnId then
        return nil
    end

    local nemesis = self.data.nemeses[self.data.selectedSpawnId]
    if nemesis and not self:ShouldHideNemesis(nemesis) then
        return nemesis
    end

    return nil
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

function NT:GetAvailableZones()
    local zones = {}
    local seen = {}
    local filter = self.data.currentFilter or "all"

    for _, nemesis in pairs(self.data.nemeses) do
        if not self:ShouldHideNemesis(nemesis) and (filter == "all" or nemesis.relation == filter) then
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
    if spawnId and self.data.nemeses[spawnId] and not self:ShouldHideNemesis(self.data.nemeses[spawnId]) then
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

function NT:BuildCommandChannel()
    if IsInGuild and IsInGuild() then
        return "GUILD"
    end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        return "RAID"
    end
    if GetNumPartyMembers and GetNumPartyMembers() > 0 then
        return "PARTY"
    end

    return "SAY"
end

function NT:SendServerCommand(commandText)
    SendChatMessage(commandText, self:BuildCommandChannel())
end

function NT:BeginBootstrap(count)
    self.data.bootstrapExpected = tonumber(count) or 0
    self.data.bootstrapActive = true
    self.data.connectionState = "bootstrap"
    self.data.lastSyncAt = self:GetNow()
    if self.UI then
        self.UI:RefreshStatus()
    end
end

function NT:FinalizeBootstrap()
    self.data.bootstrapActive = false
    self.data.connectionState = "live"
    sortNemeses()
    if (not self.data.selectedSpawnId or self:ShouldHideNemesis(self.data.nemeses[self.data.selectedSpawnId])) and self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end
    if self.UI then
        self.UI:RefreshAll()
    end
end

function NT:ShouldReplaceLocation(existing, incomingTime, incomingSource)
    if not existing then
        return true
    end

    local existingTime = existing.lastSeenAt or 0
    if incomingTime > existingTime then
        return true
    end
    if incomingTime < existingTime then
        return false
    end

    return (SOURCE_ORDER[incomingSource] or 0) >= (SOURCE_ORDER[existing.lastSeenSource] or 0)
end

function NT:UpsertNemesisFromFields(fields, startIndex, source)
    local spawnId = tonumber(fields[startIndex])
    if not spawnId then
        return nil
    end

    local existing = self.data.nemeses[spawnId]
    local incoming = {
        spawnId = spawnId,
        creatureEntry = tonumber(fields[startIndex + 1]) or 0,
        name = fields[startIndex + 2] or "Unknown",
        mapId = tonumber(fields[startIndex + 3]) or 0,
        zoneId = tonumber(fields[startIndex + 4]) or 0,
        zoneName = fields[startIndex + 5] or "Unknown",
        x = tonumber(fields[startIndex + 6]) or 0,
        y = tonumber(fields[startIndex + 7]) or 0,
        z = tonumber(fields[startIndex + 8]) or 0,
        mapX = tonumber(fields[startIndex + 9]) or 0.5,
        mapY = tonumber(fields[startIndex + 10]) or 0.5,
        level = tonumber(fields[startIndex + 11]) or 0,
        rank = tonumber(fields[startIndex + 12]) or 1,
        rankTier = fields[startIndex + 13] or "Marked",
        affixMask = tonumber(fields[startIndex + 14]) or 0,
        affixText = fields[startIndex + 15] or "None",
        targetGuid = tonumber(fields[startIndex + 16]) or 0,
        targetName = fields[startIndex + 17] or "",
        relation = normalizeRelation(fields[startIndex + 18]),
        rewardClass = fields[startIndex + 19] or "none",
        threatClass = fields[startIndex + 20] or "low",
        lastSeenAt = tonumber(fields[startIndex + 21]) or 0,
        lastSeenSource = source,
        isAlive = true,
        removeReason = nil,
    }
    incoming.zoneKey = zoneKey(incoming.zoneId, incoming.zoneName)

    if incoming.lastSeenAt <= 0 then
        incoming.lastSeenAt = existing and existing.lastSeenAt or self:GetNow()
    end

    if existing then
        if (existing.rank or 1) > incoming.rank then
            incoming.rank = existing.rank or incoming.rank
            incoming.rankTier = existing.rankTier or incoming.rankTier
        end

        if not self:ShouldReplaceLocation(existing, incoming.lastSeenAt, source) then
            incoming.mapId = existing.mapId or incoming.mapId
            incoming.zoneId = existing.zoneId or incoming.zoneId
            incoming.zoneName = existing.zoneName or incoming.zoneName
            incoming.zoneKey = existing.zoneKey or incoming.zoneKey
            incoming.x = existing.x or incoming.x
            incoming.y = existing.y or incoming.y
            incoming.z = existing.z or incoming.z
            incoming.mapX = existing.mapX or incoming.mapX
            incoming.mapY = existing.mapY or incoming.mapY
            incoming.lastSeenAt = existing.lastSeenAt or incoming.lastSeenAt
            incoming.lastSeenSource = existing.lastSeenSource or incoming.lastSeenSource
        end

        if source == "peer-sync" then
            incoming.relation = existing.relation or incoming.relation
            incoming.rewardClass = existing.rewardClass or incoming.rewardClass
            incoming.threatClass = existing.threatClass or incoming.threatClass
        end
    end

    self.data.nemeses[spawnId] = incoming

    if not self.data.selectedSpawnId then
        self.data.selectedSpawnId = spawnId
    end

    sortNemeses()
    if self.UI then
        self.UI:RefreshAll()
    end

    return incoming
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
    self:ParseServerPayload(rebuilt)
end

function NT:GetPeerDistributionTarget()
    local scope = string.upper(self.db.syncScope or "GUILD")
    if scope == "PARTY" and GetNumPartyMembers and GetNumPartyMembers() > 0 then
        return "PARTY", nil
    end
    if scope == "RAID" and GetNumRaidMembers and GetNumRaidMembers() > 0 then
        return "RAID", nil
    end
    if scope == "PUBLIC" and GetChannelName then
        local channelId = GetChannelName(self.db.publicChannelName or "NemesisTracker")
        if channelId and channelId ~= 0 then
            return "CHANNEL", channelId
        end
    end
    if IsInGuild and IsInGuild() then
        return "GUILD", nil
    end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        return "RAID", nil
    end
    if GetNumPartyMembers and GetNumPartyMembers() > 0 then
        return "PARTY", nil
    end

    return nil, nil
end

function NT:ShareValidatedNemesis(nemesis)
    if not nemesis then
        return
    end

    local distribution, target = self:GetPeerDistributionTarget()
    if not distribution then
        return
    end

    local message = string.format(
        "ENT:%d:%d:%s:%d:%d:%s:%.1f:%.1f:%.1f:%.2f:%.2f:%d:%d:%s:%d:%s:%d:%s:%s:%s:%s:%d",
        nemesis.spawnId or 0,
        nemesis.creatureEntry or 0,
        sanitizeField(nemesis.name),
        nemesis.mapId or 0,
        nemesis.zoneId or 0,
        sanitizeField(nemesis.zoneName),
        nemesis.x or 0,
        nemesis.y or 0,
        nemesis.z or 0,
        nemesis.mapX or 0.5,
        nemesis.mapY or 0.5,
        nemesis.level or 0,
        nemesis.rank or 1,
        sanitizeField(nemesis.rankTier),
        nemesis.affixMask or 0,
        sanitizeField(nemesis.affixText),
        nemesis.targetGuid or 0,
        sanitizeField(nemesis.targetName),
        sanitizeField(nemesis.relation),
        sanitizeField(nemesis.rewardClass),
        sanitizeField(nemesis.threatClass),
        nemesis.lastSeenAt or 0)
    self:SendCommMessage(self.peerPrefix, message, distribution, target, "NORMAL")
end

function NT:ParseServerPayload(payload)
    if not payload or payload == "" then
        return
    end

    local fields = splitPreserveEmpty(payload, ":")
    if fields[1] ~= "V2" then
        return
    end

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
    if opcode == "BOOTSTRAP_BEGIN" then
        self:BeginBootstrap(fields[3])
        return
    end
    if opcode == "BOOTSTRAP_ENTRY" then
        self:UpsertNemesisFromFields(fields, 3, "server-bootstrap")
        return
    end
    if opcode == "BOOTSTRAP_END" then
        self:FinalizeBootstrap()
        return
    end
    if opcode == "RANK5_BROADCAST" then
        self:UpsertNemesisFromFields(fields, 3, "rank5-broadcast")
        return
    end
    if opcode == "UPSERT_VALIDATED" then
        local nemesis = self:UpsertNemesisFromFields(fields, 3, "server-validated")
        self:ShareValidatedNemesis(nemesis)
        return
    end
    if opcode == "REMOVE" then
        self:RemoveNemesis(tonumber(fields[3]), fields[4])
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

    self:ParseServerPayload(string.sub(message, string.len(prefix) + 1))
end

function NT:RequestBootstrap()
    self.data.connectionState = "requesting"
    self.data.lastSyncAt = self:GetNow()
    if self.UI then
        self.UI:RefreshStatus()
    end
    self:SendServerCommand(".nemesis addon bootstrap")
end

function NT:RequestSync()
    self:RefreshFromSources()
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
            syncScope = "GUILD",
            publicChannelName = "NemesisTracker",
            fadeAfterSeconds = 600,
            staleAfterSeconds = 1800,
            hideAfterSeconds = 7200,
            autoBootstrap = true,
            autoPeerSync = true,
            reportSightingsToServer = true,
            peerSyncMaxEntries = 100,
            reportThrottleSeconds = 20,
            cache = { nemeses = {} },
        },
    }

    self.database = LibStub("AceDB-3.0"):New("NemesisTrackerDB", defaults, true)
    self.db = self.database.profile
    self.db.cache = self.db.cache or {}
    self.db.cache.nemeses = self.db.cache.nemeses or {}
    self.data.nemeses = self.db.cache.nemeses
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
    if input == "sync" or input == "refresh" then
        self:RefreshFromSources()
        return
    end
    if input == "peer" then
        self:RequestPeerSync()
        return
    end

    self:ToggleWindow()
end

function NT:RefreshVisibleUI()
    if self.UI and self.UI.frame and self.UI.frame:IsShown() then
        self.UI:RefreshStatus()
        self.UI:RefreshList()
        self.UI:RefreshDetails()
        self.UI:RefreshMap()
    end
end

function NT:GetPeerSyncCandidates()
    local candidates = {}
    for _, nemesis in pairs(self.data.nemeses) do
        if not self:ShouldHideNemesis(nemesis) and (nemesis.lastSeenAt or 0) > 0 then
            table.insert(candidates, nemesis)
        end
    end

    table.sort(candidates, function(a, b)
        if (a.lastSeenAt or 0) ~= (b.lastSeenAt or 0) then
            return (a.lastSeenAt or 0) > (b.lastSeenAt or 0)
        end

        return (a.rank or 1) > (b.rank or 1)
    end)

    local maxEntries = self.db.peerSyncMaxEntries or 100
    while #candidates > maxEntries do
        table.remove(candidates)
    end

    return candidates
end

function NT:RequestPeerSync()
    local distribution, target = self:GetPeerDistributionTarget()
    if not distribution then
        return
    end

    self.data.connectionState = "peer-sync"
    self:SendCommMessage(self.peerPrefix, string.format("REQ:%d", self:GetNow()), distribution, target, "BULK")
    if self.UI then
        self.UI:RefreshStatus()
    end
end

function NT:RespondToPeerSync(sender)
    if not sender or sender == "" then
        return
    end

    for _, nemesis in ipairs(self:GetPeerSyncCandidates()) do
        local message = string.format(
            "ENT:%d:%d:%s:%d:%d:%s:%.1f:%.1f:%.1f:%.2f:%.2f:%d:%d:%s:%d:%s:%d:%s:%s:%s:%s:%d",
            nemesis.spawnId or 0,
            nemesis.creatureEntry or 0,
            sanitizeField(nemesis.name),
            nemesis.mapId or 0,
            nemesis.zoneId or 0,
            sanitizeField(nemesis.zoneName),
            nemesis.x or 0,
            nemesis.y or 0,
            nemesis.z or 0,
            nemesis.mapX or 0.5,
            nemesis.mapY or 0.5,
            nemesis.level or 0,
            nemesis.rank or 1,
            sanitizeField(nemesis.rankTier),
            nemesis.affixMask or 0,
            sanitizeField(nemesis.affixText),
            nemesis.targetGuid or 0,
            sanitizeField(nemesis.targetName),
            sanitizeField(nemesis.relation),
            sanitizeField(nemesis.rewardClass),
            sanitizeField(nemesis.threatClass),
            nemesis.lastSeenAt or 0)
        self:SendCommMessage(self.peerPrefix, message, "WHISPER", sender, "BULK")
    end

    self:SendCommMessage(self.peerPrefix, string.format("DONE:%d", self:GetNow()), "WHISPER", sender, "NORMAL")
end

function NT:OnPeerCommReceived(prefix, message, distribution, sender)
    if prefix ~= self.peerPrefix or not message or shortName(sender) == shortName(UnitName("player")) then
        return
    end

    local fields = splitPreserveEmpty(message, ":")
    if fields[1] == "REQ" then
        self:RespondToPeerSync(sender)
        return
    end
    if fields[1] == "ENT" then
        self:UpsertNemesisFromFields(fields, 2, "peer-sync")
        self.data.lastSyncAt = self:GetNow()
        self.data.connectionState = "live"
        return
    end
    if fields[1] == "DONE" then
        self.data.lastSyncAt = self:GetNow()
        self.data.connectionState = "live"
        if self.UI then
            self.UI:RefreshStatus()
        end
        return
    end
    if fields[1] == "DEL" then
        self:RemoveNemesis(tonumber(fields[2]), fields[3])
    end
end

function NT:RefreshFromSources()
    self:RequestBootstrap()
    self:RequestPeerSync()
end

function NT:ReportSighting(spawnId)
    if not spawnId or not self.db.reportSightingsToServer then
        return
    end

    local now = self:GetNow()
    local throttle = self.db.reportThrottleSeconds or 20
    local lastReportAt = self.data.lastReportBySpawnId[spawnId] or 0
    if lastReportAt + throttle > now then
        return
    end

    self.data.lastReportBySpawnId[spawnId] = now
    self:SendServerCommand(string.format(".nemesis addon report %d", spawnId))
end

function NT:TrackKnownUnit(unit)
    if not UnitExists or not UnitExists(unit) then
        return
    end

    local spawnId = parseSpawnIdFromGuid(UnitGUID(unit))
    if spawnId and self.data.nemeses[spawnId] then
        self:ReportSighting(spawnId)
    end
end

function NT:OnInitialize()
    self:InitializeDatabase()
    sortNemeses()
    if self.data.ordered[1] then
        self.data.selectedSpawnId = self.data.ordered[1].spawnId
    end

    if self.UI then
        self.UI:Create()
        self.UI:RefreshAll()
    end

    self:RegisterChatCommand("nemesistracker", "SlashCommand")
    self:RegisterChatCommand("ntrack", "SlashCommand")

    if RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(self.prefix)
        RegisterAddonMessagePrefix(self.peerPrefix)
    end

    self:RegisterComm(self.peerPrefix, "OnPeerCommReceived")
end

function NT:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
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
        if self.db.autoBootstrap then
            self:RequestBootstrap()
        end
        if self.db.autoPeerSync then
            self:RequestPeerSync()
        end
    end, 2)
end

function NT:PLAYER_TARGET_CHANGED()
    self:TrackKnownUnit("target")
end

function NT:UPDATE_MOUSEOVER_UNIT()
    self:TrackKnownUnit("mouseover")
end

function NT:CHAT_MSG_SYSTEM(_, message)
    self:HandleSystemMessage(message)
end

function NT:CHAT_MSG_ADDON(_, prefix, message)
    if prefix == self.prefix then
        self:ParseServerPayload(message)
    end
end
