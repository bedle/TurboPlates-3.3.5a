--[[----------------------------------------------------------------------------
    TurboPlates - pure 3.3.5a backport, part 3: aura / threat API shims
    (Backported by Jedborg)

    Maps retail aura/threat unit APIs onto WotLK. These operate on unit tokens;
    for plates bound to a real unit (target/focus/mouseover/group target) they
    return real data via the wrapped Unit* functions. For unbound plates the
    underlying UnitAura simply returns nothing, so auras quietly don't show --
    which is the expected limit on a pure client.

    Loaded after the engine, before any module that consumes auras.
------------------------------------------------------------------------------]]

local addonName, ns = ...
if ns.Compat and ns.Compat.HAS_NATIVE_ENGINE then return end

-- Route through the compat wrappers (ns.UnitX) so the AuraUtil shims below resolve
-- plate tokens to their matched real unit. Falls back to the raw fn on a native
-- engine (where no wrapper exists).
local UnitAura   = ns.UnitAura   or UnitAura   -- singular on 3.3.5a
local UnitExists = ns.UnitExists or UnitExists

---------------------------------------------------------------------------
-- AuraUtil.ForEachAura(unit, filter, maxCount, callback)
--
-- ClassicAPI ships its own AuraUtil.ForEachAura, but it's built on the retail
-- UnitAuraSlots API which doesn't exist on stock 3.3.5a - so it errors the
-- instant TurboPlates iterates auras. Whenever the slot API is missing, REPLACE
-- ForEachAura/FindAuraByName with these UnitAura-based versions (don't just
-- skip when AuraUtil.ForEachAura already exists). UnitAura/UnitExists were
-- already wrapped in WotlkCompat.lua, so plate tokens resolve correctly here.
---------------------------------------------------------------------------
AuraUtil = AuraUtil or {}
local NEED_AURA_SHIM = (type(UnitAuraSlots) ~= "function")
if NEED_AURA_SHIM or type(AuraUtil.ForEachAura) ~= "function" then
    function AuraUtil.ForEachAura(unit, filter, maxCount, callback)
        if not unit or not UnitExists(unit) or type(callback) ~= "function" then return end
        filter = filter or "HELPFUL"
        -- Stock 3.3.5a's UnitAura does NOT reliably honour the "PLAYER" filter
        -- token: a combined "HARMFUL|PLAYER" returns nothing on common cores
        -- (TrinityCore et al.), so the enemy-debuff display - which scans with
        -- "HARMFUL|PLAYER" to show only your own DoTs - came up empty for every
        -- class. Ascension's native engine parsed the token, which is why it only
        -- broke on the backport. Never pass "PLAYER" through; scan the base
        -- HELPFUL/HARMFUL list and decide "is it mine?" ourselves.
        --
        -- "Mine" via unitCaster mirrors retail's "PLAYER" filter, which is really
        -- isFromPlayerOrPlayerPet, so player + pet + vehicle pass. But unitCaster
        -- is unreliable on some 3.3.5a cores (returns nil for every aura); when it
        -- is absent we must NOT silently drop everything. In that case we pass the
        -- aura through and let the consumer's own duration>0 check do the work -
        -- on 3.3.5a the client only timestamps auras YOU applied, so duration>0 is
        -- itself a sound "cast by me" signal.
        local auraFilter = (filter:find("HARMFUL") and "HARMFUL" or "HELPFUL")
        local playerOnly = filter:find("PLAYER") and true or false
        local limit = maxCount or 40
        for i = 1, limit do
            local name, rank, icon, count, debuffType, duration, expires,
                  caster, isStealable, shouldConsolidate, spellID,
                  canApplyAura, isBossDebuff, castByPlayer = UnitAura(unit, i, auraFilter)
            if not name then break end
            local mine = (not playerOnly)
                or caster == "player" or caster == "pet" or caster == "vehicle"
                or caster == nil  -- core didn't report a caster: defer to duration>0
            if mine then
                local stop = callback(name, rank, icon, count, debuffType, duration,
                    expires, caster, isStealable, shouldConsolidate, spellID,
                    canApplyAura, isBossDebuff, castByPlayer)
                if stop then break end
            end
        end
    end
