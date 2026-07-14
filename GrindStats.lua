-- GrindStats: session XP/hour, gold/hour, kill and loot tracking (WotLK 3.3.5)

local ADDON_NAME = "GrindStats"

-- Session state (not saved; a session is one tracking run)
local session = {
    startTime = nil,     -- GetTime() when tracking started
    xpGained = 0,
    kills = 0,
    startMoney = 0,      -- GetMoney() at session start
    lootedMoney = 0,     -- coin picked up from mobs/chests only
    lastXP = 0,
    lastXPMax = 0,
    paused = false,
    pausedAt = nil,
    pausedTotal = 0,     -- seconds spent paused
}

local f = CreateFrame("Frame", "GrindStatsFrame", UIParent)
local rows = {}
local NUM_ROWS = 8

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function SessionSeconds()
    if not session.startTime then return 0 end
    local now = session.paused and session.pausedAt or GetTime()
    return now - session.startTime - session.pausedTotal
end

local function FormatTime(seconds)
    if not seconds or seconds < 0 or seconds ~= seconds or seconds == math.huge then
        return "--"
    end
    seconds = math.floor(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

local function FormatMoney(copper)
    local neg = copper < 0
    copper = math.abs(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local out
    if g > 0 then
        out = string.format("|cffffd700%d|rg |cffc7c7cf%d|rs", g, s)
    elseif s > 0 then
        out = string.format("|cffc7c7cf%d|rs |cffeda55f%d|rc", s, c)
    else
        out = string.format("|cffeda55f%d|rc", c)
    end
    if neg then
        out = "|cffff4040-|r" .. out
    end
    return out
end

local function Comma(n)
    n = math.floor(n + 0.5)
    local str = tostring(n)
    local out = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

local function UpdateDisplay()
    local elapsed = SessionSeconds()
    local hours = elapsed / 3600

    local xpPerHour = hours > 0 and session.xpGained / hours or 0
    local netMoney = GetMoney() - session.startMoney
    local goldPerHour = hours > 0 and netMoney / hours or 0

    local xpToLevel = UnitXPMax("player") - UnitXP("player")
    local ttl -- seconds until level at current rate
    if xpPerHour > 0 and UnitLevel("player") < 80 then
        ttl = xpToLevel / xpPerHour * 3600
    end

    local xpPerKill = session.kills > 0 and session.xpGained / session.kills or 0
    local killsToLevel = xpPerKill > 0 and math.ceil(xpToLevel / xpPerKill) or nil

    local pauseTag = session.paused and " |cffff4040(paused)|r" or ""

    rows[1]:SetText("|cff9d9d9dSession|r  " .. FormatTime(elapsed) .. pauseTag)
    rows[2]:SetText("|cff9d9d9dXP|r  " .. Comma(session.xpGained) .. "  (" .. Comma(xpPerHour) .. "/hr)")
    rows[3]:SetText("|cff9d9d9dTo level|r  " .. (ttl and FormatTime(ttl) or "--"))
    rows[4]:SetText("|cff9d9d9dKills|r  " .. session.kills .. (xpPerKill > 0 and ("  (" .. Comma(xpPerKill) .. " xp/kill)") or ""))
    rows[5]:SetText("|cff9d9d9dKills to lvl|r  " .. (killsToLevel and Comma(killsToLevel) or "--"))
    rows[6]:SetText("|cff9d9d9dGold net|r  " .. FormatMoney(netMoney))
    rows[7]:SetText("|cff9d9d9dGold looted|r  " .. FormatMoney(session.lootedMoney))
    rows[8]:SetText("|cff9d9d9dGold/hr|r  " .. FormatMoney(math.floor(goldPerHour)))
end

local function ResetSession()
    session.startTime = GetTime()
    session.xpGained = 0
    session.kills = 0
    session.startMoney = GetMoney()
    session.lootedMoney = 0
    session.lastXP = UnitXP("player")
    session.lastXPMax = UnitXPMax("player")
    session.paused = false
    session.pausedAt = nil
    session.pausedTotal = 0
    UpdateDisplay()
end

local function TogglePause()
    if session.paused then
        session.pausedTotal = session.pausedTotal + (GetTime() - session.pausedAt)
        session.paused = false
        session.pausedAt = nil
        print("|cff33ff99GrindStats|r resumed.")
    else
        session.paused = true
        session.pausedAt = GetTime()
        print("|cff33ff99GrindStats|r paused.")
    end
    UpdateDisplay()
end

-- ---------------------------------------------------------------------------
-- Frame setup
-- ---------------------------------------------------------------------------

local function BuildFrame()
    f:SetWidth(190)
    f:SetHeight(14 * NUM_ROWS + 30)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.75)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        GrindStatsDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:SetClampedToScreen(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -7)
    title:SetText("|cff33ff99GrindStats|r")

    for i = 1, NUM_ROWS do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 8, -22 - (i - 1) * 14)
        fs:SetJustifyH("LEFT")
        rows[i] = fs
    end

    if GrindStatsDB.pos then
        local p = GrindStatsDB.pos
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        f:SetPoint("RIGHT", UIParent, "RIGHT", -40, 100)
    end

    if GrindStatsDB.hidden then
        f:Hide()
    end
