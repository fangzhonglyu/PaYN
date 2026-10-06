#!/usr/bin/env python3
"""C-BSG stochastic multiply: the scmp_kernels reference, the A-first hardware emulation, and their self-test.

The SC mode of payn_array must reproduce the scmp_kernels C-BSG matmul bit for bit.  Both sides of that claim live
here, integer-exact:

  kernel_acc_*  the kernel's table path (scmp_kernels ce3d7e5) ported line for line from torch/triton to numpy.  This
                is the spec; `kernels.py:N` comments cite the ported lines.  Every function returns the kernel's
                integer `acc` before the float scale (q_max^2 / L, then scale_a * scale_b).
  from_float    the kernel quantizers: float operand -> (boundary b, sign, scale).
  hw_af_acc     the A-first PE, block by block: closed-form A count kA per (row, lane), thermometer A, one W stream
                per lane shared by every row, column mask from hard-wired lane bits plus a block-phase register,
                signed per-cycle popcount accumulate, one drain per slice.  PE shapes K8/M16 and K16/M8.
  hw_calls_acc  several calls back to back on one PE without reset, optionally with an injected mask fault.

scmp_kernels/sc/rng.py (numpy only) is loaded by file path, so the package __init__ (torch/triton) is never
imported.  SCMP_KERNELS overrides ~/repos/scmp_kernels.

  python3 designs/payn/model/cbsg.py selftest [--shape k8m16|k16m8|all] [--quick] [--log FILE]
  python3 designs/payn/model/cbsg.py ka-exhaustive
  python3 designs/payn/model/cbsg.py check-tables [SCMP_KERNELS_ROOT]
"""
from __future__ import annotations

import argparse
import functools
import importlib.util
import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.dont_write_bytecode = True

KERNEL_ROOT = Path(os.path.expanduser(os.environ.get("SCMP_KERNELS", "~/repos/scmp_kernels")))
SOREN_PAYN = Path(os.path.expanduser(os.environ.get("SOREN_PAYN", "~/repos/soren_PaYN")))

# Deployed arithmetic: sc_prec 8 with halve (stream length and grid 2^(sc_prec-1), matmul.py:243-259), owen_mode
# bitrev with 64 scramble masks, bipolar.
SC_PREC = 8
BASE = 1 << SC_PREC                 # 256: Sobol word range (base_levels)
GRID = 1 << (SC_PREC - 1)           # 128: rng_levels under halve; magnitudes b are 0..GRID
Q_MAX = GRID - 1                    # 127
L_MAX = GRID                        # longest stream under halve
N_MASKS = 64                        # _DEFAULT_SCRAMBLE_MASKS = HW_MAX_MASKS (kernels.py:719, 738)
TILE_R = 8                          # A rows and W columns of one PE
SHAPES = {"k8m16": (8, 16), "k16m8": (16, 8)}   # PE shapes: K lanes (columns per block) x M AND positions


# ==================================================================================================================
# Kernel reference
# ==================================================================================================================

