#!/usr/bin/env python3
"""Exactness check for running signed INT8 on the unchanged PaYN CSA tile.

No EDA tools. Models the RTL arithmetic of
designs/payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv
(11-FA counter with five redundant outputs, per-lane sign XOR, -16*N
correction row, LOW_W=9 low segment + pending carry/borrow + lazy high part).

Encoding checked here ("Booth 2x8 digit grid"):
  * a (int8, two's complement) -> 4 radix-4 Booth digits d_a in [-2, 2]
  * w (int8, two's complement) -> 2 radix-16 Booth digits d_w in [-8, 8]
  * one lane, one cycle carries one digit pair: the 16 positions are a 2x8
    grid m = 8*r + c with a_bits[m] = |d_a| > r and w_bits[m] = |d_w| > c,
    so popcount(a_bits & w_bits) = |d_a|*|d_w| <= 16 = M exactly;
    lane sign = sign(d_a) XOR sign(d_w) goes through the existing sign pipes.
  * a*w = sum_{p,q} 4**p * 16**q * d_a[p] * d_w[q]  (8 digit pairs)

Part 1 checks every (a, w) pair through the gate-level counter model.
Part 2 runs a random GEMM with the "all-spatial" mapping (tile row h = (i, p),
tile column v = (j, q), lanes = 8 consecutive k per cycle), accumulates in the
segmented-accumulator model, combines the 8 tile sums per output with fixed
shifts 2p+4q outside the PE, and compares with numpy.
Part 3 prints the operand-bandwidth table for the space/time digit splits.
"""
import itertools
import numpy as np

K, M, LOW_W, OWIDTH = 8, 16, 9, 24
HIGH_W = OWIDTH - LOW_W


