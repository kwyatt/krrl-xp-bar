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
      - Most toggles are slash-command only. Appearance (font, font size,
        bar texture, bar size) has an in-game options panel (right-click
        the bar with Ctrl held, or /kxp options).
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
    ["fontPath"]              = "Fonts\\FRIZQT__.TTF",
    ["fontSize"]              = 12,
    ["barTexture"]            = "Interface\\TargetingFrame\\UI-StatusBar",
    ["barWidth"]              = 600,
    ["barHeight"]             = 30,
    ["lock"]                  = false,
}

-- Typefaces and bar textures bundled with the WoW client, so these work on
-- any server/expansion without shipping asset files ourselves. The options
-- panel adds whatever other addons registered with LibSharedMedia.
local FONT_OPTIONS = {
    { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",  path = "Fonts\\ARIALN.TTF" },
    { name = "Skurri",        path = "Fonts\\SKURRI.TTF" },
    { name = "Morpheus",      path = "Fonts\\MORPHEUS.TTF" },
}

local TEXTURE_OPTIONS = {
    { name = "Blizzard", path = "Interface\\TargetingFrame\\UI-StatusBar" },
    { name = "Flat",     path = "Interface\\Buttons\\WHITE8x8" },
    { name = "Raid",     path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    { name = "Skills",   path = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
}

local FONT_SIZE_MIN, FONT_SIZE_MAX = 6, 32
local BAR_WIDTH_MIN = 100               -- max is the screen width
local BAR_HEIGHT_MIN, BAR_HEIGHT_MAX = 6, 80

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

local frame = CreateFrame("StatusBar", "KrrlXPBarFrame", UIParent, "BackdropTemplate")
frame:SetSize(CONFIG_DEFAULTS.barWidth, CONFIG_DEFAULTS.barHeight)
frame:SetPoint("TOP", UIParent, "TOP", 0, -4)
frame:SetStatusBarTexture(CONFIG_DEFAULTS.barTexture)
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
frame:SetScript("OnDragStart", function(self)
    if not GetConfig().lock then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    KrrlXPBarDB.point = { point, relPoint, x, y }
end)

local restedTex = frame:CreateTexture(nil, "ARTWORK")
restedTex.color = { 0.31, 0.56, 1, 0.55 }
restedTex:SetPoint("TOP", frame, "TOP")
restedTex:SetPoint("BOTTOM", frame, "BOTTOM")

local completeTex = frame:CreateTexture(nil, "ARTWORK")
completeTex.color = { 1, 0.59, 0, 0.9 }
completeTex:SetPoint("TOP", frame, "TOP")
completeTex:SetPoint("BOTTOM", frame, "BOTTOM")

local incompleteTex = frame:CreateTexture(nil, "ARTWORK")
incompleteTex.color = { 1, 0.82, 0.31, 0.6 }
incompleteTex:SetPoint("TOP", frame, "TOP")
incompleteTex:SetPoint("BOTTOM", frame, "BOTTOM")

local mainText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
mainText:SetPoint("CENTER", frame, "CENTER", 0, 0)

-- Always-visible XP/hour + time-to-level line, anchored just below the bar.
local xpHourText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
xpHourText:SetPoint("TOP", frame, "BOTTOM", 0, -2)

--------------------------------------------------------------------------
-- Appearance (font typeface / size, bar texture, bar size)
--------------------------------------------------------------------------

-- LibSharedMedia is optional and never bundled: when another addon has
-- loaded it (EllesmereUI, SharedMedia packs, ...), its registered fonts and
-- bar textures are offered alongside the built-ins.
local function GetLSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

local function NormalizePath(path)
    return (tostring(path):lower():gsub("/", "\\"))
end

-- Built-ins plus LSM media of lsmType, deduped by file path and sorted by
-- name. Rebuilt on every call so media registered late still shows up.
local function GetMediaOptions(builtins, lsmType)
    local list, seen = {}, {}
    local function add(name, path)
        local key = NormalizePath(path)
        if not seen[key] then
            seen[key] = true
            list[#list + 1] = { name = name, path = path }
        end
    end

    for _, opt in ipairs(builtins) do
        add(opt.name, opt.path)
    end
    local LSM = GetLSM()
    if LSM then
        for name, path in pairs(LSM:HashTable(lsmType) or {}) do
            if type(path) == "string" then add(name, path) end
        end
    end

    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function FontOptions() return GetMediaOptions(FONT_OPTIONS, "font") end
local function TextureOptions() return GetMediaOptions(TEXTURE_OPTIONS, "statusbar") end

-- Settings store the file path, not the LSM name, so they keep working when
-- LSM or the addon that registered the media isn't loaded. Falls back to
-- the file name when no list entry matches.
local function MediaName(list, path)
    local key = NormalizePath(path)
    for _, opt in ipairs(list) do
        if NormalizePath(opt.path) == key then return opt.name end
    end
    return tostring(path):match("([^\\/]+)$") or tostring(path)
end

-- Newer clients return false when the font file can't be loaded; older ones
-- return nothing, which is treated as success.
local function SetFontSafe(fontString, path, size, flags)
    if fontString:SetFont(path, size, flags or "") == false then
        fontString:SetFont(CONFIG_DEFAULTS.fontPath, size, flags or "")
    end
end

local function ApplyFont()
    local cfg = GetConfig()
    local path = cfg.fontPath or CONFIG_DEFAULTS.fontPath
    local size = cfg.fontSize or CONFIG_DEFAULTS.fontSize

    local _, _, mainFlags = mainText:GetFont()
    SetFontSafe(mainText, path, size, mainFlags)

    local _, _, hourFlags = xpHourText:GetFont()
    SetFontSafe(xpHourText, path, max(FONT_SIZE_MIN, size - 2), hourFlags)
end

-- The overlays use the same texture as the fill, tinted with their own
-- color, so a texture change restyles the whole bar consistently.
local function ApplyBarTexture()
    local path = GetConfig().barTexture or CONFIG_DEFAULTS.barTexture
    frame:SetStatusBarTexture(path)
    frame:SetStatusBarColor(0.34, 0.39, 1, 1)
    for _, overlay in ipairs({ restedTex, completeTex, incompleteTex }) do
        overlay:SetTexture(path)
        overlay:SetVertexColor(unpack(overlay.color))
    end
end

local function Clamp(v, lo, hi)
    return min(hi, max(lo, v))
end

-- The widest bar that still fits on screen, in UI units.
local function GetBarWidthMax()
    return floor(UIParent:GetWidth())
end

local function ApplyBarSize()
    local cfg = GetConfig()
    cfg.barWidth = Clamp(cfg.barWidth or CONFIG_DEFAULTS.barWidth, BAR_WIDTH_MIN, GetBarWidthMax())
    cfg.barHeight = Clamp(cfg.barHeight or CONFIG_DEFAULTS.barHeight, BAR_HEIGHT_MIN, BAR_HEIGHT_MAX)
    frame:SetSize(cfg.barWidth, cfg.barHeight)
end

local function SaveBarPoint()
    local point, _, relPoint, x, y = frame:GetPoint()
    KrrlXPBarDB.point = { point, relPoint, x, y }
end

--------------------------------------------------------------------------
-- Options panel
--
-- Every control is built from plain frames (Button, Slider, EditBox with
-- InputBoxTemplate) instead of UIDropDownMenu/OptionsSliderTemplate/scroll
-- templates, which newer clients have deprecated and the WoW Forever beta
-- client may not ship.
--------------------------------------------------------------------------

local optionsFrame   -- floating panel shell
local optionsContent -- the controls; hosted by optionsFrame or the Settings page
local RefreshOptionsFrame

local BOX_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}

-- Dropdown list: one shared frame, re-pointed at whichever dropdown opened
-- it. Type in the search box to filter; scroll with the wheel or scrollbar.
local LIST_ROWS, LIST_ROW_HEIGHT = 10, 20
local dropdownList

local function RefreshDropdownList()
    local list = dropdownList
    local spec = list.owner.spec

    local filter = list.search:GetText():lower()
    local items = {}
    for _, opt in ipairs(list.all) do
        if filter == "" or opt.name:lower():find(filter, 1, true) then
            items[#items + 1] = opt
        end
    end
    list.items = items

    local maxOffset = max(0, #items - LIST_ROWS)
    list.offset = Clamp(list.offset, 0, maxOffset)
    local current = NormalizePath(GetConfig()[spec.key] or "")

    for i, row in ipairs(list.rows) do
        local opt = items[list.offset + i]
        if opt then
            row.opt = opt
            if spec.kind == "font" then
                SetFontSafe(row.text, opt.path, 13)
                row.preview:Hide()
            else
                row.text:SetFontObject(GameFontHighlightSmall)
                row.preview:SetTexture(opt.path)
                row.preview:Show()
            end
            row.text:SetText(opt.name)
            if NormalizePath(opt.path) == current then
                row.text:SetTextColor(1, 0.82, 0)
            else
                row.text:SetTextColor(1, 1, 1)
            end
            row:Show()
        else
            row:Hide()
        end
    end

    list.updating = true
    list.scrollBar:SetMinMaxValues(0, maxOffset)
    list.scrollBar:SetValue(list.offset)
    list.updating = false
    list.scrollBar:SetShown(maxOffset > 0)
    list.empty:SetShown(#items == 0)
end

local function SelectDropdownItem(opt)
    local owner = dropdownList.owner
    GetConfig()[owner.spec.key] = opt.path
    owner.spec.onChange()
    owner:Refresh()
    dropdownList:Hide()
end

local function GetDropdownList()
    if dropdownList then return dropdownList end

    -- Parented to the options content so it hides along with whichever
    -- window is hosting the controls.
    local list = CreateFrame("Frame", nil, optionsContent, "BackdropTemplate")
    dropdownList = list
    list:SetHeight(LIST_ROWS * LIST_ROW_HEIGHT + 44)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetBackdrop(BOX_BACKDROP)
    list:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
    list:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    list:EnableMouse(true)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        self.offset = self.offset - delta * 3
        RefreshDropdownList()
    end)
    list:Hide()
    list.offset = 0

    -- Close on any click outside the list or its dropdown button.
    -- GLOBAL_MOUSE_DOWN doesn't exist on older clients, hence the pcalls.
    list:SetScript("OnShow", function(self) pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    list:SetScript("OnHide", function(self)
        pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN")
        self.search:ClearFocus()
    end)
    list:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then
            self:Hide()
        end
    end)

    list.search = CreateFrame("EditBox", nil, list, "InputBoxTemplate")
    list.search:SetHeight(20)
    list.search:SetPoint("TOPLEFT", 12, -8)
    list.search:SetPoint("TOPRIGHT", -8, -8)
    list.search:SetAutoFocus(false)
    list.search:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            list.offset = 0
            RefreshDropdownList()
        end
    end)
    list.search:SetScript("OnEnterPressed", function()
        if list.items and list.items[1] then SelectDropdownItem(list.items[1]) end
    end)
    list.search:SetScript("OnEscapePressed", function() list:Hide() end)

    local searchHint = list.search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", 2, 0)
    searchHint:SetText("Type to filter...")
    list.search:HookScript("OnTextChanged", function(self) searchHint:SetShown(self:GetText() == "") end)

    list.rows = {}
    for i = 1, LIST_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(LIST_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 6, -36 - (i - 1) * LIST_ROW_HEIGHT)
        row:SetPoint("RIGHT", list, "RIGHT", -22, 0)

        row.preview = row:CreateTexture(nil, "BACKGROUND")
        row.preview:SetPoint("TOPLEFT", 0, -2)
        row.preview:SetPoint("BOTTOMRIGHT", 0, 2)
        row.preview:SetVertexColor(0.34, 0.39, 1, 1)

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.15)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetPoint("RIGHT", -6, 0)
        row.text:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self) SelectDropdownItem(self.opt) end)
        list.rows[i] = row
    end

    local scrollBar = CreateFrame("Slider", nil, list, "BackdropTemplate")
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetWidth(10)
    scrollBar:SetPoint("TOPRIGHT", -6, -36)
    scrollBar:SetPoint("BOTTOMRIGHT", -6, 8)
    scrollBar:SetBackdrop(BOX_BACKDROP)
    scrollBar:SetBackdropColor(0, 0, 0, 0.6)
    scrollBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    scrollBar:SetThumbTexture("Interface\\Buttons\\WHITE8x8")
    scrollBar:GetThumbTexture():SetSize(8, 28)
    scrollBar:GetThumbTexture():SetVertexColor(0.6, 0.6, 0.6, 1)
    scrollBar:SetValueStep(1)
    scrollBar:SetScript("OnValueChanged", function(_, value)
        if list.updating then return end
        list.offset = floor(value + 0.5)
        RefreshDropdownList()
    end)
    list.scrollBar = scrollBar

    list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    list.empty:SetPoint("TOP", 0, -44)
    list.empty:SetText("No matches")

    return list
end

local function ToggleDropdownList(owner)
    local list = GetDropdownList()
    if list:IsShown() and list.owner == owner then
        list:Hide()
        return
    end

    list.owner = owner
    list.all = owner.spec.options()
    list.search:SetText("")

    -- Start scrolled so the current selection is in view.
    list.offset = 0
    local current = NormalizePath(GetConfig()[owner.spec.key] or "")
    for i, opt in ipairs(list.all) do
        if NormalizePath(opt.path) == current then
            list.offset = i - floor(LIST_ROWS / 2)
            break
        end
    end

    -- Re-assert the strata each time: reparenting the options content
    -- between hosts can reset it to the new host's.
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    list:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -2)
    list:Show()
    RefreshDropdownList()
    list.search:SetFocus()
