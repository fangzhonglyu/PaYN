"""Generate GEMM stimulus for the RTL TB + numpy expected outputs.

Emits:
  stim.hex        — per-K-tile packed operands (hex integers, one field per line)
  expected.txt    — numpy sc_kernel's expected drain outputs, one per line
  meta.txt        — GEMM dims + array cfg for the TB to read

Layout of stim.hex (line-oriented, decimal integers unless noted):
    <M_g> <N_g> <K_g> <K> <M> <N_H> <N_W> <WIDTH> <T>
    <n_spatial_tiles> <n_k_blocks_per_tile>
    Then for each spatial tile s in 0..n_spatial-1:
        For each K-block k in 0..n_k-1:
            ifm_mag  packed hex, one line, LSB = mag[n=0,d=0]
            ifm_sign packed hex, one line
            wght_mag packed hex, one line
            wght_sign packed hex, one line

Spatial-tile iteration order matches sc_kernel.matmul: outer rt in 0..M_g/N_H,
inner ct in 0..N_g/N_W.
"""
from __future__ import annotations

import argparse
import os
import numpy as np

from sc_kernel import ArrayCfg, matmul, compute_spatial_tile


def _pack_mag(mag_NK: np.ndarray, WIDTH: int) -> int:
    """(N, K) magnitudes -> single packed int, LSB = mag[0, 0]."""
    N, K = mag_NK.shape
    out = 0
    for n in range(N):
        for d in range(K):
            v = int(mag_NK[n, d]) & ((1 << WIDTH) - 1)
            out |= v << ((n*K + d) * WIDTH)
    return out


def _pack_sign(sign_NK: np.ndarray) -> int:
    N, K = sign_NK.shape
    out = 0
    for n in range(N):
        for d in range(K):
            out |= (int(sign_NK[n, d]) & 1) << (n*K + d)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--M", type=int, default=4)
    ap.add_argument("--N", type=int, default=4)
    ap.add_argument("--K", type=int, default=16)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--outdir", type=str, default=".")
    ap.add_argument("--encoding", type=int, default=1,
                    help="1=inner_tile_2bit (exact), 3=inner_tile_2bit_apc (APC)")
    args = ap.parse_args()

    cfg = ArrayCfg(ENCODING=args.encoding)  # K=4 M=4 N_H=2 N_W=2 WIDTH=8 T=32
    q_max = (1 << (cfg.WIDTH - 1)) - 1
    rs = np.random.RandomState(args.seed)

    M_g, N_g, K_g = args.M, args.N, args.K
    assert M_g % cfg.N_H == 0 and N_g % cfg.N_W == 0 and K_g % cfg.K == 0

    A_signed = rs.randint(-q_max, q_max+1, (M_g, K_g)).astype(np.int32)
    B_signed = rs.randint(-q_max, q_max+1, (N_g, K_g)).astype(np.int32)
    A = np.abs(A_signed).astype(np.uint32)
    sA = (A_signed < 0).astype(np.uint8)
    B = np.abs(B_signed).astype(np.uint32)
    sB = (B_signed < 0).astype(np.uint8)

    y_ref = matmul(A, sA, B, sB, cfg)

    n_rt = M_g // cfg.N_H
    n_ct = N_g // cfg.N_W
    n_spatial = n_rt * n_ct
    n_k_blocks = K_g // cfg.K

    os.makedirs(args.outdir, exist_ok=True)

    stim_path = os.path.join(args.outdir, "stim.hex")
    exp_path = os.path.join(args.outdir, "expected.txt")
    meta_path = os.path.join(args.outdir, "meta.txt")

    with open(meta_path, "w") as f:
        f.write(f"M_g {M_g}\nN_g {N_g}\nK_g {K_g}\n")
        f.write(f"K {cfg.K}\nM {cfg.M}\nN_H {cfg.N_H}\nN_W {cfg.N_W}\n")
        f.write(f"WIDTH {cfg.WIDTH}\nOWIDTH {cfg.OWIDTH}\nT {cfg.T}\n")
        f.write(f"ENCODING {cfg.ENCODING}\n")
        f.write(f"n_spatial {n_spatial}\nn_k_blocks {n_k_blocks}\n")

    with open(stim_path, "w") as f:
        f.write(f"{M_g} {N_g} {K_g} {cfg.K} {cfg.M} {cfg.N_H} {cfg.N_W} {cfg.WIDTH} {cfg.T}\n")
        f.write(f"{n_spatial} {n_k_blocks}\n")

        for rt in range(n_rt):
            for ct in range(n_ct):
                A_tile = A[rt*cfg.N_H:(rt+1)*cfg.N_H]
                sA_tile = sA[rt*cfg.N_H:(rt+1)*cfg.N_H]
                B_tile = B[ct*cfg.N_W:(ct+1)*cfg.N_W]
                sB_tile = sB[ct*cfg.N_W:(ct+1)*cfg.N_W]
                for k in range(n_k_blocks):
                    ifm_mag = A_tile[:, k*cfg.K:(k+1)*cfg.K]
                    ifm_sign = sA_tile[:, k*cfg.K:(k+1)*cfg.K]
                    wght_mag = B_tile[:, k*cfg.K:(k+1)*cfg.K]
                    wght_sign = sB_tile[:, k*cfg.K:(k+1)*cfg.K]
                    f.write(f"{_pack_mag(ifm_mag, cfg.WIDTH):x}\n")
                    f.write(f"{_pack_sign(ifm_sign):x}\n")
                    f.write(f"{_pack_mag(wght_mag, cfg.WIDTH):x}\n")
                    f.write(f"{_pack_sign(wght_sign):x}\n")

    # expected: one line per (rt, ct) drain, holding y[rt*N_H:(rt+1)*N_H, ct*N_W:(ct+1)*N_W]
    # packed as (h*N_W + v) order matching drain_out layout in sc_array.sv:
    #   drain_out[r*N_H*N_W*OWIDTH +: N_H*N_W*OWIDTH] with h fastest? see sc_inner_pe.sv acc_flat.
    # acc_flat[(h*N_W + v)*ACC_W +: ACC_W]  -> h outermost, v innermost.
    # sc_array line 116: drain_out[r*...] = drain_link[r][P_COLS]
    #   drain_link[r][c+1] = doe = drain_out of PE(r,c) = drain_reg (which holds acc_flat at mac_done).
    # For P_ROWS=P_COLS=1, drain_out[0*N_H*N_W*OWIDTH +: N_H*N_W*OWIDTH] = drain_reg of PE(0,0).
    # Within that: (h*N_W + v)*OWIDTH +: OWIDTH.
    with open(exp_path, "w") as f:
        for rt in range(n_rt):
            for ct in range(n_ct):
                block = y_ref[rt*cfg.N_H:(rt+1)*cfg.N_H,
                              ct*cfg.N_W:(ct+1)*cfg.N_W]
                for h in range(cfg.N_H):
                    for v in range(cfg.N_W):
                        f.write(f"{int(block[h, v])}\n")

    print(f"Wrote {stim_path}, {exp_path}, {meta_path}")
    print(f"GEMM: ({M_g}x{K_g}) @ ({N_g}x{K_g})^T -> ({M_g}x{N_g})")
    print(f"n_spatial={n_spatial} n_k_blocks={n_k_blocks}")
    print(f"y_ref = \n{y_ref}")


if __name__ == "__main__":
    main()
