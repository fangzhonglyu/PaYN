#!/usr/bin/env python3
"""Shared reference for the all-bits-in-time (abit) INT schedule on AF-IPD (doc/cbsg_handoff.md section 5).

Used by check_abit_trace.py (single-PE functional bench, +MODE=abit of designs/payn/tb/test_payn_array_cbsg_af_ipd.sv),
check_abit_power_trace.py (the abit INT energy bench) and check_abit_grid_trace.py (the abit grid bench).

Three independent things are computed from a trace:

1. gemm_tiles: the expected drained values from numpy int64 GEMM of the operands alone (A @ W); tile (h, v) of block
   blk = ig*NJG + jg holds C[ig*8 + h, jg*8 + v], drain step t carries column v = 7 - t.  Nothing about the schedule
   enters this reference.
2. check_schedule: the bench's logged stimulus (P pass starts with their W sign, K raw-plane captures, L lap edges,
   X drain edges, M first MAC edge) against the schedule rules and the block-period formula
       BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + 8*P_C:
   every bit pair once per block, sign (p == BA-1) XOR (q == BW-1), levels p+q non-increasing in steps of at most
   one, passes of one level contiguous with no lap, one bubble and one lap (on the next level's first capture) per
   level step, no other lap, NB consecutive captures per pass, 8*P_C consecutive drain edges starting S = P_R+P_C-2
   edges after the edge following the block's last capture (one bubble = the last MAC), the last drain edge being the
   next block's first capture.  The measured period of every block is (next block's first capture - this block's
   first capture), and for the last block (its last drain edge - its first capture).
3. replay (single PE): what the tiles must hold given the LOGGED stimulus, edge by edge: a lap edge doubles every
   tile (mod 2^24), a drain edge reads the east column and shifts east with 0 entering, otherwise (mac_en) the sample
   captured on the previous edge is added with the sign in force at its capture.  For a correct schedule it equals
   the GEMM; for a negative control the RTL must equal the replay (the hardware did what the wrong schedule says)
   and differ from the GEMM.
"""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path

import numpy as np

OWIDTH = 24
MOD = 1 << OWIDTH


