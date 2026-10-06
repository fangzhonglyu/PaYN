#!/usr/bin/env python3
"""Adversarial scenario generator for the BP INT RTL (tb_bp_vec.sv).

Independent of the implementer's bench/generator/checker.  A scenario is a
stream of output blocks (each: precision, activation rows, 8 weight columns,
reduction length L that need not be a multiple of 128).  The generator

  1. builds a per-edge tile-op schedule (MAC / RING / DRAIN / IDLE / RESET),
  2. derives every DUT input per edge from the ops and the timing contract
         MAC at P_n    -> raw planes launched for P_{n-1}, mac_en at P_n
         RING at P_n   -> ring_in launched for P_{n-1}   (ring_q latency)
                          and shift_in at P_n (post-review contract; optional
                          since the per-PE lap enable, csa_bp_20261004_lap,
                          where ring_q alone shifts: Opts.lap_shift=False)
         DRAIN at P_n  -> shift_in at P_n, acc_in_west = 0
         sign pipe update at P_e -> load_X + load_X_sign + sign word at P_{e-1}
                                    legal window e in [prev MAC edge, next MAC - 1]
         INT-mode loads -> zero magnitudes (zero_bin); first INT edge after SC
                           traffic -> load_a + load_w with zero magnitudes
                           (post-review contract: magnitudes held at 0 in INT)
     with optional deliberate timing errors (sign, ring, int_prec shifts),
  3. computes the numpy int64 reference (bit-plane tiles and A @ W), and the
     exact trace positions where drained columns and combiner words must appear.

Outputs in OUT_DIR: bpv_vec.hex (bench records), bpv_expect.json.

The reference derivation (my own, from the mode definition):
  INT8:  tile(h, v) = s_h * sum_x bit_h(A[i, x]) * W[x, j_v],   s_h = -1 iff h == 7
  W4A8:  same, W in [-8, 7] (4 weight passes, w_sign in the q = 3 pass)
  INT4:  rows 0-3 -> activation row i0, plane h; rows 4-7 -> row i1, plane h-4;
         s = -1 for planes 3 and 7.  out_lo = (A@W)[i0, j], out_hi = (A@W)[i1, j]
Hardware order: weight bit q passes MSB first, w_sign = 1 in the q = BW-1 pass,
negate = a_sign ^ w_sign, x2 lap between passes (exact mod 2^24).

Usage: bpv_gen.py --scenario NAME --out-dir DIR      (bpv_gen.py --list)
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

K, M, NH, NW, OW = 8, 16, 8, 8, 24
LANE = K * M                     # 128 reduction elements per data cycle
REC_W = 2384


def bits_of(v: np.ndarray, p: int, nbits: int) -> np.ndarray:
    return ((v.astype(np.int64) & ((1 << nbits) - 1)) >> p) & 1


@dataclass
class Block:
    prec: str                    # int8 | w4a8 | int4
    A: np.ndarray                # (rows, L) rows = 1 (int8/w4a8) or 2 (int4)
    W: np.ndarray                # (L, 8)
    tag: str = ""
    BA: int = 0
    BW: int = 0
    L: int = 0
    NB: int = 0
    tiles: np.ndarray = field(default=None)   # (8 rows h, 8 cols v) int64
    out: np.ndarray = field(default=None)     # (8 cols v, 2) int64 (lo, hi)
    int_prec: int = 0

    def __post_init__(self):
        self.BA = 4 if self.prec == "int4" else 8
        self.BW = 8 if self.prec == "int8" else 4
        self.int_prec = 1 if self.prec == "int4" else 0
        self.L = self.A.shape[1]
        assert self.W.shape == (self.L, NW)
        assert self.A.shape[0] == NH // self.BA
        alo, ahi = -(1 << (self.BA - 1)), (1 << (self.BA - 1)) - 1
        wlo, whi = -(1 << (self.BW - 1)), (1 << (self.BW - 1)) - 1
        assert self.A.min() >= alo and self.A.max() <= ahi, "A out of range"
        assert self.W.min() >= wlo and self.W.max() <= whi, "W out of range"
        self.NB = -(-self.L // LANE)
        W64 = self.W.astype(np.int64)
        self.tiles = np.zeros((NH, NW), np.int64)
        for h in range(NH):
            i, p = h // self.BA, h % self.BA
            s = -1 if p == self.BA - 1 else 1
            self.tiles[h] = s * (bits_of(self.A[i], p, self.BA) @ W64)
        gemm = self.A.astype(np.int64) @ W64          # (rows, 8)
        self.out = np.zeros((NW, 2), np.int64)
        self.out[:, 0] = gemm[0]
        if self.prec == "int4":
            self.out[:, 1] = gemm[1]
        # Reference self-check: the plane identity.
        for r in range(NH // self.BA):
            recon = sum((1 << p) * self.tiles[r * self.BA + p] for p in range(self.BA))
            assert np.array_equal(recon, gemm[r]), "plane identity broken (reference bug)"

    def a_raw(self, b: int) -> int:
        """1024-bit a_raw_in for data cycle b: bit (h*K+k)*M+m = bit p of A[i, 128b+16k+m]."""
        bits = np.zeros((NH, LANE), np.uint8)
        lo, hi = b * LANE, min((b + 1) * LANE, self.L)
        for h in range(NH):
            i, p = h // self.BA, h % self.BA
            bits[h, : hi - lo] = bits_of(self.A[i, lo:hi], p, self.BA)
        return pack(bits.reshape(-1))

    def w_raw(self, b: int, q: int) -> int:
        bits = np.zeros((NW, LANE), np.uint8)
        lo, hi = b * LANE, min((b + 1) * LANE, self.L)
        for v in range(NW):
            bits[v, : hi - lo] = bits_of(self.W[lo:hi, v], q, self.BW)
        return pack(bits.reshape(-1))

    def a_sign_word(self) -> int:
        w = 0
        for h in range(NH):
            if h % self.BA == self.BA - 1:
                for k in range(K):
                    w |= 1 << (h * K + k)
        return w


def pack(bits: np.ndarray) -> int:
    return int.from_bytes(np.packbits(bits.astype(np.uint8), bitorder="little").tobytes(), "little")


# --------------------------------------------------------------- schedule --
@dataclass
class Opts:
    idle_prob: float = 0.0       # random IDLE edges between any two ops
    mac_always: bool = False     # mac_en = 1 on every non-reset edge (zero bubbles on IDLE)
    raw_junk: bool = False       # random raw planes wherever they cannot matter
    acc_junk: bool = False       # random acc_in_west on every non-drain edge
    bin_junk: bool = False       # rng_en = 1, random magnitudes, load_a/load_w + random signs every edge
    prec_junk: bool = False      # random int_prec on every non-drain edge
    reset_dirty: bool = False    # random control inputs while reset is asserted
    sign_pos: str = "late"       # late | early | random  (position inside the legal window)
    gap_between_blocks: int = 0
    seed: int = 1
    # Deliberate errors: list of (kind, index, delta)
    #   ("wsign", change_idx, d) / ("asign", change_idx, d): shift one sign-pipe update by d edges
    #   ("ring", lap_idx, d): shift the ring_in of one whole lap by d edges
    #   ("ringlen", lap_idx, d): lap with 8+d ring edges instead of 8
    #   ("ringstray", mac_idx, 0): one extra ring_in pulse one edge ahead of the
    #                              mac_idx-th MAC edge (lap-enable contract: a lap edge)
    #   ("prec", block_idx, d): switch int_prec to block idx's precision d edges early
    inject: list = field(default_factory=list)
    resets: list = field(default_factory=list)   # (block_idx, op_offset_in_block, n_reset_edges)
    # SC-mode traffic around the INT stream (int_mode = 0, ring_in = 0, everything
    # else random, comparators live): sc_prefix edges + an 8-edge SC drain before
    # the first INT block, sc_suffix edges right after the last INT drain.
    sc_prefix: int = 0
    sc_suffix: int = 0
    first_int_mac: int = -1      # force mac_en (0/1) on the first int_mode=1 edge after the SC prefix
    sc_zero_mag: bool = False    # SC prefix loads zero magnitudes (comparators output 0)
    last_int_raw_junk: bool = False  # random raw planes on the last INT edge before the SC suffix
    sc_tail_drain: bool = False  # end the SC suffix with an SC drain (for INT->SC A/B comparisons)
    sc_suffix_clean: bool = False  # SC suffix: mac_en = 1, shift_in = 0, no loads (pure SC accumulation)
    # Post-review contract (implementer, after the design review):
    lap_shift: bool = True         # shift_in on ring-lap edges (required before csa_bp_20261004_lap,
                                   # where ring_q only steered the west mux; optional since)
    int_zero_mag: bool = True      # every INT-mode load carries zero magnitudes
    int_entry_zero_load: bool = True  # load_a + load_w (zero magnitudes) on the first INT edge after SC


def build(blocks: list[Block], o: Opts):
    rng = np.random.default_rng(o.seed)
    ops: list[tuple] = []
    for _ in range(3):
        ops.append(("reset",))
    # The sign loads need two non-reset edges before the first MAC.
    ops.extend([("idle",)] * 3)
    if o.sc_prefix:
        ops.extend([("sc",)] * o.sc_prefix + [("scdrain",)] * NW + [("idle",)] * 3)
    lap_counter = [0]

    def maybe_idle():
        while o.idle_prob and rng.random() < o.idle_prob:
            ops.append(("idle",))

    def block_ops(bi: int, blk: Block):
        seq = []
        for pi in range(blk.BW):
            for b in range(blk.NB):
                seq.append(("mac", bi, pi, b))
            if pi < blk.BW - 1:
                n_ring = 8
                for kind, idx, d in o.inject:
                    if kind == "ringlen" and idx == lap_counter[0]:
                        n_ring = 8 + d
                for r in range(n_ring):
                    seq.append(("ring", bi, pi, r, lap_counter[0]))
                lap_counter[0] += 1
        for t in range(NW):
            seq.append(("drain", bi, t))
        return seq

    for bi, blk in enumerate(blocks):
        if bi and o.gap_between_blocks:
            ops.extend([("idle",)] * o.gap_between_blocks)
        seq = block_ops(bi, blk)
        resets = [r for r in o.resets if r[0] == bi]
        if resets:
            _, off, nres = resets[0]
            for op in seq[:off]:
                ops.append(op)
                maybe_idle()
            ops.extend([("reset",)] * nres)
            ops.extend([("idle",)] * 3)
            # Restart the whole block (lap ids continue; no scenario combines
            # resets with lap injections).
            seq = block_ops(bi, blk)
        for op in seq:
            ops.append(op)
            maybe_idle()
    if o.sc_suffix:
        ops.extend([("sc",)] * o.sc_suffix)
        if o.sc_tail_drain:
            ops.extend([("scdrain",)] * NW)
    for _ in range(6):
        ops.append(("idle",))
    return ops


def derive(blocks: list[Block], ops: list[tuple], o: Opts):
    rng = np.random.default_rng(o.seed + 1000)
    N = len(ops)
    f = {k: np.zeros(N, np.int64) for k in
         ("reset", "int_mode", "int_prec", "ring_in", "shift_in", "mac_en", "load_a", "load_w",
          "load_a_sign", "load_w_sign", "rng_en", "junk_bin", "zero_bin")}
    a_raw = [None] * N
    w_raw = [None] * N
    a_sg = [None] * N
    w_sg = [None] * N
    acc = [0] * N
    f["int_mode"][:] = 1
    for n, op in enumerate(ops):
        if op[0] == "reset":
            f["reset"][n] = 1

    # MAC: raw at n-1, mac_en at n.
    for n, op in enumerate(ops):
        if op[0] == "mac":
            _, bi, pi, b = op
            blk = blocks[bi]
            q = blk.BW - 1 - pi
            assert a_raw[n - 1] is None
            a_raw[n - 1] = blk.a_raw(b)
            w_raw[n - 1] = blk.w_raw(b, q)
            f["mac_en"][n] = 1
    # RING: ring_in at n-1 (+ injected shifts).
    lap_shift = {idx: d for kind, idx, d in o.inject if kind == "ring"}
    for n, op in enumerate(ops):
        if op[0] == "ring":
            d = lap_shift.get(op[4], 0)
            f["ring_in"][n - 1 + d] = 1
    mac_edges = [n for n, op in enumerate(ops) if op[0] == "mac"]
    for kind, idx, d in o.inject:
        if kind == "ringstray":
            f["ring_in"][mac_edges[idx] - 1] = 1
    # DRAIN (and, post-review, every nominal ring-lap edge).
    for n, op in enumerate(ops):
        if op[0] == "drain" or (op[0] == "ring" and o.lap_shift):
            f["shift_in"][n] = 1

    # Sign pipe updates.
    def schedule_signs(name: str, need):
        """need(op) -> required sign word for a MAC op.  Returns list of update edges."""
        cur = 0
        prev_mac = None
        last_reset = None
        changes = []
        for n, op in enumerate(ops):
            if op[0] in ("reset", "sc", "scdrain"):
                # after SC traffic the sign pipes hold junk: force a load
                cur = 0 if op[0] == "reset" else -1
                prev_mac = None
                last_reset = n
                continue
            if op[0] != "mac":
                continue
            s = need(op)
            if s != cur:
                lo_bound = prev_mac if prev_mac is not None else -10**9
                if last_reset is not None:
                    lo_bound = max(lo_bound, last_reset + 2)
                lo_bound = max(lo_bound, 1)
                assert lo_bound <= n - 1, f"{name}: empty sign window before MAC at {n}"
                if o.sign_pos == "early":
                    e = lo_bound
                elif o.sign_pos == "random":
                    e = int(rng.integers(lo_bound, n))
                else:
                    e = n - 1
                changes.append((e, s, lo_bound, n - 1))
                cur = s
            prev_mac = n
        return changes

    w_changes = schedule_signs("w", lambda op: ((1 << (NW * K)) - 1) if op[2] == 0 else 0)
    a_changes = schedule_signs("a", lambda op: blocks[op[1]].a_sign_word())
    sign_fields = {"w": ("load_w", "load_w_sign", w_sg), "a": ("load_a", "load_a_sign", a_sg)}
    inj_sign = {(kind[0], idx): d for kind, idx, d in o.inject if kind in ("wsign", "asign")}
    windows = {}
    for x, changes in (("w", w_changes), ("a", a_changes)):
        ld, lds, arr = sign_fields[x]
        windows[x] = [(lo, hi) for (_, _, lo, hi) in changes]
        for ci, (e, s, lo, hi) in enumerate(changes):
            e += inj_sign.get((x, ci), 0)
            assert ops[e - 1][0] not in ("reset", "sc", "scdrain") and arr[e - 1] is None, f"{x} sign load collision at {e-1}"
            f[ld][e - 1] = 1
            f[lds][e - 1] = 1
            arr[e - 1] = s

    # int_prec: the precision of the block that owns the most recent drain/MAC;
    # it switches on the first edge after the previous block's last drain.
    owner = [None] * N
    cur = blocks[0].int_prec if blocks else 0
    for n, op in enumerate(ops):
        if op[0] in ("mac", "ring", "drain"):
            cur = blocks[op[1]].int_prec
        owner[n] = cur
    prec = np.array(owner, np.int64)
    for kind, bi, d in o.inject:
        if kind == "prec":
            first = next(n for n, op in enumerate(ops) if op[0] == "mac" and op[1] == bi)
            prec[first - d:first] = blocks[bi].int_prec
    f["int_prec"][:] = prec

    # Adversarial junk.
    for n in range(N):
        is_reset = f["reset"][n] == 1
        if o.prec_junk and ops[n][0] != "drain":
            f["int_prec"][n] = int(rng.integers(0, 2))
        if o.acc_junk and ops[n][0] != "drain":
            acc[n] = int.from_bytes(rng.bytes(NH * OW // 8), "little")
        if o.bin_junk:
            f["rng_en"][n] = 1
            f["junk_bin"][n] = 1
            if not is_reset:
                for x in ("a", "w"):
                    ld, lds, arr = sign_fields[x]
                    # Post-review: extra loads on random edges only, so the
                    # magnitude lines also toggle on edges that load nothing.
                    if not f[ld][n] and (not o.int_zero_mag or rng.random() < 0.5):
                        f[ld][n] = 1
                        arr[n] = int.from_bytes(rng.bytes(8), "little")
        if is_reset and o.reset_dirty:
            for k in ("ring_in", "shift_in", "mac_en", "load_a", "load_w", "load_a_sign",
                      "load_w_sign", "int_prec"):
                # do not disturb loads that the schedule needs right after reset
                if f[k][n] == 0:
                    f[k][n] = int(rng.integers(0, 2))
            acc[n] = int.from_bytes(rng.bytes(NH * OW // 8), "little")
    # Raw planes where they cannot matter: edge n-1 raw is free unless op n is
    # a MAC, or op n is an IDLE with mac_en.
    for n in range(N):
        if a_raw[n] is None:
            nxt = ops[n + 1] if n + 1 < N else ("idle",)
            mac_next = o.mac_always and nxt[0] == "idle"
            if o.raw_junk and not mac_next:
                a_raw[n] = int.from_bytes(rng.bytes(128), "little")
                w_raw[n] = int.from_bytes(rng.bytes(128), "little")
            else:
                a_raw[n] = 0
                w_raw[n] = 0
    if o.mac_always:
        for n in range(N):
            if not f["reset"][n]:
                f["mac_en"][n] = 1
    # SC-mode edges: override everything (int_mode = 0, ring_in = 0).
    for n, op in enumerate(ops):
        if op[0] not in ("sc", "scdrain"):
            continue
        f["int_mode"][n] = 0
        f["ring_in"][n] = 0
        f["rng_en"][n] = 1
        f["junk_bin"][n] = 1
        for k in ("int_prec", "mac_en", "load_a", "load_w", "load_a_sign", "load_w_sign"):
            f[k][n] = int(rng.integers(0, 2))
        a_raw[n] = int.from_bytes(rng.bytes(128), "little")
        w_raw[n] = int.from_bytes(rng.bytes(128), "little")
        a_sg[n] = int.from_bytes(rng.bytes(8), "little")
        w_sg[n] = int.from_bytes(rng.bytes(8), "little")
        if op[0] == "sc":
            f["shift_in"][n] = int(rng.random() < 0.3)
            acc[n] = int.from_bytes(rng.bytes(NH * OW // 8), "little")
        else:
            f["shift_in"][n] = 1
            acc[n] = 0
        if o.sc_zero_mag:
            f["junk_bin"][n] = 0      # a/w_binary_in stay 0, so every load clears the magnitudes
        if o.sc_suffix_clean and any(p[0] == "drain" for p in ops[:n]):
            f["mac_en"][n] = 1
            for k in ("load_a", "load_w", "load_a_sign", "load_w_sign"):
                f[k][n] = 0
            if op[0] == "sc":
                f["shift_in"][n] = 0
                acc[n] = 0
    if o.first_int_mac >= 0:
        last_sc = max((n for n, op in enumerate(ops) if op[0] == "scdrain" and
                       not any(p[0] == "mac" for p in ops[:n])), default=None)
        if last_sc is not None:
            f["mac_en"][last_sc + 1] = o.first_int_mac
    if o.last_int_raw_junk:
        jr = np.random.default_rng(o.seed + 7)
        first_sfx = next(n for n in range(N - 1, -1, -1) if ops[n][0] in ("mac", "ring", "drain")) + 1
        a_raw[first_sfx - 1] = int.from_bytes(jr.bytes(128), "little")
        w_raw[first_sfx - 1] = int.from_bytes(jr.bytes(128), "little")
    # Post-review contract: magnitudes held at 0 in INT mode.  Zero-load both
    # sides on the first INT edge after SC traffic, and every INT-mode load
    # carries zero magnitudes (the bench drives a/w_binary_in = 0 there).
    if o.int_entry_zero_load:
        for n in range(1, N):
            if ops[n - 1][0] in ("sc", "scdrain") and ops[n][0] not in ("sc", "scdrain"):
                f["load_a"][n] = 1
                f["load_w"][n] = 1
    if o.int_zero_mag:
        for n in range(N):
            if f["int_mode"][n] and not f["reset"][n] and (f["load_a"][n] or f["load_w"][n]):
                f["zero_bin"][n] = 1
                f["junk_bin"][n] = 0
    # Signs that are not being loaded: hold the previous word (any value is legal).
    for arr in (a_sg, w_sg):
        last = 0
        for n in range(N):
            if arr[n] is None:
                arr[n] = last
            else:
                last = arr[n]
    return f, a_raw, w_raw, a_sg, w_sg, acc, windows


def expectations(blocks: list[Block], ops: list[tuple], f):
    """Trace index n holds the pre-edge state of P_n."""
    N = len(ops)
    drains, combs = [], []
    for n, op in enumerate(ops):
        if op[0] != "drain" or f["reset"][n]:
            continue
        _, bi, t = op
        v = NW - 1 - t
        blk = blocks[bi]
        drains.append(dict(n=n, blk=bi, t=t, v=v, tiles=[int(x) for x in blk.tiles[:, v]]))
        if n + 1 < N and not f["reset"][n + 1] and f["int_mode"][n]:
            combs.append(dict(n=n + 2, blk=bi, t=t, v=v,
                              lo=int(blk.out[v, 0]), hi=int(blk.out[v, 1])))
    first_reset = int(np.argmax(f["reset"]))
    return dict(drains=drains, combs=combs, first_check=first_reset + 1, n_trace=N + 1)


def write(out: Path, blocks, ops, f, a_raw, w_raw, a_sg, w_sg, acc, windows, meta):
    out.mkdir(parents=True, exist_ok=True)
    order = ["reset", "int_mode", "int_prec", "ring_in", "shift_in", "mac_en", "load_a", "load_w",
             "load_a_sign", "load_w_sign", "rng_en", "junk_bin", "zero_bin"]
    lines = [str(len(ops))]
    for n in range(len(ops)):
        ctrl = 0
        for bit, k in enumerate(order):
            ctrl |= int(f[k][n] & 1) << bit
        rec = ctrl | (a_raw[n] << 16) | (w_raw[n] << 1040) | (a_sg[n] << 2064) | \
            (w_sg[n] << 2128) | (acc[n] << 2192)
        assert rec >> REC_W == 0
        lines.append(format(rec, f"0{REC_W // 4}x"))
    (out / "bpv_vec.hex").write_text("\n".join(lines) + "\n")
    exp = expectations(blocks, ops, f)
    rng_ok = all(-(1 << (OW - 1)) <= d for b in blocks for d in b.tiles.reshape(-1)) and \
        all(d < (1 << (OW - 1)) for b in blocks for d in b.tiles.reshape(-1))
    exp.update(meta=meta, tiles_in_owidth=bool(rng_ok),
               blocks=[dict(prec=b.prec, L=b.L, NB=b.NB, tag=b.tag) for b in blocks],
               sign_windows=windows,
               ops_summary={k: sum(1 for op in ops if op[0] == k)
                            for k in ("mac", "ring", "drain", "idle", "reset")})
    (out / "bpv_expect.json").write_text(json.dumps(exp))
    return exp


# --------------------------------------------------------------- operands --
def rng_vals(rng, nbits, shape):
    return rng.integers(-(1 << (nbits - 1)), 1 << (nbits - 1), size=shape, dtype=np.int64)


def mk(prec, L, kind, rng, tag=""):
    BA = 4 if prec == "int4" else 8
    BW = 8 if prec == "int8" else 4
    rows = NH // BA
    alo, ahi = -(1 << (BA - 1)), (1 << (BA - 1)) - 1
    wlo, whi = -(1 << (BW - 1)), (1 << (BW - 1)) - 1
    x = np.arange(L)
    if kind == "uniform":
        A, W = rng_vals(rng, BA, (rows, L)), rng_vals(rng, BW, (L, NW))
    elif kind == "extreme_mix":       # values drawn only from {lo, -1, 0, 1, hi}
        A = rng.choice([alo, -1, 0, 1, ahi], size=(rows, L)).astype(np.int64)
        W = rng.choice([wlo, -1, 0, 1, whi], size=(L, NW)).astype(np.int64)
    elif kind == "allmin":
        A, W = np.full((rows, L), alo), np.full((L, NW), wlo)
    elif kind == "allmax":
        A, W = np.full((rows, L), ahi), np.full((L, NW), whi)
    elif kind == "minxmax":
        A, W = np.full((rows, L), alo), np.full((L, NW), whi)
    elif kind == "neg1":              # all-ones planes on both sides
        A, W = np.full((rows, L), -1), np.full((L, NW), -1)
    elif kind == "neg1xmin":          # every activation plane 1, weight = min
        A, W = np.full((rows, L), -1), np.full((L, NW), wlo)
    elif kind == "zeros":
        A, W = np.zeros((rows, L)), np.zeros((L, NW))
    elif kind == "altsign":           # sign alternates along x and across columns
        A = np.where((x[None, :] + np.arange(rows)[:, None]) % 2 == 0, alo, ahi)
        W = np.where((x[:, None] // 3 + np.arange(NW)[None, :]) % 2 == 0, whi, wlo)
    elif kind == "colmix":            # each column a different extreme pattern
        A = rng.choice([alo, ahi, -1], size=(rows, L)).astype(np.int64)
        pats = [wlo, whi, -1, 0, 1, wlo, whi, 0]
        W = np.stack([np.full(L, p) for p in pats], axis=1)
        W[:, 5] = np.where(x % 2 == 0, wlo, whi)
        W[:, 7] = rng_vals(rng, BW, L)
    else:
        raise SystemExit(f"unknown operand kind {kind}")
    return Block(prec, np.asarray(A, np.int64), np.asarray(W, np.int64), tag=tag or f"{prec}_{kind}_L{L}")


def int4_group(rng, L, which):
    """INT4 block with one activation row zero (leakage probe)."""
    A = np.zeros((2, L), np.int64)
    A[which] = rng.choice([-8, 7, -1], size=L)
    W = rng.choice([-8, 7, -1, 1], size=(L, NW)).astype(np.int64)
    return Block("int4", A, W, tag=f"int4_only_group{which}_L{L}")


# --------------------------------------------------------------- scenarios --
def scenarios():
    S = {}

    def add(name, fn, expect="pass", note=""):
        S[name] = (fn, expect, note)

    # Reduction lengths ending mid-block, extremes, all-ones / all-zero planes.
    add("int8_mixL_extremes", lambda r: ([mk("int8", 1, "allmin", r), mk("int8", 17, "neg1xmin", r),
                                          mk("int8", 200, "extreme_mix", r), mk("int8", 129, "allmin", r),
                                          mk("int8", 255, "altsign", r), mk("int8", 333, "colmix", r),
                                          mk("int8", 128, "zeros", r), mk("int8", 383, "neg1", r)],
                                         Opts(seed=11)),
        note="L = 1,17,200,129,255,333,128,383 back-to-back, no idle cycles")
    add("w4a8_mixL_extremes", lambda r: ([mk("w4a8", 1, "minxmax", r), mk("w4a8", 130, "extreme_mix", r),
                                          mk("w4a8", 257, "allmin", r), mk("w4a8", 99, "colmix", r),
                                          mk("w4a8", 511, "altsign", r), mk("w4a8", 64, "neg1xmin", r)],
                                         Opts(seed=12)))
    add("int4_mixL_extremes", lambda r: ([mk("int4", 3, "allmin", r), mk("int4", 131, "extreme_mix", r),
                                          mk("int4", 250, "colmix", r), mk("int4", 77, "altsign", r),
                                          mk("int4", 384, "neg1xmin", r), mk("int4", 129, "allmax", r)],
                                         Opts(seed=13)))
    add("int4_group_leakage", lambda r: ([int4_group(r, 200, 0), int4_group(r, 200, 1),
                                          int4_group(r, 129, 0), int4_group(r, 129, 1),
                                          mk("int4", 140, "minxmax", r)], Opts(seed=14)),
        note="one INT4 activation row all-zero: its word must be exactly 0")
    # Mixed precisions back to back, int_prec switched on the first edge after
    # the previous block's last drain.
    add("mixed_prec_stream", lambda r: ([mk("int8", 150, "extreme_mix", r), mk("int4", 150, "extreme_mix", r),
                                         mk("w4a8", 150, "extreme_mix", r), mk("int4", 260, "uniform", r),
                                         mk("int8", 260, "uniform", r), mk("int4", 1, "allmin", r),
                                         mk("int8", 1, "allmin", r)], Opts(seed=15)))
    # Adversarial traffic on everything that must not matter.
    add("junk_everything", lambda r: ([mk("int8", 300, "extreme_mix", r), mk("int4", 200, "extreme_mix", r),
                                       mk("w4a8", 170, "uniform", r), mk("int8", 129, "neg1", r)],
                                      Opts(seed=16, raw_junk=True, acc_junk=True, bin_junk=True, prec_junk=True,
                                           mac_always=True)),
        note="random raw planes on every free edge, random acc_in_west, live comparators + random "
             "magnitudes/sign words loaded every edge, random int_prec on every non-drain edge")
    add("random_idle_gaps", lambda r: ([mk("int8", 260, "extreme_mix", r), mk("int4", 140, "uniform", r),
                                        mk("w4a8", 300, "extreme_mix", r)],
                                       Opts(seed=17, idle_prob=0.3, mac_always=True, sign_pos="random")),
        note="random IDLE edges inside passes, laps, drains and between blocks; signs at random legal positions")
    add("random_idle_gaps_macoff", lambda r: ([mk("int8", 260, "extreme_mix", r), mk("int4", 140, "uniform", r)],
                                              Opts(seed=18, idle_prob=0.4, raw_junk=True, sign_pos="random")))
    add("sign_early_window", lambda r: ([mk("int8", 300, "extreme_mix", r), mk("int4", 140, "extreme_mix", r),
                                         mk("w4a8", 140, "extreme_mix", r)], Opts(seed=19, sign_pos="early")),
        note="every sign-pipe update at the earliest legal edge (= last MAC edge of the previous pass)")
    add("sign_late_window", lambda r: ([mk("int8", 300, "extreme_mix", r), mk("int4", 140, "extreme_mix", r),
                                        mk("w4a8", 140, "extreme_mix", r)], Opts(seed=19, sign_pos="late")),
        note="every sign-pipe update at the latest legal edge (= one edge before the next pass's first MAC)")
    # Reset in the middle of a block, then restart (signs reloaded).
    def rst(off, n=2, dirty=False):
        return lambda r: ([mk("int8", 200, "extreme_mix", r), mk("int8", 260, "extreme_mix", r),
                           mk("int4", 140, "extreme_mix", r)],
                          Opts(seed=20, resets=[(1, off, n)], reset_dirty=dirty, mac_always=True))
    add("reset_mid_pass", rst(1 + 3 * (3 + 8)), note="reset during pass 3 data cycles of block 1")
    add("reset_mid_lap", rst(3 + 8 + 3 + 4), note="reset 4 edges into the second ring lap")
    add("reset_mid_drain", rst(8 * 3 + 7 * 8 + 3, dirty=True), note="reset after 3 of 8 drain columns, dirty controls during reset")
    add("reset_after_last_drain", rst(8 * 3 + 7 * 8 + 8, n=1), note="1-edge reset on the edge after the last drain (combiner latency)")
    add("reset_dirty_mid_lap", rst(3 + 8 + 3 + 7, n=3, dirty=True))
    # OWIDTH limits (largest legal L per precision).
    add("int8_owidth_max_L65535", lambda r: ([mk("int8", 65535, "allmin", r)], Opts(seed=21)),
        note="tile(7) = 128*L = 8388480 (2^23 - 128), out = 2^14*L")
    add("int8_owidth_max_neg1xmin_L65535", lambda r: ([mk("int8", 65535, "neg1xmin", r)], Opts(seed=22)),
        note="tile(h<7) = -128*L, tile(7) = +128*L")
    add("w4a8_owidth_max_L1048575", lambda r: ([mk("w4a8", 1048575, "neg1xmin", r)], Opts(seed=23)),
        note="tile = -/+ 8*L = -/+ (2^23 - 8)")
    add("int8_owidth_overflow_L65536", lambda r: ([mk("int8", 65536, "allmin", r)], Opts(seed=24)),
        expect="fail", note="DOCUMENTED LIMIT: tile(7) = 2^23 overflows OWIDTH=24 (must FAIL vs int64)")
    # Deliberate timing errors: each MUST be caught.
    base = lambda r: [mk("int8", 300, "extreme_mix", r), mk("int4", 140, "extreme_mix", r)]
    add("neg_wsign_msb_late1", lambda r: (base(r), Opts(seed=30, sign_pos="late", inject=[("wsign", 0, +1)])),
        expect="fail", note="MSB-pass w_sign reaches the sign pipe one edge late")
    add("neg_wsign_msb_early1", lambda r: (base(r), Opts(seed=30, sign_pos="early", inject=[("wsign", 1, -1)])),
        expect="fail", note="w_sign clear (end of MSB pass) one edge early: last MSB MAC sees sign 0")
    add("neg_wsign_block2_early1", lambda r: (base(r), Opts(seed=30, sign_pos="early", inject=[("wsign", 2, -1)])),
        expect="fail", note="block 2 MSB w_sign set one edge early: block 1's last LSB MAC sees sign 1")
    add("neg_asign_int4_late1", lambda r: (base(r), Opts(seed=30, sign_pos="late", inject=[("asign", 1, +1)])),
        expect="fail", note="INT4 a_sign rows (3,7) one edge late")
    add("neg_ring_early1", lambda r: (base(r), Opts(seed=31, inject=[("ring", 2, -1)])), expect="fail",
        note="one lap's ring_in one edge early (forgets nothing, just early)")
    add("neg_ring_late1", lambda r: (base(r), Opts(seed=31, inject=[("ring", 2, +1)])), expect="fail",
        note="one lap's ring_in one edge late (= driving ring_in on the shift edge, ignoring ring_q latency)")
    add("neg_ring_short", lambda r: (base(r), Opts(seed=31, inject=[("ringlen", 4, -1)])), expect="fail")
    add("neg_ring_long", lambda r: (base(r), Opts(seed=31, inject=[("ringlen", 4, +1)])), expect="fail")
    add("neg_prec_early1", lambda r: (base(r), Opts(seed=32, inject=[("prec", 1, 1)])), expect="fail",
        note="int_prec switched to INT4 one edge early: the INT8 block's last column combined as INT4")
    # Positive controls for the injections: exactly at the window edge.
    add("pos_wsign_window_edges", lambda r: (base(r), Opts(seed=30, sign_pos="early")))
    add("int4_owidth_max_L1048575", lambda r: ([mk("int4", 1048575, "allmin", r)], Opts(seed=25)),
        note="INT4 tiles 3 and 7 = +8*L = 2^23 - 8")
    # SC traffic before and after the INT stream on the same DUT, no reset in between.
    add("sc_int_sc_switch", lambda r: ([mk("int8", 200, "extreme_mix", r), mk("int4", 150, "extreme_mix", r),
                                        mk("w4a8", 140, "uniform", r)],
                                       Opts(seed=26, sc_prefix=60, sc_suffix=40, mac_always=True)),
        note="was HAZARD (review): 60 SC junk edges, SC drain, INT stream with mac_en held high across "
             "the SC->INT switch; the post-review MAC guard drops the two cross-mode MACs")
    add("sc_int_sc_switch_guarded", lambda r: ([mk("int8", 200, "extreme_mix", r), mk("int4", 150, "extreme_mix", r),
                                                mk("w4a8", 140, "uniform", r)],
                                               Opts(seed=26, sc_prefix=60, sc_suffix=40, mac_always=True,
                                                    first_int_mac=0)),
        note="same, with mac_en = 0 on the first int_mode=1 edge only")

    # SC->INT switch hazard isolation.
    sw = lambda r: [mk("int8", 200, "extreme_mix", r), mk("int4", 150, "extreme_mix", r)]
    add("switch_macoff_first_int_edge", lambda r: (sw(r), Opts(seed=27, sc_prefix=60, mac_always=True, first_int_mac=0)),
        note="as sc_int_sc_switch but mac_en = 0 on the first int_mode=1 edge only")
    add("switch_mac_only_first_int_edge", lambda r: (sw(r), Opts(seed=27, sc_prefix=60, mac_always=False, first_int_mac=1)),
        note="was HAZARD (review): mac_en = 1 ONLY on the first int_mode=1 edge after the SC drain; guarded now")
    add("switch_mac_first_int_edge_zero_mag", lambda r: (sw(r), Opts(seed=27, sc_prefix=60, mac_always=False,
                                                                    first_int_mac=1, sc_zero_mag=True)),
        note="same, but the SC prefix loads zero magnitudes: comparator bits are 0")
    # INT->SC: identical SC suffix + SC drain, A/B on the raw planes of the last INT edge.
    add("int_to_sc_A", lambda r: (sw(r), Opts(seed=28, sc_suffix=30, sc_tail_drain=True, mac_always=True,
                                             sc_suffix_clean=True)))
    add("int_to_sc_B", lambda r: (sw(r), Opts(seed=28, sc_suffix=30, sc_tail_drain=True, mac_always=True,
                                             sc_suffix_clean=True, last_int_raw_junk=True)),
        note="compare SC drain columns with int_to_sc_A: must be identical if INT leaves nothing behind")

    # Per-PE lap-enable contract (csa_bp_20261004_lap): ring_q alone shifts the
    # tiles, shift_in only on drain edges.  Was neg_lap_without_shift (expect
    # fail) while ring_q only steered the west mux.
    add("lap_without_shift", lambda r: (base(r), Opts(seed=40, lap_shift=False)),
        note="lap-enable contract: ring_in only, no shift_in on lap edges (was a negative control "
             "before csa_bp_20261004_lap)")
    add("lap_without_shift_junk", lambda r: ([mk("int8", 300, "extreme_mix", r), mk("int4", 200, "extreme_mix", r),
                                              mk("w4a8", 170, "uniform", r), mk("int8", 129, "neg1", r)],
                                             Opts(seed=44, lap_shift=False, raw_junk=True, acc_junk=True,
                                                  bin_junk=True, prec_junk=True, mac_always=True)),
        note="junk_everything under the lap-enable contract (acc_in_west junk on ring-only lap edges)")
    add("lap_without_shift_idle_gaps", lambda r: ([mk("int8", 260, "extreme_mix", r), mk("int4", 140, "uniform", r),
                                                   mk("w4a8", 300, "extreme_mix", r)],
                                                  Opts(seed=45, lap_shift=False, idle_prob=0.3, mac_always=True,
                                                       sign_pos="random")),
        note="random IDLE edges inside ring-only laps: an idle edge with ring_in low must not shift")
    add("lap_without_shift_reset_mid_lap", lambda r: ([mk("int8", 200, "extreme_mix", r),
                                                       mk("int8", 260, "extreme_mix", r),
                                                       mk("int4", 140, "extreme_mix", r)],
                                                      Opts(seed=46, lap_shift=False, resets=[(1, 3 + 8 + 3 + 4, 2)],
                                                           reset_dirty=True, mac_always=True)),
        note="dirty reset 4 edges into a ring-only lap: ring_q must clear, no stray lap after reset")
    add("neg_ring_stray", lambda r: (base(r), Opts(seed=47, inject=[("ringstray", 5, 0)])), expect="fail",
        note="one stray ring_in pulse before a MAC edge: since csa_bp_20261004_lap that edge shifts")
    add("neg_ring_stray_lap_without_shift", lambda r: (base(r), Opts(seed=48, lap_shift=False,
                                                                    inject=[("ringstray", 9, 0)])),
        expect="fail", note="same under the ring-only lap contract")
    add("neg_int_entry_no_zero_load", lambda r: (sw(r), Opts(seed=41, sc_prefix=60, mac_always=True,
                                                            int_entry_zero_load=False)),
        expect="fail", note="SC magnitudes still loaded when INT MACs start: [BP-CONTRACT]")
    add("neg_int_loads_random_mag", lambda r: (base(r), Opts(seed=42, bin_junk=True, int_zero_mag=False)),
        expect="fail", note="pre-review JUNK: random magnitudes loaded in INT mode: [BP-CONTRACT]")
    add("int_entry_guard_mac_always_zero_mag", lambda r: (sw(r), Opts(seed=43, sc_prefix=60, mac_always=True,
                                                                     sc_zero_mag=True, int_entry_zero_load=False)),
        note="SC prefix with zero magnitudes, no entry load needed; mac_en high across the switch")

    def soak(seed, lap_shift=True):
        def fn(r):
            blocks = []
            for _ in range(int(r.integers(10, 16))):
                prec = str(r.choice(["int8", "w4a8", "int4"]))
                L = int(r.choice([1, 2, 15, 16, 127, 128, 129, 255, 256, 257, 383, 384, 385, 511, 640]))
                kind = str(r.choice(["uniform", "extreme_mix", "allmin", "allmax", "minxmax", "neg1",
                                     "neg1xmin", "zeros", "altsign", "colmix"]))
                blocks.append(mk(prec, L, kind, r))
            nb = len(blocks)
            rb = int(r.integers(1, nb))
            o = Opts(seed=seed, idle_prob=float(r.choice([0.0, 0.05, 0.2])), mac_always=bool(r.integers(0, 2)),
                     raw_junk=True, acc_junk=True, bin_junk=True, prec_junk=True, reset_dirty=True,
                     sign_pos="random", sc_prefix=int(r.integers(0, 30)), sc_suffix=int(r.integers(0, 30)),
                     resets=[(rb, int(r.integers(0, 40)), int(r.integers(1, 4)))], first_int_mac=0,
                     lap_shift=lap_shift)
            return blocks, o
        return fn
    for sd in range(1, 9):
        add(f"soak_{sd}", soak(100 + sd), note="random precisions/L/operands, all junk, random idles, "
            "random sign positions, SC prefix/suffix, one random mid-block reset")
    for sd in range(1, 5):
        add(f"soak_lap_without_shift_{sd}", soak(200 + sd, lap_shift=False),
            note="soak under the lap-enable contract (no shift_in on lap edges)")
    return S


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario")
    ap.add_argument("--out-dir", type=Path)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    S = scenarios()
    if args.list:
        for k, (_, e, note) in S.items():
            print(f"{k} {e}")
        return 0
    fn, expect, note = S[args.scenario]
    rng = np.random.default_rng(sum(map(ord, args.scenario)))
    blocks, o = fn(rng)
    ops = build(blocks, o)
    f, a_raw, w_raw, a_sg, w_sg, acc, windows = derive(blocks, ops, o)
    meta = dict(scenario=args.scenario, expect=expect, note=note,
                opts={k: v for k, v in o.__dict__.items()})
    exp = write(args.out_dir, blocks, ops, f, a_raw, w_raw, a_sg, w_sg, acc, windows, meta)
    print(json.dumps(dict(scenario=args.scenario, expect=expect, edges=len(ops),
                          drains=len(exp["drains"]), combs=len(exp["combs"]),
                          tiles_in_owidth=exp["tiles_in_owidth"], ops=exp["ops_summary"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
