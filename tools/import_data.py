"""import_data.py -- copies validated, ROM-derived data from the D:\\scoobydoo
RE workspace into the new D:\\scoobygodot project. Run manually (not an
autoload) whenever new validated assets are ready to bring in.

Deliberately NOT copied (per the plan's "does not carry over" list): the old
project's loose experiment PNGs/txt scratch files, the duplicate HUD-font
experiments, or either of the two old bespoke intro/room-action JSON schemas
(those get replaced by the Phase 1 canonical decoder, not imported).
"""
from __future__ import annotations
import shutil
import struct
from pathlib import Path

SRC = Path(r"D:/scoobydoo")
DST = Path(r"D:/scoobygodot/assets")

# Known-blank/placeholder source assets -- imported as-is (never silently
# "fixed" here) but flagged loudly so this doesn't get mistaken for a broken
# import later. Found by inspection: hotel room_07's background.png is a
# genuinely blank/black 193-byte PNG in the SOURCE RE workspace.
KNOWN_GAPS = {
    "hotel/scenes/room_07/background.png": "blank/black source asset, not an import bug",
}

# every room dir name under <chapter>/scenes/
CHAPTERS = {
    "hotel": sorted(p.name for p in (SRC / "hotel/scenes").iterdir() if p.is_dir()),
    "carnival": sorted(p.name for p in (SRC / "carnival/scenes").iterdir() if p.is_dir()),
}
ROOM_FILES = ["background.png", "foreground.png"]

PHASE0_FILES = [
    ("hotel/scenes/room_09/background.png", "data/hotel/room_09/background.png"),
]

# Phase 1: the canonical per-room script manifests (scooby_scene_manifest.py
# output) -- the behaviour source consumed by main_gameplay / room_behavior_runner.
PHASE1_FILES = [
    ("global/scene_manifest_hotel.json", "data/global/scene_manifest_hotel.json"),
    ("global/scene_manifest_carnival.json", "data/global/scene_manifest_carnival.json"),
]


def png_dims(path: Path):
    """IHDR width/height without needing PIL -- just for the size report."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    w, h = struct.unpack(">II", data[16:24])
    return w, h


def copy_rooms():
    n_ok = n_missing = n_gap = 0
    for chapter, rooms in CHAPTERS.items():
        for room in rooms:
            for fn in ROOM_FILES:
                rel = f"{chapter}/scenes/{room}/{fn}"
                src = SRC / rel
                dst = DST / "data" / chapter / room / fn
                if not src.exists():
                    print("  MISSING: %s" % rel)
                    n_missing += 1
                    continue
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dst)
                if rel in KNOWN_GAPS:
                    print("  ** KNOWN GAP ** %s -- %s" % (rel, KNOWN_GAPS[rel]))
                    n_gap += 1
                n_ok += 1
    print("\nrooms: %d files copied, %d missing, %d known gaps (imported anyway, flagged)"
          % (n_ok, n_missing, n_gap))


def copy_list(files):
    for rel_src, rel_dst in files:
        src = SRC / rel_src
        dst = DST / rel_dst
        if not src.exists():
            print("MISSING (skipped): %s" % src)
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        print("copied %s -> %s" % (src, dst))


def main():
    copy_list(PHASE0_FILES)
    print()
    copy_rooms()
    print()
    copy_list(PHASE1_FILES)


if __name__ == "__main__":
    main()
