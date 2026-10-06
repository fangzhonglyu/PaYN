#!/usr/bin/env python3
"""INT-mode cost table for PaYN (CSA variant): cell areas, block areas, grid
composite, INT baselines and the per-tile estimating rule.

Every input number is copied from an existing repo report (path in `src`);
nothing here runs an EDA tool.  Cell areas are LEF footprints of the A7 SVT C30
base/HPK libraries (the same values PrimeTime reports per reference in
build/area_anatomy/*.rpt and build/power_char/tile_area_audit_20260930/).

Writes sweeps/int_mode/cost_table.csv and prints the derived tables.
Usage: python3 sweeps/int_mode/cost_table.py
"""
import csv
from pathlib import Path

OUT = Path(__file__).resolve().parent / "cost_table.csv"
F_GHZ = 0.4

# ---------------------------------------------------------------- cells --
# (cell, um2, note).  LEF: libs/lef copies referenced by the CSA innovus.log.
CELLS = [
    ("MXT2_X1M (mux2, non-inverting TG)", 0.784, "X0P5..X1 all 0.784; X1P4M 0.882; seen in BS synth timing.rpt"),
    ("MXIT2_X1M (mux2, inverting TG)", 0.686, "X0P5..X1 0.686; X1P4M 1.274; DC used 17/PE in BS acc"),
    ("MX2_X1B (mux2, static)", 0.882, "X0P5B..X1B 0.882"),
    ("MXGL2_X1B (mux2 glitch-less)", 1.274, ""),
    ("AO22_X1M", 0.686, "X0P5M/X0P7M 0.686, X1P4M 0.784; = tile drain mux"),
    ("AOI22_X0P7M", 0.490, "X0P5M 0.490; X1M/X1A 0.588"),
    ("OAI22_X0P7M", 0.490, ""),
    ("AO21_X1M", 0.588, ""),
    ("AOI21_X1A / OAI21_X1A", 0.392, ""),
    ("NAND2_X1A / NOR2_X1A", 0.294, ""),
    ("AND2_X1M / OR2_X1M", 0.392, "AND2 X0P5..X1 all 0.392 (tile product AND)"),
    ("AND3_X1M", 0.490, ""),
    ("INV_X1M", 0.196, ""),
    ("BUFH_X1M", 0.294, ""),
    ("XOR2_X0P7M / XNOR2_X0P7M", 0.588, "X1M 0.882"),
    ("XOR3_X0P7M", 1.176, ""),
    ("ADDF_X1M (full adder)", 1.666, "routed tiles use only X1M"),
    ("ADDF_X1P4M", 1.862, "34+6 per synth tile, downsized at route"),
    ("ADDH_X1M (half adder)", 0.980, "X1P4M 1.176"),
    ("DFFQA_X1M (1-bit flop, no reset)", 1.470, "tile acc/pending; DFFQ_X1M 1.862"),
    ("DFFQA2W_X1M per bit (2-bit multibit)", 1.372, "cell 2.744; bit pipes, sign pipes, tile acc"),
    ("DFFRPQA_X1M (1-bit async reset)", 1.666, "peripheral, Sobol"),
    ("DFFRPQA2W_X1M per bit (async reset)", 1.617, "cell 3.234; peripheral held operands"),
    ("SDFFQA_X1M (scan flop = flop+mux2)", 2.058, "not used by default flow; +0.588 over DFFQA"),
    ("SDFFQA2W_X1M per bit", 1.960, "cell 3.92 (double height); +0.588/bit over DFFQA2W"),
    ("PREICG_X0P5B (ICG)", 1.470, "X1B 1.47; routed tile ICG X5B 2.156"),
    ("LATQ_X1M", 0.980, ""),
    ("CGENI_X1M (comparator carry cell)", 0.686, "8,691 in peripheral"),
]
ABSENT = ("No enable flop (EDFF*), no AO222/AOI222, no MX3/MX4 in the library: "
          "enable = ICG or flop+MXT2/MXIT2; 3:1 one-hot mux ~ AOI22+NAND2+NAND2 = 1.078/bit; "
          "4:1 one-hot ~ 2xAOI22+NAND2 = 1.274/bit; 4:1 tree = 3xMXT2 = 2.352/bit.")

