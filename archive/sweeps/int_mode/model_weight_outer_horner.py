#!/usr/bin/env python3
"""Weight-outer Horner INT mode on the PaYN CSA PE: bit-exact register model.

No EDA tools.  Models, edge by edge, the RTL of
  designs/payn/pe_peripheral.sv                       (held regs + comparators)
  designs/payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv
  designs/payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv
with K=8, M=16, N_H=N_W=8, OWIDTH=24, LOW_W=9 (the routed configuration), in a
P_R x P_C systolic grid (A hops east, W hops north, feed skewed by r and c).

INT mode as modelled (the proposal of this angle)
-------------------------------------------------
* Encoding.  a (two's complement) -> radix-4 Booth digits d_a[p] in [-2,2];
  w -> radix-16 Booth digits d_w[q] in [-8,8].  INT8: 4 x 2 digit pairs,
  W4A8: 4 x 1, INT4: 2 x 1.  a*w = sum_{p,q} 2**(2p+4q) d_a[p] d_w[q].
* Lanes.  Tile (h,v) = output (row h, column v), as in SC.  Each cycle lane k
  carries ONE digit pair (p,q) of reduction index k:
      count[k] = popcount(a_bits[k][m] & w_bits[k][m]) = |d_a[p]| * |d_w[q]|
      sign[k]  = a_sign[k] ^ w_sign[k]           = (d_a<0) ^ (d_w<0)
  so the unchanged tile adds sum_k d_a[p] d_w[q] (|.| <= 128 per cycle, the
  same range as SC, so LOW_W=9 + pending carry/borrow stay valid).
* Bits come from the UNCHANGED comparators.  In INT mode the shared 16x8-bit
  random-value bus of each side is forced to a constant PRESET (found by
  search, verified exhaustively below).  With the compile-time scramble masks
  the per-(side,k) thresholds then rank the 16 positions so that
      A code for |d_a| = 0,1,2 -> ones on {}, R0_k (8 positions), all 16
      W code for |d_w| = c     -> ones on the first c "pairs" of W's ranking,
  and every W pair holds one R0_k and one non-R0_k position.  Hence
  |A & W| = |d_a| * |d_w| exactly.  The data mover writes per-(side,k) 8-bit
  codes (CODE_A[k][|d|], CODE_W[k][|d|]) into the existing a/w_binary_in
  ports and the digit sign into a/w_signs_in, every cycle (load_a/load_w and
  load_*_sign held high).
* Order: weight-outer.  Every pass streams the whole reduction chunk with one
  digit pair (p,q).  Between passes of different weight, a per-PE "drain
  ring" multiplies every accumulator by 4 with no tile change:
      acc_chain[0][h] = ring_q ? {acc_out_east[h][21:0], 2'b00} : acc_in_west[h]
      tile shift_in   = shift_in | ring_q
  8 ring edges move every canonical accumulator once around the row and
  through the x4 wiring, so each tile ends up holding 4x its value (pending
  carry/borrow is folded by the canonical acc_out and cleared by the shift,
  exactly like a drain).  ring_q is one flop per PE that travels east with
  the A operands (like load_a_sign_q), so each PE rotates on the 8 idle
  slots of its own skewed stream: no grid-skew bubble per rotation.
* Variants (all use the same hardware):
    FH  full MSB-first Horner: passes sorted by weight 10,8,6,6,4,4,2,0;
        5 rotations, 1 drain per chunk; tile holds full products, so the
        chunk is limited to 511 INT8 MACs per output (OW24).
    HY  Horner over the A digits inside a W-digit segment, one drain per W
        digit (2 for INT8, 1 for W4A8/INT4); tile holds sum a*d_w (<= 1024
        per MAC) -> chunk <= 8191; the east-edge collector adds X_q << 4q.
    HYS same as HY but the W digit sits in space: tile column v carries
        weight v//n_w, digit q = v%n_w (PE = 8 activations x 4 weights for
        INT8); one segment, 3 rotations, 1 drain; the pair (j,1),(j,0)
        leaves on consecutive drain edges and the collector forms
        X1<<4 + X0 (a 1-deep hold + adder, no output read-modify-write).
        Same cycles per MAC as HY.
    GD  no rotation at all: one drain per weight group, collector shifts.
    LSB the user's "shift the result down": LSB-first, the ring wiring is
        an arithmetic >>2 and the 2 emitted bits per tile per rotation go to
        a per-PE emitted-bit buffer; tile holds result >> 10.
* East-edge collector: samples acc_out_east of the last PE column on each
  global drain edge (before the shift) and accumulates out += value << shift
  in wide (Python int) precision; chunks are accumulated the same way.

Checks: every edge, every tile, the canonical {high_next, acc_low} must equal
an independent shadow value computed from the digits (catches any datapath,
sign, -16N, pending, ring, or OW24 wrap error), |shadow| < 2**23, low_sum in
the RTL range, no pending carry+borrow; final output == numpy int64 GEMM.
Any failure raises ModelError.

Usage: python3 sweeps/int_mode/model_weight_outer_horner.py [--quick]
"""
from __future__ import annotations