end
---------------------------------------------------------------------------
-- Diagnostic: "/tp dumpaura" - dump what UnitAura actually returns for the
-- current target on this core, so we can see whether unitCaster / duration /
-- the "HARMFUL|PLAYER" token behave. Prints raw HARMFUL scan + the native
-- combined-filter result.
---------------------------------------------------------------------------
function ns.DebugDumpTargetAuras()
    local unit = "target"
    if not UnitExists(unit) then
        print("|cff4fa3ffTurboPlates|r dumpaura: no target")
        return
    end
    print("|cff4fa3ffTurboPlates|r aura dump for "..tostring(UnitName(unit)))
    local any = false
    for i = 1, 40 do
        local name, _, _, count, dtype, duration, expires, caster,
              _, _, spellID, _, _, castByPlayer = UnitAura(unit, i, "HARMFUL")
        if not name then break end
        any = true
        print(string.format("  [%d] %s | caster=%s castByPlayer=%s dur=%s exp=%s type=%s id=%s",
            i, tostring(name), tostring(caster), tostring(castByPlayer),
            tostring(duration), tostring(expires), tostring(dtype), tostring(spellID)))
    end
    if not any then print("  (no HARMFUL auras returned)") end
    local pName, _, _, _, _, pDur, _, pCaster = UnitAura(unit, 1, "HARMFUL|PLAYER")
    print(string.format("  native 'HARMFUL|PLAYER' idx1: name=%s caster=%s dur=%s",
        tostring(pName), tostring(pCaster), tostring(pDur)))

    -- The nameplate display does NOT scan "target" directly; it scans the plate's
    -- synthetic token, which only resolves to a real unit if the plate is matched.
    -- Reproduce that exact path so we can see where it breaks.
    local frame = C_NamePlate and C_NamePlate.GetNamePlateForUnit
                  and C_NamePlate.GetNamePlateForUnit(unit) or nil
    if not frame then
        print("  PLATE: no nameplate matched to target -> auras can't bind (THIS is the gap)")
        return
    end
    local mp = frame.myPlate
    local token = mp and mp.unit
    print(string.format("  PLATE: token=%s matchedUnit=%s c_showDebuffs=%s",
        tostring(token), tostring(frame._tpMatchedUnit), tostring(ns.c_showDebuffs)))
    if mp and mp.debuffContainer then
        print(string.format("  CONTAINER: shown=%s displayedCount=%s",
            tostring(mp.debuffContainer.IsShown and mp.debuffContainer:IsShown()),
            tostring(mp.debuffContainer.displayedCount)))
    else
        print("  CONTAINER: none (debuff container not created on plate)")
    end
    local tn = 0
    if token then
        AuraUtil.ForEachAura(token, "HARMFUL|PLAYER", 40, function(nm)
            tn = tn + 1
            print("    token-scan ["..tn.."] "..tostring(nm))
            return false
        end)
    end
    print("  token 'HARMFUL|PLAYER' via display path returned "..tn.." aura(s)")
end

if NEED_AURA_SHIM or type(AuraUtil.FindAuraByName) ~= "function" then
    function AuraUtil.FindAuraByName(name, unit, filter)
        if not unit or not UnitExists(unit) then return nil end
        filter = filter or "HELPFUL"
        for i = 1, 40 do
            local n = UnitAura(unit, i, filter)
            if not n then break end
            if n == name then return UnitAura(unit, i, filter) end
        end
        return nil
    end
end
_G.AuraUtil = AuraUtil

---------------------------------------------------------------------------
-- UnitAuras alias
---------------------------------------------------------------------------
if type(UnitAuras) ~= "function" then
    UnitAuras = UnitAura
    _G.UnitAuras = UnitAuras
end

