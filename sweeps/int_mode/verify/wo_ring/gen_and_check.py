#!/usr/bin/env python3
"""Stimulus generator and checker for tb_wo_ring.sv (WO-ring INT mode, RTL).

Independent of the architect's model: the schedule, Booth recoding, feed skew,
ring timing, drain timing and collector are re-derived here from the design
text.  The data-mover code tables are the claimed ones (verified separately by
indep_arith_check.py).

  gen   CASE STIM META    write the per-edge stimulus and the case metadata
  check META OUT          rebuild the outputs from the drained values and
                          compare with numpy A @ W
  list                    print the case table (name PR PC expect)

Timing derived for slot s (PE(r,c), row skew r, column skew c):
  A peripheral of PE row r loads slot s at edge s+r, W peripheral of PE
  column c at edge s+c; both reach PE(r,c)'s bit pipes at edge s+r+c+1 and the
  tiles act (MAC or ring) at edge s+r+c+2.  ring_in[r] = 1 at edge s+r+1.
  The last MAC of a segment (slot s_last) lands in PE(PR-1,PC-1) at
  s_last+PR+PC; the global drain occupies edges s_last+PR+PC+1 ... +8*PC.
  The next segment's first slot s0 must satisfy s0+2 > last drain edge.
"""
import json
import sys
import zlib
from pathlib import Path

import numpy as np

K, NH, NW = 8, 8, 8
CODE_A = np.array([[0, 73, 245], [0, 111, 234], [0, 143, 214], [0, 124, 250],
                   [0, 132, 255], [0, 96, 234], [0, 75, 253], [0, 137, 248]])
CODE_W = np.array([[0, 35, 53, 61, 115, 144, 150, 195, 240],
                   [0, 15, 20, 35, 55, 83, 100, 178, 220],
                   [0, 85, 108, 123, 170, 180, 196, 233, 248],
                   [0, 17, 26, 34, 93, 99, 126, 213, 246],
                   [0, 4, 23, 71, 138, 171, 185, 223, 254],
                   [0, 41, 64, 139, 152, 165, 179, 206, 232],
                   [0, 53, 64, 76, 85, 126, 199, 217, 255],
                   [0, 81, 102, 144, 160, 214, 231, 237, 252]])

MODES = {   # a bits, w bits, A radix-4 digits, W radix-16 digits
    "INT8": (8, 8, 4, 2), "W4A8": (8, 4, 4, 1), "INT4": (4, 4, 2, 1)}
CHUNK = {("INT8", "LSB"): 262143, ("INT8", "FH"): 511, ("INT8", "HYS"): 8191, ("W4A8", "HO"): 8191,
         ("INT4", "HO"): 131071}