end

-- spec: kind ("font" draws the current choice in its own typeface),
-- key (config key holding a file path), options (returns the list),
-- onChange (applies the new value).
local function CreateDropdown(parent, width, spec)
    local dropdown = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dropdown:SetSize(width, 24)
    dropdown:SetBackdrop(BOX_BACKDROP)
    dropdown:SetBackdropColor(0, 0, 0, 0.6)
    dropdown:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    dropdown.spec = spec

    dropdown.text = dropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dropdown.text:SetPoint("LEFT", 8, 0)
    dropdown.text:SetPoint("RIGHT", -26, 0)
    dropdown.text:SetJustifyH("LEFT")

    local arrow = dropdown:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetSize(22, 22)
    arrow:SetPoint("RIGHT", -2, 0)

    local highlight = dropdown:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    dropdown:SetScript("OnClick", ToggleDropdownList)

    function dropdown:Refresh()
        local path = GetConfig()[spec.key]
        if spec.kind == "font" then
            SetFontSafe(self.text, path, 13)
        end
        self.text:SetText(MediaName(spec.options(), path))
    end

    return dropdown
end

-- Slider plus a box you can type a number into, kept in sync. The mouse
-- wheel over the slider nudges the value by 1.
-- spec: key (numeric config key), min, max (number or function),
-- onChange (applies the new value).
local function CreateSliderRow(parent, width, spec)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width, 24)

    local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    box:SetSize(46, 20)
    box:SetPoint("RIGHT", -2, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(4)
    box:SetJustifyH("CENTER")

    local slider = CreateFrame("Slider", nil, row, "BackdropTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(17)
    slider:SetPoint("LEFT", 0, 0)
    slider:SetPoint("RIGHT", box, "LEFT", -14, 0)
    slider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:EnableMouseWheel(true)

    local function Bounds()
        local hi = type(spec.max) == "function" and spec.max() or spec.max
        return spec.min, hi
    end

    local function Set(value)
        local lo, hi = Bounds()
        GetConfig()[spec.key] = Clamp(floor(value + 0.5), lo, hi)
        spec.onChange()
    end

    function row:Refresh()
        local lo, hi = Bounds()
        local value = GetConfig()[spec.key]
        self.updating = true
        slider:SetMinMaxValues(lo, hi)
        slider:SetValue(value)
        self.updating = false
        if not box:HasFocus() then box:SetText(value) end
    end

    slider:SetScript("OnValueChanged", function(_, value)
        if row.updating then return end
        Set(value)
        row:Refresh()
    end)
    slider:SetScript("OnMouseWheel", function(_, delta)
        Set(GetConfig()[spec.key] + delta)
        row:Refresh()
    end)

    -- Typed values apply on Enter or when the box loses focus; Escape
    -- reverts to the current value.
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEscapePressed", function(self)
        self.cancelled = true
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", function(self)
        local n = tonumber(self:GetText())
        if n and not self.cancelled then Set(n) end
        self.cancelled = nil
        self:HighlightText(0, 0)
        self:SetText(GetConfig()[spec.key])
        row:Refresh()
    end)

    return row
end

-- Resize grip in the bar's bottom-right corner, shown while the options
-- panel is open.
local resizeGrip = CreateFrame("Button", nil, frame)
resizeGrip:SetSize(16, 16)
resizeGrip:SetPoint("BOTTOMRIGHT", -1, 1)
resizeGrip:SetFrameLevel(frame:GetFrameLevel() + 5)
resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
resizeGrip:Hide()

-- The grip is only offered while the options are on screen and the bar
-- isn't locked.
local function UpdateResizeGrip()
    resizeGrip:SetShown(optionsContent and optionsContent:IsVisible() and not GetConfig().lock)
end
frame:SetResizable(true)

resizeGrip:SetScript("OnMouseDown", function()
    local maxWidth = GetBarWidthMax()
    if frame.SetResizeBounds then
        frame:SetResizeBounds(BAR_WIDTH_MIN, BAR_HEIGHT_MIN, maxWidth, BAR_HEIGHT_MAX)
    else
        frame:SetMinResize(BAR_WIDTH_MIN, BAR_HEIGHT_MIN)
        frame:SetMaxResize(maxWidth, BAR_HEIGHT_MAX)
    end
    frame:StartSizing("BOTTOMRIGHT")
end)
resizeGrip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    local cfg = GetConfig()
    cfg.barWidth = floor(frame:GetWidth() + 0.5)
    cfg.barHeight = floor(frame:GetHeight() + 0.5)
    ApplyBarSize()
    SaveBarPoint()
    RefreshOptionsFrame()
end)

