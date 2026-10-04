#!/usr/bin/env python3
"""Bit-exact, register-level model of a bit-plane INT mode on the PaYN CSA grid.

No EDA tools.  Python + numpy only.  Rerun:  python3 sweeps/int_mode/model_bitplane_throughput.py
(add --quick for a reduced matrix).

What is modelled (one clock edge per call of Grid.step):
  * edge peripheral per PE row (A) / PE column (W) -- sc_pe_peripheral:
      held magnitude + sign registers, the 8-bit '>' comparator against
      (random ^ MASK(k,m)) with the real scramble constants, and the NEW
      INT path:  bits = comparator | raw_bits  (1024 OR2 per edge half) and the
      NEW INT-mode gate on the magnitude-register load (signs still load).
  * PE (InnerPESignedSegmentedCsa): ungated 2048-bit operand pipes, sign pipes
      enabled by the registered load wave, east/south re-export (1 cycle/hop),
      and the NEW control wave ctl_q = {ring, dbl} registered and re-exported
      exactly like load_a_sign_q.
  * tile (InnerTileSignedSegmentedCsa) at gate level where it matters:
      128 AND, PaynPopcount16Csa (11 FA -> s0a,s0b,s1,s2,s3), per-lane sign XOR
      on the 5 redundant bits, the -16*N correction row, the DW02 heap as a
      SUM_W-bit modular sum, low_sum range assertion, carry/borrow decode,
      LOW_W=9 acc_low + pending carry/borrow + 15-bit lazy +-1 acc_high,
      canonical acc_out, drain mux (shift_in priority).
  * doubling mechanisms (NEW, alternatives):
      'ring' -- per-PE 192-bit mux on the west drain input:
                acc_in_west_eff = ring_q ? (own acc_out_east << 1) : acc_in_west,
                tile shift_in = shift_in | ring_q.  8 shifts = one lap = every
                tile value doubled exactly once, zero tile change.
      'self' -- per-tile third source on the 24-bit drain mux:
                dbl: {acc_high,acc_low} <= acc_out << 1, pending cleared.
  * grid: P_R x P_C PEs, systolic skew applied by the data mover (A row r
      delayed r, W column c delayed c), global mac_en / shift_in, global
      west->east drain chain through all PE columns.
  * east-edge plane combiner per PE row (NEW): weighted row sum
      S = sum_h coef[h]*x[h] per row group, optional Horner R <- 2R + S over
      drain steps, COMB_W-bit registers with overflow checks.

Mappings (Ba / Bw = activation / weight bits, two's complement, MSB plane
negative via the existing lane sign; every tile always sees one uniform plane
pair, so the per-cycle partial is in [-128, 128] exactly as in SC):
  'S'  all planes in space: row h = (act row, a-plane), col v = (out col, w-plane).
       Zero PE/tile change.  Combiner: tree over a-planes, Horner over w-planes.
  'HW' row h = (act row, a-plane), col v = output column; w-planes in time,
       MSB first, one doubling between w-plane passes (ring or self).
       Combiner: tree over a-planes only.   <- recommended INT8 mapping
  'HB' row h = act row, col v = output column; both planes in time, Horner
       over s = p+q (MSB first), doubling between s stages.  Tile = full
       output, so it is limited by OWIDTH=24 (fine for W4A8 / INT4).
  'HA' transpose of HW (a-planes in time); combiner Horner per row.

Checks that fail loudly (ModelError):
  * heap exact value outside the RTL range [-K*M, 2^(LOW_W+1)-1]
  * lane CSA trick != independent signed popcount, every tile every cycle
  * pending carry and borrow both set
  * canonical acc_out != shadow exact value (every tile, every cycle)
  * |shadow| >= 2^23 at any cycle (true 24-bit register overflow)
  * combiner register overflow (COMB_W)
  * any output != numpy int64 GEMM
  * SC transparency: with the INT hardware present but idle, every register
    equals the original datapath every cycle.
"""
import argparse
import itertools
import sys
import time

import numpy as np

