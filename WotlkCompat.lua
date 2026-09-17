--[[----------------------------------------------------------------------------
    TurboPlates - stock 3.3.5a nameplate engine (name-based data layer)
    (Backported by Jedborg)

    TurboPlates was written for Ascension's modern nameplate engine, where the
    client hands the addon a real per-plate UNIT TOKEN, and it calls
    UnitName(unit)/UnitGUID(unit)/UnitHealth(unit)/UnitIsFriend(unit)/
    UnitClass(unit)... on that token ~110 times. A stock, unpatched 3.3.5a
    client has NO nameplate unit tokens, so those calls return nil/false for any
    plate that isn't your current target.

    This rebuilds the data layer to be NAME/REGION based, the way NotPlater works
    on real 3.3.5a:
      * discover plates by polling WorldFrame:GetChildren() + texture fingerprint
      * read name/level from the plate's font-string regions
      * read health + REACTION (hostile/neutral/friendly/friendlyPlayer/tapped)
        from the plate's health-bar StatusBar value + colour
      * keep name-keyed class/faction caches fed from target/mouseover/group +
        combat log
      * match a plate to a real unit (target/focus/mouseover/partyNtarget/
        raidNtarget) confirmed by name+level+exact-health for things that truly
        need a token (GUID, auras, casts)

    Instead of editing 110 call sites, we WRAP the Unit* family: each plate gets
    a stable synthetic token "TurboPlateN"; Unit* calls with that token answer
    from scraped/cached/matched data, and real tokens pass straight through.

    Must load FIRST in the .toc (before Config.lua). Pure-API shims live in the
    WotlkCompat_*.lua helpers.
------------------------------------------------------------------------------]]

local addonName, ns = ...

local HAVE_NATIVE_ENGINE = (type(C_NamePlate) == "table"
    and type(C_NamePlate.GetNamePlateForUnit) == "function"
    and type(C_NamePlateManager) == "table")

-- awesome_wotlk DLL adds C_NamePlate.GetNamePlateForUnit + native events but NOT
-- C_NamePlateManager, so HAVE_NATIVE_ENGINE stays false and our compat layer runs
-- normally. We detect it here (before we overwrite C_NamePlate) to expose it in
-- diagnostics, fall back to the native resolver inside our GetNamePlateForUnit
-- polyfill, and -- via the token bridge below -- tag each managed frame with its
-- real "nameplateN" token so health reads live UnitHealth instead of the freezable
-- bar scrape (the scrape can stall once the textureless bar stops firing
-- OnValueChanged). PURE FALLBACK: a frame that never receives a real token stays on
-- the scrape path exactly as on a stock (no-awesome_wotlk) server.
local HAVE_AWESOME_WOTLK = (not HAVE_NATIVE_ENGINE
    and type(C_NamePlate) == "table"
    and type(C_NamePlate.GetNamePlateForUnit) == "function")

local WorldFrame   = WorldFrame
local CreateFrame  = CreateFrame
local abs          = math.abs
local wipe         = wipe
local tonumber     = tonumber
local pairs, next  = pairs, next
local bit          = bit
local strupper     = string.upper
local strlower     = string.lower

local _UnitExists        = UnitExists
local _UnitName          = UnitName
local _UnitGUID          = UnitGUID
local _UnitClass         = UnitClass
local _UnitLevel         = UnitLevel
local _UnitHealth        = UnitHealth
local _UnitHealthMax     = UnitHealthMax
local _UnitIsPlayer      = UnitIsPlayer
local _UnitIsUnit        = UnitIsUnit
local _UnitIsFriend      = UnitIsFriend
local _UnitReaction      = UnitReaction
local _UnitCanAttack     = UnitCanAttack
local _UnitCreatureType  = UnitCreatureType
local _UnitIsPet         = UnitIsPet
local _UnitIsDead        = UnitIsDead
local _UnitIsDeadOrGhost = UnitIsDeadOrGhost
local _UnitClassification= UnitClassification
local _UnitIsTapped      = UnitIsTapped
local _UnitIsTappedByPlayer = UnitIsTappedByPlayer
local _UnitAffectingCombat = UnitAffectingCombat
local _GetRaidTargetIndex = GetRaidTargetIndex

-- Some 3.3.5a cores don't expose every Unit* function natively; an API-shim
-- addon (e.g. ClassicAPI) provides them and may load AFTER TurboPlates, so a
-- capture taken at this point can be nil. The wrappers call these originals for
-- real (non-plate) units, so a nil one throws "attempt to call upvalue
-- '_UnitIsPet' (a nil value)" once a plate resolves to a real unit. Re-bind the
-- originals from the live globals once everything has loaded (PLAYER_LOGIN, which
-- fires before any nameplate is queried), and stub anything still missing so the
-- wrappers degrade gracefully instead of erroring.
local function _stubNil() return nil end
local function BindUnitOriginals()
    _UnitExists        = UnitExists        or _UnitExists        or _stubNil
    _UnitName          = UnitName          or _UnitName          or _stubNil
    _UnitGUID          = UnitGUID          or _UnitGUID          or _stubNil
    _UnitClass         = UnitClass         or _UnitClass         or _stubNil
    _UnitLevel         = UnitLevel         or _UnitLevel         or _stubNil
    _UnitHealth        = UnitHealth        or _UnitHealth        or _stubNil
    _UnitHealthMax     = UnitHealthMax     or _UnitHealthMax     or _stubNil
    _UnitIsPlayer      = UnitIsPlayer      or _UnitIsPlayer      or _stubNil
    _UnitIsUnit        = UnitIsUnit        or _UnitIsUnit        or _stubNil
    _UnitIsFriend      = UnitIsFriend      or _UnitIsFriend      or _stubNil
    _UnitReaction      = UnitReaction      or _UnitReaction      or _stubNil
    _UnitCanAttack     = UnitCanAttack     or _UnitCanAttack     or _stubNil
    _UnitCreatureType  = UnitCreatureType  or _UnitCreatureType  or _stubNil
    _UnitIsPet         = UnitIsPet         or _UnitIsPet         or _stubNil
    _UnitIsDead        = UnitIsDead        or _UnitIsDead        or _stubNil
    _UnitIsDeadOrGhost = UnitIsDeadOrGhost or _UnitIsDeadOrGhost or _stubNil
    _UnitClassification= UnitClassification or _UnitClassification or _stubNil
    _UnitIsTapped      = UnitIsTapped      or _UnitIsTapped
    _UnitAffectingCombat = UnitAffectingCombat or _UnitAffectingCombat
    _GetRaidTargetIndex = GetRaidTargetIndex or _GetRaidTargetIndex or _stubNil
end
BindUnitOriginals()

local function DisableNativeNameplateClassColor()
    if not HAVE_NATIVE_ENGINE and not HAVE_AWESOME_WOTLK and type(SetCVar) == "function" then
        pcall(SetCVar, "ShowClassColorInNameplate", "0")
    end
end
DisableNativeNameplateClassColor()

local _origBinder = CreateFrame("Frame")
_origBinder:RegisterEvent("PLAYER_LOGIN")
_origBinder:RegisterEvent("PLAYER_ENTERING_WORLD")
_origBinder:SetScript("OnEvent", function()
    BindUnitOriginals()
    DisableNativeNameplateClassColor()
end)

local NAMEPLATE_COLORS = {
    hostile        = {1,   0,   0},
    neutral        = {1,   1,   0},
    friendly       = {0,   1,   0},
    friendlyPlayer = {0,   0.6, 1},
    tapped         = {0.5, 0.5, 0.5},
}
local function ColorToReactionKey(r, g, b)
    if not r then return nil end

    for key, c in pairs(NAMEPLATE_COLORS) do
        if abs(c[1]-r) <= 0.1 and abs(c[2]-g) <= 0.1 and abs(c[3]-b) <= 0.1 then
            return key
        end
    end

    if abs(r) <= 0.15 and abs(g-0.6) <= 0.25 and abs(b-1) <= 0.15 then
        return "friendlyPlayer"
    end
    if r <= 0.15 and g <= 0.15 and b >= 0.85 then
        return "friendlyPlayer"
    end
    return nil
end

local function IsHeroClassValue(value)
    return type(value) == "string" and strlower(value) == "hero"
end

local function NormalizeClassInfo(localized, token)
    if IsHeroClassValue(localized) or IsHeroClassValue(token) then
        if not localized or localized == "" then localized = "Hero" end
        return localized, "HERO"
    end
    if type(token) == "string" and token ~= "" then
        token = strupper(token)
    end
    return localized, token
end
ns.NormalizeClassInfo = NormalizeClassInfo

function ns.IsClasslessHeroPlayer()
    local classFunc = UnitClass or _UnitClass
    if type(classFunc) ~= "function" then return false end
    local localized, token = classFunc("player")
    _, token = NormalizeClassInfo(localized, token)
    return token == "HERO"
end

function ns.GetClassColor(classToken)
    if type(classToken) ~= "string" or classToken == "" then return nil end
    local _, token = NormalizeClassInfo(nil, classToken)
    local raidColors = _G.RAID_CLASS_COLORS
    local color = raidColors and raidColors[token]
    if color then return color end
    local customColors = _G.CUSTOM_CLASS_COLORS
    return customColors and customColors[token] or nil
end

local classCache          = {}
local classTokenCache     = {}
local isPlayerCache       = {}
local playerRelationCache = {}
local levelCache          = {}
ns.npClassCache          = classCache
ns.npClassTokenCache     = classTokenCache
ns.npPlayerRelationCache = playerRelationCache

local function RelationFromRealUnit(unit)
    if not unit or not _UnitExists(unit) then return nil end
    if _UnitCanAttack("player", unit) then return "enemy" end
    if _UnitIsFriend("player", unit) then return "friendly" end
    local reaction = _UnitReaction(unit, "player") or _UnitReaction("player", unit)
    if reaction then
        if reaction <= 3 then return "enemy" end
        if reaction >= 5 then return "friendly" end
    end
    return nil
end

local function CacheUnitByName(unit)
    if not _UnitExists(unit) then return end
    local name = _UnitName(unit)
    if not name then return end
    -- Normalise 3.3.5a's 1/nil to a real boolean: a cached FALSE must be
    -- distinguishable from "never checked" (nil), matching the CLEU cache, so
    -- readers don't re-derive the answer on every call for non-players.
    local isPlayer = _UnitIsPlayer(unit) and true or false
    isPlayerCache[name] = isPlayer
    if isPlayer then
        local relation = RelationFromRealUnit(unit)
        if relation then playerRelationCache[name] = relation end

        local localized, token = NormalizeClassInfo(_UnitClass(unit))
        if token then
            classCache[name] = localized
            classTokenCache[name] = token
        end
    end
    local lvl = _UnitLevel(unit)
    if lvl and lvl > 0 then levelCache[name] = lvl end
end

