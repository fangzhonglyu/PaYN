#!/usr/bin/env python3
# [ABIT COPY] of sweeps/cbsg/af_ipd/gen_bp_workload.py (sha256 6e09a949...cbc8 at copy time, 2026-10-06), itself a
# copy of sweeps/int_mode/bp/gen_bp_workload.py.  Changes for the all-bits-in-time schedule (marked [ABIT]):
#   * any BA, BW in 2..8 (INT6, W6A8, ...), MROWS a multiple of 8 (one activation row per tile row);
#   * distribution "plain": exactly sweeps/cbsg/af_ipd/gen_bitplane_workload.py's operands (A drawn first, then W,
#     same draw(); its uniform / gauss / relu, no forced extremes), i.e. the operand distribution of the routed INT
#     energy points; --dist plain --plain-dist uniform with the same seed and shape writes the same bytes;
#   * the worst-case range of the 24-bit tile is reported (worst_case_abs = L * 2^(BA+BW-2)).
"""Operand files for the all-bits-in-time INT benches (+MODE=abit of
designs/payn/tb/test_payn_array_cbsg_af_ipd.sv, the abit grid and power benches).

Writes, into OUT_DIR:
  bpt_a.hex       A[i, x]  row-major, MROWS x L, one two's-complement byte per line
  bpt_w.hex       W[x, j]  column-major (entry j*L + x), NCOLS x L bytes
  bpt_meta.json   shape, precision, distribution, seed, operand ranges

Values are BA-bit (activations) / BW-bit (weights) two's-complement integers
stored sign-extended to 8 bits, so bit p of the byte is bit p of the BA-bit
encoding for p < BA.

Distributions (lo/hi = the signed range ends, e.g. -128/127 or -32/31):
  uniform      every value of the signed range equiprobable (drawn by
               gen_bitplane_workload.draw), with lo and hi forced into a few
               reduction positions of every row and column so min x min,
               min x max and max x max products always occur
  allmin       A = lo, W = lo        (largest positive product)
  allmax       A = hi, W = hi
  minxmax      A = lo, W = hi        (largest negative product)
  maxxmin      A = hi, W = lo
  neg1xmin     A = -1, W = lo        (every activation plane is 1)
  alternating  A[i, x] = lo/hi alternating along x (phase i), W[x, j] = hi/lo
               alternating along x (phase j): every plane toggles every element
  gauss, relu  as gen_bitplane_workload.py
  plain        [ABIT] gen_bitplane_workload.py's operands for --plain-dist
               (uniform | gauss | relu): the INT energy distribution

Usage:
  gen_abit_workload.py --ba 6 --bw 6 --L 1024 --mrows 8 --ncols 16 --dist uniform --seed 1 --out-dir DIR
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))   # [ABIT] sweeps/cbsg/af_ipd
from gen_bitplane_workload import draw  # noqa: E402

DISTS = ("uniform", "allmin", "allmax", "minxmax", "maxxmin", "neg1xmin", "alternating",
         "gauss", "relu", "plain")
OWIDTH = 24


def operands(dist: str, ba: int, bw: int, mrows: int, ncols: int, L: int,
             rng: np.random.Generator, plain_dist: str = "uniform") -> tuple[np.ndarray, np.ndarray]:
    alo, ahi = -(1 << (ba - 1)), (1 << (ba - 1)) - 1
    wlo, whi = -(1 << (bw - 1)), (1 << (bw - 1)) - 1
    if dist == "plain":   # [ABIT] gen_bitplane_workload.py main(), call for call
        A = draw(rng, ba, plain_dist, (mrows, L))
        W = draw(rng, bw, "gauss" if plain_dist == "relu" else plain_dist, (L, ncols))
        return A, W
    if dist == "uniform":
        A = draw(rng, ba, "uniform", (mrows, L))
        W = draw(rng, bw, "uniform", (L, ncols))
        # Extremes at fixed and random reduction positions.
        A[:, 0], W[0, :] = alo, wlo          # min x min
        A[:, 1], W[1, :] = alo, whi          # min x max
        A[:, 2], W[2, :] = ahi, whi          # max x max
        A[:, -1], W[-1, :] = ahi, wlo        # max x min (last element of the last block)
        for row in A:
            row[rng.choice(L, size=max(1, L // 32), replace=False)] = alo
        for col in W.T:
            col[rng.choice(L, size=max(1, L // 32), replace=False)] = wlo
        return A, W
    if dist in ("gauss", "relu"):
        return (draw(rng, ba, dist, (mrows, L)),
                draw(rng, bw, "gauss", (L, ncols)))
    x = np.arange(L)
    if dist == "allmin":
        return np.full((mrows, L), alo, np.int64), np.full((L, ncols), wlo, np.int64)
    if dist == "allmax":
        return np.full((mrows, L), ahi, np.int64), np.full((L, ncols), whi, np.int64)
    if dist == "minxmax":
        return np.full((mrows, L), alo, np.int64), np.full((L, ncols), whi, np.int64)
    if dist == "maxxmin":
        return np.full((mrows, L), ahi, np.int64), np.full((L, ncols), wlo, np.int64)
    if dist == "neg1xmin":
        return np.full((mrows, L), -1, np.int64), np.full((L, ncols), wlo, np.int64)
    if dist == "alternating":
        A = np.where((x[None, :] + np.arange(mrows)[:, None]) % 2 == 0, alo, ahi).astype(np.int64)
        W = np.where((x[:, None] + np.arange(ncols)[None, :]) % 2 == 0, whi, wlo).astype(np.int64)
        return A, W
    raise SystemExit(f"unknown distribution {dist}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ba", type=int, required=True, choices=range(2, 9))   # [ABIT]
    ap.add_argument("--bw", type=int, required=True, choices=range(2, 9))
    ap.add_argument("--L", type=int, required=True)
    ap.add_argument("--mrows", type=int, required=True)
    ap.add_argument("--ncols", type=int, required=True)
    ap.add_argument("--dist", required=True, choices=DISTS)
    ap.add_argument("--plain-dist", default="uniform", choices=("uniform", "gauss", "relu"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--row-unit", type=int, default=8,
                    help="MROWS must be a multiple of this (8: one activation row per tile row; "
                         "the current-schedule controls use 8 // BA)")
    ap.add_argument("--out-dir", type=Path, required=True)
    args = ap.parse_args()

    if args.L < 128 or args.L % 128:
        raise SystemExit("L must be a positive multiple of 128")
    if args.mrows < args.row_unit or args.mrows % args.row_unit or args.ncols < 8 or args.ncols % 8:
        raise SystemExit(f"MROWS must be a multiple of {args.row_unit} and NCOLS of 8")

    rng = np.random.default_rng(args.seed)
    A, W = operands(args.dist, args.ba, args.bw, args.mrows, args.ncols, args.L, rng, args.plain_dist)
    assert A.shape == (args.mrows, args.L) and W.shape == (args.L, args.ncols)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "bpt_a.hex").write_text(
        "\n".join(f"{v & 0xFF:02x}" for v in A.reshape(-1)) + "\n")
    (args.out_dir / "bpt_w.hex").write_text(
        "\n".join(f"{v & 0xFF:02x}" for v in W.T.reshape(-1)) + "\n")
    gemm = A @ W
    worst = args.L * (1 << (args.ba + args.bw - 2))
    meta = dict(ba=args.ba, bw=args.bw, L=args.L, mrows=args.mrows, ncols=args.ncols,
                dist=args.dist, plain_dist=args.plain_dist if args.dist == "plain" else None, seed=args.seed,
                a_min=int(A.min()), a_max=int(A.max()), w_min=int(W.min()), w_max=int(W.max()),
                gemm_min=int(gemm.min()), gemm_max=int(gemm.max()),
                worst_case_abs=worst, worst_case_fits_tile=worst <= (1 << (OWIDTH - 1)) - 1)
    (args.out_dir / "bpt_meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
