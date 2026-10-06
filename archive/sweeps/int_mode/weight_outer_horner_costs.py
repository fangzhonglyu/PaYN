#!/usr/bin/env python3
"""Area / cycle / bandwidth accounting for the weight-outer Horner INT mode.

No EDA tools.  Cell areas are the LEF footprints already collected in
sweeps/int_mode/cost_table.py; block areas are the routed CSA numbers
(apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_fixed/reports/area.rpt).
Cycle counts use the same slot schedule as model_weight_outer_horner.py and
are cross-checked against it (build_schedule) for several grids.

Usage: python3 sweeps/int_mode/weight_outer_horner_costs.py
Writes sweeps/int_mode/weight_outer_horner_costs.csv
"""
from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import model_weight_outer_horner as mdl  # noqa: E402

F_GHZ = 0.4
NT = 64                                     # tiles per PE
# ---- cells (um2, LEF; see cost_table.py) ----
MXT2, AND2, OR2, NAND2, INV, AOI22, AO22 = 0.784, 0.392, 0.392, 0.294, 0.196, 0.490, 0.686
FA, HA, DFF1, DFF2B, BUFH = 1.666, 0.980, 1.470, 1.372, 0.294
MUX3_ONEHOT = AOI22 + 2 * NAND2            # 1.078 per bit
# ---- blocks (routed) ----
UPE, PERIPH, SOBOL = 29255.548, 13031.256, 844.760 + 833.588
SINGLE = 44017.974
TILE_SYN = 408.170
BOS = dict(INT8=15797.404, INT6=12403.664, INT4=10276.378)   # 64 MAC/cycle each


def grid_area(pr, pc):
    return SINGLE if (pr, pc) == (1, 1) else pr * pc * UPE + (pr + pc) * PERIPH / 2 + SOBOL


GRIDS = [(1, 1), (4, 4), (4, 8)]

# ------------------------------------------------------------- areas ----
ring_row = 22 * MXT2 + 2 * AND2             # {east[21:0],2'b0} vs west, bits[1:0] gated
PE_RING = 8 * ring_row + DFF1 + OR2 + 6 * BUFH
SOBOL_PRESET = 2 * 128 * AND2 + 2 * OR2     # constant force in the Sobol D path + enable OR
COLLECTOR_ROW = 24 * DFF2B + 28 * FA       # HYS pair combine X1<<4 + X0: 24-bit hold + 28-bit adder
BYPASS_HALF = 1024 * OR2                    # bit-plane only: OR INT planes into 1,024 comparator outputs
TILE_SELF_SHIFT = 24 * (MUX3_ONEHOT - AO22) + NAND2 + INV   # alternative: in-tile x4
GLOBAL_RING_ROW = ring_row                  # alternative: one ring per global row
EMIT_BITS_PER_PE = {"INT8": 64 * 10, "W4A8": 64 * 6, "INT4": 64 * 2}   # LSB variant


def pct(x, a):
    return 100.0 * x / a


def area_rows():
    rows = []
    for pr, pc in GRIDS:
        A = grid_area(pr, pc)
        npe, nrows = pr * pc, 8 * pr
        core = npe * PE_RING + SOBOL_PRESET
        coll = nrows * COLLECTOR_ROW
        intile = npe * NT * TILE_SELF_SHIFT + SOBOL_PRESET
        gring = nrows * GLOBAL_RING_ROW + SOBOL_PRESET
        lsb = core + npe * EMIT_BITS_PER_PE["INT8"] * DFF2B
        rows.append(dict(grid=f"{pr}x{pc}", area=A, core=core, core_pct=pct(core, A),
                         coll=coll, with_coll=core + coll, with_coll_pct=pct(core + coll, A),
                         intile=intile, intile_pct=pct(intile, A), gring=gring,
                         gring_pct=pct(gring, A), lsb=lsb, lsb_pct=pct(lsb, A)))
    return rows


# ------------------------------------------------------------ cycles ----
def drain_bubble(pr, pc):
    return pr + pc + 8 * pc - 2


def slots_per_block(mode, variant, kt, pr, pc):
    """Closed form of build_schedule(): MAC slots + ring slots + drain idles."""
    segs = mdl.plan(mode, variant)
    chunk = mdl.chunk_limit(mode, variant)
    total = 0
    for lo in range(0, kt, chunk):
        cyc = math.ceil((min(lo + chunk, kt) - lo) / 8)
        for seg in segs:
            ps = seg["passes"]
            rot = sum(abs(mdl.weight(*ps[j - 1]) - mdl.weight(*ps[j])) // 2
                      for j in range(1, len(ps)))
            total += len(ps) * cyc + 8 * rot + drain_bubble(pr, pc)
    return total


def spatial_slots(mode, kt, pr, pc):
    """Other angle (all digits in space, zero tile change): one pass, one drain."""
    return math.ceil(kt / 8) + drain_bubble(pr, pc)


PEAK = {"INT8": 1, "W4A8": 2, "INT4": 4}


