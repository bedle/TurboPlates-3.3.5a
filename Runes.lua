local addonName, ns = ...


local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitIsFriend = UnitIsFriend
local GetTime = GetTime
local GetRuneCooldown = GetRuneCooldown
local GetRuneType = GetRuneType
local CooldownFrame_SetTimer = CooldownFrame_SetTimer
local PixelUtil = PixelUtil
local C_NamePlate = C_NamePlate
local type = type
local pcall = pcall
local math_min = math.min
local math_max = math.max

local HAS_RUNE_API = type(GetRuneCooldown) == "function" and type(GetRuneType) == "function"
local MAX_RUNES = 6
local DISPLAY_ORDER = { 1, 2, 5, 6, 3, 4 }

local RUNETYPE_BLOOD, RUNETYPE_UNHOLY, RUNETYPE_FROST, RUNETYPE_DEATH = 1, 2, 3, 4
local RUNE_COLORS = {
    [RUNETYPE_BLOOD]  = { 1.00, 0.00, 0.00 },
    [RUNETYPE_UNHOLY] = { 0.00, 0.50, 0.00 },
    [RUNETYPE_FROST]  = { 0.00, 1.00, 1.00 },
    [RUNETYPE_DEATH]  = { 0.80, 0.10, 1.00 },
}

local ROUND_TEXTURE = "Interface\\AddOns\\TurboPlates\\Textures\\Circle_AlphaGradient_Out"
local WHITE_TEXTURE = "Interface\\Buttons\\WHITE8X8"

local runeState, runeStateInitialized = {}, false
for i = 1, MAX_RUNES do runeState[i] = { runeIndex = i } end

local lastTargetRunePlate
local StartRuneBootstrapWatch

local function SafeGetRuneType(index)
    if not HAS_RUNE_API then return nil end
    local ok, value = pcall(GetRuneType, index)
    return ok and value or nil
end

local function SafeGetRuneCooldown(index)
    if not HAS_RUNE_API then return nil, nil, nil end
    local ok, start, duration, ready = pcall(GetRuneCooldown, index)
    if ok then return start, duration, ready end
    return nil, nil, nil
end

local function FallbackRuneType(index)
    if index <= 2 then return RUNETYPE_BLOOD end
    if index <= 4 then return RUNETYPE_UNHOLY end
    return RUNETYPE_FROST
end

local function RefreshRuneSlotState(index)
    if not HAS_RUNE_API or not index or index < 1 or index > MAX_RUNES then return false end
    local state = runeState[index]
    local runeType = SafeGetRuneType(index)
    local start, duration, ready = SafeGetRuneCooldown(index)
    local valid = runeType ~= nil or start ~= nil or duration ~= nil or ready ~= nil
    if not valid then return false end

    state.runeType = runeType or state.runeType or FallbackRuneType(index)
    if start ~= nil then state.start = start end
    if duration ~= nil then state.duration = duration end
    if ready ~= nil then state.ready = ready and true or false end
    runeStateInitialized = true
    return true
end

local function RefreshAllRuneState()
    if not HAS_RUNE_API then runeStateInitialized = false return false end
    local any = false
    for i = 1, MAX_RUNES do
        if RefreshRuneSlotState(i) then any = true end
    end
    return any or runeStateInitialized
end

local squareTicker = CreateFrame("Frame")
local activeSquareSlots = {}
squareTicker:Hide()
squareTicker:SetScript("OnUpdate", function(self)
    local now = GetTime()
    local anyActive = false
    for slot in pairs(activeSquareSlots) do
        local bar = slot and slot.square
        if not bar or not bar:IsShown() or not slot._cooling then
            activeSquareSlots[slot] = nil
        else
            local dur = slot._runeDuration or 0
            if dur <= 0 then
                bar:SetValue(0)
                activeSquareSlots[slot] = nil
                slot._cooling = nil
            else
                local p = (now - (slot._runeStart or 0)) / dur
                if p >= 1 then
                    bar:SetValue(1)
                    bar:SetAlpha(1)
                    activeSquareSlots[slot] = nil
                    slot._cooling = nil
                else
                    bar:SetValue(math_max(0, p))
                    anyActive = true
                end
            end
        end
    end
    if not anyActive and not next(activeSquareSlots) then self:Hide() end
end)

