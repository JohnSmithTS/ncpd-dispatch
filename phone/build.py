#!/usr/bin/env python3
"""Generate WolvenKit JSON for the NCPD Dispatch phone texts.

Reads messages.json and writes, under <out>/source/ncpd_dispatch/:
  journal/ncpd_dispatch.journal.json      - journal merged by ArchiveXL into
                                            contacts/<contact>/<conversation>
  localization/en-us.json.json            - onscreen texts keyed by secondaryKey
Text values are plain keys; ArchiveXL hashes them to match the secondaryKey.
"""
import json, sys, os

src, out = sys.argv[1], sys.argv[2]
spec = json.load(open(src))
# expand per-gang templates: {gang} -> slug, {Gang} -> display name
for t in spec.get("templates", []):
    for slug, name in spec.get("gangs", {}).items():
        spec["messages"].append({
            "id": t["id"].replace("{gang}", slug),
            "delay": t.get("delay", 2),
            "text": t["text"].replace("{Gang}", name),
        })
ids = [m["id"] for m in spec["messages"]]
assert len(ids) == len(set(ids)), "duplicate message ids"
KEY = "ncpd_dispatch_"   # prefix for all localization keys

handle = [0]
def h():
    handle[0] += 1
    return str(handle[0])

def loc(key):
    return {"unk1": "0", "value": KEY + key}

def message(m):
    return {"HandleId": h(), "Data": {
        "$type": "gameJournalPhoneMessage",
        "attachment": None,
        "delay": m.get("delay", 3),
        "id": m["id"],
        "imageId": {"$type": "TweakDBID", "$storage": "uint64", "$value": "0"},
        "isQuestImportant": 0,
        "journalEntryOverrideDataList": [],
        "sender": m.get("sender", "NPC"),
        "text": loc("msg_" + m["id"]),
    }}

# Player replies: picking one in the phone sets it Succeeded and the others
# Inactive (MessengerDialogViewController.ActivateReply); the mod polls that.
replies = spec.get("replies")
def choice(c):
    return {"HandleId": h(), "Data": {
        "$type": "gameJournalPhoneChoiceEntry",
        "id": c["id"],
        "isQuestImportant": 1,
        "journalEntryOverrideDataList": [],
        "questCondition": None,
        "text": loc("reply_" + c["id"]),
    }}
conv_entries = [message(m) for m in spec["messages"]]
if replies:
    conv_entries.append({"HandleId": h(), "Data": {
        "$type": "gameJournalPhoneChoiceGroup",
        "entries": [choice(c) for c in replies["choices"]],
        "id": replies["group"],
        "journalEntryOverrideDataList": [],
    }})
conversation = {"HandleId": h(), "Data": {
    "$type": "gameJournalPhoneConversation",
    "entries": conv_entries,
    "id": spec["conversation"],
    "journalEntryOverrideDataList": [],
    "title": loc("conv_title"),
}}
# Only id/type need to match for ArchiveXL to merge into the existing contact.
contact = {"HandleId": h(), "Data": {
    "$type": "gameJournalContact",
    "avatarID": {"$type": "TweakDBID", "$storage": "string", "$value": "PhoneAvatars.Avatar_Ncpd"},
    "entries": [conversation],
    "id": spec["contact"],
    "isCallableDefault": 0,
    "journalEntryOverrideDataList": [],
    "name": {"unk1": "0", "value": "LocKey#51461"},
    "type": "Caller",
    "useFlatMessageLayout": 1,
}}
def ref_none(kind, storage="string", value="None"):
    return {"$type": kind, "$storage": storage, "$value": value}

