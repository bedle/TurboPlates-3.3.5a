local addonName, ns = ...

-- Death Knight rune widget for stock 3.3.5a / classless HERO clients.
-- This module intentionally stays independent of the nameplate reaction sensor.

local CreateFrame = CreateFrame
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitIsFriend = UnitIsFriend
local GetTime = GetTime
local GetRuneCooldown = GetRuneCooldown
local GetRuneType = GetRuneType
local CooldownFrame_SetTimer = CooldownFrame_SetTimer
local PixelUtil = PixelUtil
local type = type
local pcall = pcall
local math_min = math.min
local math_max = math.max

local HAS_RUNE_API = type(GetRuneCooldown) == "function" and type(GetRuneType) == "function"
local MAX_RUNES = 6

-- Blizzard 3.3.5 visual order. API slots 3/4 are Unholy and 5/6 are Frost;
-- the stock RuneFrame swaps them so the display is Blood, Frost, Unholy.
local DISPLAY_ORDER = { 1, 2, 5, 6, 3, 4 }

local RUNETYPE_BLOOD = 1
local RUNETYPE_UNHOLY = 2
local RUNETYPE_FROST = 3
local RUNETYPE_DEATH = 4

-- Stock 3.3.5 RuneFrame colors.
local RUNE_COLORS = {
    [RUNETYPE_BLOOD]  = { 1.00, 0.00, 0.00 },
    [RUNETYPE_UNHOLY] = { 0.00, 0.50, 0.00 },
    [RUNETYPE_FROST]  = { 0.00, 1.00, 1.00 },
    [RUNETYPE_DEATH]  = { 0.80, 0.10, 1.00 },
}

local ROUND_TEXTURE = "Interface\\AddOns\\TurboPlates\\Textures\\Circle_AlphaGradient_Out"
local WHITE_TEXTURE = "Interface\\Buttons\\WHITE8X8"

local lastTargetRunePlate = nil

local function IsRuneEligibleClass()
    local localized, token = UnitClass("player")
    if ns.NormalizeClassInfo then
        localized, token = ns.NormalizeClassInfo(localized, token)
    end
    if type(token) == "string" then
        token = string.upper(token)
    end
    if token == "DEATHKNIGHT" or token == "HERO" then
        return true
    end
    if type(localized) == "string" then
        local normalized = string.upper(localized)
        return normalized == "DEATHKNIGHT" or normalized == "DEATH KNIGHT" or normalized == "HERO"
    end
    return false
end

-- Some classless 3.3.5 cores expose the stock rune functions globally even when
-- the current HERO does not actually own a rune resource. Guard every probe so a
-- server-side compatibility quirk can never break nameplate rendering.
local function SafeGetRuneType(index)
    if not HAS_RUNE_API then return nil end
    local ok, runeType = pcall(GetRuneType, index)
    if ok then return runeType end
    return nil
end

local function SafeGetRuneCooldown(index)
    if not HAS_RUNE_API then return nil, nil, nil end
    local ok, start, duration, ready = pcall(GetRuneCooldown, index)
    if ok then return start, duration, ready end
    return nil, nil, nil
end

local function HasRuneData()
    if not HAS_RUNE_API or not IsRuneEligibleClass() then return false end
    -- GetRuneType is the most reliable capability signal: ordinary non-DK classes
    -- return no rune type, while HERO builds with a real rune resource expose it.
    for i = 1, MAX_RUNES do
        if SafeGetRuneType(i) then
            return true
        end
    end
    return false
end

local function StopSquareTicker(slot)
    if slot and slot.square then
        slot.square:SetScript("OnUpdate", nil)
        slot.square._runeElapsed = nil
    end
end

local function HideSlot(slot)
    if not slot then return end
    StopSquareTicker(slot)
    if slot.square then slot.square:Hide() end
    if slot.round then slot.round:Hide() end
    if slot.cooldown then
        if CooldownFrame_SetTimer then
            CooldownFrame_SetTimer(slot.cooldown, 0, 0, 0)
        end
        slot.cooldown:Hide()
    end
end

local function HideRuneWidget(plate)
    if not plate or not plate.runeContainer then return end
    if plate.runeSlots then
        for i = 1, MAX_RUNES do
            HideSlot(plate.runeSlots[i])
        end
    end
    plate.runeContainer:Hide()
end

