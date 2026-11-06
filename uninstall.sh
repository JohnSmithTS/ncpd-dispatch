#!/bin/bash
# game folder; default: snap Steam on Linux
G="${GAME_DIR:-$HOME/snap/steam/common/.local/share/Steam/steamapps/common/Cyberpunk 2077}"
[ -d "$G/bin/x64" ] || { echo "Game not found at $G (set GAME_DIR)"; exit 1; }
rm -rf "$G/bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch"
rm -f "$G/archive/pc/mod/ncpd_dispatch.archive" "$G/archive/pc/mod/ncpd_dispatch.archive.xl"
echo "Removed (standing and settings included)."
