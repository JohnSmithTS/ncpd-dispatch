# Developing NCPD Dispatch

The mod has two parts:

- `ncpd_dispatch/init.lua`: the Cyber Engine Tweaks Lua mod (calls, scenes, pay, the overlay window). It needs Codeware for `DynamicEntitySystem`.
- `phone/`: the generator for `ncpd_dispatch.archive`, which ArchiveXL loads. The archive holds the phone texts, the "NCPD Dispatch" quest with its objectives and map pins, and the localization.

## Layout

```
ncpd_dispatch/init.lua   the CET mod
phone/messages.json      texts, replies, quest and objective text (edit this)
phone/sites.json         the 114 call sites, extracted from the game (committed)
phone/build.py           messages.json + sites.json -> WolvenKit JSON
phone/build.sh           build.py, then WolvenKit deserialize + pack -> phone/out/
phone/extract_sites.py   game files -> sites.json (only after a game patch)
install.sh / uninstall.sh  copy into / remove from a local game install
release.sh               build dist/ncpd-dispatch-<version>.zip
```

## Build, install, release

```
phone/build.sh     # phone/out/ncpd_dispatch.archive(.xl)
./install.sh       # Lua + sites.json into CET's mods folder (keeps the save), archive into archive/pc/mod
./uninstall.sh     # removes the mod, including its save
./release.sh       # dist/ncpd-dispatch-<version>.zip, laid out like the game folder
```

`build.sh` needs the WolvenKit CLI (`WolvenKit.CLI`) and the .NET runtime it requires. Set `WK=` to its path; the default is `~/tools/wolvenkit-cli/9.1.0/WolvenKit.CLI`.

`install.sh` and `uninstall.sh` find the game through `GAME_DIR`. The default is the snap Steam path on Linux. Example: `GAME_DIR="/path/to/Cyberpunk 2077" ./install.sh`.

Lua changes load with CET overlay → "Reload all mods". Archive changes need a game restart. Never overwrite files in `archive/pc/mod` in place while the game is running: the game keeps reading the open file. `install.sh` copies to a temporary name and renames.

The version lives in `NCPD.version` in `init.lua`. `release.sh` reads it from there.

## How it works

### Calls
1. **Ring.** On duty, a call comes in every `dispatchEvery` seconds (not during combat). `prepareCall` picks the site, gang and call type, plus any heavy, victims and backup.
2. **Offer.** Answering sends the dispatch text with the reply choices. Nothing goes on the map until the player accepts, either in the phone or with the hotkeys / overlay. After 45 s with no reply, the call passes.
3. **En route.** `dispatchCall` activates the quest objectives and pin and sets the arrival deadline.
4. **Scene.** When V is within 150 m, `spawnScene` places the scene on the navmesh and spawns the suspects with tag `NCPDDispatch`.
5. **End.** `updateCall` (4 times a second) counts suspects down and ends the call as cleared, late, abandoned or void (no penalty).

### Call sites
The calls use the game's own NCPD "Assault in Progress" sites (GangWatch POIs). `phone/extract_sites.py` writes them to `phone/sites.json`; see its header for how to unbundle the inputs.

- **Cleared check.** A site counts as cleared when one of its vanilla quest facts (`..._finished`; names vary per site) is set, read with `QuestsSystem.GetFactStr`. 112 of 114 sites have one. The POI's journal state doesn't track completion.
- **Gangs.** The gang comes from the district list in `DISTRICT_GANGS`. 15% of calls ignore the list.
- **Fallback.** With no site in range, calls go to learned street spots (below) and use a plain map pin.

### Quest, objectives and map pins
The archive adds a Contract quest, `quests/minor_activities/ncpd_dispatch_call`. Each call activates two objectives in its `call` phase:

- **`respond_<type>_<gang>[_<rival>]`** names the call ("Contract: armed robbery, Animals") and has no pin. There are 80 of these.
- **`scene_<site id>`** ("Get to the scene: Kabuki") holds the site's pin, `site_<site id>`. This one is tracked for GPS and distance.

Some engine behaviour behind this design:

