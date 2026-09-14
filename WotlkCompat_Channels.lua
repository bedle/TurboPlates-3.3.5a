--[[----------------------------------------------------------------------------
    TurboPlates - channeled-spell registry for the combat-log cast mirror
    (Backported by Jedborg)

    Channeled spells never fire SPELL_CAST_START - they log SPELL_CAST_SUCCESS
    at the MOMENT channeling begins, and GetSpellInfo reports castTime = 0 for
    them. So the CLEU cast mirror (WotlkCompat.lua) cannot derive "this is a
    channel" or its duration the way it does for normal casts; it needs a
    lookup. This file provides it:

      * a SEED table of every player channeled spell across Classic / TBC /
        WotLK (one representative spell id each; the map is keyed by the
        LOCALIZED NAME via GetSpellInfo, so all ranks AND the countless NPC
        variants that share the name - "Drain Life", "Arcane Missiles",
        "Mind Flay", "Blizzard"... - are covered automatically, on any locale)
      * LEARNING: whenever the event path sees a real channel on a bound unit
        (UnitChannelInfo in Castbars.lua gives the exact duration), the name is
        (re-)learned and persisted in TurboPlatesDB.learnedChannels - so
        encounter-specific NPC channels that aren't seeded here teach
        themselves the first time anyone targets the caster.

    Same trade-off as LibClassicCasterino's channeledSpells table (the
    reference solution for token-less channel bars on old clients): durations
    are per NAME, so rank differences show a slightly-off bar until the exact
    duration is learned; the real end signals (aura removed / interrupt /
    death / the grace sweep) still clear it correctly.
------------------------------------------------------------------------------]]

local addonName, ns = ...

local GetSpellInfo = GetSpellInfo
local floor = math.floor

-- Representative spell id -> base channel duration (seconds). Rank 1 ids where
-- possible (guaranteed present in the 3.3.5a DBC); the NAME covers all ranks.
-- Deliberately EXCLUDED: anything that is instant on a 3.3.5a client even if
-- it channeled in vanilla (Mend Pet, Starshards, wand Shoot...) - a name in
-- this table turns EVERY SPELL_CAST_SUCCESS of that name into a channel bar,
-- so an instant spell sharing the name would draw a phantom bar.
local CHANNEL_SEEDS = {
    -- Druid
    [16914] = 10,  -- Hurricane
    [740]   = 8,   -- Tranquility
    -- Hunter
    [1510]  = 6,   -- Volley
    [1002]  = 60,  -- Eyes of the Beast
    [6197]  = 60,  -- Eagle Eye
    -- Mage
    [5143]  = 5,   -- Arcane Missiles (r1 is 3s; max rank 5s - learning corrects)
    [10]    = 8,   -- Blizzard
    [12051] = 8,   -- Evocation
    -- Priest
    [15407] = 3,   -- Mind Flay
    [48045] = 5,   -- Mind Sear
    [47540] = 2,   -- Penance
    [64843] = 8,   -- Divine Hymn
    [64901] = 8,   -- Hymn of Hope
    [605]   = 60,  -- Mind Control (ends early via its aura removal)
    [2096]  = 60,  -- Mind Vision
    -- Warlock
    [689]   = 5,   -- Drain Life
    [5138]  = 5,   -- Drain Mana
    [1120]  = 15,  -- Drain Soul
    [755]   = 10,  -- Health Funnel
    [1949]  = 15,  -- Hellfire
    [5740]  = 8,   -- Rain of Fire
    -- Death Knight
    [42650] = 4,   -- Army of the Dead
    -- Racials / professions / items
    [20577] = 10,  -- Cannibalize (undead mobs channel it too)
    [746]   = 8,   -- First Aid (every bandage shares the name)
    [13278] = 4,   -- Gnomish Death Ray
}

-- name -> duration. Seeded now, refined by learning below.
local channelByName = {}
for id, dur in pairs(CHANNEL_SEEDS) do
    local name = GetSpellInfo(id)
    if name and (not channelByName[name] or channelByName[name] < dur) then
        channelByName[name] = dur
    end
end

-- Consulted by the CLEU mirror on every SPELL_CAST_SUCCESS (plain table read).
function ns.GetChannelDuration(spellName)
    return spellName and channelByName[spellName] or nil
end

-- Learn/refresh a channel duration from a real UnitChannelInfo read (the event
-- path in Castbars.lua). Persisted per spell NAME in TurboPlatesDB so an NPC
-- channel seen once is known in every later session. The caller guards against
-- mid-channel reads (pushback shortens endTime, which would mistime the bar).
function ns.NoteChannelDuration(spellName, duration)
    if type(spellName) ~= "string" or type(duration) ~= "number" then return end
    if duration <= 0 or duration > 300 then return end
    duration = floor(duration * 10 + 0.5) / 10
    if channelByName[spellName] == duration then return end
    channelByName[spellName] = duration
    if TurboPlatesDB then
        if type(TurboPlatesDB.learnedChannels) ~= "table" then
            TurboPlatesDB.learnedChannels = {}
        end
        TurboPlatesDB.learnedChannels[spellName] = duration
    end
end

-- Merge previously learned durations once SavedVariables are available.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")
    local learned = TurboPlatesDB and TurboPlatesDB.learnedChannels
    if type(learned) == "table" then
        for nm, dur in pairs(learned) do
            if type(nm) == "string" and type(dur) == "number"
               and dur > 0 and dur <= 300 then
                channelByName[nm] = dur
            end
        end
    end
end)
