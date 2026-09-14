# TurboPlates 3.3.5a

Lightweight nameplate addon for **World of Warcraft 3.3.5a (WotLK, client 30300)**.

This is an **independent backport** of TurboPlates to a stock, unpatched 3.3.5a
core + awesome_wotlk.dll. The original TurboPlates was written for modern nameplate
engine; this fork rebuilds the data layer so it runs on a plain 3.3.5a client.
See [`BACKPORT_NOTES.md`](BACKPORT_NOTES.md) for the technical details.

## Features

- Threat-based coloring with tank/DPS/off-tank mode support
- Smooth nameplate stacking to prevent overlap
- Name display inside health bar option
- Spell highlight system with customizable glow effects
- Buff and debuff display on nameplates
- Whitelist/blacklist filtering
- Dispellable buff highlighting
- TurboDebuffs (BigDebuffs port) integration for priority aura tracking
- HHTD (Healers Have To Die) integration
- Personal Resource Bar customization
- Arena enemy numbering
- "Targeting me" indicator for arenas
- Totem nameplates with icon display modes
- Quest objective tracking on nameplates
- Execute range indicator
- Profile import/export
- Added Friendly Player/NPC detection and nameplate coloring for core/clean WotLK 3.3.5a severs
- Added Death Knight runes
- Added support and automatic detection of "Hero" class and classless servers
- Added automatic disabling for nameplate coloring by class for classless servers
- Completely reworked backend to be more light and in line with core/clean WotLK 3.3.5a API and cVars
- Completely reworked extremely aggressive supression of Blizzard's GlobalFont calls which supressed text on custom UI elements
- Reworded nameplate positioning system to match Blizzard's
- Added Sliders for nameplate X/Y offset
- Added Automatic scaling of nameplates using Blizzard engine
- Added distance calculation engine which calculates distance between player - target and positions nameplate based on distance 

## Installation

1. Download and extract into `Interface\AddOns\`
2. Rename the folder to `TurboPlates` (remove the version suffix)
3. Restart the game

## Usage

Type `/tp` or `/turboplates` to open the options panel, or use the minimap button.

## Configuration

Settings are organized into tabs:

- **General** — Friendly plates, PvP options and more
- **Nameplate Style** — Dimensions, textures, scale etc.
- **Nameplate Texts** — Font, name format, health values, level display
- **Colors** — Health, threat, tank mode colors
- **Castbars** — Castbar appearance and highlight spells
- **Debuffs/Buffs** — Aura filtering and display
- **Personal Bar** — Your own nameplate settings
- **Resources** — Combo Points / DK Runes Style and colors
- **TurboDebuffs** — Priority debuff tracking
- **Plate Stacking** — Overlap prevention settings
- **Profiles** — Import/export configuration

## Bundled libraries

- LibStub
- CallbackHandler-1.0
- LibCustomGlow-1.0
- LibDeflate
- AceSerializer-3.0
- LibSharedMedia-3.0

## Credits & license

TurboPlates is released under the [MIT License](LICENSE).

- Original **TurboPlates** by Miko ([esurm](https://github.com/esurm)) — © 2026.
- **3.3.5a stock + awesome_wotlk backport** by Jedborg 
- Rework and new features by Vupp

The MIT license requires the original copyright notice to be kept; it is
retained in [`LICENSE`](LICENSE) alongside the backport copyright.

## Disclaimer / non-affiliation

This is an unofficial, independent fork maintained separately for the stock
3.3.5a client. It is **not affiliated with, endorsed by, sponsored by, or
supported by** the original TurboPlates author. Please
do **not** direct support requests for this backport to the original developer —
[open an issue here](../../issues) instead. All trademarks and original work
belong to their respective owners.
