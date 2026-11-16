Forever AIO (WoW Forever, Interface 16001)
==========================================

What it does, on every character, with nothing to set up and no other addon needed:

  1. Auto-equip   Puts on gear from your bags that is an upgrade, and swaps in bigger bags.
  2. Quest reward Picks the best reward when a quest offers a choice, and completes the quest.
  3. Buff asker   Whispers nearby players for the buffs their class gives, and thanks them.

Gear is rated with the stat weights of the addon "Forever Leveling BiS" for your class, spec and level.
The numbers are built in: that addon does not have to be installed.
Credit: those stat weights are the default weights of Forever Leveling BiS by Thunder (CurseForge). The numbers
are that author's work; Forever AIO only reads them. If you like the gear picks, that addon is where they come from.

Install
-------
Copy the folder "ForeverAIO" into   World of Warcraft/_forever_/Interface/AddOns/
then start the game (or log out to the character list and back in). Type /faio to see that it runs.

Commands
--------
  /faio                         what is switched on, and this list
  /faio equip on | off | reset  auto-equip (reset = forget the items you took off by hand)
  /faio reward on | select | off
                                on = pick and complete, select = only highlight the best one, off = hands off
  /faio gear                    why each piece of gear in your bags is, or is not, being put on
  /faio spec                    which spec the gear is rated for; /faio spec <name> picks one, /faio spec auto
  /faio buffask on | preview | off
                                preview = shows the whisper only to you, sends nothing
  /faio buffask                 every buff asker option (city on|off, thanks on|off, range 15|28, <buff> on|off ...)
  /faio buffask log             what was asked and who answered

Good to know
------------
  * Spec: the talent tree with the most points. Before the first talent point: the usual levelling spec.
    Hunters in the third tree are rated as melee Survival (/faio spec survival for ranged), druids in the
    second tree as cat (/faio spec bear for tanking).
  * Hold Shift while a quest reward window opens to choose yourself.
  * Gear you take off by hand is left off. Bind-on-equip gear better than green, and trinkets when both
    trinket slots are full, are only pointed out, never put on for you.
  * A hunter's bow is not swapped for a gun (or back) until the right ammo is in the ammo slot.
  * Buff asker: everyone in reach is asked once for each buff you are missing, half a second apart. Nobody is
    asked twice for the same missing buff. Friendly player nameplates must be on to see strangers.
  * If the addon "WoWUI Tweaks" is installed and does the same job, Forever AIO lets it and stays quiet.

Updating the stat weights (on the Mac that has the project folder)
------------------------------------------------------------------
  luajit tools/flb_export.lua > ForeverAIO/Data/Weights.lua     (reads the installed Forever Leveling BiS)
  luajit tests/run.lua                                           (must end with PASS)
  ./pack.sh                                                      (makes dist/ForeverAIO.zip)