local function StopSquareTicker(slot)
    if not slot then return end
    activeSquareSlots[slot] = nil
    slot._cooling = nil
end

local function HideSlot(slot)
    if not slot then return end
    StopSquareTicker(slot)
    if slot.square then slot.square:Hide() end
    if slot.round then slot.round:Hide() end
    if slot.cooldown then
        if CooldownFrame_SetTimer then CooldownFrame_SetTimer(slot.cooldown, 0, 0, 0) end
        slot.cooldown:Hide()
        slot._cdStart, slot._cdDuration = nil, nil
    end
end

local function HideRuneWidget(plate)
    if not plate or not plate.runeContainer then return end
    if plate.runeSlots then
        for i = 1, MAX_RUNES do HideSlot(plate.runeSlots[i]) end
    end
    plate.runeContainer:Hide()
end

local function CreateRuneWidget(plate)
    if plate.runeContainer or not plate.hp then return end
    local container = CreateFrame("Frame", nil, plate)
    container:SetFrameLevel(plate:GetFrameLevel() + 15)
    container:EnableMouse(false)
    container:Hide()
    plate.runeContainer, plate.runeSlots, plate.runeSlotsByRune = container, {}, {}

    for displayIndex = 1, MAX_RUNES do
        local holder = CreateFrame("Frame", nil, container)
        holder:EnableMouse(false)
        holder.runeIndex, holder.displayIndex = DISPLAY_ORDER[displayIndex], displayIndex

        local square = CreateFrame("StatusBar", nil, holder)
        square:SetMinMaxValues(0, 1); square:SetValue(1); square:SetStatusBarTexture(WHITE_TEXTURE)
        square:EnableMouse(false); square:Hide()
        local bg = square:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(square); bg:SetTexture(WHITE_TEXTURE); square.bg = bg
        holder.square = square

        local round = holder:CreateTexture(nil, "ARTWORK", nil, 2)
        round:SetTexture(ROUND_TEXTURE); round:SetBlendMode("BLEND"); round:Hide(); holder.round = round

        local cooldown = CreateFrame("Cooldown", nil, holder)
        cooldown:SetFrameLevel(holder:GetFrameLevel() + 2); cooldown:EnableMouse(false); cooldown:Hide(); holder.cooldown = cooldown

        plate.runeSlots[displayIndex] = holder
        plate.runeSlotsByRune[holder.runeIndex] = holder
    end
end

local function ApplyRuneLayout(plate, isPersonal, force)
    CreateRuneWidget(plate)
    if not plate.runeContainer or not plate.runeSlots then return end
    local style, size = ns.c_runeStyle or 1, ns.c_runeSize or 12
    local x = isPersonal and (ns.c_runePersonalX or 0) or (ns.c_runeX or 0)
    local y = isPersonal and (ns.c_runePersonalY or 8) or (ns.c_runeY or 8)
    local signature = table.concat({style, size, x, y, isPersonal and 1 or 0}, ":")
    if not force and plate._runeLayoutSignature == signature then return end
    plate._runeLayoutSignature = signature

    local spacing = style == 2 and 3 or 4
    local height = style == 2 and size or 4
    local totalWidth = size * MAX_RUNES + spacing * (MAX_RUNES - 1)
    PixelUtil.SetSize(plate.runeContainer, totalWidth, height, 1, 1)
    plate.runeContainer:ClearAllPoints()
    PixelUtil.SetPoint(plate.runeContainer, "BOTTOM", plate.hp, "TOP", x, -1 + y, 1, 1)
    for i = 1, MAX_RUNES do
        local slot = plate.runeSlots[i]
        slot:ClearAllPoints(); PixelUtil.SetSize(slot, size, height, 1, 1)
        slot:SetPoint("LEFT", plate.runeContainer, "LEFT", (i - 1) * (size + spacing), 0)
        slot.square:ClearAllPoints(); slot.square:SetAllPoints(slot)
        slot.round:ClearAllPoints(); slot.round:SetAllPoints(slot)
        slot.cooldown:ClearAllPoints(); slot.cooldown:SetAllPoints(slot)
    end
