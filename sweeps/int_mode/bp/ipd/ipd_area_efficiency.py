#!/usr/bin/env python3
"""GMAC/s/mm2 of the in-place-doubling BP variant (T3), ESTIMATED from synthesis.

The IPD netlist is synthesized, not routed.  Its routed area is estimated by
adding the synthesized delta (csa_bp_ipd_20261004 - csa_bp_20261004_lap, same
target knobs) to the routed pinned csa_bp_20261004_lap areas, block by block:

    routed_IPD(block) ~= routed_lap(block) + syn_IPD(block) - syn_lap(block)

for the total, u_pe, u_peripheral, u_combiner and the Sobol pair.  A ratio
scaling (routed_lap * syn_IPD / syn_lap) is printed as a sensitivity check.

Composites as sweeps/int_mode/compare_grid_configs.py and the pinned
comparison.txt (4x4 = 531,321.5 um2 for the lap route):

    P_R*P_C * u_pe + (P_R+P_C)/2 * u_peripheral + P_R * u_combiner + Sobol pair

Throughput at 400 MHz: SC T=128 = 64 MAC/cycle/PE (peak; skew and drain not
charged, as in the "GMAC/s/mm2, 1 PE / 4x4" rows of the README); bit-plane INT8
= 128 MAC/cycle/PE at peak, times the data-edge utilization BW*NB / period of
an output block, with the period measured on the RTL benches (bit-exact runs):

    IPD   BW*NB + 1*(BW-1) + (P_R+P_C-2) + 8*P_C     (single PE: + 8, no skew)
    lap   BW*NB + 8*(BW-1) + (P_R+P_C-2) + 8*P_C

The periods are read from the bench runs' check.json / bpt_sched.txt
(build/rtl_preflight/bp_ipd/{grid,int}/) and each must equal its formula.

Usage: ipd_area_efficiency.py [--out build/rtl_preflight/bp_ipd/area_efficiency]
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
SYN = REPO / "syn/build/TSMC22"
RUN_LAP = SYN / "PAYN_SC_CSA_BP/csa_bp_20261004_lap"
RUN_IPD = SYN / "PAYN_SC_CSA_BP_IPD/csa_bp_ipd_20261004"
RUN_CSA = SYN / "PAYN_SC_CSA/csa_20261002"
ROUTE_LAP = REPO / "apr/build/TSMC22/PAYN_SC_CSA_BP/csa_bp_20261004_lap_distguide_spp_pins/reports/area.rpt"
BENCH = REPO / "build/rtl_preflight/bp_ipd"
F_GHZ = 0.4
BLOCKS = ("u_pe", "u_peripheral", "u_combiner", "u_a_rng", "u_w_rng")


def syn_areas(run: Path) -> dict:
    text = (run / "area.rpt").read_text()
    d = {"total": float(re.search(r"Total cell area:\s+([0-9.]+)", text)[1])}
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] in BLOCKS and f[0] not in d:
            d[f[0]] = float(f[1])
    for b in BLOCKS:
        d.setdefault(b, 0.0)
    d["sobol"] = d["u_a_rng"] + d["u_w_rng"]
    return d


def routed_areas(rpt: Path) -> dict:
    d = {}
    for line in rpt.read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if "total" not in d and f[0].startswith("payn_array_signed_segmented_csa_bp") and len(f) >= 3:
            d["total"] = float(f[2])
        if f[0] in BLOCKS and f[0] not in d:
            d[f[0]] = float(f[3])
    d["sobol"] = d["u_a_rng"] + d["u_w_rng"]
    return d


def composite(a: dict, pr: int, pc: int) -> float:
    return pr * pc * a["u_pe"] + (pr + pc) / 2 * a["u_peripheral"] + pr * a["u_combiner"] + a["sobol"]


def gmacs_mm2(mac_per_cycle: float, area_um2: float) -> float:
    return mac_per_cycle * F_GHZ / (area_um2 / 1e6)


def grid_period(shape: str, prec: str, L: int, lap: str) -> tuple[int, int, str]:
    """(block_len, formula, source) from the bench runs; lap = 'ipd' or 'ring'."""
    pr, pc = map(int, shape.split("x"))
    bw = 8 if prec == "INT8" else 4
    nb = L // 128
    S = pr + pc - 2
    lap_len = 1 if lap == "ipd" else 8
    formula = bw * nb + lap_len * (bw - 1) + S + 8 * pc
    pattern = "g*/check.json" if lap == "ipd" else "xc*/orig/check.json"
    for p in sorted((BENCH / "grid").glob(pattern)):
        d = json.loads(p.read_text())
        if (d["status"] == "PASS" and d["grid"] == shape and d["precision"] == prec and d["L"] == L
                and d["mode"] == "per_pe_laps"):
            if d["block_len"] != formula:
                raise SystemExit(f"{p}: block_len {d['block_len']} != formula {formula}")
            return d["block_len"], formula, str(p.parent.relative_to(REPO))
    return formula, formula, "formula only (no bench run)"


def single_pe_period(prec: str, L: int, lap: str) -> tuple[int, int, str]:
    bw = 8 if prec == "INT8" else 4
    nb = L // 128
    lap_len = 1 if lap == "ipd" else 8
    formula = bw * nb + lap_len * (bw - 1) + 8
    # IPD: the IPD top's runs (LAP_LEN=1); ring: the generalized bench at
    # LAP_LEN=8 on the BP top (bench cross-check runs, bit-exact, traces equal
    # to the original bench's).
    pattern = "int/*/bpt_sched.txt" if lap == "ipd" else "xcheck/gen_lap8/*/bpt_sched.txt"
    for s in sorted(BENCH.glob(pattern)):
        kv = dict(re.findall(r"(\w+)=(-?\d+)", s.read_text().split("\n")[0]))
        chk = s.parent / "check.json"
        if (chk.is_file() and json.loads(chk.read_text())["status"] == "PASS" and int(kv["lap_len"]) == lap_len
                and int(kv["nb"]) == nb and int(kv["bw"]) == bw and s.parent.name.startswith(prec.lower())):
            if int(kv["blk_len"]) != formula:
                raise SystemExit(f"{s}: blk_len {kv['blk_len']} != formula {formula}")
            return int(kv["blk_len"]), formula, str(s.parent.relative_to(REPO))
    return formula, formula, "formula only (no bench run)"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=BENCH / "area_efficiency")
    args = ap.parse_args()

    s_lap, s_ipd, s_csa = syn_areas(RUN_LAP), syn_areas(RUN_IPD), syn_areas(RUN_CSA)
    r_lap = routed_areas(ROUTE_LAP)
    keys = ("total", "u_pe", "u_peripheral", "u_combiner", "sobol")
    r_ipd = {k: r_lap[k] + s_ipd[k] - s_lap[k] for k in keys}
    r_ipd_ratio = {k: r_lap[k] * (s_ipd[k] / s_lap[k] if s_lap[k] else 1.0) for k in keys}

    out = []
    p = out.append
    p("In-place doubling (T3, csa_bp_ipd_20261004) vs BP ring (csa_bp_20261004_lap); TSMC22, 400 MHz.")
    p("Routed IPD areas are ESTIMATES: routed pinned lap area + synthesized IPD-lap delta per block.\n")
    p(f"{'block (um2)':16s} {'syn CSA':>10s} {'syn lap':>10s} {'syn IPD':>10s} {'IPD-lap':>9s} "
      f"{'routed lap':>11s} {'est. routed IPD':>16s} {'(ratio scaling)':>16s}")
    for k in keys:
        p(f"{k:16s} {s_csa.get(k, 0):10.1f} {s_lap[k]:10.1f} {s_ipd[k]:10.1f} {s_ipd[k]-s_lap[k]:+9.1f} "
          f"{r_lap[k]:11.1f} {r_ipd[k]:16.1f} {r_ipd_ratio[k]:16.1f}")
    p(f"synthesized total: IPD vs lap {s_ipd['total']-s_lap['total']:+.1f} um2 "
      f"({100*(s_ipd['total']/s_lap['total']-1):+.2f}%), IPD vs CSA {s_ipd['total']-s_csa['total']:+.1f} um2 "
      f"({100*(s_ipd['total']/s_csa['total']-1):+.2f}%); u_pe IPD vs lap "
      f"{s_ipd['u_pe']-s_lap['u_pe']:+.1f} um2 ({100*(s_ipd['u_pe']/s_lap['u_pe']-1):+.2f}%)\n")

    rows = []
    comp = {}
    for name, a in (("lap (routed)", r_lap), ("IPD (estimate)", r_ipd), ("IPD (ratio est.)", r_ipd_ratio)):
        comp[name] = {"1x1": a["total"], "4x4": composite(a, 4, 4), "4x8": composite(a, 4, 8)}
    p("composite area (um2):          1 PE       4x4        4x8")
    for name, c in comp.items():
        p(f"  {name:18s} {c['1x1']:10.1f} {c['4x4']:10.1f} {c['4x8']:11.1f}")
    p("  (4x4 lap must equal comparison.txt's 531,321.5 um2)\n")

    p("SC mode, T=128, peak GMAC/s/mm2 (64 MAC/cycle/PE):")
    for g, n in (("1x1", 1), ("4x4", 16), ("4x8", 32)):
        a_l, a_i = comp["lap (routed)"][g], comp["IPD (estimate)"][g]
        gl, gi = gmacs_mm2(64 * n, a_l), gmacs_mm2(64 * n, a_i)
        p(f"  {g}: lap {gl:7.1f}   IPD est. {gi:7.1f}   ({100*(gi/gl-1):+.2f}%)")
        rows.append(dict(mode="SC T=128 peak", grid=g, L="-", period_lap="-", period_ipd="-",
                         util_lap=1.0, util_ipd=1.0, gmacs_mm2_lap=round(gl, 1), gmacs_mm2_ipd_est=round(gi, 1)))
    p("")

    p("Bit-plane INT, GMAC/s/mm2 = peak x data-edge utilization (period measured on the RTL bench):")
    p(f"  {'grid':4s} {'prec':5s} {'L':>5s} {'period lap':>10s} {'util':>6s} {'GMAC/s/mm2':>10s}   "
      f"{'period IPD':>10s} {'util':>6s} {'GMAC/s/mm2 est.':>15s}  {'gain':>6s}")
    cases = [("1x1", "INT8", 1024), ("1x1", "INT8", 4096),
             ("4x4", "INT8", 1024), ("4x4", "INT8", 4096), ("4x8", "INT8", 1024), ("4x8", "INT8", 4096),
             ("4x4", "W4A8", 4096), ("4x8", "INT4", 4096)]
    srcs = []
    for g, prec, L in cases:
        n = 1 if g == "1x1" else (16 if g == "4x4" else 32)
        mac_pk = {"INT8": 128, "W4A8": 256, "INT4": 512}[prec] * n
        bw = 8 if prec == "INT8" else 4
        data = bw * (L // 128)
        if g == "1x1":
            (pl, fl, sl), (pi, fi, si) = single_pe_period(prec, L, "ring"), single_pe_period(prec, L, "ipd")
        else:
            (pl, fl, sl), (pi, fi, si) = grid_period(g, prec, L, "ring"), grid_period(g, prec, L, "ipd")
        ul, ui = data / pl, data / pi
        gl = gmacs_mm2(mac_pk, comp["lap (routed)"][g]) * ul
        gi = gmacs_mm2(mac_pk, comp["IPD (estimate)"][g]) * ui
        p(f"  {g:4s} {prec:5s} {L:5d} {pl:10d} {ul:6.1%} {gl:10.1f}   {pi:10d} {ui:6.1%} {gi:15.1f}  {100*(gi/gl-1):+5.1f}%")
        srcs.append(f"    {g} {prec} L={L}: lap period from {sl}; IPD period from {si}")
        rows.append(dict(mode=f"{prec} bit-plane", grid=g, L=L, period_lap=pl, period_ipd=pi,
                         util_lap=round(ul, 4), util_ipd=round(ui, 4), gmacs_mm2_lap=round(gl, 1),
                         gmacs_mm2_ipd_est=round(gi, 1)))
    p("  peak INT8 GMAC/s/mm2 (no schedule): lap {:.1f} / {:.1f}, IPD est. {:.1f} / {:.1f} (1 PE / 4x4)".format(
        gmacs_mm2(128, comp["lap (routed)"]["1x1"]), gmacs_mm2(128 * 16, comp["lap (routed)"]["4x4"]),
        gmacs_mm2(128, comp["IPD (estimate)"]["1x1"]), gmacs_mm2(128 * 16, comp["IPD (estimate)"]["4x4"])))
    p("  period sources:")
    out.extend(srcs)
    text = "\n".join(out) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.with_suffix(".txt").write_text(text)
    args.out.with_suffix(".json").write_text(json.dumps(dict(
        syn=dict(csa=s_csa, lap=s_lap, ipd=s_ipd), routed_lap=r_lap, routed_ipd_estimate=r_ipd,
        routed_ipd_ratio_estimate=r_ipd_ratio, composites=comp, rows=rows), indent=2) + "\n")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
