#!/usr/bin/env python3
"""Estimate table: PaYN INT modes and SC versus dedicated binary OS arrays.

Measured inputs (routed layouts, max-SDF GL, PT-PX): BOS INT6/INT4
(build/bos_precision/bos_precision_20261002), BOS INT8 (older flow,
doc/results.md), CSA SC T sweep, bit-plane and spatial-Booth INT energy runs.
Estimated inputs are labelled in the 'basis' column: INT-mode areas (bit-plane
cell count, spatial Booth synthesized edge blocks), all INT6 PaYN rows (no INT6
mapping was built or measured), ring/drain/skew cycle energies composed from
measured per-cycle energies, and 4x4 composites (16 x u_pe + 4 peripherals +
Sobol pair; no grid has been routed).
"""
import csv
from pathlib import Path

F = 0.4  # GHz
A1, A4 = 44017.974, 521892.14            # CSA single PE, 4x4 composite (um2)
BP_ADD1, BP_ADD4 = 1802.0, 8863.0        # bit-plane all-in adds (cell-count estimate, verified)
CN_ADD1, CN_ADD4 = 2462.0, 9538.0        # spatial Booth all-in adds (synthesized blocks, verified)
L = 4096

def eff(gmacs, area_um2): return gmacs / (area_um2 / 1e6)

rows = []
def add(prec, design, basis, a1, a4, mac_tile_peak, mac_tile_eff1, mac_tile_eff4, pj1, pj4, bits):
    g_pk1, g_pk4 = 64 * mac_tile_peak * F, 16 * 64 * mac_tile_peak * F
    rows.append(dict(precision=prec, design=design, basis=basis,
                     gmacs_mm2_peak_1pe=eff(g_pk1, a1) if a1 else None,
                     gmacs_mm2_peak_4x4=eff(g_pk4, a4),
                     gmacs_mm2_L4096_1pe=eff(64 * mac_tile_eff1 * F, a1) if a1 else None,
                     gmacs_mm2_L4096_4x4=eff(16 * 64 * mac_tile_eff4 * F, a4),
                     pJ_MAC_1pe=pj1, pJ_MAC_4x4=pj4,
                     fJ_per_bit_product_4x4=(pj4 * 1000 / bits ** 2) if bits else None))

# --- dedicated binary OS 8x8 arrays (64 MAC/cycle; area efficiency independent of tiling) ---
for prec, area, pj, b, basis in (("INT8", 15797.0, 0.41247, 8, "routed, older flow (+-~4%)"),
                                  ("INT6", 12403.664, 0.2601438, 6, "routed 2026-10-02"),
                                  ("INT4", 10276.378, 0.1552257, 4, "routed 2026-10-02")):
    g = 64 * F
    rows.append(dict(precision=prec, design="BOS binary 8x8", basis=basis,
                     gmacs_mm2_peak_1pe=eff(g, area), gmacs_mm2_peak_4x4=eff(g, area),
                     gmacs_mm2_L4096_1pe=eff(g, area), gmacs_mm2_L4096_4x4=eff(g, area),
                     pJ_MAC_1pe=pj, pJ_MAC_4x4=pj, fJ_per_bit_product_4x4=pj * 1000 / b ** 2))

# --- bit-plane (BP): per-cycle energies measured on the routed CSA PE ---
E_RING = 14.3      # pJ per ring/drain/skew cycle (measured ring cycles, L1024 dr vs d)
E_BP_EXTRA = 1.0   # mW of unmodelled BP cells during data cycles (bypass ORs, raw-bit wires,
                   # ring mux, combiner): the verified ~+0.02 pJ/MAC at 128 MAC/cycle
