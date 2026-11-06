#!/bin/bash
G=~/snap/steam/common/.local/share/Steam/steamapps/common/"Cyberpunk 2077"
rm -rf "$G/bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch"
rm -f "$G/archive/pc/mod/ncpd_dispatch.archive" "$G/archive/pc/mod/ncpd_dispatch.archive.xl"
echo "Removed (rank/rep save included)."
