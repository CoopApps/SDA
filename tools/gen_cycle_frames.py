#!/usr/bin/env python3
# carver-tool
"""Offline generator for op-$1A palette-cycle animation frames (index-based).

The ROM's off-table cycle animations (Television, Engine, crystal ball, ...) are
PALETTE cycles: op $1A (install_cycle_anim_channel, ROM 0x2626) marks a run of
CRAM colour entries; animate_cycle_tiles (ROM 0x00A7CE) rotates that run every
`period` ticks and DMAs it to CRAM ($9B10 -> CD=%100011, CRAM write). The port's
vdp_screen.rotate_palette does the same rotation live for the front-end.

WHY INDEX-BASED (not colour-matching the flat PNG): the baked background.png has
already resolved indices to RGB, so two different CRAM entries with the same RGB
are indistinguishable, and a cycled entry's colour may not even appear (proven:
matching CRAM 62-63 on room_14's PNG found 0 px; matching 34-37 matched the whole
screen). So we decode the REAL palette index per pixel from the plane nametable +
tile sheet (the same data room.gd reads for collision), and cycle only pixels
whose CRAM index is in [lo,hi].

Genesis nametable word: P CC V H TTTTTTTTTTT  (priority, palette line 0-3, vflip,
hflip, tile 0-2047). Tile = 32 bytes, 4bpp, row-major; nibble 0 = transparent.

Usage:
    gen_cycle_frames.py <room_dir> <lo> <hi> <period> <out_dir> [--plane a|b|both]
<room_dir> holds tiles.bin, ff7000.bin (plane A), ff8c00.bin (plane B),
palette.json ([{index,r,g,b}]*64 or [[r,g,b]]*..). Emits cycle_NN.png (RGBA, only
the cycled pixels; transparent elsewhere) + cycle.json {pos,period_ticks,frames,
cram_run} for room.gd::_load_cycle_anims / CycleAnim.
"""
from __future__ import annotations
import sys, os, json

NT_W, NT_H = 32, 19          # 256x152 rooms = 32x19 tiles (1216-byte nametables)


def load_palette(path):
    raw = json.load(open(path))
    if raw and isinstance(raw[0], dict):
        return [(int(c["r"]), int(c["g"]), int(c["b"])) for c in raw]
    return [tuple(c) for c in raw]


def _tile_px(tiles, tidx, px, py):
    o = tidx * 32 + py * 4 + (px >> 1)
    if o >= len(tiles):
        return 0
    b = tiles[o]
    return (b >> 4) if (px & 1) == 0 else (b & 0xF)


def decode_index_map(room_dir, plane_file, w=NT_W, h=NT_H):
    """CRAM index per pixel for one plane (-1 = transparent, nibble 0)."""
    tiles = open(os.path.join(room_dir, "tiles.bin"), "rb").read()
    nt = open(os.path.join(room_dir, plane_file), "rb").read()
    idx = [[-1] * (w * 8) for _ in range(h * 8)]
    for cy in range(h):
        for cx in range(w):
            o = (cy * w + cx) * 2
            if o + 1 >= len(nt):
                continue
            word = (nt[o] << 8) | nt[o + 1]
            pal = (word >> 13) & 3
            vf = (word >> 12) & 1
            hf = (word >> 11) & 1
            t = word & 0x7FF
            for py in range(8):
                for px in range(8):
                    sx = 7 - px if hf else px
                    sy = 7 - py if vf else py
                    n = _tile_px(tiles, t, sx, sy)
                    if n != 0:
                        idx[cy * 8 + py][cx * 8 + px] = pal * 16 + n
    return idx


def rotate_run(palette, lo, hi, k):
    run = palette[lo:hi + 1]
    n = len(run)
    rot = [run[(i + k) % n] for i in range(n)]
    out = list(palette)
    out[lo:hi + 1] = rot
    return out


def _main(argv):
    from PIL import Image
    room_dir, lo, hi, period, out_dir = argv[:5]
    lo, hi, period = int(lo), int(hi), int(period)
    plane = "both"
    if "--plane" in argv:
        plane = argv[argv.index("--plane") + 1]
    palette = load_palette(os.path.join(room_dir, "palette.json"))

    planes = {"a": ["ff7000.bin"], "b": ["ff8c00.bin"],
              "both": ["ff7000.bin", "ff8c00.bin"]}[plane]
    # composite: last plane with a non-transparent cycled pixel wins
    cyc = {}            # (x,y) -> CRAM index in [lo,hi]
    W = H = 0
    for pf in planes:
        m = decode_index_map(room_dir, pf)
        H = len(m); W = len(m[0])
        for y in range(H):
            for x in range(W):
                c = m[y][x]
                if lo <= c <= hi:
                    cyc[(x, y)] = c
    if not cyc:
        print("no pixels use CRAM entries %d..%d (planes %s)" % (lo, hi, planes))
        return 1
    xs = [p[0] for p in cyc]; ys = [p[1] for p in cyc]
    x0, y0, x1, y1 = min(xs), min(ys), max(xs) + 1, max(ys) + 1
    os.makedirs(out_dir, exist_ok=True)
    n = hi - lo + 1
    for k in range(n):
        rot = rotate_run(palette, lo, hi, k)
        im = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
        for (x, y), c in cyc.items():
            im.putpixel((x - x0, y - y0), rot[c] + (255,))
        im.save(os.path.join(out_dir, "cycle_%02d.png" % k))
    cfg = {"pos": [x0, y0], "period_ticks": period, "frames": n,
           "cram_run": [lo, hi],
           "note": ("op-$1A palette-cycle animation. install_cycle_anim_channel "
                    "(ROM 0x2626) writes ring [%d,%d] and period %d into the "
                    "channel block; animate_cycle_tiles (ROM 0x00A7CE, called from "
                    "0xA68C in gameplay_per_frame 0xA65C, i.e. once per VBLANK) "
                    "rotates that CRAM run in the $FF06F8 palette buffer and DMAs "
                    "it to CRAM via 0x9B10 (control words 0xC000/0x0080 = CD "
                    "%%100011, CRAM DMA write). Rotation fires on the timer going "
                    "NEGATIVE (0xA7E4 subq / 0xA7E8 bpl), so a period of P is P+1 "
                    "VBLANK frames -- CycleAnim applies that +1. Frames rendered "
                    "from the ROM plane nametable + tile sheet by decoding the "
                    "palette INDEX per pixel and recolouring only indices in the "
                    "ring; %d frames = the ring length. %s. tools/gen_cycle_frames.py"
                    % (lo, hi, period, n, os.path.basename(room_dir)))}
    json.dump(cfg, open(os.path.join(out_dir, "cycle.json"), "w"), indent=1)
    print("wrote %d frames, %d px, bbox=(%d,%d,%d,%d) -> %s"
          % (n, len(cyc), x0, y0, x1, y1, out_dir))
    print("config:", json.dumps(cfg))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
