#!/usr/bin/env python3
"""Adversarial cost / system-realism audit of the round-1 design
'reduction_outer_rotating' (bidirectional +-2 accumulator ring, Booth 2x8).

No EDA tools.  Inputs:
  * cell areas  : sweeps/int_mode/cost_table.csv (LEF footprints)
  * tile / PE / grid composite : sweeps/int_mode/cost_table.py (routed CSA)
  * design claims: sweeps/int_mode/design_round1.json, model_reduction_outer_rotating.py
  * RTL: designs/payn/variants/signed_segmented_csa/*.sv, designs/payn/pe_peripheral.sv,
         designs/payn/variants/signed_segmented_clean/inner_pe_grid_signed_segmented_clean.sv
           (grid: A east, W south, global mac_en/shift_in, every acc row drains east
            through all P_C PEs -> 8*P_C cycles per drain)
  * competitor schedules: weight_outer_horner_costs.py (WO-ring, imported),
    CNSB / spatial formula from design_round1.json ((L/8) + 8P_C + P_R + P_C - 2).

Usage: python3 sweeps/int_mode/verify/reduction_outer_rotating/cost_realism_audit.py
"""
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
INT_MODE = HERE.parent.parent
sys.path.insert(0, str(INT_MODE))
import model_reduction_outer_rotating as rot   # noqa: E402
import weight_outer_horner_costs as wo          # noqa: E402

F_GHZ = 0.4
C = dict(AO22=0.686, AOI22=0.490, NAND2=0.294, NOR2=0.294, AND2=0.392, OR2=0.392, AND3=0.490,
         OR3=0.490, OA21=0.588, AO21=0.588, XOR2=0.588, MXT2=0.784, DFFQA=1.470, DFF2B=1.372,
         BUFH=0.294, FA=1.666, HA=0.980, INV=0.196)
UPE, PERIPH, SOBOL, SINGLE = 29255.548, 13031.256, 844.760 + 833.588, 44017.974
TILE_SYN = 408.170
BOS8 = 15797.404


def composite(pr, pc):
    return SINGLE if (pr, pc) == (1, 1) else pr * pc * UPE + (pr + pc) * PERIPH / 2 + SOBOL


def hdr(s):
    print("\n== " + s)


