#!/usr/bin/env python3
"""Stochastic-stream activity under alternative Sobol traversal orders.

A T/M-clock block holds its binary magnitudes and signs fixed, and the output-
stationary accumulator only sees the *sum* of that block's per-clock
contributions.  Permuting the clock order of the (A threshold, W threshold)
pairs inside a block therefore leaves every drained output bit-exact, while
changing how often the comparator outputs -- and everything downstream of them
-- toggle.

With identity-like leading direction vectors (A and W both start
0x80, 0x40, 0x20), one 8-clock block traverses a coset of span{v0, v1, v2}.
The stock Gray order flips v0 (the threshold MSB) on every other clock.  The
reversed-priority order flips v2 most often and v0 once per block, so the
threshold moves by 32 most clocks instead of 128.  For uniform magnitudes the
expected comparator crossings per block fall from 672/256 to 384/256.

Schemes modelled (all on the same operand trace):

  baseline  stock generator, current bench alignment (first used value is the
            one after the first update), so a block straddles two cosets
  aligned   stock generator, count reset to all-ones so the first update holds
            and each block is one full coset (bit-exact control for `reversed`)
  reversed  aligned, plus reversed direction priority for the low REV_BITS
            count bits

  net       structured SNG from sweeps/sng_accuracy_compare.py (`ham_full`):
            Hammersley thresholds A u = 16m + 2t, W v = 32 rev3(t) + 2 rev4(m),
            each XOR'd with a fresh random 8-bit mask per (block, k); the cycle
            index t walks rev3 of a reflected Gray code so W's high field moves
            one bit at a time.  Different arithmetic: not part of the exactness
            check.

The script asserts `reversed` drains bit-identically to `aligned`, then reports
per-net toggle rates at every stage of the tile cone.  This is an activity
model, not a power measurement.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "designs/payn/cosim"))
from sc_kernel import DV_K_WIDTH8, owen_mask  # noqa: E402


@dataclass(frozen=True)
class Scheme:
    name: str
    rev_bits: int
    count_init_all_ones: bool


SCHEMES = (
    Scheme("baseline", 0, False),
    Scheme("aligned", 0, True),
    Scheme("reversed", 3, True),
    Scheme("net", 0, True),
)


def sobol_values(width: int, shift: int, dv: list[int], n: int,
                 rev_bits: int, count_init_all_ones: bool) -> np.ndarray:
    """Values seen by the comparator on clocks 1..n after rng_en (sobol.sv)."""
    mask = (1 << width) - 1
    count = mask if count_init_all_ones else 0
    value = shift & mask
    out = np.empty(n, dtype=np.int64)
    for t in range(n):
        j = 0
        while j < width and (count >> j) & 1:
            j += 1
        if j < width:
            k = rev_bits - 1 - j if j < rev_bits else j
            value ^= dv[k]
        count = (count + 1) & mask
        out[t] = value
    return out


def thresholds(scheme: Scheme, width: int, m_lanes: int, n: int,
               base: int, stride: int, dv: list[int]) -> np.ndarray:
    mask = (1 << width) - 1
    cols = [
        sobol_values(width, base ^ ((stride * m) & mask), dv, n,
                     scheme.rev_bits, scheme.count_init_all_ones)
        for m in range(m_lanes)
    ]
    return np.stack(cols, axis=1)  # (n, M)


def bitrev(x: np.ndarray, bits: int) -> np.ndarray:
    out = np.zeros_like(x)
    for b in range(bits):
        out |= ((x >> b) & 1) << (bits - 1 - b)
    return out


def net_thresholds(n_cycles: int, mac_cycles: int, K: int, M: int,
                   rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """(t, k, m) A and W thresholds of the per-block-shifted Hammersley SNG."""
    assert mac_cycles == 8 and M == 16, "modelled for T=128, M=16"
    i = np.arange(mac_cycles)
    order = bitrev(i ^ (i >> 1), 3)                 # t sequence within a block
    m = np.arange(M)
    t = order[np.arange(n_cycles) % mac_cycles]
    u = 16 * m[None, :] + 2 * t[:, None]
    v = 32 * bitrev(t, 3)[:, None] + 2 * bitrev(m, 4)[None, :]
    n_blocks = n_cycles // mac_cycles
    sa = np.repeat(rng.integers(0, 256, (n_blocks, K)), mac_cycles, axis=0)
    sw = np.repeat(rng.integers(0, 256, (n_blocks, K)), mac_cycles, axis=0)
    return u[:, None, :] ^ sa[:, :, None], v[:, None, :] ^ sw[:, :, None]


def toggles(x: np.ndarray, bits: int | None = None) -> float:
    """Mean transitions per net per clock along axis 0."""
    d = x[1:] ^ x[:-1]
    if bits is None:
        return float(d.mean())
    total = sum(((d >> b) & 1).sum() for b in range(bits))
    return float(total) / (d.size * bits)


def run(args: argparse.Namespace) -> int:
    K, M, NH, NW, WIDTH = args.K, args.M, args.N, args.N, 8
    mac_cycles = args.T // M
    n_cycles = args.batches * mac_cycles
    rng = np.random.default_rng(args.seed)

    # Bench distribution: 7-bit uniform magnitude encoded as m << 1, random sign.
    a_mag = (rng.integers(0, 128, (args.batches, NH, K)) << 1).astype(np.int64)
    w_mag = (rng.integers(0, 128, (args.batches, NW, K)) << 1).astype(np.int64)
    a_sgn = rng.integers(0, 2, (args.batches, NH, K)).astype(np.int8)
    w_sgn = rng.integers(0, 2, (args.batches, NW, K)).astype(np.int8)
    batch_of = np.arange(n_cycles) // mac_cycles

    own_a = np.array([[owen_mask(d, m, 0, WIDTH) for m in range(M)] for d in range(K)])
    own_w = np.array([[owen_mask(d, m, 1 << (WIDTH - 1), WIDTH) for m in range(M)]
                      for d in range(K)])
    dv_a = [1 << (WIDTH - 1 - j) for j in range(WIDTH)]
    dv_w = list(DV_K_WIDTH8[:WIDTH])

    results = {}
    drains = {}
    for s in SCHEMES:
        if s.name == "net":
            ta, tw = net_thresholds(n_cycles, mac_cycles, K, M,
                                    np.random.default_rng(args.seed + 1))
            a_bits = (a_mag[batch_of][:, :, :, None] > ta[:, None]).astype(np.uint8)
            w_bits = (w_mag[batch_of][:, :, :, None] > tw[:, None]).astype(np.uint8)
        else:
            thr_a = thresholds(s, WIDTH, M, n_cycles, 0x17, 0x53, dv_a)
            thr_w = thresholds(s, WIDTH, M, n_cycles, 0x9D, 0x2B, dv_w)
            # (t, row, k, m) comparator outputs == pipe D/Q == broadcast nets
            a_bits = (a_mag[batch_of][:, :, :, None] >
                      (thr_a[:, None, None, :] ^ own_a[None, None])).astype(np.uint8)
            w_bits = (w_mag[batch_of][:, :, :, None] >
                      (thr_w[:, None, None, :] ^ own_w[None, None])).astype(np.uint8)
        # (t, h, v, k, m) tile AND outputs
        prod = a_bits[:, :, None] & w_bits[:, None, :]
        count = prod.sum(axis=4, dtype=np.int64)                      # (t,h,v,k)
        neg = (a_sgn[batch_of][:, :, None, :] ^ w_sgn[batch_of][:, None, :, :])
        term = np.where(neg == 1, -count, count)                       # signed lane term
        d = term.sum(axis=3)                                            # (t,h,v)
        acc = np.cumsum(d, axis=0)
        drains[s.name] = acc[-1]

        low_w = 9
        r = {
            "a_bits": toggles(a_bits),
            "w_bits": toggles(w_bits),
            "product": toggles(prod),
            "lane_count(5b)": toggles(count, 5),
            "lane_term(6b)": toggles(term & 0x3F, 6),
            "tile_delta(9b)": toggles(d & 0x1FF, 9),
            "acc_low(9b)": toggles(acc & ((1 << low_w) - 1), low_w),
        }
        results[s.name] = r

    exact = np.array_equal(drains["aligned"], drains["reversed"])
    print(f"K={K} M={M} N={NH}x{NW} T={args.T} batches={args.batches} "
          f"clocks={n_cycles} seed={args.seed}")
    print(f"reversed vs aligned final accumulators bit-identical: {exact}")
    diff = drains["baseline"] - drains["aligned"]
    print(f"baseline vs aligned final accumulators differ in "
          f"{int((diff != 0).sum())}/{diff.size} outputs "
          f"(expected: different 8-clock threshold sets)")

    names = list(results["baseline"])
    hdr = f"{'net (toggles/net/clock)':<24}" + "".join(f"{s.name:>11}" for s in SCHEMES)
    hdr += f"{'rev/base':>10}{'net/base':>10}"
    print(hdr)
    for n in names:
        row = f"{n:<24}" + "".join(f"{results[s.name][n]:>11.4f}" for s in SCHEMES)
        row += f"{results['reversed'][n] / results['baseline'][n]:>10.3f}"
        row += f"{results['net'][n] / results['baseline'][n]:>10.3f}"
        print(row)

    if args.csv:
        with open(args.csv, "w") as f:
            f.write("net," + ",".join(s.name for s in SCHEMES) + "\n")
            for n in names:
                f.write(n + "," + ",".join(f"{results[s.name][n]:.6f}" for s in SCHEMES) + "\n")
    return 0 if exact else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--K", type=int, default=8)
    p.add_argument("--M", type=int, default=16)
    p.add_argument("--N", type=int, default=8)
    p.add_argument("--T", type=int, default=128)
    p.add_argument("--batches", type=int, default=384)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--csv", type=Path)
    return run(p.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