def bitplane_s_slots(kt, pr, pc):
    """INT8 bit-plane reference: W planes in space (8 cols = 8 planes of one
    weight), A planes weight-outer (8 passes of ceil(K/128) cycles, 7 x2
    rotations), one drain; 8 outputs per PE, K/8 MACs per tile per block."""
    return 8 * math.ceil(kt / 128) + 7 * 8 + drain_bubble(pr, pc)


def mac_per_cycle_tile(mode, variant, kt, pr, pc):
    if variant == "BP-S":
        return (kt / 8) / bitplane_s_slots(kt, pr, pc) if mode == "INT8" else float("nan")
    if variant == "HYS":
        return kt / mdl.MODES[mode]["n_w"] / slots_per_block(mode, "HYS", kt, pr, pc)
    if variant == "SPATIAL":
        return PEAK[mode] * math.ceil(kt / 8) / spatial_slots(mode, kt, pr, pc) * (kt / 8) / math.ceil(kt / 8)
    if variant == "AUTO":
        return max(mac_per_cycle_tile(mode, v, kt, pr, pc) for v in ("FH", "HYS"))
    return kt / slots_per_block(mode, variant, kt, pr, pc)


def cross_check():
    for mode in mdl.MODES:
        for variant in ("FH", "HY", "HYS", "GD", "LSB"):
            for kt in (8, 64, 520, 1100):
                for pr, pc in ((1, 1), (2, 3), (4, 4)):
                    s, _ = mdl.build_schedule(mode, variant, kt, pr, pc)
                    assert len(s) == slots_per_block(mode, variant, kt, pr, pc), \
                        (mode, variant, kt, pr, pc)
    return True