def booth_digits(v, n_bits, r_bits):
    """Radix-2**r_bits Booth digits of an n_bits two's-complement value."""
    u = v & ((1 << n_bits) - 1)
    bit = lambda i: 0 if i < 0 else ((u >> min(i, n_bits - 1)) & 1)
    digits = []
    for d in range(-(-n_bits // r_bits)):
        lo = d * r_bits
        val = bit(lo - 1)
        for t in range(r_bits):
            wgt = 1 << t
            val += (-wgt if t == r_bits - 1 else wgt) * bit(lo + t)
        digits.append(val)
    return digits


def fa(a, b, c):
    return a ^ b ^ c, (a & b) | (a & c) | (b & c)


def popcount16_csa(x):
    """Gate model of PaynPopcount16Csa: returns (s0a, s0b, s1, s2, s3)."""
    b = [(x >> i) & 1 for i in range(16)]
    fs, fc = [0] * 11, [0] * 11
    for i in range(5):
        fs[i], fc[i] = fa(b[3 * i], b[3 * i + 1], b[3 * i + 2])
    fs[5], fc[5] = fa(fs[0], fs[1], fs[2])
    fs[6], fc[6] = fa(fs[3], fs[4], b[15])
    fs[7], fc[7] = fa(fc[0], fc[1], fc[2])
    fs[8], fc[8] = fa(fc[3], fc[4], fc[5])
    fs[9], fc[9] = fa(fs[7], fs[8], fc[6])
    fs[10], fc[10] = fa(fc[7], fc[8], fc[9])
    return fs[5], fs[6], fs[9], fs[10], fc[10]


def grid_bits(da_mag, dw_mag):
    a_bits = w_bits = 0
    for r in range(2):
        for c in range(8):
            m = 8 * r + c
            a_bits |= int(da_mag > r) << m
            w_bits |= int(dw_mag > c) << m
    return a_bits, w_bits


def lane_word(da, dw):
    """Signed lane contribution exactly as the tile forms it."""
    a_bits, w_bits = grid_bits(abs(da), abs(dw))
    s0a, s0b, s1, s2, s3 = popcount16_csa(a_bits & w_bits)
    neg = int(da < 0) ^ int(dw < 0)
    return ((s0a ^ neg) + (s0b ^ neg) + 2 * (s1 ^ neg) + 4 * (s2 ^ neg)
            + 8 * (s3 ^ neg)) - 16 * neg, neg


# ---------------------------------------------------------------- part 1 --
lane_table = {}
for da in range(-2, 3):
    for dw in range(-8, 9):
        val, _ = lane_word(da, dw)
        assert val == da * dw, (da, dw, val)
        assert abs(da) * abs(dw) <= M
        lane_table[(da, dw)] = val

worst = 0
for a in range(-128, 128):
    dA = booth_digits(a, 8, 2)
    assert len(dA) == 4 and all(-2 <= d <= 2 for d in dA) and \
        sum(d * 4 ** p for p, d in enumerate(dA)) == a
    for w in range(-128, 128):
        dW = booth_digits(w, 8, 4)
        assert len(dW) == 2 and all(-8 <= d <= 8 for d in dW)
        acc = 0
        for (p, x), (q, y) in itertools.product(enumerate(dA), enumerate(dW)):
            acc += lane_table[(x, y)] << (2 * p + 4 * q)
        assert acc == a * w, (a, w, acc)
        worst = max(worst, max(abs(x) * abs(y) for x in dA for y in dW))
print(f"part 1: all 65,536 int8 x int8 pairs exact through the gate-level "
      f"counter model; max lane count = {worst} (M = {M})")


# ---------------------------------------------------------------- part 2 --
class SegmentedAcc:
    """Cycle model of the CSA tile accumulator (LOW_W low + pending + high)."""

    def __init__(self):
        self.low = self.high = 0
        self.pc = self.pb = 0

    def value(self):
        high = (self.high + (-1 if self.pb else 0) + self.pc) % (1 << HIGH_W)
        v = (high << LOW_W) | self.low
        return v - (1 << OWIDTH) if v >> (OWIDTH - 1) else v

    def mac(self, lane_words, neg_count):
        if self.pc or self.pb:
            self.high = (self.high - self.pb + self.pc) % (1 << HIGH_W)
        # heap = sum of XORed lane bits (already folded into lane_words + 16*neg)
        # + acc_low + correction row (-16*N); lane_words carry -16*neg already,
        # so add the +16*neg back and apply the single correction row.
        heap = sum(lane_words) + 16 * neg_count + self.low - 16 * neg_count
        assert -K * M <= heap < (1 << (LOW_W + 1)), heap  # RTL range argument
        self.pb = int(heap < 0)
        self.pc = int(heap >= 0 and (heap >> LOW_W) & 1)
        self.low = heap & ((1 << LOW_W) - 1)


rng = np.random.default_rng(20261003)
N_I, N_J, N_P, N_Q = 2, 4, 4, 2          # 8 rows = (i, p), 8 cols = (j, q)
KT = 8 * 96                               # reduction length, 8 lanes/cycle
A = rng.integers(-128, 128, size=(N_I, KT))
W = rng.integers(-128, 128, size=(KT, N_J))
A[0, :64] = -128                          # include extremes
W[:64, 0] = -128
dA = np.array([[booth_digits(int(x), 8, 2) for x in row] for row in A])
dW = np.array([[booth_digits(int(x), 8, 4) for x in col] for col in W.T])

tiles = {(i, p, j, q): SegmentedAcc() for i in range(N_I) for p in range(N_P)
         for j in range(N_J) for q in range(N_Q)}
for cyc in range(KT // K):
    ks = range(cyc * K, cyc * K + K)
    for (i, p, j, q), t in tiles.items():
        words, negs = [], 0
        for k in ks:
            val, neg = lane_word(int(dA[i, k, p]), int(dW[j, k, q]))
            words.append(val)
            negs += neg
        t.mac(words, negs)

out = np.zeros((N_I, N_J), dtype=np.int64)
for (i, p, j, q), t in tiles.items():
    out[i, j] += t.value() << (2 * p + 4 * q)  # fixed shifts, outside the PE
ref = A.astype(np.int64) @ W.astype(np.int64)
assert np.array_equal(out, ref), (out, ref)
print(f"part 2: {N_I}x{N_J} outputs, K={KT}, 64 tiles x {KT // K} cycles: "
      f"segmented-accumulator model + fixed-shift combine == numpy (exact)")


# --------------------------------------------------------------- part 2b --
# Bit-plane ("BISMO-like") alternative: every one of the 128 AND positions of
# a tile is a different k; one two's-complement plane pair per tile per cycle.
# Split used here: plane groups g in space (4 per operand), the 2 planes inside
# a group in time, so a 4-cycle block and an in-tile shift s = t_a + t_w in
# {0,1,2} applied to the reduced partial before it meets acc_low.  The MSB
# plane (g=3, t=1) is negative for all lanes, i.e. a per-cycle lane sign.
class ShiftedSegmentedAcc(SegmentedAcc):
    def mac_shifted(self, partial, s):
        if self.pc or self.pb:
            self.high = (self.high - self.pb + self.pc) % (1 << HIGH_W)
        heap = self.low + (partial << s)
        # LOW_W = 9 still gives "negative => exactly one borrow, bit 9 =>
        # exactly one carry" because |partial << 2| <= 128*4 = 2**LOW_W.
        assert -(1 << LOW_W) <= heap < (1 << (LOW_W + 1)), heap
        self.pb = int(heap < 0)
        self.pc = int(heap >= 0 and (heap >> LOW_W) & 1)
        self.low = heap & ((1 << LOW_W) - 1)


N_I2 = N_J2 = 2                       # 8 rows = (i, g_a), 8 cols = (j, g_w)
KB = 128 * 24                          # 128 new k per 4-cycle block
A2 = rng.integers(-128, 128, size=(N_I2, KB))
W2 = rng.integers(-128, 128, size=(KB, N_J2))
A2[:, :128] = -128
W2[:128, :] = -128
plane = lambda v, b: (v.astype(np.int64) & 0xFF) >> b & 1
t2 = {(i, ga, j, gw): ShiftedSegmentedAcc() for i in range(N_I2)
      for ga in range(4) for j in range(N_J2) for gw in range(4)}
for blk in range(KB // 128):
    ks = slice(blk * 128, blk * 128 + 128)
    for ta, tw in itertools.product(range(2), range(2)):
        for (i, ga, j, gw), t in t2.items():
            pa, pw = 2 * ga + ta, 2 * gw + tw
            cnt = int(np.sum(plane(A2[i, ks], pa) & plane(W2[ks, j], pw)))
            neg = (pa == 7) ^ (pw == 7)        # lane-uniform sign this cycle
            t.mac_shifted(-cnt if neg else cnt, ta + tw)
out2 = np.zeros((N_I2, N_J2), dtype=np.int64)
for (i, ga, j, gw), t in t2.items():
    out2[i, j] += t.value() << (2 * ga + 2 * gw)
ref2 = A2.astype(np.int64) @ W2.astype(np.int64)
assert np.array_equal(out2, ref2), (out2, ref2)
print(f"part 2b: bit-plane 2x2-time split, {N_I2}x{N_J2} outputs, K={KB}: "
      f"exact with LOW_W={LOW_W} and in-tile shift in {{0,1,2}}")


# ---------------------------------------------------------------- part 3 --
print("\npart 3: operand bandwidth into the edge, bits/cycle per PE "
      "(magnitude+sign = 9 b per value; SC reference loads 64+64 values / 8 cycles)")
print(f"{'mapping':58s} {'A':>5s} {'W':>5s} {'tot':>5s} {'b/MAC':>6s} "
      f"{'outputs/PE':>10s} {'in-tile shift set':>18s}")
rows = [
    ("SC (T=128, 8-cycle block)", 8, 8, 8, "-"),
    ("INT8 all-time: 8 digit pairs in time", 8, 8, 8, "{0,2,4,6,8,10}"),
    ("INT8 a-time(4) x w-space(2)", 8, 4, 4, "{0,2,4,6}"),
    ("INT8 a-space(2 hi) x a-time(2 lo) x w-space(2)", 4, 4, 2, "{0,2}"),
    ("INT8 w-time(2) x a-space(4)", 2, 8, 2, "{0,4}"),
    ("INT8 all-space (zero tile change)", 2, 4, 1, "none"),
    ("W4A8 all-space (w = 1 radix-16 digit)", 2, 8, 1, "none"),
    ("W4A4 all-space (a = 2 radix-4 digits)", 4, 8, 1, "none"),
]
for name, n_i, n_j, cyc, shifts in rows:
    a_b = n_i * K * 9 / cyc
    w_b = n_j * K * 9 / cyc
    macs = 64 if "INT8" in name or "SC" in name else (128 if "W4A8" in name else 256)
    print(f"{name:58s} {a_b:5.0f} {w_b:5.0f} {a_b + w_b:5.0f} "
          f"{(a_b + w_b) / macs:6.2f} {n_i * n_j:10d} {shifts:>18s}")
# Bit-plane splits: 128 MAC/cycle/PE; values are 8-bit two's complement and
# each row/col needs 128 values per block of t_a*t_w cycles.
for ta, tw in [(1, 1), (2, 2), (4, 4), (8, 8)]:
    n_i, n_j = ta, tw
    a_b = n_i * 128 * 8 / (ta * tw)
    w_b = n_j * 128 * 8 / (ta * tw)
    sh = "none" if ta * tw == 1 else "{0..%d}" % (ta + tw - 2)
    print(f"{'INT8 bit-plane, %d x %d planes in time' % (ta, tw):58s} "
          f"{a_b:5.0f} {w_b:5.0f} {a_b + w_b:5.0f} {(a_b + w_b) / 128:6.2f} "
          f"{n_i * n_j:10d} {sh:>18s}")


# ---------------------------------------------------------------- part 4 --
# Cell-count ESTIMATE of the in-tile cost of a per-cycle shift (no synthesis).
# Areas (um2) are the A7 SVT C30 footprints PT reports for the CSA tile in
# build/area_anatomy/csa_syn_area_anatomy.rpt: ADDF_X1M 1.666, AO22_X1M 0.686,
# AOI22_X0P7M 0.490, NAND2_X1A 0.294.  One-hot k:1 mux per bit (selects
# decoded once per tile): k=2 AO22; k=3 AOI22+2*NAND2; k=4 2*AOI22+NAND2;
# k=6 3*AOI22+NAND3(0.49); k=7 ~4*AOI22+NAND; k=15 ~8*AOI22+NAND tree.
# Structure assumed ("CPA-first"): lanes+correction heap -> 10-bit CPA ->
# shift mux -> 2-operand add with acc_low.  acc_low leaves the heap (-9 FA),
# the partial CPA is new (+10 FA), the final adder widens with LOW_W, the
# lazy high incrementer shrinks by the same bits (~1 um2/bit), +2 um2 decode.
# Timing is NOT modelled: the extra CPA+mux may force the carry-save-shift
# variant (mux both 10-bit heap rows, ~2x the mux cells, no extra CPA).
FA, AO22, AOI22, NAND2 = 1.666, 0.686, 0.490, 0.294
MUX = {2: AO22, 3: AOI22 + 2 * NAND2, 4: 2 * AOI22 + NAND2,
       6: 3 * AOI22 + 0.49, 7: 4 * AOI22 + 0.49, 15: 8 * AOI22 + 4 * NAND2}
TILE, UPE = 408.170, 29255.548                 # synth tile, routed u_pe
GRID44 = 16 * UPE + 8 * 12792.920 / 2 + 2 * 698.152
print("\npart 4: in-tile shift cost ESTIMATE (um2; grid = 16 u_pe + 8 edge "
      f"halves + Sobol pair = {GRID44:,.0f} um2)")
print(f"{'option':44s} {'mux':>4s} {'bits':>4s} {'dLOW':>4s} {'tile':>6s} "
      f"{'%tile':>6s} {'4x4 grid':>9s} {'%grid':>6s}")
for name, k, bits, dlow in [
        ("Booth all-space (no in-tile shift)", 1, 0, 0),
        ("Booth {0,2}  (2 digits in time)", 2, 12, 0),
        ("Booth {0,4}", 2, 14, 2),
        ("bit-plane 2x2 {0,1,2}", 3, 12, 0),
        ("Booth {0,2,4,6}", 4, 16, 4),
        ("bit-plane 4x4 {0..6}", 7, 16, 6),
        ("Booth all-time {0..10 step 2}", 6, 20, 8),
        ("bit-plane 8x8 {0..14}", 15, 22, 14)]:
    if k == 1:
        d = 0.0
    else:
        d = 10 * FA - 9 * FA + bits * MUX[k] + dlow * FA - dlow * 1.0 + 2.0
    print(f"{name:44s} {k:4d} {bits:4d} {dlow:4d} {d:6.1f} {100 * d / TILE:5.1f}% "
          f"{1024 * d:9,.0f} {100 * 1024 * d / GRID44:5.1f}%")
