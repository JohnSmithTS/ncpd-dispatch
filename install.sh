#!/bin/bash
# Copies the mod into CET's mods folder. Keeps the in-game save (ncpd_save.json).
set -e
G=~/snap/steam/common/.local/share/Steam/steamapps/common/"Cyberpunk 2077"
DEST="$G/bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch"
mkdir -p "$DEST"
cp "$(dirname "$0")/ncpd_dispatch/init.lua" "$DEST/init.lua"
echo "Installed to $DEST. In game: CET overlay -> Reload all mods."
