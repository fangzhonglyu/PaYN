#!/usr/bin/env python3
"""Operand files for the INT-mode benches of payn_array (bit-plane and all-bits-in-time schedules).

INT mode multiplies an MROWS x L activation matrix A (BA-bit two's complement) by an L x NCOLS weight matrix W
(BW-bit) on the PE array with the AF streams silent.  Every INT bench reads the same two operand files; what
differs per schedule is the precision range, the row granularity and the metadata:

  bp      bit-plane schedule (functional, grid and power benches): tile row h holds bit h % BA of activation row
          h // BA, so a PE takes ROWS_PE = 8 // BA rows and MROWS must be a multiple of it.  BA, BW in {4, 8}.
  abit    all-bits-in-time schedule (functional, grid and power benches): one activation row per tile row, MROWS a
          multiple of --row-unit (default 8; 8 // BA when the same operands also feed bit-plane controls).
          BA, BW in 2..8.  The meta adds the worst-case |output| and whether it fits the 24-bit tile.
  energy  the INT energy operands: plain draws (no forced extremes) as intb_* files whose meta carries per-plane
          one-densities and data-cycle toggle rates (the energy driver copies the hex files to bpt_*.hex).

Files written to OUT_DIR (prefix bpt for bp / abit, intb for energy):
  <prefix>_a.hex      A[i, x] row-major, MROWS x L, one two's-complement byte per line
  <prefix>_w.hex      W[x, j] column-major (entry j*L + x), NCOLS x L bytes
  <prefix>_meta.json  shape, precision, distribution, seed, operand statistics (also printed on stdout)
Values are stored sign-extended to 8 bits, so bit p of the byte is bit p of the B-bit encoding for p < B.

Data-cycle shape (--shape): K lanes x M positions carry K*M = 128 reduction elements per data cycle; lane k,
position m of data cycle b is element x = 128*b + M*k + m, packed by the bench on the raw ports as bit
(h*K + k)*M + m (activation tile row h) and (v*K + k)*M + m (weight tile column v), i.e. bit 128*h + x % 128 for
either shape.  The files are in reduction order x, so they are identical for k8m16 (default) and k16m8; a
non-default shape is recorded in the meta.

Distributions (lo / hi = the signed range ends, e.g. -128 / 127 or -32 / 31):
  uniform      every value equiprobable; bp / abit force lo and hi into a few reduction positions of every row
               and column (min x min, min x max, max x max, max x min always occur), energy does not
  allmin       A = lo, W = lo        (largest positive product)
  allmax       A = hi, W = hi
  minxmax      A = lo, W = hi        (largest negative product)
  maxxmin      A = hi, W = lo
  neg1xmin     A = -1, W = lo        (every activation plane is 1)
  alternating  A[i, x] = lo / hi alternating along x (phase i), W[x, j] = hi / lo alternating along x (phase j):
               every plane toggles every element
  gauss        round(N(0, sigma)), sigma = 2^(B-1) / 4, clipped to the signed range (DNN-like), both operands
  relu         activations max(0, round(N(0, sigma))) clipped to [0, hi] (post-ReLU), weights as gauss
  plain        (abit) exactly the energy operands of --plain-dist (same seed and shape, same bytes)

Usage:
  int_workload.py bp     --ba 8 --bw 8 --L 1024 --mrows 2 --ncols 16 --dist uniform --seed 3 --out-dir DIR
  int_workload.py abit   --ba 6 --bw 6 --L 1024 --mrows 8 --ncols 16 --dist uniform --seed 1 --out-dir DIR
  int_workload.py abit   --ba 8 --bw 8 --L 384 --mrows 16 --ncols 64 --dist plain --plain-dist uniform \\
                         --row-unit 1 --seed 1 --out-dir DIR
  int_workload.py energy --ba 8 --bw 8 --L 1024 --mrows 6 --ncols 64 --dist uniform --seed 1 --out-dir DIR
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OWIDTH = 24                                         # tile accumulator width (signed)
SHAPES = {"k8m16": (8, 16), "k16m8": (16, 8)}       # data-cycle shape: K lanes x M positions
CONST = {"allmin": ("lo", "lo"), "allmax": ("hi", "hi"), "minxmax": ("lo", "hi"), "maxxmin": ("hi", "lo"),
         "neg1xmin": (-1, "lo")}
DISTS = ("uniform", *CONST, "alternating", "gauss", "relu")
PLAIN = ("uniform", "gauss", "relu")


def signed_range(bits: int) -> tuple[int, int]:
    return -(1 << (bits - 1)), (1 << (bits - 1)) - 1


def elements_per_cycle(shape: str) -> int:
    k, m = SHAPES[shape]
    return k * m


def draw(rng: np.random.Generator, bits: int, dist: str, shape) -> np.ndarray:
    """uniform over the signed range, gauss, or relu (see the module docstring)."""
    lo, hi = signed_range(bits)
    if dist == "uniform":
        return rng.integers(lo, hi + 1, size=shape, dtype=np.int64)
    sigma = (1 << (bits - 1)) / 4.0
    return np.clip(np.rint(rng.normal(0.0, sigma, size=shape)), 0 if dist == "relu" else lo, hi).astype(np.int64)


def plain_operands(rng, ba, bw, mrows, ncols, L, dist):
    """A, then W, without forced extremes (post-ReLU activations take Gaussian weights)."""
    return draw(rng, ba, dist, (mrows, L)), draw(rng, bw, "gauss" if dist == "relu" else dist, (L, ncols))


def operands(dist, ba, bw, mrows, ncols, L, rng, plain_dist="uniform"):
    """(A, W) as int64 arrays of shape (MROWS, L) and (L, NCOLS)."""
    (alo, ahi), (wlo, whi) = signed_range(ba), signed_range(bw)
    if dist in ("plain", "gauss", "relu"):
        return plain_operands(rng, ba, bw, mrows, ncols, L, plain_dist if dist == "plain" else dist)
    if dist == "uniform":
        A, W = plain_operands(rng, ba, bw, mrows, ncols, L, "uniform")
        A[:, 0], W[0, :] = alo, wlo          # min x min
        A[:, 1], W[1, :] = alo, whi          # min x max
        A[:, 2], W[2, :] = ahi, whi          # max x max
        A[:, -1], W[-1, :] = ahi, wlo        # max x min (last element of the last data cycle)
        for row in A:
            row[rng.choice(L, size=max(1, L // 32), replace=False)] = alo
        for col in W.T:
            col[rng.choice(L, size=max(1, L // 32), replace=False)] = wlo
        return A, W
    if dist in CONST:
        a, w = CONST[dist]
        a = {"lo": alo, "hi": ahi}.get(a, a)
        w = {"lo": wlo, "hi": whi}.get(w, w)
        return np.full((mrows, L), a, np.int64), np.full((L, ncols), w, np.int64)
    x = np.arange(L)                         # alternating
    A = np.where((x[None, :] + np.arange(mrows)[:, None]) % 2 == 0, alo, ahi).astype(np.int64)
    W = np.where((x[:, None] + np.arange(ncols)[None, :]) % 2 == 0, whi, wlo).astype(np.int64)
    return A, W


def write_hex(path: Path, values: np.ndarray) -> None:
    path.write_text("\n".join(f"{v & 0xFF:02x}" for v in values.reshape(-1)) + "\n")


def read_hex(path: Path, n: int) -> np.ndarray:
    vals = [int(x, 16) for x in path.read_text().split()]
    if len(vals) != n:
        raise SystemExit(f"{path}: {len(vals)} entries, expected {n}")
    v = np.array(vals, dtype=np.int64)
    return np.where(v >= 128, v - 256, v)


def read_operands(run_dir: Path, ba: int, bw: int, mrows: int, ncols: int, L: int):
    """bpt_a.hex / bpt_w.hex of a run directory as (A (MROWS, L), W (L, NCOLS)), range-checked."""
    A = read_hex(run_dir / "bpt_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(run_dir / "bpt_w.hex", ncols * L).reshape(ncols, L).T
    (alo, ahi), (wlo, whi) = signed_range(ba), signed_range(bw)
    if A.min() < alo or A.max() > ahi or W.min() < wlo or W.max() > whi:
        raise SystemExit("operands outside the declared precision")
    return A, W


def plane_density(x: np.ndarray, bits: int) -> list[float]:
    u = x & ((1 << bits) - 1)
    return [float(((u >> p) & 1).mean()) for p in range(bits)]


def toggle_rate(x2d: np.ndarray, bits: int, dc: int) -> list[float]:
    """Per plane, the fraction of (row, wire) pairs whose bit differs between consecutive data cycles: the bench
    streams element x and x + dc over the same wire."""
    u = x2d & ((1 << bits) - 1)
    out = []
    for p in range(bits):
        b = (u >> p) & 1
        nb = b.shape[-1] // dc
        b = b[..., : nb * dc].reshape(*b.shape[:-1], nb, dc)
        out.append(float((b[..., 1:, :] != b[..., :-1, :]).mean()) if nb > 1 else float("nan"))
    return out


def metadata(args, A: np.ndarray, W: np.ndarray, dc: int) -> dict:
    meta = dict(ba=args.ba, bw=args.bw, L=args.L, mrows=args.mrows, ncols=args.ncols, dist=args.dist)
    if args.schedule == "abit":
        meta["plain_dist"] = args.plain_dist if args.dist == "plain" else None
    meta["seed"] = args.seed
    if args.schedule == "energy":
        meta.update(a_mean=float(A.mean()), a_std=float(A.std()), w_mean=float(W.mean()), w_std=float(W.std()),
                    a_plane_density=plane_density(A, args.ba), w_plane_density=plane_density(W, args.bw),
                    a_plane_toggle_rate=toggle_rate(A, args.ba, dc), w_plane_toggle_rate=toggle_rate(W.T, args.bw, dc))
    else:
        gemm = A @ W
        meta.update(a_min=int(A.min()), a_max=int(A.max()), w_min=int(W.min()), w_max=int(W.max()),
                    gemm_min=int(gemm.min()), gemm_max=int(gemm.max()))
    if args.schedule == "abit":
        worst = args.L * (1 << (args.ba + args.bw - 2))
        meta.update(worst_case_abs=worst, worst_case_fits_tile=worst <= (1 << (OWIDTH - 1)) - 1)
    if args.shape != "k8m16":
        meta["shape"] = args.shape
    return meta


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="schedule", required=True)
    for name, bits, dists, what in (
            ("bp", (4, 8), DISTS, "bit-plane benches (bpt_*)"),
            ("abit", range(2, 9), DISTS + ("plain",), "all-bits-in-time benches (bpt_*)"),
            ("energy", (4, 8), PLAIN, "INT energy operands (intb_*)")):
        p = sub.add_parser(name, help=what)
        p.add_argument("--ba", type=int, required=True, choices=bits)
        p.add_argument("--bw", type=int, required=True, choices=bits)
        p.add_argument("--L", type=int, required=True)
        p.add_argument("--mrows", type=int, required=True)
        p.add_argument("--ncols", type=int, required=True)
        p.add_argument("--dist", required=True, choices=dists)
        p.add_argument("--seed", type=int, default=1)
        p.add_argument("--shape", default="k8m16", choices=SHAPES, help="data-cycle shape K x M (default k8m16)")
        p.add_argument("--out-dir", type=Path, required=True)
        if name == "abit":
            p.add_argument("--plain-dist", default="uniform", choices=PLAIN)
            p.add_argument("--row-unit", type=int, default=8,
                           help="MROWS must be a multiple of this (8: one activation row per tile row; "
                                "8 // BA for bit-plane controls on the same operands)")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    dc = elements_per_cycle(args.shape)
    unit = args.row_unit if args.schedule == "abit" else 8 // args.ba
    if args.L < dc or args.L % dc:
        raise SystemExit(f"L must be a positive multiple of {dc}")
    if args.mrows < unit or args.mrows % unit or args.ncols < 8 or args.ncols % 8:
        raise SystemExit(f"MROWS must be a multiple of {unit} and NCOLS of 8")
    rng = np.random.default_rng(args.seed)
    if args.schedule == "energy":
        A, W = plain_operands(rng, args.ba, args.bw, args.mrows, args.ncols, args.L, args.dist)
    else:
        A, W = operands(args.dist, args.ba, args.bw, args.mrows, args.ncols, args.L, rng,
                        getattr(args, "plain_dist", "uniform"))
    prefix = "intb" if args.schedule == "energy" else "bpt"
    meta = metadata(args, A, W, dc)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_hex(args.out_dir / f"{prefix}_a.hex", A)
    write_hex(args.out_dir / f"{prefix}_w.hex", W.T)
    (args.out_dir / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
