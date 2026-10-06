#!/usr/bin/env python3
"""INT8 area efficiency of the recommended MSB-first ring (FH <= 511, HYS
above) against the user's shift-down idea done once per pass (LSB-first,
arithmetic >>2 ring, 2 emitted bits per tile per rotation kept in a per-PE
buffer: 640 bits x 1.372 um2), using the schedule of gen_and_check.py (the one
the RTL runs used).  Areas are the design's cell-count estimates.
"""
from gen_and_check import schedule

RING, PRESET, EMIT = 147.882, 101.136, 640 * 1.372
for pr, pc, area in ((4, 4, 521892.1), (4, 8, 1016043.4)):
    n = pr * pc
    a_msb = area + n * RING + PRESET
    a_lsb = area + n * (RING + EMIT) + PRESET
    sc = lambda a: n * 64 * 0.4 / a * 1e6
    print(f"grid {pr}x{pc}: add-on MSB +{100 * (a_msb - area) / area:.2f}%, LSB "
          f"+{100 * (a_lsb - area) / area:.2f}%; SC GMAC/s/mm2 {sc(area):.1f} -> "
          f"MSB {sc(a_msb):.1f}, LSB {sc(a_lsb):.1f}")
    for L in (256, 511, 600, 768, 1024, 1536, 2048, 3072, 4096, 8191):
        best = None
        for v, ch in (("FH", 511), ("HYS", 8191)):
            if v == "FH" and L > 511:
                continue
            s, _, _ = schedule("INT8", v, L, pr, pc, ch)
            u = (32 if v == "HYS" else 64) * L / (64 * len(s))
            best = max(best or (0, ""), (u, v))
        s, _, _ = schedule("INT8", "LSB", L, pr, pc, 262143)
        ul = L / len(s)
        gm, gl = best[0] * n * 25.6 / a_msb * 1e6, ul * n * 25.6 / a_lsb * 1e6
        print(f"   L={L:5d}: MSB {best[1]:3s} {best[0]:.3f} ({gm:6.1f})  LSB {ul:.3f} "
              f"({gl:6.1f})  {'LSB' if gl > gm else 'MSB'} better by {100 * abs(gl / gm - 1):.1f}%")