- **One objective per site.** An active objective shows every pin under it, so sites can't share an objective.
- **Pins can't move.** A quest pin's position is fixed: ArchiveXL resolves it once, as anchor node + offset, when the pin entry is activated, and `SetMappinPosition` has no effect. That is why calls go to fixed sites.
- **Anchor node.** Every pin references `#coyote_performance_test`, a base-game node in the always-loaded sector `always_loaded_0`, with offset = site − anchor. A pin with no node reference is never spawned.
- **Activating and removing.** The mod sets the pin entry Active itself (an Inactive pin is never spawned) and switches its icon to `Zzz06_NCPDGigVariant`. When the call ends it unregisters the pin by id, because switching the objective off doesn't remove a registered pin.
- **Debugging pins.** ArchiveXL logs each pin in `red4ext/plugins/ArchiveXL/ArchiveXL-*.log` (`Cooked mappin ... resolved`). The pin hash is Murmur3-32, seed `0x5EEDBA5E`, over the journal path.

Background: andreaolivato/cyberpunk-codes, `docs/map-pins-playbook.md`.

### Phone texts and replies
`phone/build.py` writes a journal whose root is `contacts/ncpd_dispatcher/ncpd_dispatch_calls`. ArchiveXL's `journal:` merges it into the base game's NCPD Dispatcher contact.

- **Text keys.** Text values are plain keys. ArchiveXL hashes them to match each onscreen localization entry's `secondaryKey`.
- **Templates.** Per-gang templates in `messages.json` expand `{gang}` (slug) and `{Gang}` (name).
- **Sending.** `NCPD.sendText(id)` sets the message Inactive, then Active with a notification (`JournalManager.ChangeEntryState`), so a text can be sent again.
- **Replies.** The reply choices are the group `reply` (`accept` / `decline`). Picking one in the phone sets it Succeeded and the other Inactive (`MessengerDialogViewController.ActivateReply`). The mod polls `GetEntryState`.
- **Adding a text.** Add it to `messages.json` and call it from Lua; the ids must match. Promotion texts are `promo_<standing slug>`.

### Scene placement and routes
`Game.GetNavigationSystem():GetNearestNavmeshPointBelowOnlyHumanNavmesh` snaps points to walkable ground (`snap()` in `init.lua`). `GetAINavigationSystem` did not work. The navmesh only exists near V, so scenes are placed when V is within 150 m.

`CalculatePathOnlyHumanNavmesh` checks for a walking route. At 150 m it gives false "no path" results, so for call sites it is only logged. For learned-spot targets an unreachable spot is banned (`ncpd_spots_banned.json`). The call then moves to a reachable learned spot nearby, or is voided with no penalty.

### Learned street spots
Every 20 s, the walkable point under V is recorded in `ncpd_spots.json` (at most one per 50 m cell). These are only the fallback destinations when no site is in range.

### Police cover
During a scene the prevention system is switched off under the source `NCPDDispatch` (`TogglePreventionSystem`), the way quests do it. It is switched back on, and heat is cleared, when the call ends, on CET shutdown, and at the start of each session or save load.

### Save loads
`PlayerPuppet.OnGameAttached` fires each time the player is spawned into a world. The mod then drops any active call (its NPCs and pins are gone with the old world), and the next update re-runs the session checks.

### Files the mod writes (in its CET folder)
- `ncpd_save.json`: standing, stats, settings
- `ncpd_spots.json`, `ncpd_spots_banned.json`: learned spots and bans
- `ncpd_dispatch.log`: the log

## Conventions
- **Debugging:** every risky game call is wrapped in `pcall` and logs its failure, so in-game problems can be diagnosed from `ncpd_dispatch.log`. On Linux/Proton the log can lag while the game is running; read it again after quitting.
- **Checking API names:** check names before using them. Look in `red4ext/plugins/Codeware/Scripts/*.reds`, or run `grep -a` on `r6/cache/final.redscripts`.
- **Syntax:** without a Lua interpreter, at least check that blocks balance and that local functions are defined before they are used.
- **New features:** keep them additive and toggleable in the ImGui window. Settings live in `NCPD.save` and persist.

## Open ideas
- a "lighter scenes" option for CPU-bound systems
- NPC patrol routes (world-node data; not reachable from Lua)
- `OpenWorldSystem` (Codeware) might be able to trigger the game's own NCPD activities
