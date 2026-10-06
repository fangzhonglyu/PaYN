#!/usr/bin/env python3
"""Area / throughput / bandwidth tables for the bit-plane INT mode on PaYN.

Companion of model_bitplane_throughput.py (which proves the schedules exact).
Cell-count ESTIMATES (no synthesis) using the LEF footprints listed in
sweeps/int_mode/cost_table.py; block areas are the routed CSA numbers.
Usage: python3 sweeps/int_mode/bitplane_throughput_costs.py
"""
import math

F = 0.4  # GHz
# ------------------------------------------------------------ cell areas --
OR2, AND2, AO22, NAND2, AOI22 = 0.392, 0.392, 0.686, 0.294, 0.490
FA, HA, INV, BUFH = 1.666, 0.980, 0.196, 0.294
DFF, DFF2W = 1.470, 1.372          # 1-bit flop, multibit flop per bit
# ------------------------------------------------------------ base areas --
UPE = 29255.548                    # routed u_pe
PERIPH = 13031.256                 # routed, both halves
SOBOL = 844.760 + 833.588
ARRAY1 = 44017.974                 # routed single-PE array
TILE = 408.170                     # synth tile


def grid_area(pr, pc):
    if (pr, pc) == (1, 1):
        return ARRAY1
    return pr * pc * UPE + (pr + pc) * PERIPH / 2 + SOBOL


GRIDS = [(1, 1), (4, 4), (4, 8)]

# ------------------------------------------------- INT additions (um2) ----
EDGE_HALF = {   # per edge half (A side of a PE row, W side of a PE column)
    "raw-bit OR bypass, 1024 OR2": 1024 * OR2,
    "INT gate on magnitude-register load (1 gate/bank)": AND2,
}
# east-edge plane combiner, one per PE row
COMB = {
    "8-operand shifted CSA tree (~130 FA + 10 HA + 8 INV)": 130 * FA + 10 * HA + 8 * INV,
    "carry-save pipeline register (62 b)": 62 * DFF2W,
    "32-bit CPA": 32 * FA,
    "INT4 group split (31 AND2)": 31 * AND2,
    "40-bit Horner register R<-2R+S (40 FA + 40 flop + 40 AND2), = output reg": 40 * (FA + DFF2W + AND2),
}
PE_RING = {     # per PE, HW-ring mechanism
    "west drain-input mux, 8 rows x 24 b AO22": 192 * AO22,
    "ring_q wave flop (re-exported like load_a_sign_q)": DFF,
    "shift_in | ring_q OR + select buffering (4 BUFH)": OR2 + 4 * BUFH,
    "east->west return wire buffers (allowance: 96 of 192 bits)": 96 * BUFH,
}
TILE_SELF = {   # per tile, HW-self mechanism
    "3rd source on 23 drain-mux bits: AO22 -> AOI22+2 NAND2 (+0.392/b)": 23 * (AOI22 + 2 * NAND2 - AO22),
    "one-hot select decode (2 gates)": 2 * AND2,
    "acc_high ICG enable |= dbl": OR2,
}
PE_SELF = {"dbl_q wave flop + acc_low ICG enable OR": DFF + OR2}

edge_half = sum(EDGE_HALF.values())
comb = sum(COMB.values())
pe_ring = sum(PE_RING.values())
tile_self = sum(TILE_SELF.values())
pe_self = sum(PE_SELF.values()) + 64 * tile_self


def added(option, pr, pc):
    a = (pr + pc) * edge_half + pr * comb
    if option == "HW-ring":
        a += pr * pc * pe_ring
    elif option == "HW-self":
        a += pr * pc * pe_self
    return a


# Booth digit-grid (other angle) edge estimate from its architect:
# 0.56k per A half, 0.96k per W half, ~0.5k fixed-shift combiner per PE row.
def added_booth(pr, pc, ring=False):
    return pr * 560 + pc * 960 + pr * 500 + (pr * pc * pe_ring if ring else 0)


