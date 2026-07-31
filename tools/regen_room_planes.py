#!/usr/bin/env python3
# carver-tool
"""Regenerate every room's background.png / foreground.png with the CORRECT
priority split.

Bug this fixes: the old background.png had the HIGH-priority tiles baked in as
well, while foreground.png also carried them -- so door frames, the wall
portrait etc. were drawn twice (once behind sprites, once in front). Correct
model (Genesis nametable word bit15): background = low-priority tiles only,
foreground = high-priority tiles only (transparent elsewhere), drawn at z=4000
over the sprites.

Source of truth: <kit>/<chapter>/scenes/room_NN/{tiles.bin, ff8c00.bin (plane B,
drawn first), ff7000.bin (plane A, over it), palette.json}. These bins are
byte-identical to what the executed scene_load (ROM 0x758A) writes to RAM --
verified for room 16 in-session -- so rendering them IS rendering the ROM's own
room state. Room size comes from the existing background.png (w,h) so odd-sized
rooms (hotel 8 = 512x448, carnival 6 = 696x352) keep their dimensions.
"""
import json, os, sys
from PIL import Image

KIT = r"D:/scoobydoo"
PORT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def render_room(scene_dir, w_px, h_px):
    pal = [(c["r"], c["g"], c["b"]) for c in
           json.load(open(os.path.join(scene_dir, "palette.json")))]
    tiles = open(os.path.join(scene_dir, "tiles.bin"), "rb").read()
    W, H = w_px // 8, h_px // 8

    def tpx(t, px, py):
        o = t * 32 + py * 4 + (px >> 1)
        if o >= len(tiles):
            return 0
        b = tiles[o]
        return (b >> 4) if (px & 1) == 0 else (b & 0xF)

    bg = Image.new("RGBA", (w_px, h_px), (0, 0, 0, 255))
    fg = Image.new("RGBA", (w_px, h_px), (0, 0, 0, 0))
    bgp, fgp = bg.load(), fg.load()
    for nt_file in ("ff8c00.bin", "ff7000.bin"):        # B first, A over it
        p = os.path.join(scene_dir, nt_file)
        if not os.path.isfile(p):
            continue
        nt = open(p, "rb").read()
        for cy in range(H):
            for cx in range(W):
                o = (cy * W + cx) * 2
                if o + 1 >= len(nt):
                    continue
                word = (nt[o] << 8) | nt[o + 1]
                pri = (word >> 15) & 1
                pl = (word >> 13) & 3
                vf = (word >> 12) & 1
                hf = (word >> 11) & 1
                t = word & 0x7FF
                tgt = fgp if pri else bgp
                for yy in range(8):
                    for xx in range(8):
                        sx = 7 - xx if hf else xx
                        sy = 7 - yy if vf else yy
                        n = tpx(t, sx, sy)
                        if n:
                            r, g, b = pal[pl * 16 + n]
                            tgt[cx * 8 + xx, cy * 8 + yy] = (r, g, b, 255)
    return bg, fg


def main():
    changed = 0
    for chapter in ("hotel", "carnival"):
        data_dir = os.path.join(PORT, "assets", "data", chapter)
        for room in sorted(os.listdir(data_dir)):
            room_dir = os.path.join(data_dir, room)
            bg_png = os.path.join(room_dir, "background.png")
            if not (room.startswith("room_") and os.path.isfile(bg_png)):
                continue
            scene_dir = os.path.join(KIT, chapter, "scenes", room)
            if not os.path.isfile(os.path.join(scene_dir, "tiles.bin")):
                print("SKIP %s/%s: no scene bins" % (chapter, room))
                continue
            w, h = Image.open(bg_png).size
            bg, fg = render_room(scene_dir, w, h)
            bg.save(bg_png)
            n_fg = sum(1 for p in fg.get_flattened_data() if p[3] > 0) \
                if hasattr(fg, "get_flattened_data") else \
                sum(1 for p in fg.getdata() if p[3] > 0)
            fg_png = os.path.join(room_dir, "foreground.png")
            if n_fg:
                fg.save(fg_png)
            elif os.path.isfile(fg_png):
                os.remove(fg_png)           # no high-pri tiles in this room
            changed += 1
            print("%s/%s %dx%d  fg px=%d" % (chapter, room, w, h, n_fg))
    print("regenerated %d rooms" % changed)


if __name__ == "__main__":
    sys.exit(main())
