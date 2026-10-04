#!/usr/bin/env python3
"""Bit-exact register-level model: INT mode on PaYN with NO shifter in the tile.

Angle: "spatial fixed weight".  Every tile accumulates digit products of ONE
fixed weight 4**p * 16**q for the whole output block, so the tile RTL
(designs/payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv)
is used unchanged.  The digit weights are applied once per output, after the
drain, by a fixed-shift combiner at the grid's east edge.

Encoding ("Booth 2x8 digit grid", all digits in space)
  a  (activation): radix-4 Booth digits  da in [-2, 2]   (INT8: 4, INT4: 2)
  w  (weight):     radix-16 Booth digits dw in [-8, 8]   (INT8: 2, INT4: 1)
  one lane, one cycle = one digit pair: popcount(a_bits & w_bits) = |da|*|dw|
  <= 16 = M, lane sign = sign(da) ^ sign(dw) through the existing sign pipes.
  Tile row h  = (activation, a-digit p), tile column v = (weight, w-digit q).

What is modelled at register level (one python step = one clock edge)
  * shared Sobol bus parked at a constant preset (INT mode); the per-(k,m)
    compile-time scramble masks of pe_peripheral.sv are kept;
  * edge recoder (raw two's-complement bytes -> Booth digit -> 8-bit code and
    sign), loaded every cycle into the existing a/w_binary_q and sign regs;
  * the unchanged comparator  bit = code > (preset[m] ^ MASK(k, m, salt));
  * PE bit pipes / sign pipes / load_*_sign_q, re-exported PE to PE (grid);
  * the tile: 128 AND, gate-level PaynPopcount16Csa, 5 sign XORs per lane,
    one -16*N correction row, 11-bit heap sum (mod 2**11), LOW_W=9 acc_low,
    pending carry/borrow, lazy +-1 acc_high (HIGH_W=15), canonical acc_out,
    shift_in drain with priority over mac_en, acc_in_west = 0;
  * systolic skew of the operand feed, global unskewed mac_en / shift_in;
  * the east-edge combiner (2 pipeline stages, fixed shifts, Horner on the
    q pair), with width checks.

Checks (any failure raises AssertionError -> non-zero exit):
  0. presets: the comparator emits count == |da|*|dw| for every k, both banks;
  1. every INT8xINT8 (65,536), INT8xINT4 and INT4xINT4 value pair through
     recoder + comparator + lane + digit weights;
  2. full GEMMs through the grid model vs numpy int64, modes INT8 / W4A8 /
     INT4, reduction lengths 8, 64, 1024 (+4096 on 1x1), data random
     full-range, all-max, all-min, alternating signs, mixed extremes, two
     output blocks back to back (drain must zero-fill), grids 1x1, 2x2 and
     one 4x4 run.  Every cycle: heap range, pending exclusivity, canonical
     acc_out == exact shadow sum, |acc| < 2**23, combiner widths.
  3. measured cycles/block == formula, and the area / throughput / bandwidth
     tables used in the write-up (estimates from LEF cell areas).

No EDA tools.  Usage:  python3 sweeps/int_mode/model_spatial_fixed_weight.py [--quick]
"""
from __future__ import annotations

import argparse
import sys

import numpy as np

