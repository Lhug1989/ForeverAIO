# Forever AIO

An addon for **WoW Forever** (Interface 16001). Works on every character, with nothing to set up and no other addon needed.

**Download:** [ForeverAIO.zip](https://github.com/Lhug1989/ForeverAIO/releases/latest/download/ForeverAIO.zip) (one click, always the newest version)

## What it does

1. **Auto-equip**: puts on gear from your bags that is an upgrade, and swaps in bigger bags.
2. **Quest rewards**: picks the best reward when a quest offers a choice, and completes the quest.
3. **Buff asker**: whispers nearby players for the buffs their class gives, and thanks them.

Gear is rated for your class, spec and level. Everything is on by default.

## Install

1. Download the zip with the link above.
2. Unzip it into `World of Warcraft/_forever_/Interface/AddOns/` (you should end up with a folder `AddOns/ForeverAIO`).
3. Start the game and type `/faio`.

## Commands

| Command | What it does |
|---|---|
| `/faio` | shows what is switched on, and the list of commands |
| `/faio equip on` / `off` / `reset` | auto-equip (`reset` forgets the items you took off by hand) |
| `/faio reward on` / `select` / `off` | pick and complete / only highlight the best one / hands off |
| `/faio gear` | why each piece of gear in your bags is, or is not, being put on |
| `/faio spec` | which spec the gear is rated for (`/faio spec <name>` picks one, `/faio spec auto` goes back) |
| `/faio buffask on` / `preview` / `off` | the buff asker (`preview` shows the whisper only to you) |
| `/faio buffask` | every buff asker option |
| `/faio buffask log` | what was asked and who answered |

## Good to know

- Spec: the talent tree with the most points; before the first talent point, the usual levelling spec.
- Hold **Shift** while a quest reward window opens to choose yourself.
- Gear you take off by hand is left off. Bind-on-equip gear better than green is only pointed out, never bound for you.
- A hunter's bow is not swapped for a gun (or back) until the right ammo is in the ammo slot.
- Buff asker: everyone in reach is asked once for each buff you are missing. Nobody is asked twice for the same missing buff. Friendly player nameplates must be on to see strangers.

## Credit

The stat weights are the default weights of the addon **Forever Leveling BiS** by Thunder (on CurseForge). Those numbers are that author's work; Forever AIO only reads them. If you like the gear picks, that addon is where they come from.