end

local function SetSquareCooldown(slot, start, duration, ready)
    local bar = slot.square
    if ready then
        StopSquareTicker(slot); bar:SetValue(1); bar:SetAlpha(1)
        slot._runeStart, slot._runeDuration = start, duration
        return
    end

    if slot._cooling and slot._runeStart == start and slot._runeDuration == duration then return end
    slot._runeStart, slot._runeDuration, slot._cooling = start or 0, duration or 0, true
    bar:SetAlpha(0.75)
    local dur = duration or 0
    if dur > 0 then
        bar:SetValue(math_min(1, math_max(0, (GetTime() - (start or 0)) / dur)))
        activeSquareSlots[slot] = true
        squareTicker:Show()
    else
        bar:SetValue(0)
        activeSquareSlots[slot] = nil
    end
end

local function UpdateRuneSlot(slot, style)
    local state = runeState[slot.runeIndex]
    local runeType = state and state.runeType
    if not runeType then HideSlot(slot) return false end
    local color = RUNE_COLORS[runeType] or RUNE_COLORS[RUNETYPE_DEATH]
    local start, duration, ready = state.start, state.duration, state.ready

    if style == 2 then
        StopSquareTicker(slot); slot.square:Hide()
        slot.round:SetVertexColor(color[1], color[2], color[3]); slot.round:SetAlpha(ready and 1 or 0.55); slot.round:Show()
        if not ready and start and duration and duration > 0 and CooldownFrame_SetTimer then
            if slot._cdStart ~= start or slot._cdDuration ~= duration then
                CooldownFrame_SetTimer(slot.cooldown, start, duration, 1)
                slot._cdStart, slot._cdDuration = start, duration
            end
            slot.cooldown:Show()
        else
            if slot.cooldown:IsShown() and CooldownFrame_SetTimer then CooldownFrame_SetTimer(slot.cooldown, 0, 0, 0) end
            slot.cooldown:Hide(); slot._cdStart, slot._cdDuration = nil, nil
        end
    else
        slot.round:Hide()
        if slot.cooldown:IsShown() and CooldownFrame_SetTimer then CooldownFrame_SetTimer(slot.cooldown, 0, 0, 0) end
        slot.cooldown:Hide(); slot._cdStart, slot._cdDuration = nil, nil
        slot.square:SetStatusBarColor(color[1], color[2], color[3]); slot.square.bg:SetVertexColor(color[1], color[2], color[3], 0.22)
        slot.square:Show(); SetSquareCooldown(slot, start, duration, ready)
    end
    return true
end

local function RenderAllRunes(plate, isPersonal, forceLayout)
    if not plate or not plate.hp then return end
    ApplyRuneLayout(plate, isPersonal, forceLayout)
    local style, any = ns.c_runeStyle or 1, false
    for i = 1, MAX_RUNES do if UpdateRuneSlot(plate.runeSlots[i], style) then any = true end end
    if any then plate.runeContainer:Show() else HideRuneWidget(plate) end
end

local function RenderRuneIndex(plate, runeIndex)
    if not plate or not plate.runeSlotsByRune then return end
    local slot = plate.runeSlotsByRune[runeIndex]
    if slot then UpdateRuneSlot(slot, ns.c_runeStyle or 1) end
end

function ns:CleanupPlateRunes(plate)
    if not plate then return end
    HideRuneWidget(plate)
    if lastTargetRunePlate == plate then lastTargetRunePlate = nil end
end
function ns:CleanupTargetRunes()
    if lastTargetRunePlate then HideRuneWidget(lastTargetRunePlate) end
    if ns.currentTargetPlate and ns.currentTargetPlate ~= lastTargetRunePlate then HideRuneWidget(ns.currentTargetPlate) end
    lastTargetRunePlate = nil
end
function ns:CleanupPersonalRunes()
    local plate = ns.GetPersonalPlateRef and ns:GetPersonalPlateRef() or nil
    if plate then HideRuneWidget(plate) end
