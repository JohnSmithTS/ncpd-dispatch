# Changelog

## 0.9.2
- Fix: a call with a planned heavy could hang if a suspect got stuck. Leaving the scene didn't abandon it either.
- Fix: arrival deadlines and the "fled" timer no longer run while the game is paused (map, menus).
- Fix: loading a save drops the active call cleanly instead of tracking NPCs from the old world.
- Fix: gang-war fighters no longer get re-targeted every second.
- Fix: coming back to a scene no longer counts suspects down before they load back in.
- Tidy-up: shared navmesh helper, dead code removed, comments updated.
- Release prep: LICENSE, player README, DEVELOPING.md, release script, `GAME_DIR` for install.sh.

## 0.9.1
- The "suspects left" hint no longer fires mid-fight. Its clock starts when V reaches the scene, and the hint only shows if the nearest suspect is more than 30 m away.

## 0.9.0
- V is a runner NCPD hires, not a cop. All texts were reworded. Standing goes Freelancer → Contractor → Trusted Contractor → Preferred Contractor → Fixer-on-Call.

## 0.8.5
- The HUD caller-ID panel is gone (it didn't scale with the UI). Status lines use the game's own on-screen message, and are skipped when a phone text already says the same.
- Fix: a call no longer clears in the same frame its heavy spawns.

## 0.8.4
- A suspect who was seen and then disappears for 10 s while V is at the scene counts as down.
- "N suspects left, nearest about X m" hints.
- The heavy grace period is shorter (90 s).

## 0.8.3
- The walking-route check is advisory for call sites. It gave false "no path" results at 150 m.

## 0.8.2
- Cleared sites are detected from the vanilla quest facts.
- An unreachable learned-spot target voids the call with no penalty.

## 0.8.1
- One scene objective per site, so a call shows only its own pin.

## 0.8.0
- Calls go to the game's 114 NCPD "Assault in Progress" sites, with fixed named quest pins. Cleared sites are preferred, and gangs fit the district.

## 0.7.1
- The quest pin is removed when a call ends.
- Walking-route check for scenes. Unreachable learned spots are banned.

## 0.7.0
- Confirm or decline calls by replying in the phone. The quest objective names the call.

## 0.6.0
- GPS route and NCPD marker for calls.

## 0.5.0
- Real phone texts from the game's NCPD Dispatcher contact (ArchiveXL journal merge).

## 0.4.x
- Surprise heavies, gang wars and NCPD backup (0.4).
- Civilian victims, suspects that actively attack, and no repeat destinations (0.4.1).
- Police cover during calls (0.4.2).
- Calls are checked 4 times a second instead of every frame (0.4.3).

## 0.3
- Calls send V to a destination, and suspects spawn on arrival. Learned street spots and arrival deadlines.

## 0.2
- Dispatch calls arrive by phone: ringing, dispatcher lines, auto-answer, and settings that are remembered.
- Suspects are kept out of walls (0.2.1).

## 0.1
- Prototype.
