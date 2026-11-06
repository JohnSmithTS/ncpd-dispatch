#!/bin/bash
# Builds phone/out/ncpd_dispatch.archive (+ .archive.xl) from messages.json.
# Needs WolvenKit.CLI (Linux console build) and the .NET 10 runtime.
set -e
cd "$(dirname "$0")"
WK=${WK:-~/tools/wolvenkit-cli/9.1.0/WolvenKit.CLI}
rm -rf build out && mkdir -p build out
python3 -I build.py messages.json build
# JSON -> CR2W next to the json files, then drop the json
"$WK" convert deserialize build/source -v Minimal
find build/source -name '*.json.json' -o -name '*.journal.json' | while read -r f; do
    case "$f" in *.json.json|*.journal.json) rm -f "$f";; esac
done
find build/source -type f
mkdir -p build/pack/ncpd_dispatch && cp -r build/source/ncpd_dispatch build/pack/ncpd_dispatch/
"$WK" pack build/pack/ncpd_dispatch -o out -v Minimal
cat > out/ncpd_dispatch.archive.xl <<'XL'
journal:
  - ncpd_dispatch\journal\ncpd_dispatch.journal
localization:
  onscreens:
    en-us: ncpd_dispatch\localization\en-us.json
XL
ls -l out
