#!/usr/bin/env python3
"""Recompute bit-plane HW-ring area / throughput with the SC-safe raw-bit port
fix, and confirm the 4x4 block period at L=1024 on the independent simulator.
Cell areas from design_round1.json ground facts (LEF footprints)."""
import numpy as np
import bp_ring_verify as v

OR2, AO21 = 0.392, 0.588
EDGE = 1024 * OR2 + 0.4                 # design: 401.8 per edge half
FIX = 512 * (AO21 - OR2)                # gate the 512 shared lines: cmp | (raw & int_mode)
RING, COMB = 163.0, 515.7
cfg = {"1x1": (1, 1, 44018.0), "4x4": (4, 4, 521892.0), "4x8": (4, 8, 1016043.0)}
F = 0.4e9
print("area (um2, % of SC composite)       design         with AO21 gate on shared lines")
for k, (pr, pc, base) in cfg.items():
    halves = pr + pc
    a0 = halves * EDGE + pr * COMB + pr * pc * RING
    a1 = a0 + halves * FIX
    sc0 = pr * pc * 64 * F / 1e9 / ((base + a0) * 1e-6)
    sc1 = pr * pc * 64 * F / 1e9 / ((base + a1) * 1e-6)
    print(f"  {k}: {a0:8.1f} ({100*a0/base:.2f}%)  SC {sc0:.1f} GMAC/s/mm2 | "
          f"{a1:8.1f} ({100*a1/base:.2f}%)  SC {sc1:.1f}")

def period(L, bw=8, pr=4, pc=4):
    nb = -(-L // 128)
    return bw * nb + 8 * (bw - 1) + (pr + pc - 2) + 8 * pc

print("\n4x4 INT8 HW-ring utilization (MAC/cycle/tile) and GMAC/s/mm2 (with fix)")
pr, pc, base = cfg["4x4"]
a1 = (pr + pc) * (EDGE + FIX) + pr * COMB + pr * pc * RING
for L in (1024, 4096, 16384):
    cyc = period(L)
    macs = 4 * 32 * L
    u = macs / cyc / 1024
    print(f"  L={L:5d}: {cyc} cycles/block, {u:.3f} MAC/cyc/tile, "
          f"{macs / cyc * F / 1e9 / ((base + a1) * 1e-6):.0f} GMAC/s/mm2")
print(f"  peak: {2048 * F / 1e9 / ((base + a1) * 1e-6):.0f} GMAC/s/mm2")

rng = np.random.default_rng(5)
A = rng.integers(-128, 128, (5, 1024)); W = rng.integers(-128, 128, (1024, 32))
ok, out, ref, n, per = v.gemm_ok(A, W, "HW", 8, 8, 4, 4, rng=rng)
print(f"\nindependent sim 4x4 INT8 L=1024 (2 blocks): {'exact' if ok else 'MISMATCH'}, "
      f"measured block period {per} (formula {period(1024)})")
