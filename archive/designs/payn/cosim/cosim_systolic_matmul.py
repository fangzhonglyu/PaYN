#!/usr/bin/env python3
"""Check multi-PE RTL against both PaYN's SC model and ideal signed matmul."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from payn_sim import array_reference, parse_trace


def signed_values(magnitude: np.ndarray, sign: np.ndarray) -> np.ndarray:
    values = magnitude.astype(np.int64)
    return np.where(sign.astype(bool), -values, values)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument(
        "--mag-shift",
        type=int,
        default=1,
        help="right shift from encoded comparator magnitude to logical magnitude",
    )
    parser.add_argument(
        "--max-nrmse",
        type=float,
        default=0.10,
        help="maximum scaled stochastic error versus ideal signed matmul",
    )
    args = parser.parse_args()

    cfg, a_mag, a_sign, w_mag, w_sign, rtl = parse_trace(args.trace)
    expected_sc = array_reference(a_mag, a_sign, w_mag, w_sign, cfg)

    if not np.array_equal(expected_sc, rtl):
        print("[FAIL] multi-PE RTL does not match the PaYN matmul model")
        print("RTL drain:\n", rtl)
        print("Expected SC matmul:\n", expected_sc)
        print("RTL - expected:\n", rtl - expected_sc)
        return 1

    logical_a = a_mag >> args.mag_shift
    logical_w = w_mag >> args.mag_shift
    signed_a = signed_values(logical_a, a_sign)
    signed_w = signed_values(logical_w, w_sign)
    ideal = signed_a @ signed_w.T

    levels = 1 << (cfg.WIDTH - args.mag_shift)
    samples = cfg.T * cfg.M
    scaled_rtl = rtl.astype(np.float64) * (levels * levels) / samples
    error = scaled_rtl - ideal
    denom = max(float(np.sqrt(np.mean(ideal.astype(np.float64) ** 2))), 1.0)
    nrmse = float(np.sqrt(np.mean(error**2)) / denom)

    print(
        f"[PASS] multi-PE RTL matches the independent SC matmul model "
        f"for all {rtl.size} outputs"
    )
    print(
        f"Matmul shape: {signed_a.shape} @ {signed_w.T.shape} "
        f"-> {ideal.shape}"
    )
    print(
        f"Scaled {samples}-sample stochastic estimate "
        f"(NRMSE={nrmse:.4f}):"
    )
    scaled_rounded = np.rint(scaled_rtl).astype(np.int64)
    sample_rows = min(4, ideal.shape[0])
    sample_cols = min(4, ideal.shape[1])
    print(f"Ideal top-left {sample_rows}x{sample_cols}:")
    print(ideal[:sample_rows, :sample_cols])
    print(f"Scaled RTL top-left {sample_rows}x{sample_cols}:")
    print(scaled_rounded[:sample_rows, :sample_cols])
    if nrmse > args.max_nrmse:
        print(
            f"[FAIL] NRMSE {nrmse:.4f} exceeds the "
            f"{args.max_nrmse:.4f} matmul limit"
        )
        return 1
    print(
        f"[PASS] scaled result is within the ideal-matmul NRMSE limit "
        f"({nrmse:.4f} <= {args.max_nrmse:.4f})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
