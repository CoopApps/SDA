#!/usr/bin/env python3
# carver-tool
"""Lift resident NPC placements from the per-chapter actor-init template.

Mechanism (VERIFIED, see memory actor-init-template + ROM_MAP row 471):
  cluster_init_entities 0x7F66 walks the template at [chapter+4]..[chapter+8].
  Per record (variable length): long -> rec+0/+2 ; long -> rec+4/+6 (scene) ;
  word -> +8 ; word -> +22 ; word -> +24 (flags); then ONLY if flags & 0x0200
  (BTST #1 on the high byte): long -> rec+18/+20 = home (X, Y).
  Record index N -> selector/entity id N+3 (selectors 1/2 = reserved leads).

Sprite bank (lifted THIS session, verified against the room-10 cast):
  rec+2 word = sprite-source index + 1.
    Fred sel13 w=3 -> source_02 OK; Velma sel14 w=5 -> source_04 OK;
    Daphne sel15 w=4 -> source_03 OK; Blake sel26 w=10 -> source_09 OK.

Emits assets/data/global/npcs_<chapter>.json:
  { "<room_id>": [ {"entity_id", "name", "x", "y", "source_base", "source_dir"} ] }
Only resident records (flags & 0x0200, scene > 0) are emitted -- everything else
is script-placed, not a standing NPC.

Coordinate space: (x, y) are ROM world coords -- the same space as script
move_to_xy, consumed by the sprite placement code at 0xAD5A
(screen = pos - scroll + hw_origin - hotspot). The port treats them as the
actor's FOOT position in room pixels.
"""
from __future__ import annotations
import json, os, sys

ROM = r"D:/blastem/blastem-win32-0.6.2/Scooby Doo Mystery (JUE) [!].bin"
ENTITIES = r"D:/scoobydoo/global/entities_lifted.json"
SCRIPTS = r"D:/scoobydoo/analysis/scripts.json"
SHEETS = r"D:/scoobydoo/sprites/sprite_sheets.json"
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "assets", "data", "global")

rom = open(ROM, "rb").read()
def r16(o): return (rom[o] << 8) | rom[o + 1]

def names_by_entity():
    """entity_id -> object name, from the scripts export (both chapters)."""
    sc = json.load(open(SCRIPTS, encoding="utf-8"))
    out = {}
    for chap, clusters in (sc.get("clusters") or {}).items():
        for cid, c in clusters.items():
            if not isinstance(c, dict):
                continue
            for s in c.get("scripts", []):
                eid = s.get("entity_id")
                if eid is not None and s.get("object"):
                    out.setdefault(int(eid), str(s["object"]))
    return out

def sources_by_index():
    """source index (0-based) -> (base_hex, dir), from the sheet manifest."""
    m = json.load(open(SHEETS, encoding="utf-8"))
    srcs = m["value"]["sources"] if "value" in m else m["sources"]
    out = {}
    for s in srcs:
        name = str(s.get("name", ""))          # "source_NN"
        if name.startswith("source_"):
            out[int(name[7:])] = (str(s.get("base", "")), str(s.get("dir", "")))
    return out

def main():
    ent = json.load(open(ENTITIES, encoding="utf-8"))
    names = names_by_entity()
    sources = sources_by_index()
    for chap in ("hotel", "carnival"):
        cl = ent["clusters"][chap]
        a = int(str(cl["records_start"]), 16)
        end = int(str(cl["records_end"]), 16)
        idx = 0
        rooms = {}
        while a < end:
            bank_w = r16(a + 2)
            scene = r16(a + 6)
            flags = r16(a + 12)
            sel = idx + 3
            if flags & 0x0200:
                x, y = r16(a + 14), r16(a + 16)
                if scene > 0:
                    src_idx = bank_w - 1
                    base, sdir = sources.get(src_idx, ("", ""))
                    rooms.setdefault(str(scene), []).append({
                        "entity_id": sel,
                        "name": names.get(sel, "npc_%d" % sel),
                        "x": x, "y": y,
                        "source_index": src_idx,
                        "source_base": base,
                        "source_dir": sdir,
                    })
                a += 18
            else:
                a += 14
            idx += 1
        out = {
            "note": "Resident NPC placements from the actor-init template "
                    "([chapter+4], cluster_init_entities 0x7F66, ROM_MAP row "
                    "471). flags&0x0200 records only; (x,y) = home position "
                    "(rec+18/+20, move_to_xy coord space); sprite bank = "
                    "rec+2 word - 1 (verified on the room-10 cast).",
            "rooms": rooms,
        }
        p = os.path.join(OUT_DIR, "npcs_%s.json" % chap)
        json.dump(out, open(p, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
        n = sum(len(v) for v in rooms.values())
        print("%s: %d resident NPCs in %d rooms -> %s" % (chap, n, len(rooms), p))
        for rid, lst in sorted(rooms.items(), key=lambda kv: int(kv[0])):
            print("  room %s: %s" % (rid, ", ".join(
                "%s(e%d,src%d)" % (e["name"], e["entity_id"], e["source_index"])
                for e in lst)))

if __name__ == "__main__":
    sys.exit(main())
