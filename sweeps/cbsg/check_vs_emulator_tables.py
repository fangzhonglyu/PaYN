#!/usr/bin/env python3
"""Check the hardware C-BSG A count (closed form) and W stream against the scmp_kernels emulator's own
table code, bit for bit.  Read-only use of ~/repos/scmp_kernels: rng.py (numpy only) is loaded by file path
with bytecode writing off; the torch lines of kernels.py are ported line for line (refs below).

Emulator path reproduced (scmp_kernels ce3d7e5, default C-BSG, grid 128 as in halve_bipolar / emu_golden):
  _get_cached_sequences   kernels.py:67-87    Sobol q (A) and k (W) sequences, 2**sc_prec samples, all columns equal
  _prepare_rng_prefix     kernels.py:814-861  prefix [:L], _owen_scramble, then floor(x * grid / 256)
  _owen_scramble bitrev   kernels.py:770-812  mask[d] = bit_reverse(d % 64, 8)  (HW_MAX_MASKS = 64)
  compute_k_table_kernel  kernels.py:142-171  k_table[d, v] = #{t < L : v > r[d, t]}
  build_cum_indicator     kernels.py:104-139  cum[d, k, v]  = #{i < k : v > rB[d, i]}
Usage: PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/check_vs_emulator_tables.py [path/to/scmp_kernels]
"""
import importlib.util, os, sys
import numpy as np

sys.dont_write_bytecode = True
root = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/repos/scmp_kernels")
spec = importlib.util.spec_from_file_location("emu_rng", os.path.join(root, "scmp_kernels/sc/rng.py"))
emu_rng = importlib.util.module_from_spec(spec); spec.loader.exec_module(emu_rng)

SC_PREC, GRID, MASKS = 8, 128, 64
BASE = 1 << SC_PREC
seq_q = emu_rng.Sobol(SC_PREC, seed_type="q").simulate(BASE).astype(np.int64)   # make_sobol_simple_config: q
seq_k = emu_rng.Sobol(SC_PREC, seed_type="k").simulate(BASE).astype(np.int64)   # make_sobol_simple_config: k

def bit_reverse(x, n):                       # kernels.py:722-727
    return sum(((x >> i) & 1) << (n - 1 - i) for i in range(n))

def emu_prefix(seq, L, d):                   # kernels.py:814-861 + 770-812 (bitrev, M = 64), one column d
    p = seq[:L] ^ bit_reverse(d % MASKS, SC_PREC)
    return (p * GRID) // BASE

def emu_k(b, L, d):                          # kernels.py:142-171 (strict: v > r)
    return int(np.sum(b > emu_prefix(seq_q, L, d)))

# --- hardware side ---------------------------------------------------------------------------------
def bitrev8(x): return bit_reverse(x, 8)
def gray(t): return t ^ (t >> 1)
def hw_k(b, L, d):                           # closed-form A encoder (sweeps/cbsg/ka_closed_form.py, ka_hw)
    m = bitrev8(d % 64); k = 0; s0 = 0
    for j in range(7, -1, -1):
        if L >> j & 1:
            s = 7 - j
            c = ((bitrev8(gray(s0)) ^ m) & ((1 << (8 - j)) - 1)) >> 1
            k += (b >> s) + (1 if (b & ((1 << s) - 1)) > c else 0)
            s0 += 1 << j
    return k

KDV = [0x80, 0x40, 0x20, 0x10, 0x48, 0x04, 0x52, 0xff]   # W "k" direction numbers in our / soren's sobol.sv
def hw_w_thr(t, d):                          # W sample t on the 7-bit grid: (X_k(t) ^ mask) >> 1
    x = 0
    for bit in range(8):
        if gray(t) >> bit & 1: x ^= KDV[bit]
    return (x ^ bitrev8(d % 64)) >> 1

# 1. A count, every L the RTL accepts (1..128), every mask, every magnitude 0..128
bad_k = [(b, L, d) for L in range(1, 129) for d in range(MASKS) for b in range(GRID + 1) if emu_k(b, L, d) != hw_k(b, L, d)]
print(f"A count kA vs emulator k_table : {128*MASKS*(GRID+1)} cases, {len(bad_k)} mismatches {bad_k[:3]}")

# 2. W stream: hardware sample t equals the emulator's rB prefix value, every t < 128, every mask
bad_w = [(t, d) for d in range(MASKS) for t in range(128) if hw_w_thr(t, d) != emu_prefix(seq_k, 128, d)[t]]
print(f"W sample vs emulator rB prefix : {MASKS*128} cases, {len(bad_w)} mismatches {bad_w[:3]}")

# 3. Product count: thermometer A AND free-running W == emulator cum[d, k_table[d, bA], bB]
rng = np.random.default_rng(0); bad_c = 0; n = 0
for _ in range(20000):
    L = int(rng.integers(1, 129)); d = int(rng.integers(0, 256)); bA = int(rng.integers(0, 129)); bB = int(rng.integers(0, 129))
    rB = emu_prefix(seq_k, L, d)
    emu = int(np.sum(bB > rB[:emu_k(bA, L, d)]))                       # cum[d, k_table[d, bA], bB]
    kA = hw_k(bA, L, d)
    hw = sum(1 for t in range(L) if t < kA and bB > hw_w_thr(t, d))     # AND of the two hardware streams
    bad_c += emu != hw; n += 1
print(f"product count vs emulator      : {n} random (L, d, bA, bB), {bad_c} mismatches")

# 4. Random A kept exactly as the kernel makes it, W still made once at the edge:
#    A bit at position t = [rA(d,t) < bA]                         (the kernel's own A stream, unchanged)
#    W bit at position t = [rB(d, s(t)) < bB],  s(t) = #{u < L : rA(d,u) < rA(d,t)}   (rank of A's random number)
#    s(t) depends on the column d, L and t only, never on any A value, so every row shares the same W bit.
#    A's ones sit exactly at the kA positions with the smallest rA, whose ranks are 0..kA-1, so the AND count is
#    #{i < kA : rB(d,i) < bB}, the C-BSG count.  s(t) is the closed-form encoder evaluated at b = rA(d,t).
bad_r = 0; n = 0
for _ in range(20000):
    L = int(rng.integers(1, 129)); d = int(rng.integers(0, 256)); bA = int(rng.integers(0, 129)); bB = int(rng.integers(0, 129))
    rA = emu_prefix(seq_q, L, d); rB = emu_prefix(seq_k, L, d)
    emu = int(np.sum(bB > rB[:emu_k(bA, L, d)]))
    hw = sum(1 for t in range(L) if bA > rA[t] and bB > hw_w_thr(hw_k(int(rA[t]), L, d), d))
    bad_r += emu != hw; n += 1
print(f"random A + rank-indexed edge W : {n} random (L, d, bA, bB), {bad_r} mismatches")
