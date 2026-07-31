#!/usr/bin/env python3
# carver-tool
"""Recover object behaviours that are NESTED inside a state conditional.

The scene-manifest bake only walks TOP-LEVEL op-01 guards on each object's
script. But the ROM commonly wraps an object's REAL handlers in a state test:

    op 0x04 IF <state>  THEN            <- if_compare_then_block
         op 0x01 guard OPEN  -> the real "open it" block
         op 0x01 guard SHUT  -> the real "shut it" block
    op 0x01 guard OPEN  -> "It's already open."     <- fallback, top level
    op 0x01 guard EVENT -> the exit
    op 0x01 guard SHUT  -> the real shut machinery

so the manifest kept only the FALLBACK. That is exactly why the lobby's Outside
Door answered "It's already open." forever and its exit was passable from the
start -- the port never had the guarded branch.

This walks EVERY script (per-room and unlinked, both chapters) to any depth,
emits each nested guard as a behaviour whose actions are wrapped in the
enclosing condition(s) -- {"op":"if_compare_then_block","condition":...,
"then":[...]} -- which room_behavior_runner already evaluates. Merged by
main_gameplay._behaviors_of, so nested handlers now run with their real gate.

Emits assets/data/global/nested_behaviors_<chapter>.json
    { "<entity_id>": [ {verb_code, sel2, actions, depth}, ... ] }
"""
from __future__ import annotations
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, r"D:/scoobydoo/exporters")
from scooby_script_decode import decode_actions, compare_mode, op_int  # ROM-cited decoder

SCRIPTS = r"D:/scoobydoo/analysis/scripts.json"
CTXROOMS = r"D:/scoobydoo/analysis/context_rooms.json"
ICON = r"D:/scoobydoo/analysis/icon_items.json"
OUT = os.path.join(os.path.dirname(HERE), "assets", "data", "global")
ROM = open(r"D:/blastem/blastem-win32-0.6.2/Scooby Doo Mystery (JUE) [!].bin", "rb").read()
STR_BASE = {"hotel": 0x14199C, "carnival": 0x1AF33C}


def ctx2ent():
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
    walk(json.load(open(CTXROOMS, encoding="utf-8")))
    return out


def cond_of(node):
    """Decoded condition dict for an op 0x03/0x04 node, or None."""
    a = [op_int(x) for x in node.get("operands", [])]
    if len(a) < 7:
        return None
    ls, rs, cmp_op = compare_mode(a[6])
    return {"left": {"source": ls, "index": a[2], "selector": a[3]},
            "right": {"source": rs, "index": a[4], "selector": a[5]},
            "comparator": cmp_op}


def build(chapter):
    sc = json.load(open(SCRIPTS, encoding="utf-8"))["clusters"][chapter]
    icon = json.load(open(ICON, encoding="utf-8"))["chapters"][chapter]
    name2ent = {it["item"].upper(): int(it["entity_id"]) for it in icon}
    c2e = ctx2ent()
    strblk = STR_BASE[chapter]

    def read_string(off):
        o = strblk + off
        s = []
        while 0 <= o < len(ROM) and ROM[o] and len(s) < 200:
            if not (32 <= ROM[o] < 127):
                return ""
            s.append(chr(ROM[o])); o += 1
        return "".join(s)

    out = {}
    n_nested = 0

    def scan(ops, ent, stack):
        """Walk ops; op-01 guards found with a non-empty condition stack are the
        ones the manifest missed."""
        nonlocal n_nested
        for n in ops or []:
            op = op_int(n.get("op"))
            nested = n.get("nested") or []
            if op == 0x01:
                a = [op_int(x) for x in n.get("operands", [])]
                if stack and nested and len(a) >= 2:
                    acts = decode_actions(nested, read_string=read_string)
                    for c in reversed(stack):          # innermost condition first
                        acts = [{"op": "if_compare_then_block", "condition": c,
                                 "then": acts}]
                    out.setdefault(str(ent), []).append(
                        {"verb_code": a[0], "sel2": a[1], "actions": acts,
                         "depth": len(stack)})
                    n_nested += 1
                scan(nested, ent, stack)               # guards can nest further
            elif op in (0x03, 0x04):
                c = cond_of(n)
                scan(nested, ent, stack + ([c] if c else []))
            else:
                scan(nested, ent, stack)

    def each_script(node):
        if isinstance(node, dict):
            if node.get("start") and node.get("ops") is not None:
                ent = c2e.get(node.get("context_id"))
                if ent is None and node.get("object"):
                    ent = name2ent.get(str(node["object"]).upper())
                if ent is not None:
                    scan(node["ops"], ent, [])
            for v in node.values():
                each_script(v)
        elif isinstance(node, list):
            for v in node:
                each_script(v)

    each_script(sc)
    p = os.path.join(OUT, "nested_behaviors_%s.json" % chapter)
    json.dump({"note": "Object behaviours nested inside state conditionals -- the "
                       "manifest bake only walks top-level op-01 guards, so these "
                       "(the REAL open/shut/use handlers) were missing and only the "
                       "fallback text survived. Actions are pre-wrapped in their "
                       "enclosing condition(s). tools/gen_nested_behaviors.py",
               "behaviors": out}, open(p, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print("%s: %d nested guards recovered across %d entities -> %s"
          % (chapter, n_nested, len(out), p))


if __name__ == "__main__":
    for c in ("hotel", "carnival"):
        build(c)
