#!/usr/bin/env python3
"""Check power_payn_array_ut.sv's drain bit-for-bit against the emulator model.

The reference is written from the scmp_kernels emulator's definitions (not from
the RTL's lane decomposition), for SC_MULT_SCHEME=ut on the deployed config:

  rB[d][s] = (sobol_k[s] XOR bitrev8(d mod 64)) >> 1      7-bit W threshold
  A bit    = s < kA                                       unary temporal
  kA       = the A operand (host-side UT), or from bA with the on-chip encoder:
             UT:    round(bA * T / 128)
             C-BSG: #{t < T : rA[d][t] < bA},
                    rA[d][t] = (sobol_q[t] XOR bitrev8(d mod 64)) >> 1
  W bit    = rB[d][s] < bB
  acc[h][v] += sum_k  sign * #{s < T : A bit and W bit}

Each BATCH is one K-block whose columns are d = d_base + k.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

SOBOL_K_DV = [128, 64, 32, 16, 72, 4, 82, 255]   # scmp "k" direction set, 8-bit
SOBOL_Q_DV = [128, 64, 32, 16, 8, 4, 2, 1]       # scmp "q" direction set (identity)
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
    if head[0] != "STREAMCFG_UT" or len(head) not in (9, 11):
        raise ValueError("missing STREAMCFG_UT K M NH NW WIDTH OWIDTH T NBATCHES [ENC CBSG]")
    k, m, nh, nw, width, owidth, t, nb = (int(v) for v in head[1:9])
    enc, cbsg = (int(head[9]), int(head[10])) if len(head) == 11 else (0, 0)
    batches, cur = [], 1
    for b in range(nb):
        if lines[cur][0] != "BATCH" or int(lines[cur][1]) != b:
            raise ValueError(f"missing or out-of-order BATCH {b}")
        d_base = int(lines[cur][2])
        rec = {"d_base": d_base}
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
    return (dict(K=k, M=m, NH=nh, NW=nw, OWIDTH=owidth, T=t, ENC=enc, CBSG=cbsg),
            batches, drain)


def reference(cfg: dict, batches: list[dict]) -> np.ndarray:
    T, K = cfg["T"], cfg["K"]
    words = sobol_words(SOBOL_K_DV)[:T]
    words_q = sobol_words(SOBOL_Q_DV)[:T]
    s = np.arange(T)
    acc = np.zeros((cfg["NH"], cfg["NW"]), dtype=np.int64)
    for rec in batches:
        for k in range(K):
            d = rec["d_base"] + k
            rB = (words ^ bitrev8(d % N_MASKS)) >> 1                 # (T,)
            a_op = rec["AMAG"][:, k]
            if not cfg["ENC"]:
                kA = a_op
            elif cfg["CBSG"]:
                rA = (words_q ^ bitrev8(d % N_MASKS)) >> 1
                kA = (rA[None, :] < a_op[:, None]).sum(axis=1)
            else:
                kA = (a_op * T + 64) // 128
            a_bits = s[None, :] < kA[:, None]                         # (NH, T)
            w_bits = rB[None, :] < rec["WMAG"][:, k][:, None]         # (NW, T)
            count = a_bits.astype(np.int64) @ w_bits.T.astype(np.int64)
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
    a_path = "host-UT" if not cfg["ENC"] else ("enc-CBSG" if cfg["CBSG"] else "enc-UT")
    shape = (f"K={cfg['K']} M={cfg['M']} N={cfg['NH']}x{cfg['NW']} "
             f"T={cfg['T']} batches={len(batches)} {a_path}")
    if np.array_equal(expected, drain):
        print(f"[PASS] UT streaming drain matches emulator reference ({shape})")
        return 0
    print(f"[FAIL] UT streaming drain mismatch ({shape})")
    print("RTL - expected:\n", drain - expected)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