end

-- Throttled repaint (rates change every second even without events)
local acc = 0
f:SetScript("OnUpdate", function(self, elapsed)
    acc = acc + elapsed
    if acc >= 1 then
        acc = 0
        if self:IsShown() and session.startTime then
            UpdateDisplay()
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
f:RegisterEvent("CHAT_MSG_MONEY")

f:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        GrindStatsDB = GrindStatsDB or {}
        BuildFrame()
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        if not session.startTime then
            ResetSession()
        end

    elseif event == "PLAYER_XP_UPDATE" then
        if session.paused then
            session.lastXP = UnitXP("player")
            session.lastXPMax = UnitXPMax("player")
            return
        end
        local xp = UnitXP("player")
        if xp >= session.lastXP then
            session.xpGained = session.xpGained + (xp - session.lastXP)
        else
            -- leveled: remainder of old bar plus progress into the new one
            session.xpGained = session.xpGained + (session.lastXPMax - session.lastXP) + xp
        end
        session.lastXP = xp
        session.lastXPMax = UnitXPMax("player")
        UpdateDisplay()

    elseif event == "PLAYER_LEVEL_UP" then
        print("|cff33ff99GrindStats|r ding! Level " .. arg1 .. " after " .. FormatTime(SessionSeconds()) .. " this session.")

    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        if not session.paused and string.find(arg1, "dies") then
            session.kills = session.kills + 1
        end

    elseif event == "CHAT_MSG_MONEY" then
        if session.paused then return end
        -- "You loot 1 Gold, 23 Silver, 45 Copper" (also share messages)
        local total = 0
        local g = string.match(arg1, "(%d+) " .. GOLD)
        local s = string.match(arg1, "(%d+) " .. SILVER)
        local c = string.match(arg1, "(%d+) " .. COPPER)
        if g then total = total + tonumber(g) * 10000 end
        if s then total = total + tonumber(s) * 100 end
        if c then total = total + tonumber(c) end
        session.lootedMoney = session.lootedMoney + total
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_GRINDSTATS1 = "/gs"
SLASH_GRINDSTATS2 = "/grindstats"
SlashCmdList["GRINDSTATS"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "reset" then
        ResetSession()
        print("|cff33ff99GrindStats|r session reset.")
    elseif msg == "pause" then
        TogglePause()
    elseif msg == "hide" then
        f:Hide()
        GrindStatsDB.hidden = true
    elseif msg == "show" then
        f:Show()
        GrindStatsDB.hidden = nil
        UpdateDisplay()
    else
        print("|cff33ff99GrindStats|r commands:")
        print("  /gs reset - restart the session")
        print("  /gs pause - pause/resume the timer")
        print("  /gs show | hide - toggle the window")
    end
end
