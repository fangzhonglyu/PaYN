#!/usr/bin/env python3
"""Independent adversarial check of the CNSB / spatial-Booth INT identity.

Written from the RTL, not from the architects' models (nothing is imported
from sweeps/int_mode/*.py).  The only things taken from the round-1 designs
are the claimed constants (Sobol presets, the A code list C1) and the claimed
recoding rules, because those ARE the claims under test.

RTL facts used (re-derived here from the source text, see rtl_constants()):
  designs/payn/pe_peripheral.sv
    LEVELS = 1 << WIDTH = 256
    SCRAMBLE_K_STRIDE = ((LEVELS*79/128) | 1)     (SV integer division)
    SCRAMBLE_M_STRIDE = ((LEVELS*49/128) | 1)
    MASK(depth, lane) = (depth*K_STRIDE + lane*M_STRIDE + SALT) & (LEVELS-1)
    bit = binary_q[(row*K+depth)] > (random_values[lane] ^ MASK)   (unsigned, strict)
  designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
    A_SCRAMBLE_SALT = 0, W_SCRAMBLE_SALT = 1 << (WIDTH-1) = 128
  inner_tile_signed_segmented_csa.sv
    products = a_bits[k] & w_bits[k]; PaynPopcount16Csa 11-FA network;
    heap rows {s3,s2,s1,s0a}^n and s0b^n, -16*countones(n) row.

Checks
  A. RTL constants and the CSA sign identity over all 2^16 patterns x n.
  B. For each claimed preset set (spatial PRESET_A/PRESET_W, red-team r4rows,
     red-team r16rows), per lane k, both banks: thresholds, valid code
     intervals, then popcount(a_bits & w_bits) through the real comparator
     formula and my own gate-level counter + sign XOR + -16N row equals
     |da|*|dw| with the right sign, for every |da|, |dw| and sign pair.
     Also every code inside the valid intervals (robustness), and the stated
     C1 list of the spatial design.
  C. Value level, my own recoders written from the stated bit formulas:
     all 65,536 INT8xINT8 pairs, INT8xINT4 (W4A8), INT4xINT4 with nibble
     packing and the b(-1) gating, through comparator + lane + digit weights.
  D. Edge cases outside the stated contract: unsigned 8-bit activations
     (UINT8 128..255), sign-magnitude magnitudes > 128.
  E. Native Sobol states: does any reachable state of the unchanged
     generators satisfy the identity (claim: none; preset required)?
  F. Accumulator / combiner range limits (OWIDTH=24, LOW_W=9 window).

Usage: python3 sweeps/int_mode/verify/cnsb_identity_check.py
Exit code 0 only if every check that is expected to pass passes; the
expected-to-fail edge cases (D) are reported, not asserted as passes.
"""
from __future__ import annotations

import itertools
import os
import re
import sys

import numpy as np

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
K, M, WIDTH = 8, 16, 8

FAIL = []


def ok(cond, msg):
    if not cond:
        FAIL.append(msg)
        print("  FAIL:", msg)
    return cond


