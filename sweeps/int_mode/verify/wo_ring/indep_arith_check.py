#!/usr/bin/env python3
"""Independent arithmetic check of the WO-ring (weight_outer_horner) INT mode.

Written from the RTL and the design text only; it imports nothing from the
architect's model.  Checks:

  1. comparator identity: with the claimed PRESET_A/PRESET_W forced on the
     shared random-value buses and the RTL's compile-time scramble masks
     (constants parsed from the RTL source), the claimed per-(side,k) codes give
     popcount(a_bits & w_bits) = |d_a|*|d_w| for every lane k, every
     |d_a| in 0..2, |d_w| in 0..8, and |a_bits| = 8|d_a|, |w_bits| = 2|d_w|;
  2. tile lane arithmetic: the RTL's PaynPopcount16Csa wiring, the per-lane
     sign XOR and the -16*N row give d_a*d_w for every signed pair, including
     zero digits carrying either sign; heap SUM_W=11 wrap and the single
     carry/borrow invariant hold for every acc_low in [0, 511];
  3. Booth recoding identities for INT8 / W4A8 / INT4;
  4. OW24 chunk limits re-derived per schedule (FH, HYS, W4A8, INT4), with the
     x4-wiring input bound |V| <= 2^21 checked separately from the register
     bound;
  5. exploratory: can a reachable Sobol state (shared rng_en, same count on
     both banks) serve as the preset, so that no forcing logic is needed?

Usage: python3 sweeps/int_mode/verify/wo_ring/indep_arith_check.py
"""
import itertools
import re
import sys
from pathlib import Path

# The RTL is read from a snapshot of the committed (routed) sources, taken with
# `git show HEAD:<path>`, so concurrent working-tree edits cannot leak in.
SNAP = Path(__file__).resolve().parent / "rtl_snapshot" / "payn"
PERIPH = SNAP / "pe_peripheral.sv"
ARRAY = SNAP / "variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv"
TILE = SNAP / "variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv"
SOBOL = SNAP / "sobol.sv"

K, M, WIDTH = 8, 16, 8
LOW_W, OWIDTH = 9, 24
SUM_W = LOW_W + 2
LEVELS = 1 << WIDTH
OMAX, OMIN = (1 << (OWIDTH - 1)) - 1, -(1 << (OWIDTH - 1))

FAILS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
        print("   FAIL:", msg)
    return cond


