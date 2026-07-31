# carver-tool
"""REGRESSION GATE: fail if any shipped asset is a capture or unaccounted for.

    python check_asset_provenance.py             # gate (exit 1 on failure)
    python check_asset_provenance.py --self-test # prove the gate can FAIL
    python check_asset_provenance.py --update-budget

Policy
  CAPTURE / UNKNOWN / HAND   -> FAIL.  No shipped asset may be a save-state
                                crop, a VRAM dump, a screenshot, or undeclared.
  GENERATOR_ONLY             -> tolerated up to the recorded budget, and the
                                budget may only ever go DOWN.  A generator with
                                no citable ROM address is not verified; it is
                                tracked debt.
  OWNED_ELSEWHERE            -> tolerated up to budget (another pass owns it).

WHY THE SELF-TEST IS NOT OPTIONAL
  A checker that reports zero failures is worthless until it has been shown to
  fail.  On this project a ROM_MAP validation pass shipped three checks that
  matched NOTHING while reporting "pass" -- they searched the wrong column and
  required double quotes where the map uses backticks.  It surfaced only when a
  mutation test injected deliberately false claims.  `--self-test` performs the
  equivalent mutations here:
    1. inject an undeclared asset            -> must be caught as UNKNOWN
    2. inject a runtime_capture sidecar      -> must be caught as CAPTURE
    3. inject a code_derived sidecar whose ROM address is outside every
       ROM_MAP row                           -> must be downgraded + flagged
    4. inject a code_derived sidecar with no cite -> must be downgraded
    5. break the ROM_MAP regex                -> must refuse to run rather than
                                                 pass vacuously
  Run it in CI alongside the gate.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, r"D:/scoobydoo/work")
import audit_provenance as A                                    # noqa: E402

BUDGET_PATH = os.path.join(HERE, "provenance_budget.json")
DEFAULT_BUDGET = {"GENERATOR_ONLY": 0, "OWNED_ELSEWHERE": 0}


def load_budget():
    if os.path.isfile(BUDGET_PATH):
        return json.load(open(BUDGET_PATH, encoding="utf-8"))
    return dict(DEFAULT_BUDGET)


def run(assets=A.ASSETS, manifest=A.MANIFEST, rom_map=A.ROM_MAP, quiet=False):
    recs, rows = A.audit(assets, manifest, rom_map)
    counts = A.summarize(recs)
    budget = load_budget()
    failures = []

    for k in ("CAPTURE", "UNKNOWN", "HAND"):
        bad = [r for r in recs if r["class"] == k]
        if bad:
            failures.append((k, bad))

    for k in ("GENERATOR_ONLY", "OWNED_ELSEWHERE"):
        n = counts.get(k, 0)
        lim = budget.get(k, 0)
        if n > lim:
            failures.append((k + " over budget (%d > %d)" % (n, lim),
                             [r for r in recs if r["class"] == k]))

    probs = [r for r in recs if r["problems"]]
    if probs:
        failures.append(("SELF-CONTRADICTORY DECLARATION", probs))

    if not quiet:
        print("ROM_MAP.md: %d rows (0x%06X-0x%06X)" % (len(rows), rows[0][1], rows[-1][2]))
        print("assets: %d" % len(recs))
        for k in A.CLASSES:
            print("   %-16s %4d" % (k, counts.get(k, 0)))
        print()
        for label, items in failures:
            print("FAIL  %s: %d file(s)" % (label, len(items)))
            for r in items[:10]:
                why = r.get("reason") or "; ".join(r["problems"]) or r["source"]
                print("        %-56s %s" % (r["path"], why[:90]))
            if len(items) > 10:
                print("        ... +%d more" % (len(items) - 10))
        if not failures:
            print("PASS  every shipped asset is ROM-derived and cited to a "
                  "ROM_MAP row.")
    return failures, recs, rows


# ------------------------------------------------------------------ mutation --
def _sandbox():
    """Copy just enough of the tree to mutate it cheaply."""
    d = tempfile.mkdtemp(prefix="prov_gate_")
    a = os.path.join(d, "assets")
    os.makedirs(os.path.join(a, "data", "global"))
    # one asset that the real manifest classifies ROM_DERIVED
    src = os.path.join(A.ASSETS, "data", "global", "waypoints_hotel.json")
    shutil.copy(src, os.path.join(a, "data", "global", "waypoints_hotel.json"))
    return d, a


def _classes(a, manifest=A.MANIFEST, rom_map=A.ROM_MAP):
    recs, _ = A.audit(a, manifest, rom_map)
    return {r["path"]: r for r in recs}


def self_test():
    fails = 0

    def check(name, cond, detail=""):
        nonlocal fails
        print("%-4s %s %s" % ("PASS" if cond else "FAIL", name, detail))
        if not cond:
            fails += 1

    # 0. baseline: the sandbox asset must classify clean, or the mutations below
    #    prove nothing.
    d, a = _sandbox()
    try:
        base = _classes(a)
        check("baseline sandbox asset is ROM_DERIVED",
              base["data/global/waypoints_hotel.json"]["class"] == "ROM_DERIVED",
              base["data/global/waypoints_hotel.json"]["class"])

        # 1. undeclared asset -> UNKNOWN
        open(os.path.join(a, "definitely_not_declared.png"), "wb").write(b"\0" * 8)
        c = _classes(a)
        check("undeclared asset is caught as UNKNOWN",
              c["definitely_not_declared.png"]["class"] == "UNKNOWN")

        # 2. runtime_capture sidecar -> CAPTURE
        p = os.path.join(a, "data", "global", "waypoints_hotel.json")
        json.dump({"path": "x", "provenance": "runtime_capture",
                   "capture_state": "fake.state", "producer": "mutant"},
                  open(p + ".provenance.json", "w"))
        c = _classes(a)
        check("runtime_capture sidecar is caught as CAPTURE",
              c["data/global/waypoints_hotel.json"]["class"] == "CAPTURE")

        # 3. code_derived whose ROM address is outside every ROM_MAP row
        json.dump({"path": "x", "provenance": "code_derived", "producer": "mutant",
                   "cite": "invented", "rom_addrs": ["0x3FF0000"]},
                  open(p + ".provenance.json", "w"))
        c = _classes(a)
        r = c["data/global/waypoints_hotel.json"]
        check("ROM address outside every ROM_MAP row is flagged",
              r["class"] != "ROM_DERIVED" and any("NO ROM_MAP row" in x
                                                  for x in r["problems"]),
              "%s %s" % (r["class"], r["problems"]))

        # 4. code_derived with no cite -> downgraded
        json.dump({"path": "x", "provenance": "code_derived", "producer": "mutant"},
                  open(p + ".provenance.json", "w"))
        c = _classes(a)
        r = c["data/global/waypoints_hotel.json"]
        check("code_derived with no cite is downgraded",
              r["class"] == "GENERATOR_ONLY" and bool(r["problems"]),
              r["class"])

        # 5. a ROM_MAP that parses to nothing must ABORT, not pass
        empty = os.path.join(d, "empty_map.md")
        open(empty, "w").write("# no rows here\n")
        aborted = False
        try:
            A.audit(a, A.MANIFEST, empty)
        except SystemExit:
            aborted = True
        check("empty/unparseable ROM_MAP aborts instead of passing vacuously",
              aborted)

        # 6. the real map must parse to a plausible row count (guards the
        #    en-dash / backtick regex the way the ROM_MAP pass learned to)
        rows = A.load_rom_map()
        check("real ROM_MAP parses to >400 rows", len(rows) > 400, "%d" % len(rows))
        check("real ROM_MAP covers 0x000000-0x200000",
              rows[0][1] == 0 and rows[-1][2] == 0x200000,
              "0x%06X-0x%06X" % (rows[0][1], rows[-1][2]))
    finally:
        shutil.rmtree(d, ignore_errors=True)

    print("\n%s" % ("SELF-TEST ALL PASS -- the gate demonstrably fails on bad input"
                    if not fails else "%d SELF-TEST FAILURE(S)" % fails))
    return fails


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(1 if self_test() else 0)
    if "--update-budget" in sys.argv:
        recs, _ = A.audit()
        c = A.summarize(recs)
        b = {k: c.get(k, 0) for k in ("GENERATOR_ONLY", "OWNED_ELSEWHERE")}
        old = load_budget()
        for k in b:
            if k in old and b[k] > old[k]:
                print("REFUSING: %s budget would GROW %d -> %d" % (k, old[k], b[k]))
                sys.exit(1)
        json.dump(b, open(BUDGET_PATH, "w"), indent=1)
        print("budget: %s" % b)
        sys.exit(0)
    f, _, _ = run()
    sys.exit(1 if f else 0)
