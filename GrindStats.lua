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
    lastLevel = 0,
    paused = false,
    pausedAt = nil,
    pausedTotal = 0,     -- seconds spent paused
    snapshots = {},      -- recent cumulative-XP readings (for the rate window)
    samples = {},        -- immediate-rate history, one point per SAMPLE_SECS
    recentKillXP = {},   -- XP of the last few kills (rolling estimator)
    killOutliers = {},   -- consecutive kills that disagree with the window
}

local KILL_WINDOW = 10        -- kills-to-level uses the last N kills, not the session
local KILL_DEVIATION = 0.25   -- >25% off the running average = outlier
local KILL_OUTLIERS = 3       -- this many in a row = situation changed, restart window

local f = CreateFrame("Frame", "GrindStatsFrame", UIParent)
local rows = {}
local NUM_ROWS = 8

-- Rolling XP graph: a continuous line of your immediate rate, newest on the
-- right, plus a horizontal line marking the session average
local SAMPLE_SECS = 5          -- one point every 5 seconds
local POINTS = 174             -- 1px per point -> ~14.5 minutes of history
local RATE_WINDOW = 60         -- "immediate" rate = XP over the trailing minute
local GRAPH_H = 26
local graph                    -- child frame holding the line
local dots = {}
local avgLine

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

local function UpdateGraph()
    if not graph or not graph:IsShown() then return end
    local n = #session.samples

    local elapsed = SessionSeconds()
    local avg = elapsed > 0 and session.xpGained / elapsed or 0  -- xp per second

    local maxV = avg
    for i = 1, n do
        if session.samples[i] > maxV then maxV = session.samples[i] end
    end

    local usableH = GRAPH_H - 2
    for i = 1, POINTS do
        local dot = dots[i]
        local si = n - POINTS + i   -- right-align: newest sample in last slot
        if si >= 1 and maxV > 0 then
            local v = session.samples[si]
            dot:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT",
                (i - 1) * (dot.colW), (v / maxV) * usableH)
            if avg > 0 and v >= avg then
                dot:SetVertexColor(0.3, 1, 0.3, 0.95)
            elseif avg > 0 then
                dot:SetVertexColor(1, 0.35, 0.35, 0.95)
            else
                dot:SetVertexColor(0.6, 0.6, 0.6, 0.8)
            end
            dot:Show()
        else
            dot:Hide()
        end
    end

    if avg > 0 and maxV > 0 then
        avgLine:ClearAllPoints()
        avgLine:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, (avg / maxV) * usableH)
        avgLine:SetPoint("BOTTOMRIGHT", graph, "BOTTOMRIGHT", 0, (avg / maxV) * usableH)
        avgLine:Show()
    else
        avgLine:Hide()
    end
end

-- Latest immediate rate vs session average, as a ratio
local function RecentPaceRatio()
    local n = #session.samples
    if n < 3 then return nil end
    local elapsed = SessionSeconds()
    if elapsed <= 0 or session.xpGained <= 0 then return nil end
    local avgRate = session.xpGained / elapsed
    if avgRate <= 0 then return nil end
    return session.samples[n] / avgRate
end

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

    -- xp/kill from the last KILL_WINDOW kills (recovers quickly after a ding
    -- or a mob switch); falls back to the session-wide average
    local xpPerKill = 0
    local nRecent = #session.recentKillXP
    if nRecent > 0 then
        local sum = 0
        for i = 1, nRecent do sum = sum + session.recentKillXP[i] end
        xpPerKill = sum / nRecent
    elseif session.kills > 0 then
        xpPerKill = session.xpGained / session.kills
    end
    local killsToLevel = xpPerKill > 0 and math.ceil(xpToLevel / xpPerKill) or nil

    local rested = GetXPExhaustion()
    local restedStr = ""
    if rested and rested > 0 and UnitXPMax("player") > 0 then
        restedStr = string.format("  |cff6699ffrested %d%%|r", rested / UnitXPMax("player") * 100)
    end

    local pauseTag = session.paused and " |cffff4040(paused)|r" or ""

    -- tint XP/hr by recent pace vs session average (green fast, red slow)
    local rateColor = "|cffffffff"
    local ratio = RecentPaceRatio()
    if ratio then
        if ratio >= 1.05 then
            rateColor = "|cff40ff40"
        elseif ratio <= 0.95 then
            rateColor = "|cffff5050"
        end
    end

    rows[1]:SetText("|cff9d9d9dSession|r  " .. FormatTime(elapsed) .. pauseTag)
    rows[2]:SetText("|cff9d9d9dXP|r  " .. Comma(session.xpGained) .. "  (" .. rateColor .. Comma(xpPerHour) .. "/hr|r)")
    rows[3]:SetText("|cff9d9d9dTo level|r  " .. (ttl and FormatTime(ttl) or "--") .. restedStr)
    rows[4]:SetText("|cff9d9d9dKills|r  " .. session.kills .. (xpPerKill > 0 and ("  (" .. Comma(xpPerKill) .. " xp/kill)") or ""))
    rows[5]:SetText("|cff9d9d9dKills to lvl|r  " .. (killsToLevel and Comma(killsToLevel) or "--"))
    rows[6]:SetText("|cff9d9d9dGold net|r  " .. FormatMoney(netMoney))
    rows[7]:SetText("|cff9d9d9dGold looted|r  " .. FormatMoney(session.lootedMoney))
    rows[8]:SetText("|cff9d9d9dGold/hr|r  " .. FormatMoney(math.floor(goldPerHour)))

    UpdateGraph()
