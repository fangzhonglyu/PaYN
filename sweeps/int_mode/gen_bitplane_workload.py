#!/usr/bin/env python3
"""Operand files for the bit-plane INT energy bench (power_payn_array_int_bitplane.sv).

Writes, into OUT_DIR:
  intb_a.hex   A[i, kk]  row-major, MROWS x L, one two's-complement byte per line
  intb_w.hex   W[kk, j]  column-major (W_mem[j*L + kk]), NCOLS x L bytes
  intb_meta.json  shape, precision, distribution, seed, operand statistics

Values are BA-bit (activations) / BW-bit (weights) two's-complement integers,
stored sign-extended to 8 bits; the bench takes bit-plane p as bit p of the
byte, which equals bit p of the BA-bit encoding for p < BA.

Distributions:
  uniform  every integer of the full signed range, equiprobable
  gauss    round(N(0, sigma)), sigma = 2^(B-1)/4 (a quarter of the range),
           clipped to the signed range (DNN-like: most values are small)
  relu     weights as gauss; activations max(0, round(N(0, sigma))) clipped
           to [0, 2^(BA-1)-1] (post-ReLU: half exact zeros, MSB plane zero)

Usage:
  gen_bitplane_workload.py --ba 8 --bw 8 --L 1024 --mrows 6 --ncols 64 \
      --dist uniform --seed 1 --out-dir DIR
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def draw(rng: np.random.Generator, bits: int, dist: str, shape) -> np.ndarray:
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if dist == "uniform":
        return rng.integers(lo, hi + 1, size=shape, dtype=np.int64)
    if dist == "gauss":
        sigma = (1 << (bits - 1)) / 4.0
        return np.clip(np.rint(rng.normal(0.0, sigma, size=shape)), lo, hi).astype(np.int64)
    if dist == "relu":
        sigma = (1 << (bits - 1)) / 4.0
        return np.clip(np.rint(rng.normal(0.0, sigma, size=shape)), 0, hi).astype(np.int64)
    raise SystemExit(f"unknown distribution {dist}")


def plane_density(x: np.ndarray, bits: int) -> list[float]:
    u = x & ((1 << bits) - 1)
    return [float(((u >> p) & 1).mean()) for p in range(bits)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ba", type=int, required=True, choices=(4, 8))
    ap.add_argument("--bw", type=int, required=True, choices=(4, 8))
    ap.add_argument("--L", type=int, required=True)
    ap.add_argument("--mrows", type=int, required=True)
    ap.add_argument("--ncols", type=int, required=True)
    ap.add_argument("--dist", required=True, choices=("uniform", "gauss", "relu"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out-dir", type=Path, required=True)
    args = ap.parse_args()

    if args.L % 128:
        raise SystemExit("L must be a multiple of 128")
    rows_pe = 8 // args.ba
    if args.mrows % rows_pe or args.ncols % 8:
        raise SystemExit(f"MROWS must be a multiple of {rows_pe} and NCOLS of 8")

    rng = np.random.default_rng(args.seed)
    A = draw(rng, args.ba, args.dist, (args.mrows, args.L))
    W = draw(rng, args.bw, "gauss" if args.dist == "relu" else args.dist, (args.L, args.ncols))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "intb_a.hex").write_text(
        "\n".join(f"{v & 0xFF:02x}" for v in A.reshape(-1)) + "\n")
    (args.out_dir / "intb_w.hex").write_text(
        "\n".join(f"{v & 0xFF:02x}" for v in W.T.reshape(-1)) + "\n")
    # Adjacent-cycle plane toggle rate: the bench streams kk-block b then b+1
    # through the same wires, so a wire toggles when plane bit differs between
    # element kk and kk+128 of the same row/column.
    def toggle_rate(x2d: np.ndarray, bits: int) -> list[float]:
        u = x2d & ((1 << bits) - 1)
        out = []
        for p in range(bits):
            b = (u >> p) & 1
            nb = b.shape[-1] // 128
            b = b[..., : nb * 128].reshape(*b.shape[:-1], nb, 128)
            out.append(float((b[..., 1:, :] != b[..., :-1, :]).mean()) if nb > 1 else float("nan"))
        return out
    meta = dict(ba=args.ba, bw=args.bw, L=args.L, mrows=args.mrows, ncols=args.ncols,
                dist=args.dist, seed=args.seed,
                a_mean=float(A.mean()), a_std=float(A.std()),
                w_mean=float(W.mean()), w_std=float(W.std()),
                a_plane_density=plane_density(A, args.ba),
                w_plane_density=plane_density(W, args.bw),
                a_plane_toggle_rate=toggle_rate(A, args.ba),
                w_plane_toggle_rate=toggle_rate(W.T, args.bw))
    (args.out_dir / "intb_meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
