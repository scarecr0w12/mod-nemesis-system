local addonName = ...

NemesisTracker = NemesisTracker or {}
local NT = NemesisTracker

local RELATION_ORDER = { own = 1, party = 2, guild = 3, public = 4 }

NT.prefix = "Nemesis"
NT.db = NemesisTrackerDB or {}
NT.data = NT.data or {
    nemeses = {},
    ordered = {},
    chunks = {},
    selectedSpawnId = nil,
    snapshotExpected = 0,
    snapshotActive = false,
    lastSyncAt = 0,
    lastServerTime = 0,
    connectionState = "idle",
    currentFilter = "all",
    page = 1,
    filteredCount = 0,
}

local frame = CreateFrame("Frame")
NT.frame = frame

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

local function delay(seconds, callback)
    local timer = CreateFrame("Frame")
    local elapsed = 0
    timer:SetScript("OnUpdate", function(self, diff)
        elapsed = elapsed + diff
        if elapsed < seconds then
            return
        end

        self:SetScript("OnUpdate", nil)
        callback()
    end)
end

local function shouldIncludeNemesis(nemesis)
    local filter = NT.data.currentFilter or "all"
    if filter == "all" then
        return true
    end

    return nemesis.relation == filter
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

    self.db.panX = -((nemesis.x or 0) / 20000) * (self.db.zoom or 1)
    self.db.panY = ((nemesis.y or 0) / 20000) * (self.db.zoom or 1)
    self.db.panX = math.max(-0.8, math.min(0.8, self.db.panX))
    self.db.panY = math.max(-0.8, math.min(0.8, self.db.panY))
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
    self.data.snapshotExpected = tonumber(count) or 0
    self.data.snapshotActive = true
    self.data.connectionState = "syncing"
    self.data.page = 1
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
    nemesis.x = tonumber(fields[9]) or 0
    nemesis.y = tonumber(fields[10]) or 0
    nemesis.z = tonumber(fields[11]) or 0
    nemesis.level = tonumber(fields[12]) or 0
    nemesis.rank = tonumber(fields[13]) or 1
    nemesis.rankTier = fields[14] or "Marked"
    nemesis.affixMask = tonumber(fields[15]) or 0
    nemesis.affixText = fields[16] or "None"
    nemesis.targetGuid = tonumber(fields[17]) or 0
    nemesis.targetName = fields[18] or ""
    nemesis.relation = normalizeRelation(fields[19])
    nemesis.rewardClass = fields[20] or "none"
    nemesis.threatClass = fields[21] or "low"
    nemesis.lastSeenAt = tonumber(fields[22]) or 0
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
    NemesisTrackerDB = NemesisTrackerDB or {}
    NemesisTrackerDB.window = NemesisTrackerDB.window or { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0, width = 980, height = 640 }
    NemesisTrackerDB.zoom = NemesisTrackerDB.zoom or 1
    NemesisTrackerDB.panX = NemesisTrackerDB.panX or 0
    NemesisTrackerDB.panY = NemesisTrackerDB.panY or 0
    self.db = NemesisTrackerDB
end

function NT:SlashCommand(input)
    input = string.lower(input or "")
    if input == "sync" then
        self:RequestSync()
        return
    end

    self:ToggleWindow()
end

frame:SetScript("OnUpdate", function(_, elapsed)
    NT._elapsed = (NT._elapsed or 0) + elapsed
    if NT._elapsed < 1 then
        return
    end

    NT._elapsed = 0
    if NT.UI and NT.UI.frame and NT.UI.frame:IsShown() then
        NT.UI:RefreshStatus()
        NT.UI:RefreshList()
        NT.UI:RefreshDetails()
    end
end)

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
            return
        end

        NT:InitializeDatabase()
        if NT.UI then
            NT.UI:Create()
            NT.UI:RefreshAll()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        delay(2, function()
            NT:RequestSync()
        end)
    elseif event == "CHAT_MSG_SYSTEM" then
        NT:HandleSystemMessage(...)
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix == NT.prefix then
            NT:ParsePayload(message)
        end
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("CHAT_MSG_ADDON")

if RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(NT.prefix)
end

SLASH_NEMESISTRACKER1 = "/nemesistracker"
SLASH_NEMESISTRACKER2 = "/ntrack"
SlashCmdList["NEMESISTRACKER"] = function(input)
    NT:SlashCommand(input)
end
