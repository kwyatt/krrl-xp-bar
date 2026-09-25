--[[
    Krrl XP Bar
    A standalone WoW addon port of an Experience Bar WeakAura
    (wago.io/rM_UFyew4, by Luxthos & Daemoos).

    All of the XP/hour, time-to-level, quest-XP and rested-XP math below is
    taken directly from that aura's custom trigger/action Lua, adapted to
    run as a normal addon frame instead of inside the WeakAuras engine.

    Simplifications vs. the original aura (documented, not hidden):
      - The 8 separate "subtext" regions are combined into one status line,
        an always-visible XP/hour line below the bar, and a GameTooltip
        breakdown on mouseover, instead of WeakAuras' individually
        positioned/animated text regions.
      - The bar uses a flat color instead of a WeakAuras gradient texture.
      - The pause/reset-session feature from the original aura has been
        removed by request; session time/XP-per-hour just tracks
        continuously from login (or reload, if configured).
      - There is no in-game options panel; toggles are set via slash
        command and saved per-character.
]]

local ADDON_NAME = ...

--------------------------------------------------------------------------
-- Saved variables / config
--------------------------------------------------------------------------

local CONFIG_DEFAULTS = {
    ["leveltime-text"]        = true,
    ["sessiontime-text"]      = true,
    ["showxphour-text"]       = true,
    ["questrested-text"]      = true,
    ["showincompletequest-bar"] = false,
    ["showmaxlevel"]          = false,
    ["reset_reload"]          = false,
    ["hide_xpbar"]            = false,
    ["debug-profile"]         = false,
}

-- Anything slower than this prints a warning when debug-profile is on.
local DEBUG_PROFILE_THRESHOLD_MS = 2

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then dst[k] = v end
    end
    return dst
end

