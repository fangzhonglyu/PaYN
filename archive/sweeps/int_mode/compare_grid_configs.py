#!/usr/bin/env python3
"""Side-by-side 4x4 / 4x8 grid composites: PaYN SC, PaYN bit-plane INT, binary BOS.

Composite = N_PE x routed u_pe + (edge halves / 2) x routed peripheral
          + N_rows x combiner (BP only) + one Sobol pair, with the matching
hierarchy powers.

Sources:
- BP blocks and SC power: pinned BP route.
- CSA blocks: pinned CSA route at T=128; the floating route for the T sweep.
- INT per-cycle energies (data / ring / drain, u_pe and rest) and edge/combiner/
  Sobol shares: the pinned routed INT measurement.
- BOS: routed single arrays (INT8 older flow); they tile without shared edges.

"L=4096" adds the schedule overheads of an output block:
- INT: weight passes x 32 data cycles, 8-cycle ring laps between passes, skew
  P_R+P_C-2 and an 8*P_C drain.
- SC: L*T/128 cycles (L/K lane-blocks x T/M clocks), plus skew and drain.

Skew and drain cycles are charged the measured drain-cycle energy. No grid has
been routed.
"""
import csv
from pathlib import Path

F = 0.4  # GHz
L = 4096
GRIDS = {"4x4": (4, 4), "4x8": (4, 8)}

def areas(run):
    d = {}
    for line in (Path("apr/build") / run / "reports/area.rpt").read_text().splitlines():
        f = line.split()
        if f and f[0] in ("u_pe", "u_peripheral", "u_a_rng", "u_w_rng", "u_combiner") and f[0] not in d:
            d[f[0]] = float(f[3])
    d["sobol"] = d["u_a_rng"] + d["u_w_rng"]
    return d

BP = areas("TSMC22/PAYN_SC_CSA_BP/csa_bp_20261003b_distguide_spp_pins")
CSA_PIN = areas("TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins")
CSA_FLT = areas("TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_fixed")

def grid_area(a, pr, pc, comb=False):
    return pr * pc * a["u_pe"] + (pr + pc) / 2 * a["u_peripheral"] + (pr * a["u_combiner"] if comb else 0) + a["sobol"]

rows = []
def add(group, design, basis, g, gmacs_pk, gmacs_L, pj_pk, pj_L):
    rows.append(dict(group=group, design=design, grid=g, gmacs_mm2_peak=gmacs_pk, gmacs_mm2_L4096=gmacs_L,
                     pJ_MAC_peak=pj_pk, pJ_MAC_L4096=pj_L, basis=basis))

def sc_rows(group, design, basis, a, T, u_pe, periph, sobol, comb_mW=0.0, comb=False, e_drain_pe=14.5):
    for g, (pr, pc) in GRIDS.items():
        n = pr * pc
        area = grid_area(a, pr, pc, comb)
        mac = n * 64 * 128 / T                                   # MAC/cycle, grid
        p = n * u_pe + (pr + pc) / 2 * periph + sobol + (pr * comb_mW if comb else 0)
        cyc = L * T / 128                                       # data cycles per output block: L/K lane-blocks x T/M clocks
        ovh = (pr + pc - 2) + 8 * pc
        util = cyc / (cyc + ovh)
        e_blk = p * 2.5 * cyc + ovh * (n * e_drain_pe + ((pr + pc) / 2 * periph + sobol) * 2.5)
        add(group, design, basis, g, mac * F / (area / 1e6), mac * util * F / (area / 1e6),
            p * 2.5 / mac, e_blk / (mac * cyc))

# --- SC on the carry-save design (T sweep, floating layout) ---
sweep = {(r["arm"], int(r["T"])): r for r in csv.DictReader(open("build/power_char/csa_t_sweep_20261003/results.csv"))}
for prec, T in (("~INT8 (SC)", 128), ("~INT6 (SC)", 32), ("~INT4 (SC)", 16)):
    r = sweep[("csa", T)]
    sc_rows(prec, f"PaYN carry-save SC, T={T}", "routed CSA (floating pins) + T sweep; approximate arithmetic",
            CSA_FLT, T, float(r["u_pe_mW"]), float(r["u_peripheral_mW"]), float(r["sobol_mW"]))