# --------------------------------------------------------------- 1. area --
def area_audit():
    tile, tt, pe, pt, a_lane, w_lane, a_half, w_half, seq = rot.costs()
    hdr("1. area recount (claimed values re-derived from rot.costs(), then corrections)")
    print(f"  claimed tile delta {tt:.3f} um2 = {100*tt/TILE_SYN:.2f}% of synth tile; "
          f"A lane {sum(a for _, a in a_lane):.3f}, W lane {sum(a for _, a in w_lane):.3f}")
    # RTL check: inner_tile_signed_segmented_csa.sv:120 acc_low enters the heap directly
    # (new 9-bit 3:1 mux is real new logic); :158-165 acc_high D = shift_in ? acc_in : high_next
    # (15 of the 24 AO22 drain muxes), ICG enable = shift_in | pending (+reset) -> R|L must join it.
    # Select fanout: one-hot 3:1 (AOI22+NAND2+NAND2) has 3 select pins/bit; one-hot 4:1
    # (2 AOI22 + NAND2) has 4 select pins/bit vs AO22's 2.  New select pins per tile:
    new_pins = 9 * 3 + 15 * 2
    per_pe_pins = 64 * new_pins
    bufs = per_pe_pins / 16.0                # one BUFH per ~16 loads at 400 MHz (assumption)
    buf_um2 = bufs * C["BUFH"]
    budgeted = 64 * 0.216 + 8 * C["BUFH"]
    extra_buf_tile = (buf_um2 - budgeted) / 64
    print(f"  select fanout: {new_pins} new select pins/tile = {per_pe_pins} per PE -> ~{bufs:.0f} BUFH "
          f"= {buf_um2:.1f} um2/PE vs budgeted {budgeted:.1f} -> +{extra_buf_tile:.2f} um2/tile equivalent")
    # W |d| thermometer, explicit gates (y = x^x4; o=y1|y0, a=y1&y0;
    # t0=OR3(y3,y2,o) t1=OR3(y3,y2,a) t2=AO21 t3=AO21 t4=OA21 t5=OA21 t6=AND3 t7=AND3)
    therm = 4 * C["XOR2"] + C["OR2"] + C["AND2"] + 2 * C["OR3"] + 2 * C["AO21"] + 2 * C["OA21"] + 2 * C["AND3"]
    print(f"  W recoder: explicit gate count {therm:.3f} um2/lane vs 9.0 estimate "
          f"({therm - 9.0:+.2f}/lane, {64*(therm-9.0):+.0f} um2 per W half)")
    # step-index fanout at the edge: A: 64 lanes x 3 one-hot 4:1 x 4 selects; W: 64 x 4 MXT2 + 64 AND2
    a_sel_loads, w_sel_loads = 64 * 3 * 4, 64 * 5
    edge_buf = (a_sel_loads + w_sel_loads) / 16 * C["BUFH"]
    print(f"  edge step-select fanout ({a_sel_loads}+{w_sel_loads} loads/PE edge) ~{edge_buf:.1f} um2 per PE edge, not counted")
    tile_c = tt + extra_buf_tile
    w_half_c = w_half + 64 * (therm - 9.0)
    rows = {}
    for pr, pc in ((1, 1), (4, 4), (4, 8), (8, 4)):
        npe = pr * pc
        base = composite(pr, pc)
        skew = 4 * (pr * (pr - 1) // 2 + pc * (pc - 1) // 2) * C["DFFQA"]
        claimed = 64 * npe * tt + npe * pt + pr * a_half + pc * w_half + skew + seq
        corr = 64 * npe * tile_c + npe * pt + pr * a_half + pc * w_half_c + skew + seq + (pr + pc) * edge_buf
        tiles_only = 64 * npe * tt
        # excluded memory-system items for INT8 segmentation (drain emits 8 values/cycle per grid row)
        n_add = 8 * pr
        adders = n_add * 32 * C["FA"]
        psum_bits = 64 * npe * 32
        psum_ff = psum_bits * C["DFF2B"]
        psum_sram_lo, psum_sram_hi = psum_bits * 0.2, psum_bits * 0.3   # assumption: small SRAM incl. periphery
        rows[(pr, pc)] = dict(base=base, claimed=claimed, corr=corr, tiles=tiles_only, adders=adders,
                              psum_ff=psum_ff, psum_lo=psum_sram_lo, psum_hi=psum_sram_hi,
                              edge=pr * a_half + pc * w_half + skew + seq)
        sc0 = 64 * npe * F_GHZ / (base * 1e-6)
        print(f"  {pr}x{pc}: composite {base:,.0f}; claimed add {claimed:,.0f} ({100*claimed/base:.2f}%), "
              f"tiles alone {tiles_only:,.0f} ({100*tiles_only/base:.2f}%), recount {corr:,.0f} ({100*corr/base:.2f}%); "
              f"SC {sc0:.1f} -> {64*npe*F_GHZ/((base+corr)*1e-6):.1f} GMAC/s/mm2")
        print(f"        excluded (INT8 L>496): {n_add} x 32b east adders {adders:,.0f} um2 ({100*adders/base:.2f}%) "
              f"[design text: 1 per grid row = {pr*53.3:.0f}]; psum store {psum_bits:,} b = flops {psum_ff:,.0f} "
              f"({100*psum_ff/base:.1f}%) or SRAM ~{psum_sram_lo:,.0f}-{psum_sram_hi:,.0f} ({100*psum_sram_lo/base:.1f}-{100*psum_sram_hi/base:.1f}%)"
              f" or RMW in the output buffer (bandwidth, see 3)")
    # comparator-path alternative (presets verified by model_spatial_fixed_weight part 0 / CNSB):
    # mux an 8-bit per-lane code into the comparator magnitude input instead of injecting 16 bits after it
    a_alt = 3 * (2 * C["AOI22"] + C["NAND2"]) + 2 * C["XOR2"] + C["OR2"] + C["NOR2"] + 8 * C["MXT2"] + C["MXT2"]
    w_alt = 4 * C["MXT2"] + C["AND2"] + 4 * C["XOR2"] + 5.0 + 8 * C["MXT2"] + C["MXT2"]   # 5.0: per-lane 9x8 code LUT (estimate)
    a_cl, w_cl = sum(a for _, a in a_lane), sum(a for _, a in w_lane)
    print(f"  comparator-path alternative (code mux before comparator + Sobol preset 101 um2/grid): "
          f"A {a_alt:.2f} vs {a_cl:.2f}, W {w_alt:.2f} vs {w_cl:.2f} um2/lane -> "
          f"saves {64*(a_cl-a_alt+w_cl-w_alt):.0f} um2 per PE edge; 4x4 {4*64*(a_cl-a_alt+w_cl-w_alt)-101:,.0f} "
          f"({100*(4*64*(a_cl-a_alt+w_cl-w_alt)-101)/composite(4,4):.2f}%); puts ~4 gate levels on the comparator "
          f"magnitude input, next to the +0.307 ns worst path (untimed)")
    return rows, tt, a_half, w_half


# --------------------------------------------------- 2. segments and L --
def weight_aware_kseg(rng):
    """Compile-time-safe INT8 segment length when only W is known:
    sum_k |a||w| <= 128 * sum_k |w|  (activations unbounded within INT8).
    Per-channel symmetric quantisation of a 4096-long column, max |w| -> 127."""
    over = rot.K * sum(2 * 8 * (1 << rot.sigma_of(p, q)) for p, q in rot.MODES["INT8"][2])
    budget = rot.OFFSET - 1 - over
    out = {}
    for name, gen in (("gaussian", lambda n: rng.standard_normal(n)),
                      ("student_t4 (heavy tail)", lambda n: rng.standard_t(4, n)),
                      ("laplace", lambda n: rng.laplace(size=n))):
        ks = []
        for _ in range(200):
            w = gen(4096)
            q = np.round(w / np.abs(w).max() * 127)
            ks.append(budget / (128 * np.abs(q).mean()))
        out[name] = (float(np.percentile(ks, 5)), float(np.median(ks)))
    return out, budget


def drain_overhead(pr, pc):
    return 8 * pc + pr + pc - 2


def rot_cycles(L, pr, pc, kseg):
    nseg = math.ceil(L / kseg)
    return 8 * math.ceil(L / 8) + nseg * drain_overhead(pr, pc), nseg


def cnsb_cycles(L, pr, pc):
    return math.ceil(L / 8) + drain_overhead(pr, pc)


def bos_cycles(L, pr, pc, kseg=511):
    return L + math.ceil(L / kseg) * drain_overhead(pr, pc)


def layer_eff(M, N, L, pr, pc, design, area, kseg=496):
    """Effective MAC/cycle over a whole GEMM, incl. footprint padding."""
    if design == "ROT":
        fm, fn = 8 * pr, 8 * pc
        cyc = rot_cycles(L, pr, pc, kseg)[0]
    elif design == "SC":
        fm, fn = 8 * pr, 8 * pc
        cyc = 8 * math.ceil(L / 8) + drain_overhead(pr, pc)
    elif design == "BOS":
        fm, fn = 8 * pr, 8 * pc
        cyc = bos_cycles(L, pr, pc)
    elif design == "CNSB":
        # 4x4 r4rows: 2x4 outputs per PE; 4x8 r16rows: 4x2 per PE (design_round1.json)
        fm, fn = (2 * pr, 4 * pc) if pc <= pr else (4 * pr, 2 * pc)
        cyc = cnsb_cycles(L, pr, pc)
    elif design == "WO":
        fm, fn = 8 * pr, 8 * pc
        u = wo.mac_per_cycle_tile("INT8", "AUTO", L, pr, pc)
        cyc = L / u
    else:
        raise ValueError(design)
    blocks = math.ceil(M / fm) * math.ceil(N / fn)
    macs = M * N * L
    mpc = macs / (blocks * cyc)
    peak = 64 * pr * pc
    return mpc / peak, mpc * F_GHZ / (area * 1e-6)


def utilization_audit(rows):
    rng = np.random.default_rng(1)
    wa, budget = weight_aware_kseg(rng)
    hdr("2a. INT8 segment length (24-bit offset accumulator)")
    print(f"  worst case K_seg = {rot.k_seg_max('INT8')} (model); budget {budget:,} after the 184,960 Booth overshoot")
    for k, (p5, med) in wa.items():
        print(f"  weight-aware bound, {k:24s}: K_seg p5 {p5:,.0f} / median {med:,.0f}  -> "
              f"L=4096: {math.ceil(4096/p5)}-{math.ceil(4096/med)} seg, L=11008: {math.ceil(11008/p5)}-{math.ceil(11008/med)} seg")
    kseg_wa = 2048          # representative weight-aware value used below (between Gaussian and heavy-tail medians)

    hdr("2b. per-output-block utilisation vs L (INT8, skew charged per segment drain; design log ignored it)")
    print(f"  {'grid':5s} {'L':>6s} | {'ROT claim':>9s} {'ROT wc':>7s} {'ROT wa':>7s} | {'CNSB':>6s} {'WO':>6s} {'BOS':>6s}")
    for pr, pc in ((1, 1), (4, 4), (4, 8), (8, 4)):
        for L in (64, 128, 512, 1024, 2048, 4096, 11008):
            nseg = math.ceil(L / rot.k_seg_max("INT8"))
            claim = (8 * math.ceil(L / 8)) / (8 * math.ceil(L / 8) + nseg * 8 * pc)
            c_wc, _ = rot_cycles(L, pr, pc, 496)
            c_wa, _ = rot_cycles(L, pr, pc, kseg_wa)
            u_c = math.ceil(L / 8) / cnsb_cycles(L, pr, pc)
            u_wo = wo.mac_per_cycle_tile("INT8", "AUTO", L, pr, pc)
            u_b = L / bos_cycles(L, pr, pc)
            print(f"  {pr}x{pc:<3d} {L:6d} | {100*claim:8.1f}% {100*L/c_wc:6.1f}% {100*L/c_wa:6.1f}% | "
                  f"{100*u_c:5.1f}% {100*u_wo:5.1f}% {100*u_b:5.1f}%")

    # areas used for effective GMAC/s/mm2 (all-in where the design said 'not counted')
    A = {}
    for g in ((4, 4), (4, 8)):
        r = rows[g]
        A[("ROT", g)] = r["base"] + r["claimed"]
        A[("ROT_allin", g)] = r["base"] + r["corr"] + r["adders"] + r["psum_lo"]
    A[("CNSB", (4, 4))], A[("CNSB", (4, 8))] = 521892.14 + 9437.9, 1016043.42 + 11695.8
    A[("WO", (4, 4))] = 521892.14 + 2467.2 + 2546.4
    A[("WO", (4, 8))] = 1016043.42 + 4833.4 + 2546.4
    A[("SC", (4, 4))], A[("SC", (4, 8))] = 521892.14, 1016043.42
    A[("BOS", (4, 4))], A[("BOS", (4, 8))] = 16 * BOS8, 32 * BOS8
    hdr("2c. LLM layers (Llama-2-7B shapes: d 4096, 32 heads, head_dim 128 (64 variant), FFN 11008)")
    print("  util = effective MAC/cycle / peak (time AND footprint); eff = GMAC/s/mm2 on that grid's area")
    print("  areas: ROT claimed {:,.0f} / all-in {:,.0f} (4x4); CNSB all-in {:,.0f}; WO all-in {:,.0f}; BOS 16x {:,.0f}".format(
        A[("ROT", (4, 4))], A[("ROT_allin", (4, 4))], A[("CNSB", (4, 4))], A[("WO", (4, 4))], A[("BOS", (4, 4))]))
    layers = []
    for S in (512, 4096):
        layers += [(f"prefill S={S} QKV proj", S, 12288, 4096), (f"prefill S={S} FFN up", S, 11008, 4096),
                   (f"prefill S={S} FFN down", S, 4096, 11008),
                   (f"prefill S={S} QK^T hd128", S, S, 128), (f"prefill S={S} QK^T hd64", S, S, 64),
                   (f"prefill S={S} SV hd128", S, 128, S), (f"prefill S={S} SV hd64", S, 64, S)]
    layers += [("decode B=1 FFN up", 1, 11008, 4096), ("decode B=8 FFN up", 8, 11008, 4096),
               ("decode B=32 FFN up", 32, 11008, 4096), ("decode S=4096 QK^T (M=1)", 1, 4096, 128),
               ("decode S=4096 SV (M=1)", 1, 128, 4096)]
    for g in ((4, 4), (4, 8)):
        pr, pc = g
        print(f"\n  grid {pr}x{pc}:")
        print(f"  {'layer':30s} | {'ROT wc':>13s} {'ROT wa':>13s} {'ROT allin':>9s} | {'CNSB':>13s} | {'WO':>13s} | {'BOS':>13s} | {'SC':>6s}")
        for name, M, N, L in layers:
            u1, e1 = layer_eff(M, N, L, pr, pc, "ROT", A[("ROT", g)], 496)
            u2, e2 = layer_eff(M, N, L, pr, pc, "ROT", A[("ROT", g)], kseg_wa)
            _, e2b = layer_eff(M, N, L, pr, pc, "ROT", A[("ROT_allin", g)], 496)
            u3, e3 = layer_eff(M, N, L, pr, pc, "CNSB", A[("CNSB", g)])
            u4, e4 = layer_eff(M, N, L, pr, pc, "WO", A[("WO", g)])
            u5, e5 = layer_eff(M, N, L, pr, pc, "BOS", A[("BOS", g)])
            u6, _ = layer_eff(M, N, L, pr, pc, "SC", A[("SC", g)])
            print(f"  {name:30s} | {100*u1:5.1f}% {e1:6.0f} {100*u2:5.1f}% {e2:6.0f} {e2b:9.0f} | {100*u3:5.1f}% {e3:6.0f} | "
                  f"{100*u4:5.1f}% {e4:6.0f} | {100*u5:5.1f}% {e5:6.0f} | {100*u6:5.1f}%")
    hdr("2d. whole transformer layer, prefill (MAC-weighted: total MACs / total cycles), INT8")
    for S in (512, 2048, 4096):
        mix = [(S, 12288, 4096, 1), (S, 4096, 4096, 1), (S, 11008, 4096, 2), (S, 4096, 11008, 1),
               (S, S, 128, 32), (S, 128, S, 32)]
        for g in ((4, 4), (4, 8)):
            pr, pc = g
            out = []
            for label, design, area, k in (("ROT wc", "ROT", A[("ROT", g)], 496),
                                           ("ROT wa", "ROT", A[("ROT", g)], kseg_wa),
                                           ("ROT allin wc", "ROT", A[("ROT_allin", g)], 496),
                                           ("CNSB", "CNSB", A[("CNSB", g)], 0),
                                           ("WO", "WO", A[("WO", g)], 0),
                                           ("BOS", "BOS", A[("BOS", g)], 0)):
                macs = cyc = 0.0
                for M, N, L, rep in mix:
                    u, _ = layer_eff(M, N, L, pr, pc, design, area, k or 496)
                    m = M * N * L * rep
                    macs += m
                    cyc += m / (u * 64 * pr * pc)
                ueff = macs / cyc / (64 * pr * pc)
                out.append(f"{label} {100*ueff:.1f}% {ueff*64*pr*pc*F_GHZ/(area*1e-6):.0f}")
            att = sum(M * N * L * rep for M, N, L, rep in mix[4:]) / sum(M * N * L * rep for M, N, L, rep in mix)
            print(f"  S={S:4d} {pr}x{pc} (attention {100*att:.1f}% of MACs): " + " | ".join(out))
    return kseg_wa


# ----------------------------------------------------------- 3. bandwidth --
def bandwidth_audit(kseg_wa):
    hdr("3. operand / output bandwidth, 4x4 (32x32 output footprint), INT8")
    pr = pc = 4
    a_bits = pr * 64 * 8 / 8
    w_bits = pc * 64 * 8 / 8
    mpc = 1024
    print(f"  operand: {a_bits + w_bits:.0f} b/cycle = {(a_bits + w_bits)/mpc:.3f} b/MAC (claimed 512, 0.500): "
          f"A re-read N/32, W re-read M/32 (same as SC/BOS-32x32)")
    print("  CNSB 1536 b/cycle (1.5 b/MAC, 8x16 footprint); WO-ring 4608 b/cycle at the port (4.5 b/MAC, 8x re-stream)")
    for L in (512, 4096, 11008):
        for label, k in (("worst-case", 496), ("weight-aware", kseg_wa)):
            nseg = math.ceil(L / k)
            drained = nseg * 24 / L                       # 24-bit partials out per output
            rmw = ((nseg - 1) * 64 + 32) / L if nseg > 1 else 0.0   # read+write 32b per extra segment
            print(f"  L={L:5d} {label:12s}: {nseg:2d} segments -> drain {drained:.3f} b/MAC + psum RMW {rmw:.3f} "
                  f"b/MAC -> total {0.5 + drained + rmw:.3f} b/MAC (SC: {0.5 + 24/L:.3f})")
    print("  drain-cycle output rate (4x4): 32 values x 24 b = 768 b/cycle; with RMW 32 x (32r+32w) = 2,048 b/cycle")


def main():
    rows, tt, a_half, w_half = area_audit()
    kseg_wa = utilization_audit(rows)
    bandwidth_audit(kseg_wa)
    hdr("4. GEMV / batch-1 row occupancy")
    for pr, pc in ((4, 4), (4, 8)):
        print(f"  {pr}x{pc}: ROT rows/grid {8*pr} -> M=1 uses {100/(8*pr):.1f}% (design text: '1 of 8 rows per PE' = 12.5%); "
              f"CNSB {2*pr if pc <= pr else 4*pr} rows -> {100/(2*pr if pc <= pr else 4*pr):.1f}%")


if __name__ == "__main__":
    main()
