#!/usr/bin/env python3
"""ESTIMATE (not synthesized): lap sub-ring length g as a knob between the BP ring and IPD.

Split each tile row's 8-tile ring into 8/g sub-rings of g tiles.  The head
tile of each sub-ring gets a 24-bit 2:1 mux (west neighbour, or the sub-ring's
tail << 1); the other tiles keep their plain west input.  A lap is g edges of
ring_q and doubles every tile exactly once (the BP ring is g = 8, in-place
doubling is g = 1).  No tile change, and the drain/SC path is unchanged.

  mux bits per PE = (8/g) * 8 rows * 24
  area delta vs the BP ring (g=8, 192 mux bits) = (bits - 192) * cost_per_bit
  cost_per_bit from the two synthesized runs (IPD - lap: +969.6 um2 for +1,344 bits,
  select buffering included) -> 0.721 um2/bit
  period = BW*NB + g*(BW-1) + (P_R+P_C-2) + 8*P_C      (single PE: + 8, no skew)

Areas: routed pinned csa_bp_20261004_lap composites + 16/32 x per-PE delta, the
same method as ipd_area_efficiency.py (whose g=1 row this reproduces).
"""
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
eff = json.loads((REPO / "build/rtl_preflight/bp_ipd/area_efficiency.json").read_text())
lap = eff["composites"]["lap (routed)"]
syn = eff["syn"]
d_ipd = syn["ipd"]["total"] - syn["lap"]["total"]
cost_bit = d_ipd / (1536 - 192)
csa_4x4, csa_1pe = 521100.2, 43916.5      # pinned CSA, build/power_char/pinned_pass2_csa_bp_20261004_lap/comparison.txt

print(f"mux cost per bit (IPD - lap synthesized): {cost_bit:.3f} um2")
print("g  muxbits  dPE_um2  | 4x4 INT8 L=4096: period util GMAC/s/mm2 | L=1024: period GMAC/s/mm2 | "
      "4x8 L=4096 period GMAC/s/mm2 | SC 4x4 (vs lap, vs CSA) | SC 4x8")
for g in (8, 4, 2, 1):
    bits = (8 // g) * 8 * 24
    dpe = (bits - 192) * cost_bit
    row = []
    for shape, n, pr, pc in (("4x4", 16, 4, 4), ("4x8", 32, 4, 8)):
        area = lap[shape] + n * dpe
        peak_int8 = 128 * n * 0.4 / (area / 1e6)
        sc = 64 * n * 0.4 / (area / 1e6)
        res = {}
        for L in (1024, 4096):
            nb = L // 128
            per = 8 * nb + g * 7 + (pr + pc - 2) + 8 * pc
            res[L] = (per, 8 * nb / per, peak_int8 * 8 * nb / per)
        row.append((shape, area, sc, res))
    (s4, a4, sc4, r4), (s8, a8, sc8, r8) = row
    sc4_lap = 64 * 16 * 0.4 / (lap["4x4"] / 1e6)
    sc8_lap = 64 * 32 * 0.4 / (lap["4x8"] / 1e6)
    sc4_csa = 64 * 16 * 0.4 / (csa_4x4 / 1e6)
    print(f"{g}  {bits:6d}  {dpe:+7.1f}  | {r4[4096][0]:4d} {r4[4096][1]:6.1%} {r4[4096][2]:7.1f} | "
          f"{r4[1024][0]:4d} {r4[1024][2]:6.1f} | {r8[4096][0]:4d} {r8[4096][2]:7.1f} | "
          f"{sc4:6.1f} ({100*(sc4/sc4_lap-1):+.2f}%, {100*(sc4/sc4_csa-1):+.2f}%) | {sc8:6.1f} ({100*(sc8/sc8_lap-1):+.2f}%)")