---------------------------------------------------------------------------
-- UnitRole
---------------------------------------------------------------------------
if type(UnitRole) ~= "function" then
    function UnitRole(unit)
        if not unit or not UnitExists(unit) then return nil end
        if GetPartyAssignment then
            if GetPartyAssignment("MAINTANK", unit) then return "TANK" end
            if GetPartyAssignment("MAINASSIST", unit) then return "DAMAGER" end
        end
        if UnitGroupRolesAssigned then
            local r = UnitGroupRolesAssigned(unit)
            if r and r ~= "NONE" then return r end
        end
        return nil
    end
    _G.UnitRole = UnitRole
end

---------------------------------------------------------------------------
-- UnitDetailedThreatSituation (exists on most 3.3.5a cores; fallback anyway)
---------------------------------------------------------------------------
if type(UnitDetailedThreatSituation) ~= "function" then
    function UnitDetailedThreatSituation(unit, mob)
        if not unit or not mob then return nil end
        local status = UnitThreatSituation and UnitThreatSituation(unit, mob) or nil
        if not status then return nil end
        local isTanking = (status == 2 or status == 3)
        return isTanking, status, isTanking and 100 or 0, isTanking and 100 or 0, 0
    end
    _G.UnitDetailedThreatSituation = UnitDetailedThreatSituation
end

---------------------------------------------------------------------------
-- UnitQuestInfo stub (no 3.3.5a equivalent)
---------------------------------------------------------------------------
if type(UnitQuestInfo) ~= "function" then
    function UnitQuestInfo() return nil end
    _G.UnitQuestInfo = UnitQuestInfo
end

---------------------------------------------------------------------------
-- Ambiguate (strip realm from "Name-Realm").
---------------------------------------------------------------------------
if type(Ambiguate) ~= "function" then
    function Ambiguate(name)
        if type(name) ~= "string" then return name end
        return name:match("^([^%-]+)") or name
    end
    _G.Ambiguate = Ambiguate
end

---------------------------------------------------------------------------
-- Group APIs: retail IsInGroup / IsInRaid / GetNumGroupMembers don't exist on
-- 3.3.5a. TurboPlates uses GetNumGroupMembers with retail semantics:
--   in a raid  -> total raid members, iterate raid1..N
--   in a party -> party members + player, iterate party1..(N-1)
---------------------------------------------------------------------------
local _GetNumRaidMembers  = GetNumRaidMembers
local _GetNumPartyMembers = GetNumPartyMembers

if type(IsInRaid) ~= "function" then
    function IsInRaid() return (_GetNumRaidMembers() or 0) > 0 end
    _G.IsInRaid = IsInRaid
end
if type(IsInGroup) ~= "function" then
    function IsInGroup()
        return (_GetNumRaidMembers() or 0) > 0 or (_GetNumPartyMembers() or 0) > 0
    end
    _G.IsInGroup = IsInGroup
end
if type(GetNumGroupMembers) ~= "function" then
    function GetNumGroupMembers()
        local nRaid = _GetNumRaidMembers() or 0
        if nRaid > 0 then return nRaid end
        local nParty = _GetNumPartyMembers() or 0
        if nParty > 0 then return nParty + 1 end
        return 0
    end
    _G.GetNumGroupMembers = GetNumGroupMembers
end

---------------------------------------------------------------------------
-- UnitGetTotalAbsorbs (retail absorb shields). No 3.3.5a equivalent.
---------------------------------------------------------------------------
if type(UnitGetTotalAbsorbs) ~= "function" then
    function UnitGetTotalAbsorbs() return 0 end
    _G.UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
end

---------------------------------------------------------------------------
-- UnitGroupRolesAssigned / ...Key (retail / Ascension role helpers).
---------------------------------------------------------------------------
if type(UnitGroupRolesAssigned) ~= "function" then
    function UnitGroupRolesAssigned() return "NONE" end
    _G.UnitGroupRolesAssigned = UnitGroupRolesAssigned
end
if type(UnitGroupRolesAssignedKey) ~= "function" then
    function UnitGroupRolesAssignedKey(unit)
        return (UnitRole and UnitRole(unit)) or "NONE"
    end
    _G.UnitGroupRolesAssignedKey = UnitGroupRolesAssignedKey
end
