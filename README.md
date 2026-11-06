# NCPD Dispatch

A Cyberpunk 2077 mod that puts V on NCPD's call list. NCPD is short-handed and pays runners to deal with crimes in progress. Go available, take calls from the NCPD Dispatcher on your phone, follow the GPS to the scene, deal with the suspects, and get paid. Your standing with the precinct grows as you go.

> **Beta (v0.9.x).** Playable and tested in game on Linux (Proton), but still in progress: the answer/decline hotkeys, surprise heavies and pausing mid-call haven't been fully tested with the current version, and it hasn't been tried on Windows yet. Please [open an issue](https://github.com/JohnSmithTS/ncpd-dispatch/issues) with `ncpd_dispatch.log` (in the mod's CET folder) if something goes wrong.

## Features

- **Dispatch by phone.** The phone rings, and the call arrives as a text from the game's own **NCPD Dispatcher** contact. Reply "I'm on it." or decline, in the phone or with hotkeys. If you don't reply within 45 seconds, the job goes to someone else.
- **Real NCPD sites.** Calls go to the game's 114 "Assault in Progress" locations in Night City and the Badlands. Sites where you've already cleared the vanilla crime are preferred. The gang fits the district.
- **GPS and quest tracker.** Each call is a tracked contract with an NCPD map pin and a route.
- **Scenes.** Armed robberies, gang assaults and shootouts, with civilians caught in the middle. Later you'll also get gang wars between two rival gangs, surprise heavies who show up mid-fight, and NCPD backup on big calls.
- **Pay and standing.** Each call pays, with bonuses for taking suspects alive, saving civilians, downing a heavy or catching a gang war mid-fight. Standing goes Freelancer → Contractor → Trusted Contractor → Preferred Contractor → Fixer-on-Call, and unlocks tougher calls along the way.
- **Police cover.** NCPD doesn't put a wanted level on you while you're working one of their scenes.
- Everything can be switched on or off in the mod's window in the CET overlay.

## Requirements

- Cyberpunk 2077, patch 2.x (tested with Phantom Liberty installed)
- [Cyber Engine Tweaks](https://www.nexusmods.com/cyberpunk2077/mods/107) 1.38.1+
- [RED4ext](https://www.nexusmods.com/cyberpunk2077/mods/2380) 1.31+
- [Codeware](https://www.nexusmods.com/cyberpunk2077/mods/7780) 1.21+
- [ArchiveXL](https://www.nexusmods.com/cyberpunk2077/mods/4198) 1.28+

## Install

Download the release zip and extract it into the game folder (the one that contains `bin` and `archive`). It adds:

```
bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch/init.lua
bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch/sites.json
archive/pc/mod/ncpd_dispatch.archive
archive/pc/mod/ncpd_dispatch.archive.xl
```

Mod managers (Vortex, MO2) can install the zip as is.

To update, extract the new zip over the old files. Your standing and settings are kept in the mod folder.

## How to play

1. Open the CET overlay and bind the four NCPD Dispatch hotkeys (Bindings tab):
   - **Toggle NCPD duty**: be available for calls, or not.
   - **Request NCPD call now**: don't wait for the next call.
   - **Answer / confirm NCPD call**: answer the ringing phone, then take the job.
   - **Decline NCPD call**
2. Press **Toggle NCPD duty**. A call comes in every few minutes (4 by default; you can change this). Auto-answer is on by default, so the dispatch text just arrives.
3. Reply in the phone, or use the hotkeys. Once you accept, follow the GPS. Suspects show up when you get close.
4. Clear the scene. If you leave once it's under way, or arrive too late, you lose a bit of standing.

The **NCPD Dispatch** window in the CET overlay shows your standing and the active call, and has every setting: call frequency, auto-answer, heavies and their chance, gang wars, civilians, backup, police cover, phone texts, GPS and the NCPD icon.

## Uninstall

Delete the `ncpd_dispatch` folder from `bin/x64/plugins/cyber_engine_tweaks/mods/`, and `ncpd_dispatch.archive` and `ncpd_dispatch.archive.xl` from `archive/pc/mod/`. Removing the folder also removes your standing and settings.

## Known issues

- If a site's quest pin doesn't appear within a few seconds, the call uses a plain map pin instead (no GPS route), and that site isn't offered again that session.
- If a suspect gets stuck somewhere you can't reach, the rest count as fled after a minute without progress (90 seconds with a heavy), and you get reduced pay.
- Busy scenes can be heavy on the CPU.

Problems? The mod writes a log at `bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch/ncpd_dispatch.log`. Please attach it to bug reports.

## Credits

- psiberx for Codeware and ArchiveXL, and the CET team for Cyber Engine Tweaks
- The WolvenKit team (used to build the archive)
- andreaolivato/cyberpunk-codes, `docs/map-pins-playbook.md`, for how quest map pins resolve

Building from source and how the mod works: [DEVELOPING.md](DEVELOPING.md). Version history: [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).