def bp(prec, bits_a, passes, rows_active, e_data, outputs_pe, bits, basis):
    mac_cycle_peak = outputs_pe * 128 / passes                     # per PE, data cycles
    mac_tile_peak = mac_cycle_peak / 64
    data = passes * (L // 128)
    c1 = data + 8 * (passes - 1) + 8                                # 1 PE: ring laps + drain
    c4 = data + 8 * (passes - 1) + 6 + 32                           # 4x4: + skew + 8*P_C drain
    macs = outputs_pe * L
    extra = E_BP_EXTRA * 2.5                                        # pJ per cycle
    pj1 = (data * (e_data + extra) + (c1 - data) * E_RING) / macs
    pj4 = (data * (e_data + extra) + (c4 - data) * E_RING) / macs
    add(prec, "PaYN bit-plane", basis, A1 + BP_ADD1, A4 + BP_ADD4, mac_tile_peak,
        macs / c1 / 64, macs / c4 / 64, pj1, pj4, bits)
bp("INT8", 8, 8, 8, 16.49606 * 2.5, 8, 8, "GL-measured data/ring energy; area cell-count est.")
bp("INT4", 4, 4, 8, 16.55108 * 2.5, 16, 4, "GL-measured data/ring energy; area cell-count est.")
# INT6: 6 of 8 activation-plane rows used, 6 weight passes; data-cycle energy scaled 0.75-0.9x of INT8
for lo_hi, scale in (("low", 0.75), ("high", 0.9)):
    bp("INT6", 6, 6, 6, 16.49606 * 2.5 * scale, 8, 6, f"ESTIMATE (no INT6 mapping built); data energy {scale}x INT8")

# --- spatial Booth (CNSB): measured on the unchanged routed netlist, uniform data ---
U1, U4 = 0.985, 0.931   # utilisation at L=4096 (1 PE, 4x4), verified
for prec, peak, pj1, pj4, b, basis in (
        ("INT8", 1, 0.79485, 0.66184, 8, "GL-measured energy; edge blocks synthesized"),
        ("INT4", 4, 0.19845, 0.16519, 4, "GL-measured energy; edge blocks synthesized"),
        # INT6 on the Booth mapping: 3 radix-4 digits -> 6 of 8 rows active, same MAC rate as INT8;
        # tile power x0.75, edge/PE overhead unchanged (from the INT8 uniform split)
        ("INT6", 1, (10.48 * 0.75 + 5.25694 + 4.49331 + 0.03743) * 2.5 / 64,
                    (10.48 * 0.75 + 5.25694 + 4.49331 / 4) * 2.5 / 64, 6, "ESTIMATE (no INT6 mapping built)")):
    add(prec, "PaYN spatial Booth", basis, A1 + CN_ADD1, A4 + CN_ADD4, peak, peak * U1, peak * U4, pj1, pj4, b)

# --- SC at the doc's nominal precision-equivalent T (approximate arithmetic, not integer-exact) ---
sweep = {(r["arm"], int(r["T"])): r for r in csv.DictReader(open("build/power_char/csa_t_sweep_20261003/results.csv"))}
for prec, T in (("INT8", 128), ("INT6", 32), ("INT4", 16)):
    r = sweep[("csa", T)]
    mac_tile = 128 / T
    p4 = 16 * float(r["u_pe_mW"]) + 4 * float(r["u_peripheral_mW"]) + float(r["sobol_mW"])
    add(prec, f"PaYN SC T={T} (nominal)", "routed + GL-measured; approximate, drain-excluded",
        A1, A4, mac_tile, mac_tile, mac_tile, float(r["pJ_MAC"]), p4 * 2.5 / (16 * 64 * mac_tile), None)

out = Path("build/power_char/int_mode_energy_20261003/int_vs_bos_estimate.csv")
with out.open("w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
fmt = lambda x, n=0: "-" if x is None else (f"{x:,.{n}f}")
for prec in ("INT8", "INT6", "INT4"):
    print(f"\n{prec}: design | GMAC/s/mm2 peak 1PE / 4x4 | at L=4096 1PE / 4x4 | pJ/MAC 1PE / 4x4 | fJ/bit-product (4x4) | basis")
    for r in rows:
        if r["precision"] != prec: continue
        print(f"  {r['design']:26s} | {fmt(r['gmacs_mm2_peak_1pe'])} / {fmt(r['gmacs_mm2_peak_4x4'])} | "
              f"{fmt(r['gmacs_mm2_L4096_1pe'])} / {fmt(r['gmacs_mm2_L4096_4x4'])} | "
              f"{fmt(r['pJ_MAC_1pe'],3)} / {fmt(r['pJ_MAC_4x4'],3)} | {fmt(r['fJ_per_bit_product_4x4'],2)} | {r['basis']}")
print(f"\n-> {out}")
