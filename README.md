# GrindStats

A lightweight session tracker for **WoW Ascension** (WotLK 3.3.5). Shows XP/hour, gold/hour, kills, looted gold, and estimated time-to-level while you grind.

## Features

- Session timer with pause/resume
- XP gained and XP per hour
- Estimated time to next level
- Kill count, XP per kill, and kills to level
- Net gold change and looted gold (from mobs/chests)
- Gold per hour
- Draggable window — position is saved per character

## Installation

1. Download or clone this repo.
2. Copy the `GrindStats` folder into your WoW `Interface/AddOns` directory:
   ```
   .../Interface/AddOns/GrindStats/
   ```
3. Restart WoW or type `/reload`.
4. Enable **GrindStats** on the character select screen (AddOns list).

## Slash commands

| Command | Description |
|---------|-------------|
| `/gs` | Show help |
| `/gs reset` | Restart the current session |
| `/gs pause` | Pause or resume the timer |
| `/gs show` | Show the tracker window |
| `/gs hide` | Hide the tracker window |

## Compatibility

- **Interface:** 30300 (WotLK 3.3.5)
- **Client:** Ascension

## License

MIT — use and modify freely.
