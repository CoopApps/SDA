#!/usr/bin/env python3
# carver-tool
"""Pre-render every CEL an object can take at runtime (open door, open cupboard,
broken/used states) so the port can swap the graphic when a script does.

Mechanism (ROM-grounded):
  * An object's visible graphic is its CEL, read from actor field +0 (0x7C4A).
    Script op 0x0B (actor_set_word0_and_raise_pending_flag) WRITES field +0 --
    so `op 0x0B (actor=<door>, value=<cel>)` IS "change this object's picture".
    (op 0x14 set_actor_shape_index writes +2 and does NOT change the cel --
    CLAUDE.md rendering facts.)
  * The cel id indexes the descriptor table at ctx+0x24 (rect in tiles + the
    nametable words at +0xE), rendered with the room's own tiles/palette --
    the same path gen_room_items.py uses for takeable items.

Example: room 13's Double Doors EVENT sets cel 111 (open), 0 (shut), 111, 0 ...
with waits between -- the door swinging open before the room change.

Scans every behavior action list (scene manifest + puzzle_behaviors) for op 0x0B
values, groups them by the room the object lives in, renders each cel, and emits
assets/data/<cluster>/room_NN/cels/{<cel>.png, cels.json}.
"""
from __future__ import annotations
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_room_items import cel, render_cel, KIT, PORT   # shared, proven cel path


def collect(chapter):
    """room_id -> {entity_id -> set(cel ids)} from every action list we have."""
    man = json.load(open(os.path.join(PORT, "assets/data/global/scene_manifest_%s.json" % chapter),
                        encoding="utf-8"))["scenes"]
    out = {}

    def scan(actions, rid):
        for a in actions or []:
            if a.get("op") == "actor_set_word0_and_raise_pending_flag":
                ent = int(a.get("actor", a.get("entity", -1)))
                val = int(a.get("value", -1))
                if ent >= 0 and val > 0:
                    out.setdefault(rid, {}).setdefault(ent, set()).add(val)
            for k in ("then", "else", "actions"):
                if isinstance(a.get(k), list):
                    scan(a[k], rid)

    for rid, sc in man.items():
        for o in sc.get("objects", []):
            for b in o.get("behaviors", []):
                scan(b.get("actions"), rid)

    # entity -> rooms: manifest objects PLUS the derived-geometry room for
    # dynamic entities that are NOT manifest objects (Cabinet, Frozen Bell,
    # Medallion, ...). Without the derived fallback those entities had no room,
    # so their OPEN/SHUT open-pose cel was never rendered (opening showed no
    # change). work/hotspot_geometry_derived.json is hotel-only for now.
    ent_rooms = {}
    for rid, sc in man.items():
        for o in sc.get("objects", []):
            if o.get("entity_id") is not None:
                ent_rooms.setdefault(int(o["entity_id"]), set()).add(str(rid))
    # per-chapter derived-geometry file (hotel + carnival). CHAPTER-SAFE: each
    # chapter loads only its own file.
    der_path = r"D:/scoobydoo/work/hotspot_geometry_derived%s.json" % (
        "" if chapter == "hotel" else "_" + chapter)
    if os.path.isfile(der_path):
        der = json.load(open(der_path, encoding="utf-8"))
        for grp in ("derived_geometry_hotspots", "sprite_hit_actors"):
            for h in der.get(grp, []):
                if h.get("room") is not None:
                    ent_rooms.setdefault(int(h["entity_id"]), set()).add(str(h["room"]))

    # puzzle + nested behaviors: attribute to every room the target entity is in
    for name in ("puzzle_behaviors_%s.json", "nested_behaviors_%s.json"):
        p = os.path.join(PORT, "assets/data/global", name % chapter)
        if not os.path.isfile(p):
            continue
        behs_by_ent = json.load(open(p, encoding="utf-8"))["behaviors"]
        for tgt, behs in behs_by_ent.items():
            for rid in ent_rooms.get(int(tgt), ()):
                for b in behs:
                    scan(b.get("actions"), rid)
    return out


def build(chapter):
    total = 0
    for rid, ents in sorted(collect(chapter).items(), key=lambda kv: int(kv[0])):
        scene_dir = os.path.join(KIT, chapter, "scenes", "room_%02d" % int(rid))
        if not os.path.isfile(os.path.join(scene_dir, "tiles.bin")):
            continue
        out_dir = os.path.join(PORT, "assets/data", chapter, "room_%02d" % int(rid), "cels")
        recs = {}
        for ent, cels in sorted(ents.items()):
            for cid in sorted(cels):
                c = cel(chapter, cid)
                if c is None:
                    continue
                x, y, w, h, words = c
                if not (1 <= w <= 40 and 1 <= h <= 30):
                    continue
                im = render_cel(scene_dir, x, y, w, h, words)
                if not any(p[3] for p in im.getdata()):
                    continue
                os.makedirs(out_dir, exist_ok=True)
                im.save(os.path.join(out_dir, "%d.png" % cid))
                recs.setdefault(str(ent), []).append(
                    {"cel": cid, "x": x * 8, "y": y * 8, "w": w * 8, "h": h * 8,
                     "png": "%d.png" % cid})
                total += 1
        if recs:
            json.dump({"note": "Runtime CEL states per object (op 0x0B writes actor "
                               "field +0 = the object's picture: open door, open "
                               "cupboard...). Rendered from the ctx+0x24 descriptor with "
                               "the room's tiles/palette. tools/gen_room_cels.py",
                       "by_entity": recs},
                      open(os.path.join(out_dir, "cels.json"), "w", encoding="utf-8"),
                      indent=1, ensure_ascii=False)
            for ent, lst in recs.items():
                print("   room %2s entity %-4s cels %s" % (rid, ent, [r["cel"] for r in lst]))
    print("%s: %d runtime cels rendered" % (chapter, total))


if __name__ == "__main__":
    for c in ("hotel", "carnival"):
        build(c)
