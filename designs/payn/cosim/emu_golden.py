#!/usr/bin/env python3
"""Golden accumulators from the scmp_kernels SC emulator for one int8 matmul.

Computes acc[n][m] = sum_d sign(A[n,d]) * sign(B[m,d]) * count_d with the
production emulator tables (scmp_kernels.sc.kernels.build_enable_tables) and the
production tiled Triton kernel, at the deployed configuration (sc_prec=8,
bipolar, 7-bit RNG grid, Sobol "q"/"k" seeds, bitrev masks), for a chosen
multiplication scheme (SC_MULT_SCHEME = cbsg | ut | and).

Operands are int8 .mem files in the t9_sc_matmul format (one row per line,
two's-complement hex, `//` header). With --check-cbsg DIR the script first
reproduces DIR/out_L*.mem under cbsg, validating this harness against the
mentor-provided vectors.

Runs on a GPU, or on CPU under the Triton interpreter (TRITON_INTERPRET=1 is
set automatically when no GPU is present).

    python emu_golden.py --case ../../../../gpu_aversion/t9_sc_matmul/uniform \
        --scheme ut --lengths 128,64,43,16 --out vectors_ut/uniform
"""
from __future__ import annotations

import argparse
import os
import sys
import types
from pathlib import Path

import numpy as np

if "TRITON_INTERPRET" not in os.environ:
    try:
        import torch
        if not torch.cuda.is_available():
            os.environ["TRITON_INTERPRET"] = "1"
    except ImportError:
        pass

import torch  # noqa: E402
import triton  # noqa: E402
import triton.language as tl  # noqa: E402

SC_PREC = 8
Q_MAX = 127
GRID = 128            # halve_bipolar_stoc_len: 7-bit RNG grid


def _install_cpu_shim() -> None:
    """Interpreter has no CUDA libdevice; give the quant kernels a nearbyint."""
    @triton.jit
    def _nearbyint(x):
        r = tl.floor(x + 0.5)
        tie = (r - x) == 0.5
        odd = (r - 2.0 * tl.floor(r * 0.5)) != 0.0
        return tl.where(tie & odd, r - 1.0, r)

    import scmp_kernels.quant.fused as fused
    import scmp_kernels.sc.kernels as kernels
    shim = types.SimpleNamespace(nearbyint=_nearbyint)
    fused.libdevice = shim
    kernels.libdevice = shim


def read_mem(path: Path, bits: int) -> np.ndarray:
    rows = [[int(x, 16) for x in line.split()]
            for line in path.read_text().splitlines()
            if line.strip() and not line.startswith("//")]
    a = np.array(rows, dtype=np.int64)
    return np.where(a >= 1 << (bits - 1), a - (1 << bits), a)


def write_mem(path: Path, acc: np.ndarray, header: str) -> None:
    lines = [f"// {header}"]
    for row in acc:
        lines.append(" ".join(f"{int(v) & 0xFFFFFFFF:08x}" for v in row))
    path.write_text("\n".join(lines) + "\n")


def emulator_acc(qa: np.ndarray, qb: np.ndarray, stoc_len: int, scheme: str) -> np.ndarray:
    """Integer acc from the production tables + tiled kernel (decode factor 1)."""
    os.environ["SC_MULT_SCHEME"] = scheme
    from scmp_kernels.sc import clear_rng_cache
    from scmp_kernels.sc.config_helpers import make_sobol_simple_config
    from scmp_kernels.sc.kernels import (
        _get_cached_sequences, build_enable_tables, enable_matmul_tiled_kernel)
    clear_rng_cache()

    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    N, D = qa.shape
    M = qb.shape[0]
    cfg = make_sobol_simple_config(D, D, SC_PREC)
    rng_a, rng_b = _get_cached_sequences(cfg, SC_PREC, dev)
    cum, k_table = build_enable_tables(rng_a, rng_b, SC_PREC, stoc_len, rng_levels=GRID)

    ta = torch.tensor(qa, dtype=torch.float32, device=dev)
    tb = torch.tensor(qb, dtype=torch.float32, device=dev)
    # Same boundary as fused_quantize_bipolar: round(|q| * GRID / Q_MAX).
    ba = torch.round(ta.abs() * (GRID / Q_MAX)).to(torch.int16)
    bb = torch.round(tb.abs() * (GRID / Q_MAX)).to(torch.int16)
    sa = torch.sign(ta).to(torch.int8)
    sb = torch.sign(tb).to(torch.int8)

    out = torch.empty(N, M, dtype=torch.float32, device=dev)
    rung = torch.zeros(N, dtype=torch.int32, device=dev)
    one = torch.ones(1, dtype=torch.float32, device=dev)
    BLOCK = 16
    enable_matmul_tiled_kernel[(triton.cdiv(N, BLOCK), triton.cdiv(M, BLOCK))](
        cum, k_table[None].contiguous(),
        ba.t().contiguous(), bb.t().contiguous(), sa.t().contiguous(), sb.t().contiguous(),
        out, rung, one,
        N, M, D, stoc_len, cum.shape[2], float(Q_MAX * Q_MAX), BLOCK, BLOCK, 4,
        IS_BIPOLAR=True, PER_ROW_LEN=True, num_warps=2)
    return out.round().to(torch.int64).cpu().numpy()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", type=Path, required=True,
                    help="directory holding a.mem and b.mem")
    ap.add_argument("--scheme", default="ut", choices=["cbsg", "ut", "and"])
    ap.add_argument("--lengths", default="128,64,43,16")
    ap.add_argument("--out", type=Path, help="write out_L{L}.mem here")
    ap.add_argument("--check-cbsg", action="store_true",
                    help="first reproduce CASE/out_L*.mem under cbsg")
    args = ap.parse_args()

    if os.environ.get("TRITON_INTERPRET") == "1":
        _install_cpu_shim()

    qa = read_mem(args.case / "a.mem", 8)
    qb = read_mem(args.case / "b.mem", 8)
    lengths = [int(x) for x in args.lengths.split(",")]
    ok = True

    if args.check_cbsg:
        for L in lengths:
            ref = args.case / f"out_L{L}.mem"
            if not ref.exists():
                continue
            match = np.array_equal(emulator_acc(qa, qb, L, "cbsg"), read_mem(ref, 32))
            ok &= match
            print(f"[{'PASS' if match else 'FAIL'}] cbsg L={L} reproduces {ref}")

    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        for L in lengths:
            acc = emulator_acc(qa, qb, L, args.scheme)
            write_mem(args.out / f"out_L{L}.mem", acc,
                      f"expected acc[n][m] at stream length L={L}, SC_MULT_SCHEME="
                      f"{args.scheme}, int32 two's complement, "
                      f"{acc.shape[0]} rows x {acc.shape[1]} values")
            print(f"wrote {args.out / f'out_L{L}.mem'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