if not HAVE_NATIVE_ENGINE then

    local managedPlates = {}
    local tokenToPlate  = {}
    local tokenCounter  = 0

    local NAMEPLATE_TEXTURES = {
        ["Interface\\TargetingFrame\\UI-TargetingFrame-Flash"] = true,
        ["Interface\\Tooltips\\Nameplate-Border"]              = true,
    }

    -- WotLK region order (confirmed against NotPlater):
    --   1 threatGlow  2 healthBorder  3 castBorder  4 castNoStop
    --   5 spellIcon   6 highlightTex  7 nameText    8 levelText
    --   9 bossIcon    10 raidIcon     11 eliteIcon
    -- children: 1 healthBar  2 castBar
    --
    -- IMPORTANT: TurboPlates' HideBlizzardElements REPARENTS the original health
    -- bar + regions onto a hidden frame. On a stock client a region reparented
    -- off the WorldFrame nameplate stops receiving engine updates, which would
    -- freeze anything we scrape from it. So, exactly like NotPlater, we hook the
    -- original bar/text WHILE they're still live (this runs before TurboPlates
    -- reparents them) and cache last-known values ON the plate. All readers use
    -- the cached values, immune to the later reparenting.
    local function HookPlateSources(blizzFrame, nameText, levelText, healthBar)
        if blizzFrame._tpSourcesHooked then return end
        blizzFrame._tpSourcesHooked = true

        -- Cache the value, then BLANK the Blizzard FontString. The engine re-shows
        -- suppressed regions C-side (bypassing Hide / Show hooks), so a plain Hide
        -- let the Blizzard name/level FLASH for ~0.1s on every (re-)show before the
        -- throttled scan re-hid them. But the engine fills these via SetText (the
        -- same call we hook to scrape), so emptying the text in the hook makes them
        -- render nothing no matter when the engine shows them - and re-empties every
        -- time the engine re-fills. The `txt ~= ""` guard stops the SetText("")
        -- recursion; we scrape from the cached _tpName/_tpLevel, never the live text.
        if nameText then
            blizzFrame._tpName = nameText:GetText()
            hooksecurefunc(nameText, "SetText", function(self, txt)
                if txt and txt ~= "" then
                    blizzFrame._tpName = txt
                    self:SetText("")
                end
            end)
            -- The engine may set name/level via SetFormattedText, not SetText (that's
            -- why blanking only SetText left the LEVEL number still flashing). Catch
            -- both: after SetFormattedText, read the result, cache it, and blank.
            if nameText.SetFormattedText then
                hooksecurefunc(nameText, "SetFormattedText", function(self)
                    local cur = self:GetText()
                    if cur and cur ~= "" then
                        blizzFrame._tpName = cur
                        self:SetText("")
                    end
                end)
            end
            nameText:SetText("")
        end
        if levelText then
            blizzFrame._tpLevel = tonumber(levelText:GetText())
            hooksecurefunc(levelText, "SetText", function(self, txt)
                if txt and txt ~= "" then
                    blizzFrame._tpLevel = tonumber(txt)
                    self:SetText("")
                end
            end)
            if levelText.SetFormattedText then
                hooksecurefunc(levelText, "SetFormattedText", function(self)
                    local cur = self:GetText()
                    if cur and cur ~= "" then
                        blizzFrame._tpLevel = tonumber(cur)
                        self:SetText("")
                    end
                end)
            end
            levelText:SetText("")
        end
        if healthBar and healthBar.GetValue then
            local cur = healthBar:GetValue()
            local _, max = healthBar:GetMinMaxValues()
            blizzFrame._tpHP, blizzFrame._tpHPMax = cur, max
            local r, g, b = healthBar:GetStatusBarColor()
            blizzFrame._tpReaction = ColorToReactionKey(r, g, b)
            if healthBar.IsShown then
                blizzFrame._tpReactionSourceReady = healthBar:IsShown() and true or false
            else
                blizzFrame._tpReactionSourceReady = true
            end

            if healthBar.HookScript then
                healthBar:HookScript("OnHide", function()
                    blizzFrame._tpReactionSourceReady = false
                    blizzFrame._tpReaction = nil
                    blizzFrame._tpReactionWait = nil
                end)
                healthBar:HookScript("OnShow", function(bar)
                    local rr, gg, bb = bar:GetStatusBarColor()
                    blizzFrame._tpReaction = ColorToReactionKey(rr, gg, bb)
                    blizzFrame._tpReactionSourceReady = true
                    blizzFrame._tpReactionWait = nil
                    local value = bar:GetValue()
                    local _, mx = bar:GetMinMaxValues()
                    blizzFrame._tpHP, blizzFrame._tpHPMax = value, mx
                end)
            end

            -- The engine updates the nameplate health bar C-side, which fires the
            -- OnValueChanged *script* (not the Lua SetValue method). Hook the
            local prevOVC = healthBar:GetScript("OnValueChanged")
            healthBar:SetScript("OnValueChanged", function(bar, value, ...)
                local _, mx = bar:GetMinMaxValues()
                blizzFrame._tpHP = value
                blizzFrame._tpHPMax = mx
                -- Only overwrite the cached reaction with a RECOGNISED colour - a
                -- damage flash / odd tint can read as no-match and would otherwise
                -- nil a good value, which flickers the friendly verdict and makes the
                -- re-classify pass churn (full<->lite) on every health tick.
                local rk = ColorToReactionKey(bar:GetStatusBarColor())
                if rk then blizzFrame._tpReaction = rk end
                -- Push a health re-render to TurboPlates. Stock 3.3.5a has no
                -- UNIT_HEALTH for our synthetic plate tokens, and UNIT_HEALTH for
                -- real units is keyed wrong in Core (ns.unitToPlate uses the token),
                -- so without this the plate's HP is stuck at its first-render value.
                -- The Blizzard bar's OnValueChanged is the live "health changed"
                -- signal for every plate, matched or not.
                local token = blizzFrame._tpToken
                if token and blizzFrame._tpAnnounced and ns.UpdateNameplateHealth then
                    ns.UpdateNameplateHealth(token)
                    -- Level refresh: the level text is set once at announce and, on a
                    -- recycled plate, may be stale until corrected. Do it ONCE per
                    -- occupant, not on every health tick - UpdateLevelText allocates
                    -- (GetQuestDifficultyColor builds a table), so calling it on every
                    -- damage event churned garbage -> periodic GC freezes in dungeons
                    -- with several mobs under AoE.
                    if not blizzFrame._tpLevelRefreshed and ns.UpdateLevelText then
                        blizzFrame._tpLevelRefreshed = true
                        ns.UpdateLevelText(token)
                    end
                end
                if prevOVC then return prevOVC(bar, value, ...) end
            end)
            -- Colour can also change without a value change (e.g. tapping); catch
            -- it via a method hook as a cheap supplement. Same guard: never nil a
            -- known reaction with an unrecognised colour.
            hooksecurefunc(healthBar, "SetStatusBarColor", function(_, rr, gg, bb)
                local rk = ColorToReactionKey(rr, gg, bb)
                if rk then blizzFrame._tpReaction = rk end
            end)
        end
    end

    local function CapturePlateRefs(blizzFrame)
        -- Capture ONCE per frame, and only the first time - before
        -- HideBlizzPlateRegions reparents the health/border/cast regions off the
        -- plate. The region indices (7=name, 8=level, 10=raidIcon) are only valid
        -- while the original WotLK region order is intact; after reparenting,
        -- GetRegions returns a reduced/reordered set and these indices grab the
        -- WRONG FontString. Pooled frames get RE-acquired (hidden then shown
        -- again), so without this guard a recycled plate would re-capture garbage
        -- refs -> wrong/blank name, inconsistent plates. The captured refs (and
        -- their SetText/OnValueChanged hooks) stay valid across reuse, so reusing
        -- them is correct.
        if blizzFrame._tpRefsCaptured then return end
        local regions = { blizzFrame:GetRegions() }
        local healthBar, castBar = blizzFrame:GetChildren()

        -- Identify name/level FontStrings by TYPE+ORDER, not by absolute region
        -- index. The canonical WotLK order is ...nameText(7), levelText(8)..., but
        -- the number of leading border/glow TEXTURES differs between 3.3.5a cores,
        -- which shifts those indices and makes us grab the wrong FontString: wrong
        -- scraped level, and the real level FontString left unsuppressed -> two
        -- level numbers on the plate. A stock plate has exactly two FontStrings in
        -- creation order: name first, then level. Pick those, with the canonical
        -- index as a fallback.
        local nameText, levelText
        for i = 1, #regions do
            local r = regions[i]
            if r and r.GetObjectType and r:GetObjectType() == "FontString" then
                if not nameText then
                    nameText = r
                elseif not levelText then
                    levelText = r
                    break
                end
            end
        end
        nameText  = nameText  or regions[7]
        levelText = levelText or regions[8]

        blizzFrame._tpNameText  = nameText
        blizzFrame._tpLevelText = levelText
        blizzFrame._tpRaidIcon  = regions[10]
        local nativeHighlight = regions[6]
        if nativeHighlight and nativeHighlight.GetObjectType and nativeHighlight:GetObjectType() == "Texture" then
            blizzFrame._tpNativeHighlight = nativeHighlight
        end
        local bossIcon = regions[9]
        if bossIcon and bossIcon.GetObjectType and bossIcon:GetObjectType() == "Texture" then
            blizzFrame._tpBossIcon = bossIcon
        end
        local eliteIcon = regions[11]
        if eliteIcon and eliteIcon.GetObjectType and eliteIcon:GetObjectType() == "Texture" then
            blizzFrame._tpEliteIcon = eliteIcon
        end
        local threat = regions[1]
        if threat and threat.GetObjectType and threat:GetObjectType() == "Texture" then
            blizzFrame._tpThreat = threat
        end
        blizzFrame._tpHealthBar = healthBar
        blizzFrame._tpCastBar   = castBar
        local castShield = regions[4]
        if castShield and castShield.GetObjectType and castShield:GetObjectType() == "Texture" then
            blizzFrame._tpCastShield = castShield
        end
        -- Spell icon for the cast bar (region 5 in the canonical WotLK order, same
        -- fixed-index approach as the raid icon above). Used to show WHICH spell an
        -- untargeted mob is casting (NotPlater does the same). A wrong index from a
        -- core with a different leading-texture count is harmless: it's suppressed
        -- either way, and the read-time "is this an Interface\Icons path" check
        -- rejects any non-icon texture so we never show garbage.
        local spellIcon = regions[5]
        if spellIcon and spellIcon.GetObjectType and spellIcon:GetObjectType() == "Texture" then
            blizzFrame._tpSpellIcon = spellIcon
        end
        HookPlateSources(blizzFrame, nameText, levelText, healthBar)
        blizzFrame._tpRefsCaptured = true
    end

    -- Readers prefer the cached (hook-fed) values; fall back to a live read in
    -- case the hook hasn't fired yet (first frame).
    local function PlateName(blizzFrame)
        if blizzFrame._tpName ~= nil then return blizzFrame._tpName end
        local t = blizzFrame._tpNameText
        return t and t:GetText() or nil
    end
    local function PlateLevel(blizzFrame)
        if blizzFrame._tpLevel ~= nil then return blizzFrame._tpLevel end
        local t = blizzFrame._tpLevelText
        local s = t and t:GetText()
        return s and tonumber(s) or nil
    end
    local function PlateHealth(blizzFrame)
        -- FrostAtom real "nameplateN" token: read live UnitHealth straight from the
        -- engine. Immune to the textureless-bar OnValueChanged freeze that stalls the
        -- scrape. _UnitExists guards a token left stale by a recycled plate -> falls
        -- through to the scrape below (so stock servers are unaffected).
        local rt = blizzFrame._realToken
        if rt and _UnitExists(rt) then
            return _UnitHealth(rt), _UnitHealthMax(rt)
        end
        if blizzFrame._tpHP ~= nil then
            return blizzFrame._tpHP, blizzFrame._tpHPMax
        end
        local hb = blizzFrame._tpHealthBar
        if not hb or not hb.GetValue then return nil, nil end
        local cur = hb:GetValue()
        local _, max = hb:GetMinMaxValues()
        return cur, max
    end
    local function PlateReaction(blizzFrame)
        if not blizzFrame then return nil end
        local hb = blizzFrame._tpHealthBar
        if hb and hb.GetStatusBarColor and blizzFrame._tpReactionSourceReady ~= false then
            local rk = ColorToReactionKey(hb:GetStatusBarColor())
            if rk then
                blizzFrame._tpReaction = rk
                return rk
            end
        end
        return blizzFrame._tpReaction
    end

    local trackedUnits = {}
    local function RebuildTrackedUnits()
        wipe(trackedUnits)
        trackedUnits[#trackedUnits+1] = "target"
        trackedUnits[#trackedUnits+1] = "focus"
        trackedUnits[#trackedUnits+1] = "mouseover"
        for i = 1, 5 do trackedUnits[#trackedUnits+1] = "arena"..i end
        -- Cache each group member's class/level while we're here (roster events
        -- only, not a hot path): their lite plates class-colour the name without
        -- needing a target/mouseover to fill the name-keyed cache first.
        local nRaid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
        if nRaid > 0 then
            for i = 1, nRaid do
                trackedUnits[#trackedUnits+1] = "raid"..i.."target"
                CacheUnitByName("raid"..i)
            end
        else
            local nParty = (GetNumPartyMembers and GetNumPartyMembers()) or 0
            for i = 1, nParty do
                trackedUnits[#trackedUnits+1] = "party"..i.."target"
                CacheUnitByName("party"..i)
            end
        end
    end
    RebuildTrackedUnits()

    local function PlateMatchesUnit(blizzFrame, unit)
        if not _UnitExists(unit) or _UnitIsDeadOrGhost(unit) then return false end
        local name = PlateName(blizzFrame)
        if not name or name ~= _UnitName(unit) then return false end
        local lvl = PlateLevel(blizzFrame)
        if lvl then
            local ulvl = _UnitLevel(unit)
            if ulvl and ulvl > 0 and lvl ~= ulvl then return false end
        end
        local cur, max = PlateHealth(blizzFrame)
        if cur ~= nil then
            if cur ~= _UnitHealth(unit) then return false end
            if not _UnitIsPlayer(unit) and max and cur == max then return false end
        end
        return true
    end

    -- Lenient "does this match STILL hold?" used only to decide whether to DROP an
    -- already-established match. The strict PlateMatchesUnit (name+level+EXACT
    -- health) is needed to ESTABLISH a unique match among same-named candidates,
    -- but it must NOT gate keeping one: the plate's scraped health (updated C-side
    -- via the bar's OnValueChanged hook) and the real unit's UnitHealth (the
    -- UNIT_HEALTH event) update on different signals and are briefly out of sync
    -- after every hit. Using the strict check to keep the match dropped the
    -- "target" binding for a tick on every damage event -> UnitGUID(token) fell
    -- back to the synthetic GUID -> currentTargetGUID stopped matching -> the
    -- target glow was removed and the plate shrank to non-target scale, then
    -- snapped back next tick. That one-frame flip is the "blink" on ability use.
    -- Keep the match while the unit exists and the name still matches; target/
    -- focus changes explicitly release it so it re-binds via the strict check.
    local function PlateStillMatchesUnit(blizzFrame, unit)
        if not _UnitExists(unit) or _UnitIsDeadOrGhost(unit) then return false end
        local name = PlateName(blizzFrame)
        return name ~= nil and name == _UnitName(unit)
    end

    local matchUnitToPlate = {}
    local function ReleaseMatch(blizzFrame)
        local u = blizzFrame._tpMatchedUnit
        if u and matchUnitToPlate[u] == blizzFrame then matchUnitToPlate[u] = nil end
        blizzFrame._tpMatchedUnit = nil
        blizzFrame._tpMatchedGUID = nil
    end
    local function SetMatch(blizzFrame, unit)
        if blizzFrame._tpMatchedUnit == unit then return end
        ReleaseMatch(blizzFrame)
        blizzFrame._tpMatchedUnit = unit
        blizzFrame._tpMatchedGUID = unit and _UnitGUID(unit) or nil
        if unit then
            matchUnitToPlate[unit] = blizzFrame
            CacheUnitByName(unit)
            -- The plate just gained its real unit. Plates announce on show (before the
            -- match binds), so GUID-dependent state set at announce used the synthetic
            -- guid - re-sync it now: target dimming/glow/scale and the raid marker (a
            -- marker or target set before the plate existed is otherwise missed).
            if blizzFrame._tpAnnounced and ns.OnPlateBound then
                ns.OnPlateBound(blizzFrame, blizzFrame._tpMatchedGUID)
            end
        end
    end

    -- Re-read the live regions/bar for a plate and refresh its cached scrape.
    -- The snapshot taken at acquire + the SetText/OnValueChanged hooks miss two
    -- cases: (1) Blizzard RECYCLES plate frames, and the _tpSourcesHooked guard
    -- skips re-snapshotting, so a reused plate keeps the previous mob's values
    -- until a hooked setter happens to fire again; (2) the engine sets the
    -- health-bar COLOUR C-side by pointer (not via the Lua SetStatusBarColor
    -- method), so the colour hook never fires for a full-health mob that never
    -- triggers OnValueChanged - leaving reaction stuck on the snapshot (hostile
    -- read as neutral -> "yellow instead of red"). The name/level FontStrings are
    -- kept live (not reparented) and the bar value/colour getters read the live
    -- pointer, so re-reading here is current. Guards only overwrite with valid
    -- (non-empty / parseable / known-reaction) reads so a frozen read can never
    -- clobber a good cached value.
    local function RefreshPlateScrape(frame)
        local nt = frame._tpNameText
        if nt then
            local txt = nt:GetText()
            if txt and txt ~= "" then frame._tpName = txt end
            -- Enforce suppression: on a RE-acquired (recycled) plate
            -- HideBlizzPlateRegions is skipped, and the engine can re-show a
            -- suppressed FontString C-side (bypassing our Show hook), so the
            -- Blizzard name/level reappears at its native spot (a second "14"
            -- behind the name). Re-hide here every tick.
            if nt._tpSuppressed and nt:IsShown() then nt:Hide() end
        end
        local lt = frame._tpLevelText
        if lt then
            local n = tonumber(lt:GetText())
            if n then frame._tpLevel = n end
            if lt._tpSuppressed and lt:IsShown() then lt:Hide() end
        end
        local hb = frame._tpHealthBar
        if hb and hb.GetValue then
            local cur = hb:GetValue()
            if cur ~= nil then
                local _, mx = hb:GetMinMaxValues()
                -- Fallback HP push: OnValueChanged is the primary driver, but some
                -- private server implementations batch health updates and don't call
                -- SetValue on every damage event, so the hook can miss hits. When the
                -- scraped value here differs from the cache, the bar is stale; push the
                -- update now. This runs every ~0.1s so the lag is imperceptible.
                local hpChanged = (cur ~= frame._tpHP or mx ~= frame._tpHPMax)
                frame._tpHP, frame._tpHPMax = cur, mx
                if hpChanged then
                    local tok = frame._tpToken
                    if tok and frame._tpAnnounced and ns.UpdateNameplateHealth then
                        ns.UpdateNameplateHealth(tok)
                    end
                end
            end
            -- Drive the plate's VISIBLE health every tick rather than relying only on
            -- the engine's OnValueChanged. On some awesome_wotlk builds the bar STOPS
            -- firing OnValueChanged once its texture is dropped (after the reaction
            -- colour stabilises, just below) and the scrape (GetValue) can freeze with
            -- it -- but a FrostAtom real "nameplateN" token still reports live health.
            -- Prefer the real token, fall back to the scrape, and push a re-render only
            -- when the value actually changed (free when idle, a no-op when
            -- OnValueChanged already applied it). Without this the health bar + value
            -- text froze at the spawn value ("health values not updating").
            local rt = frame._realToken
            local effCur, effMax
            if rt and _UnitExists(rt) then
                effCur, effMax = _UnitHealth(rt), _UnitHealthMax(rt)
            else
                effCur, effMax = frame._tpHP, frame._tpHPMax
            end
            if effCur ~= nil and (frame._tpLastPushHP ~= effCur or frame._tpLastPushMax ~= effMax)
               and frame._tpAnnounced and frame._tpToken and ns.UpdateNameplateHealth then
                frame._tpLastPushHP, frame._tpLastPushMax = effCur, effMax
                ns.UpdateNameplateHealth(frame._tpToken)
            end
            if hb.GetStatusBarColor and frame._tpReactionSourceReady ~= false then
                local key = ColorToReactionKey(hb:GetStatusBarColor())
                if key then
                    frame._tpReaction = key
                end
            end
        end
    end

    -- A plate's scraped name is briefly empty / "Unknown" on the first frame it
    -- appears (and right after login), before the engine fills it in. We must not
    -- announce it to TurboPlates yet: it would render with an "Unknown" name and a
    -- not-yet-sized health bar, and - because the name doesn't match the real unit
    -- yet - it also fails to bind to target/focus (so no auras, casts or raid
    -- marker). Wait until the name is real, then announce (see the driver).
    local function PlateDataReady(blizzFrame)
        local name = PlateName(blizzFrame)
        return name ~= nil and name ~= "" and name ~= UNKNOWN and name ~= "Unknown"
    end

    -- The health-bar COLOUR (reaction) lags the name by a frame or two on fresh /
    -- login plates - the engine writes it C-side and our scrape reads nil until
    -- then. Announcing on name-ready alone made Core classify friendly NPCs as
    -- HOSTILE (full red plate instead of green name-only), and it never re-checked,
    -- so they stayed wrong until /reload. So also wait for a known reaction before
    -- announcing. Fall back after a few ticks so a plate whose colour never maps to
    -- a known reaction key (odd server tint) still appears instead of staying
    -- invisible. Reaction-ready is the friendly/hostile gate; name-ready is the
    -- "don't render Unknown" gate above.
    local REACTION_WAIT_TICKS = 5
    local function PlateAnnounceReady(blizzFrame)
        if not PlateDataReady(blizzFrame) then return false end
        if blizzFrame._tpReactionSourceReady == false then return false end
        if PlateReaction(blizzFrame) ~= nil then return true end
        blizzFrame._tpReactionWait = (blizzFrame._tpReactionWait or 0) + 1
        return blizzFrame._tpReactionWait >= REACTION_WAIT_TICKS
    end

    -- Core decides friendly (lite green name-only) vs hostile (full plate) ONCE at
    -- OnNamePlateAdded and never re-checks. The reaction colour can still be
    -- wrong/unknown at announce (engine writes it C-side a frame or two later, and
    -- the announce fallback may fire), which left friendly NPCs stuck as full red
    -- plates until /reload. We watch the friendly verdict after announce and re-fire
    -- OnNamePlateAdded when it flips, which switches the plate lite<->full.
    local function PlateIsFriendly(blizzFrame)
        local rk = PlateReaction(blizzFrame)
        return rk == "friendly" or rk == "friendlyPlayer"
    end

    -- Scratch buffers reused across passes so each plate is scraped at most once
    -- per UpdateMatches call (instead of once per unmatched tracked unit).
    local candFrame, candName, candLvl, candCur, candMax = {}, {}, {}, {}, {}
    local function UpdateMatches()
        -- Refresh every managed plate from its live regions, then drop matches
        -- that no longer hold (few matched plates -> cheap).
        for frame in pairs(managedPlates) do
            RefreshPlateScrape(frame)
            local u = frame._tpMatchedUnit
            if u then
                local drop = not PlateStillMatchesUnit(frame, u)
                -- awesome_wotlk: the plate carries the real mob's "nameplateN" token, so
                -- verify the binding still points at the SAME mob. PlateStillMatchesUnit
                -- is name-only and would keep a same-named twin bound to the WRONG unit
                -- (two identical mobs that briefly share an HP value can bind the wrong
                -- one in the establish pass) -> a debuff/cast read via UnitAura(matched
                -- unit) then shows on the wrong plate. Exact GUID mismatch -> release so
                -- the GUID pass below re-binds the correct plate this same tick.
                if not drop and HAVE_AWESOME_WOTLK then
                    local rt = frame._realToken
                    if rt and _UnitExists(rt) and _UnitGUID(rt) ~= _UnitGUID(u) then
                        drop = true
                    end
                end
                if drop then
                    local tok = frame._tpToken
                    ReleaseMatch(frame)
                    -- Reset the health bar colour: the plate may have been coloured
                    -- by threat data from the now-gone match (e.g. moused over briefly
                    -- → status=0 → DPS-secure magenta). UpdateColor is not triggered
                    -- automatically on release, so the stale colour would persist
                    -- until the next aura/health/target event hits this plate.
                    if tok and ns.UpdateColor then ns.UpdateColor(tok) end
                end
            end
        end
        -- Correct a premature "target" binding: if the currently bound plate is
        -- dimmed by the engine (alpha < 0.99) while an unmatched same-named/same-
        -- level plate is at full alpha, we grabbed the wrong plate first (real
        -- target was out of nameplate range when the initial binding fired). Release
        -- the stale binding NOW, before candidate collection, so both plates enter
        -- the candidate pool and the existing alpha-disambiguation re-runs cleanly
        -- this cycle and binds the correct one.
        -- PlateStillMatchesUnit (name-only) would otherwise keep the wrong plate
        -- bound indefinitely because the name never changes.
        -- Safe when non-target dimming is OFF: all plates alpha >=0.99 -> outer
        -- condition fails -> no release -> status quo.
        local tf = matchUnitToPlate["target"]
        if tf and _UnitExists("target") and not _UnitIsDeadOrGhost("target")
           and tf.GetAlpha and tf:GetAlpha() < 0.99 then
            local tName = _UnitName("target")
            local tLvl  = _UnitLevel("target")
            for frame in pairs(managedPlates) do
                if frame:IsShown() and not frame._tpMatchedUnit then
                    local fn = PlateName(frame)
                    if fn == tName then
                        local fl = PlateLevel(frame)
                        if not (fl and tLvl and tLvl > 0 and fl ~= tLvl) then
                            if (frame.GetAlpha and frame:GetAlpha() or 1.0) >= 0.99 then
                                local tfTok = tf._tpToken
                                ReleaseMatch(tf)
                                if tfTok and ns.UpdateColor then ns.UpdateColor(tfTok) end
                            end
                            break
                        end
                    end
                end
            end
        end
        -- Collect unmatched, shown plates and scrape name/level/health ONCE each.
        local nCand = 0
        for frame in pairs(managedPlates) do
            if frame:IsShown() and not frame._tpMatchedUnit then
                nCand = nCand + 1
                candFrame[nCand] = frame
                candName[nCand]  = PlateName(frame)
                candLvl[nCand]   = PlateLevel(frame)
                local cur, max = PlateHealth(frame)
                candCur[nCand]   = cur
                candMax[nCand]   = max
            end
        end
        -- Match each unmatched tracked unit against the pre-scraped candidates
        -- using value comparisons only (no further region/bar scraping).
        for i = 1, #trackedUnits do
            local unit = trackedUnits[i]
            if _UnitExists(unit) and not matchUnitToPlate[unit]
               and not _UnitIsDeadOrGhost(unit) then
                -- awesome_wotlk: bind by EXACT real-token GUID first. Each plate carries
                -- the real mob's "nameplateN" token, so this is unambiguous - two
                -- identical mobs (even sharing an HP value, which the name+HP heuristic
                -- below would resolve to an arbitrary one and could glow/aura the wrong
                -- twin) never cross-bind. Falls through to the heuristic when no plate has
                -- a live token yet (bridge lag) or on stock 3.3.5a (no DLL, no _realToken).
                local boundByGUID = false
                if HAVE_AWESOME_WOTLK then
                    local ug = _UnitGUID(unit)
                    for c = 1, nCand do
                        local frame = candFrame[c]
                        if frame and not frame._tpMatchedUnit then
                            local rt = frame._realToken
                            if rt and ug and _UnitExists(rt) and _UnitGUID(rt) == ug then
                                SetMatch(frame, unit)
                                boundByGUID = true
                                break
                            end
                        end
                    end
                end
                if not boundByGUID then
                local uName  = _UnitName(unit)
                local uLvl   = _UnitLevel(unit)
                local uHP    = _UnitHealth(unit)
                local uIsPlr = _UnitIsPlayer(unit)
                -- A full-HP non-player can't be told apart from a same-named
                -- neighbour by health, so we can't bind it by an exact HP match.
                -- But if it's the ONLY same-named full-HP candidate (e.g. a single
                -- mob you just opened on) it's unambiguous, so remember it and bind
                -- after the scan. With two identical full-HP mobs we leave it
                -- unbound rather than risk binding (and glowing) the wrong one -
                -- health resolves it the instant either takes damage. (Raw alpha
                -- can't disambiguate the general case: with non-target dimming off
                -- every plate reads full alpha, so it would pick an arbitrary one -
                -- but see the UNIQUE-alpha "target" exception after the loop.)
                local fullHpFrame, fullHpAmbiguous = nil, false
                for c = 1, nCand do
                    local frame = candFrame[c]
                    if frame and not frame._tpMatchedUnit and candName[c]
                       and candName[c] == uName then
                        local lvl = candLvl[c]
                        if not (lvl and uLvl and uLvl > 0 and lvl ~= uLvl) then
                            local cur, max = candCur[c], candMax[c]
                            if cur ~= nil and cur ~= uHP then
                                -- health mismatch: not this plate
                            elseif cur ~= nil and not uIsPlr and max and cur == max then
                                if fullHpFrame then fullHpAmbiguous = true
                                else fullHpFrame = frame end
                            else
                                -- exact sub-max HP match (or no HP read): unambiguous
                                SetMatch(frame, unit)
                                fullHpFrame = nil
                                break
                            end
                        end
                    end
                end
                if fullHpFrame and not fullHpAmbiguous
                   and not matchUnitToPlate[unit] then
                    SetMatch(fullHpFrame, unit)
                end
                -- Same-named full-HP mobs are ambiguous by health (above), so left
                -- unbound. But for the TARGET the client renders the real target's
                -- plate at full alpha and dims the rest, so disambiguate by alpha
                -- when it's UNIQUE. Gate on uniqueness so non-target dimming OFF
                -- (every plate full alpha) still leaves it unbound rather than
                -- binding an arbitrary one (the reason raw alpha was rejected for the
                -- general full-HP case). Only "target" gets engine target-dimming, so
                -- restrict to it - focus/mouseover alpha is uniform. Binding the
                -- target here is what makes UnitAura (Sap timer), the pinned-GUID
                -- debuff path, target scale and glow all work for a sapped same-named
                -- twin instead of it staying unbound.
                if fullHpAmbiguous and unit == "target"
                   and not matchUnitToPlate[unit] then
                    local alphaFrame, alphaAmbiguous = nil, false
                    for c = 1, nCand do
                        local frame = candFrame[c]
                        if frame and not frame._tpMatchedUnit
                           and candName[c] == uName then
                            local lvl = candLvl[c]
                            if not (lvl and uLvl and uLvl > 0 and lvl ~= uLvl) then
                                local cur, max = candCur[c], candMax[c]
                                if cur ~= nil and not uIsPlr and max and cur == max
                                   and frame.GetAlpha and frame:GetAlpha() >= 0.99 then
                                    if alphaFrame then alphaAmbiguous = true
                                    else alphaFrame = frame end
                                end
                            end
                        end
                    end
                    if alphaFrame and not alphaAmbiguous then
                        SetMatch(alphaFrame, unit)
                    end
                end
                end  -- if not boundByGUID (awesome_wotlk exact-GUID bind ran instead)
            end
        end
        -- Release frame references so hidden plates can be GC'd.
        for c = 1, nCand do candFrame[c] = nil end
    end

    local function ResolveToken(token)
        local frame = tokenToPlate[token]
        if not frame then return nil end
        return frame, frame._tpMatchedUnit
    end

    local function isPlateToken(unit)
        return type(unit) == "string" and tokenToPlate[unit] ~= nil
    end

    function ns.GetNativePlateReaction(unit)
        if not isPlateToken(unit) then return nil end
        return PlateReaction(tokenToPlate[unit])
    end

    function ns.GetNativePlateThreatStatus(unit)
        if not isPlateToken(unit) then return nil end
        local frame = tokenToPlate[unit]
        if not frame then return nil end
        local threat = frame._tpThreat
        if threat and threat.IsShown and threat:IsShown() then
            local r, g, b = threat:GetVertexColor()
            if r and r > 0 then
                if g and g > 0 then
                    if b and b > 0 then return 1 end
                    return 2
                end
                return 3
            end
        end
        return nil
    end

    function ns.UnitExists(unit, ...)
        if isPlateToken(unit) then
            local f = tokenToPlate[unit]
            return f and f:IsShown() and true or false
        end
        return _UnitExists(unit, ...)
    end

    -- Returns the real unit a plate token is bound to (target/focus/... ), or
    -- nil if the plate isn't matched. A real unit token passes straight back.
    -- Lets consumers tell "bound" plates (UnitAura works) from unbound ones.
    function ns.GetPlateRealUnit(unit)
        if isPlateToken(unit) then
            local _, real = ResolveToken(unit)
            return real
        end
        return unit
    end

    -- The plate's REAL FrostAtom "nameplateN" token, when awesome_wotlk is present and
    -- it currently resolves to a live unit; else nil. Unlike GetPlateRealUnit (which
    -- only knows the name+health MATCH binding - target/focus/mouseover), this is the
    -- DLL's exact per-plate unit, available for EVERY visible plate, not just matched
    -- ones. Lets the CLEU-mirror consumers (untargeted casts, player debuffs) resolve
    -- same-named twins by exact GUID instead of guessing by name (the only way to stop
    -- a single mob's cast/debuff bleeding onto identical neighbours). nil on stock
    -- 3.3.5a (no DLL) so those consumers keep their existing name/pin fallbacks.
    function ns.GetPlateRealToken(unit)
        local f = tokenToPlate[unit]
        local rt = f and f._realToken
        if rt and _UnitExists(rt) then return rt end
        return nil
    end

    -- True when `guid` is claimed by a plate OTHER than the one holding `exceptToken`,
    -- so that plate's pinnedGUID == guid is STALE. A plate can keep a pin from a
    -- transient WRONG bind to a same-named mob's unit (two identical mobs both full HP
    -- when you target one -> a twin gets bound + pinned, then the alpha/lenient
    -- correction moves the binding but the pin persists across unbind by design). The
    -- real mob is then shown on another plate - either BOUND to its unit (matched by
    -- exact HP -> authoritative) or also PINNED to it (ambiguous: can't tell twins
    -- apart without a token, so both suppress, which beats bleeding onto the wrong one).
    -- This only VALIDATES the pin at read time; it never clears it (clearing was
    -- reverted - it broke the persist design). Stock-relevant: on awesome_wotlk the
    -- exact GUID bind keeps the pin correct and the _realToken debuff path runs first.
    function ns.IsPinnedGUIDStale(guid, exceptToken)
        if not guid then return false end
        -- (1) bound elsewhere by exact HP = authoritative; any other pin to it is stale.
        for _, frame in pairs(matchUnitToPlate) do
            if frame._tpMatchedGUID == guid and frame._tpToken ~= exceptToken then
                return true
            end
        end
        -- (2) another visible plate is also pinned to it -> ambiguous, both suppress.
        for frame in pairs(managedPlates) do
            if frame._tpToken ~= exceptToken and frame:IsShown() then
                local mp = frame.myPlate
                if mp and mp.pinnedGUID == guid then return true end
            end
        end
        return false
    end

    -- DISPLAY DATA IS SCRAPED, NOT TAKEN FROM THE MATCHED TOKEN.
    -- This follows how NotPlater works on real 3.3.5a: the plate's own regions
    -- (name/level FontStrings, health-bar value + colour) are the source of truth
    -- for everything visible. A matched real unit is only cross-referenced for
    -- token-only extras that can't be scraped (GUID, auras, casts, threat). The
    -- match heuristic (name+level+health) can bind to the WRONG unit - e.g. a
    -- recycled plate briefly stuck on a previous target ("Mogg" on a Sunscale,
    -- wrong colour/level) - so the visible data must never depend on it.
    function ns.UnitName(unit, ...)
        if isPlateToken(unit) then
            return PlateName(tokenToPlate[unit])
        end
        return _UnitName(unit, ...)
    end

    function ns.UnitGUID(unit, ...)
        if isPlateToken(unit) then
            -- token-only: real GUID if matched, else a stable synthetic one
            local f, real = ResolveToken(unit)
            if real then return _UnitGUID(real) end
            return f and f._tpSyntheticGUID or nil
        end
        return _UnitGUID(unit, ...)
    end

    function ns.UnitClass(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            -- class is keyed by the scraped name first (only players need it)
            local name = PlateName(f)
            if name and classTokenCache[name] then
                return classCache[name], classTokenCache[name]
            end
            if real then return NormalizeClassInfo(_UnitClass(real)) end
            -- awesome_wotlk: the plate's real "nameplateN" token answers for
            -- EVERY visible plate - no bind, no click. Without this, class
            -- colours on player plates only appeared after target/mouseover
            -- (whatever filled the name cache). Seed the name caches so the
            -- class survives the plate hiding and reaches by-name consumers.
            local rt = f._realToken
            if rt and _UnitExists(rt) then
                CacheUnitByName(rt)
                return NormalizeClassInfo(_UnitClass(rt))
            end
            return (UNKNOWN or "Unknown"), nil
        end
        return NormalizeClassInfo(_UnitClass(unit, ...))
    end

    function ns.UnitLevel(unit, ...)
        if isPlateToken(unit) then
            return PlateLevel(tokenToPlate[unit]) or -1
        end
        return _UnitLevel(unit, ...)
    end

    function ns.UnitHealth(unit, ...)
        if isPlateToken(unit) then
            return PlateHealth(tokenToPlate[unit]) or 0
        end
        return _UnitHealth(unit, ...)
    end

    function ns.UnitHealthMax(unit, ...)
        if isPlateToken(unit) then
            local _, max = PlateHealth(tokenToPlate[unit])
            return max or 0
        end
        return _UnitHealthMax(unit, ...)
    end

    function ns.UnitIsPlayer(unit, ...)
        if isPlateToken(unit) then
            local f = tokenToPlate[unit]
            local rk = PlateReaction(f)
            if rk == "friendlyPlayer" then return true end
            if rk == "friendly" then return false end
            -- awesome_wotlk: exact per-plate token, same rationale as UnitClass.
            local rt = f._realToken
            if rt and _UnitExists(rt) then
                CacheUnitByName(rt)
                return _UnitIsPlayer(rt) and true or false
            end
            local name = PlateName(f)
            if name and isPlayerCache[name] ~= nil then return isPlayerCache[name] end
            return false
        end
        return _UnitIsPlayer(unit, ...)
    end

    function ns.UnitIsUnit(unitA, unitB, ...)
        local aPlate, bPlate = isPlateToken(unitA), isPlateToken(unitB)
        if aPlate or bPlate then
            if aPlate and bPlate then
                return tokenToPlate[unitA] == tokenToPlate[unitB]
            end
            local plateTok = aPlate and unitA or unitB
            local other    = aPlate and unitB or unitA
            local f = tokenToPlate[plateTok]
            if not f or not _UnitExists(other) then return false end
            -- awesome_wotlk: the plate carries the real mob's "nameplateN" token,
            -- so identity is an exact GUID comparison. The scraped-name+alpha
            -- heuristic below can transiently claim BOTH same-named twins (a
            -- just-shown plate sits at full alpha for a frame before the engine
            -- dims it), which put the target glow on two plates at once.
            local rt = f._realToken
            if rt and _UnitExists(rt) then
                local g = _UnitGUID(rt)
                return (g ~= nil and g == _UnitGUID(other)) or false
            end
            -- Stock: when the match tracker has an opinion it is authoritative
            -- (bindings are established by name+level+EXACT-health, rule 5, with
            -- unique-alpha disambiguation for the target, rule 5d):
            -- (a) this plate is bound to a real unit -> ask the real API about it;
            -- (b) 'other' is bound to a DIFFERENT plate -> this plate can't be it.
            local mu = f._tpMatchedUnit
            if mu and _UnitExists(mu) then
                return _UnitIsUnit(mu, other) and true or false
            end
            local boundFrame = matchUnitToPlate[other]
            if boundFrame and boundFrame ~= f then return false end
            -- Unbound plate vs real unit: compare the SCRAPED plate name to the
            -- unit's name. Names collide (many mobs share one), so for the target
            -- the engine renders the matching plate at full alpha and dims the
            -- rest - disambiguate by opacity like NotPlater's IsTarget, but only
            -- when the full alpha is UNIQUE among same-named plates (the same
            -- gate rule 5d applies when binding). Raw alpha alone marked a
            -- transiently-full-alpha twin as a second target; ambiguity must
            -- suppress (rule: show nothing beats glowing the wrong twin).
            local plateName = PlateName(f)
            if not plateName then return false end
            if plateName ~= _UnitName(other) then return false end
            if other == "target" then
                if f:GetAlpha() < 0.99 then return false end
                for frame in pairs(managedPlates) do
                    if frame ~= f and frame:IsShown()
                       and (frame.GetAlpha and frame:GetAlpha() or 1) >= 0.99
                       and PlateName(frame) == plateName then
                        return false
                    end
                end
                return true
            end
            return true
        end
        return _UnitIsUnit(unitA, unitB, ...)
    end

    function ns.UnitIsFriend(unitA, unitB, ...)
        if isPlateToken(unitB) then
            local f, real = ResolveToken(unitB)
            if real and _UnitExists(real) then
                local relation = RelationFromRealUnit(real)
                local name = PlateName(f)
                if name and relation then playerRelationCache[name] = relation end
                return _UnitIsFriend(unitA, real, ...) and true or false
            end
            local rk = PlateReaction(f)
            return rk == "friendly" or rk == "friendlyPlayer"
        end
        if isPlateToken(unitA) then
            local f, real = ResolveToken(unitA)
            if real and _UnitExists(real) then
                local relation = RelationFromRealUnit(real)
                local name = PlateName(f)
                if name and relation then playerRelationCache[name] = relation end
                return _UnitIsFriend(real, unitB, ...) and true or false
            end
            local rk = PlateReaction(f)
            return rk == "friendly" or rk == "friendlyPlayer"
        end
        return _UnitIsFriend(unitA, unitB, ...)
    end

    function ns.UnitReaction(unitA, unitB, ...)
        local function reactFor(token, other, tokenIsB)
            local f, real = ResolveToken(token)
            if real and _UnitExists(real) then
                local relation = RelationFromRealUnit(real)
                local name = PlateName(f)
                if name and relation then playerRelationCache[name] = relation end
                if tokenIsB then return _UnitReaction(other, real) end
                return _UnitReaction(real, other)
            end
            local rk = PlateReaction(f)
            if rk == "hostile"  then return 2 end
            if rk == "neutral"  then return 4 end
            if rk == "friendly" or rk == "friendlyPlayer" then return 5 end
            if rk == "tapped"   then return 2 end
            return nil
        end
        if isPlateToken(unitB) then return reactFor(unitB, unitA, true) end
        if isPlateToken(unitA) then return reactFor(unitA, unitB, false) end
        return _UnitReaction(unitA, unitB, ...)
    end

    function ns.UnitCanAttack(unitA, unitB, ...)
        if isPlateToken(unitB) then
            local f, real = ResolveToken(unitB)
            if real and _UnitExists(real) then
                local relation = RelationFromRealUnit(real)
                local name = PlateName(f)
                if name and relation then playerRelationCache[name] = relation end
                return _UnitCanAttack(unitA, real, ...) and true or false
            end
            local rk = PlateReaction(f)
            return rk == "hostile" or rk == "neutral" or rk == "tapped"
        end
        if isPlateToken(unitA) then
            local f, real = ResolveToken(unitA)
            if real and _UnitExists(real) then
                local relation = RelationFromRealUnit(real)
                local name = PlateName(f)
                if name and relation then playerRelationCache[name] = relation end
                return _UnitCanAttack(real, unitB, ...) and true or false
            end
            local rk = PlateReaction(f)
            return rk == "hostile" or rk == "neutral" or rk == "tapped"
        end
        return _UnitCanAttack(unitA, unitB, ...)
    end

    function ns.UnitCreatureType(unit, ...)
        if isPlateToken(unit) then
            local _, real = ResolveToken(unit)
            if real then return _UnitCreatureType(real) end
            return nil
        end
        return _UnitCreatureType(unit, ...)
    end

    function ns.UnitIsPet(unit, ...)
        if isPlateToken(unit) then
            local _, real = ResolveToken(unit)
            if real then return _UnitIsPet(real) end
            return false
        end
        return _UnitIsPet(unit, ...)
    end

    function ns.UnitIsDead(unit, ...)
        if isPlateToken(unit) then
            return PlateHealth(tokenToPlate[unit]) == 0
        end
        return _UnitIsDead(unit, ...)
    end

    function ns.UnitClassification(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _UnitClassification(real) end
            if f then
                local boss = f._tpBossIcon
                if boss and boss.IsShown and boss:IsShown() then
                    return "worldboss"
                end
                local state = f._tpEliteIcon
                if state and state.IsShown and state:IsShown() then
                    local texture = state.GetTexture and state:GetTexture()
                    if texture == "Interface\\Tooltips\\EliteNameplateIcon" then
                        return "elite"
                    end
                    return "rare"
                end
            end
            return "normal"
        end
        return _UnitClassification(unit, ...)
    end

    if _UnitIsTapped then
        function ns.UnitIsTapped(unit, ...)
            if isPlateToken(unit) then
                local f, real = ResolveToken(unit)
                if real then return _UnitIsTapped(real) end
                return PlateReaction(f) == "tapped"
            end
            return _UnitIsTapped(unit, ...)
        end
    end

    if _UnitAffectingCombat then
        function ns.UnitAffectingCombat(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitAffectingCombat(real) end
                return false
            end
            return _UnitAffectingCombat(unit, ...)
        end
    end

    local _UnitPlayerControlled = UnitPlayerControlled
    if _UnitPlayerControlled then
        function ns.UnitPlayerControlled(unit, ...)
            if isPlateToken(unit) then
                local f, real = ResolveToken(unit)
                if real then return _UnitPlayerControlled(real) end
                -- friendlyPlayer bar colour implies player-controlled
                return PlateReaction(f) == "friendlyPlayer"
            end
            return _UnitPlayerControlled(unit, ...)
        end
    end

    if _UnitIsTappedByPlayer then
        function ns.UnitIsTappedByPlayer(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitIsTappedByPlayer(real) end
                return false
            end
            return _UnitIsTappedByPlayer(unit, ...)
        end
    end

    -- UnitPower family: real on 3.3.5a and mostly called on "player". Only wrap
    -- the plate-token case (we have no power data for arbitrary plates -> 0).
    local _UnitPower    = UnitPower
    local _UnitPowerMax = UnitPowerMax
    local _UnitPowerType= UnitPowerType
    if _UnitPower then
        function ns.UnitPower(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitPower(real, ...) end
                return 0
            end
            return _UnitPower(unit, ...)
        end
    end
    if _UnitPowerMax then
        function ns.UnitPowerMax(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitPowerMax(real, ...) end
                return 0
            end
            return _UnitPowerMax(unit, ...)
        end
    end
    if _UnitPowerType then
        function ns.UnitPowerType(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitPowerType(real, ...) end
                return 0, "MANA"
            end
            return _UnitPowerType(unit, ...)
        end
    end

    -- UnitCastingInfo / UnitChannelInfo: cast bars need a real unit. For plate
    -- tokens, defer to the matched real unit; otherwise return nil (no cast),
    -- which TurboPlates handles as "not casting".
    local _UnitCastingInfo = UnitCastingInfo
    local _UnitChannelInfo = UnitChannelInfo
    if _UnitCastingInfo then
        function ns.UnitCastingInfo(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitCastingInfo(real) end
                return nil
            end
            return _UnitCastingInfo(unit, ...)
        end
    end
    if _UnitChannelInfo then
        function ns.UnitChannelInfo(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitChannelInfo(real) end
                return nil
            end
            return _UnitChannelInfo(unit, ...)
        end
    end

    -- Auras: a plate token only has auras when matched to a real unit.
    local _UnitBuff   = UnitBuff
    local _UnitDebuff = UnitDebuff
    local _UnitAura   = UnitAura
    if _UnitBuff then
        function ns.UnitBuff(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitBuff(real, ...) end
                return nil
            end
            return _UnitBuff(unit, ...)
        end
    end
    if _UnitDebuff then
        function ns.UnitDebuff(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitDebuff(real, ...) end
                return nil
            end
            return _UnitDebuff(unit, ...)
        end
    end
    if _UnitAura then
        function ns.UnitAura(unit, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if real then return _UnitAura(real, ...) end
                return nil
            end
            return _UnitAura(unit, ...)
        end
    end

    -- Threat: UnitDetailedThreatSituation(unit, mob) exists natively on 3.3.5a,
    -- but the native C function throws "Usage:" if either arg is one of our
    -- synthetic plate tokens. Resolve plate tokens to their matched real unit;
    -- if a token isn't bound to a real unit, return nil (no threat data) rather
    -- than erroring.
    local _UnitDetailedThreatSituation = UnitDetailedThreatSituation
    if _UnitDetailedThreatSituation then
        function ns.UnitDetailedThreatSituation(unit, mob, ...)
            if isPlateToken(unit) then
                local _, real = ResolveToken(unit)
                if not real then return nil end
                unit = real
            end
            if isPlateToken(mob) then
                local _, real = ResolveToken(mob)
                if not real then return nil end
                mob = real
            end
            return _UnitDetailedThreatSituation(unit, mob, ...)
        end
    end

    -- Raid target marker. GetRaidTargetIndex(unit) is called with our synthetic
    -- plate token; the native C function doesn't understand it and returns garbage
    -- (every plate showed a "Star" marker). Resolution order:
    --   1. Matched real unit (target/focus/party member's target) - most reliable.
    --   2. The Blizzard nameplate's native "nameplateN" unit attribute. The stock
    --      3.3.5a client sets GetAttribute("unit") = "nameplate1" etc. on each
    --      plate frame, and GetRaidTargetIndex("nameplateN") works natively - the
    --      engine maps it to the mob C-side. This lets us show raid markers even
    --      for mobs that aren't currently targeted/tracked.
    -- (defined unconditionally; _GetRaidTargetIndex is captured at file scope and
    -- re-bound in BindUnitOriginals, since on some cores it's nil at load.)
    function ns.GetRaidTargetIndex(unit, ...)
        if isPlateToken(unit) then
            local f, real = ResolveToken(unit)
            if real then return _GetRaidTargetIndex(real) end
            if f then
                local blizzUnit = f.GetAttribute and f:GetAttribute("unit")
                if blizzUnit then return _GetRaidTargetIndex(blizzUnit) end
            end
            return nil
        end
        return _GetRaidTargetIndex(unit, ...)
    end

    -- Hide the stock Blizzard nameplate so only TurboPlates' own art shows. On a
    -- real Ascension/retail client DisableBlizzPlate just flips a secure
    -- attribute and the native engine hides the plate; stock 3.3.5a ignores that,
    -- so we hide the regions ourselves.
    --
    -- The name/level FontStrings are what we SCRAPE for unmatched plates, so they
    -- must keep receiving the engine's SetText. Reparenting a region off the
    -- WorldFrame plate stops those updates on this client (and alpha-0 alone is
    -- undone when the engine re-shows the region), so for those two we keep them
    -- parented and force them hidden via Hide() + a Show hook - the text keeps
    --
    -- Runs at AcquirePlate (before TurboPlates ever sees the plate) and sets the
    -- `_turboBlizzHidden` flag TurboPlates checks, so TP's own HideBlizzardElements
    -- (which would reparent the names and break scraping, incl. its in-combat
    -- path) no-ops on every plate.
    local blizzHiddenParent = CreateFrame("Frame")
    blizzHiddenParent:Hide()
    local function SuppressRegion(region)
        if not region then return end
        region:Hide()
        if not region._tpSuppressed then
            region._tpSuppressed = true
            hooksecurefunc(region, "Show", function(self)
                if self._tpSuppressed then self:Hide() end
            end)
        end
    end
    local function HideBlizzPlateRegions(blizzFrame)
        if blizzFrame._turboBlizzHidden then return end
        local elements = { blizzFrame:GetRegions() }
        local healthBar, castBar = blizzFrame:GetChildren()
        if healthBar then elements[#elements + 1] = healthBar end
        if castBar   then elements[#elements + 1] = castBar end
        for i = 1, #elements do
            local child = elements[i]
            if child then
                local isFontString = child.GetObjectType
                    and child:GetObjectType() == "FontString"
                if isFontString then
                    -- ALL FontStrings (name, level, and any extra text region)
                    -- get the Hide()+Show-hook treatment, not just name/level.
                    -- Reparenting a FontString off the plate is undone by the C
                    -- engine on this client - it re-shows the region in place - so
                    -- a reparented level text reappears as a stray floating number
                    -- ("14") next to our own plate. Suppressing keeps them parented
                    -- (so the name/level SetText hooks we scrape from keep firing)
                    -- and reliably hidden.
                    SuppressRegion(child)
                elseif child == healthBar then
                    if child.SetStatusBarTexture then
                        child:SetStatusBarTexture("Interface\\AddOns\\TurboPlates\\Textures\\ReactionSensor.tga")
                    end
                    if child.IsShown then
                        blizzFrame._tpReactionSourceReady = child:IsShown() and true or false
                    else
                        blizzFrame._tpReactionSourceReady = true
                    end
                elseif child == castBar then
                    -- Keep the cast bar PARENTED (do NOT reparent) so the engine
                    -- keeps driving its shown-state and value - that's the live
                    -- "this mob is casting" signal for plates we have no unitID for
                    -- (untargeted casters), which ProcessPlateCasts mirrors onto our
                    -- own castbar. Reparenting would freeze it exactly like the
                    -- health bar. We don't want the Blizzard cast ART though, so drop
                    -- the bar texture and its child regions (bg/border/spark). The
                    -- engine can re-apply the texture per cast, so ProcessPlateCasts
                    -- re-drops it each frame while the bar is shown.
                    if child.SetStatusBarTexture then child:SetStatusBarTexture(nil) end
                    local cregions = { child:GetRegions() }
                    for ci = 1, #cregions do
                        local cr = cregions[ci]
                        if cr then
                            if cr.SetTexture then cr:SetTexture() end
                            if cr.Hide then cr:Hide() end
                        end
                    end
                elseif child == blizzFrame._tpNativeHighlight then
                    child:SetAlpha(0)
                elseif child == blizzFrame._tpCastShield then
                    child:SetAlpha(0)
                elseif child == blizzFrame._tpRaidIcon then
                    child:SetAlpha(0)
                elseif child == blizzFrame._tpBossIcon or child == blizzFrame._tpEliteIcon then
                    child:SetAlpha(0)
                elseif child == blizzFrame._tpThreat then
                    if child.SetTexture then child:SetTexture("") end
                    child:Hide()
                elseif child == blizzFrame._tpSpellIcon then
                    -- Keep the spell icon PARENTED (do NOT reparent/clear) so the
                    -- engine keeps writing the casting spell's texture into it in
                    -- place - that's what lets us show WHICH spell an untargeted mob
                    -- casts. Suppress it visually (Hide + Show-hook) so the Blizzard
                    -- icon never leaks; we only read its texture (ProcessPlateCasts).
                    SuppressRegion(child)
                else
                    child:SetParent(blizzHiddenParent)
                    child:SetAlpha(0)
                    child:Hide()
                    if child.SetTexture then
                        child:SetTexture()
                    elseif child.SetStatusBarTexture then
                        child:SetStatusBarTexture(nil)
                    end
                end
            end
        end
        blizzFrame._turboBlizzHidden = true
    end

    -- Forward declaration: AcquirePlate's Show hook (below) captures this name.
    -- Without it the closure compiled a GLOBAL lookup (the local didn't exist yet
    -- at that point in the file), so the hook threw "attempt to call global
    -- 'IsNamePlate' (a nil value)" whenever a released plate was re-shown via a
    -- Lua-side Show() instead of the usual C-side path.
    local IsNamePlate

    local function FireAdded(token, blizzFrame)
        if EventRegistry and EventRegistry.TriggerEvent then
            EventRegistry:TriggerEvent("NamePlateManager.UnitAdded", token, blizzFrame)
        end
    end
    local function FireRemoved(token, blizzFrame)
        if EventRegistry and EventRegistry.TriggerEvent then
            EventRegistry:TriggerEvent("NamePlateManager.UnitRemoved", token, blizzFrame)
        end
    end

    local function AcquirePlate(blizzFrame)
        -- Reuse one stable token per pooled frame. Pooled frames are hidden and
        -- re-shown constantly, and minting a NEW token on every re-show churned
        -- Core's per-token state (ns.unitToPlate / currentTargetPlate), which made
        -- the target scale and other per-plate data flicker. Assign once; keep the
        -- token + tokenToPlate mapping across hide/show.
        local token = blizzFrame._tpToken
        if not token then
            tokenCounter = tokenCounter + 1
            token = "TurboPlate" .. tokenCounter
            blizzFrame._tpToken         = token
            blizzFrame._tpSyntheticGUID =
                string.format("0xF130%07X%05X", tokenCounter % 0xFFFFFFF, tokenCounter % 0xFFFFF)
            tokenToPlate[token] = blizzFrame
        end

        managedPlates[blizzFrame] = true
        blizzFrame._unit            = token
        -- New occupant: allow exactly one level-text refresh on its first health
        -- tick (see the OnValueChanged hook), in case the level was stale at announce.
        blizzFrame._tpLevelRefreshed = nil
        -- Drop the previous occupant's aura colour override. Core clears pinnedGUID/
        -- Name/Level on OnNamePlateRemoved; we must NOT clear them here because a
        -- camera-pan hide/re-show goes through AcquirePlate WITHOUT a remove, and
        -- the same mob is back. Clearing the pin would lose the GUID, causing
        -- MergeTrackedDebuffs to fall back to name-only lookup and either show
        -- wrong debuffs (bleed) or no debuffs at all (sap disappears). The bleed
        -- guard in MergeTrackedDebuffs (CountPlatesWithName > 1) already prevents
        -- same-name cross-plate bleed. _auraColorOverride is match-derived and
        -- must be reset so a new match doesn't inherit a stale colour.
        local mp = blizzFrame.myPlate
        if mp then
            mp._auraColorOverride = nil
        end
        -- Pooled plates are hidden/re-shown without a WorldFrame child-count change,
        -- so a re-show is otherwise only noticed on the throttled scan (~0.1s) - long
        -- enough that the Blizzard name/level/bar flash at the Blizzard position
        -- before we re-hide and render our own. The FRAME's Show IS hookable (unlike
        -- the C-side region shows), so react to it immediately: re-acquire a released
        -- plate (suppress + announce now) or just re-hide a still-managed one.
        if not blizzFrame._tpShowHooked then
            blizzFrame._tpShowHooked = true
            hooksecurefunc(blizzFrame, "Show", function(self)
                if managedPlates[self] then
                    RefreshPlateScrape(self)
                elseif IsNamePlate(self) then
                    AcquirePlate(self)
                end
            end)
        end

        CapturePlateRefs(blizzFrame)
        HideBlizzPlateRegions(blizzFrame)

        -- Pull fresh data from the live FontStrings/bar NOW, before PlateDataReady.
        -- By the time our OnUpdate fires, the engine has already written the new
        -- mob's name/level/health into the regions C-side. Without this call,
        -- recycled plates (where _tpSourcesHooked skips the HookPlateSources
        -- re-snapshot) keep _tpName/_tpLevel from the PREVIOUS mob and announce
        -- with wrong data.
        RefreshPlateScrape(blizzFrame)

        for i = 1, #trackedUnits do
            local unit = trackedUnits[i]
            if _UnitExists(unit) and not matchUnitToPlate[unit]
               and PlateMatchesUnit(blizzFrame, unit) then
                SetMatch(blizzFrame, unit)
                break
            end
        end

        -- Only announce once the scraped name is ready. If not (first frame /
        -- login), the driver re-checks each tick and announces when it becomes
        -- available, so Core never renders a half-initialized "Unknown" plate.
        if PlateAnnounceReady(blizzFrame) then
            blizzFrame._tpAnnounced = true
            blizzFrame._tpAnnouncedFriendly = PlateIsFriendly(blizzFrame)
            blizzFrame._tpAnnouncedReaction = PlateReaction(blizzFrame)
            FireAdded(token, blizzFrame)
        else
            blizzFrame._tpAnnounced = false
        end
    end

    local function ReleasePlate(blizzFrame)
        local token = blizzFrame._tpToken
        ReleaseMatch(blizzFrame)
        managedPlates[blizzFrame] = nil
        if blizzFrame._tpAnnounced then
            FireRemoved(token, blizzFrame)
            blizzFrame._tpAnnounced = false
        end
        blizzFrame._tpReaction = nil
        blizzFrame._tpReactionSourceReady = false
        blizzFrame._tpReactionWait = nil
        blizzFrame._tpAnnouncedReaction = nil
        blizzFrame._unit = nil
        -- Keep _tpToken + tokenToPlate[token] so the SAME token is reused when this
        -- pooled frame is shown again (see AcquirePlate). Visibility is gated by
        -- IsShown() / managedPlates elsewhere, so a kept-but-hidden token is inert.
    end

    function IsNamePlate(frame)  -- assigns the forward-declared local above
        if managedPlates[frame] then return true end
        -- Once a pooled WorldFrame child has been confirmed as a nameplate it
        -- stays one for the session (the client recycles the same frames). We must
        -- remember it: HideBlizzPlateRegions reparents the border TEXTURE off the
        -- plate, destroying the fingerprint below, so a plate that's been hidden
        -- once would never be re-identified after the engine re-shows it - it would
        -- vanish for good when panned off-screen and back.
        if frame._tpIsNamePlate then return true end
        if frame:GetName() then return false end
        local region = frame:GetRegions()
        if not region or region:GetObjectType() ~= "Texture" then return false end
        local tex = region:GetTexture()
        if tex and NAMEPLATE_TEXTURES[tex] then
            frame._tpIsNamePlate = true
            return true
        end
        return false
    end

    local visible = {}
    local knownPlates = {}   -- every WorldFrame child ever confirmed a nameplate (the pool)
    -- Untargeted-cast tracking, driven ENTIRELY from the combat log. Stock 3.3.5a
    -- (no awesome_wotlk) does NOT engine-drive the Blizzard nameplate cast bar, so
    -- there was nothing to scrape and only target/focus/mouseover casts (the event
    -- path) ever showed. SPELL_CAST_START fires for EVERY caster in range with no
    -- unitID, and GetSpellInfo gives the icon AND the base cast time - enough to
    -- render a self-animating bar with no unit and no Blizzard bar. Cached by GUID
    -- ONLY: a cast is rendered on a plate solely when that plate is bound to the
    -- caster's GUID -- pinned (stock) or a real nameplateN token (awesome_wotlk).
    -- The former by-name index was removed: it bled an off-screen same-named
    -- caster's cast onto a visible non-caster (see ProcessPlateCasts stock branch).
    -- entry = { name, icon, start, duration, guid[, channel, victim] }
    -- channel=true entries come from SPELL_CAST_SUCCESS + the channeled-spell
    -- registry (WotlkCompat_Channels.lua) and render DRAINING (1 -> 0).
    local castByGUID = {}      -- [caster GUID] = entry
    -- Memoised "is this texture path a spell icon?" verdicts. The check runs every
    -- frame while a cast is mirrored, and tex:lower() re-built and re-hashed the
    -- lowered path each time; distinct icon paths per session are few, so this
    -- stays small. [texture path] = true/false.
    local iconPathVerdict = {}
    local lastCastSweep = 0    -- throttle for the stale-entry sweep below
    local CAST_GRACE = 0.5     -- keep the bar this long past the estimated cast time
                               -- (haste makes the real cast shorter; the end event
                               -- normally clears it first) before treating a missed
                               -- end event as stale.
    -- Fully remove a cast entry from the GUID index.
    local function ClearCastEntry(entry)
        if not entry then return end
        if entry.guid and castByGUID[entry.guid] == entry then castByGUID[entry.guid] = nil end
    end
    -- Reused between scans: a fresh { WorldFrame:GetChildren() } table on every
    -- scan tick (throttled 0.1s rescan + the child-count fast path) churned
    -- enough garbage to cause periodic GC hitches - the same pattern fixed in
    -- Gladdy's TotemPlates scanner. Varargs + select fill a persistent buffer
    -- and never touch the Lua heap.
    local worldChildren = {}
    local function CollectWorldChildren(...)
        local n = select("#", ...)
        for i = 1, n do
            worldChildren[i] = select(i, ...)
        end
        return n
    end
    local function ScanWorldFrame()
        wipe(visible)
        wipe(worldChildren)
        local numChildren = CollectWorldChildren(WorldFrame:GetChildren())
        for i = 1, numChildren do
            local frame = worldChildren[i]
            if IsNamePlate(frame) then
                knownPlates[frame] = true   -- pooled frames are reused, never destroyed
                visible[frame] = true
                if not managedPlates[frame] then
                    AcquirePlate(frame)
                end
            end
        end
        for frame in pairs(managedPlates) do
            if not visible[frame] or not frame:IsShown() then
                ReleasePlate(frame)
            end
        end
    end

    -- Per-frame, cheap (iterates the small persistent pool set, no allocation): act
    -- on a pooled plate's show/hide the instant it happens. The engine shows/hides
    -- pooled plates C-SIDE (bypassing Lua Show/Hide hooks), so otherwise a transition
    -- was only caught on the 0.1s scan - long enough for a stale/partial plate (e.g.
    -- just the level number, or the previous occupant's art) to flash before the real
    -- one renders, and for our own plate to linger after the mob is gone.
    local function ProcessPlateVisibility()
        for frame in pairs(knownPlates) do
            if frame:IsShown() then
                if not managedPlates[frame] then AcquirePlate(frame) end
            elseif managedPlates[frame] then
                ReleasePlate(frame)
            end
        end
    end

    -- Render untargeted casters' cast bars from the combat-log cache (built above).
    -- This is the ONLY source on stock 3.3.5a: UNIT_SPELLCAST_* / UnitCastingInfo
    -- answer only for target/focus/mouseover/party/raid (the event-driven path in
    -- Castbars.lua handles those), and the engine doesn't drive the Blizzard nameplate
    -- cast bar to scrape. We self-animate from start + base cast time; the real end
    -- event (or the grace cap) hides it. Identity (no bleed onto same-named twins on
    -- EITHER platform): awesome_wotlk -> the plate's real "nameplateN" GUID, exact;
    -- stock -> pinned GUID (caster was targeted/moused-over), else the caster name but
    -- ONLY when it's the unique visible plate of that name, else nothing. Runs every
    -- frame.
    local function ProcessPlateCasts()
        if not (ns.ScrapeCastStart and ns.ScrapeCastUpdate and ns.ScrapeCastStop) then return end
        local now = GetTime()
        -- Periodically drop cast entries whose end event we never saw (caster cast
        -- out of nameplate range, then died/despawned): the per-plate stale check
        -- below only clears casters that currently have a visible plate.
        if now - lastCastSweep > 2 then
            lastCastSweep = now
            for _, e in pairs(castByGUID) do
                if now - e.start > e.duration + CAST_GRACE then ClearCastEntry(e) end
            end
        end
        for frame in pairs(knownPlates) do
            local token = frame._tpToken
            local active = frame:IsShown() and managedPlates[frame] and frame._tpAnnounced and token
            -- Defensive: if a core DOES drive the Blizzard cast bar, keep its texture
            -- dropped so no Blizzard cast art leaks next to our plate.
            local cb = frame._tpCastBar
            if cb and cb.IsShown and cb:IsShown() and cb.SetStatusBarTexture then
                cb:SetStatusBarTexture(nil)
            end
            -- Same for the Blizzard cast SPELL ICON (region 5). On awesome_wotlk the
            -- engine DRIVES the nameplate cast bar and re-shows this icon C-side on every
            -- cast, bypassing the one-time Show-hook that HideBlizzPlateRegions installed
            -- (rule 8) - so it leaked as a stray icon at the un-offset mob-head position
            -- (visible once the plate has an X/Y offset). Re-hide it every frame, like we
            -- re-drop the bar texture; its texture stays readable via GetTexture for the
            -- icon fallback below. No-op on stock (the engine never drives the cast bar
            -- there, so the icon is never shown) and harmless to our own castbar.icon
            -- (a separate frame in Castbars.lua).
            local si = frame._tpSpellIcon
            if si and si.IsShown and si:IsShown() and si.Hide then si:Hide() end
            local info
            -- The match tracker binds plates to target/focus/mouseover AND to every
            -- party/raid member's target (partyNtarget/raidNtarget, see trackedUnits).
            -- The event-driven castbar path (UNIT_SPELLCAST_*) only fires for units the
            -- client tracks as EVENT units - and on 3.3.5a that is target/focus/player/
            -- pet/party/raid, NOT "mouseover" and NOT partyNtarget/raidNtarget (this is
            -- why Quartz's Mouseover module POLLS UnitCastingInfo instead of using
            -- events). So a plate bound to any of those non-event units used to get a
            -- castbar from NEITHER path: this CLEU mirror skipped every matched plate,
            -- yet no UNIT_SPELLCAST event ever fires for them. First seen for
            -- partyNtarget ("no cast on a mob I don't target/mouseover", worst in
            -- dungeons/raids); the SAME dead zone applied to a plate bound to
            -- "mouseover" - a cast STARTED while the cursor stayed on the mob never
            -- showed, and an in-progress cast picked up at bind (CheckExistingCast)
            -- never saw its end events, so an interrupted cast filled to completion.
            -- Drive the mirror for all matched plates EXCEPT the ones the event path
            -- truly owns (target/focus) - driving those here would fight the event
            -- path over the same bar. The mirror resolves by UnitGUID(matchedUnit)
            -- below (exact on awesome_wotlk, as-exact-as-the-bind on stock) and the
            -- CLEU end events clear it, so interrupts tear the bar down correctly.
            local mu = frame._tpMatchedUnit
            local eventOwnsCast = (mu == "target" or mu == "focus")
            if active and not eventOwnsCast then
                local mp = frame.myPlate
                local pname = PlateName(frame)
                local rt = frame._realToken
                if mu then
                    -- Matched to a mouseover/partyNtarget/raidNtarget REAL unit: resolve
                    -- the cast by that mob's exact GUID. Base WoW (UnitGUID + CLEU
                    -- castByGUID), no DLL needed, so it works on stock AND awesome_wotlk -
                    -- exact on awesome_wotlk (the bind is GUID-exact), and as-exact-as-the-
                    -- bind on stock, matching how debuffs/auras already read
                    -- UnitAura(matchedUnit) on a bound plate. Fixes "castbar doesn't show
                    -- on a mob I haven't targeted" in groups AND on a mob the cursor is
                    -- resting on (no UNIT_SPELLCAST event ever fires for "mouseover").
                    local g = _UnitGUID(mu)
                    info = g and castByGUID[g] or nil
                elseif rt and _UnitExists(rt) then
                    -- awesome_wotlk: this plate carries a real FrostAtom "nameplateN" token
                    -- that resolves to the EXACT mob it shows, so match the cast by that
                    -- mob's real GUID. This is what lets awesome_wotlk show untargeted casts
                    -- on ANY plate without bleeding onto same-named neighbours (one Murkgill
                    -- Oracle casting Lightning Bolt, three standing by; two Sifreldar Storm
                    -- Maidens, one casting): the DLL token disambiguates twins exactly.
                    -- nil castByGUID[rg] => this mob isn't casting => no bar.
                    local rg = _UnitGUID(rt)
                    info = rg and castByGUID[rg] or nil
                else
                    -- Stock 3.3.5a (no DLL): there is NO plate->GUID for an unbound mob,
                    -- so the ONLY reliable way to know THIS plate is the caster is its
                    -- PINNED GUID (set when you targeted/focused/moused-over it at least
                    -- once). The former name fallback (show on the unique VISIBLE plate of
                    -- the caster's name) was fundamentally ambiguous and bled a bar onto
                    -- innocent mobs: an OFF-SCREEN same-named caster (in combat-log range
                    -- but with no nameplate) cast Frostbolt, and the bar rendered on a
                    -- visible same-named mob that wasn't casting ("mobs look like they're
                    -- casting when they aren't"). Nothing on the stock client can tell the
                    -- two apart, so we show NOTHING unless the plate is pinned; mousing
                    -- over the real caster once pins it and shows the cast exactly.
                    -- (awesome_wotlk resolves this exactly via the real nameplateN GUID in
                    -- the branch above and is unaffected by this.)
                    local pg = mp and mp.pinnedGUID
                    if pg and castByGUID[pg] and mp.pinnedName == pname then
                        -- Validate the pin like the debuff path (PinSignatureValid in
                        -- Auras.lua, commit 4eca096): a plate can keep a pin from a
                        -- transient WRONG bind to a same-named twin's unit (both full
                        -- HP -> the engine pins a twin, the correction moves the bind
                        -- but the pin persists by design). Without this the twin drew
                        -- the caster's bar via its stale pin - the cast-side sibling
                        -- of the Polymorph icon bleed. Same level check, and reject a
                        -- pin whose GUID another plate now claims (bound elsewhere by
                        -- exact HP, or also pinned -> ambiguous, both suppress).
                        local pl, cl = mp.pinnedLevel, PlateLevel(frame)
                        local levelOK = not (pl and pl > 0 and cl and cl > 0 and cl ~= pl)
                        if levelOK and not ns.IsPinnedGUIDStale(pg, token) then
                            info = castByGUID[pg]
                        end
                    end
                end
                -- Past the estimated cast time with no end event: treat as stale and
                -- drop it (bounds memory for a cast whose end we never saw).
                if info and (now - info.start) > info.duration + CAST_GRACE then
                    ClearCastEntry(info)
                    info = nil
                end
            end
            if info then
                -- Icon from the spell (combat log); fall back to the scraped Blizzard
                -- spell-icon region only if GetSpellInfo gave us none.
                local icon = info.icon
                if not icon then
                    local si = frame._tpSpellIcon
                    if si and si.GetTexture then
                        local tex = si:GetTexture()
                        if type(tex) == "string" then
                            local ok = iconPathVerdict[tex]
                            if ok == nil then
                                ok = tex:lower():find("icons", 1, true) ~= nil
                                iconPathVerdict[tex] = ok
                            end
                            if ok then icon = tex end
                        end
                    end
                end
                local fill = (now - info.start) / info.duration
                -- Channels drain from full to empty, like the event path's
                -- channeling branch (CastbarOnUpdate decrements for channels).
                if info.channel then fill = 1 - fill end
                if fill < 0 then fill = 0 elseif fill > 1 then fill = 1 end
                local shield = frame._tpCastShield
                local notInterruptible = shield and shield.IsShown and shield:IsShown() and true or false
                if not frame._tpScraping then
                    frame._tpScraping = true
                    ns:ScrapeCastStart(token, notInterruptible, icon, info.name)
                end
                ns:ScrapeCastUpdate(token, fill, notInterruptible, icon, info.name)
            elseif frame._tpScraping then
                -- Cast ended, plate hidden/recycled, or it gained a real unit (event
                -- path takes over) - tear our mirror down. ScrapeCastStop no-ops if
                -- the event path has already claimed the castbar.
                frame._tpScraping = nil
                if token then ns:ScrapeCastStop(token) end
            end
        end
    end

    function ns:RefreshNativeMouseoverPresentation()
        if not ns.UpdateNativeMouseoverPresentation then return end
        for frame in pairs(managedPlates) do
            if frame:IsShown() and frame._tpAnnounced then
                local h = frame._tpNativeHighlight
                ns.UpdateNativeMouseoverPresentation(frame, h and h.IsShown and h:IsShown() and true or false)
            end
        end
    end

    local lastChildCount = -1
    local matchElapsed = 0
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(_, elapsed)
        -- Cheap fast-path: a change in WorldFrame's child count means the client
        -- grew its nameplate pool (a brand-new plate frame). Scan immediately so
        -- newly created plates pop in without waiting for the throttled tick.
        local n = WorldFrame:GetNumChildren()
        if n ~= lastChildCount then
            lastChildCount = n
            ScanWorldFrame()
        end
        -- Every frame: catch C-side show/hide of known pooled plates immediately,
        -- so appearance/disappearance is ~1 frame, not up to a throttled tick.
        ProcessPlateVisibility()
        -- Every frame: mirror engine-driven casts for untargeted mobs.
        ProcessPlateCasts()
        if ns.UpdateNativeMouseoverPresentation then
            for frame in pairs(managedPlates) do
                if frame:IsShown() and frame._tpAnnounced then
                    local h = frame._tpNativeHighlight
                    ns.UpdateNativeMouseoverPresentation(frame, h and h.IsShown and h:IsShown() and true or false)
                end
            end
        end
        matchElapsed = matchElapsed + elapsed
        if matchElapsed >= 0.1 * (ns.c_throttleMultiplier or 1) then
            matchElapsed = 0
            -- On stock 3.3.5a nameplate frames are POOLED: the client hides and
            -- re-shows persistent WorldFrame children, it doesn't add/remove them.
            -- Once the pool stops growing the child-count fast-path above never
            -- fires again, so a plate panned off-screen and back (or a pooled
            -- frame reused for a new mob) would never be released/re-acquired and
            -- its art would stay hidden ("plates disappear after looking away").
            -- Re-scan on the throttled tick to catch those show/hide transitions.
            ScanWorldFrame()
            UpdateMatches()
            -- Announce any plate whose name only just became available (deferred in
            -- AcquirePlate). Done here because FireAdded is defined below the scan
            -- functions. UpdateMatches ran first, so a now-ready plate is already
            -- matched to its real unit when Core first renders it.
            for frame in pairs(managedPlates) do
                if frame:IsShown() then
                    if not frame._tpAnnounced then
                        if PlateAnnounceReady(frame) then
                            frame._tpAnnounced = true
                            frame._tpAnnouncedFriendly = PlateIsFriendly(frame)
                            frame._tpAnnouncedReaction = PlateReaction(frame)
                            FireAdded(frame._tpToken, frame)
                        end
                    else
                        local fr = PlateIsFriendly(frame)
                        local rk = PlateReaction(frame)
                        if fr ~= frame._tpAnnouncedFriendly then
                            frame._tpAnnouncedFriendly = fr
                            frame._tpAnnouncedReaction = rk
                            FireAdded(frame._tpToken, frame)
                        elseif rk and rk ~= frame._tpAnnouncedReaction then
                            frame._tpAnnouncedReaction = rk
                            if ns.UpdateColor then ns.UpdateColor(frame._tpToken) end
                            if frame._isLite and frame.liteContainer and ns.UpdateLiteHealthBar then
                                ns:UpdateLiteHealthBar(frame.liteContainer, frame._tpToken)
                            end
                        end
                        if ns.c_tankMode and ns.c_tankMode ~= 0 and ns.GetNativePlateThreatStatus then
                            local ts = ns.GetNativePlateThreatStatus(frame._tpToken)
                            if ts ~= frame._tpLastThreatStatus then
                                frame._tpLastThreatStatus = ts
                                if ns.UpdateColor then ns.UpdateColor(frame._tpToken) end
                            end
                        else
                            frame._tpLastThreatStatus = nil
                        end
                    end
                end
            end
        end
    end)

    -- Memoised unit -> "unit.."target"" tokens: UNIT_TARGET fires constantly in
    -- group combat and rebuilding the token re-hashed it on every event. Bounded
    -- by the client's unit-token set (party/raid/arena/pet...), so it stays small.
    local unitTargetToken = {}

    driver:RegisterEvent("PLAYER_ENTERING_WORLD")
    driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
    driver:RegisterEvent("RAID_ROSTER_UPDATE")
    driver:RegisterEvent("PLAYER_TARGET_CHANGED")
    driver:RegisterEvent("PLAYER_FOCUS_CHANGED")
    driver:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    driver:RegisterEvent("UNIT_TARGET")
    driver:RegisterEvent("ARENA_OPPONENT_UPDATE")
    driver:RegisterEvent("CVAR_UPDATE")
    driver:SetScript("OnEvent", function(_, event, arg1)
        if event == "CVAR_UPDATE" then
            -- Toggling friendly/enemy nameplates (nameplateShowFriends/Enemies) is a
            -- CVar change that bulk-shows the plates C-side, bypassing our per-frame
            -- Show hook - so they'd only be re-acquired on the throttled scan (~0.1s),
            -- leaving a brief gap where the plate is gone. Rescan now (synchronous
            -- show) AND force a full scan next frame (async show) to close the gap.
            ScanWorldFrame()
            matchElapsed = 1e9
            UpdateMatches()
            return
        end
        if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE"
           or event == "PLAYER_ENTERING_WORLD" then
            RebuildTrackedUnits()
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            -- Same rationale as target/focus: release first so UpdateMatches
            -- re-binds "mouseover" to the hovered plate by strict health rather
            -- than letting the lenient keep-check hold a same-named neighbour.
            local f = matchUnitToPlate["mouseover"]
            if f then ReleaseMatch(f) end
            CacheUnitByName("mouseover")
        elseif event == "PLAYER_TARGET_CHANGED" then
            -- Drop the prior "target" binding so UpdateMatches re-establishes it
            -- against the correct plate via the strict health check. The lenient
            -- keep-check would otherwise let a same-named neighbouring plate stay
            -- bound to "target" when switching between two same-name mobs.
            local f = matchUnitToPlate["target"]
            if f then ReleaseMatch(f) end
            CacheUnitByName("target")
        elseif event == "PLAYER_FOCUS_CHANGED" then
            local f = matchUnitToPlate["focus"]
            if f then ReleaseMatch(f) end
            CacheUnitByName("focus")
        elseif event == "UNIT_TARGET" and arg1 then
            local ut = unitTargetToken[arg1]
            if not ut then
                ut = arg1 .. "target"
                unitTargetToken[arg1] = ut
            end
            CacheUnitByName(ut)
        elseif event == "ARENA_OPPONENT_UPDATE" and arg1 then
            -- Arena enemy became visible ("seen"): cache class/level NOW so their
            -- plate class-colours without ever being clicked. This is the
            -- automatic class source for arenas on stock 3.3.5a (no DLL token);
            -- CacheUnitByName no-ops for "unseen"/"cleared" (UnitExists false).
            CacheUnitByName(arg1)
        end
        UpdateMatches()
    end)

    -- 3.3.5a delivers COMBAT_LOG args as the event payload (not via a getter).
    local COMBATLOG_OBJECT_TYPE_PLAYER = 0x00000400
    -- Learn a player's CLASS from the combat log (native 3.2+ GUID lookup): the
    -- automatic class source on stock 3.3.5a for a player you never target or
    -- mouseover ("plates only class-colour after I click them"). Fills the same
    -- name-keyed caches CacheUnitByName feeds, then recolours the name's announced
    -- plates ONCE (class is immutable per name, so this runs once per new player
    -- name and is a table lookup afterwards; no per-event garbage).
    local _GetPlayerInfoByGUID = GetPlayerInfoByGUID
    local function LearnClassFromGUID(guid, name)
        if classTokenCache[name] or not _GetPlayerInfoByGUID then return end
        local localized, token = NormalizeClassInfo(_GetPlayerInfoByGUID(guid))
        if not token or token == "" then return end
        classCache[name] = localized
        classTokenCache[name] = token
        if ns.UpdateColor then
            for frame in pairs(managedPlates) do
                if frame._tpAnnounced and PlateName(frame) == name then
                    ns.UpdateColor(frame._tpToken)
                end
            end
        end
    end

    local COMBATLOG_OBJECT_REACTION_FRIENDLY = 0x00000010
    local COMBATLOG_OBJECT_REACTION_HOSTILE  = 0x00000040

    local function RefreshKnownPlayerPlates(name)
        for frame in pairs(managedPlates) do
            if frame._tpAnnounced and PlateName(frame) == name then
                local friendly = PlateIsFriendly(frame)
                if friendly ~= frame._tpAnnouncedFriendly then
                    frame._tpAnnouncedFriendly = friendly
                    FireAdded(frame._tpToken, frame)
                elseif ns.UpdateColor then
                    ns.UpdateColor(frame._tpToken)
                end
            end
        end
    end

    local function LearnPlayerRelationFromFlags(name, flags)
        if not name or not flags then return end
        local oldIsPlayer = isPlayerCache[name]
        local oldRelation = playerRelationCache[name]

        if bit.band(flags, COMBATLOG_OBJECT_TYPE_PLAYER) == 0 then
            isPlayerCache[name] = false
            return
        end

        isPlayerCache[name] = true
        if bit.band(flags, COMBATLOG_OBJECT_REACTION_FRIENDLY) ~= 0 then
            playerRelationCache[name] = "friendly"
        elseif bit.band(flags, COMBATLOG_OBJECT_REACTION_HOSTILE) ~= 0 then
            playerRelationCache[name] = "enemy"
        end

        if oldIsPlayer ~= true or oldRelation ~= playerRelationCache[name] then
            RefreshKnownPlayerPlates(name)
        end
    end

    local clog = CreateFrame("Frame")
    clog:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    -- 3.3.5a CLEU payload (after self,event): timestamp, subevent, srcGUID,
    -- srcName, srcFlags, dstGUID, dstName, dstFlags (no raid flags on this core),
    -- then event-specific args. For SPELL_CAST_START: spellId, spellName, school.
    clog:SetScript("OnEvent", function(_, _, _, subevent, srcGUID, srcName, srcFlags, destGUID, destName, destFlags, spellId, spellName)
        if srcName and srcFlags then
            LearnPlayerRelationFromFlags(srcName, srcFlags)
            if isPlayerCache[srcName] and srcGUID then LearnClassFromGUID(srcGUID, srcName) end
        end
        if destName and destFlags then
            LearnPlayerRelationFromFlags(destName, destFlags)
            if isPlayerCache[destName] and destGUID then LearnClassFromGUID(destGUID, destName) end
        end
        -- Capture every in-range cast so untargeted nameplates can render it. This is
        -- the ONLY source for an untargeted cast on stock 3.3.5a (the engine doesn't
        -- drive the Blizzard nameplate cast bar to scrape).
        if subevent == "SPELL_CAST_START" and srcGUID and srcName then
            -- GetSpellInfo is nil-safe for unknown/private-server ids and never
            -- crashes (unlike SetSpellByID). On 3.3.5a it returns
            -- name, rank, icon, cost, isFunnel, powerType, castTime(ms), ... - so the
            -- 7th value is the base cast time we use to animate the bar.
            local giName, _, giIcon, _, _, _, giCastMs = GetSpellInfo(spellId)
            local dur = (type(giCastMs) == "number" and giCastMs > 0) and (giCastMs / 1000) or nil
            if dur then
                local now = GetTime()
                local entry = { name = giName or spellName, icon = giIcon,
                                start = now, duration = dur, guid = srcGUID }
                castByGUID[srcGUID] = entry
            end
        elseif subevent == "SPELL_CAST_SUCCESS" and srcGUID then
            -- For a CHANNELED spell this is the START marker: channels never fire
            -- SPELL_CAST_START, they log SPELL_CAST_SUCCESS the moment channeling
            -- begins, and GetSpellInfo reports castTime 0 for them - so the
            -- duration comes from the seed/learned registry instead
            -- (WotlkCompat_Channels.lua, name-keyed so NPC variants that share a
            -- player spell's name resolve too). For a normal cast this is the END.
            local chDur = spellName and ns.GetChannelDuration
                          and ns.GetChannelDuration(spellName)
            if chDur then
                local giName, _, giIcon = GetSpellInfo(spellId)
                -- victim = the channel's target; its aura removal (below) is the
                -- live "channel stopped early" signal. Normalize the no-target
                -- GUID so AoE self-channels match their own aura instead.
                local victim = destGUID
                if victim == "" or victim == "0x0000000000000000" then victim = nil end
                castByGUID[srcGUID] = { name = giName or spellName, icon = giIcon,
                                        start = GetTime(), duration = chDur,
                                        guid = srcGUID, channel = true,
                                        victim = victim }
            else
                ClearCastEntry(castByGUID[srcGUID])
            end
        elseif subevent == "SPELL_CAST_FAILED" then
            if srcGUID then ClearCastEntry(castByGUID[srcGUID]) end
        elseif subevent == "SPELL_INTERRUPT" then
            -- The INTERRUPTED caster is destGUID - srcGUID is the INTERRUPTER
            -- (Kick/Counterspell source). The old clear-by-srcGUID removed a
            -- nonexistent entry, so an interrupted unbound mob's bar kept
            -- filling until the grace sweep instead of vanishing on the kick.
            if destGUID then ClearCastEntry(castByGUID[destGUID]) end
        elseif subevent == "SPELL_AURA_REMOVED" then
            -- Early channel end (caster stunned/moved, victim died/LoS'd): most
            -- channels maintain an aura with the SAME name - on the victim
            -- (Drain Life, Mind Flay, Mind Control) or on the caster itself
            -- (Hellfire, Evocation, Eyes of the Beast) - and its removal is the
            -- only live "channel stopped" signal CLEU gives. Guard on the
            -- recorded victim so this caster's OLD copy of the aura expiring on
            -- another unit can't kill a live bar, and skip the first 0.3s to
            -- survive apply/remove reordering at channel start. Pure-AoE
            -- channels with no aura (Blizzard) rely on the duration timeout /
            -- interrupt / death like before.
            local e = srcGUID and castByGUID[srcGUID]
            if e and e.channel and spellName == e.name
               and (not e.victim or e.victim == destGUID)
               and (GetTime() - e.start) > 0.3 then
                ClearCastEntry(e)
            end
        elseif subevent == "UNIT_DIED" then
            -- Dead caster: drop its bar now instead of waiting for the sweep.
            if destGUID then ClearCastEntry(castByGUID[destGUID]) end
        end
    end)

    -- Cast bar driver. On stock 3.3.5a, UNIT_SPELLCAST_* events fire with real
    -- unit tokens (target/focus/party/raid), never with our synthetic plate
    -- tokens - so TurboPlates' own castbar handler (which only acts on
    -- "nameplate"-prefixed units) never fires. Bridge it: when a real unit that
    -- the match tracker has bound to a plate casts, route the event to that
    -- plate's castbar via TurboPlates' public API, passing the PLATE TOKEN.
    -- CheckExistingCast/CleanupCastbar look the plate up in ns.unitToPlate (keyed
    -- by token, populated by Core.lua), and CastStart reads UnitCastingInfo(token)
    -- which our wrapper resolves back to the real unit. (Cast events only fire
    -- for units the client tracks - target/focus/party/raid - which covers the
    -- mob you're actually fighting; arbitrary unbound plates can't show casts.)
    local castDriver = CreateFrame("Frame")
    castDriver:RegisterEvent("UNIT_SPELLCAST_START")
    castDriver:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    castDriver:RegisterEvent("UNIT_SPELLCAST_STOP")
    castDriver:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    castDriver:RegisterEvent("UNIT_SPELLCAST_FAILED")
    castDriver:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    castDriver:RegisterEvent("UNIT_SPELLCAST_DELAYED")
    castDriver:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
    castDriver:SetScript("OnEvent", function(_, event, unit)
        if not unit or isPlateToken(unit) then return end
        local blizzFrame = matchUnitToPlate[unit]
        local token = blizzFrame and blizzFrame._tpToken
        if not token then return end
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
           or event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            if ns.CheckExistingCast then ns:CheckExistingCast(token) end
        else
            if ns.CleanupCastbar then ns:CleanupCastbar(token) end
        end
    end)

    -- awesome_wotlk DLL compatibility: if a partial native C_NamePlate already
    -- exists (GetNamePlateForUnit present but no C_NamePlateManager), preserve
    -- its GetNamePlateForUnit as a fallback so addons using native unit tokens
    -- ("nameplate1" etc. from NAME_PLATE_UNIT_ADDED events) still resolve
    -- correctly when our name-based cache hasn't caught up yet.
    local _nativeGetNamePlateForUnit = (type(C_NamePlate) == "table"
        and type(C_NamePlate.GetNamePlateForUnit) == "function")
        and C_NamePlate.GetNamePlateForUnit or nil

    -- awesome_wotlk token bridge: tag each managed frame with its real "nameplateN"
    -- unit so the scrapers (PlateHealth / RefreshPlateScrape) can prefer live engine
    -- health over the freezable bar scrape, and push an INSTANT re-render on the real
    -- UNIT_HEALTH event. The DLL resolves the token to the SAME WorldFrame child we
    -- manage, so the field lands on the frame the scrapers see. Fully optional: a
    -- frame that never receives a token just stays on the scrape path. faTokenFrame
    -- gives O(1) UNIT_HEALTH lookup and naturally ignores non-nameplate units.
    if HAVE_AWESOME_WOTLK and _nativeGetNamePlateForUnit then
        local faTokenFrame = {}
        local faBridge = CreateFrame("Frame")
        faBridge:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        faBridge:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        faBridge:RegisterEvent("UNIT_HEALTH")
        faBridge:RegisterEvent("UNIT_MAXHEALTH")
        faBridge:SetScript("OnEvent", function(_, event, unit)
            if not unit then return end
            if event == "NAME_PLATE_UNIT_ADDED" then
                local f = _nativeGetNamePlateForUnit(unit)
                if f then
                    f._realToken = unit
                    faTokenFrame[unit] = f
                end
            elseif event == "NAME_PLATE_UNIT_REMOVED" then
                local f = faTokenFrame[unit]
                if f and f._realToken == unit then
                    f._realToken = nil
                    f._tpLastPushHP, f._tpLastPushMax = nil, nil
                end
                faTokenFrame[unit] = nil
            else  -- UNIT_HEALTH / UNIT_MAXHEALTH for a real nameplate token
                local f = faTokenFrame[unit]
                if f and f._tpAnnounced and f._tpToken and ns.UpdateNameplateHealth then
                    -- Sync the scrape sweep's "last pushed" so its 0.1s backstop doesn't
                    -- redundantly re-push the same value right after this instant one.
                    f._tpLastPushHP, f._tpLastPushMax = _UnitHealth(unit), _UnitHealthMax(unit)
                    ns.UpdateNameplateHealth(f._tpToken)
                end
            end
        end)
    end

    C_NamePlate = {}
    function C_NamePlate.GetNamePlateForUnit(unit)
        if not unit then return nil end
        if isPlateToken(unit) then
            local f = tokenToPlate[unit]
            return (f and f:IsShown() and f._tpAnnounced) and f or nil
        end
        --
        if _UnitExists(unit) then
            --
            local aliasFrame
            if not matchUnitToPlate[unit] then
                for ownedFrame in pairs(managedPlates) do
                    local ownedUnit = ownedFrame._tpMatchedUnit
                    if ownedUnit and ownedUnit ~= unit and _UnitExists(ownedUnit)
                       and UnitIsUnit and UnitIsUnit(ownedUnit, unit) then
                        if unit == "target" then
                            SetMatch(ownedFrame, unit)
                        else
                            aliasFrame = ownedFrame
                        end
                        break
                    end
                end
            end
            if aliasFrame and aliasFrame:IsShown() and aliasFrame._tpAnnounced
               and PlateStillMatchesUnit(aliasFrame, unit) then
                return aliasFrame
            end
            if UpdateMatches then UpdateMatches() end
        end
        local f = matchUnitToPlate[unit]

        if not f and unit == "target" and _UnitExists("target") then
            local targetName = _UnitName("target")
            local targetLevel = _UnitLevel("target")
            local alphaFrame, alphaAmbiguous, sawDimmed = nil, false, false

            for frame in pairs(managedPlates) do
                if frame:IsShown() and frame._tpAnnounced and frame.GetAlpha then
                    local a = frame:GetAlpha() or 1
                    if a < 0.99 then sawDimmed = true end

                    if a >= 0.99 and PlateName(frame) == targetName then
                        local lvl = PlateLevel(frame)
                        if not (lvl and targetLevel and targetLevel > 0 and lvl ~= targetLevel) then
                            if alphaFrame then
                                alphaAmbiguous = true
                            else
                                alphaFrame = frame
                            end
                        end
                    end
                end
            end

            if sawDimmed and alphaFrame and not alphaAmbiguous then
                SetMatch(alphaFrame, "target")
                f = matchUnitToPlate[unit]
            end
        end

        -- Trust an already-established match via the lenient check; the strict
        -- health compare here would intermittently return nil for the target on
        -- the post-hit sync gap (see PlateStillMatchesUnit) and flicker the glow.
        if f and f:IsShown() and f._tpAnnounced and PlateStillMatchesUnit(f, unit) then return f end
        if _UnitExists(unit) then
            for frame in pairs(managedPlates) do
                if frame:IsShown() and frame._tpAnnounced and PlateMatchesUnit(frame, unit) then
                    SetMatch(frame, unit)
                    return frame
                end
            end
        end
        -- Last resort: if awesome_wotlk provided a native implementation, let it
        -- resolve native unit tokens (e.g. "nameplate1") that our cache missed.
        if _nativeGetNamePlateForUnit then return _nativeGetNamePlateForUnit(unit) end
        return nil
    end
    function C_NamePlate.GetNamePlates()
        local t = {}
        for frame in pairs(managedPlates) do
            if frame:IsShown() and frame._tpAnnounced then t[#t+1] = frame end
        end
        return t
    end
    _G.C_NamePlate = C_NamePlate

    C_NamePlateManager = {}
    -- Only enumerate ANNOUNCED plates (see PlateDataReady) so Core never iterates
    -- and renders a half-initialized plate before its name/size are ready.
    function C_NamePlateManager.EnumerateActiveNamePlates()
        local frame = nil
        return function()
            repeat frame = next(managedPlates, frame)
            until frame == nil or (frame:IsShown() and frame._tpAnnounced)
            return frame
        end
    end
    function C_NamePlateManager.GetNamePlateSize()
        for frame in pairs(managedPlates) do
            local hb = frame._tpHealthBar
            if hb and hb.GetWidth then
                local w, h = hb:GetWidth(), hb:GetHeight()
                if w and w > 0 then return w, h end
            end
        end
        return 110, 30
    end
    function C_NamePlateManager.DisableBlizzPlate(unit)
        local frame = C_NamePlate.GetNamePlateForUnit(unit)
        if not frame then return end
        if frame.SetAttribute then
            frame:SetAttribute("disabled-blizz-plate", true)
        end
        HideBlizzPlateRegions(frame)
    end
    function C_NamePlateManager.ApplyFPSIncrease() end
    function C_NamePlateManager.SetEnableResizeNamePlates() end
    _G.C_NamePlateManager = C_NamePlateManager

    -- awesome_wotlk native-event plate discovery + WeakAura sync -----------
    -- On awesome_wotlk the DLL manages nameplate VISIBILITY C-side and exposes
    -- authoritative native events. Our stock-3.3.5a discovery (WorldFrame scan +
    -- texture fingerprint + IsShown) races with that C-side state: after a /reload
    -- the DLL's visibility flags are briefly stale, so an already-visible plate is
    -- missed by the heuristic and never re-evaluated (no WorldFrame child-count
    -- change, no Show hook fires), leaving it invisible until the player toggles
    -- nameplates - which forces both a DLL visibility re-sync AND our CVAR_UPDATE
    -- rescan. Symptom the testers hit: "nameplate randomly not showing, especially
    -- after /reload; deactivate/activate nameplates to see them again".
    --
    -- The DLL's nameplate IS the client's own anonymous WorldFrame-child frame
    -- (unit->nameplate) - the exact frame we scrape - so we can drive discovery
    -- straight from the native events instead of the fingerprint heuristic:
    --   NAME_PLATE_CREATED     -> remember the frame as a known plate (authoritative
    --                             identity; no fingerprint match needed).
    --   NAME_PLATE_UNIT_ADDED  -> the plate is visible NOW: acquire it immediately
    --                             if the scan hasn't yet (closes the post-reload
    --                             gap), pre-fill name + reaction from the native unit
    --                             API so PlateAnnounceReady passes at once, and
    --                             announce in THIS event cycle. TurboPlates loads
    --                             before WeakAuras, so a WA anchored to the plate
    --                             (which runs right after us) sees the final scaled
    --                             plate - no reposition, no lag.
    -- Release still flows through ProcessPlateVisibility (IsShown) as before.
    if HAVE_AWESOME_WOTLK and _nativeGetNamePlateForUnit then
        local function aweMarkKnown(blizzFrame)
            if not blizzFrame then return end
            blizzFrame._tpIsNamePlate = true
            knownPlates[blizzFrame] = true
        end
        local aweSyncFrame = CreateFrame("Frame")
        aweSyncFrame:RegisterEvent("NAME_PLATE_CREATED")
        aweSyncFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        aweSyncFrame:SetScript("OnEvent", function(_, event, arg1)
            if event == "NAME_PLATE_CREATED" then
                -- arg1 is the namePlateBase frame itself.
                aweMarkKnown(arg1)
                return
            end
            -- NAME_PLATE_UNIT_ADDED: arg1 is a native unit token ("nameplate1").
            local unit = arg1
            local blizzFrame = _nativeGetNamePlateForUnit(unit)
            if not blizzFrame then return end
            aweMarkKnown(blizzFrame)
            -- Acquire now if the fingerprint scan hasn't - this is the authoritative
            -- "plate is up" signal and closes the post-reload discovery gap.
            if not managedPlates[blizzFrame] then
                AcquirePlate(blizzFrame)
            end
            if blizzFrame._tpAnnounced then return end
            -- Pre-fill name from native API, bypassing the font-region scrape wait.
            local name = _UnitName(unit)
            if name and name ~= "" and name ~= "Unknown" then
                blizzFrame._tpName = name
            end
            local hb = blizzFrame._tpHealthBar
            if hb and hb.GetStatusBarColor then
                local rk = ColorToReactionKey(hb:GetStatusBarColor())
                if rk then blizzFrame._tpReaction = rk end
            end
            -- Announce immediately if ready.
            if PlateAnnounceReady(blizzFrame) then
                blizzFrame._tpAnnounced = true
                blizzFrame._tpAnnouncedFriendly = PlateIsFriendly(blizzFrame)
                FireAdded(blizzFrame._tpToken, blizzFrame)
            end
        end)
    end
    -- end awesome_wotlk native-event discovery -----------------------------

    function ns.GetResolvedNameplateUnit(blizzFrame)
        return blizzFrame and blizzFrame._unit or nil
    end
    function ns.GetPlateReaction(blizzFrame) return PlateReaction(blizzFrame) end

    -- Diagnostic: dump the raw region/child layout of the current target's plate.
    -- Reveals this core's actual region order/types so we can confirm name/level
    -- detection. Invoked via "/tp dumpplate".
    function ns.DebugDumpPlate()
        local frame = matchUnitToPlate["target"]
        if not frame then
            for f in pairs(managedPlates) do
                if f:IsShown() then frame = f break end
            end
        end
        if not frame then
            print("|cff4fa3ffTurboPlates|r: no managed plate found (target a mob first).")
            return
        end
        print("|cff4fa3ffTurboPlates|r plate dump  name="..tostring(PlateName(frame))
            .." level="..tostring(PlateLevel(frame)))
        -- awesome_wotlk bridge status: confirms whether this plate is bound to a real
        -- "nameplateN" token (so health comes from live UnitHealth, not the scrape).
        local rt = frame._realToken
        local mp2 = frame.myPlate
        local rtOK = rt and _UnitExists(rt)
        print(string.format("  awesome_wotlk=%s realToken=%s realHP=%s/%s scrapeHP=%s/%s barHP=%s/%s",
            tostring(HAVE_AWESOME_WOTLK), tostring(rt),
            rtOK and tostring(_UnitHealth(rt)) or "n/a",
            rtOK and tostring(_UnitHealthMax(rt)) or "n/a",
            tostring(frame._tpHP), tostring(frame._tpHPMax),
            (mp2 and mp2.hp) and tostring(mp2.hp:GetValue()) or "n/a",
            (mp2 and mp2.hp) and tostring(select(2, mp2.hp:GetMinMaxValues())) or "n/a"))
        -- Read-only health/token diagnostic (awesome_wotlk): confirms the synthetic
        -- token resolves to THIS myPlate. A nil/mismatched mapping is the "health bar
        -- frozen" signature (UpdateHealth early-returns on it).
        local tok = frame._tpToken
        local mapped = tok and ns.unitToPlate and ns.unitToPlate[tok]
        print("  token="..tostring(tok).." unitToPlate[token]="..tostring(mapped)
            .." sameAsMyPlate="..tostring(mapped == mp2)
            .." announced="..tostring(frame._tpAnnounced))
        local depth = frame.GetEffectiveDepth and frame:GetEffectiveDepth() or 0
        local fx, fy = frame:GetCenter()
        local fbottom = frame.GetBottom and frame:GetBottom() or nil
        local ftop = frame.GetTop and frame:GetTop() or nil
        print(string.format("  frame scale=%.3f effScale=%.3f size=%.0fx%.0f depth=%.3f center=%.1f,%.1f bottom=%.1f top=%.1f",
            frame:GetScale() or 0, frame:GetEffectiveScale() or 0,
            frame:GetWidth() or 0, frame:GetHeight() or 0, depth or 0,
            fx or 0, fy or 0, fbottom or 0, ftop or 0))
        local nativeHB = frame._tpHealthBar
        if not nativeHB and frame.GetChildren then
            nativeHB = select(1, frame:GetChildren())
        end
        if nativeHB then
            local hbDepth = nativeHB.GetEffectiveDepth and nativeHB:GetEffectiveDepth() or 0
            print(string.format("  nativeHB scale=%.3f effScale=%.3f depth=%.3f shown=%s",
                nativeHB.GetScale and nativeHB:GetScale() or 0,
                nativeHB.GetEffectiveScale and nativeHB:GetEffectiveScale() or 0,
                hbDepth or 0, tostring(nativeHB.IsShown and nativeHB:IsShown())))
        end
        local depthProbe = frame._tpDistanceDepthProbe
        if depthProbe then
            local pd = depthProbe.GetEffectiveDepth and depthProbe:GetEffectiveDepth() or 0
            print(string.format("  depthProbe depth=%.3f shown=%s envelopeFactor=%s baseSize=%sx%s currentSize=%.1fx%.1f",
                pd or 0, tostring(depthProbe.IsShown and depthProbe:IsShown()),
                frame._tpDistanceEnvelopeFactor and string.format("%.3f", frame._tpDistanceEnvelopeFactor) or "nil",
                tostring(frame._tpDistanceBaseWidth), tostring(frame._tpDistanceBaseHeight),
                frame:GetWidth() or 0, frame:GetHeight() or 0))
        end
        local mp = frame.myPlate
        if mp then
            local mx, my = mp:GetCenter()
            local mbottom = mp.GetBottom and mp:GetBottom() or nil
            local mtop = mp.GetTop and mp:GetTop() or nil
            local mdepth = mp.GetEffectiveDepth and mp:GetEffectiveDepth() or 0
            print(string.format("  myPlate scale=%.3f effScale=%.3f size=%.0fx%.0f depth=%.3f center=%.1f,%.1f bottom=%.1f top=%.1f nativeDepth=%s factor=%s yComp=%s",
                mp:GetScale() or 0, mp:GetEffectiveScale() or 0,
                mp:GetWidth() or 0, mp:GetHeight() or 0, mdepth or 0,
                mx or 0, my or 0, mbottom or 0, mtop or 0,
                mp._tpNativeDepth and string.format("%.3f", mp._tpNativeDepth) or "nil",
                mp._tpDistanceScaleFactor and string.format("%.3f", mp._tpDistanceScaleFactor) or "nil",
                mp._tpDistanceYOffset and string.format("%.2f", mp._tpDistanceYOffset) or "0.00"))
            print(string.format("  autoY rawProbe=%s cameraDistance=%s playerDepth=%s cameraValid=%s source=%s rootComp=%s",
                mp._tpDistanceRawDepth and string.format("%.3f", mp._tpDistanceRawDepth) or "nil",
                mp._tpCameraDistance and string.format("%.3f", mp._tpCameraDistance) or "nil",
                mp._tpPlayerRelativeDepth and string.format("%.3f", mp._tpPlayerRelativeDepth) or "nil",
                tostring(mp._tpCameraDistanceValid == true),
                tostring(mp._tpCameraDistanceSource or ns._tpDistanceCameraSource or "nil"),
                mp._tpRootDistanceYOffset and string.format("%.2f", mp._tpRootDistanceYOffset) or "0.00"))
            print(string.format("  cameraReadback savedBefore=%s savedAfter=%s savedPitch=%s",
                mp._tpCameraSavedDistanceBefore and string.format("%.3f", mp._tpCameraSavedDistanceBefore) or "nil",
                mp._tpCameraSavedDistanceAfter and string.format("%.3f", mp._tpCameraSavedDistanceAfter) or "nil",
                mp._tpCameraSavedPitch and string.format("%.3f", mp._tpCameraSavedPitch) or "nil"))
        end
        local regions = { frame:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            local t = r and r.GetObjectType and r:GetObjectType() or "?"
            local extra = ""
            if t == "FontString" then
                extra = " text='"..tostring(r:GetText()).."' shown="..tostring(r:IsShown())
            elseif t == "Texture" then
                extra = " tex='"..tostring(r:GetTexture()).."'"
            end
            print("  region["..i.."] "..t..extra)
        end
        local i = 0
        for _, c in ipairs({ frame:GetChildren() }) do
            i = i + 1
            print("  child["..i.."] "..(c.GetObjectType and c:GetObjectType() or "?"))
        end
    end
end

ns.IS_WOTLK_COMPAT = not HAVE_NATIVE_ENGINE
ns.HAVE_AWESOME_WOTLK = HAVE_AWESOME_WOTLK or false
TurboPlatesWotlkCompat = {
    active         = not HAVE_NATIVE_ENGINE,
    mode           = HAVE_NATIVE_ENGINE and "native"
                     or (HAVE_AWESOME_WOTLK and "namebased-335+awesome_wotlk" or "namebased-335"),
    awesomeWotlk   = HAVE_AWESOME_WOTLK or false,
    note           = "Backported to stock 3.3.5a by Jedborg",
}
