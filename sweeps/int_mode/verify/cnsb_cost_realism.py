#!/usr/bin/env python3
"""Adversarial cost / system-realism check of the CNSB (comparator-native
spatial Booth) INT mode, round-1 keys red_team_novel and spatial_fixed_weight.

Independent of the architects' models: nothing is imported from them.  The
preset constants are copied as data; the comparator formula is re-derived from
the RTL source text (designs/payn/pe_peripheral.sv, payn_array_signed_segmented_csa.sv).

Sections
  1. preset certification from RTL-derived masks (both preset sets)
  2. area ledger: composite-only vs all-in vs all-in + uncounted items
     (cell areas from sweeps/int_mode/cost_table.csv; synthesized numbers from
      sweeps/int_mode/verify/syn_runs/*/area.rpt when present)
  3. utilization vs reduction length L (1x1, 4x4, 4x8, 8x4) for CNSB and the
     comparison designs, same skew/drain accounting for all
  4. realistic LLM layers (LLaMA-2-7B shapes) with output-footprint quantization
  5. operand bandwidth, GEMM-level re-fetch, bandwidth-capped utilization
  6. energy proxy (measured SC T=16 point, per-cycle reload cadence)

Usage: python3 sweeps/int_mode/verify/cnsb_cost_realism.py
No EDA tools; reads repo files only.
"""
from __future__ import annotations

import csv
import math
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
VERIFY = Path(__file__).resolve().parent

# ----------------------------------------------------------------- cells --
CELL = {}
with open(REPO / "sweeps/int_mode/cost_table.csv") as fh:
    for row in csv.DictReader(fh):
        if row["kind"] == "cell" and row["area_um2"]:
            CELL[row["item"]] = float(row["area_um2"])


def cell(prefix):
    for k, v in CELL.items():
        if k.startswith(prefix):
            return v
    raise KeyError(prefix)


AND2 = cell("AND2_X1M")
OR2 = AND2
NAND2 = cell("NAND2_X1A")
XOR2 = cell("XOR2_X0P7M")
AO22 = cell("AO22_X1M")
AOI22 = cell("AOI22_X0P7M")
FA = cell("ADDF_X1M")
HA = cell("ADDH_X1M")
DFF2W = cell("DFFQA2W_X1M")         # per bit
MXT2 = cell("MXT2_X1M")

# Routed composite inputs (ground facts, doc/SC_area_efficiency.md formula)
UPE, PERIPH, SOBOL = 29255.548, 13031.256, 1678.348
A_1PE_ROUTED = 44017.974


def composite(pr, pc):
    if (pr, pc) == (1, 1):
        return A_1PE_ROUTED
    return pr * pc * UPE + (pr + pc) * PERIPH / 2 + SOBOL


GMACS_PER_TILE_MAC = 64 * 0.4        # one PE at 1 MAC/cycle/tile = 25.6 GMAC/s