--------------------------------------------------------------------------
-- Runtime environment (mirrors the aura's `aura_env` table)
--------------------------------------------------------------------------

local env = {
    mouseOver = false,
    xpRate = 1,                 -- bonus from "Discoverer's Delight"-style buffs
    heirloomBonusQXP = 1,       -- bonus multiplier for quest-log XP estimate
    questXP = 0,
    completeXP = 0,
    incompleteXP = 0,
    tickerRTP = nil,
    requestingTimePlayed = false,
    level = UnitLevel("player"),
}

local function GetConfig()
    return KrrlXPBarDB.config
end

local function GetSavedVars()
    KrrlXPBarCharDB.session = KrrlXPBarCharDB.session or {}
    local S = KrrlXPBarCharDB.session
    S.gainedXP               = S.gainedXP or 0
    S.lastXP                 = S.lastXP or UnitXP("player")
    S.maxXP                  = S.maxXP or UnitXPMax("player")
    S.startTime              = S.startTime or time()
    S.realTotalTime          = S.realTotalTime or 0
    S.realLevelTime          = S.realLevelTime or 0
    S.lastTimePlayedRequest  = S.lastTimePlayedRequest or 0
    return S
end

local function GetMaxLevel(exp)
    exp = exp or GetExpansionLevel()
    return min(GetMaxPlayerLevel(), GetMaxLevelForExpansionLevel(exp))
end

local function round(num, decimals)
    local mult = 10 ^ (decimals or 0)
    return Round(num * mult) / mult
end

-- Verbatim (adapted) from the aura: formats a duration in seconds using a
-- "%dd %hh %mm"-style pattern, dropping empty leading units.
local function FormatTime(t, format)
    if t <= 59 then
        return "< 1m"
    end

    local d, h, m, s = ChatFrame_TimeBreakDown(t)
    local fmt = format or "%dd %hh %mm"

    local function pad(v) return v < 10 and ("0" .. v) or v end

    local subs = {
        ["%%D([Dd]?)"] = d > 0 and (pad(d) .. "%1") or "",
        ["%%d([Dd]?)"] = d > 0 and (d .. "%1") or "",
        ["%%H([Hh]?)"] = (d > 0 or h > 0) and (pad(h) .. "%1") or "",
        ["%%h([Hh]?)"] = (d > 0 or h > 0) and (h .. "%1") or "",
        ["%%M([Mm]?)"] = pad(m) .. "%1",
        ["%%m([Mm]?)"] = m .. "%1",
        ["%%S([Ss]?)"] = pad(s) .. "%1",
        ["%%s([Ss]?)"] = s .. "%1",
    }

    for k, v in pairs(subs) do
        fmt = fmt:gsub(k, v)
    end

    return strtrim(fmt:gsub("^%s*0*", ""):gsub("^%s*[DdHhMm]", ""), " :/-|")
end

--------------------------------------------------------------------------
-- XP-rate buff scan ("Discoverer's Delight" style buffs)
--------------------------------------------------------------------------

-- Some servers don't expose UnitBuff even though other modern-looking APIs
-- exist. Fall back to UnitAura, and if neither is callable, just skip the
-- bonus scan instead of erroring.
local function GetBuffNameByIndex(unit, i)
    if type(UnitBuff) == "function" then
        local ok, name = pcall(UnitBuff, unit, i)
        if ok then return name end
    end
    if type(UnitAura) == "function" then
        local ok, name = pcall(UnitAura, unit, i, "HELPFUL")
        if ok then return name end
    end
    return nil
end

local function ScanXPRateBuffInner()
    local locName = GetSpellInfo and GetSpellInfo(436412) or (C_Spell and C_Spell.GetSpellName(436412))
    if not locName then return end

    for i = 1, 40 do
        local name = GetBuffNameByIndex("player", i)
        if not name then break end
        if name == locName then
            local tooltip = CreateFrame("GameTooltip", "KrrlXPBarHiddenTooltip", nil, "GameTooltipTemplate")
            tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
            if type(tooltip.SetUnitBuff) == "function" then
                pcall(tooltip.SetUnitBuff, tooltip, "player", i)
            end
            local description = _G["KrrlXPBarHiddenTooltipTextLeft2"] and _G["KrrlXPBarHiddenTooltipTextLeft2"]:GetText()
            if description then
                local expGain = description:match("Experience gains increased by (%d+)%%")
                if expGain then
                    env.xpRate = 1 + tonumber(expGain) / 100
                end
            end
            break
        end
    end
end

local function ScanXPRateBuff()
    env.xpRate = 1
    pcall(ScanXPRateBuffInner)
end

--------------------------------------------------------------------------
-- Heirloom / talent / buff quest-XP bonus scan
--------------------------------------------------------------------------

-- Wrapped in pcall per-call so a missing/renamed API on a given server
-- (GetItemInfo, IsSpellKnown, UnitBuff, etc.) degrades that one bonus to
-- "not detected" instead of breaking the whole scan.
local function isHeirloom(slot)
    if type(GetInventoryItemLink) ~= "function" then return false end
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if not ok or not link then return false end
    if type(GetItemInfo) ~= "function" then return false end
    local ok2, _, _, quality = pcall(GetItemInfo, link)
    if not ok2 then return false end
    return quality == 7
end

local function ScanHeirloomBonusInner()
    local SLOT_HEAD, SLOT_CLOAK, SLOT_SHOULDER, SLOT_CHEST = 1, 15, 3, 5
    local baseQXP = 1

    if isHeirloom(SLOT_HEAD) then baseQXP = baseQXP + 0.10 end
    if isHeirloom(SLOT_CLOAK) then baseQXP = baseQXP + 0.05 end
    if UnitLevel("player") < 80 then
        if isHeirloom(SLOT_SHOULDER) then baseQXP = baseQXP + 0.10 end
        if isHeirloom(SLOT_CHEST) then baseQXP = baseQXP + 0.10 end
    end

    if type(IsSpellKnown) == "function" then
        local ok, known = pcall(IsSpellKnown, 78632)
        if ok and known then baseQXP = baseQXP + 0.10 end
    end

    local i = 1
    while true do
        local name = GetBuffNameByIndex("player", i)
        if not name then break end
        local spellId
        if type(UnitBuff) == "function" then
            local ok, r10
            ok, _, _, _, _, _, _, _, _, _, r10 = pcall(UnitBuff, "player", i)
            if ok then spellId = r10 end
        end
        if spellId == 86963 then
            baseQXP = baseQXP + 0.10
            break
        end
        i = i + 1
    end

    env.heirloomBonusQXP = baseQXP
end

local function ScanHeirloomBonus()
    local ok = pcall(ScanHeirloomBonusInner)
    if not ok then
        env.heirloomBonusQXP = env.heirloomBonusQXP or 1
    end
end

--------------------------------------------------------------------------
-- Quest-log XP scan
--------------------------------------------------------------------------

local GetNumQuestLogEntries = C_QuestLog.GetNumQuestLogEntries
local GetQuestIDForLogIndex = C_QuestLog.GetQuestIDForLogIndex
local IsQuestComplete = C_QuestLog.IsComplete
local QuestReadyForTurnIn = C_QuestLog.ReadyForTurnIn or function() return false end

local function UpdateQuestXP()
    local numQ = GetNumQuestLogEntries()
    local questXP, completeXP, incompleteXP = 0, 0, 0

    for i = 1, numQ do
        local questID = GetQuestIDForLogIndex(i)
        if questID and questID > 0 then
            local rewardXP = (GetQuestLogRewardXP and GetQuestLogRewardXP(questID)) or 0
            rewardXP = rewardXP * env.xpRate

            if rewardXP > 0 then
                questXP = questXP + rewardXP
                if IsQuestComplete(questID) or QuestReadyForTurnIn(questID) then
                    completeXP = completeXP + rewardXP
                else
                    incompleteXP = incompleteXP + rewardXP
                end
            end
        end
    end

    env.questXP = questXP
    env.completeXP = completeXP
    env.incompleteXP = incompleteXP
end

--------------------------------------------------------------------------
-- Time-played request throttling
--------------------------------------------------------------------------

local function ClearTickerRTP()
    if env.tickerRTP then
        env.tickerRTP:Cancel()
        env.tickerRTP = nil
    end
    env.requestingTimePlayed = false
end

local function RequestTimePlayedNow()
    if not env.requestingTimePlayed then
        ClearTickerRTP()
        env.requestingTimePlayed = true
        RequestTimePlayed()
    end
end

--------------------------------------------------------------------------
-- Core state computation (mirrors the aura's stateupdate trigger)
--------------------------------------------------------------------------

local function ComputeState()
    local cfg = GetConfig()
    local WAS = GetSavedVars()
    local now = time()

    local currentXP = UnitXP("player") or 0
    local totalXP = UnitXPMax("player") or 0
    local remainingXP = totalXP - currentXP
    local restedXP = GetXPExhaustion() or 0

    local totalTime = WAS.realTotalTime or 0
    local levelTime = WAS.realLevelTime or 0
    if cfg["leveltime-text"] and WAS.lastTimePlayedRequest > 0 then
        totalTime = now - WAS.lastTimePlayedRequest + WAS.realTotalTime
        levelTime = now - WAS.lastTimePlayedRequest + WAS.realLevelTime
    end

    local sessionTime, hourlyXP, timeToLevel = 0, 0, 0
    if cfg["sessiontime-text"] or cfg["showxphour-text"] then
        if WAS.startTime > 0 then
            sessionTime = now - WAS.startTime
            local coeff = sessionTime / 3600
            if coeff > 0 and (WAS.gainedXP or 0) > 0 then
                hourlyXP = ceil(WAS.gainedXP / coeff)
                if hourlyXP > 0 then
                    timeToLevel = ceil(remainingXP / hourlyXP * 3600)
                end
            end
        end
    end

    return {
        level = env.level,
        currentXP = currentXP,
        totalXP = totalXP,
        remainingXP = remainingXP,
        restedXP = restedXP,
        questXP = env.questXP,
        completeXP = env.completeXP,
        incompleteXP = env.incompleteXP,
        hourlyXP = hourlyXP,
        timeToLevel = timeToLevel,
        timeToLevelText = timeToLevel > 0 and FormatTime(timeToLevel) or "--",
        totalTimeText = FormatTime(totalTime),
        levelTimeText = FormatTime(levelTime),
        sessionTimeText = FormatTime(sessionTime),
        percentXP = totalXP > 0 and ((currentXP / totalXP) * 100) or 0,
        percentrested = totalXP > 0 and ((restedXP / totalXP) * 100) or 0,
        percentcomplete = totalXP > 0 and ((env.completeXP / totalXP) * 100) or 0,
        totalpercentcomplete = totalXP > 0 and (((env.completeXP + currentXP) / totalXP) * 100) or 0,
    }
end

local isPlayerMaxLevel = env.level >= GetMaxLevel()

local function BuildCustomTexts(s)
    local cfg = GetConfig()
    local t = {}

    t.c1 = "Level " .. s.level

    if isPlayerMaxLevel then
        t.c2 = "Max Level"
    else
        t.c2 = string.format("%s / %s (%s)", FormatLargeNumber(s.currentXP),
            FormatLargeNumber(s.totalXP), FormatLargeNumber(s.remainingXP))
    end

    t.c3 = string.format("%s%%" .. ((s.percentcomplete or 0) > 0 and " (%s%%)" or ""),
        round(s.percentXP, 1), round(s.totalpercentcomplete, 1))

    if not isPlayerMaxLevel then
        if cfg["showxphour-text"] then
            local hourlyXP = s.hourlyXP or 0
            t.c4 = string.format("Leveling in: %s (%s%s XP/Hour)", s.timeToLevelText,
                hourlyXP > 10000 and round(hourlyXP / 1000, 1) or FormatLargeNumber(hourlyXP),
                hourlyXP > 10000 and "K" or "")
        end
        if cfg["questrested-text"] then
            t.c5 = string.format("Completed: %d%% - Rested: %d%%", round(s.percentcomplete, 1), round(s.percentrested, 1))
        end
    end

    if cfg["leveltime-text"] then
        t.c6 = isPlayerMaxLevel and ("Time played: " .. s.totalTimeText) or ("Time this level: " .. s.levelTimeText)
    end

    if cfg["sessiontime-text"] then
        t.c7 = "Time this session: " .. s.sessionTimeText
    end

    return t
end

--------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------

local BAR_WIDTH, BAR_HEIGHT = 600, 30

local frame = CreateFrame("StatusBar", "KrrlXPBarFrame", UIParent, "BackdropTemplate")
frame:SetSize(BAR_WIDTH, BAR_HEIGHT)
frame:SetPoint("TOP", UIParent, "TOP", 0, -4)
frame:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
frame:SetStatusBarColor(0.34, 0.39, 1, 1)
frame:SetMinMaxValues(0, 1)
frame:SetValue(0)
frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
frame:SetBackdropColor(0, 0, 0, 0.5)
frame:SetBackdropBorderColor(0, 0, 0, 1)

-- Always movable: just click-and-drag the bar, no unlock/lock step needed.
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    KrrlXPBarDB.point = { point, relPoint, x, y }
end)

local restedTex = frame:CreateTexture(nil, "ARTWORK")
restedTex:SetColorTexture(0.31, 0.56, 1, 0.55)
restedTex:SetPoint("TOP", frame, "TOP")
restedTex:SetPoint("BOTTOM", frame, "BOTTOM")

local completeTex = frame:CreateTexture(nil, "ARTWORK")
completeTex:SetColorTexture(1, 0.59, 0, 0.9)
completeTex:SetPoint("TOP", frame, "TOP")
completeTex:SetPoint("BOTTOM", frame, "BOTTOM")

local incompleteTex = frame:CreateTexture(nil, "ARTWORK")
incompleteTex:SetColorTexture(1, 0.82, 0.31, 0.6)
incompleteTex:SetPoint("TOP", frame, "TOP")
incompleteTex:SetPoint("BOTTOM", frame, "BOTTOM")

local mainText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
mainText:SetPoint("CENTER", frame, "CENTER", 0, 0)

-- Always-visible XP/hour + time-to-level line, anchored just below the bar.
local xpHourText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
xpHourText:SetPoint("TOP", frame, "BOTTOM", 0, -2)

local lastTexts -- cache of the last BuildCustomTexts() result, for the tooltip

local function ShowTooltip()
    if not lastTexts then return end
    GameTooltip:SetOwner(frame, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Krrl XP Bar", 1, 1, 1)
    for _, key in ipairs({ "c5", "c6", "c7" }) do
        local line = lastTexts[key]
        if line and line ~= "" then
            GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true)
        end
    end
    GameTooltip:Show()
end

frame:SetScript("OnEnter", function()
    env.mouseOver = true
    ShowTooltip()
end)
frame:SetScript("OnLeave", function()
    env.mouseOver = false
    GameTooltip:Hide()
end)

--------------------------------------------------------------------------
-- Display refresh
--------------------------------------------------------------------------

local function UpdateDisplay()
    local cfg = GetConfig()
    if isPlayerMaxLevel and not cfg["showmaxlevel"] then
        frame:Hide()
        return
    end
    frame:Show()

    local s = ComputeState()
    lastTexts = BuildCustomTexts(s)

    frame:SetMinMaxValues(0, s.totalXP > 0 and s.totalXP or 1)
    frame:SetValue(s.currentXP)
    frame:SetStatusBarColor(0.34, 0.39, 1, 1)

    local width = frame:GetWidth()
    local total = s.totalXP > 0 and s.totalXP or 1
    local function widthFor(xp) return width * math.min(xp / total, 1) end

    -- Starts where the current-XP fill ends, so it shows how far turning in
    -- ready-to-turn-in quests would push you (currentXP + completeXP), not
    -- completeXP measured from zero. Each segment's end is clamped to the
    -- bar, so XP past the level cap doesn't spill off the right edge.
    local incompleteXP = cfg["showincompletequest-bar"] and s.incompleteXP or 0
    local curEnd = widthFor(s.currentXP)
    local completeEnd = widthFor(s.currentXP + s.completeXP)
    local incompleteEnd = widthFor(s.currentXP + s.completeXP + incompleteXP)
    local restedEnd = widthFor(s.currentXP + s.completeXP + incompleteXP + s.restedXP)

    completeTex:ClearAllPoints()
    completeTex:SetPoint("TOPLEFT", frame, "TOPLEFT", curEnd, 0)
    completeTex:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", curEnd, 0)
    completeTex:SetWidth(math.max(completeEnd - curEnd, 0.01))

    incompleteTex:ClearAllPoints()
    incompleteTex:SetPoint("TOPLEFT", completeTex, "TOPRIGHT")
    incompleteTex:SetPoint("BOTTOMLEFT", completeTex, "BOTTOMRIGHT")
    incompleteTex:SetWidth(math.max(incompleteEnd - completeEnd, 0.01))

    restedTex:ClearAllPoints()
    restedTex:SetPoint("TOPLEFT", incompleteTex, "TOPRIGHT")
    restedTex:SetPoint("BOTTOMLEFT", incompleteTex, "BOTTOMRIGHT")
    restedTex:SetWidth(math.max(restedEnd - incompleteEnd, 0.01))

    mainText:SetText(string.format("%s   %s   %s", lastTexts.c1, lastTexts.c2, lastTexts.c3))
    xpHourText:SetText(lastTexts.c4 or "")

    if env.mouseOver and GameTooltip:IsOwned(frame) then
        ShowTooltip()
    end
end

--------------------------------------------------------------------------
-- Event handling (mirrors the aura's event trigger)
--------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local watchedEvents = {
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "QUEST_LOG_UPDATE",
    "UNIT_QUEST_LOG_CHANGED",
    "PLAYER_XP_UPDATE",
    "PLAYER_LEVEL_UP",
    "UPDATE_EXHAUSTION",
    "UPDATE_EXPANSION_LEVEL",
    "MAX_EXPANSION_LEVEL_UPDATED",
    "TIME_PLAYED_MSG",
    "ENABLE_XP_GAIN",
    "DISABLE_XP_GAIN",
    "PLAYER_EQUIPMENT_CHANGED",
    "ZONE_CHANGED_NEW_AREA",
    "ZONE_CHANGED",
    "UNIT_AURA",
}
for _, e in ipairs(watchedEvents) do
    eventFrame:RegisterEvent(e)
end

local function OnEventInner(self, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        KrrlXPBarDB = KrrlXPBarDB or {}
        KrrlXPBarDB.config = KrrlXPBarDB.config or {}
        CopyDefaults(KrrlXPBarDB.config, CONFIG_DEFAULTS)
        KrrlXPBarCharDB = KrrlXPBarCharDB or {}
        GetSavedVars()
        if KrrlXPBarDB.point then
            frame:ClearAllPoints()
            frame:SetPoint(KrrlXPBarDB.point[1], UIParent, KrrlXPBarDB.point[2], KrrlXPBarDB.point[3], KrrlXPBarDB.point[4])
        end
        ScanXPRateBuff()
        ScanHeirloomBonus()
        UpdateQuestXP()
        UpdateDisplay()
        return
    end

    local currentXP = UnitXP("player")
    local maxXP = UnitXPMax("player")
    local now = time()
    local WAS = GetSavedVars()

    if event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = arg1, arg2
        if isLogin or (isReload and GetConfig().reset_reload) then
            WAS.gainedXP = 0
            WAS.lastXP = currentXP
            WAS.maxXP = maxXP
            WAS.startTime = now
        end
        if isLogin or isReload then
            WAS.realTotalTime = 0
            WAS.realLevelTime = 0
            WAS.lastTimePlayedRequest = 0
        end
        if GetConfig()["leveltime-text"] and WAS.lastTimePlayedRequest <= 0 then
            RequestTimePlayedNow()
        end

    elseif event == "PLAYER_LEVEL_UP" then
        env.level = arg1 or env.level
        isPlayerMaxLevel = env.level >= GetMaxLevel()
        WAS.realLevelTime = 0
        WAS.maxXP = maxXP
        WAS.lastTimePlayedRequest = now

    elseif event == "UPDATE_EXPANSION_LEVEL" or event == "MAX_EXPANSION_LEVEL_UPDATED" then
        isPlayerMaxLevel = env.level >= GetMaxLevel()
        if now - WAS.startTime >= (86400 * 3) then
            WAS.startTime = now
        end

    elseif event == "QUEST_LOG_UPDATE" or (event == "UNIT_QUEST_LOG_CHANGED" and arg1 == "player") then
        UpdateQuestXP()

    elseif event == "TIME_PLAYED_MSG" and arg2 then
        WAS.realTotalTime = arg1
        WAS.realLevelTime = arg2
        WAS.lastTimePlayedRequest = now
        ClearTickerRTP()

    elseif event == "PLAYER_XP_UPDATE" then
        local gained = currentXP - WAS.lastXP
        if gained < 0 then
            gained = WAS.maxXP - WAS.lastXP + currentXP
        end
        WAS.gainedXP = WAS.gainedXP + gained
        WAS.lastXP = currentXP
        WAS.maxXP = maxXP

    elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" then
        ScanHeirloomBonus()
        UpdateQuestXP()

    elseif event == "UNIT_AURA" then
        if arg1 == "player" then
            ScanXPRateBuff()
        end
    end

    UpdateDisplay()
end

-- Self-timing wrapper: prints how long each event took to handle when
-- debug-profile is on, so hitches can be traced to a specific event
-- (e.g. QUEST_LOG_UPDATE firing repeatedly on quest-item loot) without
-- relying on the client's built-in CPU profiler, which isn't reliable on
-- WoW Forever's beta client.
local function OnEvent(self, event, ...)
    if KrrlXPBarDB and KrrlXPBarDB.config and KrrlXPBarDB.config["debug-profile"] then
        local t0 = debugprofilestop()
        OnEventInner(self, event, ...)
        local dt = debugprofilestop() - t0
        if dt > DEBUG_PROFILE_THRESHOLD_MS then
            print(("|cffff5555Krrl XP Bar debug|r: %s took %.2fms"):format(event, dt))
        end
    else
        OnEventInner(self, event, ...)
    end
end

eventFrame:SetScript("OnEvent", OnEvent)

-- Recompute XP/hour, time-to-level, and session-time text once per second.
C_Timer.NewTicker(1, function()
    if KrrlXPBarDB then
        UpdateDisplay()
    end
end)

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_KRRLXPBAR1 = "/kxp"
SlashCmdList["KRRLXPBAR"] = function(msg)
    msg = (msg or ""):lower():trim()

    if CONFIG_DEFAULTS[msg] ~= nil then
        local cfg = GetConfig()
        cfg[msg] = not cfg[msg]
        UpdateDisplay()
        print(("|cff33ff99Krrl XP Bar|r: %s is now %s."):format(msg, tostring(cfg[msg])))
    else
        print("|cff33ff99Krrl XP Bar|r commands:")
        print("  Click and drag the bar to move it.")
        print("  /kxp <option>  - toggle: leveltime-text, sessiontime-text,")
        print("                   showxphour-text, questrested-text,")
        print("                   showincompletequest-bar, showmaxlevel,")
        print("                   reset_reload, hide_xpbar, debug-profile")
    end
end
