#!/usr/bin/env python3
"""Table of the BP-hybrid RTL runs (run_bp_hybrid_checks.sh) next to the model's
T1 (as built) and T3 (in-place doubling) numbers, plus closed-form points.

Hybrid (TA activation bits, TW weight bits in time per tile) block period:
    TA*TW*NB + 8*(TA+TW-2) + (P_R+P_C-2) + 8*P_C
    outputs per PE = (8 / (BA/TA)) * (8 / (BW/TW))
Range: |Afield| * |Wfield| * L < 2^23 (24-bit tile), split into blocks beyond.
Area: the routed csa_bp_20261004_lap composite (same as T1; no RTL change; the
east-edge combine differs from T1's, as T2's Horner does, and is not costed).

Usage:  hybrid_periods.py [OUT_DIR]     (default build/rtl_preflight/bp_hybrid)
Exit 1 if a measured period differs from the closed form.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model_lap_schedules as m  # noqa: E402

PREC = {"INT8": (8, 8), "W4A8": (8, 4), "INT4": (4, 4)}


def hyb(prec, ta, tw, L, pr, pc):
    ba, bw = PREC[prec]
    ga, gw = ba // ta, bw // tw
    outs = (8 // ga) * (8 // gw)
    amax = (1 << ta) - 1 if ga > 1 else 1 << (ta - 1)
    wmax = (1 << tw) - 1 if gw > 1 else 1 << (tw - 1)
    lmax = ((1 << 23) - 1) // (amax * wmax)
    lsub_max = (lmax // 128) * 128
    nsplit = math.ceil(L / lsub_max)
    nb_tot = math.ceil(L / 128)
    per = ta * tw * nb_tot + nsplit * (8 * (ta + tw - 2) + pr + pc - 2 + 8 * pc)
    peak = 128 // (ba * bw)
    pct = outs * L / (64 * peak * per)
    return dict(period=per, outs=outs, nsplit=nsplit, pct=pct, lmax=lmax)


def gm(prec, shape, outs, L, per):
    pr, pc = m.SHAPES[shape]
    ar, _ = m.area(m.Sch("T1"), prec, shape)
    return m.gmacs(pr * pc * outs * L, per, ar)


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else m.REPO / "build/rtl_preflight/bp_hybrid"
    bad = 0
    print("RTL runs (nominal, passing): measured block period vs closed form")
    print(f"  {'case':46s} {'grid':4s} {'prec':4s} TA TW {'L':>5s} out/PE period spacing formula  %peak  e/8o")
    for p in sorted((out / "hyb").glob("*/check.json")):
        d = json.loads(p.read_text())
        if d["mode"] != "nominal":
            continue
        pr, pc = map(int, d["grid"].split("x"))
        f = d["TA"] * d["TW"] * d["nb"] + 8 * (d["TA"] + d["TW"] - 2) + pr + pc - 2 + 8 * pc
        ok = d["status"] == "PASS" and d["block_len"] == f and all(x == f for x in d["measured_periods"])
        bad += not ok
        print(f"  {p.parent.name:46s} {d['grid']:4s} {d['precision']:4s} {d['TA']:2d} {d['TW']:2d} {d['L']:5d} "
              f"{d['outputs_per_pe']:6d} {d['block_len']:6d} {str(d['measured_periods']):>7s} {f:7d} "
              f"{d['pct_peak']:5.1f}% {d['edges_per_8_outputs_per_pe']:6.1f} {'ok' if ok else 'MISMATCH'}")

    print("\nClosed form, % of peak / GMAC/s/mm2 (routed csa_bp_20261004_lap areas; T3 = model, synthesized"
          " IPD delta, estimate)")
    m.T3SRC.update(mode="placeholder")
    ipd = m.REPO / m.IPD_JSON
    if ipd.exists():
        js = json.loads(ipd.read_text())       # same source and rule as model_lap_schedules.main()
        ri, rl = js["routed_ipd_estimate"], js["routed_lap"]
        m.T3SRC.update(mode="ipd", d_pe=ri["u_pe"] - rl["u_pe"], d_periph=ri["u_peripheral"] - rl["u_peripheral"],
                       d_total=ri["total"] - rl["total"])
    pts = [("INT8", [(1, 8, "T1 map"), (2, 8, ""), (4, 4, ""), (4, 8, ""), (8, 4, ""), (8, 8, "")]),
           ("W4A8", [(1, 4, "T1 map"), (4, 4, ""), (8, 4, "")]),
           ("INT4", [(1, 4, "T1 map"), (2, 4, ""), (4, 4, "")])]
    for prec, maps in pts:
        for shape in ("1PE", "4x4", "4x8"):
            pr, pc = m.SHAPES[shape]
            for L in (128, 1024, 4096, 16384):
                cells = []
                t1 = m.schedule(m.Sch("T1"), prec, L, pr, pc)
                t3 = m.schedule(m.Sch("T3"), prec, L, pr, pc)
                ar3, _ = m.area(m.Sch("T3"), prec, shape)
                cells.append(f"T1 {100 * t1['pct']:5.1f}%/{gm(prec, shape, t1['outs'], L, t1['period']):6,.0f}")
                cells.append(f"T3 {100 * t3['pct']:5.1f}%/{m.gmacs(t3['macs'], t3['period'], ar3):6,.0f}")
                for ta, tw, _ in maps[1:]:
                    h = hyb(prec, ta, tw, L, pr, pc)
                    cells.append(f"({ta},{tw}) {100 * h['pct']:5.1f}%/{gm(prec, shape, h['outs'], L, h['period']):6,.0f}"
                                 + (f"x{h['nsplit']}" if h["nsplit"] > 1 else "  "))
                print(f"  {prec:4s} {shape:3s} L={L:5d}  " + "  ".join(cells))
    print("\n(TA,TW): outputs/PE = (8/(BA/TA))*(8/(BW/TW)); xN = split into N blocks by the 24-bit tile range.")
    print("RTL-validated points are listed above; the rest use the same closed form.")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