local APPEARANCE_KEYS = { "fontPath", "fontSize", "barTexture", "barWidth", "barHeight" }

local function ResetAppearance()
    local cfg = GetConfig()
    for _, key in ipairs(APPEARANCE_KEYS) do
        cfg[key] = CONFIG_DEFAULTS[key]
    end
    ApplyFont()
    ApplyBarTexture()
    ApplyBarSize()
    RefreshOptionsFrame()
end

function RefreshOptionsFrame()
    if not optionsContent then return end
    for _, control in ipairs(optionsContent.controls) do
        control:Refresh()
    end
    optionsContent.lockCheck:SetChecked(GetConfig().lock)
    optionsContent.lsmNote:SetText(GetLSM() and "" or "LibSharedMedia not loaded: built-in media only")
    UpdateResizeGrip()
end

local OPTIONS_WIDTH, OPTIONS_PAD = 320, 20

-- All controls live in one content frame that moves between two hosts: the
-- floating panel (Ctrl+Right-click, /kxp options) and the AddOns page of
-- Blizzard's settings window (Escape -> Options -> AddOns).
local function GetOptionsContent()
    if optionsContent then return optionsContent end

    optionsContent = CreateFrame("Frame", nil, UIParent)
    optionsContent:SetWidth(OPTIONS_WIDTH)
    optionsContent:Hide()
    optionsContent:SetScript("OnShow", UpdateResizeGrip)
    optionsContent:SetScript("OnHide", UpdateResizeGrip)

    local controlWidth = OPTIONS_WIDTH - 2 * OPTIONS_PAD
    local y = -4
    optionsContent.controls = {}

    local function AddRow(label, control)
        local text = optionsContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("TOPLEFT", OPTIONS_PAD, y)
        text:SetText(label)
        control:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -6)
        tinsert(optionsContent.controls, control)
        y = y - 54
    end

    AddRow("Font", CreateDropdown(optionsContent, controlWidth, {
        kind = "font", key = "fontPath", options = FontOptions, onChange = ApplyFont,
    }))
    AddRow("Font Size", CreateSliderRow(optionsContent, controlWidth, {
        key = "fontSize", min = FONT_SIZE_MIN, max = FONT_SIZE_MAX, onChange = ApplyFont,
    }))
    AddRow("Bar Texture", CreateDropdown(optionsContent, controlWidth, {
        kind = "texture", key = "barTexture", options = TextureOptions, onChange = ApplyBarTexture,
    }))
    AddRow("Bar Width", CreateSliderRow(optionsContent, controlWidth, {
        key = "barWidth", min = BAR_WIDTH_MIN, max = GetBarWidthMax, onChange = ApplyBarSize,
    }))
    AddRow("Bar Height", CreateSliderRow(optionsContent, controlWidth, {
        key = "barHeight", min = BAR_HEIGHT_MIN, max = BAR_HEIGHT_MAX, onChange = ApplyBarSize,
    }))

    local lockCheck = CreateFrame("CheckButton", nil, optionsContent, "UICheckButtonTemplate")
    lockCheck:SetSize(24, 24)
    lockCheck:SetPoint("TOPLEFT", OPTIONS_PAD - 4, y + 6)
    lockCheck:SetScript("OnClick", function(self)
        GetConfig().lock = self:GetChecked() and true or false
        UpdateResizeGrip()
    end)
    optionsContent.lockCheck = lockCheck

    local lockLabel = optionsContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lockLabel:SetPoint("LEFT", lockCheck, "RIGHT", 2, 0)
    lockLabel:SetText("Lock bar (no moving or resizing)")
    y = y - 26

    local hint = optionsContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", OPTIONS_PAD, y + 4)
    hint:SetPoint("RIGHT", -OPTIONS_PAD, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("While unlocked, you can also drag the grip in the bar's corner to resize it.")

    optionsContent.lsmNote = optionsContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    optionsContent.lsmNote:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
    y = y - 48

    local reset = CreateFrame("Button", nil, optionsContent, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("TOP", 0, y)
    reset:SetText("Reset to Defaults")
    reset:SetScript("OnClick", ResetAppearance)
    y = y - 22

    optionsContent:SetHeight(-y + 4)
    return optionsContent
end

local function AttachOptionsContent(host, x, y)
    local content = GetOptionsContent()
    if dropdownList then dropdownList:Hide() end
    content:SetParent(host)
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
    content:Show()
    RefreshOptionsFrame()
end

local OPTIONS_TITLE_HEIGHT = 46

local function GetOptionsFrame()
    if optionsFrame then return optionsFrame end

    optionsFrame = CreateFrame("Frame", "KrrlXPBarOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(OPTIONS_WIDTH, GetOptionsContent():GetHeight() + OPTIONS_TITLE_HEIGHT + 18)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    optionsFrame:SetMovable(true)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    optionsFrame:Hide()

    -- Lets Escape close the panel.
    tinsert(UISpecialFrames, "KrrlXPBarOptionsFrame")

    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Krrl XP Bar Options")

    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -6, -6)

    return optionsFrame
end

local function ToggleOptionsPanel()
    local panel = GetOptionsFrame()
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        AttachOptionsContent(panel, 0, -OPTIONS_TITLE_HEIGHT)
    end
end

-- Page in Escape -> Options -> AddOns. Uses the Settings API on current
-- clients and InterfaceOptions_AddCategory on older ones; if neither exists
-- the floating panel is still there.
local function RegisterSettingsPage()
    local page = CreateFrame("Frame")
    page.name = "Krrl XP Bar" -- read by InterfaceOptions_AddCategory
    page:Hide()

    local title = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Krrl XP Bar")

    local subtitle = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText("Ctrl+Right-click the bar or type /kxp options to open these settings in a floating window.")

    page:SetScript("OnShow", function(self)
        if optionsFrame then optionsFrame:Hide() end
        AttachOptionsContent(self, -4, -58)
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(page, page.name))
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(page)
    end
end

pcall(RegisterSettingsPage)

-- Ctrl+Right-click opens the options panel (plain right-click is too easy to
-- hit by accident); left-click-drag moves the bar unless it's locked.
frame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" and IsControlKeyDown() then
        ToggleOptionsPanel()
    end
end)

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
    GameTooltip:AddLine(GetConfig().lock and "Ctrl+Right-click for options (bar locked)"
        or "Drag to move. Ctrl+Right-click for options.", 0.5, 0.5, 0.5, true)
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

-- The quest/rested overlays are laid out from the bar's width, so re-run
-- the layout whenever the bar is resized (options panel or corner grip).
frame:SetScript("OnSizeChanged", function()
    if KrrlXPBarDB then UpdateDisplay() end
end)

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
        ApplyFont()
        ApplyBarTexture()
        ApplyBarSize()
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

    if msg == "options" or msg == "config" then
        ToggleOptionsPanel()
    elseif CONFIG_DEFAULTS[msg] ~= nil then
        local cfg = GetConfig()
        cfg[msg] = not cfg[msg]
        UpdateDisplay()
        RefreshOptionsFrame()
        print(("|cff33ff99Krrl XP Bar|r: %s is now %s."):format(msg, tostring(cfg[msg])))
    else
        print("|cff33ff99Krrl XP Bar|r commands:")
        print("  Drag the bar to move it. Ctrl+Right-click for options.")
        print("  /kxp options   - open the appearance options panel")
        print("  /kxp <option>  - toggle: leveltime-text, sessiontime-text,")
        print("                   showxphour-text, questrested-text,")
        print("                   showincompletequest-bar, showmaxlevel,")
        print("                   reset_reload, hide_xpbar, debug-profile,")
        print("                   lock (stop the bar moving/resizing)")
    end
end