import argparse
import itertools
import math
import sys
import time

import numpy as np

# ------------------------------------------------------------ parameters --
K, M, NH, NW = 8, 16, 8, 8
WIDTH, OWIDTH, LOW_W = 8, 24, 9
SUM_W, HIGH_W = LOW_W + 2, OWIDTH - LOW_W
LEVELS = 1 << WIDTH
SK = (LEVELS * 79 // 128) | 1          # SCRAMBLE_K_STRIDE = 159
SM = (LEVELS * 49 // 128) | 1          # SCRAMBLE_M_STRIDE = 99
SALT_A, SALT_W = 0, 1 << (WIDTH - 1)   # payn_array_signed_segmented_csa.sv
OMIN, OMAX = -(1 << (OWIDTH - 1)), (1 << (OWIDTH - 1)) - 1

# INT-mode constants forced onto the shared random-value buses (lane m).
PRESET_A = [70, 33, 70, 10, 131, 227, 62, 107, 131, 35, 223, 203, 45, 0, 158, 133]
PRESET_W = [86, 214, 211, 157, 137, 29, 123, 218, 23, 200, 76, 227, 24, 69, 155, 223]

MODES = {
    # a_bits/w_bits: operand width; n_a radix-4 A digits; n_w radix-16 W digits
    "INT8": dict(a_bits=8, w_bits=8, n_a=4, n_w=2),
    "W4A8": dict(a_bits=8, w_bits=4, n_a=4, n_w=1),
    "INT4": dict(a_bits=4, w_bits=4, n_a=2, n_w=1),
}


class ModelError(AssertionError):
    pass


def check(cond, msg):
    if not cond:
        raise ModelError(msg)


# ---------------------------------------------------- edge comparators ----
def thresholds(preset, salt):
    """thr[k][m] = preset[m] ^ MASK(k,m): pe_peripheral.sv scrambled_random."""
    return np.array([[preset[m] ^ ((k * SK + m * SM + salt) & (LEVELS - 1))
                      for m in range(M)] for k in range(K)], dtype=np.int64)


def derive_codes(thr_a, thr_w):
    """Per-(side,k) 8-bit operand codes; verified through the comparator."""
    code_a = np.zeros((K, 3), dtype=np.int64)
    code_w = np.zeros((K, 9), dtype=np.int64)
    for k in range(K):
        ta, tw = np.sort(thr_a[k]), np.sort(thr_w[k])
        check(ta[7] < ta[8], f"A k={k}: no strict 8/8 split")
        check(ta[15] < LEVELS - 1 and tw[15] < LEVELS - 1,
              f"k={k}: a threshold equals 255, all-ones code impossible")
        code_a[k] = [0, ta[7] + 1, ta[15] + 1]
        for c in range(1, 9):
            code_w[k, c] = tw[2 * c - 1] + 1
            if c < 8:
                check(tw[2 * c - 1] < tw[2 * c], f"W k={k}: tie across pair {c}")
    for k in range(K):
        for x in range(3):
            abits = code_a[k, x] > thr_a[k]
            for y in range(9):
                wbits = code_w[k, y] > thr_w[k]
                check(int(np.sum(abits & wbits)) == x * y,
                      f"k={k}: |A&W| != {x}*{y} through the comparators")
    return code_a, code_w


THR_A = thresholds(PRESET_A, SALT_A)
THR_W = thresholds(PRESET_W, SALT_W)
CODE_A, CODE_W = derive_codes(THR_A, THR_W)


# --------------------------------------------------------------- booth ----
def booth_digits(v, n_bits, r_bits):
    """Radix-2**r_bits Booth digits (last axis) of n_bits two's complement."""
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
            wgt = 1 << t
            val = val + (-wgt if t == r_bits - 1 else wgt) * bit(lo + t)
        out.append(val)
    return np.stack(out, axis=-1)


# --------------------------------------------------------- tile pieces ----
def fa(x, y, z):
    return x ^ y ^ z, (x & y) | (x & z) | (y & z)


def popcount16_csa(b):
    """Gate model of PaynPopcount16Csa on (..., 16) 0/1 arrays."""
    fs, fc = [None] * 11, [None] * 11
    for i in range(5):
        fs[i], fc[i] = fa(b[..., 3 * i], b[..., 3 * i + 1], b[..., 3 * i + 2])
    fs[5], fc[5] = fa(fs[0], fs[1], fs[2])
    fs[6], fc[6] = fa(fs[3], fs[4], b[..., 15])
    fs[7], fc[7] = fa(fc[0], fc[1], fc[2])
    fs[8], fc[8] = fa(fc[3], fc[4], fc[5])
    fs[9], fc[9] = fa(fs[7], fs[8], fc[6])
    fs[10], fc[10] = fa(fc[7], fc[8], fc[9])
    return fs[5], fs[6], fs[9], fs[10], fc[10]


def to_signed(x, bits):
    x = np.asarray(x, dtype=np.int64) & ((1 << bits) - 1)
    return x - (((x >> (bits - 1)) & 1) << bits)


# ------------------------------------------------------------ schedule ----
def weight(p, q):
    """Bit weight of digit pair (p,q); q=None: W digit lives in space (HYS)."""
    return 2 * p + (0 if q is None else 4 * q)


def plan(mode, variant):
    """Segments: list of dict(base, passes=[(p,q)...], dir='L'|'R')."""
    n_a, n_w = MODES[mode]["n_a"], MODES[mode]["n_w"]
    pairs = [(p, q) for p in range(n_a) for q in range(n_w)]
    if variant == "FH":
        return [dict(base=0, dir="L",
                     passes=sorted(pairs, key=lambda pq: (-weight(*pq), pq)))]
    if variant == "HY":
        return [dict(base=4 * q, dir="L",
                     passes=[(p, q) for p in reversed(range(n_a))])
                for q in reversed(range(n_w))]
    if variant == "HYS":   # A digits weight-outer in time, W digits in space
        return [dict(base=0, dir="L", wspace=True,
                     passes=[(p, None) for p in reversed(range(n_a))])]
    if variant == "GD":
        ws = sorted({weight(*pq) for pq in pairs}, reverse=True)
        return [dict(base=w, dir="L",
                     passes=[pq for pq in pairs if weight(*pq) == w]) for w in ws]
    if variant == "LSB":
        return [dict(base=0, dir="R",
                     passes=sorted(pairs, key=lambda pq: (weight(*pq), pq)))]
    raise ValueError(variant)


def chunk_limit(mode, variant):
    """Largest reduction chunk whose worst case keeps every register state
    inside signed OWIDTH (all lanes carrying the worst (a, w))."""
    if variant == "HYS":
        return chunk_limit(mode, "HY")
    cfg = MODES[mode]
    av = np.arange(-(1 << (cfg["a_bits"] - 1)), 1 << (cfg["a_bits"] - 1))
    wv = np.arange(-(1 << (cfg["w_bits"] - 1)), 1 << (cfg["w_bits"] - 1))
    dA = booth_digits(av, cfg["a_bits"], 2)[:, None, :]
    dW = booth_digits(wv, cfg["w_bits"], 4)[None, :, :]
    worst = 1
    for seg in plan(mode, variant):
        ps = seg["passes"]
        if seg["dir"] == "L":
            acc = 0
            for j, (p, q) in enumerate(ps):
                if j:
                    acc = acc * (1 << (weight(*ps[j - 1]) - weight(p, q)))
                    worst = max(worst, int(np.max(np.abs(acc))))
                acc = acc + dA[..., p] * dW[..., q]
                worst = max(worst, int(np.max(np.abs(acc))))
        else:   # register = floor(sum / 4**n); bound by |sum|/4**n + 1
            acc, base = 0, weight(*ps[0])
            for j, (p, q) in enumerate(ps):
                acc = acc + dA[..., p] * dW[..., q] * (1 << (weight(p, q) - base))
                scale = 1 << (weight(p, q) - base)
                worst = max(worst, math.ceil(int(np.max(np.abs(acc))) / scale) + 1)
    return OMAX // worst


def build_schedule(mode, variant, k_total, pr, pc, chunk=None):
    """Slot stream (slot s is loaded into PE row r's edge at edge s+r and PE
    column c's edge at edge s+c) plus global drain edges."""
    segs = plan(mode, variant)
    chunk = chunk or chunk_limit(mode, variant)
    slots, drains = [], []
    for lo in range(0, k_total, chunk):
        hi = min(lo + chunk, k_total)
        cyc = -(-(hi - lo) // K)
        for seg in segs:
            ps, nrot_total = seg["passes"], 0
            for j, (p, q) in enumerate(ps):
                if j:
                    nrot = abs(weight(*ps[j - 1]) - weight(p, q)) // 2
                    nrot_total += nrot
                    slots += [("ring",)] * (NW * nrot)
                slots += [("mac", p, q, lo, hi, t) for t in range(cyc)]
            s_last = len(slots) - 1
            d1 = s_last + pr + pc + 1
            drains.append(dict(first=d1, n=NW * pc, seg=seg, nrot=nrot_total))
            slots += [("idle",)] * (pr + pc + NW * pc - 2)
    return slots, drains


# ---------------------------------------------------------------- grid ----
class Grid:
    def __init__(self, pr, pc, ring_dir):
        self.pr, self.pc, self.dir = pr, pc, ring_dir
        z = lambda *s: np.zeros(s, dtype=np.int64)
        # edge peripherals (held registers, async reset to 0)
        self.a_code_q, self.a_sign_q, self.a_dig_q = z(pr, NH, K), z(pr, NH, K), z(pr, NH, K)
        self.w_code_q, self.w_sign_q, self.w_dig_q = z(pc, NW, K), z(pc, NW, K), z(pc, NW, K)
        # PE registers
        self.ld_a_q, self.ld_w_q, self.ring_q = z(pr, pc), z(pr, pc), z(pr, pc)
        self.a_bits_p, self.w_bits_p = z(pr, pc, NH, K, M), z(pr, pc, NW, K, M)
        self.a_sign_p, self.w_sign_p = z(pr, pc, NH, K), z(pr, pc, NW, K)
        self.a_dig_p, self.w_dig_p = z(pr, pc, NH, K), z(pr, pc, NW, K)   # shadow
        # tiles
        self.acc_low, self.acc_high = z(pr, pc, NH, NW), z(pr, pc, NH, NW)
        self.pend_c, self.pend_b = z(pr, pc, NH, NW), z(pr, pc, NH, NW)
        self.shadow = z(pr, pc, NH, NW)                                   # golden
        self.ring_step = z(pr, pc)            # consecutive ring edges (mod 8)
        self.emitted = {}                     # (r,c,h,v) -> list of 2-bit digits
        self.max_abs = 0
        self.max_low_sum = (0, 0)

    def acc_out(self):
        high_next = (self.acc_high + self.pend_b * ((1 << HIGH_W) - 1)
                     + self.pend_c) & ((1 << HIGH_W) - 1)
        return to_signed((high_next << LOW_W) | self.acc_low, OWIDTH)

    def step(self, inp):
        pr, pc = self.pr, self.pc
        # ---------------------------------------------------- combinational
        out = self.acc_out()
        check(np.array_equal(out, self.shadow),
              f"edge {inp['edge']}: canonical acc != shadow at "
              f"{np.argwhere(out != self.shadow)[:3].tolist()} "
              f"(datapath error or OW{OWIDTH} wrap)")
        check(np.all(np.abs(self.shadow) <= OMAX), "OWIDTH overflow of shadow")
        check(not np.any(self.pend_c & self.pend_b), "pending carry and borrow both set")
        self.max_abs = max(self.max_abs, int(np.max(np.abs(self.shadow))))

        a_cmp = (self.a_code_q[..., None] > THR_A[None, None]).astype(np.int64)
        w_cmp = (self.w_code_q[..., None] > THR_W[None, None]).astype(np.int64)

        low_sum = np.zeros((pr, pc, NH, NW), dtype=np.int64)
        d_true = np.zeros_like(low_sum)
        for r in range(pr):
            for c in range(pc):
                prod = self.a_bits_p[r, c][:, None] & self.w_bits_p[r, c][None]
                s0a, s0b, s1, s2, s3 = popcount16_csa(prod)          # (NH,NW,K)
                neg = self.a_sign_p[r, c][:, None] ^ self.w_sign_p[r, c][None]
                row4 = (s0a ^ neg) + 2 * (s1 ^ neg) + 4 * (s2 ^ neg) + 8 * (s3 ^ neg)
                row1 = s0b ^ neg
                ncnt = neg.sum(-1)
                corr = (-16 * ncnt) & ((1 << SUM_W) - 1)            # SUM_W'(-16N)
                lanes = row4.sum(-1) + row1.sum(-1)
                heap = (lanes + corr + self.acc_low[r, c]) & ((1 << SUM_W) - 1)
                ls = to_signed(heap, SUM_W)                          # DW02 + CPA
                true = lanes - 16 * ncnt + self.acc_low[r, c]
                check(np.all((true >= -K * M) & (true <= (1 << (LOW_W + 1)) - 1)),
                      "low_sum outside the RTL range [-K*M, 2**(LOW_W+1)-1]")
                check(np.array_equal(ls, true), "SUM_W heap wrap")
                low_sum[r, c] = ls
                d_true[r, c] = (self.a_dig_p[r, c][:, None]
                                * self.w_dig_p[r, c][None]).sum(-1)
                self.max_low_sum = (min(self.max_low_sum[0], int(ls.min())),
                                    max(self.max_low_sum[1], int(ls.max())))
        next_b = (low_sum < 0).astype(np.int64)
        next_c = (1 - next_b) * ((low_sum >> LOW_W) & 1)

        # chain inputs (acc_in of each tile, and its shadow)
        acc_in = np.zeros_like(out)
        sh_in = np.zeros_like(out)
        acc_in[..., 1:] = out[..., :-1]
        sh_in[..., 1:] = self.shadow[..., :-1]
        east, sh_east = out[..., NW - 1], self.shadow[..., NW - 1]   # (pr,pc,NH)
        west = np.zeros((pr, pc, NH), dtype=np.int64)
        sh_west = np.zeros_like(west)
        west[:, 1:] = east[:, :-1]
        sh_west[:, 1:] = sh_east[:, :-1]
        ring = self.ring_q[..., None].astype(bool)
        if self.dir == "L":
            ring_val = to_signed(east << 2, OWIDTH)       # {east[21:0], 2'b00}
            sh_ring = sh_east * 4
        else:
            ring_val = east >> 2                           # {2{east[23]}, east[23:2]}
            sh_ring = sh_east >> 2
        acc_in[..., 0] = np.where(ring, ring_val, west)
        sh_in[..., 0] = np.where(ring, sh_ring, sh_west)

        # emitted bits of the LSB-first variant (per-PE buffer)
        if self.dir == "R":
            for r, c in zip(*np.nonzero(self.ring_q)):
                v = NW - 1 - int(self.ring_step[r, c])
                for h in range(NH):
                    check((int(east[r, c, h]) & 3) == (int(sh_east[r, c, h]) & 3),
                          "emitted bits mismatch")
                    self.emitted.setdefault((r, c, h, v), []).append(int(east[r, c, h]) & 3)

        # collector sample (east column of the last PE column, before shift)
        sample = out[:, pc - 1, :, NW - 1].copy() if inp["shift_in"] else None

        # -------------------------------------------------------- registers
        mac_en = inp["mac_en"]
        shift_local = (inp["shift_in"] | self.ring_q)[..., None, None].astype(bool)
        pend = (self.pend_c | self.pend_b).astype(bool)
        high_next = (self.acc_high + self.pend_b * ((1 << HIGH_W) - 1)
                     + self.pend_c) & ((1 << HIGH_W) - 1)
        n_low = np.where(shift_local, acc_in & ((1 << LOW_W) - 1),
                         low_sum & ((1 << LOW_W) - 1) if mac_en else self.acc_low)
        n_high = np.where(shift_local, (acc_in >> LOW_W) & ((1 << HIGH_W) - 1),
                          np.where(pend, high_next, self.acc_high))
        zero = np.zeros_like(self.pend_c)
        n_pc = np.where(shift_local, zero, next_c if mac_en else zero)
        n_pb = np.where(shift_local, zero, next_b if mac_en else zero)
        n_sh = np.where(shift_local, sh_in, self.shadow + (d_true if mac_en else 0))
        self.acc_low, self.acc_high, self.pend_c, self.pend_b = n_low, n_high, n_pc, n_pb
        self.shadow = n_sh
        self.ring_step = np.where(self.ring_q.astype(bool), (self.ring_step + 1) % NW, 0)

        # PE pipes: bits every clock, signs when load_*_sign_q
        a_in = np.empty_like(self.a_bits_p)
        a_in[:, 0], a_in[:, 1:] = a_cmp, self.a_bits_p[:, :-1]
        w_in = np.empty_like(self.w_bits_p)
        w_in[0], w_in[1:] = w_cmp, self.w_bits_p[:-1]
        as_in = np.empty_like(self.a_sign_p)
        as_in[:, 0], as_in[:, 1:] = self.a_sign_q, self.a_sign_p[:, :-1]
        ws_in = np.empty_like(self.w_sign_p)
        ws_in[0], ws_in[1:] = self.w_sign_q, self.w_sign_p[:-1]
        ad_in = np.empty_like(self.a_dig_p)
        ad_in[:, 0], ad_in[:, 1:] = self.a_dig_q, self.a_dig_p[:, :-1]
        wd_in = np.empty_like(self.w_dig_p)
        wd_in[0], wd_in[1:] = self.w_dig_q, self.w_dig_p[:-1]
        la = self.ld_a_q[..., None, None].astype(bool)
        lw = self.ld_w_q[..., None, None].astype(bool)
        self.a_sign_p = np.where(la, as_in, self.a_sign_p)
        self.w_sign_p = np.where(lw, ws_in, self.w_sign_p)
        self.a_dig_p = np.where(la, ad_in, self.a_dig_p)
        self.w_dig_p = np.where(lw, wd_in, self.w_dig_p)
        self.a_bits_p, self.w_bits_p = a_in, w_in
        n_lda, n_ldw, n_ring = np.empty_like(self.ld_a_q), np.empty_like(self.ld_w_q), np.empty_like(self.ring_q)
        n_lda[:, 0], n_lda[:, 1:] = inp["load_a_sign"], self.ld_a_q[:, :-1]
        n_ldw[0], n_ldw[1:] = inp["load_w_sign"], self.ld_w_q[:-1]
        n_ring[:, 0], n_ring[:, 1:] = inp["ring_in"], self.ring_q[:, :-1]
        self.ld_a_q, self.ld_w_q, self.ring_q = n_lda, n_ldw, n_ring

        # edge held registers (load every cycle in INT mode)
        self.a_code_q, self.a_sign_q, self.a_dig_q = inp["a_code"], inp["a_sign"], inp["a_dig"]
        self.w_code_q, self.w_sign_q, self.w_dig_q = inp["w_code"], inp["w_sign"], inp["w_dig"]
        return sample


# ----------------------------------------------------------------- run ----
def run_gemm(A, W, mode, variant, pr=1, pc=1, chunk=None):
    """Simulate out = A @ W (A: 8pr x Kt, W: Kt x 8pc). Returns (out, stats)."""
    cfg = MODES[mode]
    rows, kt = A.shape
    n_w = cfg["n_w"]
    wspace = variant == "HYS"
    wcols = (NW // n_w if wspace else NW) * pc
    check(rows == NH * pr and W.shape == (kt, wcols), "shape")
    dA = booth_digits(A, cfg["a_bits"], 2)                 # (rows, kt, n_a)
    dW = booth_digits(W, cfg["w_bits"], 4)                 # (kt, cols, n_w)
    check(np.array_equal((dA * (4 ** np.arange(cfg["n_a"]))).sum(-1), A), "booth A")
    check(np.array_equal((dW * (16 ** np.arange(cfg["n_w"]))).sum(-1), W), "booth W")
    check(np.all(np.abs(dA) <= 2) and np.all(np.abs(dW) <= 8), "digit range")
    slots, drains = build_schedule(mode, variant, kt, pr, pc, chunk)
    ring_dir = "R" if variant == "LSB" else "L"
    g = Grid(pr, pc, ring_dir)
    drain_at = {}
    for d in drains:
        for i in range(d["n"]):
            drain_at[d["first"] + i] = (d, i)
    n_edges = drains[-1]["first"] + drains[-1]["n"] + 1
    out = np.zeros((NH * pr, wcols), dtype=object)
    v_ar = np.arange(NW)
    zeros_a = np.zeros((NH, K), dtype=np.int64)

    def lane_digits(slot, side, idx):
        if slot[0] != "mac":
            return zeros_a
        _, p, q, lo, hi, t = slot
        ks = lo + K * t + np.arange(K)
        valid = ks < hi
        ks = np.where(valid, ks, 0)
        if side == "a":
            d = dA[NH * idx:NH * idx + NH][:, ks, p]
        elif q is None:      # HYS: column v carries weight v//n_w, digit v%n_w
            d = dW[ks][:, (NW // n_w) * idx + v_ar // n_w, v_ar % n_w].T
        else:
            d = dW[ks][:, NW * idx:NW * idx + NW, q].T
        return np.where(valid[None, :], d, 0)

    for e in range(n_edges):
        a_dig = np.stack([lane_digits(slots[e - r] if 0 <= e - r < len(slots) else ("idle",), "a", r)
                          for r in range(pr)])
        w_dig = np.stack([lane_digits(slots[e - c] if 0 <= e - c < len(slots) else ("idle",), "w", c)
                          for c in range(pc)])
        ring_in = np.array([1 if 0 <= e - r - 1 < len(slots) and slots[e - r - 1][0] == "ring" else 0
                            for r in range(pr)], dtype=np.int64)
        kidx = np.arange(K)[None, None, :]
        inp = dict(edge=e, mac_en=1, shift_in=int(e in drain_at),
                   load_a_sign=1, load_w_sign=1, ring_in=ring_in,
                   a_dig=a_dig, a_sign=(a_dig < 0).astype(np.int64),
                   a_code=CODE_A[kidx, np.abs(a_dig)],
                   w_dig=w_dig, w_sign=(w_dig < 0).astype(np.int64),
                   w_code=CODE_W[kidx, np.abs(w_dig)])
        sample = g.step(inp)
        if sample is not None:
            d, i = drain_at[e]
            gc = NW * pc - 1 - i
            base, nrot = d["seg"]["base"], d["nrot"]
            for r in range(pr):
                for h in range(NH):
                    v = int(sample[r, h])
                    if ring_dir == "R":
                        c_pe, v_loc = gc // NW, gc % NW
                        em = g.emitted.pop((r, c_pe, h, v_loc), [])
                        check(len(em) == nrot, "emitted-bit count")
                        v = (v << (2 * nrot)) + sum(b << (2 * n) for n, b in enumerate(em))
                    if wspace:   # pair (j,1),(j,0) leaves on consecutive drain edges
                        out[NH * r + h, gc // n_w] += v << (base + 4 * (gc % n_w))
                    else:
                        out[NH * r + h, gc] += v << base
    check(not g.emitted, "unconsumed emitted bits")
    stats = dict(slots=len(slots),
                 mac=sum(1 for s in slots if s[0] == "mac"),
                 ring=sum(1 for s in slots if s[0] == "ring"),
                 idle=sum(1 for s in slots if s[0] == "idle"),
                 drains=len(drains), edges=n_edges, max_abs=g.max_abs,
                 low_sum_range=g.max_low_sum,
                 chunk=chunk or chunk_limit(mode, variant))
    return out.astype(np.int64), stats


def gemm_case(mode, variant, kt, pr, pc, kind, rng, chunk=None):
    cfg = MODES[mode]
    alo, ahi = -(1 << (cfg["a_bits"] - 1)), (1 << (cfg["a_bits"] - 1)) - 1
    wlo, whi = -(1 << (cfg["w_bits"] - 1)), (1 << (cfg["w_bits"] - 1)) - 1
    wcols = (NW // cfg["n_w"] if variant == "HYS" else NW) * pc
    shp_a, shp_w = (NH * pr, kt), (kt, wcols)
    if kind == "random":
        A = rng.integers(alo, ahi + 1, size=shp_a)
        W = rng.integers(wlo, whi + 1, size=shp_w)
        A[0, :] = alo                     # make sure both ends appear
        W[:, 0] = whi
        A[1, ::2] = ahi
    elif kind == "allmax":
        A, W = np.full(shp_a, ahi), np.full(shp_w, whi)
    elif kind == "allmin":                # (-128)(-128): largest positive product
        A, W = np.full(shp_a, alo), np.full(shp_w, wlo)
    elif kind == "minmax":                # most negative product
        A, W = np.full(shp_a, alo), np.full(shp_w, whi)
    elif kind == "alternating":
        sgn = np.where(np.arange(kt) % 2 == 0, 1, -1)
        A = np.where(sgn[None, :] > 0, ahi, alo) * np.ones(shp_a, dtype=np.int64)
        A[1::2] = -A[1::2] - 1
        W = np.where(sgn[:, None] > 0, wlo, whi) * np.ones(shp_w, dtype=np.int64)
    else:
        raise ValueError(kind)
    A, W = A.astype(np.int64), W.astype(np.int64)
    out, st = run_gemm(A, W, mode, variant, pr, pc, chunk)
    ref = A @ W
    check(np.array_equal(out, ref),
          f"{mode}/{variant} K={kt} {pr}x{pc} {kind}: mismatch vs numpy "
          f"at {np.argwhere(out != ref)[:3].tolist()}")
    return st, int(np.max(np.abs(ref)))


# ---------------------------------------------------------------- main ----
def main():
    global THR_A
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="skip the long chunk-limit runs")
    args = ap.parse_args()
    t0 = time.time()
    rng = np.random.default_rng(20261003)

    print("== 1. comparator preset: per-(side,k) codes verified through the comparators")
    print(f"   PRESET_A = {PRESET_A}\n   PRESET_W = {PRESET_W}")
    for k in range(K):
        print(f"   k={k}: CODE_A={CODE_A[k].tolist()}  CODE_W={CODE_W[k].tolist()}")
    # every signed digit pair through comparator -> gate counter -> sign XOR -> -16N
    for k in range(K):
        for da in range(-2, 3):
            for dw in range(-8, 9):
                ab = (CODE_A[k, abs(da)] > THR_A[k]).astype(np.int64)
                wb = (CODE_W[k, abs(dw)] > THR_W[k]).astype(np.int64)
                s = popcount16_csa(ab & wb)
                n = int(da < 0) ^ int(dw < 0)
                val = ((s[0] ^ n) + (s[1] ^ n) + 2 * (s[2] ^ n) + 4 * (s[3] ^ n)
                       + 8 * (s[4] ^ n)) - 16 * n
                check(int(val) == da * dw, f"lane k={k} da={da} dw={dw} -> {val}")
    av = np.arange(-128, 128)
    pa, pw = booth_digits(av, 8, 2), booth_digits(av, 8, 4)
    prod = sum((pa[:, None, p] * pw[None, :, q]) << weight(p, q)
               for p in range(4) for q in range(2))
    check(np.array_equal(prod, av[:, None] * av[None, :]), "INT8 digit identity")
    print("   all 8 lanes x 85 signed digit pairs exact; all 65,536 INT8 pairs "
          "exact as sum of 2^(2p+4q) d_a d_w")

    print("\n== 2. chunk limits (largest reduction per drain, worst case, OW24)")
    for mode in MODES:
        print("   " + mode + ": " + ", ".join(
            f"{v}={chunk_limit(mode, v)}" for v in ("FH", "HY", "HYS", "GD", "LSB")))

    print("\n== 3. GEMM vs numpy (register model, shadow check every edge)")
    cases = []
    for mode in MODES:
        for variant in ("FH", "HY", "HYS", "GD", "LSB"):
            for kt in (8, 64, 1024):
                cases.append((mode, variant, kt, 1, 1, "random"))
            for kind in ("allmax", "allmin", "minmax", "alternating"):
                cases.append((mode, variant, 64, 1, 1, kind))
    cases += [("INT8", "HY", 1024, 2, 2, "random"), ("INT8", "FH", 200, 2, 3, "random"),
              ("INT8", "LSB", 136, 3, 2, "random"), ("W4A8", "HY", 333, 2, 2, "alternating"),
              ("INT4", "HY", 1000, 2, 2, "random"), ("INT8", "GD", 64, 2, 2, "minmax"),
              ("INT8", "FH", 1022, 1, 1, "allmin"), ("INT8", "FH", 511, 1, 1, "allmin"),
              ("INT8", "HY", 1000, 1, 1, "allmin"), ("INT8", "HYS", 1024, 2, 2, "random"),
              ("INT8", "HYS", 700, 3, 2, "alternating"), ("INT8", "HYS", 1000, 1, 1, "minmax")]
    if not args.quick:
        cases += [("INT8", "HY", 8191, 1, 1, "allmin"), ("INT8", "HYS", 8191, 1, 1, "allmin"),
                  ("W4A8", "HY", 8191, 1, 1, "minmax"),
                  ("INT8", "LSB", 4096, 1, 1, "allmin")]
    for mode, variant, kt, pr, pc, kind in cases:
        st, mx = gemm_case(mode, variant, kt, pr, pc, kind, rng)
        print(f"   PASS {mode:4s} {variant:3s} K={kt:5d} grid {pr}x{pc} {kind:11s} "
              f"slots={st['slots']:6d} (mac {st['mac']}, ring {st['ring']}, idle "
              f"{st['idle']}, drains {st['drains']}) MAC/cyc/tile="
              f"{kt / (MODES[mode]['n_w'] if variant == 'HYS' else 1) / st['slots']:.3f} max|acc|={st['max_abs']} max|out|={mx} "
              f"low_sum {st['low_sum_range']}")

    print("\n== 4. negative tests (the model must fail loudly)")
    try:
        gemm_case("INT8", "FH", 512, 1, 1, "allmin", rng, chunk=512)
        raise SystemExit("FAIL: FH chunk 512 all-min overflow went undetected")
    except ModelError as e:
        print(f"   OK  FH INT8 chunk=512 all (-128)x(-128): caught -> {str(e)[:90]}")
    saved = THR_A.copy()
    THR_A = THR_A.copy()
    m0 = int(np.argmin(THR_A[3]))            # move one R0 position of lane 3
    THR_A[3, m0] = CODE_A[3, 1]              # out of R0 (a wrong preset byte)
    try:
        gemm_case("INT8", "HY", 64, 1, 1, "random", rng)
        raise SystemExit("FAIL: corrupted preset went undetected")
    except ModelError as e:
        print(f"   OK  corrupted comparator threshold: caught -> {str(e)[:90]}")
    THR_A = saved
    print(f"\nALL CHECKS PASSED in {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()
