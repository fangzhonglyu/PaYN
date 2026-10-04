#!/usr/bin/env python3
"""Red-team INT-mode model for the PaYN CSA PE (no EDA tools, numpy only).

What is modelled, at register level and bit-exact against the RTL:
  * designs/payn/pe_peripheral.sv: held binary/sign registers (load every
    cycle in INT mode) and the unchanged comparator
        bit[k][m] = binary_q[k] > (r[m] ^ MASK(k, m, salt)),
    MASK = (159k + 99m + salt) & 255, salt 0 (A bank) / 128 (W bank).
  * designs/payn/sobol.sv: in INT mode the 16 random_value registers of each
    bank are forced to a compile-time PRESET (one AND2/OR2 per flop D-pin,
    off the comparator path) and then frozen (rng_en = 0).
  * inner_pe_signed_segmented_csa.sv: ungated bit pipes, sign pipes enabled
    by the registered load wave (held high in INT mode), west->east drain.
  * inner_tile_signed_segmented_csa.sv: 128 AND, gate-level PaynPopcount16Csa,
    5 redundant bits XOR lane sign, one -16*N row, 11-bit heap sum, LOW_W=9
    low segment, pending carry/borrow, lazy +-1 high segment, canonical
    acc_out, shift_in priority.  RTL range assertion and an exact shadow
    accumulator per tile (OWIDTH wrap is a hard failure).
  * a P_R x P_C systolic grid (A east, W along columns, edge skew r / c),
    the cross-PE drain chain (8*P_C shifts, zero fill) and a register-level
    east-edge combiner (MSB-first Horner over the drain stream).

INT schedules ("spatial digits": every digit weight gets its own tile row or
column, so the tile never shifts; weights are applied once per output in the
east-edge combiner):
  booth  : one lane = one signed digit product per cycle, unary 2x8 grid.
           radix-4 Booth digit (|d|<=2) on one side, radix-16 (|d|<=8) on the
           other, count = |da|*|dw| <= 16 = M, lane sign = sign(da)^sign(dw).
           INT8 1, W4A8 2, INT4 4 MAC/cycle/tile.
           edge E2 ("comparator-native"): the unchanged comparators make the
           thermometers; the feeder sends per-lane 8-bit codes E_k(|d|).
           edge E1 ("OR injection"): comparators idle (binary_q = 0), the
           thermometer bits are ORed in after the comparator.
  plane  : bit-plane (BISMO-like) with every plane pair in space: each of the
           128 AND slots of a tile is a different k, tile (i, j) = popcount of
           plane i of a and plane j of w, MSB planes negative via the lane
           sign.  INT8 2, W4A8 4, INT4 8 MAC/cycle/tile; needs edge E1.

Everything is checked against numpy integer GEMM; any mismatch, heap range
violation, pending conflict, OWIDTH wrap or combiner overflow raises.

Usage:  python3 sweeps/int_mode/model_red_team_novel.py [--quick] [--search]
"""
from __future__ import annotations

import argparse
import math
import random
import sys
import time

import numpy as np

K, M, NH, NW = 8, 16, 8, 8
LOW_W = 9
SUM_W = LOW_W + 2
SK, SM = 159, 99            # SCRAMBLE_K_STRIDE, SCRAMBLE_M_STRIDE (WIDTH = 8)
SALT_A, SALT_W = 0, 128
CW = 40                     # east-edge combiner register width (bits, signed)


class ModelError(AssertionError):
    pass


MUTATE = set()   # negative tests only: {"ecode", "skew", "nocorr"}


def check(cond, msg):
    if not bool(cond):
        raise ModelError(msg)


# ----------------------------------------------------------- tile datapath --
def _fa(a, b, c):
    return a ^ b ^ c, (a & b) | (a & c) | (b & c)


def popcount16_csa(x):
    """Gate model of PaynPopcount16Csa on the last axis (16 bits, uint8)."""
    b = [x[..., i] for i in range(16)]
    fs, fc = [None] * 11, [None] * 11
    for i in range(5):
        fs[i], fc[i] = _fa(b[3 * i], b[3 * i + 1], b[3 * i + 2])
    fs[5], fc[5] = _fa(fs[0], fs[1], fs[2])
    fs[6], fc[6] = _fa(fs[3], fs[4], b[15])
    fs[7], fc[7] = _fa(fc[0], fc[1], fc[2])
    fs[8], fc[8] = _fa(fc[3], fc[4], fc[5])
    fs[9], fc[9] = _fa(fs[7], fs[8], fc[6])
    fs[10], fc[10] = _fa(fc[7], fc[8], fc[9])
    return fs[5], fs[6], fs[9], fs[10], fc[10]       # s0a s0b s1 s2 s3


def selftest_counter():
    x = np.arange(1 << 16, dtype=np.uint32)
    bits = ((x[:, None] >> np.arange(16)) & 1).astype(np.uint8)
    s0a, s0b, s1, s2, s3 = (v.astype(np.int64) for v in popcount16_csa(bits))
    check(np.array_equal(s0a + s0b + 2 * s1 + 4 * s2 + 8 * s3,
                         bits.sum(1)), "counter model is not a popcount")


