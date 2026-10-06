#!/usr/bin/env python3
"""Adversarial cost / system-realism check of the WO-ring INT mode
(design key weight_outer_horner, sweeps/int_mode/design_round1.json).

What this adds over sweeps/int_mode/weight_outer_horner_costs.py
  1. Area: replaces the hand cell counts with DC synthesis of the INT-only
     blocks (verify/wo_ring/syn/*/<TOP>.area.rpt), and counts the edge feeder
     (Booth digit select + per-lane code LUT + SC/INT port mux), which the
     WO-ring entry did not count at all, next to the in-composite numbers.
  2. Throughput on whole GEMMs: output-footprint tiling (partial blocks waste
     tiles), both operand orientations, FH/HYS chosen per layer, chunking, and
     the same drain/skew model for the competitors (CNSB/spatial, bit-plane,
     SC, BOS INT8), for realistic LLM layers (prefill and decode).
  3. Bandwidth: port bits/cycle, raw bits/cycle at the buffer, and GEMM-level
     re-fetch (passes x footprint) in bits/MAC, plus the throughput cap when the
     buffer only supplies SC's rate.

Usage: python3 sweeps/int_mode/verify/wo_ring_system.py
Writes sweeps/int_mode/verify/wo_ring_system.csv
"""
from __future__ import annotations

import csv
import math
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import model_weight_outer_horner as mdl          # noqa: E402
import weight_outer_horner_costs as woc          # noqa: E402

F_GHZ = 0.4
NT = 64
UPE, PERIPH, SOBOL = 29255.548, 13031.256, 844.760 + 833.588   # routed, reports/area.rpt
SINGLE = 44017.974
BOS8 = 15797.404                                               # routed BOS INT8 8x8, 64 MAC/cycle
GRIDS = [(1, 1), (4, 4), (4, 8)]


def grid_area(pr, pc):
    return SINGLE if (pr, pc) == (1, 1) else pr * pc * UPE + (pr + pc) * PERIPH / 2 + SOBOL


# ------------------------------------------------------------------ area --
def syn_area(top, fallback):
    rpt = HERE / "wo_ring" / "syn" / top / f"{top}.area.rpt"
    try:
        m = re.search(r"Total cell area:\s+([\d.]+)", rpt.read_text())
        return float(m.group(1)), "DC synth"
    except (OSError, AttributeError):
        return fallback, "estimate"


RING_PE, RING_SRC = syn_area("WoRingPeDelta", woc.PE_RING)
FEED_A, FEED_A_SRC = syn_area("WoFeederA", 0.0)
FEED_W, FEED_W_SRC = syn_area("WoFeederW", 0.0)
COLL_ROW, COLL_SRC = syn_area("WoCollectorRow", woc.COLLECTOR_ROW)
PRESET = woc.SOBOL_PRESET                     # 256 AND2/OR2 + 2 OR2, cell count (not synthesized)
CTRL = 100.0                                  # INT sequencer, architect's own "~0.1k um2, not counted"


def wo_area(pr, pc):
    a = grid_area(pr, pc)
    core_claim = pr * pc * woc.PE_RING + PRESET
    core = pr * pc * RING_PE + PRESET
    coll = 8 * pr * COLL_ROW
    feed = pr * FEED_A + pc * FEED_W
    return dict(grid=f"{pr}x{pc}", A=a, core_claim=core_claim, core=core, coll=coll,
                feed=feed, ctrl=CTRL, all_in=core + coll + feed + CTRL)


# ------------------------------------------------------------ throughput --
def drain(pr, pc):
    return 8 * pc + pr + pc - 2