end

local function ResetSession()
    session.startTime = GetTime()
    session.xpGained = 0
    session.kills = 0
    session.startMoney = GetMoney()
    session.lootedMoney = 0
    session.lastXP = UnitXP("player")
    session.lastXPMax = UnitXPMax("player")
    session.lastLevel = UnitLevel("player")
    session.paused = false
    session.pausedAt = nil
    session.pausedTotal = 0
    session.snapshots = {}
    session.samples = {}
    session.recentKillXP = {}
    session.killOutliers = {}
    UpdateDisplay()
end

local function TogglePause()
    if session.paused then
        session.pausedTotal = session.pausedTotal + (GetTime() - session.pausedAt)
        session.paused = false
        session.pausedAt = nil
        session.snapshots = {}  -- fresh rate window so the line doesn't dip
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

-- Right-click opacity slider ------------------------------------------------

local alphaPopup

local function BuildAlphaPopup()
    alphaPopup = CreateFrame("Frame", "GrindStatsAlphaPopup", UIParent)
    alphaPopup:SetWidth(190)
    alphaPopup:SetHeight(54)
    alphaPopup:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    alphaPopup:SetBackdropColor(0, 0, 0, 0.9)
    alphaPopup:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    alphaPopup:SetPoint("TOP", f, "BOTTOM", 0, -2)
    alphaPopup:SetFrameStrata("DIALOG")
    alphaPopup:EnableMouse(true)
    alphaPopup:Hide()
    tinsert(UISpecialFrames, "GrindStatsAlphaPopup")  -- Esc closes it

    local slider = CreateFrame("Slider", "GrindStatsAlphaSlider", alphaPopup, "OptionsSliderTemplate")
    slider:SetWidth(160)
    slider:SetPoint("CENTER", 0, -6)
    slider:SetMinMaxValues(0.2, 1)
    slider:SetValueStep(0.05)
    getglobal("GrindStatsAlphaSliderLow"):SetText("20%")
    getglobal("GrindStatsAlphaSliderHigh"):SetText("100%")
    slider:SetScript("OnValueChanged", function(self, value)
        GrindStatsDB.alpha = value
        f:SetAlpha(value)
        getglobal("GrindStatsAlphaSliderText"):SetText(string.format("Opacity %d%%", value * 100 + 0.5))
    end)
    slider:SetValue(GrindStatsDB.alpha or 1)
end

local function ToggleAlphaPopup()
    if alphaPopup:IsShown() then
        alphaPopup:Hide()
    else
        alphaPopup:Show()
    end
end

local function ApplyFrameHeight()
    local h = 14 * NUM_ROWS + 30
    if GrindStatsDB.graph then
        h = h + GRAPH_H + 10
    end
    f:SetHeight(h)
end

