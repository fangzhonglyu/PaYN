#!/usr/bin/env python3
"""GMAC/s/mm2 of the lap sub-ring family g = 8 (BP ring), 4, 2, 1 (in-place doubling).

g is the sub-ring length: each tile row's 8 tiles form 8/g sub-rings of g tiles,
a mux sits at each sub-ring head (8/g * 8 rows = 64/g muxes per PE, 24 bits
each), and a weight-pass lap takes g edges.

Areas.  g = 8 is the routed pinned csa_bp_20261004_lap layout.  The other g are
synthesized, not routed; their routed areas are ESTIMATED from the routed lap
blocks plus the synthesized delta (same DC knobs):

  primary   routed_g(u_pe) = routed_lap(u_pe) + syn_g(u_pe) - syn_lap(u_pe);
            every other block (u_peripheral, u_combiner, Sobol) has unchanged
            RTL and is held at its routed lap value (their synthesized
            differences, e.g. -53 um2 in u_peripheral for g = 2 / 4, are DC
            run-to-run noise).
  sens. 1   block-by-block delta for every block (the method of
            sweeps/int_mode/bp/ipd/ipd_area_efficiency.py).
  sens. 2   ratio scaling, routed_lap(block) * syn_g(block) / syn_lap(block).

Composites as sweeps/int_mode/compare_grid_configs.py and the pinned
comparison.txt (4x4 lap = 531,321.5 um2, 4x4 CSA = 521,100.2 um2):
    P_R*P_C*u_pe + (P_R+P_C)/2*u_peripheral + P_R*u_combiner + Sobol pair.

Throughput at 400 MHz: SC T=128 = 64 MAC/cycle/PE (peak); bit-plane INT8 = 128
MAC/cycle/PE at peak, times the data-edge utilization BW*NB / period, with the
period MEASURED on the RTL benches (bit-exact runs) and checked against
    BW*NB + g*(BW-1) + (P_R+P_C-2) + 8*P_C        (single PE: + 8, no skew)
from build/rtl_preflight/bp_sr/grid (g = 2, 4), bp_ipd/grid (g = 1, and the
BP-ring cross-check runs for g = 8) and the single-PE int runs.

Synthesis sources for g = 2 / 4: syn/build/TSMC22/PAYN_SC_CSA_BP_SR<g>/csa_bp_sr<g>_20261004
if present, else the archived reports of the first run
(build/rtl_preflight/bp_sr/syn/placeholder_alib_runs/sr<g>/area.rpt; that run
loaded placeholder alibs because the AFS token expired during it, see the README).

Opt-in --sr-run TEMPLATE selects other g = 2 / 4 runs ({g} is replaced), e.g. the clean
reruns csa_bp_sr{g}_20261004_clean; an explicitly named run must exist.

Usage: sr_area_efficiency.py [--out build/rtl_preflight/bp_sr/area_efficiency] [--sr-run TEMPLATE]
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
SYN = REPO / "syn/build/TSMC22"
RUNS = {8: SYN / "PAYN_SC_CSA_BP/csa_bp_20261004_lap", 1: SYN / "PAYN_SC_CSA_BP_IPD/csa_bp_ipd_20261004"}
RUN_CSA = SYN / "PAYN_SC_CSA/csa_20261002"
ROUTE_LAP = REPO / "apr/build/TSMC22/PAYN_SC_CSA_BP/csa_bp_20261004_lap_distguide_spp_pins/reports/area.rpt"
ROUTE_CSA = REPO / "apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins/reports/area.rpt"
B_SR = REPO / "build/rtl_preflight/bp_sr"
B_IPD = REPO / "build/rtl_preflight/bp_ipd"
F_GHZ = 0.4
BLOCKS = ("u_pe", "u_peripheral", "u_combiner", "u_a_rng", "u_w_rng")
KEYS = ("total", "u_pe", "u_peripheral", "u_combiner", "sobol")
GS = (8, 4, 2, 1)


def syn_area_rpt(rpt: Path) -> dict:
    text = rpt.read_text()
    d = {"total": float(re.search(r"Total cell area:\s+([0-9.]+)", text)[1])}
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] in BLOCKS and f[0] not in d:
            d[f[0]] = float(f[1])
    for b in BLOCKS:
        d.setdefault(b, 0.0)
    d["sobol"] = d["u_a_rng"] + d["u_w_rng"]
    return d


SR_RUN_DEFAULT = "csa_bp_sr{g}_20261004"


def sr_run(g: int, template: str = SR_RUN_DEFAULT) -> tuple[Path, str]:
    run = SYN / f"PAYN_SC_CSA_BP_SR{g}" / template.format(g=g) / "area.rpt"
    if run.is_file():
        return run, str(run.parent.relative_to(REPO))
    if template != SR_RUN_DEFAULT:   # an explicitly requested run must exist (no archive fallback)
        raise SystemExit(f"--sr-run {template}: {run} not found")
    arch = B_SR / f"syn/placeholder_alib_runs/sr{g}/area.rpt"
    return arch, f"{arch.relative_to(REPO)} (first run, placeholder alibs, netlist not kept)"


def routed_areas(rpt: Path, top_prefix: str) -> dict:
    d = {}
    for line in rpt.read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if "total" not in d and f[0].startswith(top_prefix) and len(f) >= 3:
            d["total"] = float(f[2])
        if f[0] in BLOCKS and f[0] not in d:
            d[f[0]] = float(f[3])
    for b in BLOCKS:
        d.setdefault(b, 0.0)
    d["sobol"] = d["u_a_rng"] + d["u_w_rng"]
    return d


def composite(a: dict, pr: int, pc: int) -> float:
    return pr * pc * a["u_pe"] + (pr + pc) / 2 * a["u_peripheral"] + pr * a["u_combiner"] + a["sobol"]


def gmacs_mm2(mac_per_cycle: float, area_um2: float) -> float:
    return mac_per_cycle * F_GHZ / (area_um2 / 1e6)


def grid_period(g: int, shape: str, prec: str, L: int) -> tuple[int, str]:
    pr, pc = map(int, shape.split("x"))
    bw = 8 if prec == "INT8" else 4
    nb = L // 128
    formula = bw * nb + g * (bw - 1) + (pr + pc - 2) + 8 * pc
    if g in (2, 4):
        pattern, base = f"g{g}/g*/check.json", B_SR / "grid"
    elif g == 1:
        pattern, base = "g*/check.json", B_IPD / "grid"
    else:
        pattern, base = "xc*/orig/check.json", B_IPD / "grid"
    for p in sorted(base.glob(pattern)):
        d = json.loads(p.read_text())
        if (d["status"] == "PASS" and d["grid"] == shape and d["precision"] == prec and d["L"] == L
                and d["mode"] == "per_pe_laps"):
            if d["block_len"] != formula or (g != 8 and d["lap_len"] != g):
                raise SystemExit(f"{p}: block_len {d['block_len']} / lap_len {d['lap_len']} vs formula {formula}")
            return d["block_len"], str(p.parent.relative_to(REPO))
    return formula, "formula only (no bench run)"


def single_pe_period(g: int, prec: str, L: int) -> tuple[int, str]:
    bw = 8 if prec == "INT8" else 4
    nb = L // 128
    formula = bw * nb + g * (bw - 1) + 8
    if g in (2, 4):
        pattern, base = f"int_g{g}/*/bpt_sched.txt", B_SR
    elif g == 1:
        pattern, base = "int/*/bpt_sched.txt", B_IPD
    else:
        pattern, base = "xcheck/gen_lap8/*/bpt_sched.txt", B_IPD
    for s in sorted(base.glob(pattern)):
        kv = dict(re.findall(r"(\w+)=(-?\d+)", s.read_text().split("\n")[0]))
        chk = s.parent / "check.json"
        if (chk.is_file() and json.loads(chk.read_text())["status"] == "PASS" and int(kv["lap_len"]) == g
                and int(kv["nb"]) == nb and int(kv["bw"]) == bw and s.parent.name.startswith(prec.lower())):
            if int(kv["blk_len"]) != formula:
                raise SystemExit(f"{s}: blk_len {kv['blk_len']} != formula {formula}")
            return int(kv["blk_len"]), str(s.parent.relative_to(REPO))
    return formula, "formula only (no bench run)"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=B_SR / "area_efficiency")
    ap.add_argument("--sr-run", default=SR_RUN_DEFAULT,
                    help="opt-in g = 2 / 4 run-name template under syn/build/TSMC22/PAYN_SC_CSA_BP_SR<g>/, "
                         "e.g. csa_bp_sr{g}_20261004_clean (default %(default)s, with the archive fallback)")
    args = ap.parse_args()

    syn, src = {}, {}
    for g in GS:
        if g in RUNS:
            syn[g], src[g] = syn_area_rpt(RUNS[g] / "area.rpt"), str(RUNS[g].relative_to(REPO))
        else:
            rpt, src[g] = sr_run(g, args.sr_run)
            syn[g] = syn_area_rpt(rpt)
    s_csa = syn_area_rpt(RUN_CSA / "area.rpt")
    r_lap = routed_areas(ROUTE_LAP, "payn_array_signed_segmented_csa_bp")
    r_csa = routed_areas(ROUTE_CSA, "payn_array_signed_segmented_csa")

    est = {}   # method -> g -> block areas
    for g in GS:
        d = {k: syn[g][k] - syn[8][k] for k in KEYS}
        prim = dict(r_lap)
        prim["u_pe"] = r_lap["u_pe"] + d["u_pe"]
        prim["total"] = r_lap["total"] + d["u_pe"]
        est.setdefault("primary (u_pe delta)", {})[g] = prim
        est.setdefault("block-by-block delta", {})[g] = {k: r_lap[k] + d[k] for k in KEYS}
        est.setdefault("ratio scaling", {})[g] = {k: r_lap[k] * (syn[g][k] / syn[8][k] if syn[8][k] else 1.0)
                                                  for k in KEYS}

    out = []
    p = out.append
    p("Lap sub-ring family on the BP INT PE: g = 8 (BP ring, csa_bp_20261004_lap), 4, 2, 1 (in-place doubling,")
    p("csa_bp_ipd_20261004); TSMC22, 400 MHz, DC knobs identical.  g = 8 areas are the routed pinned layout;")
    p("the others are ESTIMATES (routed lap + synthesized u_pe delta).\n")
    p("synthesis sources:")
    for g in GS:
        p(f"  g={g}: {src[g]}")
    p(f"  CSA: {RUN_CSA.relative_to(REPO)}\n")
    p(f"{'g':>2s} {'muxes/PE':>8s} {'mux bits':>8s} {'syn total':>10s} {'d total':>8s} {'syn u_pe':>9s} "
      f"{'d u_pe':>8s} {'d u_pe %':>8s} {'um2/added bit':>13s} {'d periph':>8s}")
    for g in GS:
        bits = 64 // g * 24
        du = syn[g]["u_pe"] - syn[8]["u_pe"]
        dbit = (bits - 192)
        p(f"{g:2d} {64 // g:8d} {bits:8d} {syn[g]['total']:10.1f} {syn[g]['total'] - syn[8]['total']:+8.1f} "
          f"{syn[g]['u_pe']:9.1f} {du:+8.1f} {100 * du / syn[8]['u_pe']:+7.2f}% "
          f"{(du / dbit if dbit else 0):13.3f} {syn[g]['u_peripheral'] - syn[8]['u_peripheral']:+8.1f}")
    p(f"   CSA (no INT): syn total {s_csa['total']:.1f}, u_pe {s_csa['u_pe']:.1f}\n")

    comp = {m: {g: {"1x1": a["total"], "4x4": composite(a, 4, 4), "4x8": composite(a, 4, 8)}
                for g, a in est[m].items()} for m in est}
    comp_csa = {"1x1": r_csa["total"], "4x4": composite(r_csa, 4, 4), "4x8": composite(r_csa, 4, 8)}
    p("composite area (um2), primary method [block-by-block / ratio scaling]:")
    p(f"  {'g':>2s} {'1 PE':>10s} {'4x4':>11s} {'4x8':>12s}   {'4x4 sens.':>21s} {'4x8 sens.':>23s}")
    for g in GS:
        c = comp["primary (u_pe delta)"][g]
        b, r = comp["block-by-block delta"][g], comp["ratio scaling"][g]
        p(f"  {g:2d} {c['1x1']:10.1f} {c['4x4']:11.1f} {c['4x8']:12.1f}   [{b['4x4']:9.1f} / {r['4x4']:9.1f}] "
          f"[{b['4x8']:10.1f} / {r['4x8']:10.1f}]")
    p(f"  CSA {comp_csa['1x1']:9.1f} {comp_csa['4x4']:11.1f} {comp_csa['4x8']:12.1f}   (routed pinned CSA)")
    p("  (g=8 4x4 must equal comparison.txt's 531,321.5; CSA 4x4 its 521,100.2)\n")

    C = comp["primary (u_pe delta)"]
    rows = []
    p("SC mode, T=128, peak GMAC/s/mm2 (64 MAC/cycle/PE); change vs the BP ring (g=8) and vs CSA (no INT mode):")
    for shape, n in (("1x1", 1), ("4x4", 16), ("4x8", 32)):
        gc = gmacs_mm2(64 * n, comp_csa[shape])
        line = f"  {shape}: CSA {gc:6.1f} |"
        for g in GS:
            v = gmacs_mm2(64 * n, C[g][shape])
            v8 = gmacs_mm2(64 * n, C[8][shape])
            line += f" g={g} {v:6.1f} ({100 * (v / v8 - 1):+.2f}% lap, {100 * (v / gc - 1):+.2f}% CSA) |"
            rows.append(dict(mode="SC T=128 peak", grid=shape, g=g, L="-", period="-", util=1.0,
                             gmacs_mm2=round(v, 1), vs_lap_pct=round(100 * (v / v8 - 1), 2),
                             vs_csa_pct=round(100 * (v / gc - 1), 2)))
        p(line)
    p("  INT area tax over CSA, 4x4 composite: " + ", ".join(
        f"g={g} {C[g]['4x4'] - comp_csa['4x4']:+.0f} um2 ({100 * (C[g]['4x4'] / comp_csa['4x4'] - 1):+.2f}%)"
        for g in GS) + "\n")

    p("Bit-plane INT, GMAC/s/mm2 = peak x data-edge utilization (period measured on the RTL benches):")
    p(f"  {'grid':4s} {'prec':5s} {'L':>5s} | " + " | ".join(f"g={g}: period util GMAC/s/mm2 (vs g=8)" for g in GS))
    cases = [("1x1", "INT8", 1024), ("1x1", "INT8", 4096), ("4x4", "INT8", 1024), ("4x4", "INT8", 4096),
             ("4x8", "INT8", 1024), ("4x8", "INT8", 4096), ("4x4", "W4A8", 4096), ("4x8", "INT4", 4096)]
    srcs = []
    for shape, prec, L in cases:
        n = {"1x1": 1, "4x4": 16, "4x8": 32}[shape]
        mac_pk = {"INT8": 128, "W4A8": 256, "INT4": 512}[prec] * n
        data = (8 if prec == "INT8" else 4) * (L // 128)
        line = f"  {shape:4s} {prec:5s} {L:5d} |"
        base = None
        for g in GS:
            per, s = single_pe_period(g, prec, L) if shape == "1x1" else grid_period(g, shape, prec, L)
            u = data / per
            v = gmacs_mm2(mac_pk, C[g][shape]) * u
            base = v if g == 8 else base
            line += f" g={g}: {per:4d} {u:6.1%} {v:7.1f} ({100 * (v / base - 1):+5.1f}%) |"
            srcs.append(f"    {shape} {prec} L={L} g={g}: {s}")
            rows.append(dict(mode=f"{prec} bit-plane", grid=shape, g=g, L=L, period=per, util=round(u, 4),
                             gmacs_mm2=round(v, 1), vs_lap_pct=round(100 * (v / base - 1), 2), vs_csa_pct=None))
        p(line)
    p("  peak INT8 GMAC/s/mm2 (no schedule), 1 PE / 4x4: " + ", ".join(
        f"g={g} {gmacs_mm2(128, C[g]['1x1']):.1f} / {gmacs_mm2(128 * 16, C[g]['4x4']):.1f}" for g in GS))
    p("\nReview estimate check (0.721 um2 per added mux bit from IPD - lap): "
      + ", ".join(f"g={g} est. {(64 // g * 24 - 192) * (syn[1]['total'] - syn[8]['total']) / 1344:+.1f} vs synthesized "
                  f"u_pe {syn[g]['u_pe'] - syn[8]['u_pe']:+.1f} / total {syn[g]['total'] - syn[8]['total']:+.1f} um2"
                  for g in (4, 2)))
    p("  period sources:")
    out.extend(srcs)
    text = "\n".join(out) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.with_suffix(".txt").write_text(text)
    args.out.with_suffix(".json").write_text(json.dumps(dict(
        syn={str(g): syn[g] for g in GS} | {"csa": s_csa}, syn_sources={str(g): src[g] for g in GS},
        routed_lap=r_lap, routed_csa=r_csa,
        estimates={m: {str(g): a for g, a in v.items()} for m, v in est.items()},
        composites={m: {str(g): c for g, c in v.items()} for m, v in comp.items()} | {"csa (routed)": comp_csa},
        rows=rows), indent=2) + "\n")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