# ------------------------------------------------------------------ A ----
def rtl_constants():
    periph = open(os.path.join(REPO, "designs/payn/pe_peripheral.sv")).read()
    top = open(os.path.join(
        REPO, "designs/payn/variants/signed_segmented_csa/"
              "payn_array_signed_segmented_csa.sv")).read()
    assert "SCRAMBLE_K_STRIDE = ((LEVELS * 79 / 128) | 1)" in periph
    assert "SCRAMBLE_M_STRIDE = ((LEVELS * 49 / 128) | 1)" in periph
    assert re.search(r"\(depth\*SCRAMBLE_K_STRIDE \+ lane\*SCRAMBLE_M_STRIDE \+\s*"
                     r"A_SCRAMBLE_SALT\) & \(LEVELS - 1\)", periph)
    assert re.search(r"a_binary_q\[\(row\*K \+ depth\)\*WIDTH \+: WIDTH\] >\s*"
                     r"scrambled_random", periph)
    assert "parameter int A_SCRAMBLE_SALT = 0" in top
    assert "parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1))" in top
    assert "parameter logic SCRAMBLE_ENABLE = 1'b1" in top
    levels = 1 << WIDTH
    sk = (levels * 79 // 128) | 1
    sm = (levels * 49 // 128) | 1
    return sk, sm, 0, 1 << (WIDTH - 1)


SK, SM, SALT_A, SALT_W = rtl_constants()


def mask(k, m, salt):
    return (k * SK + m * SM + salt) & 0xFF


def fa(a, b, c):
    return a ^ b ^ c, (a & b) | (b & c) | (a & c)


def csa16(bits):
    """PaynPopcount16Csa, transcribed from inner_tile_signed_segmented_csa.sv."""
    fs, fc = [0] * 11, [0] * 11
    for i in range(5):
        fs[i], fc[i] = fa(bits[3 * i], bits[3 * i + 1], bits[3 * i + 2])
    fs[5], fc[5] = fa(fs[0], fs[1], fs[2])
    fs[6], fc[6] = fa(fs[3], fs[4], bits[15])
    fs[7], fc[7] = fa(fc[0], fc[1], fc[2])
    fs[8], fc[8] = fa(fc[3], fc[4], fc[5])
    fs[9], fc[9] = fa(fs[7], fs[8], fc[6])
    fs[10], fc[10] = fa(fc[7], fc[8], fc[9])
    return fs[5], fs[6], fs[9], fs[10], fc[10]          # s0a s0b s1 s2 s3


def lane_value(word, n):
    """Heap contribution of one lane: 4-bit row + 1-bit row - 16*n (n = sign)."""
    bits = [(word >> i) & 1 for i in range(16)]
    s0a, s0b, s1, s2, s3 = csa16(bits)
    row4 = ((s3 << 3) | (s2 << 2) | (s1 << 1) | s0a) ^ (0xF if n else 0)
    row1 = s0b ^ n
    return row4 + row1 - 16 * n


def part_a():
    print(f"A. RTL constants: K_STRIDE={SK} M_STRIDE={SM} salts A={SALT_A} W={SALT_W}")
    ok((SK, SM) == (159, 99), "strides differ from the 159/99 the designs assume")
    x = np.arange(1 << 16, dtype=np.int64)
    b = [(x >> i) & 1 for i in range(16)]
    s0a, s0b, s1, s2, s3 = csa16(b)
    cnt = s0a + s0b + 2 * s1 + 4 * s2 + 8 * s3
    pc = np.zeros_like(x)
    for i in range(16):
        pc += b[i]
    ok(np.array_equal(cnt, pc), "11-FA network is not a popcount")
    for n in (0, 1):
        row4 = ((s3 << 3) | (s2 << 2) | (s1 << 1) | s0a) ^ (0xF * n)
        v = row4 + (s0b ^ n) - 16 * n
        ok(np.array_equal(v, pc * (1 - 2 * n)), f"CSA sign identity broken for n={n}")
    print("   11-FA counter == popcount and n ? -count : count over all 65,536 "
          "patterns, n in {0,1}: OK")


# ------------------------------------------------------------------ B ----
PRESET_SETS = {
    # sweeps/int_mode/model_spatial_fixed_weight.py (PRESET_A, PRESET_W):
    # rows (A bank, salt 0) radix-4, columns (W bank, salt 128) radix-16
    "spatial": dict(row=[183, 166, 106, 211, 179, 48, 65, 189, 197, 84, 120, 108,
                         10, 177, 221, 209],
                    col=[254, 16, 49, 107, 53, 212, 110, 133, 21, 35, 183, 70,
                         165, 180, 161, 32],
                    row_levels=3, col_levels=9),
    # sweeps/int_mode/model_red_team_novel.py PRESETS
    "red_r4rows": dict(row=[184, 112, 109, 173, 159, 27, 142, 93, 253, 44, 148,
                            40, 250, 207, 155, 139],
                       col=[243, 203, 204, 246, 229, 147, 152, 9, 146, 95, 190,
                            181, 96, 91, 75, 37],
                       row_levels=3, col_levels=9),
    "red_r16rows": dict(row=[222, 50, 245, 231, 140, 40, 98, 162, 230, 210, 171,
                             241, 250, 189, 169, 229],
                        col=[139, 92, 120, 87, 27, 6, 224, 234, 96, 84, 79, 234,
                             201, 197, 115, 145],
                        row_levels=9, col_levels=3),
}
# design_round1.json, spatial_fixed_weight mapping text
C1_CLAIMED = [173, 115, 122, 124, 119, 130, 113, 129]


def thresholds(preset, salt):
    return [[preset[m] ^ mask(k, m, salt) for m in range(M)] for k in range(K)]


def word(code, thr_k):
    return sum(1 << m for m in range(M) if code > thr_k[m])


def code_intervals(thr_k, levels):
    """Valid code sets per level: code c lights #{m: thr < c}; level x of a
    3-level side must light 8x positions, level y of a 9-level side 2y."""
    step = 16 // (levels - 1)
    s = sorted(thr_k)
    out = []
    for lvl in range(levels):
        want = step * lvl
        out.append([c for c in range(256) if sum(t < c for t in thr_k) == want])
    return out, s


def part_b():
    print("B. Per-lane comparator identity, every preset set, every lane, both banks")
    tables = {}
    for name, ps in PRESET_SETS.items():
        tr, tc = thresholds(ps["row"], SALT_A), thresholds(ps["col"], SALT_W)
        row_codes, col_codes = [], []
        n_checked = 0
        worst_margin = 999
        for k in range(K):
            ok(max(tr[k]) <= 254 and max(tc[k]) <= 254,
               f"{name} k={k}: a threshold is 255 (code 255 cannot light all 16)")
            ri, sr = code_intervals(tr[k], ps["row_levels"])
            ci, sc = code_intervals(tc[k], ps["col_levels"])
            ok(all(len(v) > 0 for v in ri), f"{name} k={k}: some row level unreachable")
            ok(all(len(v) > 0 for v in ci), f"{name} k={k}: some col level unreachable")
            if not (all(ri) and all(ci)):
                continue
            row_codes.append(ri)
            col_codes.append(ci)
            worst_margin = min(worst_margin, *(len(v) for v in ri[1:-1] + ci[1:-1]))
            # every code combination inside the valid sets (robustness) through
            # the real comparator; sign pairs through my gate-level lane on the
            # interval-end codes (the sign path does not depend on the code)
            wr = [word(c, tr[k]) for c in range(256)]
            wc = [word(c, tc[k]) for c in range(256)]
            for x, cx_set in enumerate(ri):
                for y, cy_set in enumerate(ci):
                    want = x * y
                    for cx in cx_set:
                        for cy in cy_set:
                            got = bin(wr[cx] & wc[cy]).count("1")
                            n_checked += 1
                            if got != want:
                                ok(False, f"{name} k={k} |{x}|x|{y}| codes {cx},{cy}: "
                                          f"popcount {got} != {want}")
                    for cx in (cx_set[0], cx_set[-1]):
                        for cy in (cy_set[0], cy_set[-1]):
                            prod = wr[cx] & wc[cy]
                            for sa in (0, 1):
                                for sw in (0, 1):
                                    v = lane_value(prod, sa ^ sw)
                                    exp = -want if (sa ^ sw) else want
                                    if v != exp:
                                        ok(False, f"{name} k={k} sign {sa}{sw}: {v} != {exp}")
        tables[name] = (tr, tc, row_codes, col_codes)
        print(f"   {name:12s}: identity holds for all 8 lanes, all |d| pairs, all sign "
              f"pairs and every code in the valid intervals ({n_checked:,} code "
              f"pairs); narrowest valid code interval = {worst_margin} codes")
    # spatial C1 list
    tr, tc, rc, cc = tables["spatial"]
    for k in range(K):
        ok(C1_CLAIMED[k] in rc[k][1], f"claimed C1[{k}]={C1_CLAIMED[k]} not a valid "
                                      f"|da|=1 code (valid {rc[k][1][0]}..{rc[k][1][-1]})")
    print("   spatial: stated C1 = {173,115,122,124,119,130,113,129} each lies in its "
          "lane's valid |da|=1 interval: " +
          ("OK" if all(C1_CLAIMED[k] in rc[k][1] for k in range(K)) else "NO"))
    return tables


# ------------------------------------------------------------------ C ----
def bit(x, i):
    return (x >> i) & 1 if i >= 0 else 0


def r4_digits_from_byte(byte, int4_pack=False):
    """Radix-4 Booth on 8 raw bits; gate view x1=b2^b1, x0=b1^b0, nz, two, sign=b2.
    int4_pack: byte = {a_hi, a_lo}, digit 2 gets b(-1)=0."""
    out = []
    for p in range(4):
        b2, b1 = bit(byte, 2 * p + 1), bit(byte, 2 * p)
        b0 = bit(byte, 2 * p - 1)
        if int4_pack and p == 2:
            b0 = 0
        x1, x0 = b2 ^ b1, b1 ^ b0
        nz, two = x1 | x0, x1 & (1 - x0)
        mag = 2 if two else (1 if nz else 0)
        out.append((mag, b2))
    return out


def r16_digits_from_byte(byte, w4_pack=False):
    out = []
    for q in range(2):
        b3, b2, b1, b0 = (bit(byte, 4 * q + t) for t in (3, 2, 1, 0))
        bm1 = bit(byte, 4 * q - 1)
        if w4_pack and q == 1:
            bm1 = 0
        u = 4 * b2 + 2 * b1 + b0 + bm1
        mag = 8 - u if b3 else u
        out.append((mag, b3))
    return out


def a_code_spatial(k, mag):
    """Spatial design wiring: code bit = C1[k] bit ? nz : two."""
    nz, two = int(mag >= 1), int(mag == 2)
    c = 0
    for bb in range(8):
        c |= (nz if (C1_CLAIMED[k] >> bb) & 1 else two) << bb
    return c


def part_c(tables):
    print("C. Value level with my recoders + comparator + lane + digit weights")
    tr, tc, rc, cc = tables["spatial"]
    # W code: pick the TOP of each valid interval (architects chose bottom / other)
    wcode = [[cc[k][y][-1] for y in range(9)] for k in range(K)]
    lane_lut = {}
    for k in range(K):
        for ma in range(3):
            wa = word(a_code_spatial(k, ma), tr[k])
            for mw in range(9):
                ww = word(wcode[k][mw], tc[k])
                for n in (0, 1):
                    lane_lut[(k, ma, mw, n)] = lane_value(wa & ww, n)

    def mac(abyte, wbyte, k, int4_pack=False, nib=0, w4_pack=False):
        da = r4_digits_from_byte(abyte, int4_pack)
        dw = r16_digits_from_byte(wbyte, w4_pack)
        ps = (2 * nib, 2 * nib + 1) if int4_pack else range(4)
        qs = (0,) if w4_pack else range(2)
        tot = 0
        for p in ps:
            for q in qs:
                (ma, sa), (mw, sw) = da[p], dw[q]
                tot += lane_lut[(k, ma, mw, sa ^ sw)] << (2 * (p - (2 * nib if int4_pack else 0)) + 4 * q)
        return tot

    bad = 0
    for a in range(-128, 128):
        for w in range(-128, 128):
            k = (a * 7 + w * 3) & 7        # spread over lanes
            if mac(a & 0xFF, w & 0xFF, k) != a * w:
                bad += 1
    ok(bad == 0, f"INT8xINT8: {bad} mismatching pairs")
    print(f"   INT8 x INT8: 65,536 pairs, {bad} mismatches (lanes spread, W codes at "
          f"interval top)")
    # every lane for the extremes
    for k in range(K):
        for a, w in itertools.product((-128, -127, -1, 0, 1, 127), repeat=2):
            ok(mac(a & 0xFF, w & 0xFF, k) == a * w, f"k={k} {a}x{w}")
    print("   extremes {-128,-127,-1,0,1,127}^2 on every lane: OK")
    bad = 0
    for a in range(-128, 128):
        for w_lo in range(-8, 8):
            for w_hi in range(-8, 8):
                wbyte = ((w_hi & 0xF) << 4) | (w_lo & 0xF)
                k = (a + w_lo + w_hi) & 7
                # q=0 column carries w_lo, q=1 column w_hi (digit = weight)
                da = r4_digits_from_byte(a & 0xFF)
                dw = r16_digits_from_byte(wbyte, w4_pack=True)
                for q, wv in ((0, w_lo), (1, w_hi)):
                    tot = sum(lane_lut[(k, da[p][0], dw[q][0], da[p][1] ^ dw[q][1])] << (2 * p)
                              for p in range(4))
                    bad += tot != a * wv
    ok(bad == 0, f"W4A8: {bad} mismatches")
    print(f"   W4A8 (packed nibble pairs, q=1 b(-1) gated): 65,536 x 2 products, {bad} "
          f"mismatches")
    bad = 0
    for a_lo in range(-8, 8):
        for a_hi in range(-8, 8):
            abyte = ((a_hi & 0xF) << 4) | (a_lo & 0xF)
            da = r4_digits_from_byte(abyte, int4_pack=True)
            for w_lo in range(-8, 8):
                for w_hi in range(-8, 8):
                    wbyte = ((w_hi & 0xF) << 4) | (w_lo & 0xF)
                    dw = r16_digits_from_byte(wbyte, w4_pack=True)
                    k = (a_lo + 3 * w_hi) & 7
                    for nib, av in ((0, a_lo), (1, a_hi)):
                        for q, wv in ((0, w_lo), (1, w_hi)):
                            tot = sum(lane_lut[(k, da[p][0], dw[q][0], da[p][1] ^ dw[q][1])]
                                      << (2 * (p - 2 * nib)) for p in (2 * nib, 2 * nib + 1))
                            bad += tot != av * wv
    ok(bad == 0, f"INT4xINT4: {bad} mismatches")
    print(f"   INT4 x INT4 (both operands nibble-packed, digit-2 b(-1) gated): 65,536 "
          f"x 4 products, {bad} mismatches")
    # gating omitted: show it is load-bearing
    bad = 0
    for a_lo in range(-8, 8):
        for a_hi in range(-8, 8):
            abyte = ((a_hi & 0xF) << 4) | (a_lo & 0xF)
            da = r4_digits_from_byte(abyte, int4_pack=False)
            tot = sum(lane_lut[(0, da[p][0], 1, da[p][1])] << (2 * (p - 2)) for p in (2, 3))
            bad += tot != a_hi
    print(f"   (mutation) INT4 digit-2 b(-1) gate removed: {bad}/256 high-nibble "
          f"activations wrong -> the gate is load-bearing")
    return lane_lut


# ------------------------------------------------------------------ D ----
def part_d(lane_lut):
    print("D. Inputs outside the stated two's-complement contract")
    bad_u8 = []
    for a in range(256):
        da = r4_digits_from_byte(a)
        val = sum((-1 if s else 1) * mg * 4 ** p for p, (mg, s) in enumerate(da))
        if val != a:
            bad_u8.append(a)
    print(f"   UINT8 activation fed as a raw byte: {len(bad_u8)}/256 values wrong "
          f"(all of 128..255 decode as a-256); UINT8 needs a 5th radix-4 digit or a "
          f"zero-point shift (a-128) plus a 128*sum(w) column correction")
    # red-team sign-magnitude path: digits of mag's byte, flip by s^mag[7]
    bad_sm = []
    for s in (0, 1):
        for mag in range(256):
            da = r4_digits_from_byte(mag)
            flip = s ^ (mag >> 7)
            val = sum((-1 if (sg ^ flip) else 1) * mg * 4 ** p
                      for p, (mg, sg) in enumerate(da))
            want = -mag if s else mag
            if val != want:
                bad_sm.append((s, mag))
    mags = sorted({m for _, m in bad_sm})
    print(f"   red-team sign-magnitude recode: correct for mag 0..128, wrong for "
          f"{len(bad_sm)} (sign,mag) pairs, mag range {mags[0]}..{mags[-1]} "
          f"(PaYN SC magnitudes span 0..255)")
    return bad_u8, bad_sm


# ------------------------------------------------------------------ E ----
def sobol_trace(direction_set, shift_base, shift_stride, steps):
    """Reachable random_values of the unchanged sobol_bank (FULL_PERIOD_WRAP=0)."""
    if direction_set == 0:
        dv = [1 << (WIDTH - 1 - i) for i in range(WIDTH)]
    else:
        dv = [0x80, 0x40, 0x20, 0x10, 0x48, 0x04, 0x52, 0xFF]
    vals = [shift_base ^ ((shift_stride * m) & 0xFF) for m in range(M)]
    count = 0
    out = []
    for _ in range(steps):
        out.append(list(vals))
        sel = 0
        for i in range(WIDTH):
            if not (count >> i) & 1:
                sel = dv[i]
                break
        vals = [v ^ sel for v in vals]
        count = (count + 1) & 0xFF
    return out


def identity_ok(row_preset, col_preset, row_levels, col_levels):
    tr, tc = thresholds(row_preset, SALT_A), thresholds(col_preset, SALT_W)
    for k in range(K):
        ri, _ = code_intervals(tr[k], row_levels)
        ci, _ = code_intervals(tc[k], col_levels)
        if not (all(ri) and all(ci)):
            return False
        for x in range(row_levels):
            wa = word(ri[x][0], tr[k])
            for y in range(col_levels):
                if bin(wa & word(ci[y][0], tc[k])).count("1") != x * y:
                    return False
    return True


def part_e():
    print("E. Native (un-preset) Sobol states")
    a_tr = sobol_trace(0, 0x17, 0x53, 256)
    w_tr = sobol_trace(1, 0x9D, 0x2B, 256)
    hits = 0
    for t in range(256):
        for lv in ((3, 9), (9, 3)):
            hits += identity_ok(a_tr[t], w_tr[t], *lv)
    ok(hits == 0, "a native Sobol state satisfies the identity (preset unnecessary?)")
    print(f"   {hits} of 256 lock-step native states satisfy the identity in either "
          f"orientation -> the preset hardware is required (claim confirmed)")


# ------------------------------------------------------------------ F ----
def part_f():
    print("F. Range limits")
    LOW_W, OW = 9, 24
    lo, hi = -K * M, (1 << LOW_W) - 1 + K * M
    ok(lo >= -(1 << (LOW_W + 1)) and hi < (1 << (LOW_W + 1)), "low_sum window")
    print(f"   per-cycle |d| <= K*16 = {K * M}; low_sum in [{lo}, {hi}] inside the RTL "
          f"window [-{K * M}, {(1 << (LOW_W + 1)) - 1}] and signed 11-bit: OK")
    Lmax = ((1 << (OW - 1)) - 1) // 16
    print(f"   tile |acc| <= 16*L -> OWIDTH=24 exact for L <= {Lmax:,} "
          f"(+16*L = 2^23 overflows at L = {Lmax + 1:,}); only (-128)x(-128) or "
          f"(+2 digit)x(+8 digit) streams reach the bound")
    # worst-case reachable per-tile value: max over values of |da_p*dw_q| = 16
    worst = 0
    for a in range(-128, 128):
        da = r4_digits_from_byte(a & 0xFF)
        for w in range(-128, 128):
            dw = r16_digits_from_byte(w & 0xFF)
            worst = max(worst, max(m1 * m2 for m1, _ in da for m2, _ in dw))
    ok(worst == 16, "digit product bound")
    print(f"   max |da*dw| over all INT8 pairs = {worst}")


def main():
    part_a()
    tables = part_b()
    lut = part_c(tables)
    part_d(lut)
    part_e()
    part_f()
    print()
    if FAIL:
        print(f"{len(FAIL)} FAILURES")
        sys.exit(1)
    print("ALL EXPECTED-PASS CHECKS PASSED (D lists out-of-contract inputs that fail)")


if __name__ == "__main__":
    main()
