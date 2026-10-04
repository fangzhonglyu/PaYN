#!/usr/bin/env python3
"""Reduction-outer INT mode for the PaYN CSA tile: bidirectional +-2 rotating
accumulator ring ("shift the result down", made block-periodic).

Bit-exact register-level model.  No EDA tools.  Usage:
    python3 sweeps/int_mode/model_reduction_outer_rotating.py
Exit status is non-zero on any mismatch or register-range violation.

Design being modelled (see the docstrings below for the exact registers)
-----------------------------------------------------------------------
* Operand interface stays SC-like: the edge holds one block of 8 values per
  tile row (A) and per tile column (W) for the whole block, exactly as it
  holds SC magnitudes for T/M = 8 cycles today.
* Lane code ("Booth 2x8 digit grid"): a -> radix-4 Booth digits d_a in [-2,2],
  w -> radix-16 Booth digits d_w in [-8,8].  One lane, one cycle carries one
  digit pair on a 2x8 grid m = 8r + c:
      a_bits[k][m] = (|d_a| > r),  w_bits[k][m] = (|d_w| > c),
      a_sign[k] = neg(d_a), w_sign[k] = neg(d_w)
  so count[k] = |d_a|*|d_w| <= 16 and the existing per-lane sign XOR and the
  -16*N correction row produce d_a*d_w exactly.
* Weight of step (p, q) is 2**sigma with sigma = 2p + 4q.  INT8: 8 steps,
  sigma in {0,2,4,4,6,6,8,10}; W4A8: 4 steps {0,2,4,6}; INT4: 2 steps {0,2}.
* The tile never shifts the partial.  The 24 accumulator flops form a ring
  (acc_low 9 = "window", acc_high 15); the ring rotates by exactly 2 bits when
  sigma changes:  R (sigma += 2, LSB-first "shift down": the window's two low
  bits, now final for this block, wrap to the top of acc_high) or
  L (sigma -= 2, MSB-first Horner: they come back).  Blocks alternate
  ascending / descending order, so sigma goes 0 -> max -> 0 with no jump.
* The rotation is applied to the acc row that enters the DW02 heap (3:1 mux),
  so a rotate costs no cycle.  acc_high's D input grows from 2:1 to 4:1.
* The accumulator is stored offset-binary (U = V + 2**23, loaded through the
  existing drain chain).  Valid U never carries out of logical bit 23, so the
  unchanged 15-bit +-1 lazy incrementer never disturbs the parked low bits that
  sit physically above the logical MSB.  No carry-chain cut is needed.
* pending carry/borrow: consumed by the incrementer in the same cycle the ring
  rotates (high_next feeds both the rotated acc row and the rotated acc_high).
"""
import functools
import itertools
import sys

import numpy as np

K, M, LOW_W, OWIDTH = 8, 16, 9, 24
HIGH_W = OWIDTH - LOW_W            # 15
SUM_W = LOW_W + 2                  # 11
N_H = N_W = 8
MASK_LOW = (1 << LOW_W) - 1
MASK_HIGH = (1 << HIGH_W) - 1
MASK24 = (1 << OWIDTH) - 1
OFFSET = 1 << (OWIDTH - 1)

SEL_NONE, SEL_R, SEL_L = 0, 1, 2
COVER = {"R": 0, "L": 0, "R_pc": 0, "R_pb": 0, "L_pc": 0, "L_pb": 0,
         "ripple_ge8": 0, "low_sum_neg": 0, "low_sum_ge512": 0}


class ModelError(AssertionError):
    pass


def require(cond, msg):
    if not cond:
        raise ModelError(msg)


def rotl24(x, s):
    s %= OWIDTH
    return ((x << s) | (x >> (OWIDTH - s))) & MASK24 if s else x & MASK24


def rotr24(x, s):
    return rotl24(x, OWIDTH - (s % OWIDTH))


# ---------------------------------------------------------------- tile lane --
def fa(a, b, c):
    return a ^ b ^ c, (a & b) | (a & c) | (b & c)


@functools.lru_cache(maxsize=None)
def popcount16_csa(x):
    """Gate model of PaynPopcount16Csa (inner_tile_signed_segmented_csa.sv:13-37)."""
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
    return fs[5], fs[6], fs[9], fs[10], fc[10]          # s0a s0b s1 s2 s3


@functools.lru_cache(maxsize=None)
def lane_rows(prod, neg):
    """The two heap rows one lane drives (RTL :103-106), as unsigned ints."""
    s0a, s0b, s1, s2, s3 = popcount16_csa(prod)
    row4 = ((s3 << 3) | (s2 << 2) | (s1 << 1) | s0a) ^ (0xF if neg else 0)
    row1 = s0b ^ neg
    return row4 + row1