q = spec["quest"]
# One objective per call type and gang (gang wars: per gang pair), so the
# objective line names the call; the mod activates the matching one.
# Ids: respond_<type>_<gang>[_<rival>]
gangs = spec["gangs"]
objectives = []   # (id, text)
for key, tmpl in q["objectives"].items():
    for slug, name in gangs.items():
        if "{Rival}" in tmpl:
            for slug2, name2 in gangs.items():
                if slug2 != slug:
                    objectives.append((f"respond_{key}_{slug}_{slug2}",
                                       tmpl.replace("{Gang}", name).replace("{Rival}", name2)))
        else:
            objectives.append((f"respond_{key}_{slug}", tmpl.replace("{Gang}", name)))

# Call sites: the game's own "Assault in Progress" locations (sites.json,
# made by extract_sites.py). One objective per district, "Get to the scene:
# <district>", per site: scene_<site id> holds that site's one map pin.
# (Activating an objective spawns every pin under it, so one objective per
# district showed all its sites at once.) The mod activates the call's scene
# objective and tracks it (GPS + distance). The named objective above has no
# pin; the tracker lists both active objectives.
sites_spec = json.load(open(os.path.join(os.path.dirname(os.path.abspath(src)), "sites.json")))
anchor = sites_spec["anchor"]
districts = sites_spec["districts"]
by_district = {}
for st in sites_spec["sites"]:
    by_district.setdefault(st["district"], []).append(st)

def empty_objective(oid, entries=(), text_key=None):
    return {"HandleId": h(), "Data": {
        "$type": "gameJournalQuestObjective",
        "counter": 0,
        "description": loc("quest_obj_" + (text_key or oid)),
        "districtID": "",
        "entries": list(entries),
        "id": oid,
        "itemID": ref_none("TweakDBID", "uint64", "0"),
        "journalEntryOverrideDataList": [],
        "locationPrefabRef": ref_none("NodeRef", "uint64", "0"),
        "optional": 0,
    }}

def site_pin(st):
    # A quest pin needs a node reference or it is never spawned; ArchiveXL puts
    # it at anchor node + offset, once, when the pin entry is activated (it
    # can't be moved later). The anchor is in an always-loaded sector, so it
    # resolves wherever V is.
    ax, ay, az = anchor["pos"]
    return {"HandleId": h(), "Data": {
        "$type": "gameJournalQuestMapPin",
        "enableGPS": 1,
        "entries": [],
        "id": "site_" + st["id"],
        "journalEntryOverrideDataList": [],
        "mappinData": {
            "$type": "gamemappinsMappinData",
            "active": 1,
            "debugCaption": "",
            "localizedCaption": loc("pin_" + st["district"]),
            "mappinType": ref_none("TweakDBID", "string", "Mappins.QuestStaticMappinDefinition"),
            "scriptData": None,
            "variant": q.get("variant", "DefaultQuestVariant"),
            "visibleThroughWalls": 1,
        },
        "offset": {"$type": "Vector3", "X": round(st["x"] - ax, 4), "Y": round(st["y"] - ay, 4),
                   "Z": round(st["z"] - az, 4)},
        "reference": {
            "$type": "gameEntityReference",
            "dynamicEntityUniqueName": ref_none("CName"),
            "names": [],
            "reference": {"$type": "NodeRef", "$storage": "string", "$value": anchor["node"]},
            "sceneActorContextName": ref_none("CName"),
            "slotName": ref_none("CName"),
            "type": "EntityRef",
        },
        "slotName": ref_none("CName"),
        "uiAnimation": ref_none("TweakDBID", "uint64", "0"),
    }}

# texts are per district: quest_obj_scene_<district>
scene_texts = [("scene_" + d, q["scene_objective"].replace("{District}", districts[d])) for d in sorted(by_district)]

