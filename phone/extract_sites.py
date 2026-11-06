#!/usr/bin/env python3
r"""Extract the game's own NCPD "Assault in Progress" sites into sites.json.

These are the call locations: outdoor street-fight areas the game designed,
spread over Night City and the Badlands. The result is committed, so normal
builds don't need the game files. Re-run only after a game patch.

Inputs are WolvenKit JSON (convert serialize) of the files the game actually
uses. With Phantom Liberty installed, those come from archive/pc/ep1/:
  ep1_1_nightcity.archive -> base/worlds/03_night_city/_compiled/default/03_night_city.poimappins
  ep1_2_gamedata.archive  -> base/journal/cooked_journal.journal  (PL's copy of the base journal)
                             ep1/journal/cooked_journal.journal
and, for the anchor check, basegame_3_nightcity.archive ->
  base/worlds/03_night_city/_compiled/default/always_loaded_0.streamingsector

  WK=~/tools/wolvenkit-cli/9.1.0/WolvenKit.CLI
  $WK unbundle "$G/archive/pc/ep1/ep1_1_nightcity.archive" -o x -w '*.poimappins'
  $WK unbundle "$G/archive/pc/ep1/ep1_2_gamedata.archive"  -o x -w '*.journal'
  $WK convert serialize <each file>
  python3 -I extract_sites.py sites.json <poimappins.json> <journal.json> [<journal.json> ...] \
      [--phases <dir>]

--phases: a folder of serialized open_world/minor_activities quest phases
(unbundle -r '.*open_world.minor_activities.*\.questphase$' from
basegame_4_gamedata, then ep1_2_gamedata into the same folder so PL's copies
win, then convert serialize the folder). Each site gets the facts its phases
set to mark the activity done ("<something>_finished"; the names vary, e.g.
ma_dtn_01_finished, ma_kab_016_finished). The mod reads them with
QuestsSystem.GetFactStr to tell cleared sites from uncleared ones.

Each POI's cooked position is looked up by ArchiveXL's journal path hash:
Murmur3-32 with seed 0x5EEDBA5E over the path, e.g.
points_of_interest/minor_activities/ma_wat_kab_01.
"""
import json
import os
import struct
import sys

# Pins are anchored to this base-game node in always_loaded_0 (never unloads),
# position read from that sector in game 2.x with Phantom Liberty.
ANCHOR = {"node": "#coyote_performance_test", "pos": [-1259.71252, -988.872009, 12.0372458]}

DISTRICTS = {
    "bls_ina": "Badlands", "cct_cpz": "Corpo Plaza", "cct_dtn": "Downtown",
    "hey_gle": "The Glen", "hey_rey": "Vista del Rey", "hey_spr": "Wellsprings",
    "pac_cvi": "Coastview", "pac_wwd": "West Wind Estate", "std_arr": "Arroyo",
    "std_rcr": "Rancho Coronado", "wat_kab": "Kabuki", "wat_lch": "Little China",
    "wat_nid": "Northside", "wbr_hil": "Charter Hill", "wbr_jpn": "Japantown",
    "wbr_nok": "North Oak",
}


