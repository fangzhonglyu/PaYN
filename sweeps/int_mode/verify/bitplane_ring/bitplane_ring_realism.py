#!/usr/bin/env python3
"""Cost and system-realism audit of the round-1 bit-plane INT mode
(design key bitplane_throughput, "BP-HW-ring").

Pure arithmetic, no EDA.  Inputs:
  * cell areas, routed block areas and the grid composite from
    sweeps/int_mode/cost_table.py (LEF footprints, routed CSA reports);
  * per-design block shapes / cycle formulas from design_round1.json, the
    bit-plane ones re-verified at 4x4 / 4x8 by check_model_grid.py;
  * BOS INT8 8x8 routed area 15,797.404 um2 (apr/build/TSMC22/BOS_ARRAY/20260728_143921),
    drain contract from designs/baselines/binary_os/binary_os_array.sv.
Writes bitplane_ring_realism.csv next to this file and prints every table.
Usage: python3 sweeps/int_mode/verify/bitplane_ring/bitplane_ring_realism.py
"""
import csv
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
F = 0.4  # GHz
# ------------------------------------------------------------------ cells --
OR2, AND2, AO21, AO22, BUFH, INV = 0.392, 0.392, 0.588, 0.686, 0.294, 0.196
FA, HA, DFF, DFF2W = 1.666, 0.980, 1.470, 1.372
# ------------------------------------------------------------ base areas ---
A1 = 44017.974           # routed single-PE array
UPE = 29255.548          # routed u_pe
PERIPH = 13031.256       # routed peripheral (both halves)
SOBOL = 844.760 + 833.588
BOS8 = 15797.404         # routed BOS INT8 8x8


def base(pr, pc):
    return A1 if (pr, pc) == (1, 1) else pr * pc * UPE + (pr + pc) * PERIPH / 2 + SOBOL


GRIDS = [(1, 1), (4, 4), (4, 8)]

# ======================================================== 1. area recount ==
# bit-plane, as claimed in design_round1.json
EDGE_OR = 1024 * OR2                     # raw-bit bypass, per edge half
EDGE_GATE = AND2                         # INT gate on magnitude load
EDGE_CLAIM = EDGE_OR + EDGE_GATE         # 401.8
RING_PE = 192 * AO22 + DFF + OR2 + 4 * BUFH + 96 * BUFH     # 163.0
COMB_ROW = (130 * FA + 10 * HA + 8 * INV) + 62 * DFF2W + 32 * FA + 31 * AND2 \
    + 40 * (FA + DFF2W + AND2)                               # 515.7
CTRL = 100.0                              # sequencer, once per grid (architect's estimate)
# correction: the 512 raw lines shared with a_binary_in carry magnitudes on every
# SC load cycle (every 8 clocks), so they must be gated by int_mode
# (check_model_grid.py section 3: SC corrupts without it).  OR2 -> AO21 on 512
# lines + int_mode fan-out buffering (~32 BUFH).
EDGE_SHARE_FIX = 512 * (AO21 - OR2) + 32 * BUFH                # 109.8 per edge half
TILE_SELF = 23 * (0.490 + 2 * 0.294 - AO22) + 2 * AND2 + OR2  # HW-self option, per tile
PE_SELF = DFF + OR2 + 64 * TILE_SELF


def bp_add(pr, pc, mech="ring", fix=True, allin=True):
    """Return (inside_composite, outside_composite) added area, um2."""
    edge = EDGE_CLAIM + (EDGE_SHARE_FIX if fix else 0.0)
    inside = (pr + pc) * edge
    if mech == "ring":
        inside += pr * pc * RING_PE
    elif mech == "self":
        inside += pr * pc * PE_SELF
    outside = pr * COMB_ROW + (CTRL if allin else 0.0)
    return inside, outside