# --------------------------------------------------------------- blocks --
# tile split from sweeps/int_mode/csa_tile_split.py on the matched synth netlist
TILE_SYN = [
    ("product AND2 (128)", 50.176),
    ("lane counters (8 x 11 FA)", 153.272),
    ("lane sign XOR/XNOR (40)", 23.520),
    ("sign glue (8 a^w XOR, countones, -16N row)", 18.326),
    ("heap DW02_tree (35 FA, 5 HA, 1 XOR)", 64.974),
    ("final CPA (8 FA + 1 HA, 9-bit ripple)", 14.308),
    ("carry/borrow decode", 2.842),
    ("high segment +-1 (14 FA + XOR3 + NAND3BB)", 24.990),
    ("drain/reset control glue", 1.764),
    ("drain mux AO22 (24)", 16.464),
    ("state flops (26 bits)", 36.064),
    ("tile ICG", 1.470),
]
TILE_SYN_TOTAL = 408.170          # build/area_anatomy/csa_syn_area_anatomy.rpt
TILE_APR_AVG = 25849.166 / 64     # apr .../reports/area.rpt, 64 tiles

UPE_APR = 29255.548               # apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_fixed/reports/area.rpt
PERIPH_APR = 13031.256
SOBOL_PAIR_APR = 844.760 + 833.588
TOTAL_APR = 44017.974
UPE_SYN = 29253.000               # syn/build/TSMC22/PAYN_SC_CSA/csa_20261002/area.rpt
PERIPH_SYN = 12792.920
SOBOL_PAIR_SYN = 698.152 + 707.854
TOTAL_SYN = 43454.964

PE_SPLIT_SYN = [
    ("64 tiles", 26198.340),
    ("A+W bit pipes (1,024 DFFQA2W = 2,048 bits)", 2809.856),
    ("A+W sign pipes (64 DFFQA2W = 128 bits)", 175.616),
    ("sign-pipe sync-reset gating (130 NOR2XB)", 50.960),
    ("buffers (33 BUFH)", 9.702),
    ("load-wave flops (2 DFFQA)", 2.940),
    ("ICGs (sign pipes x2, shared acc_low x1)", 4.410),
    ("misc (2 OR2, TIELO)", 1.176),
]
PERIPH_SPLIT_SYN = [
    ("held magnitudes 1,024 bits (DFFRPQ[N]A2W) + 2 ICG", 1658.846),
    ("held signs 128 bits (64 DFFRPQA2W)", 206.976),
    ("2,048 comparators incl. scramble/distribution INV/BUF (comb)", 10927.098),
]


def grid(pr, pc, upe=UPE_APR, periph=PERIPH_APR, sobol=SOBOL_PAIR_APR):
    """doc/SC_area_efficiency.md 3b: P_R*P_C*u_pe + (P_R+P_C)*periph/2 + one Sobol pair."""
    return pr * pc * upe + (pr + pc) * periph / 2 + sobol


BASELINES = [
    # name, area um2, MAC/cycle, src
    ("BOS INT8 (8x8 OS, 1 MAC/PE)", 15797.404, 64, "apr/build/TSMC22/BOS_ARRAY/20260728_143921/reports/area.rpt"),
    ("BOS INT6 native", 12403.664, 64, "build/bos_precision/bos_precision_20261002/results.csv"),
    ("BOS INT4 native", 10276.378, 64, "build/bos_precision/bos_precision_20261002/results.csv"),
    ("BP INT8 (8x8 WS)", 16536.226, 64, "apr/build/TSMC22/BP_ARRAY/20260718_165153 (doc/results.md 16,536)"),
    ("BS bit-serial 8x8 (8 cyc/MAC)", 13674.724, 8, "apr/build/TSMC22/BS_ARRAY/20260718_183112/reports/area.rpt"),
    ("bitmod Simple i8xi8 (16 tiles)", 357858, 1024, "doc/bitmod_results.md (collaborator CSV, not reproduced)"),
    ("bitmod Simple i6xi8", 357858, 1365.33, "doc/bitmod_results.md"),
    ("bitmod Simple i4xi8", 357858, 2048, "doc/bitmod_results.md"),
    ("bitmod Simple i2xi8", 357858, 4096, "doc/bitmod_results.md"),
    ("bitmod Simple tile only i8", 21906, 64, "doc/bitmod_results.md"),
    ("bitmod BitMoD i8xf16", 1129910, 1024, "doc/bitmod_results.md"),
    ("bitmod BitMoD f4xf16", 1129910, 2048, "doc/bitmod_results.md"),
    ("PaYN CSA SC T=128 (1 PE, routed)", TOTAL_APR, 64, "designs/payn/variants/signed_segmented_csa/README.md"),
    ("PaYN CSA SC 4x4 composite", grid(4, 4), 1024, "composite, this script"),
    ("PaYN CSA SC 4x8 composite", grid(4, 8), 2048, "composite, this script"),
]


def eff(area_um2, mac_per_cycle):
    return mac_per_cycle * F_GHZ / (area_um2 * 1e-6)