NK, M, NH, NW = 8, 16, 8, 8
OW, LOW_W = 24, 9
HIGH_W = OW - LOW_W
SUM_W = LOW_W + 2
M24 = (1 << OW) - 1
LOWMASK = (1 << LOW_W) - 1
HIGHMASK = (1 << HIGH_W) - 1
SUMMASK = (1 << SUM_W) - 1
COMB_W = 40
LEVELS = 256
K_STRIDE = ((LEVELS * 79 // 128) | 1)      # 159, pe_peripheral.sv
M_STRIDE = ((LEVELS * 49 // 128) | 1)      # 99
A_SALT, W_SALT = 0, 128
MASK_A = np.array([[(k * K_STRIDE + m * M_STRIDE + A_SALT) & 255 for m in range(M)]
                   for k in range(NK)], dtype=np.int64)
MASK_W = np.array([[(k * K_STRIDE + m * M_STRIDE + W_SALT) & 255 for m in range(M)]
                   for k in range(NK)], dtype=np.int64)


class ModelError(AssertionError):
    pass


def check(cond, msg):
    if not cond:
        raise ModelError(msg)


def to_signed(u, bits):
    u = np.asarray(u, dtype=np.int64)
    return np.where(u >> (bits - 1) & 1, u - (1 << bits), u)


def popcount16_csa(b):
    """Gate model of PaynPopcount16Csa; b[..., 16] in {0,1}."""
    def fa(x, y, z):
        return x ^ y ^ z, (x & y) | (x & z) | (y & z)
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


# ============================================================== hardware ==
class Grid:
    """P_R x P_C PEs + edge peripherals + east-edge combiners."""

    def __init__(self, pr, pc, mech="none", int_hw=True):
        assert mech in ("none", "ring", "self")
        self.pr, self.pc, self.mech, self.int_hw = pr, pc, mech, int_hw
        z = lambda *s: np.zeros(s, dtype=np.int64)
        # peripherals
        self.a_bin_q, self.a_sgn_q = z(pr, NH, NK), z(pr, NH, NK)
        self.w_bin_q, self.w_sgn_q = z(pc, NW, NK), z(pc, NW, NK)
        # PE registers
        self.a_bits = z(pr, pc, NH, NK, M)
        self.w_bits = z(pr, pc, NW, NK, M)
        self.a_sgn = z(pr, pc, NH, NK)
        self.w_sgn = z(pr, pc, NW, NK)
        self.lda_q, self.ldw_q = z(pr, pc), z(pr, pc)
        self.ring_q, self.dbl_q = z(pr, pc), z(pr, pc)
        # tiles
        self.acc_low, self.acc_high = z(pr, pc, NH, NW), z(pr, pc, NH, NW)
        self.pcar, self.pbor = z(pr, pc, NH, NW), z(pr, pc, NH, NW)
        self.shadow = z(pr, pc, NH, NW)   # exact value; |.| < 2^23 is checked
        self.cycle = 0
        self.max_abs_shadow = 0

    # ---------------------------------------------------------- helpers --
    def state(self):
        return tuple(x.copy() for x in (
            self.a_bin_q, self.a_sgn_q, self.w_bin_q, self.w_sgn_q, self.a_bits,
            self.w_bits, self.a_sgn, self.w_sgn, self.lda_q, self.ldw_q,
            self.acc_low, self.acc_high, self.pcar, self.pbor))

    def acc_out_u(self):
        high_next = (self.acc_high + np.where(self.pbor == 1, HIGHMASK, 0)
                     + self.pcar) & HIGHMASK
        return (high_next << LOW_W) | self.acc_low

    # ------------------------------------------------------------- step --
    def step(self, inp):
        """One clock edge.  inp: dict of port values valid during this cycle."""
        pr, pc = self.pr, self.pc
        int_mode = inp.get("int_mode", 0)
        # ---- peripheral comparators (combinational from held registers)
        ra = inp["a_rand"][None, None, :]          # (1,1,M) shared by all k
        rw = inp["w_rand"][None, None, :]
        a_cmp = (self.a_bin_q[:, :, :, None] > (ra ^ MASK_A[None])).astype(np.int64)
        w_cmp = (self.w_bin_q[:, :, :, None] > (rw ^ MASK_W[None])).astype(np.int64)
        if self.int_hw:
            a_edge = a_cmp | inp["a_raw"]            # NEW: 1024 OR2 per edge half
            w_edge = w_cmp | inp["w_raw"]
        else:
            check(not inp["a_raw"].any() and not inp["w_raw"].any(),
                  "raw bits driven on a datapath without the INT bypass")
            a_edge, w_edge = a_cmp, w_cmp

        # ---- PE inputs (west/north edge or neighbour re-export, old values)
        a_bits_in = np.empty_like(self.a_bits)
        a_bits_in[:, 0] = a_edge
        a_bits_in[:, 1:] = self.a_bits[:, :-1]
        a_sgn_in = np.empty_like(self.a_sgn)
        a_sgn_in[:, 0] = self.a_sgn_q
        a_sgn_in[:, 1:] = self.a_sgn[:, :-1]
        lda_in = np.empty_like(self.lda_q)
        lda_in[:, 0] = inp["load_a_sign"]
        lda_in[:, 1:] = self.lda_q[:, :-1]
        ring_in = np.empty_like(self.ring_q)
        ring_in[:, 0] = inp["ring"]
        ring_in[:, 1:] = self.ring_q[:, :-1]
        dbl_in = np.empty_like(self.dbl_q)
        dbl_in[:, 0] = inp["dbl"]
        dbl_in[:, 1:] = self.dbl_q[:, :-1]
        w_bits_in = np.empty_like(self.w_bits)
        w_bits_in[0] = w_edge
        w_bits_in[1:] = self.w_bits[:-1]
        w_sgn_in = np.empty_like(self.w_sgn)
        w_sgn_in[0] = self.w_sgn_q
        w_sgn_in[1:] = self.w_sgn[:-1]
        ldw_in = np.empty_like(self.ldw_q)
        ldw_in[0] = inp["load_w_sign"]
        ldw_in[1:] = self.ldw_q[:-1]
        if not self.int_hw or self.mech != "ring":
            check(not self.ring_q.any(), "ring control on hardware without the ring mux")
        if not self.int_hw or self.mech != "self":
            check(not self.dbl_q.any(), "dbl control on hardware without the self-shift")

        # ---- tile datapath (all tiles of all PEs at once)
        prod = self.a_bits[:, :, :, None] & self.w_bits[:, :, None, :]   # (pr,pc,NH,NW,NK,M)
        s0a, s0b, s1, s2, s3 = popcount16_csa(prod)
        neg = self.a_sgn[:, :, :, None, :] ^ self.w_sgn[:, :, None, :, :]
        row4 = ((s3 ^ neg) << 3) | ((s2 ^ neg) << 2) | ((s1 ^ neg) << 1) | (s0a ^ neg)
        row1 = s0b ^ neg
        ncnt = neg.sum(-1)
        corr = (-(ncnt << 4)) & SUMMASK                # SUM_W'(-{0,N,4'b0})
        heap_u = (row4.sum(-1) + row1.sum(-1) + corr + self.acc_low) & SUMMASK
        low_sum = to_signed(heap_u, SUM_W)
        # independent reference for the lane trick
        cnt = prod.sum(-1)
        d_ref = np.where(neg == 1, -cnt, cnt).sum(-1)
        exact = d_ref + self.acc_low
        check(np.array_equal(low_sum, exact),
              f"cycle {self.cycle}: CSA lane trick / heap wrap mismatch")
        check(exact.min() >= -NK * M and exact.max() <= (1 << (LOW_W + 1)) - 1,
              f"cycle {self.cycle}: low_sum {exact.min()}..{exact.max()} outside RTL range")
        next_borrow = (heap_u >> (SUM_W - 1)) & 1
        next_carry = (1 - next_borrow) & ((heap_u >> LOW_W) & 1)
        high_next = (self.acc_high + np.where(self.pbor == 1, HIGHMASK, 0)
                     + self.pcar) & HIGHMASK
        acc_out = (high_next << LOW_W) | self.acc_low              # canonical, 24 b
        check(np.array_equal(to_signed(acc_out, OW), self.shadow),
              f"cycle {self.cycle}: canonical acc_out != shadow value")

        # ---- drain chain inputs
        acc_in = np.empty_like(acc_out)
        acc_in[..., 1:] = acc_out[..., :-1]
        west = np.zeros((pr, pc, NH), dtype=np.int64)
        west[:, 1:] = acc_out[:, :-1, :, NW - 1]
        sh_west = np.zeros((pr, pc, NH), dtype=np.int64)
        sh_west[:, 1:] = self.shadow[:, :-1, :, NW - 1]
        if self.int_hw and self.mech == "ring":                       # NEW per-PE mux
            own = (acc_out[:, :, :, NW - 1] << 1) & M24
            rq = self.ring_q[:, :, None]
            west = np.where(rq == 1, own, west)
            sh_west = np.where(rq == 1, 2 * self.shadow[:, :, :, NW - 1], sh_west)
        acc_in[..., 0] = west
        sh_in = np.empty_like(self.shadow)
        sh_in[..., 1:] = self.shadow[..., :-1]
        sh_in[..., 0] = sh_west

        shift = np.broadcast_to((inp["shift_in"] | self.ring_q)[:, :, None, None],
                                acc_out.shape)
        dbl = np.broadcast_to(self.dbl_q[:, :, None, None], acc_out.shape)
        mac = inp["mac_en"]
        reset = inp.get("reset", 0)

        # ---- tile always_ff (priority reset > shift_in > dbl > mac)
        v2 = (acc_out << 1) & M24
        pend = (self.pcar | self.pbor) == 1
        hi_else = np.where(pend, high_next, self.acc_high)
        lo_else = (heap_u & LOWMASK) if mac else self.acc_low
        pc_else = next_carry if mac else np.zeros_like(self.pcar)
        pb_else = next_borrow if mac else np.zeros_like(self.pbor)
        n_low = np.where(shift, acc_in & LOWMASK, np.where(dbl, v2 & LOWMASK, lo_else))
        n_high = np.where(shift, acc_in >> LOW_W, np.where(dbl, v2 >> LOW_W, hi_else))
        n_pc = np.where(shift | dbl, 0, pc_else)
        n_pb = np.where(shift | dbl, 0, pb_else)
        n_sh = np.where(shift, sh_in, np.where(dbl, 2 * self.shadow,
                                               self.shadow + d_ref if mac else self.shadow))
        if reset:
            n_low = n_high = n_pc = n_pb = np.zeros_like(self.acc_low)
            n_sh = np.zeros_like(self.shadow)
        mx = max(abs(int(n_sh.max())), abs(int(n_sh.min())))
        check(mx < (1 << (OW - 1)),
              f"cycle {self.cycle}: true accumulator value {mx} overflows OWIDTH={OW}")
        self.max_abs_shadow = max(self.max_abs_shadow, mx)
        check(not np.any((n_pc == 1) & (n_pb == 1)), "pending carry and borrow both set")

        # ---- PE register updates
        lda_now = self.lda_q[:, :, None, None]
        ldw_now = self.ldw_q[:, :, None, None]
        self.a_sgn = np.where(lda_now == 1, a_sgn_in, self.a_sgn)
        self.w_sgn = np.where(ldw_now == 1, w_sgn_in, self.w_sgn)
        self.a_bits, self.w_bits = a_bits_in, w_bits_in
        self.lda_q, self.ldw_q = lda_in, ldw_in
        self.ring_q, self.dbl_q = ring_in, dbl_in
        self.acc_low, self.acc_high, self.pcar, self.pbor = n_low, n_high, n_pc, n_pb
        self.shadow = n_sh

        # ---- peripheral register updates (NEW: magnitude load gated in INT mode)
        gate = (1 - int_mode) if self.int_hw else 1
        for r in range(pr):
            if inp["load_a"][r]:
                if gate:
                    self.a_bin_q[r] = inp["a_bin"][r]
                self.a_sgn_q[r] = inp["a_sgn"][r]
        for c in range(pc):
            if inp["load_w"][c]:
                if gate:
                    self.w_bin_q[c] = inp["w_bin"][c]
                self.w_sgn_q[c] = inp["w_sgn"][c]
        self.cycle += 1
        return to_signed(acc_out[:, pc - 1, :, NW - 1], OW)   # acc_out_east (pre-edge)


class Combiner:
    """East-edge plane combiner for one PE row (register level)."""

    def __init__(self, groups, horner_len):
        self.groups = groups            # list of [(h, coef), ...]
        self.L = horner_len
        self.R = [0] * len(groups)
        self.t = 0

    def edge(self, x):
        out = []
        for g, rows in enumerate(self.groups):
            s = sum(coef * int(x[h]) for h, coef in rows)
            self.R[g] = s if self.t % self.L == 0 else 2 * self.R[g] + s
            check(abs(self.R[g]) < (1 << (COMB_W - 1)), "combiner register overflow")
            if self.t % self.L == self.L - 1:
                out.append((g, self.t, self.R[g]))
        self.t += 1
        return out


# ============================================================ data mover ==
def plane(x, p, bits):
    return (np.asarray(x, dtype=np.int64) & ((1 << bits) - 1)) >> p & 1


class Mapping:
    def __init__(self, mode, ba, bw, mech):
        self.mode, self.ba, self.bw, self.mech = mode, ba, bw, mech
        assert 8 % ba == 0 and 8 % bw == 0
        if mode == "S":
            self.rows = [(h // ba, h % ba) for h in range(NH)]     # (i_local, p) p fixed
            self.cols = [(v // bw, v % bw) for v in range(NW)]
            self.stages = [[(None, None)]]
        elif mode == "HW":
            self.rows = [(h // ba, h % ba) for h in range(NH)]
            self.cols = [(v, None) for v in range(NW)]
            self.stages = [[(None, q)] for q in reversed(range(bw))]
        elif mode == "HA":
            self.rows = [(h, None) for h in range(NH)]
            self.cols = [(v // bw, v % bw) for v in range(NW)]
            self.stages = [[(p, None)] for p in reversed(range(ba))]
        elif mode == "HB":
            self.rows = [(h, None) for h in range(NH)]
            self.cols = [(v, None) for v in range(NW)]
            self.stages = [[(p, s - p) for p in range(ba) if 0 <= s - p < bw]
                           for s in reversed(range(ba + bw - 1))]
        else:
            raise ValueError(mode)
        self.rows_pe = max(r[0] for r in self.rows) + 1
        self.cols_pe = max(c[0] for c in self.cols) + 1
        if len(self.stages) > 1:
            assert mech in ("ring", "self"), f"{mode} needs a doubling mechanism"
        # combiner
        if mode in ("S", "HW"):
            self.groups = [[(gi * ba + p, 1 << p) for p in range(ba)]
                           for gi in range(NH // ba)]
        else:
            self.groups = [[(h, 1)] for h in range(NH)]
        self.horner = bw if mode in ("S", "HA") else 1

    def row_plane(self, h, pt):
        i, p = self.rows[h]
        return i, (pt if p is None else p)

    def col_plane(self, v, qt):
        j, q = self.cols[v]
        return j, (qt if q is None else q)


def block_stream(mp, A, W, ti, tj, pr, pc):
    """Logical per-tau stream for one output block (tau 0 = sign preload).

    Returns list of dict(tau-events) and tau_last (last data tau)."""
    K = A.shape[1]
    nb = -(-K // 128)
    dbl_len = {"ring": NW, "self": 1, "none": 0}[mp.mech]
    ev = []                          # each: dict(kind, pass(pt,qt), b, ctl)
    first = True
    for si, stage in enumerate(mp.stages):
        if si > 0:
            for t in range(dbl_len):
                ev.append(dict(kind="bubble", ctl=("ring" if mp.mech == "ring" else "dbl")))
        for (pt, qt) in stage:
            ev.append(dict(kind="sign", pt=pt, qt=qt))   # attach sign load to previous slot
            for b in range(nb):
                ev.append(dict(kind="data", pt=pt, qt=qt, b=b))
    # fold sign events into the previous tau (preload one cycle early)
    taus = [dict(sign=None, data=None, ctl=None)]
    for e in ev:
        if e["kind"] == "sign":
            check(taus[-1]["sign"] is None, "two sign loads in one cycle")
            taus[-1]["sign"] = (e["pt"], e["qt"])
        elif e["kind"] == "data":
            taus.append(dict(sign=None, data=(e["pt"], e["qt"], e["b"]), ctl=None))
        else:
            taus.append(dict(sign=None, data=None, ctl=e["ctl"]))
    tau_last = max(t for t, x in enumerate(taus) if x["data"] is not None)
    return taus, tau_last


def edge_values(mp, A, W, ti, tj, pr, pc, taus):
    """Precompute per-tau A-edge and W-edge raw bits and signs."""
    K = A.shape[1]
    Mt, Nt = A.shape[0], W.shape[1]
    a_rows = pr * mp.rows_pe
    w_cols = pc * mp.cols_pe
    cache_a, cache_w = {}, {}

    def a_edge(r, pt, b):
        key = (r, pt, b)
        if key not in cache_a:
            bits = np.zeros((NH, NK, M), dtype=np.int64)
            for h in range(NH):
                il, p = mp.row_plane(h, pt)
                i = ti * a_rows + r * mp.rows_pe + il
                if i >= Mt:
                    continue
                kk = 128 * b + np.arange(128)
                vals = np.where(kk < K, A[i, np.minimum(kk, K - 1)], 0)
                bits[h] = plane(vals, p, mp.ba).reshape(NK, M)
            cache_a[key] = bits
        return cache_a[key]

    def w_edge(c, qt, b):
        key = (c, qt, b)
        if key not in cache_w:
            bits = np.zeros((NW, NK, M), dtype=np.int64)
            for v in range(NW):
                jl, q = mp.col_plane(v, qt)
                j = tj * w_cols + c * mp.cols_pe + jl
                if j >= Nt:
                    continue
                kk = 128 * b + np.arange(128)
                vals = np.where(kk < K, W[np.minimum(kk, K - 1), j], 0)
                bits[v] = plane(vals, q, mp.bw).reshape(NK, M)
            cache_w[key] = bits
        return cache_w[key]

    def a_sign(pt):
        s = np.zeros((NH, NK), dtype=np.int64)
        for h in range(NH):
            _, p = mp.row_plane(h, pt)
            s[h, :] = int(p == mp.ba - 1)
        return s

    def w_sign(qt):
        s = np.zeros((NW, NK), dtype=np.int64)
        for v in range(NW):
            _, q = mp.col_plane(v, qt)
            s[v, :] = int(q == mp.bw - 1)
        return s

    return a_edge, w_edge, a_sign, w_sign


def run_gemm(A, W, mode, ba, bw, pr, pc, mech, rng, verbose=False):
    """Run a full GEMM through the grid; return (out, stats)."""
    mp = Mapping(mode, ba, bw, mech)
    Mt, K = A.shape
    Nt = W.shape[1]
    a_rows, w_cols = pr * mp.rows_pe, pc * mp.cols_pe
    tiles = [(ti, tj) for ti in range(-(-Mt // a_rows)) for tj in range(-(-Nt // w_cols))]
    grid = Grid(pr, pc, mech if mode != "S" else "none")
    combs = None
    out = np.full((Mt, Nt), None, dtype=object)
    # schedule all blocks
    blocks = []
    n0 = 0
    for (ti, tj) in tiles:
        taus, tau_last = block_stream(mp, A, W, ti, tj, pr, pc)
        n_d = n0 + tau_last + pr + pc
        blocks.append(dict(ti=ti, tj=tj, n0=n0, taus=taus, tau_last=tau_last, n_d=n_d,
                           fns=edge_values(mp, A, W, ti, tj, pr, pc, taus)))
        n0 = n_d + NW * pc - 2
    n_end = blocks[-1]["n_d"] + NW * pc
    zero_a = np.zeros((NH, NK, M), dtype=np.int64)
    zero_w = np.zeros((NW, NK, M), dtype=np.int64)
    zs = np.zeros((NH, NK), dtype=np.int64)
    bi = 0
    drain_t = {}
    for n in range(n_end):
        inp = dict(int_mode=1, mac_en=1, shift_in=0,
                   a_rand=rng.integers(0, 256, M), w_rand=rng.integers(0, 256, M),
                   a_raw=np.zeros((pr, NH, NK, M), dtype=np.int64),
                   w_raw=np.zeros((pc, NW, NK, M), dtype=np.int64),
                   a_bin=rng.integers(0, 256, (pr, NH, NK)),   # junk: must be gated off
                   w_bin=rng.integers(0, 256, (pc, NW, NK)),
                   a_sgn=np.zeros((pr, NH, NK), dtype=np.int64),
                   w_sgn=np.zeros((pc, NW, NK), dtype=np.int64),
                   load_a=[0] * pr, load_w=[0] * pc,
                   load_a_sign=np.zeros(pr, dtype=np.int64),
                   load_w_sign=np.zeros(pc, dtype=np.int64),
                   ring=np.zeros(pr, dtype=np.int64), dbl=np.zeros(pr, dtype=np.int64))
        draining = None
        for blk in blocks:
            a_edge, w_edge, a_sign, w_sign = blk["fns"]
            for r in range(pr):
                tau = n - blk["n0"] - r
                if 0 <= tau < len(blk["taus"]):
                    ev = blk["taus"][tau]
                    if ev["data"] is not None:
                        pt, qt, b = ev["data"]
                        inp["a_raw"][r] = a_edge(r, pt, b)
                    if ev["sign"] is not None:
                        inp["a_sgn"][r] = a_sign(ev["sign"][0])
                        inp["load_a"][r] = 1
                        inp["load_a_sign"][r] = 1
                    if ev["ctl"] == "ring":
                        inp["ring"][r] = 1
                    elif ev["ctl"] == "dbl":
                        inp["dbl"][r] = 1
            for c in range(pc):
                tau = n - blk["n0"] - c
                if 0 <= tau < len(blk["taus"]):
                    ev = blk["taus"][tau]
                    if ev["data"] is not None:
                        pt, qt, b = ev["data"]
                        inp["w_raw"][c] = w_edge(c, qt, b)
                    if ev["sign"] is not None:
                        inp["w_sgn"][c] = w_sign(ev["sign"][1])
                        inp["load_w"][c] = 1
                        inp["load_w_sign"][c] = 1
            if blk["n_d"] <= n < blk["n_d"] + NW * pc:
                check(draining is None, "overlapping drains")
                draining = blk
        if draining is not None:
            inp["shift_in"] = 1
        east = grid.step(inp)
        if draining is not None:
            blk = draining
            if blk["n_d"] == n:
                combs = [Combiner(mp.groups, mp.horner) for _ in range(pr)]
            t = n - blk["n_d"]
            for r in range(pr):
                for (g, tt, val) in combs[r].edge(east[r]):
                    c = pc - 1 - tt // NW
                    v = NW - 1 - tt % NW
                    il = mp.rows[mp.groups[g][0][0]][0]
                    jl = mp.cols[v][0]
                    i = blk["ti"] * a_rows + r * mp.rows_pe + il
                    j = blk["tj"] * w_cols + c * mp.cols_pe + jl
                    if i < Mt and j < Nt:
                        check(out[i, j] is None, f"output ({i},{j}) emitted twice")
                        out[i, j] = val
    check(all(x is not None for x in out.flat), "some outputs never emitted")
    ref = A.astype(np.int64) @ W.astype(np.int64)
    got = out.astype(np.int64)
    if not np.array_equal(got, ref):
        bad = np.argwhere(got != ref)[0]
        raise ModelError(f"{mode}/{mech} INT{ba}xINT{bw}: out{tuple(bad)}={got[tuple(bad)]} "
                         f"!= numpy {ref[tuple(bad)]}")
    b0 = blocks[0]
    blk_cycles = (blocks[1]["n0"] - blocks[0]["n0"]) if len(blocks) > 1 else \
        b0["tau_last"] + pr + pc + NW * pc - 2
    data_cycles = sum(1 for x in b0["taus"] if x["data"] is not None)
    stats = dict(cycles=n_end, blocks=len(blocks), block_cycles=blk_cycles,
                 data_cycles=data_cycles, max_tile=grid.max_abs_shadow,
                 max_out=int(np.abs(ref).max()))
    return got, stats


# ======================================================= SC transparency ==
def sc_transparency(pr, pc, rng, n_blocks=3, mech="ring"):
    """SC stimulus on (a) datapath with INT additions present but idle and
    (b) original datapath: every register must match every cycle; the shadow
    check inside Grid.step already compares against an independent popcount."""
    ga = Grid(pr, pc, mech, int_hw=True)
    gb = Grid(pr, pc, "none", int_hw=False)
    T = 8
    for blk in range(n_blocks):
        a_bin = rng.integers(0, 256, (pr, NH, NK))
        w_bin = rng.integers(0, 256, (pc, NW, NK))
        a_sgn = rng.integers(0, 2, (pr, NH, NK))
        w_sgn = rng.integers(0, 2, (pc, NW, NK))
        for t in range(T):
            inp = dict(int_mode=0, mac_en=1, shift_in=0,
                       a_rand=rng.integers(0, 256, M), w_rand=rng.integers(0, 256, M),
                       a_raw=np.zeros((pr, NH, NK, M), dtype=np.int64),
                       w_raw=np.zeros((pc, NW, NK, M), dtype=np.int64),
                       a_bin=a_bin, w_bin=w_bin, a_sgn=a_sgn, w_sgn=w_sgn,
                       load_a=[int(t == 0)] * pr, load_w=[int(t == 0)] * pc,
                       load_a_sign=np.full(pr, int(t == 0)),
                       load_w_sign=np.full(pc, int(t == 0)),
                       ring=np.zeros(pr, dtype=np.int64), dbl=np.zeros(pr, dtype=np.int64))
            ea, eb = ga.step(inp), gb.step(inp)
            for x, y in zip(ga.state(), gb.state()):
                check(np.array_equal(x, y), "SC transparency: register mismatch")
            check(np.array_equal(ea, eb), "SC transparency: acc_out_east mismatch")
    # drain
    for t in range(NW * pc + pr + pc):
        inp["shift_in"] = int(t >= pr + pc)
        inp["load_a"], inp["load_w"] = [0] * pr, [0] * pc
        inp["load_a_sign"], inp["load_w_sign"] = np.zeros(pr, int), np.zeros(pc, int)
        ea, eb = ga.step(inp), gb.step(inp)
        check(np.array_equal(ea, eb), "SC transparency: drain mismatch")
    return ga.cycle, ga.max_abs_shadow


# ================================================================ driver ==
def gen(kind, Mt, K, Nt, ba, bw, rng):
    lo_a, hi_a = -(1 << (ba - 1)), (1 << (ba - 1)) - 1
    lo_w, hi_w = -(1 << (bw - 1)), (1 << (bw - 1)) - 1
    if kind == "random":
        A = rng.integers(lo_a, hi_a + 1, (Mt, K))
        W = rng.integers(lo_w, hi_w + 1, (K, Nt))
        A.flat[0], A.flat[-1], W.flat[0], W.flat[-1] = lo_a, hi_a, lo_w, hi_w
    elif kind == "allmax":
        A, W = np.full((Mt, K), hi_a), np.full((K, Nt), hi_w)
    elif kind == "allmin":
        A, W = np.full((Mt, K), lo_a), np.full((K, Nt), lo_w)
    elif kind == "minmax":
        A, W = np.full((Mt, K), lo_a), np.full((K, Nt), hi_w)
    elif kind == "alternating":
        ev = (np.arange(K) % 2 == 0)
        A = np.empty((Mt, K), dtype=np.int64)
        A[0::2] = np.where(ev, hi_a, lo_a)[None, :]
        A[1::2] = np.where(ev, lo_a, hi_a)[None, :]
        W = np.empty((K, Nt), dtype=np.int64)
        W[:, 0::2] = np.where(ev, lo_w, hi_w)[:, None]
        W[:, 1::2] = np.where(ev, hi_w, lo_w)[:, None]
    else:
        raise ValueError(kind)
    return A.astype(np.int64), W.astype(np.int64)


PREC = {"INT8": (8, 8), "W4A8": (8, 4), "INT4": (4, 4)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--seed", type=int, default=20261003)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    t0 = time.time()
    n_ok = 0

    print("== SC transparency (INT hardware present, idle) ==")
    for (pr, pc), mech in [((1, 1), "ring"), ((2, 3), "ring"), ((2, 2), "self")]:
        cyc, mx = sc_transparency(pr, pc, rng, mech=mech)
        print(f"  {pr}x{pc} {mech:4s}: {cyc} cycles, every register identical to the "
              f"original datapath; tile values == independent popcount (max |acc| {mx})")
        n_ok += 1

    print("\n== INT GEMM vs numpy (register level) ==")
    configs = [("S", "none"), ("HW", "ring"), ("HW", "self"), ("HB", "ring"),
               ("HB", "self"), ("HA", "ring")]
    grids = [(1, 1), (2, 3)] if args.quick else [(1, 1), (2, 2), (2, 3)]
    Ks = [8, 64, 1024] if args.quick else [8, 64, 200, 1024]
    kinds = ["allmax", "allmin", "minmax", "alternating"]
    for (pr, pc) in grids:
        for prec, (ba, bw) in PREC.items():
            for mode, mech in configs:
                if mode == "HB" and prec == "INT8":
                    continue                       # OWIDTH-limited; tested below
                mp = Mapping(mode, ba, bw, mech)
                Mt = pr * mp.rows_pe + (1 if pr > 1 else 0)   # partial last tile
                Nt = pc * mp.cols_pe + (1 if pc > 1 else 0)
                runs = [("random", K) for K in Ks] + [(k, 1024) for k in kinds]
                for kind, K in runs:
                    if (pr, pc) == (2, 2) and kind != "random":
                        continue
                    A, W = gen(kind, Mt, K, Nt, ba, bw, rng)
                    _, st = run_gemm(A, W, mode, ba, bw, pr, pc, mech, rng)
                    n_ok += 1
                    print(f"  {pr}x{pc} {prec:4s} {mode:2s}/{mech:4s} {kind:11s} K={K:5d} "
                          f"M={Mt:2d} N={Nt:2d}: exact; {st['blocks']} blocks, "
                          f"{st['block_cycles']} cyc/block ({st['data_cycles']} data), "
                          f"max|tile|={st['max_tile']}, max|out|={st['max_out']}")

    print("\n== HB INT8 (full product in the 24-bit tile) ==")
    A, W = gen("random", 8, 64, 8, 8, 8, rng)
    run_gemm(A, W, "HB", 8, 8, 1, 1, "ring", rng)
    n_ok += 1
    print("  random K=64: exact")
    A, W = gen("allmin", 8, 1024, 8, 8, 8, rng)
    try:
        run_gemm(A, W, "HB", 8, 8, 1, 1, "ring", rng)
        raise SystemExit("FAIL: expected an OWIDTH overflow error")
    except ModelError as e:
        print(f"  all -128, K=1024 (|out| = 16,777,216 >= 2^23): model fails loudly as "
              f"required -> {e}")
    n_ok += 1

    print("\n== negative control: HW with the ring doubling suppressed ==")
    A, W = gen("random", 8, 256, 8, 8, 8, rng)
    orig_step = Grid.step

    def broken(self, inp):
        inp = dict(inp)
        inp["ring"] = np.zeros_like(inp["ring"])
        return orig_step(self, inp)
    Grid.step = broken
    try:
        run_gemm(A, W, "HW", 8, 8, 1, 1, "ring", rng)
        raise SystemExit("FAIL: suppressed doubling was not detected")
    except ModelError as e:
        print(f"  detected -> {str(e)[:110]}")
    finally:
        Grid.step = orig_step
    n_ok += 1

    print(f"\nALL {n_ok} CHECKS PASSED in {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()
