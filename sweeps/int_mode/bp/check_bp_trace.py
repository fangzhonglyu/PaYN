#!/usr/bin/env python3
"""Bit-exact check of the bit-plane INT RTL bench (designs/payn/tb/test_payn_array_bp.sv).

Independent numpy int64 reference.  For every output block (ig, jg) the bench
drains the 8x8 tile matrix after BW weight passes with a x2 ring lap between
passes, and the east-edge combiner (u_combiner) emits one output word per
drained column.  Drain step t of block (ig, jg) carries column v = 7 - t,
j = jg*8 + v.  Tile (h, v) must hold

    T(h, v) = sigma_p * sum_x a_p[x] * W[x, j],
    i = ig*ROWS_PE + h // BA,  p = h % BA,
    a_p = bit p of A[i, x] (BA-bit two's complement), sigma_p = -1 iff p == BA-1,

which is also recomputed pass by pass (MSB-first Horner over the weight planes,
sigma_q = -1 iff q == BW-1, the hardware's order); the two references must
agree.  The combiner word must equal the int64 GEMM:

    lo = (A @ W)[ig*ROWS_PE, j]
    hi = (A @ W)[ig*ROWS_PE + 1, j]  for INT4 (BA = 4, int_prec = 1), else 0

and is cross-checked against sum_p 2^p * drained tile.  Every (block, step)
must appear exactly once in both streams.  Exits 1 on any mismatch.

Usage:  check_bp_trace.py RUN_DIR [--json out.json]
RUN_DIR holds bpt_trace.txt, bpt_a.hex, bpt_w.hex.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OWIDTH = 24
OUT_W = 32


def read_hex(path: Path, n: int) -> np.ndarray:
    vals = [int(x, 16) for x in path.read_text().split()]
    if len(vals) != n:
        raise SystemExit(f"{path}: {len(vals)} entries, expected {n}")
    v = np.array(vals, dtype=np.int64)
    return np.where(v >= 128, v - 256, v)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    args = ap.parse_args()

    lines = (args.run_dir / "bpt_trace.txt").read_text().splitlines()
    if not lines or not lines[0].startswith("BPTCFG"):
        raise SystemExit("missing BPTCFG header")
    cfg = [int(x) for x in lines[0].split()[1:]]
    if len(cfg) != 14:
        raise SystemExit(f"BPTCFG has {len(cfg)} fields, expected 14")
    (ba, bw, L, mrows, ncols, nblk, nb, int_prec, junk, neg_no_ring, neg_prec,
     neg_no_lap_shift, neg_mag, mode_at) = cfg
    rows_pe = 8 // ba
    njg = ncols // 8
    if nblk != (mrows // rows_pe) * njg or nb != L // 128:
        raise SystemExit("BPTCFG shape fields are inconsistent")

    drains: dict[tuple[int, int], list[int]] = {}
    combs: dict[tuple[int, int], tuple[int, int]] = {}
    dup = []
    for line in lines[1:]:
        f = line.split()
        if f[0] == "D":
            key = (int(f[1]), int(f[2]))
            vals = [int(x) for x in f[3:]]
            if len(vals) != 8:
                raise SystemExit(f"D line with {len(vals)} values")
            if key in drains:
                dup.append(("D",) + key)
            drains[key] = vals
        elif f[0] == "C":
            key = (int(f[1]), int(f[2]))
            if key in combs:
                dup.append(("C",) + key)
            combs[key] = (int(f[3]), int(f[4]))
        else:
            raise SystemExit(f"unknown trace record {f[0]!r}")
    want = {(b, t) for b in range(nblk) for t in range(8)}
    coverage_ok = set(drains) == want and set(combs) == want and not dup

    A = read_hex(args.run_dir / "bpt_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(args.run_dir / "bpt_w.hex", ncols * L).reshape(ncols, L).T   # (L, ncols)
    a_lo, a_hi = -(1 << (ba - 1)), (1 << (ba - 1)) - 1
    w_lo, w_hi = -(1 << (bw - 1)), (1 << (bw - 1)) - 1
    if A.min() < a_lo or A.max() > a_hi or W.min() < w_lo or W.max() > w_hi:
        raise SystemExit("operands outside the declared precision")
    a_planes = np.stack([((A & ((1 << ba) - 1)) >> p) & 1 for p in range(ba)])   # (ba, mrows, L)
    w_planes = np.stack([((W & ((1 << bw) - 1)) >> q) & 1 for q in range(bw)])   # (bw, L, ncols)
    gemm = A @ W
    if np.abs(gemm).max() >= (1 << (OUT_W - 1)):
        raise SystemExit("GEMM output exceeds the 32-bit combiner word; workload invalid")

    mismatches = []
    max_abs_tile = max_abs_out = 0
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        for t in range(8):
            v = 7 - t
            j = jg * 8 + v
            got_tiles = drains.get((blk, t))
            for h in range(8):
                il, p = divmod(h, ba)
                i = ig * rows_pe + il
                sig_p = -1 if p == ba - 1 else 1
                t_direct = sig_p * int(a_planes[p, i] @ W[:, j])
                acc = 0
                for q in reversed(range(bw)):
                    sig_q = -1 if q == bw - 1 else 1
                    acc = 2 * acc + sig_p * sig_q * int(a_planes[p, i] @ w_planes[q, :, j])
                if acc != t_direct:
                    raise SystemExit(f"reference self-check failed at block {blk} h{h} v{v}")
                if abs(t_direct) >= (1 << (OWIDTH - 1)):
                    raise SystemExit(f"tile value {t_direct} overflows OWIDTH={OWIDTH}")
                max_abs_tile = max(max_abs_tile, abs(t_direct))
                if got_tiles is not None and got_tiles[h] != t_direct:
                    mismatches.append(dict(kind="tile", block=blk, step=t, h=h, v=v,
                                           got=got_tiles[h], exp=t_direct))
            exp_lo = int(gemm[ig * rows_pe, j])
            exp_hi = int(gemm[ig * rows_pe + 1, j]) if rows_pe == 2 else 0
            max_abs_out = max(max_abs_out, abs(exp_lo), abs(exp_hi))
            got = combs.get((blk, t))
            if got is not None and got != (exp_lo, exp_hi):
                mismatches.append(dict(kind="combiner", block=blk, step=t, col=j,
                                       got=list(got), exp=[exp_lo, exp_hi]))
            if got is not None and got_tiles is not None:
                g = [sum((1 << p) * got_tiles[il * ba + p] for p in range(ba))
                     for il in range(rows_pe)]
                g += [0] * (2 - rows_pe)
                if list(got) != g:
                    mismatches.append(dict(kind="combiner_vs_tiles", block=blk, step=t,
                                           got=list(got), from_tiles=g))

    prec = {(8, 8): "INT8", (8, 4): "W4A8", (4, 4): "INT4", (4, 8): "W8A4"}[(ba, bw)]
    macs = nblk * rows_pe * 8 * L
    result = dict(
        status="PASS" if not mismatches and coverage_ok else "FAIL",
        precision=prec, ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols, blocks=nblk, nb=nb,
        int_prec=int_prec, junk=junk, neg_no_ring=neg_no_ring, neg_prec=neg_prec,
        neg_no_lap_shift=neg_no_lap_shift, neg_mag=neg_mag, mode_at=mode_at,
        coverage_ok=coverage_ok, duplicates=dup[:8],
        tiles_checked=nblk * 64, outputs_checked=nblk * rows_pe * 8, macs=macs,
        max_abs_tile=max_abs_tile, max_abs_output=max_abs_out,
        n_mismatch=len(mismatches), mismatches=mismatches[:16],
    )
    text = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    if result["status"] != "PASS":
        print(f"[FAIL] {prec} L={L} blocks={nblk}: {len(mismatches)} mismatches, "
              f"coverage_ok={coverage_ok}")
        return 1
    print(f"[PASS] {prec} L={L} blocks={nblk}: {nblk * 64} tiles and "
          f"{nblk * rows_pe * 8} GEMM outputs bit-exact ({macs} MACs, max|out| {max_abs_out})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
