#!/usr/bin/env python3
"""Accuracy of PaYN's stochastic number generator (SNG) variants at equal T.

current      bit-exact to sc_kernel / RTL: per lane m a free-running 8-bit Sobol
             threshold XOR'd with an Owen mask per (k, m); one 8-bit comparator
             per (row/col, k, m).
strat_aXwY   lane-stratified SNG (designs/payn/variants/stratified_sng/): the
             top X (A) / Y (W) threshold bits are per-lane constants, so with
             X + Y = log2(M) the lanes tile the coarse grid once; lanes that
             differ only in A-stratum bits share one fine threshold taken from
             the top bits of an 8-bit Sobol lane.  Hardware: one shared
             (8-X)-bit compare per group plus one small gate per lane.
             strat_a2w2 matches ScPePeripheralStrat bit-for-bit
             (designs/payn/tb/test_pe_peripheral_strat.sv).
ham_*        (--ham) Hammersley-net thresholds with static, partly or fully
             per-block-randomized digital shifts; kept for reference.

Also reported: the RMSE of an *exact* dot product after rounding both 7-bit
magnitudes to n bits -- the binary precision each SC error corresponds to.

Metric matches sweeps/sc_tpad_accuracy.py: estimate of
sum_k s_k (a_k/256)(w_k/256) for one K-lane block; `acc` columns accumulate
the error over a depth-D dot product (D/K consecutive blocks into one output).
--repeat reuses one operand set for every block of an output (coherent-error
stress case).  Analysis: doc/SC_area_efficiency.md.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "designs/payn/cosim"))
from sc_kernel import ArrayCfg, owen_mask  # noqa: E402


def bitrev(x: np.ndarray, bits: int) -> np.ndarray:
    out = np.zeros_like(x)
    for b in range(bits):
        out |= ((x >> b) & 1) << (bits - 1 - b)
    return out


def current_counts(a, w, sgn, K, M, C, W, seed_offset=0):
    """(blocks,) signed AND counts with the RTL Sobol/Owen SNG, Sobol free-running."""
    blocks = a.shape[0]
    cfg = ArrayCfg(K=K, M=M, N_H=1, N_W=1, WIDTH=W, OWIDTH=24, T=C * M)
    ra, rw = cfg.make_rng_in(), cfg.make_rng_w()
    for _ in range(seed_offset):
        ra.step(); rw.step()
    n = blocks * C
    thr_a = np.stack([ra.step() for _ in range(n)]).reshape(blocks, C, M)
    thr_w = np.stack([rw.step() for _ in range(n)]).reshape(blocks, C, M)
    own_a = np.array([[owen_mask(d, m, 0, W) for m in range(M)] for d in range(K)])
    own_w = np.array([[owen_mask(d, m, 1 << (W - 1), W) for m in range(M)] for d in range(K)])
    ab = a[:, None, :, None] > (thr_a[:, :, None, :] ^ own_a[None, None])
    wb = w[:, None, :, None] > (thr_w[:, :, None, :] ^ own_w[None, None])
    lane = (ab & wb).sum(axis=(1, 3))                      # (blocks, K)
    return (sgn * lane).sum(axis=1)


def ham_counts(a, w, sgn, K, M, C, W, mode, rng):
    blocks = a.shape[0]
    T = C * M
    n = int(np.log2(T))
    c = int(np.log2(C))
    scale = (1 << W) // T                                   # threshold LSB step
    m = np.arange(M)
    t = np.arange(C)
    i = C * m[None, :] + t[:, None]                         # (C, M)
    u = i * scale                                           # 16m + t*16/C
    v = bitrev(i, n) * scale
    # Static per-k digital shift (both coordinates), then optional per-block
    # randomisation.
    mu = rng.integers(0, 1 << W, K)
    mv = rng.integers(0, 1 << W, K)
    U = np.broadcast_to(u, (blocks, K, C, M)) ^ mu[None, :, None, None]
    V = np.broadcast_to(v, (blocks, K, C, M)) ^ mv[None, :, None, None]
    if mode == "ham_lowrand":
        # Cheap bits only: A's sub-lane offset (below the 16-spacing) and W's
        # top rev_c(t) bits -- both are global XORs on the cycle index.
        lo_bits = 4
        hi_bits = max(c, 1)
        ra = rng.integers(0, 1 << lo_bits, (blocks, K))
        rv = rng.integers(0, 1 << hi_bits, (blocks, K)) << (W - hi_bits)
        U = U ^ ra[:, :, None, None]
        V = V ^ rv[:, :, None, None]
    elif mode == "ham_full":
        U = U ^ rng.integers(0, 1 << W, (blocks, K))[:, :, None, None]
        V = V ^ rng.integers(0, 1 << W, (blocks, K))[:, :, None, None]
    ab = a[:, :, None, None] > U
    wb = w[:, :, None, None] > V
    lane = (ab & wb).sum(axis=(2, 3))
    return (sgn * lane).sum(axis=1)


def strat_thresholds(K, M, n, ga, gw, W=8):
    """(n, K, M) A and W thresholds of the lane-stratified SNG.

    Lane m owns A stratum m >> (4-ga) and W stratum m & (2**gw - 1): the top
    ga (gw) threshold bits are fixed per lane.  Lanes that differ only in their
    A-stratum bits share one free-running Sobol fine value of width 8-ga, so a
    row/k needs one (8-ga)-bit compare per group plus one small gate per lane.
    Per-(k, group) Owen masks permute strata and digitally shift fine bits, as
    the RTL masks do today.
    """
    from sc_kernel import SobolRNG
    lanes = np.arange(M)
    lb = int(np.log2(M))

    def side(g, stratum, group, dv8, base, stride, salt):
        # Fine bits are the top 8-g bits of an ordinary 8-bit Sobol lane (same
        # direction table as today).  A (8-g)-bit generator would repeat every
        # 2**(8-g) clocks and re-pair the same A/W fine samples, which adds up
        # coherently over a long reduction; the 8-bit lane keeps a 256-clock
        # period exactly like the current SNG.
        fw = W - g
        n_groups = int(group.max()) + 1
        seq = np.empty((n, n_groups), dtype=np.int64)
        for gi in range(n_groups):
            r = SobolRNG(W, (base ^ (stride * gi)) & 0xFF, dv=list(dv8))
            seq[:, gi] = [r.step() for _ in range(n)]
        # Fine bits: digital shift per (k, group).  Stratum bits: one XOR per k
        # for every lane, so the lane -> coarse-cell map stays a bijection
        # (a per-group stratum XOR can double-book cells and bias the count).
        own = np.array([[owen_mask(k, gi, salt, W) for gi in range(n_groups)]
                        for k in range(K)])                      # (K, groups)
        smask = np.array([owen_mask(k, 0, salt, W) >> fw for k in range(K)])
        fine = (seq[:, None, group] ^ own[None][:, :, group]) >> g
        return ((stratum[None, None, :] ^ smask[None, :, None]) << fw) | fine

    dv_a = [1 << (W - 1 - j) for j in range(W)]
    dv_w = [128, 64, 32, 16, 72, 4, 82, 255]
    a_str = lanes >> (lb - ga) if ga else np.zeros(M, dtype=np.int64)
    a_grp = lanes & ((1 << (lb - ga)) - 1)
    w_str = lanes & ((1 << gw) - 1)
    w_grp = lanes >> gw
    ta = side(ga, a_str, a_grp, dv_a, 0x17, 0x53, 0)
    tw = side(gw, w_str, w_grp, dv_w, 0x9D, 0x2B, 1 << (W - 1))
    return ta, tw


def strat_counts(a, w, sgn, K, M, C, ga, gw, W=8):
    blocks = a.shape[0]
    ta, tw = strat_thresholds(K, M, blocks * C, ga, gw, W)
    ta = ta.reshape(blocks, C, K, M)
    tw = tw.reshape(blocks, C, K, M)
    ab = a[:, None, :, None] > ta
    wb = w[:, None, :, None] > tw
    lane = (ab & wb).sum(axis=(1, 3))
    return (sgn * lane).sum(axis=1)


def quantized_dot(a, w, sgn, bits, W):
    """Exact dot product after rounding 7-bit magnitudes to `bits` bits."""
    step = (1 << (W - 1)) // ((1 << bits) - 1) if bits < W - 1 else None
    if bits >= W - 1:
        qa, qw = a, w
    else:
        full = (1 << W) - 2                                  # 254 = top 7-bit code
        levels = (1 << bits) - 1
        qa = np.round(a / full * levels) / levels * full
        qw = np.round(w / full * levels) / levels * full
    del step
    L = float(1 << W)
    return (sgn * (qa / L) * (qw / L)).sum(axis=1)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--blocks", type=int, default=4096)
    p.add_argument("--K", type=int, default=8)
    p.add_argument("--M", type=int, default=16)
    p.add_argument("--depth", type=int, default=256,
                   help="dot-product depth D for the accumulated-error column")
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--repeat", action="store_true",
                   help="stress case: every block of one output reuses the same "
                        "operands, so deterministic per-block errors add coherently")
    p.add_argument("--ham", action="store_true",
                   help="also report the Hammersley-net SNG variants")
    p.add_argument("--csv", type=Path)
    args = p.parse_args()

    K, M, W = args.K, args.M, 8
    L = float(1 << W)
    rng = np.random.default_rng(args.seed)
    blocks = args.blocks
    per_out = args.depth // K                                # blocks per output
    n_out = blocks // per_out
    a = (rng.integers(0, 128, (blocks, K)) << 1).astype(np.int64)
    w = (rng.integers(0, 128, (blocks, K)) << 1).astype(np.int64)
    sgn = np.where(rng.integers(0, 2, (blocks, K)) ^ rng.integers(0, 2, (blocks, K)), -1, 1)
    if args.repeat:
        idx = np.repeat(np.arange(n_out) * per_out, per_out)
        idx = np.concatenate([idx, np.arange(n_out * per_out, blocks)])
        a, w, sgn = a[idx], w[idx], sgn[idx]
    exact = (sgn * (a / L) * (w / L)).sum(axis=1)

    def stats(est):
        err = est - exact
        acc = err[: n_out * per_out].reshape(n_out, per_out).sum(axis=1)
        return np.sqrt(np.mean(err ** 2)), np.mean(err), np.sqrt(np.mean(acc ** 2))

    rows = []
    print(f"K={K} M={M} blocks={blocks} depth D={args.depth} ({per_out} blocks/output)"
          f"{' repeated-operand stress' if args.repeat else ''}")
    print(f"{'scheme':<14}{'T':>5}{'block_rmse':>12}{'bias':>11}{'acc_rmse(D)':>13}")
    for C in (1, 2, 4, 8):
        T = C * M
        res = {"current": current_counts(a, w, sgn, K, M, C, W)}
        for ga, gw in ((1, 0), (1, 1), (2, 2)):
            res[f"strat_a{ga}w{gw}"] = strat_counts(a, w, sgn, K, M, C, ga, gw, W)
        if args.ham:
            for mode in ("ham_fixed", "ham_lowrand", "ham_full"):
                res[mode] = ham_counts(a, w, sgn, K, M, C, W, mode,
                                       np.random.default_rng(args.seed + 100 + C))
        for name, cnt in res.items():
            r, b, ar = stats(cnt / T)
            rows.append((name, T, r, b, ar))
            print(f"{name:<14}{T:>5}{r:>12.5f}{b:>+11.5f}{ar:>13.4f}")
    for bits in (3, 4, 5, 6, 7):
        r, b, ar = stats(quantized_dot(a, w, sgn, bits, W))
        rows.append((f"binary_{bits}b_mag", 0, r, b, ar))
        print(f"{'binary '+str(bits)+'b mag':<14}{'-':>5}{r:>12.5f}{b:>+11.5f}{ar:>13.4f}")

    if args.csv:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with open(args.csv, "w") as f:
            f.write("scheme,T,block_rmse,bias,acc_rmse\n")
            for r in rows:
                f.write(",".join(str(x) for x in r) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