def main():
    rows = []
    print("== cells (um2)")
    for c, a, n in CELLS:
        print(f"  {c:42s} {a:6.3f}  {n}")
        rows.append(("cell", c, f"{a:.3f}", n))
    print("  " + ABSENT)
    rows.append(("cell", "absent", "", ABSENT))

    print(f"\n== tile split, synth (sum {sum(a for _, a in TILE_SYN):.3f} vs report {TILE_SYN_TOTAL})")
    for n, a in TILE_SYN:
        print(f"  {n:48s} {a:8.3f}  {100*a/TILE_SYN_TOTAL:5.1f}%")
        rows.append(("tile_syn", n, f"{a:.3f}", f"{100*a/TILE_SYN_TOTAL:.1f}% of tile"))
    print(f"  routed tile average {TILE_APR_AVG:.3f} (routed/synth {TILE_APR_AVG/TILE_SYN_TOTAL:.4f})")
    rows.append(("tile_apr", "routed tile average", f"{TILE_APR_AVG:.3f}", "64 tiles"))

    print(f"\n== PE split, synth (sum {sum(a for _, a in PE_SPLIT_SYN):.3f} vs {UPE_SYN})")
    for n, a in PE_SPLIT_SYN:
        print(f"  {n:48s} {a:9.3f}")
        rows.append(("pe_syn", n, f"{a:.3f}", ""))
    print(f"  routed u_pe {UPE_APR} = tiles {25849.166} + non-tile {UPE_APR-25849.166:.3f}")
    print(f"\n== peripheral split, synth (sum {sum(a for _, a in PERIPH_SPLIT_SYN):.3f} vs {PERIPH_SYN})")
    for n, a in PERIPH_SPLIT_SYN:
        print(f"  {n:60s} {a:9.3f}")
        rows.append(("periph_syn", n, f"{a:.3f}", ""))
    print(f"  per comparator {10927.098/2048:.3f} um2; routed periph {PERIPH_APR} "
          f"(edge half {PERIPH_APR/2:.3f}); Sobol pair routed {SOBOL_PAIR_APR:.3f} synth {SOBOL_PAIR_SYN:.3f}")

    print("\n== grid composite (routed inputs, doc 3b formula)")
    for pr, pc in ((1, 1), (4, 4), (4, 8)):
        A = grid(pr, pc)
        edge = (pr + pc) * PERIPH_APR / 2 + SOBOL_PAIR_APR
        g = eff(A, 64 * pr * pc)
        print(f"  {pr}x{pc}: {A:12.3f} um2  edge share {100*edge/A:5.2f}%  "
              f"SC {25.6*pr*pc:7.1f} GMAC/s  {g:7.2f} GMAC/s/mm2")
        rows.append(("grid", f"{pr}x{pc}", f"{A:.3f}", f"edge {100*edge/A:.2f}%; {g:.2f} GMAC/s/mm2"))

    print("\n== baselines")
    for n, A, mpc, src in BASELINES:
        g = eff(A, mpc)
        print(f"  {n:36s} {A:12.3f} um2 {mpc:8.2f} MAC/cyc {mpc*F_GHZ:7.1f} GMAC/s "
              f"{g:8.1f} GMAC/s/mm2  {A/mpc:8.1f} um2/(MAC/cyc)")
        rows.append(("baseline", n, f"{A:.3f}", f"{mpc} MAC/cyc; {g:.1f} GMAC/s/mm2; {src}"))

    print("\n== estimating rule (per um2 added in every tile)")
    for label, A, npe in (("1 PE", TOTAL_APR, 1), ("4x4", grid(4, 4), 16), ("4x8", grid(4, 8), 32)):
        per = 64 * npe / A * 100
        sc = eff(A, 64 * npe)
        print(f"  {label}: +{64*npe} um2 per um2/tile = {per:.4f}% of area; SC eff {sc:.2f} -> "
              f"{eff(A + 64*npe, 64*npe):.2f} GMAC/s/mm2 per um2/tile; "
              f"1 MAC/cyc/tile = {eff(A, 64*npe):.1f} GMAC/s/mm2")
        for cname, a in (("MXT2", 0.784), ("AO22/MXIT2", 0.686), ("24 x MXT2", 24 * 0.784),
                         ("24 x AO22", 24 * 0.686), ("1 DFFQA2W bit", 1.372)):
            d = 64 * npe * a
            print(f"     {cname:14s} {a:7.3f}/tile -> {64*a:8.3f}/PE -> +{d:9.3f} um2 = {100*d/A:.4f}%")
            rows.append(("rule", f"{label} {cname}", f"{d:.3f}", f"{100*d/A:.4f}% of {label}"))
    with OUT.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["kind", "item", "area_um2", "note"])
        w.writerows(rows)
    print(f"\nwrote {OUT}")


if __name__ == "__main__":
    main()