def wo_block(mode, variant, L, pr, pc):
    """(cycles per output block, block rows, block cols) for WO-ring."""
    cyc = woc.slots_per_block(mode, variant, L, pr, pc)
    n_w = mdl.MODES[mode]["n_w"]
    cols = (8 // n_w if variant == "HYS" else 8) * pc
    return cyc, 8 * pr, cols


def gemm_cycles(M, N, L, block_fn):
    """Best orientation; block_fn(L) -> (cycles, rows, cols)."""
    cyc, br, bc = block_fn(L)
    best = None
    for m, n in ((M, N), (N, M)):
        c = math.ceil(m / br) * math.ceil(n / bc) * cyc
        if best is None or c < best[0]:
            best = (c, m, n)
    return best[0]


def designs(pr, pc):
    """Each design: dict(name, area_add (all-in um2 over the SC grid), block(mode,L))."""
    D = drain(pr, pc)
    wa = wo_area(pr, pc)
    A = grid_area(pr, pc)

    def wo(mode, L):
        opts = [wo_block(mode, v, L, pr, pc) for v in ("FH", "HYS")]
        return opts

    def cnsb(mode, L):          # 2x4 outputs/PE (INT8), one digit pair per tile, peak 1
        return [(math.ceil(L / 8) + D, 2 * pr, 4 * pc)]

    def bitplane(mode, L):      # BP-HW-ring INT8: 1x8 outputs/PE, 8 A passes of L/128, 7 x2 laps
        return [(8 * math.ceil(L / 128) + 56 + D, pr, 8 * pc)]

    def sc(mode, L):            # SC T=128: 8 cycles per MAC per lane, 8x8 outputs/PE
        return [(8 * math.ceil(L / 8) + D, 8 * pr, 8 * pc)]

    return {
        "WO-ring (in-composite area)": dict(fn=wo, area=A + wa["core"]),
        "WO-ring (all-in area)": dict(fn=wo, area=A + wa["all_in"]),
        "CNSB (all-in, its own estimate)": dict(fn=cnsb, area=A * 1.0181 if (pr, pc) == (4, 4)
                                                 else A * (1.0115 if (pr, pc) == (4, 8) else 1.0553)),
        "BP-HW-ring (its own estimate)": dict(fn=bitplane, area=A * (1.0151 if (pr, pc) == (4, 4)
                                                   else (1.0119 if (pr, pc) == (4, 8) else 1.0337))),
        "SC T=128 (reference)": dict(fn=sc, area=A),
    }


def util(fn, mode, M, N, L, ntile):
    best = None
    for cyc, br, bc in fn(mode, L):
        c = gemm_cycles(M, N, L, lambda _L: (cyc, br, bc))
        u = M * N * L / (c * ntile)
        best = u if best is None else max(best, u)
    return best


def bos_util(M, N, L, n_arrays):
    """n independent 8x8 OS arrays (BOS RTL: skew 14 + drain 8 per block)."""
    blocks = math.ceil(M / 8) * math.ceil(N / 8)
    rounds = math.ceil(blocks / n_arrays)
    return M * N * L / (rounds * (L + 22) * 64 * n_arrays)


# ------------------------------------------------------------- workloads --
def llm_layers():
    """(label, M, N, L, count) per transformer block; LLaMA-2-7B shapes
    (d=4096, 32 heads x 128, FFN 11008) plus a head_dim=64 attention case."""
    out = []
    for S in (512, 2048, 4096):
        out += [(f"prefill S={S} QKV proj", S, 3 * 4096, 4096, 1),
                (f"prefill S={S} O proj", S, 4096, 4096, 1),
                (f"prefill S={S} FFN gate+up", S, 2 * 11008, 4096, 1),
                (f"prefill S={S} FFN down", S, 4096, 11008, 1),
                (f"prefill S={S} QK^T hd128", S, S, 128, 32),
                (f"prefill S={S} QK^T hd64", S, S, 64, 32),
                (f"prefill S={S} SV hd128", S, 128, S, 32)]
    for B in (1, 8, 32):
        out += [(f"decode B={B} FFN gate+up", B, 2 * 11008, 4096, 1),
                (f"decode B={B} FFN down", B, 4096, 11008, 1)]
    for S in (512, 4096):
        out += [(f"decode ctx={S} QK^T hd128 (per seq,head)", 1, S, 128, 32),
                (f"decode ctx={S} SV hd128 (per seq,head)", 1, 128, S, 32)]
    return out


# -------------------------------------------------------------- bandwidth --
def bits_per_mac(design, M, N, L, pr, pc, variant="HYS"):
    """Raw operand bits read at the buffer per useful MAC, GEMM level."""
    if design == "WO":
        if variant == "HYS":
            br, bc, pa, pw = 8 * pr, 4 * pc, 4, 4
        else:
            br, bc, pa, pw = 8 * pr, 8 * pc, 8, 8
    elif design == "CNSB":
        br, bc, pa, pw = 2 * pr, 4 * pc, 1, 1
    elif design == "BP":
        br, bc, pa, pw = pr, 8 * pc, 8, 1         # A bytes replayed per W plane (no replay buffer);
                                                  # W read once as 8 one-bit planes
    elif design == "SC":
        br, bc, pa, pw = 8 * pr, 8 * pc, 1, 1
    elif design == "OS32":
        br, bc, pa, pw = 8 * pr, 8 * pc, 1, 1     # BOS arrays meshed to the same footprint
    best = None
    for m, n in ((M, N), (N, M)):
        bits = 8 * (m * L * math.ceil(n / bc) * pa + n * L * math.ceil(m / br) * pw)
        if design == "SC":
            bits *= 9 / 8                          # sign bit with each magnitude
        v = bits / (M * N * L)
        best = v if best is None else min(best, v)
    return best


def main():
    rows = []
    print("== 1. area (um2).  Ring/collector/feeders: DC synthesis of verify/wo_ring/wo_ring_blocks.sv")
    print(f"   PE ring delta {RING_PE:.1f} ({RING_SRC}; claim {woc.PE_RING:.1f})   "
          f"collector/global row {COLL_ROW:.1f} ({COLL_SRC}; claim {woc.COLLECTOR_ROW:.1f})")
    print(f"   feeder A half {FEED_A:.1f} ({FEED_A_SRC}; claim 0, not counted)   "
          f"feeder W half {FEED_W:.1f} ({FEED_W_SRC}; claim 0)   Sobol preset {PRESET:.1f} (cell count)")
    print(f"   {'grid':5s} {'SC area':>11s} {'claim core':>10s} {'%':>6s} {'synth core':>10s} {'%':>6s} "
          f"{'+coll':>8s} {'+feeders':>9s} {'+ctrl':>6s} {'all-in':>9s} {'%':>6s} "
          f"{'SC GMAC/s/mm2: now':>18s} {'core':>6s} {'all-in':>7s}")
    for pr, pc in GRIDS:
        w = wo_area(pr, pc)
        sc = NT * pr * pc * F_GHZ
        print(f"   {w['grid']:5s} {w['A']:11,.1f} {w['core_claim']:10,.1f} {100*w['core_claim']/w['A']:6.3f} "
              f"{w['core']:10,.1f} {100*w['core']/w['A']:6.3f} {w['coll']:8,.1f} {w['feed']:9,.1f} "
              f"{w['ctrl']:6.0f} {w['all_in']:9,.1f} {100*w['all_in']/w['A']:6.3f} "
              f"{sc/(w['A']/1e6):18.1f} {sc/((w['A']+w['core'])/1e6):6.1f} {sc/((w['A']+w['all_in'])/1e6):7.1f}")
        rows.append(dict(kind="area", grid=w["grid"], **{k: round(v, 3) for k, v in w.items() if k != "grid"}))
    w44 = wo_area(4, 4)
    print(f"   W codes precomputed offline (2.25x weight storage): W feeder -> port mux only "
          f"(~576 x 0.686 = 395): 4x4 all-in {100*(w44['all_in'] - 4*(FEED_W-395.1))/w44['A']:.2f}%")
    nofeed = w44['all_in'] - w44['feed']
    print(f"   both operands stored pre-coded (W 2.25x, A 4.5x storage; no feeders): 4x4 "
          f"{nofeed:,.0f} um2 = {100*nofeed/w44['A']:.2f}%")

    print("\n== 2. MAC/cycle/tile and GMAC/s/mm2 on whole GEMMs (footprint tiling, best orientation,"
          " FH/HYS per layer for WO)")
    for pr, pc in GRIDS:
        ntile = NT * pr * pc
        ds = designs(pr, pc)
        print(f"\n   --- grid {pr}x{pc}: drain+skew D={drain(pr, pc)}; WO block FH {8*pr}x{8*pc}, HYS {8*pr}x{4*pc}; "
              f"CNSB {2*pr}x{4*pc}; BP {pr}x{8*pc}; SC {8*pr}x{8*pc}; BOS 8x8 per array")
        hdr = f"   {'layer':44s}" + "".join(f"{n.split(' (')[0][:12]:>13s}" for n in ds) + f"{'BOS(eq.n)':>11s}"
        print(hdr + "      [GMAC/s/mm2: WO all-in | BOS]")
        n_bos = max(1, round(ntile / 64))
        for label, M, N, L, cnt in llm_layers():
            us = {n: util(d["fn"], "INT8", M, N, L, ntile) for n, d in ds.items()}
            peak = {n: (2.0 if n.startswith("BP") else 1.0) for n in ds}
            ub = bos_util(M, N, L, n_bos)
            g_wo = us["WO-ring (all-in area)"] * ntile * F_GHZ / (ds["WO-ring (all-in area)"]["area"] / 1e6)
            g_bos = ub * 64 * F_GHZ / (BOS8 / 1e6)
            print(f"   {label:44s}" + "".join(f"{us[n]:13.3f}" for n in ds) + f"{ub:11.3f}"
                  f"      [{g_wo:7.1f} | {g_bos:7.1f}]")
            for n, d in ds.items():
                rows.append(dict(kind="util", grid=f"{pr}x{pc}", layer=label, M=M, N=N, L=L, design=n,
                                 mac_per_cycle_tile=round(us[n], 4),
                                 gmacs_per_mm2=round(us[n] * ntile * F_GHZ / (d["area"] / 1e6), 1)))
            rows.append(dict(kind="util", grid=f"{pr}x{pc}", layer=label, M=M, N=N, L=L,
                             design=f"BOS INT8 x{n_bos}", mac_per_cycle_tile=round(ub, 4),
                             gmacs_per_mm2=round(g_bos, 1)))

    print("\n== 2b. MAC-weighted INT8 utilization over one LLaMA-2-7B block (QKV, O, FFN x3, QK^T, SV)")
    for pr, pc in GRIDS:
        ntile = NT * pr * pc
        ds = designs(pr, pc)
        for S in (512, 2048, 4096):
            lay = [(S, 3 * 4096, 4096, 1), (S, 4096, 4096, 1), (S, 2 * 11008, 4096, 1),
                   (S, 4096, 11008, 1), (S, S, 128, 32), (S, 128, S, 32)]
            macs = sum(M * N * L * c for M, N, L, c in lay)
            att = sum(M * N * L * c for M, N, L, c in lay[4:]) / macs
            line = []
            for n, d in ds.items():
                cyc = sum(c * M * N * L / (util(d["fn"], "INT8", M, N, L, ntile) * ntile)
                          for M, N, L, c in lay)
                u = macs / (cyc * ntile)
                g = u * ntile * F_GHZ / (d["area"] / 1e6)
                line.append(f"{n.split(' (')[0][:10]} {u:.3f} ({g:.0f})")
                rows.append(dict(kind="block_weighted", grid=f"{pr}x{pc}", layer=f"LLaMA2-7B block S={S}",
                                 design=n, mac_per_cycle_tile=round(u, 4), gmacs_per_mm2=round(g, 1)))
            cycb = sum(c * M * N * L / (bos_util(M, N, L, 1) * 64) for M, N, L, c in lay)
            ub = macs / (cycb * 64)
            print(f"   {pr}x{pc} S={S} (attention {100*att:.1f}% of MACs): " + "; ".join(line)
                  + f"; BOS {ub:.3f} ({ub*64*F_GHZ/(BOS8/1e6):.0f})")

    print("\n== 3. operand bandwidth")
    for pr, pc in GRIDS:
        port = (pr + pc) * 576
        raw_hys = pr * 64 * 8 + pc * 32 * 8
        raw_fh = pr * 64 * 8 + pc * 64 * 8
        peak_mac = NT * pr * pc
        print(f"   {pr}x{pc}: WO port {port} b/cycle ({port/peak_mac:.3f} b/MAC at peak); raw bytes at the "
              f"buffer HYS {raw_hys} ({raw_hys/peak_mac:.3f} b/MAC), FH {raw_fh} ({raw_fh/peak_mac:.3f}); "
              f"= {raw_hys*F_GHZ/8:.1f}-{raw_fh*F_GHZ/8:.1f} GB/s; SC avg {port/8:.0f} b/cycle "
              f"-> WO/SC = {raw_hys/(port/8):.1f}-{raw_fh/(port/8):.1f}x raw, {8:.0f}x port")
    print("\n   GEMM-level bits/MAC at the buffer (re-fetch = passes x footprint), 4x4 / 4x8:")
    cases = [("FFN gate+up S=2048", 2048, 22016, 4096), ("FFN down S=2048", 2048, 4096, 11008),
             ("QK^T S=2048 hd128", 2048, 2048, 128), ("SV S=2048 hd128", 2048, 128, 2048),
             ("decode B=8 FFN up", 8, 22016, 4096)]
    print(f"   {'case':22s} {'WO-HYS':>8s} {'WO-FH':>8s} {'CNSB':>8s} {'BP':>8s} {'SC':>8s} {'OS mesh':>8s}")
    for pr, pc in ((4, 4), (4, 8)):
        for lab, M, N, L in cases:
            v = [bits_per_mac(d, M, N, L, pr, pc, var) for d, var in
                 (("WO", "HYS"), ("WO", "FH"), ("CNSB", None), ("BP", None), ("SC", None), ("OS32", None))]
            print(f"   {pr}x{pc} {lab:18s}" + "".join(f"{x:8.3f}" for x in v))
            rows.append(dict(kind="bits_per_mac", grid=f"{pr}x{pc}", layer=lab, M=M, N=N, L=L,
                             WO_HYS=round(v[0], 4), WO_FH=round(v[1], 4), CNSB=round(v[2], 4),
                             BP=round(v[3], 4), SC=round(v[4], 4), OS_mesh=round(v[5], 4)))
    print("\n   throughput cap if the buffer supplies only SC's average rate (4x4: 576 b/cycle):")
    for lab, M, N, L in cases[:2]:
        b = bits_per_mac("WO", M, N, L, 4, 4, "HYS")
        print(f"   {lab}: WO-HYS {b:.2f} b/MAC -> {576/b:.0f} MAC/cycle = {576/b/1024:.3f} MAC/cycle/tile "
              f"= {576/b*F_GHZ/((w44['A']+w44['all_in'])/1e6):.0f} GMAC/s/mm2 all-in")

    print("\n== 4. equal-throughput dedicated BOS INT8 (with its own skew+drain), FFN gate+up S=2048")
    for pr, pc in GRIDS:
        ntile = NT * pr * pc
        ds = designs(pr, pc)
        u = util(ds["WO-ring (all-in area)"]["fn"], "INT8", 2048, 22016, 4096, ntile)
        macs = u * ntile
        ub = bos_util(2048, 22016, 4096, 1)
        n = macs / (64 * ub)
        w = wo_area(pr, pc)
        print(f"   {pr}x{pc}: WO {macs:7.1f} MAC/cycle -> {n:5.2f} BOS arrays = {n*BOS8:9,.0f} um2 = "
              f"{100*n*BOS8/w['A']:5.1f}% of the SC grid (WO-ring all-in {w['all_in']:,.0f} um2 = "
              f"{100*w['all_in']/w['A']:.2f}%); standalone INT8 GMAC/s/mm2 WO all-in "
              f"{macs*F_GHZ/((w['A']+w['all_in'])/1e6):.1f} vs BOS {ub*64*F_GHZ/(BOS8/1e6):.1f}")

    with open(HERE / "wo_ring_system.csv", "w", newline="") as f:
        keys = []
        for r in rows:
            for k in r:
                if k not in keys:
                    keys.append(k)
        wr = csv.DictWriter(f, fieldnames=keys)
        wr.writeheader()
        wr.writerows(rows)
    print(f"\nwrote {HERE / 'wo_ring_system.csv'}")


if __name__ == "__main__":
    main()
