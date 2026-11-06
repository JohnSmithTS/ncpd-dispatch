#!/bin/bash
# Builds dist/ncpd-dispatch-<version>.zip, laid out like the game folder so
# players (or Vortex / MO2) can extract it straight into Cyberpunk 2077/.
# Needs the archive built first: phone/build.sh
set -e
cd "$(dirname "$(readlink -f "$0")")"
VERSION=$(sed -n 's/^ *version = "\([^"]*\)",.*/\1/p' ncpd_dispatch/init.lua | head -1)
[ -n "$VERSION" ] || { echo "NCPD.version not found in init.lua"; exit 1; }
for f in phone/out/ncpd_dispatch.archive phone/out/ncpd_dispatch.archive.xl; do
    [ -f "$f" ] || { echo "$f missing: run phone/build.sh first"; exit 1; }
done
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "Warning: uncommitted changes; the zip may not match a commit."
fi
STAGE=dist/stage
rm -rf "$STAGE" && mkdir -p "$STAGE"
MOD="$STAGE/bin/x64/plugins/cyber_engine_tweaks/mods/ncpd_dispatch"
mkdir -p "$MOD" "$STAGE/archive/pc/mod"
# only the files the game needs: no save, spots, bans or logs
cp ncpd_dispatch/init.lua phone/sites.json "$MOD/"
cp phone/out/ncpd_dispatch.archive phone/out/ncpd_dispatch.archive.xl "$STAGE/archive/pc/mod/"
cp README.md LICENSE CHANGELOG.md "$MOD/"
OUT="dist/ncpd-dispatch-$VERSION.zip"
rm -f "$OUT"
python3 -I -c '
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in sorted(os.walk(stage)):
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, stage))
' "$STAGE" "$OUT"
rm -rf "$STAGE"
python3 -I -m zipfile -l "$OUT"
echo "Built $OUT"