def wrap(v):
    """Signed OWIDTH-bit value of an integer (or int64 array)."""
    v = np.asarray(v, dtype=np.int64) % MOD
    return np.where(v >= MOD // 2, v - MOD, v)


def read_hex(path: Path, n: int) -> np.ndarray:
    vals = [int(x, 16) for x in path.read_text().split()]
    if len(vals) != n:
        raise SystemExit(f"{path}: {len(vals)} entries, expected {n}")
    v = np.array(vals, dtype=np.int64)
    return np.where(v >= 128, v - 256, v)


def formula(ba: int, bw: int, nb: int, pr: int = 1, pc: int = 1) -> int:
    return ba * bw * nb + (ba + bw - 2) + (pr + pc - 2) + 8 * pc


def precision_name(ba: int, bw: int) -> str:
    return f"INT{ba}" if ba == bw else f"W{bw}A{ba}"


def load_operands(run_dir: Path, ba: int, bw: int, mrows: int, ncols: int, L: int):
    A = read_hex(run_dir / "bpt_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(run_dir / "bpt_w.hex", ncols * L).reshape(ncols, L).T          # (L, ncols)
    a_lo, a_hi = -(1 << (ba - 1)), (1 << (ba - 1)) - 1
    w_lo, w_hi = -(1 << (bw - 1)), (1 << (bw - 1)) - 1
    if A.min() < a_lo or A.max() > a_hi or W.min() < w_lo or W.max() > w_hi:
        raise SystemExit("operands outside the declared precision")
    return A, W


def parse_records(lines: list[str]):
    """P/K/L/X/M/D/C records of an abit trace (header excluded)."""
    rec = dict(P=[], K=[], L=[], X=[], M=[], D={}, C={}, Dedge={}, dup=[])
    for line in lines:
        f = line.split()
        if not f:
            continue
        t = f[0]
        if t == "P":
            rec["P"].append(tuple(int(x) for x in f[1:7]))          # e blk j p q sign
        elif t == "K":
            rec["K"].append(tuple(int(x) for x in f[1:5]))          # e blk j u
        elif t == "L":
            rec["L"].append(int(f[1]))
        elif t == "X":
            rec["X"].append(tuple(int(x) for x in f[1:4]))          # e blk t
        elif t == "M":
            rec["M"].append(int(f[1]))
        elif t == "D":
            vals = [int(x) for x in f[3:]]
            key = (int(f[1]), int(f[2]))
            if len(vals) == 9:                                      # power bench: D blk t e v0..v7
                rec["Dedge"][key] = vals[0]
                vals = vals[1:]
            if len(vals) != 8:
                raise SystemExit(f"D line with {len(vals)} values")
            if key in rec["D"]:
                rec["dup"].append(("D",) + key)
            rec["D"][key] = vals
        elif t == "C":
            key = (int(f[1]), int(f[2]))
            if key in rec["C"]:
                rec["dup"].append(("C",) + key)
            rec["C"][key] = (int(f[3]), int(f[4]))
        else:
            raise SystemExit(f"unknown trace record {t!r}")
    return rec


def gemm_tiles(A: np.ndarray, W: np.ndarray, nblk: int, njg: int, pr: int = 1, pc: int = 1):
    """{(blk, r, t): [8 expected values]}: PE row r, drain step t (PE column pc-1-t//8, tile column 7-t%8)."""
    C = A @ W
    out = {}
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        for r in range(pr):
            for t in range(8 * pc):
                c, v = pc - 1 - t // 8, 7 - t % 8
                j = (jg * pc + c) * 8 + v
                out[(blk, r, t)] = [int(C[(ig * pr + r) * 8 + h, j]) for h in range(8)]
    return out, C


def check_schedule(cfg: dict, rec: dict, pr: int = 1, pc: int = 1) -> dict:
    """Rules of the abit schedule on the logged stimulus (PE (0,0) time for a grid)."""
    ba, bw, nb, nblk, e0 = cfg["ba"], cfg["bw"], cfg["nb"], cfg["nblk"], cfg["e0"]
    S = pr + pc - 2
    nd = 8 * pc
    want_formula = formula(ba, bw, nb, pr, pc)
    errors: list[str] = []
    passes = defaultdict(list)                       # blk -> [(e, j, p, q, s)]
    for e, blk, j, p, q, s in rec["P"]:
        passes[blk].append((e, j, p, q, s))
    caps = defaultdict(list)                         # (blk, j) -> [(e, u)]
    for e, blk, j, u in rec["K"]:
        caps[(blk, j)].append((e, u))
    laps = sorted(rec["L"])
    lapset = set(laps)
    if len(lapset) != len(laps):
        errors.append("a lap edge is logged twice")
    drains = defaultdict(list)
    for e, blk, t in rec["X"]:
        drains[blk].append((e, t))
    pairs = {(p, q) for p in range(ba) for q in range(bw)}
    used_laps = set()
    starts, last_drain, periods = {}, {}, []
    for blk in range(nblk):
        pl = sorted(passes.get(blk, []))
        if {(p, q) for _, _, p, q, _ in pl} != pairs or len(pl) != ba * bw:
            errors.append(f"block {blk}: passes are not every (p, q) pair exactly once ({len(pl)} passes)")
            continue
        for e, j, p, q, s in pl:
            want_s = int((p == ba - 1) ^ (q == bw - 1))
            if s != want_s:
                errors.append(f"block {blk} pass ({p},{q}) at edge {e}: W sign {s}, expected {want_s}")
        spans = []
        for e, j, p, q, s in pl:
            cl = sorted(caps.get((blk, j), []))
            if cl != [(e + u, u) for u in range(nb)]:
                errors.append(f"block {blk} pass ({p},{q}): captures {cl[:3]}... are not u = 0..{nb-1} from edge {e}")
            spans.append((e, e + nb - 1, p + q))
        if pl[0][2] + pl[0][3] != ba + bw - 2:
            errors.append(f"block {blk}: first pass level {pl[0][2] + pl[0][3]}, expected {ba + bw - 2} (MSB first)")
        for (f0, l0, k0), (f1, l1, k1) in zip(spans, spans[1:]):
            inside = [x for x in laps if l0 < x <= f1]
            if k1 == k0:
                if f1 != l0 + 1 or inside:
                    errors.append(f"block {blk}: passes of level {k0} at {f0}..{l0} and {f1}.. not contiguous "
                                  f"or lapped ({len(inside)} laps between)")
            elif k1 == k0 - 1:
                if f1 != l0 + 2 or inside != [f1]:
                    errors.append(f"block {blk}: level {k0} -> {k1} step at edges {l0} -> {f1}: needs one bubble and "
                                  f"one lap on {l0 + 2}, got first capture {f1} and laps {inside}")
            else:
                errors.append(f"block {blk}: level {k0} followed by level {k1} (must not increase or skip)")
            used_laps.update(inside)
        dl = sorted(drains.get(blk, []))
        d0 = spans[-1][1] + 2 + S
        if dl != [(d0 + t, t) for t in range(nd)]:
            errors.append(f"block {blk}: drain edges {dl[:2]}..{dl[-1:]} , expected {nd} edges from {d0}")
        starts[blk] = spans[0][0]
        last_drain[blk] = dl[-1][0] if dl else d0 + nd - 1     # the measured last drain edge
    if set(lapset) - used_laps:
        errors.append(f"{len(lapset - used_laps)} lap edge(s) outside the level steps, e.g. {sorted(lapset - used_laps)[:3]}")
    if len(laps) != nblk * (ba + bw - 2):
        errors.append(f"{len(laps)} laps, expected {nblk * (ba + bw - 2)}")
    if starts:
        if starts.get(0) != e0:
            errors.append(f"block 0 starts at edge {starts.get(0)}, header E0 = {e0}")
        for blk in range(nblk):
            if blk not in starts:
                continue
            end = starts[blk + 1] if blk + 1 in starts else last_drain[blk]
            if blk + 1 in starts and starts[blk + 1] != last_drain[blk]:
                errors.append(f"block {blk + 1} starts at {starts[blk + 1]}, not on block {blk}'s last drain edge "
                              f"{last_drain[blk]}")
            periods.append(end - starts[blk])
    if rec["M"] != [e0 + 1]:
        errors.append(f"first MAC edge {rec['M']}, expected [{e0 + 1}]")
    period_ok = bool(periods) and all(p == want_formula for p in periods)
    if not period_ok:
        errors.append(f"measured block periods {sorted(set(periods))} != formula {want_formula}")
    return dict(errors=errors, periods=periods, formula=want_formula, period_ok=period_ok,
                laps=len(laps), passes=sum(len(v) for v in passes.values()))


def replay(cfg: dict, rec: dict, A: np.ndarray, W: np.ndarray) -> dict:
    """Single-PE edge model of the logged stimulus -> {(blk, t): [8 drained values]}."""
    ba, bw, nblk, njg = cfg["ba"], cfg["bw"], cfg["nblk"], cfg["ncols"] // 8
    a_pl = [(((A & ((1 << ba) - 1)) >> p) & 1).astype(np.int64) for p in range(ba)]   # (mrows, L)
    w_pl = [(((W & ((1 << bw) - 1)) >> q) & 1).astype(np.int64) for q in range(bw)]   # (L, ncols)
    pq = {}
    for e, blk, j, p, q, s in rec["P"]:
        pq[(blk, j)] = (p, q)
    sign_at = {e: s for e, blk, j, p, q, s in rec["P"]}
    cap = {e: (blk, j, u) for e, blk, j, u in rec["K"]}
    lap = set(rec["L"])
    drn = {e: (blk, t) for e, blk, t in rec["X"]}
    mac0 = rec["M"][0] if rec["M"] else 1 << 62
    last = max([0] + list(cap) + list(lap) + list(drn))
    T = np.zeros((8, 8), dtype=np.int64)
    sign = 0
    sample_sign = {}
    out = {}
    for e in range(0, last + 1):
        if e in drn:
            out[drn[e]] = [int(x) for x in wrap(T[:, 7])]
        if e in lap:
            T = wrap(2 * T)
        elif e in drn:
            T = np.concatenate([np.zeros((8, 1), np.int64), T[:, :7]], axis=1)
        elif e >= mac0 and (e - 1) in cap:
            blk, j, u = cap[e - 1]
            ig, jg = divmod(blk, njg)
            p, q = pq[(blk, j)]
            xs = slice(u * 128, (u + 1) * 128)
            cnt = a_pl[p][ig * 8:(ig + 1) * 8, xs] @ w_pl[q][xs, jg * 8:(jg + 1) * 8]
            T = wrap(T + (-cnt if sample_sign[e - 1] else cnt))
        if e in sign_at:
            sign = sign_at[e]
        sample_sign[e] = sign
    return out
