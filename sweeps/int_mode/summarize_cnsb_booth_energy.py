#!/usr/bin/env python3
"""Summarize the CNSB INT energy campaign against the SC references.

Inputs (all measured, nothing re-simulated):
  build/power_char/int_mode_energy_20261003/cnsb_booth/results.csv and each
  point's power/ reports (run_cnsb_booth_energy.sh), and the carry-save T-sweep
  reports build/power_char/csa_t_sweep_20261003/csa/T{128,16}/power/ for SC.

For every point it prints and writes (summary.csv / summary.json):
  * single-PE full and u_pe-only pJ/MAC (P x 2.5 ns / MAC per cycle per PE),
  * a u_pe breakdown from power_hier.rpt: 64 tiles (of which the 512 lane
    counters) and the rest of u_pe (bit pipes, sign pipes, clock gates,
    buffers),
  * grid composites, the same composition the README uses for area:
      P = PR*PC*(u_pe + top-level residual) + PR*periph_A + PC*periph_W + Sobol,
    with each edge half = periph/2 (exact for square grids: PR*(A+W)),
  * ratios to SC T=128 and T=16 composed the same way.
Estimates of what the measurement does not include are computed from stated
assumptions (see NOT_MODELLED below) and written to the JSON.
"""
from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "build/power_char/int_mode_energy_20261003/cnsb_booth"
SC = REPO / "build/power_char/csa_t_sweep_20261003/csa"
PERIOD = 2.5
GRIDS = [(1, 1), (4, 4), (4, 8)]
PERIPH_AREA = 12792.92        # synthesized peripheral, um2 (routed within 0.1%)
DESIGN_AREA = 44017.974       # routed CSA single-PE array, um2
# Area estimates from the round-1 design (model_red_team_novel.py cost table)
FEED_A_HALF = 564.5           # 64 Booth-4 recoders + 576 AO22 port mux
FEED_W_HALF = 1204.0          # 64 radix-16 |d| + per-lane code LUT + 576 AO22 mux
COMBINER_ROW = 740.9          # east-edge combiner per PE row (red_team estimate)
PRESET_GATE = 101.1           # Sobol preset gate, per grid


def cell_powers(pdir: Path) -> dict:
    cells = {}
    for line in (pdir / "cell_power.rpt").read_text().splitlines():
        m = re.match(r"(u_pe|u_peripheral|u_a_rng|u_w_rng)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s.*\bh\s*$", line)
        if m and m[1] not in cells:
            cells[m[1]] = float(m[5]) * 1e3
    total = float(re.search(r"Total Power\s*=\s*([0-9.eE+-]+)",
                            (pdir / "power.rpt").read_text())[1]) * 1e3
    leak = float(re.search(r"Cell Leakage Power\s*=\s*([0-9.eE+-]+)",
                           (pdir / "power.rpt").read_text())[1]) * 1e3
    return dict(total=total, leakage=leak, u_pe=cells["u_pe"], periph=cells["u_peripheral"],
                sobol=cells["u_a_rng"] + cells["u_w_rng"])