end

local function ResolveTargetRunePlate()
    if not UnitExists("target") then return nil end
    local plate = ns.currentTargetPlate
    if plate and plate.hp and not plate.isFriendly then return plate end
end

function ns:UpdateRunes(forceLayout)
    local targetPlate = not ns.c_runesOnPersonalBar and ResolveTargetRunePlate() or nil
    if lastTargetRunePlate and lastTargetRunePlate ~= targetPlate then HideRuneWidget(lastTargetRunePlate); lastTargetRunePlate = nil end
    if not ns.c_showRunes then ns:CleanupTargetRunes(); ns:CleanupPersonalRunes(); return end
    if not RefreshAllRuneState() then
        ns:CleanupTargetRunes(); ns:CleanupPersonalRunes(); if StartRuneBootstrapWatch then StartRuneBootstrapWatch() end; return
    end

    if ns.c_runesOnPersonalBar then
        ns:CleanupTargetRunes()
        local personal = ns.GetPersonalPlateRef and ns:GetPersonalPlateRef() or nil
        if personal and ns.c_personalEnabled then RenderAllRunes(personal, true, forceLayout) else ns:CleanupPersonalRunes() end
        return
    end

    ns:CleanupPersonalRunes()
    if targetPlate then
        lastTargetRunePlate = targetPlate; RenderAllRunes(targetPlate, false, forceLayout)
    else
        ns:CleanupTargetRunes()
    end
end

local function UpdateSingleRune(runeIndex)
    runeIndex = tonumber(runeIndex)
    if not ns.c_showRunes or not runeIndex or runeIndex < 1 or runeIndex > MAX_RUNES then return end
    if not RefreshRuneSlotState(runeIndex) then return end
    local plate
    if ns.c_runesOnPersonalBar then
        plate = ns.GetPersonalPlateRef and ns:GetPersonalPlateRef() or nil
    else
        plate = ResolveTargetRunePlate()
    end
    if plate and plate.runeContainer and plate.runeContainer:IsShown() then RenderRuneIndex(plate, runeIndex) end
end

local eventFrame = CreateFrame("Frame")
if HAS_RUNE_API then eventFrame:RegisterEvent("RUNE_POWER_UPDATE"); eventFrame:RegisterEvent("RUNE_TYPE_UPDATE") end
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_ALIVE"); eventFrame:RegisterEvent("PLAYER_UNGHOST")

local fullUpdateQueued = false
local function ScheduleFullRuneUpdate(forceLayout)
    if fullUpdateQueued then return end
    fullUpdateQueued = true
    C_Timer.After(0, function() fullUpdateQueued = false; ns:UpdateRunes(forceLayout) end)
end

local bootstrap = CreateFrame("Frame")
local bootstrapElapsed, bootstrapTotal = 0, 0
StartRuneBootstrapWatch = function()
    if bootstrap._active or not ns.c_showRunes or runeStateInitialized then return end
    bootstrapElapsed, bootstrapTotal, bootstrap._active = 0, 0, true
    bootstrap:SetScript("OnUpdate", function(self, elapsed)
        bootstrapElapsed, bootstrapTotal = bootstrapElapsed + elapsed, bootstrapTotal + elapsed
        if bootstrapElapsed < 0.10 then return end
        bootstrapElapsed = 0
        if not ns.c_showRunes then self._active=nil; self:SetScript("OnUpdate",nil); return end
        if RefreshAllRuneState() then self._active=nil; self:SetScript("OnUpdate",nil); ns:UpdateRunes(true); return end
        if bootstrapTotal >= 3 then self._active=nil; self:SetScript("OnUpdate",nil) end
    end)
end

eventFrame:SetScript("OnEvent", function(self, event, runeIndex)
    if event == "RUNE_POWER_UPDATE" or event == "RUNE_TYPE_UPDATE" then
        if tonumber(runeIndex) then UpdateSingleRune(runeIndex) else ScheduleFullRuneUpdate(false) end
        return
    end
    ScheduleFullRuneUpdate(event == "PLAYER_ENTERING_WORLD")
end)
