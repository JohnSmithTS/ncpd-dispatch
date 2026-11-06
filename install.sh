#!/bin/bash
# Copies the mod into the game. Keeps the in-game save (ncpd_save.json).
#  - CET Lua:      bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch/init.lua
#  - phone texts:  archive/pc/mod/ncpd_dispatch.archive(.xl)  (build with phone/build.sh)
set -e
HERE="$(dirname "$(readlink -f "$0")")"
G=~/snap/steam/common/.local/share/Steam/steamapps/common/"Cyberpunk 2077"
DEST="$G/bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch"
mkdir -p "$DEST"
cp "$HERE/ncpd_dispatch/init.lua" "$DEST/init.lua"
echo "Installed Lua to $DEST. In game: CET overlay -> Reload all mods."
if [ -f "$HERE/phone/out/ncpd_dispatch.archive" ]; then
    mkdir -p "$G/archive/pc/mod"
    cp "$HERE/phone/out/ncpd_dispatch.archive" "$HERE/phone/out/ncpd_dispatch.archive.xl" "$G/archive/pc/mod/"
    echo "Installed phone texts to archive/pc/mod (needs a game restart, not just a CET reload)."
fi