def load_rng(root=KERNEL_ROOT):
    """scmp_kernels/sc/rng.py imports only numpy/random/abc, so it is loaded by path without its package."""
    spec = importlib.util.spec_from_file_location("_scmp_rng", Path(root) / "scmp_kernels" / "sc" / "rng.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@functools.lru_cache(maxsize=None)
def base_sequences(root=KERNEL_ROOT):
    """Sobol q (A) and k (W) words, 2^sc_prec samples: RNGPool(make_sobol_simple_config) ->
    Sobol(sc_prec, seed_type).simulate(2^sc_prec) (config_helpers.py:583-607, sng.py:69-116, kernels.py:79-86)."""
    rng = load_rng(root)
    return tuple(rng.Sobol(SC_PREC, seed_type=s).simulate(BASE).astype(np.int32) for s in ("q", "k"))


def kernel_sequences(d_cfg):
    """_get_cached_sequences (kernels.py:67-87) for make_sobol_simple_config(d_cfg, d_cfg): every SNG has scramble
    None, so SNGBank.get_all_sequences broadcasts the one base sequence to every column (sng.py:218-220)."""
    q, k = base_sequences()
    return np.broadcast_to(q, (d_cfg, BASE)).copy(), np.broadcast_to(k, (d_cfg, BASE)).copy()


def _resolve_rng_levels(sc_prec, rng_levels):                       # kernels.py:667-678
    return 2 ** sc_prec if rng_levels is None else int(rng_levels)


def _bit_reverse(x, n_bits):                                        # kernels.py:722-727
    x = np.asarray(x)
    y = np.zeros_like(x)
    for i in range(n_bits):
        y = y | (((x >> i) & 1) << (n_bits - 1 - i))
    return y


def _scramble_mask_count(base_levels, scramble_masks=N_MASKS, hw_max_masks=N_MASKS):   # kernels.py:746-767
    m = min(scramble_masks, hw_max_masks, base_levels)              # kernels.py:761
    if m & (m - 1):
        raise ValueError(f"mask count must be a power of two, got {m}")
    return m


def _owen_scramble(prefix, base_levels):                            # kernels.py:770-811, SC_OWEN_MODE=bitrev
    m = _scramble_mask_count(base_levels)
    n_bits = int(round(np.log2(base_levels)))                       # kernels.py:794
    idx = np.arange(prefix.shape[0], dtype=np.int64) % m            # kernels.py:795
    masks = _bit_reverse(idx, n_bits).astype(prefix.dtype)[:, None]  # kernels.py:796
    return np.ascontiguousarray(prefix ^ masks)                     # kernels.py:811


def _prepare_rng_prefix(rng, sc_prec, stoc_len, rng_levels):        # kernels.py:814-849
    grid_levels = _resolve_rng_levels(sc_prec, rng_levels)
    base_levels = 2 ** sc_prec
    is_prefix = stoc_len < rng.shape[1]                             # kernels.py:823
    prefix = np.ascontiguousarray(rng[:, :stoc_len]) if is_prefix else rng
    if grid_levels == base_levels:                                  # fixed-level path (not deployed)
        return _owen_scramble(prefix, base_levels) if is_prefix else prefix
    prefix = _owen_scramble(prefix, base_levels)                    # kernels.py:846 (always on)
    scaled = (prefix.astype(np.int64) * grid_levels) // base_levels  # kernels.py:848 (floor division)
    return np.ascontiguousarray(scaled.astype(prefix.dtype))


def _next_power_of_2(n):                                            # triton.next_power_of_2
    return 1 << (int(n) - 1).bit_length()


def build_cum_indicator(rng_b, D, stoc_len, V):                     # kernels.py:103-139 (one program per d)
    rng_b = np.ascontiguousarray(rng_b).reshape(-1)[: D * stoc_len].reshape(D, stoc_len)
    v_range = np.arange(V)
    cum = np.zeros((D, stoc_len + 1, V), dtype=np.int16)            # cum[d, 0, :] = 0
    running = np.zeros((D, V), dtype=np.int16)
    for k in range(stoc_len):
        running = running + (v_range[None, :] > rng_b[:, k][:, None]).astype(np.int16)   # kernels.py:133 (strict >)
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
    V_PADDED = _next_power_of_2(grid_levels + 1)                    # kernels.py:910
    cum = build_cum_indicator(_prepare_rng_prefix(rng_b, SC_PREC, stoc_len, grid_levels), d_cfg, stoc_len, V_PADDED)
    k_table = compute_k_table(_prepare_rng_prefix(rng_a, SC_PREC, stoc_len, grid_levels), d_cfg, stoc_len, V_PADDED)
    cum.setflags(write=False)
    k_table.setflags(write=False)
    return cum, k_table


@functools.lru_cache(maxsize=256)
def build_k_table_only(d_cfg, stoc_len, rng_levels=GRID):           # kernels.py:1113-1136
    rng_a, _ = kernel_sequences(d_cfg)
    grid_levels = _resolve_rng_levels(SC_PREC, rng_levels)
    V_PADDED = _next_power_of_2(grid_levels + 1)                    # kernels.py:1132
    kt = compute_k_table(_prepare_rng_prefix(rng_a, SC_PREC, stoc_len, grid_levels), d_cfg, stoc_len, V_PADDED)
    kt.setflags(write=False)
    return kt


def k_table_stack(d_cfg, level_lens, rng_levels=GRID):              # _get_cached_k_table_stack kernels.py:1008-1036
    return np.stack([build_k_table_only(d_cfg, int(L), rng_levels) for L in level_lens], axis=0)


@functools.lru_cache(maxsize=64)
def rng_b_prefix_for(d_cfg, stoc_len, rng_levels=GRID):             # kernels.py:1851 (chunked fast path)
    p = _prepare_rng_prefix(kernel_sequences(d_cfg)[1], SC_PREC, stoc_len, rng_levels)
    p.setflags(write=False)
    return p


@functools.lru_cache(maxsize=4)
def _chunk_cum(chunk_d, stoc_len, V):
    """build_cum_indicator_kernel[(chunk_d,)](rng_b, cum, chunk_d, stoc_len, V) (kernels.py:1619-1629)."""
    cum = build_cum_indicator(rng_b_prefix_for(chunk_d, stoc_len), chunk_d, stoc_len, V)
    cum.setflags(write=False)
    return cum


def tiled_kernel_acc(cum, k_table, ba_t, bb_t, sa_t, sb_t, N, M, D, rung=None):
    """enable_matmul_tiled_kernel with IS_BIPOLAR (kernels.py:177-302), returning `acc` before the scale
    (kernels.py:279-283).  ba_t/bb_t/sa_t/sb_t are the (D, N) / (D, M) transposed tensors the kernel reads.  The
    kernel accumulates `counts * sa * sb` in float32; every term is an integer and |acc| < 2^24 (asserted), so the
    float32 sum equals this int64 one.  The all-zero-sign tile skip (kernels.py:248-251) only skips zero terms."""
    acc = np.zeros((N, M), dtype=np.int64)
    if rung is not None:
        rung = np.asarray(rung, dtype=np.int64)                     # kernels.py:236-237 k_base = rung * (D * V)
    for d in range(D):
        ba = ba_t[d].astype(np.int64)
        if rung is not None:
            k_vals = k_table[rung, d, ba].astype(np.int64)          # kernels.py:256 k_table[k_base + d*V + ba]
        else:
            k_vals = k_table[d, ba].astype(np.int64)                # kernels.py:258
        counts = cum[d, k_vals[:, None], bb_t[d].astype(np.int64)[None, :]].astype(np.int64)  # kernels.py:259-262
        acc += counts * sa_t[d].astype(np.int64)[:, None] * sb_t[d].astype(np.int64)[None, :]  # kernels.py:263
    assert np.abs(acc).max(initial=0) < (1 << 24), "float32 accumulator would no longer be exact"
    return acc


def _check_lengths(L):
    L = np.asarray(L)
    if L.size and (L.min() < 1 or L.max() > L_MAX):
        raise ValueError(f"stream lengths must lie in 1..{L_MAX} under halve (matmul.py:247-256)")


def kernel_acc_plain(ba, sa, bb, sb, L):
    """Plain (unchunked) per-row / per-tensor path, (N, M): _sc_matmul_per_row (kernels.py:1931-2015) or
    _sc_matmul_per_tensor (1297-1396) -> config make_sobol_simple_config(D, D) (1973 / 1355) ->
    _get_cached_enable_tables (2003 / 1379) -> enable_matmul_triton (1039-1110) -> the tiled kernel with
    PER_ROW_LEN=False.  The mask index d runs along the whole D.

    L is a scalar or per row.  Per-row L on this path (chunk_d = 0: attention qk / av) is one call per distinct L on
    that row subset, as the model wrapper dispatches it; kernel_acc_plain_kstack is the single-call PER_ROW_LEN
    form, and the self-test checks the two agree."""
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
    """The same rows in one PER_ROW_LEN call: cum at stoc_len, k_table stack over the distinct lengths, per-row rung
    (kernels.py:178-302 with PER_ROW_LEN=True; stack as kernels.py:1008-1036)."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    N, D = ba.shape
    Lr = np.asarray(L_rows, dtype=np.int64)
    _check_lengths(Lr)
    lens = sorted(set(int(v) for v in Lr))
    if max(lens) > stoc_len:                                        # kernels.py:1571
        raise ValueError("level_lens max exceeds stoc_len")
    rung = np.array([lens.index(int(v)) for v in Lr])
    cum, _ = build_enable_tables(D, stoc_len)
    return tiled_kernel_acc(cum, k_table_stack(D, lens), ba.T, bb.T, sa.T, sb.T, N, bb.shape[0], D, rung=rung)


def kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=L_MAX, rung_table=None, level_lens=None):
    """Chunked MLP path, (n_chunks, N, M): _sc_matmul_per_row_mlp fast path (kernels.py:1840-1856) +
    _sc_matmul_bipolar_mlp_chunked (1517-1708).  Each entry is the integer `partial` of one chunk before
    `output += partial * (scale_a * scale_b)` (1706), i.e. what the hardware drains per chunk.
      * config make_sobol_simple_config(chunk_d, chunk_d) (1844): the mask index d restarts in every chunk;
      * k_table and rng_b prefix at stoc_len (1848, 1851), one cum over chunk_d columns (1619-1629);
      * short last chunk: cum rebuilt from rng_b[:d_len], k_table[:d_len] / k_stack[:, :d_len] (1668-1676);
      * rung_table (N, n_chunks) indexes level_lens per (row, chunk) (1605, 1689, kernel 236-256).
    D <= chunk_d falls through to the standard path (1840), which is the plain path."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    N, D = ba.shape
    M = bb.shape[0]
    if not (chunk_d > 0 and D > chunk_d):                           # kernels.py:1840
        if rung_table is not None:                                  # kernels.py:1874-1878
            raise ValueError("rung_table needs the chunked fast path (0 < chunk_d < D)")
        return kernel_acc_plain(ba, sa, bb, sb, stoc_len)[None]
    per_row_len = rung_table is not None
    n_chunks = -(-D // chunk_d)
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
        cs = slice(d_start, d_end)
        out.append(tiled_kernel_acc(cum_chunk, k_tab_chunk, ba[:, cs].T, bb[:, cs].T, sa[:, cs].T, sb[:, cs].T,
                                    N, M, d_len, rung=rung_table[:, ci] if per_row_len else None))   # 1689
    return np.stack(out)


def kernel_acc_chunked_rowsplit(ba, sa, bb, sb, chunk_d, L_rows):
    """Per-row L on the chunked path as the SCLinear wrapper dispatches it: one call per level on that level's row
    subset with stoc_len = L.  By prefix nesting this equals one rung-table call whose rung is constant along the
    chunks (self-test)."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    N, D = ba.shape
    Lr = np.asarray(L_rows, dtype=np.int64)
    out = np.zeros((-(-D // chunk_d) if (chunk_d > 0 and D > chunk_d) else 1, N, bb.shape[0]), np.int64)
    for Lv in np.unique(Lr):
        rows = np.nonzero(Lr == Lv)[0]
        out[:, rows] = kernel_acc_chunked(ba[rows], sa[rows], bb, sb, chunk_d, stoc_len=int(Lv))
    return out


def kernel_acc_batched(ba, sa, bb, sb, L):
    """3D paths, (BH, N, M): _sc_matmul_per_head_bipolar (kernels.py:475-631) and _sc_matmul_per_row_batched
    (2136-2252) both run enable_matmul_bipolar_batched_kernel (397-472): tables over D (config
    make_sobol_simple_config(D, D): matmul.py:417-420, kernels.py:2174) shared by every head, mask index d per
    head, one uniform stoc_len.  Inputs (BH, N, D) / (BH, M, D)."""
    ba, sa, bb, sb = (np.asarray(x) for x in (ba, sa, bb, sb))
    BH, N, D = ba.shape
    _check_lengths([L])
    cum, k_table = build_enable_tables(D, int(L))
    return np.stack([tiled_kernel_acc(cum, k_table, ba[h].T, bb[h].T, sa[h].T, sb[h].T, N, bb.shape[1], D)
                     for h in range(BH)])


def from_float(x, path, chunk_d=0):
    """The kernel's quantization of a float operand to (b, sign, scale), in IEEE float32 arithmetic.

      'per_row'     2D attention / plain per-row: _grouped_symmetric_quant G=1 (grouped.py:13-71), then
                    b = round(|x_int| * 128 / 127) (kernels.py:2036-2037).  Zero -> sign +1.
      'per_row_3d'  3D per-row: _grouped_symmetric_quant_batched G=1 (grouped.py:153-159),
                    b = round(|x_int| * (128/127)) (kernels.py:2221-2222).  Zero -> sign +1.
      'chunked'     MLP with 0 < chunk_d < D: fused_quantize_bipolar_perrow per chunk (kernels.py:1660-1665;
                    fused.py:134-159, kernel 72-110).  Zero -> sign 0.  Scale (rows, n_chunks).  With D <= chunk_d
                    or chunk_d = 0 the kernel takes the standard path (kernels.py:1840 false, then 1477-1500: grouped
                    G=1, b = round(|x_int| * 128 / 127)), so this returns the 'per_row' result with scale (rows, 1).
      'per_head'    host scale (kernels.py:525-529) + fused_quant_bipolar_batched_kernel (fused.py:238-280).
      'per_tensor'  fused_quantize_bipolar (fused.py:162-192).
    Every path yields b in 0..128 without 64: round(k * 128/127) skips it.

    Checked only for internal consistency (kernel == emulation on its operands), never against GPU output.  The
    fused per-row branch computes scale = abs_max / q_max and 1 / scale with fp32 '/' inside Triton (fused.py:76-81),
    which the NVIDIA backend probably lowers to the approximate div.full.f32 (<= 2 ulp) rather than IEEE division,
    so b can differ by +-1 where x * inv_scale lies within a few ulp of k + 0.5 (about 1e-6 of random elements).
    The other paths divide in torch / Python (IEEE).  The hardware contract starts at (b, sign)."""
    x = np.asarray(x, dtype=np.float32)
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
        return np.round(np.abs(xc) * (grid / q)).astype(np.int16), sign   # max_rng_val / q_max in fp32

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
            b, s = fused(xc, (np.float32(1.0) / scale).astype(np.float32), -Q_MAX)        # fused.py:79
            bs.append(b)
            ss.append(s)
            scales.append(scale[:, 0])
        return np.concatenate(bs, axis=1), np.concatenate(ss, axis=1), np.stack(scales, axis=1)
    if path == "per_head":
        amax = np.maximum(np.maximum(np.abs(x.max(axis=(1, 2))), np.abs(x.min(axis=(1, 2)))),
                          np.float32(1e-5))                         # kernels.py:525
        scale = (amax / q).astype(np.float32)                       # kernels.py:527
        inv = (np.float32(1.0) / scale).astype(np.float32)          # kernels.py:529
        b, s = fused(x, inv[:, None, None], -(Q_MAX + 1))           # q_min = -128 (kernels.py:520)
        return b, s, scale
    if path == "per_tensor":
        abs_max = max(abs(float(x.max())), abs(float(x.min())), 1e-5)   # fused.py:172 (Python double)
        scale = abs_max / Q_MAX
        b, s = fused(x, np.float32(1.0 / scale), -Q_MAX)            # fp32 kernel argument
        return b, s, np.float32(scale)
    raise ValueError(f"unknown path {path!r}")


# ==================================================================================================================
# A-first hardware emulation
# ==================================================================================================================

BR8 = _bit_reverse(np.arange(BASE), 8).astype(np.int64)

# Sobol direction numbers as the RTL holds them.  q is the identity, so A word t is bitrev8(gray(t)); k drives W.
DV_Q = [0x80 >> j for j in range(8)]
DV_K = [0x80, 0x40, 0x20, 0x10, 0x48, 0x04, 0x52, 0xFF]

MASK_FAULTS = {
    # name: how the column mask goes wrong (each is a way the scrambling-mask state can leak)
    "call_d":         "d = column index inside the call (reset at call start, not at chunk / head starts)",
    "no_slice_reset": "phase register reset at call start only, not at chunk / head starts",
    "global_mask":    "d = columns counted from the start of the run (never reset; continues across calls)",
    "no_phase_reset": "phase register free-runs from power-up (reset neither per slice nor per call)",
    "orig_channel_d": "d = original input-channel index of a gathered column (protected / unprotected split)",
}


def sobol_gray(idx, dv):
    """Sobol word by index: XOR of dv[j] over the set bits j of gray(idx)."""
    idx = np.asarray(idx, dtype=np.int64)
    g = idx ^ (idx >> 1)
    x = np.zeros_like(idx)
    for j, v in enumerate(dv):
        x ^= ((g >> j) & 1) * v
    return x


def sobol_bank(dv, M):
    """The W words in sample order as the stream generator makes them, (128 / M cycles, M positions): word M*c + m
    is H(c) ^ LANE(m) with LANE(m) = XOR over j < log2 M of gray(m)[j] dv[j]; H(0) = 0 at every block start and
    H(c+1) = H(c) ^ dv[log2 M - 1] ^ dv[log2 M + (trailing ones of c)]."""
    lm = M.bit_length() - 1
    lane = sobol_gray(np.arange(M), dv[:lm])
    out, h = [], 0
    for c in range(L_MAX // M):
        out.append(h ^ lane)
        ones = 0
        while (c >> ones) & 1:
            ones += 1
        if lm + ones < len(dv):
            h ^= dv[lm + ones]
        h ^= dv[lm - 1]
    return np.array(out, dtype=np.int64)


@functools.lru_cache(maxsize=None)
def geometry(K=8, M=16):
    """Block geometry of a K-lane, M-position PE.  Lane k of block j of a slice carries the slice-local column
    d = K*j + k.  Its mask bitrev8(d mod 64) splits into the lane bits bitrev(k) at [7:8-log2 K], hard-wired, and
    PB = 6 - log2 K phase bits bitrev(p) just below, p = j mod 2^PB from the block-phase register; bits [1:0] are 0.
    MASK[k, p] is that mask, WBANK the W words in sample order (t = M*c + m), CYC = 128 / M the longest block."""
    if (K, M) not in SHAPES.values():
        raise ValueError(f"unsupported PE shape K{K}/M{M}; supported: {', '.join(SHAPES)}")
    lk = K.bit_length() - 1
    pb = 6 - lk
    mask = (_bit_reverse(np.arange(K)[:, None], lk) << (8 - lk)) | (_bit_reverse(np.arange(1 << pb)[None, :], pb) << 2)
    return SimpleNamespace(K=K, M=M, PB=pb, NPH=1 << pb, CYC=L_MAX // M, MASK=mask.astype(np.int64),
                           WBANK=sobol_bank(DV_K, M), name=f"K{K}/M{M}")


def ka_closed(b, L, mask):
    """A-side encoder: kA = #{t < L : ((Xq(t) ^ mask) >> 1) < b} in closed form, without a Sobol bank.  [0, L)
    splits into aligned dyadic blocks, largest first; a block of 2^j samples starting at s0 adds
    (b >> s) + [(b mod 2^s) > c] with s = 7 - j and c = ((bitrev8(gray(s0)) ^ mask) mod 2^(8-j)) >> 1."""
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
    """The hardware sign is one bit (1 = negative).  Sign 0 is legal only with b = 0 (both kernel conventions for
    x = 0, sign +1 or 0, map to b = 0, which contributes nothing)."""
    b, s = np.asarray(b), np.asarray(s)
    if np.any((s == 0) & (b != 0)):
        raise ValueError(f"{what}: sign 0 with non-zero magnitude is outside the hardware contract")
    if b.min(initial=0) < 0 or b.max(initial=0) > GRID:
        raise ValueError(f"{what}: magnitude outside 0..{GRID}")
    return s < 0


def block_schedule(D, slice_len=0, K=8):
    """Block order of one call: the reduction axis is cut into slices (the whole D for plain, chunk_d for chunked,
    one head for per-head), every slice into blocks of K lanes from its first column, the last one padded with zero
    magnitude.  Block j of a slice has phase j mod (64 / K).  Returns [(slice, j, lo, hi, phase, last_in_slice)]
    with the call-local column range [lo, hi)."""
    sl = slice_len or D
    out = []
    for s, s_lo in enumerate(range(0, D, sl)):
        s_hi = min(s_lo + sl, D)
        nb = -(-(s_hi - s_lo) // K)
        for j in range(nb):
            lo = s_lo + K * j
            out.append((s, j, lo, min(lo + K, s_hi), j % (N_MASKS // K), j == nb - 1))
    return out


def af_block(g, aB, aN, wB, wN, Lr, masks, C, fault=None):
    """One block for a group of rows: aB/aN (R, K), wB/wN (K, cols), Lr (R,), masks (K,), C cycles.  A bit at
    position m of cycle c is [M*c + m < kA]; W bit [bW > rB(d, M*c + m)] from the lane's bank, shared by every row.
    Returns the (R, cols) block sum and kA."""
    kA = ka_closed(aB, Lr[:, None], masks[None, :])
    if fault == "af_ka_eq_b":
        kA = np.minimum(aB, Lr[:, None])
    sgn = np.where(aN[:, :, None] ^ wN[None, :, :], -1, 1)                 # (R, K, cols) sign XOR per lane
    acc = np.zeros((aB.shape[0], wB.shape[1]), np.int64)
    pos = np.arange(g.M)
    for c in range(C):
        a = (g.M * c + pos)[None, None, :] < kA[:, :, None]                # (R, K, M) thermometer
        rB = (g.WBANK[c][None, :] ^ masks[:, None]) >> 1                   # (K, M)
        w = wB[:, :, None] > rB[:, None, :]                                # (K, cols, M)
        acc += (sgn * (a[:, :, None, :] & w[None]).sum(axis=3)).sum(axis=1)   # signed per-cycle popcount
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


def _block_masks(g, fault, p, lo, w, state, call_blk, cols):
    """Lane masks of one block.  Correct hardware: MASK[:, p], i.e. bitrev8(d mod 64) with d the column index inside
    the slice of the current call (the phase register resets at every slice start, so at every call start).  In one
    call from reset call_d == global_mask and no_slice_reset == no_phase_reset; they differ only across calls."""
    lanes = np.arange(g.K)
    if fault == "call_d":
        return BR8[(lo + lanes) % N_MASKS]
    if fault == "global_mask":
        return BR8[(state["cols"] + lo + lanes) % N_MASKS]
    if fault == "no_slice_reset":
        return g.MASK[:, call_blk % g.NPH]
    if fault == "no_phase_reset":
        return g.MASK[:, state["blocks"] % g.NPH]
    if fault == "orig_channel_d":
        m = np.zeros(g.K, np.int64)                                # padded lanes carry b = 0: mask irrelevant
        m[:w] = BR8[(np.arange(lo, lo + w) if cols is None else np.asarray(cols, np.int64)[lo:lo + w]) % N_MASKS]
        return m
    if fault in (None, "af_ka_eq_b"):
        return g.MASK[:, p]
    raise ValueError(f"unknown fault {fault!r}")


def hw_af_acc(ba, sa, bb, sb, L, slice_len=0, shape=(8, 16), full_cycles=False, fault=None, trace=None,
              state=None, cols=None, call=0):
    """The A-first PE on one call: (n_slices, N, M) accumulators, one per drain.  ba/sa (N, D), bb/sb (M, D); L is
    a scalar, per row (N,) or per (row, slice) (N, n_slices).  Every TILE_R-row group runs ceil(max L / M) cycles
    per block (all 128 / M with full_cycles).  state carries the instance's block and column counts across calls
    (only the mask faults read it); cols is the original channel of each column of a gathered call; a list passed
    as trace gets one record per block."""
    g = geometry(*shape)
    ba, bb = np.asarray(ba, np.int64), np.asarray(bb, np.int64)
    aNeg, wNeg = _sign_bits(ba, sa, "A"), _sign_bits(bb, sb, "W")
    N, D = ba.shape
    M = bb.shape[0]
    if cols is not None and len(cols) != D:
        raise ValueError(f"cols must give one original channel per column ({D}), got {len(cols)}")
    state = dict(blocks=0, cols=0) if state is None else state
    blocks = block_schedule(D, slice_len, g.K)
    Lm = _row_lengths(L, N, blocks[-1][0] + 1)
    acc = np.zeros((Lm.shape[1], N, M), np.int64)
    for call_blk, (s, j, lo, hi, p, last) in enumerate(blocks):
        w = hi - lo
        aB = np.zeros((N, g.K), np.int64)
        aB[:, :w] = ba[:, lo:hi]
        aN = np.zeros((N, g.K), bool)
        aN[:, :w] = aNeg[:, lo:hi]
        wB = np.zeros((g.K, M), np.int64)
        wB[:w] = bb[:, lo:hi].T
        wN = np.zeros((g.K, M), bool)
        wN[:w] = wNeg[:, lo:hi].T
        masks = _block_masks(g, fault, p, lo, w, state, call_blk, cols)
        state["blocks"] += 1
        cyc, kas = [], []
        for r0 in range(0, N, TILE_R):
            rows = slice(r0, min(r0 + TILE_R, N))
            Lr = Lm[rows, s]
            C = g.CYC if full_cycles else int(-(-Lr.max() // g.M))
            blk, kA = af_block(g, aB[rows], aN[rows], wB, wN, Lr, masks, C, fault)
            acc[s, rows] += blk
            cyc.append(C)
            kas.append(kA)
        if trace is not None:
            trace.append(dict(call=call, call_blk=call_blk, slice=s, blk=j, lo=lo, hi=hi, s_lo=lo - g.K * j,
                              phase=p, last=last, slice_start=(j == 0), call_start=(call_blk == 0),
                              L=Lm[:, s].copy(), cycles=cyc, kA=np.concatenate(kas), acc=acc[s].copy()))
    state["cols"] += D
    return acc


def hw_calls_acc(calls, fault=None, shape=(8, 16), **kw):
    """Several calls back to back on one PE with no reset in between, as deployed: consecutive (B, H) attention
    calls, or the unprotected and the protected call of one linear.  A call is dict(ba, sa, bb, sb, L, slice_len=0,
    cols=None).  Correct hardware carries no mask state across calls; the mask faults carry the phase / column
    count over.  Returns one (n_slices, N, M) array per call."""
    state = dict(blocks=0, cols=0)
    return [hw_af_acc(c["ba"], c["sa"], c["bb"], c["sb"], c["L"], c.get("slice_len", 0), shape=shape, fault=fault,
                      state=state, cols=c.get("cols"), call=ci, **kw) for ci, c in enumerate(calls)]


def hw_acc_batched(ba, sa, bb, sb, L, shape=(8, 16), **kw):
    """3D operands (per-head / per-row 3D), (BH, N, M): every head is its own slice on one instance."""
    kw.setdefault("state", dict(blocks=0, cols=0))
    return np.stack([hw_af_acc(ba[h], sa[h], bb[h], sb[h], L, 0, shape=shape, **kw)[0] for h in range(ba.shape[0])])


# ==================================================================================================================
# Deployment ladders and test operands
# ==================================================================================================================

# The 118 distinct stream-length sets of the deployment traces: rung levels plus the escape L (128) and the
# protected-channel L of every model / target config, and every per-op set of group stoc_len.  The order (by source
# name) is fixed: the self-test and the extra golden set index this list.
TRACE_LADDERS = [[int(v) for v in s.split()] for s in """
128 96 64 48 32 16; 128 64 48 32 16; 128 32 16; 128 96 64; 128 96 64 48; 128; 128 96 80 64 48 32 24 16;
128 95 86 64 48 41 39 34 33 32; 128 112 96 64 48 44 42 38; 128 96 64 48 32; 128 97 84 64 48 32 25 18;
128 96 68 64 46 44 40 35 32 31; 128 111 85 84 49 48 33; 128 112 105 64 63 62 61 60 48; 128 96 74 68 48 32 24 19;
128 98 95 70 48 30 24; 128 95 64 63 58 31; 128 112 75 66 65 64 63 48; 128 80 24 16; 96 80 64 48 32 24 16;
128 80 48 32 24; 96 80 32 24 16; 128 96; 96 80 64 48 32 24; 86 64 48 41 39 34 33 32; 128 95 39 34 33;
95 86 64 48 41 39 34 33 32; 128 95 48 41 39 34 33; 95 86 39 34 33 32; 128 86 64 48 41; 95 86 64 48 41 39 34 33;
128 96 64 48 44 42 38; 128 112 48 44 42 38; 128 112 42 38; 128 112 64 48 44 42 38; 128 112 48 44 42;
128 112 44 42 38; 128 112 64 48 44 42; 128 48 32; 128 64 48 32; 96 64 48 32 24 16; 128 96 80 32 24;
128 96 80 24 16; 128 80 16; 128 96 64 48 32 24 16; 128 80 32 24 16; 96 65 49 47 32 31 30; 128 96 68 47 32 31 30;
128 96 68 30; 128 68 31 30; 128 68 30; 128 96 65 49 47 32 31 30; 128 96 68 31 30; 128 68 47 32 31 30;
109 66 48 47 46 45 32; 128 112 109 47 46 45 32; 128 112 109 45 32; 128 112 46 45 32; 128 112 45 32;
128 109 66 48 47 46 45 32; 128 112 109 46 45 32; 128 112 47 46 45 32; 128 117 95 62 61 32; 128 117 95 60 32;
128 95 61 60 32; 128 95 60 32; 128 117; 128 117 95 61 60 32; 128 95 62 61 60 32; 128 97 64 48 32 25 18;
128 84 32 25 18; 128 84 18; 128 84 25 18; 128 97 64 48 32 25; 97 84 18; 128 84 48 32 25 18;
128 96 64 46 44 40 35 32 31; 128 68 44 40 35 32 31; 128 68 32 31; 128 96 64 46 44 40 35 32; 96 68 31;
128 68 46 44 40 35 32 31; 128 111 85 49 48 33; 128 84 48 33; 128 84 33; 128 111 85 49 48; 111 84 33;
128 84 49 48 33; 128 105 64 63 62 61 60 48; 128 112 62 61 60 48; 128 112 60 48; 128 112 61 60 48;
128 105 64 63 62 61; 112 105 61 60 48; 128 112 63 62 61 60 48; 128 68 32 24 19; 128 68 24 19; 128 96 68 32 24 19;
128 68 48 32 24; 128 96 68 24 19; 128 74 68 48 32; 128 98; 128 95 48 30 24; 128 95 30 24; 128 98 95 48 30 24;
128 95 48 30; 128 98 95 30 24; 128 95 70 48; 128 95 58 31; 128 95 31; 128 95 63 58 31; 128 95 64 63 58;
128 112 65 64 63 48; 128 112 63 48; 128 112 66 65 64; 128 112 64 63 48; 128 112 75 66 65; 128 96 48
""".split(";")]


def gen_operands(rng, rows, D, mags="mixed"):
    """Magnitudes 0..128 ('mixed': uniform plus 30 % from the extremes 0 1 63 64 65 127 128; 'extreme': 0 1 127 128
    only; 'uniform'), random +-1 signs; zeros get sign 0 or +1 at random (the two kernel quantizer conventions)."""
    if mags == "extreme":
        b = rng.choice(np.array([0, 1, 127, 128]), size=(rows, D))
    else:
        b = rng.integers(0, GRID + 1, size=(rows, D))
        if mags != "uniform":
            pick = rng.random((rows, D)) < 0.3
            b[pick] = rng.choice(np.array([0, 1, 63, 64, 65, 127, 128]), size=int(pick.sum()))
    s = rng.choice(np.array([-1, 1]), size=(rows, D))
    zero = b == 0
    s[zero] = rng.choice(np.array([0, 1]), size=int(zero.sum()))
    return b.astype(np.int16), s.astype(np.int8)


def ladder_rows(rng, ladder, N):
    """Per-row L: every ladder value at least once (as far as N allows), the rest random, shuffled."""
    lad = np.array(ladder)
    L = rng.choice(lad, size=N)
    L[: min(N, len(lad))] = lad[: min(N, len(lad))]
    rng.shuffle(L)
    return L


# ==================================================================================================================
# Self-test: kernel == A-first emulation
# ==================================================================================================================

class Log:
    def __init__(self, path=None):
        self.f = None
        if path:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            self.f = Path(path).open("w")

    def __call__(self, msg=""):
        print(msg, flush=True)
        if self.f:
            self.f.write(msg + "\n")
            self.f.flush()


class Tally:
    """Accumulators the emulation gets wrong, per (shape, path); named checks."""

    def __init__(self, log):
        self.log, self.paths, self.bad = log, {}, []

    def add(self, path, name, ref, outs, macs):
        for shape, out in outs.items():
            rec = self.paths.setdefault((shape, path), dict(cases=0, macs=0, bad=0))
            n = int(np.count_nonzero(ref != out))
            rec["cases"] += 1
            rec["macs"] += int(macs)
            rec["bad"] += n
            if n:
                self.bad.append((shape, path, name, n))
                self.log(f"  MISMATCH {shape} {path} {name}: {n} of {ref.size} accumulators")

    def check(self, name, ok, detail=""):
        self.log(f"  [{'PASS' if ok else 'FAIL'}] {name} {detail}")
        if not ok:
            self.bad.append(("check", name))

    def summary(self, path):
        return "  ".join(f"{s}: {r['cases']} cases, {r['macs']:,} MACs, {r['bad']} wrong"
                         for (s, p), r in self.paths.items() if p == path)


def selftest(shapes, log_path=None, quick=False):
    """Every kernel path against the emulation at each shape in `shapes`, plus primitives, path equivalences,
    invariances and fault sensitivity.  Returns 0 on PASS."""
    t0 = time.time()
    log = Log(log_path)
    rng = np.random.default_rng(20261004)
    T = Tally(log)
    geo = {s: geometry(*SHAPES[s]) for s in shapes}
    log(f"cbsg self-test  kernel={KERNEL_ROOT} (ce3d7e5 expected)  shapes {' '.join(g.name for g in geo.values())}")
    log(f"arithmetic: sc_prec={SC_PREC} halve grid={GRID} masks=bitrev8(d mod {N_MASKS})")

    def af(*args, **kw):
        return {s: hw_af_acc(*args, shape=SHAPES[s], **kw) for s in shapes}

    def run(path, name, ref, ba, sa, bb, sb, L, slice_len=0):
        T.add(path, name, ref, af(ba, sa, bb, sb, L, slice_len), ba.shape[0] * bb.shape[0] * ba.shape[1])

    # ---------------- T0 primitives ----------------
    log("\n[T0] primitives")
    q, k = base_sequences()
    T.check("A word by index (Gray code, identity directions) == rng.py Sobol q[0:256]",
            np.array_equal(sobol_gray(np.arange(BASE), DV_Q), q))
    T.check("W word by index (Gray code, k directions) == rng.py Sobol k[0:256]",
            np.array_equal(sobol_gray(np.arange(BASE), DV_K), k))
    d = np.arange(4096)
    kmask = _bit_reverse(d % N_MASKS, 8)
    T.check("kernel _owen_scramble mask row d == bitrev8(d mod 64)",
            np.array_equal(_owen_scramble(np.zeros((4096, 1), np.int64), BASE)[:, 0], kmask))
    for g in geo.values():
        T.check(f"{g.name} W bank (sample order, H(c) ^ LANE(m)) == rng.py Sobol k[0:128]",
                np.array_equal(g.WBANK.reshape(-1), k[:L_MAX]))
        T.check(f"{g.name} mask split MASK[d % {g.K}, (d // {g.K}) % {g.NPH}] == bitrev8(d mod 64), d < 4096",
                np.array_equal(g.MASK[d % g.K, (d // g.K) % g.NPH], kmask))
        m64 = g.MASK[np.arange(N_MASKS) % g.K, np.arange(N_MASKS) // g.K]
        T.check(f"{g.name} W sample (bank ^ mask) >> 1 == kernel rB prefix (64 masks x 128 t)",
                np.array_equal(rng_b_prefix_for(N_MASKS, L_MAX), (g.WBANK.reshape(-1)[None, :] ^ m64[:, None]) >> 1))
    bad = 0
    for L in range(1, L_MAX + 1):
        kt = build_k_table_only(N_MASKS, L)[:, : GRID + 1]          # (64 masks, 129)
        bad += int(np.count_nonzero(kt != ka_closed(np.arange(GRID + 1)[None, :], L, BR8[:N_MASKS, None])))
    T.check("closed-form kA == kernel k_table (L 1..128 x 64 masks x b 0..128 = 1,056,768)", bad == 0, f"{bad} bad")
    cum128 = build_enable_tables(N_MASKS, L_MAX)[0]                 # per-row L relies on prefix nesting
    T.check("cum table at L == first L+1 rows of the L=128 table (prefix nesting)",
            all(np.array_equal(build_enable_tables(N_MASKS, L)[0], cum128[:, : L + 1])
                for L in (1, 18, 25, 38, 64, 97, 127)))

    Ls = range(1, L_MAX + 1) if not quick else (1, 2, 15, 16, 17, 18, 25, 31, 33, 64, 84, 97, 127, 128)

    # ---------------- T1 plain, uniform L ----------------
    log("\n[T1] plain path, uniform L = every value in 1..128, D alternating 200 / 203 (not a multiple of 8 or 64)")
    for L in Ls:
        D = 200 if L % 2 else 203
        ba, sa = gen_operands(rng, 16, D, "extreme" if L % 7 == 0 else "mixed")
        bb, sb = gen_operands(rng, 16, D, "extreme" if L % 11 == 0 else "mixed")
        run("plain", f"L={L} D={D}", kernel_acc_plain(ba, sa, bb, sb, L)[None], ba, sa, bb, sb, L)
    log(f"  plain uniform: {T.summary('plain')}")

    # ---------------- T2 plain, per-row ladders ----------------
    log(f"\n[T2] plain path (chunk_d = 0: attention qk/av), per-row L from the {len(TRACE_LADDERS)} trace ladders")
    for i, lad in enumerate(TRACE_LADDERS):
        D = (128, 257, 136)[i % 3]                                  # qk head_dim, ViT av (32 blocks + 1 lane), 17 blocks
        L = ladder_rows(rng, lad, 24)
        ba, sa = gen_operands(rng, 24, D)
        bb, sb = gen_operands(rng, 8, D)
        ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
        run("plain_perrow", f"ladder {lad} D={D}", ref, ba, sa, bb, sb, L)
        ks = kernel_acc_plain_kstack(ba, sa, bb, sb, L)
        ks2 = kernel_acc_plain_kstack(ba, sa, bb, sb, L, stoc_len=int(max(lad)))
        if not (np.array_equal(ks, ref[0]) and np.array_equal(ks2, ref[0])):
            T.check(f"row-split == PER_ROW_LEN k-stack (ladder {lad})", False)
    for D, N, M in ((72, 32, 8), (2048, 16, 32) if not quick else (512, 16, 16)):   # every row its own L
        L = rng.integers(1, L_MAX + 1, size=N)
        L[:4] = (1, 16, 17, 128)
        ba, sa = gen_operands(rng, N, D)
        bb, sb = gen_operands(rng, M, D)
        ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
        run("plain_perrow", f"random L D={D}", ref, ba, sa, bb, sb, L)
        T.check(f"row-split == PER_ROW_LEN k-stack (random L, D={D})",
                np.array_equal(kernel_acc_plain_kstack(ba, sa, bb, sb, L), ref[0]))
    log(f"  plain per-row: {T.summary('plain_perrow')}")

    # ---------------- T3 chunked ----------------
    log("\n[T3] chunked path (MLP), mask index restarts per chunk, short last chunk, per-(row, chunk) rungs")
    for L in Ls:
        chunk_d, D = ((96, 296), (100, 330), (128, 440))[L % 3]
        ba, sa = gen_operands(rng, 8, D, "extreme" if L % 5 == 0 else "mixed")
        bb, sb = gen_operands(rng, 8, D)
        run("chunked", f"uniform L={L} chunk_d={chunk_d} D={D}", kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=L),
            ba, sa, bb, sb, L, chunk_d)
    for i, lad in enumerate(TRACE_LADDERS):                         # rung tables per (row, chunk)
        chunk_d, D = ((128, 440), (128, 584), (96, 296), (100, 330))[i % 4]   # 440 = 3x128 + 56, 584 = 4x128 + 72
        N = 16
        rung = rng.integers(0, len(lad), size=(N, -(-D // chunk_d)))
        rung.reshape(-1)[: len(lad)] = np.arange(len(lad))
        ba, sa = gen_operands(rng, N, D)
        bb, sb = gen_operands(rng, 8, D)
        stoc = L_MAX if i % 2 == 0 else int(max(lad))
        ref = kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=stoc, rung_table=rung, level_lens=lad)
        run("chunked", f"rungs {lad} chunk_d={chunk_d} D={D} stoc_len={stoc}", ref, ba, sa, bb, sb,
            np.asarray(lad)[rung], chunk_d)
    nrs = 0                                                         # row-subset calls == constant-rung table
    for lad in TRACE_LADDERS[:: max(1, len(TRACE_LADDERS) // 12)]:
        chunk_d, D, N = 128, 440, 16
        L = ladder_rows(rng, lad, N)
        ba, sa = gen_operands(rng, N, D)
        bb, sb = gen_operands(rng, 8, D)
        lens = sorted(set(int(v) for v in L))
        rung = np.repeat(np.array([lens.index(int(v)) for v in L])[:, None], -(-D // chunk_d), axis=1)
        a1 = kernel_acc_chunked_rowsplit(ba, sa, bb, sb, chunk_d, L)
        a2 = kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len=L_MAX, rung_table=rung, level_lens=lens)
        nrs += int(np.count_nonzero(a1 != a2))
        run("chunked", f"row-split {lad}", a1, ba, sa, bb, sb, L, chunk_d)
    T.check("chunked: row-subset calls at stoc_len=L == one rung-table call (rung constant per row)", nrs == 0, f"{nrs} bad")
    # Protected-channel split: the protected input channels are gathered into their own call at the protected L,
    # the rest run with the rung table.  Two independent calls.
    D, chunk_d, N = 1000, 128, 16
    prot = np.sort(rng.choice(D, size=60, replace=False))
    rest = np.setdiff1d(np.arange(D), prot)
    ba, sa = gen_operands(rng, N, D)
    bb, sb = gen_operands(rng, 8, D)
    lad = [97, 64, 48, 32, 25, 18, 128]
    rung = rng.integers(0, len(lad), size=(N, -(-len(rest) // chunk_d)))
    for cols, kw, Lh, nm in ((prot, dict(stoc_len=84), 84, "protected 60 ch @84 (D<=chunk_d: standard path)"),
                             (rest, dict(stoc_len=L_MAX, rung_table=rung, level_lens=lad), np.asarray(lad)[rung],
                              "unprotected 940 ch, rungs")):
        g4 = [x[:, cols] for x in (ba, sa, bb, sb)]
        run("chunked", nm, kernel_acc_chunked(*g4, chunk_d, **kw), *g4, Lh, chunk_d)
    ba, sa = gen_operands(rng, 8, 100)
    bb, sb = gen_operands(rng, 8, 100)
    T.check("chunked with D <= chunk_d == plain path", np.array_equal(
        kernel_acc_chunked(ba, sa, bb, sb, 128, stoc_len=64)[0], kernel_acc_plain(ba, sa, bb, sb, 64)))
    log(f"  chunked: {T.summary('chunked')}")

    # ---------------- T4 batched (per-head / per-row 3D) ----------------
    log("\n[T4] batched path (per_head, per_row 3D): D = 64 / 128 per head, uniform L = every value in 1..128")
    for L in Ls:
        D, BH = (64 if L % 2 else 128), 3
        ops = [gen_operands(rng, 8, D, "extreme" if L % 9 == 0 else "mixed") for _ in range(BH)]
        opw = [gen_operands(rng, 8, D) for _ in range(BH)]
        ba, sa = (np.stack([o[i] for o in ops]) for i in (0, 1))
        bb, sb = (np.stack([o[i] for o in opw]) for i in (0, 1))
        T.add("batched", f"L={L} D={D} BH={BH}", kernel_acc_batched(ba, sa, bb, sb, L),
              {s: hw_acc_batched(ba, sa, bb, sb, L, shape=SHAPES[s]) for s in shapes}, BH * 8 * 8 * D)
    log(f"  batched: {T.summary('batched')}")

    # ---------------- T5 from_float end to end ----------------
    log("\n[T5] from_float -> kernel == emulation (operand contract from the kernel quantizers)")
    for path in ("per_row", "per_row_3d", "chunked", "per_head", "per_tensor"):
        if path in ("per_row_3d", "per_head"):
            xa = (rng.standard_normal((2, 8, 128)) * rng.choice([0.01, 1, 30], size=(2, 8, 1))).astype(np.float32)
            xb = rng.standard_normal((2, 8, 128)).astype(np.float32)
            xa[0, 0, :5] = 0.0
            ba, sa, _ = from_float(xa, path)
            bb, sb, _ = from_float(xb, path)
            ref = kernel_acc_batched(ba, sa, bb, sb, 97)
            outs = {s: hw_acc_batched(ba, sa, bb, sb, 97, shape=SHAPES[s]) for s in shapes}
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
            outs = af(ba, sa, bb, sb, 64, cd)
            macs = ba.size * bb.shape[0]
        vals = np.unique(np.concatenate([ba.ravel(), bb.ravel()]))
        contract = (vals.min() >= 0 and vals.max() <= GRID and 64 not in vals
                    and not np.any((sa == 0) & (ba != 0)) and not np.any((sb == 0) & (bb != 0)))
        T.check(f"from_float({path}): b in 0..128 without 64, sign 0 only at b = 0", bool(contract))
        T.add("from_float", path, ref, outs, macs)
    # A small gathered linear call (d_in 77 at chunk_d 128) takes the standard path and its grouped quantizer.
    xa = (rng.standard_normal((16, 77)) * rng.choice([0.01, 1, 30], size=(16, 1))).astype(np.float32)
    xb = rng.standard_normal((8, 77)).astype(np.float32)
    ba, sa, sca = from_float(xa, "chunked", 128)
    bb, sb, _ = from_float(xb, "chunked", 128)
    bp, sp, scp = from_float(xa, "per_row")
    T.check("from_float(chunked, 128) at D = 77 (standard path) == grouped per_row quantizer, scale (rows, 1)",
            np.array_equal(ba, bp) and np.array_equal(sa, sp) and sca.shape == (16, 1) and np.array_equal(sca[:, 0], scp))
    T.add("from_float", "chunked D=77 <= chunk_d (standard path)", kernel_acc_chunked(ba, sa, bb, sb, 128, stoc_len=84),
          af(ba, sa, bb, sb, 84, 128), ba.size * bb.shape[0])

    # ---------------- T6 invariances + independent reference ----------------
    log("\n[T6] invariances and independent reference")
    ba, sa = gen_operands(rng, 16, 136)
    bb, sb = gen_operands(rng, 8, 136)
    L = ladder_rows(rng, [128, 97, 64, 33, 18, 1], 16)
    ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
    for s, out in af(ba, sa, bb, sb, L, full_cycles=True).items():
        T.check(f"{geo[s].name} with all {geo[s].CYC} cycles every block == kernel", np.array_equal(out, ref))
    cosim = SOREN_PAYN / "designs" / "payn" / "cosim" / "cosim_streaming.py"
    if cosim.exists():                                              # an independent numpy C-BSG (read-only)
        spec = importlib.util.spec_from_file_location("_soren_cosim_streaming", cosim)
        cs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cs)
        nb = 0
        for L in (128, 97, 64, 43, 16, 1):
            ba, sa = gen_operands(rng, 8, 136)
            bb, sb = gen_operands(rng, 8, 136)
            batches = [dict(d_base=lo, AMAG=ba[:, lo:lo + 8].astype(np.int64), ASIGN=(sa[:, lo:lo + 8] < 0).astype(np.int64),
                            WMAG=bb[:, lo:lo + 8].astype(np.int64), WSIGN=(sb[:, lo:lo + 8] < 0).astype(np.int64))
                       for lo in range(0, 136, 8)]
            soren = cs.reference(dict(K=8, NH=8, NW=8, OWIDTH=40, T=L), batches)
            nb += int(np.count_nonzero(soren != kernel_acc_plain(ba, sa, bb, sb, L)))
        T.check("soren cosim_streaming.reference (independent numpy C-BSG) == kernel_acc_plain, 6 lengths", nb == 0,
                f"{nb} bad")
    else:
        log(f"  (skip: {cosim} not found)")

    # ---------------- T7 sensitivity (each fault must be caught) ----------------
    log("\n[T7] sensitivity: injected faults must produce mismatches")
    ba, sa = gen_operands(rng, 8, 296)
    bb, sb = gen_operands(rng, 8, 296)
    ref = kernel_acc_chunked(ba, sa, bb, sb, 96, stoc_len=97)
    for s, g in geo.items():
        for fault in ("call_d", "no_slice_reset", "global_mask", "no_phase_reset"):
            n = int(np.count_nonzero(hw_af_acc(ba, sa, bb, sb, 97, 96, shape=SHAPES[s], fault=fault) != ref))
            T.check(f"{g.name} fault {fault} (one call, chunk_d=96, L=97) detected", n > 0, f"({n} accumulators differ)")
    ba, sa = gen_operands(rng, 8, 128)
    bb, sb = gen_operands(rng, 8, 128)
    L = np.array([97, 64, 33, 18, 128, 100, 5, 49])
    ref = kernel_acc_plain(ba, sa, bb, sb, L)[None]
    for s, g in geo.items():
        n = int(np.count_nonzero(hw_af_acc(ba, sa, bb, sb, L, shape=SHAPES[s], fault="af_ka_eq_b") != ref))
        T.check(f"{g.name} fault kA = min(bA, L) detected", n > 0, f"({n} accumulators differ)")

    # ---------------- T8 calls back to back (mask state across calls) ----------------
    log("\n[T8] calls back to back on one instance, no reset in between: where the scrambling-mask issue bites")
    for fault, what in MASK_FAULTS.items():
        log(f"    {fault:15s} {what}")

    def seq_check(name, calls, refs, caught):
        """Kernel == emulation on the sequence; then every mask fault: those in caught[K] must leave accumulators
        wrong, every other one none (this pins where the issue does not bite)."""
        tot = sum(r.size for r in refs)
        macs = sum(c["ba"].shape[0] * c["bb"].shape[0] * c["ba"].shape[1] for c in calls)
        flat = lambda xs: np.concatenate([x.reshape(-1) for x in xs])   # noqa: E731
        T.add("calls", name, flat(refs), {s: flat(hw_calls_acc(calls, shape=SHAPES[s])) for s in shapes}, macs)
        for s, g in geo.items():
            for fault in MASK_FAULTS:
                n = sum(int(np.count_nonzero(o != r)) for o, r in zip(hw_calls_acc(calls, fault, SHAPES[s]), refs))
                want = fault in caught[g.K]
                T.check(f"{g.name} {name}: {fault} {'caught' if want else 'harmless'}", (n > 0) if want else (n == 0),
                        f"({n} of {tot} wrong)")

    def call(ba, sa, bb, sb, cols, L, slice_len):
        return dict(ba=ba[:, cols], sa=sa[:, cols], bb=bb[:, cols], sb=sb[:, cols], L=L, slice_len=slice_len, cols=cols)

    # (1) one deployed chunk_d = 128 call with a padded tail, from reset: no mask fault is visible
    D, lad = 3973, [97, 64, 48, 32, 25, 18, 128]                    # d_in 3973 = 31 x 128 + 5
    ba, sa = gen_operands(rng, 8, D)
    bb, sb = gen_operands(rng, 8, D)
    rung = rng.integers(0, len(lad), size=(8, -(-D // 128)))
    ref = kernel_acc_chunked(ba, sa, bb, sb, 128, stoc_len=L_MAX, rung_table=rung, level_lens=lad)
    seq_check("one call chunk_d=128 D=3973 (tail 5)", [call(ba, sa, bb, sb, np.arange(D), np.asarray(lad)[rung], 128)],
              [ref], caught={8: (), 16: ()})
    # (2, 3) protected split of a down_proj (d_in 9144 at rungs + 584 at L = 84), gathered from scattered channels,
    # both orders.  At K16 the unprotected call has 572 blocks, a multiple of 4, so a free-running phase register
    # happens to enter the protected call at phase 0.
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
    seq_check("unprotected 9144 then protected 584", [cu, cp], [ru, rp],
              caught={8: gathered, 16: ("global_mask", "orig_channel_d")})
    seq_check("protected 584 then unprotected 9144", [cp, cu], [rp, ru], caught={8: gathered, 16: gathered})
    # (4) ViT av (chunk_d 0, d_in 257): consecutive (B, H) calls, per-row L
    calls, refs = [], []
    for _ in range(3):
        ba, sa = gen_operands(rng, 8, 257)
        bb, sb = gen_operands(rng, 8, 257)
        L = ladder_rows(rng, [128, 97, 64, 48, 32], 8)
        calls.append(call(ba, sa, bb, sb, np.arange(257), L, 0))
        refs.append(kernel_acc_plain(ba, sa, bb, sb, L)[None])
    av = ("global_mask", "no_phase_reset")
    seq_check("ViT av: 3 consecutive calls at D=257", calls, refs, caught={8: av, 16: av})
    # (5) ViT qk per_head (d_in 64): heads back to back, a whole number of phase periods per head
    ops = [gen_operands(rng, 8, 64) for _ in range(6)]
    ba, sa = (np.stack([o[i] for o in ops[:3]]) for i in (0, 1))
    bb, sb = (np.stack([o[i] for o in ops[3:]]) for i in (0, 1))
    ref = kernel_acc_batched(ba, sa, bb, sb, 64)
    seq_check("ViT qk per_head: 3 heads at D=64", [call(ba[h], sa[h], bb[h], sb[h], np.arange(64), 64, 0) for h in range(3)],
              [ref[h][None] for h in range(3)], caught={8: (), 16: ()})
    log(f"  calls: {T.summary('calls')}")

    # ---------------- summary ----------------
    log("\n[summary] kernel == A-first emulation, MACs = rows x cols x D summed over cases")
    for s, g in geo.items():
        tot = 0
        for (s2, path), rec in T.paths.items():
            if s2 == s:
                tot += rec["macs"]
                log(f"  {g.name:7s} {path:13s} cases {rec['cases']:4d}  MACs {rec['macs']:>11,}  mismatches {rec['bad']}")
        log(f"  {g.name:7s} total MACs {tot:,}")
    log(f"  failures {len(T.bad)}   {time.time() - t0:.1f} s")
    log("RESULT: " + ("PASS" if not T.bad else f"FAIL {T.bad[:10]}"))
    return 0 if not T.bad else 1


# ==================================================================================================================
# Exhaustive and table-level checks
# ==================================================================================================================

def _bitrev8_str(x):
    return int(f"{x & 0xFF:08b}"[::-1], 2)


def ka_exhaustive():
    """The closed-form A count against its definition kA = #{t < L : ((bitrev8(gray(t)) ^ mask) >> 1) < b} (A word t
    is bitrev8(gray(t)): identity directions), for every L 1..128, column mask bitrev8(d), d < 64, and b 0..128."""
    br = np.array([_bitrev8_str(x) for x in range(BASE)])
    t = np.arange(L_MAX)
    r = (br[t ^ (t >> 1)][None, :] ^ br[:N_MASKS, None]) >> 1               # (mask, t)
    b = np.arange(GRID + 1)
    brute = np.cumsum(r[:, :, None] < b, axis=1)                             # (mask, L - 1, b)
    closed = ka_closed(b, np.arange(1, L_MAX + 1)[:, None], br[:N_MASKS, None, None])
    bad = int(np.count_nonzero(brute != closed))
    print(f"kA closed form vs definition: {brute.size} cases (L 1..128 x 64 masks x b 0..128), {bad} mismatches")
    return int(bad != 0)


def check_tables(root=KERNEL_ROOT):
    """The emulation's A count and W samples against the scmp_kernels emulator's table code, written here
    independently of the kernel port: rng.py Sobol words, prefix [:L], bitrev scramble mask bit_reverse(d % 64, 8),
    floor(x * 128 / 256) (kernels.py:770-861); k_table[d, v] = #{t < L : v > rA[d, t]} (142-171);
    cum[d, k, v] = #{i < k : v > rB[d, i]} (104-139)."""
    q, k = (s.astype(np.int64) for s in base_sequences(Path(os.path.expanduser(str(root)))))
    mask = np.array([_bitrev8_str(d % N_MASKS) for d in range(BASE)])       # emulator mask of column d
    rA = ((q[None, :L_MAX] ^ mask[:N_MASKS, None]) * GRID) // BASE          # (d, t)
    rB = ((k[None, :L_MAX] ^ mask[:, None]) * GRID) // BASE                 # (d < 256, t)
    b = np.arange(GRID + 1)
    k_emu = np.cumsum(b[None, None, :] > rA[:, :, None], axis=1)            # (d, L - 1, b)
    k_hw = ka_closed(b, np.arange(1, L_MAX + 1)[:, None], mask[:N_MASKS, None, None])
    bad = int(np.count_nonzero(k_emu != k_hw))
    print(f"A count kA vs emulator k_table : {k_emu.size} cases, {bad} mismatches")
    rng = np.random.default_rng(0)                                          # product count: random (L, d, bA, bB)
    draws = np.array([[rng.integers(1, 129), rng.integers(0, 256), rng.integers(0, 129), rng.integers(0, 129)]
                      for _ in range(20000)])
    L, dd, bA, bB = draws.T
    kA = ka_closed(bA, L, mask[dd])
    t = np.arange(L_MAX)[None, :]
    emu = ((t < k_emu[dd % N_MASKS, L - 1, bA][:, None]) & (bB[:, None] > rB[dd])).sum(axis=1)
    rc = int(bad != 0)
    for name, (K, M) in SHAPES.items():
        g = geometry(K, M)
        d = np.arange(BASE)
        w_hw = (g.WBANK.reshape(-1)[None, :] ^ g.MASK[d % K, (d // K) % g.NPH][:, None]) >> 1   # (d, t)
        bw = int(np.count_nonzero(w_hw[:N_MASKS] != rB[:N_MASKS]))
        bc = int(np.count_nonzero(((t < L[:, None]) & (t < kA[:, None]) & (bB[:, None] > w_hw[dd])).sum(axis=1) != emu))
        print(f"{g.name:7s} W sample vs emulator rB prefix : {N_MASKS * L_MAX} cases, {bw} mismatches")
        print(f"{g.name:7s} product count vs emulator      : {len(L)} random (L, d, bA, bB), {bc} mismatches")
        rc |= int(bw != 0 or bc != 0)
    print("RESULT: " + ("PASS" if rc == 0 else "FAIL"))
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("selftest", help="kernel == A-first emulation on every path (exit 1 on any mismatch)")
    st.add_argument("--shape", choices=[*SHAPES, "all"], default="all")
    st.add_argument("--quick", action="store_true", help="a subset of L (smoke run)")
    st.add_argument("--log", help="also write the log to this file")
    sub.add_parser("ka-exhaustive", help="closed-form kA vs its definition, all 1,056,768 (L, mask, b)")
    ct = sub.add_parser("check-tables", help="kA, W samples and product counts vs the emulator's table code")
    ct.add_argument("root", nargs="?", default=str(KERNEL_ROOT), help="scmp_kernels checkout (default %(default)s)")
    args = ap.parse_args()
    if args.cmd == "selftest":
        return selftest(list(SHAPES) if args.shape == "all" else [args.shape], args.log, args.quick)
    if args.cmd == "ka-exhaustive":
        return ka_exhaustive()
    return check_tables(args.root)


if __name__ == "__main__":
    sys.exit(main())
