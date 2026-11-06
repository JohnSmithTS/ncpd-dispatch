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

conversation = {"HandleId": h(), "Data": {
    "$type": "gameJournalPhoneConversation",
    "entries": [message(m) for m in spec["messages"]],
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
journal = {
    "Header": {"WKitJsonVersion": "0.0.9", "GameVersion": 2310, "DataType": "CR2W"},
    "Data": {"Version": 195, "BuildVersion": 0, "EmbeddedFiles": [], "RootChunk": {
        "$type": "gameJournalResource",
        "cookingPlatform": "PLATFORM_PC",
        "entry": {"HandleId": h(), "Data": {
            "$type": "gameJournalRootFolderEntry",
            "descriptor": {"DepotPath": {"$type": "ResourcePath", "$storage": "uint64", "$value": "0"}, "Flags": "Default"},
            "entries": [{"HandleId": h(), "Data": {
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

texts = [("conv_title", spec["conversation_title"])] + [("msg_" + m["id"], m["text"]) for m in spec["messages"]]
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
print(f"{len(spec['messages'])} messages, {len(texts)} texts")
