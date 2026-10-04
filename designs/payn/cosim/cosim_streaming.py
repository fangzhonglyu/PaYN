#!/usr/bin/env python3
"""Check power_payn_array.sv's drain bit-for-bit against the emulator's C-BSG.

The reference is written from the scmp_kernels emulator's definitions (not from
the RTL), for SC_MULT_SCHEME=cbsg on the deployed config:

  rA[d][t] = (sobol_q[t] XOR bitrev8(d mod 64)) >> 1      A thresholds
  rB[d][t] = (sobol_k[t] XOR bitrev8(d mod 64)) >> 1      W thresholds
  kA       = #{t < T : rA[d][t] < bA}                     ones in A's stream
  count    = #{i < kA : rB[d][i] < bB}                    W gated by A
  acc[h][v] += sum_k  sign * count

Each BATCH is one K-block whose columns are d = d_base + k.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

SOBOL_Q_DV = [128, 64, 32, 16, 8, 4, 2, 1]       # scmp "q" direction set (A)
SOBOL_K_DV = [128, 64, 32, 16, 72, 4, 82, 255]   # scmp "k" direction set (W)
N_MASKS = 64


def sobol_words(dv: list[int], n: int = 256) -> np.ndarray:
    """Gray-code Sobol: x[0] = 0, x[t+1] = x[t] ^ dv[lsz(t)]."""
    x, out = 0, []
    for t in range(n):
        out.append(x)
        c = 0
        while (t >> c) & 1:
            c += 1
        if c < len(dv):
            x ^= dv[c]
    return np.array(out, dtype=np.int64)


def bitrev8(x: int) -> int:
    return int(f"{x:08b}"[::-1], 2)


def parse(path: Path):
    lines = [ln.split() for ln in path.read_text().splitlines() if ln.split()]
    head = lines[0]
    if head[0] != "STREAMCFG" or len(head) != 9:
        raise ValueError("missing STREAMCFG K M NH NW WIDTH OWIDTH T NBATCHES")
    k, m, nh, nw, width, owidth, t, nb = (int(v) for v in head[1:9])
    batches, cur = [], 1
    for b in range(nb):
        if lines[cur][0] != "BATCH" or int(lines[cur][1]) != b:
            raise ValueError(f"missing or out-of-order BATCH {b}")
        rec = {"d_base": int(lines[cur][2])}
        for i, (tag, rows) in enumerate((("AMAG", nh), ("ASIGN", nh),
                                         ("WMAG", nw), ("WSIGN", nw))):
            row = lines[cur + 1 + i]
            if row[0] != tag:
                raise ValueError(f"batch {b}: expected {tag}")
            rec[tag] = np.array(row[1:], dtype=np.int64).reshape(rows, k)
        batches.append(rec)
        cur += 5
    if lines[cur][0] != "DRAIN":
        raise ValueError("missing DRAIN")
    drain = np.array(lines[cur][1:], dtype=np.int64).reshape(nh, nw)
    return dict(K=k, M=m, NH=nh, NW=nw, OWIDTH=owidth, T=t), batches, drain


def reference(cfg: dict, batches: list[dict]) -> np.ndarray:
    T, K = cfg["T"], cfg["K"]
    words_q = sobol_words(SOBOL_Q_DV)[:T]
    words_k = sobol_words(SOBOL_K_DV)[:T]
    acc = np.zeros((cfg["NH"], cfg["NW"]), dtype=np.int64)
    for rec in batches:
        for k in range(K):
            mask = bitrev8((rec["d_base"] + k) % N_MASKS)
            rA = (words_q ^ mask) >> 1
            rB = (words_k ^ mask) >> 1
            kA = (rA[None, :] < rec["AMAG"][:, k][:, None]).sum(axis=1)         # (NH,)
            w_hits = rB[None, :] < rec["WMAG"][:, k][:, None]                  # (NW, T)
            cum = np.concatenate([np.zeros((w_hits.shape[0], 1), np.int64),
                                  w_hits.cumsum(axis=1)], axis=1)              # (NW, T+1)
            count = cum[:, kA].T                                               # (NH, NW)
            sign = np.where(rec["ASIGN"][:, k][:, None] == rec["WSIGN"][:, k][None, :], 1, -1)
            acc += sign * count
    mask = (1 << cfg["OWIDTH"]) - 1
    wrapped = acc & mask
    return np.where(wrapped >> (cfg["OWIDTH"] - 1), wrapped - (1 << cfg["OWIDTH"]), wrapped)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", type=Path)
    args = ap.parse_args()
    cfg, batches, drain = parse(args.trace)
    expected = reference(cfg, batches)
    shape = (f"K={cfg['K']} M={cfg['M']} N={cfg['NH']}x{cfg['NW']} "
             f"T={cfg['T']} batches={len(batches)}")
    if np.array_equal(expected, drain):
        print(f"[PASS] streaming drain matches emulator C-BSG ({shape})")
        return 0
    print(f"[FAIL] streaming drain mismatch ({shape})")
    print("RTL - expected:\n", drain - expected)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