quest = {"HandleId": h(), "Data": {
    "$type": "gameJournalQuest",
    "districtID": "",
    "entries": [
        {"HandleId": h(), "Data": {
            "$type": "gameJournalQuestDescription",
            "description": loc("quest_description"),
            "id": "description",
            "journalEntryOverrideDataList": [],
        }},
        {"HandleId": h(), "Data": {
            "$type": "gameJournalQuestPhase",
            "entries": [empty_objective(oid) for oid, _ in objectives]
                     + [empty_objective("scene_" + st["id"], [site_pin(st)], "scene_" + st["district"])
                        for st in sites_spec["sites"]],
            "id": "call",
            "journalEntryOverrideDataList": [],
            "locationPrefabRef": ref_none("NodeRef", "uint64", "0"),
        }},
    ],
    "id": q["id"],
    "journalEntryOverrideDataList": [],
    "recommendedLevelID": ref_none("TweakDBID", "uint64", "0"),
    "title": loc("quest_title"),
    "type": q.get("type", "Contract"),
}}
quests_folder = {"HandleId": h(), "Data": {
    "$type": "gameJournalPrimaryFolderEntry",
    "entries": [{"HandleId": h(), "Data": {
        "$type": "gameJournalFolderEntry",
        "entries": [quest],
        "id": q["folder"],
        "journalEntryOverrideDataList": [],
    }}],
    "id": "quests",
    "journalEntryOverrideDataList": [],
}}

journal = {
    "Header": {"WKitJsonVersion": "0.0.9", "GameVersion": 2310, "DataType": "CR2W"},
    "Data": {"Version": 195, "BuildVersion": 0, "EmbeddedFiles": [], "RootChunk": {
        "$type": "gameJournalResource",
        "cookingPlatform": "PLATFORM_PC",
        "entry": {"HandleId": h(), "Data": {
            "$type": "gameJournalRootFolderEntry",
            "descriptor": {"DepotPath": {"$type": "ResourcePath", "$storage": "uint64", "$value": "0"}, "Flags": "Default"},
            "entries": [quests_folder, {"HandleId": h(), "Data": {
                "$type": "gameJournalPrimaryFolderEntry",
                "entries": [contact],
                "id": "contacts",
                "journalEntryOverrideDataList": [],
            }}],
            "id": "",
            "journalEntryOverrideDataList": [],
        }},
    }},
}

texts = ([("conv_title", spec["conversation_title"]),
          ("quest_title", q["title"]), ("quest_description", q["description"])]
         + [("quest_obj_" + oid, t) for oid, t in objectives + scene_texts]
         + [("pin_" + d, q["pin_caption"].replace("{District}", districts[d])) for d in sorted(by_district)]
         + [("reply_" + c["id"], c["text"]) for c in (replies or {}).get("choices", [])]
         + [("msg_" + m["id"], m["text"]) for m in spec["messages"]])
keys = [k for k, _ in texts]
assert len(keys) == len(set(keys)), "duplicate localization keys"
locres = {
    "Header": {"WKitJsonVersion": "0.0.9", "GameVersion": 2310, "DataType": "CR2W"},
    "Data": {"Version": 195, "BuildVersion": 0, "EmbeddedFiles": [], "RootChunk": {
        "$type": "JsonResource",
        "cookingPlatform": "PLATFORM_PC",
        "root": {"HandleId": "0", "Data": {
            "$type": "localizationPersistenceOnScreenEntries",
            "entries": [{"$type": "localizationPersistenceOnScreenEntry",
                         "femaleVariant": t, "maleVariant": "", "primaryKey": "0",
                         "secondaryKey": KEY + k} for k, t in texts],
        }},
    }},
}

base = os.path.join(out, "source", "ncpd_dispatch")
os.makedirs(os.path.join(base, "journal"), exist_ok=True)
os.makedirs(os.path.join(base, "localization"), exist_ok=True)
json.dump(journal, open(os.path.join(base, "journal", "ncpd_dispatch.journal.json"), "w"), indent=1)
json.dump(locres, open(os.path.join(base, "localization", "en-us.json.json"), "w"), indent=1)
print(f"{len(spec['messages'])} messages, {len(objectives)} call objectives, "
      f"{len(sites_spec['sites'])} scene objectives with one pin each, {len(texts)} texts")
