#!/usr/bin/env python3
# carver-tool
"""Render every takeable room item's CEL art so items are VISIBLE in the port.

Room items (Screwdriver, Key, Chili, Rope...) are not sprites: they are CEL
objects. Verified by executing the ROM (cluster_init 0x7F66 -> scene_load
0x758A) and reading each actor's mode bit: every items_here entity has
+0x18 bit1 CLEAR = cel/poly mode (the same bit the hit-test 0x1018 branches on),
and its record position is (0,0) -- the position lives in the CEL DESCRIPTOR,
not the actor record. So an item's art AND its clickable rect both come from:

    desc = reloc(ctx+0x1C) + offset_table(ctx+0x24)[shape-1]
    desc: +0 X tiles, +2 Y tiles, +4 W tiles, +6 H tiles,
          +0xC plane select, +0xE nametable words (W*H of them)

The cel stamper (0x7D54/0x7DD0) copies those words over the room's nametable --
REPLACING, never compositing -- which is why the items are absent from the
exported background planes: the port never ran the stamp. We render the words
with the room's own tiles.bin + palette.json and emit a transparent PNG per
item plus its pixel rect, for room.gd to draw as an overlay and hit-test.

Emits assets/data/<cluster>/room_NN/items/<entity>.png and, per room,
items.json = [{entity_id, name, x, y, w, h, png}].
"""
from __future__ import annotations
import json, os, sys
from PIL import Image

ROM = open(r"D:/blastem/blastem-win32-0.6.2/Scooby Doo Mystery (JUE) [!].bin", "rb").read()
KIT = r"D:/scoobydoo"
PORT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CTX = {"hotel": 0x0FCA0C, "carnival": 0x0FCA40}


def r16(o): return int.from_bytes(ROM[o:o + 2], "big")
def r32(o): return int.from_bytes(ROM[o:o + 4], "big")
def hx(s): return int(s, 16) if isinstance(s, str) else int(s)


def cel(chapter, shape):
    """(x,y,w,h in tiles, address of the nametable words) or None."""
    ctx = CTX[chapter]
    reloc, tbl = r32(ctx + 0x1C), r32(ctx + 0x24)
    if shape <= 0:
        return None
    a = reloc + r32(tbl + (shape - 1) * 4)
    return r16(a), r16(a + 2), r16(a + 4), r16(a + 6), a + 0xE


def render_cel(scene_dir, x, y, w, h, words_at):
    """Render W*H nametable words with the room's tiles+palette -> RGBA image."""
    pal = [(c["r"], c["g"], c["b"]) for c in
           json.load(open(os.path.join(scene_dir, "palette.json"), encoding="utf-8"))]
    tiles = open(os.path.join(scene_dir, "tiles.bin"), "rb").read()

    def tpx(t, px, py):
        o = t * 32 + py * 4 + (px >> 1)
        if o >= len(tiles):
            return 0
        b = tiles[o]
        return (b >> 4) if (px & 1) == 0 else (b & 0xF)

    im = Image.new("RGBA", (w * 8, h * 8), (0, 0, 0, 0))
    p = im.load()
    for ty in range(h):
        for tx in range(w):
            word = r16(words_at + (ty * w + tx) * 2)
            pl = (word >> 13) & 3
            vf = (word >> 12) & 1
            hf = (word >> 11) & 1
            t = word & 0x7FF
            for yy in range(8):
                for xx in range(8):
                    sx = 7 - xx if hf else xx
                    sy = 7 - yy if vf else yy
                    n = tpx(t, sx, sy)
                    if n:
                        p[tx * 8 + xx, ty * 8 + yy] = pal[pl * 16 + n] + (255,)
    return im


def _render_one(chapter, scene_dir, shape, name):
    """shape -> (rec dict fields, image) or None. Shared by both passes."""
    c = cel(chapter, shape)
    if c is None:
        return None
    x, y, w, h, words = c
    if not (1 <= w <= 40 and 1 <= h <= 30):
        print("   SKIP %s: implausible cel %dx%d tiles" % (name, w, h))
        return None
    im = render_cel(scene_dir, x, y, w, h, words)
    if not any(px[3] for px in im.getdata()):
        print("   SKIP %s: cel renders empty" % name)
        return None
    return (x * 8, y * 8, w * 8, h * 8), im