def main():
    cross_check()
    print("closed-form slot counts == model build_schedule for all modes/variants/grids checked\n")

    print("== area of the RTL changes (um2)")
    print(f"   tile: 0 (RTL unchanged)")
    print(f"   PE ring mux: 8 rows x (22 MXT2 + 2 AND2) = {8 * ring_row:.3f}; + ring_q DFFQA "
          f"{DFF1} + OR2 {OR2} + 6 BUFH {6 * BUFH:.3f} => {PE_RING:.3f} per PE "
          f"({pct(PE_RING, UPE):.3f}% of u_pe)")
    print(f"   Sobol preset: 256 AND2/OR2 force + 2 OR2 enables = {SOBOL_PRESET:.3f} per grid")
    print(f"   east collector (memory-system side): 24-bit hold + 28 FA = {COLLECTOR_ROW:.3f} per global row")
    print(f"   [bit-plane only] comparator bypass 1024 OR2 = {BYPASS_HALF:.1f} per edge half + 2x port width")
    print(f"   [alt] in-tile self-shift x4 (3rd source on 24 AO22): {TILE_SELF_SHIFT:.3f} per tile")
    print(f"   [alt] LSB-first emitted-bit buffer INT8: 640 bits x {DFF2B} = "
          f"{EMIT_BITS_PER_PE['INT8'] * DFF2B:.1f} per PE (+ readout path, not counted)")
    print(f"\n   {'grid':5s} {'area':>12s} {'ring+preset':>12s} {'%':>6s} {'+collector':>11s} "
          f"{'%':>6s} {'in-tile alt':>11s} {'%':>6s} {'global-ring':>11s} {'%':>6s} "
          f"{'LSB-buf':>9s} {'%':>6s}")
    ar = area_rows()
    for r in ar:
        print(f"   {r['grid']:5s} {r['area']:12,.1f} {r['core']:12,.1f} {r['core_pct']:6.3f} "
              f"{r['with_coll']:11,.1f} {r['with_coll_pct']:6.3f} {r['intile']:11,.1f} "
              f"{r['intile_pct']:6.3f} {r['gring']:11,.1f} {r['gring_pct']:6.3f} "
              f"{r['lsb']:9,.1f} {r['lsb_pct']:6.3f}")

    print("\n== effective MAC/cycle/tile (includes ring rotations, chunk drains, grid skew)")
    print("   SPATIAL = the other angle (all digits in space, zero tile change), for reference")
    out_rows = []
    for mode in mdl.MODES:
        for pr, pc in GRIDS:
            hdr = f"   {mode} {pr}x{pc}: " + " ".join(f"{'K=' + str(k):>8s}" for k in (64, 256, 511, 1024, 4096, 16384))
            print(hdr)
            for v in ("FH", "HY", "HYS", "GD", "LSB", "AUTO", "SPATIAL", "BP-S"):
                vals = [mac_per_cycle_tile(mode, v, k, pr, pc) for k in (64, 256, 511, 1024, 4096, 16384)]
                print(f"      {v:8s}" + " ".join(f"{x:8.3f}" for x in vals))
                for k, x in zip((64, 256, 511, 1024, 4096, 16384), vals):
                    out_rows.append(dict(mode=mode, grid=f"{pr}x{pc}", variant=v, K=k,
                                         mac_per_cycle_tile=round(x, 4)))

    print("\n== INT area efficiency, GMAC/s/mm2 (ring+preset area; collector excluded / included)")
    for pr, pc in GRIDS:
        r = next(x for x in ar if x["grid"] == f"{pr}x{pc}")
        A0, A1, A2 = r["area"], r["area"] + r["core"], r["area"] + r["with_coll"]
        ntile = NT * pr * pc
        for mode in mdl.MODES:
            for k in (511, 1024, 4096):
                u = mac_per_cycle_tile(mode, "AUTO", k, pr, pc)
                g = u * ntile * F_GHZ
                sp = mac_per_cycle_tile(mode, "SPATIAL", k, pr, pc) * ntile * F_GHZ
                print(f"   {pr}x{pc} {mode} K={k:5d}: WO-auto {u:.3f} MAC/c/t -> "
                      f"{g / (A1 / 1e6):7.1f} / {g / (A2 / 1e6):7.1f}   "
                      f"(SPATIAL ref at SC area: {sp / (A0 / 1e6):7.1f}; SC mode now "
                      f"{ntile * F_GHZ / (A1 / 1e6):6.1f} vs {ntile * F_GHZ / (A0 / 1e6):6.1f})")

    print("\n== operand bandwidth (existing ports: 512 mag + 64 sign bits per side per cycle)")
    for pr, pc in GRIDS:
        sides = pr + pc
        bits = sides * 576
        for mode in mdl.MODES:
            npass = MODES_PASSES[mode]
            mac = NT * pr * pc * PEAK[mode]
            print(f"   {pr}x{pc} {mode}: {bits} bits/cycle into the grid edges "
                  f"(576 per edge side, every cycle), {bits / mac:.3f} bits/MAC at peak; "
                  f"re-read factor {npass} (each operand re-sent once per digit-pair pass); "
                  f"SC uses {sides * 576 / 8:.0f} bits/cycle avg ({sides * 576 / 8 / (NT * pr * pc):.3f} b/MAC)")

    print("\n== dedicated BOS INT8 array sized for the same effective INT8 throughput")
    for pr, pc in GRIDS:
        r = next(x for x in ar if x["grid"] == f"{pr}x{pc}")
        for k in (1024, 4096):
            u = mac_per_cycle_tile("INT8", "AUTO", k, pr, pc)
            macs = u * NT * pr * pc
            n_bos = macs / 64
            a_bos = n_bos * BOS["INT8"]
            print(f"   {pr}x{pc} K={k}: {macs:7.1f} MAC/cycle -> {n_bos:5.2f} BOS 8x8 arrays = "
                  f"{a_bos:10,.0f} um2 = {pct(a_bos, r['area']):5.1f}% of the SC grid "
                  f"(vs WO INT mode {r['with_coll']:,.0f} um2 = {r['with_coll_pct']:.2f}%)")
        w4 = mac_per_cycle_tile("W4A8", "AUTO", 4096, pr, pc) * NT * pr * pc
        i4 = mac_per_cycle_tile("INT4", "AUTO", 4096, pr, pc) * NT * pr * pc
        print(f"      K=4096 W4A8 {w4:.0f} MAC/c -> {w4 / 64 * BOS['INT8']:,.0f} um2 (BOS INT8 arrays); "
              f"INT4 {i4:.0f} MAC/c -> {i4 / 64 * BOS['INT4']:,.0f} um2 (BOS INT4 arrays)")

    print("\n== FH -> HYS crossover (smallest K where HYS beats FH) and BP-S area")
    for pr, pc in GRIDS:
        kx = next(k for k in range(8, 20000, 8)
                  if mac_per_cycle_tile("INT8", "HYS", k, pr, pc) > mac_per_cycle_tile("INT8", "FH", k, pr, pc))
        r = next(x for x in ar if x["grid"] == f"{pr}x{pc}")
        bp_area = r["core"] + (pr + pc) * BYPASS_HALF
        ntile = NT * pr * pc
        bp = [mac_per_cycle_tile("INT8", "BP-S", k, pr, pc) * ntile * F_GHZ / ((r["area"] + bp_area) / 1e6)
              for k in (1024, 4096, 16384)]
        print(f"   {pr}x{pc}: INT8 crossover K={kx}; BP-S extra area {bp_area:,.0f} um2 "
              f"({pct(bp_area, r['area']):.2f}%), INT8 GMAC/s/mm2 at K=1024/4096/16384: "
              + " / ".join(f"{x:.0f}" for x in bp))

    with open(HERE / "weight_outer_horner_costs.csv", "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(out_rows[0].keys()))
        wr.writeheader()
        wr.writerows(out_rows)
    print(f"\nwrote {HERE / 'weight_outer_horner_costs.csv'}")


MODES_PASSES = {m: len(mdl.plan(m, "FH")[0]["passes"]) for m in mdl.MODES}

if __name__ == "__main__":
    main()