K, M, NH, NW = 8, 16, 8, 8
OWIDTH, LOW_W = 24, 9
SUM_W, HIGH_W = LOW_W + 2, OWIDTH - LOW_W
LEVELS = 256
SK = ((LEVELS * 79) // 128) | 1          # pe_peripheral SCRAMBLE_K_STRIDE
SM = ((LEVELS * 49) // 128) | 1          # pe_peripheral SCRAMBLE_M_STRIDE
SALT_A, SALT_W = 0, 128

# INT-mode constants driven onto the shared random_values bus (one Sobol pair
# per grid).  Found by simulated annealing (search over 2 x 16 bytes); the
# check in part 0 is what certifies them.
PRESET_A = [183, 166, 106, 211, 179, 48, 65, 189, 197, 84, 120, 108, 10, 177, 221, 209]
PRESET_W = [254, 16, 49, 107, 53, 212, 110, 133, 21, 35, 183, 70, 165, 180, 161, 32]


def mask(k: int, m: int, salt: int) -> int:
    return (k * SK + m * SM + salt) & (LEVELS - 1)


THR_A = np.array([[PRESET_A[m] ^ mask(k, m, SALT_A) for m in range(M)] for k in range(K)])
THR_W = np.array([[PRESET_W[m] ^ mask(k, m, SALT_W) for m in range(M)] for k in range(K)])


# ------------------------------------------------------------ code tables --
def build_code_tables():
    """A side: 3 levels (|da| = 0,1,2); W side: 9 levels (|dw| = 0..8).
    code > thr is strict, so code c lights #{thr < c} positions."""
    c1 = np.zeros(K, dtype=np.int64)
    cw = np.zeros((K, 9), dtype=np.int64)
    for k in range(K):
        sa = sorted(THR_A[k])
        assert max(sa) <= 254, "A: a threshold of 255 blocks the all-ones code"
        assert sa[7] < sa[8], f"A k={k}: no gap between 8th and 9th threshold"
        c1[k] = sa[7] + 1
        sw = sorted(THR_W[k])
        assert max(sw) <= 254, "W: a threshold of 255 blocks the all-ones code"
        cw[k, 0], cw[k, 8] = 0, 255
        for n in range(1, 8):
            assert sw[2 * n - 1] < sw[2 * n], f"W k={k}: no gap at {2 * n}"
            cw[k, n] = sw[2 * n - 1] + 1
    return c1, cw


C1_A, CODE_W = build_code_tables()


def comparator(codes: np.ndarray, thr: np.ndarray) -> np.ndarray:
    """codes [..., K] (8-bit) -> packed 16-bit lane words [..., K]."""
    bits = codes[..., None] > thr                     # [..., K, M]
    return (bits.astype(np.int64) << np.arange(M)).sum(-1).astype(np.int64)


# --------------------------------------------- gate-level 11-FA counter LUT --
def _fa(a, b, c):
    return a ^ b ^ c, (a & b) | (a & c) | (b & c)


def _popcount16_csa_table():
    x = np.arange(1 << 16, dtype=np.int64)
    b = [(x >> i) & 1 for i in range(16)]
    fs, fc = [None] * 11, [None] * 11
    for i in range(5):
        fs[i], fc[i] = _fa(b[3 * i], b[3 * i + 1], b[3 * i + 2])
    fs[5], fc[5] = _fa(fs[0], fs[1], fs[2])
    fs[6], fc[6] = _fa(fs[3], fs[4], b[15])
    fs[7], fc[7] = _fa(fc[0], fc[1], fc[2])
    fs[8], fc[8] = _fa(fc[3], fc[4], fc[5])
    fs[9], fc[9] = _fa(fs[7], fs[8], fc[6])
    fs[10], fc[10] = _fa(fc[7], fc[8], fc[9])
    s0a, s0b, s1, s2, s3 = fs[5], fs[6], fs[9], fs[10], fc[10]
    cnt = s0a + s0b + 2 * s1 + 4 * s2 + 8 * s3
    pc = np.array([bin(int(v)).count("1") for v in range(1 << 16)])
    assert np.array_equal(cnt, pc), "PaynPopcount16Csa gate model is wrong"
    return np.stack([s0a, s0b, s1, s2, s3]).astype(np.int64)


CSA = _popcount16_csa_table()


# ------------------------------------------------------------- recoders --
def bit(x, i):
    return (x >> i) & 1


def recode_a(byte: np.ndarray, int4: bool):
    """Radix-4 Booth on one raw byte per (row group i, lane k).
    Returns code [..., 4(p), K] and sign [..., 4, K].  Gate view per digit:
    x1 = b2^b1, x0 = b1^b0, nz = x1|x0, two = x1&~x0, sign = b2; the 8-bit
    code is pure wiring: bit = C1[k]_bit ? nz : two (C2 = 255).
    INT4: the byte holds two nibbles; digit 2 gets b_-1 = b3 & ~int4."""
    codes, signs = [], []
    for p in range(4):
        b2 = bit(byte, 2 * p + 1)
        b1 = bit(byte, 2 * p)
        b0 = bit(byte, 2 * p - 1) if p > 0 else np.zeros_like(byte)
        if p == 2 and int4:
            b0 = np.zeros_like(byte)
        x1, x0 = b2 ^ b1, b1 ^ b0
        nz, two = x1 | x0, x1 & (1 - x0)
        code = np.zeros_like(byte)
        for bb in range(8):
            c1bit = (C1_A >> bb) & 1                 # per lane k (last axis)
            code |= np.where(c1bit == 1, nz, two) << bb
        codes.append(code)
        signs.append(b2)
    return np.stack(codes, axis=-2), np.stack(signs, axis=-2)


def recode_w(byte: np.ndarray, w4: bool):
    """Radix-16 Booth on one raw byte per (col group j, lane k).
    INT8: digits q=0 (b3..b0, 0) and q=1 (b7..b4, b3).
    W4: the byte holds two 4-bit weights; q=1 gets b_-1 = b3 & ~w4.
    Returns code [..., 2(q), K], sign [..., 2, K]."""
    codes, signs = [], []
    for q in range(2):
        b3, b2, b1, b0 = (bit(byte, 4 * q + t) for t in (3, 2, 1, 0))
        bm1 = bit(byte, 4 * q - 1) if q > 0 and not w4 else np.zeros_like(byte)
        u = 4 * b2 + 2 * b1 + b0 + bm1                # 0..8
        mag = np.where(b3 == 1, 8 - u, u)
        assert mag.min() >= 0 and mag.max() <= 8
        kk = np.broadcast_to(np.arange(K), byte.shape)
        codes.append(CODE_W[kk, mag])
        signs.append(b3)
    return np.stack(codes, axis=-2), np.stack(signs, axis=-2)


def booth_value_a(byte, int4):
    """Digit values (for the value-level check), [..., 4]."""
    out = []
    for p in range(4):
        b2, b1 = bit(byte, 2 * p + 1), bit(byte, 2 * p)
        b0 = bit(byte, 2 * p - 1) if p > 0 and not (p == 2 and int4) else 0
        out.append(-2 * b2 + b1 + b0)
    return np.stack(out, -1)


def booth_value_w(byte, w4):
    out = []
    for q in range(2):
        b3, b2, b1, b0 = (bit(byte, 4 * q + t) for t in (3, 2, 1, 0))
        bm1 = bit(byte, 4 * q - 1) if q > 0 and not w4 else 0
        out.append(-8 * b3 + 4 * b2 + 2 * b1 + b0 + bm1)
    return np.stack(out, -1)


def lane_signed(a_word, w_word, a_sign, w_sign):
    """Tile lane exactly as the RTL forms it: 5 XORed CSA bits - 16*neg."""
    s = CSA[:, a_word & w_word]
    neg = a_sign ^ w_sign
    row4 = ((s[4] << 3) | (s[3] << 2) | (s[2] << 1) | s[0]) ^ (15 * neg)
    row1 = s[1] ^ neg
    return row4 + row1 - 16 * neg, row4, row1, neg


# ---------------------------------------------------------------- part 0 --
def check_presets():
    for k in range(K):
        for x in range(3):
            ca = np.array([0, C1_A[k], 255])[x]
            a_word = int(comparator(np.array([ca] * K), THR_A)[k])
            for y in range(9):
                w_word = int(comparator(np.array([CODE_W[k, y]] * K), THR_W)[k])
                assert bin(w_word).count("1") == 2 * y
                for sa in (0, 1):
                    for sw in (0, 1):
                        v, *_ = lane_signed(np.int64(a_word), np.int64(w_word), sa, sw)
                        want = x * y * (-1 if (sa ^ sw) and x * y else 1)
                        assert int(v) == want, (k, x, y, sa, sw, int(v), want)
    print("part 0: presets OK - for all 8 lanes k, both banks, all |da| in 0..2, "
          "|dw| in 0..8 and all sign pairs, comparator+counter+sign give exactly "
          "da*dw (A codes C1[k]=" + ",".join(str(int(c)) for c in C1_A) + "; C2=255)")


# ---------------------------------------------------------------- part 1 --
def check_value_pairs():
    """Every value pair through recoder -> comparator -> lane -> weights."""
    kk = np.arange(K)
    for name, a_rng, w_rng, int4, w4 in [
            ("INT8 x INT8", range(-128, 128), range(-128, 128), False, False),
            ("INT8 x INT4 (W4A8)", range(-128, 128), range(-8, 8), False, True),
            ("INT4 x INT4", range(-8, 8), range(-8, 8), True, True)]:
        av = np.array(list(a_rng))
        wv = np.array(list(w_rng))
        # A byte: INT8 the value; INT4 the value in the low nibble (activation
        # 2i), the high nibble holds activation 2i+1 (checked separately).
        for nib in ((0, 1) if int4 else (0,)):
            a_byte = ((av & 0xF) << (4 * nib)) if int4 else (av & 0xFF)
            w_byte = (wv & 0xF) if w4 else (wv & 0xFF)
            ab = np.broadcast_to(a_byte[:, None], (len(av), K))
            wb = np.broadcast_to(w_byte[:, None], (len(wv), K))
            a_code, a_sign = recode_a(ab, int4)          # [na, 4, K]
            w_code, w_sign = recode_w(wb, w4)            # [nw, 2, K]
            a_word = comparator(a_code, THR_A)          # [na, 4, K]
            w_word = comparator(w_code, THR_W)          # [nw, 2, K]
            pa = (2 * nib, 2 * nib + 1) if int4 else range(4)
            pq = (0,) if w4 else range(2)
            acc = np.zeros((len(av), len(wv)), dtype=np.int64)
            for p in pa:
                for q in pq:
                    v, *_ = lane_signed(a_word[:, None, p, :], w_word[None, :, q, :],
                                        a_sign[:, None, p, :], w_sign[None, :, q, :])
                    assert np.all(np.abs(v) <= 16)
                    # each lane k carries the same pair here: all K agree
                    assert np.all(v == v[..., :1])
                    acc += v[..., 0] << (2 * (p - (2 * nib if int4 else 0)) + 4 * q)
            ref = av[:, None] * wv[None, :]
            assert np.array_equal(acc, ref), name
        print(f"part 1: {name}: all {len(av) * len(wv):,} value pairs exact through "
              f"recoder + comparator + gate-level counter + sign/-16N + digit weights")


# ------------------------------------------------------------ grid model --
def s24(x):
    x = x & ((1 << OWIDTH) - 1)
    return np.where(x >> (OWIDTH - 1), x - (1 << OWIDTH), x)


class Grid:
    """P_R x P_C PEs, each 8x8 unchanged CSA tiles, edge peripherals on the
    west (A, one per PE row) and on the W side (one per PE column)."""

    def __init__(self, pr: int, pc: int):
        self.pr, self.pc = pr, pc
        z = lambda *s: np.zeros(s, dtype=np.int64)
        self.a_code_q, self.a_sign_q = z(pr, NH, K), z(pr, NH, K)
        self.w_code_q, self.w_sign_q = z(pc, NW, K), z(pc, NW, K)
        self.a_bits_pipe, self.a_signs_pipe = z(pr, pc, NH, K), z(pr, pc, NH, K)
        self.w_bits_pipe, self.w_signs_pipe = z(pr, pc, NW, K), z(pr, pc, NW, K)
        self.load_a_sign_q, self.load_w_sign_q = z(pr, pc), z(pr, pc)
        self.acc_low, self.acc_high = z(pr, pc, NH, NW), z(pr, pc, NH, NW)
        self.pend_c, self.pend_b = z(pr, pc, NH, NW), z(pr, pc, NH, NW)
        self.shadow = z(pr, pc, NH, NW)                  # exact integer sum
        self.max_abs = 0

    def step(self, a_codes, a_signs, w_codes, w_signs, mac_en, shift_in,
             load_a_sign_in=1, load_w_sign_in=1):
        pr, pc = self.pr, self.pc
        # ---------------- combinational: edge comparators (unchanged) ----
        cmp_a = comparator(self.a_code_q, THR_A)          # [pr, NH, K]
        cmp_w = comparator(self.w_code_q, THR_W)          # [pc, NW, K]
        # ---------------- combinational: tiles ----------------------------
        aw = self.a_bits_pipe[:, :, :, None, :]
        ww = self.w_bits_pipe[:, :, None, :, :]
        asg = self.a_signs_pipe[:, :, :, None, :]
        wsg = self.w_signs_pipe[:, :, None, :, :]
        lane, row4, row1, neg = lane_signed(aw, ww, asg, wsg)   # [pr,pc,h,v,k]
        ncount = neg.sum(-1)
        corr = (-(ncount * 16)) & ((1 << SUM_W) - 1)            # SUM_W'(-16N)
        heap_mod = (row4.sum(-1) + row1.sum(-1) + corr + self.acc_low) \
            & ((1 << SUM_W) - 1)
        low_sum = np.where(heap_mod >= (1 << (SUM_W - 1)), heap_mod - (1 << SUM_W),
                           heap_mod)
        d = lane.sum(-1)
        true_sum = d + self.acc_low
        assert np.all(np.abs(d) <= K * M), "per-cycle |d| > K*M"
        assert np.all((true_sum >= -K * M) & (true_sum < (1 << (LOW_W + 1)))), \
            "heap range argument violated"
        assert np.array_equal(low_sum, true_sum), "11-bit heap wrapped"
        nb = (low_sum < 0).astype(np.int64)
        ncy = ((1 - nb) & ((low_sum >> LOW_W) & 1)).astype(np.int64)
        high_next = (self.acc_high - self.pend_b + self.pend_c) & ((1 << HIGH_W) - 1)
        acc_out = s24((high_next << LOW_W) | self.acc_low)
        assert np.array_equal(acc_out, self.shadow), "canonical acc_out != exact sum"
        acc_in = np.zeros_like(acc_out)
        acc_in[..., 1:] = acc_out[..., :-1]
        acc_in[:, 1:, :, 0] = acc_out[:, :-1, :, NW - 1]       # acc_in_west = 0
        sh_in = np.zeros_like(self.shadow)
        sh_in[..., 1:] = self.shadow[..., :-1]
        sh_in[:, 1:, :, 0] = self.shadow[:, :-1, :, NW - 1]
        east = acc_out[:, pc - 1, :, NW - 1].copy()            # sampled pre-edge
        # ---------------- sequential: tiles (RTL priority) -----------------
        if shift_in:
            self.acc_low = acc_in & ((1 << LOW_W) - 1)
            self.acc_high = (acc_in >> LOW_W) & ((1 << HIGH_W) - 1)
            self.pend_c = np.zeros_like(self.pend_c)
            self.pend_b = np.zeros_like(self.pend_b)
            self.shadow = sh_in
        else:
            upd = (self.pend_c | self.pend_b) == 1
            self.acc_high = np.where(upd, high_next, self.acc_high)
            if mac_en:
                self.acc_low = low_sum & ((1 << LOW_W) - 1)
                self.pend_c, self.pend_b = ncy, nb
                self.shadow = self.shadow + d
            else:
                self.pend_c = np.zeros_like(self.pend_c)
                self.pend_b = np.zeros_like(self.pend_b)
        assert not np.any(self.pend_c & self.pend_b), "carry and borrow both pending"
        self.max_abs = max(self.max_abs, int(np.abs(self.shadow).max()))
        assert self.max_abs < (1 << (OWIDTH - 1)), "24-bit accumulator overflow"
        # ---------------- sequential: PE pipes (A east, W across rows) -----
        nab = np.empty_like(self.a_bits_pipe)
        nab[:, 0], nab[:, 1:] = cmp_a, self.a_bits_pipe[:, :-1]
        a_src = np.empty_like(self.a_signs_pipe)
        a_src[:, 0], a_src[:, 1:] = self.a_sign_q, self.a_signs_pipe[:, :-1]
        self.a_signs_pipe = np.where(self.load_a_sign_q[..., None, None] == 1,
                                     a_src, self.a_signs_pipe)
        nla = np.empty_like(self.load_a_sign_q)
        nla[:, 0], nla[:, 1:] = load_a_sign_in, self.load_a_sign_q[:, :-1]
        nwb = np.empty_like(self.w_bits_pipe)
        nwb[0], nwb[1:] = cmp_w, self.w_bits_pipe[:-1]
        w_src = np.empty_like(self.w_signs_pipe)
        w_src[0], w_src[1:] = self.w_sign_q, self.w_signs_pipe[:-1]
        self.w_signs_pipe = np.where(self.load_w_sign_q[..., None, None] == 1,
                                     w_src, self.w_signs_pipe)
        nlw = np.empty_like(self.load_w_sign_q)
        nlw[0], nlw[1:] = load_w_sign_in, self.load_w_sign_q[:-1]
        self.a_bits_pipe, self.w_bits_pipe = nab, nwb
        self.load_a_sign_q, self.load_w_sign_q = nla, nlw
        # ---------------- sequential: edge held regs (load every cycle) ----
        self.a_code_q, self.a_sign_q = a_codes, a_signs
        self.w_code_q, self.w_sign_q = w_codes, w_signs
        return east


class Combiner:
    """East-edge fixed-shift combiner, one per PE row (vectorised over rows).
    Stage 1 (registered): P_t = v[2t] + (v[2t+1] << 2), Q_u = P_2u + (P_2u+1 << 4).
    Stage 2: INT8: q=1 -> R <= Q; q=0 -> OUT <= (R << 4) + Q.
             W4A8: OUT <= Q.   INT4: OUT <= P."""
    P_W, Q_W, O_W = 27, 32, 36

    def __init__(self, mode, pr):
        self.mode, self.pr = mode, pr
        self.s1 = None
        self.R = np.zeros((pr, 2), dtype=np.int64)
        self.out = []                                  # (c, v, values[pr, n])

    @staticmethod
    def _fits(x, w):
        assert np.all((x >= -(1 << (w - 1))) & (x < (1 << (w - 1)))), \
            f"combiner overflow at {w} bits"

    def step(self, sample, meta):
        if self.s1 is not None:                        # stage 2
            P, Q, (c, v) = self.s1
            if self.mode == "INT8":
                if v % 2 == 1:
                    self.R = Q.copy()
                else:
                    o = (self.R << 4) + Q
                    self._fits(o, self.O_W)
                    self.out.append((c, v // 2, o))
            elif self.mode == "W4A8":
                self.out.append((c, v, Q.copy()))
            else:
                self.out.append((c, v, P.copy()))
        self.s1 = None
        if sample is not None:                         # stage 1
            P = sample[:, 0::2] + (sample[:, 1::2] << 2)
            self._fits(P, self.P_W)
            Q = P[:, 0::2] + (P[:, 1::2] << 4)
            self._fits(Q, self.Q_W)
            self.s1 = (P, Q, meta)


MODES = {   # (a bytes per row group, int4 gating, w4 gating, acts/PE, wts/PE)
    "INT8": dict(int4=False, w4=False, n_i=2, n_j=4),
    "W4A8": dict(int4=False, w4=True, n_i=2, n_j=8),
    "INT4": dict(int4=True, w4=True, n_i=4, n_j=8),
}


def pack_a(A, mode, pr, s, ks):
    """Raw A port bytes for every PE-row edge: [pr, 2(i), K]."""
    n_i = MODES[mode]["n_i"]
    blk = A.reshape(pr, n_i, -1)[:, :, ks]                # [pr, n_i, K]
    if mode == "INT4":
        return ((blk[:, 1::2] & 0xF) << 4) | (blk[:, 0::2] & 0xF)
    return blk & 0xFF


def pack_w(W, mode, pc, ks):
    """Raw W port bytes for every PE-column edge: [pc, 4(j), K]."""
    n_j = MODES[mode]["n_j"]
    blk = W[ks].T.reshape(pc, n_j, K)                    # [pc, n_j, K]
    if MODES[mode]["w4"]:
        return ((blk[:, 1::2] & 0xF) << 4) | (blk[:, 0::2] & 0xF)
    return blk & 0xFF


def run_blocks(mode, blocks, pr, pc):
    """blocks: list of (A [pr*n_i, L], W [L, pc*n_j]); run back to back."""
    cfg = MODES[mode]
    L = blocks[0][0].shape[1]
    assert L % K == 0
    S = L // K
    g = Grid(pr, pc)
    combs = []
    mac_per_block = S + pr + pc - 2
    period = mac_per_block + NW * pc
    starts = [2 + b * period for b in range(len(blocks))]
    t_end = starts[-1] + 2 + period + 4
    mac_edges = 0
    for t in range(t_end):
        a_codes = np.zeros((pr, NH, K), dtype=np.int64)
        a_signs = np.zeros_like(a_codes)
        w_codes = np.zeros((pc, NW, K), dtype=np.int64)
        w_signs = np.zeros_like(w_codes)
        mac_en, shift_in, drain_idx, blk_id = 0, 0, None, None
        for b, F in enumerate(starts):
            A, W = blocks[b]
            for r in range(pr):                        # skewed A feed
                s = t - F - r
                if 0 <= s < S:
                    ks = slice(s * K, s * K + K)
                    byte = pack_a(A, mode, pr, s, ks)[r]       # [2, K]
                    code, sign = recode_a(byte, cfg["int4"])   # [2, 4, K]
                    a_codes[r] = code.reshape(NH, K)           # h = 4i + p
                    a_signs[r] = sign.reshape(NH, K)
            for c in range(pc):                        # skewed W feed
                s = t - F - c
                if 0 <= s < S:
                    ks = slice(s * K, s * K + K)
                    byte = pack_w(W, mode, pc, ks)[c]          # [4, K]
                    code, sign = recode_w(byte, cfg["w4"])     # [4, 2, K]
                    w_codes[c] = code.reshape(NW, K)           # v = 2j + q
                    w_signs[c] = sign.reshape(NW, K)
            first_mac = F + 2
            if first_mac <= t < first_mac + mac_per_block:
                mac_en = 1
            if first_mac + mac_per_block <= t < first_mac + period:
                shift_in, drain_idx, blk_id = 1, t - first_mac - mac_per_block, b
        if mac_en:
            mac_edges += 1
        east = g.step(a_codes, a_signs, w_codes, w_signs, mac_en, shift_in)
        while len(combs) < len(blocks):
            combs.append(Combiner(mode, pr))
        for b, cb in enumerate(combs):
            if blk_id == b:
                c = pc - 1 - drain_idx // NW
                v = NW - 1 - drain_idx % NW
                cb.step(east, (c, v))
            else:
                cb.step(None, None)
    results = []
    for (A, W), cb in zip(blocks, combs):
        out = np.full((A.shape[0], W.shape[1]), np.iinfo(np.int64).min)
        n_i, n_j = cfg["n_i"], cfg["n_j"]
        for c, j, vals in cb.out:
            for r in range(pr):
                for i in range(vals.shape[1]):
                    out[r * n_i + i, c * n_j + j] = vals[r, i]
        results.append(out)
    return results, mac_edges, period, g.max_abs


def data(mode, kind, rows, L, cols, rng):
    lo_a, hi_a = (-8, 7) if mode == "INT4" else (-128, 127)
    lo_w, hi_w = (-128, 127) if mode == "INT8" else (-8, 7)
    if kind == "random":
        A = rng.integers(lo_a, hi_a + 1, (rows, L))
        W = rng.integers(lo_w, hi_w + 1, (L, cols))
    elif kind == "all_max":
        A, W = np.full((rows, L), hi_a), np.full((L, cols), hi_w)
    elif kind == "all_min":
        A, W = np.full((rows, L), lo_a), np.full((L, cols), lo_w)
    elif kind == "alternating":
        sa = np.where(np.arange(L) % 2 == 0, hi_a, lo_a)
        A = np.tile(sa, (rows, 1))
        W = np.tile(np.where(np.arange(L) % 2 == 0, lo_w, hi_w)[:, None], (1, cols))
        A[1::2] = -A[1::2] - 1                          # flip pattern per row
    elif kind == "mixed_extremes":
        A = rng.choice([lo_a, -1, 0, 1, hi_a], (rows, L))
        W = rng.choice([lo_w, -1, 0, 1, hi_w], (L, cols))
    else:
        raise ValueError(kind)
    return A.astype(np.int64), W.astype(np.int64)


def check_gemms(quick: bool):
    rng = np.random.default_rng(20261003)
    kinds = ["random", "all_max", "all_min", "alternating", "mixed_extremes"]
    plan = []
    for mode in MODES:
        for L in (8, 64, 1024):
            for kind in kinds:
                plan.append((mode, 1, 1, L, kind))
        for L in (8, 64) + (() if quick else (1024,)):
            for kind in (kinds if L < 1024 else ["random", "all_min"]):
                plan.append((mode, 2, 2, L, kind))
    if not quick:
        plan += [("INT8", 1, 1, 4096, "random"), ("INT8", 1, 1, 4096, "all_min"),
                 ("INT4", 1, 1, 4096, "random"), ("INT8", 4, 4, 64, "random"),
                 ("W4A8", 4, 4, 64, "all_min")]
    n_checked, worst = 0, 0
    util_rows = {}
    for mode, pr, pc, L, kind in plan:
        cfg = MODES[mode]
        rows, cols = pr * cfg["n_i"], pc * cfg["n_j"]
        blocks = [data(mode, kind, rows, L, cols, rng),
                  data(mode, "random", rows, L, cols, rng)]
        outs, mac_edges, period, max_abs = run_blocks(mode, blocks, pr, pc)
        for (A, W), out in zip(blocks, outs):
            ref = A @ W
            assert np.array_equal(out, ref), (mode, pr, pc, L, kind)
            n_checked += out.size
        worst = max(worst, max_abs)
        S = L // K
        assert period == S + pr + pc - 2 + NW * pc
        assert mac_edges == len(blocks) * (S + pr + pc - 2)
        util_rows[(mode, pr, pc, L)] = S / period
        print(f"  ok  {mode:4s} grid {pr}x{pc}  L={L:5d}  {kind:15s}  "
              f"2 blocks, {rows}x{cols} outputs each, cycles/block {period:4d} "
              f"(MAC {S}, skew {pr + pc - 2}, drain {NW * pc}), "
              f"max|tile acc| {max_abs}")
    print(f"part 2: {len(plan)} GEMM runs, {n_checked:,} outputs, all bit-exact vs "
          f"numpy; largest tile accumulator magnitude {worst} (< 2**23 = {1 << 23})")
    return util_rows


# ------------------------------------------------------- costs (part 3) --
# LEF footprints (um2), A7 SVT C30 (ground truth in sweeps/int_mode/cost_table.py)
FA, HA, AND2, OR2, XOR2, AO22, AOI22, NAND2, INV = 1.666, 0.980, 0.392, 0.392, \
    0.588, 0.686, 0.490, 0.294, 0.196
MXT2, DFF2W = 0.784, 1.372
UPE, PERIPH, SOBOL = 29255.548, 13031.256, 844.760 + 833.588     # routed
ARRAY_1PE = 44017.974                                            # routed
TILE = 408.170


def grid_area(pr, pc):
    return pr * pc * UPE + (pr + pc) * PERIPH / 2 + SOBOL


def costs(util_rows):
    print("\npart 3: area / throughput / bandwidth (cell-count ESTIMATES, no synthesis)")
    # ---- A-edge INT path, per PE-row edge peripheral ----
    rec_a = 64 * (2 * XOR2 + OR2 + AOI22)      # nz, two per digit lane (64 lanes)
    gate4 = 16 * AND2                           # INT4: b_-1 of digit 2 forced to 0
    merge_a = 512 * AO22                        # a_binary_q D: code vs SC magnitude
    smerge_a = 64 * AO22                        # a_signs_q D: digit sign vs SC sign
    a_half = rec_a + gate4 + merge_a + smerge_a
    # ---- W-edge INT path, per PE-column edge, three weight formats ----
    lut_w = 64 * 5.4            # per-lane |dw| (0..8) -> 8-bit code LUT, ~12 gates
    absd_w = 64 * (3 * HA + 4 * XOR2 + 2 * HA)  # radix-16 |digit| from 5 raw bits
    gatew4 = 32 * AND2
    merge_w, smerge_w = 512 * AO22, 64 * AO22
    w_half = {"Wa_precoded": 0.0,
              "Wb_sign_absdigit": lut_w + merge_w + smerge_w,
              "Wc_raw": absd_w + lut_w + gatew4 + merge_w + smerge_w}
    # ---- Sobol preset (one pair per grid): D-path gate per random_value bit
    sobol_preset = 256 * AND2 + 32 * OR2
    # ---- East-edge combiner per PE row ----
    comb = (4 * 25 + 2 * 28 + 2 * 32) * FA + (64 + 64 + 72) * DFF2W + 100.0
    print(f"  A edge half: recoders {rec_a:.1f} + INT4 gating {gate4:.1f} + "
          f"512 AO22 code merge {merge_a:.1f} + 64 AO22 sign merge {smerge_a:.1f} "
          f"= {a_half:.1f} um2")
    for kk, vv in w_half.items():
        print(f"  W edge half ({kk}): {vv:.1f} um2")
    print(f"  Sobol-bus preset (shared pair): {sobol_preset:.1f} um2 per grid")
    print(f"  east-edge combiner per PE row: 220 FA + 200 flops + ~100 glue = "
          f"{comb:.1f} um2")

    configs = {
        "full (W raw, combiner in grid)": ("Wc_raw", True),
        "W as sign+|digit|, combiner in grid": ("Wb_sign_absdigit", True),
        "minimum (W pre-coded, combine downstream)": ("Wa_precoded", False),
    }
    grids = [("1 PE", 1, 1, ARRAY_1PE), ("4x4", 4, 4, grid_area(4, 4)),
             ("4x8 (P_R=4,P_C=8)", 4, 8, grid_area(4, 8)),
             ("8x4 (P_R=8,P_C=4)", 8, 4, grid_area(8, 4))]
    print("\n  INT-path area added (tile area added = 0):")
    tbl = {}
    for cname, (wk, with_comb) in configs.items():
        for gname, pr, pc, area in grids:
            add = pr * a_half + pc * w_half[wk] + sobol_preset + (pr * comb if with_comb else 0)
            tbl[(cname, gname)] = (add, area)
            sc_new = 25.6 * pr * pc / ((area + add) * 1e-6)
            sc_old = 25.6 * pr * pc / (area * 1e-6)
            print(f"    {cname:44s} {gname:18s} +{add:9.1f} um2 = {100 * add / area:5.2f}% "
                  f"of {area:,.0f};  SC GMAC/s/mm2 {sc_old:6.1f} -> {sc_new:6.1f}")

    print("\n  Utilisation per output block = (L/8) / (L/8 + (P_R+P_C-2) + 8*P_C):")
    for gname, pr, pc in [("1 PE", 1, 1), ("4x4", 4, 4), ("4x8", 4, 8), ("8x4", 8, 4)]:
        u = [(L // 8) / (L // 8 + pr + pc - 2 + 8 * pc) for L in (512, 1024, 4096, 11008)]
        print(f"    {gname:5s} L=512 {u[0]:.3f}  L=1024 {u[1]:.3f}  L=4096 {u[2]:.3f}  "
              f"L=11008 {u[3]:.3f}")
    meas = {k: v for k, v in util_rows.items()}
    for (mode, pr, pc, L), u in sorted(meas.items()):
        if L >= 64:
            f = (L // 8) / (L // 8 + pr + pc - 2 + 8 * pc)
            assert abs(u - f) < 1e-12
    print("    (simulated cycles/block match the formula for every GEMM run)")

    print("\n  Effective INT GMAC/s/mm2, 4x4, full config (peak MAC/cycle/tile x util):")
    add, area = tbl[("full (W raw, combiner in grid)", "4x4")]
    mm2 = (area + add) * 1e-6
    for mode, mct in (("INT8", 1), ("W4A8", 2), ("INT4", 4)):
        row = []
        for L in (512, 1024, 4096, 11008):
            u = (L // 8) / (L // 8 + 6 + 32)
            row.append(25.6 * 16 * mct * u / mm2)
        print(f"    {mode}: peak {25.6 * 16 * mct / mm2:7.1f};  L=512 {row[0]:7.1f}  "
              f"L=1024 {row[1]:7.1f}  L=4096 {row[2]:7.1f}  L=11008 {row[3]:7.1f}")

    # ---------------- alternatives, consistent accounting at 4x4 ----------
    # Every scheme pays the A/W edge recoders + Sobol preset (except bit-plane,
    # which bypasses the comparators).  Temporal schemes also need a per-pass
    # digit select at the edge (A: 3-bit 4:1, W raw: 5-bit 2:1) but no combiner.
    # Schemes whose tile holds the WEIGHTED INT8 sum overflow OWIDTH=24 for
    # L > 511 (worst case -128*-128); widening costs per tile and per bit:
    # 1 flop (1.372) + 1 high-segment FA (1.666) + 1 drain AO22 (0.686).
    print("\n  Alternatives at 4x4, INT8, consistent accounting (area added um2, % of grid,"
          " SC GMAC/s/mm2, effective INT8 GMAC/s/mm2):")
    a44 = grid_area(4, 4)
    horner_tile = 24 * (AOI22 + 2 * NAND2 - AO22) + 1.0      # 3rd source, fixed <<2
    ow_bit = DFF2W + FA + AO22
    ow_need = lambda L: int(np.ceil(np.log2(16384 * L + 1))) + 1
    widen = (ow_need(4096) - OWIDTH) * ow_bit                 # for L up to 4096
    sel_a, sel_w = 64 * 3 * (2 * AOI22 + NAND2), 64 * 5 * MXT2
    ring = 32 * 24 * AND2 + 768 * DFF2W
    for wk, wlabel in (("Wc_raw", "W raw at port"), ("Wa_precoded", "W pre-coded")):
        edge = 4 * a_half + 4 * w_half[wk] + sobol_preset
        sel = 4 * sel_a + (4 * sel_w if wk == "Wc_raw" else 0.0)
        alts = [
            ("spatial digits (this), combiner in grid", edge + 4 * comb,
             lambda L: (L / 8) / (L / 8 + 38), 1.5),
            ("spatial digits (this), combine downstream", edge,
             lambda L: (L / 8) / (L / 8 + 38), 1.5),
            ("in-tile x4 Horner, OW=24 (L<=511 only!)", edge + sel + 1024 * horner_tile,
             lambda L: L / (L + 5 + 38), 4.0),
            ("in-tile x4 Horner, OW=28 (L<=4096)", edge + sel + 1024 * (horner_tile + widen),
             lambda L: L / (L + 5 + 38), 4.0),
            ("drain-ring Horner, OW=24 (L<=511 only!)", edge + sel + ring,
             lambda L: L / (L + 6 * 38), 4.0),
            ("drain-ring Horner, OW=28 (L<=4096)", edge + sel + ring + 1024 * widen,
             lambda L: L / (L + 6 * 38), 4.0),
            ("bit-plane all-space, 2/cyc/tile peak", 8 * 1024 * OR2 + 4 * 1150,
             lambda L: 2 * (L / 128) / (L / 128 + 38), 4.0),
        ]
        print(f"   [{wlabel}]")
        for nm, dA, uf, bpm in alts:
            mm = (a44 + dA) * 1e-6
            lmax = 511 if "OW=24" in nm else (4096 if "OW=28" in nm else 1 << 30)
            vals = "  ".join((f"L={L}:{409.6 * uf(L) / mm:6.1f}" if L <= lmax else
                              f"L={L}:   ovf") for L in (511, 1024, 4096, 11008))
            print(f"    {nm:44s} +{dA:7.0f} ({100 * dA / a44:4.2f}%)  SC {409.6 / mm:6.1f}  "
                  f"{vals}  [{bpm} b/MAC]")
    print(f"    (in-tile Horner = {horner_tile:.2f} um2/tile; OWIDTH widening "
          f"{ow_bit:.3f} um2/bit/tile, INT8 needs OW={ow_need(4096)} at L=4096, "
          f"{ow_need(11008)} at L=11008; spatial tiles stay at OW=24 up to L=524,287)")

    print("\n  Operand bandwidth (raw two's-complement bits from memory):")
    for mode, a_bits, w_bits, mpc in (("INT8", 2 * 8 * 8, 4 * 8 * 8, 64),
                                      ("W4A8", 2 * 8 * 8, 8 * 8 * 4, 128),
                                      ("INT4", 4 * 8 * 4, 8 * 8 * 4, 256),
                                      ("SC T=128", 8 * 8 * 9 / 8, 8 * 8 * 9 / 8, 64)):
        pe = a_bits + w_bits
        g44 = 4 * a_bits + 4 * w_bits
        print(f"    {mode:9s} per PE {pe:6.0f} b/cyc = {pe / mpc:5.3f} b/MAC;  "
              f"4x4 {g44:6.0f} b/cyc = {g44 / (16 * mpc):5.3f} b/MAC")

    bos = 15797.404
    print(f"\n  Dedicated BOS INT8 for 1024 MAC/cyc (= 4x4 INT8 peak): 16 x {bos:.0f} = "
          f"{16 * bos:,.0f} um2 = {100 * 16 * bos / a44:.1f}% of 4x4 -> SC "
          f"{409.6 / ((a44 + 16 * bos) * 1e-6):.1f} GMAC/s/mm2")
    return a_half, w_half, sobol_preset, comb, tbl


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()
    check_presets()
    check_value_pairs()
    util = check_gemms(args.quick)
    costs(util)
    print("\nALL CHECKS PASSED")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print(f"\nMODEL CHECK FAILED: {e!r}", file=sys.stderr)
        raise