local function CreateRuneWidget(plate)
    if plate.runeContainer then return end
    if not plate.hp then return end

    local container = CreateFrame("Frame", nil, plate)
    container:SetFrameLevel(plate:GetFrameLevel() + 15)
    container:EnableMouse(false)
    container:Hide()
    plate.runeContainer = container
    plate.runeSlots = {}

    for displayIndex = 1, MAX_RUNES do
        local holder = CreateFrame("Frame", nil, container)
        holder:EnableMouse(false)
        holder.runeIndex = DISPLAY_ORDER[displayIndex]
        holder.displayIndex = displayIndex

        -- Square style: a StatusBar fills from empty to ready over the rune cooldown.
        local square = CreateFrame("StatusBar", nil, holder)
        square:SetMinMaxValues(0, 1)
        square:SetValue(1)
        square:SetStatusBarTexture(WHITE_TEXTURE)
        square:EnableMouse(false)
        square:Hide()
        local squareBG = square:CreateTexture(nil, "BACKGROUND")
        squareBG:SetAllPoints(square)
        squareBG:SetTexture(WHITE_TEXTURE)
        square.bg = squareBG
        holder.square = square

        -- Rounded style: colored pip with Blizzard's native cooldown sweep.
        local round = holder:CreateTexture(nil, "ARTWORK", nil, 2)
        round:SetTexture(ROUND_TEXTURE)
        round:SetBlendMode("BLEND")
        round:Hide()
        holder.round = round

        local cooldown = CreateFrame("Cooldown", nil, holder)
        cooldown:SetFrameLevel(holder:GetFrameLevel() + 2)
        cooldown:EnableMouse(false)
        cooldown:Hide()
        holder.cooldown = cooldown

        plate.runeSlots[displayIndex] = holder
    end
end

local function ApplyRuneLayout(plate, isPersonal)
    CreateRuneWidget(plate)
    if not plate.runeContainer or not plate.runeSlots then return end

    local style = ns.c_runeStyle or 1
    local size = ns.c_runeSize or 12
    local offsetX = isPersonal and (ns.c_runePersonalX or 0) or (ns.c_runeX or 0)
    local offsetY = isPersonal and (ns.c_runePersonalY or 8) or (ns.c_runeY or 8)
    local spacing = (style == 2) and 3 or 4
    local height = (style == 2) and size or 4
    local totalWidth = (size * MAX_RUNES) + (spacing * (MAX_RUNES - 1))

    PixelUtil.SetSize(plate.runeContainer, totalWidth, height, 1, 1)
    plate.runeContainer:ClearAllPoints()
    PixelUtil.SetPoint(plate.runeContainer, "BOTTOM", plate.hp, "TOP", offsetX, -1 + offsetY, 1, 1)

    for i = 1, MAX_RUNES do
        local slot = plate.runeSlots[i]
        slot:ClearAllPoints()
        PixelUtil.SetSize(slot, size, height, 1, 1)
        slot:SetPoint("LEFT", plate.runeContainer, "LEFT", (i - 1) * (size + spacing), 0)

        slot.square:ClearAllPoints()
        slot.square:SetAllPoints(slot)
        slot.round:ClearAllPoints()
        slot.round:SetAllPoints(slot)
        slot.cooldown:ClearAllPoints()
        slot.cooldown:SetAllPoints(slot)
    end

    plate.runeContainer:Show()
end

local function SetSquareCooldown(slot, start, duration, runeReady)
    local bar = slot.square
    if runeReady then
        StopSquareTicker(slot)
        bar:SetValue(1)
        bar:SetAlpha(1)
        return
    end

    local now = GetTime()
    local progress = 0
    if start and duration and duration > 0 then
        progress = math_min(1, math_max(0, (now - start) / duration))
    end
    bar:SetValue(progress)
    bar:SetAlpha(0.75)
    bar._runeStart = start or 0
    bar._runeDuration = duration or 0
    bar._runeElapsed = 0

    bar:SetScript("OnUpdate", function(self, elapsed)
        self._runeElapsed = (self._runeElapsed or 0) + elapsed
        if self._runeElapsed < 0.05 then return end
        self._runeElapsed = 0
        local dur = self._runeDuration or 0
        if dur <= 0 then
            self:SetValue(0)
            return
        end
        local p = (GetTime() - (self._runeStart or 0)) / dur
        if p >= 1 then
            self:SetValue(1)
            self:SetAlpha(1)
            self:SetScript("OnUpdate", nil)
        else
            self:SetValue(math_max(0, p))
        end
    end)
end

