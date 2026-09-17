# TurboPlates — stock 3.3.5a backport (name-based rewrite)

TurboPlates for an **unpatched 3.3.5a (WotLK 30300)** client. **Backported by Jedborg.**

This document is the architecture map for the backport: the core problem, the
data layer that solves it, and the hard-won rules behind every subsystem. If you
touch the compat layer, read the **"Rules that bit us"** section first — most of
them are reverted-and-rediscovered the hard way.

---

## The core problem

TurboPlates was written for Ascension's modern nameplate engine, where the
client gives the addon a real **unit token** per nameplate. It then calls
`UnitName(unit)`, `UnitGUID(unit)`, `UnitHealth(unit)`, `UnitIsFriend(unit)`,
`UnitClass(unit)`, … on that token in ~110 places.

A stock, unpatched 3.3.5a client has **no nameplate unit tokens at all** (those
only exist on patched clients running AwesomeWotLK / FrostAtom, which Ascension
effectively bundles). So on a normal core, every one of those calls returns
nil/false for any plate that isn't your current target — the addon can't tell
friend from foe, read a name, a class, or health.

## The fix: a name-based data layer (the NotPlater model)

NotPlater works on stock 3.3.5a because it never uses unit tokens. It scrapes the
**name** as text from the plate's regions, reads **health** and **reaction**
(hostile/neutral/friendly/friendly-player/tapped) from the plate's health-bar
value + colour, and rebuilds class info from name-keyed caches fed by the combat
log and by your target/mouseover/group units. This backport rebuilds TurboPlates'
data layer the same way.

Rather than editing 110 call sites across 20,000 lines, the rewrite **wraps the
`Unit*` API family**. Each plate gets a stable synthetic token (`TurboPlateN`).
When TurboPlates calls a `Unit*` function with that token, the wrapper answers
from scraped regions / bars / caches; real unit tokens pass straight through
untouched, so the rest of the UI and other addons are unaffected.

The backport is concentrated in three load-first compat files plus a few small,
surgical hooks inside TurboPlates' own files:

- **`WotlkCompat_API.lua`** — pure API gap-fillers: `RunNextFrame`,
  `C_Timer`, `CreateColor`/`ColorMixin`, `WrapTextInColorCode`, `PixelUtil`,
  `Texture:SetColorTexture`, `C_CVar`, `EventRegistry`, `GetCreatureIDFromGUID`,
  the frame/texture object pools, `CombatLogGetCurrentEventInfo`, and the
  `WOW_PROJECT_*` constants. Also hardens `GameTooltip:SetSpellByID` /
  `SetHyperlink` against unknown spell ids (those crash the client natively).