# other designs' all-in additions (design_round1.json "area" fields; their
# arithmetic was not re-derived here -- other lenses own those).
OTHER_ADD = {   # name: {grid: (inside_composite, outside_composite)}
    "CNSB (Booth spatial, E2)": {(1, 1): (101.1, 2334.2), (4, 4): (101.1, 9336.8),
                                 (4, 8): (101.1, 11594.7)},
    "WO-ring (+collector)": {(1, 1): (249.0, 636.6), (4, 4): (2467.2, 2546.4),
                             (4, 8): (4833.4, 2546.4)},
    "Reduction-outer rot.": {(1, 1): (3895.0, 0.0), (4, 4): (30648.0, 0.0),
                             (4, 8): (57071.0, 0.0)},
}

# =========================================================== 2. schedules ==
# Each returns (Bm, Bn, cycles_per_block, data_cycles_per_block, port_bits_per_data_cycle,
#               A_replay) for INT8.  port bits = raw operand bits that must
# arrive at the grid edge per data cycle (memory side).


def nb128(L):
    return -(-L // 128)


def sched(design, L, pr, pc):
    S = pr + pc - 2
    D = 8 * pc
    if design == "BP HW-ring":
        dc = 8 * nb128(L)
        return pr, 8 * pc, dc + 56 + S + D, dc, 1024 * (pr + pc)
    if design == "BP HW-self":
        dc = 8 * nb128(L)
        return pr, 8 * pc, dc + 7 + S + D, dc, 1024 * (pr + pc)
    if design == "BP-S":
        dc = nb128(L)
        return pr, pc, dc + S + D, dc, 1024 * (pr + pc)
    if design == "BP HB-ring":           # INT8 legal only for L <= 511 (overflow bound)
        if L > 511:
            return None
        dc = 64 * nb128(L)
        return 8 * pr, 8 * pc, dc + 112 + S + D, dc, 1024 * (pr + pc)
    if design == "CNSB (Booth spatial, E2)":
        dc = -(-L // 8)
        if (pr, pc) == (4, 8):           # 'r16rows': 4 act rows x 2 weight cols per PE
            return 4 * pr, 2 * pc, dc + S + D, dc, 256 * pr + 128 * pc
        return 2 * pr, 4 * pc, dc + S + D, dc, 128 * pr + 256 * pc
    if design == "WO-ring (+collector)":
        C = -(-L // 8)
        if L <= 511:                     # FH
            return 8 * pr, 8 * pc, 8 * C + 40 + S + D, 8 * C, 576 * (pr + pc)
        nch = -(-L // 8191)              # HYS chunk limit; partials summed by collector
        Cc = -(-math.ceil(L / nch) // 8)
        return 8 * pr, 4 * pc, nch * (4 * Cc + 24 + S + D), nch * 4 * Cc, 576 * (pr + pc)
    if design == "Reduction-outer rot.":
        dc = 8 * -(-L // 8)
        seg = -(-L // 496)               # worst-case-safe segments, each pays drain + skew
        return 8 * pr, 8 * pc, dc + seg * (D + S) + 2, dc, 64 * (pr + pc)   # 64 x 8 b per half / 8 cyc
    if design == "SC T=128 (ref)":
        dc = 8 * -(-L // 8)
        return 8 * pr, 8 * pc, dc + S + D, dc, 72 * (pr + pc)       # 576/8 halves avg
    raise ValueError(design)


def bp_best(L, pr, pc):
    cands = []
    for d in ("BP HW-ring", "BP-S", "BP HB-ring"):
        s = sched(d, L, pr, pc)
        if s is not None:
            cands.append((d, s))
    return cands


def layer_cycles(design, M, N, L, pr, pc):
    s = sched(design, L, pr, pc)
    if s is None:
        return None
    Bm, Bn, cyc, dc, port = s
    nblk = -(-M // Bm) * -(-N // Bn)
    return nblk * cyc, nblk * dc, nblk, Bm, Bn, cyc, dc, port


def bos_cycles(M, N, L, n_arr, mesh=None):
    """BOS INT8.  n_arr independent 8x8 arrays (each block L + 14 skew + 8 drain),
    or one mesh (Bm x Bn) with skew Bm+Bn-2 and drain Bn."""
    if mesh is None:
        nblk = -(-M // 8) * -(-N // 8)
        return -(-nblk // n_arr) * (L + 22)
    Bm, Bn = mesh
    return -(-M // Bm) * -(-N // Bn) * (L + Bm + Bn - 2 + Bn)


# ---------------------------------------------------------- LLM shapes -----
# Llama-2-7B-like: d=4096, ffn=11008, 32 heads, head_dim 128.  head_dim 64
# variant for attention.  (M = rows of A = tokens, L = reduction, N = outputs)
def layers(S, phase, hd=128, d=4096, ffn=11008, heads=32, M_dec=1):
    M = S if phase == "prefill" else M_dec
    out = [
        ("QKV proj", M, 3 * d, d, 1),
        ("O proj", M, d, d, 1),
        ("FFN gate+up", M, 2 * ffn, d, 1),
        ("FFN down", M, d, ffn, 1),
        (f"QK^T (L=hd={hd})", M, S, hd, heads),
        (f"SV (L=S={S})", M, hd, S, heads),
    ]
    return out


DESIGNS = ["BP HW-ring", "BP best-mode", "BP HW-self", "BP-S", "CNSB (Booth spatial, E2)",
           "WO-ring (+collector)", "Reduction-outer rot.", "SC T=128 (ref)"]


def design_area(design, pr, pc, allin=True):
    b = base(pr, pc)
    if design.startswith("BP"):
        mech = "self" if design == "BP HW-self" else ("none" if design == "BP-S" else "ring")
        i, o = bp_add(pr, pc, mech)
        return b + i + (o if allin else 0.0)
    if design in OTHER_ADD:
        i, o = OTHER_ADD[design][(pr, pc)]
        return b + i + (o if allin else 0.0)
    return b


def run_layer(design, M, N, L, pr, pc):
    """(cycles, data cycles, port_bits, Bm, Bn, mode)"""
    if design == "BP best-mode":
        best = None
        for d in ("BP HW-ring", "BP-S", "BP HB-ring"):
            r = layer_cycles(d, M, N, L, pr, pc)
            if r is not None and (best is None or r[0] < best[0][0]):
                best = (r, d)
        r, d = best
        return r[0], r[1], r[7], r[3], r[4], d
    r = layer_cycles(design, M, N, L, pr, pc)
    return r[0], r[1], r[7], r[3], r[4], design


def main():
    rows = []
    out = rows.append
    # ------------------------------------------------------------ area -----
    print("== 1. Area recount (cell-count, LEF footprints)")
    print(f"  edge half claimed  {EDGE_CLAIM:8.2f} = 1024 OR2 {EDGE_OR:.2f} + gate {EDGE_GATE:.2f}  (arith OK)")
    print(f"  edge half fix      +{EDGE_SHARE_FIX:7.2f} = 512 x (AO21-OR2) + 32 BUFH: raw lines shared with "
          f"a_binary_in need an int_mode gate (SC loads every 8 clk)")
    print(f"  ring per PE        {RING_PE:8.2f} = 192 AO22 {192*AO22:.2f} + DFF + OR2 + 100 BUFH  (arith OK)")
    print(f"  combiner per row   {COMB_ROW:8.2f}  (arith OK; tree size plausible: 8x24-bit shifted "
          f"operands, ~192 bits -> 2x31 => ~130 FA)")
    print(f"  HW-self per tile   {TILE_SELF:8.2f}; per PE {PE_SELF:.1f}")
    print(f"  controller         {CTRL:8.2f} per grid (outside composite)")
    print()
    hdr = f"  {'grid':5s} {'base':>12s} | {'claimed':>16s} | {'inside comp.':>16s} {'outside':>9s} {'all-in corr.':>16s} | SC GMAC/s/mm2 base -> all-in"
    print(hdr)
    claimed = {(1, 1): 1482, (4, 4): 7885, (4, 8): 12099}
    for pr, pc in GRIDS:
        b = base(pr, pc)
        i, o = bp_add(pr, pc, "ring")
        tot = i + o
        sc0 = 64 * pr * pc * F / (b * 1e-6)
        sc1 = 64 * pr * pc * F / ((b + tot) * 1e-6)
        sci = 64 * pr * pc * F / ((b + i) * 1e-6)
        print(f"  {pr}x{pc:<3d} {b:12,.0f} | {claimed[(pr,pc)]:7,d} {100*claimed[(pr,pc)]/b:6.2f}% | "
              f"{i:7,.0f} {100*i/b:6.2f}% {o:9,.0f} {tot:7,.0f} {100*tot/b:6.2f}% | "
              f"{sc0:6.1f} -> {sc1:6.1f} (inside-only {sci:6.1f})")
        out(dict(section="area", item=f"BP HW-ring {pr}x{pc}", value=round(tot, 1),
                 note=f"inside {i:.1f} outside {o:.1f}; {100*tot/b:.2f}% of {b:.0f}; claimed {claimed[(pr,pc)]}"))
    print("  memory system (not in any composite): see section 5")

    # ------------------------------------------------- 2. L sweep ----------
    print("\n== 2. Effective INT8 MAC/cycle/tile vs reduction length (one large GEMM, M,N >> block)")
    Ls = [64, 128, 256, 512, 1024, 2048, 4096, 11008]
    for pr, pc in GRIDS:
        print(f"  -- {pr}x{pc}")
        for dsg in DESIGNS:
            vals = []
            for L in Ls:
                M = N = 4096
                cyc, dc, port, Bm, Bn, mode = run_layer(dsg, M, N, L, pr, pc)
                vals.append(M * N * L / (cyc * 64 * pr * pc))
            print(f"    {dsg:26s} " + " ".join(f"L{L}:{v:5.2f}" for L, v in zip(Ls, vals)))
            for L, v in zip(Ls, vals):
                out(dict(section="L_sweep", item=f"{dsg} {pr}x{pc} L={L}", value=round(v, 4),
                         note="MAC/cycle/tile, M=N=4096"))
        # BOS reference (per-array utilisation)
        nar = pr * pc
        vals = [4096 * 4096 * L / (bos_cycles(4096, 4096, L, nar) * 64 * nar) for L in Ls]
        print(f"    {'BOS INT8 x'+str(nar)+' (8x8 each)':26s} " + " ".join(f"L{L}:{v:5.2f}" for L, v in zip(Ls, vals))
              + "   (per-PE-equivalent: 1 MAC/cycle per BOS PE)")

    # BP cycle anatomy at 4x4
    print("\n  BP HW-ring 4x4 block anatomy (cycles): data / ring laps / skew / drain -> data fraction")
    for L in Ls:
        dc = 8 * nb128(L)
        tot = dc + 56 + 6 + 32
        pad = (nb128(L) * 128 - L) / (nb128(L) * 128)
        print(f"    L={L:5d}: {dc:4d} / 56 / 6 / 32 = {tot:4d}; data {dc/tot:5.1%}; "
              f"kk-block padding waste {pad:5.1%}")

    # ---------------------------------------------- 3. LLM layers ----------
    print("\n== 3. Realistic LLM layers (Llama-2-7B-like d=4096, ffn=11008, 32 heads), INT8")
    print("   GMAC/s/mm2 use all-in area excluding the memory system; util = MAC/cycle/tile")
    cases = []
    for S in (512, 2048, 4096):
        cases.append((f"prefill S={S}", layers(S, "prefill")))
    cases.append(("prefill S=2048 hd=64", layers(2048, "prefill", hd=64)))
    cases.append(("decode ctx=2048 B=1", layers(2048, "decode", M_dec=1)))
    cases.append(("decode ctx=2048 B=16", layers(2048, "decode", M_dec=16)))
    agg = {}
    for pr, pc in ((4, 4), (4, 8), (1, 1)):
        ntile = 64 * pr * pc
        print(f"\n  ===== grid {pr}x{pc} =====")
        for cname, lys in cases:
            print(f"  -- {cname}")
            head = f"    {'layer':22s} {'M':>5s} {'N':>6s} {'L':>6s} |" + "".join(f" {d[:14]:>14s}" for d in DESIGNS) + f" {'BOS x'+str(pr*pc):>10s}"
            print(head)
            tot_mac = 0
            tot_cyc = {d: 0 for d in DESIGNS}
            tot_cyc["BOS"] = 0
            for (lname, M, N, L, rep) in lys:
                mac = M * N * L * rep
                tot_mac += mac
                cells = []
                for d in DESIGNS:
                    cyc, dc, port, Bm, Bn, mode = run_layer(d, M, N, L, pr, pc)
                    tot_cyc[d] += cyc * rep
                    u = M * N * L / (cyc * ntile)
                    tag = ""
                    if d == "BP best-mode":
                        tag = {"BP HW-ring": "r", "BP-S": "s", "BP HB-ring": "h"}[mode]
                    cells.append(f"{u:13.3f}{tag or ' '}")
                    out(dict(section="llm", item=f"{pr}x{pc} {cname} {lname} {d}", value=round(u, 4),
                             note=f"MAC/cycle/tile; mode {mode}; blocks {Bm}x{Bn}"))
                bc = bos_cycles(M, N, L, pr * pc) * rep
                tot_cyc["BOS"] += bc
                ub = M * N * L * rep / (bc * 64 * pr * pc)
                print(f"    {lname:22s} {M:5d} {N:6d} {L:6d} |" + "".join(f" {c:>14s}" for c in cells) + f" {ub:10.3f}")
            # aggregate
            line = f"    {'LAYER TOTAL util':22s} {'':5s} {'':6s} {'':6s} |"
            line2 = f"    {'LAYER GMAC/s/mm2':22s} {'':5s} {'':6s} {'':6s} |"
            for d in DESIGNS:
                u = tot_mac / (tot_cyc[d] * ntile)
                g = tot_mac / tot_cyc[d] * F / (design_area(d, pr, pc) * 1e-6)
                line += f" {u:14.3f}"
                line2 += f" {g:14.1f}"
                agg[(pr, pc, cname, d)] = (u, g)
                out(dict(section="llm_total", item=f"{pr}x{pc} {cname} {d}", value=round(g, 1),
                         note=f"GMAC/s/mm2 all-in excl. memory; util {u:.4f}"))
            ub = tot_mac / (tot_cyc["BOS"] * 64 * pr * pc)
            gb = tot_mac / tot_cyc["BOS"] * F / (pr * pc * BOS8 * 1e-6)
            line += f" {ub:10.3f}"
            line2 += f" {gb:10.1f}"
            agg[(pr, pc, cname, "BOS")] = (ub, gb)
            print(line)
            print(line2)

    # ----------------------------------------------- 4. bandwidth ----------
    print("\n== 4. Operand bandwidth into the grid (INT8)")
    for pr, pc in ((1, 1), (4, 4), (4, 8)):
        print(f"  -- {pr}x{pc}")
        for d in ("BP HW-ring", "BP-S", "CNSB (Booth spatial, E2)", "WO-ring (+collector)",
                  "Reduction-outer rot.", "SC T=128 (ref)"):
            s = sched(d, 4096, pr, pc)
            Bm, Bn, cyc, dc, port = s
            peak_mac = {"BP HW-ring": 2, "BP-S": 2}.get(d, 1) * 64 * pr * pc
            print(f"    {d:26s} port {port:6d} b/data-cycle; {port/peak_mac:5.2f} b/MAC at peak; "
                  f"block {Bm}x{Bn}; A re-read N/{Bn}, W re-read M/{Bm}")
        nar = pr * pc
        print(f"    {'BOS x'+str(nar)+' independent 8x8':26s} port {128*nar:6d} b/cycle; 2.00 b/MAC; block 8x8 per array")
    # traffic for a real layer, 4x4
    print("\n  GB->grid traffic per layer, 4x4 (Gbit; bits/MAC; avg b/cycle over the layer)")
    for (lname, M, N, L) in (("FFN down S=2048", 2048, 4096, 11008), ("QKV S=2048", 2048, 12288, 4096),
                             ("QK^T S=2048 hd128", 2048, 2048, 128), ("SV S=2048 hd128", 2048, 128, 2048)):
        mac = M * N * L
        print(f"    {lname}:")
        for d in ("BP HW-ring", "CNSB (Booth spatial, E2)", "WO-ring (+collector)", "SC T=128 (ref)"):
            cyc, dc, port, Bm, Bn, mode = run_layer(d, M, N, L, 4, 4)
            traffic = dc * port
            extra = ""
            if d == "BP HW-ring":
                # with a K-byte A replay buffer per PE row, A crosses once instead of 8x
                a_part = dc * 1024 * 4
                t2 = traffic - a_part + a_part / 8
                extra = f"; with A replay buffer {t2/mac:5.2f} b/MAC"
            print(f"      {d:26s} {traffic/1e9:8.2f} Gbit  {traffic/mac:5.2f} b/MAC  "
                  f"avg {traffic/cyc:7.0f} b/cyc{extra}")
            out(dict(section="traffic", item=f"4x4 {lname} {d}", value=round(traffic / mac, 3),
                     note=f"bits/MAC; avg {traffic/cyc:.0f} b/cyc"))

    print("\n  Throughput if the edge feed is capped (4x4, L=4096 FFN-like GEMM, data cycles stretch):")
    for cap in (576, 1536, 4608, 8192):
        line = f"    cap {cap:5d} b/cyc:"
        for d in ("BP HW-ring", "CNSB (Booth spatial, E2)", "WO-ring (+collector)"):
            Bm, Bn, cyc, dc, port = sched(d, 4096, 4, 4)
            stretch = max(1.0, port / cap)
            cyc2 = cyc - dc + dc * stretch
            u = Bm * Bn * 4096 / (cyc2 * 1024)
            g = u * 1024 * F / (design_area(d, 4, 4) * 1e-6)
            line += f"  {d[:12]} {u:4.2f} ({g:6.1f})"
            out(dict(section="bw_cap", item=f"4x4 L4096 cap{cap} {d}", value=round(g, 1),
                     note=f"util {u:.3f}"))
        print(line)

    # --------------------------------------------- 5. memory system --------
    print("\n== 5. Memory-system items outside every composite (bit-plane specific)")
    for pr, pc in ((4, 4), (4, 8)):
        for L in (4096, 11008):
            bits = pr * 8 * L
            print(f"  {pr}x{pc} A replay buffer (L={L}): {bits:,} bits = {bits/8192:.1f} KiB, "
                  f"{pr} banks x 1024-bit read port; as DFFQA2W flops {bits*DFF2W:,.0f} um2 "
                  f"({100*bits*DFF2W/base(pr,pc):.1f}% of grid) -- upper bound, SRAM needs a compiler number")
        print(f"  {pr}x{pc} independent 1024-bit streams: {pr+pc} (A {pr} + W {pc}); "
              f"{1024*(pr+pc)} b/cyc = {1024*(pr+pc)*F/8:.1f} GB/s at 400 MHz")
    print("  W must be stored bit-plane-major (offline OK); HB additionally needs plane-major A (runtime corner turn).")

    # ----------------------------------------------- 6. summary vs claims ---
    print("\n== 6. Claimed vs recomputed headline (4x4 INT8, all-in excl. memory)")
    A44 = design_area("BP HW-ring", 4, 4)
    for L, cl in ((1024, 626), (4096, 1131), (16384, 1416)):
        Bm, Bn, cyc, dc, port = sched("BP HW-ring", L, 4, 4)
        u = Bm * Bn * L / (cyc * 1024)
        print(f"  L={L:5d}: util {u:.3f}; {u*1024*F/(A44*1e-6):7.1f} GMAC/s/mm2 (claimed {cl})")
    with (HERE / "bitplane_ring_realism.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["section", "item", "value", "note"])
        w.writeheader()
        w.writerows(rows)
    print(f"\nwrote {HERE / 'bitplane_ring_realism.csv'}")


if __name__ == "__main__":
    main()


# ====================================================== addenda (run after main) ==
def addenda():
    print("\n== 7. Addenda")
    # 7a. 8x4 orientation (drain along the 4-PE side) vs 4x8, prefill S=2048 INT8 aggregate
    print("  7a. 8x4 vs 4x8 orientation, Llama-2-7B prefill S=2048, INT8 (util; GMAC/s/mm2 all-in excl. memory)")
    lys = layers(2048, "prefill")
    for pr, pc in ((4, 8), (8, 4)):
        for d in ("BP HW-ring", "BP best-mode", "CNSB (Booth spatial, E2)"):
            tot_mac = tot_cyc = 0
            for (lname, M, N, L, rep) in lys:
                if d == "CNSB (Booth spatial, E2)" and (pr, pc) == (8, 4):
                    # r4rows on 8x4: 2 act rows x 4 weight cols per PE, drain 8*P_C
                    dc = -(-L // 8)
                    Bm, Bn, cyc = 2 * pr, 4 * pc, dc + pr + pc - 2 + 8 * pc
                    c = -(-M // Bm) * -(-N // Bn) * cyc
                else:
                    c = run_layer(d, M, N, L, pr, pc)[0]
                tot_mac += M * N * L * rep
                tot_cyc += c * rep
            if d.startswith("BP"):
                i, o = bp_add(pr, pc, "ring")
                A = base(pr, pc) + i + o
            else:
                A = base(pr, pc) + 101.1 + (8 * 1204.0 + 4 * 564.5 + 8 * 565.7 if (pr, pc) == (8, 4)
                                            else 11594.7)
            u = tot_mac / (tot_cyc * 64 * pr * pc)
            print(f"    {pr}x{pc} {d:26s} util {u:5.3f}  {tot_mac/tot_cyc*F/(A*1e-6):7.1f}  (add {A-base(pr,pc):,.0f} um2)")
    # 7b. W4A8 (weight-only INT4 LLM), prefill S=2048, 4x4
    print("  7b. W4A8, Llama-2-7B prefill S=2048, 4x4 (util = MAC/cycle/tile; GMAC/s/mm2 all-in excl. memory)")
    i, o = bp_add(4, 4, "ring")
    Abp = base(4, 4) + i + o
    Acn = base(4, 4) + 101.1 + 9336.8

    def bp_w4(L, pr=4, pc=4):
        nb = nb128(L)
        hw = (pr, 8 * pc, 4 * nb + 24 + pr + pc - 2 + 8 * pc)
        hb = (8 * pr, 8 * pc, 32 * nb + 80 + pr + pc - 2 + 8 * pc) if L <= 8191 else None
        return hw, hb

    tot = {"BP HW-ring": 0, "BP best (HW/HB)": 0, "CNSB": 0, "BOS INT6 x16": 0}
    tot_mac = 0
    for (lname, M, N, L, rep) in lys:
        tot_mac += M * N * L * rep
        hw, hb = bp_w4(L)
        c_hw = -(-M // hw[0]) * -(-N // hw[1]) * hw[2]
        c_hb = -(-M // hb[0]) * -(-N // hb[1]) * hb[2] if hb else c_hw
        tot["BP HW-ring"] += c_hw * rep
        tot["BP best (HW/HB)"] += min(c_hw, c_hb) * rep
        dc = -(-L // 8)
        tot["CNSB"] += -(-M // 8) * -(-N // 32) * (dc + 6 + 32) * rep
        tot["BOS INT6 x16"] += bos_cycles(M, N, L, 16) * rep
    for k, c in tot.items():
        A = {"BP HW-ring": Abp, "BP best (HW/HB)": Abp, "CNSB": Acn, "BOS INT6 x16": 16 * 12403.664}[k]
        print(f"    {k:18s} util {tot_mac/(c*1024):5.3f}  {tot_mac/c*F/(A*1e-6):7.1f}")
    print("    (BP HB for W4A8 needs plane-major A = runtime corner turn; BOS INT6 used as W4A8 proxy)")


if __name__ == "__main__":
    addenda()
