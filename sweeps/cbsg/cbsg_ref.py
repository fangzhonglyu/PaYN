#!/usr/bin/env python3
"""Bit-exact C-BSG reference for the PaYN carry-save SC port (library + CLI).

Three things live here, all integer-exact:

  kernel_acc_*   the scmp_kernels (ce3d7e5) integer accumulator, ported line for line from the torch/triton
                 code into numpy (file:line cited at every ported piece).  This is the golden.
  hw_rg_acc      cycle/position-level model of design RG (per-row generator, literal C-BSG): random A,
                 per-(row, lane) W index counter = number of that row's A ones so far, per-tile W comparators.
  hw_af_acc      cycle/position-level model of design AF (A-first): thermometer A from the closed-form kA,
                 one W stream per lane shared by every row.

Both hardware models run blocks of 8 lanes x 16 positions per cycle, restart the streams every block,
use per-row stream lengths, build the column mask from a 3-bit block-phase register plus hard-wired
lane bits, pad partial blocks with zero magnitude, and accumulate a signed per-cycle popcount the way
the CSA tile does.  The self-test proves kernel == RG == AF bit for bit.  hw_calls_acc runs several calls
back to back on one instance, so mask state that leaks across calls (the deployed form of the
scrambling-mask issue) can be modelled; MASK_FAULTS lists the injected mask faults.

Read-only inputs: ~/repos/scmp_kernels (rng.py loaded by file path, no package import, no bytecode),
~/repos/soren_scmp/sc_traces (trace + config JSON only), ~/repos/soren_PaYN (one numpy reference loaded
by path for an independent cross-check).

Usage:
  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/cbsg_ref.py --selftest          # log: build/cbsg/ref_selftest.log
  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/cbsg_ref.py --emit build/cbsg/golden --case all
  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/cbsg_ref.py --list-cases
"""
from __future__ import annotations

import argparse
import functools
import glob
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

sys.dont_write_bytecode = True
os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")

REPO = Path(__file__).resolve().parents[2]
KERNEL_ROOT = Path(os.path.expanduser(os.environ.get("SCMP_KERNELS", "~/repos/scmp_kernels")))
TRACE_ROOT = Path(os.path.expanduser(os.environ.get("SOREN_SC_TRACES", "~/repos/soren_scmp/sc_traces")))
SOREN_PAYN = Path(os.path.expanduser(os.environ.get("SOREN_PAYN", "~/repos/soren_PaYN")))

# Deployed arithmetic (trace headers: sc_prec=8, sc_halve=true, rng_levels=128, owen_mode=bitrev,
# scramble_masks=64, mode=bipolar).  halve forces stoc_len/rng_levels to 2**(sc_prec-1) (matmul.py:243-259).
SC_PREC = 8
BASE = 1 << SC_PREC                 # 256: Sobol word range / base_levels
GRID = 1 << (SC_PREC - 1)           # 128: rng_levels (enable grid) under halve
Q_MAX = (1 << (SC_PREC - 1)) - 1    # 127
L_MAX = GRID                        # longest realizable stream under halve (matmul.py:247-256)
N_MASKS_DEFAULT = 64                # _DEFAULT_SCRAMBLE_MASKS (kernels.py:719), HW_MAX_MASKS (kernels.py:738)

LANES = 8                           # K: reduction columns per block (one per lane)
POS = 16                            # M: AND positions per lane per cycle
TILE_R = 8                          # rows per tile
POS_IDX = np.arange(POS)


# =====================================================================================================
# Kernel port (numpy).  Every function cites the kernels.py / quant lines it reproduces.
# =====================================================================================================