def heap_sum(acc_row, lanes):
    """DW02_tree(18 rows x 11 b) + CPA, i.e. low_sum, with the RTL range check.

    lanes: iterable of (and_word, negate).  Returns (low_sum, carry, borrow)."""
    total = acc_row
    nneg = 0
    for prod, neg in lanes:
        total += lane_rows(prod, neg)
        nneg += neg
    total -= 16 * nneg                     # -M * countones(negative lanes)
    # Range argument of the RTL (:138-143): low_sum in [-K*M, 2**(LOW_W+1)-1].
    require(-K * M <= total <= (1 << (LOW_W + 1)) - 1,
            f"low_sum {total} outside [-{K*M}, {(1 << (LOW_W + 1)) - 1}]")
    raw = total & ((1 << SUM_W) - 1)       # what the 11-bit tree + CPA produce
    low_sum = raw - (1 << SUM_W) if raw >> (SUM_W - 1) else raw
    require(low_sum == total, "11-bit heap wrapped")
    borrow = int(low_sum < 0)
    carry = int((not borrow) and ((low_sum >> LOW_W) & 1))
    return low_sum, carry, borrow


class OrigTile:
    """Exact model of InnerTileSignedSegmentedCsa (the unchanged RTL)."""
    __slots__ = ("low", "high", "pc", "pb")

    def __init__(self):
        self.low = self.high = self.pc = self.pb = 0

    def high_next(self):
        return (self.high + (MASK_HIGH if self.pb else 0) + self.pc) & MASK_HIGH

    def acc_out(self):
        return (self.high_next() << LOW_W) | self.low

    def clock(self, lanes, mac_en, shift_in, acc_in, reset=False):
        low_sum, nc, nb = heap_sum(self.low, lanes)
        if reset:
            self.low = self.high = self.pc = self.pb = 0
        elif shift_in:
            self.low, self.high = acc_in & MASK_LOW, (acc_in >> LOW_W) & MASK_HIGH
            self.pc = self.pb = 0
        else:
            if self.pc or self.pb:
                self.high = self.high_next()
            if mac_en:
                self.low, self.pc, self.pb = low_sum & MASK_LOW, nc, nb
            else:
                self.pc = self.pb = 0
        require(not (self.pc and self.pb), "pending carry and borrow both set")


class RingTile:
    """Modified tile.  Registers: acc_low[8:0], acc_high[14:0], pending_carry,
    pending_borrow -- the same 26 flops as today.  New combinational logic:

      acc_row (heap input, 9 b, one-hot 3:1):
        NONE: acc_low
        R   : {high_next[1:0], acc_low[8:2]}
        L   : {acc_low[6:0], acc_high[14:13]}
      acc_high D (15 b, one-hot 4:1; enable = shift_in | rot | pending):
        shift_in: acc_in[23:9]            (drain, unchanged)
        NONE    : high_next                (lazy +-1, unchanged)
        R       : {acc_low[1:0], high_next[14:2]}
        L       : {high_next[12:0], acc_low[8:7]}
      acc_low D: unchanged (shift_in ? acc_in[8:0] : low_sum[8:0]).
      high_next = acc_high + {15{pending_borrow}} + pending_carry  (unchanged).

    sigma_old is a testbench-only argument used by the checker (the tile has
    no sigma state; sigma lives in the per-array sequencer)."""
    __slots__ = ("low", "high", "pc", "pb")

    def __init__(self):
        self.low = self.high = self.pc = self.pb = 0

    def high_next(self):
        return (self.high + (MASK_HIGH if self.pb else 0) + self.pc) & MASK_HIGH

    def acc_out(self):
        return (self.high_next() << LOW_W) | self.low

    def clock(self, lanes, sel, mac_en, shift_in, acc_in, reset=False,
              sigma_old=None):
        hn = self.high_next()
        if sigma_old:
            # parked low bits = top sigma_old bits of acc_high; the unchanged
            # incrementer must never touch them (offset-binary guarantees it).
            top = HIGH_W - sigma_old
            require((hn >> top) == (self.high >> top),
                    f"+-1 incrementer carried into the {sigma_old} parked bits")
        if sel != SEL_NONE:
            tag = "R" if sel == SEL_R else "L"
            COVER[tag] += 1
            COVER[tag + "_pc"] += self.pc
            COVER[tag + "_pb"] += self.pb
        if (self.pc or self.pb) and bin(hn ^ self.high).count("1") >= 8:
            COVER["ripple_ge8"] += 1
        if sel == SEL_NONE:
            row = self.low
        elif sel == SEL_R:
            row = (self.low >> 2) | ((hn & 3) << (LOW_W - 2))
        elif sel == SEL_L:
            row = ((self.low << 2) & MASK_LOW) | (self.high >> (HIGH_W - 2))
        else:
            raise ModelError(f"bad sel {sel}")
        low_sum, nc, nb = heap_sum(row, lanes)
        COVER["low_sum_neg"] += nb
        COVER["low_sum_ge512"] += nc
        if reset:
            self.low = self.high = self.pc = self.pb = 0
        elif shift_in:
            require(sel == SEL_NONE, "rotate during drain")
            self.low, self.high = acc_in & MASK_LOW, (acc_in >> LOW_W) & MASK_HIGH
            self.pc = self.pb = 0
        else:
            if sel == SEL_R:
                new_high = ((self.low & 3) << (HIGH_W - 2)) | (hn >> 2)
            elif sel == SEL_L:
                new_high = ((hn << 2) & MASK_HIGH) | (self.low >> (LOW_W - 2))
            elif self.pc or self.pb:
                new_high = hn
            else:
                new_high = self.high
            self.high = new_high
            if mac_en:
                self.low, self.pc, self.pb = low_sum & MASK_LOW, nc, nb
            else:
                require(sel == SEL_NONE, "rotate requires mac_en")
                self.pc = self.pb = 0
        require(not (self.pc and self.pb), "pending carry and borrow both set")