# ------------------------------------------------- 1. preset certification --
def rtl_constants():
    src = (REPO / "designs/payn/pe_peripheral.sv").read_text()
    top = (REPO / "designs/payn/variants/signed_segmented_csa/"
           "payn_array_signed_segmented_csa.sv").read_text()
    km = re.search(r"SCRAMBLE_K_STRIDE\s*=\s*\(\(LEVELS\s*\*\s*(\d+)\s*/\s*(\d+)\)\s*\|\s*1\)", src)
    mm = re.search(r"SCRAMBLE_M_STRIDE\s*=\s*\(\(LEVELS\s*\*\s*(\d+)\s*/\s*(\d+)\)\s*\|\s*1\)", src)
    levels = 256
    sk = (levels * int(km[1]) // int(km[2])) | 1
    sm = (levels * int(mm[1]) // int(mm[2])) | 1
    assert "A_SCRAMBLE_SALT = 0" in top
    assert "W_SCRAMBLE_SALT = (1 << (WIDTH - 1))" in top
    # comparator: bit = binary_q > (random ^ MASK), strict
    assert re.search(r"a_binary_q\[.*\]\s*>\s*\n?\s*scrambled_random", src)
    return sk, sm, 0, 128


PRESETS = {  # copied as data from the two round-1 models
    "red_team r4rows": ([184, 112, 109, 173, 159, 27, 142, 93, 253, 44, 148, 40, 250, 207, 155, 139],
                        [243, 203, 204, 246, 229, 147, 152, 9, 146, 95, 190, 181, 96, 91, 75, 37],
                        "rows3"),
    "red_team r16rows": ([222, 50, 245, 231, 140, 40, 98, 162, 230, 210, 171, 241, 250, 189, 169, 229],
                         [139, 92, 120, 87, 27, 6, 224, 234, 96, 84, 79, 234, 201, 197, 115, 145],
                         "rows9"),
    "spatial A/W": ([183, 166, 106, 211, 179, 48, 65, 189, 197, 84, 120, 108, 10, 177, 221, 209],
                    [254, 16, 49, 107, 53, 212, 110, 133, 21, 35, 183, 70, 165, 180, 161, 32],
                    "rows3"),
}


def certify(row_r, col_r, kind, sk, sm, salt_a, salt_w):
    """Independent check: for every lane k there exist codes c_row[x], c_col[y]
    with popcount((c_row[x] > thrA) & (c_col[y] > thrW)) == x*y for all x, y.
    Codes are any value in the strict gap; we take gap upper ends."""
    K, M = 8, 16
    n_row, n_col = (3, 9) if kind == "rows3" else (9, 3)
    out = []
    for k in range(K):
        ta = [row_r[m] ^ ((k * sk + m * sm + salt_a) & 255) for m in range(M)]
        tw = [col_r[m] ^ ((k * sk + m * sm + salt_w) & 255) for m in range(M)]

        def codes(t, n):
            s = sorted(t)
            if max(s) == 255:
                return None
            step = 16 // (n - 1)
            c = [0]
            for x in range(1, n - 1):
                lo, hi = s[step * x - 1], s[step * x]
                if lo >= hi:
                    return None
                c.append(hi)               # lights exactly step*x positions
            c.append(255)
            return c

        cr, cc = codes(ta, n_row), codes(tw, n_col)
        if cr is None or cc is None:
            return False, k
        for x in range(n_row):
            for y in range(n_col):
                cnt = sum((cr[x] > ta[m]) and (cc[y] > tw[m]) for m in range(M))
                if cnt != x * y:
                    return False, k
        out.append((cr, cc))
    return True, out


# ---------------------------------------------------- 2. area ledger --
def synth_area(run):
    rpt = VERIFY / "syn_runs" / run / "area.rpt"
    if not rpt.exists():
        return None
    m = re.search(r"Total cell area:\s*([0-9.]+)", rpt.read_text())
    return float(m[1]) if m else None


def ledger():
    print("\n=== 2. Area ledger (um2) ===")
    # architects' hand counts, recomputed from LEF cell areas
    rt = dict(preset=2 * (128 * AND2 + OR2),
              r4=64 * (2 * XOR2 + AND2 + OR2 + NAND2 + AND2) + 576 * AO22,
              r16=64 * (4 * XOR2 + NAND2 + AND2 + 9.6) + 576 * AO22,
              comb=2 * (128 * FA + 32 * DFF2W) * 1.10)
    sp = dict(preset=256 * AND2 + 32 * OR2,
              r4=64 * (2 * XOR2 + OR2 + AOI22) + 16 * AND2 + 512 * AO22 + 64 * AO22,
              r16=64 * (5 * HA + 4 * XOR2) + 64 * 5.4 + 32 * AND2 + 512 * AO22 + 64 * AO22,
              comb=220 * FA + 200 * DFF2W + 100.0)
    for name, d in (("red_team (as claimed)", rt), ("spatial (as claimed)", sp)):
        print(f"  {name:24s} preset {d['preset']:7.1f}  r4-half {d['r4']:7.1f}  "
              f"r16-half {d['r16']:7.1f}  combiner/PE-row {d['comb']:7.1f}")
    # synthesized (this check), if available
    syn = {k: synth_area(k) for k in (
        "feed_r4_half", "feed_r16_half_hi", "feed_r16_half_lo", "combiner_row_1st",
        "combiner_row_2st", "sobol_pair_orig", "sobol_pair_preset")}
    have = all(v is not None for v in syn.values())
    if have:
        r16 = min(syn["feed_r16_half_hi"], syn["feed_r16_half_lo"])
        sy = dict(preset=syn["sobol_pair_preset"] - syn["sobol_pair_orig"],
                  r4=syn["feed_r4_half"], r16=r16,
                  comb=syn["combiner_row_2st"], comb1=syn["combiner_row_1st"])
        print(f"  {'synthesized (this check)':24s} preset {sy['preset']:7.1f}  r4-half {sy['r4']:7.1f}  "
              f"r16-half {sy['r16']:7.1f}  combiner/PE-row {sy['comb']:7.1f} "
              f"(1-stage {sy['comb1']:.1f})")
        print("    raw synth totals: " + ", ".join(f"{k}={v:.1f}" for k, v in syn.items()))
    else:
        sy = None
        print("  synthesized numbers: not available (run sweeps/int_mode/verify/run_cnsb_synth.sh)")

    # Skew delay lines (uncounted by both architects).  INT operands change every
    # cycle, so edge half r must see slice s at cycle s+r.  SC hides this behind
    # held registers with staggered load strobes; INT cannot.  Cheapest: delay
    # raw bytes before the recoders (A raw b/half, W raw b/half), multibit flops.
    def skew_bits(pr, pc, a_raw, w_raw):
        return a_raw * pr * (pr - 1) // 2 + w_raw * pc * (pc - 1) // 2

    grids = [("1x1", 1, 1, "r4rows"), ("4x4", 4, 4, "r4rows"),
             ("4x8", 4, 8, "r16rows"), ("8x4", 8, 4, "r4rows")]
    rows = {}
    print("\n  Grid totals.  r4rows: A side radix-4 (128 raw b/half), W side radix-16 "
          "(256 raw b/half); r16rows swaps them.")
    print(f"  {'grid':4s} {'composite':>10s} | {'inside(RT)':>10s} {'allin RT':>9s} {'allin SP':>9s} "
          f"{'allin syn':>9s} | {'skew bits':>9s} {'skew um2':>8s} | {'corrected':>9s} {'%':>6s} "
          f"| SC GMAC/s/mm2: base, RT-composite, corrected")
    for g, pr, pc, orient in grids:
        A = composite(pr, pc)
        if orient == "r4rows":
            n4, n16 = pr, pc
            a_raw, w_raw = 128, 256
        else:
            n4, n16 = pc, pr
            a_raw, w_raw = 256, 128
        allin_rt = rt["preset"] + n4 * rt["r4"] + n16 * rt["r16"] + pr * rt["comb"]
        allin_sp = sp["preset"] + n4 * sp["r4"] + n16 * sp["r16"] + pr * sp["comb"]
        allin_sy = (sy["preset"] + n4 * sy["r4"] + n16 * sy["r16"] + pr * sy["comb"]) if sy else float("nan")
        sb = skew_bits(pr, pc, a_raw, w_raw)
        su = sb * DFF2W
        corr = (allin_sy if sy else max(allin_rt, allin_sp)) + su
        base = pr * pc * GMACS_PER_TILE_MAC / (A * 1e-6)
        rows[g] = dict(A=A, allin_rt=allin_rt, allin_sp=allin_sp, allin_sy=allin_sy,
                       skew=su, corr=corr, corr_noskew=corr - su, pr=pr, pc=pc)
        print(f"  {g:4s} {A:10.0f} | {rt['preset']:10.1f} {allin_rt:9.0f} {allin_sp:9.0f} "
              f"{allin_sy:9.0f} | {sb:9d} {su:8.0f} | {corr:9.0f} {100 * corr / A:5.2f}% "
              f"| {base:6.1f} {base * A / (A + rt['preset']):6.1f} {base * A / (A + corr):6.1f}")
    return rows, rt, sp, sy


# ------------------------------------------- 3/4. utilization models --
def ceil(a, b):
    return -(-a // b)


def design_models(pr, pc, areas):
    """Return {name: (footprint fn, cycles-per-block fn, peak MAC/cycle/tile,
    all-in area um2, note)} for INT8 on a pr x pc grid.  Footprint is the
    output block (Mb, Nb) one grid block produces.  Same skew (pr+pc-2) and
    drain (8*pc, global, MAC-blocking) accounting for every PaYN design."""
    S = pr + pc - 2
    D = 8 * pc
    A0 = composite(pr, pc)
    m = {}
    m["SC T=128 (ref)"] = ((8 * pr, 8 * pc), lambda L: 8 * ceil(L, 8) + S + D, 1.0, A0, "")
    m["CNSB r4rows"] = ((2 * pr, 4 * pc), lambda L: ceil(L, 8) + S + D, 1.0,
                        A0 + areas["corr"], "")
    m["CNSB r16rows"] = ((4 * pr, 2 * pc), lambda L: ceil(L, 8) + S + D, 1.0,
                         A0 + areas["corr"], "")
    m["CNSB r4rows no-skew"] = ((2 * pr, 4 * pc), lambda L: ceil(L, 8) + S + D, 1.0,
                                A0 + areas["corr_noskew"], "banked SRAM")
    tri_r, tri_c = pr * (pr - 1) // 2, pc * (pc - 1) // 2

    def wo_cycles(L):
        if L <= 511:
            return 8 * ceil(L, 8) + 40 + D + S        # FH, 8x8 block per PE
        n = ceil(L, 8191)
        cyc, rem = 0, L
        for _ in range(n):
            ch = min(rem, 8191)
            rem -= ch
            cyc += 4 * ceil(ch, 8) + 24 + D + S       # HYS, 8x4 block per PE
        return cyc

    def wo_fp(L):
        return (8 * pr, 8 * pc) if L <= 511 else (8 * pr, 4 * pc)

    # WO-ring all-in as claimed (ring + preset + collector) PLUS the feeder it
    # needs but did not count (same recoders/port mux as CNSB + per-pass digit
    # select: spatial's sel_a/sel_w estimates).
    n4, n16 = pr, pc
    feed = n4 * 564.5 + n16 * 1204.0 + n4 * 64 * 3 * (2 * AOI22 + NAND2) + n16 * 64 * 5 * MXT2
    wo_claim = pr * pc * 147.882 + 101.136 + pr * 79.58 * 8 * (1 if pr > 0 else 0)
    m["WO-ring (claimed area)"] = (wo_fp, wo_cycles, 1.0, A0 + wo_claim, "")
    m["WO-ring (+feeder)"] = (wo_fp, wo_cycles, 1.0, A0 + wo_claim + feed, "")
    wo_skew = (512 * tri_r + 256 * tri_c) * DFF2W
    m["WO-ring (+feeder+skew)"] = (wo_fp, wo_cycles, 1.0, A0 + wo_claim + feed + wo_skew, "")
    # bit-plane ring HW: 1 x 8 outputs per PE, Bw=8 passes, 8-cycle ring laps
    bp_add = 2 * (pr + pc) / 2 * 401.8 * 1 + pr * 515.7 + pr * pc * 163.0
    m["bit-plane ring"] = ((pr, 8 * pc), lambda L: 8 * ceil(L, 128) + 56 + S + D, 2.0,
                           A0 + bp_add, "no corner-turn counted")
    bp_skew = 1024 * (tri_r + tri_c) * DFF2W
    m["bit-plane ring (+skew)"] = ((pr, 8 * pc), lambda L: 8 * ceil(L, 128) + 56 + S + D, 2.0,
                                   A0 + bp_add + bp_skew, "no corner-turn counted")
    # reduction-outer rotating: worst-case segments of 496, one drain each
    ro_add = 1024 * 19.52 * (pr * pc / 16) + pr * pc * 5.29 + pr * 1066.2 + pc * 1554.4 + 20
    m["reduction-outer"] = ((8 * pr, 8 * pc),
                            lambda L: 8 * ceil(L, 8) + ceil(L, 496) * D + S, 1.0, A0 + ro_add, "")
    return m


def bos_fleet(n_arrays):
    """n independent 8x8 BOS INT8 arrays (block 8x8, L + 14 skew + 8 drain)."""
    return ((8, 8), lambda L: L + 14 + 8, n_arrays * 15797.404, n_arrays * 64)


def layer_util(fp, cyc, peak_per_tile, tiles, M, L, N):
    Mb, Nb = fp(L) if callable(fp) else fp
    blocks = ceil(M, Mb) * ceil(N, Nb)
    cycles = blocks * cyc(L)
    macs = M * L * N
    return macs / (cycles * tiles * peak_per_tile), macs / (cycles * tiles)


LLAMA = dict(d=4096, dff=11008, hd=128, nh=32)


def layers(S, batch_decode=False):
    d, dff, hd, nh = LLAMA["d"], LLAMA["dff"], LLAMA["hd"], LLAMA["nh"]
    if batch_decode:
        Mt = S          # here S = batch
        return [("QKV proj (decode)", Mt, d, 3 * d, 1), ("O proj (decode)", Mt, d, d, 1),
                ("FFN gate+up (decode)", Mt, d, 2 * dff, 1), ("FFN down (decode)", Mt, dff, d, 1)]
    return [("QKV proj", S, d, 3 * d, 1), ("QK^T hd=128", S, hd, S, nh),
            ("QK^T hd=64", S, 64, S, nh), ("SV hd=128", S, S, hd, nh),
            ("O proj", S, d, d, 1), ("FFN gate+up", S, d, 2 * dff, 1), ("FFN down", S, dff, d, 1)]


def weighted_util(fp, cyc, peak, tiles, S):
    macs = cycles_tiles = 0.0
    for lname, M, L, N, reps in layers(S):
        if "hd=64" in lname:
            continue
        Mb, Nb = fp(L) if callable(fp) else fp
        macs += M * L * N * reps
        cycles_tiles += ceil(M, Mb) * ceil(N, Nb) * cyc(L) * reps * tiles
    return macs / cycles_tiles          # MAC/cycle/tile (actual)


def mixed_workload(rows):
    print("\n=== 4b. Mixed SC + INT8 workload (LLaMA-2-7B prefill S=2048 mix for both "
          "phases), 4x4 ===")
    g = rows["4x4"]
    pr, pc = g["pr"], g["pc"]
    tiles = 64 * pr * pc
    mods = design_models(pr, pc, g)
    u_sc = weighted_util(*mods["SC T=128 (ref)"][:3], tiles, 2048)
    u_int = weighted_util(*mods["CNSB r4rows"][:3], tiles, 2048)
    bos_fp, bos_cyc, _, _ = bos_fleet(1)
    u_bos = weighted_util(bos_fp, bos_cyc, 1.0, 64, 2048)
    A_g = composite(pr, pc) * 1e-6
    dA = g["corr"] * 1e-6
    A_b = 15797.404e-6
    T_full = 409.6           # GMAC/s at 1 MAC/cycle/tile
    print(f"  MAC-weighted utilization: SC {u_sc:.3f}, CNSB INT8 {u_int:.3f}, BOS 8x8 {u_bos:.3f}")
    print(f"  {'f_INT':>6s} {'CNSB INT mode':>14s} {'BOS seq (best n)':>17s} {'BOS concurrent':>15s}  GMAC/s/mm2")
    for f in (0.05, 0.10, 0.30):
        eff_a = 1.0 / (((1 - f) / (T_full * u_sc) + f / (T_full * u_int)) * (A_g + dA))
        best = (0, 0)
        for n10 in range(1, 4001):
            n = n10 / 10
            t = (1 - f) / (T_full * u_sc) + f / (n * 25.6 * u_bos)
            e = 1.0 / (t * (A_g + n * A_b))
            if e > best[0]:
                best = (e, n)
        n_c = f / (1 - f) * (T_full * u_sc) / (25.6 * u_bos)
        t_c = (1 - f) / (T_full * u_sc)
        eff_c = 1.0 / (t_c * (A_g + n_c * A_b))
        print(f"  {f:6.2f} {eff_a:14.1f} {best[0]:11.1f} (n={best[1]:4.1f}) {eff_c:9.1f} (n={n_c:4.1f})")


def main():
    sk, sm, sa, sw = rtl_constants()
    print("=== 1. Preset certification from RTL text ===")
    print(f"  RTL: SCRAMBLE_K_STRIDE={sk}, SCRAMBLE_M_STRIDE={sm}, salts A={sa} W={sw}; "
          "bit = binary_q > (r[m]^MASK(k,m)) (strict)")
    for name, (r, c, kind) in PRESETS.items():
        ok, info = certify(r, c, kind, sk, sm, sa, sw)
        print(f"  {name:18s}: {'PASS' if ok else 'FAIL at lane ' + str(info)} "
              f"(count == |x|*|y| for all lanes, x in 0..{2 if kind == 'rows3' else 8}, "
              f"y in 0..{8 if kind == 'rows3' else 2})")
    # Sobol reset state must not work (sanity: the preset is needed)
    def lane_shift(base, stride):
        return [(base ^ ((stride * m) & 255)) for m in range(16)]
    ok, _ = certify(lane_shift(0x17, 0x53), lane_shift(0x9D, 0x2B), "rows3", sk, sm, sa, sw)
    print(f"  Sobol reset state as preset: {'PASS (unexpected)' if ok else 'FAIL (expected: preset needed)'}")

    rows, rt, sp, sy = ledger()

    print("\n=== 3. INT8 MAC/cycle/tile vs L (perfect footprint fill; skew+drain per block) ===")
    Ls = [64, 128, 256, 512, 1024, 2048, 4096, 11008]
    print("  " + f"{'design':24s}{'grid':6s}" + "".join(f"{'L=' + str(x):>8s}" for x in Ls))
    for g in ("1x1", "4x4", "4x8", "8x4"):
        pr, pc = rows[g]["pr"], rows[g]["pc"]
        mods = design_models(pr, pc, rows[g])
        for name in ("SC T=128 (ref)", "CNSB r4rows", "WO-ring (claimed area)", "bit-plane ring",
                     "reduction-outer"):
            fp, cyc, peak, area, _ = mods[name]
            vals = []
            for L in Ls:
                Mb, Nb = fp(L) if callable(fp) else fp
                macs_per_block = Mb * Nb * L
                vals.append(macs_per_block / (cyc(L) * 64 * pr * pc))
            print(f"  {name:24s}{g:6s}" + "".join(f"{v:8.3f}" for v in vals))
    print("  BOS 8x8 (any fleet size)    " + "".join(f"{L / (L + 22):8.3f}" for L in Ls))

    print("\n=== 4. Effective INT8 GMAC/s/mm2 on LLaMA-2-7B layers (all-in area, "
          "footprint quantization) ===")
    for g in ("4x4", "4x8", "8x4", "1x1"):
        pr, pc = rows[g]["pr"], rows[g]["pc"]
        tiles = 64 * pr * pc
        mods = design_models(pr, pc, rows[g])
        names = ["SC T=128 (ref)", "CNSB r4rows", "CNSB r16rows", "CNSB r4rows no-skew",
                 "WO-ring (claimed area)", "WO-ring (+feeder+skew)", "bit-plane ring",
                 "bit-plane ring (+skew)", "reduction-outer"]
        print(f"\n  grid {g}: all-in areas um2: " + ", ".join(
            f"{n}={mods[n][3]:.0f}" for n in names))
        for S in (512, 2048, 4096):
            print(f"   prefill S={S}")
            hdr = f"    {'layer':22s}{'M':>6s}{'L':>6s}{'N':>6s}" + "".join(f"{n[:14]:>15s}" for n in names) + f"{'BOS fleet':>11s}"
            print(hdr)
            tot = {n: [0.0, 0.0] for n in names + ["BOS"]}
            for lname, M, L, N, reps in layers(S):
                vals = []
                for n in names:
                    fp, cyc, peak, area, _ = mods[n]
                    u, mac_per_tile = layer_util(fp, cyc, peak, tiles, M, L, N)
                    eff = mac_per_tile * pr * pc * 25.6 / (area * 1e-6)
                    vals.append(eff)
                    if "hd=64" not in lname:
                        tot[n][0] += M * L * N * reps
                        tot[n][1] += M * L * N * reps / eff
                fp, cyc, barea, bmac = bos_fleet(1)
                Mb, Nb = fp
                blocks = ceil(M, Mb) * ceil(N, Nb)
                u = M * L * N / (blocks * cyc(L) * 64)
                beff = u * 25.6 / (barea * 1e-6)
                if "hd=64" not in lname:
                    tot["BOS"][0] += M * L * N * reps
                    tot["BOS"][1] += M * L * N * reps / beff
                print(f"    {lname:22s}{M:6d}{L:6d}{N:6d}" + "".join(f"{v:15.1f}" for v in vals)
                      + f"{beff:11.1f}")
            print(f"    {'MAC-weighted (hd=128)':40s}" + "".join(
                f"{tot[n][0] / tot[n][1]:15.1f}" for n in names) + f"{tot['BOS'][0] / tot['BOS'][1]:11.1f}")
        # decode
        print("   decode (batch B), CNSB r4rows / r16rows / SC / BOS util:")
        for B in (1, 4, 8, 16):
            out = []
            for lname, M, L, N, reps in layers(B, batch_decode=True)[2:3]:
                for n in ("CNSB r4rows", "CNSB r16rows", "SC T=128 (ref)"):
                    fp, cyc, peak, area, _ = mods[n]
                    u, _ = layer_util(fp, cyc, peak, tiles, M, L, N)
                    out.append(f"{n.split()[0]}{'-' + n.split()[1] if 'CNSB' in n else ''}={u:.3f}")
                bu = M * L * N / (ceil(M, 8) * ceil(N, 8) * (L + 22) * 64)
                out.append(f"BOS={bu:.3f}")
            print(f"    B={B:2d} FFN gate+up: " + "  ".join(out))

    mixed_workload(rows)

    print("\n=== 5. Operand bandwidth and re-fetch ===")
    print("  peak b/cycle into grid while MACing; GEMM-level b/MAC = bits*(1/Mb + 1/Nb)")
    cases = [("SC T=128 4x4", 576, 9 * (1 / 32 + 1 / 32), 1024),
             ("CNSB INT8 4x4 r4rows", 4 * 128 + 4 * 256, 8 * (1 / 8 + 1 / 16), 1024),
             ("CNSB INT8 4x8 r16rows", 4 * 256 + 8 * 128, 8 * (1 / 16 + 1 / 16), 2048),
             ("CNSB INT8 8x4 r4rows", 8 * 128 + 4 * 256, 8 * (1 / 16 + 1 / 16), 2048),
             ("CNSB W4A8 4x4", 1536, None, 2048),
             ("BOS INT8, 16 x 8x8 independent", 16 * 128, 8 * (1 / 8 + 1 / 8), 1024),
             ("BOS INT8, one 32x32 mesh", 512, 8 * (1 / 32 + 1 / 32), 1024),
             ("WO-ring 4x4 (codes at port)", 4608, None, 1024),
             ("bit-plane ring 4x4", 8192, None, 1024)]
    for name, bpc, bpm, macs in cases:
        gbs = bpc * 0.4 / 8
        s = f"  {name:34s} {bpc:6d} b/cyc = {bpc / macs:6.3f} b/MAC at peak, {gbs:6.1f} GB/s"
        if bpm is not None:
            s += f";  GEMM re-fetch {bpm:.3f} b/MAC"
        print(s)
    print("  CNSB INT8 4x4 utilization cap if the feed is sized for SC:")
    for feed in (576, 1152):
        print(f"    {feed:5d} b/cycle -> {feed / 1536:.3f} MAC/cycle/tile cap")
    # DRAM-side re-fetch for FFN gate+up at S=2048 (no on-chip reuse beyond the block)
    M, L, N = 2048, 4096, 2 * 11008
    for name, Mb, Nb in (("SC 4x4 (32x32)", 32, 32), ("CNSB 4x4 (8x16)", 8, 16),
                         ("CNSB 4x8 r16 (16x16)", 16, 16), ("BOS 8x8 (8x8)", 8, 8)):
        a_t = M * L * 8 * ceil(N, Nb) / 8e9
        w_t = L * N * 8 * ceil(M, Mb) / 8e9
        print(f"    FFN gate+up S=2048, {name:22s}: A re-read {ceil(N, Nb):5d}x, W re-read "
              f"{ceil(M, Mb):4d}x, operand traffic {a_t + w_t:7.1f} GB per layer if the "
              f"buffer holds only one block's panels")

    print("\n=== 6. Energy proxy (unmeasured INT mode) ===")
    # SC T=16 reloads magnitudes/signs every cycle, the same cadence as INT mode
    p16, sob = 23.89762, 0.715
    print(f"  CSA T=16 routed GL/PT-PX: {p16:.3f} mW full (Sobol {sob} mW). INT mode freezes "
          f"Sobol: {(p16 - sob):.2f} mW / 64 INT8 MAC/cycle = "
          f"{(p16 - sob) * 2.5 / 64:.3f} pJ/MAC (drain-excluded proxy)")
    print("  BOS INT8 routed: 10.559 mW = 0.412 pJ/MAC (D->inf), 0.477 at D=64 (doc/results.md)")


if __name__ == "__main__":
    main()