def booth(v, n, r):
    """Radix-2^r Booth digits (last axis, LSB first) of n-bit values v."""
    u = np.asarray(v, dtype=np.int64) & ((1 << n) - 1)
    b = lambda i: np.zeros_like(u) if i < 0 else (u >> min(i, n - 1)) & 1
    out = []
    for d in range(-(-n // r)):
        s = b(r * d - 1) - (1 << (r - 1)) * b(r * d + r - 1)
        for t in range(r - 1):
            s = s + (1 << t) * b(r * d + t)
        out.append(s)
    return np.stack(out, -1)


def passes(mode, variant):
    """List of weight groups; each group is a list of (p, q); q=None -> W
    digit in space (HYS).  Consecutive groups differ by 2 bits (one ring)."""
    if variant == "FH":
        return [[(3, 1)], [(2, 1)], [(3, 0), (1, 1)], [(2, 0), (0, 1)], [(1, 0)], [(0, 0)]]
    if variant == "HYS":
        return [[(3, None)], [(2, None)], [(1, None)], [(0, None)]]
    if variant == "LSB":   # user's shift-down: ascending weight, ring = >>2
        return [[(0, 0)], [(1, 0)], [(2, 0), (0, 1)], [(3, 0), (1, 1)], [(2, 1)], [(3, 1)]]
    na = MODES[mode][2]
    return [[(p, 0)] for p in reversed(range(na))]


def schedule(mode, variant, L, PR, PC, chunk, opts=()):
    """opts (negative timing controls): drain_early = global drain one edge
    early; gap_minus1 = next segment one slot earlier than the tightest legal
    start."""
    slots, drains = [], []
    for lo in range(0, L, chunk):
        hi = min(L, lo + chunk)
        C = -(-(hi - lo) // K)
        for gi, grp in enumerate(passes(mode, variant)):
            if gi:
                slots += [("ring",)] * NW          # one x4 rotation = 8 edges
            for p, q in grp:
                slots += [("mac", p, q, lo, hi, t) for t in range(C)]
        s_last = len(slots) - 1
        d1 = s_last + PR + PC + 1 - ("drain_early" in opts)
        drains.append((d1, NW * PC))
        s0 = d1 + NW * PC - 2 - ("gap_minus1" in opts)                       # first slot of the next segment:
        slots += [("idle",)] * (s0 - len(slots))   # tightest s0 with s0+2 > d1+8PC-1
    n_edges = drains[-1][0] + drains[-1][1] + 2
    return slots, drains, n_edges


def make_data(mode, variant, L, PR, PC, kind, rng):
    na_b, nw_b = MODES[mode][0], MODES[mode][1]
    alo, ahi = -(1 << (na_b - 1)), (1 << (na_b - 1)) - 1
    wlo, whi = -(1 << (nw_b - 1)), (1 << (nw_b - 1)) - 1
    ncol = (NW // 2 if variant == "HYS" else NW) * PC
    sa, sw = (NH * PR, L), (L, ncol)
    if kind == "random":
        A, W = rng.integers(alo, ahi + 1, sa), rng.integers(wlo, whi + 1, sw)
        A[0] = alo; W[:, -1] = wlo; A[-1, ::3] = ahi; W[::5, 0] = whi
    elif kind == "allmin":
        A, W = np.full(sa, alo), np.full(sw, wlo)
    elif kind == "allmax":
        A, W = np.full(sa, ahi), np.full(sw, whi)
    elif kind == "minmax":
        A, W = np.full(sa, alo), np.full(sw, whi)
    elif kind == "boundary":   # Booth digit boundary values
        va = np.array([v for v in (alo, alo + 1, alo + 2, -1, 0, 1, ahi - 1, ahi,
                                   ahi // 2 + 1, -(ahi // 2 + 1), 2, -2, 3, -3)
                       if alo <= v <= ahi])
        vw = np.array([v for v in (wlo, wlo + 1, -1, 0, 1, whi, whi - 1, 7, -7, 8, -8, 9, -9)
                       if wlo <= v <= whi])
        A = va[rng.integers(0, len(va), sa)]
        W = vw[rng.integers(0, len(vw), sw)]
    elif kind == "alternating":
        s = np.where(np.arange(L) % 2 == 0, 1, -1)
        A = np.where(s[None, :] > 0, ahi, alo) * np.ones(sa, dtype=np.int64)
        A[1::2] = -A[1::2] - 1
        W = np.where(s[:, None] > 0, wlo, whi) * np.ones(sw, dtype=np.int64)
    else:
        raise ValueError(kind)
    return A.astype(np.int64), W.astype(np.int64)


def pack_codes(codes):
    """codes[h][k] -> integer with byte (h*K+k) = code (peripheral packing)."""
    return int.from_bytes(np.asarray(codes, dtype=np.uint8).reshape(-1).tobytes(), "little")


def pack_signs(signs):
    return int.from_bytes(np.packbits(np.asarray(signs, dtype=np.uint8).reshape(-1),
                                      bitorder="little").tobytes(), "little")


CASES = [
    # name, mode, variant, L, PR, PC, kind, chunk(None=claimed), opts
    ("fh_rand_1x1_200", "INT8", "FH", 200, 1, 1, "random", None, ""),
    ("fh_bound_1x1_333", "INT8", "FH", 333, 1, 1, "boundary", None, "zs gr"),
    ("fh_allmin_1x1_511", "INT8", "FH", 511, 1, 1, "allmin", None, ""),
    ("fh_minmax_1x1_511", "INT8", "FH", 511, 1, 1, "minmax", None, ""),
    ("fh_rand_1x1_1022_2chunks", "INT8", "FH", 1022, 1, 1, "random", None, ""),
    ("fh_alt_2x2_511", "INT8", "FH", 511, 2, 2, "alternating", None, "zs gr"),
    ("fh_rand_2x3_200", "INT8", "FH", 200, 2, 3, "random", None, ""),
    ("fh_allmin_2x2_511", "INT8", "FH", 511, 2, 2, "allmin", None, ""),
    ("hys_rand_1x1_1024", "INT8", "HYS", 1024, 1, 1, "random", None, ""),
    ("hys_bound_2x2_1000", "INT8", "HYS", 1000, 2, 2, "boundary", None, "zs gr"),
    ("hys_rand_3x2_700", "INT8", "HYS", 700, 3, 2, "random", None, ""),
    ("hys_allmin_1x1_8191", "INT8", "HYS", 8191, 1, 1, "allmin", None, ""),
    ("hys_minmax_1x1_8191", "INT8", "HYS", 8191, 1, 1, "minmax", None, ""),
    ("hys_rand_1x1_9001_2chunks", "INT8", "HYS", 9001, 1, 1, "random", None, ""),
    ("w4a8_alt_2x3_333", "W4A8", "HO", 333, 2, 3, "alternating", None, ""),
    ("w4a8_minmax_1x1_8191", "W4A8", "HO", 8191, 1, 1, "minmax", None, ""),
    ("w4a8_bound_1x3_517", "W4A8", "HO", 517, 1, 3, "boundary", None, "zs gr"),
    ("int4_rand_3x2_1000", "INT4", "HO", 1000, 3, 2, "random", None, ""),
    ("int4_bound_2x2_999", "INT4", "HO", 999, 2, 2, "boundary", None, "zs gr"),
    ("int4_allmin_1x1_131071", "INT4", "HO", 131071, 1, 1, "allmin", None, ""),
    # negative controls: one MAC past the claimed limit must wrap
    ("NEG_fh_allmin_1x1_512", "INT8", "FH", 512, 1, 1, "allmin", 512, "expect_fail"),
    ("NEG_hys_allmin_1x1_8192", "INT8", "HYS", 8192, 1, 1, "allmin", 8192, "expect_fail"),
    # second batch: true W4A8 worst case, multi-chunk grids, timing controls
    ("w4a8_allmin_1x1_8191", "W4A8", "HO", 8191, 1, 1, "allmin", None, ""),
    ("fh_rand_2x2_1100_3chunks", "INT8", "FH", 1100, 2, 2, "random", None, "zs gr"),
    ("hys_bound_2x3_8300_2chunks", "INT8", "HYS", 8300, 2, 3, "boundary", None, "zs gr"),
    ("int4_rand_2x2_300", "INT4", "HO", 300, 2, 2, "random", None, "gr"),
    ("NEG_fh_drain_early_2x2_200", "INT8", "FH", 200, 2, 2, "random", None, "drain_early expect_fail"),
    ("NEG_fh_ring_late_2x2_200", "INT8", "FH", 200, 2, 2, "random", None, "ring_late expect_fail"),
    ("NEG_fh_gap_minus1_2x2_1022", "INT8", "FH", 1022, 2, 2, "random", None, "gap_minus1 expect_fail"),
    ("NEG_int4_allmin_1x1_131072", "INT4", "HO", 131072, 1, 1, "allmin", 131072, "expect_fail"),
    # the user's shift-down idea (LSB-first, arithmetic >>2 ring, emitted bits)
    ("lsb_rand_2x2_1000", "INT8", "LSB", 1000, 2, 2, "random", None, "zs gr"),
    ("lsb_allmin_1x1_4096", "INT8", "LSB", 4096, 1, 1, "allmin", None, ""),
    ("lsb_bound_1x2_777", "INT8", "LSB", 777, 1, 2, "boundary", None, ""),
]


def gen(name, stim_path, meta_path):
    case = next(c for c in CASES if c[0] == name)
    _, mode, variant, L, PR, PC, kind, chunk, opts = case
    chunk = chunk or CHUNK[(mode, variant)]
    rng = np.random.default_rng(zlib.crc32(name.encode()))
    A, W = make_data(mode, variant, L, PR, PC, kind, rng)
    na_b, nw_b, n_a, n_w = MODES[mode]
    dA = booth(A, na_b, 2)            # (rows, L, n_a)
    dW = booth(W, nw_b, 4)            # (L, cols, n_w)
    assert np.array_equal((dA * 4 ** np.arange(n_a)).sum(-1), A)
    assert np.array_equal((dW * 16 ** np.arange(n_w)).sum(-1), W)
    slots, drains, n_edges = schedule(mode, variant, L, PR, PC, chunk, opts.split())
    ring_lag = 1 + ("ring_late" in opts.split())     # ring_in at edge s+r+1 (+1 if late)
    drain_edges = {d1 + i for d1, n in drains for i in range(n)}
    kidx = np.arange(K)[None, :]
    v_ar = np.arange(NW)
    zs, gr = "zs" in opts.split(), "gr" in opts.split()

    def slot(i):
        return slots[i] if 0 <= i < len(slots) else ("idle",)

    def side(sl, which, idx):
        if sl[0] == "ring" and gr:          # garbage during ring slots
            d = rng.integers(-8 if which == "w" else -2, 9 if which == "w" else 3, (NH, K))
        elif sl[0] != "mac":
            d = np.zeros((NH, K), dtype=np.int64)
        else:
            _, p, q, lo, hi, t = sl
            ks = lo + K * t + np.arange(K)
            ok = ks < hi
            ks = np.where(ok, ks, 0)
            if which == "a":
                d = dA[NH * idx:NH * idx + NH][:, ks, p]
            elif q is None:                  # HYS: column v -> weight 4c+v//2, digit v%2
                d = dW[ks][:, (NW // 2) * idx + v_ar // 2, v_ar % 2].T
            else:
                d = dW[ks][:, NW * idx:NW * idx + NW, q].T
            d = np.where(ok[None, :], d, 0)
        code = (CODE_A if which == "a" else CODE_W)[kidx, np.abs(d)]
        sign = (d < 0).astype(np.int64)
        if zs:                               # zero digits carry a random sign
            sign = np.where(d == 0, rng.integers(0, 2, d.shape), sign)
        return pack_codes(code), pack_signs(sign)

    with open(stim_path, "w") as f:
        f.write(f"{n_edges}\n")
        for e in range(n_edges):
            ring = sum(1 << r for r in range(PR) if slot(e - r - ring_lag)[0] == "ring")
            toks = [f"{int(e in drain_edges):x}", f"{ring:x}"]
            for r in range(PR):
                c_, s_ = side(slot(e - r), "a", r)
                toks += [f"{c_:x}", f"{s_:x}"]
            for c in range(PC):
                c_, s_ = side(slot(e - c), "w", c)
                toks += [f"{c_:x}", f"{s_:x}"]
            f.write(" ".join(toks) + "\n")
    np.savez_compressed(str(meta_path) + ".npz", A=A, W=W)
    meta = dict(name=name, mode=mode, variant=variant, L=L, PR=PR, PC=PC, kind=kind,
                chunk=chunk, opts=opts, drains=drains, n_edges=n_edges,
                slots=len(slots), mac_slots=sum(s[0] == "mac" for s in slots),
                ring_slots=sum(s[0] == "ring" for s in slots))
    Path(meta_path).write_text(json.dumps(meta, indent=1))


def check(meta_path, out_path):
    meta = json.loads(Path(meta_path).read_text())
    dat = np.load(str(meta_path) + ".npz")
    A, W = dat["A"], dat["W"]
    PR, PC, variant = meta["PR"], meta["PC"], meta["variant"]
    ref = A.astype(object) @ W.astype(object)
    out = np.zeros(ref.shape, dtype=object)
    edge_info = {}
    for d1, n in meta["drains"]:
        for i in range(n):
            edge_info[d1 + i] = NW * PC - 1 - i       # global column drained
    nx, seen = None, set()
    emitted, ring_cnt = {}, {}
    for line in Path(out_path).read_text().split("\n"):
        if not line:
            continue
        if line.startswith("R "):                  # LSB: emitted 2 bits at a ring edge
            _, e, r, c, h, b = line.split()
            r, c, h, b = int(r), int(c), int(h), int(b)
            n = ring_cnt.get((r, c, h), 0)
            ring_cnt[(r, c, h)] = n + 1
            v_loc = NW - 1 - (n % NW)              # tile whose value passes the mux
            emitted.setdefault((r, c, h, v_loc), []).append(b)
            continue
        if line.startswith("END"):
            nx = int(line.split()[1])
            continue
        e, r, h, v = map(int, line.split())
        gc = edge_info[e]
        seen.add((e, r, h))
        if variant == "HYS":
            out[NH * r + h, gc // 2] += v << (4 * (gc % 2))
        elif variant == "LSB":
            em = emitted.pop((r, gc // NW, h, gc % NW))
            out[NH * r + h, gc] += (v << (2 * len(em))) + sum(x << (2 * i) for i, x in enumerate(em))
        else:
            out[NH * r + h, gc] += v
    exp_samples = len(edge_info) * PR * NH
    ok = (nx == 0 and len(seen) == exp_samples and not emitted and np.array_equal(out, ref))
    nbad = int(np.sum(out != ref))
    expect_fail = "expect_fail" in meta["opts"]
    verdict = ("PASS" if ok != expect_fail else "FAIL")
    tag = " (negative control: mismatch expected)" if expect_fail else ""
    print(f"{verdict} {meta['name']}: {meta['mode']}/{meta['variant']} L={meta['L']} "
          f"grid {PR}x{PC} {meta['kind']} chunk={meta['chunk']} opts='{meta['opts']}' "
          f"edges={meta['n_edges']} slots={meta['slots']} (mac {meta['mac_slots']}, ring "
          f"{meta['ring_slots']}) samples={len(seen)}/{exp_samples} X={nx} "
          f"mismatches={nbad}/{ref.size} max|ref|={int(np.max(np.abs(ref.astype(np.int64))))}{tag}")
    if nbad and not expect_fail:
        idx = np.argwhere(out != ref)[:3]
        for i, j in idx:
            print(f"     out[{i},{j}]={out[i, j]} ref={ref[i, j]}")
    return verdict == "PASS"


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3]) else 1)
    elif sys.argv[1] == "list":
        for c in CASES:
            print(c[0], c[4], c[5], "lsb" if c[2] == "LSB" else "msb")
