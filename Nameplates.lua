local addonName, ns = ...

-- Event-driven nameplate system - no OnUpdate polling

-- Cached globals.
-- Unit API routed through the WotLK compat wrappers (ns.UnitX) so plate tokens
-- resolve; NEVER assign these back to the real globals (that taints Blizzard's
-- secure code). Falls back to the real global on a native engine.
local UnitHealth = ns.UnitHealth or UnitHealth
local UnitHealthMax = ns.UnitHealthMax or UnitHealthMax
local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
local UnitExists = ns.UnitExists or UnitExists
local UnitName = ns.UnitName or UnitName
local UnitClass = ns.UnitClass or UnitClass
local UnitLevel = ns.UnitLevel or UnitLevel
local UnitIsPlayer = ns.UnitIsPlayer or UnitIsPlayer
local UnitIsFriend = ns.UnitIsFriend or UnitIsFriend
local UnitIsUnit = ns.UnitIsUnit or UnitIsUnit
local UnitReaction = ns.UnitReaction or UnitReaction
local UnitThreatSituation = UnitThreatSituation
local UnitDetailedThreatSituation = ns.UnitDetailedThreatSituation or UnitDetailedThreatSituation
local UnitGUID = ns.UnitGUID or UnitGUID
local UnitBuff = ns.UnitBuff or UnitBuff
local UnitDebuff = ns.UnitDebuff or UnitDebuff
local UnitIsPet = ns.UnitIsPet or UnitIsPet
local UnitPlayerControlled = ns.UnitPlayerControlled or UnitPlayerControlled
local UnitCreatureType = ns.UnitCreatureType or UnitCreatureType
local GetComboPoints = GetComboPoints
local GetRaidTargetIndex = ns.GetRaidTargetIndex or GetRaidTargetIndex
local SetRaidTargetIconTexture = SetRaidTargetIconTexture
local SetRaidTarget = SetRaidTarget
local GetTime = GetTime
local GetSpellInfo = GetSpellInfo
local IsInRaid = IsInRaid
local IsInGroup = IsInGroup
local GetNumGroupMembers = GetNumGroupMembers
local CreateFrame = CreateFrame
local UnitIsTapped = ns.UnitIsTapped or UnitIsTapped
local UnitIsTappedByPlayer = ns.UnitIsTappedByPlayer or UnitIsTappedByPlayer
local UnitClassification = ns.UnitClassification or UnitClassification
local UnitGroupRolesAssignedKey = UnitGroupRolesAssignedKey
local UnitPower = ns.UnitPower or UnitPower
local UnitPowerType = ns.UnitPowerType or UnitPowerType
local UnitPowerMax = ns.UnitPowerMax or UnitPowerMax
local SetCVar = SetCVar
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local math_max = math.max
local floor = math.floor
local ceil = math.ceil
local format = string.format
local strsub = string.sub
local strmatch = string.match
local gmatch = string.gmatch
local gsub = string.gsub

-- Name formatting functions
local function SplitNameWords(name)
    local normalized = name
        :gsub("\194\160", " ")
        :gsub("\226\128\175", " ")
        :gsub("\226\128\135", " ")
        :gsub("\227\128\128", " ")

    local words = {}
    for word in gmatch(normalized, "%S+") do
        words[#words + 1] = word
    end
    return words
end

local function FirstUTF8Character(text)
    if not text or text == "" then return "" end
    if string.utf8sub then return string.utf8sub(text, 1, 1) end

    local b = text:byte(1)
    local bytes = 1
    if b and b >= 240 then
        bytes = 4
    elseif b and b >= 224 then
        bytes = 3
    elseif b and b >= 192 then
        bytes = 2
    end
    return strsub(text, 1, bytes)
end

-- Abbreviate: "Shadowfury Witch Doctor" -> "S. W. Doctor"
local function AbbreviateName(name)
    local words = SplitNameWords(name)
    if #words <= 1 then return name end

    local abbreviated = {}
    for i = 1, #words - 1 do
        local first = FirstUTF8Character(words[i])
        if first ~= "" then abbreviated[#abbreviated + 1] = first .. "." end
    end
    abbreviated[#abbreviated + 1] = words[#words]
    return table.concat(abbreviated, " ")
end

-- Get first word: "Shadowfury Witch Doctor" -> "Shadowfury"
local function FirstName(name)
    local words = SplitNameWords(name)
    return words[1] or name
end

-- Get last word: "Shadowfury Witch Doctor" -> "Doctor"
local function LastName(name)
    local words = SplitNameWords(name)
    return words[#words] or name
end

function ns:FormatName(name)
    if not name or name == "" then return name end
    local fmt = ns.c_nameDisplayFormat or "none"
    if fmt == "abbreviate" then
        return AbbreviateName(name)
    elseif fmt == "first" then
        return FirstName(name)
    elseif fmt == "last" then
        return LastName(name)
    end
    return name
end

local C_NamePlate = C_NamePlate
local C_NamePlate_GetNamePlateForUnit = C_NamePlate.GetNamePlateForUnit

local C_NamePlateManager = C_NamePlateManager
local C_NamePlateManager_EnumerateActiveNamePlates = C_NamePlateManager.EnumerateActiveNamePlates
local C_NamePlateManager_GetNamePlateSize = C_NamePlateManager.GetNamePlateSize

local C_Timer = C_Timer
local C_Timer_After = C_Timer.After

local PixelUtil = PixelUtil

local db

-- Forward declarations for throttle tables (defined later, needed for zone cleanup)
local dirtyHealth, dirtyThreat, dirtyAbsorb

-- =============================================================================
-- SHARED TEXTURE BORDER SYSTEM
-- Uses 4 separate textures (top, bottom, left, right) for pixel-perfect borders
-- =============================================================================
local BORDER_TEX = "Interface\\Buttons\\WHITE8X8"
local BORDER_ALPHA = 0.6  -- Prevents 1px dropout in 3.3.5

-- Shared border methods
local BorderMethods = {}
BorderMethods.__index = BorderMethods

function BorderMethods:SetColor(r, g, b, a, forceAlpha)
    -- Clamp alpha to BORDER_ALPHA max to maintain anti-dropout behavior (unless forced)
    if not forceAlpha then
        a = a and math.min(a, BORDER_ALPHA) or BORDER_ALPHA
    end
    self.top:SetVertexColor(r, g, b, a or 1)
    self.bottom:SetVertexColor(r, g, b, a or 1)
    self.left:SetVertexColor(r, g, b, a or 1)
    self.right:SetVertexColor(r, g, b, a or 1)
end

function BorderMethods:Show()
    self.top:Show()
    self.bottom:Show()
    self.left:Show()
    self.right:Show()
end

function BorderMethods:Hide()
    self.top:Hide()
    self.bottom:Hide()
    self.left:Hide()
    self.right:Hide()
end

function BorderMethods:GetColor()
    return self.top:GetVertexColor()
end

function BorderMethods:UpdateScale(parent, thickness)
    thickness = thickness or 1
    local pixelSize = PixelUtil.GetNearestPixelSize(thickness, parent:GetEffectiveScale(), 1)

    -- Update top edge
    self.top:ClearAllPoints()
    self.top:SetPoint("TOPLEFT", parent, "TOPLEFT", -pixelSize, pixelSize)
    self.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", pixelSize, pixelSize)
    PixelUtil.SetHeight(self.top, pixelSize, 1)

    -- Update bottom edge
    self.bottom:ClearAllPoints()
    self.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -pixelSize, -pixelSize)
    self.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", pixelSize, -pixelSize)
    PixelUtil.SetHeight(self.bottom, pixelSize, 1)

    -- Update left edge
    self.left:ClearAllPoints()
    self.left:SetPoint("TOPLEFT", parent, "TOPLEFT", -pixelSize, 0)
    self.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -pixelSize, 0)
    PixelUtil.SetWidth(self.left, pixelSize, 1)

    -- Update right edge
    self.right:ClearAllPoints()
    self.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", pixelSize, 0)
    self.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", pixelSize, 0)
    PixelUtil.SetWidth(self.right, pixelSize, 1)
end

-- Create pixel-perfect texture-based border
local function CreateTextureBorder(parent, thickness)
    thickness = thickness or 1
    local pixelSize = PixelUtil.GetNearestPixelSize(thickness, parent:GetEffectiveScale(), 1)

    local border = setmetatable({}, BorderMethods)

    -- Use OVERLAY layer so borders render ABOVE StatusBar fill texture (ARTWORK layer)
    -- Top edge
    border.top = parent:CreateTexture(nil, "OVERLAY")
    border.top:SetTexture(BORDER_TEX)
    border.top:SetPoint("TOPLEFT", parent, "TOPLEFT", -pixelSize, pixelSize)
    border.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", pixelSize, pixelSize)
    PixelUtil.SetHeight(border.top, pixelSize, 1)

    -- Bottom edge
    border.bottom = parent:CreateTexture(nil, "OVERLAY")
    border.bottom:SetTexture(BORDER_TEX)
    border.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -pixelSize, -pixelSize)
    border.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", pixelSize, -pixelSize)
    PixelUtil.SetHeight(border.bottom, pixelSize, 1)

    -- Left edge
    border.left = parent:CreateTexture(nil, "OVERLAY")
    border.left:SetTexture(BORDER_TEX)
    border.left:SetPoint("TOPLEFT", parent, "TOPLEFT", -pixelSize, 0)
    border.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -pixelSize, 0)
    PixelUtil.SetWidth(border.left, pixelSize, 1)

    -- Right edge
    border.right = parent:CreateTexture(nil, "OVERLAY")
    border.right:SetTexture(BORDER_TEX)
    border.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", pixelSize, 0)
    border.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", pixelSize, 0)
    PixelUtil.SetWidth(border.right, pixelSize, 1)

    -- Default to black with alpha bias (prevents 1px dropout)
    border:SetColor(0, 0, 0, BORDER_ALPHA)

    return border
end

-- Export for other files (Auras.lua, Castbars.lua)
ns.CreateTextureBorder = CreateTextureBorder
ns.BorderMethods = BorderMethods
ns.BORDER_TEX = BORDER_TEX
ns.BORDER_ALPHA = BORDER_ALPHA

-- =============================================================================
-- THROTTLE CONSTANTS (base values, multiplied by ns.c_throttleMultiplier)
-- =============================================================================
local THROTTLE = {
    health = 0.05,      -- 20 FPS (50ms) - fast enough for burst windows
    threat = 0.066,     -- 15 FPS (66ms) - threat changes infrequently
    quest = 0.5,        -- 2 FPS (500ms) - give API time to update after quest events
    personal = 0.05,    -- 20 FPS (50ms) - same as health
    targetingMe = 0.1,  -- 10 FPS (100ms) - polling rate for arena targeting
    vigilance = 5,      -- 0.2 FPS (5s) - group vigilance buff scan
    groupRole = 1,      -- 1 FPS (1s) - group role refresh
}

