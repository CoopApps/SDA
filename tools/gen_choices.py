#!/usr/bin/env python3
# carver-tool
"""Lift the dialogue-CHOICE data (script op $02 register_choice_option) from ROM.

Structure per the VERIFIED handler at ROM $25AC (ROM_MAP row 116), operand base
confirmed empirically (every label offset lands on a string start only for
base == the chapter dialogue string block):

    (2,A5).l   choice LABEL  = player's line   (offset into string block)
    (6,A5).l   NPC REPLY     = response line   (same base)
    (0xA,A5).w total operand length; inline BODY script = bytes [0xE, len)
    (0xC,A5).w slot word
    string blocks: hotel 0x14199C, carnival 0x1AF33C (analysis/dialogue.json)

Emits assets/data/global/choices_<chapter>.json:
    { "<entity_id>": [ {"at","label","reply","slot","body_hex"}, ... ] }
Entity attribution = containment of the op address in the scene manifest's
per-entity script [start,end) ranges. Unattributed sites go under "unlinked".
"""
from __future__ import annotations
import json, re, sys, os

ROM = r"D:/blastem/blastem-win32-0.6.2/Scooby Doo Mystery (JUE) [!].bin"
SCRIPTS = r"D:/scoobydoo/analysis/scripts.json"
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "assets", "data", "global")
BASES = {"hotel": 0x14199C, "carnival": 0x1AF33C}

rom = open(ROM, "rb").read()

def r16(o): return (rom[o] << 8) | rom[o + 1]
def r32(o): return (rom[o] << 24) | (rom[o + 1] << 16) | (rom[o + 2] << 8) | rom[o + 3]

def cstr(o, cap=200):
    if o < 0 or o >= len(rom):
        return ""
    s = []
    for i in range(min(cap, len(rom) - o)):
        c = rom[o + i]
        if c == 0:
            break
        if not (32 <= c < 127):
            return ""            # binary data, not a dialogue string
        s.append(chr(c))
    return "".join(s)

def op02_sites():
    sc = json.load(open(SCRIPTS, encoding="utf-8"))
    sites = []
    def walk(o, chap=None):
        if isinstance(o, dict):
            if str(o.get("op", "")).lower() == "0x02" and o.get("at"):
                sites.append((chap, int(o["at"], 16)))
            for k, v in o.items():
                walk(v, k if k in ("hotel", "carnival") else chap)
        elif isinstance(o, list):
            for v in o:
                walk(v, chap)
    walk(sc.get("clusters", {}))
    return sorted(set(sites), key=lambda x: x[1])

def entity_ranges(chapter):
    """(start, end, entity_id, name, room_id) from the port's scene manifest
    (scenes is a dict keyed by room id; entities under 'objects')."""
    p = os.path.join(OUT_DIR, "scene_manifest_%s.json" % chapter)
    m = json.load(open(p, encoding="utf-8"))
    out = []
    for rid, scene in m.get("scenes", {}).items():
        for ent in scene.get("objects", []):
            s = ent.get("script") or {}
            if s.get("start") and s.get("end"):
                out.append((int(s["start"], 16), int(s["end"], 16),
                            ent.get("entity_id"), ent.get("name"), rid))
    return out

# --- inline consequence-script (body) decoder --------------------------------
# The bytes after a choice's 14-byte op-$02 header, up to total_len, are a normal
# script fragment in the SAME 34-opcode VM as everything else (dispatcher 0x2406,
# table 0x2354). We decode them into the exact event shape room_behavior_runner.gd
# consumes, so a picked choice actually runs its consequence. Op names + fixed
# lengths are the grounded values from analysis/opcodes.json / gameplay_spec.json.
OP_LEN = {  # bytes AFTER the opcode word (so total op size = 2 + this)
    0x00: 0, 0x01: 6, 0x03: 14, 0x04: 14, 0x05: 4, 0x06: 4, 0x07: 2, 0x08: 10,
    0x09: 4, 0x0A: 4, 0x0B: 4, 0x0C: 2, 0x0D: 2, 0x0E: 8, 0x0F: 10, 0x10: 6,
    0x11: 6, 0x12: 4, 0x13: 2, 0x14: 4, 0x15: 2, 0x16: 2, 0x17: 2, 0x18: 6,
    0x19: 2, 0x1A: 8, 0x1B: 10, 0x1C: 2, 0x1D: 2, 0x1E: 4, 0x1F: 2, 0x20: 2,
}
OP_NAME = {
    0x00: "nop", 0x05: "move_actor_to_room", 0x06: "start_anim_sequence_and_wait",
    0x07: "mark_object_present", 0x08: "assign_flagbit_or_actor_field",
    0x09: "actor_set_byte_field_and_refresh", 0x0A: "set_actor_icon_id",
    0x0B: "actor_set_word0_and_raise_pending_flag", 0x0D: "queue_sound_driver_id",
    0x0E: "move_actor_to_waypoint", 0x10: "draw_text_message_and_wait",
    0x11: "change_scene_with_palette_fadeout", 0x12: "set_actor_asset_id",
    0x14: "set_actor_shape_index", 0x15: "wait_n_frames",
    0x17: "wait_until_anim_channel_signalled", 0x18: "load_room_at_entry_with_facing",
    0x19: "resume_anim_channel_wait_drawn", 0x1A: "set_palette_cycle_channel",
    0x1B: "move_actor_to_xy", 0x1F: "wait_while_channel_busy",
    0x20: "stop_script_slot",
}


