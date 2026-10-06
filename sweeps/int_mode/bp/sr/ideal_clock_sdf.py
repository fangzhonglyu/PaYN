#!/usr/bin/env python3
"""Ideal-clock copy of a DC (pre-CTS) SDF for gate-level activity simulation.

Design Compiler leaves clock networks unbuffered and times them as ideal, but
it still writes the cell delay of every clock-gating cell into the SDF.  On
the PaYN netlists each PREICG_X0P5B drives up to ~600 flop clock pins, so
the SDF gives it a CK->ECK delay of up to 3.36 ns, longer than the 1.25 ns
clock pulse at 400 MHz.  VCS's inertial delay then swallows the pulse, the
gated clocks never fire (the tile accumulators keep their power-up X through
reset), and the simulation is not the circuit DC timed.

This writes a copy of the SDF in which only the IOPATH delays of the
clock-gating cells (CELLTYPE matching --icg, default PREICG*) are zero: the
clock reaches every flop at the edge, exactly as in DC's ideal-clock STA, and
every data-path delay (flop CK->Q, logic, DC's wire-load interconnect) is
kept.  It checks that every INTERCONNECT from the clk port is already zero
(the clock net itself is ideal) and refuses otherwise.  A JSON record lists
the edited cells and their original delays.

  ideal_clock_sdf.py IN.sdf OUT.sdf [--json OUT.json] [--icg PREICG]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

TRIPLE = re.compile(r"\((-?[0-9.]+):(-?[0-9.]+):(-?[0-9.]+)\)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sdf_in", type=Path)
    ap.add_argument("sdf_out", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    ap.add_argument("--icg", default="PREICG", help="CELLTYPE prefix of the clock-gating cells")
    args = ap.parse_args()
    if args.sdf_out.exists():
        raise SystemExit(f"{args.sdf_out} exists; refusing to overwrite")
    text = args.sdf_in.read_text()
    lines = text.splitlines(keepends=True)

    out, cells, edited_lines = [], [], 0
    in_icg = False
    cur = None
    clk_ic_nonzero = []
    for line in lines:
        s = line.strip()
        m = re.match(r'\(CELLTYPE "([^"]+)"\)', s)
        if m:
            in_icg = m[1].startswith(args.icg)
            cur = {"celltype": m[1], "instance": None, "rise_ns": [], "fall_ns": []} if in_icg else None
            if in_icg:
                cells.append(cur)
        elif in_icg and s.startswith("(INSTANCE "):
            cur["instance"] = s[len("(INSTANCE "):].rstrip(")")
        if s.startswith("(INTERCONNECT clk "):
            vals = [float(v) for t in TRIPLE.findall(s) for v in t]
            if any(v != 0.0 for v in vals):
                clk_ic_nonzero.append(s)
        if in_icg and "IOPATH" in s:
            trip = TRIPLE.findall(s)
            if trip:
                cur["rise_ns"].append(float(trip[0][2]))
                if len(trip) > 1:
                    cur["fall_ns"].append(float(trip[1][2]))
                line = TRIPLE.sub("(0.000:0.000:0.000)", line)
                edited_lines += 1
        out.append(line)
    if clk_ic_nonzero:
        raise SystemExit(f"{len(clk_ic_nonzero)} INTERCONNECT entries from clk are not zero, e.g. {clk_ic_nonzero[0]}")
    if not cells:
        raise SystemExit(f"no {args.icg}* cells in {args.sdf_in}")
    if any(not c["rise_ns"] for c in cells):
        raise SystemExit("a clock-gating cell has no IOPATH entry")
    args.sdf_out.parent.mkdir(parents=True, exist_ok=True)
    args.sdf_out.write_text("".join(out))
    rise = [max(c["rise_ns"]) for c in cells]
    fall = [max(c["fall_ns"]) for c in cells if c["fall_ns"]]
    rec = {
        "sdf_in": str(args.sdf_in), "sdf_in_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "sdf_out": str(args.sdf_out),
        "sdf_out_sha256": hashlib.sha256(args.sdf_out.read_bytes()).hexdigest(),
        "icg_prefix": args.icg, "icg_cells": len(cells), "iopath_lines_zeroed": edited_lines,
        "max_original_rise_ns": max(rise), "max_original_fall_ns": max(fall) if fall else None,
        "cells_with_rise_over_1p25ns": sum(r > 1.25 for r in rise),
        "clk_interconnects_all_zero": True,
        "cells": cells,
    }
    if args.json_path:
        args.json_path.write_text(json.dumps(rec, indent=2) + "\n")
    print(f"ideal-clock SDF: {len(cells)} {args.icg}* cells, {edited_lines} IOPATH lines zeroed "
          f"(original CK->ECK rise up to {max(rise):.3f} ns, {rec['cells_with_rise_over_1p25ns']} cells "
          f"above the 1.25 ns clock pulse); clk interconnects all zero; every other delay unchanged -> {args.sdf_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