# ------------------------------------------------ constants from the RTL ----
src = PERIPH.read_text()
mk = re.search(r"SCRAMBLE_K_STRIDE\s*=\s*\(\(LEVELS\s*\*\s*(\d+)\s*/\s*(\d+)\)\s*\|\s*1\)", src)
mm = re.search(r"SCRAMBLE_M_STRIDE\s*=\s*\(\(LEVELS\s*\*\s*(\d+)\s*/\s*(\d+)\)\s*\|\s*1\)", src)
SK = (LEVELS * int(mk.group(1)) // int(mk.group(2))) | 1
SM = (LEVELS * int(mm.group(1)) // int(mm.group(2))) | 1
asrc = ARRAY.read_text()
salt_a = re.search(r"parameter int A_SCRAMBLE_SALT\s*=\s*(\d+)", asrc)
salt_w = re.search(r"parameter int W_SCRAMBLE_SALT\s*=\s*\(1 << \(WIDTH - 1\)\)", asrc)
SALT_A = int(salt_a.group(1))
assert salt_w is not None
SALT_W = 1 << (WIDTH - 1)
# The comparator is "binary_q > (random ^ MASK)", unsigned WIDTH bits.
assert re.search(r"a_binary_q\[\(row\*K \+ depth\)\*WIDTH \+: WIDTH\] >\s*scrambled_random", src)
assert re.search(r"w_binary_q\[\(col\*K \+ depth\)\*WIDTH \+: WIDTH\] >\s*scrambled_random", src)
print(f"RTL constants: K_STRIDE={SK} M_STRIDE={SM} A_SALT={SALT_A} W_SALT={SALT_W}")


def mask(k, m, salt):
    return (k * SK + m * SM + salt) & (LEVELS - 1)


# ---------------------------------------------------- claims under test ----
PRESET_A = [70, 33, 70, 10, 131, 227, 62, 107, 131, 35, 223, 203, 45, 0, 158, 133]
PRESET_W = [86, 214, 211, 157, 137, 29, 123, 218, 23, 200, 76, 227, 24, 69, 155, 223]
CLAIM_CODE_A = {0: [0, 73, 245], 1: [0, 111, 234], 2: [0, 143, 214], 3: [0, 124, 250],
                4: [0, 132, 255], 5: [0, 96, 234], 6: [0, 75, 253], 7: [0, 137, 248]}
CLAIM_CODE_W = {0: [0, 35, 53, 61, 115, 144, 150, 195, 240],
                1: [0, 15, 20, 35, 55, 83, 100, 178, 220],
                2: [0, 85, 108, 123, 170, 180, 196, 233, 248],
                3: [0, 17, 26, 34, 93, 99, 126, 213, 246],
                4: [0, 4, 23, 71, 138, 171, 185, 223, 254],
                5: [0, 41, 64, 139, 152, 165, 179, 206, 232],
                6: [0, 53, 64, 76, 85, 126, 199, 217, 255],
                7: [0, 81, 102, 144, 160, 214, 231, 237, 252]}


def bits_of(code, preset, k, salt):
    return [1 if code > (preset[m] ^ mask(k, m, salt)) else 0 for m in range(M)]


# =========================================================== 1. comparator ==
print("\n== 1. comparator identity (claimed preset + claimed codes, real masks)")
margins = []
for k in range(K):
    for x in range(3):
        ab = bits_of(CLAIM_CODE_A[k][x], PRESET_A, k, SALT_A)
        check(sum(ab) == 8 * x, f"k={k}: |a_bits| for |d_a|={x} is {sum(ab)}")
        for y in range(9):
            wb = bits_of(CLAIM_CODE_W[k][y], PRESET_W, k, SALT_W)
            check(sum(wb) == 2 * y, f"k={k}: |w_bits| for |d_w|={y} is {sum(wb)}")
            cnt = sum(a & w for a, w in zip(ab, wb))
            check(cnt == x * y, f"k={k}: popcount {cnt} != {x}*{y}")
    # code margins: how far each code can move before the bit pattern changes
    ta = sorted(PRESET_A[m] ^ mask(k, m, SALT_A) for m in range(M))
    tw = sorted(PRESET_W[m] ^ mask(k, m, SALT_W) for m in range(M))
    margins.append((k, ta[8] - ta[7], tw))
print("   all 8 lanes x 3 x 9 magnitude pairs: popcount = |d_a||d_w|;"
      " |a_bits| = 8|d_a|, |w_bits| = 2|d_w|" if not FAILS else "   FAILURES above")
print("   A 8/8 split gap per lane (thr[8]-thr[7]):", [g for _, g, _ in margins])

# =========================================================== 2. tile lane ===
print("\n== 2. tile lane arithmetic (RTL CSA counter + XOR + -16N)")
tsrc = TILE.read_text()
tsrc = tsrc[tsrc.index("module PaynPopcount16Csa"):]
tsrc = tsrc[:tsrc.index("endmodule")]
# Parse the FA wiring of PaynPopcount16Csa straight from the RTL.
fa_first = re.search(r"\.a\(bits_in\[3\*i\]\), \.b\(bits_in\[3\*i\+1\]\), \.ci\(bits_in\[3\*i\+2\]\)", tsrc)
assert fa_first
fa_rest = re.findall(r"PaynPopcountFA u_fa(\d+) \(\.a\(([^)]+)\), \.b\(([^)]+)\), \.ci\(([^)]+)\), "
                     r"\.s\(fs\[(\d+)\]\), \.co\(fc\[(\d+)\]\)\);", tsrc)
outs = dict(re.findall(r"assign (s0a|s0b|s1|s2|s3) = (f[sc]\[\d+\]);", tsrc))
assert len(fa_rest) == 6 and len(outs) == 5, (fa_rest, outs)


def csa16(b):
    sig = {}
    for i in range(5):
        x, y, z = b[3 * i], b[3 * i + 1], b[3 * i + 2]
        sig[f"fs[{i}]"], sig[f"fc[{i}]"] = x ^ y ^ z, (x & y) | (x & z) | (y & z)

    def val(name):
        name = name.strip()
        mb = re.fullmatch(r"bits_in\[(\d+)\]", name)
        return b[int(mb.group(1))] if mb else sig[name]
    for _, a, bb, ci, s, co in fa_rest:
        x, y, z = val(a), val(bb), val(ci)
        sig[f"fs[{s}]"], sig[f"fc[{co}]"] = x ^ y ^ z, (x & y) | (x & z) | (y & z)
    return {k_: sig[v] for k_, v in outs.items()}


# The counter must be an exact popcount for all 2^16 inputs.
bad = 0
for v in range(1 << 16):
    b = [(v >> i) & 1 for i in range(16)]
    o = csa16(b)
    if o["s0a"] + o["s0b"] + 2 * o["s1"] + 4 * o["s2"] + 8 * o["s3"] != sum(b):
        bad += 1
check(bad == 0, f"PaynPopcount16Csa not an exact popcount on {bad} inputs")
print("   PaynPopcount16Csa (parsed from RTL) = popcount on all 65,536 inputs")


def lane_value(k, da, dw, sa=None, sw=None):
    """Signed contribution of lane k as the tile heap sees it."""
    sa = (1 if da < 0 else 0) if sa is None else sa
    sw = (1 if dw < 0 else 0) if sw is None else sw
    ab = bits_of(CLAIM_CODE_A[k][abs(da)], PRESET_A, k, SALT_A)
    wb = bits_of(CLAIM_CODE_W[k][abs(dw)], PRESET_W, k, SALT_W)
    o = csa16([a & w for a, w in zip(ab, wb)])
    n = sa ^ sw
    row4 = 8 * (o["s3"] ^ n) + 4 * (o["s2"] ^ n) + 2 * (o["s1"] ^ n) + (o["s0a"] ^ n)
    row1 = o["s0b"] ^ n
    return row4 + row1 - 16 * n, n


nbad = 0
for k in range(K):
    for da in range(-2, 3):
        for dw in range(-8, 9):
            v, _ = lane_value(k, da, dw)
            nbad += v != da * dw
            if da == 0 or dw == 0:          # zero digit with any sign pattern
                for sa, sw in itertools.product((0, 1), repeat=2):
                    v2, _ = lane_value(k, da, dw, sa, sw)
                    nbad += v2 != 0
check(nbad == 0, f"{nbad} lane values wrong")
print("   8 lanes x 85 signed pairs exact; zero digits give 0 for all 4 sign patterns")

# heap: lanes + (-16N mod 2^11) + acc_low, summed mod 2^11, read signed.
# The extremes are reached by all-lanes-equal patterns; sweep acc_low fully.
lane_vals = sorted({da * dw for da in range(-2, 3) for dw in range(-8, 9)})
dmin, dmax = K * min(lane_vals), K * max(lane_vals)
lo, hi = 0 + dmin, (1 << LOW_W) - 1 + dmax
check(dmin == -128 and dmax == 128, f"per-cycle tile delta range [{dmin},{dmax}]")
check(-(1 << (SUM_W - 1)) <= lo and hi <= (1 << (SUM_W - 1)) - 1, "SUM_W wrap possible")
check(lo >= -(1 << LOW_W) and hi < (1 << (LOW_W + 1)), "more than one carry/borrow possible")
print(f"   per-cycle tile delta in [{dmin},{dmax}] -> low_sum in [{lo},{hi}]: "
      f"fits SUM_W=11, at most one borrow (low_sum<0) or one carry (bit 9)")

# =========================================================== 3. Booth =======
print("\n== 3. Booth recoding")


def booth(v, n, r):
    """Radix-2^r Booth digits of n-bit two's complement v (LSB digit first)."""
    u = v & ((1 << n) - 1)
    b = lambda i: 0 if i < 0 else (u >> min(i, n - 1)) & 1
    nd = -(-n // r)
    out = []
    for d in range(nd):
        s = b(r * d - 1) - (1 << (r - 1)) * b(r * d + r - 1)
        s += sum((1 << t) * b(r * d + t) for t in range(r - 1))
        out.append(s)
    return out


for name, na, nw in (("INT8", 8, 8), ("W4A8", 8, 4), ("INT4", 4, 4)):
    ar = range(-(1 << (na - 1)), 1 << (na - 1))
    wr = range(-(1 << (nw - 1)), 1 << (nw - 1))
    da = {a: booth(a, na, 2) for a in ar}
    dw = {w: booth(w, nw, 4) for w in wr}
    ok = all(sum(d * 4 ** p for p, d in enumerate(da[a])) == a for a in ar)
    ok &= all(sum(d * 16 ** q for q, d in enumerate(dw[w])) == w for w in wr)
    ok &= all(abs(d) <= 2 for a in ar for d in da[a])
    ok &= all(abs(d) <= 8 for w in wr for d in dw[w])
    ok &= all(sum(x * y << (2 * p + 4 * q) for p, x in enumerate(da[a])
                  for q, y in enumerate(dw[w])) == a * w for a in ar for w in wr)
    check(ok, f"{name} Booth identity")
    print(f"   {name}: {len(da[0])} A digits in [-2,2], {len(dw[0])} W digits in [-8,8]; "
          f"a*w = sum 2^(2p+4q) d_a d_w for all {len(ar) * len(wr)} pairs: {'OK' if ok else 'FAIL'}")
# boundary cases called out
for v in (-128, -127, -126, 127, 126, -1, 64, -64):
    print(f"     a={v:5d}: radix-4 {booth(v, 8, 2)}  radix-16 {booth(v, 8, 4)}")
for v in (-8, 7, -1):
    print(f"     w4={v:3d}: radix-16 {booth(v, 4, 4)}  a4 radix-4 {booth(v, 4, 2)}")

# =========================================================== 4. chunks ======
print("\n== 4. OW24 chunk limits (per-MAC worst case, exhaustive over operands)")


def horner_trace(adig, wdig, groups):
    """groups: list of lists of (p,q) in pass order; groups of equal weight,
    consecutive groups differ by 2 bits (one x4 ring).  Returns the list of
    register values per MAC: after each pass, and the x4-wiring inputs."""
    regs, ring_in = [], []
    acc = 0
    for gi, grp in enumerate(groups):
        if gi:
            ring_in.append(acc)
            acc *= 4
            regs.append(acc)
        for p, q in grp:
            acc += adig[p] * (wdig[q] if q is not None else 1)
            regs.append(acc)
    return regs, ring_in, acc


def chunk_report(name, ar, wr, na, nw, groups_fn, final_fn):
    mx_pos = mx_neg = mx_ring = 0
    for a in ar:
        dA = booth(a, na, 2)
        for w in wr:
            dW = booth(w, nw, 4)
            for groups, wd in groups_fn(dW):
                regs, ring, fin = horner_trace(dA, wd, groups)
                check(fin == final_fn(a, w, wd), f"{name}: Horner end value a={a} w={w}")
                mx_pos = max(mx_pos, max(regs))
                mx_neg = min(mx_neg, min(regs))
                if ring:
                    mx_ring = max(mx_ring, max(abs(r) for r in ring))
    lim_reg = min(OMAX // mx_pos, (-OMIN) // (-mx_neg) if mx_neg else 10 ** 9)
    lim_ring = ((1 << 21) - 1) // mx_ring if mx_ring else 10 ** 9   # 4V <= 2^23-1
    lim = min(lim_reg, lim_ring)
    print(f"   {name:9s}: per-MAC register max +{mx_pos} / {mx_neg}, x4-input max |{mx_ring}| "
          f"-> L <= {lim_reg} (register), {lim_ring} (x4 wiring) => chunk {lim}")
    return lim


A8, A4 = range(-128, 128), range(-8, 8)
# INT8 FH: weight groups 10, 8, 6, 4, 2, 0 (weight = 2p + 4q)
FH_GROUPS = [[(3, 1)], [(2, 1)], [(3, 0), (1, 1)], [(2, 0), (0, 1)], [(1, 0)], [(0, 0)]]
fh = chunk_report("INT8 FH", A8, A8, 8, 8, lambda dW: [(FH_GROUPS, dW)], lambda a, w, wd: a * w)
# alternative within-group order (1,1) before (3,0) -- must not change the bound much
FH2 = [[(3, 1)], [(2, 1)], [(1, 1), (3, 0)], [(0, 1), (2, 0)], [(1, 0)], [(0, 0)]]
chunk_report("INT8 FH'", A8, A8, 8, 8, lambda dW: [(FH2, dW)], lambda a, w, wd: a * w)
# INT8 HYS: one W digit per tile column; A digits weight-outer 3..0
hys = chunk_report("INT8 HYS", A8, A8, 8, 8,
                   lambda dW: [([[(p, 0)] for p in (3, 2, 1, 0)], [dW[q]]) for q in (0, 1)],
                   lambda a, w, wd: a * wd[0])
w4a8 = chunk_report("W4A8", A8, A4, 8, 4, lambda dW: [([[(p, 0)] for p in (3, 2, 1, 0)], dW)],
                    lambda a, w, wd: a * w)
int4 = chunk_report("INT4", A4, A4, 4, 4, lambda dW: [([[(1, 0)], [(0, 0)]], dW)],
                    lambda a, w, wd: a * w)
check(fh == 511, f"INT8 FH chunk {fh} != claimed 511")
check(hys == 8191, f"INT8 HYS chunk {hys} != claimed 8191")
check(w4a8 == 8191, f"W4A8 chunk {w4a8} != claimed 8191")
check(int4 == 131071, f"INT4 chunk {int4} != claimed 131071")
print("   (x4-input margins at the claimed chunks: HYS 8191*256 = %d vs 2^21 = %d; "
      "INT4 131071*16 = %d)" % (8191 * 256, 1 << 21, 131071 * 16))

# ================================================ 5. reachable Sobol presets ==
print("\n== 5. exploratory: is any reachable Sobol state (shared rng_en) a valid preset?")
ssrc = SOBOL.read_text()
dirs1 = [int(h, 16) for h in re.findall(r"\d: decorrelated_vector = 8'h([0-9a-f]{2});", ssrc)]
assert len(dirs1) == 8


def sobol_states(dset, base, stride):
    dirv = [1 << (WIDTH - 1 - i) for i in range(WIDTH)] if dset == 0 else dirs1
    states = []
    rv = [(base ^ ((stride * m) & 0xFF)) for m in range(M)]
    cnt = 0
    for _ in range(256):
        states.append(list(rv))
        sel = 0
        for i in range(WIDTH):
            if not (cnt >> i) & 1:
                sel = dirv[i]
                break
        rv = [x ^ sel for x in rv]
        cnt = (cnt + 1) & 0xFF
    return states


SA = sobol_states(0, 0x17, 0x53)
SW = sobol_states(1, 0x9D, 0x2B)


def preset_ok(pa, pw):
    for k in range(K):
        ta = sorted((pa[m] ^ mask(k, m, SALT_A), m) for m in range(M))
        tw = sorted((pw[m] ^ mask(k, m, SALT_W), m) for m in range(M))
        if not (ta[7][0] < ta[8][0] and ta[15][0] < 255 and tw[15][0] < 255):
            return False
        r0 = {m for _, m in ta[:8]}
        for c in range(8):
            pair = (tw[2 * c][1], tw[2 * c + 1][1])
            if c < 7 and not tw[2 * c + 1][0] < tw[2 * c + 2][0]:
                return False
            if (pair[0] in r0) + (pair[1] in r0) != 1:
                return False
    return True


check(preset_ok(PRESET_A, PRESET_W), "structural preset test rejects the claimed preset")
same = [c for c in range(256) if preset_ok(SA[c], SW[c])]
anyp = sum(1 for ca in range(256) for cw in range(256) if preset_ok(SA[ca], SW[cw]))
print(f"   claimed preset passes the structural test: {preset_ok(PRESET_A, PRESET_W)}")
print(f"   reachable states with both banks at the same count that work: {same}")
print(f"   (A count, W count) pairs that work if the banks could stop independently: {anyp}")

print("\nRESULT:", "ALL CHECKS PASSED" if not FAILS else f"{len(FAILS)} FAILURES")
sys.exit(1 if FAILS else 0)