def tile_partials(a_bits, a_sg, w_bits, w_sg):
    """Per-tile heap inputs exactly as the CSA tile forms them.

    a_bits [NH,K,M], w_bits [NW,K,M] uint8; signs [NH,K], [NW,K] uint8.
    Returns (rows_sum, corr_row_value, d) with d = exact signed partial."""
    prod = a_bits[:, None, :, :] & w_bits[None, :, :, :]          # [h,v,k,m]
    s0a, s0b, s1, s2, s3 = popcount16_csa(prod)
    n = a_sg[:, None, :] ^ w_sg[None, :, :]                        # [h,v,k]
    row4 = (((s3 ^ n).astype(np.int64) << 3) | ((s2 ^ n).astype(np.int64) << 2)
            | ((s1 ^ n).astype(np.int64) << 1) | (s0a ^ n).astype(np.int64))
    row1 = (s0b ^ n).astype(np.int64)
    rows_sum = (row4 + row1).sum(-1)                               # [h,v]
    neg = n.astype(np.int64).sum(-1)
    if "nocorr" in MUTATE:
        neg = np.zeros_like(neg)
    return rows_sum, neg, rows_sum - 16 * neg


class PE:
    """InnerPESignedSegmentedCsa, register level (8x8 tiles)."""

    def __init__(self, owidth):
        self.ow = owidth
        self.hw = owidth - LOW_W
        self.a_pipe = np.zeros((NH, K, M), np.uint8)
        self.w_pipe = np.zeros((NW, K, M), np.uint8)
        self.a_sg = np.zeros((NH, K), np.uint8)
        self.w_sg = np.zeros((NW, K), np.uint8)
        self.lda_q = 0
        self.ldw_q = 0
        self.low = np.zeros((NH, NW), np.int64)
        self.high = np.zeros((NH, NW), np.int64)
        self.pc = np.zeros((NH, NW), np.int64)
        self.pb = np.zeros((NH, NW), np.int64)
        self.shadow = np.zeros((NH, NW), np.int64)    # exact, for wrap check

    def acc_out(self):
        hn = (self.high - self.pb + self.pc) & ((1 << self.hw) - 1)
        v = (hn << LOW_W) | self.low
        return np.where(v >= (1 << (self.ow - 1)), v - (1 << self.ow), v)

    def outputs(self):
        return (self.a_pipe, self.a_sg, self.lda_q, self.w_pipe, self.w_sg,
                self.ldw_q)

    def step(self, a_in, as_in, lda_in, w_in, ws_in, ldw_in, mac_en, shift_in,
             west_acc, west_shadow):
        out = self.acc_out()
        check(np.array_equal(out, self.shadow),
              f"OWIDTH={self.ow} wrap: canonical acc_out != exact value")
        check(not np.any(self.pc & self.pb), "pending carry and borrow both set")
        acc_in = np.concatenate([west_acc[:, None], out[:, :-1]], 1)
        sh_in = np.concatenate([west_shadow[:, None], self.shadow[:, :-1]], 1)
        rows_sum, neg, d = tile_partials(self.a_pipe, self.a_sg,
                                         self.w_pipe, self.w_sg)
        # 11-bit heap exactly as DW02_tree + final add, then the range rule.
        heap = (rows_sum + ((-16 * neg) % (1 << SUM_W)) + self.low) % (1 << SUM_W)
        low_sum = np.where(heap >= (1 << (SUM_W - 1)), heap - (1 << SUM_W), heap)
        exact = self.low + d
        if mac_en and not shift_in:
            check(np.array_equal(low_sum, exact), "11-bit heap wrapped")
            check(np.all((exact >= -K * M) & (exact < (1 << (LOW_W + 1)))),
                  "RTL range argument violated (low_sum outside [-KM, 2^(LOW_W+1)))")
        nb = (low_sum < 0).astype(np.int64)
        nc = ((low_sum >= 0) & (((low_sum >> LOW_W) & 1) == 1)).astype(np.int64)
        hn = (self.high - self.pb + self.pc) & ((1 << self.hw) - 1)
        if shift_in:
            u = acc_in % (1 << self.ow)
            self.low = u & ((1 << LOW_W) - 1)
            self.high = u >> LOW_W
            self.pc = np.zeros_like(self.pc)
            self.pb = np.zeros_like(self.pb)
            self.shadow = sh_in
        else:
            busy = (self.pc | self.pb) == 1
            self.high = np.where(busy, hn, self.high)
            if mac_en:
                self.low = low_sum & ((1 << LOW_W) - 1)
                self.pc, self.pb = nc, nb
                self.shadow = self.shadow + d
            else:
                self.pc = np.zeros_like(self.pc)
                self.pb = np.zeros_like(self.pb)
        # pipes (bits ungated, signs enabled by the registered load wave)
        if self.lda_q:
            self.a_sg = as_in.copy()
        if self.ldw_q:
            self.w_sg = ws_in.copy()
        self.a_pipe = a_in.copy()
        self.w_pipe = w_in.copy()
        self.lda_q, self.ldw_q = int(lda_in), int(ldw_in)
        return out[:, -1], self.shadow  # east value sampled before the edge


# ------------------------------------------------------------ edge (periph) --
def mask_table(salt):
    k = np.arange(K)[:, None]
    m = np.arange(M)[None, :]
    return (k * SK + m * SM + salt) & 255