# ------------------------------------------------------------ edge digits --
def tbit(v, i, nbits):
    """Two's-complement bit i of an nbits value (sign-extended), bit -1 = 0."""
    if i < 0:
        return 0
    return (v >> min(i, nbits - 1)) & 1


def r4_digit(v, p, nbits):
    """Radix-4 Booth digit p, as the edge recoder forms it.
    Returns (row0, row1, neg, value): row0 = |d|>0, row1 = |d|>1."""
    b2, b1, b0 = tbit(v, 2 * p + 1, nbits), tbit(v, 2 * p, nbits), tbit(v, 2 * p - 1, nbits)
    x21, x10 = b2 ^ b1, b1 ^ b0                 # 2 XOR2
    row0 = x21 | x10                            # OR2
    row1 = x21 & (1 ^ x10)                      # NOR2(~x21, x10)
    neg = b2                                    # d=0 with neg=1 gives zero bits -> 0
    value = -2 * b2 + b1 + b0
    require(row0 + row1 == abs(value) and (value >= 0 or neg), "r4 recoder")
    return row0, row1, neg, value


def r16_digit(v, q, nbits):
    """Radix-16 Booth digit q.  Returns (therm8, neg, value), therm bit c = |d|>c."""
    x4, x3, x2, x1, x0 = (tbit(v, 4 * q + 3, nbits), tbit(v, 4 * q + 2, nbits),
                          tbit(v, 4 * q + 1, nbits), tbit(v, 4 * q, nbits),
                          tbit(v, 4 * q - 1, nbits))
    u = 4 * x3 + 2 * x2 + x1 + x0
    mag = 8 - u if x4 else u
    therm = 0
    for c in range(8):
        therm |= int(mag > c) << c
    value = -8 * x4 + u
    require(mag == abs(value), "r16 recoder")
    return therm, x4, value


def a_word(row0, row1):
    """2x8 grid, m = 8r + c: rows r=0 -> m 0..7, r=1 -> m 8..15."""
    return (0x00FF if row0 else 0) | (0xFF00 if row1 else 0)


def w_word(therm):
    return therm | (therm << 8)


# --------------------------------------------------------------- schedules --
MODES = {
    #        A bits, W bits, ascending (p, q) order
    "INT8": (8, 8, [(0, 0), (1, 0), (2, 0), (0, 1), (3, 0), (1, 1), (2, 1), (3, 1)]),
    "W4A8": (8, 4, [(0, 0), (1, 0), (2, 0), (3, 0)]),
    "INT4": (4, 4, [(0, 0), (1, 0)]),
}


def sigma_of(p, q):
    return 2 * p + 4 * q


def max_product(mode):
    na, nw, _ = MODES[mode]
    return (1 << (na - 1)) * (1 << (nw - 1))