def decode_body(start, end, strblk):
    """Walk [start,end) as a script fragment -> list of runner events. Unknown
    ops emit {op:'raw_%02X', raw:...} so nothing is silently dropped."""
    a5, out, guard = start, [], 0
    while a5 + 1 < end and guard < 400:
        guard += 1
        op = r16(a5)
        if op > 0x21:
            break
        ln = OP_LEN.get(op)
        if ln is None:
            out.append({"op": "raw_%02X" % op, "at": "0x%06X" % a5})
            break
        name = OP_NAME.get(op, "op_%02X" % op)
        ev = {"op": name}
        if op == 0x10:                                   # draw_text
            off = r32(a5 + 4)
            ev["flag_word"] = r16(a5 + 2)
            ev["text_offset"] = "0x%X" % off
            ev["text"] = cstr(strblk + off) or ""
        elif op in (0x1B, 0x0E):                         # move_actor_to_xy / waypoint
            ev["actor"] = r16(a5 + 2) & 0x7FFF
            if op == 0x1B:
                ev["x"], ev["y"] = r16(a5 + 6), r16(a5 + 8)
            else:
                ev["anim"] = r16(a5 + 6); ev["waypoint"] = r16(a5 + 8)
        elif op == 0x05:                                 # move_actor_to_room
            ev["actor"], ev["room"] = r16(a5 + 2) & 0x7FFF, r16(a5 + 4)
        elif op == 0x06:                                 # start_anim
            ev["actor"] = r16(a5 + 2) & 0x7FFF; ev["seq"] = r16(a5 + 4)
        elif op in (0x12, 0x14):                         # set asset/shape
            ev["actor"] = r16(a5 + 2) & 0x7FFF; ev["value"] = r16(a5 + 4)
        elif op == 0x0B:                                 # actor word0
            ev["actor"] = r16(a5 + 2) & 0x7FFF; ev["value"] = r16(a5 + 4)
        elif op == 0x15:                                 # wait_n_frames
            ev["frames"] = r16(a5 + 2)
        elif op == 0x0D:                                 # sound
            ev["sound"] = r16(a5 + 2) & 0x7FFF
        elif op == 0x08:                                 # assign flag/field
            ev["dest_index"] = r16(a5 + 2); ev["dest_bit"] = r16(a5 + 4)
            ev["src_index"] = r16(a5 + 6); ev["src_bit"] = r16(a5 + 8)
        elif op == 0x18:                                 # load room
            ev["room"] = r16(a5 + 2); ev["entry"] = r16(a5 + 4); ev["facing"] = r16(a5 + 6)
        elif op == 0x11:                                 # change scene
            ev["scene"] = r16(a5 + 2); ev["facing"] = r16(a5 + 6)
        elif op == 0x1A:                                 # palette-cycle channel
            ev["operands"] = [r16(a5 + 2), r16(a5 + 4), r16(a5 + 6), r16(a5 + 8)]
        else:
            ev["raw"] = rom[a5:a5 + 2 + ln].hex()
        out.append(ev)
        a5 += 2 + ln
    return out


def main():
    per_chapter = {"hotel": {}, "carnival": {}}
    counts = {"hotel": 0, "carnival": 0}
    ranges = {c: entity_ranges(c) for c in per_chapter}
    for chap, at in op02_sites():
        if chap not in BASES:
            continue
        base = BASES[chap]
        lab_off, sec_off = r32(at + 2), r32(at + 6)
        ln, slot = r16(at + 0xA), r16(at + 0xC)
        label, reply = cstr(base + lab_off), cstr(base + sec_off)
        if not label:            # non-dialogue use of the thread scheduler
            continue
        body = rom[at + 0xE: at + ln].hex() if ln > 0xE else ""
        actions = decode_body(at + 0xE, at + ln, base) if ln > 0xE else []
        ent_id, ent_name, room_id = None, None, None
        for s, e, eid, nm, rid in ranges[chap]:
            if s <= at < e:
                ent_id, ent_name, room_id = eid, nm, rid
                break
        key = str(ent_id) if ent_id is not None else "unlinked"
        rec = {"at": "0x%06X" % at, "label": label, "reply": reply,
               "slot": slot, "body_hex": body, "actions": actions}
        if ent_name:
            rec["entity_name"] = ent_name
        if room_id is not None:
            rec["room_id"] = int(room_id)
        per_chapter[chap].setdefault(key, []).append(rec)
        counts[chap] += 1
    for chap, data in per_chapter.items():
        out = {"note": "dialogue choices lifted from script op $02 (ROM $25AC, "
                       "ROM_MAP row 116); label=player line, reply=NPC line, "
                       "actions=decoded inline consequence script (34-op VM, "
                       "room_behavior_runner event shape); body_hex kept for "
                       "reference. String base %s." % ("0x%06X" % BASES[chap]),
               "choices": data}
        p = os.path.join(OUT_DIR, "choices_%s.json" % chap)
        json.dump(out, open(p, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
        print("%s: %d choices, %d entities -> %s"
              % (chap, counts[chap], len(data), p))

if __name__ == "__main__":
    sys.exit(main())