# --- SC T=128 on the pinned layouts: CSA alone and the BP design in SC mode ---
pc_ = next(csv.DictReader(open("build/power_char/pinned_pass2_20261004/csa/result.csv")))
pb_ = next(csv.DictReader(open("build/power_char/pinned_pass2_20261004/csa_bp/result.csv")))
sc_rows("~INT8 (SC)", "PaYN carry-save SC, T=128 (pinned)", "routed, pinned pass 2", CSA_PIN, 128,
        float(pc_["u_pe_mW"]), float(pc_["u_peripheral_mW"]), float(pc_["sobol_mW"]))
sc_rows("~INT8 (SC)", "PaYN with bit-plane HW, SC T=128 (pinned)", "routed, pinned pass 2", BP, 128,
        float(pb_["u_pe_mW"]), float(pb_["u_peripheral_mW"]), float(pb_["sobol_mW"]), comb_mW=0.01106, comb=True)

# --- bit-plane INT on the routed BP (pinned) ---
res = {r["label"]: r for r in csv.DictReader(open(
    "build/power_char/int_mode_energy_20261003/bp/csa_bp_20261003b_distguide_spp_pins/results.csv"))}
# per-PE u_pe energies per cycle (pJ) from the routed measurement (summary.log)
E = {"INT8": (42.89, 14.58, 14.45), "W4A8": (42.98, 14.65, 12.81), "INT4": (43.02, 14.94, 12.85)}
PEAK = {"INT8": "int8_uniform_L49152_d", "W4A8": "w4a8_uniform_L98304_d", "INT4": "int4_uniform_L98304_d"}
SHAPE = {"INT8": (8, 8), "W4A8": (4, 8), "INT4": (4, 16)}      # (weight passes, outputs per PE)
def bp_rows(prec, e_data_scale=1.0, basis="routed BP (pinned), GL-measured per-cycle energies"):
    key = "INT8" if prec == "INT6" else prec
    r = res[PEAK[key]]
    periph, comb, sobol = (float(r["u_peripheral_mW"]), float(r["u_combiner_mW"]), float(r["sobol_mW"]))
    ed, er, edr = E[key]
    ed *= e_data_scale
    passes, outs = (6, 8) if prec == "INT6" else SHAPE[prec]
    for g, (pr, pc) in GRIDS.items():
        n = pr * pc
        area = grid_area(BP, pr, pc, comb=True)
        mac_pk = n * outs * 128 / passes
        edge_pc = ((pr + pc) / 2 * periph + pr * comb + sobol) * 2.5      # pJ per cycle, grid
        data, ring, ovh = passes * (L // 128), 8 * (passes - 1), (pr + pc - 2) + 8 * pc
        cyc = data + ring + ovh
        macs = n * outs * L
        e_blk = n * (data * ed + ring * er + ovh * edr) + cyc * edge_pc
        add(prec, "PaYN bit-plane INT", basis, g, mac_pk * F / (area / 1e6), macs / cyc * F / (area / 1e6),
            (n * ed + edge_pc) / mac_pk, e_blk / macs)
bp_rows("INT8"); bp_rows("W4A8"); bp_rows("INT4")
for s in (0.75, 0.90):
    bp_rows("INT6", s, f"ESTIMATE: no INT6 mapping built; 6 rows x 6 passes, data energy {s}x INT8")

# --- dedicated binary OS 8x8 arrays (tiled) ---
for prec, area, pj, basis in (("INT8", 15797.0, 0.41247, "routed, older flow (+-~4%)"),
                              ("INT6", 12403.664, 0.2601438, "routed 2026-10-02"),
                              ("INT4", 10276.378, 0.1552257, "routed 2026-10-02")):
    for g in GRIDS:
        eff = 64 * F / (area / 1e6)
        util = L / (L + 8 + 14)            # 8-cycle drain + skew per output block at D=L
        add(prec, "binary 8x8 OS (BOS)", basis, g, eff, eff * util, pj, pj / util)

out = Path("build/power_char/int_mode_energy_20261003/grid_config_comparison.csv")
with out.open("w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
order = ["INT8", "~INT8 (SC)", "INT6", "~INT6 (SC)", "W4A8", "INT4", "~INT4 (SC)"]
for g in GRIDS:
    print(f"\n### {g}: GMAC/s/mm2 (peak / L=4096) | pJ/MAC (peak / L=4096)")
    for grp in order:
        for r in rows:
            if r["grid"] == g and r["group"] == grp:
                print(f"  {grp:11s} {r['design']:44s} {r['gmacs_mm2_peak']:7,.0f} / {r['gmacs_mm2_L4096']:7,.0f} | "
                      f"{r['pJ_MAC_peak']:.3f} / {r['pJ_MAC_L4096']:.3f}   [{r['basis']}]")
print(f"\n-> {out}")