-- Update cached db reference (called after settings change)
function ns:UpdateDBCache()
    db = TurboPlatesDB or ns.defaults

    -- Potato PC Mode: doubles throttle values
    ns.c_potatoMode = db.potatoMode == true
    ns.c_throttleMultiplier = ns.c_potatoMode and 2 or 1

    -- Alpha setting for non-targeted nameplates (manual override since CVars don't exist)
    ns.c_nonTargetAlpha = db.nonTargetAlpha or 0.6

    -- Cached settings
    ns.c_width = db.width or 110
    ns.c_hpHeight = db.hpHeight or 12
    ns.c_castHeight = db.castHeight or 10
    ns.c_castbarYOffset = db.castbarYOffset or 0
    -- Use LSM to fetch texture/font paths from names
    ns.c_texture = ns.GetTexture and ns.GetTexture(db.texture) or "Interface\\RaidFrame\\Raid-Bar-Hp-Fill"
    ns.c_backgroundAlpha = db.backgroundAlpha or 0.8
    ns.c_font = ns.GetFont and ns.GetFont(db.font) or "Fonts\\FRIZQT__.TTF"
    ns.c_fontSize = db.fontSize or 10
    ns.c_fontOutline = db.fontOutline or "OUTLINE"
    ns.c_scale = db.scale or 1
    ns.c_targetScale = db.targetScale or 1.2
    ns.c_friendlyScale = db.friendlyScale or 1.0
    ns.c_distanceScaling = db.distanceScaling == true
    ns.c_distanceYOffset = db.distanceYOffset == true
    local distanceYOffsetMax = tonumber(db.distanceYOffsetMax)
    if not distanceYOffsetMax or distanceYOffsetMax ~= distanceYOffsetMax
       or distanceYOffsetMax == math.huge or distanceYOffsetMax == -math.huge then
        distanceYOffsetMax = 0
    end
    distanceYOffsetMax = floor(distanceYOffsetMax + 0.5)
    if distanceYOffsetMax < -15 then
        distanceYOffsetMax = -15
    elseif distanceYOffsetMax > 50 then
        distanceYOffsetMax = 50
    end
    db.distanceYOffsetMax = distanceYOffsetMax
    ns.c_distanceYOffsetMax = distanceYOffsetMax
    ns.c_healthBarBorder = db.healthBarBorder ~= false  -- Default true
    ns.c_raidMarkerSize = db.raidMarkerSize or 20
    ns.c_raidMarkerAnchor = db.raidMarkerAnchor or "LEFT"
    ns.c_raidMarkerX = db.raidMarkerX or 0
    ns.c_raidMarkerY = db.raidMarkerY or 0
    ns.c_showCastIcon = (db.showCastIcon == nil) or (db.showCastIcon == true)
    ns.c_showCastSpark = (db.showCastSpark == nil) or (db.showCastSpark == true)
    ns.c_showCastTimer = (db.showCastTimer == nil) or (db.showCastTimer == true)
    ns.c_highlightGlowEnabled = db.highlightGlowEnabled or false
    ns.c_highlightGlowLines = db.highlightGlowLines or 8
    ns.c_highlightGlowFrequency = db.highlightGlowFrequency or 0.25
    ns.c_highlightGlowLength = db.highlightGlowLength or 10
    ns.c_highlightGlowThickness = db.highlightGlowThickness or 2
    -- Cache highlight glow color
    local hlc = db.highlightGlowColor or { r = 1, g = 0.3, b = 0.1 }
    ns.c_highlightGlowColor_r = hlc.r
    ns.c_highlightGlowColor_g = hlc.g
    ns.c_highlightGlowColor_b = hlc.b
    ns.c_highlightSpells = type(db.highlightSpells) == "table" and db.highlightSpells or {}
    -- Only cache spell names if highlight is enabled (save overhead)
    ns.c_highlightSpellNames = {}
    if ns.c_highlightGlowEnabled then
        for spellID in pairs(ns.c_highlightSpells) do
            local name = GetSpellInfo(spellID)
            if name then ns.c_highlightSpellNames[name] = true end
        end
    end

    -- Tank mode settings
    ns.c_tankMode = db.tankMode or 0

    local classColorsUnavailable = ns.IsClasslessHeroPlayer and ns.IsClasslessHeroPlayer() or false
    if classColorsUnavailable and db ~= ns.defaults then
        db.classColoredHealth = false
        db.classColoredName = false
    end
    ns.c_classColoredHealth = (not classColorsUnavailable) and db.classColoredHealth == true
    ns.c_classColoredName = (not classColorsUnavailable) and db.classColoredName == true
    ns.c_arenaNumbers = db.arenaNumbers == true               -- false by default
    ns.c_healerMarks = db.healerMarks or 3                    -- 0 = disabled, 1 = enemies, 2 = friendly, 3 = both
    ns.c_executeRange = db.executeRange or 0                  -- 0 = disabled

    -- Color settings
    local hpc = db.hpColor or { r = 1, g = 0.2, b = 0.2 }
    ns.c_hpColor_r, ns.c_hpColor_g, ns.c_hpColor_b = hpc.r, hpc.g, hpc.b

    local fpc = db.friendlyPlayerColor or { r = 0.31, g = 0.45, b = 0.63 }
    ns.c_friendlyPlayerColor_r, ns.c_friendlyPlayerColor_g, ns.c_friendlyPlayerColor_b = fpc.r, fpc.g, fpc.b
    local fnc = db.friendlyNPCColor or { r = 0.29, g = 0.68, b = 0.30 }
    ns.c_friendlyNPCColor_r, ns.c_friendlyNPCColor_g, ns.c_friendlyNPCColor_b = fnc.r, fnc.g, fnc.b
    local nc = db.neutralColor or { r = 0.85, g = 0.77, b = 0.36 }
    ns.c_neutralColor_r, ns.c_neutralColor_g, ns.c_neutralColor_b = nc.r, nc.g, nc.b

    local pc = db.petColor or { r = 0.5, g = 0.5, b = 0.5 }
    ns.c_petColor_r, ns.c_petColor_g, ns.c_petColor_b = pc.r, pc.g, pc.b

    -- Tapped unit color
    local tpc = db.tappedColor or { r = 0.5, g = 0.5, b = 0.5 }
    ns.c_tappedColor_r, ns.c_tappedColor_g, ns.c_tappedColor_b = tpc.r, tpc.g, tpc.b

    local hnc = db.hostileNameColor or { r = 1, g = 1, b = 1 }
    ns.c_hostileNameColor_r, ns.c_hostileNameColor_g, ns.c_hostileNameColor_b = hnc.r, hnc.g, hnc.b
    local fnc = db.friendlyNameColor or { r = 1, g = 1, b = 1 }
    ns.c_friendlyNameColor_r, ns.c_friendlyNameColor_g, ns.c_friendlyNameColor_b = fnc.r, fnc.g, fnc.b

    -- Tank mode colors
    local sc = db.secureColor or { r = 1, g = 0, b = 1 }
    ns.c_secureColor_r, ns.c_secureColor_g, ns.c_secureColor_b = sc.r, sc.g, sc.b

    local tc = db.transColor or { r = 1, g = 0.8, b = 0 }
    ns.c_transColor_r, ns.c_transColor_g, ns.c_transColor_b = tc.r, tc.g, tc.b

    local ic = db.insecureColor or { r = 1, g = 0, b = 0 }
    ns.c_insecureColor_r, ns.c_insecureColor_g, ns.c_insecureColor_b = ic.r, ic.g, ic.b

    local oc = db.offTankColor or { r = 0.2, g = 0.7, b = 0.5 }
    ns.c_offTankColor_r, ns.c_offTankColor_g, ns.c_offTankColor_b = oc.r, oc.g, oc.b

    -- DPS mode colors
    local dsc = db.dpsSecureColor or { r = 1, g = 0, b = 1 }
    ns.c_dpsSecureColor_r, ns.c_dpsSecureColor_g, ns.c_dpsSecureColor_b = dsc.r, dsc.g, dsc.b

    local dtc = db.dpsTransColor or { r = 1, g = 0.8, b = 0 }
    ns.c_dpsTransColor_r, ns.c_dpsTransColor_g, ns.c_dpsTransColor_b = dtc.r, dtc.g, dtc.b

    local dac = db.dpsAggroColor or { r = 1, g = 0, b = 0 }
    ns.c_dpsAggroColor_r, ns.c_dpsAggroColor_g, ns.c_dpsAggroColor_b = dac.r, dac.g, dac.b

    -- Pet/Totem settings (visibility controlled by game CVars, these are just styling)
    ns.c_petScale = db.petScale or 0.7
    local totemMode = db.totemDisplay or "icon_name"
    ns.c_totemDisplay = totemMode
    -- Boolean flags
    ns.c_totemEnabled = totemMode ~= "disabled"
    ns.c_totemShowIcon = totemMode ~= "hp_name" and totemMode ~= "disabled"
    ns.c_totemShowName = totemMode ~= "icon_only" and totemMode ~= "icon_hp" and totemMode ~= "disabled"
    ns.c_totemShowHP = totemMode == "hp_name" or totemMode == "icon_hp" or totemMode == "icon_name_hp"

    -- Combo point settings
    ns.c_showComboPoints = db.showComboPoints ~= false
    ns.c_cpOnPersonalBar = db.cpOnPersonalBar == true
    ns.c_cpSize = db.cpSize or 14
    ns.c_cpX = db.cpX or 0
    ns.c_cpY = db.cpY or 0
    ns.c_cpPersonalX = db.cpPersonalX or 0
    ns.c_cpPersonalY = db.cpPersonalY or 0

    ns.c_showRunes = db.showRunes == true
    ns.c_runesOnPersonalBar = db.runesOnPersonalBar == true
    ns.c_runeStyle = db.runeStyle or 1
    ns.c_runeSize = db.runeSize or 12
    ns.c_runeX = db.runeX or 0
    ns.c_runeY = db.runeY or 8
    ns.c_runePersonalX = db.runePersonalX or 0
    ns.c_runePersonalY = db.runePersonalY or 8

    -- Castbar settings
    ns.c_showCastbar = db.showCastbar ~= false
    local cc = db.castColor or { r = 1, g = 0.8, b = 0 }
    ns.c_castColor_r, ns.c_castColor_g, ns.c_castColor_b = cc.r, cc.g, cc.b
    local nic = db.noInterruptColor or { r = 0.6, g = 0.6, b = 0.6 }
    ns.c_noInterruptColor_r, ns.c_noInterruptColor_g, ns.c_noInterruptColor_b = nic.r, nic.g, nic.b

    -- Health value display settings
    ns.c_healthValueFormat = db.healthValueFormat or "none"
    ns.c_healthValueFontSize = db.healthValueFontSize or 10
    ns.c_nameTextYOffset = db.nameTextYOffset or 0
    ns.c_plateXOffset = db.plateXOffset or 0
    ns.c_plateYOffset = db.plateYOffset or 0
    ns.c_nameInHealthbar = db.nameInHealthbar == true  -- Default to false
    ns.c_hidePercentWhenFull = db.hidePercentWhenFull == true  -- Default to false (show 100%)

    -- Friendly plate settings
    ns.c_friendlyNameOnly = db.friendlyNameOnly ~= false
    ns.c_liteHealthWhenDamaged = db.liteHealthWhenDamaged ~= false  -- true by default
    ns.c_friendlyGuild = db.friendlyGuild == true
    ns.c_friendlyFontSize = db.friendlyFontSize or 12
    ns.c_guildFontSize = db.guildFontSize or 10
    ns.c_npcTitleCache = type(db.npcTitleCache) == "table" and db.npcTitleCache or {}

    -- Combo point style (placeholder for future use)
    ns.c_cpStyle = db.cpStyle or 1

    -- Name display format (none, abbreviate, first, last)
    ns.c_nameDisplayFormat = db.nameDisplayFormat or "none"

    -- Target glow settings
    ns.c_targetGlow = db.targetGlow or "none"
    ns.c_targetArrow = db.targetArrow or "none"
    local tgc = db.targetGlowColor or { r = 1, g = 1, b = 1 }
    ns.c_targetGlowColor_r, ns.c_targetGlowColor_g, ns.c_targetGlowColor_b = tgc.r, tgc.g, tgc.b
    ns.c_mouseoverGlow = db.mouseoverGlow ~= false
    local mgc = db.mouseoverGlowColor or { r = 1, g = 1, b = 1 }
    ns.c_mouseoverGlowColor_r, ns.c_mouseoverGlowColor_g, ns.c_mouseoverGlowColor_b = mgc.r, mgc.g, mgc.b

    -- PvP Targeting Me indicator settings
    ns.c_targetingMeIndicator = db.targetingMeIndicator or "disabled"
    local tmc = db.targetingMeColor or { r = 1, g = 0.2, b = 0.2 }
    ns.c_targetingMeColor_r, ns.c_targetingMeColor_g, ns.c_targetingMeColor_b = tmc.r, tmc.g, tmc.b

    -- Quest objective icon settings
    ns.c_showQuestNPCs = db.showQuestNPCs ~= false        -- Default true
    ns.c_showQuestObjectives = db.showQuestObjectives ~= false  -- Default true
    -- Convert % to scale (100% = 1.2x), with fallback for old multiplier format
    local rawScale = db.questIconScale or 100
    if rawScale < 10 then rawScale = (rawScale / 1.2) * 100 end  -- Old format (0.5-2.0) → percentage
    ns.c_questIconScale = (rawScale / 100) * 1.2
    ns.c_questIconAnchor = db.questIconAnchor or "LEFT"
    ns.c_questIconX = db.questIconX or 0
    ns.c_questIconY = db.questIconY or 0
    ns.c_questIconsEnabled = ns.c_showQuestNPCs or ns.c_showQuestObjectives

    -- Level indicator settings
    ns.c_levelMode = db.levelMode or "disabled"  -- disabled, enemies, all
    ns.c_playerLevel = UnitLevel("player")  -- Cache player level for comparison

    -- Classification icon settings
    ns.c_classificationStyle = db.classificationStyle or "default"
    ns.c_classificationAnchor = db.classificationAnchor or "TOPLEFT"
    ns.c_classificationX = db.classificationX or 0
    ns.c_classificationY = db.classificationY or 0
    ns.c_classificationSize = db.classificationSize or 18

    -- Threat text display settings
    ns.c_threatTextAnchor = db.threatTextAnchor or "disabled"
    ns.c_threatTextFontSize = db.threatTextFontSize or 10
    ns.c_threatTextOffsetX = db.threatTextOffsetX or 2
    ns.c_threatTextOffsetY = db.threatTextOffsetY or 0

    -- Personal resource bar settings
    local personal = db.personal or ns.defaults.personal

    -- Personal enabled: CVar is authoritative (synced with Interface settings)
    -- Read from CVar first, fall back to saved setting for initial load
    local cvarVal = GetCVar and GetCVar("nameplateShowPersonal")
    if cvarVal ~= nil then
        -- CVar exists - use its value (Interface settings take precedence)
        ns.c_personalEnabled = (cvarVal == "1" or cvarVal == 1)
        -- Sync saved setting to match CVar (keeps DB in sync)
        if personal.enabled ~= ns.c_personalEnabled then
            personal.enabled = ns.c_personalEnabled
        end
    else
        -- CVar doesn't exist yet (unlikely) - use saved setting
        ns.c_personalEnabled = personal.enabled == true
    end

    ns.c_personalWidth = personal.width or 110
    ns.c_personalHeight = personal.height or 12
    ns.c_personalShowPower = personal.showPowerBar ~= false
    ns.c_personalPowerHeight = personal.powerHeight or 8
    ns.c_personalHealthFormat = personal.healthFormat or "percent"
    ns.c_personalPowerFormat = personal.powerFormat or "percent"
    -- Health color is always user-defined (no class color mode)
    local phc = personal.healthColor
    if not phc or not phc.r then phc = { r = 0, g = 0.8, b = 0 } end
    ns.c_personalHealthColor_r = phc.r or 0
    ns.c_personalHealthColor_g = phc.g or 0.8
    ns.c_personalHealthColor_b = phc.b or 0
    ns.c_personalPowerColorByType = personal.powerColorByType ~= false
    ns.c_personalUseClassColor = personal.useClassColor == true  -- Default false
    ns.c_personalShowAdditionalPower = personal.showAdditionalPower ~= false
    ns.c_personalAdditionalPowerHeight = personal.additionalPowerHeight or 6
    ns.c_personalHeroPowerOrder = personal.heroPowerOrder or 1  -- HERO class power order
    ns.c_personalShowBuffs = personal.showBuffs ~= false
    ns.c_personalShowDebuffs = personal.showDebuffs ~= false
    ns.c_personalBuffXOffset = personal.buffXOffset or 0
    ns.c_personalBuffYOffset = personal.buffYOffset or 0
    ns.c_personalDebuffXOffset = personal.debuffXOffset or 0
    ns.c_personalDebuffYOffset = personal.debuffYOffset or 0
    ns.c_personalYOffset = personal.yOffset or 0
    ns.c_personalBorderStyle = personal.borderStyle or "removable"  -- removable, black, debuff, debuff_only, none

    -- Sync CVar with cached value
    if SetCVar then
        SetCVar("nameplateShowPersonal", ns.c_personalEnabled and "1" or "0")
    end

    -- Cache aura settings (defined in Auras.lua)
    if ns.CacheAuraSettings then
        ns:CacheAuraSettings()
    end

    -- Cache TurboDebuffs settings
    if ns.CacheTurboDebuffsSettings then
        ns:CacheTurboDebuffsSettings()
    end

    -- Update targeting me polling state (forward declared, may be nil at load time)
    if ns.UpdateTargetingMePolling then
        ns.UpdateTargetingMePolling()
    end

    -- Update personal power event registration (forward declared, may be nil at load time)
    if ns.UpdatePersonalPowerEvents then
        ns.UpdatePersonalPowerEvents()
    end

    -- Stacking settings (ratio-based, adapts to clickbox size)
    local stacking = db.stacking or ns.defaults.stacking
    local stackingDefaults = ns.defaults.stacking
    ns.c_stackingEnabled = stacking.enabled == true
    -- Spring physics
    ns.c_stackingSpringFrequencyRaise = stacking.springFrequencyRaise or stackingDefaults.springFrequencyRaise
    ns.c_stackingSpringFrequencyLower = stacking.springFrequencyLower or stackingDefaults.springFrequencyLower
    ns.c_stackingLaunchDamping = stacking.launchDamping or stackingDefaults.launchDamping
    ns.c_stackingSettleThreshold = stacking.settleThreshold or stackingDefaults.settleThreshold
    ns.c_stackingMaxPlates = stacking.maxPlates or stackingDefaults.maxPlates
    -- Layout settings
    ns.c_stackingXSpaceRatio = stacking.xSpaceRatio or stackingDefaults.xSpaceRatio
    ns.c_stackingYSpaceRatio = stacking.ySpaceRatio or stackingDefaults.ySpaceRatio
    ns.c_stackingOriginPosRatio = stacking.originPosRatio or stackingDefaults.originPosRatio
    ns.c_stackingUpperBorder = stacking.upperBorder or stackingDefaults.upperBorder

    -- Update stacking state (forward declared, may be nil at load time)
    if ns.UpdateStacking then
        ns.UpdateStacking()
    end

    -- Refresh stacking config cache (in case settings changed while enabled)
    if ns.RefreshStackingConfig then
        ns.RefreshStackingConfig()
    end

    -- Initialize tall boss fix (always-on, extends WorldFrame for tall boss visibility)
    if ns.InitTallBossFix then
        ns.InitTallBossFix()
    end

    -- Update nameplate alphas with new settings
    if ns.UpdateNameplateAlphas then
        ns.UpdateNameplateAlphas("settings")
    end

    -- Invalidate per-plate style caches so UpdatePlateStyle re-applies everything
    for unit, myPlate in pairs(ns.unitToPlate or {}) do
        if myPlate then
            -- Font caches
            myPlate._lastFont = nil
            myPlate._lastFontSize = nil
            myPlate._lastFontOutline = nil
            myPlate._lastHealthFont = nil
            myPlate._lastHealthFontSize = nil
            myPlate._lastHealthFontOutline = nil
            -- Dimension caches
            myPlate._lastWidth = nil
            myPlate._lastHpHeight = nil
            myPlate._lastPlateX = nil
            myPlate._lastPlateY = nil
            myPlate._lastBgAlpha = nil
            myPlate._lastBorderShown = nil
            -- Execute indicator
            myPlate._lastExecWidth = nil
            myPlate._lastExecHeight = nil
            -- Aura icon caches
            myPlate._lastDebuffW = nil
            myPlate._lastDebuffH = nil
            myPlate._lastBuffW = nil
            myPlate._lastBuffH = nil
            myPlate._lastDebuffSpacing = nil
            myPlate._lastBuffSpacing = nil
            myPlate._lastMaxDebuffs = nil
            myPlate._lastMaxBuffs = nil
            -- Raid marker caches
            myPlate._lastRaidSize = nil
            myPlate._lastRaidAnchor = nil
            myPlate._lastRaidX = nil
            myPlate._lastRaidY = nil
            -- Quest icon caches
            myPlate._lastQuestAnchor = nil
            myPlate._lastQuestScale = nil
            myPlate._lastQuestX = nil
            myPlate._lastQuestY = nil
            -- Castbar caches
            myPlate._lastCastHeight = nil
            myPlate._lastCastYOffset = nil
            myPlate._lastCastTexture = nil
            -- Combo point caches
            myPlate._lastCpX = nil
            myPlate._lastCpY = nil
            -- Personal plate caches
            myPlate._lastPersonalWidth = nil
            myPlate._lastPersonalHeight = nil
            myPlate._lastPersonalTexture = nil
            myPlate._lastPersonalY = nil
            myPlate._lastPersonalHealthFont = nil
            myPlate._lastPersonalHealthFontSize = nil
            myPlate._lastPersonalHealthFontOutline = nil
            -- Power bar caches
            if myPlate.powerBar then
                myPlate.powerBar._lastWidth = nil
                myPlate.powerBar._lastHeight = nil
                myPlate.powerBar._lastTexture = nil
                myPlate.powerBar._lastFont = nil
                myPlate.powerBar._lastFontSize = nil
                myPlate.powerBar._lastFontOutline = nil
            end
            if myPlate.additionalPowerBar then
                myPlate.additionalPowerBar._lastWidth = nil
                myPlate.additionalPowerBar._lastHeight = nil
            end
            -- HERO power bar caches
            if myPlate.heroPowerBars then
                for i = 1, 3 do
                    if myPlate.heroPowerBars[i] then
                        myPlate.heroPowerBars[i]._lastWidth = nil
                        myPlate.heroPowerBars[i]._lastHeight = nil
                    end
                end
            end
            -- Reorder HERO power bars if settings changed
            if ns.isHeroClass and myPlate.heroPowerBars and myPlate.isPlayer then
                ns.ReorderHeroPowerBars(myPlate)
            end
        end
    end
end

do
local DISTANCE_SCALE_REFERENCE_DEPTH = 30
local DISTANCE_SCALE_MIN_FACTOR = 0.60
local DISTANCE_SCALE_MAX_FACTOR = 1.00

local DISTANCE_PROBE_NEAR = 5
local DISTANCE_PROBE_FAR = 61

local function GetNativeParent(visual)
    if not visual then return nil end
    if visual.parentPlate then return visual.parentPlate end
    if visual.movementCallback then return visual.movementCallback.parent end
    return nil
end

local function EnsureDistanceDepthProbe(visual)
    local parent = GetNativeParent(visual)
    if not parent then return nil, nil end

    if not parent._tpDistanceBaseWidth or not parent._tpDistanceBaseHeight then
        local w, h = parent:GetSize()
        if w and h and w > 0 and h > 0 then
            parent._tpDistanceBaseWidth = w
            parent._tpDistanceBaseHeight = h
        end
    end

    local probe = parent._tpDistanceDepthProbe
    if not probe then
        probe = CreateFrame("Frame", nil, parent)
        probe:EnableMouse(false)
        probe:SetPoint("TOP", parent, "TOP", 0, 0)
        local w = parent._tpDistanceBaseWidth or parent:GetWidth() or 1
        local h = parent._tpDistanceBaseHeight or parent:GetHeight() or 1
        probe:SetSize(math.max(1, w), math.max(1, h))
        probe:Show()
        parent._tpDistanceDepthProbe = probe

        if WorldFrame and WorldFrame.GetDepth and WorldFrame.SetDepth then
            local d = WorldFrame:GetDepth()
            if d then
                WorldFrame:SetDepth(d + 1)
                WorldFrame:SetDepth(d)
            end
        end
    elseif not probe:IsShown() then
        probe:Show()
    end

    return probe, parent
end

local function GetDistanceProbeDepth(visual)
    if not visual or visual.isPlayer then return nil end
    local probe = EnsureDistanceDepthProbe(visual)
    if not probe or not probe.GetEffectiveDepth then return nil end
    local depth = probe:GetEffectiveDepth()
    if depth and depth > 0 then
        visual._tpNativeDepth = depth
        visual._tpDistanceProbeDepth = depth
        return depth
    end
    return nil
end

local function GetDistanceYOffsetFromDepth(depth)
    if not ns.c_distanceYOffset or not depth then
        return 0
    end

    local t = (depth - DISTANCE_PROBE_NEAR) / (DISTANCE_PROBE_FAR - DISTANCE_PROBE_NEAR)

    local maxOffset = 15 + (ns.c_distanceYOffsetMax or 0)

    if t <= 0 then
        return 0
    end
    if t >= 1 then
        return maxOffset
    end

    return maxOffset * t
end

function ns:RefreshDistanceCameraSnapshot(force)
    local now = (GetTime and GetTime()) or 0
    local last = tonumber(ns._tpDistanceCameraSnapshotAt) or -1000
    if not force and ns._tpDistanceCameraSnapshotReady and (now - last) < 0.10 then
        return ns._tpDistanceCameraDistance, ns._tpDistanceCameraValid, ns._tpDistanceCameraSource
    end

    ns._tpDistanceCameraSnapshotAt = now

    if type(GetCameraZoom) == "function" then
        local ok, value = pcall(GetCameraZoom)
        value = ok and tonumber(value) or nil
        if value and value >= 0 then
            ns._tpDistanceCameraDistance = value
            ns._tpDistanceCameraValid = true
            ns._tpDistanceCameraSource = "GetCameraZoom"
            ns._tpDistanceCameraSavedBefore = nil
            ns._tpDistanceCameraSavedAfter = nil
            ns._tpDistanceCameraSnapshotReady = true
            return value, true, ns._tpDistanceCameraSource
        end
    end

    if type(SaveView) == "function" and type(GetCVar) == "function" then
        local oldDistance, oldPitch
        local okOldD, oldD = pcall(GetCVar, "cameraSavedDistance")
        local okOldP, oldP = pcall(GetCVar, "cameraSavedPitch")
        if okOldD then oldDistance = oldD end
        if okOldP then oldPitch = oldP end

        local captured, capturedPitch
        local oldDistanceNumber = tonumber(oldDistance)
        local okSave = false
        if oldDistanceNumber then
            okSave = pcall(SaveView, 5)
        end
        if okSave then
            local okReadD, valueD = pcall(GetCVar, "cameraSavedDistance")
            local okReadP, valueP = pcall(GetCVar, "cameraSavedPitch")
            captured = okReadD and tonumber(valueD) or nil
            capturedPitch = okReadP and tonumber(valueP) or nil
        end

        ns._tpDistanceCameraSavedBefore = tonumber(oldDistance)
        ns._tpDistanceCameraSavedAfter = captured
        ns._tpDistanceCameraSavedPitch = capturedPitch

        if type(SetCVar) == "function" then
            if oldDistance ~= nil then pcall(SetCVar, "cameraSavedDistance", oldDistance) end
            if oldPitch ~= nil then pcall(SetCVar, "cameraSavedPitch", oldPitch) end
        end

        if captured and captured >= 0 then
            ns._tpDistanceCameraDistance = captured
            ns._tpDistanceCameraValid = true
            ns._tpDistanceCameraSource = "SaveView5-cameraSavedDistance"
            ns._tpDistanceCameraSnapshotReady = true
            return captured, true, ns._tpDistanceCameraSource
        end
    end

    ns._tpDistanceCameraDistance = 0
    ns._tpDistanceCameraValid = false
    ns._tpDistanceCameraSource = "unavailable"
    ns._tpDistanceCameraSavedBefore = nil
    ns._tpDistanceCameraSavedAfter = nil
    ns._tpDistanceCameraSavedPitch = nil
    ns._tpDistanceCameraSnapshotReady = true
    return 0, false, ns._tpDistanceCameraSource
end

function ns:GetCurrentDistanceYOffset(visual)
    if not visual or visual.isPlayer or not ns.c_distanceYOffset then
        return 0
    end

    local rawDepth = GetDistanceProbeDepth(visual)
    if not rawDepth then
        visual._tpDistanceRawDepth = nil
        visual._tpPlayerRelativeDepth = nil
        return 0
    end

    local cameraDistance, cameraValid, cameraSource
    if ns._tpDistanceCameraSnapshotReady then
        cameraDistance = tonumber(ns._tpDistanceCameraDistance) or 0
        cameraValid = ns._tpDistanceCameraValid == true
        cameraSource = ns._tpDistanceCameraSource
    else
        cameraDistance, cameraValid, cameraSource = ns:RefreshDistanceCameraSnapshot(true)
    end

    visual._tpDistanceRawDepth = rawDepth
    visual._tpCameraDistance = cameraDistance
    visual._tpCameraDistanceValid = cameraValid
    visual._tpCameraDistanceSource = cameraSource
    visual._tpCameraSavedDistanceBefore = ns._tpDistanceCameraSavedBefore
    visual._tpCameraSavedDistanceAfter = ns._tpDistanceCameraSavedAfter
    visual._tpCameraSavedPitch = ns._tpDistanceCameraSavedPitch

    if not cameraValid then
        visual._tpPlayerRelativeDepth = nil
        return 0
    end

    local playerDepth = rawDepth - cameraDistance
    if playerDepth < 0 then playerDepth = 0 end
    visual._tpPlayerRelativeDepth = playerDepth

    return GetDistanceYOffsetFromDepth(playerDepth)
end

local function GetDistanceScaleFactor(visual)
    if not ns.c_distanceScaling or not visual or visual.isPlayer then
        if visual then
            visual._tpNativeDepth = nil
            visual._tpDistanceProbeDepth = nil
        end
        return 1
    end

    local depth = GetDistanceProbeDepth(visual)
    if not depth or depth <= DISTANCE_SCALE_REFERENCE_DEPTH then
        return 1
    end

    local factor = DISTANCE_SCALE_REFERENCE_DEPTH / depth
    if factor < DISTANCE_SCALE_MIN_FACTOR then
        factor = DISTANCE_SCALE_MIN_FACTOR
    elseif factor > DISTANCE_SCALE_MAX_FACTOR then
        factor = DISTANCE_SCALE_MAX_FACTOR
    end
    return factor
end

local function ApplyNativeDistanceEnvelope(visual, factor)
    local parent = GetNativeParent(visual)
    if not parent then return end

    local baseW = parent._tpDistanceBaseWidth
    local baseH = parent._tpDistanceBaseHeight
    if not baseW or not baseH then
        local w, h = parent:GetSize()
        if not w or not h or w <= 0 or h <= 0 then return end
        baseW, baseH = w, h
        parent._tpDistanceBaseWidth = baseW
        parent._tpDistanceBaseHeight = baseH
    end

    local useFactor = (ns.c_distanceScaling and not visual.isPlayer) and factor or 1
    local targetW = baseW * useFactor
    local targetH = baseH * useFactor
    local curW, curH = parent:GetSize()
    if not curW or not curH or math.abs(curW - targetW) > 0.05 or math.abs(curH - targetH) > 0.05 then
        parent:SetSize(targetW, targetH)
    end
    parent._tpDistanceEnvelopeFactor = useFactor
end

function ns:RestoreDistanceProjection(visual)
    if not visual then return end
    local parent = GetNativeParent(visual)
    if parent and parent._tpDistanceBaseWidth and parent._tpDistanceBaseHeight then
        local w, h = parent:GetSize()
        local bw, bh = parent._tpDistanceBaseWidth, parent._tpDistanceBaseHeight
        if not w or not h or math.abs(w - bw) > 0.05 or math.abs(h - bh) > 0.05 then
            parent:SetSize(bw, bh)
        end
        parent._tpDistanceEnvelopeFactor = 1
    end

    local base = visual._tpBaseScale or (visual.isPlayer and (ns.c_scale or 1)) or (ns.c_scale or 1)
    if visual._tpAppliedScale == nil or math.abs((visual:GetScale() or 1) - base) > 0.001 then
        visual:SetScale(base)
    end
    visual._tpAppliedScale = base
    visual._tpDistanceScaleFactor = 1
    visual._tpNativeDepth = nil
    visual._tpDistanceProbeDepth = nil
end

function ns:ApplyPlateScale(myPlate, baseScale)
    if not myPlate then return end
    if baseScale ~= nil then
        myPlate._tpBaseScale = baseScale
    elseif myPlate._tpBaseScale == nil then
        myPlate._tpBaseScale = myPlate:GetScale() or 1
    end

    local base = myPlate._tpBaseScale or 1
    local factor = GetDistanceScaleFactor(myPlate)
    local applied = base * factor

    if myPlate._tpAppliedScale == nil or math.abs(myPlate._tpAppliedScale - applied) > 0.001 then
        myPlate:SetScale(applied)
        myPlate._tpAppliedScale = applied
    end

    myPlate._tpDistanceScaleFactor = factor
    ApplyNativeDistanceEnvelope(myPlate, factor)
end

function ns:RefreshPlateDistanceScale(myPlate)
    if not myPlate then return end
    ns:ApplyPlateScale(myPlate, nil)
end

function ns:RefreshPlateDistanceYOffset(visual)
    if not visual or visual.isPlayer then return end

    local y = ns:GetCurrentDistanceYOffset(visual)
    visual._tpDistanceYOffset = y
    if ns.ApplyDistanceRootOffset then
        ns:ApplyDistanceRootOffset(visual, false, y)
    end
end

function ns:RestorePlateDistanceYOffset(visual)
    if not visual or visual.isPlayer then return end
    visual._tpDistanceYOffset = 0
    if ns.ApplyDistanceRootOffset then
        ns:ApplyDistanceRootOffset(visual, false, 0)
    end
end

local distanceFeaturesWereEnabled = false

local function RefreshAllActiveDistanceScales()
    if ns.c_distanceYOffset and ns.RefreshDistanceCameraSnapshot then
        ns:RefreshDistanceCameraSnapshot(false)
    else
        ns._tpDistanceCameraSnapshotReady = false
        ns._tpDistanceCameraDistance = 0
        ns._tpDistanceCameraValid = false
        ns._tpDistanceCameraSource = "disabled"
    end

    if not C_NamePlateManager_EnumerateActiveNamePlates then return end
    for blizzFrame in C_NamePlateManager_EnumerateActiveNamePlates() do
        if blizzFrame then
            local full = blizzFrame.myPlate
            local lite = blizzFrame.liteContainer

            if ns.c_distanceScaling then
                if full then ns:RefreshPlateDistanceScale(full) end
                if lite then ns:RefreshPlateDistanceScale(lite) end
            else
                local needsRestore = (blizzFrame._tpDistanceEnvelopeFactor and math.abs(blizzFrame._tpDistanceEnvelopeFactor - 1) > 0.001)
                if full and ((full._tpDistanceScaleFactor and math.abs(full._tpDistanceScaleFactor - 1) > 0.001) or needsRestore) then
                    ns:RestoreDistanceProjection(full)
                end
                if lite and ((lite._tpDistanceScaleFactor and math.abs(lite._tpDistanceScaleFactor - 1) > 0.001) or needsRestore) then
                    ns:RestoreDistanceProjection(lite)
                end

                if needsRestore and blizzFrame._tpDistanceBaseWidth and blizzFrame._tpDistanceBaseHeight then
                    local w, h = blizzFrame:GetSize()
                    if not w or not h or math.abs(w - blizzFrame._tpDistanceBaseWidth) > 0.05 or math.abs(h - blizzFrame._tpDistanceBaseHeight) > 0.05 then
                        blizzFrame:SetSize(blizzFrame._tpDistanceBaseWidth, blizzFrame._tpDistanceBaseHeight)
                    end
                    blizzFrame._tpDistanceEnvelopeFactor = 1
                end
            end

            if ns.c_distanceYOffset then
                if full then ns:RefreshPlateDistanceYOffset(full) end
                if lite then ns:RefreshPlateDistanceYOffset(lite) end
            else
                if full then ns:RestorePlateDistanceYOffset(full) end
                if lite then ns:RestorePlateDistanceYOffset(lite) end
            end
        end
    end

end

ns.RefreshAllDistanceScales = RefreshAllActiveDistanceScales
ns.RefreshAllDistanceFeatures = RefreshAllActiveDistanceScales

WorldFrame:HookScript("OnUpdate", function()
    if ns.c_distanceScaling or ns.c_distanceYOffset then
        distanceFeaturesWereEnabled = true
        RefreshAllActiveDistanceScales()
    elseif distanceFeaturesWereEnabled then
        distanceFeaturesWereEnabled = false
        RefreshAllActiveDistanceScales()
    end
end)

end
local nameplateAlphaUpdateScheduled = false
local function ScheduleNameplateAlphaUpdate()
    if nameplateAlphaUpdateScheduled then return end
    nameplateAlphaUpdateScheduled = true
    C_Timer_After(0, function()
        nameplateAlphaUpdateScheduled = false
        if ns.UpdateNameplateAlphas then
            ns.UpdateNameplateAlphas("retry")
        end
    end)
end

-- Update alpha for all nameplates based on target state
-- Called on PLAYER_TARGET_CHANGED and when alpha settings change
function ns.UpdateNameplateAlphas(reason)
    for nameplate in C_NamePlateManager.EnumerateActiveNamePlates() do
        if nameplate._isLite and nameplate.liteContainer then
            local parentAlpha = nameplate:GetAlpha()
            local alpha = ns.ResolveNameplateAlpha(nameplate.liteContainer, parentAlpha, reason or "refresh", ScheduleNameplateAlphaUpdate)
            if alpha ~= nameplate.liteContainer:GetAlpha() then
                nameplate.liteContainer:SetAlpha(alpha)
            end
        end

        local myPlate = nameplate.myPlate
        if myPlate and not myPlate.isPlayer then
            local parentAlpha = nameplate:GetAlpha()
            local alpha = ns.ResolveNameplateAlpha(myPlate, parentAlpha, reason or "refresh", ScheduleNameplateAlphaUpdate)
            if alpha ~= myPlate:GetAlpha() then
                myPlate:SetAlpha(alpha)
            end
        end
    end
end

-- Called by the compat layer the instant a plate binds to its real unit. Plates now
-- announce on show (before the match establishes), so the GUID-dependent state set at
-- announce used the SYNTHETIC guid: cachedGUID drives target dimming
-- (ResolveNameplateAlpha) and target glow/scale (GetPlateByGUID), so a just-targeted
-- mob whose plate bound late stayed dimmed and unglowed. Re-sync those here.
function ns.OnPlateBound(blizzFrame, realGUID)
    if not blizzFrame or not realGUID then return end
    if blizzFrame.myPlate then
        blizzFrame.myPlate.cachedGUID = realGUID
        -- PIN the real GUID + a name/level signature onto the plate. cachedGUID
        -- reverts to the synthetic guid on the next unbound FullPlateUpdate, so it
        -- can't identify the mob once it stops being target/focus/mouseover. This
        -- pin persists across unbind (cleared on recycle / signature break) so
        -- CLEU-tracked debuffs can be shown on THIS specific mob by GUID instead of
        -- by name-union (which bleeds onto same-named neighbours). Mirrors
        -- NotPlater's frame.npGUID + signature approach (modules/aura).
        blizzFrame.myPlate.pinnedGUID = realGUID
        blizzFrame.myPlate.pinnedName = blizzFrame._tpName
        blizzFrame.myPlate.pinnedLevel = blizzFrame._tpLevel
    end
    if blizzFrame.liteContainer then blizzFrame.liteContainer.cachedGUID = realGUID end
    -- It just became identifiable as the target (real GUID now matches): fix glow/scale.
    if realGUID == ns.currentTargetGUID and ns.ValidateTargetPlate then
        ns.ValidateTargetPlate()
    end
    -- Re-apply this plate's alpha so a just-bound target stops being dimmed like a
    -- non-target (and a bound non-target gets correctly dimmed).
    local plate = (blizzFrame._isLite and blizzFrame.liteContainer) or blizzFrame.myPlate
    if plate and not plate.isPlayer and ns.ResolveNameplateAlpha then
        local a = ns.ResolveNameplateAlpha(plate, blizzFrame:GetAlpha(), "bind")
        if a ~= plate:GetAlpha() then plate:SetAlpha(a) end
    end
    if blizzFrame._tpToken and ns.UpdateColor then ns.UpdateColor(blizzFrame._tpToken) end
    if blizzFrame._tpToken and ns.UpdateRaidIcon then ns.UpdateRaidIcon(blizzFrame._tpToken) end
    -- Binding gives us the real unit, so the quest tooltip scan can finally run here.
    -- This is what makes MOUSING OVER (or targeting) a quest mob learn it - the icon
    -- update otherwise only fires on FullPlateUpdate / QUEST_LOG_UPDATE, never on a
    -- plain mouseover, so item-drop quest mobs were never learned from a hover.
    if blizzFrame._tpToken and ns.UpdateQuestIcon then ns.UpdateQuestIcon(blizzFrame._tpToken) end
    -- Binding gives us a real unit, so UnitCastingInfo finally answers. If the mob
    -- was ALREADY mid-cast when we targeted/focused/moused-over it, no fresh
    -- UNIT_SPELLCAST_START will fire - so pick up the in-progress cast here.
    if blizzFrame._tpToken and ns.CheckExistingCast then ns:CheckExistingCast(blizzFrame._tpToken) end
    -- ROOT bind-time re-sync. Plates render (FullPlateUpdate) BEFORE the match binds
    -- (rule 8: announce on show), so everything that needs the REAL unit was computed
    -- against a synthetic token, and nothing refreshes it once the unit resolves - no
    -- event fires for state that was already present (an applied aura, an existing
    -- elite classification, a standing threat). THIS hook is the single authoritative
    -- "real unit now available" point: every real-unit-dependent consumer must
    -- refresh here, not only on show. Scraped data (name/level/health/colour, rule 2)
    -- is intentionally absent - it comes from the plate's own regions, not the unit.
    -- The raid/quest/cast refreshes above are the same mechanism; auras (+ the
    -- aura-driven colour override done inside UpdateAuras), the priority debuff,
    -- classification and threat are the rest. Each one caused a real bug while it was
    -- only computed on show: invisible Sap on a re-shown target, missing elite border,
    -- stale threat text. New unit-dependent features belong HERE too.
    local mp = blizzFrame.myPlate
    if mp and mp.unit then
        if ns.UpdateAuras then ns:UpdateAuras(mp, mp.unit) end
        if ns.UpdateTurboDebuff then ns:UpdateTurboDebuff(mp, mp.unit) end
        if ns.UpdateClassificationIndicator then ns.UpdateClassificationIndicator(mp.unit) end
        if ns.UpdateThreatText then ns.UpdateThreatText(mp.unit, mp) end
    end
end

-- Arena detection for arena-specific features
local inArena = false
local IsInInstance = IsInInstance

-- Forward declarations for arena variables (defined later)
local arenaNames, UpdateArenaNames

-- Forward declaration for targeting me polling update (defined later)
local UpdateTargetingMePolling

-- Forward declaration for personal power event management (defined later)
local UpdatePersonalPowerEvents

local function UpdateArenaStatus()
    local inInstance, instanceType = IsInInstance()
    local wasInArena = inArena

    inArena = inInstance and instanceType == "arena"

    -- Reset arena names when leaving arena
    if wasInArena and not inArena then
        wipe(arenaNames)
    end

    -- Update arena names when entering arena
    if not wasInArena and inArena then
        UpdateArenaNames()
    end

    -- Update targeting me polling state (only polls in arena when enabled)
    if UpdateTargetingMePolling then
        UpdateTargetingMePolling()
    end
end



-- Arena name -> number lookup
arenaNames = {}  -- [name] = number (assigned to forward declaration)

local ARENA_UNITS = {"arena1", "arena2", "arena3", "arena4", "arena5"}

UpdateArenaNames = function()
    wipe(arenaNames)
    for i = 1, 5 do
        local name = UnitName(ARENA_UNITS[i])
        if name then
            arenaNames[name] = i
        end
    end
end

-- Get arena number for a unit (returns number 1-5 or nil)
-- Uses direct UnitIsUnit comparison for reliability (cache may be stale)
local function GetArenaNumber(unit)
    if not inArena or not ns.c_arenaNumbers then return nil end

    -- Direct comparison - most reliable method
    for i = 1, 5 do
        if UnitIsUnit(unit, ARENA_UNITS[i]) then
            return i
        end
    end

    -- Fallback to name cache if direct comparison fails
    local unitName = UnitName(unit)
    return unitName and arenaNames[unitName] or nil
end

-- Refresh arena numbers on all existing hostile player nameplates
-- Returns true if all enemy player nameplates have arena numbers resolved
local function RefreshArenaNumbers()
    if not inArena or not ns.c_arenaNumbers then return true end

    local allResolved = true
    local hasEnemyPlates = false

    for nameplate in C_NamePlateManager_EnumerateActiveNamePlates() do
        local unit = nameplate._unit
        -- Use nameplate.myPlate directly instead of unitToPlate lookup
        local myPlate = unit and nameplate.myPlate
        if myPlate and myPlate.nameText and UnitIsPlayer(unit) and not UnitIsFriend("player", unit) then
            hasEnemyPlates = true
            local arenaNum = GetArenaNumber(unit)
            if arenaNum then
                myPlate.nameText:SetText(arenaNum)
                myPlate.nameText:Show()
            else
                allResolved = false
                -- Keep normal name until arena number is available
                local name = UnitName(unit)
                if name then
                    myPlate.nameText:SetText(ns:FormatName(name))
                end
            end
        end
    end

    -- If no enemy plates visible yet, keep trying
    return hasEnemyPlates and allResolved
end

-- Delayed arena number refresh timer
local arenaRefreshTimer = nil
local arenaRefreshCount = 0

local function ScheduleArenaNumberRefresh()
    if arenaRefreshTimer then return end  -- Already scheduled
    arenaRefreshCount = 0

    -- Refresh every 0.5s until all numbers resolved (max 3 seconds)
    local function DoRefresh()
        if not inArena then
            arenaRefreshTimer = nil
            return
        end

        arenaRefreshCount = arenaRefreshCount + 1
        UpdateArenaNames()
        local allResolved = RefreshArenaNumbers()

        -- Stop early if all enemy nameplates have arena numbers
        if allResolved then
            arenaRefreshTimer = nil
            return
        end

        if arenaRefreshCount < 6 then
            arenaRefreshTimer = C_Timer_After(0.5, DoRefresh)
        else
            arenaRefreshTimer = nil
        end
    end

    arenaRefreshTimer = C_Timer_After(0.5, DoRefresh)
end

-- Totem SpellID lookup table - Ascension totem spell IDs
-- Bronzebeard server uses 11xxxxx format, other servers use standard WoW IDs
local TotemSpellIDs = {
    -- Fire Totems
    [2894] = true,  [1102894] = true,  -- Fire Elemental Totem
    [8190] = true,  [1108190] = true, [10585] = true, [1110585] = true, [10586] = true, [1110586] = true, [10587] = true, [1110587] = true,  -- Magma Totem
    [3599] = true,  [1103599] = true, [6363] = true, [1106363] = true, [6364] = true, [1106364] = true, [6365] = true, [1106365] = true, [10437] = true, [1110437] = true, [10438] = true, [1110438] = true,  -- Searing Totem
    [8184] = true,  [1108184] = true, [10537] = true, [1110537] = true, [10538] = true, [1110538] = true,  -- Fire Resistance Totem
    [8227] = true,  [1108227] = true, [8249] = true, [1108249] = true, [10526] = true, [1110526] = true, [16387] = true, [1116387] = true,  -- Flametongue Totem
    -- Earth Totems
    [2484] = true,  [1102484] = true,  -- Earthbind Totem
    [5730] = true,  [1105730] = true, [6390] = true, [1106390] = true, [6391] = true, [1106391] = true, [6392] = true, [1106392] = true, [10427] = true, [1110427] = true, [10428] = true, [110428] = true,  -- Stoneclaw Totem
    [2062] = true,  [1102062] = true,  -- Earth Elemental Totem
    [8071] = true,  [1108071] = true, [8154] = true, [1108154] = true, [8155] = true, [1108155] = true, [10406] = true, [1110406] = true, [10407] = true, [1110407] = true, [10408] = true, [1110408] = true,  -- Stoneskin Totem
    [8075] = true,  [1108075] = true, [8160] = true, [1108160] = true, [8161] = true, [1108161] = true, [10442] = true, [1110442] = true, [25361] = true, [1125361] = true,  -- Strength of Earth Totem
    [8143] = true,  [1108143] = true,  -- Tremor Totem
    -- Water Totems
    [8170] = true,  [1108170] = true,  -- Cleansing Totem
    [5394] = true,  [1105394] = true, [6375] = true, [1106375] = true, [6377] = true, [1106377] = true, [10462] = true, [1110462] = true, [10463] = true, [1110463] = true,  -- Healing Stream Totem
    [5675] = true,  [1105675] = true, [10495] = true, [1110495] = true, [10496] = true, [1110496] = true, [10497] = true, [1110497] = true,  -- Mana Spring Totem
    [8181] = true,  [1108181] = true, [10478] = true, [1110478] = true, [10479] = true, [1110479] = true,  -- Frost Resistance Totem
    [10595] = true, [1110595] = true, [10600] = true, [1110600] = true, [10601] = true, [1110601] = true,  -- Nature Resistance Totem
    -- Air Totems
    [3738] = true,  [1103738] = true,  -- Wrath of Air Totem
    [8177] = true,  [1108177] = true,  -- Grounding Totem
    -- Other Totems
    [30706] = true, [1130706] = true, [57720] = true, [1157720] = true,  -- Totem of Wrath
    [16190] = true, [1116190] = true,  -- Mana Tide Totem
    [2304590] = true,  -- Capacitor Totem
}

-- Name -> icon lookup (built at load time)
local TotemNameToIcon = {}
for spellID in pairs(TotemSpellIDs) do
    local name, _, icon = GetSpellInfo(spellID)
    if name and icon then
        TotemNameToIcon[name] = icon
    end
end

-- Manual icon overrides for totems where GetSpellInfo doesn't work
-- (Ascension custom totems or totems with mismatched spell/unit names)
TotemNameToIcon["Capacitor Totem"] = GetSpellInfo(2304590) and select(3, GetSpellInfo(2304590))
    or "Interface\\Icons\\Spell_Nature_Lightning"

-- Fallback icon for unknown totems
local TOTEM_FALLBACK_ICON = "Interface\\Icons\\Spell_Nature_StoneClawTotem"

-- Strip rank suffix from totem name (e.g., "Frost Resistance Totem III" -> "Frost Resistance Totem")
-- Handles Roman numerals I-X and "Rank X" format
local function StripRankSuffix(name)
    if not name then return nil end
    -- Remove trailing Roman numerals (I, II, III, IV, V, VI, VII, VIII, IX, X)
    local stripped = name:gsub("%s+[IVX]+$", "")
    -- Also handle "Rank X" format just in case
    stripped = stripped:gsub("%s+Rank%s+%d+$", "")
    return stripped
end

-- Get totem icon from unit name
local function GetTotemIcon(unit)
    local name = UnitName(unit)
    if not name then return nil end

    -- Try exact match first (includes previously cached ranked names)
    local icon = TotemNameToIcon[name]
    if icon then return icon end

    -- Try with rank suffix stripped, then cache the result
    local baseName = StripRankSuffix(name)
    if baseName then
        icon = TotemNameToIcon[baseName]
        if icon then
            -- Cache ranked name for next lookup
            TotemNameToIcon[name] = icon
            return icon
        end
    end

    return nil
end

-- Note: UnitIsPet(unit) is provided by FrameXML/Util/UnitUtil.lua
-- It uses GUIDIsPet(UnitGUID(unit)) where GUIDType 4 = Pet

-- =============================================================================
-- STRING CACHING SYSTEM
-- =============================================================================

-- Percent strings (0% to 100%)
local percentCache = {}
for i = 0, 100 do
    percentCache[i] = format("%.0f%%", i)
end

-- Composite health format cache
-- Key format: "cur|max" or "cur|max|pct" -> pre-built result string
local COMPOSITE_CACHE_SIZE = 500
local compositeCacheCount = 0
local compositeCache = setmetatable({}, {
    __index = function(t, key)
        -- Only cache if under limit
        if compositeCacheCount >= COMPOSITE_CACHE_SIZE then
            -- Cache full, compute without caching
            return nil
        end
        return nil  -- Let caller handle missing entries
    end
})

-- Helper to get or create composite format strings
local function GetCompositeFormat(curStr, maxStr, percentStr)
    if percentStr then
        local key = curStr .. "|" .. maxStr .. "|" .. percentStr
        local cached = rawget(compositeCache, key)
        if cached then return cached end
        local result = curStr .. " / " .. maxStr .. " (" .. percentStr .. ")"
        if compositeCacheCount < COMPOSITE_CACHE_SIZE then
            rawset(compositeCache, key, result)
            compositeCacheCount = compositeCacheCount + 1
        end
        return result
    else
        local key = curStr .. "|" .. maxStr
        local cached = rawget(compositeCache, key)
        if cached then return cached end
        local result = curStr .. " / " .. maxStr
        if compositeCacheCount < COMPOSITE_CACHE_SIZE then
            rawset(compositeCache, key, result)
            compositeCacheCount = compositeCacheCount + 1
        end
        return result
    end
end

-- Helper for "current (percent)" format - cached
local function GetCurrentPercentFormat(curStr, percentStr)
    local key = "cp|" .. curStr .. "|" .. percentStr
    local cached = rawget(compositeCache, key)
    if cached then return cached end
    local result = curStr .. " (" .. percentStr .. ")"
    if compositeCacheCount < COMPOSITE_CACHE_SIZE then
        rawset(compositeCache, key, result)
        compositeCacheCount = compositeCacheCount + 1
    end
    return result
end

-- Helper for deficit format - cached
local function GetDeficitFormat(deficitStr)
    local key = "d|" .. deficitStr
    local cached = rawget(compositeCache, key)
    if cached then return cached end
    local result = "-" .. deficitStr
    if compositeCacheCount < COMPOSITE_CACHE_SIZE then
        rawset(compositeCache, key, result)
        compositeCacheCount = compositeCacheCount + 1
    end
    return result
end

-- Helper for "current | -deficit" format - cached
local function GetCurrentDeficitFormat(curStr, deficitStr)
    local key = "cd|" .. curStr .. "|" .. deficitStr
    local cached = rawget(compositeCache, key)
    if cached then return cached end
    local result = curStr .. " | -" .. deficitStr
    if compositeCacheCount < COMPOSITE_CACHE_SIZE then
        rawset(compositeCache, key, result)
        compositeCacheCount = compositeCacheCount + 1
    end
    return result
end

-- Helper for "percent | -deficit" format - cached
local function GetPercentDeficitFormat(percentStr, deficitStr)
    local key = "pd|" .. percentStr .. "|" .. deficitStr
    local cached = rawget(compositeCache, key)
    if cached then return cached end
    local result = percentStr .. " | -" .. deficitStr
    if compositeCacheCount < COMPOSITE_CACHE_SIZE then
        rawset(compositeCache, key, result)
        compositeCacheCount = compositeCacheCount + 1
    end
    return result
end

-- Truncated value cache (lazy metatable, size-limited)
local TRUNCATE_CACHE_SIZE = 2000
local truncateCacheCount = 0
local truncateCache = setmetatable({}, {
    __index = function(t, value)
        -- Generate and cache the truncated string
        local str
        if value >= 1000000 then
            str = format("%.2fm", value / 1000000)
        elseif value >= 1000 then
            str = format("%.1fk", value / 1000)
        else
            str = format("%d", value)
        end

        -- Only cache if under limit
        if truncateCacheCount < TRUNCATE_CACHE_SIZE then
            rawset(t, value, str)
            truncateCacheCount = truncateCacheCount + 1
        end

        return str
    end
})

-- Non-truncated (raw integer) cache for when truncation is disabled
local rawIntCache = setmetatable({}, {
    __index = function(t, value)
        local str = format("%d", value)
        if truncateCacheCount < TRUNCATE_CACHE_SIZE then
            rawset(t, value, str)
            truncateCacheCount = truncateCacheCount + 1
        end
        return str
    end
})

-- =============================================================================
-- FORMATTING HELPERS
-- =============================================================================

-- Combo point colors (per-point coloring)
local cpColors = {
    [1] = {r = 1.0, g = 0.2, b = 0.1},     -- Red (slight orange tint to counter optical illusion)
    [2] = {r = 1.0, g = 0.5, b = 0.0},     -- Orange
    [3] = {r = 1.0, g = 1.0, b = 0.0},     -- Yellow
    [4] = {r = 0.5, g = 1.0, b = 0.0},     -- Yellow-green
    [5] = {r = 0.0, g = 1.0, b = 0.0},     -- Green
}

-- Use WoW's MAX_COMBO_POINTS global
local MAX_CP = MAX_COMBO_POINTS or 5

-- Truncate large numbers (K/M format) - always enabled
local function TruncateValue(value)
    return truncateCache[value]
end

-- Format health value text based on user settings
-- Optional healthFmt parameter for personal bar (overrides ns.c_healthValueFormat)
local function FormatHealthValue(current, max, healthFmt)
    local fmt = healthFmt or ns.c_healthValueFormat
    if fmt == "none" or not current or not max then
        return ""
    end

    -- CEIL (round any fraction up) to match the unit-frame addons the user compares
    -- against, which show 75% for a mob at 74.x% (and 66% for 65.x%). floor() read 1%
    -- LOW vs those frames; round-to-nearest read 1% HIGH near .5. ceil makes the
    -- nameplate agree with the unit frame. Full health is handled by the atFullHealth
    -- branch, and percentCache[100] clamps, so 100% never overflows to 101.
    local percentInt = ceil((current / max) * 100)
    local deficit = max - current
    local atFullHealth = (current == max)
    local hideWhenFull = ns.c_hidePercentWhenFull  -- User setting (default false = show 100%)

    -- Get cached strings
    local curStr = TruncateValue(current)
    local percentStr = percentCache[percentInt] or percentCache[100]  -- Clamp to cache range

    if fmt == "current" then
        return curStr
    elseif fmt == "percent" then
        if atFullHealth and hideWhenFull then
            return ""
        end
        return percentStr
    elseif fmt == "current-max" then
        local maxStr = TruncateValue(max)
        return GetCompositeFormat(curStr, maxStr, nil)
    elseif fmt == "current-max-percent" then
        local maxStr = TruncateValue(max)
        if atFullHealth and hideWhenFull then
            return GetCompositeFormat(curStr, maxStr, nil)
        else
            return GetCompositeFormat(curStr, maxStr, percentStr)
        end
    elseif fmt == "current-percent" then
        if atFullHealth and hideWhenFull then
            return curStr
        else
            return GetCurrentPercentFormat(curStr, percentStr)
        end
    elseif fmt == "deficit" then
        if not atFullHealth then
            return GetDeficitFormat(TruncateValue(deficit))
        end
        return ""
    elseif fmt == "current-deficit" then
        if atFullHealth then
            return curStr
        else
            return GetCurrentDeficitFormat(curStr, TruncateValue(deficit))
        end
    elseif fmt == "percent-deficit" then
        if not atFullHealth then
            return GetPercentDeficitFormat(percentStr, TruncateValue(deficit))
        end
        return ""
    end

    return ""
end

-- Expose for Core.lua lite health bar
ns.FormatHealthValue = FormatHealthValue

-- Rounded combo point texture
local CP_ROUND_TEXTURE = "Interface\\AddOns\\TurboPlates\\Textures\\Circle_AlphaGradient_Out"

-- Create combo points on first use
-- isPersonal: true = attach to personal bar with personal offsets, false = attach to target nameplate
local function EnsureComboPoints(myPlate, isPersonal)
    -- Recreate if style changed
    local currentStyle = ns.c_cpStyle or 1
    if myPlate.cps and myPlate.cpStyle == currentStyle then return end
    if not myPlate.hp then return end  -- Need hp for anchoring

    -- Clean up existing combo points if style changed
    if myPlate.cps then
        -- Both styles now use Textures - clear with SetTexture(nil)
        for i = 1, #myPlate.cps do
            myPlate.cps[i]:Hide()
            myPlate.cps[i]:SetTexture(nil)
        end
        myPlate.cps = nil
        if myPlate.cpContainer then
            myPlate.cpContainer:Hide()
            myPlate.cpContainer:SetParent(nil)
            myPlate.cpContainer = nil
        end
    end

    myPlate.cps = {}
    myPlate.cpStyle = currentStyle

    -- Create container frame for combo points
    -- Frame level +15 to ensure combo points draw above classification icon (+10)
    local cpContainer = CreateFrame("Frame", nil, myPlate)
    cpContainer:SetFrameLevel(myPlate:GetFrameLevel() + 15)
    cpContainer:EnableMouse(false)  -- Pass through clicks
    myPlate.cpContainer = cpContainer

    local cpWidth = ns.c_cpSize
    local offsetX, offsetY
    if isPersonal then
        offsetX = ns.c_cpPersonalX
        offsetY = ns.c_cpPersonalY
    else
        offsetX = ns.c_cpX
        offsetY = ns.c_cpY
    end

    if currentStyle == 2 then
        -- ROUNDED STYLE (Kui-like)
        local spacing = 3
        local totalWidth = (cpWidth * MAX_CP) + (spacing * (MAX_CP - 1))

        PixelUtil.SetSize(cpContainer, totalWidth, cpWidth, 1, 1)
        cpContainer:ClearAllPoints()
        PixelUtil.SetPoint(cpContainer, "BOTTOM", myPlate.hp, "TOP", offsetX, -1 + offsetY, 1, 1)

        for i = 1, MAX_CP do
            local color = cpColors[i] or cpColors[5]

            -- Main combo point texture
            local cp = cpContainer:CreateTexture(nil, "ARTWORK", nil, 2)
            cp:SetTexture(CP_ROUND_TEXTURE)
            cp:SetVertexColor(color.r, color.g, color.b)
            cp:SetBlendMode("BLEND")
            PixelUtil.SetSize(cp, cpWidth, cpWidth, 1, 1)
            cp:Hide()
            myPlate.cps[i] = cp

            -- Position absolutely from container to avoid staircase effect
            local xOffset = (i - 1) * (cpWidth + spacing)
            cp:SetPoint("LEFT", cpContainer, "LEFT", xOffset, 0)
        end
    else
        -- SQUARE STYLE (simple colored bars)
        local texture = "Interface\\Buttons\\WHITE8X8"
        local cpHeight = 4
        local spacing = 4     -- 3px gap between bars
        local totalWidth = (cpWidth * MAX_CP) + (spacing * (MAX_CP - 1))

        PixelUtil.SetSize(cpContainer, totalWidth, cpHeight, 1, 1)
        cpContainer:ClearAllPoints()
        PixelUtil.SetPoint(cpContainer, "BOTTOM", myPlate.hp, "TOP", offsetX, -1 + offsetY, 1, 1)

        for i = 1, MAX_CP do
            -- Create simple texture for each combo point
            local bar = cpContainer:CreateTexture(nil, "ARTWORK")
            bar:SetTexture(texture)

            -- Set color
            local color = cpColors[i] or cpColors[5]
            bar:SetVertexColor(color.r, color.g, color.b)

            bar:Hide()
            myPlate.cps[i] = bar

            -- Position absolutely from container to avoid staircase effect
            bar:ClearAllPoints()
            PixelUtil.SetSize(bar, cpWidth, cpHeight, 1, 1)
            local xOffset = (i - 1) * (cpWidth + spacing)
            bar:SetPoint("LEFT", cpContainer, "LEFT", xOffset, 0)
        end
    end
end

-- Create health bar on first use (upgrades lite plate to full plate)
local function ApplyMouseoverGlowColor(highlight)
    if not (highlight and highlight.texture) then return end
    highlight.texture:SetVertexColor(
        ns.c_mouseoverGlowColor_r or 1,
        ns.c_mouseoverGlowColor_g or 1,
        ns.c_mouseoverGlowColor_b or 1,
        0.25
    )
end

function ns.UpdateNativeMouseoverPresentation(blizzFrame, hovered)
    if not blizzFrame then return end
    if ns.c_mouseoverGlow == false then hovered = false end
    local cameraLook = type(IsMouselooking) == "function" and IsMouselooking()
    if cameraLook then hovered = false end
    if blizzFrame._isLite then
        if hovered then
            if ns.ShowLiteNameHighlight then
                ns.ShowLiteNameHighlight(blizzFrame, nil, blizzFrame._tpNativeHighlight)
            end
        elseif ns.HideLiteNameHighlight then
            local c = blizzFrame.liteContainer
            local d = c and c.liteNameHighlightDriver
            if d and d.nativeSource then ns.HideLiteNameHighlight(c) end
        end
        return
    end
    local myPlate = blizzFrame.myPlate
    local highlight = myPlate and myPlate.highlight
    if not highlight or myPlate.isPlayer then return end
    if hovered then
        ApplyMouseoverGlowColor(highlight)
        highlight.nativeSource = blizzFrame._tpNativeHighlight
        highlight.elapsed = 0
        highlight:Show()
    elseif highlight.nativeSource then
        highlight.nativeSource = nil
        if cameraLook or not (highlight.unit and UnitExists("mouseover") and UnitIsUnit("mouseover", highlight.unit)) then
            highlight:Hide()
        end
    end
end

local function EnsureFullPlate(myPlate)
    if myPlate.hp then return end  -- Already has health bar

    local hp = CreateFrame("StatusBar", nil, myPlate)
    PixelUtil.SetPoint(hp, "CENTER", myPlate, "CENTER", (ns.c_plateXOffset or 0), 15 + (ns.c_plateYOffset or 0), 1, 1)
    hp:EnableMouse(false)  -- Pass through clicks
    hp:Hide()  -- Start hidden

    -- Set status bar texture FIRST so GetStatusBarTexture() works for absorb anchoring
    hp:SetStatusBarTexture(ns.c_texture)

    local bg = hp:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(hp)
    bg:SetTexture(0, 0, 0, ns.c_backgroundAlpha)
    hp.bg = bg  -- Store reference for background alpha updates

    -- Pixel-perfect 4-texture border (no anti-aliasing shimmer)
    local border = CreateTextureBorder(hp, 1)
    hp.border = border  -- Store reference for border toggle

    -- Absorb bar (uses user's chosen texture with cyan tint, tiled shield overlay on top)
    -- Anchored to health fill texture's right edge so it moves with health
    local absorbBar = hp:CreateTexture(nil, "ARTWORK", nil, 1)
    absorbBar:SetTexture(ns.c_texture)
    absorbBar:SetVertexColor(0.66, 1, 1, 0.7)
    absorbBar:SetPoint("TOPLEFT", hp:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
    absorbBar:SetPoint("BOTTOMLEFT", hp:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    absorbBar:SetWidth(1)
    absorbBar:Hide()
    hp.absorbBar = absorbBar

    -- Incoming heal bar (personal bar only)
    -- Also anchored to health fill, positioned dynamically in UpdateHealPrediction
    local healBar = hp:CreateTexture(nil, "ARTWORK", nil, 1)
    healBar:SetTexture(ns.c_texture)
    healBar:SetVertexColor(0, 0.8, 0.3, 0.5)
    healBar:SetPoint("TOPLEFT", hp:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
    healBar:SetPoint("BOTTOMLEFT", hp:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    healBar:SetWidth(1)
    healBar:Hide()
    hp.healBar = healBar

    -- Tiled shield pattern overlay
    local absorbOverlay = hp:CreateTexture(nil, "ARTWORK", nil, 2)
    absorbOverlay:SetTexture("Interface\\RaidFrame\\Shield-Overlay", true, true)
    absorbOverlay:SetAllPoints(absorbBar)
    absorbOverlay.tileSize = 32
    absorbOverlay:Hide()
    hp.absorbOverlay = absorbOverlay

    -- Over-absorb glow (shown when absorb exceeds remaining health bar space)
    local overAbsorbGlow = hp:CreateTexture(nil, "ARTWORK", nil, 3)
    overAbsorbGlow:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
    overAbsorbGlow:SetBlendMode("ADD")
    overAbsorbGlow:SetAlpha(0.7)
    PixelUtil.SetWidth(overAbsorbGlow, 15, 1)
    PixelUtil.SetPoint(overAbsorbGlow, "TOPLEFT", hp, "TOPRIGHT", -7, 2, 1, 1)
    PixelUtil.SetPoint(overAbsorbGlow, "BOTTOMLEFT", hp, "BOTTOMRIGHT", -7, -2, 1, 1)
    overAbsorbGlow:Hide()
    hp.overAbsorbGlow = overAbsorbGlow

    myPlate.hp = hp

    -- Initialize cache values for UpdatePlateStyle
    myPlate._lastBgAlpha = ns.c_backgroundAlpha
    myPlate._lastWidth = ns.c_width
    myPlate._lastHpHeight = ns.c_hpHeight

    -- MOUSEOVER HIGHLIGHT: Parent to hp (highlights healthbar only, not whole clickbox)
    -- Self-managing highlight frame with its own OnUpdate
    local highlight = CreateFrame("Frame", nil, hp)
    highlight:SetAllPoints(hp)
    highlight:SetFrameLevel(hp:GetFrameLevel() + 1)
    highlight:EnableMouse(false)

    local highlightTexture = highlight:CreateTexture(nil, "OVERLAY")
    highlightTexture:SetTexture("Interface\\Buttons\\WHITE8X8")
    highlightTexture:SetBlendMode("ADD")
    highlightTexture:SetAllPoints(highlight)

    highlight.texture = highlightTexture
    ApplyMouseoverGlowColor(highlight)
    highlight.unit = nil  -- Set when showing
    highlight.elapsed = 0
    highlight:Hide()

    -- OnUpdate: hide when mouse leaves unit
    highlight:SetScript("OnUpdate", function(self, elapsed)
        if ns.c_mouseoverGlow == false then
            self.nativeSource = nil
            self.unit = nil
            self:Hide()
            return
        end
        self.elapsed = (self.elapsed or 0) + elapsed
        local throttle = 0.1 * (ns.c_throttleMultiplier or 1)
        if self.elapsed > throttle then
            self.elapsed = 0
            -- If mouse moved off this unit, hide
            local cameraLook = type(IsMouselooking) == "function" and IsMouselooking()
            local native = self.nativeSource
            local nativeHover = not cameraLook and native and native.IsShown and native:IsShown()
            if cameraLook or (not nativeHover and not (self.unit and UnitExists("mouseover") and UnitIsUnit("mouseover", self.unit))) then
                self.nativeSource = nil
                self:Hide()
            end
        end
    end)

    myPlate.highlight = highlight

    -- Create totem icon frame (parented to myPlate for auto show/hide)
    local totemIconFrame = CreateFrame("Frame", nil, myPlate)
    totemIconFrame:SetFrameLevel(myPlate:GetFrameLevel() - 1)  -- Below plate content
    PixelUtil.SetSize(totemIconFrame, 24, 24, 1, 1)
    PixelUtil.SetPoint(totemIconFrame, "CENTER", myPlate, "CENTER", 0, -10, 1, 1)
    totemIconFrame:EnableMouse(false)
    totemIconFrame:Hide()

    -- Use BACKGROUND layer with low sublevel to render behind text
    local totemIcon = totemIconFrame:CreateTexture(nil, "BACKGROUND", nil, -8)
    totemIcon:SetAllPoints(totemIconFrame)
    totemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- 30% zoom to crop icon border

    myPlate.totemIconFrame = totemIconFrame
    myPlate.totemIcon = totemIcon

    -- Create raid icon (only needed for full plates) - use cached values


    -- Quest icon created on-demand by EnsureQuestIcon()

    -- Re-anchor name based on nameInHealthbar setting
    myPlate.nameText:ClearAllPoints()
    if ns.c_nameInHealthbar then
        -- Inside healthbar: reparent to hp so it renders above statusbar fill
        myPlate.nameText:SetParent(hp)
        myPlate.nameText:SetDrawLayer("OVERLAY", 7)
        PixelUtil.SetPoint(myPlate.nameText, "LEFT", hp, "LEFT", 4, ns.c_nameTextYOffset, 1, 1)
        myPlate.nameText:SetJustifyH("LEFT")
        -- Limit width and disable word wrap for ellipsis truncation
        myPlate.nameText:SetWidth(ns.c_width * 0.6)
        myPlate.nameText:SetWordWrap(false)
        myPlate.nameText:SetNonSpaceWrap(false)
    else
        -- Above healthbar: parent to myPlate, centered
        myPlate.nameText:SetParent(myPlate)
        myPlate.nameText:SetDrawLayer("OVERLAY")
        PixelUtil.SetPoint(myPlate.nameText, "BOTTOM", hp, "TOP", 0, 2 + ns.c_nameTextYOffset, 1, 1)
        myPlate.nameText:SetJustifyH("CENTER")
        myPlate.nameText:SetWidth(0)  -- No width limit
        myPlate.nameText:SetWordWrap(true)
    end
    myPlate._lastNameInHealthbar = ns.c_nameInHealthbar
    myPlate._lastNameTextYOffset = ns.c_nameTextYOffset

    -- Create execute range indicator (vertical line on healthbar)
    local execIndicator = hp:CreateTexture(nil, "OVERLAY")
    execIndicator:SetTexture("Interface\\Buttons\\WHITE8X8")
    execIndicator:SetVertexColor(1, 1, 1, 0.8)  -- White line
    PixelUtil.SetWidth(execIndicator, 2, 1)
    PixelUtil.SetPoint(execIndicator, "TOP", hp, "TOP", 0, 0, 1, 1)
    PixelUtil.SetPoint(execIndicator, "BOTTOM", hp, "BOTTOM", 0, 0, 1, 1)
    execIndicator:Hide()
    myPlate.execIndicator = execIndicator

    -- Create health value text
    local healthText = hp:CreateFontString(nil, "OVERLAY")
    ns:SetFontSafe(healthText, ns.c_font, ns.c_healthValueFontSize, ns.c_fontOutline)
    healthText:SetTextColor(1, 1, 1)
    healthText:SetJustifyV("MIDDLE")
    if ns.c_nameInHealthbar then
        -- Right-aligned inside healthbar
        healthText:ClearAllPoints()
        PixelUtil.SetPoint(healthText, "RIGHT", hp, "RIGHT", -4, 0, 1, 1)
        healthText:SetJustifyH("RIGHT")
    else
        -- Centered (fill parent for proper vertical centering)
        healthText:SetAllPoints(hp)
        healthText:SetJustifyH("CENTER")
    end
    healthText:Hide()  -- Hidden by default, shown when format is not "none"
    myPlate.healthText = healthText

    -- Create threat text (anchored dynamically based on setting)
    local threatText = myPlate:CreateFontString(nil, "OVERLAY")
    ns:SetFontSafe(threatText, ns.c_font, ns.c_threatTextFontSize, ns.c_fontOutline)
    threatText:SetTextColor(1, 1, 1)
    threatText:SetJustifyH("CENTER")
    threatText:SetJustifyV("MIDDLE")
    threatText:Hide()
    myPlate.threatText = threatText

    -- Create level text (right of name, matches name font)
    local levelText = myPlate:CreateFontString(nil, "OVERLAY")
    ns:SetFontSafe(levelText, ns.c_font, ns.c_fontSize, ns.c_fontOutline)
    PixelUtil.SetPoint(levelText, "LEFT", myPlate.nameText, "RIGHT", 2, 0, 1, 1)
    levelText:SetJustifyH("LEFT")
    levelText:SetJustifyV("MIDDLE")
    levelText:Hide()
    myPlate.levelText = levelText

    -- Create classification icon (elite/rare/boss indicator)
    -- Uses atlas textures - placed on separate frame with higher level to ensure it draws above border
    local classifyFrame = CreateFrame("Frame", nil, hp)
    classifyFrame:SetFrameLevel(hp:GetFrameLevel() + 10)
    classifyFrame:EnableMouse(false)
    PixelUtil.SetSize(classifyFrame, 14, 14, 1, 1)
    PixelUtil.SetPoint(classifyFrame, "LEFT", hp, "RIGHT", 2, 0, 1, 1)
    local classifyIcon = classifyFrame:CreateTexture(nil, "ARTWORK")
    PixelUtil.SetSize(classifyIcon, 14, 14, 1, 1)
    PixelUtil.SetPoint(classifyIcon, "CENTER", classifyFrame, "CENTER", 0, 0, 1, 1)
    classifyIcon:Hide()
    myPlate.classifyIcon = classifyIcon
    myPlate.classifyFrame = classifyFrame

    -- Create target glow frame (border style - surrounds healthbar)
    local targetGlow = CreateFrame("Frame", nil, hp)
    PixelUtil.SetPoint(targetGlow, "TOPLEFT", hp, "TOPLEFT", -5, 5, 1, 1)
    PixelUtil.SetPoint(targetGlow, "BOTTOMRIGHT", hp, "BOTTOMRIGHT", 5, -5, 1, 1)
    targetGlow:SetBackdrop({ edgeFile = "Interface\\AddOns\\TurboPlates\\Textures\\GlowTex.tga", edgeSize = 5 })
    targetGlow:SetBackdropBorderColor(1, 1, 1, 0.9)
    targetGlow:SetFrameLevel(hp:GetFrameLevel() - 1)
    targetGlow:EnableMouse(false)
    targetGlow:Hide()
    myPlate.targetGlow = targetGlow

    -- Create target arrows (1 per side, mirrored via TexCoord)
    local targetArrows = {
        left = hp:CreateTexture(nil, "OVERLAY"),
        right = hp:CreateTexture(nil, "OVERLAY"),
    }
    for _, tex in pairs(targetArrows) do
        tex:SetBlendMode("ADD")
        tex:Hide()
    end
    -- Left arrow: points right (towards bar) - normal
    targetArrows.left:SetTexCoord(0, 1, 0, 1)
    -- Right arrow: points left (towards bar) - flipped horizontally
    targetArrows.right:SetTexCoord(1, 0, 0, 1)
    myPlate.targetArrows = targetArrows

    -- Apply styles to new health bar (use PixelUtil for pixel-perfect dimensions)
    PixelUtil.SetWidth(hp, ns.c_width, 1)
    PixelUtil.SetHeight(hp, ns.c_hpHeight, 1)
    hp:SetStatusBarTexture(ns.c_texture)
end

-- =============================================================================
-- PERSONAL RESOURCE BAR - POWER BAR & ADDITIONAL POWER (Druid Mana)
-- =============================================================================

-- Power type colors (matches Blizzard PowerBarColor) - stored in ns to save locals
ns.POWER_COLORS = {
    [0]  = { r = 0.00, g = 0.00, b = 1.00 },  -- Mana (blue)
    [1]  = { r = 1.00, g = 0.00, b = 0.00 },  -- Rage (red)
    [2]  = { r = 1.00, g = 0.50, b = 0.25 },  -- Focus (orange)
    [3]  = { r = 1.00, g = 1.00, b = 0.00 },  -- Energy (yellow)
    [4]  = { r = 0.00, g = 1.00, b = 1.00 },  -- Happiness (cyan) - not used in WotLK
    [5]  = { r = 0.50, g = 0.50, b = 0.50 },  -- Runes (grey)
    [6]  = { r = 0.00, g = 0.82, b = 1.00 },  -- Runic Power (light blue)
}
local POWER_COLORS = ns.POWER_COLORS  -- Local alias for performance

-- Additional power bar index (mana = 0)
ns.ADDITIONAL_POWER_INDEX = 0  -- Mana

-- HERO class power system (consolidated into ns to save locals)
do
    local _, playerClass = UnitClass("player")
    ns.isHeroClass = (playerClass == "HERO")
end

-- HERO power order definitions: { powerType1, powerType2, powerType3 }
-- 0 = Mana, 1 = Rage, 3 = Energy
ns.HERO_POWER_ORDERS = {
    [1] = { 0, 3, 1 },  -- Mana > Energy > Rage
    [2] = { 0, 1, 3 },  -- Mana > Rage > Energy
    [3] = { 3, 0, 1 },  -- Energy > Mana > Rage
    [4] = { 3, 1, 0 },  -- Energy > Rage > Mana
    [5] = { 1, 0, 3 },  -- Rage > Mana > Energy
    [6] = { 1, 3, 0 },  -- Rage > Energy > Mana
}

-- Create power bar on first use
local function EnsurePowerBar(myPlate)
    if myPlate.powerBar then return end
    if not myPlate.hp then return end

    local power = CreateFrame("StatusBar", nil, myPlate)
    PixelUtil.SetPoint(power, "TOPLEFT", myPlate.hp, "BOTTOMLEFT", 0, -1, 1, 1)
    PixelUtil.SetPoint(power, "TOPRIGHT", myPlate.hp, "BOTTOMRIGHT", 0, -1, 1, 1)
    PixelUtil.SetHeight(power, ns.c_personalPowerHeight, 1)
    power:SetStatusBarTexture(ns.c_texture)
    power:SetMinMaxValues(0, 100)
    power:SetValue(100)
    power:EnableMouse(false)

    local bg = power:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(power)
    bg:SetTexture(0, 0, 0, ns.c_backgroundAlpha)
    power.bg = bg

    -- Pixel-perfect 4-texture border
    local border = CreateTextureBorder(power, 1)
    power.border = border

    -- Power text (fake-centered via LEFT+RIGHT span to avoid sub-pixel jitter)
    local powerText = power:CreateFontString(nil, "OVERLAY")
    PixelUtil.SetPoint(powerText, "LEFT", power, "LEFT", 0, 0, 1, 1)
    PixelUtil.SetPoint(powerText, "RIGHT", power, "RIGHT", 0, 0, 1, 1)
    ns:SetFontSafe(powerText, ns.c_font, ns.c_fontSize - 2, ns.c_fontOutline)
    powerText:SetTextColor(1, 1, 1)
    powerText:SetJustifyH("CENTER")
    powerText:SetJustifyV("MIDDLE")
    powerText:Hide()
    power.text = powerText

    power:Hide()  -- Start hidden
    myPlate.powerBar = power
end

-- Create additional power bar on first use (druid mana when shapeshifted)
local function EnsureAdditionalPowerBar(myPlate)
    if myPlate.additionalPowerBar then return end
    if not myPlate.powerBar then return end

    local addPower = CreateFrame("StatusBar", nil, myPlate)
    PixelUtil.SetPoint(addPower, "TOPLEFT", myPlate.powerBar, "BOTTOMLEFT", 0, -1, 1, 1)
    PixelUtil.SetPoint(addPower, "TOPRIGHT", myPlate.powerBar, "BOTTOMRIGHT", 0, -1, 1, 1)
    PixelUtil.SetHeight(addPower, ns.c_personalAdditionalPowerHeight, 1)
    addPower:SetStatusBarTexture(ns.c_texture)
    addPower:SetMinMaxValues(0, 100)
    addPower:SetValue(100)
    addPower:EnableMouse(false)

    -- Always mana color (blue)
    local manaColor = POWER_COLORS[0]
    addPower:SetStatusBarColor(manaColor.r, manaColor.g, manaColor.b)

    local bg = addPower:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(addPower)
    bg:SetTexture(0, 0, 0, ns.c_backgroundAlpha)
    addPower.bg = bg

    -- Pixel-perfect 4-texture border
    local border = CreateTextureBorder(addPower, 1)
    addPower.border = border

    addPower:Hide()  -- Start hidden
    myPlate.additionalPowerBar = addPower
end

-- Check if additional power bar should be shown (druid in shapeshift with mana pool)
local function ShouldShowAdditionalPower()
    if not ns.c_personalShowAdditionalPower then return false end
    if not ns.c_personalShowPower then return false end

    local currentPowerType = UnitPowerType("player")
    local maxMana = UnitPowerMax("player", ns.ADDITIONAL_POWER_INDEX)

    -- Show if: current power is NOT mana AND player has a mana pool
    return currentPowerType ~= ns.ADDITIONAL_POWER_INDEX and maxMana > 0
end

-- Update additional power bar (mana for druids)
local function UpdateAdditionalPowerBar(myPlate)
    if not myPlate.additionalPowerBar then return end

    if not ShouldShowAdditionalPower() then
        myPlate.additionalPowerBar:Hide()
        return
    end

    local mana = UnitPower("player", ns.ADDITIONAL_POWER_INDEX)
    local maxMana = UnitPowerMax("player", ns.ADDITIONAL_POWER_INDEX)

    if maxMana == 0 then
        myPlate.additionalPowerBar:Hide()
        return
    end

    myPlate.additionalPowerBar:SetMinMaxValues(0, maxMana)
    myPlate.additionalPowerBar:SetValue(mana)
    myPlate.additionalPowerBar:Show()
end

-- =============================================================================
-- HERO CLASS - TRIPLE POWER BAR SYSTEM (Mana, Energy, Rage)
-- =============================================================================

-- Create a single HERO power bar (used for all 3)
local function CreateHeroPowerBar(myPlate, powerType, index, anchor)
    local height = ns.c_personalPowerHeight

    local bar = CreateFrame("StatusBar", nil, myPlate)
    bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -1)
    bar:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -1)
    bar:SetHeight(height)
    bar:SetStatusBarTexture(ns.c_texture)
    bar:SetMinMaxValues(0, 100)
    bar:SetValue(100)
    bar:EnableMouse(false)
    bar.powerType = powerType
    bar.index = index

    local color = ns.POWER_COLORS[powerType] or ns.POWER_COLORS[0]
    bar:SetStatusBarColor(color.r, color.g, color.b)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(0, 0, 0, ns.c_backgroundAlpha)
    bar.bg = bg

    local border = CreateTextureBorder(bar, 1)
    bar.border = border

    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetPoint("LEFT", bar, "LEFT", 0, 0)
    text:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    local powerFontSize = max(ns.c_fontSize - 2, 6)
    ns:SetFontSafe(text, ns.c_font, powerFontSize, ns.c_fontOutline)
    text:SetTextColor(1, 1, 1)
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:Hide()
    bar.text = text

    bar:Hide()
    return bar
end

-- Position all HERO bars (chained)
local function PositionHeroPowerBars(myPlate)
    if not myPlate.heroPowerBars or not myPlate.hp then return end
    local height = ns.c_personalPowerHeight

    for i = 1, 3 do
        local bar = myPlate.heroPowerBars[i]
        if bar then
            bar:ClearAllPoints()
            local anchor = (i == 1) and myPlate.hp or myPlate.heroPowerBars[i - 1]
            bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -1)
            bar:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -1)
            bar:SetHeight(height)
        end
    end
end

-- Ensure HERO power bars exist (creates all 3)
local function EnsureHeroPowerBars(myPlate)
    if myPlate.heroPowerBars then return end
    if not myPlate.hp then return end

    myPlate.heroPowerBars = {}
    local order = ns.HERO_POWER_ORDERS[ns.c_personalHeroPowerOrder] or ns.HERO_POWER_ORDERS[1]

    local anchor = myPlate.hp
    for i = 1, 3 do
        local bar = CreateHeroPowerBar(myPlate, order[i], i, anchor)
        myPlate.heroPowerBars[i] = bar
        anchor = bar
    end
end

-- Update a single HERO power bar
local function UpdateSingleHeroPowerBar(bar)
    if not bar then return end

    local powerType = bar.powerType
    local power = UnitPower("player", powerType)
    local maxPower = UnitPowerMax("player", powerType)

    if maxPower == 0 then
        bar:Hide()
        if bar.text then bar.text:Hide() end
        return false
    end

    bar:SetMinMaxValues(0, maxPower)
    bar:SetValue(power)

    -- Update text using same format as standard power bar
    if bar.text then
        local powerFmt = ns.c_personalPowerFormat
        if powerFmt and powerFmt ~= "none" then
            local text = ""
            local percentInt = ceil((power / maxPower) * 100)
            local percentStr = percentCache[percentInt] or percentCache[100]
            local deficit = maxPower - power
            local atFullPower = (power == maxPower)
            local hideWhenFull = ns.c_hidePercentWhenFull
            local curStr = TruncateValue(power)

            if powerFmt == "current" then
                text = curStr
            elseif powerFmt == "percent" then
                if atFullPower and hideWhenFull then
                    text = ""
                else
                    text = percentStr
                end
            elseif powerFmt == "current-max" then
                local maxStr = TruncateValue(maxPower)
                text = GetCompositeFormat(curStr, maxStr, nil)
            elseif powerFmt == "current-max-percent" then
                local maxStr = TruncateValue(maxPower)
                if atFullPower and hideWhenFull then
                    text = GetCompositeFormat(curStr, maxStr, nil)
                else
                    text = GetCompositeFormat(curStr, maxStr, percentStr)
                end
            elseif powerFmt == "current-percent" then
                if atFullPower and hideWhenFull then
                    text = curStr
                else
                    text = GetCurrentPercentFormat(curStr, percentStr)
                end
            elseif powerFmt == "deficit" then
                if deficit > 0 then
                    text = GetDeficitFormat(TruncateValue(deficit))
                else
                    text = ""
                end
            elseif powerFmt == "current-deficit" then
                if deficit > 0 then
                    text = GetCurrentDeficitFormat(curStr, TruncateValue(deficit))
                else
                    text = curStr
                end
            elseif powerFmt == "percent-deficit" then
                if deficit > 0 then
                    text = GetPercentDeficitFormat(percentStr, TruncateValue(deficit))
                else
                    if hideWhenFull then
                        text = ""
                    else
                        text = percentStr
                    end
                end
            end

            if text ~= "" then
                bar.text:SetText(text)
                bar.text:Show()
            else
                bar.text:Hide()
            end
        else
            bar.text:Hide()
        end
    end

    bar:Show()
    return true
end

-- Update all HERO power bars
local function UpdateHeroPowerBars(myPlate)
    if not myPlate.heroPowerBars then return end
    if not ns.c_personalShowPower then
        for i = 1, 3 do
            if myPlate.heroPowerBars[i] then
                myPlate.heroPowerBars[i]:Hide()
            end
        end
        return
    end

    for i = 1, 3 do
        UpdateSingleHeroPowerBar(myPlate.heroPowerBars[i])
    end
end

-- Reorder HERO power bars when setting changes
local function ReorderHeroPowerBars(myPlate)
    if not myPlate.heroPowerBars then return end

    local order = ns.HERO_POWER_ORDERS[ns.c_personalHeroPowerOrder] or ns.HERO_POWER_ORDERS[1]

    for i = 1, 3 do
        local bar = myPlate.heroPowerBars[i]
        if bar then
            bar.powerType = order[i]
            local color = ns.POWER_COLORS[order[i]] or ns.POWER_COLORS[0]
            bar:SetStatusBarColor(color.r, color.g, color.b)
        end
    end

    PositionHeroPowerBars(myPlate)
end

-- Export for external use
ns.EnsureHeroPowerBars = EnsureHeroPowerBars
ns.UpdateHeroPowerBars = UpdateHeroPowerBars
ns.ReorderHeroPowerBars = ReorderHeroPowerBars

-- Update power bar values and color
local function UpdatePowerBar(myPlate, unit)
    -- HERO class uses triple power bar system
    if ns.isHeroClass then
        -- Hide standard power bar for HERO
        if myPlate.powerBar then myPlate.powerBar:Hide() end
        if myPlate.additionalPowerBar then myPlate.additionalPowerBar:Hide() end

        -- Hero bars only on personal plate
        if not myPlate.isPlayer then
            if myPlate.heroPowerBars then
                for i = 1, 3 do
                    if myPlate.heroPowerBars[i] then
                        myPlate.heroPowerBars[i]:Hide()
                    end
                end
            end
            return
        end

        if not ns.c_personalShowPower then
            if myPlate.heroPowerBars then
                for i = 1, 3 do
                    if myPlate.heroPowerBars[i] then
                        myPlate.heroPowerBars[i]:Hide()
                    end
                end
            end
            return
        end

        -- Ensure HERO bars exist and update them
        local wasNew = not myPlate.heroPowerBars
        EnsureHeroPowerBars(myPlate)
        UpdateHeroPowerBars(myPlate)
        if wasNew and myPlate.heroPowerBars then
            ns:UpdatePersonalBorder()
        end
        return
    end

    -- Standard power bar logic for non-HERO classes
    if not myPlate.powerBar then return end
    if not ns.c_personalShowPower then
        myPlate.powerBar:Hide()
        if myPlate.additionalPowerBar then myPlate.additionalPowerBar:Hide() end
        return
    end

    local powerType = UnitPowerType(unit)
    local power = UnitPower(unit)
    local maxPower = UnitPowerMax(unit)

    if maxPower == 0 then
        myPlate.powerBar:Hide()
        return
    end

    myPlate.powerBar:SetMinMaxValues(0, maxPower)
    myPlate.powerBar:SetValue(power)

    -- Color by power type
    if ns.c_personalPowerColorByType then
        local color = POWER_COLORS[powerType] or POWER_COLORS[0]
        myPlate.powerBar:SetStatusBarColor(color.r, color.g, color.b)
    else
        myPlate.powerBar:SetStatusBarColor(0, 0.5, 1)  -- Default blue
    end

    -- Update power text if format is set
    -- Uses cached percent strings
    local powerFmt = ns.c_personalPowerFormat
    if powerFmt and powerFmt ~= "none" then
        local text = ""
        local percentInt = ceil((power / maxPower) * 100)
        local percentStr = percentCache[percentInt] or percentCache[100]
        local deficit = maxPower - power
        local atFullPower = (power == maxPower)
        local hideWhenFull = ns.c_hidePercentWhenFull  -- User setting (default false = show 100%)

        local curStr = TruncateValue(power)

        if powerFmt == "current" then
            text = curStr
        elseif powerFmt == "percent" then
            if atFullPower and hideWhenFull then
                text = ""
            else
                text = percentStr
            end
        elseif powerFmt == "current-max" then
            local maxStr = TruncateValue(maxPower)
            text = GetCompositeFormat(curStr, maxStr, nil)
        elseif powerFmt == "current-max-percent" then
            local maxStr = TruncateValue(maxPower)
            if atFullPower and hideWhenFull then
                text = GetCompositeFormat(curStr, maxStr, nil)
            else
                text = GetCompositeFormat(curStr, maxStr, percentStr)
            end
        elseif powerFmt == "current-percent" then
            if atFullPower and hideWhenFull then
                text = curStr
            else
                text = GetCurrentPercentFormat(curStr, percentStr)
            end
        elseif powerFmt == "deficit" then
            if deficit > 0 then
                text = GetDeficitFormat(TruncateValue(deficit))
            else
                text = ""  -- No deficit at full power
            end
        elseif powerFmt == "current-deficit" then
            if deficit > 0 then
                text = GetCurrentDeficitFormat(curStr, TruncateValue(deficit))
            else
                text = curStr
            end
        elseif powerFmt == "percent-deficit" then
            if deficit > 0 then
                text = GetPercentDeficitFormat(percentStr, TruncateValue(deficit))
            else
                if hideWhenFull then
                    text = ""
                else
                    text = percentStr
                end
            end
        end

        if text ~= "" then
            myPlate.powerBar.text:SetText(text)
            myPlate.powerBar.text:Show()
        else
            myPlate.powerBar.text:Hide()
        end
    else
        myPlate.powerBar.text:Hide()
    end

    myPlate.powerBar:Show()

    -- Update additional power bar (druid mana)
    if myPlate.additionalPowerBar or ShouldShowAdditionalPower() then
        local wasNew = not myPlate.additionalPowerBar
        EnsureAdditionalPowerBar(myPlate)
        UpdateAdditionalPowerBar(myPlate)
        -- If additional power bar was just created, update its border to match style
        if wasNew and myPlate.additionalPowerBar then
            ns:UpdatePersonalBorder()
        end
    end
end

-- Export for event handling
ns.UpdatePowerBar = UpdatePowerBar
ns.UpdateAdditionalPowerBar = UpdateAdditionalPowerBar

-- Create castbar on first use
local function EnsureCastbar(myPlate)
    if myPlate.castbar then return end
    if not myPlate.hp then return end  -- Need hp for anchoring
    if ns.CreateCastbar then
        ns:CreateCastbar(myPlate)
        -- Apply castbar styles (use cached values)
        if myPlate.castbar then
            local iconSize = ns.c_castHeight
            local showIcon = ns.c_showCastIcon
            local castbarWidth = showIcon and (ns.c_width - iconSize - 2) or ns.c_width

            PixelUtil.SetWidth(myPlate.castbar, castbarWidth, 1)
            PixelUtil.SetHeight(myPlate.castbar, ns.c_castHeight, 1)
            myPlate.castbar:SetStatusBarTexture(ns.c_texture)
            myPlate.castbar:ClearAllPoints()

            -- Update spark size based on castbar height
            if myPlate.castbar.spark then
                PixelUtil.SetSize(myPlate.castbar.spark, 16, ns.c_castHeight * 2, 1, 1)
            end

            if showIcon then
                PixelUtil.SetPoint(myPlate.castbar, "TOPLEFT", myPlate.hp, "BOTTOMLEFT", iconSize + 2, -2 + (ns.c_castbarYOffset or 0), 1, 1)
                -- Position and size icon
                if myPlate.castbar.icon then
                    PixelUtil.SetSize(myPlate.castbar.icon, iconSize, iconSize, 1, 1)
                    myPlate.castbar.icon:ClearAllPoints()
                    PixelUtil.SetPoint(myPlate.castbar.icon, "RIGHT", myPlate.castbar, "LEFT", -2, 0, 1, 1)
                end
                -- Position icon border (same size as icon, border textures extend outside)
                if myPlate.castbar.iconBorder then
                    myPlate.castbar.iconBorder:ClearAllPoints()
                    myPlate.castbar.iconBorder:SetAllPoints(myPlate.castbar.icon)
                end
            else
                PixelUtil.SetPoint(myPlate.castbar, "TOP", myPlate.hp, "BOTTOM", 0, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            end
        end
    end
end

-- Current target's plate and GUID (GUID is source of truth for identity)
-- Exposed to namespace so Core.lua can access for alpha dimming
ns.currentTargetPlate = nil
ns.currentTargetGUID = nil
-- Player's personal nameplate
local personalPlateRef = nil

-- Helper: Find myPlate by GUID (for GUID-based target validation)
local function GetPlateByGUID(guid)
    if not guid then return nil end
    for nameplate in C_NamePlateManager.EnumerateActiveNamePlates() do
        local unit = nameplate._unit
        if unit and UnitGUID(unit) == guid then
            local myPlate = nameplate.myPlate
            -- Skip personal/lite/name-only plates
            if myPlate and not myPlate.isPlayer and not nameplate._isLite and not myPlate.isNameOnly then
                return myPlate
            end
        end
    end
    return nil
end

-- Clear personal plate reference (called from Core.lua OnNamePlateRemoved)
function ns:ClearPersonalPlateRef()
    personalPlateRef = nil
end

function ns:GetPersonalPlateRef()
    return personalPlateRef
end

-- Clean up combo points on personal bar (called when settings change)
function ns:CleanupPersonalComboPoints()
    if personalPlateRef and personalPlateRef.cps then
        for i = 1, #personalPlateRef.cps do
            personalPlateRef.cps[i]:Hide()
        end
    end
end

-- Clean up combo points on target plate (called when settings change)
function ns:CleanupTargetComboPoints()
    if ns.currentTargetPlate and ns.currentTargetPlate.cps then
        for i = 1, #ns.currentTargetPlate.cps do
            ns.currentTargetPlate.cps[i]:Hide()
        end
    end
end

-- Update combo points on personal resource bar
local function UpdatePersonalComboPoints()
    -- If combo points disabled or personal mode off, hide them on personal plate
    if not ns.c_showComboPoints or not ns.c_cpOnPersonalBar then
        if personalPlateRef and personalPlateRef.cps then
            for i = 1, #personalPlateRef.cps do
                personalPlateRef.cps[i]:Hide()
            end
        end
        return
    end

    if not personalPlateRef then return end

    -- Ensure combo points exist on personal plate (true = personal mode)
    EnsureComboPoints(personalPlateRef, true)

    if not personalPlateRef.cps then return end

    -- Get current combo points (works even without target if player has points stored)
    local points = GetComboPoints("player", "target") or 0
    local numCPs = #personalPlateRef.cps

    for i = 1, numCPs do
        if i <= points then
            personalPlateRef.cps[i]:Show()
        else
            personalPlateRef.cps[i]:Hide()
        end
    end
end

-- Expose for OptionsGUI to call when settings change
function ns:UpdatePersonalComboPoints()
    UpdatePersonalComboPoints()
end

-- =============================================================================
-- PERSONAL BAR DEBUFF BORDER COLORS
-- Same as aura border colors for consistency
-- =============================================================================
ns.PERSONAL_DEBUFF_COLORS = {
    Magic   = { 0.20, 0.60, 1.00 },  -- Blue
    Curse   = { 0.60, 0.00, 1.00 },  -- Purple
    Disease = { 0.60, 0.40, 0.00 },  -- Brown
    Poison  = { 0.00, 0.60, 0.00 },  -- Green
}
local PERSONAL_DEBUFF_COLORS = ns.PERSONAL_DEBUFF_COLORS  -- Local alias

-- Class-based debuff priorities (what each class wants to dispel first)
ns.CLASS_DEBUFF_PRIORITIES = {
    DRUID   = { Curse = 5, Poison = 4, Magic = 3, Disease = 2 },
    PALADIN = { Magic = 5, Disease = 4, Curse = 3, Poison = 2 },
    SHAMAN  = { Poison = 5, Disease = 4, Magic = 3, Curse = 2 },
    MAGE    = { Curse = 5, Magic = 4, Poison = 3, Disease = 2 },
    PRIEST  = { Magic = 5, Curse = 4, Poison = 3, Disease = 2 },
}
ns.DEFAULT_PRIORITIES = { Magic = 5, Curse = 4, Disease = 3, Poison = 2 }

-- What each class can remove
ns.CLASS_REMOVABLE = {
    DRUID   = { Curse = true, Poison = true },
    PALADIN = { Magic = true, Disease = true },
    SHAMAN  = { Poison = true, Disease = true },
    MAGE    = { Curse = true },
    PRIEST  = { Magic = true, Curse = true },
}

-- Cache player class for debuff lookups
do
    local _, pClass = UnitClass("player")
    ns.playerClassForDebuffs = pClass
end

-- Get highest priority debuff type on player (for border coloring)
-- onlyRemovable: if true, only considers debuffs the player class can remove
local function GetPlayerDebuffType(onlyRemovable)
    local hasDebuff = false
    local highestPriority = nil
    local priorities = ns.CLASS_DEBUFF_PRIORITIES[ns.playerClassForDebuffs] or ns.DEFAULT_PRIORITIES
    local removable = ns.CLASS_REMOVABLE[ns.playerClassForDebuffs] or {}
    local currentPriority = 0

    for i = 1, 40 do
        local name, _, _, _, debuffType = UnitDebuff("player", i)
        if not name then break end  -- No more debuffs

        if debuffType then
            -- If onlyRemovable mode, skip non-removable types for this class
            if onlyRemovable and not removable[debuffType] then
                -- Skip this debuff, not removable by this class
            else
                hasDebuff = true
                local prio = priorities[debuffType] or 1
                if prio > currentPriority then
                    currentPriority = prio
                    highestPriority = debuffType
                end
            end
        end
        -- Physical/none debuffs are intentionally ignored for border coloring
    end

    return hasDebuff, highestPriority
end

-- Update personal bar health border based on borderStyle setting
-- Handles hp, power, additionalPower, and HERO power bars together
function ns:UpdatePersonalBorder()
    if not personalPlateRef then return end

    local hpBorder = personalPlateRef.hp and personalPlateRef.hp.border
    local powerBorder = personalPlateRef.powerBar and personalPlateRef.powerBar.border
    local addPowerBorder = personalPlateRef.additionalPowerBar and personalPlateRef.additionalPowerBar.border

    -- HERO class power bar borders
    local heroBorders = {}
    if personalPlateRef.heroPowerBars then
        for i = 1, 3 do
            if personalPlateRef.heroPowerBars[i] then
                heroBorders[i] = personalPlateRef.heroPowerBars[i].border
            end
        end
    end

    local style = ns.c_personalBorderStyle

    -- Determine if tight spacing is needed (no visible borders)
    -- True for "none" always, and for "debuff_only" when no debuff
    local hideBorders = false
    if style == "none" then
        hideBorders = true
    elseif style == "debuff_only" then
        local _, debuffType = GetPlayerDebuffType(false)
        hideBorders = not debuffType
    end

    -- Helper to show all borders with a color
    local function ShowAllBorders(r, g, b)
        if hpBorder then
            hpBorder:SetColor(r, g, b, 1)
            hpBorder:Show()
        end
        if powerBorder then
            powerBorder:SetColor(r, g, b, 1)
            powerBorder:Show()
            -- Hide top border to avoid double-thickness with HP's bottom border
            powerBorder.top:Hide()
        end
        if addPowerBorder then
            addPowerBorder:SetColor(r, g, b, 1)
            addPowerBorder:Show()
            -- Hide top border to avoid double-thickness with power bar's bottom border
            addPowerBorder.top:Hide()
        end
        -- HERO power bars
        for i = 1, 3 do
            if heroBorders[i] then
                heroBorders[i]:SetColor(r, g, b, 1)
                heroBorders[i]:Show()
                if i > 1 or (i == 1 and personalPlateRef.hp) then
                    heroBorders[i].top:Hide()
                end
            end
        end
    end

    -- Helper to hide all borders
    local function HideAllBorders()
        if hpBorder then hpBorder:Hide() end
        if powerBorder then powerBorder:Hide() end
        if addPowerBorder then addPowerBorder:Hide() end
        for i = 1, 3 do
            if heroBorders[i] then heroBorders[i]:Hide() end
        end
    end

    -- Adjust bar spacing based on border visibility
    -- When borders are hidden, reduce the gap between bars
    if personalPlateRef.powerBar and personalPlateRef.hp then
        if hideBorders then
            personalPlateRef.powerBar:SetPoint("TOPLEFT", personalPlateRef.hp, "BOTTOMLEFT", 0, 0)
            personalPlateRef.powerBar:SetPoint("TOPRIGHT", personalPlateRef.hp, "BOTTOMRIGHT", 0, 0)
        else
            -- -1 offset: power bar's top border is hidden, so move 1px closer
            personalPlateRef.powerBar:SetPoint("TOPLEFT", personalPlateRef.hp, "BOTTOMLEFT", 0, -1)
            personalPlateRef.powerBar:SetPoint("TOPRIGHT", personalPlateRef.hp, "BOTTOMRIGHT", 0, -1)
        end
    end
    if personalPlateRef.additionalPowerBar and personalPlateRef.powerBar then
        if hideBorders then
            personalPlateRef.additionalPowerBar:SetPoint("TOPLEFT", personalPlateRef.powerBar, "BOTTOMLEFT", 0, 0)
            personalPlateRef.additionalPowerBar:SetPoint("TOPRIGHT", personalPlateRef.powerBar, "BOTTOMRIGHT", 0, 0)
        else
            personalPlateRef.additionalPowerBar:SetPoint("TOPLEFT", personalPlateRef.powerBar, "BOTTOMLEFT", 0, -1)
            personalPlateRef.additionalPowerBar:SetPoint("TOPRIGHT", personalPlateRef.powerBar, "BOTTOMRIGHT", 0, -1)
        end
    end
    -- HERO power bar spacing
    if personalPlateRef.heroPowerBars then
        for i = 1, 3 do
            local bar = personalPlateRef.heroPowerBars[i]
            if bar then
                local anchor = (i == 1) and personalPlateRef.hp or personalPlateRef.heroPowerBars[i - 1]
                if anchor then
                    bar:ClearAllPoints()
                    if hideBorders then
                        bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
                        bar:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
                    else
                        bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -1)
                        bar:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -1)
                    end
                end
            end
        end
    end

    if style == "none" then
        -- No borders at all
        HideAllBorders()
    elseif style == "black" then
        -- Default black border, always visible
        ShowAllBorders(0, 0, 0)
    elseif style == "debuff" then
        -- Black border by default, colored when debuff present
        local _, debuffType = GetPlayerDebuffType(false)
        if debuffType then
            local color = PERSONAL_DEBUFF_COLORS[debuffType]
            if color then
                ShowAllBorders(color[1], color[2], color[3])
            else
                ShowAllBorders(0, 0, 0)
            end
        else
            ShowAllBorders(0, 0, 0)
        end
    elseif style == "debuff_only" then
        -- Hidden unless debuff present
        local _, debuffType = GetPlayerDebuffType(false)
        if debuffType then
            local color = PERSONAL_DEBUFF_COLORS[debuffType]
            if color then
                ShowAllBorders(color[1], color[2], color[3])
            else
                HideAllBorders()
            end
        else
            HideAllBorders()
        end
    elseif style == "removable" then
        -- Black border normally, colored when self-removable debuff present
        local _, debuffType = GetPlayerDebuffType(true)
        if debuffType then
            local color = PERSONAL_DEBUFF_COLORS[debuffType]
            if color then
                ShowAllBorders(color[1], color[2], color[3])
            else
                ShowAllBorders(0, 0, 0)
            end
        else
            ShowAllBorders(0, 0, 0)
        end
    end
end

-- Update target glow color and visibility for a plate
local function UpdateTargetGlow(myPlate, isTarget)
    -- Skip target glow on personal plate (player doesn't need target indicator on themselves)
    if myPlate.isPlayer then return end
    -- Bail on a half-built plate: the thick/thin outline parents to myPlate.hp and
    -- reads its frame level, so a nil health bar throws "attempt to index field
    -- 'hp'". hp is a constructor field and is normally always present; it can be
    -- missing only if plate setup was aborted partway (e.g. an earlier error), so
    -- there's nothing to glow yet. A later update re-runs this once the plate is whole.
    if not myPlate.hp then return end

    local glowStyle = ns.c_targetGlow
    local arrowStyle = ns.c_targetArrow

    -- Hide all glow elements first
    if myPlate.targetGlow then myPlate.targetGlow:Hide() end
    if myPlate.targetArrows then
        myPlate.targetArrows.left:Hide()
        myPlate.targetArrows.right:Hide()
    end
    if myPlate.thickOutline then
        myPlate.thickOutline:Hide()
        -- Hide both cached borders
        if myPlate.thickOutline.borders then
            if myPlate.thickOutline.borders.thick then myPlate.thickOutline.borders.thick:Hide() end
            if myPlate.thickOutline.borders.thin then myPlate.thickOutline.borders.thin:Hide() end
        end
    end

    if not isTarget then
        return
    end

    -- Arrow styles
    local arrowTextures = {
        arrows_thin = "Interface\\AddOns\\TurboPlates\\Textures\\arrow_thin_right_64.tga",
        arrows_normal = "Interface\\AddOns\\TurboPlates\\Textures\\arrow_single_right_64.tga",
        arrows_double = "Interface\\AddOns\\TurboPlates\\Textures\\arrow_double_right_64.tga",
    }

    -- Show arrows if enabled
    if arrowTextures[arrowStyle] then
        local arrows = myPlate.targetArrows
        local hp = myPlate.hp
        if arrows and hp then
            -- Set texture for both arrows
            local texPath = arrowTextures[arrowStyle]
            arrows.left:SetTexture(texPath)
            arrows.right:SetTexture(texPath)

            -- Size scales with HP bar height
            local effectiveScale = hp:GetEffectiveScale()
            local hpHeight = ns.c_hpHeight or 8
            local arrowHeight = PixelUtil.GetNearestPixelSize(hpHeight * 1.3, effectiveScale, 1)
            local arrowWidth = PixelUtil.GetNearestPixelSize(arrowHeight * 1, effectiveScale, 1)

            local sizeKey = arrowStyle .. ":" .. arrowWidth .. ":" .. arrowHeight .. ":" .. hpHeight
            if arrows._lastSizeKey ~= sizeKey then
                PixelUtil.SetSize(arrows.left, arrowWidth, arrowHeight, 1, 1)
                PixelUtil.SetSize(arrows.right, arrowWidth, arrowHeight, 1, 1)

                arrows.left:ClearAllPoints()
                arrows.right:ClearAllPoints()

                -- Position arrows overlapping the bar edges
                PixelUtil.SetPoint(arrows.right, "LEFT", hp, "RIGHT", -3, 0, 1, 1)
                PixelUtil.SetPoint(arrows.left, "RIGHT", hp, "LEFT", 3, 0, 1, 1)

                arrows._lastSizeKey = sizeKey
            end

            local r, g, b = ns.c_targetGlowColor_r, ns.c_targetGlowColor_g, ns.c_targetGlowColor_b
            arrows.left:SetVertexColor(r, g, b, 0.9)
            arrows.right:SetVertexColor(r, g, b, 0.9)

            arrows.left:Show()
            arrows.right:Show()
        end
    end

    -- Show glow/border if enabled (independent of arrows)
    if glowStyle == "thick" or glowStyle == "thin" then
        -- Thick/Thin outline: solid colored border around healthbar (pixel-perfect texture-based)
        -- Positioned OUTSIDE the existing 1px black hp.border
        local thickness = (glowStyle == "thick") and 3 or 1.5
        local innerOffset = 1  -- Account for hp's 1px black border

        if not myPlate.thickOutline then
            -- Create container frame for the border (created once per plate)
            local outline = CreateFrame("Frame", nil, myPlate.hp)
            outline:SetFrameLevel(myPlate.hp:GetFrameLevel() + 2)
            outline:EnableMouse(false)
            outline.borders = {}  -- Cache for thick/thin borders
            myPlate.thickOutline = outline
        end

        local outline = myPlate.thickOutline
        local borderKey = glowStyle  -- "thick" or "thin" as cache key
        local currentScale = myPlate.hp:GetEffectiveScale()

        -- Invalidate cache if scale changed (prevents stale pixel sizes)
        if outline._lastScale and outline._lastScale ~= currentScale then
            outline.borders = {}
            outline._lastScale = nil
        end

        -- Use cached border or create new one (each thickness created only once)
        if not outline.borders[borderKey] then
            -- Create border positioned outside the existing 1px hp.border
            local pixelSize = PixelUtil.GetNearestPixelSize(thickness, myPlate.hp:GetEffectiveScale(), 1)
            local offsetSize = PixelUtil.GetNearestPixelSize(innerOffset, myPlate.hp:GetEffectiveScale(), 1)
            local totalOffset = pixelSize + offsetSize  -- Border extends outside the 1px black border

            local border = setmetatable({}, ns.BorderMethods)

            border.top = myPlate.hp:CreateTexture(nil, "BORDER")
            border.top:SetTexture(ns.BORDER_TEX)
            border.top:SetPoint("TOPLEFT", myPlate.hp, "TOPLEFT", -totalOffset, totalOffset)
            border.top:SetPoint("TOPRIGHT", myPlate.hp, "TOPRIGHT", totalOffset, totalOffset)
            PixelUtil.SetHeight(border.top, pixelSize, 1)

            border.bottom = myPlate.hp:CreateTexture(nil, "BORDER")
            border.bottom:SetTexture(ns.BORDER_TEX)
            border.bottom:SetPoint("BOTTOMLEFT", myPlate.hp, "BOTTOMLEFT", -totalOffset, -totalOffset)
            border.bottom:SetPoint("BOTTOMRIGHT", myPlate.hp, "BOTTOMRIGHT", totalOffset, -totalOffset)
            PixelUtil.SetHeight(border.bottom, pixelSize, 1)

            border.left = myPlate.hp:CreateTexture(nil, "BORDER")
            border.left:SetTexture(ns.BORDER_TEX)
            border.left:SetPoint("TOPLEFT", myPlate.hp, "TOPLEFT", -totalOffset, offsetSize)
            border.left:SetPoint("BOTTOMLEFT", myPlate.hp, "BOTTOMLEFT", -totalOffset, -offsetSize)
            PixelUtil.SetWidth(border.left, pixelSize, 1)

            border.right = myPlate.hp:CreateTexture(nil, "BORDER")
            border.right:SetTexture(ns.BORDER_TEX)
            border.right:SetPoint("TOPRIGHT", myPlate.hp, "TOPRIGHT", totalOffset, offsetSize)
            border.right:SetPoint("BOTTOMRIGHT", myPlate.hp, "BOTTOMRIGHT", totalOffset, -offsetSize)
            PixelUtil.SetWidth(border.right, pixelSize, 1)

            outline.borders[borderKey] = border
            outline._lastScale = currentScale
        end

        -- Hide the other thickness if shown
        local otherKey = (borderKey == "thick") and "thin" or "thick"
        if outline.borders[otherKey] then
            outline.borders[otherKey]:Hide()
        end

        -- Show and color the active border (forceAlpha to allow full brightness)
        local border = outline.borders[borderKey]
        border:SetColor(
            ns.c_targetGlowColor_r,
            ns.c_targetGlowColor_g,
            ns.c_targetGlowColor_b,
            1,
            true  -- forceAlpha: bypass BORDER_ALPHA clamp for target highlight
        )
        border:Show()
        outline:Show()
    elseif glowStyle == "border" then
        -- Border glow style: glow surrounding the healthbar
        if not myPlate.targetGlow then return end
        local glow = myPlate.targetGlow

        glow:ClearAllPoints()
        glow:SetPoint("TOPLEFT", myPlate.hp, "TOPLEFT", -5, 5)
        glow:SetPoint("BOTTOMRIGHT", myPlate.hp, "BOTTOMRIGHT", 5, -5)
        glow:SetBackdrop({ edgeFile = "Interface\\AddOns\\TurboPlates\\Textures\\GlowTex.tga", edgeSize = 5 })
        glow:SetBackdropBorderColor(
            ns.c_targetGlowColor_r,
            ns.c_targetGlowColor_g,
            ns.c_targetGlowColor_b,
            0.9
        )
        glow:Show()
    end
end

-- Clear target glow from a plate (for cleanup on removal)
function ns.ClearTargetGlow(myPlate)
    if not myPlate then return end
    if myPlate.targetGlow then myPlate.targetGlow:Hide() end
    if myPlate.targetArrows then
        myPlate.targetArrows.left:Hide()
        myPlate.targetArrows.right:Hide()
    end
    if myPlate.thickOutline then
        myPlate.thickOutline:Hide()
        if myPlate.thickOutline.borders then
            if myPlate.thickOutline.borders.thick then myPlate.thickOutline.borders.thick:Hide() end
            if myPlate.thickOutline.borders.thin then myPlate.thickOutline.borders.thin:Hide() end
        end
    end
end

-- ============================================================================
-- ARENA TARGETING ME INDICATOR
-- Highlights nameplates of hostile units that are targeting the player
-- Only active in Arena (uses arena1target, arena2target, etc. tokens)
-- ============================================================================

-- Create the targeting me glow frame
local function EnsureTargetingMeGlow(myPlate)
    if myPlate.targetingMeGlow then return end
    if not myPlate.hp then return end

    local glow = CreateFrame("Frame", nil, myPlate.hp)
    glow:SetPoint("TOPLEFT", myPlate.hp, "TOPLEFT", -5, 5)
    glow:SetPoint("BOTTOMRIGHT", myPlate.hp, "BOTTOMRIGHT", 5, -5)
    glow:SetBackdrop({ edgeFile = "Interface\\AddOns\\TurboPlates\\Textures\\GlowTex.tga", edgeSize = 5 })
    glow:SetBackdropBorderColor(1, 0.2, 0.2, 0.9)
    glow:SetFrameLevel(myPlate.hp:GetFrameLevel() - 1)
    glow:EnableMouse(false)
    glow:Hide()
    myPlate.targetingMeGlow = glow
end

-- Forward declaration for UpdateColor (defined later)
local UpdateColor

-- Update the visual indicator for "targeting me" state
local function UpdateTargetingMeVisual(myPlate, isTargetingMe)
    if not myPlate or not myPlate.hp then return end

    local indicator = ns.c_targetingMeIndicator
    if indicator == "disabled" then
        -- Clean up any active indicators
        if myPlate.targetingMeGlow then myPlate.targetingMeGlow:Hide() end
        if myPlate._targetingMeActive then
            if myPlate.unit and UpdateColor then UpdateColor(myPlate.unit) end
            if myPlate.nameText and myPlate.unit then
                local friendly = UnitIsFriend("player", myPlate.unit)
                local _, class = UnitClass(myPlate.unit)
                local cc = ns.c_classColoredName and class and ns.GetClassColor(class)
                if cc then myPlate.nameText:SetTextColor(cc.r, cc.g, cc.b)
                elseif friendly then myPlate.nameText:SetTextColor(ns.c_friendlyNameColor_r, ns.c_friendlyNameColor_g, ns.c_friendlyNameColor_b)
                else myPlate.nameText:SetTextColor(ns.c_hostileNameColor_r, ns.c_hostileNameColor_g, ns.c_hostileNameColor_b) end
            end
            myPlate._targetingMeActive = nil
        end
        return
    end

    local r, g, b = ns.c_targetingMeColor_r, ns.c_targetingMeColor_g, ns.c_targetingMeColor_b

    if isTargetingMe then
        myPlate._targetingMeActive = true

        if indicator == "glow" then
            -- Glow highlight around health bar
            EnsureTargetingMeGlow(myPlate)
            if myPlate.targetingMeGlow then
                myPlate.targetingMeGlow:SetBackdropBorderColor(r, g, b, 0.9)
                myPlate.targetingMeGlow:Show()
            end
        elseif indicator == "border" then
            -- Change health bar border color (force show even if borders disabled)
            if myPlate.hp and myPlate.hp.border then
                myPlate.hp.border:Show()
                myPlate.hp.border:SetColor(r, g, b, 1)
            end
        elseif indicator == "name" then
            -- Change name text color
            if myPlate.nameText then
                myPlate.nameText:SetTextColor(r, g, b)
            end
        elseif indicator == "health" then
            -- Change health bar color
            if myPlate.hp then
                myPlate.hp:SetStatusBarColor(r, g, b)
            end
        end
    else
        -- Not targeting me - restore defaults and hide indicators
        if myPlate._targetingMeActive then
            if indicator == "health" and myPlate.unit and UpdateColor then UpdateColor(myPlate.unit) end
            if indicator == "name" and myPlate.nameText and myPlate.unit then
                local friendly = UnitIsFriend("player", myPlate.unit)
                local _, class = UnitClass(myPlate.unit)
                local cc = ns.c_classColoredName and class and ns.GetClassColor(class)
                if cc then myPlate.nameText:SetTextColor(cc.r, cc.g, cc.b)
                elseif friendly then myPlate.nameText:SetTextColor(ns.c_friendlyNameColor_r, ns.c_friendlyNameColor_g, ns.c_friendlyNameColor_b)
                else myPlate.nameText:SetTextColor(ns.c_hostileNameColor_r, ns.c_hostileNameColor_g, ns.c_hostileNameColor_b) end
            end
            myPlate._targetingMeActive = nil
        end

        -- Reset border to user's setting (respect disabled state)
        if myPlate.hp and myPlate.hp.border then
            myPlate.hp.border:SetColor(0, 0, 0, BORDER_ALPHA)
            if not myPlate.isPlayer and not ns.c_healthBarBorder then
                myPlate.hp.border:Hide()
            end
        end

        -- Always hide glow when not targeting
        if myPlate.targetingMeGlow then
            myPlate.targetingMeGlow:Hide()
        end
    end
end

local function UpdateAllTargetingMe()
    if not inArena or ns.c_targetingMeIndicator == "disabled" then return end

    for _, myPlate in pairs(ns.unitToPlate) do
        if myPlate and myPlate.isTargetingMe then
            myPlate.isTargetingMe = nil
            UpdateTargetingMeVisual(myPlate, false)
        end
    end

    for i = 1, 5 do
        local arenaUnit = "arena" .. i
        local targetUnit = arenaUnit .. "target"
        if UnitExists(arenaUnit) and UnitExists(targetUnit) and UnitIsUnit(targetUnit, "player") then
            local frame = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(arenaUnit)
            local myPlate = frame and frame.myPlate
            if myPlate and myPlate.hp and not UnitIsFriend("player", arenaUnit) then
                myPlate.isTargetingMe = true
                UpdateTargetingMeVisual(myPlate, true)
            end
        end
    end
end

-- Polling frame for targeting me updates (arena only)
-- Frame is hidden when disabled or outside arena (OnUpdate doesn't fire when hidden)
local targetingMeFrame = CreateFrame("Frame")
local targetingMeElapsed = 0

-- Dynamic throttle getter (respects Potato PC mode)
local function GetTargetingMeThrottle() return THROTTLE.targetingMe * (ns.c_throttleMultiplier or 1) end

-- Toggle targeting me polling based on zone and settings
UpdateTargetingMePolling = function()
    -- Only active in arena (arena unit tokens work, nameplate tokens don't)
    local shouldPoll = inArena and ns.c_targetingMeIndicator ~= "disabled"

    if shouldPoll then
        targetingMeElapsed = 0  -- Reset throttle when re-enabling
        targetingMeFrame:Show()
    else
        targetingMeFrame:Hide()
        -- Clear all targeting me states when disabling (check both flags)
        for unit, myPlate in pairs(ns.unitToPlate) do
            if myPlate and (myPlate.isTargetingMe or myPlate._targetingMeActive) then
                myPlate.isTargetingMe = nil
                UpdateTargetingMeVisual(myPlate, false)
            end
        end
    end
end

targetingMeFrame:SetScript("OnUpdate", function(self, delta)
    targetingMeElapsed = targetingMeElapsed + delta
    if targetingMeElapsed < GetTargetingMeThrottle() then return end
    targetingMeElapsed = 0

    UpdateAllTargetingMe()
end)

-- Start hidden (will be shown by UpdateTargetingMePolling when appropriate)
targetingMeFrame:Hide()

-- Expose for external use
ns.UpdateAllTargetingMe = UpdateAllTargetingMe
ns.UpdateTargetingMePolling = UpdateTargetingMePolling

function ns:UpdatePlateStyle(myPlate)
    -- Only style health bar if it exists
    if myPlate.hp then
        -- Non-personal plate dimensions (personal has own sizing below)
        if not myPlate.isPlayer then
            if myPlate._lastWidth ~= ns.c_width or myPlate._lastHpHeight ~= ns.c_hpHeight then
                PixelUtil.SetWidth(myPlate.hp, ns.c_width, 1)
                PixelUtil.SetHeight(myPlate.hp, ns.c_hpHeight, 1)
                myPlate._lastWidth = ns.c_width
                myPlate._lastHpHeight = ns.c_hpHeight
            end

            if myPlate._lastPlateY ~= ns.c_plateYOffset or myPlate._lastPlateX ~= ns.c_plateXOffset then
                PixelUtil.SetPoint(myPlate.hp, "CENTER", myPlate, "CENTER", (ns.c_plateXOffset or 0), 15 + (ns.c_plateYOffset or 0), 1, 1)
                myPlate._lastPlateY = ns.c_plateYOffset
                myPlate._lastPlateX = ns.c_plateXOffset
            end
        end

        -- Always apply texture (no caching - SetStatusBarTexture is cheap)
        myPlate.hp:SetStatusBarTexture(ns.c_texture)

        -- Update background alpha
        if myPlate.hp.bg and myPlate._lastBgAlpha ~= ns.c_backgroundAlpha then
            myPlate.hp.bg:SetTexture(0, 0, 0, ns.c_backgroundAlpha)
            -- Also update power bar backgrounds
            if myPlate.powerBar and myPlate.powerBar.bg then
                myPlate.powerBar.bg:SetTexture(0, 0, 0, ns.c_backgroundAlpha)
            end
            if myPlate.additionalPowerBar and myPlate.additionalPowerBar.bg then
                myPlate.additionalPowerBar.bg:SetTexture(0, 0, 0, ns.c_backgroundAlpha)
            end
            myPlate._lastBgAlpha = ns.c_backgroundAlpha
        end

        -- Toggle healthbar border visibility (personal has own border via UpdatePersonalBorder)
        if not myPlate.isPlayer and myPlate.hp.border then
            local showBorder = ns.c_healthBarBorder
            if myPlate._lastBorderShown ~= showBorder then
                if showBorder then
                    myPlate.hp.border:Show()
                else
                    myPlate.hp.border:Hide()
                end
                myPlate._lastBorderShown = showBorder
            end

            -- Update border scale when UI scale changes
            local currentScale = myPlate.hp:GetEffectiveScale()
            if myPlate._lastBorderScale ~= currentScale then
                myPlate.hp.border:UpdateScale(myPlate.hp, 1)
                myPlate._lastBorderScale = currentScale
            end
        end
    end

    ApplyMouseoverGlowColor(myPlate.highlight)

    -- Personal plate settings (comprehensive update when options change)
    if myPlate.isPlayer and myPlate.hp then
        -- Health bar dimensions
        local personalWidth = ns.c_personalWidth
        local personalHeight = ns.c_personalHeight
        if myPlate._lastPersonalWidth ~= personalWidth then
            PixelUtil.SetWidth(myPlate.hp, personalWidth, 1)
            myPlate._lastPersonalWidth = personalWidth
        end
        if myPlate._lastPersonalHeight ~= personalHeight then
            PixelUtil.SetHeight(myPlate.hp, personalHeight, 1)
            myPlate._lastPersonalHeight = personalHeight
        end

        -- Health bar Y offset
        if myPlate._lastPersonalY ~= ns.c_personalYOffset then
            myPlate.hp:ClearAllPoints()
            myPlate.hp:SetPoint("CENTER", myPlate, "CENTER", 0, ns.c_personalYOffset)
            myPlate._lastPersonalY = ns.c_personalYOffset
        end

        -- Health bar texture
        if myPlate._lastPersonalTexture ~= ns.c_texture then
            myPlate.hp:SetStatusBarTexture(ns.c_texture)
            myPlate._lastPersonalTexture = ns.c_texture
        end

        -- Health bar color (apply class color or user-defined color)
        if not ns.c_personalUseClassColor then
            local r = ns.c_personalHealthColor_r or 0
            local g = ns.c_personalHealthColor_g or 0.8
            local b = ns.c_personalHealthColor_b or 0
            myPlate.hp:SetStatusBarColor(r, g, b)
        end

        -- Health text font
        if myPlate.healthText then
            local healthFontSize = ns.c_healthValueFontSize
            if myPlate._lastPersonalHealthFont ~= ns.c_font or myPlate._lastPersonalHealthFontSize ~= healthFontSize or myPlate._lastPersonalHealthFontOutline ~= ns.c_fontOutline then
                ns:SetFontSafe(myPlate.healthText, ns.c_font, healthFontSize, ns.c_fontOutline)
                myPlate._lastPersonalHealthFont = ns.c_font
                myPlate._lastPersonalHealthFontSize = healthFontSize
                myPlate._lastPersonalHealthFontOutline = ns.c_fontOutline
            end

            -- Health text format (show/hide based on format setting)
            local healthFmt = ns.c_personalHealthFormat
            if healthFmt and healthFmt ~= "none" then
                local health = UnitHealth("player")
                local maxHealth = UnitHealthMax("player")
                local text = FormatHealthValue(health, maxHealth, healthFmt)
                myPlate.healthText:SetText(text)
                myPlate.healthText:Show()
            else
                myPlate.healthText:Hide()
            end
        end

        -- Power bar
        if ns.c_personalShowPower then
            EnsurePowerBar(myPlate)
            if myPlate.powerBar then
                -- Power bar dimensions
                if myPlate.powerBar._lastWidth ~= personalWidth then
                    PixelUtil.SetWidth(myPlate.powerBar, personalWidth, 1)
                    myPlate.powerBar._lastWidth = personalWidth
                end
                if myPlate.powerBar._lastHeight ~= ns.c_personalPowerHeight then
                    PixelUtil.SetHeight(myPlate.powerBar, ns.c_personalPowerHeight, 1)
                    myPlate.powerBar._lastHeight = ns.c_personalPowerHeight
                end
                if myPlate.powerBar._lastTexture ~= ns.c_texture then
                    myPlate.powerBar:SetStatusBarTexture(ns.c_texture)
                    myPlate.powerBar._lastTexture = ns.c_texture
                end

                -- Power text font
                if myPlate.powerBar.text then
                    local powerFontSize = ns.c_healthValueFontSize - 2
                    if myPlate.powerBar._lastFontSize ~= powerFontSize or myPlate.powerBar._lastFont ~= ns.c_font or myPlate.powerBar._lastFontOutline ~= ns.c_fontOutline then
                        ns:SetFontSafe(myPlate.powerBar.text, ns.c_font, powerFontSize, ns.c_fontOutline)
                        myPlate.powerBar._lastFont = ns.c_font
                        myPlate.powerBar._lastFontSize = powerFontSize
                        myPlate.powerBar._lastFontOutline = ns.c_fontOutline
                    end
                end

                -- Show and update values
                UpdatePowerBar(myPlate, "player")
            end

            -- Additional power bar (druid mana)
            if myPlate.additionalPowerBar then
                if myPlate.additionalPowerBar._lastWidth ~= personalWidth then
                    PixelUtil.SetWidth(myPlate.additionalPowerBar, personalWidth, 1)
                    myPlate.additionalPowerBar._lastWidth = personalWidth
                end
                if myPlate.additionalPowerBar._lastHeight ~= ns.c_personalAdditionalPowerHeight then
                    PixelUtil.SetHeight(myPlate.additionalPowerBar, ns.c_personalAdditionalPowerHeight, 1)
                    myPlate.additionalPowerBar._lastHeight = ns.c_personalAdditionalPowerHeight
                end
            end

            -- HERO class power bars (mana, energy, rage)
            if myPlate.heroPowerBars then
                local powerFontSize = max(ns.c_healthValueFontSize - 2, 6)
                local height = ns.c_personalPowerHeight
                local needsReposition = false
                for i = 1, 3 do
                    local bar = myPlate.heroPowerBars[i]
                    if bar then
                        if bar._lastHeight ~= height then
                            needsReposition = true
                            bar._lastHeight = height
                        end
                        if bar._lastTexture ~= ns.c_texture then
                            bar:SetStatusBarTexture(ns.c_texture)
                            bar._lastTexture = ns.c_texture
                        end
                        -- Text font
                        if bar.text then
                            if bar._lastFont ~= ns.c_font or bar._lastFontSize ~= powerFontSize or bar._lastFontOutline ~= ns.c_fontOutline then
                                ns:SetFontSafe(bar.text, ns.c_font, powerFontSize, ns.c_fontOutline)
                                bar._lastFont = ns.c_font
                                bar._lastFontSize = powerFontSize
                                bar._lastFontOutline = ns.c_fontOutline
                            end
                        end
                    end
                end
                if needsReposition then
                    PositionHeroPowerBars(myPlate)
                end
            end
        else
            -- Hide power bars when disabled
            if myPlate.powerBar then
                myPlate.powerBar:Hide()
            end
            if myPlate.additionalPowerBar then
                myPlate.additionalPowerBar:Hide()
            end
            if myPlate.heroPowerBars then
                for i = 1, 3 do
                    if myPlate.heroPowerBars[i] then
                        myPlate.heroPowerBars[i]:Hide()
                    end
                end
            end
        end

        -- Update border style
        if ns.UpdatePersonalBorder then
            ns:UpdatePersonalBorder()
        end

        -- Update personal plate border scales when UI scale changes
        local currentScale = myPlate.hp:GetEffectiveScale()
        if myPlate._lastBorderScale ~= currentScale then
            if myPlate.hp.border then
                myPlate.hp.border:UpdateScale(myPlate.hp, 1)
            end
            if myPlate.powerBar and myPlate.powerBar.border then
                myPlate.powerBar.border:UpdateScale(myPlate.powerBar, 1)
            end
            if myPlate.additionalPowerBar and myPlate.additionalPowerBar.border then
                myPlate.additionalPowerBar.border:UpdateScale(myPlate.additionalPowerBar, 1)
            end
            -- HERO power bar border scales
            if myPlate.heroPowerBars then
                for i = 1, 3 do
                    local bar = myPlate.heroPowerBars[i]
                    if bar and bar.border then
                        bar.border:UpdateScale(bar, 1)
                    end
                end
            end
            myPlate._lastBorderScale = currentScale
        end

        -- Update aura positions (buff/debuff Y offsets)
        if ns.UpdateAuraPositions then
            ns:UpdateAuraPositions(myPlate)
        end

        -- Note: Buff/debuff visibility is handled in UpdateAuras called from FullPlateUpdate
    end

    -- Cache font settings (name text, guild text, level text use same cache)
    if myPlate._lastFont ~= ns.c_font or myPlate._lastFontSize ~= ns.c_fontSize or myPlate._lastFontOutline ~= ns.c_fontOutline then
        ns:SetFontSafe(myPlate.nameText, ns.c_font, ns.c_fontSize, ns.c_fontOutline)
        if myPlate.guildText then
            ns:SetFontSafe(myPlate.guildText, ns.c_font, math_max(ns.c_fontSize - 2, 8), ns.c_fontOutline)
        end
        if myPlate.levelText then
            ns:SetFontSafe(myPlate.levelText, ns.c_font, ns.c_fontSize, ns.c_fontOutline)
        end
        myPlate._lastFont = ns.c_font
        myPlate._lastFontSize = ns.c_fontSize
        myPlate._lastFontOutline = ns.c_fontOutline
    end

    -- Update nameText and healthText positions when nameInHealthbar changes
    -- Skip totem plates (they use custom layout, restored via _wasTotem on next non-totem use)
    if not myPlate.isPlayer and not myPlate._wasTotem and (myPlate._lastNameInHealthbar ~= ns.c_nameInHealthbar or myPlate._lastNameTextYOffset ~= ns.c_nameTextYOffset) then
        myPlate.nameText:ClearAllPoints()
        if ns.c_nameInHealthbar then
            -- Reparent to hp so it renders above statusbar fill
            myPlate.nameText:SetParent(myPlate.hp)
            myPlate.nameText:SetDrawLayer("OVERLAY", 7)
            PixelUtil.SetPoint(myPlate.nameText, "LEFT", myPlate.hp, "LEFT", 4, ns.c_nameTextYOffset, 1, 1)
            myPlate.nameText:SetJustifyH("LEFT")
            myPlate.nameText:SetWidth(ns.c_width * 0.6)
            myPlate.nameText:SetWordWrap(false)
            myPlate.nameText:SetNonSpaceWrap(false)
        else
            -- Reparent back to myPlate
            myPlate.nameText:SetParent(myPlate)
            myPlate.nameText:SetDrawLayer("OVERLAY")
            PixelUtil.SetPoint(myPlate.nameText, "BOTTOM", myPlate.hp, "TOP", 0, 2 + ns.c_nameTextYOffset, 1, 1)
            myPlate.nameText:SetJustifyH("CENTER")
            myPlate.nameText:SetWidth(0)
            myPlate.nameText:SetWordWrap(true)
        end

        if myPlate.healthText then
            myPlate.healthText:ClearAllPoints()
            if ns.c_nameInHealthbar then
                PixelUtil.SetPoint(myPlate.healthText, "RIGHT", myPlate.hp, "RIGHT", -4, 0, 1, 1)
                myPlate.healthText:SetJustifyH("RIGHT")
            else
                myPlate.healthText:SetAllPoints(myPlate.hp)
                myPlate.healthText:SetJustifyH("CENTER")
            end
        end

        -- Reset level text position cache so it repositions
        if myPlate.levelText then
            myPlate.levelText._lastPositionKey = nil
        end

        myPlate._lastNameInHealthbar = ns.c_nameInHealthbar
        myPlate._lastNameTextYOffset = ns.c_nameTextYOffset
    end

    -- Update health text font and visibility setting
    if myPlate.healthText then
        if myPlate._lastHealthFont ~= ns.c_font or myPlate._lastHealthFontSize ~= ns.c_healthValueFontSize or myPlate._lastHealthFontOutline ~= ns.c_fontOutline then
            ns:SetFontSafe(myPlate.healthText, ns.c_font, ns.c_healthValueFontSize, ns.c_fontOutline)
            myPlate._lastHealthFont = ns.c_font
            myPlate._lastHealthFontSize = ns.c_healthValueFontSize
            myPlate._lastHealthFontOutline = ns.c_fontOutline
        end
        -- Update health text format for non-personal plates
        if not myPlate.isPlayer and myPlate.unit then
            local healthFmt = ns.c_healthValueFormat
            if healthFmt and healthFmt ~= "none" then
                local health = UnitHealth(myPlate.unit)
                local maxHealth = UnitHealthMax(myPlate.unit)
                if maxHealth > 0 then
                    local text = FormatHealthValue(health, maxHealth)
                    myPlate.healthText:SetText(text)
                    myPlate.healthText:Show()
                end
            else
                myPlate.healthText:Hide()
            end
        end
    end

    -- Update name visibility based on format setting (for non-personal plates)
    if not myPlate.isPlayer and myPlate.nameText then
        if ns.c_nameDisplayFormat == "disabled" then
            myPlate.nameText:Hide()
        elseif not myPlate.nameText:IsShown() then
            myPlate.nameText:Show()
        end
    end

    -- Update execute indicator position when settings change
    if myPlate.execIndicator and myPlate.hp then
        local execRange = ns.c_executeRange or 0
        if execRange > 0 and execRange <= 100 then
            if myPlate._lastExecRange ~= execRange or myPlate._lastExecWidth ~= ns.c_width or myPlate._lastExecHeight ~= ns.c_hpHeight then
                local width = ns.c_width
                local height = ns.c_hpHeight
                local xPos = (execRange / 100) * width
                PixelUtil.SetHeight(myPlate.execIndicator, height, 1)
                myPlate.execIndicator:ClearAllPoints()
                myPlate.execIndicator:SetPoint("LEFT", myPlate.hp, "LEFT", xPos, 0)
                myPlate._lastExecRange = execRange
                myPlate._lastExecWidth = ns.c_width
                myPlate._lastExecHeight = ns.c_hpHeight
            end
        else
            myPlate.execIndicator:Hide()
        end
    end

    -- Update aura positions for non-personal plates
    if not myPlate.isPlayer and ns.UpdateAuraPositions then
        ns:UpdateAuraPositions(myPlate)
    end

    -- Refresh auras when aura-related settings change (icon size, spacing, counts, etc.)
    if myPlate.unit and ns.UpdateAuras then
        local auraNeedsRefresh = myPlate._lastDebuffW ~= ns.c_debuffIconWidth
            or myPlate._lastDebuffH ~= ns.c_debuffIconHeight
            or myPlate._lastBuffW ~= ns.c_buffIconWidth
            or myPlate._lastBuffH ~= ns.c_buffIconHeight
            or myPlate._lastDebuffSpacing ~= ns.c_iconSpacing
            or myPlate._lastBuffSpacing ~= ns.c_buffIconSpacing
            or myPlate._lastMaxDebuffs ~= ns.c_maxDebuffs
            or myPlate._lastMaxBuffs ~= ns.c_maxBuffs
        if auraNeedsRefresh then
            ns:UpdateAuras(myPlate, myPlate.unit)
            myPlate._lastDebuffW = ns.c_debuffIconWidth
            myPlate._lastDebuffH = ns.c_debuffIconHeight
            myPlate._lastBuffW = ns.c_buffIconWidth
            myPlate._lastBuffH = ns.c_buffIconHeight
            myPlate._lastDebuffSpacing = ns.c_iconSpacing
            myPlate._lastBuffSpacing = ns.c_buffIconSpacing
            myPlate._lastMaxDebuffs = ns.c_maxDebuffs
            myPlate._lastMaxBuffs = ns.c_maxBuffs
        end
    end

    -- Update raid icon size and position (only if settings changed)
    if myPlate.raidIcon and (myPlate._lastRaidSize ~= ns.c_raidMarkerSize or myPlate._lastRaidAnchor ~= ns.c_raidMarkerAnchor or myPlate._lastRaidX ~= ns.c_raidMarkerX or myPlate._lastRaidY ~= ns.c_raidMarkerY) then
        PixelUtil.SetSize(myPlate.raidIcon, ns.c_raidMarkerSize, ns.c_raidMarkerSize, 1, 1)
        myPlate.raidIcon:ClearAllPoints()
        -- Position based on anchor: LEFT/RIGHT outside healthbar, TOP above name
        if ns.c_raidMarkerAnchor == "LEFT" then
            myPlate.raidIcon:SetPoint("RIGHT", myPlate.hp, "LEFT", ns.c_raidMarkerX - 2, ns.c_raidMarkerY)
        elseif ns.c_raidMarkerAnchor == "RIGHT" then
            myPlate.raidIcon:SetPoint("LEFT", myPlate.hp, "RIGHT", ns.c_raidMarkerX + 2, ns.c_raidMarkerY)
        elseif ns.c_raidMarkerAnchor == "TOP" then
            myPlate.raidIcon:SetPoint("BOTTOM", myPlate.nameText, "TOP", ns.c_raidMarkerX, ns.c_raidMarkerY + 2)
        else
            -- Fallback: treat as LEFT
            myPlate.raidIcon:SetPoint("RIGHT", myPlate.hp, "LEFT", ns.c_raidMarkerX - 2, ns.c_raidMarkerY)
        end
        myPlate._lastRaidSize = ns.c_raidMarkerSize
        myPlate._lastRaidAnchor = ns.c_raidMarkerAnchor
        myPlate._lastRaidX = ns.c_raidMarkerX
        myPlate._lastRaidY = ns.c_raidMarkerY
    end

    -- Update quest icon position and scale (anchor/scale/offsets/nameInHealthbar may have changed)
    if myPlate.questIcon then
        local needsUpdate = myPlate._lastQuestAnchor ~= ns.c_questIconAnchor
            or myPlate._lastQuestScale ~= ns.c_questIconScale
            or myPlate._lastQuestX ~= ns.c_questIconX
            or myPlate._lastQuestY ~= ns.c_questIconY
            or myPlate._lastQuestNameInHealthbar ~= ns.c_nameInHealthbar
        if myPlate.questIcon:IsShown() and needsUpdate then
            myPlate.questIcon:ClearAllPoints()
            local anchor = ns.c_questIconAnchor
            local xOff, yOff = ns.c_questIconX, ns.c_questIconY
            if ns.c_nameInHealthbar and anchor == "LEFT" then
                -- With name in healthbar, LEFT anchor goes to left of healthbar instead
                myPlate.questIcon:SetPoint("RIGHT", myPlate.hp, "LEFT", -2 + xOff, yOff)
            elseif anchor == "LEFT" then
                myPlate.questIcon:SetPoint("RIGHT", myPlate.nameText, "LEFT", -2 + xOff, yOff)
            elseif anchor == "RIGHT" then
                -- Anchor after level text if visible, otherwise after healthbar (nameInHealthbar) or name
                local levelText = myPlate.levelText
                if levelText and levelText:IsShown() and levelText:GetText() and levelText:GetText() ~= "" then
                    myPlate.questIcon:SetPoint("LEFT", levelText, "RIGHT", 2 + xOff, yOff)
                elseif ns.c_nameInHealthbar then
                    myPlate.questIcon:SetPoint("LEFT", myPlate.hp, "RIGHT", 2 + xOff, yOff)
                else
                    myPlate.questIcon:SetPoint("LEFT", myPlate.nameText, "RIGHT", 2 + xOff, yOff)
                end
            else  -- TOP
                if ns.c_nameInHealthbar then
                    myPlate.questIcon:SetPoint("BOTTOM", myPlate.hp, "TOP", xOff, 2 + yOff)
                else
                    myPlate.questIcon:SetPoint("BOTTOM", myPlate.nameText, "TOP", xOff, 2 + yOff)
                end
            end
            -- Update scale if icon has stored original dimensions
            if myPlate.questIcon._origW and myPlate.questIcon._origH then
                local scale = ns.c_questIconScale * 0.5
                myPlate.questIcon:SetSize(myPlate.questIcon._origW * scale, myPlate.questIcon._origH * scale)
            end
            myPlate._lastQuestAnchor = ns.c_questIconAnchor
            myPlate._lastQuestScale = ns.c_questIconScale
            myPlate._lastQuestX = ns.c_questIconX
            myPlate._lastQuestY = ns.c_questIconY
            myPlate._lastQuestNameInHealthbar = ns.c_nameInHealthbar
        end
    end

    -- Reset classification icon anchor cache so it repositions on next update
    if myPlate.classifyIcon then
        myPlate.classifyIcon._anchor = nil
        myPlate.classifyIcon._style = nil
        myPlate.classifyIcon._classification = nil
        myPlate.classifyIcon._lastWidth = nil
        myPlate.classifyIcon._lastHeight = nil
        if ns.c_classificationStyle == "none" then
            myPlate.classifyIcon:Hide()
        end
    end
    if myPlate.unit and ns.UpdateClassificationIndicator then
        ns.UpdateClassificationIndicator(myPlate.unit)
    end

    -- Only style castbar if it exists (deferred creation)
    if myPlate.castbar then
        local iconSize = ns.c_castHeight
        local showIcon = ns.c_showCastIcon
        local castbarWidth = showIcon and (ns.c_width - iconSize - 2) or ns.c_width

        -- Cache castbar styling to avoid redundant calls
        local cbNeedsUpdate = myPlate._lastCastWidth ~= castbarWidth or myPlate._lastCastHeight ~= ns.c_castHeight or myPlate._lastCastTexture ~= ns.c_texture or myPlate._lastCastShowIcon ~= showIcon or myPlate._lastCastYOffset ~= ns.c_castbarYOffset

        if cbNeedsUpdate then
            PixelUtil.SetWidth(myPlate.castbar, castbarWidth, 1)
            PixelUtil.SetHeight(myPlate.castbar, ns.c_castHeight, 1)
            myPlate.castbar:SetStatusBarTexture(ns.c_texture)
            myPlate.castbar:ClearAllPoints()

            -- Update spark size based on castbar height
            if myPlate.castbar.spark then
                PixelUtil.SetSize(myPlate.castbar.spark, 16, ns.c_castHeight * 2, 1, 1)
            end

            if showIcon then
                PixelUtil.SetPoint(myPlate.castbar, "TOPLEFT", myPlate.hp, "BOTTOMLEFT", iconSize + 2, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            else
                PixelUtil.SetPoint(myPlate.castbar, "TOP", myPlate.hp, "BOTTOM", 0, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            end

            -- Position and size icon (visibility controlled in cast event handlers)
            if myPlate.castbar.icon then
                PixelUtil.SetSize(myPlate.castbar.icon, iconSize, iconSize, 1, 1)
                myPlate.castbar.icon:ClearAllPoints()
                PixelUtil.SetPoint(myPlate.castbar.icon, "RIGHT", myPlate.castbar, "LEFT", -2, 0, 1, 1)
                myPlate.castbar.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

                -- Position icon border (same size as icon, border textures extend outside)
                if myPlate.castbar.iconBorder then
                    myPlate.castbar.iconBorder:ClearAllPoints()
                    myPlate.castbar.iconBorder:SetAllPoints(myPlate.castbar.icon)
                end

                -- Ensure icons stay hidden when disabled (don't show until cast starts)
                if not showIcon then
                    myPlate.castbar.icon:Hide()
                    if myPlate.castbar.iconBorder then
                        myPlate.castbar.iconBorder:Hide()
                    end
                end
            end

            -- Update cache
            myPlate._lastCastWidth = castbarWidth
            myPlate._lastCastHeight = ns.c_castHeight
            myPlate._lastCastYOffset = ns.c_castbarYOffset
            myPlate._lastCastTexture = ns.c_texture
            myPlate._lastCastShowIcon = showIcon
        end
    end

    -- Only style combo points if they exist (deferred creation) - cache settings
    if myPlate.cps and myPlate.hp and myPlate.cpContainer then
        local cpWidth = ns.c_cpSize
        local currentStyle = ns.c_cpStyle or 1
        -- Use correct offsets based on whether this is personal plate
        local isPersonalPlate = myPlate.isPlayer
        local offsetX = isPersonalPlate and ns.c_cpPersonalX or ns.c_cpX
        local offsetY = isPersonalPlate and ns.c_cpPersonalY or ns.c_cpY

        -- Check if style changed - need to recreate combo points
        if myPlate.cpStyle ~= currentStyle then
            EnsureComboPoints(myPlate, isPersonalPlate)
            -- Force update after recreation
            myPlate._lastCpSize = nil

            -- Re-show combo points after style change
            -- For target plate: show if this is target and combo points enabled (not personal mode)
            -- For personal plate: show if personal mode enabled
            if myPlate.cps then
                local points = 0
                if isPersonalPlate and ns.c_showComboPoints and ns.c_cpOnPersonalBar then
                    points = GetComboPoints("player", "target") or 0
                elseif not isPersonalPlate and ns:IsTargetPlate(myPlate) and ns.c_showComboPoints and not ns.c_cpOnPersonalBar then
                    points = GetComboPoints("player", "target") or 0
                end
                for i = 1, #myPlate.cps do
                    if i <= points then
                        myPlate.cps[i]:Show()
                    else
                        myPlate.cps[i]:Hide()
                    end
                end
            end
        end

        local cpNeedsUpdate = myPlate._lastCpSize ~= cpWidth or myPlate._lastCpOffsetX ~= offsetX or myPlate._lastCpOffsetY ~= offsetY

        if cpNeedsUpdate then
            local numCPs = #myPlate.cps

            if currentStyle == 2 then
                -- ROUNDED STYLE - square textures, glow behind
                local spacing = -1  -- Slight overlap
                local totalWidth = (cpWidth * numCPs) + (spacing * (numCPs - 1))

                PixelUtil.SetSize(myPlate.cpContainer, totalWidth, cpWidth, 1, 1)
                myPlate.cpContainer:ClearAllPoints()
                myPlate.cpContainer:SetPoint("BOTTOM", myPlate.hp, "TOP", offsetX, -1 + offsetY)

                for i = 1, numCPs do
                    PixelUtil.SetSize(myPlate.cps[i], cpWidth, cpWidth, 1, 1)
                    myPlate.cps[i]:ClearAllPoints()
                    if i == 1 then
                        myPlate.cps[i]:SetPoint("LEFT", myPlate.cpContainer, "LEFT", 0, 0)
                    else
                        myPlate.cps[i]:SetPoint("LEFT", myPlate.cps[i-1], "RIGHT", spacing, 0)
                    end
                end
            else
                -- SQUARE STYLE - simple colored textures
                local cpHeight = 4
                local spacing = 1  -- 1px gap between bars
                local totalWidth = (cpWidth * numCPs) + (spacing * (numCPs - 1))

                PixelUtil.SetSize(myPlate.cpContainer, totalWidth, cpHeight, 1, 1)
                myPlate.cpContainer:ClearAllPoints()
                myPlate.cpContainer:SetPoint("BOTTOM", myPlate.hp, "TOP", offsetX, -1 + offsetY)

                for i = 1, numCPs do
                    myPlate.cps[i]:ClearAllPoints()
                    PixelUtil.SetSize(myPlate.cps[i], cpWidth, cpHeight, 1, 1)
                    if i == 1 then
                        myPlate.cps[i]:SetPoint("LEFT", myPlate.cpContainer, "LEFT", 0, 0)
                    else
                        myPlate.cps[i]:SetPoint("LEFT", myPlate.cps[i-1], "RIGHT", spacing, 0)
                    end
                end
            end

            myPlate._lastCpSize = cpWidth
            myPlate._lastCpOffsetX = offsetX
            myPlate._lastCpOffsetY = offsetY
        end
    end

    -- Update target glow style if this plate is the current target
    if myPlate.targetGlow and ns:IsTargetPlate(myPlate) then
        UpdateTargetGlow(myPlate, true)
    end

    -- Update health bar color (for non-personal plates when color settings change)
    if not myPlate.isPlayer and myPlate.unit then
        UpdateColor(myPlate.unit)
    end

    -- Apply scale when settings change (not handled elsewhere during UpdateAllPlates)
    local targetScale = ns.c_scale
    if myPlate.isPlayer then
        -- Personal plate uses base scale
        targetScale = ns.c_scale
    elseif ns:IsTargetPlate(myPlate) then
        -- Current target uses target scale multiplier
        targetScale = ns.c_scale * ns.c_targetScale
    elseif myPlate.unit and UnitIsPet(myPlate.unit) then
        targetScale = ns.c_scale * ns.c_petScale
    elseif myPlate.isFriendly then
        targetScale = ns.c_scale * ns.c_friendlyScale
    end

    if myPlate._lastScale ~= targetScale then
        ns:ApplyPlateScale(myPlate, targetScale)
        myPlate._lastScale = targetScale
    end
end

-- Update incoming heal bar display (personal bar only)
local function UpdateHealPrediction(myPlate)
    if not myPlate or not myPlate.hp then return end
    if not myPlate.isPlayer then return end  -- Personal bar only
    local hp = myPlate.hp
    if not hp.healBar then return end

    local incomingHeal = UnitGetIncomingHeals and UnitGetIncomingHeals("player") or 0
    local health = UnitHealth("player")
    local maxHealth = UnitHealthMax("player")

    if incomingHeal == 0 or maxHealth == 0 then
        hp.healBar:Hide()
        return
    end

    local barWidth = hp:GetWidth()
    local healthPercent = health / maxHealth
    local healPercent = incomingHeal / maxHealth

    -- Get current absorb bar width in pixels (0 if hidden)
    local absorbOffset = 0
    if hp.absorbBar and hp.absorbBar:IsShown() then
        absorbOffset = hp.absorbBar:GetWidth() or 0
    end

    -- Calculate max heal width based on displayed absorb (pixels), not total absorb
    -- Heal bar starts at: health edge + absorbOffset
    -- Heal bar can extend up to: 20% past bar right edge
    local maxOverflow = 1.2
    local maxHealWidth = (barWidth * maxOverflow) - (healthPercent * barWidth) - absorbOffset
    local healWidth = math.min(healPercent * barWidth, math.max(0, maxHealWidth))

    if healWidth >= 1 then
        -- Reposition heal bar to start after absorb bar
        hp.healBar:ClearAllPoints()
        hp.healBar:SetPoint("TOPLEFT", hp:GetStatusBarTexture(), "TOPRIGHT", absorbOffset, 0)
        hp.healBar:SetPoint("BOTTOMLEFT", hp:GetStatusBarTexture(), "BOTTOMRIGHT", absorbOffset, 0)
        hp.healBar:SetWidth(healWidth)
        hp.healBar:Show()
    else
        hp.healBar:Hide()
    end
end

-- Update absorb bar display
local function UpdateAbsorb(unit, myPlate)
    if not myPlate or not myPlate.hp then return end
    if myPlate._wasTotem then return end  -- Totems don't have shields
    local hp = myPlate.hp
    if not hp.absorbBar then return end

    local absorb = UnitGetTotalAbsorbs and UnitGetTotalAbsorbs(unit) or 0
    local health = UnitHealth(unit)
    local maxHealth = UnitHealthMax(unit)

    -- Cache check - skip update if neither absorb nor health changed
    -- (health affects where absorb bar is positioned relative to health fill)
    if myPlate._lastAbsorb == absorb and myPlate._lastAbsorbHealth == health then return end
    myPlate._lastAbsorb = absorb
    myPlate._lastAbsorbHealth = health

    if absorb == 0 then
        hp.absorbBar:Hide()
        if hp.absorbOverlay then hp.absorbOverlay:Hide() end
        hp.overAbsorbGlow:Hide()
        return
    end

    if maxHealth == 0 then return end

    local barWidth = hp:GetWidth()
    local barHeight = hp:GetHeight()
    local healthPercent = health / maxHealth
    local absorbPercent = absorb / maxHealth

    -- Calculate how much space is left in the bar after health
    local missingHealthPercent = 1 - healthPercent

    -- Absorb bar fills from health edge towards right
    -- Clamp to remaining bar space (overflow shows glow instead)
    local displayPercent = math.min(absorbPercent, missingHealthPercent)
    local absorbWidth = displayPercent * barWidth

    -- Show absorb bar if there's any width to display
    if absorbWidth >= 1 then
        hp.absorbBar:SetWidth(absorbWidth)
        hp.absorbBar:Show()
        -- Update tiled overlay texcoord
        if hp.absorbOverlay and hp.absorbOverlay.tileSize then
            hp.absorbOverlay:SetTexCoord(0, absorbWidth / hp.absorbOverlay.tileSize, 0, barHeight / hp.absorbOverlay.tileSize)
            hp.absorbOverlay:Show()
        end
    else
        hp.absorbBar:Hide()
        if hp.absorbOverlay then hp.absorbOverlay:Hide() end
    end

    -- Show overflow glow when absorb exceeds remaining bar space (health + absorb > max)
    if absorbPercent > missingHealthPercent and missingHealthPercent >= 0 then
        hp.overAbsorbGlow:Show()
    else
        hp.overAbsorbGlow:Hide()
    end
end

-- Direct health update (called frequently for regular nameplates)
-- Personal plate health is handled separately by ProcessPersonalUpdates
local function UpdateHealth(unit)
    local myPlate = ns.unitToPlate[unit]
    if not myPlate or myPlate.isNameOnly or not myPlate.hp then return end

    -- Skip personal plates - they use ProcessPersonalUpdates with ns.c_personalHealthFormat
    if myPlate.isPlayer then return end

    local hp = myPlate.hp
    local current = UnitHealth(unit)
    local max = UnitHealthMax(unit)
    hp:SetMinMaxValues(0, max)
    hp:SetValue(current)

    -- Update absorb bar (health changes affect absorb display position)
    UpdateAbsorb(unit, myPlate)

    -- Update health value text (only show/hide when state changes)
    if myPlate.healthText and ns.c_healthValueFormat ~= "none" then
        local text = FormatHealthValue(current, max)
        if text and text ~= "" then
            myPlate.healthText:SetText(text)
            if not myPlate.healthText:IsShown() then
                myPlate.healthText:Show()
            end
        else
            if myPlate.healthText:IsShown() then
                myPlate.healthText:Hide()
            end
        end
    elseif myPlate.healthText and myPlate.healthText:IsShown() then
        myPlate.healthText:Hide()
    end

    -- Update execute indicator (only reposition when settings change)
    if myPlate.execIndicator then
        local execRange = ns.c_executeRange or 0
        if execRange > 0 and execRange <= 100 then
            -- Only recalculate position if settings changed
            if myPlate._lastExecRange ~= execRange or myPlate._lastExecWidth ~= ns.c_width or myPlate._lastExecHeight ~= ns.c_hpHeight then
                local width = ns.c_width
                local height = ns.c_hpHeight
                local xPos = (execRange / 100) * width
                PixelUtil.SetHeight(myPlate.execIndicator, height, 1)
                myPlate.execIndicator:ClearAllPoints()
                myPlate.execIndicator:SetPoint("LEFT", hp, "LEFT", xPos, 0)
                myPlate._lastExecRange = execRange
                myPlate._lastExecWidth = ns.c_width
                myPlate._lastExecHeight = ns.c_hpHeight
            end
            if not myPlate.execIndicator:IsShown() then
                myPlate.execIndicator:Show()
            end
        else
            if myPlate.execIndicator:IsShown() then
                myPlate.execIndicator:Hide()
            end
        end
    end
end

-- Exposed so the WotLK compat layer can push a health re-render when the Blizzard
-- nameplate health bar changes (stock 3.3.5a has no UNIT_HEALTH for our synthetic
-- plate tokens, and UNIT_HEALTH for real units doesn't map to ns.unitToPlate).
ns.UpdateNameplateHealth = UpdateHealth

-- Update health for lite plates (name-only friendly plates with health bar when damaged)
local function UpdateLiteHealth(unit)
    local nameplate = C_NamePlate_GetNamePlateForUnit(unit)
    if not nameplate or not nameplate._isLite then return end

    local container = nameplate.liteContainer
    if not container or not container.liteHealthBar then return end

    if not ns.c_liteHealthWhenDamaged then
        container.liteHealthBar:Hide()
        return
    end

    ns:UpdateLiteHealthBar(container, unit)
end

-- Group role tracking for off-tank detection
local group = {
    roles = {},      -- [guid] = role
    tanks = {},      -- Unit IDs of tanks (e.g., "raid1", "party2") for fast iteration
    inGroup = false,
    playerIsTank = false,
}

-- Tank aura spell IDs (manual-group fallback when LFG roles aren't available).
-- Both Ascension (Level 60 custom, base WOTLK id + 1100000) and stock WOTLK.
local TANK_AURAS = {
    [1182001] = true,  -- Ascension Shaman tank buff (no stock-WOTLK equivalent)
    [1109634] = true,  -- Ascension Druid Dire Bear Form
    [1125780] = true,  -- Ascension Paladin Righteous Fury
    [9634]    = true,  -- WOTLK Druid Dire Bear Form
    [25780]   = true,  -- WOTLK Paladin Righteous Fury
    [48263]   = true,  -- WOTLK Death Knight Frost Presence
}

-- Vigilance buff - applied BY a warrior tank ON a party member; scanned via
-- UnitBuff to find that warrior. Accept every Vigilance id that can show up
-- across platforms so detection never silently misses:
--   1150720 = Ascension Vigilance (base id + 1100000)
--   50720   = WOTLK Vigilance, the persistent 30-min aura that actually sits on
--             the target (what UnitBuff returns) and carries the threat transfer
--   50725   = the no-duration script/proc id Vigilance triggers (taunt reset);
--             kept as a belt-and-suspenders match in case a client surfaces it
local VIGILANCE_SPELL_IDS = {
    [1150720] = true,
    [50720]   = true,
    [50725]   = true,
}

-- Vigilance caster cache
local cachedVigilanceCaster = nil
local vigilanceScanTime = 0

-- Dynamic interval getter (respects Potato PC mode)
local function GetVigilanceScanInterval() return THROTTLE.vigilance * (ns.c_throttleMultiplier or 1) end

-- Check if a unit has a tank aura active
local function HasTankAura(unit)
    for i = 1, 40 do
        local _, _, _, _, _, _, _, _, _, _, spellId = UnitBuff(unit, i)
        if not spellId then break end
        if TANK_AURAS[spellId] then return true end
    end
    return false
end

-- Scan group for Vigilance buff and return the caster's name (Warrior tank)
-- Only called on: GROUP_ROSTER_UPDATE, READY_CHECK+10s, PLAYER_ENTERING_WORLD
local function FindVigilanceCaster(forceRescan)
    local now = GetTime()

    -- Use cached result if still fresh
    if not forceRescan and (now - vigilanceScanTime) < GetVigilanceScanInterval() then
        return cachedVigilanceCaster
    end

    vigilanceScanTime = now
    cachedVigilanceCaster = nil

    -- Scan using modern API
    local inRaid = IsInRaid()

    local function ScanUnit(unit)
        for i = 1, 40 do
            local _, _, _, _, _, _, _, caster, _, _, spellId = UnitBuff(unit, i)
            if not spellId then return nil end
            if VIGILANCE_SPELL_IDS[spellId] and caster then
                return UnitName(caster)
            end
        end
        return nil
    end

    if inRaid then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local caster = ScanUnit(unit)
                if caster then
                    cachedVigilanceCaster = caster
                    return caster
                end
            end
        end
    else
        local caster = ScanUnit("player")
        if caster then
            cachedVigilanceCaster = caster
            return caster
        end
        if IsInGroup() then
            for i = 1, GetNumGroupMembers() - 1 do  -- -1 because player not in party array
                local unit = "party" .. i
                if UnitExists(unit) then
                    caster = ScanUnit(unit)
                    if caster then
                        cachedVigilanceCaster = caster
                        return caster
                    end
                end
            end
        end
    end

    return nil
end

-- Check if player is Protection Warrior (most points in Protection tree = tree 3)
local function IsProtectionWarrior()
    -- The "3rd tab = Protection" assumption only holds for warriors. Without this
    -- guard any class whose 3rd talent tab is its highest gets flagged as a tank
    -- (Frost mage, Ret paladin, Unholy DK, Resto druid, Shadow priest, Destro
    -- lock, Sub rogue), which on stock 3.3.5a paints tank aggro colour whenever a
    -- mob hits them. Class token is locale-independent.
    local _, class = UnitClass("player")
    if class ~= "WARRIOR" then return false end

    local numTabs = GetNumTalentTabs()
    if numTabs < 3 then return false end

    local _, _, pointsSpent1 = GetTalentTabInfo(1)  -- Arms
    local _, _, pointsSpent2 = GetTalentTabInfo(2)  -- Fury
    local _, _, pointsSpent3 = GetTalentTabInfo(3)  -- Protection

    -- Consider Protection spec if it has the most points AND at least some investment
    return pointsSpent3 > 0 and pointsSpent3 >= pointsSpent1 and pointsSpent3 >= pointsSpent2
end

-- Helper to get role as string
-- Priority: MAINTANK assignment > LFG role > Tank aura
local function GetUnitRole(unit)
    -- Method 1: Check raid MAINTANK assignment (most reliable for raids)
    if GetPartyAssignment("MAINTANK", unit) then
        return "TANK"
    end

    -- Method 2: Ascension's UnitGroupRolesAssignedKey returns string directly
    -- (This function wraps UnitGroupRolesAssigned internally)
    local role = UnitGroupRolesAssignedKey(unit)
    if role and role ~= "NONE" then
        return role
    end

    -- Method 3: Tank aura detection (fallback for manual groups without LFG roles)
    if HasTankAura(unit) then
        return "TANK"
    end

    return "NONE"
end

-- Update player's own tank status (for smart tank mode)
-- Called only on: GROUP_ROSTER_UPDATE, READY_CHECK+10s, PLAYER_ENTERING_WORLD
local function UpdatePlayerTankStatus()
    -- Priority 1: Check MAINTANK assignment (most reliable for raids)
    if GetPartyAssignment("MAINTANK", "player") then
        group.playerIsTank = true
        return
    end

    -- Priority 2: Check LFG role (UnitGroupRolesAssignedKey always exists in Ascension)
    local role = UnitGroupRolesAssignedKey("player")
    if role == "TANK" then
        group.playerIsTank = true
        return
    end

    -- Priority 3: Check tank auras (Shaman/Druid/Paladin/Death Knight)
    if HasTankAura("player") then
        group.playerIsTank = true
        return
    end

    -- Priority 4: Check Protection Warrior (most points in Prot tree)
    if IsProtectionWarrior() then
        group.playerIsTank = true
        return
    end

    -- Priority 5: Check if player is the Vigilance caster (Warrior tank)
    local vigilanceCaster = FindVigilanceCaster()
    if vigilanceCaster and vigilanceCaster == UnitName("player") then
        group.playerIsTank = true
        return
    end

    group.playerIsTank = false
end

-- Throttle for group role updates (avoid spam on UNIT_AURA)
local lastGroupRoleUpdate = 0

-- Dynamic throttle getter (respects Potato PC mode)
local function GetGroupRoleThrottle() return THROTTLE.groupRole * (ns.c_throttleMultiplier or 1) end

local function RefreshGroupRoles(forceUpdate, isRetry)
    local now = GetTime()

    -- Throttle full group scans (but allow forced updates)
    if not forceUpdate and (now - lastGroupRoleUpdate) < GetGroupRoleThrottle() then
        return
    end
    lastGroupRoleUpdate = now

    local inRaid = IsInRaid()
    group.inGroup = inRaid or IsInGroup()
    wipe(group.roles)
    wipe(group.tanks)  -- Clear tank unit list

    -- Update player's tank status
    UpdatePlayerTankStatus()

    if group.inGroup then
        -- Get Vigilance caster name once (cached for 5s)
        local vigilanceCaster = FindVigilanceCaster()

        if inRaid then
            for i = 1, GetNumGroupMembers() do
                local unit = "raid" .. i
                if UnitExists(unit) then
                    local guid = UnitGUID(unit)
                    local name = UnitName(unit)
                    if guid then
                        local role = GetUnitRole(unit)
                        -- Check Vigilance in same loop (avoid double iteration)
                        if vigilanceCaster and name == vigilanceCaster and role ~= "TANK" then
                            role = "TANK"
                        end
                        group.roles[guid] = role
                        -- Build tank unit list for fast off-tank checks
                        if role == "TANK" and not UnitIsUnit(unit, "player") then
                            group.tanks[#group.tanks + 1] = unit
                        end
                    end
                end
            end
        else
            for i = 1, GetNumGroupMembers() - 1 do  -- -1 because player not in party array
                local unit = "party" .. i
                if UnitExists(unit) then
                    local guid = UnitGUID(unit)
                    local name = UnitName(unit)
                    if guid then
                        local role = GetUnitRole(unit)
                        -- Check Vigilance in same loop (avoid double iteration)
                        if vigilanceCaster and name == vigilanceCaster and role ~= "TANK" then
                            role = "TANK"
                        end
                        group.roles[guid] = role
                        -- Build tank unit list for fast off-tank checks (exclude player - same as raid mode for consistency)
                        if role == "TANK" and not UnitIsUnit(unit, "player") then
                            group.tanks[#group.tanks + 1] = unit
                        end
                    end
                end
            end
        end

        -- Include player in group roles
        local playerGUID = UnitGUID("player")
        if playerGUID then
			local playerRole = GetUnitRole("player")
			-- Sync with UpdatePlayerTankStatus logic
			if group.playerIsTank then
				playerRole = "TANK"
			end

			group.roles[playerGUID] = playerRole
            -- Check if player is Vigilance caster
            if vigilanceCaster and UnitName("player") == vigilanceCaster then
                group.roles[playerGUID] = "TANK"
            end
        end
		if not isRetry then
        C_Timer.After(2.5, function()
            RefreshGroupRoles(true, true)
        end)
		end
    end
end

-- Check if another tank has aggro (off-tank situation)
local function CheckOffTank(unit)
    -- Use cached group.inGroup flag (updated by RefreshGroupRoles on roster/zone events)
    if not group.inGroup then return false end

    -- Iterate cached group.tanks (populated by RefreshGroupRoles)
    for i = 1, #group.tanks do
        local tankUnit = group.tanks[i]
        if UnitExists(tankUnit) then
            local isTanking = UnitDetailedThreatSituation(tankUnit, unit)
            if isTanking then
                return true
            end
        end
    end

    return false
end

-- Getter for player tank status (used by smart tank mode)
function ns:IsPlayerTank()
    return group.playerIsTank
end

-- =============================================================================
-- THREAT TEXT DISPLAY
-- =============================================================================

-- Cache group state for threat lead calculation (updated on GROUP_ROSTER_UPDATE)
local threatLeadCache = {
    isRaid = false,
    groupSize = 0,
}

-- Update cached group state
local function UpdateThreatLeadGroupCache()
    threatLeadCache.isRaid = IsInRaid()
    threatLeadCache.groupSize = GetNumGroupMembers()
end

-- Calculate threat lead when player has aggro
-- Returns: lead value, hasCompetition (whether anyone else is on threat table)
local function GetThreatLead(enemyUnit, myThreatValue)
    if not myThreatValue or myThreatValue <= 0 then return nil, false end

    local secondHighest = 0
    local cache = threatLeadCache

    if cache.isRaid then
        for i = 1, cache.groupSize do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local _, _, _, _, threatVal = UnitDetailedThreatSituation(unit, enemyUnit)
                if threatVal and threatVal > secondHighest then
                    secondHighest = threatVal
                end
            end
        end
    elseif cache.groupSize > 0 then
        for i = 1, cache.groupSize - 1 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local _, _, _, _, threatVal = UnitDetailedThreatSituation(unit, enemyUnit)
                if threatVal and threatVal > secondHighest then
                    secondHighest = threatVal
                end
            end
        end
    end

    -- Check player's pet (always check directly, cheap call)
    if UnitExists("pet") then
        local _, _, _, _, threatVal = UnitDetailedThreatSituation("pet", enemyUnit)
        if threatVal and threatVal > secondHighest then
            secondHighest = threatVal
        end
    end

    -- Return lead and whether there's actual competition
    return myThreatValue - secondHighest, secondHighest > 0
end

-- Format threat lead as abbreviated number with threshold caching
-- Only updates display if value changed by more than 2% or crossed a tier boundary
-- Note: Raw threatValue from API is 100x larger than displayed values (divide by 100)
local function FormatThreatLead(value, lastValue, lastText)
    -- Normalize to match other threat addons (API returns 100x actual value)
    value = floor(value / 100)

    -- Skip recalculation if change is minimal (within 2%)
    if lastValue and lastText then
        local diff = math.abs(value - lastValue)
        local threshold = lastValue * 0.02  -- 2% threshold
        if diff < threshold and diff < 1 then  -- Also require at least 1 change
            return lastText, lastValue
        end
    end

    local text
    if value >= 1000000 then
        text = format("+%.1fM", value / 1000000)
    elseif value >= 1000 then
        text = format("+%.1fK", value / 1000)
    else
        text = format("+%.0f", value)
    end
    return text, value
end

-- Update threat text anchor based on setting
local function UpdateThreatTextAnchor(myPlate)
    local threatText = myPlate.threatText
    if not threatText then return end

    local anchor = ns.c_threatTextAnchor
    local offsetX = ns.c_threatTextOffsetX or 2
    local offsetY = ns.c_threatTextOffsetY or 0
    local hp = myPlate.hp

    threatText:ClearAllPoints()

    if anchor == "right_hp" then
        PixelUtil.SetPoint(threatText, "LEFT", hp, "RIGHT", offsetX, offsetY, 1, 1)
        threatText:SetJustifyH("LEFT")
    elseif anchor == "left_hp" then
        PixelUtil.SetPoint(threatText, "RIGHT", hp, "LEFT", -offsetX, offsetY, 1, 1)
        threatText:SetJustifyH("RIGHT")
    elseif anchor == "below_hp" then
        PixelUtil.SetPoint(threatText, "TOP", hp, "BOTTOM", offsetX, -offsetY, 1, 1)
        threatText:SetJustifyH("CENTER")
    elseif anchor == "top_hp" then
        PixelUtil.SetPoint(threatText, "BOTTOM", hp, "TOP", offsetX, offsetY, 1, 1)
        threatText:SetJustifyH("CENTER")
    elseif anchor == "left_name" then
        PixelUtil.SetPoint(threatText, "RIGHT", myPlate.nameText, "LEFT", -offsetX, offsetY, 1, 1)
        threatText:SetJustifyH("RIGHT")
    elseif anchor == "right_name" then
        -- Dynamic anchor: find rightmost visible element
        local anchorTo = myPlate.nameText
        local anchorPoint = "RIGHT"

        -- Check quest icon first (rightmost if visible)
        if myPlate.questIcon and myPlate.questIcon:IsShown() then
            anchorTo = myPlate.questIcon
        -- Then check level text
        elseif myPlate.levelText and myPlate.levelText:IsShown() then
            anchorTo = myPlate.levelText
        end

        PixelUtil.SetPoint(threatText, "LEFT", anchorTo, "RIGHT", offsetX, offsetY, 1, 1)
        threatText:SetJustifyH("LEFT")
    end
end

-- Update threat text display
local function UpdateThreatText(unit, myPlate)
    if not myPlate or not myPlate.threatText then return end

    local threatText = myPlate.threatText
    local anchor = ns.c_threatTextAnchor

    -- Hide if disabled, friendly, or personal bar
    if anchor == "disabled" or myPlate.isPlayer or UnitIsFriend("player", unit) then
        threatText:Hide()
        threatText._lastPct = nil
        threatText._lastLeadText = nil
        threatText._lastLeadValue = nil
        return
    end

    -- Only show for hostile NPCs on threat table
    if UnitIsPlayer(unit) or UnitPlayerControlled(unit) then
        threatText:Hide()
        threatText._lastPct = nil
        threatText._lastLeadText = nil
        threatText._lastLeadValue = nil
        return
    end

    -- Get threat info (5th return is raw threat value)
    local isTanking, status, scaledPct, rawPct, threatValue = UnitDetailedThreatSituation("player", unit)

    -- Hide if not on threat table
    if status == nil or not scaledPct or scaledPct <= 0 then
        threatText:Hide()
        threatText._lastPct = nil
        threatText._lastLeadText = nil
        threatText._lastLeadValue = nil
        return
    end

    -- Update font if changed
    if threatText._lastFont ~= ns.c_font or threatText._lastSize ~= ns.c_threatTextFontSize or threatText._lastOutline ~= ns.c_fontOutline then
        ns:SetFontSafe(threatText, ns.c_font, ns.c_threatTextFontSize, ns.c_fontOutline)
        threatText._lastFont = ns.c_font
        threatText._lastSize = ns.c_threatTextFontSize
        threatText._lastOutline = ns.c_fontOutline
    end

    -- Update anchor (handles dynamic "right_name" mode)
    if anchor == "right_name" or threatText._lastAnchor ~= anchor then
        UpdateThreatTextAnchor(myPlate)
        threatText._lastAnchor = anchor
    end

    -- Determine tank mode
    local tankModeActive = false
    local tankModeValue = ns.c_tankMode
    if tankModeValue == 2 then
        tankModeActive = true
    elseif tankModeValue == 1 then
        tankModeActive = group.playerIsTank
    end

    -- Only show threat text when there's meaningful competition
    local cache = threatLeadCache
    local inGroup = cache.groupSize > 0 or UnitExists("pet")

    -- Solo: hide threat text entirely (no point showing 100%)
    if not inGroup then
        threatText:Hide()
        threatText._lastPct = nil
        threatText._lastLeadText = nil
        threatText._lastLeadValue = nil
        return
    end

    local threatLead = nil
    local hasCompetition = false

    if isTanking then
        -- Tanking: show lead if there's competition
        threatLead, hasCompetition = GetThreatLead(unit, threatValue)
        if threatLead and threatLead > 0 and hasCompetition then
            local text, newValue = FormatThreatLead(threatLead, threatText._lastLeadValue, threatText._lastLeadText)
            if text ~= threatText._lastLeadText then
                threatText:SetText(text)
                threatText._lastLeadText = text
                threatText._lastLeadValue = newValue
            end
        else
            -- Tanking without competition: hide
            threatText:Hide()
            threatText._lastPct = nil
            threatText._lastLeadText = nil
            threatText._lastLeadValue = nil
            return
        end
    else
        -- Not tanking: show percentage (useful to know when close to pulling)
        local pctInt = floor(scaledPct + 0.5)
        if threatText._lastPct ~= pctInt then
            threatText:SetText(pctInt .. "%")
            threatText._lastPct = pctInt
            threatText._lastLeadText = nil
            threatText._lastLeadValue = nil
        end
    end

    -- Color based on threat status
    if tankModeActive then
        -- Tank mode: use threat lead for more granular color when available
        if threatLead and hasCompetition and threatValue and threatValue > 0 then
            -- Lead-based coloring: yellow when lead < 10% of our threat (close to losing)
            local leadPct = threatLead / threatValue
            if leadPct < 0.10 then
                -- Tight lead - yellow (transition/insecure)
                threatText:SetTextColor(ns.c_transColor_r, ns.c_transColor_g, ns.c_transColor_b)
            else
                -- Solid lead - white (secure)
                threatText:SetTextColor(1, 1, 1)
            end
        elseif status == 3 then
            threatText:SetTextColor(1, 1, 1)  -- White - secure aggro
        elseif status == 2 then
            threatText:SetTextColor(ns.c_transColor_r, ns.c_transColor_g, ns.c_transColor_b)
        else
            threatText:SetTextColor(ns.c_insecureColor_r, ns.c_insecureColor_g, ns.c_insecureColor_b)
        end
    else
        -- DPS mode: white when safe (status 0), threat colors otherwise
        if status == 0 then
            threatText:SetTextColor(1, 1, 1)  -- White - safe, low threat
        elseif status == 1 or status == 2 then
            threatText:SetTextColor(ns.c_dpsTransColor_r, ns.c_dpsTransColor_g, ns.c_dpsTransColor_b)
        else
            threatText:SetTextColor(ns.c_dpsAggroColor_r, ns.c_dpsAggroColor_g, ns.c_dpsAggroColor_b)
        end
    end

    threatText:Show()
end

-- Export for external use
ns.UpdateThreatText = UpdateThreatText
ns.UpdateThreatTextAnchor = UpdateThreatTextAnchor

-- Threat-based health bar coloring
UpdateColor = function(unit)
    local myPlate = ns.unitToPlate[unit]
    if not myPlate or myPlate.isNameOnly or not myPlate.hp then return end

    -- Skip personal bar - it has its own color logic
    if myPlate.isPlayer then return end

    local nativeReaction = ns.GetNativePlateReaction and ns.GetNativePlateReaction(unit)
    local isPlayer = UnitIsPlayer(unit)
    local isFriendly
    if nativeReaction ~= nil then
        isFriendly = nativeReaction == "friendly" or nativeReaction == "friendlyPlayer"
    else
        isFriendly = UnitIsFriend("player", unit)
    end
    if nativeReaction == "friendlyPlayer" then isPlayer = true end

    -- Update threat text display
    UpdateThreatText(unit, myPlate)

    local auraColor = myPlate._auraColorOverride
    if auraColor then
        myPlate.hp:SetStatusBarColor(auraColor.r, auraColor.g, auraColor.b)
        return
    end

    -- ===========================================
    -- EARLY RETURNS - Units that never get threat coloring
    -- ===========================================

    if isFriendly then
        if isPlayer and ns.c_classColoredHealth then
            local _, class = UnitClass(unit)
            local classColor = class and ns.GetClassColor(class)
            if classColor then
                myPlate.hp:SetStatusBarColor(classColor.r, classColor.g, classColor.b)
                return
            end
        end
        if nativeReaction == "friendlyPlayer" or isPlayer then
            myPlate.hp:SetStatusBarColor(ns.c_friendlyPlayerColor_r, ns.c_friendlyPlayerColor_g, ns.c_friendlyPlayerColor_b)
        else
            myPlate.hp:SetStatusBarColor(ns.c_friendlyNPCColor_r, ns.c_friendlyNPCColor_g, ns.c_friendlyNPCColor_b)
        end
        return
    end

    if isPlayer then
        if ns.c_classColoredHealth then
            local _, class = UnitClass(unit)
            local classColor = class and ns.GetClassColor(class)
            if classColor then
                myPlate.hp:SetStatusBarColor(classColor.r, classColor.g, classColor.b)
                return
            end
        end
        myPlate.hp:SetStatusBarColor(ns.c_hpColor_r, ns.c_hpColor_g, ns.c_hpColor_b)
        return
    end

    if nativeReaction == "tapped"
       or (not nativeReaction and UnitIsTapped(unit) and not UnitIsTappedByPlayer(unit)) then
        myPlate.hp:SetStatusBarColor(ns.c_tappedColor_r, ns.c_tappedColor_g, ns.c_tappedColor_b)
        return
    end

    -- 4. Player-controlled units (hostile pets, totems, mind-controlled, etc.) - flat color, no threat
    if UnitPlayerControlled(unit) then
        myPlate.hp:SetStatusBarColor(ns.c_petColor_r, ns.c_petColor_g, ns.c_petColor_b)
        return
    end

    -- ===========================================
    -- ===========================================

    if ns.c_tankMode == 0 then
        if nativeReaction == "neutral" or UnitCreatureType(unit) == "Critter" then
            myPlate.hp:SetStatusBarColor(ns.c_neutralColor_r, ns.c_neutralColor_g, ns.c_neutralColor_b)
        else
            myPlate.hp:SetStatusBarColor(ns.c_hpColor_r, ns.c_hpColor_g, ns.c_hpColor_b)
        end
        return
    end

    -- Get threat status using UnitDetailedThreatSituation for more reliable results
    -- Returns: isTanking, status, threatPct, rawThreatPct, threatValue
    -- status: nil = not on threat table, 0 = not tanking (lowest threat), 1 = not tanking but higher threat,
    --         2 = insecurely tanking, 3 = securely tanking
    local isTanking, status = UnitDetailedThreatSituation("player", unit)
    if status == nil and ns.GetNativePlateThreatStatus then
        status = ns.GetNativePlateThreatStatus(unit)
    end

    if status == nil then
        if nativeReaction == "neutral" or UnitCreatureType(unit) == "Critter" then
            myPlate.hp:SetStatusBarColor(ns.c_neutralColor_r, ns.c_neutralColor_g, ns.c_neutralColor_b)
        else
            myPlate.hp:SetStatusBarColor(ns.c_hpColor_r, ns.c_hpColor_g, ns.c_hpColor_b)
        end
        return
    end

    local tankModeActive = false
    local tankModeValue = ns.c_tankMode

    if tankModeValue == 2 then
        tankModeActive = true
    elseif tankModeValue == 1 then
        tankModeActive = group.playerIsTank
    end


    if tankModeActive then
        -- status 3 = Secure aggro -> secureColor (good - you have solid aggro)
        -- status 2 = Insecure tanking -> transColor (warning - you have aggro but losing it)
        -- status 1 = High threat but not tanking -> check off-tank situation
        -- status 0 = Lowest threat -> insecureColor (bad - you need to get aggro)

        if status == 3 then
            -- Secure aggro - GOOD for tank
            myPlate.hp:SetStatusBarColor(ns.c_secureColor_r, ns.c_secureColor_g, ns.c_secureColor_b)
        elseif status == 2 then
            -- Insecure tanking - WARNING (you have aggro but it's not solid)
            myPlate.hp:SetStatusBarColor(ns.c_transColor_r, ns.c_transColor_g, ns.c_transColor_b)
        elseif status == 1 then
            -- High threat but someone else is tanking
            local isOffTank = CheckOffTank(unit)
            if isOffTank then
                -- Another tank has aggro - off-tank color (acceptable)
                myPlate.hp:SetStatusBarColor(ns.c_offTankColor_r, ns.c_offTankColor_g, ns.c_offTankColor_b)
            else
                -- A DPS has aggro or threat is unstable - transition color (you're gaining threat)
                myPlate.hp:SetStatusBarColor(ns.c_transColor_r, ns.c_transColor_g, ns.c_transColor_b)
            end
        else
            -- status == 0: Lowest threat - BAD for tank (you don't have aggro)
            local isOffTank = CheckOffTank(unit)
            if isOffTank then
                -- Another tank has aggro - off-tank color (acceptable)
                myPlate.hp:SetStatusBarColor(ns.c_offTankColor_r, ns.c_offTankColor_g, ns.c_offTankColor_b)
            else
                -- Nobody tanking properly - insecure color (bad)
                myPlate.hp:SetStatusBarColor(ns.c_insecureColor_r, ns.c_insecureColor_g, ns.c_insecureColor_b)
            end
        end
    else
        -- status 3 = You have solid aggro -> dpsAggroColor (bad - you're tanking!)
        -- status 2 = You're tanking insecurely -> dpsTransColor (warning - losing aggro)
        -- status 1 = High threat but not tanking -> dpsTransColor (warning - watch your threat)
        -- status 0 = Lowest threat -> dpsSecureColor (safe - you have no threat issues)

        if status == 3 then
            -- You have solid aggro - BAD for DPS
            myPlate.hp:SetStatusBarColor(ns.c_dpsAggroColor_r, ns.c_dpsAggroColor_g, ns.c_dpsAggroColor_b)
        elseif status == 2 or status == 1 then
            -- High threat or insecurely tanking - WARNING
            myPlate.hp:SetStatusBarColor(ns.c_dpsTransColor_r, ns.c_dpsTransColor_g, ns.c_dpsTransColor_b)
        else
            -- status == 0: Safe, lowest threat - use DPS safe color (magenta by default)
            myPlate.hp:SetStatusBarColor(ns.c_dpsSecureColor_r, ns.c_dpsSecureColor_g, ns.c_dpsSecureColor_b)
        end
    end
end
ns.UpdateColor = UpdateColor

-- Register for group updates - ONLY scan on specific events:
-- 1. GROUP_ROSTER_UPDATE (group composition changes)
-- 2. READY_CHECK (10 seconds after ready check starts)
-- 3. PLAYER_ENTERING_WORLD (zone/instance changes, reload, login)
local groupFrame = CreateFrame("Frame")
groupFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
groupFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
groupFrame:RegisterEvent("READY_CHECK")  -- Ready check started
groupFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")  -- Zone changes (entering instances)
groupFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")  -- Role changes (manual assignment, M+ groups)
groupFrame:RegisterEvent("PLAYER_LOGOUT")  -- Cancel timers on logout
groupFrame:RegisterEvent("PLAYER_DEAD")  -- Clear targeting me on death

-- Timer for delayed ready check scan
local readyCheckTimer = nil

-- Cancel all pending timers (called on logout/zone change)
local function CancelPendingTimers()
    if readyCheckTimer then
        readyCheckTimer:Cancel()
        readyCheckTimer = nil
    end
    if arenaMarkTimer then
        arenaMarkTimer:Cancel()
        arenaMarkTimer = nil
    end
end

local function DoReadyCheckScan()
    readyCheckTimer = nil
    cachedVigilanceCaster = nil
    vigilanceScanTime = 0
    RefreshGroupRoles(true)
end

groupFrame:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGOUT" then
        -- Cancel all pending timers on logout to prevent errors
        CancelPendingTimers()
        return
    elseif event == "READY_CHECK" then
        -- Cancel any pending timer
        if readyCheckTimer then
            readyCheckTimer:Cancel()
            readyCheckTimer = nil
        end
        -- Schedule scan 10 seconds after ready check
        readyCheckTimer = C_Timer.NewTimer(10, DoReadyCheckScan)
    elseif event == "PLAYER_DEAD" then
        -- Clear all targeting me states when player dies (can't be targeted while dead)
        for unit, myPlate in pairs(ns.unitToPlate) do
            if myPlate and myPlate.isTargetingMe then
                myPlate.isTargetingMe = nil
                UpdateTargetingMeVisual(myPlate, false)
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ROLES_ASSIGNED" then
        -- Cancel pending timers on zone change (they're no longer relevant)
        if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
            CancelPendingTimers()
            -- Cleanup dirty tables on zone/world change to prevent stale unit references
            wipe(dirtyHealth)
            wipe(dirtyThreat)
            wipe(dirtyAbsorb)
            -- Clear all targeting me states on zone change
            for unit, myPlate in pairs(ns.unitToPlate) do
                if myPlate and (myPlate.isTargetingMe or myPlate._targetingMeActive) then
                    myPlate.isTargetingMe = nil
                    myPlate._targetingMeActive = nil
                    if myPlate.targetingMeGlow then myPlate.targetingMeGlow:Hide() end
                end
            end
        end
        -- Immediate full refresh on roster/zone changes
        cachedVigilanceCaster = nil
        vigilanceScanTime = 0
        RefreshGroupRoles(true)
        UpdateThreatLeadGroupCache()  -- Update cached group state for threat lead
        -- Update arena status for arena number display
        local wasInArena = inArena
        UpdateArenaStatus()
        -- Schedule arena number refresh after entering arena
        if inArena and not wasInArena then
            ScheduleArenaNumberRefresh()
        end
    end
end)

-- Refresh ONLY the combo-point pips on the current target plate. Split out of
-- UpdateTarget so combo-point events can update the pips without tearing down
-- and rebuilding the target glow/scale.
function ns.TargetAllowsResources()
    if not UnitExists("target") then return false end
    local canAttack = (ns.UnitCanAttack or UnitCanAttack)
    if canAttack and canAttack("player", "target") then return true end
    return not UnitIsFriend("player", "target")
end

local function RefreshTargetComboPoints()
    local plate = ns.currentTargetPlate
    if not plate then return end

    -- Personal bar mode takes priority - hide pips on the target plate.
    if ns.c_cpOnPersonalBar then
        if plate.cps then
            for i = 1, #plate.cps do plate.cps[i]:Hide() end
        end
    elseif ns.c_showComboPoints and ns.TargetAllowsResources() then
        EnsureComboPoints(plate, false)  -- false = target nameplate mode
        if plate.cps then
            local points = GetComboPoints("player", "target")
            for i = 1, #plate.cps do
                if i <= points then plate.cps[i]:Show() else plate.cps[i]:Hide() end
            end
        end
    else
        -- Disabled or friendly target - hide any existing pips.
        if plate.cps then
            for i = 1, #plate.cps do plate.cps[i]:Hide() end
        end
    end
end

function ns:ClearTargetOwnership(nextGUID, suppressNotify)
    local prevPlate = ns.currentTargetPlate
    if prevPlate then
        prevPlate.isTarget = nil
        if prevPlate.cps then
            for i = 1, #prevPlate.cps do prevPlate.cps[i]:Hide() end
        end
        UpdateTargetGlow(prevPlate, false)

        if not prevPlate.isPlayer then
            local prevUnit = prevPlate.unit
            if prevUnit and UnitIsPet(prevUnit) then
                ns:ApplyPlateScale(prevPlate, ns.c_scale * ns.c_petScale)
            elseif prevPlate.isFriendly then
                ns:ApplyPlateScale(prevPlate, ns.c_scale * ns.c_friendlyScale)
            else
                ns:ApplyPlateScale(prevPlate, ns.c_scale)
            end
            prevPlate._lastScale = nil
        end
    end

    ns.currentTargetPlate = nil
    ns.currentTargetGUID = nextGUID
    if not suppressNotify and ns.UpdateRunes then ns:UpdateRunes() end
end

function ns:CommitTargetOwnership(plate, guid, suppressNotify)
    if not plate or plate.isNameOnly then return false end

    if ns.currentTargetPlate ~= plate then
        ns:ClearTargetOwnership(guid, true)
        ns.currentTargetPlate = plate
    else
        ns.currentTargetGUID = guid or ns.currentTargetGUID
    end

    plate.isTarget = true
    if not plate.isPlayer then
        ns:ApplyPlateScale(plate, ns.c_scale * ns.c_targetScale)
    end
    UpdateTargetGlow(plate, true)
    RefreshTargetComboPoints()
    if not suppressNotify and ns.UpdateRunes then ns:UpdateRunes(true) end
    return true
end

function ns:ReleaseTargetOwnership(plate)
    if not plate or ns.currentTargetPlate ~= plate then return false end
    plate.isTarget = nil
    ns.currentTargetPlate = nil
    if ns.UpdateRunes then ns:UpdateRunes() end
    return true
end

function ns:IsTargetPlate(plate)
    return plate and ns.currentTargetPlate == plate and plate.isTarget == true
end

local function UpdateTarget()
    local targetGUID = UnitExists("target") and UnitGUID("target") or nil

    if targetGUID and ns.currentTargetPlate and ns.currentTargetGUID == targetGUID then
        RefreshTargetComboPoints()
        if ns.UpdateRunes then ns:UpdateRunes() end
        return
    end

    if not targetGUID then
        ns:ClearTargetOwnership(nil)
        return
    end

    ns:ClearTargetOwnership(targetGUID, true)
    local nameplate = C_NamePlate_GetNamePlateForUnit("target")
    if nameplate and nameplate.myPlate and not nameplate.myPlate.isNameOnly then
        ns:CommitTargetOwnership(nameplate.myPlate, targetGUID)
    elseif ns.UpdateRunes then
        ns:UpdateRunes()
    end
end

local function ValidateTargetPlate()
    if not ns.currentTargetGUID then
        ns:ClearTargetOwnership(nil)
        return
    end

    if ns.currentTargetPlate then
        local unit = ns.currentTargetPlate.unit
        local plateGUID = unit and UnitGUID(unit)
        if plateGUID == ns.currentTargetGUID
           or (unit and UnitExists("target") and UnitIsUnit(unit, "target")) then
            ns.currentTargetPlate.isTarget = true
            if ns.UpdateRunes then ns:UpdateRunes() end
            return
        end
        ns:ClearTargetOwnership(ns.currentTargetGUID, true)
    end

    local plate = GetPlateByGUID(ns.currentTargetGUID)
    if plate then
        ns:CommitTargetOwnership(plate, ns.currentTargetGUID)
        return
    end

    if UnitExists("target") then
        local nameplate = C_NamePlate_GetNamePlateForUnit("target")
        if nameplate and nameplate.myPlate and not nameplate.myPlate.isNameOnly then
            ns:CommitTargetOwnership(nameplate.myPlate, ns.currentTargetGUID)
            return
        end
    end

    if ns.UpdateRunes then ns:UpdateRunes() end
end

-- Expose validation for stacking module to call
ns.ValidateTargetPlate = ValidateTargetPlate

-- Ensure raid icon exists (creates on-demand for any plate type)
local function UpdateLevelText(unit)
    local myPlate = ns.unitToPlate[unit]
    if not myPlate or not myPlate.levelText then return end

    local levelMode = ns.c_levelMode
    if levelMode == "disabled" then
        myPlate.levelText:Hide()
        return
    end

    -- Hide level text in arenas when arena numbers are shown
    if inArena and ns.c_arenaNumbers then
        myPlate.levelText:Hide()
        return
    end

    -- Check if we should show based on mode and unit type
    local isFriendly = UnitIsFriend("player", unit)
    if levelMode == "enemies" and isFriendly then
        myPlate.levelText:Hide()
        return
    end

    -- Don't show level for player's own nameplate
    if UnitIsUnit(unit, "player") then
        myPlate.levelText:Hide()
        return
    end

    local level = UnitLevel(unit)

    local levelText = myPlate.levelText

    -- Font caching
    if levelText._lastFont ~= ns.c_font or levelText._lastFontSize ~= ns.c_fontSize or levelText._lastOutline ~= ns.c_fontOutline then
        ns:SetFontSafe(levelText, ns.c_font, ns.c_fontSize, ns.c_fontOutline)
        levelText._lastFont = ns.c_font
        levelText._lastFontSize = ns.c_fontSize
        levelText._lastOutline = ns.c_fontOutline
    end

    -- Position caching (depends on name display format and nameInHealthbar)
    local positionKey = ns.c_nameDisplayFormat .. (ns.c_nameInHealthbar and "_inbar" or "")
    if levelText._lastPositionKey ~= positionKey then
        levelText:ClearAllPoints()
        if ns.c_nameInHealthbar then
            -- Anchor to right of healthbar when name is inside
            levelText:SetPoint("LEFT", myPlate.hp, "RIGHT", PixelUtil.GetNearestPixelSize(2, 1), 0)
        elseif ns.c_nameDisplayFormat == "disabled" then
            levelText:SetPoint("BOTTOM", myPlate.hp, "TOP", 0, PixelUtil.GetNearestPixelSize(3, 1))
        else
            levelText:SetPoint("LEFT", myPlate.hp, "RIGHT", PixelUtil.GetNearestPixelSize(2, 1), 0)
        end
        levelText._lastPositionKey = positionKey
    end

    -- Get difficulty color
    local color
    if level <= 0 then
        -- Skull level (world boss or unknown) - show "??" in red
        color = GetQuestDifficultyColor(999)  -- Forces red color
        levelText:SetText("??")
    else
        color = GetQuestDifficultyColor(level)
        levelText:SetText(level)
    end

    levelText:SetTextColor(color.r, color.g, color.b)
    levelText:Show()
end

-- Export for Core.lua (PLAYER_LEVEL_UP handler)
ns.UpdateLevelText = UpdateLevelText

-- Classification icon atlas/textures
ns.ClassificationAtlas = {
    rare = "warfront-alliancehero",
    elite = "islands-azeriteboss",
    rareelite = "warfront-hordehero",
    worldboss = "dungeonskull",
    boss = "dungeonskull",
}

ns.ClassificationTextureStyles = {
    colored_skulls = {
        texture = "Interface\\AddOns\\TurboPlates\\Textures\\EliteIcons\\ElvUI_SkullIcon.tga",
        ratio = 0.9166666667,
        coords = { 0.078125, 0.9375, 0.03125, 0.96875 },
    },
    elvui_dragons = {
        texture = "Interface\\AddOns\\TurboPlates\\Textures\\EliteIcons\\ElvUI_Nameplates.blp",
        ratio = 1.3,
        coordsByClassification = {
            rare = { 0, 0.15234375, 0.671875, 0.90625 },
            elite = { 0, 0.15234375, 0.359375, 0.59375 },
            rareelite = { 0, 0.15234375, 0.359375, 0.59375 },
            worldboss = { 0, 0.15234375, 0.359375, 0.59375 },
            boss = { 0, 0.15234375, 0.359375, 0.59375 },
        },
    },
    sre_classic = {
        folder = "Interface\\AddOns\\TurboPlates\\Textures\\EliteIcons\\SRE\\classic\\",
        ratio = 1.9595959596,
        coords = { 0.00390625, 0.76171875, 0, 0.7734375 },
    },
    sre_modern = {
        folder = "Interface\\AddOns\\TurboPlates\\Textures\\EliteIcons\\SRE\\modern\\",
        ratio = 1.24,
        coords = { 0, 0.96875, 0, 0.78125 },
    },
    sre_tiny = {
        folder = "Interface\\AddOns\\TurboPlates\\Textures\\EliteIcons\\SRE\\tiny\\",
        ratio = 1.4819277108,
        coords = { 0.0078125, 0.96875, 0, 0.6484375 },
    },
}

ns.ClassificationSkullColors = {
    rare = { 1, 0.82, 0 },
    elite = { 1, 0.82, 0 },
    rareelite = { 1, 0.45, 0 },
    worldboss = { 1, 0.05, 0.05 },
    boss = { 1, 0.05, 0.05 },
}

function ns.ApplyClassificationIconTexture(icon, style, classification)
    if not ns.ClassificationAtlas[classification] then return nil end

    icon:SetVertexColor(1, 1, 1, 1)
    icon:SetTexCoord(0, 1, 0, 1)

    if style == "default" then
        local atlasName = classification and ns.ClassificationAtlas[classification]
        if not atlasName then return nil end
        if ns.SafeSetAtlas then ns.SafeSetAtlas(icon, atlasName) end
        return 1
    end

    local styleInfo = ns.ClassificationTextureStyles[style]
    if not styleInfo then return nil end

    if styleInfo.texture then
        icon:SetTexture(styleInfo.texture)
    elseif styleInfo.folder then
        local fileKey = classification == "boss" and "worldboss" or classification
        icon:SetTexture(styleInfo.folder .. fileKey .. ".tga")
    end

    local coords = styleInfo.coords
    if styleInfo.coordsByClassification then
        coords = styleInfo.coordsByClassification[classification]
    end
    if coords then
        icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    end

    if style == "colored_skulls" then
        local color = ns.ClassificationSkullColors[classification]
        if color then icon:SetVertexColor(color[1], color[2], color[3], 1) end
    end

    return styleInfo.ratio or 1
end

-- Update classification indicator (elite/rare/boss star icon)
function ns.UpdateClassificationIndicator(unit)
    local myPlate = ns.unitToPlate[unit]
    if not myPlate then return end

    local classifyIcon = myPlate.classifyIcon
    if not classifyIcon then return end

    local anchor = ns.c_classificationAnchor
    local style = ns.c_classificationStyle or "default"

    -- Early exit for disabled or name-only plates
    if style == "none" or myPlate.isNameOnly then
        classifyIcon:Hide()
        return
    end

    local classification = UnitClassification(unit)

    -- Check for skull level (boss) - elite/rareelite mobs with level <= 0 are dungeon/raid bosses
    if (classification == "elite" or classification == "rareelite") and UnitLevel(unit) <= 0 then
        classification = "boss"
    end

    local ratio = classification and ns.ApplyClassificationIconTexture(classifyIcon, style, classification)

    if ratio then
        local iconHeight = ns.c_classificationSize or 18
        local iconWidth = iconHeight * ratio

        if classifyIcon._lastWidth ~= iconWidth or classifyIcon._lastHeight ~= iconHeight then
            PixelUtil.SetSize(classifyIcon, iconWidth, iconHeight, 1, 1)
            classifyIcon._lastWidth = iconWidth
            classifyIcon._lastHeight = iconHeight
        end

        local xOffset, yOffset = ns.c_classificationX or 0, ns.c_classificationY or 0
        local positionKey = anchor .. ":" .. xOffset .. ":" .. yOffset .. ":" .. style .. ":" .. classification
        if classifyIcon._anchor ~= positionKey then
            classifyIcon:ClearAllPoints()
            if anchor == "RIGHT" then
                classifyIcon:SetPoint("LEFT", myPlate.hp, "RIGHT", 2 + xOffset, yOffset)
            elseif anchor == "LEFT" then
                classifyIcon:SetPoint("RIGHT", myPlate.hp, "LEFT", -2 + xOffset, yOffset)
            else
                if anchor == "TOPLEFT" or anchor == "TOPRIGHT" then
                    yOffset = yOffset - 2
                end
                classifyIcon:SetPoint("CENTER", myPlate.hp, anchor or "TOPLEFT", xOffset, yOffset)
            end
            classifyIcon._anchor = positionKey
        end

        classifyIcon:Show()
    else
        classifyIcon:Hide()
    end
end

-- Update raid icon (for full plates only)
local function UpdateRaidIcon(unit)
    local myPlate = ns.unitToPlate[unit]
    if not myPlate then return end

    local blizzFrame = myPlate.parentPlate
    local icon = blizzFrame and blizzFrame._tpRaidIcon
    if not icon then
        if myPlate.raidIcon then myPlate.raidIcon:Hide() end
        return
    end

    if myPlate.raidIcon and myPlate.raidIcon ~= icon then
        myPlate.raidIcon:Hide()
    end
    myPlate.raidIcon = icon

    if icon:GetParent() ~= myPlate then icon:SetParent(myPlate) end
    icon:SetAlpha(1)

    if icon._lastSize ~= ns.c_raidMarkerSize then
        PixelUtil.SetSize(icon, ns.c_raidMarkerSize, ns.c_raidMarkerSize, 1, 1)
        icon._lastSize = ns.c_raidMarkerSize
    end

    local isNameOnly = myPlate.isNameOnly
    local anchor = isNameOnly and "NAME_ONLY" or ns.c_raidMarkerAnchor
    local xOff = isNameOnly and 0 or ns.c_raidMarkerX
    local yOff = isNameOnly and 0 or ns.c_raidMarkerY

    if icon._lastAnchor ~= anchor or icon._lastX ~= xOff or icon._lastY ~= yOff then
        icon:ClearAllPoints()
        if isNameOnly then
            icon:SetPoint("BOTTOM", myPlate.nameText, "TOP", 0, 2)
        else
            if anchor == "LEFT" then
                icon:SetPoint("RIGHT", myPlate.hp, "LEFT", xOff - 2, yOff)
            elseif anchor == "RIGHT" then
                icon:SetPoint("LEFT", myPlate.hp, "RIGHT", xOff + 2, yOff)
            elseif anchor == "TOP" then
                icon:SetPoint("BOTTOM", myPlate.nameText, "TOP", xOff, yOff + 2)
            else
                icon:SetPoint("RIGHT", myPlate.hp, "LEFT", xOff - 2, yOff)
            end
        end
        icon._lastAnchor = anchor
        icon._lastX = xOff
        icon._lastY = yOff
    end

end
ns.UpdateRaidIcon = UpdateRaidIcon

-- Ensure quest icon exists (creates on-demand for any plate type)
local function EnsureQuestIcon(myPlate)
    if myPlate.questIcon then return end

    local questIcon = myPlate:CreateTexture(nil, "OVERLAY")
    PixelUtil.SetSize(questIcon, 16, 16, 1, 1)
    PixelUtil.SetPoint(questIcon, "LEFT", myPlate.hp, "RIGHT", 2, 0, 1, 1)
    questIcon:Hide()
    myPlate.questIcon = questIcon
end

-- Quest system state (consolidated to reduce local variable count)
local Quest = {
    GetLogIndexByID = GetQuestLogIndexByID,
    GetLogTitle = GetQuestLogTitle,
    isNilOrEmpty = string.isNilOrEmpty or function(s) return s == nil or s == "" end,
    retryState = {},  -- Key = unit string, Value = { token, attempt }
    MAX_RETRIES = 4,
    RETRY_DELAYS = { 0.15, 0.3, 0.6, 1.2 },  -- Exponential backoff
    IsObjectiveStatus = function(status)
        return status == "collect" or status == "objective"
    end,
}

-- =============================================================================
-- NATIVE QUEST-OBJECTIVE DETECTION (self-contained, independent of ClassicAPI)
-- 3.3.5a exposes per-unit quest data poorly, so we use two complementary sources:
--   1) TOOLTIP scan of the plate's REAL unit (target/focus/mouseover, or the real
--      token on a native engine). The game tooltip lists a quest mob's objective
--      progress ("Purifying Earth: 1/2") even for use-item / interact quests where
--      the mob name never appears in the quest text - the only way to catch those.
--   2) QUEST-LOG objective name match against the plate's scraped name, for plates
--      with no real unit (unbound): catches kill / collect-from quests passively
--      on every visible mob.
-- ns.GetPlateQuestInfo returns the shape consumers expect from GetUnitQuestInfo:
-- questStatus ("objective" when an in-progress objective is detected), questID,
-- talkToMe (the latter two nil - we detect objectives, not quest-givers).
-- Wrapped in a do-block so its state stays out of the main chunk's local pool
-- (Lua 5.1 caps a function at 200 locals); the ns.* fns keep it via upvalues.
-- =============================================================================
do
local GetNumQuestLeaderBoards = GetNumQuestLeaderBoards
local GetQuestLogLeaderBoard = GetQuestLogLeaderBoard
local GetNumQuestLogEntries = GetNumQuestLogEntries

-- (1) Quest-log objective cache, rebuilt lazily after QUEST_LOG_UPDATE.
--   questObjectiveTexts : raw in-progress objective strings (for name match).
--   questObjectiveKeys  : the same with the " x/y" stripped (for tooltip match).
local questObjectiveTexts = {}
local questObjectiveKeys = {}
local questNameMatchCache = {}
local questCacheDirty = true
-- [mobName] = objectiveKey learned from a tooltip scan of a BOUND mob. Item-drop
-- quests name the ITEM in the objective ("Highland Raptor Eye"), not the mob, so
-- name match can't find them - but once we've seen ONE of a mob type as a quest
-- target via its tooltip, every same-named plate is one too (they all drop it).
-- Gated by questObjectiveKeys so it self-invalidates when the objective is done.
local learnedQuestMobs = {}
ns.InvalidateQuestCache = function() questCacheDirty = true end

-- Strip a trailing " : x/y" progress and a leading dash/bullet so the same
-- objective matches whether it came from the quest log or the unit tooltip.
local function NormalizeObjective(s)
    if not s then return nil end
    s = s:gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    s = s:gsub("^[%s%-%.•]+", "")
    s = s:gsub("%s+$", "")
    return s
end

local function RebuildQuestObjectiveCache()
    questCacheDirty = false
    wipe(questObjectiveTexts)
    wipe(questObjectiveKeys)
    wipe(questNameMatchCache)
    local numEntries = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
    for i = 1, numEntries do
        local title, _, _, _, isHeader, _, isComplete = GetQuestLogTitle(i)
        if title and not isHeader and not isComplete then
            local numObj = (GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i)) or 0
            for o = 1, numObj do
                local text, _, finished = GetQuestLogLeaderBoard(o, i)
                if text and not finished then
                    questObjectiveTexts[#questObjectiveTexts + 1] = text
                    local key = NormalizeObjective(text)
                    if key and key ~= "" then questObjectiveKeys[key] = true end
                end
            end
        end
    end
end

-- (2) Hidden scanning tooltip. True if the unit's tooltip shows an IN-PROGRESS
-- objective line (x/y, x < y) that matches one of OUR quest-log objectives. The
-- quest-log cross-check matters: other addons (Questie, drop trackers) inject
-- their own "x/y" lines into unit tooltips, which would false-positive otherwise
-- (a "!" on a mob you have no quest for). Catches use-item/interact quests where
-- the mob name isn't in the objective text (the tooltip still shows the progress).
local questScanTip
-- Returns the matched objective KEY (normalised) if the unit's tooltip shows an
-- in-progress objective (x/y, x<y) that's in OUR quest log, else nil. The quest-log
-- cross-check matters: other addons (Questie, drop trackers) inject "x/y" lines into
-- unit tooltips, which would false-positive otherwise (a "!" on a non-quest mob).
local function UnitTooltipQuestKey(realUnit)
    if not realUnit then return nil end
    if questCacheDirty then RebuildQuestObjectiveCache() end
    if not next(questObjectiveKeys) then return nil end  -- no active objectives
    if not questScanTip then
        questScanTip = CreateFrame("GameTooltip", "TurboPlatesQuestScanTip", UIParent, "GameTooltipTemplate")
    end
    questScanTip:SetOwner(UIParent, "ANCHOR_NONE")  -- ANCHOR_NONE + Hide() keeps it invisible
    questScanTip:ClearLines()
    -- pcall: SetUnit on an unexpected token shouldn't error out the caller.
    if not pcall(questScanTip.SetUnit, questScanTip, realUnit) then
        questScanTip:Hide()
        return nil
    end
    local key
    for i = 2, (questScanTip:NumLines() or 0) do  -- line 1 is the unit name
        local fs = _G["TurboPlatesQuestScanTipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text then
            local cur, total = strmatch(text, "(%d+)%s*/%s*(%d+)")
            if cur then
                cur, total = tonumber(cur), tonumber(total)
                local k = (cur and total and total > 0 and cur < total) and NormalizeObjective(text)
                if k and questObjectiveKeys[k] then
                    key = k
                    break
                end
            end
        end
    end
    questScanTip:Hide()
    return key
end

-- (3) Name match: a plate is a quest target if its name is the tracked creature/
-- item name at the START of an in-progress objective. The name is anchored to the
-- start of the line in every locale ("MobName slain: 3/10", "MobName getötet: 3/10",
-- "MobName：已击杀 3/10"), so we MUST anchor there rather than a free substring:
-- a plain substring match flags a plate whose name is only a SUFFIX of the real
-- mob name ("Pterrordax" inside the quest mob "Frenzied Pterrordax"). Works on
-- unbound plates (no tooltip).
local function PlateNameMatchesQuest(plateName)
    if not plateName or plateName == "" then return false end
    if questCacheDirty then RebuildQuestObjectiveCache() end
    local cached = questNameMatchCache[plateName]
    if cached ~= nil then return cached end
    local result = false
    local nlen = #plateName
    for i = 1, #questObjectiveTexts do
        local text = questObjectiveTexts[i]
        -- Anchor at the start: the objective line must BEGIN with the plate name.
        if text:sub(1, nlen) == plateName then
            -- Trailing boundary: reject when the next byte continues a Latin word
            -- (letter/digit), i.e. the plate name is only a prefix of a longer
            -- first word ("Frenz" vs "Frenzied"). nil = end-of-string = a match.
            local after = text:byte(nlen + 1)
            if not after
               or not ((after >= 48 and after <= 57)        -- 0-9
                    or (after >= 65 and after <= 90)         -- A-Z
                    or (after >= 97 and after <= 122)) then  -- a-z
                result = true
                break
            end
        end
    end
    questNameMatchCache[plateName] = result
    return result
end

function ns.GetPlateQuestInfo(plateUnit)
    -- Real unit behind the plate: the bound unit on compat, the real token on a
    -- native engine, nil for an unbound compat plate.
    local realUnit
    if ns.GetPlateRealUnit then
        realUnit = ns.GetPlateRealUnit(plateUnit)
    else
        realUnit = plateUnit
    end
    local name = UnitName(plateUnit)
    if realUnit then
        local key = UnitTooltipQuestKey(realUnit)
        if key then
            if name and learnedQuestMobs[name] ~= key then
                learnedQuestMobs[name] = key  -- learn the mob type
                -- Newly learned: refresh all plates so same-named UNBOUND ones show
                -- the icon now (deferred to avoid recursing through
                -- UpdateAllQuestIcons -> UpdateQuestIcon -> here).
                if C_Timer_After and ns.UpdateAllQuestIcons then
                    C_Timer_After(0, ns.UpdateAllQuestIcons)
                end
            end
            return "objective"
        end
    end
    if name and PlateNameMatchesQuest(name) then
        return "objective"
    end
    -- Item-drop quest (objective names the item, not the mob): show on every
    -- same-named plate once we've learned one via tooltip, while the objective is
    -- still active (PlateNameMatchesQuest above already refreshed the cache).
    if name then
        local lk = learnedQuestMobs[name]
        if lk and questObjectiveKeys[lk] then
            return "objective"
        end
    end
    return nil
end
end  -- native quest-detection do-block

-- Update quest objective icon for a unit (full plates)
-- Uses C_QuestLog.GetUnitQuestInfo and QuestUtil to get appropriate icon
-- Logic matches FrameXML/CompactUnitFrame.lua:UpdateQuestIcon()
local function UpdateQuestIcon(unit)
    local myPlate = ns.unitToPlate[unit]
    if not myPlate then return end

    -- Fast path: quest icons completely disabled
    if not ns.c_questIconsEnabled then
        if myPlate.questIcon then myPlate.questIcon:Hide() end
        return
    end

    -- Skip for name-only plates (handled separately by UpdateLiteQuestIcon)
    if myPlate.isNameOnly then
        if myPlate.questIcon then myPlate.questIcon:Hide() end
        return
    end

    -- Quest info: prefer our native detector (no ClassicAPI needed; catches
    -- interact-quests via a tooltip scan of the bound unit AND kill/collect quests
    -- via quest-log name match on any plate). Fall back to ClassicAPI's
    -- GetUnitQuestInfo for the quest-giver (!/?) detection it provides, but ONLY on
    -- non-hostile units: a hostile mob is never a quest giver, and ClassicAPI was
    -- flagging some with a bogus "!" (our native already covers hostile objectives).
    local questStatus, questID, talkToMe = ns.GetPlateQuestInfo(unit)
    if not questStatus and C_QuestLog and C_QuestLog.GetUnitQuestInfo then
        local rk = UnitReaction("player", unit)
        if rk and rk > 2 then
            local questUnit = (ns.GetPlateRealUnit and ns.GetPlateRealUnit(unit)) or unit
            questStatus, questID, talkToMe = C_QuestLog.GetUnitQuestInfo(questUnit)
        end
    end

    -- No quest data for this unit
    if Quest.isNilOrEmpty(talkToMe) and not questStatus then
        -- Retry mechanism with exponential backoff
        if UnitExists(unit) then
            local state = Quest.retryState[unit]
            local attempt = state and state.attempt or 0

            if attempt < Quest.MAX_RETRIES then
                local token = {}
                local delay = Quest.RETRY_DELAYS[attempt + 1] or 1.2
                Quest.retryState[unit] = { token = token, attempt = attempt + 1 }

                C_Timer_After(delay, function()
                    local current = Quest.retryState[unit]
                    if not current or current.token ~= token then return end
                    if UnitExists(unit) then
                        UpdateQuestIcon(unit)
                    else
                        Quest.retryState[unit] = nil
                    end
                end)
            end
        end
        if myPlate.questIcon then myPlate.questIcon:Hide() end
        return
    end

    -- Success - clear retry state for this unit
    Quest.retryState[unit] = nil

    -- Validate quest is in log and not complete (mirror lite plate validation)
    if questID and questID > 0 then
        local questLogIndex = Quest.GetLogIndexByID(questID)
        if questLogIndex == 0 then
            if myPlate.questIcon then myPlate.questIcon:Hide() end
            return
        else
            local isComplete = select(7, Quest.GetLogTitle(questLogIndex))
            if isComplete then
                if myPlate.questIcon then myPlate.questIcon:Hide() end
                return
            end
        end
    end

    local atlas, desaturate

    -- Check for quest NPC (pickup/turnin) first
    if not Quest.isNilOrEmpty(talkToMe) then
        if not ns.c_showQuestNPCs then
            if myPlate.questIcon then myPlate.questIcon:Hide() end
            return
        end
        -- Get atlas for talk-to-me NPC icons
        if QuestUtil and QuestUtil.GetTalkToMeQuestIcon then
            atlas, desaturate = QuestUtil.GetTalkToMeQuestIcon(talkToMe)
        end
        -- Fallback if no atlas returned
        if not atlas and QuestUtil and QuestUtil.GetQuestStatusIcon then
            atlas, desaturate = QuestUtil.GetQuestStatusIcon(questStatus)
        end
    -- Quest status can also represent pickup/turnin/trivial NPC icons when talkToMe is empty.
    elseif questStatus then
        if Quest.IsObjectiveStatus(questStatus) then
            if not ns.c_showQuestObjectives then
                if myPlate.questIcon then myPlate.questIcon:Hide() end
                return
            end
        elseif not ns.c_showQuestNPCs then
            if myPlate.questIcon then myPlate.questIcon:Hide() end
            return
        end
        -- Get atlas for quest status icons
        if QuestUtil and QuestUtil.GetQuestStatusIcon then
            atlas, desaturate = QuestUtil.GetQuestStatusIcon(questStatus)
        end
    else
        if myPlate.questIcon then myPlate.questIcon:Hide() end
        return
    end

    -- Create quest icon on-demand (only when actually showing something)
    EnsureQuestIcon(myPlate)

    -- Override kill objective icon
    if atlas == "questkill" then atlas = "tormentors-boss" end

    -- Apply atlas texture with UseAtlasSize=FALSE. With true, ClassicAPI's SetAtlas
    -- forces the atlas's native (large) size and OVERRIDES our SetSize below on this
    -- client - icons came out huge / inconsistent. With false it only sets the texture
    -- and our fixed base size (below) controls, so all quest icons are uniform.
    if ns.SafeSetAtlas then ns.SafeSetAtlas(myPlate.questIcon, atlas or "questnormal", false) end
    local base = 20  -- 20 * (default scale 0.6) = 12px; scales with questIconScale
    local scale = ns.c_questIconScale * 0.5  -- Match Ascension's internal scaling (* 0.5)
    myPlate.questIcon:SetSize(base * scale, base * scale)
    myPlate.questIcon._origW, myPlate.questIcon._origH = base, base

    -- Apply desaturation if needed
    if myPlate.questIcon.SetDesaturated then
        myPlate.questIcon:SetDesaturated(desaturate or false)
    end

    -- Position based on anchor setting (relative to name text or level text)
    myPlate.questIcon:ClearAllPoints()
    local anchor = ns.c_questIconAnchor
    local xOff, yOff = ns.c_questIconX, ns.c_questIconY
    if anchor == "LEFT" then
        myPlate.questIcon:SetPoint("RIGHT", myPlate.nameText, "LEFT", -2 + xOff, yOff)
    elseif anchor == "RIGHT" then
        -- Anchor after level text if visible and has content, otherwise after name
        local levelText = myPlate.levelText
        if levelText and levelText:IsShown() and levelText:GetText() and levelText:GetText() ~= "" then
            myPlate.questIcon:SetPoint("LEFT", levelText, "RIGHT", 2 + xOff, yOff)
        else
            myPlate.questIcon:SetPoint("LEFT", myPlate.nameText, "RIGHT", 2 + xOff, yOff)
        end
    else  -- TOP
        myPlate.questIcon:SetPoint("BOTTOM", myPlate.nameText, "TOP", xOff, 2 + yOff)
    end

    myPlate.questIcon:Show()
end

-- Update quest icon for lite plates (name-only friendly plates)
-- Called from Core.lua when updating lite plates
local function UpdateLiteQuestIcon(nameplate, unit)
    if not nameplate then return end

    -- Fast path: quest icons completely disabled
    if not ns.c_questIconsEnabled then
        if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
        return
    end

    -- Quest info: native detector first, ClassicAPI fallback (see UpdateQuestIcon).
    local questStatus, questID, talkToMe = ns.GetPlateQuestInfo(unit)
    if not questStatus and C_QuestLog and C_QuestLog.GetUnitQuestInfo then
        local rk = UnitReaction("player", unit)
        if rk and rk > 2 then
            local questUnit = (ns.GetPlateRealUnit and ns.GetPlateRealUnit(unit)) or unit
            questStatus, questID, talkToMe = C_QuestLog.GetUnitQuestInfo(questUnit)
        end
    end

    -- No quest data for this unit
    if Quest.isNilOrEmpty(talkToMe) and not questStatus then
        if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
        return
    end

    -- Validate quest is in log and not complete
    if questID and questID > 0 then
        local questLogIndex = Quest.GetLogIndexByID(questID)
        if questLogIndex == 0 then
            if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
            return
        else
            local isComplete = select(7, Quest.GetLogTitle(questLogIndex))
            if isComplete then
                if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
                return
            end
        end
    end

    local atlas, desaturate

    -- Check for quest NPC (pickup/turnin) first
    if not Quest.isNilOrEmpty(talkToMe) then
        if not ns.c_showQuestNPCs then
            if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
            return
        end
        if QuestUtil and QuestUtil.GetTalkToMeQuestIcon then
            atlas, desaturate = QuestUtil.GetTalkToMeQuestIcon(talkToMe)
        end
        if not atlas and QuestUtil and QuestUtil.GetQuestStatusIcon then
            atlas, desaturate = QuestUtil.GetQuestStatusIcon(questStatus)
        end
    elseif questStatus then
        if Quest.IsObjectiveStatus(questStatus) then
            if not ns.c_showQuestObjectives then
                if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
                return
            end
        elseif not ns.c_showQuestNPCs then
            if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
            return
        end
        if QuestUtil and QuestUtil.GetQuestStatusIcon then
            atlas, desaturate = QuestUtil.GetQuestStatusIcon(questStatus)
        end
    else
        if nameplate.liteQuestIcon then nameplate.liteQuestIcon:Hide() end
        return
    end

    -- Create lite quest icon on demand
    if not nameplate.liteQuestIcon then
        local icon = nameplate:CreateTexture(nil, "OVERLAY")
        PixelUtil.SetSize(icon, 16, 16, 1, 1)
        PixelUtil.SetPoint(icon, "LEFT", nameplate.liteNameText, "RIGHT", 2, 0, 1, 1)
        icon:Hide()
        nameplate.liteQuestIcon = icon
    end

    local icon = nameplate.liteQuestIcon
    local txt = nameplate.liteNameText

    -- Override kill objective icon
    if atlas == "questkill" then atlas = "tormentors-boss" end

    -- Apply atlas texture. Fixed base size - UseAtlasSize/GetSize is unreliable on
    -- this client and gave inconsistent icon sizes (see UpdateQuestIcon).
    if ns.SafeSetAtlas then ns.SafeSetAtlas(icon, atlas or "questnormal", false) end
    local base = 20  -- 20 * (default scale 0.6) = 12px; scales with questIconScale
    local scale = ns.c_questIconScale * 0.5
    icon:SetSize(base * scale, base * scale)

    if icon.SetDesaturated then
        icon:SetDesaturated(desaturate or false)
    end

    -- Position based on anchor (lite plates anchor to liteNameText or liteLevelText)
    icon:ClearAllPoints()
    local anchor = ns.c_questIconAnchor
    if anchor == "LEFT" then
        icon:SetPoint("RIGHT", txt, "LEFT", -2, 0)
    elseif anchor == "RIGHT" then
        -- Anchor after level text if visible, otherwise after name
        local levelText = nameplate.liteLevelText
        if levelText and levelText:IsShown() and levelText:GetText() and levelText:GetText() ~= "" then
            icon:SetPoint("LEFT", levelText, "RIGHT", 2, 0)
        else
            icon:SetPoint("LEFT", txt, "RIGHT", 2, 0)
        end
    else  -- TOP
        icon:SetPoint("BOTTOM", txt, "TOP", 0, 2)
    end

    icon:Show()
end

-- Update all quest icons (called on QUEST_LOG_UPDATE)
local function UpdateAllQuestIcons()
    -- Update full plates
    for unit, myPlate in pairs(ns.unitToPlate) do
        if myPlate and UnitExists(unit) then
            UpdateQuestIcon(unit)
        end
    end

    -- Update lite plates
    if C_NamePlateManager_EnumerateActiveNamePlates then
        for nameplate in C_NamePlateManager_EnumerateActiveNamePlates() do
            if nameplate._isLite and nameplate._unit then
                UpdateLiteQuestIcon(nameplate, nameplate._unit)
            end
        end
    end
end

-- Expose for external use
ns.UpdateQuestIcon = UpdateQuestIcon
ns.UpdateLiteQuestIcon = UpdateLiteQuestIcon
ns.UpdateAllQuestIcons = UpdateAllQuestIcons
-- Expose quest retry state cleanup for nameplate removal
ns.ClearQuestRetryState = function(unit)
    if unit then Quest.retryState[unit] = nil end
end

-- Full update for a plate (non-lite plates only)
function ns:FullPlateUpdate(myPlate, unit)
    if not myPlate or not unit or not UnitExists(unit) then return end

    -- Clear stale quest retry state for this unit (fresh start)
    Quest.retryState[unit] = nil

    -- Clear stale state from previous unit (plate recycling)
    if myPlate.questIcon then myPlate.questIcon:Hide() end
    myPlate._lastAbsorb = nil  -- Force absorb bar refresh for new unit
    myPlate._lastAbsorbHealth = nil
    myPlate._auraColorOverride = nil

    -- Cache GetTime() at start (used for class cache LRU tracking)
    local now = GetTime()

    -- Reset targeting me state for this plate (unit may have changed)
    if myPlate.isTargetingMe then
        myPlate.isTargetingMe = nil
        if myPlate.targetingMeGlow then myPlate.targetingMeGlow:Hide() end
        if myPlate._targetingMeActive then
            myPlate._targetingMeActive = nil
        end
    end

    local name = UnitName(unit) or ""
    local isPlayer = UnitIsPlayer(unit)

    -- Early totem check
    local isTotem = not isPlayer and UnitCreatureType(unit) == "Totem"

    -- Check if Gladdy is handling this totem
    if isTotem then
        local basePlate = C_NamePlate.GetNamePlateForUnit(unit)
        if basePlate and basePlate.gladdyTotemFrame and basePlate.gladdyTotemFrame.active then
            -- Gladdy is handling this totem - it already hid myPlate via ToggleAddon
            return
        end
    end

    if isTotem and ns.c_totemEnabled then
        -- Minimal setup for compact totems
        myPlate.isNameOnly = false
        EnsureFullPlate(myPlate)

        -- Use pre-computed boolean flags (avoid string comparisons)
        local showIcon = ns.c_totemShowIcon
        local showName = ns.c_totemShowName
        local showHP = ns.c_totemShowHP

        -- Get friendly status for coloring
        local isFriendly = UnitIsFriend("player", unit)

        -- Handle healthbar
        if showHP then
            -- Show compact healthbar (25% normal width)
            myPlate.hp:SetSize(ns.c_width * 0.25, ns.c_hpHeight)
            myPlate.hp:Show()
            -- Update health values
            local health = UnitHealth(unit)
            local maxHealth = UnitHealthMax(unit)
            myPlate.hp:SetMinMaxValues(0, maxHealth)
            myPlate.hp:SetValue(health)
            -- Color based on friendly/hostile
            if isFriendly then
                myPlate.hp:SetStatusBarColor(0, 0.8, 0)  -- Green or blue
            else
                myPlate.hp:SetStatusBarColor(0.8, 0, 0)  -- Red
            end
        else
            myPlate.hp:Hide()
        end

        -- Handle name text
        if showName then
            myPlate.nameText:SetText(ns:FormatName(name))
            if isFriendly then
                myPlate.nameText:SetTextColor(ns.c_friendlyNameColor_r, ns.c_friendlyNameColor_g, ns.c_friendlyNameColor_b)
            else
                myPlate.nameText:SetTextColor(ns.c_hostileNameColor_r, ns.c_hostileNameColor_g, ns.c_hostileNameColor_b)
            end
            myPlate.nameText:Show()
        else
            myPlate.nameText:Hide()
        end

        -- Handle totem icon
        if showIcon and myPlate.totemIconFrame then
            local icon = GetTotemIcon(unit) or TOTEM_FALLBACK_ICON
            myPlate.totemIcon:SetTexture(icon)
            myPlate.totemIconFrame:Show()
        elseif myPlate.totemIconFrame then
            myPlate.totemIconFrame:Hide()
        end

        -- Reparent nameText to myPlate for totem layout (may have been inside hp)
        myPlate.nameText:SetParent(myPlate)
        myPlate.nameText:SetDrawLayer("OVERLAY")
        myPlate.nameText:SetJustifyH("CENTER")
        myPlate.nameText:SetWidth(0)
        myPlate.nameText:SetWordWrap(true)

        -- Position elements based on what's visible
        myPlate.nameText:ClearAllPoints()
        if myPlate.totemIconFrame then
            myPlate.totemIconFrame:ClearAllPoints()
        end

        if showIcon and showName and showHP then
            -- Icon + Name + HP: name on top, icon middle, hp bottom
            myPlate.nameText:SetPoint("BOTTOM", myPlate, "BOTTOM", 0, 22)
            myPlate.totemIconFrame:SetPoint("TOP", myPlate.nameText, "BOTTOM", 0, -2)
            myPlate.hp:ClearAllPoints()
            myPlate.hp:SetPoint("TOP", myPlate.totemIconFrame, "BOTTOM", 0, -2)
        elseif showIcon and showHP then
            -- Icon + HP: icon on top, hp below
            myPlate.totemIconFrame:SetPoint("BOTTOM", myPlate, "BOTTOM", 0, 8)
            myPlate.hp:ClearAllPoints()
            myPlate.hp:SetPoint("TOP", myPlate.totemIconFrame, "BOTTOM", 0, -2)
        elseif showIcon and showName then
            -- Icon + Name: name on top, icon below
            myPlate.nameText:SetPoint("BOTTOM", myPlate, "BOTTOM", 0, 18)
            myPlate.totemIconFrame:SetPoint("TOP", myPlate.nameText, "BOTTOM", 0, -4)
        elseif showIcon then
            -- Icon only: centered
            myPlate.totemIconFrame:SetPoint("BOTTOM", myPlate, "BOTTOM", 0, 0)
        elseif showHP and showName then
            -- HP + Name: name on top, hp below
            myPlate.nameText:SetPoint("BOTTOM", myPlate, "BOTTOM", 0, 10)
            myPlate.hp:ClearAllPoints()
            myPlate.hp:SetPoint("TOP", myPlate.nameText, "BOTTOM", 0, -2)
        end

        -- Hide absorb textures (totems don't have shields)
        if myPlate.hp.absorbBar then myPlate.hp.absorbBar:Hide() end
        if myPlate.hp.absorbOverlay then myPlate.hp.absorbOverlay:Hide() end
        if myPlate.hp.overAbsorbGlow then myPlate.hp.overAbsorbGlow:Hide() end
        myPlate._lastAbsorb = nil
        myPlate._lastAbsorbHealth = nil

        -- Hide other elements
        if myPlate.guildText and myPlate.guildText:IsShown() then myPlate.guildText:Hide() end
        if myPlate.raidIcon and myPlate.raidIcon:IsShown() then myPlate.raidIcon:Hide() end
        if myPlate.questIcon and myPlate.questIcon:IsShown() then myPlate.questIcon:Hide() end
        if myPlate.levelText and myPlate.levelText:IsShown() then myPlate.levelText:Hide() end
        if myPlate.cps then
            for i = 1, #myPlate.cps do
                local cp = myPlate.cps[i]
                if cp:IsShown() then cp:Hide() end
            end
        end
        -- Hide aura containers (totems don't show auras)
        if myPlate.debuffContainer and myPlate.debuffContainer:IsShown() then myPlate.debuffContainer:Hide() end
        if myPlate.buffContainer and myPlate.buffContainer:IsShown() then myPlate.buffContainer:Hide() end

        -- Create castbar for totems (some totems like Capacitor Totem cast)
        EnsureCastbar(myPlate)

        -- Reposition castbar for totem layout (anchor to bottom-most visible element)
        if myPlate.castbar then
            myPlate.castbar:ClearAllPoints()
            if showHP then
                -- Anchor below HP bar
                PixelUtil.SetPoint(myPlate.castbar, "TOP", myPlate.hp, "BOTTOM", 0, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            elseif showIcon and myPlate.totemIconFrame then
                -- Anchor below totem icon
                PixelUtil.SetPoint(myPlate.castbar, "TOP", myPlate.totemIconFrame, "BOTTOM", 0, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            elseif showName then
                -- Anchor below name
                PixelUtil.SetPoint(myPlate.castbar, "TOP", myPlate.nameText, "BOTTOM", 0, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            else
                -- Fallback: anchor to plate center
                PixelUtil.SetPoint(myPlate.castbar, "TOP", myPlate, "BOTTOM", 0, 10 + (ns.c_castbarYOffset or 0), 1, 1)
            end
        end

        -- Mark plate as totem so it gets restored to normal on next non-totem use
        myPlate._wasTotem = true
        ns:ApplyPlateScale(myPlate, ns.c_scale)
        return
    end

    -- ==========================================================================
    -- PERSONAL RESOURCE BAR (Player's own nameplate)
    -- ==========================================================================
    local isPersonal = UnitIsUnit(unit, "player")
    myPlate.isPlayer = isPersonal

    if isPersonal then
        -- Early exit if personal bar is disabled (shouldn't happen with CVar sync,
        -- but handles edge cases where nameplate appears before settings loaded)
        if not ns.c_personalEnabled then
            myPlate:Hide()
            personalPlateRef = nil  -- Clear cache
            return
        end

        -- Cache reference to personal plate for efficient event handling
        personalPlateRef = myPlate

        -- Personal bar styling
        myPlate.isNameOnly = false
        EnsureFullPlate(myPlate)
        EnsurePowerBar(myPlate)

        -- Apply personal bar dimensions (cached)
        local personalWidth = ns.c_personalWidth
        local personalHeight = ns.c_personalHeight
        if myPlate._lastPersonalWidth ~= personalWidth then
            PixelUtil.SetWidth(myPlate.hp, personalWidth, 1)
            myPlate._lastPersonalWidth = personalWidth
        end
        if myPlate._lastPersonalHeight ~= personalHeight then
            PixelUtil.SetHeight(myPlate.hp, personalHeight, 1)
            myPlate._lastPersonalHeight = personalHeight
        end
        if myPlate._lastPersonalTexture ~= ns.c_texture then
            myPlate.hp:SetStatusBarTexture(ns.c_texture)
            myPlate._lastPersonalTexture = ns.c_texture
        end

        -- Position health bar with yOffset (cached)
        if myPlate._lastPersonalY ~= ns.c_personalYOffset then
            myPlate.hp:ClearAllPoints()
            myPlate.hp:SetPoint("CENTER", myPlate, "CENTER", 0, ns.c_personalYOffset)
            myPlate._lastPersonalY = ns.c_personalYOffset
        end

        -- Personal health color - use class color if enabled, otherwise user-defined
        if ns.c_personalUseClassColor then
            local _, class = UnitClass("player")
            if class then
                local color = ns.GetClassColor(class)
                if color then
                    myPlate.hp:SetStatusBarColor(color.r, color.g, color.b)
                end
            end
        else
            -- Use user-defined color (with fallback to green)
            local r = ns.c_personalHealthColor_r or 0
            local g = ns.c_personalHealthColor_g or 0.8
            local b = ns.c_personalHealthColor_b or 0
            myPlate.hp:SetStatusBarColor(r, g, b)
        end

        -- Update health bar
        local health = UnitHealth(unit)
        local maxHealth = UnitHealthMax(unit)
        myPlate.hp:SetMinMaxValues(0, maxHealth)
        myPlate.hp:SetValue(health)
        myPlate.hp:Show()

        -- Update absorb and heal prediction (initial state after reload)
        UpdateAbsorb(unit, myPlate)
        UpdateHealPrediction(myPlate)

        -- Health text (uses personal health format)
        if myPlate.healthText then
            local healthFmt = ns.c_personalHealthFormat
            if healthFmt and healthFmt ~= "none" then
                local text = FormatHealthValue(health, maxHealth, healthFmt)
                myPlate.healthText:SetText(text)
                myPlate.healthText:Show()
            else
                myPlate.healthText:Hide()
            end
        end

        -- Update power bar
        if ns.c_personalShowPower then
            -- Cache power bar dimensions
            if myPlate.powerBar._lastWidth ~= personalWidth then
                PixelUtil.SetWidth(myPlate.powerBar, personalWidth, 1)
                myPlate.powerBar._lastWidth = personalWidth
            end
            if myPlate.powerBar._lastHeight ~= ns.c_personalPowerHeight then
                PixelUtil.SetHeight(myPlate.powerBar, ns.c_personalPowerHeight, 1)
                myPlate.powerBar._lastHeight = ns.c_personalPowerHeight
            end
            if myPlate.powerBar._lastTexture ~= ns.c_texture then
                myPlate.powerBar:SetStatusBarTexture(ns.c_texture)
                myPlate.powerBar._lastTexture = ns.c_texture
            end
            UpdatePowerBar(myPlate, unit)
        elseif myPlate.powerBar then
            myPlate.powerBar:Hide()
            if myPlate.additionalPowerBar then myPlate.additionalPowerBar:Hide() end
        end

        -- Hide name for personal bar (player already knows who they are)
        myPlate.nameText:Hide()
        if myPlate.guildText then myPlate.guildText:Hide() end
        if myPlate.levelText then myPlate.levelText:Hide() end

        -- No castbar on personal (player has their own)
        if myPlate.castbar then myPlate.castbar:Hide() end

        -- Position aura containers based on personal settings
        if ns.UpdateAuraPositions then
            ns:UpdateAuraPositions(myPlate)
        end

        -- Update auras (player auras use different filter)
        if ns.UpdateAuras then
            ns:UpdateAuras(myPlate, unit)
        end

        -- Hide elements not needed for personal bar
        if myPlate.raidIcon and myPlate.raidIcon:IsShown() then myPlate.raidIcon:Hide() end
        if myPlate.questIcon and myPlate.questIcon:IsShown() then myPlate.questIcon:Hide() end
        if myPlate.totemIconFrame and myPlate.totemIconFrame:IsShown() then myPlate.totemIconFrame:Hide() end
        if myPlate.cps then
            for i = 1, #myPlate.cps do
                local cp = myPlate.cps[i]
                if cp:IsShown() then cp:Hide() end
            end
        end
        if myPlate.highlight and myPlate.highlight:IsShown() then myPlate.highlight:Hide() end
        if myPlate.targetGlow and myPlate.targetGlow:IsShown() then myPlate.targetGlow:Hide() end
        if myPlate.targetingMeGlow and myPlate.targetingMeGlow:IsShown() then myPlate.targetingMeGlow:Hide() end

        -- Update personal bar health border (uses its own borderStyle setting, not global healthBarBorder)
        ns:UpdatePersonalBorder()

        ns:ApplyPlateScale(myPlate, ns.c_scale)
        if ns.UpdateRunes then ns:UpdateRunes() end
        return
    end

    -- Cache class if player (on the nameplate frame for local access)
    local class
    if isPlayer then
        _, class = UnitClass(unit)
    end

    -- Check friendly status
    local isFriendly = UnitIsFriend("player", unit)
    myPlate.isFriendly = isFriendly

    -- Note: Friendly name-only plates are handled by Core.lua's lite system
    -- They never reach this function. This is only for full plates.

    -- FULL PLATE MODE: Ensure all components exist
    myPlate.isNameOnly = false
    EnsureFullPlate(myPlate)  -- Creates hp, highlight, totemIcon, raidIcon if missing

    -- Hide power bars if this frame was previously used for personal plate (recycling)
    if myPlate.powerBar then
        myPlate.powerBar:Hide()
    end
    if myPlate.additionalPowerBar then
        myPlate.additionalPowerBar:Hide()
    end

    -- Re-anchor aura containers now that hp exists (for ABOVE_HEALTH/BELOW_HEALTH positions)
    if ns.UpdateAuraPositions then
        ns:UpdateAuraPositions(myPlate)
    end

    -- Set name color based on friendly/hostile status
    if isFriendly then
        local useClassColor = ns.c_classColoredName and isPlayer and class
        if useClassColor then
            local classColor = ns.GetClassColor(class)
            if classColor then
                myPlate.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
            else
                myPlate.nameText:SetTextColor(ns.c_friendlyNameColor_r, ns.c_friendlyNameColor_g, ns.c_friendlyNameColor_b)
            end
        else
            myPlate.nameText:SetTextColor(ns.c_friendlyNameColor_r, ns.c_friendlyNameColor_g, ns.c_friendlyNameColor_b)
        end
    else
        -- Hostile/Neutral units: Use class color if enabled, otherwise custom hostile color
        local arenaNum = isPlayer and GetArenaNumber(unit)
        local useClassColor = ns.c_classColoredName and isPlayer and class

        if useClassColor then
            local classColor = ns.GetClassColor(class)
            if classColor then
                myPlate.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
            else
                myPlate.nameText:SetTextColor(ns.c_hostileNameColor_r, ns.c_hostileNameColor_g, ns.c_hostileNameColor_b)
            end
        else
            myPlate.nameText:SetTextColor(ns.c_hostileNameColor_r, ns.c_hostileNameColor_g, ns.c_hostileNameColor_b)
        end

        -- Set name text (arena number if in arena and enabled, otherwise normal name)
        -- Arena numbers always show regardless of name display format
        if arenaNum then
            myPlate.nameText:SetText(arenaNum)
            myPlate.nameText:Show()
        else
            myPlate.nameText:SetText(ns:FormatName(name))
            -- Show/hide name based on format setting (disabled hides name on full plates)
            if ns.c_nameDisplayFormat == "disabled" then
                myPlate.nameText:Hide()
            else
                myPlate.nameText:Show()
            end
        end
    end

    -- Set name text for friendly (no arena number handling needed)
    if isFriendly then
        myPlate.nameText:SetText(ns:FormatName(name))
        -- Show/hide name based on format setting (disabled hides name on full plates)
        if ns.c_nameDisplayFormat == "disabled" then
            myPlate.nameText:Hide()
        else
            myPlate.nameText:Show()
        end
    end

    -- Hide guild text for normal plates
    if myPlate.guildText then
        myPlate.guildText:Hide()
    end

    -- Check if unit is a pet or guardian (totems handled earlier via early return)
    -- UnitIsPet covers hunter/warlock pets, UnitPlayerControlled catches guardians (spirit wolves, treants, etc.)
    local isPet = not isPlayer and (UnitIsPet(unit) or (UnitPlayerControlled(unit) and UnitCreatureType(unit) ~= "Totem"))

    -- Restore healthbar and nameText to normal positions only if previously used for totem display
    -- (totem mode repositions both hp and nameText, so we need to reset both)
    if myPlate._wasTotem then
        myPlate.hp:SetSize(ns.c_width, ns.c_hpHeight)
        myPlate.hp:ClearAllPoints()
        myPlate.hp:SetPoint("CENTER", myPlate, "CENTER", (ns.c_plateXOffset or 0), 15 + (ns.c_plateYOffset or 0))
        -- Restore nameText respecting nameInHealthbar setting
        myPlate.nameText:ClearAllPoints()
        if ns.c_nameInHealthbar then
            myPlate.nameText:SetParent(myPlate.hp)
            myPlate.nameText:SetDrawLayer("OVERLAY", 7)
            PixelUtil.SetPoint(myPlate.nameText, "LEFT", myPlate.hp, "LEFT", 4, ns.c_nameTextYOffset, 1, 1)
            myPlate.nameText:SetJustifyH("LEFT")
            myPlate.nameText:SetWidth(ns.c_width * 0.6)
            myPlate.nameText:SetWordWrap(false)
            myPlate.nameText:SetNonSpaceWrap(false)
        else
            myPlate.nameText:SetParent(myPlate)
            myPlate.nameText:SetDrawLayer("OVERLAY")
            PixelUtil.SetPoint(myPlate.nameText, "BOTTOM", myPlate.hp, "TOP", 0, 2 + ns.c_nameTextYOffset, 1, 1)
            myPlate.nameText:SetJustifyH("CENTER")
            myPlate.nameText:SetWidth(0)
            myPlate.nameText:SetWordWrap(true)
        end
        myPlate._lastNameInHealthbar = ns.c_nameInHealthbar
        myPlate._lastNameTextYOffset = ns.c_nameTextYOffset
        -- Re-anchor castbar to hp (totem fallback may have anchored to myPlate:BOTTOM)
        if myPlate.castbar then
            myPlate.castbar:ClearAllPoints()
            if ns.c_showCastIcon then
                local iconSize = ns.c_castHeight
                PixelUtil.SetPoint(myPlate.castbar, "TOPLEFT", myPlate.hp, "BOTTOMLEFT", iconSize + 2, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            else
                PixelUtil.SetPoint(myPlate.castbar, "TOP", myPlate.hp, "BOTTOM", 0, -2 + (ns.c_castbarYOffset or 0), 1, 1)
            end
        end
        myPlate._wasTotem = false
        -- Invalidate UpdatePlateStyle cache so it re-applies settings
        myPlate._lastWidth = nil
        myPlate._lastHpHeight = nil
        myPlate._lastCastWidth = nil
    end

    -- Enforce nameText parent/anchor every FullPlateUpdate (plate may have been recycled
    -- from personal bar, totem, or another state that moved nameText)
    if myPlate._lastNameInHealthbar ~= ns.c_nameInHealthbar or myPlate._lastNameTextYOffset ~= ns.c_nameTextYOffset then
        myPlate.nameText:ClearAllPoints()
        if ns.c_nameInHealthbar then
            myPlate.nameText:SetParent(myPlate.hp)
            myPlate.nameText:SetDrawLayer("OVERLAY", 7)
            PixelUtil.SetPoint(myPlate.nameText, "LEFT", myPlate.hp, "LEFT", 4, ns.c_nameTextYOffset, 1, 1)
            myPlate.nameText:SetJustifyH("LEFT")
            myPlate.nameText:SetWidth(ns.c_width * 0.6)
            myPlate.nameText:SetWordWrap(false)
            myPlate.nameText:SetNonSpaceWrap(false)
        else
            myPlate.nameText:SetParent(myPlate)
            myPlate.nameText:SetDrawLayer("OVERLAY")
            PixelUtil.SetPoint(myPlate.nameText, "BOTTOM", myPlate.hp, "TOP", 0, 2 + ns.c_nameTextYOffset, 1, 1)
            myPlate.nameText:SetJustifyH("CENTER")
            myPlate.nameText:SetWidth(0)
            myPlate.nameText:SetWordWrap(true)
        end
        myPlate._lastNameInHealthbar = ns.c_nameInHealthbar
        myPlate._lastNameTextYOffset = ns.c_nameTextYOffset
        -- Also fix healthText alignment
        if myPlate.healthText then
            myPlate.healthText:ClearAllPoints()
            if ns.c_nameInHealthbar then
                PixelUtil.SetPoint(myPlate.healthText, "RIGHT", myPlate.hp, "RIGHT", -4, 0, 1, 1)
                myPlate.healthText:SetJustifyH("RIGHT")
            else
                myPlate.healthText:SetAllPoints(myPlate.hp)
                myPlate.healthText:SetJustifyH("CENTER")
            end
        end
        -- Reset level text position cache so it repositions
        if myPlate.levelText then
            myPlate.levelText._lastPositionKey = nil
        end
    end

    myPlate.hp:Show()
    if myPlate.totemIconFrame then
        myPlate.totemIconFrame:Hide()
    end

    local isTarget = UnitIsUnit(unit, "target")
    if isTarget and not isPet then
        ns:CommitTargetOwnership(myPlate, UnitGUID("target"), true)
    elseif ns:IsTargetPlate(myPlate) and not isTarget then
        ns:ClearTargetOwnership(ns.currentTargetGUID, true)
    end

    if isPet then
        ns:ApplyPlateScale(myPlate, ns.c_scale * ns.c_petScale)
    elseif ns:IsTargetPlate(myPlate) then
        ns:ApplyPlateScale(myPlate, ns.c_scale * ns.c_targetScale)
        UpdateTargetGlow(myPlate, true)
    elseif isFriendly then
        ns:ApplyPlateScale(myPlate, ns.c_scale * ns.c_friendlyScale)
        UpdateTargetGlow(myPlate, false)
    else
        ns:ApplyPlateScale(myPlate, ns.c_scale)
        UpdateTargetGlow(myPlate, false)
    end

    -- Health & Color
    UpdateHealth(unit)
    if ns.UpdateNameplateAuraColorOverride then
        ns.UpdateNameplateAuraColorOverride(myPlate, unit)
    end
    UpdateColor(unit)

    -- Raid icon
    UpdateRaidIcon(unit)

    -- Level indicator
    UpdateLevelText(unit)

    -- Classification indicator (elite/rare/boss)
    ns.UpdateClassificationIndicator(unit)

    -- Quest objective icon
    UpdateQuestIcon(unit)

    -- Re-anchor threat text after level/quest visibility is set (for "right_name" mode)
    if ns.c_threatTextAnchor == "right_name" and myPlate.threatText and myPlate.threatText:IsShown() then
        UpdateThreatTextAnchor(myPlate)
    end

    -- Combo points only for target (if enabled, not friendly, and not using personal bar mode)
    if UnitIsUnit(unit, "target") and ns.c_showComboPoints and not ns.c_cpOnPersonalBar and not isFriendly then
        EnsureComboPoints(myPlate)
        local points = GetComboPoints("player", "target")
        if myPlate.cps then
            local numCPs = #myPlate.cps
            for i = 1, numCPs do
                if i <= points then
                    myPlate.cps[i]:Show()
                else
                    myPlate.cps[i]:Hide()
                end
            end
        end
    elseif myPlate.cps then
        local numCPs = #myPlate.cps
        for i = 1, numCPs do
            myPlate.cps[i]:Hide()
        end
    end

    -- Create castbar for all full plates (deferred)
    -- Note: Castbars are not shown for name-only plates (handled by Core.lua lite system)
    EnsureCastbar(myPlate)

    -- Update auras (defined in Auras.lua)
    if ns.UpdateAuras then
        ns:UpdateAuras(myPlate, unit)
    end

    -- Update TurboDebuff (BigDebuffs-style priority aura)
    if ns.UpdateTurboDebuff then
        ns:UpdateTurboDebuff(myPlate, unit)
    end

    -- Update healer icon (CLEU-based detection from HealerDetection.lua)
    if ns.UpdateHealerIcon then
        ns:UpdateHealerIcon(myPlate, unit)
    end

    if ns.c_distanceYOffset and ns.RefreshPlateDistanceYOffset then
        ns:RefreshPlateDistanceYOffset(myPlate)
    end
end

-- Create MINIMAL plate frame (just parent + nameText + guildText)
-- Full components are added on-demand via EnsureFullPlate()
function ns:RefreshNameDisplay()
    for unit, myPlate in pairs(ns.unitToPlate or {}) do
        if myPlate and myPlate.nameText and unit and UnitExists(unit) then
            local name = UnitName(unit) or ""
            local isPlayer = UnitIsPlayer(unit)
            local isFriendly = UnitIsFriend("player", unit)

            local arenaNum = (not isFriendly and isPlayer) and GetArenaNumber(unit)
            if arenaNum then
                myPlate.nameText:SetText(arenaNum)
                myPlate.nameText:Show()
            else
                myPlate.nameText:SetText(ns:FormatName(name))
                if ns.c_nameDisplayFormat == "disabled" then
                    myPlate.nameText:Hide()
                else
                    myPlate.nameText:Show()
                end
            end
        end
    end
end

function ns:CreatePlateFrame(parentFrame, unit)
    local myPlate = CreateFrame("Frame", nil, parentFrame)

    local width, height = C_NamePlateManager_GetNamePlateSize()
    PixelUtil.SetSize(myPlate, width, height, 1, 1)
    PixelUtil.SetPoint(myPlate, "CENTER", parentFrame, "CENTER", 0, 0, 1, 1)
    myPlate:SetFrameLevel(parentFrame:GetFrameLevel() + 1)
    myPlate:EnableMouse(false)  -- Pass through clicks
    parentFrame.myPlate = myPlate

    myPlate.parentPlate = parentFrame
    myPlate.unit = unit
    myPlate.cachedGUID = UnitGUID(unit)

    -- MINIMAL CREATION: Just nameText and guildText
    -- Health bar, castbar, combo points created on-demand

    local nameText = myPlate:CreateFontString(nil, "OVERLAY")
    PixelUtil.SetPoint(nameText, "BOTTOM", myPlate, "BOTTOM", 0, 0, 1, 1)
    nameText:SetTextColor(1, 1, 1)  -- White by default, will be set properly in FullPlateUpdate
    nameText:SetJustifyH("CENTER")
    nameText:SetJustifyV("MIDDLE")
    myPlate.nameText = nameText

    local guildText = myPlate:CreateFontString(nil, "OVERLAY")
    PixelUtil.SetPoint(guildText, "TOP", nameText, "BOTTOM", 0, -1, 1, 1)
    guildText:SetTextColor(0.8, 0.8, 0.8)
    guildText:SetJustifyH("CENTER")
    guildText:Hide()
    myPlate.guildText = guildText

    -- Apply font styles (using cached values)
    ns:SetFontSafe(nameText, ns.c_font, ns.c_fontSize, ns.c_fontOutline)
    ns:SetFontSafe(guildText, ns.c_font, math_max(ns.c_fontSize - 2, 8), ns.c_fontOutline)

    -- Create aura containers (defined in Auras.lua)
    if ns.CreateAuraContainers then
        ns:CreateAuraContainers(myPlate)
    end

    -- Don't use OnShow script - causes taint with SecureNamePlateDriver
    -- Frame visibility is managed by Core.lua's NamePlateUnitAdded/Removed callbacks
end

-- Event frame for unit events
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("UNIT_MAXHEALTH")
eventFrame:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")  -- Threat status changed
eventFrame:RegisterEvent("UNIT_THREAT_LIST_UPDATE")      -- Unit added/removed from threat list
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_COMBO_POINTS")
eventFrame:RegisterEvent("UNIT_COMBO_POINTS")  -- Also register this for compatibility
eventFrame:RegisterEvent("RAID_TARGET_UPDATE")
eventFrame:RegisterEvent("UNIT_FACTION")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
eventFrame:RegisterEvent("ARENA_OPPONENT_UPDATE")  -- Update arena name cache
-- Quest events (verified to exist in Ascension FrameXML)
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("QUEST_QUERY_COMPLETE")
eventFrame:RegisterEvent("QUEST_ACCEPTED")
eventFrame:RegisterEvent("QUEST_POI_UPDATE")
eventFrame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")  -- Nameplate appeared - check quest icon immediately
eventFrame:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")  -- Absorb shield changed
eventFrame:RegisterEvent("UNIT_HEAL_PREDICTION")        -- Incoming heals changed
-- Power events (UNIT_MANA, UNIT_RAGE, UNIT_ENERGY, etc.) registered conditionally below

-- =============================================================================
-- PERSONAL POWER EVENT MANAGEMENT
-- Registers/unregisters power events based on personal bar setting
-- =============================================================================
local personalPowerEventsRegistered = false

UpdatePersonalPowerEvents = function()
    if ns.c_personalEnabled and ns.c_personalShowPower then
        -- Personal bar with power is enabled - register events
        -- NOTE: WoW 3.3.5 uses separate events per power type, not UNIT_POWER_UPDATE
        if not personalPowerEventsRegistered then
            -- Power type-specific events (3.3.5 API)
            eventFrame:RegisterEvent("UNIT_MANA")
            eventFrame:RegisterEvent("UNIT_RAGE")
            eventFrame:RegisterEvent("UNIT_ENERGY")
            eventFrame:RegisterEvent("UNIT_FOCUS")
            eventFrame:RegisterEvent("UNIT_RUNIC_POWER")
            -- Max power events
            eventFrame:RegisterEvent("UNIT_MAXMANA")
            eventFrame:RegisterEvent("UNIT_MAXRAGE")
            eventFrame:RegisterEvent("UNIT_MAXENERGY")
            eventFrame:RegisterEvent("UNIT_MAXFOCUS")
            eventFrame:RegisterEvent("UNIT_MAXRUNIC_POWER")
            -- Power type change event
            eventFrame:RegisterEvent("UNIT_DISPLAYPOWER")
            personalPowerEventsRegistered = true
        end
    else
        -- Personal bar or power disabled - unregister events
        if personalPowerEventsRegistered then
            eventFrame:UnregisterEvent("UNIT_MANA")
            eventFrame:UnregisterEvent("UNIT_RAGE")
            eventFrame:UnregisterEvent("UNIT_ENERGY")
            eventFrame:UnregisterEvent("UNIT_FOCUS")
            eventFrame:UnregisterEvent("UNIT_RUNIC_POWER")
            eventFrame:UnregisterEvent("UNIT_MAXMANA")
            eventFrame:UnregisterEvent("UNIT_MAXRAGE")
            eventFrame:UnregisterEvent("UNIT_MAXENERGY")
            eventFrame:UnregisterEvent("UNIT_MAXFOCUS")
            eventFrame:UnregisterEvent("UNIT_MAXRUNIC_POWER")
            eventFrame:UnregisterEvent("UNIT_DISPLAYPOWER")
            personalPowerEventsRegistered = false
        end
    end
end

-- Export to namespace for UpdateDBCache to call
ns.UpdatePersonalPowerEvents = UpdatePersonalPowerEvents

-- Fast nameplate check (uses cached strsub)
local function IsNameplateUnit(unit)
    -- In compat mode the authoritative tokens are our synthetic "TurboPlateN" (which
    -- never match the "nameplate" prefix), and awesome_wotlk's REAL "nameplateN" tokens
    -- must be IGNORED here. Letting a real-token UNIT_FACTION through made
    -- RefreshPlateForUnit -> OnNamePlateAdded("nameplateN") re-track the frame and CLEAR
    -- the synthetic ns.unitToPlate["TurboPlateN"] entry (Core TrackNameplate old-unit
    -- path), after which UpdateHealth returns early and the health bar FROZE. Real
    -- UNIT_HEALTH is harvested by the WotlkCompat FrostAtom bridge and routed through the
    -- synthetic token instead, so nothing is lost by ignoring real tokens here.
    if ns.IS_WOTLK_COMPAT then return false end
    return unit and strsub(unit, 1, 9) == "nameplate"
end

-- Timer-based throttling with batched updates
-- Health updates faster than threat color
dirtyHealth = {}     -- [unit] = true
dirtyThreat = {}     -- [unit] = true
dirtyAbsorb = {}     -- [unit] = true

-- Pending timer state (consolidated)
local pendingTimers = {
    health = nil,
    threat = nil,
    quest = nil,
    personal = nil,
    absorb = nil,
}

-- Dynamic throttle getters (respects Potato PC mode)
local function GetHealthThrottle() return THROTTLE.health * (ns.c_throttleMultiplier or 1) end
local function GetThreatThrottle() return THROTTLE.threat * (ns.c_throttleMultiplier or 1) end
local function GetQuestThrottle() return THROTTLE.quest * (ns.c_throttleMultiplier or 1) end
local function GetPersonalThrottle() return THROTTLE.personal * (ns.c_throttleMultiplier or 1) end

-- Personal bar pending state (consolidated)
local pendingPersonal = {
    health = false,
    power = false,
}

-- Process all pending personal bar updates in one batch
local function ProcessPersonalUpdates()
    pendingTimers.personal = nil

    if not ns.c_personalEnabled or not personalPlateRef then
        pendingPersonal.health = false
        pendingPersonal.power = false
        return
    end

    local myPlate = personalPlateRef

    -- Update health
    if pendingPersonal.health and myPlate.hp then
        local health = UnitHealth("player")
        local maxHealth = UnitHealthMax("player")
        myPlate.hp:SetMinMaxValues(0, maxHealth)
        myPlate.hp:SetValue(health)
        -- Update health text
        if myPlate.healthText then
            local healthFmt = ns.c_personalHealthFormat
            if healthFmt and healthFmt ~= "none" then
                local text = FormatHealthValue(health, maxHealth, healthFmt)
                myPlate.healthText:SetText(text)
                if text and text ~= "" then
                    myPlate.healthText:Show()
                else
                    myPlate.healthText:Hide()
                end
            else
                myPlate.healthText:Hide()
            end
        end
        -- Update absorb bar (health changes affect absorb display position)
        UpdateAbsorb("player", myPlate)
        -- Update incoming heal prediction
        UpdateHealPrediction(myPlate)
        pendingPersonal.health = false
    end

    -- Update power
    if pendingPersonal.power and myPlate.powerBar then
        UpdatePowerBar(myPlate, "player")
        -- Also update additional power bar (druid mana) if applicable
        if ns.c_personalShowAdditionalPower and myPlate.additionalPowerBar then
            ns.UpdateAdditionalPowerBar(myPlate)
        end
        pendingPersonal.power = false
    end
end

-- Schedule personal bar update (batches multiple updates together)
local function SchedulePersonalUpdate()
    -- Early exit: don't schedule timer if personal bar is disabled
    if not ns.c_personalEnabled or not personalPlateRef then
        return
    end
    if not pendingTimers.personal then
        pendingTimers.personal = C_Timer_After(GetPersonalThrottle(), ProcessPersonalUpdates)
    end
end

local function ProcessDirtyHealth()
    pendingTimers.health = nil
    local unit = next(dirtyHealth)
    while unit do
        local nextUnit = next(dirtyHealth, unit)
        if IsNameplateUnit(unit) and UnitExists(unit) then
            UpdateHealth(unit)
            -- Also update lite plate health (for name-only friendly plates)
            UpdateLiteHealth(unit)
        end
        dirtyHealth[unit] = nil
        unit = nextUnit
    end
end

local function ProcessDirtyThreat()
    pendingTimers.threat = nil
    local unit = next(dirtyThreat)
    while unit do
        local nextUnit = next(dirtyThreat, unit)
        if IsNameplateUnit(unit) and UnitExists(unit) then
            UpdateColor(unit)
        end
        dirtyThreat[unit] = nil
        unit = nextUnit
    end
end

local function ProcessQuestUpdate()
    pendingTimers.quest = nil
    -- Quest log changed: drop the cached objective texts so the native detector
    -- rebuilds them on the next lookup.
    if ns.InvalidateQuestCache then ns.InvalidateQuestCache() end
    -- Only update if quest icons are actually enabled
    if ns.c_questIconsEnabled then
        UpdateAllQuestIcons()
    end
end

local function ScheduleHealthUpdate()
    if not pendingTimers.health then
        pendingTimers.health = C_Timer_After(GetHealthThrottle(), ProcessDirtyHealth)
    end
end

local function ScheduleThreatUpdate()
    if not pendingTimers.threat then
        pendingTimers.threat = C_Timer_After(GetThreatThrottle(), ProcessDirtyThreat)
    end
end

local function ProcessDirtyAbsorb()
    pendingTimers.absorb = nil
    local unit = next(dirtyAbsorb)
    while unit do
        local nextUnit = next(dirtyAbsorb, unit)
        if IsNameplateUnit(unit) and UnitExists(unit) then
            local myPlate = ns.unitToPlate[unit]
            if myPlate and not myPlate.isNameOnly and myPlate.hp then
                UpdateAbsorb(unit, myPlate)
            end
        end
        dirtyAbsorb[unit] = nil
        unit = nextUnit
    end
end

local function ScheduleAbsorbUpdate()
    if not pendingTimers.absorb then
        pendingTimers.absorb = C_Timer_After(GetHealthThrottle(), ProcessDirtyAbsorb)
    end
end

eventFrame:SetScript("OnEvent", function(self, event, unit)
    if event == "UPDATE_MOUSEOVER_UNIT" then
        -- Mouseover changed - show highlight on new mouseover unit (if it's a nameplate)
        if ns.c_mouseoverGlow ~= false and UnitExists("mouseover") then
            local mouseoverPlate = C_NamePlate_GetNamePlateForUnit("mouseover")
            if mouseoverPlate and mouseoverPlate._unit then
                local mouseoverUnit = mouseoverPlate._unit
                if mouseoverPlate._isLite and ns.ShowLiteNameHighlight then
                    ns.ShowLiteNameHighlight(mouseoverPlate, mouseoverUnit)
                else
                    local myPlate = ns.unitToPlate[mouseoverUnit]
                    -- Skip highlight on personal plate (player doesn't need to highlight themselves)
                    if myPlate and myPlate.highlight and not myPlate.isPlayer then
                        ApplyMouseoverGlowColor(myPlate.highlight)
                        myPlate.highlight.unit = mouseoverUnit  -- Track which unit this is
                        myPlate.highlight.elapsed = 0  -- Reset timer
                        myPlate.highlight:Show()  -- OnUpdate will auto-hide when mouse leaves
                    end
                end
            end
        end
    elseif event == "ARENA_OPPONENT_UPDATE" then
        -- Arena opponent changed - update arena name cache and refresh existing nameplates
        if inArena then
            UpdateArenaNames()
            RefreshArenaNumbers()
        end
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_COMBO_POINTS" or event == "UNIT_COMBO_POINTS" then
        UpdateTarget()
        -- Update personal bar combo points (independent of target nameplate)
        UpdatePersonalComboPoints()
        -- Update nameplate alphas based on new target state
        if event == "PLAYER_TARGET_CHANGED" then
            ns.UpdateNameplateAlphas("target")
        end
    elseif event == "RAID_TARGET_UPDATE" then
        -- Update raid icons for all active nameplates
        -- Note: This enumerates all nameplates, but RAID_TARGET_UPDATE is infrequent
        for nameplate in C_NamePlateManager_EnumerateActiveNamePlates() do
            local unit = nameplate._unit
            if unit then
                if nameplate._isLite and nameplate.liteRaidIcon then
                    -- Update lite plate raid icon
                    local raidIndex = GetRaidTargetIndex(unit)
                    if raidIndex then
                        nameplate.liteRaidIcon:SetSize(ns.c_raidMarkerSize, ns.c_raidMarkerSize)
                        nameplate.liteRaidIcon:ClearAllPoints()
                        nameplate.liteRaidIcon:SetPoint("BOTTOM", nameplate.liteNameText, "TOP", 0, 2)
                        SetRaidTargetIconTexture(nameplate.liteRaidIcon, raidIndex)
                        nameplate.liteRaidIcon:Show()
                    else
                        nameplate.liteRaidIcon:Hide()
                    end
                elseif unit and ns.unitToPlate[unit] then
                    -- Update full plate raid icon (use cached lookup)
                    UpdateRaidIcon(unit)
                end
            end
        end
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_QUERY_COMPLETE"
           or event == "QUEST_ACCEPTED" or event == "QUEST_POI_UPDATE"
           or event == "UNIT_QUEST_LOG_CHANGED" then
        -- Quest data changed - throttle updates (quest events can fire rapidly)
        if not pendingTimers.quest then
            pendingTimers.quest = C_Timer_After(GetQuestThrottle(), ProcessQuestUpdate)
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- Nameplate appeared - immediately check quest icon
        -- UpdateQuestIcon has built-in exponential backoff retry if API not ready
        if unit and ns.c_questIconsEnabled then
            UpdateQuestIcon(unit)
        end
    elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        -- Absorb shield changed
        if unit == "player" and ns.c_personalEnabled and personalPlateRef then
            -- Personal bar absorb update
            local myPlate = personalPlateRef
            if myPlate and myPlate.hp then
                UpdateAbsorb(unit, myPlate)
            end
        elseif IsNameplateUnit(unit) then
            dirtyAbsorb[unit] = true
            ScheduleAbsorbUpdate()
        end
    elseif event == "UNIT_HEAL_PREDICTION" then
        -- Incoming heals changed (personal bar only)
        if unit == "player" and ns.c_personalEnabled and personalPlateRef then
            pendingPersonal.health = true
            SchedulePersonalUpdate()
        end
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        -- Handle player health with throttling (same as nameplate units)
        if unit == "player" and ns.c_personalEnabled and personalPlateRef then
            pendingPersonal.health = true
            SchedulePersonalUpdate()
        elseif IsNameplateUnit(unit) then
            -- Throttled updates for other nameplates
            dirtyHealth[unit] = true
            ScheduleHealthUpdate()
        end
    elseif event == "UNIT_MANA" or event == "UNIT_RAGE" or event == "UNIT_ENERGY"
           or event == "UNIT_FOCUS" or event == "UNIT_RUNIC_POWER"
           or event == "UNIT_MAXMANA" or event == "UNIT_MAXRAGE" or event == "UNIT_MAXENERGY"
           or event == "UNIT_MAXFOCUS" or event == "UNIT_MAXRUNIC_POWER"
           or event == "UNIT_DISPLAYPOWER" then
        -- Power update for personal bar (only care about player) - throttled
        if unit == "player" and ns.c_personalEnabled and personalPlateRef then
            pendingPersonal.power = true
            SchedulePersonalUpdate()
        end
    elseif IsNameplateUnit(unit) then
        -- Throttled updates via C_Timer (safe from taint)
        if event == "UNIT_THREAT_SITUATION_UPDATE" or event == "UNIT_THREAT_LIST_UPDATE" then
            -- Skip personal bar - class color doesn't change with threat
            local isPersonalPlate = personalPlateRef and UnitIsUnit(unit, "player")
            if not isPersonalPlate then
                dirtyThreat[unit] = true
                ScheduleThreatUpdate()
            end
        elseif event == "UNIT_FACTION" then
            -- FACTION CHANGE: Unit became hostile/friendly - re-evaluate entire plate type
            -- Handles bosses that start friendly then become hostile
            -- Need to rebuild the plate (lite -> full or vice versa), not just recolor
            if ns.RefreshPlateForUnit then
                ns:RefreshPlateForUnit(unit)
            end
        end
    end
end)
