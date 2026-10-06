#!/usr/bin/env python3
"""Operand files for the BP-space (T2) INT benches
(designs/payn/tb/test_payn_array_bp_space.sv, designs/payn/tb/test_pe_grid_bp_space.sv).

Same distributions and file format as sweeps/int_mode/bp/gen_bp_workload.py
(whose operands() it calls, unchanged), without that script's NCOLS % 8 rule:
with S weight bits in space a PE holds only 8/S output columns, so a block can
have 1, 2 or 4 columns per PE.

Writes, into OUT_DIR:
  bpt_a.hex       A[i, x]  row-major, MROWS x L, one two's-complement byte per line
  bpt_w.hex       W[x, j]  column-major (entry j*L + x), NCOLS x L bytes
  bpt_meta.json   shape, precision, distribution, seed, operand ranges

Usage:
  gen_bp_space_workload.py --ba 8 --bw 8 --L 1024 --mrows 2 --ncols 3 --dist uniform --seed 1 --out-dir DIR
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gen_bp_workload import DISTS, operands  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ba", type=int, required=True, choices=(4, 8))
    ap.add_argument("--bw", type=int, required=True, choices=(4, 8))
    ap.add_argument("--L", type=int, required=True)
    ap.add_argument("--mrows", type=int, required=True)
    ap.add_argument("--ncols", type=int, required=True)
    ap.add_argument("--dist", required=True, choices=DISTS)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out-dir", type=Path, required=True)
    args = ap.parse_args()

    if args.L < 128 or args.L % 128:
        raise SystemExit("L must be a positive multiple of 128")
    if args.mrows < 1 or args.ncols < 1:
        raise SystemExit("MROWS and NCOLS must be positive")

    rng = np.random.default_rng(args.seed)
    A, W = operands(args.dist, args.ba, args.bw, args.mrows, args.ncols, args.L, rng)
    assert A.shape == (args.mrows, args.L) and W.shape == (args.L, args.ncols)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "bpt_a.hex").write_text(
        "\n".join(f"{v & 0xFF:02x}" for v in A.reshape(-1)) + "\n")
    (args.out_dir / "bpt_w.hex").write_text(
        "\n".join(f"{v & 0xFF:02x}" for v in W.T.reshape(-1)) + "\n")
    gemm = A @ W
    meta = dict(ba=args.ba, bw=args.bw, L=args.L, mrows=args.mrows, ncols=args.ncols,
                dist=args.dist, seed=args.seed,
                a_min=int(A.min()), a_max=int(A.max()), w_min=int(W.min()), w_max=int(W.max()),
                gemm_min=int(gemm.min()), gemm_max=int(gemm.max()))
    (args.out_dir / "bpt_meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
