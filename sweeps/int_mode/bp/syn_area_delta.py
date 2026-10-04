#!/usr/bin/env python3
"""Area / slack delta between two DC runs of the single-PE CSA array.

Reads area.rpt (hierarchical) and timing.rpt from each run directory and
prints total cell area, the top-level blocks (u_pe, u_pe/u_array_core,
u_peripheral, u_peripheral/u_sc, u_combiner, u_a_rng, u_w_rng, top-level
glue), worst slack overall, worst register-to-register slack, and worst
slack of paths that start at each INT input port.

Usage: syn_area_delta.py BASE_RUN_DIR NEW_RUN_DIR [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

BLOCKS = ("u_pe", "u_pe/u_array_core", "u_peripheral", "u_peripheral/u_sc",
          "u_combiner", "u_a_rng", "u_w_rng")


def area(run: Path) -> dict:
    text = (run / "area.rpt").read_text()
    out = {}
    m = re.search(r"Total cell area:\s+([0-9.]+)", text)
    out["total"] = float(m[1])
    out["combinational"] = float(re.search(r"Combinational area:\s+([0-9.]+)", text)[1])
    out["noncombinational"] = float(re.search(r"Noncombinational area:\s+([0-9.]+)", text)[1])
    top_local = None
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 6 and f[0] in BLOCKS and f[0] not in out:
            out[f[0]] = float(f[1])
        if top_local is None and len(f) >= 6 and f[0].startswith("payn_array_signed_segmented_csa"):
            top_local = float(f[3]) + float(f[4])
    out["top_local_glue"] = top_local
    out["top_level_clock_gates_and_glue"] = out["total"] - sum(
        out.get(b, 0.0) for b in ("u_pe", "u_peripheral", "u_combiner", "u_a_rng", "u_w_rng"))
    return out


def timing(run: Path) -> dict:
    text = (run / "timing.rpt").read_text()
    worst = None
    worst_r2r = None
    worst_by_port: dict[str, float] = {}
    for block in re.split(r"\n\s*Startpoint: ", text)[1:]:
        # Long names push the "(input port ...)" description to the next line.
        sm = re.match(r"(\S+)\s*\(([^)]*)\)", block)
        if not sm:
            continue
        name, kind = sm[1], sm[2]
        m = re.search(r"slack \((?:MET|VIOLATED)\)\s+(-?[0-9.]+)", block)
        if not m:
            continue
        slack = float(m[1])
        worst = slack if worst is None else min(worst, slack)
        if "input port" in kind:
            port = re.sub(r"\[\d+\]$", "", name)
            worst_by_port[port] = min(worst_by_port.get(port, slack), slack)
        else:
            # Register start; timing.rpt is truncated, so this is the worst
            # register-start path it lists (the DC probe reports the true one).
            worst_r2r = slack if worst_r2r is None else min(worst_r2r, slack)
    return dict(worst_slack=worst, worst_reg_to_reg_slack=worst_r2r,
                worst_slack_by_input_port=worst_by_port)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", type=Path)
    ap.add_argument("new", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    args = ap.parse_args()
    base, new = area(args.base), area(args.new)
    tb, tn = timing(args.base), timing(args.new)
    rows = []
    print(f"{'block':34s} {'base um2':>12s} {'new um2':>12s} {'delta um2':>11s} {'delta %':>8s}")
    for key in ("total", "combinational", "noncombinational") + BLOCKS + ("top_level_clock_gates_and_glue",):
        b, n = base.get(key), new.get(key)
        d = None if b is None or n is None else n - b
        pct = None if d is None or not b else 100.0 * d / b
        rows.append(dict(block=key, base=b, new=n, delta=d, delta_pct=pct))
        fmt = lambda x, w, p: f"{x:{w}.{p}f}" if x is not None else f"{'-':>{w}s}"
        print(f"{key:34s} {fmt(b, 12, 3)} {fmt(n, 12, 3)} {fmt(d, 11, 3)} {fmt(pct, 8, 2)}")
    print(f"worst slack (ns): base {tb['worst_slack']}  new {tn['worst_slack']}")
    print(f"worst register-start slack in timing.rpt (ns): base {tb['worst_reg_to_reg_slack']}  new {tn['worst_reg_to_reg_slack']}")
    for port in ("int_mode", "ring_in", "int_prec", "a_raw_in", "w_raw_in", "shift_in", "mac_en",
                 "a_binary_in", "w_binary_in", "load_a", "load_w", "reset"):
        print(f"worst slack from input {port}: base {tb['worst_slack_by_input_port'].get(port)}  "
              f"new {tn['worst_slack_by_input_port'].get(port)}")
    if args.json_path:
        args.json_path.write_text(json.dumps(dict(base=str(args.base), new=str(args.new), rows=rows,
                                                  timing_base=tb, timing_new=tn), indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
