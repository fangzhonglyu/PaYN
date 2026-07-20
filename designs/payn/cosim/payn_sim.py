"""Array-level bit-exact reference for the PaYN SC array (one spatial tile).

Thin driver over sc_kernel.matmul: given one spatial tile's binary operands
(magnitudes + signs), returns the N_H x N_W drained accumulator matrix the RTL
`payn_array` produces. Reusable as a standalone array simulator and used by the
array cosim (cosim_array.py).
"""
from __future__ import annotations

import numpy as np

from sc_kernel import ArrayCfg, matmul


def array_reference(a_mag, a_sign, w_mag, w_sign, cfg: ArrayCfg) -> np.ndarray:
    """One spatial tile. a_*: (N_H, K); w_*: (N_W, K) -> drain (N_H, N_W)."""
    A = np.asarray(a_mag, dtype=np.uint32)
    sA = np.asarray(a_sign, dtype=np.uint8)
    B = np.asarray(w_mag, dtype=np.uint32)
    sB = np.asarray(w_sign, dtype=np.uint8)
    return matmul(A, sA, B, sB, cfg)


def parse_trace(path):
    """Parse array_rtl.txt written by test_payn_array.sv."""
    fields = {}
    with open(path) as handle:
        for line in handle:
            parts = line.split()
            if parts:
                fields[parts[0]] = parts[1:]
    K, M, N_H, N_W, WIDTH, OWIDTH, T = (int(x) for x in fields["CFG"])
    cfg = ArrayCfg(K=K, M=M, N_H=N_H, N_W=N_W, WIDTH=WIDTH, OWIDTH=OWIDTH, T=T)
    a_mag = np.array(fields["AMAG"], dtype=np.int64).reshape(N_H, K)
    a_sign = np.array(fields["ASIGN"], dtype=np.uint8).reshape(N_H, K)
    w_mag = np.array(fields["WMAG"], dtype=np.int64).reshape(N_W, K)
    w_sign = np.array(fields["WSIGN"], dtype=np.uint8).reshape(N_W, K)
    drain = np.array(fields["DRAIN"], dtype=np.int64).reshape(N_H, N_W)
    return cfg, a_mag, a_sign, w_mag, w_sign, drain
