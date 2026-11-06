# NCPD Dispatch

A Cyberpunk 2077 mod (Cyber Engine Tweaks Lua + Codeware) that gives V an NCPD career: go on duty, get dispatch calls by phone, drive to generated crime scenes built from the game's own NPC records, and earn eddies, reputation and ranks.

## Features (v0.4.3)

- **Phone dispatch:** ringing with the game's phone sounds, a caller-ID HUD panel, and dispatcher lines with direction and distance. Auto-answer, or answer/decline hotkeys.
- **Destinations:** 150–400 m away on foot, 400–1200 m in a vehicle. Suspects spawn when V is within 150 m. Each call has an arrival deadline.
- **Learned street spots:** a walkable point near V is sampled every 20 s (at most one per 50 m cell) into `ncpd_spots.json`. These are used as destinations, and the last 6 are avoided.
- **Scenes:**
  - robbery, assault and "shots fired" calls, with civilian victims the suspects attack
  - surprise heavies (Elite/Officer/Boss records)
  - gang wars (two rival factions fighting each other)
  - NCPD backup officers at higher ranks
- **Police cover:** the prevention system is switched off under the source `NCPDDispatch` while a scene is active. Heat is cleared when the call ends, and police are re-enabled at shutdown and on each session start.
- **Phone texts:** dispatch, result, promotion and warning texts come from the base game's **NCPD Dispatcher** contact, in a conversation named "NCPD Dispatch" (`phone/`, 46 messages).
- **Ranks:** Patrol Officer → Senior Officer (60) → Sergeant (150) → Detective (300) → Lieutenant (600).

## Requirements

Game patch 2.5 with CET 1.38.1+, RED4ext 1.31+, Codeware 1.21+ and ArchiveXL 1.28+ (for the phone texts). TweakXL is installed but not used yet.

## Install / develop

```
phone/build.sh   # builds phone/out/ncpd_dispatch.archive(.xl) from phone/messages.json
./install.sh     # copies init.lua into CET's mods folder (keeps the save) and the archive into archive/pc/mod
./uninstall.sh   # removes the mod including its save
```

The installer assumes snap Steam on Linux (`~/snap/steam/common/.local/share/Steam`). In game, open the CET overlay and click "Reload all mods".

## Phone texts

Messages are defined in `phone/messages.json`. Per-gang templates expand `{gang}`/`{Gang}` for each entry in `gangs`.

`phone/build.py` generates WolvenKit JSON for two files:
- a journal whose root is `contacts/ncpd_dispatcher/ncpd_dispatch_calls`, which ArchiveXL's `journal:` merges into the base game's NCPD Dispatcher contact
- an onscreen localization file

Text values are plain keys, which ArchiveXL hashes to match each localization entry's `secondaryKey`.

`phone/build.sh` converts and packs the files. It needs WolvenKit.ConsoleLinux (default path `~/tools/wolvenkit-cli/9.1.0`, override with `WK=`) and the .NET 10 runtime.

At runtime, `NCPD.sendText(id)` sets the message to Inactive, then back to Active with a notification, using `JournalManager.ChangeEntryState`. Repeat sends work; this was tested in game. Archive changes need a game restart, not just a CET reload.

After you add a message, also call it from Lua. The ids used in Lua and the ids in `messages.json` must match.

## Notes for contributors (human or agent)

- **Debugging:** the log is `bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch/ncpd_dispatch.log`. Every risky game call is wrapped in `pcall` and logs its failure, so in-game problems can be diagnosed from that log.
- **Navmesh:** use `Game.GetNavigationSystem():GetNearestNavmeshPointBelowOnlyHumanNavmesh` (`GetAINavigationSystem` did not work). The navmesh only exists near V.
- **Checking API names:** check names before using them. Look in `red4ext/plugins/Codeware/Scripts/*.reds`, or run `grep -a` on `r6/cache/final.redscripts`.
- **Syntax:** no Lua interpreter is assumed. At minimum, check that blocks balance and that local functions are defined before use.
- **Known open items:**
  - a "lighter scenes" option for CPU-bound systems
  - NPC patrol routes (world-node data; not reachable from Lua)
- **Conventions:** keep new features additive and toggleable in the ImGui window. Settings live in `NCPD.save` and persist.