local function BuildFrame()
    f:SetWidth(190)
    ApplyFrameHeight()
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
    f:SetAlpha(GrindStatsDB.alpha or 1)
    f:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            ToggleAlphaPopup()
        end
    end)

    BuildAlphaPopup()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -7)
    title:SetText("|cff33ff99GrindStats|r")

    for i = 1, NUM_ROWS do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 8, -22 - (i - 1) * 14)
        fs:SetJustifyH("LEFT")
        rows[i] = fs
    end

    -- Sparkline strip along the bottom
    graph = CreateFrame("Frame", nil, f)
    graph:SetPoint("BOTTOMLEFT", 8, 8)
    graph:SetPoint("BOTTOMRIGHT", -8, 8)
    graph:SetHeight(GRAPH_H)

    local bg = graph:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(1, 1, 1, 0.06)

    local innerW = 190 - 16
    local colW = innerW / POINTS
    for i = 1, POINTS do
        local dot = graph:CreateTexture(nil, "ARTWORK")
        dot:SetTexture(1, 1, 1, 1)
        dot:SetWidth(colW)
        dot:SetHeight(2)
        dot.colW = colW
        dot:Hide()
        dots[i] = dot
    end

    avgLine = graph:CreateTexture(nil, "OVERLAY")
    avgLine:SetTexture(1, 0.82, 0, 0.5)   -- gold: session average
    avgLine:SetHeight(1)
    avgLine:Hide()

    if not GrindStatsDB.graph then
        graph:Hide()
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
local sampleAcc = 0
f:SetScript("OnUpdate", function(self, elapsed)
    if session.startTime and not session.paused then
        sampleAcc = sampleAcc + elapsed
        if sampleAcc >= SAMPLE_SECS then
            sampleAcc = sampleAcc - SAMPLE_SECS

            local snaps = session.snapshots
            table.insert(snaps, session.xpGained)
            if #snaps > (RATE_WINDOW / SAMPLE_SECS) + 1 then
                table.remove(snaps, 1)
            end

            -- immediate rate (xp/sec) over however much of the window we have
            local rate = 0
            if #snaps >= 2 then
                rate = (snaps[#snaps] - snaps[1]) / ((#snaps - 1) * SAMPLE_SECS)
            end
            table.insert(session.samples, rate)
            if #session.samples > POINTS then
                table.remove(session.samples, 1)
            end
        end
    end

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
        if GrindStatsDB.graph == nil then
            GrindStatsDB.graph = true
        end
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
            session.lastLevel = UnitLevel("player")
            return
        end
        local xp = UnitXP("player")
        local level = UnitLevel("player")
        local gained
        if level > session.lastLevel then
            -- crossed a level: remainder of the old bar plus progress into
            -- the new one (intermediate bars on a multi-level jump aren't
            -- knowable from the API and are ignored)
            gained = (session.lastXPMax - session.lastXP) + xp
        else
            gained = math.max(0, xp - session.lastXP)
        end
        session.xpGained = session.xpGained + gained
        session.lastXP = xp
        session.lastXPMax = UnitXPMax("player")
        session.lastLevel = level
        UpdateDisplay()

    elseif event == "PLAYER_LEVEL_UP" then
        -- kill XP drops after a ding: rebuild the estimator from fresh kills
        session.recentKillXP = {}
        session.killOutliers = {}
        print("|cff33ff99GrindStats|r ding! Level " .. arg1 .. " after " .. FormatTime(SessionSeconds()) .. " this session.")

    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        if not session.paused and string.find(arg1, "dies") then
            session.kills = session.kills + 1
            -- "Mob dies, you gain 120 experience." (rested bonus already
            -- included in the first number)
            local amount = tonumber(string.match(arg1, "gain (%d+) experience"))
            if amount then
                local window = session.recentKillXP
                local n = #window
                local avg
                if n >= 3 then
                    local sum = 0
                    for i = 1, n do sum = sum + window[i] end
                    avg = sum / n
                end
                if avg and math.abs(amount - avg) / avg > KILL_DEVIATION then
                    -- disagrees with the window: quarantine it. A lone odd
                    -- kill is ignored; a streak means the situation changed
                    -- (new mobs, rested ran out), so restart from the streak.
                    table.insert(session.killOutliers, amount)
                    if #session.killOutliers >= KILL_OUTLIERS then
                        session.recentKillXP = session.killOutliers
                        session.killOutliers = {}
                    end
                else
                    session.killOutliers = {}
                    table.insert(window, amount)
                    if #window > KILL_WINDOW then
                        table.remove(window, 1)
                    end
                end
            end
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
    elseif msg == "graph" then
        GrindStatsDB.graph = not GrindStatsDB.graph
        if GrindStatsDB.graph then graph:Show() else graph:Hide() end
        ApplyFrameHeight()
        UpdateDisplay()
    else
        print("|cff33ff99GrindStats|r commands:")
        print("  /gs reset - restart the session")
        print("  /gs pause - pause/resume the timer")
        print("  /gs graph - toggle the XP sparkline")
        print("  /gs show | hide - toggle the window")
        print("  right-click the window for opacity")
    end
end
