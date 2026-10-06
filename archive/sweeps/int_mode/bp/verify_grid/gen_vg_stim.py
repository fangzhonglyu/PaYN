#!/usr/bin/env python3
"""Independent adversarial stimulus + reference generator for the BP PE grid.

Target: InnerPESignedSegmentedCsaBpGrid
(designs/payn/variants/signed_segmented_csa_bp/inner_pe_grid_signed_segmented_csa_bp.sv)
with the per-PE lap enable (core shift = shift_in | ring_q, ring_q waving east).

This file does NOT reuse the implementer's bench, workload generator or checker.
It derives every edge of the schedule from first principles of the RTL
(InnerPESignedSegmentedCsa + InnerTileSignedSegmentedCsa + the BP PE):

  * an input presented before posedge e is captured at e; a bit-pipe sample
    captured at e is MAC'd at e+1; shift (shift_in | ring_q) has priority over
    the MAC on the same edge;
  * PE (r,c)'s A pipe is a_bits_in[r] delayed c+1, its W pipe w_bits_in[c]
    delayed r+1, its ring_q is ring_in[r] delayed c+1 (gated by int_mode at the
    west edge only), its sign-load wave likewise;
  * "virtual time" u = the edge on which PE (0,0) captures a slice.  A for
    virtual u enters row r at edge u+r, W enters column c at u+c, both meet in
    PE (r,c) and are MAC'd at u+r+c+1.

INT block (BA activation planes, BW weight passes, MSB pass first), base B:
    pass pi starts at P[pi] = B + pi*SP, NB = ceil(L/128) data slices,
    per-PE laps:  SP = NB+8, PE (r,c) laps on P[pi]+NB+1+r+c .. +8 (pi < BW-1)
    global laps:  SP = NB+8+S (P_C = 1 only, old contract, shift_in on laps)
    final drain:  D0 = P[BW-1] + NB + 1 + S (after the far PE's last MAC),
                  8*P_C edges of shift_in with acc_in_west = 0,
    next block:   B' = D0 + 8*P_C - 1 + gap (first capture on the last drain
                  edge, so the first MAC of the next block is the edge after).
The reduction elements of a block are scattered over the NB*128 slots by a
random permutation (L need not be a multiple of 128; unused slots are zero),
and the activation rows / output columns are scattered over the grid's tile
rows / columns by random injective maps (partial blocks leave tiles empty).

Expected values: T(r,c,h,v) = sigma_p * sum_x a_p[i,x] * W[x,j]
(sigma_p = -1 for the activation MSB plane), mod 2^24, and the combined
out(i,j) = sum_p 2^p T(p) = (A @ W)[i,j] (formed by the checker from the
drained tiles).  SC blocks: T = sum over slices and lanes of
(-1)^(a_sign ^ w_sign) * popcount(a & w), straight from the random bits.

Outputs in --out-dir: stim.txt (one line per edge, consumed by
tb_vg_player.sv), expect.npz (sample edges, expected drained columns,
expected per-PE ring_q, per-block tiles and A@W), plusargs.txt (bench-side
fault forces), meta.json.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

K, M, NH, NW, OW = 8, 16, 8, 8, 24
AB, AS, WB, WS, AW = NH * K * M, NH * K, NW * K * M, NW * K, NH * OW
SL = K * M                      # 128 slots per data slice
RESET0 = 12                     # edges 0..11 in reset: flushes X from the un-reset operand pipes
                                # (PE (r,c) needs min(r,c)+1 edges; 8x8 grids at most)
E0 = RESET0 + 2                 # first block base


def rnd_bits(rng, shape, p=0.5):
    return (rng.random(shape) < p).astype(np.uint8)


class Grid:
    def __init__(self, pr: int, pc: int, n: int, rng: np.random.Generator):
        self.pr, self.pc, self.S, self.n, self.rng = pr, pc, pr + pc - 2, n, rng
        z = lambda *s: np.zeros(s, np.uint8)
        self.reset, self.int_mode, self.mac_en, self.shift, self.sample = (z(n) for _ in range(5))
        self.ring = z(n, pr)
        self.lda, self.ldw = z(n, pr), z(n, pc)
        self.asg, self.wsg = z(n, pr, AS), z(n, pc, WS)
        self.abits, self.wbits = z(n, pr, AB), z(n, pc, WB)
        self.acc = z(n, pr, AW)
        self.exp_ring = z(n, pr, pc)
        self.pe_shift = np.zeros((n, pr, pc), bool)   # edges on which each PE (should) shift / reset
        self.mac_needed = np.zeros(n, bool)
        self.mac_forced0 = np.zeros(n, bool)
        self.latch_a = np.zeros((n, pr), bool)
        self.latch_w = np.zeros((n, pc), bool)
        self.drain = np.zeros(n, bool)
        self.ring_junk_ok = np.zeros(n, bool)          # extra: junk ring allowed (INT->SC early drop)
        self.int_seg = np.zeros(n, bool)               # edges owned by an INT block (int_mode = 1)
        self.samples: list[tuple[int, int, int]] = []  # (edge, block id, step)
        self.blocks: list[dict] = []
        self.plusargs: list[str] = []
        self.last = 0
        self.notes: list[str] = []

    # ------------------------------------------------------------------ util
    def touch(self, e):
        if e >= self.n - 8:
            raise SystemExit(f"schedule overflow at edge {e} (n={self.n})")
        self.last = max(self.last, e)

    def lap_windows(self, P, NB, BW, mode):
        """{(pi, r, c): first lap edge} of PE (r,c) after pass pi."""
        out = {}
        for pi in range(BW - 1):
            for r in range(self.pr):
                for c in range(self.pc):
                    off = (r + c) if mode == "pe" else self.S
                    out[(pi, r, c)] = P[pi] + NB + 1 + off
        return out

    # ----------------------------------------------------------- int block
    def int_block(self, B: int, spec: dict) -> int:
        rng, pr, pc, S = self.rng, self.pr, self.pc, self.S
        BA, BW, L = spec["BA"], spec["BW"], spec["L"]
        lap = spec.get("lap", "pe")
        if lap == "global" and pc != 1:
            raise SystemExit("global laps through the grid wrapper need P_C = 1")
        NB = -(-L // SL)
        rows_pe = NH // BA
        nslot_r, nslot_c = pr * rows_pe, pc * NW
        nrows = min(spec.get("rows", nslot_r), nslot_r)
        ncols = min(spec.get("cols", nslot_c), nslot_c)
        dist = spec.get("dist", "uniform")
        lo_a, hi_a = -(1 << (BA - 1)), (1 << (BA - 1)) - 1
        lo_w, hi_w = -(1 << (BW - 1)), (1 << (BW - 1)) - 1
        if dist == "uniform":
            A = rng.integers(lo_a, hi_a + 1, (nrows, L))
            W = rng.integers(lo_w, hi_w + 1, (L, ncols))
        elif dist == "allmin":
            A = np.full((nrows, L), lo_a); W = np.full((L, ncols), lo_w)
        elif dist == "minmax":
            A = np.full((nrows, L), lo_a); W = np.full((L, ncols), hi_w)
        elif dist == "maxmin":
            A = np.full((nrows, L), hi_a); W = np.full((L, ncols), lo_w)
        elif dist == "extreme":
            A = rng.choice([lo_a, hi_a, -1, 0, 1], (nrows, L))
            W = rng.choice([lo_w, hi_w, -1, 0, 1], (L, ncols))
        elif dist == "sparse":
            A = rng.integers(lo_a, hi_a + 1, (nrows, L)) * (rng.random((nrows, L)) < 0.1)
            W = rng.integers(lo_w, hi_w + 1, (L, ncols)) * (rng.random((L, ncols)) < 0.1)
        else:
            raise SystemExit(f"unknown dist {dist}")
        A = A.astype(np.int64); W = W.astype(np.int64)

        # placement: reduction elements -> slots, rows/cols -> tile rows/cols
        perm = rng.permutation(NB * SL)[:L]
        r_slots = rng.permutation(nslot_r)[:nrows]          # activation row i -> slot
        c_slots = rng.permutation(nslot_c)[:ncols]          # output column j -> slot
        slot_i = np.full(nslot_r, -1); slot_i[r_slots] = np.arange(nrows)
        slot_j = np.full(nslot_c, -1); slot_j[c_slots] = np.arange(ncols)

        ap = ((A[:, None, :] & ((1 << BA) - 1)) >> np.arange(BA)[None, :, None]) & 1   # [i,p,x]
        wq = ((W.T[:, None, :] & ((1 << BW) - 1)) >> np.arange(BW)[None, :, None]) & 1  # [j,q,x]
        aslot = np.zeros((nrows, BA, NB * SL), np.uint8); aslot[:, :, perm] = ap
        wslot = np.zeros((ncols, BW, NB * SL), np.uint8); wslot[:, :, perm] = wq

        # per-row A bits for each slice: [r, b, 1024]
        arow = np.zeros((pr, NB, AB), np.uint8)
        for r in range(pr):
            for h in range(NH):
                i = slot_i[r * rows_pe + h // BA]
                if i >= 0:
                    arow[r, :, h * SL:(h + 1) * SL] = aslot[i, h % BA].reshape(NB, SL)
        wcol = np.zeros((pc, BW, NB, WB), np.uint8)
        for c in range(pc):
            for v in range(NW):
                j = slot_j[c * NW + v]
                if j >= 0:
                    for pi in range(BW):
                        wcol[c, pi, :, v * SL:(v + 1) * SL] = wslot[j, BW - 1 - pi].reshape(NB, SL)

        a_word = np.array([1 if (h % BA) == BA - 1 else 0 for h in range(NH) for _ in range(K)], np.uint8)

        # expected tiles
        T = np.zeros((pr, pc, NH, NW), np.int64)
        for r in range(pr):
            for h in range(NH):
                i = slot_i[r * rows_pe + h // BA]
                if i < 0:
                    continue
                p = h % BA
                sig = -1 if p == BA - 1 else 1
                row = ap[i, p].astype(np.int64) @ W           # [ncols]
                for c in range(pc):
                    for v in range(NW):
                        j = slot_j[c * NW + v]
                        if j >= 0:
                            T[r, c, h, v] = sig * row[j]
        for r in range(pr):
            for c in range(pc):
                for il in range(rows_pe):
                    for v in range(NW):
                        i, j = slot_i[r * rows_pe + il], slot_j[c * NW + v]
                        if i >= 0 and j >= 0:
                            assert sum((1 << p) * T[r, c, il * BA + p, v] for p in range(BA)) == int(A[i] @ W[:, j])

        SP = NB + 8 + (S if lap == "global" else 0)
        P = [B + pi * SP for pi in range(BW)]
        fault = spec.get("fault") or {}
        ft = fault.get("type")

        # data + MAC-needed edges
        for pi in range(BW):
            for b in range(NB):
                u = P[pi] + b
                for r in range(pr):
                    self.touch(u + r); self.abits[u + r, r] = arow[r, b]
                for c in range(pc):
                    self.touch(u + c); self.wbits[u + c, c] = wcol[c, pi, b]
                for r in range(pr):
                    for c in range(pc):
                        self.mac_needed[u + r + c + 1] = True
        # signs
        for r in range(pr):
            self.lda[B + r - 1, r] = 1
            self.asg[B + r, r] = a_word
            self.latch_a[B + r, r] = True
        for pi in range(BW):
            wword = np.ones(WS, np.uint8) if pi == 0 else np.zeros(WS, np.uint8)
            for c in range(pc):
                self.ldw[P[pi] + c - 1, c] = 1
                self.wsg[P[pi] + c, c] = wword
                self.latch_w[P[pi] + c, c] = True
        # laps (intended)
        lw = self.lap_windows(P, NB, BW, lap)
        for (pi, r, c), ls in lw.items():
            self.exp_ring[ls:ls + 8, r, c] = 1
            self.pe_shift[ls:ls + 8, r, c] = True
        # ring drive: one edge ahead of PE (r,0)'s lap edges
        for (pi, r, c), ls in lw.items():
            if c != 0:
                continue
            lo, hi = ls - 1, ls + 6
            if ft in ("row_late", "row_early", "lap_short", "lap_long") and fault["r"] == r and fault.get("pi", pi) == pi:
                lo, hi = {"row_late": (lo + 1, hi + 1), "row_early": (lo - 1, hi - 1),
                          "lap_short": (lo, hi - 1), "lap_long": (lo, hi + 1)}[ft]
            if ft == "row_noskew":
                ls0 = lw[(pi, 0, 0)]
                lo, hi = ls0 - 1, ls0 + 6
            self.ring[lo:hi + 1, r] = 1
        if ft == "stray":
            pi, r = fault.get("pi", 0), fault["r"]
            e = P[pi] + max(0, NB // 2) + r      # PE (r,0) mid-pass data MAC is e+1
            self.ring[e, r] = 1
            self.notes.append(f"stray ring_in[{r}] at edge {e}")
        if lap == "global":
            for (pi, r, c), ls in lw.items():
                self.shift[ls:ls + 8] = 1
        if spec.get("oldc_idemp"):
            allr = self.exp_ring.reshape(self.n, -1).all(axis=1) & (np.arange(self.n) >= B) & (np.arange(self.n) < P[-1] + 1)
            self.shift[allr] = 1
            self.notes.append(f"oldc_idemp: shift_in on {int(allr.sum())} edges where every PE laps")
            if not allr.any():
                self.notes.append("oldc_idemp: S >= 8, no edge has every PE lapping")
        if ft == "shift_extra":
            e = lw[(fault.get("pi", 0), 0, 0)]
            self.shift[e] = 1
            self.notes.append(f"shift_extra: global shift_in at edge {e} (PE (0,0) first lap edge)")
        if ft == "link_late" or ft == "link_early":
            r, c, pi = fault["r"], fault["c"], fault.get("pi", 0)
            ls = lw[(pi, r, c)]
            fr, to = (ls - 1, ls + 7) if ft == "link_late" else (ls - 2, ls + 6)
            self.plusargs += [f"+FKIND={1 if ft == 'link_late' else 2}", f"+FR={r}", f"+FC={c}",
                              f"+FFROM={fr}", f"+FTO={to}"]
            self.notes.append(f"{ft} PE ({r},{c}) pass {pi} lap, force window {fr}..{to}")

        D0 = P[BW - 1] + NB + 1 + S + (-1 if ft == "drain_early" else 0)
        bid = len(self.blocks)
        interrupt = spec.get("interrupt")
        end_last = D0 + 8 * pc - 1
        if interrupt is None:
            for t in range(8 * pc):
                e = D0 + t
                self.touch(e)
                self.shift[e] = 1
                self.drain[e] = True
                self.sample[e] = 1
                self.pe_shift[e] = True
                self.samples.append((e, bid, t))
        self.int_seg[B - 1:end_last + 1] = True
        if spec.get("drop_int_early"):
            last_ring = int(np.nonzero(self.ring[:, :].any(axis=1) & (np.arange(self.n) <= end_last))[0].max())
            e_drop = last_ring + 1
            self.int_seg[e_drop:end_last + 1] = False
            self.ring_junk_ok[e_drop:end_last + 1] = True
            self.notes.append(f"int_mode dropped at edge {e_drop} (after the last ring_in edge {last_ring}); "
                              f"in-flight laps at PEs c>0 still to come; junk ring_in from there")
        self.blocks.append(dict(kind="int", BA=BA, BW=BW, L=L, NB=NB, base=B, lap=lap, D0=D0,
                                P=P, T=T, slot_i=slot_i, slot_j=slot_j, AW=(A @ W),
                                rows_pe=rows_pe, checked=interrupt is None,
                                period_formula=BW * NB + 8 * (BW - 1) + S + 8 * pc,
                                period_global=BW * NB + (8 + S) * (BW - 1) + S + 8 * pc))
        if interrupt is not None:
            return self.do_interrupt(B, P, NB, lw, interrupt)
        gap = spec.get("gap", 0) + (-1 if spec.get("next_early") else 0)
        return end_last + gap

    # ----------------------------------------------------------- interrupt
    def do_interrupt(self, B, P, NB, lw, it) -> int:
        """Reset in the middle of the block (R chosen inside pass-1's lap wave)."""
        S, pr, pc = self.S, self.pr, self.pc
        if it.get("loc", "lap") == "lap":      # PE (0,0) on its 4th lap edge after pass 1
            R = lw[(1, 0, 0)] + 3
        else:                                  # dense pass-1 data still in flight in the pipes
            R = P[1] + NB - 1
        n, f = it["n"], it.get("flush", 0)
        # cancel everything of this block at / after R (A, W = zero from R on)
        for arr in (self.abits, self.wbits, self.asg, self.wsg, self.lda, self.ldw, self.ring,
                    self.shift, self.sample, self.acc):
            arr[R:] = 0
        self.mac_needed[R:] = False
        self.pe_shift[R:] = False
        self.exp_ring[R + 1:] = 0
        self.latch_a[R:] = False; self.latch_w[R:] = False
        self.int_seg[R:] = False
        in_flight = [(r, c) for r in range(pr) for c in range(pc) if self.exp_ring[R, r, c]]
        self.notes.append(f"reset at edges {R}..{R + n - 1} (PEs lapping at R: {in_flight}); "
                          f"mac_en forced 0 on {f} edges after reset")
        for e in range(R, R + n):
            self.touch(e)
            self.reset[e] = 1
            self.pe_shift[e] = True
            # dirty reset: junk on every control and data-path input except the planes
            self.ring[e] = self.rng.integers(0, 2, pr)
            self.shift[e] = self.rng.integers(0, 2)
            self.lda[e] = self.rng.integers(0, 2, pr); self.ldw[e] = self.rng.integers(0, 2, pc)
            self.asg[e] = rnd_bits(self.rng, (pr, AS)); self.wsg[e] = rnd_bits(self.rng, (pc, WS))
            self.acc[e] = rnd_bits(self.rng, (pr, AW))
            self.mac_forced0[e] = False
        self.mac_en[R:R + n] = self.rng.integers(0, 2, n)
        self.mac_forced0[R:R + n] = True     # keep the junk value
        for e in range(R + n, R + n + f):
            self.mac_forced0[e] = True       # mac_en = 0 flush
        self.int_seg[R:R + n] = True         # int_mode high through reset (ring junk is still gated by reset)
        return R + n + max(1, f)

    # ------------------------------------------------------------ SC block
    def sc_block(self, B: int, spec: dict) -> int:
        rng, pr, pc, S = self.rng, self.pr, self.pc, self.S
        NB = spec["NB"]
        a = rnd_bits(rng, (NB, pr, AB))
        w = rnd_bits(rng, (NB, pc, WB))
        asw = rnd_bits(rng, (pr, AS))
        wsw = rnd_bits(rng, (pc, WS))
        for b in range(NB):
            u = B + b
            for r in range(pr):
                self.touch(u + r); self.abits[u + r, r] = a[b, r]
            for c in range(pc):
                self.touch(u + c); self.wbits[u + c, c] = w[b, c]
            for r in range(pr):
                for c in range(pc):
                    self.mac_needed[u + r + c + 1] = True
        for r in range(pr):
            self.lda[B + r - 1, r] = 1; self.asg[B + r, r] = asw[r]; self.latch_a[B + r, r] = True
        for c in range(pc):
            self.ldw[B + c - 1, c] = 1; self.wsg[B + c, c] = wsw[c]; self.latch_w[B + c, c] = True
        a5 = a.reshape(NB, pr, NH, K, M).astype(np.int64)
        w5 = w.reshape(NB, pc, NW, K, M).astype(np.int64)
        pop = np.einsum("brhkm,bcvkm->rchvk", a5, w5)
        sg = asw.reshape(pr, 1, NH, 1, K) ^ wsw.reshape(1, pc, 1, NW, K)
        T = (pop * np.where(sg == 1, -1, 1)).sum(axis=-1)
        D0 = B + NB + 1 + S                # after the far PE's last MAC (B+NB-1 + S + 1)
        bid = len(self.blocks)
        for t in range(8 * pc):
            e = D0 + t
            self.touch(e)
            self.shift[e] = 1; self.drain[e] = True; self.sample[e] = 1; self.pe_shift[e] = True
            self.samples.append((e, bid, t))
        self.blocks.append(dict(kind="sc", NB=NB, base=B, D0=D0, T=T, checked=True))
        return D0 + 8 * pc - 1 + spec.get("gap", 0)

    # ------------------------------------------------------------- finish
    def finish(self, junk: bool, junk_planes: bool, sc_ring_junk: bool, mac_junk: bool = True):
        n, rng, pr, pc = self.last + 4, self.rng, self.pr, self.pc
        self.reset[:RESET0] = 1
        self.pe_shift[:RESET0] = True
        self.int_mode[:] = self.int_seg.astype(np.uint8)
        # mac_en: 1 where any PE needs a data MAC; junk or 1 elsewhere; flush edges 0
        idx = np.arange(self.n)
        free = ~self.mac_needed & ~self.mac_forced0 & (idx < n)
        self.mac_en[free] = rng.integers(0, 2, int(free.sum())) if (junk and mac_junk) else 1
        self.mac_en[self.mac_needed] = 1
        flush = self.mac_forced0 & (self.reset == 0)
        self.mac_en[flush] = 0
        if junk:
            for r in range(pr):
                m = ~self.latch_a[:, r] & (idx < n)
                self.asg[m, r] = rnd_bits(rng, (int(m.sum()), AS))
            for c in range(pc):
                m = ~self.latch_w[:, c] & (idx < n)
                self.wsg[m, c] = rnd_bits(rng, (int(m.sum()), WS))
            m = ~self.drain & (idx < n) & (self.reset == 0)
            self.acc[m] = rnd_bits(rng, (int(m.sum()), pr, AW))
        if sc_ring_junk:
            m = ((self.int_mode == 0) | self.ring_junk_ok) & (self.reset == 0) & (idx >= RESET0) & (idx < n)
            # ring junk only where int_mode is low at that edge
            m &= self.int_mode == 0
            self.ring[m] = rng.integers(0, 2, (int(m.sum()), pr))
            self.notes.append(f"ring_in junk on {int(m.sum())} edges with int_mode = 0")
        if junk_planes:
            # Beyond-contract: random A and W planes on virtual times whose MAC lands on a
            # shift (lap / drain / reset) edge in EVERY PE.  With per-PE laps the 8 bubble
            # slices between passes qualify; a one-edge lap misalignment leaks them.
            nj = 0
            for u in range(RESET0, n - self.S - 2):
                if all(self.pe_shift[u + r + c + 1, r, c] for r in range(pr) for c in range(pc)):
                    if any(self.abits[u + r, r].any() for r in range(pr)) or any(self.wbits[u + c, c].any() for c in range(pc)):
                        raise SystemExit(f"internal: data on a dropped virtual time {u}")
                    for r in range(pr):
                        self.abits[u + r, r] = rnd_bits(rng, AB)
                    for c in range(pc):
                        self.wbits[u + c, c] = rnd_bits(rng, WB)
                    nj += 1
            self.notes.append(f"junk_planes on {nj} virtual times")
        self.n_final = n


def hexrows(bits2d: np.ndarray) -> list[str]:
    """bits2d [N, width] (index = bit position) -> per-row hex strings, MSB first."""
    nrow, w = bits2d.shape
    pad = (-w) % 8
    b = np.concatenate([np.zeros((nrow, pad), np.uint8), bits2d[:, ::-1]], axis=1)
    packed = np.packbits(b, axis=1)
    return [row.tobytes().hex() for row in packed]


# ---------------------------------------------------------------- scenarios
def scenario(name: str, pr: int, pc: int, rng) -> tuple[list[dict], dict]:
    S = pr + pc - 2
    i8 = dict(BA=8, BW=8); w48 = dict(BA=8, BW=4); i4 = dict(BA=4, BW=4)
    opts = dict(junk=False, junk_planes=False, sc_ring_junk=False)
    far_r, far_c = pr - 1, pc - 1
    if name == "b2b_int8":            # 3 blocks, zero idle, L ending mid-slice, partial blocks
        segs = [dict(kind="int", **i8, L=300), dict(kind="int", **i8, L=257, rows=max(1, pr - 1), cols=max(1, 8 * pc - 5)),
                dict(kind="int", **i8, L=129)]
        opts["junk"] = True
    elif name == "mixed_prec":        # precision changes block to block, zero idle
        segs = [dict(kind="int", **i8, L=200), dict(kind="int", **i4, L=130), dict(kind="int", **w48, L=129),
                dict(kind="int", **i4, L=5), dict(kind="int", **i8, L=128)]
        opts["junk"] = True
    elif name == "nb1":               # one data slice per pass: laps back to back with 1-edge passes
        segs = [dict(kind="int", **i8, L=100), dict(kind="int", **i8, L=1), dict(kind="int", **i4, L=128),
                dict(kind="int", **w48, L=77)]
        opts["junk"] = True
    elif name == "w4a8_int4":
        segs = [dict(kind="int", **w48, L=640), dict(kind="int", **i4, L=513), dict(kind="int", **w48, L=383, dist="extreme")]
        opts["junk"] = True
    elif name == "extremes":
        segs = [dict(kind="int", **i8, L=1000, dist="allmin"), dict(kind="int", **i8, L=999, dist="minmax"),
                dict(kind="int", **i8, L=600, dist="maxmin"), dict(kind="int", **i4, L=700, dist="allmin"),
                dict(kind="int", **i8, L=500, dist="sparse")]
        opts["junk"] = True
    elif name == "long_int8":         # longest legal INT8 block (L = 65408 <= 65535)
        segs = [dict(kind="int", **i8, L=65408, dist="allmin"), dict(kind="int", **i8, L=128)]
    elif name == "junk_planes":       # beyond contract: junk planes on every lap-dropped virtual time
        segs = [dict(kind="int", **i8, L=384), dict(kind="int", **i4, L=200), dict(kind="int", **w48, L=128)]
        opts.update(junk=True, junk_planes=True)
    elif name == "oldc_idemp":        # old contract: shift_in also on lap edges (where every PE laps)
        segs = [dict(kind="int", **i8, L=256, oldc_idemp=True), dict(kind="int", **i4, L=200, oldc_idemp=True)]
        opts["junk"] = True
    elif name == "oldc_global":       # old contract on an N x 1 grid: global laps + shift_in, wait S
        segs = [dict(kind="int", **i8, L=256, lap="global"), dict(kind="int", **w48, L=130, lap="global"),
                dict(kind="int", **i8, L=128)]
        opts["junk"] = True
    elif name == "sc_ring_junk":      # SC mode, ring_in random on every row every edge
        segs = [dict(kind="sc", NB=3), dict(kind="sc", NB=1), dict(kind="sc", NB=2)]
        opts.update(junk=True, sc_ring_junk=True)
    elif name == "f_sc_nogate":       # negative: SC ring junk with the int_mode gate forced away
        segs = [dict(kind="sc", NB=3), dict(kind="sc", NB=1), dict(kind="sc", NB=2)]
        opts.update(junk=True, sc_ring_junk=True, extra_plusargs=["+FKIND=3"])
    elif name == "util4096":          # long GEMM block periods (README table)
        segs = [dict(kind="int", **i8, L=4096), dict(kind="int", **w48, L=4096), dict(kind="int", **i4, L=4096),
                dict(kind="int", **i8, L=128)]
    elif name == "int_sc_int":        # INT (int_mode dropped with the wave in flight) -> SC (ring junk) -> INT
        segs = [dict(kind="int", **i8, L=256, drop_int_early=True), dict(kind="sc", NB=2),
                dict(kind="int", **i4, L=130, drop_int_early=True), dict(kind="sc", NB=1), dict(kind="int", **i8, L=128)]
        opts.update(junk=True, sc_ring_junk=True)
    elif name.startswith("reset_"):   # reset_<lap|pass>_n<N>_f<F>: reset N edges, then F edges of mac_en = 0
        _, loc, nn, ff = name.split("_")
        n, f = int(nn[1:]), int(ff[1:])
        segs = [dict(kind="int", **i8, L=384 if loc == "lap" else 1536, interrupt=dict(n=n, flush=f, loc=loc)),
                dict(kind="int", **i8, L=256), dict(kind="int", **i4, L=128)]
        # mac_en stays 1 outside the reset / flush window, so the in-flight operand
        # hazard is deterministic (junk mac_en could mask it)
        opts.update(junk=True, mac_junk=False)
    # ---- negative controls: one-edge ring-wave / schedule errors (must FAIL) ----
    elif name == "f_row_late":
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="row_late", r=far_r, pi=3))]
    elif name == "f_row_early":
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="row_early", r=far_r, pi=3))]
    elif name == "f_lap_short":
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="lap_short", r=far_r, pi=2))]
    elif name == "f_lap_long":
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="lap_long", r=far_r, pi=2))]
    elif name == "f_link_late":       # far PE only, one lap, one edge late
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="link_late", r=far_r, c=far_c, pi=4))]
    elif name == "f_link_early":      # far PE only (c >= 1), one lap, one edge early
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="link_early", r=far_r, c=far_c, pi=4))]
    elif name == "f_link_late_last":  # far PE, LAST lap of the block, INT4
        segs = [dict(kind="int", **i4, L=256, fault=dict(type="link_late", r=far_r, c=far_c, pi=2))]
    elif name == "f_row_noskew":
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="row_noskew"))]
    elif name == "f_stray":
        segs = [dict(kind="int", **i8, L=384, fault=dict(type="stray", r=far_r, pi=1))]
    elif name == "f_drain_early":     # drain one edge before the far PE's last MAC
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="drain_early"))]
    elif name == "f_next_early":      # next block's first MAC lands on the last drain edge
        segs = [dict(kind="int", **i8, L=256, next_early=True), dict(kind="int", **i8, L=256)]
    elif name == "f_shift_extra":     # global shift_in on an edge where not every PE laps
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="shift_extra", pi=2))]
    elif name == "f_junk_planes_late":  # junk planes + far PE one lap one edge late
        segs = [dict(kind="int", **i8, L=256, fault=dict(type="link_late", r=far_r, c=far_c, pi=4))]
        opts.update(junk=True, junk_planes=True)
    else:
        raise SystemExit(f"unknown scenario {name}")
    return segs, opts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pr", type=int, required=True)
    ap.add_argument("--pc", type=int, required=True)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out-dir", type=Path, required=True)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    segs, opts = scenario(a.scenario, a.pr, a.pc, rng)
    S = a.pr + a.pc - 2
    est = 64
    for s in segs:
        if s["kind"] == "int":
            NB = -(-s["L"] // SL)
            est += s["BW"] * (NB + 8 + S) + S + 8 * a.pc + 16
        else:
            est += s["NB"] + S + 8 * a.pc + 16
        est += 32
    g = Grid(a.pr, a.pc, est, rng)
    B = E0
    for s in segs:
        B = g.int_block(B, s) if s["kind"] == "int" else g.sc_block(B, s)
    g.plusargs += opts.pop("extra_plusargs", [])
    g.finish(**opts)
    n = g.n_final
    a.out_dir.mkdir(parents=True, exist_ok=True)

    ctl = (g.reset[:n] | (g.int_mode[:n] << 1) | (g.mac_en[:n] << 2) | (g.shift[:n] << 3)).astype(int)
    cols = [
        [f"{x:x}" for x in ctl],
        hexrows(g.ring[:n]), hexrows(g.lda[:n]), hexrows(g.ldw[:n]),
        hexrows(g.asg[:n].reshape(n, -1)), hexrows(g.wsg[:n].reshape(n, -1)),
        hexrows(g.abits[:n].reshape(n, -1)), hexrows(g.wbits[:n].reshape(n, -1)),
        hexrows(g.acc[:n].reshape(n, -1)),
        [f"{x:x}" for x in g.sample[:n]],
    ]
    with open(a.out_dir / "stim.txt", "w") as fh:
        fh.write(f"{n}\n")
        for e in range(n):
            fh.write(" ".join(c[e] for c in cols) + "\n")

    smp = np.array(g.samples, dtype=np.int64).reshape(-1, 3)
    exp_vals = np.zeros((len(smp), a.pr, NH), np.int64)
    for idx, (e, bid, t) in enumerate(smp):
        T = g.blocks[bid]["T"]
        c, v = a.pc - 1 - t // 8, 7 - t % 8
        exp_vals[idx] = T[:, c, :, v]
    exp_vals = ((exp_vals + (1 << 23)) % (1 << 24)) - (1 << 23)
    save = dict(samples=smp, exp_vals=exp_vals, exp_ring=g.exp_ring[:n], reset=g.reset[:n])
    meta_blocks = []
    for bid, b in enumerate(g.blocks):
        save[f"T{bid}"] = b["T"]
        mb = dict(kind=b["kind"], base=b["base"], D0=b["D0"], checked=b["checked"], NB=b["NB"])
        if b["kind"] == "int":
            save[f"slot_i{bid}"] = b["slot_i"]; save[f"slot_j{bid}"] = b["slot_j"]; save[f"AW{bid}"] = b["AW"]
            mb.update(BA=b["BA"], BW=b["BW"], L=b["L"], lap=b["lap"], rows_pe=b["rows_pe"],
                      period_formula=b["period_formula"], period_global=b["period_global"], P=b["P"])
        meta_blocks.append(mb)
    np.savez_compressed(a.out_dir / "expect.npz", **save)
    (a.out_dir / "plusargs.txt").write_text(" ".join(g.plusargs) + "\n")
    meta = dict(pr=a.pr, pc=a.pc, S=S, scenario=a.scenario, seed=a.seed, n_edges=n, blocks=meta_blocks,
                notes=g.notes, opts=opts, reset0=RESET0)
    (a.out_dir / "meta.json").write_text(json.dumps(meta, indent=1, default=int))
    print(json.dumps(dict(n_edges=n, blocks=len(g.blocks), notes=g.notes)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