local function UpdateRuneSlot(slot, style)
    local runeIndex = slot.runeIndex
    local runeType = SafeGetRuneType(runeIndex)
    if not runeType then
        HideSlot(slot)
        return false
    end

    local color = RUNE_COLORS[runeType] or RUNE_COLORS[RUNETYPE_DEATH]
    local start, duration, runeReady = SafeGetRuneCooldown(runeIndex)

    if style == 2 then
        StopSquareTicker(slot)
        slot.square:Hide()
        slot.round:SetVertexColor(color[1], color[2], color[3])
        slot.round:SetAlpha(runeReady and 1 or 0.55)
        slot.round:Show()

        if not runeReady and start and duration and duration > 0 and CooldownFrame_SetTimer then
            CooldownFrame_SetTimer(slot.cooldown, start, duration, 1)
            slot.cooldown:Show()
        else
            if CooldownFrame_SetTimer then
                CooldownFrame_SetTimer(slot.cooldown, 0, 0, 0)
            end
            slot.cooldown:Hide()
        end
    else
        slot.round:Hide()
        if CooldownFrame_SetTimer then
            CooldownFrame_SetTimer(slot.cooldown, 0, 0, 0)
        end
        slot.cooldown:Hide()

        slot.square:SetStatusBarColor(color[1], color[2], color[3])
        slot.square.bg:SetVertexColor(color[1], color[2], color[3], 0.22)
        slot.square:Show()
        SetSquareCooldown(slot, start, duration, runeReady)
    end

    return true
end

local function UpdatePlateRunes(plate, isPersonal)
    if not plate or not plate.hp then return end
    ApplyRuneLayout(plate, isPersonal)
    local style = ns.c_runeStyle or 1
    local anyVisible = false
    for i = 1, MAX_RUNES do
        if UpdateRuneSlot(plate.runeSlots[i], style) then
            anyVisible = true
        end
    end
    if anyVisible then
        plate.runeContainer:Show()
    else
        HideRuneWidget(plate)
    end
end

function ns:CleanupPlateRunes(plate)
    if not plate then return end
    HideRuneWidget(plate)
    if lastTargetRunePlate == plate then
        lastTargetRunePlate = nil
    end
end

function ns:CleanupTargetRunes()
    if lastTargetRunePlate then HideRuneWidget(lastTargetRunePlate) end
    if ns.currentTargetPlate and ns.currentTargetPlate ~= lastTargetRunePlate then
        HideRuneWidget(ns.currentTargetPlate)
    end
    lastTargetRunePlate = nil
end

function ns:CleanupPersonalRunes()
    local plate = ns.GetPersonalPlateRef and ns:GetPersonalPlateRef() or nil
    if plate then HideRuneWidget(plate) end
end

function ns:UpdateRunes()
    -- Always clear a stale target widget first when the target plate identity changed.
    if lastTargetRunePlate and lastTargetRunePlate ~= ns.currentTargetPlate then
        HideRuneWidget(lastTargetRunePlate)
        lastTargetRunePlate = nil
    end

    if not ns.c_showRunes or not HasRuneData() then
        ns:CleanupTargetRunes()
        ns:CleanupPersonalRunes()
        return
    end

    if ns.c_runesOnPersonalBar then
        ns:CleanupTargetRunes()
        local personalPlate = ns.GetPersonalPlateRef and ns:GetPersonalPlateRef() or nil
        if personalPlate and ns.c_personalEnabled then
            UpdatePlateRunes(personalPlate, true)
        else
            ns:CleanupPersonalRunes()
        end
        return
    end

    -- Target-nameplate mode. Match Combo Points behavior: don't draw resources on
    -- a friendly target plate.
    ns:CleanupPersonalRunes()
    local plate = ns.currentTargetPlate
    if plate and UnitExists("target") and not UnitIsFriend("player", "target") then
        lastTargetRunePlate = plate
        UpdatePlateRunes(plate, false)
    else
        ns:CleanupTargetRunes()
    end
end

-- Standalone event watcher: rune events refresh only the rune widget, never the
-- whole nameplate. This avoids target glow/scale churn on every rune spend.
local eventFrame = CreateFrame("Frame")
if HAS_RUNE_API then
    eventFrame:RegisterEvent("RUNE_POWER_UPDATE")
    eventFrame:RegisterEvent("RUNE_TYPE_UPDATE")
end
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")

local runeUpdateQueued = false
local function ScheduleRuneUpdate()
    if runeUpdateQueued then return end
    runeUpdateQueued = true
    local function run()
        runeUpdateQueued = false
        ns:UpdateRunes()
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, run)
    else
        run()
    end
end

eventFrame:SetScript("OnEvent", function()
    -- Spending one rune can emit several power/type events in the same rendered
    -- frame. Coalesce them so the six-slot widget is laid out/refreshed once.
    -- The next-frame scheduling also preserves the old target-change ordering
    -- guarantee versus Nameplates.lua.
    ScheduleRuneUpdate()
end)
