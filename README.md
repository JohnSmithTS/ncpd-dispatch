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
- **Ranks:** Patrol Officer → Senior Officer (60) → Sergeant (150) → Detective (300) → Lieutenant (600).

## Requirements

Game patch 2.5 with CET 1.38.1+, RED4ext 1.31+, Codeware 1.21+. ArchiveXL and TweakXL are installed but not used yet.

## Install / develop

```
./install.sh     # copies ncpd_dispatch/init.lua into CET's mods folder (keeps the save)
./uninstall.sh   # removes the mod including its save
```

The installer assumes snap Steam on Linux (`~/snap/steam/common/.local/share/Steam`). In game, open the CET overlay and click "Reload all mods".

## Notes for contributors (human or agent)

- **Debugging:** the log is `bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch/ncpd_dispatch.log`. Every risky game call is wrapped in `pcall` and logs its failure, so in-game problems can be diagnosed from that log.
- **Navmesh:** use `Game.GetNavigationSystem():GetNearestNavmeshPointBelowOnlyHumanNavmesh` (`GetAINavigationSystem` did not work). The navmesh only exists near V.
- **Checking API names:** check names before using them. Look in `red4ext/plugins/Codeware/Scripts/*.reds`, or run `grep -a` on `r6/cache/final.redscripts`.
- **Syntax:** no Lua interpreter is assumed. At minimum, check that blocks balance and that local functions are defined before use.
- **Known open items:**
  - real phone SMS (would need a WolvenKit journal plus ArchiveXL)
  - a "lighter scenes" option for CPU-bound systems
  - NPC patrol routes (world-node data; not reachable from Lua)
- **Conventions:** keep new features additive and toggleable in the ImGui window. Settings live in `NCPD.save` and persist.