# --------------------------------------------------------- throughput -----
PREC = {"INT8": (8, 8), "W4A8": (8, 4), "INT4": (4, 4)}


def block(mapping, prec, K, pr, pc):
    """(outputs per PE, data cycles C, doubling cycles X) per output block."""
    ba, bw = PREC[prec]
    nb = math.ceil(K / 128)
    if mapping == "S":
        return (8 // ba) * (8 // bw), nb, 0
    if mapping in ("HW-ring", "HW-self"):
        L = 8 if mapping == "HW-ring" else 1
        return (8 // ba) * 8, bw * nb, (bw - 1) * L
    if mapping in ("HB-ring", "HB-self"):
        L = 8 if mapping == "HB-ring" else 1
        return 64, ba * bw * nb, (ba + bw - 2) * L
    if mapping in ("Booth", "Booth-ring"):          # other angle, for comparison
        dpm = {"INT8": 8, "W4A8": 4, "INT4": 2}[prec]   # digit pairs per MAC
        outs = 64 // dpm
        if mapping == "Booth":
            return outs, math.ceil(K / 8), 0
        # a-digit Horner (x4 per ring lap): rows = 8 act rows
        nad = {"INT8": 4, "W4A8": 4, "INT4": 2}[prec]
        return outs * nad, nad * math.ceil(K / 8), (nad - 1) * 8
    raise ValueError(mapping)


def eff_mac_per_tile(mapping, prec, K, pr, pc):
    outs, C, X = block(mapping, prec, K, pr, pc)
    S, D = pr + pc - 2, 8 * pc
    cyc = C + X + S + D
    return outs * K / cyc / 64, C / cyc


PEAK = {"INT8": 2, "W4A8": 4, "INT4": 8}


def main():
    print("== INT additions (cell-count estimates, um2)")
    for title, d in (("per edge half", EDGE_HALF), ("east combiner per PE row", COMB),
                     ("HW-ring per PE", PE_RING), ("HW-self per tile", TILE_SELF),
                     ("HW-self per PE (excl. tiles)", PE_SELF)):
        print(f"  {title}: {sum(d.values()):.1f}")
        for k, v in d.items():
            print(f"     {v:8.2f}  {k}")
    print(f"  HW-self per PE incl. 64 tiles: {pe_self:.1f}  ({tile_self:.2f}/tile = "
          f"{100*tile_self/TILE:.2f}% of the synth tile)")

    print("\n== overhead by grid")
    print(f"  {'option':9s} " + "  ".join(f"{f'{pr}x{pc}':>22s}" for pr, pc in GRIDS))
    for opt in ("BP-S", "HW-ring", "HW-self"):
        cells = []
        for pr, pc in GRIDS:
            a = added(opt, pr, pc)
            cells.append(f"{a:8.0f} um2 {100*a/grid_area(pr,pc):5.2f}%")
        print(f"  {opt:9s} " + "  ".join(f"{c:>22s}" for c in cells))
    for pr, pc in GRIDS:
        A = grid_area(pr, pc)
        print(f"  {pr}x{pc} base {A:,.0f} um2, SC {64*pr*pc*F/(A*1e-6):.1f} GMAC/s/mm2 -> "
              + ", ".join(f"{o} {64*pr*pc*F/((A+added(o,pr,pc))*1e-6):.1f}"
                          for o in ("BP-S", "HW-ring", "HW-self")))

    print("\n== effective INT MAC/cycle/tile (and data-cycle utilisation)")
    Ks = [256, 512, 1024, 2048, 4096, 16384]
    maps = ["S", "HW-ring", "HW-self", "HB-ring", "HB-self", "Booth", "Booth-ring"]
    for prec in PREC:
        print(f"  -- {prec} (bit-plane peak {PEAK[prec]}, Booth peak {PEAK[prec]/2:g})")
        for pr, pc in GRIDS:
            for mp in maps:
                if mp.startswith("HB") and prec == "INT8":
                    continue
                vals = [eff_mac_per_tile(mp, prec, K, pr, pc)[0] for K in Ks]
                print(f"    {pr}x{pc} {mp:10s} " + " ".join(f"K{K}:{v:5.2f}" for K, v in zip(Ks, vals)))

    print("\n== INT GMAC/s/mm2 (area incl. INT additions), grid 4x4 and 4x8")
    rows = [("BP-S", "S", "BP-S"), ("HW-ring", "HW-ring", "HW-ring"),
            ("HW-self", "HW-self", "HW-self"), ("HB-ring (W4A8/INT4)", "HB-ring", "HW-ring"),
            ("Booth all-space", "Booth", None), ("Booth + ring", "Booth-ring", "booth-ring")]
    for pr, pc in ((4, 4), (4, 8), (1, 1)):
        A0 = grid_area(pr, pc)
        print(f"  -- {pr}x{pc}")
        for prec in PREC:
            for name, mp, area_opt in rows:
                if mp.startswith("HB") and prec == "INT8":
                    continue
                if area_opt is None:
                    A = A0 + added_booth(pr, pc)
                elif area_opt == "booth-ring":
                    A = A0 + added_booth(pr, pc, ring=True)
                else:
                    A = A0 + added(area_opt, pr, pc)
                peak = PEAK[prec] / (2 if mp.startswith("Booth") else 1)
                pk = peak * 64 * pr * pc * F / (A * 1e-6)
                e = [eff_mac_per_tile(mp, prec, K, pr, pc)[0] * 64 * pr * pc * F / (A * 1e-6)
                     for K in (1024, 4096, 16384)]
                print(f"    {prec:4s} {name:20s} peak {pk:7.1f} | K1024 {e[0]:7.1f} "
                      f"K4096 {e[1]:7.1f} K16384 {e[2]:7.1f}")

    print("\n== bandwidth")
    for prec, macs in (("INT8", 128), ("W4A8", 256), ("INT4", 512)):
        print(f"  {prec}: PE 2048 b/cyc = {2048/macs:.2f} b/MAC; "
              f"4x4 8192 b/cyc = {8192/(macs*16):.2f} b/MAC; "
              f"4x8 12288 b/cyc = {12288/(macs*32):.2f} b/MAC")
    print("  SC: PE 144 b/cyc avg (2.25 b/MAC); 4x4 576 (0.5625 b/MAC); 4x8 864 (0.42)")
    print("  Booth all-space INT8 (8-bit values): PE 384 (6 b/MAC); 4x4 1536 (1.5); 4x8 2560 (1.25)")
    print("  BOS INT8 8x8: 128 b/cyc (2 b/MAC); a 32x32 OS array: 512 b/cyc (0.5 b/MAC)")

    print("\n== dedicated BOS arrays for the same effective INT throughput (4x4, K=4096)")
    bos = {"INT8": 15797.404, "W4A8": 12403.664, "INT4": 10276.378}  # W4A8 ~ INT6 proxy
    A0 = grid_area(4, 4)
    for prec in PREC:
        for mp, opt in (("S", "BP-S"), ("HW-ring", "HW-ring"), ("HW-self", "HW-self")):
            e = eff_mac_per_tile(mp, prec, 4096, 4, 4)[0] * 1024
            nb = e / 64
            ab = nb * bos[prec]
            print(f"  {prec} {mp:8s}: {e:7.1f} MAC/cyc -> {nb:5.1f} BOS arrays = {ab:9,.0f} um2 "
                  f"({100*ab/A0:5.1f}% of grid) vs bit-plane add {added(opt,4,4):6,.0f} um2 "
                  f"({100*added(opt,4,4)/A0:4.2f}%); chip SC eff with BOS "
                  f"{1024*F/((A0+ab)*1e-6):6.1f} vs {1024*F/((A0+added(opt,4,4))*1e-6):6.1f}")


if __name__ == "__main__":
    main()
