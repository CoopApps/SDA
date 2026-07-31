#!/usr/bin/env python3
# carver-tool
"""Extract each chapter's INITIAL FLAG BLOCK.

cluster_init_entities (ROM 0x7F66) clears the 256-byte script flag area at
$FF2A00 and then copies a chapter-specific block over it:
    A0 = chapter header ($FF06AA -> 0x31AF2 table)
    MOVEA.L (0,A0),A1        ; source
    LEA $FF2A00,A2
    MOVE.B (A1)+,(A2)+ ; CMPA.L (4,A0),A1 ; BNE   ; copy until end ptr
So the flags do NOT start at zero. Hotel byte 15 = 0x01, and fb15.0 is the
front/double-door gate -- without this the port treated every such door as
already open ("It's already open", exit passable from the start).

Emits assets/data/global/initial_flags_<chapter>.json  {"fb<i>": <byte>}.
"""
import json, os

ROM = open(r"D:/blastem/blastem-win32-0.6.2/Scooby Doo Mystery (JUE) [!].bin", "rb").read()
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "assets", "data", "global")
CTX = {"hotel": 0x0FCA0C, "carnival": 0x0FCA40}


def r32(o):
    return int.from_bytes(ROM[o:o + 4], "big")


for chapter, ctx in CTX.items():
    src, end = r32(ctx), r32(ctx + 4)
    block = ROM[src:end]
    flags = {"fb%d" % i: b for i, b in enumerate(block) if b}
    p = os.path.join(OUT, "initial_flags_%s.json" % chapter)
    json.dump({"note": "Chapter initial script-flag block copied to $FF2A00 by "
                       "cluster_init_entities 0x7F66 (source 0x%06X..0x%06X). "
                       "Keyed fb<index> = byte value; bits are read as fb<i>.<bit>. "
                       "tools/gen_initial_flags.py" % (src, end),
               "flags": flags}, open(p, "w", encoding="utf-8"), indent=1)
    print("%s: %d bytes, %d nonzero -> %s" % (chapter, len(block), len(flags), p))
    print("   ", flags)
