#!/usr/bin/env python3
# carver-tool
"""Extract the hotel's GLOBAL puzzle behaviors (USE-combinations, gated grants)
from the `unlinked` script bucket the scene-manifest bake skips.

WHY: analysis/scripts.json splits each chapter's scripts into per-room buckets
plus an `unlinked` bucket -- scripts whose address falls in no room's declared
extents. These unlinked scripts are the game's GLOBAL puzzle logic: USE-item
combinations doable in any room where you hold the items (e.g. USE Battery on
Light Bulb -> consumes both, grants "Bulb and Battery"). The manifest decoder
only reads per-room scripts, so 35 of 52 hotel item-grant sites -- including the
FLASHLIGHT, Book, Crowbar, Scissors, Medallion, and every combo -- were in NO
decoded behavior, making the hotel uncompletable.

Each unlinked script has an `object` (the USE target) and op-01 guards of the
form (verb, armed-item-entity). We attribute the object to its icon_items
entity, map the guard's item-entity to its icon_id (the port matches items by
icon), decode the guarded block into runner events (gen_choices.decode_body,
the proven decoder), and emit assets/data/global/puzzle_behaviors_<chapter>.json:
    { "<target_entity_id>": [ {verb_code, sel2(icon or 0), actions:[...] }, ...] }
room_behavior_runner / main_gameplay consult this as a GLOBAL fallback so a USE
combination fires regardless of which room you are standing in.
"""
from __future__ import annotations
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, r"D:/scoobydoo/exporters")
# Use the SAME decoder the manifest + nested bakes use, so the puzzle behaviours
# emit the schema room_behavior_runner.gd actually reads. The previous decoder
# (gen_choices.decode_body) produced an INCOMPATIBLE schema: it left ops
# op_0C/0F/04/16/1E as raw {'op':'op_0C','raw':...} (the runner's default case
# logs+skips them) and emitted assign_flagbit_or_actor_field with fields
# dest_bit/src_index/src_bit and NO `dest`/`operation` -- so the runner took the
# actor-field branch and a puzzle's progression flag write silently misfired.
from scooby_script_decode import decode_actions, op_int  # runner-compatible decoder

ROM = r"D:/blastem/blastem-win32-0.6.2/Scooby Doo Mystery (JUE) [!].bin"
rom = open(ROM, "rb").read()
SCRIPTS = r"D:/scoobydoo/analysis/scripts.json"
ICON = r"D:/scoobydoo/analysis/icon_items.json"
OUT = os.path.join(os.path.dirname(HERE), "assets", "data", "global")
STR_BASE = {"hotel": 0x14199C, "carnival": 0x1AF33C}

VERB_USE = 5


def _ctx2ent(chapter):
    """context_id -> entity_id, from context_rooms.json (each record carries
    both). Captures NON-item objects (bridges, doors, fixtures) that the item
    name map misses -- e.g. the Totem Pole Bridge (context 053 -> entity 56)
    whose USE handler transitions to room 21."""
    cr = json.load(open(r"D:/scoobydoo/analysis/context_rooms.json", encoding="utf-8"))
    out = {}
    def walk(o):
        if isinstance(o, dict):
            if o.get("context_id") and o.get("entity_id") is not None:
                out[o["context_id"]] = int(o["entity_id"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(cr)
    return out


def build(chapter):
    sc = json.load(open(SCRIPTS, encoding="utf-8"))["clusters"][chapter]
    unlinked = sc.get("unlinked", {}).get("scripts", [])
    icon = json.load(open(ICON, encoding="utf-8"))["chapters"][chapter]
    name2ent = {it["item"].upper(): int(it["entity_id"]) for it in icon}
    ent2icon = {int(it["entity_id"]): int(it["icon_id"]) for it in icon}
    ctx2ent = _ctx2ent(chapter)
    strblk = STR_BASE[chapter]

    def read_string(off):
        o = strblk + off
        s = []
        while 0 <= o < len(rom) and rom[o] and len(s) < 200:
            if not (32 <= rom[o] < 127):
                return ""
            s.append(chr(rom[o])); o += 1
        return "".join(s)

    out = {}
    n_beh = n_grant = 0
    for s in unlinked:
        obj = s.get("object")
        # the target entity: context_id (covers item AND fixture/exit objects),
        # falling back to the object name -> inventory-item entity.
        tgt_ent = ctx2ent.get(s.get("context_id"))
        if tgt_ent is None and obj:
            tgt_ent = name2ent.get(str(obj).upper())
        if tgt_ent is None:
            continue
        for g in s.get("ops", []):
            if str(g.get("op", "")).lower() not in ("0x01", "0x1"):
                continue
            ops = [int(x, 16) for x in g.get("operands", [])]
            if len(ops) < 3:
                continue
            verb, sel = ops[0], ops[1]
            nested = g.get("nested") or []
            if not nested:
                continue
            # Decode the guarded block with the runner-compatible decoder, from
            # the nested op list scripts.json already carries (same input
            # gen_nested_behaviors uses) -- no raw-byte re-decode needed.
            actions = decode_actions(nested, read_string=read_string)
            if not actions:
                continue
            # sel is the OTHER participant's ENTITY id (item OR room object --
            # e.g. Goblet's USE guard carries 166 = the Statue). Keep it RAW:
            # converting through entity->icon silently zeroed every pairing whose
            # partner is not an inventory item, losing 10 late-game puzzles.
            sel2 = sel
            rec = {"verb_code": verb, "sel2": sel2, "actions": actions,
                   "target_name": obj}
            if sel and sel in ent2icon:
                rec["item_name"] = next((it["item"] for it in icon
                                         if int(it["entity_id"]) == sel), None)
            out.setdefault(str(tgt_ent), []).append(rec)
            n_beh += 1
            n_grant += sum(1 for a in actions
                           if a.get("op") == "move_actor_to_room" and int(a.get("room", -1)) == 1)
    p = os.path.join(OUT, "puzzle_behaviors_%s.json" % chapter)
    json.dump({"note": "Global puzzle behaviors (USE-combinations + gated grants) "
                       "from analysis/scripts.json 'unlinked' bucket -- the logic the "
                       "manifest bake skipped. Keyed by target entity_id; verb_code + "
                       "sel2(icon) match the port's _behavior_for. gen_puzzle_behaviors.py.",
               "behaviors": out}, open(p, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print("%s: %d target entities, %d behaviors, %d item-grants -> %s"
          % (chapter, len(out), n_beh, n_grant, p))


if __name__ == "__main__":
    for c in ("hotel", "carnival"):
        build(c)
