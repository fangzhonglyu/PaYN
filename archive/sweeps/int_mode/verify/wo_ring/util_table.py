#!/usr/bin/env python3
"""Utilization (MAC/cycle/tile) and area-efficiency table for the WO-ring INT
mode from the independently written schedule in gen_and_check.py (the same
schedule the RTL runs used), steady state (back-to-back output blocks).

Areas: routed composite 4x4 = 521,892.1 um2, 4x8 = 1,016,043.4 um2,
single PE = 44,017.974 um2; WO-ring adder per the design: 147.882 um2/PE
plus 101.136 um2 per grid (cell-count estimate, not synthesized).
"""
from gen_and_check import schedule

F = 0.4  # GHz
GRIDS = {(1, 1): 44017.974, (4, 4): 521892.1, (4, 8): 1016043.4}
CLAIM = {("INT8", 1, 1): (0.912, 0.941, 0.985), ("INT8", 4, 4): (0.866, 0.892, 0.971),
         ("INT8", 4, 8): (0.816, 0.839, 0.954), ("W4A8", 4, 4): (1.607, 1.784, 1.941),
         ("INT4", 4, 4): (2.937, 3.391, 3.828)}


def util(mode, L, pr, pc):
    best = None
    for variant in (("FH", "HYS") if mode == "INT8" else ("HO",)):
        chunk = {"FH": 511, "HYS": 8191, "HO": 8191 if mode == "W4A8" else 131071}[variant]
        if variant == "FH" and L > 511:
            continue                       # FH is only used inside its chunk limit
        slots, _, _ = schedule(mode, variant, L, pr, pc, chunk)
        outs_per_pe = 32 if variant == "HYS" else 64
        u = outs_per_pe * L / (64 * len(slots))
        if best is None or u > best[0]:
            best = (u, variant, len(slots))
    return best


print(f"{'mode':5s} {'grid':5s} {'L':>5s} {'variant':7s} {'slots':>6s} {'MAC/cyc/tile':>12s} "
      f"{'claim':>6s} {'GMAC/s/mm2':>10s}")
for (mode, pr, pc), claims in CLAIM.items():
    area = GRIDS[(pr, pc)] + pr * pc * 147.882 + 101.136
    for L, cl in zip((511, 1024, 4096), claims):
        u, var, ns = util(mode, L, pr, pc)
        g = u * 64 * pr * pc * F / (area * 1e-6)
        flag = "" if abs(u - cl) < 0.0015 else "  <-- differs"
        print(f"{mode:5s} {pr}x{pc:<3d} {L:5d} {var:7s} {ns:6d} {u:12.3f} {cl:6.3f} {g:10.1f}{flag}")
sc = {k: 64 * k[0] * k[1] * F / (v * 1e-6) for k, v in GRIDS.items()}
print("SC T=128 GMAC/s/mm2 without/with the INT add-on:",
      {f"{k[0]}x{k[1]}": (round(v, 1), round(64 * k[0] * k[1] * F / ((GRIDS[k] + k[0] * k[1] * 147.882 + 101.136) * 1e-6), 1))
       for k, v in sc.items()})
# utilization vs L for INT8 4x4 (the knee and the FH/HYS switch)
print("INT8 4x4 utilization vs L:")
for L in (64, 128, 256, 384, 511, 512, 768, 1024, 2048, 4096, 8191, 16384):
    u, var, ns = util("INT8", L, 4, 4)
    print(f"   L={L:6d}: {u:.3f} ({var})")