def murmur3(data, seed=0x5EEDBA5E):
    data = data.encode()
    c1, c2, h, n = 0xcc9e2d51, 0x1b873593, seed, len(data)
    for i in range(0, n // 4 * 4, 4):
        k = struct.unpack("<I", data[i:i + 4])[0]
        k = (k * c1) & 0xffffffff
        k = ((k << 15) | (k >> 17)) & 0xffffffff
        k = (k * c2) & 0xffffffff
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xffffffff
        h = (h * 5 + 0xe6546b64) & 0xffffffff
    tail, k = data[n // 4 * 4:], 0
    if len(tail) >= 3: k ^= tail[2] << 16
    if len(tail) >= 2: k ^= tail[1] << 8
    if tail:
        k ^= tail[0]
        k = (k * c1) & 0xffffffff
        k = ((k << 15) | (k >> 17)) & 0xffffffff
        k = (k * c2) & 0xffffffff
        h ^= k
    h ^= n
    h ^= h >> 16
    h = (h * 0x85ebca6b) & 0xffffffff
    h ^= h >> 13
    h = (h * 0xc2b2ae35) & 0xffffffff
    h ^= h >> 16
    return h


def journal_pois(root):
    """Yield (path, entry) for every gameJournalPointOfInterestMappin."""
    def walk(o, path):
        if isinstance(o, dict):
            d = o.get("Data") if "HandleId" in o else o
            if isinstance(d, dict) and str(d.get("$type", "")).startswith("gameJournal") and "id" in d:
                p = (path + "/" + d["id"]).strip("/") if d["id"] else path
                if d["$type"] == "gameJournalPointOfInterestMappin":
                    yield p, d
                for e in d.get("entries") or []:
                    yield from walk(e, p)
                return
            for v in o.values():
                yield from walk(v, path)
        elif isinstance(o, list):
            for v in o:
                yield from walk(v, path)
    yield from walk(root, "")


def variant(entry):
    md = entry.get("mappinData") or {}
    tv = md.get("typedVariant")
    if isinstance(tv, dict) and tv.get("Data"):
        return tv["Data"].get("variant")
    return md.get("variant")


def finished_facts(phase_dir):
    """site id -> sorted list of facts its quest phases set to mark it done."""
    facts = {}
    for root, _, files in os.walk(phase_dir):
        parts = root.replace("\\", "/").split("/")
        for f in files:
            if not f.endswith(".questphase.json"):
                continue
            found = set()
            def walk(o):
                if isinstance(o, dict):
                    if (o.get("$type") == "questSetVar_NodeType"
                            and str(o.get("factName", "")).endswith("_finished") and o.get("value", 0) >= 1):
                        found.add(o["factName"])
                    for v in o.values():
                        walk(v)
                elif isinstance(o, list):
                    for v in o:
                        walk(v)
            walk(json.load(open(os.path.join(root, f))))
            # the activity is named by its folder (.../<id or loc_id>/...) or,
            # where the folder is named differently (ma_bls_ina_01 holding
            # ma_bls_ina_se1_01_phase), by the file
            stem = f[:-len(".questphase.json")]
            for suffix in ("_questphase", "_phase", "_quest"):
                if stem.endswith(suffix):
                    stem = stem[:-len(suffix)]
            for seg in parts + [stem]:
                sid = seg[4:] if seg.startswith("loc_ma_") else seg
                if sid.startswith("ma_"):
                    facts.setdefault(sid, set()).update(found)
    return {k: sorted(v) for k, v in facts.items()}


def main():
    args = sys.argv[1:]
    phase_dir = None
    if "--phases" in args:
        i = args.index("--phases")
        phase_dir = args[i + 1]
        del args[i:i + 2]
    out, poi_file, journals = args[0], args[1], args[2:]
    facts = finished_facts(phase_dir) if phase_dir else {}
    cooked = json.load(open(poi_file))["Data"]["RootChunk"]["cookedData"]
    pos = {e["journalPathHash"]: e["position"] for e in cooked}
    sites, seen = [], set()
    for jf in journals:
        root = json.load(open(jf))["Data"]["RootChunk"]["entry"]
        for path, entry in journal_pois(root):
            if variant(entry) != "GangWatchVariant" or path in seen:
                continue
            p = pos.get(murmur3(path))
            if not p:
                print("no cooked position:", path)
                continue
            seen.add(path)
            sid = path.rsplit("/", 1)[-1]               # ma_wat_kab_01
            dist = "_".join(sid.split("_")[1:3])        # wat_kab
            if dist not in DISTRICTS:
                print("unknown district, skipped:", sid)
                continue
            sites.append({"id": sid, "poi": path, "district": dist,
                          "x": round(p["X"], 3), "y": round(p["Y"], 3), "z": round(p["Z"], 3),
                          "facts": facts.get(sid, [])})
    sites.sort(key=lambda s: s["id"])
    json.dump({"anchor": ANCHOR, "districts": DISTRICTS, "sites": sites},
              open(out, "w"), indent=1)
    print(f"{len(sites)} sites in {len({s['district'] for s in sites})} districts, "
          f"{sum(1 for s in sites if s['facts'])} with a finished fact -> {out}")
    missing = [s["id"] for s in sites if not s["facts"]]
    if missing:
        print("no finished fact (counted as uncleared):", ", ".join(missing))


if __name__ == "__main__":
    main()
