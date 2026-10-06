#!/usr/bin/env python3
"""SC dot-product accuracy versus stream length T, including padded T.

Companion to sweeps/run_pending_t_pad_power.sh: energy per MAC is a step
function of ceil(T/M) while accuracy improves with T sample-by-sample, so the
accuracy/energy Pareto is made of flat-energy segments.  This script supplies
the accuracy axis using the repo's bit-exact SC model (sc_kernel): the same
Sobol banks, Owen scramble and slice ordering as the hardware, with the top
M - T%M lanes of each block's final slice dead -- exactly what
power_payn_array_tpad.sv executes.

Metric: one inner-tile block accumulates, per lane d and sample t,
and = a_bit & w_bit with product sign s_d.  The signed sample mean
(1/T)*sum_d,t s_d*and estimates sum_d s_d*(a_d/2^W)*(w_d/2^W).  RMSE of
(estimate - exact) over random operand batches, per T.

Usage: python3 sweeps/sc_tpad_accuracy.py [--blocks 4000] [--tmin 16]
           [--tmax 128] [--out build/power_char/t_pad/accuracy_vs_T.csv]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent
                       / "designs" / "payn" / "cosim"))
from sc_kernel import ArrayCfg, edge_operand_bits  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--blocks", type=int, default=4000,
                   help="random operand batches per T point")
    p.add_argument("--tmin", type=int, default=16)
    p.add_argument("--tmax", type=int, default=128)
    p.add_argument("--k", type=int, default=8)
    p.add_argument("--m", type=int, default=16)
    p.add_argument("--width", type=int, default=8)
    p.add_argument("--mag-width", type=int, default=7,
                   help="logical magnitude bits; encoded as mag << (WIDTH-MAG_WIDTH)")
    p.add_argument("--seed", type=int, default=0xDEADBEEF)
    p.add_argument("--out", type=Path,
                   default=Path("build/power_char/t_pad/accuracy_vs_T.csv"))
    args = p.parse_args()

    K, M, W = args.k, args.m, args.width
    levels = 1 << W
    rng = np.random.default_rng(args.seed)

    # One tile row/col pair is enough: accuracy is a per-tile property.
    cfg = ArrayCfg(K=K, M=M, N_H=1, N_W=1, WIDTH=W, OWIDTH=24,
                   T=args.tmax, RNG_FULL_PERIOD_WRAP=False)

    # Random operands per block, MAG_WIDTH-precision like the bench:
    # logical 0..2^MAG-1 encoded as mag << (W-MAG).
    shift = W - args.mag_width
    a_mag = (rng.integers(0, 1 << args.mag_width,
                          size=(args.blocks, 1, K)) << shift).astype(np.int64)
    w_mag = (rng.integers(0, 1 << args.mag_width,
                          size=(args.blocks, 1, K)) << shift).astype(np.int64)
    a_sgn = rng.integers(0, 2, size=(args.blocks, K))
    w_sgn = rng.integers(0, 2, size=(args.blocks, K))
    lane_sign = np.where(a_sgn ^ w_sgn, -1.0, 1.0)          # (blocks, K)
    exact = (lane_sign * (a_mag[:, 0, :] / levels)
             * (w_mag[:, 0, :] / levels)).sum(axis=1)        # (blocks,)

    max_cycles = -(-args.tmax // M)
    rng_a = cfg.make_rng_in()
    rng_w = cfg.make_rng_w()

    # Signed AND-count per (block, slice, lane-within-slice): shape
    # (blocks, max_cycles, M).  Sobol advances continuously across blocks,
    # exactly as rng_en=1 holds across the bench's SAIF window.
    signed_and = np.zeros((args.blocks, max_cycles, M))
    for b in range(args.blocks):
        for c in range(max_cycles):
            thr_a = rng_a.step()
            thr_w = rng_w.step()
            ab = edge_operand_bits(a_mag[b], thr_a, K, M, W, 0)
            wb = edge_operand_bits(w_mag[b], thr_w, K, M, W, 1 << (W - 1))
            prod = (ab[0] & wb[0]).astype(np.float64)        # (K, M)
            signed_and[b, c] = (lane_sign[b][:, None] * prod).sum(axis=0)

    rows = ["T,mac_cycles,pad_lanes,rmse,mean_bias"]
    for t in range(args.tmin, args.tmax + 1):
        cycles = -(-t // M)
        pad = cycles * M - t
        # samples used: all lanes of slices 0..cycles-2, first t%M (or M)
        # lanes of the final slice
        s = signed_and[:, :cycles, :].copy()
        if pad:
            s[:, cycles - 1, M - pad:] = 0.0
        est = s.sum(axis=(1, 2)) / t
        err = est - exact
        rows.append(f"{t},{cycles},{pad},"
                    f"{np.sqrt(np.mean(err**2)):.6f},{np.mean(err):+.6f}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(rows) + "\n")
    print(f"wrote {args.out} ({args.blocks} blocks, K={K} M={M} W={W} "
          f"MAG={args.mag_width})")
    for line in rows[:1] + [r for r in rows[1:]
                            if int(r.split(",")[0]) % 8 == 0]:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