def build(chapter):
    recs = json.load(open(os.path.join(KIT, chapter, "entities/entities.json"), encoding="utf-8"))
    man = json.load(open(os.path.join(PORT, "assets/data/global/scene_manifest_%s.json" % chapter),
                         encoding="utf-8"))["scenes"]
    # room -> {eid -> rec} accumulator so the two passes merge into one items.json
    by_room = {}

    def emit(rid, eid, name, shape, box, im):
        out_dir = os.path.join(PORT, "assets/data", chapter, "room_%02d" % int(rid), "items")
        os.makedirs(out_dir, exist_ok=True)
        png = "%d.png" % eid
        im.save(os.path.join(out_dir, png))
        by_room.setdefault(int(rid), {})[eid] = {
            "entity_id": eid, "name": name, "shape": shape,
            "x": box[0], "y": box[1], "w": box[2], "h": box[3], "png": png}

    total = 0
    for rid, sc in man.items():
        items = sc.get("items_here", [])
        if not items:
            continue
        scene_dir = os.path.join(KIT, chapter, "scenes", "room_%02d" % int(rid))
        if not os.path.isfile(os.path.join(scene_dir, "tiles.bin")):
            continue
        for it in items:
            eid = int(it["entity_id"])
            if eid - 3 >= len(recs):
                continue
            shape = hx(recs[eid - 3]["long0"]) & 0xFFFF
            r = _render_one(chapter, scene_dir, shape, it.get("item"))
            if r is None:
                continue
            box, im = r
            emit(rid, eid, it.get("item"), shape, box, im)
            total += 1

    # ---- pass 2: derived room-pickup items placed DYNAMICALLY ----
    # These items' TEMPLATE field+0 is 0, so pass 1 (which reads the template)
    # renders nothing. Their RUNTIME render cel = record field +0 (the cel word,
    # 0x7C4A -- NOT record+2 shape, the hit-test index) was resolved by EXECUTING
    # cluster_init 0x7F66 -> scene_load 0x758A and reading $FF1200+slot*26 +0.
    # That per-chapter result lives in work/dynamic_item_cels_<chapter>.json --
    # {entity_id,name,room,field0_cel,mode_bit1}. CHAPTER-SAFE by construction:
    # each chapter reads only its own file (no cross-chapter leak). An item whose
    # field0_cel is 0 (e.g. Medallion, a dynamic reveal not stamped at load and
    # not painted into the bg) is left UNRENDERED -- we never invent art from the
    # hit-test shape. (Extractor: work/derive_dynamic_item_cels.py)
    dyn_path = r"D:/scoobydoo/work/dynamic_item_cels_%s.json" % chapter
    if os.path.isfile(dyn_path):
        for it in json.load(open(dyn_path, encoding="utf-8")):
            eid = int(it["entity_id"]); rid = it.get("room")
            cel_word = int(it.get("field0_cel") or 0)
            if rid is None or cel_word <= 0:
                continue                          # unresolved / dynamic-reveal
            if int(it.get("mode_bit1", 0)):
                continue                          # positioned sprite, not a cel
            if any(eid in v for v in by_room.values()):
                continue                          # already rendered by pass 1
            scene_dir = os.path.join(KIT, chapter, "scenes", "room_%02d" % int(rid))
            if not os.path.isfile(os.path.join(scene_dir, "tiles.bin")):
                continue
            r = _render_one(chapter, scene_dir, cel_word, it.get("name"))
            if r is None:
                continue
            box, im = r
            emit(rid, eid, it.get("name"), cel_word, box, im)
            total += 1

    for rid in sorted(by_room):
        recs_out = [by_room[rid][e] for e in sorted(by_room[rid])]
        out_dir = os.path.join(PORT, "assets/data", chapter, "room_%02d" % int(rid), "items")
        if recs_out:
            json.dump({"note": "Takeable room items rendered from their CEL descriptors "
                               "(ctx+0x24 table, words at +0xE) with the room's own tiles/"
                               "palette. Position+size ARE the cel rect -- items' actor "
                               "records carry (0,0). tools/gen_room_items.py",
                       "items": recs_out},
                      open(os.path.join(out_dir, "items.json"), "w", encoding="utf-8"),
                      indent=1, ensure_ascii=False)
            for r in recs_out:
                print("   room %2s %-16s eid %3d cel %3d at (%3d,%3d) %dx%d"
                      % (rid, r["name"], r["entity_id"], r["shape"], r["x"], r["y"], r["w"], r["h"]))
    print("%s: %d item cels rendered" % (chapter, total))


if __name__ == "__main__":
    for c in ("hotel", "carnival"):
        build(c)
