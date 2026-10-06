#!/usr/bin/env python3
"""Adversarial arithmetic verification of the bit-plane INT mode (round-1 key
`bitplane_throughput`, "BP-HW-ring") on the PaYN CSA tile.

Independent re-implementation: written from the RTL text
  designs/payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv  (M=16 path)
  designs/payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv
  designs/payn/variants/signed_segmented_clean/inner_pe_grid_signed_segmented_clean.sv (grid wiring)
  designs/payn/pe_peripheral.sv, designs/payn/sobol.sv
  designs/payn/power/power_payn_array.sv (SC streaming schedule)
and from the design text in sweeps/int_mode/design_round1.json.  It does not
import or copy sweeps/int_mode/model_bitplane_throughput.py.

Parts
  A  exhaustive lane identity (PaynPopcount16Csa FA network, 5 XORs, -16N row),
     heap modulus and carry/borrow decode over the whole reachable low_sum range
  B  register-level P_R x P_C grid: peripheral (comparator | raw), PE pipes, sign
     load wave, NEW per-PE ring mux + ring_q wave, tiles (LOW_W=9 + pending +
     lazy acc_high), global drain, east combiner.  HW-ring (recommended), HB-ring,
     BP-S.  Edge cases incl. -128, all-max/min, K near the 24-bit limit.
  C  negative controls on schedule timing (drain one cycle early, next block one
     cycle early, sign loaded with the first data instead of one cycle ahead)
  D  SC transparency of the proposed peripheral change, under the real SC
     streaming schedule of power_payn_array.sv, for (i) dedicated raw lines and
     (ii) raw lines shared with a_binary_in[511:0] as the design's array_port
     row states.
  E  SC -> INT entry with stale held magnitudes (binary_q not zeroed).

Run: python3 sweeps/int_mode/verify/bp_ring_verify.py [--long]
"""
import argparse
import sys
import time

import numpy as np

K, M, NH, NW = 8, 16, 8, 8
OW, LOW_W = 24, 9
HIGH_W = OW - LOW_W
SUM_W = LOW_W + 2
M24 = (1 << OW) - 1
WIDTH = 8

FAILS = []


def expect(cond, msg):
    if not cond:
        FAILS.append(msg)
        print("  FAIL:", msg)
    return cond


def s24(u):
    u = np.asarray(u, dtype=np.int64) & M24
    return np.where(u >= (1 << 23), u - (1 << 24), u)


# ----------------------------------------------------------------- Part A ---
def fa(a, b, c):
    t = a + b + c
    return t & 1, t >> 1


def csa16(x):
    """PaynPopcount16Csa, transcribed from the RTL (x[..., 16])."""
    fs, fc = {}, {}
    for i in range(5):
        fs[i], fc[i] = fa(x[..., 3 * i], x[..., 3 * i + 1], x[..., 3 * i + 2])
    fs[5], fc[5] = fa(fs[0], fs[1], fs[2])
    fs[6], fc[6] = fa(fs[3], fs[4], x[..., 15])
    fs[7], fc[7] = fa(fc[0], fc[1], fc[2])
    fs[8], fc[8] = fa(fc[3], fc[4], fc[5])
    fs[9], fc[9] = fa(fs[7], fs[8], fc[6])
    fs[10], fc[10] = fa(fc[7], fc[8], fc[9])
    return fs[5], fs[6], fs[9], fs[10], fc[10]          # s0a s0b s1 s2 s3


def part_a():
    print("== A: lane identity, heap, carry/borrow (exhaustive) ==")
    x = ((np.arange(1 << 16)[:, None] >> np.arange(16)) & 1).astype(np.int64)
    s0a, s0b, s1, s2, s3 = csa16(x)
    cnt = x.sum(1)
    expect(np.array_equal(s0a + s0b + 2 * s1 + 4 * s2 + 8 * s3, cnt),
           "redundant count != popcount")
    for n in (0, 1):
        row4 = ((s3 ^ n) << 3) | ((s2 ^ n) << 2) | ((s1 ^ n) << 1) | (s0a ^ n)
        row1 = s0b ^ n
        val = row4 + row1 - 16 * n
        expect(np.array_equal(val, -cnt if n else cnt), f"lane trick n={n}")
    print("  all 65,536 lane inputs x both signs: (bits^n).(1,1,2,4,8) - 16n == +-count")
    # Correction row SUM_W'(-$signed({1'b0, N[3:0], 4'b0})) for N=0..8
    for N in range(9):
        v9 = N << 4                                   # 9-bit {0,N,0000}, positive
        corr = (-v9) & ((1 << SUM_W) - 1)
        expect(corr == ((-16 * N) % (1 << SUM_W)), f"corr row N={N}")
    # heap/decode over the whole reachable range: acc_low in [0,511], d in [-128,128]
    ok = True
    for acc_low in range(512):
        for d in range(-128, 129):
            heap = (acc_low + d) % (1 << SUM_W)       # DW02 OUT0+OUT1 mod 2^SUM_W
            low_sum = heap - (1 << SUM_W) if heap >> (SUM_W - 1) else heap
            borrow = (heap >> (SUM_W - 1)) & 1
            carry = (1 - borrow) & ((heap >> LOW_W) & 1)
            new_low = heap & ((1 << LOW_W) - 1)
            if low_sum != acc_low + d or new_low + 512 * (carry - borrow) != acc_low + d:
                ok = False
    expect(ok, "heap / carry / borrow decode")
    print("  acc_low 0..511 x d -128..128: low_sum exact in signed 11 b, "
          "acc_low' + 512*(carry-borrow) exact, never both")