class EdgeHalf:
    """One half of sc_pe_peripheral (8 rows/cols x K lanes) plus, for E1,
    the feeder's output register that drives the OR-injection port."""

    def __init__(self, salt):
        self.mask = mask_table(salt)
        self.bin_q = np.zeros((8, K), np.int64)
        self.sg_q = np.zeros((8, K), np.uint8)
        self.inj_q = np.zeros((8, K, M), np.uint8)

    def out(self, r):
        thr = (np.asarray(r)[None, :] ^ self.mask)                  # [K,M]
        cmp = (self.bin_q[:, :, None] > thr[None, :, :]).astype(np.uint8)
        return cmp | self.inj_q, self.sg_q

    def load(self, bin_in, sg_in, inj_in):          # load_a/load_w held high
        self.bin_q = bin_in.astype(np.int64)
        self.sg_q = sg_in.astype(np.uint8)
        self.inj_q = inj_in.astype(np.uint8)


# ------------------------------------------- comparator-native presets (E2) --
# Found by search_preset() (simulated annealing, seconds).  Row bank feeds the
# tile rows (A side, salt 0), column bank the tile columns (W side, salt 128).
PRESETS = {
    # rows carry radix-4 digits, columns radix-16 digits
    "r4rows": dict(row=[184, 112, 109, 173, 159, 27, 142, 93, 253, 44, 148, 40,
                        250, 207, 155, 139],
                   col=[243, 203, 204, 246, 229, 147, 152, 9, 146, 95, 190, 181,
                        96, 91, 75, 37]),
    # rows carry radix-16 digits, columns radix-4 digits
    "r16rows": dict(row=[222, 50, 245, 231, 140, 40, 98, 162, 230, 210, 171, 241,
                         250, 189, 169, 229],
                    col=[139, 92, 120, 87, 27, 6, 224, 234, 96, 84, 79, 234, 201,
                         197, 115, 145]),
}


def ecode_table(r, salt, kind):
    """Per-lane comparator codes E_k(|d|) for a preset (raises if unusable)."""
    thr = np.asarray(r)[None, :] ^ mask_table(salt)
    s = np.sort(thr, 1)
    check(np.all(thr != 255), "a threshold equals 255: |d|max cannot set all bits")
    if kind == "r4":
        check(np.all(s[:, 7] < s[:, 8]), "radix-4 side: no strict 8|8 split")
        return np.stack([np.zeros(K, np.int64), s[:, 8], np.full(K, 255)], 1)
    for y in range(1, 8):
        check(np.all(s[:, 2 * y - 1] < s[:, 2 * y]), "radix-16 side: group tie")
    cols = [np.zeros(K, np.int64)] + [s[:, 2 * y] for y in range(1, 8)] + \
        [np.full(K, 255)]
    return np.stack(cols, 1)


def verify_preset(orient):
    """Exhaustive per-lane check through the real comparator formula."""
    p = PRESETS[orient]
    rk, ck = ("r4", "r16") if orient == "r4rows" else ("r16", "r4")
    Er, Ec = ecode_table(p["row"], SALT_A, rk), ecode_table(p["col"], SALT_W, ck)
    tr = np.asarray(p["row"])[None, :] ^ mask_table(SALT_A)
    tc = np.asarray(p["col"])[None, :] ^ mask_table(SALT_W)
    for k in range(K):
        for x in range(Er.shape[1]):
            for y in range(Ec.shape[1]):
                cnt = int(np.sum((Er[k, x] > tr[k]) & (Ec[k, y] > tc[k])))
                check(cnt == x * y, f"preset {orient}: lane {k} |{x}|x|{y}| -> {cnt}")
    return Er, Ec


def search_preset(salt_pairs, salt_split, seed=0, iters=300000):
    """Simulated annealing for a preset (pairs side = radix-16)."""
    rnd = random.Random(seed)

    def viol(rP, rS):
        v = 0
        for k in range(K):
            tp = [rP[m] ^ ((k * SK + m * SM + salt_pairs) & 255) for m in range(M)]
            ts = [rS[m] ^ ((k * SK + m * SM + salt_split) & 255) for m in range(M)]
            v += sum(t == 255 for t in tp) + sum(t == 255 for t in ts)
            op = sorted(range(M), key=lambda m: tp[m])
            v += sum(tp[op[2 * c + 1]] >= tp[op[2 * c + 2]] for c in range(7))
            os_ = sorted(range(M), key=lambda m: ts[m])
            v += ts[os_[7]] >= ts[os_[8]]
            low = set(os_[:8])
            v += sum(abs((op[2 * c] in low) + (op[2 * c + 1] in low) - 1)
                     for c in range(8))
        return v

    rP = [rnd.randrange(256) for _ in range(M)]
    rS = [rnd.randrange(256) for _ in range(M)]
    cur, T = viol(rP, rS), 2.0
    for _ in range(iters):
        arr = rP if rnd.randrange(2) == 0 else rS
        m = rnd.randrange(M)
        old = arr[m]
        arr[m] = rnd.randrange(256) if rnd.random() < 0.3 else old ^ (1 << rnd.randrange(8))
        new = viol(rP, rS)
        if new <= cur or rnd.random() < math.exp((cur - new) / T):
            cur = new
            if cur == 0:
                return rP, rS
        else:
            arr[m] = old
        T = max(0.05, T * 0.99997)
    return None


