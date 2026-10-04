#!/usr/bin/env python3
"""Generate int8 matmul operand cases for the UT RTL-vs-emulator sweep.

Each case is a directory holding a.mem (N x D), b.mem (M x D) in the
t9_sc_matmul $readmemh format, plus shape.txt ("N M D"). Shapes deliberately
include sizes that are not multiples of the array (partial tiles / K-blocks),
D past the 64-column mask period, and degenerate 1x1 cases.

    python gen_ut_cases.py --out sweep_cases
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

Q_MAX = 127

# name: (N, M, D, distribution)
CASES = {
    "s8x8x128_gauss":   (8, 8, 128, "gauss_outlier"),
    "s16x8x64_unif":    (16, 8, 64, "uniform"),
    "s5x7x40_sparse":   (5, 7, 40, "sparse"),
    "s12x20x200_gauss": (12, 20, 200, "gauss_outlier"),
    "s1x1x8_extreme":   (1, 1, 8, "extreme"),
    "s9x9x9_extreme":   (9, 9, 9, "extreme"),
    "s24x16x256_unif":  (24, 16, 256, "uniform"),
    "s3x11x130_pos":    (3, 11, 130, "positive"),
    "s8x8x512_gauss":   (8, 8, 512, "gauss_outlier"),
    "s17x3x77_unif":    (17, 3, 77, "uniform"),
}


def quantize_rows(x: np.ndarray) -> np.ndarray:
    """Per-row symmetric quantization, as the emulator does: max|row| -> 127."""
    scale = np.maximum(np.abs(x).max(axis=1, keepdims=True), 1e-5) / Q_MAX
    return np.clip(np.round(x / scale), -Q_MAX, Q_MAX).astype(np.int64)


def operand(rng: np.random.Generator, rows: int, d: int, dist: str, is_a: bool) -> np.ndarray:
    if dist == "uniform":
        return rng.integers(-Q_MAX, Q_MAX + 1, size=(rows, d))
    if dist == "sparse":
        q = rng.integers(-Q_MAX, Q_MAX + 1, size=(rows, d))
        return np.where(rng.random((rows, d)) < 0.7, 0, q)
    if dist == "extreme":
        return rng.choice([-127, -64, -63, -1, 0, 1, 63, 64, 127], size=(rows, d))
    if dist == "positive":
        return rng.integers(0, Q_MAX + 1, size=(rows, d))
    if dist == "gauss_outlier":
        x = rng.standard_normal((rows, d))
        if is_a:   # activation-like: a few outlier columns
            cols = rng.choice(d, size=max(1, d // 32), replace=False)
            x[:, cols] *= 8.0
        return quantize_rows(x)
    raise ValueError(dist)


def write_mem(path: Path, q: np.ndarray, header: str) -> None:
    lines = [f"// {header}"]
    for row in q:
        lines.append(" ".join(f"{int(v) & 0xFF:02x}" for v in row))
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--seed", type=int, default=2026)
    args = ap.parse_args()
    for i, (name, (n, m, d, dist)) in enumerate(CASES.items()):
        rng = np.random.default_rng(args.seed + i)
        out = args.out / name
        out.mkdir(parents=True, exist_ok=True)
        write_mem(out / "a.mem", operand(rng, n, d, dist, True),
                  f"A[n][d], int8 two's complement, {n} rows x {d} columns ({dist})")
        write_mem(out / "b.mem", operand(rng, m, d, dist, False),
                  f"B[m][d], int8 two's complement, {m} rows x {d} columns ({dist})")
        (out / "shape.txt").write_text(f"{n} {m} {d}\n")
        print(f"{name}: N={n} M={m} D={d} {dist}")


if __name__ == "__main__":
    main()