# ----------------------------------------------------------- Sobol (RTL) ---
DIR1 = [0x80, 0x40, 0x20, 0x10, 0x48, 0x04, 0x52, 0xFF]


class Sobol:
    def __init__(self, dset, base, stride):
        self.dset = dset
        self.shift = [(base ^ ((stride * l) & 0xFF)) & 0xFF for l in range(M)]
        self.reset()

    def reset(self):
        self.count = 0
        self.val = list(self.shift)

    def dirv(self, idx):
        return (1 << (WIDTH - 1 - idx)) if self.dset == 0 else DIR1[idx]

    def step(self, en):
        if not en:
            return
        sel = 0
        for i in range(WIDTH):
            if not (self.count >> i) & 1:
                sel = self.dirv(i)
                break
        self.count = (self.count + 1) & 0xFF
        self.val = [v ^ sel for v in self.val]


def masks(salt):
    ks = ((256 * 79 // 128) | 1)
    ms = ((256 * 49 // 128) | 1)
    return np.array([[(k * ks + m * ms + salt) & 255 for m in range(M)] for k in range(K)])


MASK_A, MASK_W = masks(0), masks(128)


# ------------------------------------------------------------ peripheral ---
class Edge:
    """One sc_pe_peripheral half (A or W) with the proposed INT changes."""

    def __init__(self, mask, int_hw=True, shared_lines=False):
        self.mask, self.int_hw, self.shared = mask, int_hw, shared_lines
        self.mag = np.zeros((8, K), dtype=np.int64)
        self.sgn = np.zeros((8, K), dtype=np.int64)

    def bits(self, rand, raw, binary_in, int_mode):
        cmp = (self.mag[:, :, None] > (np.array(rand)[None, None, :] ^ self.mask[None])).astype(np.int64)
        if not self.int_hw:
            return cmp
        r = raw.copy()
        if self.shared:
            # design: raw_bits[1023:0] reuses binary_in[511:0] plus 512 new lines;
            # flat index i -> (row, k, m) as a_bits[(row*K+k)*M+m]
            b = ((binary_in.reshape(-1)[:, None] >> np.arange(8)) & 1).reshape(-1)  # 512 bits
            r = r.reshape(-1).copy()
            r[:512] |= b
            r = r.reshape(8, K, M)
        return cmp | r

    def update(self, load, binary_in, signs_in, int_mode):
        if load:
            if not (self.int_hw and int_mode):
                self.mag = binary_in.copy()
            self.sgn = signs_in.copy()


# -------------------------------------------------------------------- PE ---
class PE:
    def __init__(self, ring_hw=True):
        z = lambda *s: np.zeros(s, dtype=np.int64)
        self.ring_hw = ring_hw
        self.a, self.w = z(NH, K, M), z(NW, K, M)
        self.asg, self.wsg = z(NH, K), z(NW, K)
        self.lda = self.ldw = self.ring = 0
        self.lo, self.hi = z(NH, NW), z(NH, NW)
        self.pc, self.pb = z(NH, NW), z(NH, NW)

    def acc_out(self):
        hn = (self.hi + np.where(self.pb == 1, (1 << HIGH_W) - 1, 0) + self.pc) & ((1 << HIGH_W) - 1)
        return (hn << LOW_W) | self.lo, hn

    def comb(self):
        """Combinational tile outputs from current state."""
        prod = self.a[:, None] & self.w[None, :]                     # NH,NW,K,M
        s0a, s0b, s1, s2, s3 = csa16(prod)
        n = self.asg[:, None, :] ^ self.wsg[None, :, :]               # NH,NW,K
        row4 = ((s3 ^ n) << 3) | ((s2 ^ n) << 2) | ((s1 ^ n) << 1) | (s0a ^ n)
        row1 = s0b ^ n
        N = n.sum(-1)
        heap = (row4.sum(-1) + row1.sum(-1) + ((-(N << 4)) & 2047) + self.lo) & 2047
        ls = np.where(heap >> 10, heap - 2048, heap)
        if ls.min() < -128 or ls.max() > 1023:
            raise AssertionError("low_sum outside RTL range")
        ref = np.where(n == 1, -prod.sum(-1), prod.sum(-1)).sum(-1) + self.lo
        if not np.array_equal(ls, ref):
            raise AssertionError("heap != independent signed popcount")
        return heap

    def step(self, ins, mac_en, shift_in, reset):
        """ins: dict a, asg, lda, w, wsg, ldw, ring, west[NH]. Returns nothing;
        outputs must be read (outputs()) before step."""
        heap = self.comb()
        ao, hn = self.acc_out()
        acc_in = np.empty_like(ao)
        acc_in[:, 1:] = ao[:, :-1]
        west = np.array(ins["west"], dtype=np.int64) & M24
        if self.ring_hw and self.ring:
            west = (ao[:, NW - 1] << 1) & M24          # {acc_out_east[22:0],1'b0}
        acc_in[:, 0] = west
        sh = shift_in | (self.ring if self.ring_hw else 0)
        if reset:
            nlo = nhi = npc = npb = np.zeros_like(self.lo)
        elif sh:
            nlo, nhi = acc_in & 511, acc_in >> 9
            npc = npb = np.zeros_like(self.lo)
        else:
            pend = (self.pc | self.pb) == 1
            nhi = np.where(pend, hn, self.hi)
            if mac_en:
                nlo = heap & 511
                npb = (heap >> 10) & 1
                npc = (1 - npb) & ((heap >> 9) & 1)
            else:
                nlo, npc, npb = self.lo, np.zeros_like(self.lo), np.zeros_like(self.lo)
        if np.any((npc == 1) & (npb == 1)):
            raise AssertionError("pending carry and borrow both set")
        # PE registers
        if reset:
            nasg, nwsg = np.zeros_like(self.asg), np.zeros_like(self.wsg)
            nlda = nldw = nring = 0
        else:
            nasg = ins["asg"].copy() if self.lda else self.asg
            nwsg = ins["wsg"].copy() if self.ldw else self.wsg
            nlda, nldw, nring = ins["lda"], ins["ldw"], ins["ring"]
        self.a, self.w = ins["a"].copy(), ins["w"].copy()
        self.asg, self.wsg = nasg, nwsg
        self.lda, self.ldw, self.ring = nlda, nldw, nring
        self.lo, self.hi, self.pc, self.pb = nlo, nhi, npc, npb

    def outputs(self):
        ao, _ = self.acc_out()
        return dict(a=self.a, asg=self.asg, lda=self.lda, ring=self.ring,
                    w=self.w, wsg=self.wsg, ldw=self.ldw, east=ao[:, NW - 1])


class Grid:
    def __init__(self, pr, pc, ring_hw=True, shared_lines=False, int_hw=True):
        self.pr, self.pc = pr, pc
        self.pes = [[PE(ring_hw) for _ in range(pc)] for _ in range(pr)]
        self.ea = [Edge(MASK_A, int_hw, shared_lines) for _ in range(pr)]
        self.ew = [Edge(MASK_W, int_hw, shared_lines) for _ in range(pc)]
        self.sa, self.sw = Sobol(0, 0x17, 0x53), Sobol(1, 0x9D, 0x2B)

    def step(self, x):
        """x: per-cycle inputs.  Returns pre-edge acc_out_east per PE row."""
        pr, pc = self.pr, self.pc
        outs = [[p.outputs() for p in row] for row in self.pes]
        abits = [self.ea[r].bits(self.sa.val, x["araw"][r], x["abin"][r], x["int_mode"]) for r in range(pr)]
        wbits = [self.ew[c].bits(self.sw.val, x["wraw"][c], x["wbin"][c], x["int_mode"]) for c in range(pc)]
        east = [s24(outs[r][pc - 1]["east"]) for r in range(pr)]
        for r in range(pr):
            for c in range(pc):
                if c == 0:
                    a, asg, lda, ring = abits[r], self.ea[r].sgn, x["lda"][r], x["ring"][r]
                    west = np.zeros(NH, dtype=np.int64)          # grid west edge tied 0
                else:
                    o = outs[r][c - 1]
                    a, asg, lda, ring, west = o["a"], o["asg"], o["lda"], o["ring"], o["east"]
                if r == 0:
                    w, wsg, ldw = wbits[c], self.ew[c].sgn, x["ldw"][c]
                else:
                    o = outs[r - 1][c]
                    w, wsg, ldw = o["w"], o["wsg"], o["ldw"]
                self.pes[r][c].step(dict(a=a, asg=asg, lda=lda, ring=ring, west=west,
                                         w=w, wsg=wsg, ldw=ldw),
                                    x["mac_en"], x["shift_in"], x.get("reset", 0))
        for r in range(pr):
            self.ea[r].update(x["load_a"][r], x["abin"][r], x["asgn"][r], x["int_mode"])
        for c in range(pc):
            self.ew[c].update(x["load_w"][c], x["wbin"][c], x["wsgn"][c], x["int_mode"])
        self.sa.step(x.get("rng_en", 0))
        self.sw.step(x.get("rng_en", 0))
        return east


# ------------------------------------------------------------ sequencer ---
def plane(v, p, b):
    return (int(v) & ((1 << b) - 1)) >> p & 1


class Mode:
    """Mapping per design text.  Returns per-pass functions."""

    def __init__(self, name, ba, bw):
        self.name, self.ba, self.bw = name, ba, bw
        if name == "HW":
            # rows: (activation i_local = h//ba, plane p = h%ba); cols: output j=v; w planes in time
            self.rows_pe, self.cols_pe = NH // ba, NW
            self.stages = [[(None, q)] for q in reversed(range(bw))]
        elif name == "HB":
            self.rows_pe, self.cols_pe = NH, NW
            self.stages = [[(p, s - p) for p in range(ba) if 0 <= s - p < bw]
                           for s in reversed(range(ba + bw - 1))]
        elif name == "S":
            self.rows_pe, self.cols_pe = NH // ba, NW // bw
            self.stages = [[(None, None)]]
        else:
            raise ValueError(name)

    def arow(self, h, pt):
        if self.name == "HB":
            return h, pt
        return h // self.ba, h % self.ba

    def wcol(self, v, qt):
        if self.name == "HW":
            return v, qt
        if self.name == "HB":
            return v, qt
        return v // self.bw, v % self.bw


def run(A, W, mode, ba, bw, pr, pc, sign_lead=1, drain_early=0, next_early=0,
        unsigned_a=False, stale_mag=None, rng=None):
    """Full GEMM through the grid.  Returns (C, cycles, block_period)."""
    mo = Mode(mode, ba, bw)
    Mt, L = A.shape
    Nt = W.shape[1]
    nb = -(-L // 128)
    ar, wc = pr * mo.rows_pe, pc * mo.cols_pe
    blocks = [(ti, tj) for ti in range(-(-Mt // ar)) for tj in range(-(-Nt // wc))]
    g = Grid(pr, pc, ring_hw=(len(mo.stages) > 1))
    if stale_mag is not None:                      # leftover SC magnitudes (Part E)
        for e in g.ea + g.ew:
            e.mag = stale_mag.copy()
    # Build each block's slot list: slot = dict(data=(pt,qt,b) | None, ring=0/1, sign=(pt,qt)|None)
    def slots():
        sl = []
        for si, st in enumerate(mo.stages):
            if si:
                sl += [dict(data=None, ring=1, sign=None) for _ in range(NW)]
            for (pt, qt) in st:
                first = len(sl)
                sl += [dict(data=(pt, qt, b), ring=0, sign=None) for b in range(nb)]
                # the pass's signs ride one slot ahead of its first data (sign_lead)
                tgt = first - sign_lead
                sl_sign = (pt, qt)
                if tgt < 0:
                    sl = [dict(data=None, ring=0, sign=None) for _ in range(-tgt)] + sl
                    first += -tgt
                    tgt = 0
                assert sl[tgt]["sign"] is None
                sl[tgt]["sign"] = sl_sign
        return sl

    # absolute timing (derived in the report): last data slot reaches PE(pr-1,pc-1)'s tiles
    # at n0+tau+(pr-1)+(pc-1)+1; drain must start after that; next block's first data
    # (slot tau_f) reaches PE(0,0) tiles at n0'+tau_f+1 and must be >= drain end.
    sched = []
    n0 = 0
    for (ti, tj) in blocks:
        sl = slots()
        tau_last = max(i for i, s in enumerate(sl) if s["data"])
        tau_first = min(i for i, s in enumerate(sl) if s["data"])
        n_d = n0 + tau_last + pr + pc - drain_early
        sched.append(dict(ti=ti, tj=tj, n0=n0, sl=sl, n_d=n_d))
        # next block: its first data slot must reach PE(0,0) at n >= n_d + 8*pc
        n0_next = n_d + NW * pc - (tau_first + 1) - next_early
        n0 = max(n0_next, n0 + 1)
    n_end = sched[-1]["n_d"] + NW * pc
    C = {}
    zero8 = np.zeros((8, K), dtype=np.int64)
    rngv = rng if rng is not None else np.random.default_rng(1)

    def a_bits(blk, r, pt, b):
        bits = np.zeros((NH, K, M), dtype=np.int64)
        for h in range(NH):
            il, p = mo.arow(h, pt)
            i = blk["ti"] * ar + r * mo.rows_pe + il
            if i >= Mt:
                continue
            seg = np.zeros(128, dtype=np.int64)
            hi_ = min(L, 128 * b + 128)
            seg[:hi_ - 128 * b] = A[i, 128 * b:hi_]
            bits[h] = ((seg & ((1 << ba) - 1)) >> p & 1).reshape(K, M)   # byte n -> lane n//16, pos n%16
        return bits

    def w_bits(blk, c, qt, b):
        bits = np.zeros((NW, K, M), dtype=np.int64)
        for v in range(NW):
            jl, q = mo.wcol(v, qt)
            j = blk["tj"] * wc + c * mo.cols_pe + jl
            if j >= Nt:
                continue
            seg = np.zeros(128, dtype=np.int64)
            hi_ = min(L, 128 * b + 128)
            seg[:hi_ - 128 * b] = W[128 * b:hi_, j]
            bits[v] = ((seg & ((1 << bw) - 1)) >> q & 1).reshape(K, M)
        return bits

    def a_sign(pt):
        s = np.zeros((NH, K), dtype=np.int64)
        for h in range(NH):
            _, p = mo.arow(h, pt)
            s[h, :] = 0 if unsigned_a else int(p == ba - 1)
        return s

    def w_sign(qt):
        s = np.zeros((NW, K), dtype=np.int64)
        for v in range(NW):
            _, q = mo.wcol(v, qt)
            s[v, :] = int(q == bw - 1)
        return s

    cache = {}
    comb = {}
    for n in range(n_end):
        x = dict(int_mode=1, mac_en=1, shift_in=0, rng_en=1,
                 araw=[np.zeros((NH, K, M), dtype=np.int64) for _ in range(pr)],
                 wraw=[np.zeros((NW, K, M), dtype=np.int64) for _ in range(pc)],
                 abin=[rngv.integers(0, 256, (8, K)) for _ in range(pr)],   # junk
                 wbin=[rngv.integers(0, 256, (8, K)) for _ in range(pc)],
                 asgn=[zero8] * pr, wsgn=[zero8] * pc,
                 load_a=[0] * pr, load_w=[0] * pc, lda=[0] * pr, ldw=[0] * pc,
                 ring=[0] * pr)
        drain = None
        for bi, blk in enumerate(sched):
            for r in range(pr):
                tau = n - blk["n0"] - r
                if 0 <= tau < len(blk["sl"]):
                    s = blk["sl"][tau]
                    if s["data"]:
                        pt, qt, b = s["data"]
                        key = ("a", bi, r, pt, b)
                        if key not in cache:
                            cache[key] = a_bits(blk, r, pt, b)
                        x["araw"][r] = x["araw"][r] | cache[key]
                    if s["sign"]:
                        x["asgn"][r] = a_sign(s["sign"][0])
                        x["load_a"][r] = x["lda"][r] = 1
                    x["ring"][r] |= s["ring"]
            for c in range(pc):
                tau = n - blk["n0"] - c
                if 0 <= tau < len(blk["sl"]):
                    s = blk["sl"][tau]
                    if s["data"]:
                        pt, qt, b = s["data"]
                        key = ("w", bi, c, qt, b)
                        if key not in cache:
                            cache[key] = w_bits(blk, c, qt, b)
                        x["wraw"][c] = x["wraw"][c] | cache[key]
                    if s["sign"]:
                        x["wsgn"][c] = w_sign(s["sign"][1])
                        x["load_w"][c] = x["ldw"][c] = 1
            if blk["n_d"] <= n < blk["n_d"] + NW * pc:
                assert drain is None
                drain = blk
        if drain is not None:
            x["shift_in"] = 1
            assert not any(x["ring"]), "ring control during a drain"
        east = g.step(x)
        if drain is None:
            continue
        blk = drain
        t = n - blk["n_d"]
        cc, v = pc - 1 - t // NW, NW - 1 - t % NW
        for r in range(pr):
            xv = [int(e) for e in east[r]]
            if mode == "HW":
                for gi in range(NH // ba):
                    S = sum((1 << p) * xv[gi * ba + p] for p in range(ba))
                    i = blk["ti"] * ar + r * mo.rows_pe + gi
                    j = blk["tj"] * wc + cc * mo.cols_pe + v
                    C[(i, j)] = S
            elif mode == "HB":
                for h in range(NH):
                    i = blk["ti"] * ar + r * mo.rows_pe + h
                    j = blk["tj"] * wc + cc * mo.cols_pe + v
                    C[(i, j)] = xv[h]
            else:  # S: tree over a planes, Horner over w planes in drain order (v high first)
                for gi in range(NH // ba):
                    S = sum((1 << p) * xv[gi * ba + p] for p in range(ba))
                    jl, q = mo.wcol(v, None)
                    i = blk["ti"] * ar + r * mo.rows_pe + gi
                    j = blk["tj"] * wc + cc * mo.cols_pe + jl
                    key = (i, j)
                    comb[key] = S if q == bw - 1 else 2 * comb[key] + S
                    if q == 0:
                        C[key] = comb[key]
    out = np.zeros((Mt, Nt), dtype=np.int64)
    for (i, j), val in C.items():
        if i < Mt and j < Nt:
            out[i, j] = val
    period = (sched[1]["n0"] - sched[0]["n0"]) if len(sched) > 1 else None
    return out, n_end, period


def gemm_ok(A, W, *a, **k):
    out, n, per = run(A, W, *a, **k)
    ref = A.astype(np.int64) @ W.astype(np.int64)
    return np.array_equal(out, ref), out, ref, n, per


def rint(rng, b, shape, unsigned=False):
    if unsigned:
        return rng.integers(0, 1 << b, shape)
    return rng.integers(-(1 << (b - 1)), 1 << (b - 1), shape)


# ----------------------------------------------------------------- Part B ---
def part_b(rng, long_run):
    print("\n== B: register-level grid, bit-plane HW-ring / HB-ring / BP-S ==")
    PREC = {"INT8": (8, 8), "W4A8": (8, 4), "INT4": (4, 4)}
    n_ok = 0
    for (pr, pc) in [(1, 1), (2, 2), (2, 3), (4, 4)]:
        for prec, (ba, bw) in PREC.items():
            mo = Mode("HW", ba, bw)
            Mt = pr * mo.rows_pe + (1 if pr > 1 else 0)
            Nt = pc * mo.cols_pe + (1 if pc > 1 else 0)
            Ks = [1, 129, 300] if (pr, pc) != (4, 4) else [200]
            for L in Ks:
                A, W = rint(rng, ba, (Mt, L)), rint(rng, bw, (L, Nt))
                A[0, 0], A[-1, -1] = -(1 << (ba - 1)), (1 << (ba - 1)) - 1
                W[0, 0], W[-1, -1] = -(1 << (bw - 1)), (1 << (bw - 1)) - 1
                ok, out, ref, n, per = gemm_ok(A, W, "HW", ba, bw, pr, pc, rng=rng)
                expect(ok, f"HW {prec} {pr}x{pc} L={L} random")
                n_ok += ok
                print(f"  HW-ring {prec} {pr}x{pc} L={L:4d} M={Mt} N={Nt}: "
                      f"{'exact' if ok else 'MISMATCH'}; block period {per}")
    # extremes at L=1024 (all -128, min x max, -1 x -128 etc.) on 2x2 incl. INT4/W4
    for prec, (ba, bw) in PREC.items():
        lo_a, hi_a, lo_w, hi_w = -(1 << (ba - 1)), (1 << (ba - 1)) - 1, -(1 << (bw - 1)), (1 << (bw - 1)) - 1
        mo = Mode("HW", ba, bw)
        Mt, Nt = 2 * mo.rows_pe, 2 * NW
        L = 1024
        A = np.empty((Mt, L), dtype=np.int64)
        W = np.empty((L, Nt), dtype=np.int64)
        rows = [lo_a, hi_a, -1, 0]
        cols = [lo_w, hi_w, -1, 1, 0, lo_w, hi_w, -1]
        for i in range(Mt):
            A[i] = rows[i % 4]
        for j in range(Nt):
            W[:, j] = cols[j % 8]
        ok, out, ref, n, per = gemm_ok(A, W, "HW", ba, bw, 2, 2, rng=rng)
        expect(ok, f"HW {prec} 2x2 extremes L=1024")
        n_ok += ok
        print(f"  HW-ring {prec} 2x2 L=1024 rows {rows} x cols {cols[:5]}: "
              f"{'exact' if ok else 'MISMATCH'}; max|out| {int(np.abs(ref).max())}")
    # unsigned activations (uint8 after ReLU): a_sign = 0
    A, W = rint(rng, 8, (2, 300), unsigned=True), rint(rng, 8, (300, 16))
    A[0, :] = 255
    ok, *_ = gemm_ok(A, W, "HW", 8, 8, 2, 2, unsigned_a=True, rng=rng)
    expect(ok, "HW uint8 x int8")
    n_ok += ok
    print(f"  HW-ring uint8 x int8 2x2 L=300: {'exact' if ok else 'MISMATCH'}")
    # HB (W4A8, INT4) and BP-S (INT8, W4A8)
    for mode, prec, (ba, bw), (pr, pc) in [("HB", "W4A8", (8, 4), (1, 1)), ("HB", "INT4", (4, 4), (2, 2)),
                                          ("S", "INT8", (8, 8), (2, 3)), ("S", "W4A8", (8, 4), (2, 2))]:
        mo = Mode(mode, ba, bw)
        Mt, Nt = pr * mo.rows_pe + 1, pc * mo.cols_pe + 1
        L = 257
        A, W = rint(rng, ba, (Mt, L)), rint(rng, bw, (L, Nt))
        A[:, 0], W[0, :] = -(1 << (ba - 1)), -(1 << (bw - 1))
        ok, *_ , n, per = gemm_ok(A, W, mode, ba, bw, pr, pc, rng=rng)
        expect(ok, f"{mode} {prec} {pr}x{pc}")
        n_ok += ok
        print(f"  {mode:2s} {prec} {pr}x{pc} L={L} M={Mt} N={Nt}: {'exact' if ok else 'MISMATCH'}; "
              f"block period {per}")
    # 24-bit limit, HW INT8: |T| = 128 L.  L = 65535 must be exact, 65536 must fail.
    lims = [(65535, True), (65536, False)] if long_run else [(4096, True)]
    for L, should in lims:
        A = np.empty((1, L), dtype=np.int64)
        A[0] = -128
        W = np.empty((L, 2), dtype=np.int64)
        W[:, 0], W[:, 1] = -128, 127
        t0 = time.time()
        ok, out, ref, n, per = gemm_ok(A, W, "HW", 8, 8, 1, 1, rng=rng)
        expect(ok == should, f"HW INT8 OWIDTH limit L={L} expected {'exact' if should else 'overflow'}")
        print(f"  HW-ring INT8 1x1 all -128 x [-128,127] L={L}: out={out[0].tolist()} "
              f"ref={ref[0].tolist()} -> {'exact' if ok else 'WRONG (tile T=128L wraps 24 b)'}"
              f" [{time.time() - t0:.0f} s]")
        n_ok += (ok == should)
    if long_run:
        # HB W4A8 limit: |a*w| <= 1024 -> L <= 8191
        for L, should in [(8191, True), (8192, False)]:
            A = np.full((1, L), -128, dtype=np.int64)
            W = np.full((L, 1), -8, dtype=np.int64)
            ok, out, ref, n, per = gemm_ok(A, W, "HB", 8, 4, 1, 1, rng=rng)
            expect(ok == should, f"HB W4A8 limit L={L}")
            print(f"  HB-ring W4A8 1x1 all -128 x -8 L={L}: out={int(out[0,0])} ref={int(ref[0,0])} "
                  f"-> {'exact' if ok else 'WRONG (24-bit wrap)'}")
            n_ok += (ok == should)
    return n_ok


# ----------------------------------------------------------------- Part C ---
def part_c(rng):
    print("\n== C: negative controls on schedule timing (each must FAIL) ==")
    A, W = rint(rng, 8, (3, 260)), rint(rng, 8, (260, 17))
    base_ok, *_ , per = gemm_ok(A, W, "HW", 8, 8, 2, 2, rng=rng)
    expect(base_ok, "control baseline")
    print(f"  baseline HW INT8 2x2 L=260 (2 blocks x 2): {'exact' if base_ok else 'MISMATCH'}, "
          f"period {per}")
    for kw, what in [(dict(drain_early=1), "drain shift_in one cycle early"),
                     (dict(next_early=1), "next block one cycle early (overlaps drain)"),
                     (dict(sign_lead=0), "pass sign loaded with its first data")]:
        ok, *_ = gemm_ok(A, W, "HW", 8, 8, 2, 2, rng=rng, **kw)
        expect(not ok, f"negative control not caught: {what}")
        print(f"  {what:46s}: {'caught (mismatch)' if not ok else 'NOT CAUGHT'}")
    ok, *_ = gemm_ok(A, W, "HW", 8, 8, 2, 2, rng=rng, sign_lead=4)
    expect(ok, "sign 4 slots early inside ring bubbles should still be exact")
    print(f"  sign loaded 4 slots early (inside ring lap)       : {'exact' if ok else 'MISMATCH'}")


# ----------------------------------------------------------------- Part D ---
def sc_stream(shared, n_batches=6, seed=7, zero_lines=False):
    """SC streaming schedule of power_payn_array.sv (T=128, MAC_CYCLES=8) on one
    PE, original peripheral vs modified peripheral.  Returns final tile values."""
    rng = np.random.default_rng(seed)
    g = Grid(1, 1, ring_hw=True, shared_lines=shared, int_hw=True)
    ref = Grid(1, 1, ring_hw=False, int_hw=False)
    MC = 8
    batches = [dict(abin=(rng.integers(0, 128, (8, K)) << 1), wbin=(rng.integers(0, 128, (8, K)) << 1),
                    asg=rng.integers(0, 2, (8, K)), wsg=rng.integers(0, 2, (8, K)))
               for _ in range(n_batches)]
    zero = [np.zeros((NH, K, M), dtype=np.int64)]

    z8 = np.zeros((8, K), dtype=np.int64)

    def x_for(bt, load, mac):
        ab = bt["abin"] if (load or not zero_lines) else z8
        wb = bt["wbin"] if (load or not zero_lines) else z8
        return dict(int_mode=0, mac_en=mac, shift_in=0, rng_en=1, araw=zero, wraw=zero,
                    abin=[ab], wbin=[wb], asgn=[bt["asg"]], wsgn=[bt["wsg"]],
                    load_a=[load], load_w=[load], lda=[load], ldw=[load], ring=[0])
    # prologue: load batch 0, one clock, then a clock with mac_en, then window
    seq = [x_for(batches[0], 1, 0), x_for(batches[0], 0, 0)]
    nxt = 1
    cur = batches[0]
    for cyc in range(n_batches * MC):
        load = ((cyc + 2) % MC == 0) and nxt < n_batches
        if load:
            cur = batches[nxt]
            nxt += 1
        # binary_in holds the most recently issued batch (bench keeps it stable)
        seq.append(x_for(cur, int(load), 1))
    mism = 0
    for x in seq:
        g.step(x)
        ref.step(x)
        st_g = (g.pes[0][0].a, g.pes[0][0].w)
        st_r = (ref.pes[0][0].a, ref.pes[0][0].w)
        mism += int(not (np.array_equal(st_g[0], st_r[0]) and np.array_equal(st_g[1], st_r[1])))
    vg = s24(g.pes[0][0].acc_out()[0])
    vr = s24(ref.pes[0][0].acc_out()[0])
    return mism, vg, vr


def part_d():
    print("\n== D: SC transparency of the peripheral change (real SC streaming schedule) ==")
    for shared, zl, label in [(False, False, "dedicated 1024 raw lines, driven 0 in SC"),
                              (True, False, "raw[511:0] = binary_in[511:0], bench holds binary_in"),
                              (True, True, "raw[511:0] = binary_in[511:0], binary_in 0 off load cycles")]:
        mism, vg, vr = sc_stream(shared, zero_lines=zl)
        same = np.array_equal(vg, vr)
        nbad = int((vg != vr).sum())
        print(f"  {label}: bit-pipe cycles differing {mism}; "
              f"tiles differing {nbad}/64 after 6 T=128 batches"
              + ("" if same else f"; e.g. tile(0,0) {int(vg[0,0])} vs original {int(vr[0,0])}"))
        if not shared:
            expect(same and mism == 0, "SC transparency with dedicated raw lines")
        else:
            expect(not same, "shared-line SC corruption expected (finding)")


# ----------------------------------------------------------------- Part E ---
def part_e(rng):
    print("\n== E: SC -> INT entry with stale held magnitudes ==")
    A, W = rint(rng, 8, (1, 256)), rint(rng, 8, (256, 8))
    stale = (rng.integers(0, 128, (8, K)) << 1)
    ok0, *_ = gemm_ok(A, W, "HW", 8, 8, 1, 1, rng=rng)
    ok1, out, ref, *_ = gemm_ok(A, W, "HW", 8, 8, 1, 1, rng=rng, stale_mag=stale)
    print(f"  binary_q zeroed (reset): {'exact' if ok0 else 'MISMATCH'}; "
          f"binary_q left from SC: {'exact' if ok1 else 'WRONG'} "
          f"(e.g. out[0,0]={int(out[0,0])} vs {int(ref[0,0])})")
    expect(ok0 and not ok1, "stale-magnitude precondition behaviour")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--long", action="store_true", help="run L=65535/65536 and HB 8191/8192 limits")
    ap.add_argument("--seed", type=int, default=31337)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    t0 = time.time()
    part_a()
    part_b(rng, args.long)
    part_c(rng)
    part_d()
    part_e(rng)
    print(f"\n{'ALL EXPECTATIONS MET' if not FAILS else str(len(FAILS)) + ' UNEXPECTED RESULTS'}"
          f" in {time.time() - t0:.0f} s")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