# ------------------------------------------------------------- recoders --
def booth_digits(v, n_bits, r_bits):
    """Radix-2**r_bits Booth digits of n_bits two's-complement ints (vector)."""
    v = np.asarray(v, dtype=np.int64)
    u = v & ((1 << n_bits) - 1)

    def bit(i):
        if i < 0:
            return np.zeros_like(u)
        return (u >> min(i, n_bits - 1)) & 1

    out = []
    for d in range(-(-n_bits // r_bits)):
        lo = d * r_bits
        val = bit(lo - 1)
        for t in range(r_bits):
            val = val + (-(1 << t) if t == r_bits - 1 else (1 << t)) * bit(lo + t)
        out.append(val)
    return np.stack(out, -1)


def booth_digits_signmag(s, mag, r_bits):
    """Sign-magnitude operands (mag 0..128): digits of the 8-bit pattern of mag
    with the lane sign flipped by s XOR mag[7]; covers -128..+128."""
    d = booth_digits(mag, 8, r_bits)
    flip = (np.asarray(s) ^ ((np.asarray(mag) >> 7) & 1))[..., None]
    return np.where(flip == 1, -d, d)


KIND_BITS = {"r4": 2, "r16": 4}


# ------------------------------------------------------------ mappings --
def make_cfg(mapping, prec, orient="r4rows", edge="E2"):
    ab, wb = {"int8": (8, 8), "w4a8": (8, 4), "int4": (4, 4)}[prec]
    if mapping == "booth":
        rk, ck = ("r4", "r16") if orient == "r4rows" else ("r16", "r4")
        NP, NQ = -(-ab // KIND_BITS[rk]), -(-wb // KIND_BITS[ck])
        ra, rw = 1 << KIND_BITS[rk], 1 << KIND_BITS[ck]
        kslice = K
    else:
        check(edge == "E1", "bit-plane needs arbitrary per-slot bits: edge E1 only")
        rk = ck = "plane"
        NP, NQ, ra, rw, kslice = ab, wb, 2, 2, K * M
    check(8 % NP == 0 and 8 % NQ == 0, "digit count must divide 8")
    return dict(mapping=mapping, prec=prec, orient=orient, edge=edge, ab=ab, wb=wb,
                rk=rk, ck=ck, NP=NP, NQ=NQ, NI=8 // NP, NJ=8 // NQ, ra=ra, rw=rw,
                kslice=kslice, mac_per_tile=(8 // NP) * (8 // NQ) * kslice / 64)


def side_streams(cfg, X, side, S, E):
    """Edge data for one operand side and one output tile.

    X: rows-side [n_vec, L] (A) or columns-side [n_vec, L] (W transposed).
    Returns bin [S, n_vec/NI.., 8, K], sg, inj arrays per edge-half index."""
    kind = cfg["rk"] if side == "row" else cfg["ck"]
    nd = cfg["NP"] if side == "row" else cfg["NQ"]
    nv = cfg["NI"] if side == "row" else cfg["NJ"]
    nbits = cfg["ab"] if side == "row" else cfg["wb"]
    halves = (X[1] if isinstance(X, tuple) else X).shape[0] // nv
    shape = (S, halves, 8, K)
    binv = np.zeros(shape, np.int64)
    sg = np.zeros(shape, np.uint8)
    inj = np.zeros(shape + (M,), np.uint8)
    if cfg["mapping"] == "booth":
        if isinstance(X, tuple):                       # sign-magnitude input
            s, mag = X
            dig = booth_digits_signmag(s, mag, KIND_BITS[kind])
        else:
            dig = booth_digits(X, nbits, KIND_BITS[kind])       # [nvec, L, nd]
        check(dig.shape[-1] == nd, "digit count mismatch")
        dig = dig.reshape(halves, nv, S, K, nd)                 # L = S*K
        dig = dig.transpose(2, 0, 1, 4, 3).reshape(S, halves, 8, K)  # h=nd*i+p
        mag = np.abs(dig)
        check(mag.max(initial=0) <= (2 if kind == "r4" else 8), "digit range")
        sg[:] = (dig < 0)
        if cfg["edge"] == "E2":
            binv[:] = E[np.arange(K)[None, None, None, :], mag]
        else:
            m = np.arange(M)
            lvl = (m // 8) if kind == "r4" else (m % 8)        # the 2x8 grid
            inj[:] = (mag[..., None] > lvl).astype(np.uint8)
    else:
        u = (X & ((1 << nbits) - 1)).reshape(halves, nv, S, K, M)
        for p in range(nd):
            pl = ((u >> p) & 1).transpose(2, 0, 1, 3, 4)          # [S,halves,nv,K,M]
            inj[:, :, p::nd] = pl.astype(np.uint8)
            sg[:, :, p::nd] = 1 if p == nd - 1 else 0
    return binv, sg, inj


def run_gemm(A, W, cfg, PR=1, PC=1, owidth=24, r_e1=None, a_signmag=None,
             w_signmag=None, tiles_back_to_back=True, verbose=False):
    """Simulate a full GEMM Y = A @ W on a PR x PC grid; returns (Y, cycles)."""
    L0 = A.shape[1] if a_signmag is None else a_signmag[1].shape[1]
    Mr = A.shape[0] if a_signmag is None else a_signmag[1].shape[0]
    N = W.shape[1] if w_signmag is None else w_signmag[1].shape[1]
    NI, NJ, NP, NQ = cfg["NI"], cfg["NJ"], cfg["NP"], cfg["NQ"]
    ks = cfg["kslice"]
    L = -(-L0 // ks) * ks
    pad = L - L0

    def padk(X, axis):
        if pad == 0:
            return X
        w = [(0, 0)] * X.ndim
        w[axis] = (0, pad)
        return np.pad(X, w)

    S = L // ks
    tm_n, tn_n = Mr // (NI * PR), N // (NJ * PC)
    check(tm_n * NI * PR == Mr and tn_n * NJ * PC == N, "GEMM shape must tile the grid")
    if cfg["edge"] == "E2":
        p = PRESETS[cfg["orient"]]
        Er, Ec = verify_preset(cfg["orient"])
        if "ecode" in MUTATE:
            Ec = Ec.copy()
            Ec[3, 5] += 1
        r_row, r_col = p["row"], p["col"]
    else:
        Er = Ec = None
        rng = np.random.default_rng(7)
        r_row = list(rng.integers(0, 256, M)) if r_e1 is None else r_e1
        r_col = list(rng.integers(0, 256, M)) if r_e1 is None else r_e1
    pes = [[PE(owidth) for _ in range(PC)] for _ in range(PR)]
    eh_row = [EdgeHalf(SALT_A) for _ in range(PR)]
    eh_col = [EdgeHalf(SALT_W) for _ in range(PC)]
    Y = np.zeros((Mr, N), dtype=object)
    span = S + PR + PC - 2                     # MAC edges per output tile
    period = span + 8 * PC                     # + drain
    n_tiles = tm_n * tn_n
    E_total = 2 + n_tiles * period
    # precompute per output tile edge streams
    streams = []
    for tm in range(tm_n):
        for tn in range(tn_n):
            if a_signmag is None:
                Xa = padk(A[tm * NI * PR:(tm + 1) * NI * PR].astype(np.int64), 1)
            else:
                Xa = (padk(a_signmag[0][tm * NI * PR:(tm + 1) * NI * PR], 1),
                      padk(a_signmag[1][tm * NI * PR:(tm + 1) * NI * PR], 1))
            if w_signmag is None:
                Xw = padk(W[:, tn * NJ * PC:(tn + 1) * NJ * PC].T.astype(np.int64), 1)
            else:
                Xw = (padk(w_signmag[0][:, tn * NJ * PC:(tn + 1) * NJ * PC].T, 1),
                      padk(w_signmag[1][:, tn * NJ * PC:(tn + 1) * NJ * PC].T, 1))
            streams.append((tm, tn, side_streams(cfg, Xa, "row", S, Er),
                            side_streams(cfg, Xw, "col", S, Ec)))
    zero_b = np.zeros((8, K), np.int64)
    zero_s = np.zeros((8, K), np.uint8)
    zero_i = np.zeros((8, K, M), np.uint8)
    H = [[0] * NI for _ in range(PR)]
    for e in range(1, E_total + 1):
        n, ph = divmod(e - 3, period)       # tile index and phase of edge e
        mac_en = (e >= 3) and ph < span
        shift_in = (e >= 3) and ph >= span
        # feeder values presented in cycle e-1 (captured by the edge at e)
        tau = e - 1

        def fetch(side, idx, extra=0):
            # slice t of tile nn is presented at tau = nn*period + t + idx (skew)
            for nn in (n, n + 1):
                if 0 <= nn < n_tiles:
                    t = tau - nn * period - idx - extra
                    if 0 <= t < S:
                        st = streams[nn][2 if side == "row" else 3]
                        return st[0][t, idx], st[1][t, idx], st[2][t, idx]
            return zero_b, zero_s, zero_i

        # combinational edge outputs (current peripheral state)
        row_out = [eh.out(r_row) for eh in eh_row]
        col_out = [eh.out(r_col) for eh in eh_col]
        outs = [[pe.outputs() for pe in row] for row in pes]
        # drain sampling + combiner (before the edge)
        if shift_in:
            s_idx = ph - span
            g = 8 * PC - 1 - s_idx
            c, v = divmod(g, 8)
            j, q = divmod(v, NQ)
            tm, tn = streams[n][0], streams[n][1]
            for r in range(PR):
                east = pes[r][PC - 1].acc_out()[:, -1]
                for i in range(NI):
                    s_val = sum(int(east[NP * i + pp]) * cfg["ra"] ** pp
                                for pp in range(NP))
                    H[r][i] = s_val if q == NQ - 1 else H[r][i] * cfg["rw"] + s_val
                    check(abs(H[r][i]) < (1 << (CW - 1)), "combiner overflow")
                    if q == 0:
                        Y[tm * NI * PR + NI * r + i, tn * NJ * PC + NJ * c + j] = H[r][i]
        # register updates
        new_east = {}
        for r in range(PR):
            for c in range(PC):
                pe = pes[r][c]
                if c == 0:
                    a_in, as_in = row_out[r]
                    lda = 1
                    w_acc = np.zeros(NH, np.int64)
                    w_sh = np.zeros(NH, np.int64)
                else:
                    a_in, as_in, lda = outs[r][c - 1][0], outs[r][c - 1][1], outs[r][c - 1][2]
                    w_acc = pes[r][c - 1].acc_out()[:, -1]
                    w_sh = pes[r][c - 1].shadow[:, -1]
                if r == 0:
                    w_in, ws_in = col_out[c]
                    ldw = 1
                else:
                    w_in, ws_in, ldw = outs[r - 1][c][3], outs[r - 1][c][4], outs[r - 1][c][5]
                new_east[(r, c)] = (a_in, as_in, lda, w_in, ws_in, ldw, w_acc, w_sh)
        for r in range(PR):
            for c in range(PC):
                a_in, as_in, lda, w_in, ws_in, ldw, w_acc, w_sh = new_east[(r, c)]
                pes[r][c].step(a_in, as_in, lda, w_in, ws_in, ldw, mac_en,
                               shift_in, w_acc, w_sh)
        for r in range(PR):
            eh_row[r].load(*fetch("row", r))
        for c in range(PC):
            eh_col[c].load(*fetch("col", c, 1 if ("skew" in MUTATE and c > 0) else 0))
    # after the last drain every accumulator must be zero
    for row in pes:
        for pe in row:
            check(np.all(pe.acc_out() == 0), "accumulators not zero after drain")
    return Y.astype(np.int64), dict(S=S, span=span, period=period,
                                    edges=E_total, tiles=n_tiles)


# ------------------------------------------------------------- test harness --
def int_range(bits):
    return -(1 << (bits - 1)), (1 << (bits - 1)) - 1


def datasets(cfg, Mr, L, N, rng):
    lo_a, hi_a = int_range(cfg["ab"])
    lo_w, hi_w = int_range(cfg["wb"])
    A = rng.integers(lo_a, hi_a + 1, (Mr, L))
    W = rng.integers(lo_w, hi_w + 1, (L, N))
    A.flat[0], A.flat[-1] = lo_a, hi_a
    W.flat[0], W.flat[-1] = lo_w, hi_w
    alt_a = np.where((np.arange(L) % 2) == 0, hi_a, lo_a)[None, :].repeat(Mr, 0)
    alt_w = np.where((np.arange(L) % 2) == 0, lo_w, hi_w)[:, None].repeat(N, 1)
    return {
        "random": (A, W),
        "all_max": (np.full((Mr, L), hi_a), np.full((L, N), hi_w)),
        "all_min": (np.full((Mr, L), lo_a), np.full((L, N), lo_w)),
        "alt_sign": (alt_a, alt_w),
        "min_x_max": (np.full((Mr, L), lo_a), np.full((L, N), hi_w)),
    }


def run_case(cfg, PR, PC, L, data, label, log):
    A, W = data
    t0 = time.time()
    Y, info = run_gemm(A, W, cfg, PR, PC)
    ref = A.astype(np.int64) @ W.astype(np.int64)
    if not np.array_equal(Y, ref):
        bad = np.argwhere(Y != ref)[:4]
        raise ModelError(f"MISMATCH {label}: {[(tuple(b), Y[tuple(b)], ref[tuple(b)]) for b in bad]}")
    log.append((cfg["mapping"], cfg["edge"], cfg["orient"], cfg["prec"], f"{PR}x{PC}", L,
                label, A.shape[0], W.shape[1], info["tiles"], info["period"],
                f"{time.time() - t0:.1f}s"))


def utilization_table():
    print("\nEffective INT MAC/cycle/tile incl. systolic skew and drain "
          "(per output tile: S slices + (PR-1)+(PC-1) skew + 8*PC drain)")
    print("  peak: booth INT8/W4A8/INT4 = 1/2/4, plane = 2/4/8; "
          "booth S = L/8, plane S = L/128; SC S = L (1 k/cycle/output)")
    grids = [(1, 1), (4, 4), (4, 8)]
    Ls = [128, 512, 1024, 4096, 11008, 16384]
    head = "  mode            grid " + "".join(f"{'L=' + str(x):>9s}" for x in Ls)
    print(head)
    rows = [("SC (ref)", 1, 1), ("booth INT8", 1, 8), ("plane INT8", 2, 128),
            ("booth W4A8", 2, 8), ("plane W4A8", 4, 128), ("booth INT4", 4, 8),
            ("plane INT4", 8, 128)]
    for name, peak, kap in rows:
        for PR, PC in grids:
            ov = (PR - 1) + (PC - 1) + 8 * PC
            vals = []
            for L in Ls:
                S = -(-L // kap)
                vals.append(peak * S / (S + ov))
            print(f"  {name:15s} {PR}x{PC:<3d}" + "".join(f"{v:9.3f}" for v in vals))


def cost_and_compare():
    c = dict(OR2=0.392, AND2=0.392, NAND2=0.294, NOR2=0.294, XOR2=0.588,
             AO21=0.588, AO22=0.686, MXT2=0.784, FA=1.666, HA=0.980, DFF=1.372,
             INV=0.196)
    A1 = 43965.152; A1r = 44017.974; A44 = 521892.140; A48 = 1016043.420
    print("\nArea (LEF cell areas; composite = P_R*P_C*u_pe + (P_R+P_C)*periph/2 + Sobol pair)")
    preset = 2 * (128 * c["AND2"] + c["OR2"])
    r4 = 2 * c["XOR2"] + c["AND2"] + c["OR2"] + c["NAND2"] + c["AND2"]   # Booth-4
    # |d| (4 XOR2), sign, per-lane 9x8 code table: 9.6 um2 (a QM-style estimate on
    # the real r4rows tables gives 11.9 with E=s[2y], 8.6 with codes chosen
    # inside their intervals)
    r16 = 4 * c["XOR2"] + (c["NAND2"] + c["AND2"]) + 9.6
    portmux = 576 * c["AO22"]
    feed_r4 = 64 * r4 + portmux
    feed_r16 = 64 * r16 + portmux
    comb_group = 128 * c["FA"] + 32 * c["DFF"]       # 5-input 32b CSA+CPA + H reg
    comb_row = 2 * comb_group * 1.10                  # +10% precision muxing
    or_inj = 1024 * c["OR2"]
    print(f"  Sobol preset (2 banks x 128 random_value D-pins, AND2/OR2 + enable OR2): "
          f"{preset:.1f} um2 per grid")
    print(f"  feeder radix-4 half : 64 x {r4:.3f} (Booth-4 recoder) + 576 x AO22 port mux "
          f"{portmux:.1f} = {feed_r4:.1f}")
    print(f"  feeder radix-16 half: 64 x {r16:.3f} (|d|, sign, 9x8 per-lane E table) + "
          f"{portmux:.1f} = {feed_r16:.1f}")
    print(f"  east combiner per PE row: 2 x (128 FA + 32 DFF) x 1.10 = {comb_row:.1f}")
    print(f"  [E1 alternative] OR injection per edge half: 1024 x OR2 = {or_inj:.1f}")
    for name, Ag, PR, PC, r16_on_rows in [("1x1", A1r, 1, 1, False),
                                           ("4x4", A44, 4, 4, False),
                                           ("4x8", A48, 4, 8, True)]:
        if r16_on_rows:
            feed = PR * feed_r16 + PC * feed_r4
        else:
            feed = PR * feed_r4 + PC * feed_r16
        comb = PR * comb_row
        tot = preset + feed + comb
        sc_eff = PR * PC * 25.6 / (Ag * 1e-6)
        print(f"  {name}: inside composite {preset:8.1f} ({100 * preset / Ag:.3f}%), "
              f"feeder {feed:8.1f}, combiner {comb:7.1f}, all-in {tot:8.1f} "
              f"({100 * tot / Ag:.2f}%)  SC eff {sc_eff:.2f} -> "
              f"{sc_eff * Ag / (Ag + preset):.2f} (composite) GMAC/s/mm2")
        for prec, mac in [("INT8", 1), ("W4A8", 2), ("INT4", 4)]:
            g = PR * PC * 64 * mac * 0.4
            print(f"      {prec}: peak {g:7.1f} GMAC/s, {g / ((Ag + tot) * 1e-6):7.1f} "
                  f"GMAC/s/mm2 all-in")
    bos = 15797.404
    print("\nDedicated BOS INT8 sized for the same INT8 throughput as booth INT8 on 4x4 "
          f"(1024 MAC/cycle): 16 x {bos:.1f} = {16 * bos:,.0f} um2 = "
          f"{100 * 16 * bos / A44:.1f}% of the 4x4 grid (vs this mode all-in "
          f"~{100 * (preset + 4 * feed_r4 + 4 * feed_r16 + 4 * comb_row) / A44:.2f}%)")
    for f in (0.05, 0.1, 0.3):
        conc = 1 / ((1 - f) / 784.84 + f / 1620.5)
        seq_int = 784.84 / (1 + (preset + 4 * feed_r4 + 4 * feed_r16 + 4 * comb_row) / A44) \
            / ((1 - f) + f / 0.931)
        seq_bos = max(1 / (((1 - f) + f / r) * (1 / 784.84 + r / 1620.5))
                      for r in np.linspace(0.01, 2.0, 400))
        print(f"  INT fraction f={f:.2f}: SC grid + perfectly concurrent BOS (balanced) "
              f"{conc:6.1f} GMAC/s/mm2; SC grid + best-sized BOS, layers sequential "
              f"{seq_bos:6.1f}; INT mode on the grid (L=4096 util 0.931) {seq_int:6.1f}")


def bounds_table():
    print("\nSlot bound (unchanged tile: 8 lanes x 16 AND slots, one sign per lane, "
          "one weight per tile)")
    print("  one-product-per-lane Booth radix (2^ra, 2^rw): lane needs "
          "2^(ra-1)*2^(rw-1) <= 16 slots")
    for ra in range(1, 6):
        for rw in range(ra, 6):
            need = (1 << (ra - 1)) * (1 << (rw - 1))
            if need > 16:
                continue
            pairs = (-(-8 // ra)) * (-(-8 // rw))
            print(f"    ra={ra} rw={rw}: {need:2d} slots/lane, {pairs:2d} pairs/MAC "
                  f"-> INT8 {8 / pairs:.3f} MAC/cycle/tile")
    print("  bit-plane: 64 plane pairs x 1 slot = 64 slots per INT8 MAC -> 128/64 = "
          "2 MAC/cycle/tile (every slot is one distinct bit product: the ceiling)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--search", action="store_true")
    args = ap.parse_args()
    if args.search:
        for name, (sp, ss) in {"r4rows": (SALT_W, SALT_A),
                               "r16rows": (SALT_A, SALT_W)}.items():
            print(name, search_preset(sp, ss))
        return
    selftest_counter()
    print("counter: gate model == popcount for all 65,536 patterns")
    for o in PRESETS:
        Er, Ec = verify_preset(o)
        print(f"preset {o}: every lane gives count == |x|*|y| through the "
              f"unchanged comparator (row codes {Er.shape[1]} levels, col codes "
              f"{Ec.shape[1]} levels)")
    rng = np.random.default_rng(20261003)
    log = []
    Ls = [8, 64, 1024] if not args.quick else [8, 64]
    # ---- booth, comparator-native edge (the proposed mode) ----
    for prec in ("int8", "w4a8", "int4"):
        cfg = make_cfg("booth", prec, "r4rows", "E2")
        for L in Ls:
            for label, data in datasets(cfg, cfg["NI"], L, cfg["NJ"], rng).items():
                run_case(cfg, 1, 1, L, data, label, log)
        Mr, N = cfg["NI"] * 2 * 2, cfg["NJ"] * 3     # 2x3 grid, 2 output tiles
        for label, data in datasets(cfg, Mr, 64, N, rng).items():
            run_case(cfg, 2, 3, 64, data, label, log)
    cfg = make_cfg("booth", "int8", "r16rows", "E2")
    for label, data in datasets(cfg, cfg["NI"] * 2, 256, cfg["NJ"] * 2, rng).items():
        run_case(cfg, 2, 2, 256, data, label, log)
    if not args.quick:
        cfg = make_cfg("booth", "int8", "r4rows", "E2")
        run_case(cfg, 4, 4, 256, datasets(cfg, cfg["NI"] * 4, 256, cfg["NJ"] * 4,
                                          rng)["random"], "random", log)
        run_case(cfg, 2, 2, 4096, datasets(cfg, cfg["NI"] * 2, 4096, cfg["NJ"] * 2,
                                           rng)["all_min"], "all_min", log)
    # ---- booth, OR-injection edge ----
    cfg = make_cfg("booth", "int8", "r4rows", "E1")
    for label, data in datasets(cfg, cfg["NI"] * 2, 1024 if not args.quick else 64,
                                cfg["NJ"] * 2, rng).items():
        run_case(cfg, 2, 2, 1024 if not args.quick else 64, data, label, log)
    # ---- sign-magnitude native INT8 (values -128..+128) ----
    cfg = make_cfg("booth", "int8", "r4rows", "E2")
    for L in (64, 1024) if not args.quick else (64,):
        sa = rng.integers(0, 2, (2, L)); ma = rng.integers(0, 129, (2, L))
        sw = rng.integers(0, 2, (L, 4)); mw = rng.integers(0, 129, (L, 4))
        ma[:, :4] = 128; mw[:4, :] = 128; sa[0, :2] = 0; sw[:2, 0] = 0  # +128 too
        Av = np.where(sa == 1, -ma, ma); Wv = np.where(sw == 1, -mw, mw)
        Y, _ = run_gemm(Av, Wv, cfg, 1, 1, a_signmag=(sa, ma), w_signmag=(sw, mw))
        check(np.array_equal(Y, Av @ Wv), "sign-magnitude mismatch")
        log.append(("booth", "E2", "r4rows", "int8", "1x1", L, "signmag+-128", 2, 4,
                    1, "-", "-"))
    # ---- bit-plane, all plane pairs in space (E1 edge) ----
    for prec in ("int8", "w4a8", "int4"):
        cfg = make_cfg("plane", prec, "r4rows", "E1")
        for L in ([8, 128, 1024] if not args.quick else [8, 128]):
            for label, data in datasets(cfg, cfg["NI"], L, cfg["NJ"], rng).items():
                run_case(cfg, 1, 1, L, data, label, log)
        for label, data in datasets(cfg, cfg["NI"] * 2 * 2, 256, cfg["NJ"] * 2,
                                    rng).items():
            run_case(cfg, 2, 2, 256, data, label, log)
    print(f"\n{len(log)} GEMM runs, all bit-exact vs numpy:")
    print("  mapping edge orient  prec grid      L case          M   N tiles period")
    for r in log:
        print(f"  {r[0]:6s}  {r[1]:3s} {r[2]:7s} {r[3]:4s} {r[4]:4s} {r[5]:6d} {r[6]:13s} "
              f"{r[7]:3d} {r[8]:3d} {r[9]:5} {r[10]:>6}")
    # ---- negative tests: the checks must fire ----
    cfg = make_cfg("booth", "int8", "r4rows", "E2")
    A = np.full((2, 4096), -128); W = np.full((4096, 4), -128)
    try:
        run_gemm(A, W, cfg, 1, 1, owidth=14)
        raise SystemExit("negative test failed: OWIDTH=14 overflow not detected")
    except ModelError as e:
        print(f"\nnegative test OK (OWIDTH=14, all -128, L=4096): {e}")
    saved = PRESETS["r4rows"]["col"]
    PRESETS["r4rows"]["col"] = [(0x9D ^ ((0x2B * m) & 255)) for m in range(M)]
    try:
        verify_preset("r4rows")
        raise SystemExit("negative test failed: Sobol reset state accepted as preset")
    except ModelError as e:
        print(f"negative test OK (Sobol reset state instead of preset): {e}")
    finally:
        PRESETS["r4rows"]["col"] = saved
    for mut in ("ecode", "skew", "nocorr"):
        MUTATE.clear()
        MUTATE.add(mut)
        cfg = make_cfg("booth", "int8", "r4rows", "E2")
        A, W = datasets(cfg, cfg["NI"] * 2, 64, cfg["NJ"] * 2, rng)["random"]
        try:
            Y, _ = run_gemm(A, W, cfg, 2, 2)
            check(np.array_equal(Y, A @ W), f"mutation {mut}: GEMM mismatch")
            raise SystemExit(f"negative test failed: mutation {mut} not detected")
        except ModelError as e:
            print(f"negative test OK (mutation {mut}): {e}")
    MUTATE.clear()
    bounds_table()
    utilization_table()
    cost_and_compare()


if __name__ == "__main__":
    main()
