local addonName, ns = ...

-- =============================================================================
-- "MOB IS ATTACKING ME" THREAT COLOURING (stock 3.3.5a)
-- On the token-based engine (Ascension) UnitDetailedThreatSituation answered for
-- EVERY nameplate, so a mob attacking you got its threat colour (e.g. your DPS
-- aggro colour) for free. On stock 3.3.5a the threat API can't resolve an UNBOUND
-- plate token, so only your current target was coloured and mobs hitting you from
-- the side stayed default. We restore the old behaviour by detecting "this mob is
-- hitting the player" from the combat log (no unit token needed) and feeding it to
-- UpdateColor as full aggro (Nameplates.lua, gated on status == nil so a real
-- threat read always wins - a group cleave shouldn't read as you holding aggro).
-- Keyed by GUID (pinned plate) and name (unbound fallback), like the debuff/cast
-- caches. Lives in its own file because Nameplates.lua is already at Lua 5.1's
-- 200-local-per-function limit.
-- =============================================================================

-- Routed through the compat wrappers for plate tokens (real units pass through).
local UnitName = ns.UnitName or UnitName
local UnitGUID = ns.UnitGUID or UnitGUID
local GetTime = GetTime
local pairs, next, wipe = pairs, next, wipe
local CreateFrame = CreateFrame

local aggroByGUID = {}   -- [mobGUID] = { t = lastHit, name = mobName }
local aggroByName = {}   -- [mobName] = { guid = mobGUID, t = lastHit }
local AGGRO_TTL = 5      -- treat as "on me" for this long after the last hit

-- True when this plate's mob is currently attacking the player. Exposed via ns so
-- UpdateColor (Nameplates.lua) can call it without adding a file-local there.
function ns.PlayerHasAggroFrom(myPlate, unit)
    local name = UnitName(unit)
    local now = GetTime()
    -- PRIMARY: pinned GUID (exact mob) - authoritative, no name fallback, so a
    -- same-named neighbour's aggro can't bleed onto a mob that ISN'T attacking you.
    -- Validate the pin like the debuff/cast paths (ns.IsPinnedGUIDStale): a stale
    -- pin from a transient wrong bind to a same-named twin would otherwise paint
    -- the twin your aggro colour while the REAL mob hits you. A stale pin falls
    -- through to the unique-name fallback below (ambiguous -> no colour).
    local pg = myPlate and myPlate.pinnedGUID
    if pg and myPlate.pinnedName == name
       and not (ns.IsPinnedGUIDStale and ns.IsPinnedGUIDStale(pg, unit)) then
        local e = aggroByGUID[pg]
        return e ~= nil and (now - e.t) <= AGGRO_TTL
    end
    -- FALLBACK: name-only, and ONLY when this is the UNIQUE visible plate of that
    -- name. Same-named mobs can't be told apart without a token; if >1 plate shares
    -- the name, the aggro colour would bleed onto neighbours not actually hitting
    -- the player. Mirror the debuff logic: ambiguous -> show nothing; a single
    -- same-named plate (or one that gets targeted/moused-over and gains a pin) is
    -- unambiguous. Health damage resolves the pin the instant any mob takes a hit.
    local n = name and aggroByName[name]
    if not (n and (now - n.t) <= AGGRO_TTL) then return false end
    if ns.unitToPlate then
        local count = 0
        for token in pairs(ns.unitToPlate) do
            if UnitName(token) == name then
                count = count + 1
                if count > 1 then return false end  -- ambiguous: don't bleed
            end
        end
    end
    return true
end

-- Re-colour every visible plate of a mob name (no-op until Nameplates has exposed
-- UpdateColor + unitToPlate, both true by the time CLEU fires in combat).
local function RecolorByName(name)
    if not (name and ns.UpdateColor and ns.unitToPlate) then return end
    for token, mp in pairs(ns.unitToPlate) do
        if mp and not mp.isPlayer and UnitName(token) == name then
            ns.UpdateColor(token)
        end
    end
end

local function RecolorAll()
    if not (ns.UpdateColor and ns.unitToPlate) then return end
    for token, mp in pairs(ns.unitToPlate) do
        if mp and not mp.isPlayer then ns.UpdateColor(token) end
    end
end

-- Subevents where a hostile is landing/attempting an attack ON the player.
local AGGRO_EVENTS = {
    SWING_DAMAGE = true, SWING_MISSED = true,
    SPELL_DAMAGE = true, SPELL_MISSED = true,
    RANGE_DAMAGE = true, RANGE_MISSED = true,
    SPELL_PERIODIC_DAMAGE = true, SPELL_PERIODIC_MISSED = true,
}

local playerGUID
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- left combat: nothing is on us
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
-- 3.3.5a CLEU payload after (self,event): timestamp, subevent, srcGUID, srcName,
-- srcFlags, destGUID, ...
frame:SetScript("OnEvent", function(_, event, _, subevent, srcGUID, srcName, _, destGUID)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not playerGUID or destGUID ~= playerGUID then return end       -- not aimed at me
        if not srcGUID or srcGUID == playerGUID or not AGGRO_EVENTS[subevent] then return end
        local now = GetTime()
        local g = aggroByGUID[srcGUID]
        local fresh = (g == nil)
        if g then g.t = now else aggroByGUID[srcGUID] = { t = now, name = srcName } end
        if srcName then
            -- Update the existing entry in place: this fires on EVERY swing/spell
            -- aimed at the player, and a fresh table per hit churned the GC in
            -- sustained combat.
            local n = aggroByName[srcName]
            if n then
                n.guid, n.t = srcGUID, now
            else
                aggroByName[srcName] = { guid = srcGUID, t = now }
            end
        end
        if fresh and srcName then RecolorByName(srcName) end  -- newly on us: colour now
    elseif event == "PLAYER_REGEN_ENABLED" then
        if next(aggroByGUID) or next(aggroByName) then
            wipe(aggroByGUID)
            wipe(aggroByName)
            RecolorAll()  -- back to normal
        end
    else
        playerGUID = UnitGUID("player")
    end
end)

-- Decay sweep: drop entries past the TTL and re-colour their plates so a mob that
-- stopped hitting you (switched target, you LoS'd it, etc.) reverts.
local accum = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if not next(aggroByGUID) then return end
    accum = accum + elapsed
    if accum < 0.5 then return end
    accum = 0
    local now = GetTime()
    for guid, e in pairs(aggroByGUID) do
        if now - e.t > AGGRO_TTL then
            aggroByGUID[guid] = nil
            local n = e.name and aggroByName[e.name]
            if n and n.guid == guid then aggroByName[e.name] = nil end
            RecolorByName(e.name)
        end
    end
end)