def k_seg_max(mode):
    """Largest multiple of 8 such that a worst-case segment keeps U in range.

    Bound: |V| <= K_seg*maxprod + per-block intermediate overshoot (8 lanes x
    sum over digit pairs of |da||dw|2**sigma), must stay <= 2**23 - 1."""
    na, nw, order = MODES[mode]
    over = K * sum(2 * 8 * (1 << sigma_of(p, q)) for p, q in order)
    return ((OFFSET - 1 - over) // max_product(mode)) // K * K


def to_twos(x, nbits):
    return int(x) & ((1 << nbits) - 1)


# ------------------------------------------------------------- PE runner --
def run_pe(A, W, mode, offset=True, seg=None, stats=None):
    """One PE (8x8 tiles) computes C = A @ W for A (8 x L), W (L x 8).

    Loop order: segment (<= seg products) -> block of 8 k -> step (p, q) in
    ascending or descending sigma order (alternating per block; first block's
    direction chosen so the segment ends at sigma = 0) -> drain 8 edges into
    the edge's wide accumulator.  Returns the 8x8 int result."""
    na, nw, asc = MODES[mode]
    desc = list(reversed(asc))
    smax = sigma_of(*asc[-1])
    L = A.shape[1]
    nblk_tot = -(-L // K)
    Ap = np.zeros((N_H, nblk_tot * K), dtype=np.int64)
    Wp = np.zeros((nblk_tot * K, N_W), dtype=np.int64)
    Ap[:, :L], Wp[:L, :] = A, W
    seg = seg or k_seg_max(mode)
    seg_blocks = max(1, seg // K)
    base = OFFSET if offset else 0

    tiles = [[RingTile() for _ in range(N_W)] for _ in range(N_H)]
    result = [[0] * N_W for _ in range(N_H)]
    cycles = {"mac": 0, "drain": 0}

    def drain(acc_in_west, collect):
        out = [[None] * N_W for _ in range(N_H)]
        for e in range(N_W):
            ao = [[t.acc_out() for t in row] for row in tiles]
            for h in range(N_H):
                out[h][N_W - 1 - e] = ao[h][N_W - 1]          # sampled before shift
                for v in range(N_W):
                    tiles[h][v].clock((), SEL_NONE, 0, 1,
                                      acc_in_west if v == 0 else ao[h][v - 1])
            cycles["drain"] += 1
        if collect:
            for h in range(N_H):
                for v in range(N_W):
                    u = out[h][v]
                    vv = u - base
                    if not offset:
                        vv = vv - (1 << OWIDTH) if vv >> (OWIDTH - 1) else vv
                    result[h][v] += vv

    segs = [(s, min(s + seg_blocks, nblk_tot)) for s in range(0, nblk_tot, seg_blocks)]

    def init_word(nblk):
        start_desc = nblk % 2 == 1
        return rotr24(base, smax if start_desc else 0), start_desc

    first_init, _ = init_word(segs[0][1] - segs[0][0])
    drain(first_init, collect=False)                      # fill every tile

    for si, (b0, b1) in enumerate(segs):
        nblk = b1 - b0
        _, start_desc = init_word(nblk)
        sigma = smax if start_desc else 0
        gold = [[base] * N_W for _ in range(N_H)]
        for b in range(b0, b1):
            order = desc if ((b - b0) + start_desc) % 2 else asc
            ks = slice(b * K, b * K + K)
            Ablk = [[to_twos(x, na) for x in Ap[h, ks]] for h in range(N_H)]
            Wblk = [[to_twos(x, nw) for x in Wp[ks, v]] for v in range(N_W)]
            for (p, q) in order:
                s_new = sigma_of(p, q)
                d = s_new - sigma
                require(d in (-2, 0, 2), f"sigma step {d}")
                sel = {0: SEL_NONE, 2: SEL_R, -2: SEL_L}[d]
                # edge: one recoder per held value; rows share A, cols share W
                arow = [[r4_digit(x, p, na) for x in Ablk[h]] for h in range(N_H)]
                wcol = [[r16_digit(x, q, nw) for x in Wblk[v]] for v in range(N_W)]
                aw = [[(a_word(r0, r1), ng) for (r0, r1, ng, _) in arow[h]] for h in range(N_H)]
                ww = [[(w_word(t), ng) for (t, ng, _) in wcol[v]] for v in range(N_W)]
                da = np.array([[x[3] for x in arow[h]] for h in range(N_H)], dtype=np.int64)
                dw = np.array([[x[2] for x in wcol[v]] for v in range(N_W)], dtype=np.int64)
                P = da @ dw.T
                for h in range(N_H):
                    ah = aw[h]
                    for v in range(N_W):
                        wv = ww[v]
                        lanes = [(ah[k][0] & wv[k][0], ah[k][1] ^ wv[k][1]) for k in range(K)]
                        t = tiles[h][v]
                        t.clock(lanes, sel, 1, 0, 0, sigma_old=sigma)
                        g = gold[h][v] + (int(P[h, v]) << s_new)
                        gold[h][v] = g
                        if offset:
                            require(0 <= g <= MASK24,
                                    f"offset accumulator out of range ({g}); shorten the segment")
                        if s_new:
                            top = HIGH_W - s_new
                            require((t.high_next() >> top) == (t.high >> top),
                                    f"tile ({h},{v}): pending +-1 rippled into the {s_new} parked bits")
                        logical = rotl24(t.acc_out(), s_new)
                        require(logical == (g & MASK24),
                                f"tile ({h},{v}) mismatch: ring {logical:#x} != golden {g & MASK24:#x}")
                sigma = s_new
                cycles["mac"] += 1
        require(sigma == 0, "segment did not end aligned")
        nxt = init_word(segs[si + 1][1] - segs[si + 1][0])[0] if si + 1 < len(segs) else base
        drain(nxt, collect=True)
    if stats is not None:
        stats.update(cycles)
        stats["segments"] = len(segs)
    return np.array(result, dtype=np.int64)


# ------------------------------------------------------------------ tests --
def part1_pairs():
    """Every (a, w) pair through edge recoders + gate-level lane + weights."""
    out = []
    for mode in ("INT8", "W4A8", "INT4"):
        na, nw, order = MODES[mode]
        worst = 0
        for a in range(-(1 << (na - 1)), 1 << (na - 1)):
            for w in range(-(1 << (nw - 1)), 1 << (nw - 1)):
                acc = 0
                for p, q in order:
                    r0, r1, an, dav = r4_digit(to_twos(a, na), p, na)
                    th, wn, dwv = r16_digit(to_twos(w, nw), q, nw)
                    prod = a_word(r0, r1) & w_word(th)
                    cnt = bin(prod).count("1")
                    worst = max(worst, cnt)
                    lane = lane_rows(prod, an ^ wn) - 16 * (an ^ wn)
                    require(lane == dav * dwv, f"lane {mode} a={a} w={w} p={p} q={q}")
                    acc += lane << sigma_of(p, q)
                require(acc == a * w, f"{mode} pair {a}*{w} -> {acc}")
        n = (1 << na) * (1 << nw)
        out.append(f"{mode}: all {n} pairs exact, max lane count {worst} (M={M})")
    return out


def part2_sc_equivalence(rng, cycles=30000):
    """RingTile with sel=NONE vs the unchanged RTL tile, random SC traffic."""
    o, r = OrigTile(), RingTile()
    for c in range(cycles):
        lanes = [(int(rng.integers(0, 1 << 16)) & int(rng.integers(0, 1 << 16)),
                  int(rng.integers(0, 2))) for _ in range(K)]
        sh = int(rng.random() < 0.02)
        mac = int(rng.random() < 0.9)
        acc_in = int(rng.integers(0, 1 << OWIDTH))
        reset = c == 0
        o.clock(lanes, mac, sh, acc_in, reset)
        r.clock(lanes, SEL_NONE, mac, sh, acc_in, reset)
        require((o.low, o.high, o.pc, o.pb) == (r.low, r.high, r.pc, r.pb),
                f"SC-mode state differs at cycle {c}")
        require(o.acc_out() == r.acc_out(), f"SC-mode acc_out differs at cycle {c}")
    return f"{cycles} random SC cycles (2% drains, 10% idle): ring tile == unchanged tile, every register, every cycle"


def part3_random_walk(rng, steps=40000):
    """Single tile, random sigma walk in [0,10] with +-2/0 steps and random
    digit lanes, start near the range edges; checks ring vs golden each cycle."""
    t = RingTile()
    sigma = 0
    for start in (OFFSET, 1, MASK24 - 1, OFFSET - 12345):
        t = RingTile()
        t.clock((), SEL_NONE, 0, 1, start)
        g, sigma = start, 0
        for _ in range(steps // 4):
            d = int(rng.choice([-2, 0, 2]))
            if not 0 <= sigma + d <= 10:
                d = -d
            s_new = sigma + d
            sel = {0: SEL_NONE, 2: SEL_R, -2: SEL_L}[d]
            lanes, P = [], 0
            for _k in range(K):
                da, dw = int(rng.integers(-2, 3)), int(rng.integers(-8, 9))
                ag = a_word(abs(da) > 0, abs(da) > 1)
                th = sum(1 << c for c in range(8) if abs(dw) > c)
                lanes.append((ag & w_word(th), int(da < 0) ^ int(dw < 0)))
                P += da * dw
            # keep the golden value in range: flip the contribution if needed
            if not 0 <= g + (P << s_new) <= MASK24:
                lanes = [(w_, 1 ^ n_) if w_ else (w_, n_) for (w_, n_) in lanes]
                P = -P
            t.clock(lanes, sel, 1, 0, 0, sigma_old=sigma)
            g += P << s_new
            require(0 <= g <= MASK24, "walk left range")
            require(rotl24(t.acc_out(), s_new) == g, "random walk mismatch")
            sigma = s_new
    return f"{steps} random +-2/0 rotations with random digit lanes from 4 start values (incl. 1 and 2^24-2): exact"


def gemm_case(rng, mode, L, kind):
    na, nw, _ = MODES[mode]
    alo, ahi = -(1 << (na - 1)), (1 << (na - 1)) - 1
    wlo, whi = -(1 << (nw - 1)), (1 << (nw - 1)) - 1
    if kind == "random":
        A = rng.integers(alo, ahi + 1, size=(N_H, L))
        W = rng.integers(wlo, whi + 1, size=(L, N_W))
    elif kind == "all_max":
        A = np.full((N_H, L), ahi); W = np.full((L, N_W), whi)
    elif kind == "all_min":
        A = np.full((N_H, L), alo); W = np.full((L, N_W), wlo)
    elif kind == "min_x_max":
        A = np.full((N_H, L), alo); W = np.full((L, N_W), whi)
    elif kind == "alternating":
        hk = np.add.outer(np.arange(N_H), np.arange(L))
        A = np.where(hk % 2 == 0, alo, ahi)
        kv = np.add.outer(np.arange(L), np.arange(N_W))
        W = np.where(kv % 3 == 0, wlo, np.where(kv % 3 == 1, whi, -1))
    elif kind == "extremes_mix":
        A = rng.choice([alo, ahi, -1, 0, 1], size=(N_H, L))
        W = rng.choice([wlo, whi, -1, 0, 1], size=(L, N_W))
    else:
        raise ValueError(kind)
    return A.astype(np.int64), W.astype(np.int64)


def part4_gemm(rng):
    lines = []
    plan = [
        ("INT8", 8, "random"), ("INT8", 24, "random"), ("INT8", 64, "random"),
        ("INT8", 1000, "random"), ("INT8", 1024, "random"),
        ("INT8", 64, "all_max"), ("INT8", 1024, "all_min"), ("INT8", 496, "all_min"),
        ("INT8", 1024, "min_x_max"), ("INT8", 1024, "alternating"),
        ("INT8", 512, "extremes_mix"),
        ("W4A8", 8, "random"), ("W4A8", 64, "random"), ("W4A8", 1024, "random"),
        ("W4A8", 1024, "all_min"), ("W4A8", 1024, "alternating"), ("W4A8", 1000, "min_x_max"),
        ("INT4", 8, "random"), ("INT4", 64, "random"), ("INT4", 1024, "random"),
        ("INT4", 1024, "all_min"), ("INT4", 1024, "all_max"), ("INT4", 1016, "alternating"),
    ]
    for mode, L, kind in plan:
        A, W = gemm_case(rng, mode, L, kind)
        st = {}
        C = run_pe(A, W, mode, stats=st)
        ref = A @ W
        require(np.array_equal(C, ref), f"{mode} L={L} {kind}: PE result != numpy")
        lines.append(f"{mode:5s} L={L:5d} {kind:12s}: exact (64 outputs, {st['mac']} MAC cycles, "
                     f"{st['segments']} segment(s), {st['drain']} drain edges incl. initial fill)")
    return lines


def part5_expected_failures(rng):
    lines = []
    # (a) two's-complement storage instead of offset-binary: incrementer ripples
    #     into the parked bits as soon as a value crosses zero.
    #     A = -1 for even blocks, +1 for odd blocks, W = 127: V drops to -1016
    #     and climbs back through zero at the sigma = 4 step of the next block.
    A = np.where((np.arange(64) // 8) % 2 == 0, -1, 1)[None, :].repeat(N_H, 0).astype(np.int64)
    W = np.full((64, N_W), 127, dtype=np.int64)
    try:
        run_pe(A, W, "INT8", offset=False)
        raise RuntimeError("expected failure not raised (two's complement ring)")
    except ModelError as e:
        lines.append(f"two's-complement ring (no offset): caught as expected -> {e}")
    # (b) an INT8 segment longer than the bound with all -128 overflows 24 bits
    A = np.full((N_H, 528), -128, dtype=np.int64)
    W = np.full((528, N_W), -128, dtype=np.int64)
    try:
        run_pe(A, W, "INT8", seg=528)
        raise RuntimeError("expected failure not raised (segment too long)")
    except ModelError as e:
        lines.append(f"INT8 segment of 528 x (-128*-128): caught as expected -> {e}")
    return lines


# ------------------------------------------------------------ cost model --
CELL = dict(AO22=0.686, AOI22=0.490, NAND2=0.294, NOR2=0.294, AND2=0.392, OR2=0.392,
            XOR2=0.588, MXT2=0.784, AO21=0.588, DFFQA=1.470, BUFH=0.294, ADDH=0.980,
            ADDF=1.666, INV=0.196)
MUX3 = CELL["AOI22"] + 2 * CELL["NAND2"]          # one-hot 3:1, 1.078
MUX4 = 2 * CELL["AOI22"] + CELL["NAND2"]          # one-hot 4:1, 1.274
TILE_SYN = 408.170
UPE_APR, PERIPH_APR, SOBOL_APR, ARRAY_APR = 29255.548, 13031.256, 1678.348, 44017.974
BOS = {"INT8": 15797.404, "INT6": 12403.664, "INT4": 10276.378}


def grid_area(pr, pc):
    return pr * pc * UPE_APR + (pr + pc) * PERIPH_APR / 2 + SOBOL_APR


def costs():
    c = CELL
    tile = [
        ("heap acc row 3:1 one-hot (9 b)", 9 * MUX3),
        ("acc_high D 2:1 AO22 -> 4:1 one-hot (15 b, +AOI22... delta)", 15 * (MUX4 - c["AO22"])),
        ("select gating for R/L vs reset/shift_in (2 gates) + fanout share", 2 * c["AND2"] + 0.216),
        ("+-1 incrementer carry cut", 0.0),
        ("extra flops", 0.0),
    ]
    tile_total = sum(a for _, a in tile)
    pe = [("sel_R/sel_L pipeline flops (2 DFFQA, ride with the data wave)", 2 * c["DFFQA"]),
          ("select fanout buffers (8 BUFH)", 8 * c["BUFH"])]
    pe_total = sum(a for _, a in pe)
    a_lane = [
        ("radix-4 digit select, 3 b x one-hot 4:1", 3 * MUX4),
        ("recode: 2 XOR2 + OR2 + NOR2", 2 * c["XOR2"] + c["OR2"] + c["NOR2"]),
        ("inject 16 bits: 2 AND2 (gate rows) + 16 AO21", 2 * c["AND2"] + 16 * c["AO21"]),
        ("sign-pipe source mux", c["MXT2"]),
    ]
    w_lane = [
        ("radix-16 digit select, 4 MXT2 + 1 AND2", 4 * c["MXT2"] + c["AND2"]),
        ("recode to |d| thermometer (HA + ~20 gates, estimate)", 9.0),
        ("inject 16 bits: 16 AO22", 16 * c["AO22"]),
        ("sign-pipe source mux", c["MXT2"]),
    ]
    a_half = 64 * sum(a for _, a in a_lane)
    w_half = 64 * sum(a for _, a in w_lane)
    seq = 20.0          # per array/grid: 3-bit step counter, dir flop, 8-entry (p,q) ROM
    return tile, tile_total, pe, pe_total, a_lane, w_lane, a_half, w_half, seq


def print_costs():
    tile, tt, pe, pt, a_lane, w_lane, a_half, w_half, seq = costs()
    print("\n== area (cell areas: LEF footprints from the ground truth; estimate, no synthesis)")
    print(f"  tile (synth tile {TILE_SYN} um2):")
    for n, a in tile:
        print(f"    {n:66s} {a:7.3f}")
    print(f"    {'TOTAL per tile':66s} {tt:7.3f}  = {100 * tt / TILE_SYN:.2f}% of tile")
    print("  PE (non-tile):")
    for n, a in pe:
        print(f"    {n:66s} {a:7.3f}")
    print("  edge A lane / W lane:")
    for n, a in a_lane:
        print(f"    A {n:64s} {a:7.3f}")
    for n, a in w_lane:
        print(f"    W {n:64s} {a:7.3f}")
    print(f"    A edge half (64 lanes) {a_half:9.1f}   W edge half {w_half:9.1f}   "
          f"per PE edge {a_half + w_half:9.1f}")
    rows = []
    for pr, pc in ((1, 1), (4, 4), (4, 8)):
        npe = pr * pc
        base = ARRAY_APR if npe == 1 else grid_area(pr, pc)
        skew_flops = 4 * (pr * (pr - 1) // 2 + pc * (pc - 1) // 2)  # step index skew per edge row
        add_tile = 64 * npe * tt
        add_pe = npe * pt
        add_edge = pr * a_half + pc * w_half + skew_flops * CELL["DFFQA"] + seq
        tot = add_tile + add_pe + add_edge
        sc0 = 64 * npe * 0.4 / (base * 1e-6)
        sc1 = 64 * npe * 0.4 / ((base + tot) * 1e-6)
        rows.append((pr, pc, base, add_tile, add_pe, add_edge, tot, sc0, sc1))
        print(f"  {pr}x{pc}: base {base:,.0f}; tiles 64x{npe}x{tt:.2f}={add_tile:,.0f} "
              f"({100 * add_tile / base:.2f}%); PE {add_pe:,.0f}; edge {pr}x{a_half:.0f}+{pc}x{w_half:.0f}"
              f"+skew {skew_flops} flops+seq = {add_edge:,.0f} ({100 * add_edge / base:.2f}%); "
              f"total +{tot:,.0f} = {100 * tot / base:.2f}%; SC {sc0:.1f} -> {sc1:.1f} GMAC/s/mm2")
    return rows


def print_bandwidth():
    print("\n== operand bandwidth (INT values two's complement; SC row uses 9-bit sign+mag)")
    print(f"  {'mode':6s} {'steps':>5s} {'MAC/cyc/tile':>12s} {'b/cyc into PE':>14s} {'b/MAC':>6s} "
          f"{'b/cyc into 4x4':>15s} {'b/MAC 4x4':>9s}")
    for mode, (na, nw, order) in [("SC", (9, 9, [None] * 8))] + [(m, MODES[m]) for m in MODES]:
        steps = len(order)
        mpt = K / steps
        bpe = (64 * na + 64 * nw) / steps
        b44 = (4 * 64 * na + 4 * 64 * nw) / steps
        print(f"  {mode:6s} {steps:5d} {mpt:12.2f} {bpe:14.1f} {bpe / (64 * mpt):6.3f} "
              f"{b44:15.1f} {b44 / (1024 * mpt):9.3f}")


def print_alternatives():
    c = CELL
    tt = costs()[1]
    print("\n== reduction-outer accumulator options (per tile, um2; 26 state flops today)")
    MUX5 = 2 * c["AOI22"] + c["NAND2"] + 0.392       # one-hot 5:1 ~ 2 AOI22 + NAND2 + NAND3
    MUX6 = 3 * c["AOI22"] + 0.490                     # one-hot 6:1 ~ 3 AOI22 + NAND3
    alts = [
        ("bidirectional +-2 ring (this model)", tt, 26, "1 / 2 / 4"),
        ("one-way R2 ring, realign by idle rotations", 9 * c["AO22"] + 15 * (MUX3 - c["AO22"]) + 0.6,
         26, "8/15=0.53 / 8/13=0.62 / 8/13=0.62"),
        ("R2 ring + jump L10 (INT8 only)", tt, 26, "1 / - / -   (10-bit-long wires)"),
        ("R2 ring + jumps L10/L6/L2 (all modes)", 9 * MUX5 + 15 * (MUX6 - c["AO22"]) + 1.0,
         26, "1 / 2 / 4"),
        ("barrel shift of the partial {0..10} (prior-art estimate)", 48.2, 26, "1 / 2 / 4"),
        ("6 accumulators, one per weight (~16 b each)", 80 * 1.372 + 9 * 1.96 + 5 * 1.47 + 5, 106, "1 / 2 / 4"),
        ("block register + LSB-first serial add into ring", 12 * 1.372 + 15 + 5 + 9 * MUX3, 38, "1 / 2 / 4"),
    ]
    for n, a, fl, thr in alts:
        print(f"  {n:58s} {a:7.1f} um2 ({100 * a / TILE_SYN:5.1f}% tile)  flops {fl:3d}  "
              f"INT8/W4A8/INT4 MAC/cyc/tile {thr}")


def print_comparison(rows):
    print("\n== versus a dedicated BOS array of equal INT throughput (4x4: INT8 1024 MAC/cyc)")
    for pr, pc, base, at, ap, ae, tot, sc0, sc1 in rows[1:]:
        npe = pr * pc
        for mode, mpt, bos_key in (("INT8", 1, "INT8"), ("W4A8", 2, "INT8"), ("INT4", 4, "INT4")):
            macs = 64 * npe * mpt
            bos = BOS[bos_key] * macs / 64
            print(f"  {pr}x{pc} {mode}: {macs} MAC/cyc; this mode +{tot:,.0f} um2 vs BOS-{bos_key} x{macs // 64} "
                  f"= {bos:,.0f} um2 ({bos / tot:.1f}x); INT-mode eff {macs * 0.4 / ((base + tot) * 1e-6):.0f} GMAC/s/mm2")


def print_utilization():
    print("\n== utilization incl. drains (worst-case-safe INT8 segments of "
          f"{k_seg_max('INT8')} products; +2 pipeline/skew ignored)")
    for L in (512, 4096):
        for pc, name in ((1, "1x1"), (4, "4x4"), (8, "4x8")):
            vals = []
            for mode in MODES:
                steps = len(MODES[mode][2])
                segs = -(-L // k_seg_max(mode))
                mac = steps * (-(-L // K))
                dr = segs * 8 * pc
                vals.append(f"{mode} {100 * mac / (mac + dr):5.1f}%")
            print(f"  L={L:5d} {name}: " + "  ".join(vals))


def main():
    rng = np.random.default_rng(20261003)
    print("model_reduction_outer_rotating: bidirectional +-2 ring, offset-binary, Booth 2x8 lanes")
    print("K_seg max (worst-case, multiple of 8): " +
          ", ".join(f"{m} {k_seg_max(m)}" for m in MODES))
    print("\n== part 1: pairs through edge recoders + gate-level lane")
    for s in part1_pairs():
        print("  " + s)
    print("\n== part 2: SC-mode equivalence")
    print("  " + part2_sc_equivalence(rng))
    for key in COVER:
        COVER[key] = 0                    # coverage below counts parts 3+4 only
    print("\n== part 3: ring random walk")
    print("  " + part3_random_walk(rng))
    print("\n== part 4: PE GEMM (8x8 tiles, drain chain, wide edge accumulate) vs numpy")
    for s in part4_gemm(rng):
        print("  " + s)
    print("  coverage (parts 3+4): " + ", ".join(f"{k}={v}" for k, v in COVER.items()))
    for k in ("R_pc", "R_pb", "L_pc", "L_pb", "ripple_ge8"):
        require(COVER[k] > 0, f"coverage hole: {k}")
    print("\n== part 5: negative tests (must fail loudly)")
    for s in part5_expected_failures(rng):
        print("  " + s)
    rows = print_costs()
    print_alternatives()
    print_bandwidth()
    print_comparison(rows)
    print_utilization()
    print("\nALL CHECKS PASSED")


if __name__ == "__main__":
    try:
        main()
    except (ModelError, RuntimeError) as e:
        print(f"\nFAIL: {e}", file=sys.stderr)
        sys.exit(1)