def _load_emu_rng():
    """scmp_kernels/sc/rng.py imports only numpy/random/abc, so it is loaded by path (no torch/triton)."""
    path = KERNEL_ROOT / "scmp_kernels" / "sc" / "rng.py"
    spec = importlib.util.spec_from_file_location("_scmp_emu_rng", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


EMU_RNG = _load_emu_rng()


def _resolve_rng_levels(sc_prec, rng_levels):                       # kernels.py:667-678
    if rng_levels is None:
        return 2 ** sc_prec
    return int(rng_levels)


def _bit_reverse(x, n_bits):                                        # kernels.py:722-727
    x = np.asarray(x)
    y = np.zeros_like(x)
    for i in range(n_bits):
        y = y | (((x >> i) & 1) << (n_bits - 1 - i))
    return y


def _scramble_mask_count(base_levels, scramble_masks=N_MASKS_DEFAULT,
                         hw_max_masks=N_MASKS_DEFAULT):             # kernels.py:746-767 (env defaults)
    k = scramble_masks
    m = min(k, hw_max_masks, base_levels)                           # kernels.py:761
    if m & (m - 1):
        raise ValueError(f"mask count must be a power of two, got {m}")
    return m


def _owen_scramble(prefix, base_levels):                            # kernels.py:770-811, SC_OWEN_MODE=bitrev
    D = prefix.shape[0]
    m = _scramble_mask_count(base_levels)
    n_bits = int(round(np.log2(base_levels)))                       # kernels.py:794
    idx = np.arange(D, dtype=np.int64) % m                          # kernels.py:795
    masks = _bit_reverse(idx, n_bits).astype(prefix.dtype)[:, None]  # kernels.py:796
    return np.ascontiguousarray(prefix ^ masks)                     # kernels.py:811


def _prepare_rng_prefix(rng, sc_prec, stoc_len, rng_levels):        # kernels.py:814-849
    grid_levels = _resolve_rng_levels(sc_prec, rng_levels)
    base_levels = 2 ** sc_prec
    is_prefix = stoc_len < rng.shape[1]                             # kernels.py:823
    prefix = np.ascontiguousarray(rng[:, :stoc_len]) if is_prefix else rng
    if grid_levels == base_levels:                                  # fixed-level path (not deployed)
        if is_prefix:
            return _owen_scramble(prefix, base_levels)
        return prefix
    prefix = _owen_scramble(prefix, base_levels)                    # kernels.py:846 (always on)
    scaled = (prefix.astype(np.int64) * grid_levels) // base_levels  # kernels.py:848 (floor div)
    return np.ascontiguousarray(scaled.astype(prefix.dtype))


def _next_power_of_2(n):                                            # triton.next_power_of_2
    return 1 << (int(n) - 1).bit_length()


@functools.lru_cache(maxsize=None)
def _base_sequences():
    """RNGPool(make_sobol_simple_config) -> Sobol(sc_prec, seed_type).simulate(2**sc_prec)
    (config_helpers.py:583-607, sng.py:69-116, kernels.py:79-86)."""
    q = EMU_RNG.Sobol(SC_PREC, seed_type="q").simulate(BASE).astype(np.int32)
    k = EMU_RNG.Sobol(SC_PREC, seed_type="k").simulate(BASE).astype(np.int32)
    return q, k


def kernel_sequences(d_cfg):
    """_get_cached_sequences (kernels.py:67-87) for make_sobol_simple_config(d_cfg, d_cfg): every SNG has
    scramble None, so SNGBank.get_all_sequences broadcasts the one base sequence (sng.py:218-220)."""
    q, k = _base_sequences()
    return (np.broadcast_to(q, (d_cfg, BASE)).copy(), np.broadcast_to(k, (d_cfg, BASE)).copy())


def build_cum_indicator(rng_b, D, stoc_len, V):                     # kernels.py:103-139 (one program per d)
    rng_b = np.ascontiguousarray(rng_b).reshape(-1)[: D * stoc_len].reshape(D, stoc_len)  # rng_b_ptr + d*stoc_len + k
    v_range = np.arange(V)
    cum = np.zeros((D, stoc_len + 1, V), dtype=np.int16)            # cum[d, 0, :] = 0
    running = np.zeros((D, V), dtype=np.int16)
    for k in range(stoc_len):
        r = rng_b[:, k]
        running = running + (v_range[None, :] > r[:, None]).astype(np.int16)   # kernels.py:133 (strict >)
        cum[:, k + 1, :] = running
    return cum


def compute_k_table(rng_a, D, stoc_len, V):                         # kernels.py:141-171
    rng_a = np.ascontiguousarray(rng_a).reshape(-1)[: D * stoc_len].reshape(D, stoc_len)
    v_range = np.arange(V)
    counts = np.zeros((D, V), dtype=np.int16)
    for t in range(stoc_len):
        counts += (v_range[None, :] > rng_a[:, t][:, None]).astype(np.int16)  # kernels.py:166
    return counts


@functools.lru_cache(maxsize=4)                                     # cum is D x 129 x 256 int16: keep few
def build_enable_tables(d_cfg, stoc_len, rng_levels=GRID):          # kernels.py:883-930
    """(cum_indicator (D, stoc_len+1, V_PADDED), k_table (D, V_PADDED)), V_PADDED = next_pow2(129) = 256."""
    rng_a, rng_b = kernel_sequences(d_cfg)
    grid_levels = _resolve_rng_levels(SC_PREC, rng_levels)
    V = grid_levels + 1
    V_PADDED = _next_power_of_2(V)                                  # kernels.py:910
    rng_a_prefix = _prepare_rng_prefix(rng_a, SC_PREC, stoc_len, grid_levels)
    rng_b_prefix = _prepare_rng_prefix(rng_b, SC_PREC, stoc_len, grid_levels)
    cum = build_cum_indicator(rng_b_prefix, d_cfg, stoc_len, V_PADDED)
    k_table = compute_k_table(rng_a_prefix, d_cfg, stoc_len, V_PADDED)
    cum.setflags(write=False)
    k_table.setflags(write=False)
    return cum, k_table


@functools.lru_cache(maxsize=256)
def build_k_table_only(d_cfg, stoc_len, rng_levels=GRID):           # kernels.py:1113-1136
    rng_a, _ = kernel_sequences(d_cfg)
    grid_levels = _resolve_rng_levels(SC_PREC, rng_levels)
    V_PADDED = _next_power_of_2(grid_levels + 1)                    # kernels.py:1132
    rng_a_prefix = _prepare_rng_prefix(rng_a, SC_PREC, stoc_len, grid_levels)
    kt = compute_k_table(rng_a_prefix, d_cfg, stoc_len, V_PADDED)
    kt.setflags(write=False)
    return kt


def k_table_stack(d_cfg, level_lens, rng_levels=GRID):              # _get_cached_k_table_stack kernels.py:1008-1036
    return np.stack([build_k_table_only(d_cfg, int(L), rng_levels) for L in level_lens], axis=0)


@functools.lru_cache(maxsize=64)
def rng_b_prefix_for(d_cfg, stoc_len, rng_levels=GRID):             # kernels.py:1851 (chunked fast path)
    _, rng_b = kernel_sequences(d_cfg)
    p = _prepare_rng_prefix(rng_b, SC_PREC, stoc_len, rng_levels)
    p.setflags(write=False)
    return p


@functools.lru_cache(maxsize=4)
def _chunk_cum(chunk_d, stoc_len, V):
    """build_cum_indicator_kernel[(chunk_d,)](rng_b, cum, chunk_d, stoc_len, V) (kernels.py:1619-1629)."""
    cum = build_cum_indicator(rng_b_prefix_for(chunk_d, stoc_len), chunk_d, stoc_len, V)
    cum.setflags(write=False)
    return cum


def tiled_kernel_acc(cum, k_table, ba_t, bb_t, sa_t, sb_t, N, M, D, rung=None):
    """enable_matmul_tiled_kernel, IS_BIPOLAR=True (kernels.py:177-302), returning `acc` BEFORE the scale
    (kernels.py:279-283).  ba_t/bb_t/sa_t/sb_t are the (D, N)/(D, M) transposed tensors the kernel reads.
    The kernel accumulates `counts * sa * sb` in float32; every term is an integer and |acc| < 2**24 here
    (asserted), so the float32 accumulator equals this int64 one.  The all-zero-sign tile skip
    (kernels.py:248-251) only skips zero terms, so it is not modelled."""
    acc = np.zeros((N, M), dtype=np.int64)
    if rung is not None:
        rung = np.asarray(rung, dtype=np.int64)                     # kernels.py:236-237 k_base = rung*(D*V)
    for d in range(D):
        sa = sa_t[d].astype(np.int64)
        sb = sb_t[d].astype(np.int64)
        ba = ba_t[d].astype(np.int64)
        bb = bb_t[d].astype(np.int64)
        if rung is not None:
            k_vals = k_table[rung, d, ba].astype(np.int64)          # kernels.py:256 k_table[k_base + d*V + ba]
        else:
            k_vals = k_table[d, ba].astype(np.int64)                # kernels.py:258
        counts = cum[d, k_vals[:, None], bb[None, :]].astype(np.int64)  # kernels.py:259-262
        acc += counts * sa[:, None] * sb[None, :]                   # kernels.py:263
    assert np.abs(acc).max(initial=0) < (1 << 24), "float32 accumulator would no longer be exact"
    return acc


def _check_lengths(L):
    L = np.asarray(L)
    if L.size and (L.min() < 1 or L.max() > L_MAX):
        raise ValueError(f"stream lengths must lie in 1..{L_MAX} under halve (matmul.py:247-256)")


def kernel_acc_plain(ba, sa, bb, sb, L):
    """Plain (unchunked) per-row / per-tensor path: _sc_matmul_per_row (kernels.py:1931-2015) or
    _sc_matmul_per_tensor (1297-1396) -> config make_sobol_simple_config(D, D) (1973 / 1355) ->
    _get_cached_enable_tables (2003 / 1379) -> enable_matmul_triton (1039-1110, transposes at 1073-1077)
    -> enable_matmul_tiled_kernel with PER_ROW_LEN=False.  Mask index d is global along D.

    L may be a scalar (one call) or a per-row array.  Per-row L on this path (chunk_d = 0; attention qk/av
    in the traces) is modelled as one call per distinct L on that row subset: the trace records chunk_d=0
    groups per (op, unit, stoc_len) with row counts that split each call, rung tables need chunk_d > 0
    (matmul.py gate), and per-row quantization makes the row split exact.  kernel_acc_plain_kstack is the
    single-call PER_ROW_LEN equivalent; the self-test checks the two agree."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    N, D = ba.shape
    M = bb.shape[0]
    Lr = np.broadcast_to(np.asarray(L, dtype=np.int64), (N,))
    _check_lengths(Lr)
    acc = np.zeros((N, M), dtype=np.int64)
    for Lv in np.unique(Lr):
        rows = np.nonzero(Lr == Lv)[0]
        cum, k_table = build_enable_tables(D, int(Lv))
        acc[rows] = tiled_kernel_acc(cum, k_table, ba[rows].T, bb.T, sa[rows].T, sb.T, len(rows), M, D)
    return acc


def kernel_acc_plain_kstack(ba, sa, bb, sb, L_rows, stoc_len=L_MAX):
    """Same rows in ONE PER_ROW_LEN call: cum at stoc_len, k_table stack over the distinct lengths, per-row
    rung (kernels.py:178-302 with PER_ROW_LEN=True; stack as kernels.py:1008-1036)."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    N, D = ba.shape
    M = bb.shape[0]
    Lr = np.asarray(L_rows, dtype=np.int64)
    _check_lengths(Lr)
    lens = sorted(set(int(v) for v in Lr))
    if max(lens) > stoc_len:                                        # kernels.py:1571
        raise ValueError("level_lens max exceeds stoc_len")
    rung = np.array([lens.index(int(v)) for v in Lr])
    cum, _ = build_enable_tables(D, stoc_len)
    return tiled_kernel_acc(cum, k_table_stack(D, lens), ba.T, bb.T, sa.T, sb.T, N, M, D, rung=rung)


def kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=L_MAX, rung_table=None, level_lens=None):
    """Chunked MLP path: _sc_matmul_per_row_mlp fast path (kernels.py:1840-1856) +
    _sc_matmul_bipolar_mlp_chunked (1517-1708).  Returns (n_chunks, N, M): the integer `partial` of every
    chunk before `output += partial * (scale_a * scale_b)` (1706), i.e. what the hardware drains per chunk.

      * config = make_sobol_simple_config(chunk_d, chunk_d) (1844): the tables have chunk_d columns, so the
        mask index d restarts at 0 in every chunk;
      * k_table at stoc_len (1848), rng_b prefix at stoc_len (1851), one cum over chunk_d columns (1619-1629);
      * short last chunk: cum rebuilt from rng_b[:d_len], k_table[:d_len] / k_stack[:, :d_len] (1668-1676);
      * rung_table (N, n_chunks) indexes level_lens per (row, chunk) (1605, 1689, kernel 236-256).
    D <= chunk_d falls through to the standard path (1840 condition), i.e. the plain path."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    N, D = ba.shape
    M = bb.shape[0]
    if not (chunk_d > 0 and D > chunk_d):                           # kernels.py:1840
        if rung_table is not None:                                  # kernels.py:1874-1878
            raise ValueError("rung_table needs the chunked fast path (0 < chunk_d < D)")
        return kernel_acc_plain(ba, sa, bb, sb, stoc_len)[None]
    per_row_len = rung_table is not None
    n_chunks = (D + chunk_d - 1) // chunk_d
    if per_row_len:                                                 # kernels.py:1561-1610
        lens = [int(v) for v in level_lens]
        rung_table = np.asarray(rung_table, dtype=np.int64)
        if rung_table.shape != (N, n_chunks):
            raise ValueError(f"rung_table must be (N, num_chunks) = ({N}, {n_chunks})")
        if max(lens) > stoc_len:                                    # kernels.py:1571
            raise ValueError(f"level_lens max {max(lens)} exceeds stoc_len {stoc_len}")
        if min(lens) < 1:
            raise ValueError("level_lens must be >= 1")
        if rung_table.max() >= len(lens) or rung_table.min() < 0:
            raise ValueError("rung_table values out of range")
        _check_lengths(lens)
        k_stack = k_table_stack(chunk_d, lens)                      # kernels.py:1605
    _check_lengths([stoc_len])
    k_table = build_k_table_only(chunk_d, stoc_len)                 # kernels.py:1848
    rng_b = rng_b_prefix_for(chunk_d, stoc_len)                     # kernels.py:1851
    V = k_table.shape[1]                                            # kernels.py:1610 (= V_PADDED)
    cum_indicator = _chunk_cum(chunk_d, stoc_len, V)                # kernels.py:1619-1629
    out = []
    for ci, d_start in enumerate(range(0, D, chunk_d)):             # kernels.py:1651
        d_end = min(d_start + chunk_d, D)
        d_len = d_end - d_start
        if d_len < chunk_d:                                         # kernels.py:1668-1676
            cum_chunk = build_cum_indicator(rng_b[:d_len], d_len, stoc_len, V)
            k_tab_chunk = k_stack[:, :d_len, :] if per_row_len else k_table[:d_len]
        else:
            cum_chunk = cum_indicator
            k_tab_chunk = k_stack if per_row_len else k_table
        rung_chunk = rung_table[:, ci] if per_row_len else None     # kernels.py:1689
        out.append(tiled_kernel_acc(cum_chunk, k_tab_chunk,
                                    ba[:, d_start:d_end].T, bb[:, d_start:d_end].T,
                                    sa[:, d_start:d_end].T, sb[:, d_start:d_end].T,
                                    N, M, d_len, rung=rung_chunk))
    return np.stack(out)


def kernel_acc_chunked_rowsplit(ba, sa, bb, sb, chunk_d, L_rows):
    """Per-row L on the chunked path as the scmp_llm SCLinear wrapper dispatches it (local scmp_llm dc3c8a2,
    model/sc_common.py:149-179): one sc_matmul call per level on that level's row subset with stoc_len=L.
    By prefix nesting this equals one rung-table call whose rung is constant along the chunks (self-test)."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    N, D = ba.shape
    Lr = np.asarray(L_rows, dtype=np.int64)
    out = np.zeros((-(-D // chunk_d) if (chunk_d > 0 and D > chunk_d) else 1, N, bb.shape[0]), np.int64)
    for Lv in np.unique(Lr):
        rows = np.nonzero(Lr == Lv)[0]
        out[:, rows] = kernel_acc_chunked(ba[rows], sa[rows], bb, sb, chunk_d, stoc_len=int(Lv))
    return out


def kernel_acc_batched(ba, sa, bb, sb, L):
    """3D paths: _sc_matmul_per_head_bipolar (kernels.py:475-631) and _sc_matmul_per_row_batched
    (2136-2252) both run enable_matmul_bipolar_batched_kernel (397-472): tables over D (config
    make_sobol_simple_config(D, D): matmul.py:417-420, kernels.py:2174) shared by every head, mask index d per
    head, one uniform stoc_len.  Inputs (BH, N, D) / (BH, M, D); returns (BH, N, M) before the scale (470)."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    BH, N, D = ba.shape
    M = bb.shape[1]
    _check_lengths([L])
    cum, k_table = build_enable_tables(D, int(L))
    return np.stack([tiled_kernel_acc(cum, k_table, ba[h].T, bb[h].T, sa[h].T, sb[h].T, N, M, D)
                     for h in range(BH)])


# ----- FP -> (boundary, sign): the hardware operand contract ------------------------------------------

def _f32(x):
    return np.asarray(x, dtype=np.float32)


def from_float(x, path, chunk_d=0):
    """The kernel's quantization of a float operand to (b, sign, scale), in IEEE float32 arithmetic.

    path:
      'per_row'     2D attention / plain per-row: _grouped_symmetric_quant G=1 (grouped.py:13-71) then
                    boundary = round(|x_int| * 128 / 127) (kernels.py:2036-2037).  Zero -> sign +1.
      'per_row_3d'  3D per-row: _grouped_symmetric_quant_batched G=1 (grouped.py:153-159), boundary
                    round(|x_int| * (128/127)) (kernels.py:2221-2222).  Zero -> sign +1.
      'chunked'     MLP with 0 < chunk_d < D: fused_quantize_bipolar_perrow on every chunk (kernels.py:1660-1665;
                    fused.py:134-159, kernel 72-110).  Zero -> sign 0.  Returns scale (rows, n_chunks).
                    With D <= chunk_d or chunk_d == 0 the kernel takes the STANDARD path instead (kernels.py:1840
                    false -> _sc_matmul_enable_triton_bipolar_mlp, kernels.py:1477-1500: _grouped_symmetric_quant
                    G=1, boundary round(|x_int| * 128 / 127)), so this returns the 'per_row' result, scale (rows, 1).
                    Deployed small gathered calls (d_in 21..123 at chunk_d 128) take this branch.
      'per_head'    host scale (kernels.py:525-529) + fused_quant_bipolar_batched_kernel (fused.py:238-280).
      'per_tensor'  fused_quantize_bipolar (fused.py:162-192).
    Every path yields b in {0..63, 65..128}: round(k * 128/127) skips 64 (k/127 never sits at 0.5).

    Exactness: checked only for internal consistency (kernel == RG == AF on these operands), never against GPU
    output (no torch/triton/GPU here).  The fused per-row branch ('chunked' with 0 < chunk_d < D) computes
    scale = abs_max / q_max and 1.0 / scale with fp32 '/' inside Triton (fused.py:76-81), which the NVIDIA backend
    probably lowers to the approximate div.full.f32 (<= 2 ulp; unconfirmed here) rather than IEEE division, so b
    can differ by +-1 where x * inv_scale is within a few ulp of k + 0.5 (about 1e-6 of random elements).  The
    other paths divide in torch / Python (IEEE) and only multiply in the kernel.  The hardware contract starts
    at (b, sign): golden vectors are generated from integer operands, not from this function."""
    x = _f32(x)
    q = np.float32(Q_MAX)
    grid = np.float32(GRID)
    if path in ("per_row", "per_row_3d"):
        amax = np.maximum(np.abs(x).max(axis=-1, keepdims=True), np.float32(1e-5))   # amax(dim=...).clamp
        scale = (amax / q).astype(np.float32)
        x_int = np.clip(np.round(x / scale), -Q_MAX, Q_MAX).astype(np.float32)        # .round().clamp()
        sign = np.sign(x_int).astype(np.int8)
        sign[sign == 0] = 1                                                           # grouped.py:53 / 158
        if path == "per_row":
            b = np.round(np.abs(x_int) * grid / q)                                    # kernels.py:2036
        else:
            b = np.round(np.abs(x_int) * (grid / q))                                  # kernels.py:2221
        return b.astype(np.int16), sign, scale[..., 0]

    def fused(xs, inv_scale, lo):                                   # fused.py:98-106 / 265-273
        xr = np.round((xs * inv_scale).astype(np.float32))          # libdevice.nearbyint (half-even)
        xc = np.minimum(np.maximum(xr, np.float32(lo)), q)
        sign = np.where(xc > 0, 1, np.where(xc < 0, -1, 0)).astype(np.int8)
        b = np.round(np.abs(xc) * (grid / q)).astype(np.int16)      # max_rng_val / q_max in fp32
        return b, sign

    if path == "chunked":
        N, D = x.shape
        if not (chunk_d > 0 and D > chunk_d):                       # kernels.py:1840 false: standard path
            b, s, scale = from_float(x, "per_row")                  # kernels.py:1489-1500 (grouped, G = 1)
            return b, s, scale[:, None]
        bs, ss, scales = [], [], []
        for d0 in range(0, D, chunk_d):
            xc = x[:, d0:d0 + chunk_d]
            amax = np.maximum(np.abs(xc).max(axis=1, keepdims=True), np.float32(1e-5))   # fused.py:76-77
            scale = (amax / q).astype(np.float32)                                         # fused.py:78
            inv = (np.float32(1.0) / scale).astype(np.float32)                            # fused.py:79
            b, s = fused(xc, inv, -Q_MAX)
            bs.append(b); ss.append(s); scales.append(scale[:, 0])
        return np.concatenate(bs, axis=1), np.concatenate(ss, axis=1), np.stack(scales, axis=1)
    if path == "per_head":
        amax = np.maximum(np.maximum(np.abs(x.max(axis=(1, 2))), np.abs(x.min(axis=(1, 2)))),
                          np.float32(1e-5))                         # kernels.py:525
        scale = (amax / q).astype(np.float32)                       # kernels.py:527
        inv = (np.float32(1.0) / scale).astype(np.float32)          # kernels.py:529
        b, s = fused(x, inv[:, None, None], -(Q_MAX + 1))           # q_min = -128 (kernels.py:520)
        return b, s, scale
    if path == "per_tensor":
        abs_max = max(abs(float(x.max())), abs(float(x.min())), 1e-5)   # fused.py:172 (python double)
        scale = abs_max / Q_MAX
        inv = np.float32(1.0 / scale)                               # fp32 kernel argument
        b, s = fused(x, inv, -Q_MAX)
        return b, s, np.float32(scale)
    raise ValueError(f"unknown path {path!r}")


# =====================================================================================================
# Hardware models
# =====================================================================================================

BR8 = _bit_reverse(np.arange(256), 8).astype(np.int64)
BR3 = _bit_reverse(np.arange(8), 3).astype(np.int64)

# Direction numbers as the RTL holds them (soren sobol.sv dv(): q = identity, k = 80 40 20 10 48 04 52 ff).
DV_Q = [0x80 >> j for j in range(8)]
DV_K = [0x80, 0x40, 0x20, 0x10, 0x48, 0x04, 0x52, 0xFF]


def hw_mask(k, p):
    """Column mask from the hardware split d = 8p + k (mod 64): lane bits [7:5] = bitrev3(k), hard-wired per
    lane; bits [4:2] = bitrev3(p), p the 3-bit block-phase register; bits [1:0] = 0.  Equals bitrev8(d mod 64)."""
    return (BR3[np.asarray(k)] << 5) | (BR3[np.asarray(p)] << 2)


HW_MASK = hw_mask(np.arange(LANES)[:, None], np.arange(8)[None, :])   # (lane k, phase p)


def sobol_gray(idx, dv):
    """Direct Gray-code Sobol word: x(idx) = XOR over set bits b of gray(idx) of dv[b] (an index-addressed
    generator: soren inner_pe.sv per-(row, lane) W generator)."""
    idx = np.asarray(idx, dtype=np.int64)
    g = idx ^ (idx >> 1)
    x = np.zeros_like(idx)
    for b, v in enumerate(dv):
        x ^= ((g >> b) & 1) * v
    return x


def sobol_bank(dv, cycles=L_MAX // POS):
    """Sample-ordered bank (soren sobol.sv): lane m of cycle c = sample 16c+m, x[16c+m] = H(c) ^ LANE(m),
    LANE(m) = XOR_{j<4} gray(m)[j] dv[j], H(c+1) = H(c) ^ dv[4 + lsz(c)] ^ dv[3], H(0) = 0 (restart)."""
    LM = 4
    lane = sobol_gray(np.arange(POS), dv[:LM])
    out, H = [], 0
    for c in range(cycles):
        out.append(H ^ lane)
        lsz = 0
        while (c >> lsz) & 1:
            lsz += 1
        if LM + lsz < len(dv):
            H ^= dv[LM + lsz]
        H ^= dv[LM - 1]
    return np.array(out, dtype=np.int64)


XQ_BANK = sobol_bank(DV_Q)          # (8 cycles, 16 positions): A random words (RG)
XK_BANK = sobol_bank(DV_K)          # W random words in sample order (AF)
XK_GRAY = sobol_gray(np.arange(BASE), DV_K)   # W word by index (RG per-(row, lane) generator)


def ka_closed(b, L, mask):
    """A-first encoder: kA = #{t < L : ((Xq(t) ^ mask) >> 1) < b} in closed form (no Sobol bank).
    [0, L) splits into aligned dyadic blocks (largest first); a block of 2^j samples starting at s0
    contributes (b >> s) + [(b mod 2^s) > c], s = 7 - j, c = ((bitrev8(gray(s0)) ^ mask) mod 2^(8-j)) >> 1.
    (sweeps/cbsg/ka_closed_form.py ka_hw, vectorized.)"""
    b, L, mask = np.broadcast_arrays(np.asarray(b, np.int64), np.asarray(L, np.int64), np.asarray(mask, np.int64))
    k = np.zeros(b.shape, np.int64)
    s0 = np.zeros(b.shape, np.int64)
    for j in range(7, -1, -1):
        on = (L >> j) & 1
        s = 7 - j
        c = ((BR8[s0 ^ (s0 >> 1)] ^ mask) & ((1 << (8 - j)) - 1)) >> 1
        k += on * ((b >> s) + ((b & ((1 << s) - 1)) > c))
        s0 += on << j
    return k


def _sign_bits(b, s, what):
    """Hardware sign is one bit (1 = negative).  A zero sign is legal only with zero magnitude (both kernel
    quantizer conventions, +1 or 0 for x = 0, map to b = 0, which contributes nothing)."""
    b = np.asarray(b)
    s = np.asarray(s)
    if np.any((s == 0) & (b != 0)):
        raise ValueError(f"{what}: sign 0 with non-zero magnitude is outside the hardware contract")
    if b.min(initial=0) < 0 or b.max(initial=0) > GRID:
        raise ValueError(f"{what}: magnitude outside 0..{GRID}")
    return s < 0


def block_schedule(D, slice_len=0):
    """Hardware block order: the reduction axis is cut into slices (whole D for plain, chunk_d for chunked,
    one head for per-head); every slice is cut into blocks of 8 lanes starting at its first column, the
    last block padded with zero magnitude.  Block j of a slice has phase p = j mod 8 and lane k carries
    slice-local column d = 8j + k.  Returns [(slice, j, lo, hi, p, last_in_slice)] with global [lo, hi)."""
    sl = D if not slice_len else slice_len
    out = []
    for s, s_lo in enumerate(range(0, D, sl)):
        s_hi = min(s_lo + sl, D)
        nb = -(-(s_hi - s_lo) // LANES)
        for j in range(nb):
            lo = s_lo + LANES * j
            out.append((s, j, lo, min(lo + LANES, s_hi), j % 8, j == nb - 1))
    return out


def _rg_block(aB, aN, wB, wN, Lr, masks, C, fault=None):
    """One block of design RG for a group of tile rows.  aB/aN (R, 8), wB/wN (8, M), Lr (R,), masks (8,)."""
    R, M = aB.shape[0], wB.shape[1]
    sgn = np.where(aN[:, :, None] ^ wN[None, :, :], -1, 1)                 # (R, 8, M) sign XOR per lane
    j = np.zeros((R, LANES), np.int64)                                     # W index counter per (row, lane)
    acc = np.zeros((R, M), np.int64)
    for c in range(C):
        t = POS * c + POS_IDX
        rA = (XQ_BANK[c][None, :] ^ masks[:, None]) >> 1                   # (8, 16) shared by all rows
        a = rA[None, :, :] < aB[:, :, None]                                # (R, 8, 16) A = [rA < bA]
        if fault != "no_len_gate":
            a &= t[None, None, :] < Lr[:, None, None]                      # per-row length gate
        idx = j[:, :, None] + (np.cumsum(a, axis=2) - a)                   # A ones before t in the block
        if fault == "rg_w_by_t":
            idx = np.broadcast_to(t, idx.shape)
        rB = (XK_GRAY[idx] ^ masks[None, :, None]) >> 1                    # (R, 8, 16) per (row, lane)
        w = wB[None, :, :, None] > rB[:, :, None, :]                       # (R, 8, M, 16) per-tile compare
        acc += (sgn * (a[:, :, None, :] & w).sum(axis=3)).sum(axis=1)      # signed popcount this cycle
        j += a.sum(axis=2)
    return acc, None


def _af_block(aB, aN, wB, wN, Lr, masks, C, fault=None):
    """One block of design AF.  A bit = [t < kA] (closed form at the row's L), W bit = [bW > rB(d, t)]
    from one sample-ordered bank per lane, shared by every row of the array."""
    kA = ka_closed(aB, Lr[:, None], masks[None, :])                        # (R, 8) edge encoder
    if fault == "af_ka_eq_b":
        kA = np.minimum(aB, Lr[:, None])
    sgn = np.where(aN[:, :, None] ^ wN[None, :, :], -1, 1)
    acc = np.zeros((aB.shape[0], wB.shape[1]), np.int64)
    for c in range(C):
        t = POS * c + POS_IDX
        a = t[None, None, :] < kA[:, :, None]                              # (R, 8, 16) thermometer
        rB = (XK_BANK[c][None, :] ^ masks[:, None]) >> 1                   # (8, 16)
        w = wB[:, :, None] > rB[:, None, :]                                # (8, M, 16) shared W
        acc += (sgn * (a[:, :, None, :] & w[None]).sum(axis=3)).sum(axis=1)
    return acc, kA


def _row_lengths(L, N, n_slices):
    L = np.asarray(L, dtype=np.int64)
    if L.ndim == 0:
        L = np.full((N, n_slices), int(L))
    elif L.ndim == 1:
        L = np.repeat(L[:, None], n_slices, axis=1)
    if L.shape != (N, n_slices):
        raise ValueError(f"L must be scalar, (N,) or (N, n_slices) = ({N}, {n_slices}); got {L.shape}")
    _check_lengths(L)
    return L


MASK_FAULTS = {
    # name: (how the mask goes wrong, where it bites)
    "call_d":         "d = column index inside the call (reset at call start, not at chunk / head starts)",
    "no_slice_reset": "phase register reset at call start only, not at chunk / head starts",
    "global_mask":    "d = columns counted from the start of the run (never reset; continues across calls)",
    "no_phase_reset": "phase register free-runs from power-up (reset neither per slice nor per call)",
    "orig_channel_d": "d = original input-channel index of a gathered column (protected / unprotected split)",
}


def _block_masks(fault, p, lo, w, state, call_blk, cols):
    """Column masks (8 lanes) of one block.  Correct hardware: HW_MASK[:, p], p = (block index in the slice) mod 8,
    i.e. bitrev8(d mod 64) with d the column index inside the slice of the current call; the phase register resets
    at every slice start, which includes every call start.  The faults (MASK_FAULTS) are the ways the scrambling-
    mask issue can come back.  In ONE call from reset, call_d == global_mask and no_slice_reset == no_phase_reset;
    they differ only across calls (hw_calls_acc).  lo is the call-local first column, w the live lanes."""
    if fault == "call_d":
        return BR8[(lo + np.arange(LANES)) % N_MASKS_DEFAULT]
    if fault == "global_mask":
        return BR8[(state["cols"] + lo + np.arange(LANES)) % N_MASKS_DEFAULT]
    if fault == "no_slice_reset":
        return HW_MASK[:, call_blk % 8]
    if fault == "no_phase_reset":
        return HW_MASK[:, state["blocks"] % 8]
    if fault == "orig_channel_d":
        orig = np.arange(lo, lo + w) if cols is None else np.asarray(cols, np.int64)[lo:lo + w]
        m = np.zeros(LANES, np.int64)                  # padded lanes carry b = 0: their mask is irrelevant
        m[:w] = BR8[orig % N_MASKS_DEFAULT]
        return m
    if fault in (None, "no_len_gate", "rg_w_by_t", "af_ka_eq_b"):
        return HW_MASK[:, p]
    raise ValueError(f"unknown fault {fault!r}")


def _hw_acc(block_fn, ba, sa, bb, sb, L, slice_len=0, full_cycles=False, fault=None, trace=None,
            state=None, cols=None, call=0):
    """state: hardware state carried from earlier calls on the same instance (hw_calls_acc); only the mask
    faults read it.  cols: original channel index of every column of a gathered call (orig_channel_d)."""
    ba, bb = np.asarray(ba, np.int64), np.asarray(bb, np.int64)
    aNeg, wNeg = _sign_bits(ba, sa, "A"), _sign_bits(bb, sb, "W")
    N, D = ba.shape
    M = bb.shape[0]
    if cols is not None and len(cols) != D:
        raise ValueError(f"cols must give one original channel per column ({D}), got {len(cols)}")
    state = dict(blocks=0, cols=0) if state is None else state
    blocks = block_schedule(D, slice_len)
    n_slices = blocks[-1][0] + 1
    Lm = _row_lengths(L, N, n_slices)
    acc = np.zeros((n_slices, N, M), np.int64)
    for call_blk, (s, j, lo, hi, p, last) in enumerate(blocks):
        w = hi - lo
        aB = np.zeros((N, LANES), np.int64); aB[:, :w] = ba[:, lo:hi]
        aN = np.zeros((N, LANES), bool); aN[:, :w] = aNeg[:, lo:hi]
        wB = np.zeros((LANES, M), np.int64); wB[:w] = bb[:, lo:hi].T
        wN = np.zeros((LANES, M), bool); wN[:w] = wNeg[:, lo:hi].T
        masks = _block_masks(fault, p, lo, w, state, call_blk, cols)
        state["blocks"] += 1
        cyc, kas = [], []
        for g in range(0, N, TILE_R):                  # tile rows; all tile columns share the row group's cycles
            rows = slice(g, min(g + TILE_R, N))
            Lr = Lm[rows, s]
            C = L_MAX // POS if full_cycles else int(-(-Lr.max() // POS))
            blk, kA = block_fn(aB[rows], aN[rows], wB, wN, Lr, masks, C, fault)
            acc[s, rows] += blk
            cyc.append(C)
            kas.append(kA)
        if trace is not None:
            trace.append(dict(call=call, call_blk=call_blk, slice=s, blk=j, lo=lo, hi=hi, s_lo=lo - LANES * j,
                              phase=p, last=last, slice_start=(j == 0), call_start=(call_blk == 0),
                              L=Lm[:, s].copy(), cycles=cyc,
                              kA=None if kas[0] is None else np.concatenate(kas), acc=acc[s].copy()))
    state["cols"] += D
    return acc


def hw_rg_acc(ba, sa, bb, sb, L, slice_len=0, **kw):
    """Design RG over the whole reduction axis.  Returns (n_slices, N, M) per-slice (per-drain) accumulators."""
    return _hw_acc(_rg_block, ba, sa, bb, sb, L, slice_len, **kw)


def hw_af_acc(ba, sa, bb, sb, L, slice_len=0, **kw):
    """Design AF over the whole reduction axis.  Returns (n_slices, N, M)."""
    return _hw_acc(_af_block, ba, sa, bb, sb, L, slice_len, **kw)


def hw_calls_acc(design, calls, fault=None, **kw):
    """Several calls back to back on ONE hardware instance with no reset in between, as deployed: consecutive
    (B, H) attention calls, or the unprotected and the protected call of one linear.  Every call is
    dict(ba, sa, bb, sb, L, slice_len=0, cols=None); cols = original input-channel index of each column of a
    gathered call.  Correct hardware carries no mask state across calls (its phase register resets at every
    slice start, hence at every call start); the mask faults carry the phase / d count over.
    Returns one (n_slices, N, M) array per call."""
    fn = _rg_block if design == "rg" else _af_block
    state = dict(blocks=0, cols=0)
    return [_hw_acc(fn, c["ba"], c["sa"], c["bb"], c["sb"], c["L"], c.get("slice_len", 0), fault=fault,
                    state=state, cols=c.get("cols"), call=ci, **kw) for ci, c in enumerate(calls)]


def hw_acc_batched(design, ba, sa, bb, sb, L, **kw):
    """3D (per-head / per-row-3D): every head is its own slice (phase restarts, own drain).  The heads run on one
    instance, so the mask faults carry their state from head to head."""
    fn = hw_rg_acc if design == "rg" else hw_af_acc
    kw.setdefault("state", dict(blocks=0, cols=0))
    return np.stack([fn(ba[h], sa[h], bb[h], sb[h], L, 0, **kw)[0] for h in range(ba.shape[0])])


# =====================================================================================================
# Trace settings
# =====================================================================================================

FALLBACK_LADDERS = {
    "14B/target48 levels+esc+prot (fallback)": [128, 112, 96, 64, 48, 44, 42, 38],
    "4B/target32 levels+esc+prot (fallback)": [128, 97, 84, 64, 48, 32, 25, 18],
}


def trace_ladders():
    """Distinct stream-length sets in deployment, read from the trace archive (read-only):
      mp_best/configs/<model>/<target>/metadata.json  levels + escape_stoc_len + protected_stoc_len
      mp_best/{mp,uniform}/*_trace.json, *_trace.json  per-op sets of group stoc_len."""
    found = {}
    for meta in sorted(glob.glob(str(TRACE_ROOT / "mp_best" / "configs" / "*" / "target*" / "metadata.json"))):
        m = json.loads(Path(meta).read_text())
        s = set(m.get("levels") or [])
        for key in ("escape_stoc_len", "protected_stoc_len"):
            if m.get(key):
                s.add(int(m[key]))
        if s:
            found.setdefault(tuple(sorted(s, reverse=True)), f"{Path(meta).parent.relative_to(TRACE_ROOT)} levels+esc+prot")
    for tr in _trace_files():
        d = json.loads(Path(tr).read_text())
        per_op = {}
        for g in d.get("groups", []):
            per_op.setdefault(g["op"], set()).add(int(g["stoc_len"]))
        for op, s in per_op.items():
            if len(s) > 1:
                found.setdefault(tuple(sorted(s, reverse=True)), f"{Path(tr).relative_to(TRACE_ROOT)}:{op}")
    if not found:
        return {k: v for k, v in FALLBACK_LADDERS.items()}
    return {name: list(lad) for lad, name in found.items()}


def _trace_files():
    return sorted(glob.glob(str(TRACE_ROOT / "mp_best" / "*" / "*_trace.json")) + glob.glob(str(TRACE_ROOT / "*_trace.json")))


def trace_call_shapes():
    """Deployed call shapes, from every trace group's (chunk_d, d_in) (d_in is the call's reduction length, after any
    protected-channel gather).  Per chunk_d: all d_in; those whose block count is not a multiple of 8 (the phase
    register ends the call at a non-zero value, so a phase carried into the next call is wrong); those whose last
    block is padded (slice tail not a multiple of 8)."""
    dins = {}
    for tr in _trace_files():
        for g in json.loads(Path(tr).read_text()).get("groups", []):
            dins.setdefault(int(g.get("chunk_d") or 0), set()).add(int(g["d_in"]))
    out = {}
    for cd, s in sorted(dins.items()):
        s = sorted(s)
        sched = {D: block_schedule(D, cd) for D in s}
        out[cd] = dict(d_in=s, odd_blocks=[D for D in s if len(sched[D]) % 8],
                       padded=[D for D in s if sched[D][-1][3] - sched[D][-1][2] < LANES])
    return out


# =====================================================================================================
# Self-test
# =====================================================================================================

class Log:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.f = self.path.open("w")

    def __call__(self, msg=""):
        print(msg, flush=True)
        self.f.write(msg + "\n")
        self.f.flush()


def gen_operands(rng, rows, D, mags="mixed"):
    """Magnitudes 0..128 (mixed: uniform plus a share of the extremes 0, 1, 63, 64, 65, 127, 128), random
    +/-1 signs; zeros get sign 0 or +1 at random (the two kernel quantizer conventions)."""
    if mags == "extreme":
        b = rng.choice(np.array([0, 1, 127, 128]), size=(rows, D))
    elif mags == "uniform":
        b = rng.integers(0, GRID + 1, size=(rows, D))
    else:
        b = rng.integers(0, GRID + 1, size=(rows, D))
        pick = rng.random((rows, D)) < 0.3
        b[pick] = rng.choice(np.array([0, 1, 63, 64, 65, 127, 128]), size=int(pick.sum()))
    s = rng.choice(np.array([-1, 1]), size=(rows, D))
    zero = b == 0
    s[zero] = rng.choice(np.array([0, 1]), size=int(zero.sum()))
    return b.astype(np.int16), s.astype(np.int8)


class Tally:
    def __init__(self, log):
        self.log = log
        self.paths = {}
        self.bad = []

    def add(self, path, name, ref, rg, af, macs):
        rec = self.paths.setdefault(path, dict(cases=0, macs=0, rg_bad=0, af_bad=0))
        rec["cases"] += 1
        rec["macs"] += int(macs)
        nrg = int(np.count_nonzero(ref != rg))
        naf = int(np.count_nonzero(ref != af))
        rec["rg_bad"] += nrg
        rec["af_bad"] += naf
        if nrg or naf:
            self.bad.append((path, name, nrg, naf))
            self.log(f"  MISMATCH {path} {name}: RG {nrg}, AF {naf} of {ref.size} accumulators")

    def check(self, name, ok, detail=""):
        self.log(f"  [{'PASS' if ok else 'FAIL'}] {name} {detail}")
        if not ok:
            self.bad.append(("check", name, 0, 0))


def _ladder_rows(rng, ladder, N):
    """Every ladder value at least once, the rest random."""
    lad = np.array(ladder)
    L = rng.choice(lad, size=N)
    L[: min(N, len(lad))] = lad[: min(N, len(lad))]
    rng.shuffle(L)
    return L


def selftest(log_path, quick=False):
    t0 = time.time()
    log = Log(log_path)
    rng = np.random.default_rng(20261004)
    T = Tally(log)
    log(f"cbsg_ref self-test  kernel={KERNEL_ROOT} (ce3d7e5 expected)  traces={TRACE_ROOT}")
    log(f"arithmetic: sc_prec={SC_PREC} halve grid={GRID} masks=bitrev8(d mod {N_MASKS_DEFAULT}) "
        f"block={LANES} lanes x {POS} positions")

    # ---------------- T0 primitives ----------------
    log("\n[T0] primitives")
    q, k = _base_sequences()
    T.check("q bank (sample order, H(c)^LANE(m)) == rng.py Sobol q[0:128]", np.array_equal(XQ_BANK.reshape(-1), q[:L_MAX]))
    T.check("k bank (sample order, H(c)^LANE(m)) == rng.py Sobol k[0:128]", np.array_equal(XK_BANK.reshape(-1), k[:L_MAX]))
    T.check("k index generator (gray code) == rng.py Sobol k[0:256]", np.array_equal(XK_GRAY, k))
    d = np.arange(4096)
    kmask = _bit_reverse(d % 64, 8)
    T.check("mask split: hw_mask(k = d%8, p = (d//8)%8) == bitrev8(d mod 64), d < 4096",
            np.array_equal(hw_mask(d % 8, (d // 8) % 8), kmask))
    owen = _owen_scramble(np.zeros((4096, 1), np.int64), BASE)[:, 0]
    T.check("kernel _owen_scramble mask row d == bitrev8(d mod 64)", np.array_equal(owen, kmask))
    # kA closed form vs the kernel k_table, every L, every mask, every magnitude
    bad = 0
    for L in range(1, L_MAX + 1):
        kt = build_k_table_only(64, L)[:, : GRID + 1]               # (64 masks, 129)
        hw = ka_closed(np.arange(GRID + 1)[None, :], L, BR8[np.arange(64)][:, None])
        bad += int(np.count_nonzero(kt != hw))
    T.check("closed-form kA == kernel k_table (L 1..128 x 64 masks x b 0..128 = 1,056,768)", bad == 0, f"{bad} bad")
    rb = rng_b_prefix_for(64, L_MAX)                                # (64, 128) kernel rB prefix
    hwb = (XK_BANK.reshape(-1)[None, :] ^ HW_MASK[np.arange(64) % 8, np.arange(64) // 8][:, None]) >> 1
    T.check("hw W sample (bank ^ hw_mask) >> 1 == kernel rB prefix (64 masks x 128 t)", np.array_equal(rb, hwb))
    ra = _prepare_rng_prefix(kernel_sequences(64)[0], SC_PREC, L_MAX, GRID)
    hwa = (XQ_BANK.reshape(-1)[None, :] ^ HW_MASK[np.arange(64) % 8, np.arange(64) // 8][:, None]) >> 1
    T.check("hw A sample (bank ^ hw_mask) >> 1 == kernel rA prefix (64 masks x 128 t)", np.array_equal(ra, hwa))
    # prefix nesting the per-row path relies on: cum at L is the first L+1 rows of cum at 128
    cum128 = build_enable_tables(64, L_MAX)[0]
    nest = all(np.array_equal(build_enable_tables(64, L)[0], cum128[:, : L + 1]) for L in (1, 18, 25, 38, 64, 97, 127))
    T.check("cum table at L == first L+1 rows of the L=128 table (prefix nesting)", nest)

    def run(path, name, ref, ba, sa, bb, sb, L, slice_len=0):
        rg = hw_rg_acc(ba, sa, bb, sb, L, slice_len)
        af = hw_af_acc(ba, sa, bb, sb, L, slice_len)
        T.add(path, name, ref, rg, af, ba.shape[0] * bb.shape[0] * ba.shape[1])
        return rg, af

    Ls = range(1, L_MAX + 1) if not quick else (1, 2, 15, 16, 17, 18, 25, 31, 33, 64, 84, 97, 127, 128)

    # ---------------- T1 plain, uniform L ----------------
    log("\n[T1] plain path, uniform L = every value in 1..128, D alternating 200 / 203 (not a multiple of 8 or 64)")
    for L in Ls:
        D = 200 if L % 2 else 203
        N, M = 16, 16
        ba, sa = gen_operands(rng, N, D, "extreme" if L % 7 == 0 else "mixed")
        bb, sb = gen_operands(rng, M, D, "extreme" if L % 11 == 0 else "mixed")
        ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
        run("plain", f"L={L} D={D}", ref, ba, sa, bb, sb, L)
    log(f"  plain uniform: {T.paths['plain']}")

    # ---------------- T2 plain, per-row ladders ----------------
    ladders = trace_ladders()
    log(f"\n[T2] plain path (chunk_d = 0: attention qk/av), per-row L from {len(ladders)} distinct trace ladders")
    for name, lad in sorted(ladders.items()):
        log(f"    ladder {lad}  <- {name}")
    lad_items = sorted(ladders.items())
    for i, (name, lad) in enumerate(lad_items):
        D = (128, 257, 136)[i % 3]                                  # qk head_dim, ViT av (257 = 32 blocks + 1 lane), 17 blocks
        N, M = 24, 8
        L = _ladder_rows(rng, lad, N)
        ba, sa = gen_operands(rng, N, D)
        bb, sb = gen_operands(rng, M, D)
        ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
        run("plain_perrow", f"{name} D={D}", ref, ba, sa, bb, sb, L)
        ks = kernel_acc_plain_kstack(ba, sa, bb, sb, L)
        ks2 = kernel_acc_plain_kstack(ba, sa, bb, sb, L, stoc_len=int(max(lad)))
        if not (np.array_equal(ks, ref[0]) and np.array_equal(ks2, ref[0])):
            T.check(f"row-split == PER_ROW_LEN k-stack ({name})", False)
    # random per-row L (every row its own length) and one long av-like call
    for D, N, M in ((72, 32, 8), (2048, 16, 32) if not quick else (512, 16, 16)):
        L = rng.integers(1, L_MAX + 1, size=N)
        L[:4] = (1, 16, 17, 128)
        ba, sa = gen_operands(rng, N, D)
        bb, sb = gen_operands(rng, M, D)
        ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
        run("plain_perrow", f"random L D={D}", ref, ba, sa, bb, sb, L)
        T.check(f"row-split == PER_ROW_LEN k-stack (random L, D={D})",
                np.array_equal(kernel_acc_plain_kstack(ba, sa, bb, sb, L), ref[0]))
    log(f"  plain per-row: {T.paths['plain_perrow']}")

    # ---------------- T3 chunked ----------------
    log("\n[T3] chunked path (MLP), mask index restarts per chunk, short last chunk, per-(row, chunk) rungs")
    for L in Ls:                                                    # uniform L sweep, non-multiple-of-64 chunks
        chunk_d, D = ((96, 296), (100, 330), (128, 440))[L % 3]
        N, M = 8, 8
        ba, sa = gen_operands(rng, N, D, "extreme" if L % 5 == 0 else "mixed")
        bb, sb = gen_operands(rng, M, D)
        ref = kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=L)
        run("chunked", f"uniform L={L} chunk_d={chunk_d} D={D}", ref, ba, sa, bb, sb, L, chunk_d)
    for i, (name, lad) in enumerate(lad_items):                     # rung tables per (row, chunk)
        chunk_d, D = ((128, 440), (128, 584), (96, 296), (100, 330))[i % 4]   # 440 = 3x128 + 56, 584 = 4x128 + 72
        N, M = 16, 8
        nch = -(-D // chunk_d)
        rung = rng.integers(0, len(lad), size=(N, nch))
        rung.reshape(-1)[: len(lad)] = np.arange(len(lad))
        ba, sa = gen_operands(rng, N, D)
        bb, sb = gen_operands(rng, M, D)
        stoc = L_MAX if i % 2 == 0 else int(max(lad))
        ref = kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=stoc, rung_table=rung, level_lens=lad)
        Lrc = np.asarray(lad)[rung]
        run("chunked", f"rungs {name} chunk_d={chunk_d} D={D} stoc_len={stoc}", ref, ba, sa, bb, sb, Lrc, chunk_d)
    # per-row L via row-subset calls (scmp_llm SCLinear) == rung table constant along the chunks
    nrs = 0
    for i, (name, lad) in enumerate(lad_items[:: max(1, len(lad_items) // 12)]):
        chunk_d, D, N = 128, 440, 16
        L = _ladder_rows(rng, lad, N)
        ba, sa = gen_operands(rng, N, D)
        bb, sb = gen_operands(rng, 8, D)
        lens = sorted(set(int(v) for v in L))
        rung = np.repeat(np.array([lens.index(int(v)) for v in L])[:, None], -(-D // chunk_d), axis=1)
        a1 = kernel_acc_chunked_rowsplit(ba, sa, bb, sb, chunk_d, L)
        a2 = kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=L_MAX, rung_table=rung, level_lens=lens)
        nrs += int(np.count_nonzero(a1 != a2))
        run("chunked", f"row-split {name}", a1, ba, sa, bb, sb, L, chunk_d)
    T.check("chunked: row-subset calls at stoc_len=L == one rung-table call (rung constant per row)", nrs == 0, f"{nrs} bad")
    # protected-channel split (table.json protected_channels): host gathers the protected input channels
    # into their own call at protected_stoc_len; the rest run with the rung table.  Two independent calls.
    D, chunk_d, N, M = 1000, 128, 16, 8
    prot = np.sort(rng.choice(D, size=60, replace=False))
    rest = np.setdiff1d(np.arange(D), prot)
    ba, sa = gen_operands(rng, N, D)
    bb, sb = gen_operands(rng, M, D)
    lad = [97, 64, 48, 32, 25, 18, 128]
    nch = -(-len(rest) // chunk_d)
    rung = rng.integers(0, len(lad), size=(N, nch))
    for cols, kw, Lh, nm in ((prot, dict(stoc_len=84), 84, "protected 60 ch @84 (D<=chunk_d: standard path)"),
                             (rest, dict(stoc_len=L_MAX, rung_table=rung, level_lens=lad), np.asarray(lad)[rung],
                              "unprotected 940 ch, rungs")):
        ref = kernel_acc_chunked(ba[:, cols], sa[:, cols], bb[:, cols], sb[:, cols], chunk_d, **kw)
        run("chunked", nm, ref, ba[:, cols], sa[:, cols], bb[:, cols], sb[:, cols], Lh, chunk_d)
    # D <= chunk_d: standard path == plain
    ba, sa = gen_operands(rng, 8, 100)
    bb, sb = gen_operands(rng, 8, 100)
    T.check("chunked with D <= chunk_d == plain path", np.array_equal(
        kernel_acc_chunked(ba, sa, bb, sb, 128, stoc_len=64)[0], kernel_acc_plain(ba, sa, bb, sb, 64)))
    log(f"  chunked: {T.paths['chunked']}")

    # ---------------- T4 batched (per-head / per-row 3D) ----------------
    log("\n[T4] batched path (per_head, per_row 3D): D = 64 / 128 per head, uniform L = every value in 1..128")
    for L in Ls:
        D = 64 if L % 2 else 128
        BH, N, M = 3, 8, 8
        ops = [gen_operands(rng, N, D, "extreme" if L % 9 == 0 else "mixed") for _ in range(BH)]
        opw = [gen_operands(rng, M, D) for _ in range(BH)]
        ba = np.stack([o[0] for o in ops]); sa = np.stack([o[1] for o in ops])
        bb = np.stack([o[0] for o in opw]); sb = np.stack([o[1] for o in opw])
        ref = kernel_acc_batched(ba, sa, bb, sb, L)
        rg = hw_acc_batched("rg", ba, sa, bb, sb, L)
        af = hw_acc_batched("af", ba, sa, bb, sb, L)
        T.add("batched", f"L={L} D={D} BH={BH}", ref, rg, af, BH * N * M * D)
    log(f"  batched: {T.paths['batched']}")

    # ---------------- T5 from_float end to end ----------------
    log("\n[T5] from_float -> kernel == RG == AF (operand contract from the kernel quantizers)")
    for path in ("per_row", "per_row_3d", "chunked", "per_head", "per_tensor"):
        if path in ("per_row_3d", "per_head"):
            xa = (rng.standard_normal((2, 8, 128)) * rng.choice([0.01, 1, 30], size=(2, 8, 1))).astype(np.float32)
            xb = rng.standard_normal((2, 8, 128)).astype(np.float32)
            xa[0, 0, :5] = 0.0
            ba, sa, _ = from_float(xa, path)
            bb, sb, _ = from_float(xb, path)
            ref = kernel_acc_batched(ba, sa, bb, sb, 97)
            rg = hw_acc_batched("rg", ba, sa, bb, sb, 97)
            af = hw_acc_batched("af", ba, sa, bb, sb, 97)
            macs = ba.size * bb.shape[1]
        else:
            xa = (rng.standard_normal((16, 300)) * rng.choice([0.01, 1, 30], size=(16, 1))).astype(np.float32)
            xb = rng.standard_normal((8, 300)).astype(np.float32)
            xa[0, :7] = 0.0
            cd = 128 if path == "chunked" else 0
            ba, sa, _ = from_float(xa, path, cd)
            bb, sb, _ = from_float(xb, path, cd)
            ref = (kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=64) if path == "chunked"
                   else kernel_acc_plain(ba, sa, bb, sb, 64)[None])
            rg = hw_rg_acc(ba, sa, bb, sb, 64, cd)
            af = hw_af_acc(ba, sa, bb, sb, 64, cd)
            macs = ba.size * bb.shape[0]
        vals = np.unique(np.concatenate([ba.ravel(), bb.ravel()]))
        contract = (vals.min() >= 0 and vals.max() <= GRID and 64 not in vals
                    and not np.any((sa == 0) & (ba != 0)) and not np.any((sb == 0) & (bb != 0)))
        T.check(f"from_float({path}): b in 0..128 without 64, sign 0 only at b = 0", bool(contract))
        T.add("from_float", path, ref, rg, af, macs)
    # small gathered linear call (trace d_in 77 at chunk_d 128): D <= chunk_d takes the standard path, whose
    # quantizer is the grouped one (kernels.py:1840, 1477-1500), not the fused per-row one
    xa = (rng.standard_normal((16, 77)) * rng.choice([0.01, 1, 30], size=(16, 1))).astype(np.float32)
    xb = rng.standard_normal((8, 77)).astype(np.float32)
    ba, sa, sca = from_float(xa, "chunked", 128)
    bb, sb, _ = from_float(xb, "chunked", 128)
    bp, sp, scp = from_float(xa, "per_row")
    T.check("from_float(chunked, 128) at D = 77 (standard path) == grouped per_row quantizer, scale (rows, 1)",
            np.array_equal(ba, bp) and np.array_equal(sa, sp) and sca.shape == (16, 1) and np.array_equal(sca[:, 0], scp))
    ref = kernel_acc_chunked(ba, sa, bb, sb, 128, stoc_len=84)
    T.add("from_float", "chunked D=77 <= chunk_d (standard path)", ref,
          hw_rg_acc(ba, sa, bb, sb, 84, 128), hw_af_acc(ba, sa, bb, sb, 84, 128), ba.size * bb.shape[0])

    # ---------------- T6 invariances + independent reference ----------------
    log("\n[T6] invariances and independent reference")
    ba, sa = gen_operands(rng, 16, 136)
    bb, sb = gen_operands(rng, 8, 136)
    L = _ladder_rows(rng, [128, 97, 64, 33, 18, 1], 16)
    ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
    T.check("RG with all 8 cycles every block == RG with ceil(max L/16) cycles",
            np.array_equal(hw_rg_acc(ba, sa, bb, sb, L, full_cycles=True), ref))
    T.check("AF with all 8 cycles every block == kernel",
            np.array_equal(hw_af_acc(ba, sa, bb, sb, L, full_cycles=True), ref))
    cosim = SOREN_PAYN / "designs" / "payn" / "cosim" / "cosim_streaming.py"
    if cosim.exists():
        spec = importlib.util.spec_from_file_location("_soren_cosim_streaming", cosim)
        cs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cs)
        nb = 0
        for L in (128, 97, 64, 43, 16, 1):
            D = 136
            ba, sa = gen_operands(rng, 8, D)
            bb, sb = gen_operands(rng, 8, D)
            batches = [dict(d_base=lo, AMAG=ba[:, lo:lo + 8].astype(np.int64), ASIGN=(sa[:, lo:lo + 8] < 0).astype(np.int64),
                            WMAG=bb[:, lo:lo + 8].astype(np.int64), WSIGN=(sb[:, lo:lo + 8] < 0).astype(np.int64))
                       for lo in range(0, D, 8)]
            soren = cs.reference(dict(K=8, NH=8, NW=8, OWIDTH=40, T=L), batches)
            nb += int(np.count_nonzero(soren != kernel_acc_plain(ba, sa, bb, sb, L)))
        T.check("soren cosim_streaming.reference (independent numpy C-BSG) == kernel_acc_plain, 6 lengths", nb == 0, f"{nb} bad")
    else:
        log(f"  (skip: {cosim} not found)")

    # ---------------- T7 sensitivity (each fault must be caught) ----------------
    log("\n[T7] sensitivity: injected faults must produce mismatches")
    ba, sa = gen_operands(rng, 8, 296)
    bb, sb = gen_operands(rng, 8, 296)
    ref = kernel_acc_chunked(ba, sa, bb, sb, 96, stoc_len=97)
    for design, fn in (("RG", hw_rg_acc), ("AF", hw_af_acc)):
        for fault in ("call_d", "no_slice_reset", "global_mask", "no_phase_reset"):
            n = int(np.count_nonzero(fn(ba, sa, bb, sb, 97, 96, fault=fault) != ref))
            T.check(f"{design} fault {fault} (one call, chunk_d=96, L=97) detected", n > 0, f"({n} accumulators differ)")
    ba, sa = gen_operands(rng, 8, 128)
    bb, sb = gen_operands(rng, 8, 128)
    L = np.array([97, 64, 33, 18, 128, 100, 5, 49])
    ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
    for nm, fn, fault in (("RG W index = t (ungated W)", hw_rg_acc, "rg_w_by_t"),
                          ("RG without the t < L gate", hw_rg_acc, "no_len_gate"),
                          ("AF with kA = min(bA, L)", hw_af_acc, "af_ka_eq_b")):
        n = int(np.count_nonzero(fn(ba, sa, bb, sb, L, full_cycles=(fault == "no_len_gate"), fault=fault) != ref))
        T.check(f"fault {nm} detected", n > 0, f"({n} accumulators differ)")

    # ---------------- T8 calls back to back (mask state across calls) ----------------
    log("\n[T8] calls back to back on one instance, no reset in between: where the scrambling-mask issue bites")
    for fault, what in MASK_FAULTS.items():
        log(f"    {fault:15s} {what}")
    for cd, rec in trace_call_shapes().items():
        log(f"  traces, chunk_d={cd}: {len(rec['d_in'])} distinct d_in; block count not a multiple of 8 "
            f"(phase ends != 0): {rec['odd_blocks']}; last block padded: {rec['padded']}")

    def seq_check(name, calls, refs, caught):
        """kernel == RG == AF on the sequence; then every mask fault: those in `caught` must leave accumulators
        wrong in both designs, every other one must leave none wrong (pins where the issue does NOT bite)."""
        tot = sum(r.size for r in refs)
        macs = sum(c["ba"].shape[0] * c["bb"].shape[0] * c["ba"].shape[1] for c in calls)
        flat = lambda xs: np.concatenate([x.reshape(-1) for x in xs])
        T.add("calls", name, flat(refs), flat(hw_calls_acc("rg", calls)), flat(hw_calls_acc("af", calls)), macs)
        for fault in MASK_FAULTS:
            n = [sum(int(np.count_nonzero(o != r)) for o, r in zip(hw_calls_acc(d, calls, fault=fault), refs))
                 for d in ("rg", "af")]
            want = fault in caught
            T.check(f"{name}: {fault} {'caught' if want else 'harmless'}", (min(n) > 0) if want else (max(n) == 0),
                    f"(RG {n[0]}, AF {n[1]} of {tot} wrong)")

    def call(ba, sa, bb, sb, cols, L, slice_len):
        return dict(ba=ba[:, cols], sa=sa[:, cols], bb=bb[:, cols], sb=sb[:, cols], L=L, slice_len=slice_len, cols=cols)

    # (1) one deployed chunk_d = 128 call with a padded tail, from reset: no mask fault is visible
    D, lad = 3973, [97, 64, 48, 32, 25, 18, 128]                    # trace d_in 3973 = 31 x 128 + 5
    ba, sa = gen_operands(rng, 8, D)
    bb, sb = gen_operands(rng, 8, D)
    rung = rng.integers(0, len(lad), size=(8, -(-D // 128)))
    ref = kernel_acc_chunked(ba, sa, bb, sb, 128, stoc_len=L_MAX, rung_table=rung, level_lens=lad)
    seq_check("one call chunk_d=128 D=3973 (tail 5)", [call(ba, sa, bb, sb, np.arange(D), np.asarray(lad)[rung], 128)],
              [ref], caught=())
    # (2, 3) 4B down_proj protected split (mp_best/mp/4B_t32_awq_trace.json: d_in 9144 @ rungs + 584 @ L = 84 = 9728),
    # gathered from scattered channels; both orders
    D0 = 9728
    ba, sa = gen_operands(rng, 8, D0)
    bb, sb = gen_operands(rng, 8, D0)
    prot = np.sort(rng.choice(D0, size=584, replace=False))
    rest = np.setdiff1d(np.arange(D0), prot)
    rung = rng.integers(0, len(lad), size=(8, -(-len(rest) // 128)))
    cu = call(ba, sa, bb, sb, rest, np.asarray(lad)[rung], 128)
    cp = call(ba, sa, bb, sb, prot, 84, 128)
    ru = kernel_acc_chunked(cu["ba"], cu["sa"], cu["bb"], cu["sb"], 128, stoc_len=L_MAX, rung_table=rung, level_lens=lad)
    rp = kernel_acc_chunked(cp["ba"], cp["sa"], cp["bb"], cp["sb"], 128, stoc_len=84)
    gathered = ("global_mask", "no_phase_reset", "orig_channel_d")
    seq_check("unprotected 9144 (1143 blocks) then protected 584", [cu, cp], [ru, rp], caught=gathered)
    seq_check("protected 584 (73 blocks) then unprotected 9144", [cp, cu], [rp, ru], caught=gathered)
    # (4) ViT av (r64_amax_s41_trace.json: chunk_d 0, d_in 257): consecutive (B, H) calls, per-row L
    calls, refs = [], []
    for _ in range(3):
        ba, sa = gen_operands(rng, 8, 257)
        bb, sb = gen_operands(rng, 8, 257)
        L = _ladder_rows(rng, [128, 97, 64, 48, 32], 8)
        calls.append(call(ba, sa, bb, sb, np.arange(257), L, 0))
        refs.append(kernel_acc_plain(ba, sa, bb, sb, L)[None])
    seq_check("ViT av: 3 consecutive calls at D=257 (33 blocks each)", calls, refs, caught=("global_mask", "no_phase_reset"))
    # (5) ViT qk per_head (d_in 64): heads back to back; 8 blocks per head, so nothing carries over
    ops = [gen_operands(rng, 8, 64) for _ in range(6)]
    ba = np.stack([o[0] for o in ops[:3]]); sa = np.stack([o[1] for o in ops[:3]])
    bb = np.stack([o[0] for o in ops[3:]]); sb = np.stack([o[1] for o in ops[3:]])
    ref = kernel_acc_batched(ba, sa, bb, sb, 64)
    seq_check("ViT qk per_head: 3 heads at D=64", [call(ba[h], sa[h], bb[h], sb[h], np.arange(64), 64, 0) for h in range(3)],
              [ref[h][None] for h in range(3)], caught=())
    log(f"  calls: {T.paths['calls']}")

    # ---------------- summary ----------------
    log("\n[summary] kernel == RG == AF, MACs = rows x cols x D summed over cases")
    tot = 0
    for path, rec in T.paths.items():
        tot += rec["macs"]
        log(f"  {path:13s} cases {rec['cases']:4d}  MACs {rec['macs']:>11,}  RG mismatches {rec['rg_bad']}  "
            f"AF mismatches {rec['af_bad']}")
    log(f"  total MACs {tot:,}   failures {len(T.bad)}   {time.time() - t0:.1f} s")
    log("RESULT: " + ("PASS" if not T.bad else f"FAIL {T.bad[:10]}"))
    return 0 if not T.bad else 1


# =====================================================================================================
# Golden vectors for a SystemVerilog bench (one 8 x 8 tile)
# =====================================================================================================

_SLICE_FAULTS = ("call_d", "no_slice_reset", "global_mask", "no_phase_reset")   # all bite when slices are not 64-aligned
_LAD_4B = [128, 97, 84, 64, 48, 32, 25, 18]                                      # 4B target32 levels + escape + protected

CASES = {
    "plain_u128":    dict(path="plain", D=64, L=128, doc="plain, uniform L=128, 8 blocks (all 8 phases)"),
    "plain_u97":     dict(path="plain", D=136, L=97, doc="plain, uniform L=97, 17 blocks (phase wraps)"),
    "plain_ladder":  dict(path="plain", D=133, ladder=[128, 96, 64, 48, 44, 42, 38],
                          doc="plain per-row L (14B target48 ladder), D=133: last block has 5 lanes"),
    "plain_extreme": dict(path="plain", D=72, Lrows=[128, 1, 2, 16, 17, 97, 64, 127], mags="extreme",
                          doc="magnitudes only 0/1/127/128, per-row L incl. 1 and 17"),
    "chunked_rung":  dict(path="chunked", D=312, chunk_d=128, ladder=_LAD_4B,
                          doc="chunk_d=128, D=312 (2 full + 56-column tail), per-(row, chunk) rungs (4B target32 + esc + prot)"),
    "chunked_tail5": dict(path="chunked", D=261, chunk_d=128, ladder=_LAD_4B,
                          doc="chunk_d=128, D=261 (2 full + 5-column tail, like trace d_in 3973 = 31x128 + 5): "
                              "padded last block at the deployed chunk_d, per-(row, chunk) rungs"),
    "chunked_96":    dict(path="chunked", D=200, chunk_d=96, ladder=[128, 96, 64, 48, 32, 24, 16], catches=_SLICE_FAULTS,
                          doc="chunk_d=96 (not a multiple of 64), D=200 (tail of 8), per-(row, chunk) rungs"),
    "chunked_100":   dict(path="chunked", D=230, chunk_d=100, L=64, catches=_SLICE_FAULTS,
                          doc="chunk_d=100 (not a multiple of 8): every chunk ends in a padded block"),
    "perhead_64":    dict(path="perhead", BH=2, D=64, L=48, doc="per-head, 2 heads x D=64, L=48: one drain per head"),
    "perhead_128":   dict(path="perhead", BH=2, D=128, L=128, doc="per-head, 2 heads x D=128 (mask repeats at d+64)"),
    "calls_prot":    dict(path="calls_prot", D=600, n_prot=139, prot_L=84, chunk_d=128, ladder=_LAD_4B,
                          catches=("global_mask", "no_phase_reset", "orig_channel_d"),
                          doc="2 calls, no reset between: unprotected 461 gathered channels (3x128 + 77 = 58 blocks, so a "
                              "free-running phase enters the next call at 2) with rungs, then protected 139 scattered "
                              "channels (128 + 11) at L=84"),
    "calls_av257":   dict(path="calls_av", D=257, n_calls=2, ladder=[128, 97, 64, 48, 32],
                          catches=("global_mask", "no_phase_reset"),
                          doc="2 consecutive attention calls at D=257 (ViT av: 33 blocks each), per-row L, no reset between"),
}

# DUT phase-reset policies check_golden can apply from the .mem files alone, and the fault each one is
PHASE_POLICIES = {"call": "no_slice_reset", "free": "no_phase_reset"}


def _write_mem(path, values, digits, header):
    lines = [f"// {header}"]
    mask = (1 << (4 * digits)) - 1
    lines += [f"{int(v) & mask:0{digits}x}" for v in np.asarray(values).reshape(-1)]
    Path(path).write_text("\n".join(lines) + "\n")


def build_case(name, seed=1):
    """One 8x8-tile golden case as a list of calls run back to back on one instance (no reset in between).
    Every call is dict(ba, sa, bb, sb (8, D), L (8, n_slices), slice_len, cols (original input channel of each
    column of a gathered call, or None), exp (n_slices, 8, 8) kernel accumulators, one per drain)."""
    spec = CASES[name]
    rng = np.random.default_rng(seed + sum(map(ord, name)))
    R = C = TILE_R
    mags = spec.get("mags", "mixed")
    if spec["path"] == "perhead":                   # one call; heads concatenated along D, one slice per head
        BH, D = spec["BH"], spec["D"]
        ops = [gen_operands(rng, R, D, mags) for _ in range(BH)]
        opw = [gen_operands(rng, C, D, mags) for _ in range(BH)]
        ba = np.stack([o[0] for o in ops]); sa = np.stack([o[1] for o in ops])
        bb = np.stack([o[0] for o in opw]); sb = np.stack([o[1] for o in opw])
        exp = kernel_acc_batched(ba, sa, bb, sb, spec["L"])
        cat = lambda x: np.concatenate(list(x), axis=1)
        return spec, [dict(ba=cat(ba), sa=cat(sa), bb=cat(bb), sb=cat(sb), L=np.full((R, BH), spec["L"]),
                           slice_len=D, cols=None, exp=exp)]
    if spec["path"] == "calls_av":                  # consecutive plain (attention) calls
        calls = []
        for _ in range(spec["n_calls"]):
            ba, sa = gen_operands(rng, R, spec["D"], mags)
            bb, sb = gen_operands(rng, C, spec["D"], mags)
            L = _ladder_rows(rng, spec["ladder"], R)
            calls.append(dict(ba=ba, sa=sa, bb=bb, sb=sb, L=L[:, None], slice_len=0, cols=None,
                              exp=kernel_acc_plain(ba, sa, bb, sb, L)[None]))
        return spec, calls
    D = spec["D"]
    ba, sa = gen_operands(rng, R, D, mags)
    bb, sb = gen_operands(rng, C, D, mags)
    if spec["path"] == "plain":
        if "ladder" in spec:
            L = _ladder_rows(rng, spec["ladder"], R)
        elif "Lrows" in spec:
            L = np.array(spec["Lrows"])
        else:
            L = np.full(R, spec["L"])
        return spec, [dict(ba=ba, sa=sa, bb=bb, sb=sb, L=L[:, None], slice_len=0, cols=None,
                           exp=kernel_acc_plain(ba, sa, bb, sb, L)[None])]
    cd = spec["chunk_d"]
    if spec["path"] == "calls_prot":                # unprotected call (rungs), then protected call (one L)
        prot = np.sort(rng.choice(D, size=spec["n_prot"], replace=False))
        rest = np.setdiff1d(np.arange(D), prot)
        lad = spec["ladder"]
        rung = rng.integers(0, len(lad), size=(R, -(-len(rest) // cd)))
        rung.reshape(-1)[: len(lad)] = np.arange(len(lad))
        gather = lambda cols: dict(ba=ba[:, cols], sa=sa[:, cols], bb=bb[:, cols], sb=sb[:, cols], slice_len=cd, cols=cols)
        cu, cp = gather(rest), gather(prot)
        cu.update(L=np.asarray(lad)[rung], exp=kernel_acc_chunked(cu["ba"], cu["sa"], cu["bb"], cu["sb"], cd,
                                                                    stoc_len=L_MAX, rung_table=rung, level_lens=lad))
        Lp = spec["prot_L"]
        cp.update(L=np.full((R, -(-len(prot) // cd)), Lp),
                  exp=kernel_acc_chunked(cp["ba"], cp["sa"], cp["bb"], cp["sb"], cd, stoc_len=Lp))
        return spec, [cu, cp]
    nch = -(-D // cd)
    if "ladder" in spec:
        lad = spec["ladder"]
        rung = rng.integers(0, len(lad), size=(R, nch))
        rung.reshape(-1)[: len(lad)] = np.arange(len(lad))
        exp = kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=L_MAX, rung_table=rung, level_lens=lad)
        Lrc = np.asarray(lad)[rung]
    else:
        exp = kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=spec["L"])
        Lrc = np.full((R, nch), spec["L"])
    return spec, [dict(ba=ba, sa=sa, bb=bb, sb=sb, L=Lrc, slice_len=cd, cols=None, exp=exp)]


def _fault_wrong(calls, fault):
    """Accumulators left wrong by a mask fault on a call sequence, (RG, AF)."""
    return tuple(sum(int(np.count_nonzero(o != c["exp"])) for o, c in zip(hw_calls_acc(d, calls, fault=fault), calls))
                 for d in ("rg", "af"))


def emit_case(outdir, name, seed=1):
    spec, calls = build_case(name, seed)
    tr_rg, tr_af = [], []
    rg = hw_calls_acc("rg", calls, trace=tr_rg)
    af = hw_calls_acc("af", calls, trace=tr_af)
    ok = all(np.array_equal(r, c["exp"]) and np.array_equal(f, c["exp"]) for r, f, c in zip(rg, af, calls))
    ok &= len(tr_rg) == len(tr_af) and all(np.array_equal(x["acc"], y["acc"]) for x, y in zip(tr_rg, tr_af))
    if not ok:
        raise SystemExit(f"{name}: hardware models disagree with the kernel; nothing written")
    caught = {f: _fault_wrong(calls, f) for f in spec.get("catches", ())}
    for f, n in caught.items():
        if min(n) == 0:
            raise SystemExit(f"{name}: declared to catch {f}, but it leaves RG/AF {n} accumulators wrong; nothing written")
    out = Path(outdir) / name
    out.mkdir(parents=True, exist_ok=True)
    A_mag, A_sgn, W_mag, W_sgn, Lmem, phase, cycles, drain, s_start, c_start, kA, acc_blk, exp, blkinfo = \
        ([] for _ in range(14))
    for b in tr_af:
        c = calls[b["call"]]
        lo, hi = b["lo"], b["hi"]
        w = hi - lo
        a = np.zeros((TILE_R, LANES), np.int64); a[:, :w] = c["ba"][:, lo:hi]
        an = np.zeros((TILE_R, LANES), np.int64); an[:, :w] = c["sa"][:, lo:hi] < 0
        wm = np.zeros((LANES, TILE_R), np.int64); wm[:w] = c["bb"][:, lo:hi].T
        wn = np.zeros((LANES, TILE_R), np.int64); wn[:w] = c["sb"][:, lo:hi].T < 0
        A_mag.append(a); A_sgn.append(an); W_mag.append(wm); W_sgn.append(wn)
        Lmem.append(b["L"]); phase.append(b["phase"]); cycles.append(b["cycles"][0]); drain.append(int(b["last"]))
        s_start.append(int(b["slice_start"])); c_start.append(int(b["call_start"]))
        kA.append(b["kA"]); acc_blk.append(b["acc"])
        info = dict(call=b["call"], slice=len(exp), call_slice=b["slice"], blk=b["blk"], cols=[lo, hi],
                    local_d=[lo - b["s_lo"], hi - b["s_lo"]], phase=b["phase"], cycles=b["cycles"][0],
                    drain=bool(b["last"]), slice_start=bool(b["slice_start"]), call_start=bool(b["call_start"]))
        if c["cols"] is not None:
            info["orig_ch"] = [int(v) for v in np.asarray(c["cols"])[lo:hi]]
        blkinfo.append(info)
        if b["last"]:
            exp.append(c["exp"][b["slice"]])
    nb = len(A_mag)
    hdr = f"case {name}: {spec['doc']}"
    _write_mem(out / "a_mag.mem", np.stack(A_mag), 2, f"{hdr} | A magnitude, entry blk*64 + row*8 + lane, 0..80h")
    _write_mem(out / "a_sgn.mem", np.stack(A_sgn), 1, f"{hdr} | A sign bit (1 = negative), entry blk*64 + row*8 + lane")
    _write_mem(out / "w_mag.mem", np.stack(W_mag), 2, f"{hdr} | W magnitude, entry blk*64 + lane*8 + col, 0..80h")
    _write_mem(out / "w_sgn.mem", np.stack(W_sgn), 1, f"{hdr} | W sign bit (1 = negative), entry blk*64 + lane*8 + col")
    _write_mem(out / "row_len.mem", np.stack(Lmem), 2, f"{hdr} | stream length L of each row, entry blk*8 + row, 01..80h")
    _write_mem(out / "phase.mem", np.array(phase), 1,
               f"{hdr} | EXPECTED block phase p (mask bits [4:2] = bitrev3(p)), entry blk; the DUT derives it from slice_start")
    _write_mem(out / "cycles.mem", np.array(cycles), 1, f"{hdr} | cycles this block = ceil(max row L / 16), entry blk")
    _write_mem(out / "drain.mem", np.array(drain), 1, f"{hdr} | 1 = drain and clear the accumulators after this block")
    _write_mem(out / "slice_start.mem", np.array(s_start), 1,
               f"{hdr} | 1 = first block of a slice (chunk / head / call): phase register resets to 0 for this block")
    _write_mem(out / "call_start.mem", np.array(c_start), 1,
               f"{hdr} | 1 = first block of a new call; do NOT reset the DUT here (calls run back to back)")
    _write_mem(out / "ka.mem", np.stack(kA), 2, f"{hdr} | AF A count kA (closed form), entry blk*64 + row*8 + lane")
    _write_mem(out / "acc_blk.mem", np.stack(acc_blk), 8,
               f"{hdr} | accumulator after each block (since last drain), entry blk*64 + row*8 + col, int32")
    _write_mem(out / "acc_exp.mem", np.stack(exp), 8,
               f"{hdr} | expected accumulator at each drain, entry drain*64 + row*8 + col, int32 two's complement")
    cfg = [nb, len(exp), TILE_R, TILE_R, LANES, POS, len(calls)]
    _write_mem(out / "cfg.mem", np.array(cfg), 8, f"{hdr} | N_BLOCKS N_DRAINS ROWS COLS LANES POS N_CALLS")
    meta = dict(case=name, doc=spec["doc"], spec={k: v for k, v in spec.items() if k != "doc"}, seed=seed,
                n_blocks=nb, n_drains=len(exp), n_calls=len(calls),
                checked="kernel == RG == AF (every drain and every block)",
                catches={f: dict(rg_wrong=n[0], af_wrong=n[1], what=MASK_FAULTS[f]) for f, n in caught.items()},
                blocks=blkinfo)
    (out / "case.json").write_text(json.dumps(meta, indent=1, default=int) + "\n")
    return out, nb, len(exp), len(calls), caught


def read_mem(path):
    """Parse a .mem file written by _write_mem (hex words, `//` comments)."""
    vals = []
    for line in Path(path).read_text().splitlines():
        line = line.split("//")[0].strip()
        if line:
            vals.append(int(line, 16))
    return np.array(vals, dtype=np.int64)


def _policy_phase(slice_start, call_start, policy):
    """Phase per block of a DUT whose phase register resets at every slice start ('slice', correct), at call
    starts only ('call'), or only at the first block of the run ('free', free-running)."""
    reset = {"slice": slice_start, "call": call_start, "free": np.arange(len(slice_start)) == 0}[policy]
    ph, p = np.zeros(len(reset), np.int64), 0
    for b, r in enumerate(reset):
        p = 0 if r else (p + 1) % 8
        ph[b] = p
    return ph


def check_golden(case_dir):
    """Re-derive every drain of an emitted case from its .mem files alone (the bench's view): both block models
    are fed only what the files hold, so a layout error in the writer cannot hide.  Also checks the control
    files agree (a slice starts after every drain, call_start implies slice_start, phase.mem equals a phase
    register reset at slice_start) and reports what a DUT with a wrong phase-reset policy gets ('call': reset at
    call starts only; 'free': never reset after the first block).  If case.json declares that the case catches
    no_slice_reset / no_phase_reset, the matching policy must leave accumulators wrong.
    Returns (bad, n_blocks, n_drains, n_calls, {policy: (rg_wrong, af_wrong)})."""
    d = Path(case_dir)
    def s32(v):
        return np.where(v >= 1 << 31, v - (1 << 32), v)
    cfg = read_mem(d / "cfg.mem")
    nb, nd = cfg[:2]
    am, asg = read_mem(d / "a_mag.mem").reshape(nb, 8, 8), read_mem(d / "a_sgn.mem").reshape(nb, 8, 8).astype(bool)
    wm, wsg = read_mem(d / "w_mag.mem").reshape(nb, 8, 8), read_mem(d / "w_sgn.mem").reshape(nb, 8, 8).astype(bool)
    Lm, ph = read_mem(d / "row_len.mem").reshape(nb, 8), read_mem(d / "phase.mem")
    cy, dr = read_mem(d / "cycles.mem"), read_mem(d / "drain.mem").astype(bool)
    ka, ab = read_mem(d / "ka.mem").reshape(nb, 8, 8), s32(read_mem(d / "acc_blk.mem")).reshape(nb, 8, 8)
    ex = s32(read_mem(d / "acc_exp.mem")).reshape(nd, 8, 8)
    after_drain = np.r_[True, dr[:-1]]
    if (d / "slice_start.mem").exists():
        ss, cs = read_mem(d / "slice_start.mem").astype(bool), read_mem(d / "call_start.mem").astype(bool)
    else:                                           # written before the flags existed: one call
        ss, cs = after_drain, np.arange(nb) == 0
    n_calls = int(cfg[6]) if len(cfg) > 6 else 1
    bad = int(not np.array_equal(ss, after_drain)) + int(np.any(cs & ~ss)) + int(not cs[0]) + int(cs.sum() != n_calls)
    bad += int(not np.array_equal(_policy_phase(ss, cs, "slice"), ph))

    def run(phases, debug):
        acc = {"rg": np.zeros((8, 8), np.int64), "af": np.zeros((8, 8), np.int64)}
        wrong = {"rg": 0, "af": 0}
        nbad, di = 0, 0
        for b in range(nb):
            masks = HW_MASK[:, phases[b]]
            r, _ = _rg_block(am[b], asg[b], wm[b], wsg[b], Lm[b], masks, int(cy[b]))
            f, k = _af_block(am[b], asg[b], wm[b], wsg[b], Lm[b], masks, int(cy[b]))
            acc["rg"] += r
            acc["af"] += f
            if debug:
                nbad += int(np.count_nonzero(k != ka[b])) + sum(int(np.count_nonzero(a != ab[b])) for a in acc.values())
            if dr[b]:
                for kk, a in acc.items():
                    wrong[kk] += int(np.count_nonzero(a != ex[di]))
                    a[:] = 0
                di += 1
        return nbad + int(di != nd), (wrong["rg"], wrong["af"])

    nbad, wrong = run(ph, True)
    bad += nbad + sum(wrong)
    sens = {pol: run(_policy_phase(ss, cs, pol), False)[1] for pol in PHASE_POLICIES}
    meta = json.loads((d / "case.json").read_text()) if (d / "case.json").exists() else {}
    for pol, fault in PHASE_POLICIES.items():
        if fault in meta.get("catches", {}) and min(sens[pol]) == 0:
            bad += 1
    return bad, int(nb), int(nd), n_calls, sens


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--quick", action="store_true", help="self-test on a subset of L (smoke run)")
    ap.add_argument("--log", default=str(REPO / "build" / "cbsg" / "ref_selftest.log"))
    ap.add_argument("--emit", metavar="DIR")
    ap.add_argument("--case", default="all", help="case name or 'all' (see --list-cases)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--list-cases", action="store_true")
    ap.add_argument("--check-golden", metavar="DIR", help="re-derive the drains of every case under DIR from its .mem files")
    args = ap.parse_args()
    if args.list_cases:
        for k, v in CASES.items():
            print(f"{k:14s} {v['doc']}")
        return 0
    rc = 0
    if args.selftest:
        rc |= selftest(args.log, quick=args.quick)
    if args.emit:
        names = list(CASES) if args.case == "all" else args.case.split(",")
        for n in names:
            out, nb, nd, nc, caught = emit_case(args.emit, n, args.seed)
            cs = "; catches " + ", ".join(f"{f} (RG/AF {a}/{b} wrong)" for f, (a, b) in caught.items()) if caught else ""
            print(f"wrote {out}  ({nb} blocks, {nd} drains, {nc} call{'s' if nc > 1 else ''}, kernel == RG == AF{cs})")
    if args.check_golden:
        for cd in sorted(p for p in Path(args.check_golden).iterdir() if (p / "cfg.mem").exists()):
            bad, nb, nd, nc, sens = check_golden(cd)
            print(f"[{'PASS' if bad == 0 else 'FAIL'}] {cd.name}: {nb} blocks, {nd} drains, {nc} call{'s' if nc > 1 else ''} "
                  f"re-derived from the .mem files; DUT phase reset at call start only -> RG/AF {sens['call'][0]}/"
                  f"{sens['call'][1]} wrong, never reset -> {sens['free'][0]}/{sens['free'][1]} wrong")
            rc |= int(bad != 0)
    if not (args.selftest or args.emit or args.check_golden):
        ap.print_help()
    return rc


if __name__ == "__main__":
    sys.exit(main())
