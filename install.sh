#!/bin/bash
# Copies the mod into the game. Keeps the in-game save (ncpd_save.json).
#  - CET Lua:      bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch/init.lua
#  - phone texts:  archive/pc/mod/ncpd_dispatch.archive(.xl)  (build with phone/build.sh)
set -e
HERE="$(dirname "$(readlink -f "$0")")"
# game folder; default: snap Steam on Linux
G="${GAME_DIR:-$HOME/snap/steam/common/.local/share/Steam/steamapps/common/Cyberpunk 2077}"
[ -d "$G/bin/x64" ] || { echo "Game not found at $G (set GAME_DIR)"; exit 1; }
DEST="$G/bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch"
mkdir -p "$DEST"
cp "$HERE/ncpd_dispatch/init.lua" "$DEST/init.lua"
cp "$HERE/phone/sites.json" "$DEST/sites.json"   # call sites (same list the archive's pins use)
echo "Installed Lua to $DEST. In game: CET overlay -> Reload all mods."
if [ -f "$HERE/phone/out/ncpd_dispatch.archive" ]; then
    mkdir -p "$G/archive/pc/mod"
    # copy to a temp name, then rename: a running game keeps reading the old
    # file instead of seeing it overwritten in place
    for f in ncpd_dispatch.archive ncpd_dispatch.archive.xl; do
        cp "$HERE/phone/out/$f" "$G/archive/pc/mod/.$f.tmp"
        mv -f "$G/archive/pc/mod/.$f.tmp" "$G/archive/pc/mod/$f"
    done
    if pgrep -f '[C]yberpunk2077\.exe' >/dev/null; then
        echo "Note: the game is running; restart it to load the new phone texts."
    fi
    echo "Installed phone texts to archive/pc/mod (needs a game restart, not just a CET reload)."
fi