- **`WotlkCompat.lua`** — the name-based nameplate engine: WorldFrame polling +
  texture-fingerprint plate discovery (NotPlater's method), region/bar scraping
  with hooks that survive TurboPlates reparenting the Blizzard bar, the match
  tracker, the wrapped `Unit*` family, `C_NamePlate` / `C_NamePlateManager`, and
  the combat-log mirrors for casts/identity.
- **`WotlkCompat_Auras.lua`** — `AuraUtil.ForEachAura` over `UnitAura`, plus
  `UnitAuras`, `UnitRole`, `UnitDetailedThreatSituation`, `UnitGetTotalAbsorbs`,
  `UnitGroupRolesAssigned(Key)`, `Ambiguate`, and the retail group APIs
  (`IsInGroup` / `IsInRaid` / `GetNumGroupMembers`).
- **`ThreatAggro.lua`** — a small standalone subsystem (see below) that restores
  threat/aggro colouring for plates the engine can't give threat data for.

All shims define a symbol only if it's missing, so the folder is harmless on a
patched client / Ascension (the native engine wins; `TurboPlatesWotlkCompat.mode`
reports `"native"` vs `"namebased-335"`).

---

## Two platforms: stock vs awesome_wotlk

`ns.IS_WOTLK_COMPAT` is true on **both** non-Ascension platforms; the real
discriminator is **`ns.HAVE_AWESOME_WOTLK`** (the FrostAtom DLL):

- **awesome_wotlk (FrostAtom DLL present).** Every managed plate carries a **real
  `nameplateN` unit token** — `frame._realToken`, set by the bridge on
  `NAME_PLATE_UNIT_ADDED`, resolving to the exact WorldFrame child we scrape. So
  `UnitGUID(_realToken)` / `UnitAura(_realToken)` are authoritative per plate.
  **Identity is exact; same-named twins are never confused.** Accessor:
  `ns.GetPlateRealToken(unit)` (nil on stock).
- **stock 3.3.5a (no DLL).** No per-plate token. Identity is a **heuristic** —
  scraped name + level + exact-health — plus combat-log mirrors for everything a
  token would otherwise provide. It is fundamentally ambiguous for identical mobs
  at the same HP, and the governing principle there is **suppress-on-ambiguity:
  showing nothing beats bleeding onto the wrong twin.**

Every per-plate feature has both paths. **The awesome_wotlk path is exact and is
treated as sacrosanct** — every stock fix is gated (`HAVE_AWESOME_WOTLK` /
`_realToken` present, or runs only after the `_realToken` branch returns) so it
can never change the working DLL behaviour.

---

## How reaction (friend/foe) is determined

Read from the default nameplate health-bar colour, like NotPlater:
hostile `{1,0,0}`, neutral `{1,1,0}`, friendly NPC `{0,1,0}`, friendly player
`{0,0.6,1}`, tapped `{0.5,0.5,0.5}`.

---

## The match tracker — establish strictly, keep leniently

`UpdateMatches` / `PlateMatchesUnit` bind a plate to a real unit (`target`,
`focus`, `mouseover`, `partyNtarget`, `raidNtarget`) so token-only data can be
read for it.

- **Establish strictly:** name + level + **exact** health picks the unique plate
  among same-named candidates. On awesome_wotlk an exact `UnitGUID(_realToken)`
  match is tried first and wins outright.
- **Keep leniently:** re-validating the strict match *every tick* caused the
  "target glow blinks on every ability" bug — the plate's scraped HP (bar
  `OnValueChanged`, C-side) and the real unit's `UnitHealth` (`UNIT_HEALTH`
  event) are briefly out of sync after each hit, so the strict match dropped for
  a tick. The keep-path uses a lenient check (`exists + name`); strict is for
  establish only. `target`/`focus`/`mouseover` changes `ReleaseMatch` first so
  they re-bind correctly among same-named mobs.
- **Full-HP ambiguity:** a non-player at full HP can't be told from a same-named
  neighbour by health. Bind it only when it's the **unique** same-named full-HP
  candidate (single-mob opener); with 2+ identical full-HP mobs, leave it unbound
  and let health resolve it the instant either takes damage. For `target` only, a
  unique full-alpha plate (engine target-dimming) is also accepted.

> ⚠️ Plate **alpha is not a reliable disambiguator** on its own — with non-target
> dimming OFF, every plate reads full alpha. It is used only as a uniqueness-gated
> tiebreak for `target`, never as the primary signal.

---

## Bind-time re-sync: `ns.OnPlateBound` (the single most important rule)

Plates **announce on show, before the match binds**. So any state computed at
`OnNamePlateAdded` from `UnitGUID(token)` used the **synthetic** GUID, and
`FullPlateUpdate` renders on show against that synthetic token. Nothing re-fires
for state that is already present (an applied aura, an existing elite
classification, standing threat — unlike health/cast which emit their own
events). That is the **root of a whole class of "X is wrong/missing until I
re-target / look away and back" bugs** — not each consumer individually.

`ns.OnPlateBound(blizzFrame, realGUID)` is called from `SetMatch` the instant a
plate binds to its real unit, and is the **single authoritative "real unit now
available" re-sync.** It refreshes **every** real-unit-dependent consumer:

- `cachedGUID` + `pinnedGUID` (and the lite container's)
- `ValidateTargetPlate` (target glow + scale)
- the plate's alpha (target dimming)
- the raid marker
- the quest tooltip scan (so mousing over a mob can *learn* an item-drop quest)
- any in-progress cast
- auras (+ the aura-driven colour override) and priority TurboDebuff
- the classification indicator and threat text

**Rule for new features:** anything keyed on the real unit/GUID must refresh in
`OnPlateBound`, not only in `FullPlateUpdate`. Keep the bind re-sync surgical —
do **not** call `FullPlateUpdate` from the bind hook (it re-runs scale/glow/Show
on every mouseover bind, a broad surface for flashes). Scraped data (name, level,
health, colour) is deliberately *not* re-synced here — it isn't unit-derived.

---

## Combat-log mirrors: casts, debuffs, threat for unbound plates

A stock client gives no auras, no cast info and no per-unit threat for any plate
that isn't bound to a real unit. The backport mirrors all three **from the combat
log**, which broadcasts events for every source in range with no unitID needed,
and resolves the plate via the identity model. (On awesome_wotlk each mirror
instead reads the exact `_realToken`, so twins are never confused.)

### Cast bars (`ProcessPlateCasts`, in `WotlkCompat.lua`)

> **Stock** 3.3.5a does **not** engine-drive the Blizzard nameplate cast bar, so
> there is nothing to scrape — an early scrape-the-bar attempt showed nothing for
> exactly this reason. We drive cast bars from the **combat log** instead (below),
> so untargeted casts *do* work on stock. *awesome_wotlk* **does** drive the bar,
> which is why we also suppress its leaking spell icon (note at the end).

`SPELL_CAST_START` fires for every caster in range with no unitID. We cache the
spell **name**, **icon** and base **cast time** (`GetSpellInfo`'s 7th return, ms),
keyed by GUID, then `ProcessPlateCasts` (every frame in the driver) renders a
**self-animating** bar via the `ns:ScrapeCast*` API — no unit, no Blizzard bar
needed. The real `SPELL_CAST_SUCCESS` / `FAILED` clears it, `SPELL_INTERRUPT`
clears the **destGUID** entry (the interrupted caster — srcGUID is the
*interrupter*, an easy trap), `UNIT_DIED` drops a dead caster's bar, and a 0.5s
grace + a periodic sweep cap a missed end event.

**Channels** never fire `SPELL_CAST_START` — they log `SPELL_CAST_SUCCESS` at
the moment channeling *begins*, and `GetSpellInfo` reports castTime 0 for them.
`WotlkCompat_Channels.lua` supplies what CLEU can't: a registry of every player
channeled spell across Classic/TBC/WotLK, keyed by **localized name** (via
`GetSpellInfo(id)`), so all ranks and same-named NPC variants resolve on any
locale. A `SPELL_CAST_SUCCESS` whose name is in the registry creates a
`channel = true` entry that renders **draining** (1 → 0). Early ends are caught
live via `SPELL_AURA_REMOVED` of the same-named aura the channel maintains (on
the recorded victim — Drain Life, Mind Flay — or on the caster itself —
Hellfire, Evocation), plus interrupt/death/timeout as above. Unknown channels
**self-teach**: when the event path sees a real channel (`UnitChannelInfo` on a
bound unit, at channel start only — pushback shortens a mid-channel read), the
exact duration is learned per name and persisted in
`TurboPlatesDB.learnedChannels`. Names that channeled in vanilla but are
instant on a 3.3.5a client (Mend Pet, wand Shoot…) are deliberately excluded —
an instant sharing a listed name would draw a phantom bar.

**Which plates the mirror drives — "matched" ≠ "event-covered".** The normal
`UNIT_SPELLCAST_*` event path only answers for `target` / `focus` / `player` /
`pet` / party-and-raid **members** — **never `mouseover`** (this is why Quartz's
Mouseover module polls `UnitCastingInfo` instead of using events) **and never
their targets.** But the match tracker also binds `mouseover` and each
`partyNtarget` / `raidNtarget` (the mob a group member is fighting). An older
gate excluded *all* matched plates from the mirror, so a plate bound to any of
those non-event units got a cast bar from **neither** path — a dead zone, worst
in dungeons/raids where every mob is some member's target, and equally on a mob
the cursor rested on (a cast *started* mid-hover never showed; an in-progress
cast picked up at bind never saw its end events, so an interrupt filled to
completion). The resolution ladder is now:

| Plate | Cast source |
|---|---|
| matched → `target` / `focus` | event path (`UNIT_SPELLCAST_*`) |
| matched → `mouseover` / `partyN` / `raidNtarget` | `castByGUID[UnitGUID(matchedUnit)]` — exact |
| unmatched, **awesome_wotlk** | `castByGUID[UnitGUID(_realToken)]` — exact |
| unmatched, **stock** | **pinned GUID only**, validated like the debuff pin (level match + `IsPinnedGUIDStale`); nothing if never pinned |

There is **no name-union** "show on all same-named" path (it bled onto every twin)
and, for casts, **no unique-name fallback** either: a stock mob you've never
targeted/moused-over simply shows no cast bar, because there's no reliable way to
tie an untargeted cast to one of several identical plates. (Debuffs *do* keep a
unique-name fallback — a debuff is persistent, so a lone same-named add still
showing its DoT is worth more than the precision a transient cast needs.)

> ⚠️ **awesome_wotlk spell-icon leak.** Because the engine drives the cast bar
> there, it re-shows the Blizzard nameplate's own spell icon (`_tpSpellIcon`)
> **C-side**, bypassing the one-time Hide hook — it leaked as a stray icon at the
> un-offset mob position (visible once the plate has an X/Y offset).
> `ProcessPlateCasts` re-hides that icon (and re-drops the bar texture) every
> frame to keep it suppressed; the texture stays readable for the icon. No-op on
> stock, where the engine never shows it.

### Debuff icons (`MergeTrackedDebuffs`, in `Auras.lua`)

Only for **unbound** plates (bound plates read `UnitAura` on the matched unit).
Player/pet debuffs are mirrored from CLEU into `cleuByGUID` (keyed by destGUID)
and merged in. Two non-obvious points:

- **Removal is more than `SPELL_AURA_REMOVED`.** A CC broken by *damage* (Sap,
  Polymorph, Gouge…) fires `SPELL_AURA_BROKEN` / `SPELL_AURA_BROKEN_SPELL`.
  `SPELL_AURA_BROKEN_SPELL` has extra spell args before `auraType`, so the
  removal path must key off `spellId` (positionally stable), never `auraType`.
- **Durations are learned** from bound `UnitAura` reads (session-persistent);
  until learned, mirrored icons are timerless. A bound read also *reconciles* —
  spellIDs `UnitAura` no longer reports are pruned from `cleuByGUID`, so looking
  at a mob self-corrects a missed removal. (Skip pet entries in reconciliation —
  `HARMFUL|PLAYER` doesn't enumerate pet auras.)

Identity ladder (stock): pinned GUID (validated not-stale) → unique-name
(`CountPlatesWithName == 1`) → nothing. Unlike casts, debuffs **keep** the
unique-name fallback: a debuff is persistent, so a lone same-named add still
showing its DoT is worth more than the wrong-twin risk a transient cast carries.

### Threat / aggro colour (`ThreatAggro.lua`)

On Ascension `UnitDetailedThreatSituation("player", plateToken)` answered for
every plate; on stock it can't resolve an unbound token, so only your target got
its threat colour. `ThreatAggro.lua` tracks "this mob is hitting the player" from
CLEU damage/miss subevents where `destGUID == playerGUID` (keyed by GUID + name,
5s decay + combat-exit wipe) and exposes `ns.PlayerHasAggroFrom`. `UpdateColor`
consults it **only when the threat API returned nil** — a real status always
wins, so a group cleave that incidentally hits you isn't mis-coloured.

Two scope rules keep this honest:

- **Only in a group/raid, or with a pet.** The fallback forces "full aggro" for
  an unbound plate, which is meaningless when nothing competes for threat — solo
  it painted every attacker the threat colour. It now applies only when there's
  actually a threat contest (party/raid or a pet), matching the threat *text*
  (already hidden solo) and awesome_wotlk. Solo with no pet, hostile mobs use the
  normal hostile colour.
- **The colour follows your role.** Tank → the "secure aggro" colour, DPS → the
  DPS aggro colour. Role is auto-detected; the stock prot-spec heuristic ("most
  points in the 3rd talent tab") is gated to the **WARRIOR** class, so a Frost
  mage / Ret paladin / etc. is no longer mis-flagged as a tank (which then painted
  every incoming hit the tank colour).

> This had to be a **new file**: `Nameplates.lua` is already at Lua 5.1's
> 200-locals-per-function limit. **Do not add top-level locals to
> `Nameplates.lua`** — put new subsystems in their own file and talk to
> Nameplates via `ns.` (`ns.UpdateColor`, `ns.unitToPlate`, …).

---

## Same-named mobs: identity invariants

Every same-named bug (debuff/cast/icon bleed, wrong target glow, stuck scale)
reduces to one question: **which nameplate is which mob?**

- **`pinnedGUID` persists across unbind.** Set in `OnPlateBound`, cleared **only**
  on recycle in Core's `OnNamePlateRemoved`, so a sapped target's debuff survives
  a look-away. **Do not add per-plate pin clearing** — it breaks the persist
  design and forces casts/debuffs back onto the bleeding name-union path. The
  sanctioned fix for a *wrong* pin is read-time **validation**
  (`ns.IsPinnedGUIDStale`): reject a pin when its GUID is claimed by another plate
  (bound elsewhere by exact-HP, or pinned on another visible plate → both
  suppress), never by clearing it.
- **awesome_wotlk is exact and sacrosanct.** Gate any new same-named logic so it's
  a no-op when `_realToken` is present.
- **Diagnose which bleed root before fixing.** A bleed via
  `UnitAura`/`UnitGUID(matchedUnit)` is a *match-tracker wrong-bind*; a bleed on
  *unbound* plates is a *CLEU name/pin* path. Different fixes.

---

## Why the plate doesn't flicker (announce, flash, pooled re-show)

Stock 3.3.5a **pools** WorldFrame nameplate children — it hides and re-shows
persistent frames, it doesn't add/remove them, and it does so **C-side, bypassing
Lua `Show`/`Hide` hooks.** Three rules keep our art clean:

- **Announce gating.** A plate is announced to Core (`FireAdded`) only once both
  its **name and reaction colour** are scraped. Colour lags name by a frame or
  two; announcing early showed friendly NPCs as full red plates (Core classifies
  friendly-vs-hostile once and never re-checks). A re-classify net re-fires
  `FireAdded` if the friendly verdict later flips (idempotent, at most once).
- **Suppress by killing content, not by Hide.** The engine restores a region's
  *visibility* C-side but refills its *content* via hookable setters. So: blank
  the Blizzard name/level FontStrings in the `SetText` **and** `SetFormattedText`
  hooks (the engine sets name via one, level via the other), and **drop the
  health-bar texture** once the reaction colour is stable (a textureless
  StatusBar can't render, while `GetValue` still scrapes). Recycled plates
  re-arm the texture to read the new occupant's reaction, then drop it again.
- **Per-frame visibility.** `ProcessPlateVisibility()` runs every frame over a
  persistent `knownPlates` set and acquires a newly-shown / releases a
  newly-hidden plate within one frame — the 0.1s scan was slow enough to flash
  the Blizzard plate first. A `CVAR_UPDATE` rescan covers the bulk show/hide when
  friendly/enemy nameplates are toggled.

## Health must be pushed from the scrape, not the engine callback

Because the reaction fix **drops the Blizzard health-bar texture**, on some
awesome_wotlk builds a textureless StatusBar stops firing `OnValueChanged` —
so the visible health froze a fraction of a second after spawn. `hb:GetValue()`
stays live, though, so `RefreshPlateScrape` pushes health from the 0.1s scrape
(`ns.UpdateNameplateHealth`) whenever the value changed. **Don't "fix" a
health-freeze by reverting the texture-drop** — that re-opens the Blizzard-bar
leak.

---

## Quest-objective icons (native detector)

Quest-objective icons are detected by a self-contained native detector in
`Nameplates.lua` (`ns.GetPlateQuestInfo`), **independent of ClassicAPI** (3.3.5a
exposes per-unit quest data poorly). Three complementary sources, in order:

1. **Tooltip scan** of the plate's real unit (target/focus/mouseover, or
   `_realToken`) — the game tooltip lists objective progress ("Purifying Earth:
   1/2") even for use-item/interact quests where the mob name never appears in
   quest text. Cross-checked against our own quest log so other addons' injected
   tooltip lines can't false-positive.
2. **Quest-log name match** against the scraped name, for unbound plates — catches
   kill/collect quests passively on every visible mob.
3. **Learned item-drop mobs** — a kill-for-item quest names the *item*, not the
   mob, so once one same-named mob is confirmed a quest target via its tooltip,
   every same-named plate is flagged (self-invalidates on completion).

> **Never use free substring matching for the name match.** "Pterrordax" is a
> substring of "Frenzied Pterrordax", which put a quest icon on the wrong mob.
> The tracked name is always at the **start** of the objective line in every
> locale ("MobName slain: x/y"), so anchor the match there (`sub(1,#name)==name`)
> with a trailing word-boundary check.

---

## ClassicAPI dependency status

Jedborg is phasing out the separate **ClassicAPI** addon. ClassicAPI loads first
and provides a large modern-retail API surface; while it's present, the compat
shims here (all gated `if type(X) ~= "function"`) **never run** — so removing
ClassicAPI exercises them for the first time. Status:

- **Self-shimmed** (work standalone): `C_Timer`, `C_CVar`, `PixelUtil`,
  `EventRegistry`, `RunNextFrame`, `CreateColor`/`ColorMixin`,
  `GetCreatureIDFromGUID`, the object pools, `CombatLogGetCurrentEventInfo`,
  group APIs, `Ambiguate`, `UnitGetTotalAbsorbs`.
- **Degrade silently if absent:** `QuestUtil` (quest-icon atlas only),
  `UnitGetIncomingHeals`.
- **No longer needed for quest objectives** — the native detector above replaced
  `C_QuestLog.GetUnitQuestInfo`; ClassicAPI is only a fallback for quest-*giver*
  (!/?) detection on non-hostile units.
- **Note:** `C_NamePlate` itself comes from the **awesome_wotlk client patch**,
  not from ClassicAPI's Lua. "Remove ClassicAPI" and "remove awesome_wotlk" are
  different things.

Two traps worth remembering: retail **XML templates** (`BackdropTemplate`) are an
easy-to-miss ClassicAPI dependency that throw on `CreateFrame` (stripped from all
call sites); and `Texture:SetAtlas(name, true)` forces the atlas's native size
and **overrides a later `SetSize`** on this client — always pass
`useAtlasSize = false` and size manually.

---

## What works, and the honest limits

**Full data for every visible plate:** name, level, current/max health, reaction
(friendly/hostile/neutral colouring, name-only friendly mode), class colour for
players once learned, **quest icons**, and **threat/aggro colouring**.

**Casts and player/pet debuffs now show on untargeted plates too**, mirrored from
the combat log — not just on your target/focus/mouseover. On **awesome_wotlk**
this is exact for every plate via `_realToken`.

**The irreducible limit** is on **stock** clients only: 2+ *identical* same-named
mobs at the same health can't be told apart without a token, so per-plate extras
are **suppressed** rather than risk bleeding onto the wrong twin. A **debuff**
still shows on the *unique* same-named plate (or one you've pinned by
targeting/mousing over); a **cast** shows only on a plate you've pinned that way —
otherwise nothing. It all resolves the instant you target/mouseover one (which
pins it) or their health diverges. This is the same ceiling every nameplate addon
hits on a stock client; installing awesome_wotlk removes it entirely (every plate
is exact, via `_realToken`).

---

## Install

Drop the `TurboPlates` folder into `Interface\AddOns\`. `/tp` opens options.
If something errors in-game, the per-plate data path is the place to look first;
note the exact Lua error and we can iterate. `/tp dumpplate` dumps a target
plate's regions + scale for diagnosis.

---

## Rules that bit us (quick reference for contributors)

1. **Never overwrite a global Blizzard `Unit*` function** — it taints secure code
   ("Interface action failed because of an AddOn", target won't clear on death).
   Wrappers live on `ns.UnitX`; each file pulls them in as locals
   (`local UnitName = ns.UnitName or UnitName`).
2. **Display data is scrape-first.** When a plate shows wrong/stale data, the fix
   is almost always "make that wrapper read the scrape, not the match" — not to
   improve matching.
3. **Re-sync real-unit state in `OnPlateBound`,** not only in `FullPlateUpdate`.
4. **The engine restores visibility C-side; suppress by killing content** (blank
   text / drop texture), not by `Hide()`/alpha.
5. **Don't add top-level locals to `Nameplates.lua`** (200-local limit) — new
   subsystems get their own file, exposed via `ns.`.
6. **`pinnedGUID` persists across unbind;** fix a wrong pin by validation, never
   by clearing it.
7. **Gate every stock fix** so it's a no-op on awesome_wotlk (`_realToken`).
8. **Diagnose which root** a same-named bleed has (match-tracker vs CLEU path)
   before fixing.

NotPlater is the reference implementation for this client:
<https://github.com/RichSteini/NotPlater> (`modules/matchTracker.lua`,
`modules/aura/*`, `NotPlater.lua` IsTarget).