def hier_breakdown(pdir: Path) -> dict:
    tiles = counters = 0.0
    nt = nc = 0
    for line in (pdir / "power_hier.rpt").read_text().splitlines():
        m = re.match(r"\s+(g_row_\d+__g_col_\d+__u_inner)\s+\(\S+\)\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
        if m:
            tiles += float(m[2]) * 1e3
            nt += 1
            continue
        m = re.match(r"\s+(g_lanes_\d+__u_popcount)\s+\(\S+\)\s+\S+\s+\S+\s+\S+\s+(\S+)", line)
        if m:
            counters += float(m[2]) * 1e3
            nc += 1
    assert nt == 64 and nc == 512, (pdir, nt, nc)
    return dict(tiles=tiles, counters=counters)


def compose(p: dict, mpc: float, pr: int, pc: int) -> float:
    resid = p["total"] - p["u_pe"] - p["periph"] - p["sobol"]
    watts = pr * pc * (p["u_pe"] + resid) + (pr + pc) * p["periph"] / 2 + p["sobol"]
    return watts * PERIOD / (pr * pc * mpc)


def main() -> None:
    rows = list(csv.DictReader((OUT / "results.csv").open()))
    refs = {}
    for t in (128, 16):
        pdir = SC / f"T{t}" / "power"
        p = cell_powers(pdir)
        p.update(hier_breakdown(pdir))
        refs[t] = dict(p, mpc=8192 / t)
    out_rows = []
    for r in rows:
        pdir = OUT / r["label"] / "power"
        p = cell_powers(pdir)
        p.update(hier_breakdown(pdir))
        mpc = float(r["mac_per_cycle_per_pe"])
        row = dict(label=r["label"], prec=r["prec"], dist=r["dist"], sign=r["sign"],
                   sigma_frac=r["sigma_frac"], mac_per_cycle_per_pe=mpc,
                   power_mW=p["total"], u_pe_mW=p["u_pe"], tiles_mW=p["tiles"],
                   counters_mW=p["counters"], pe_nontile_mW=p["u_pe"] - p["tiles"],
                   periph_mW=p["periph"], sobol_mW=p["sobol"],
                   pJ_MAC_full=p["total"] * PERIOD / mpc,
                   pJ_MAC_array=p["u_pe"] * PERIOD / mpc)
        for pr, pc in GRIDS[1:]:
            row[f"pJ_MAC_{pr}x{pc}"] = compose(p, mpc, pr, pc)
        for t, ref in refs.items():
            row[f"full_vs_SC_T{t}"] = row["pJ_MAC_full"] / (ref["total"] * PERIOD / ref["mpc"])
            row[f"array_vs_SC_T{t}"] = row["pJ_MAC_array"] / (ref["u_pe"] * PERIOD / ref["mpc"])
            row[f"4x4_vs_SC_T{t}"] = row["pJ_MAC_4x4"] / compose(ref, ref["mpc"], 4, 4)
        out_rows.append(row)
    ref_rows = []
    for t, ref in refs.items():
        rr = dict(label=f"SC_T{t}", mac_per_cycle_per_pe=ref["mpc"], power_mW=ref["total"],
                  u_pe_mW=ref["u_pe"], tiles_mW=ref["tiles"], counters_mW=ref["counters"],
                  pe_nontile_mW=ref["u_pe"] - ref["tiles"], periph_mW=ref["periph"],
                  sobol_mW=ref["sobol"], pJ_MAC_full=ref["total"] * PERIOD / ref["mpc"],
                  pJ_MAC_array=ref["u_pe"] * PERIOD / ref["mpc"])
        for pr, pc in GRIDS[1:]:
            rr[f"pJ_MAC_{pr}x{pc}"] = compose(ref, ref["mpc"], pr, pc)
        ref_rows.append(rr)

    # ---- estimates of what the measurement leaves out (stated assumptions) ----
    leak_density = refs[128]["leakage"] / DESIGN_AREA            # mW per um2
    est = {}
    for row in out_rows:
        dens = row["periph_mW"] / PERIPH_AREA                     # measured INT periph density
        mpc = row["mac_per_cycle_per_pe"]
        e = {}
        for pr, pc in GRIDS:
            macs = pr * pc * mpc
            feed_mW = (pr * FEED_A_HALF + pc * FEED_W_HALF) * dens
            comb_leak_mW = pr * COMBINER_ROW * leak_density
            e[f"{pr}x{pc}"] = dict(
                feeder_mW=feed_mW, feeder_pJ_MAC=feed_mW * PERIOD / macs,
                preset_gate_pJ_MAC=PRESET_GATE * leak_density * PERIOD / macs,
                combiner_leak_pJ_MAC=comb_leak_mW * PERIOD / macs,
                drain_upper_bound_frac_L1024=(8 * pc + pr + pc - 2) / (1024 / 8),
                drain_upper_bound_frac_L4096=(8 * pc + pr + pc - 2) / (4096 / 8))
        # combiner switching: one active cycle per drained tile column, energy
        # ~ combiner area x INT periph density x 2.5 ns, 8 columns per PE per block
        comb_pJ_per_block_pe = COMBINER_ROW * dens * PERIOD * 8
        e["combiner_switch_pJ_MAC_L1024"] = comb_pJ_per_block_pe / (1024 / 8 * mpc)
        est[row["label"]] = e
    bits_per_mac = {"int8": {"1x1": 6.0, "4x4": 1.5, "4x8": 1.25},
                    "w4a8": {"1x1": 3.0, "4x4": 0.75, "4x8": 0.625},
                    "int4": {"1x1": 1.5, "4x4": 0.375, "4x8": 0.3125},
                    "SC_T128": {"1x1": 2.25, "4x4": 0.5625, "4x8": 0.46875}}
    summary = dict(points=out_rows, sc_refs=ref_rows, not_modelled_estimates=est,
                   operand_bits_per_mac=bits_per_mac,
                   assumptions=dict(
                       leak_density_mW_per_um2=leak_density,
                       periph_area_um2=PERIPH_AREA, feeder_A_half_um2=FEED_A_HALF,
                       feeder_W_half_um2=FEED_W_HALF, combiner_per_row_um2=COMBINER_ROW,
                       preset_gate_um2=PRESET_GATE,
                       feeder_power="area x measured INT peripheral power density "
                                    "(flops + comparators; likely high for mostly "
                                    "combinational feeder logic)"))
    keys = list(out_rows[0])
    with (OUT / "summary.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(out_rows)
        w.writerows(ref_rows)
    (OUT / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")

    print("| point | MAC/cyc/PE | P mW | u_pe | tiles | counters | PE non-tile | periph | Sobol "
          "| pJ/MAC 1PE | array | 4x4 | 4x8 | 1PE/SC128 | array/SC128 | 4x4/SC128 | 4x4/SC16 |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in out_rows + ref_rows:
        def g(k, f="{:.3f}"):
            return f.format(r[k]) if k in r else "-"
        print(f"| {r['label']} | {r['mac_per_cycle_per_pe']:.0f} | {r['power_mW']:.3f} | "
              f"{r['u_pe_mW']:.3f} | {r['tiles_mW']:.2f} | {r['counters_mW']:.2f} | "
              f"{r['pe_nontile_mW']:.2f} | {r['periph_mW']:.3f} | {r['sobol_mW']:.3f} | "
              f"{r['pJ_MAC_full']:.4f} | {r['pJ_MAC_array']:.4f} | {r['pJ_MAC_4x4']:.4f} | "
              f"{r['pJ_MAC_4x8']:.4f} | {g('full_vs_SC_T128')} | {g('array_vs_SC_T128')} | "
              f"{g('4x4_vs_SC_T128')} | {g('4x4_vs_SC_T16')} |")


if __name__ == "__main__":
    sys.exit(main())
