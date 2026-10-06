#!/usr/bin/env python3
"""Summarize the bit-plane INT energy campaign (run_bitplane_energy.sh).

Reads OUT/results.csv (one PT-PX-qualified row per point) and derives:
  * peak (data cycles only) pJ/MAC, full design and u_pe only
  * averages including ring laps (drain excluded, SC methodology) and with
    the drain included, as measured
  * an exact energy split per cycle class.  The three window modes of one
    (precision, dist, L) triple come from separate GL runs with IDENTICAL
    stimulus, so the data intervals are the same events in every mode:
        E_ring  = P_dr  * T_dr  - P_d  * T_d
        E_drain = P_all * T_all - P_dr * T_dr
  * pJ/MAC versus L composed from the measured per-cycle class energies,
    cycles per block = BW*ceil(L/128) data + 8*(BW-1) ring (+ 8 drain).
Writes OUT/summary.json and OUT/summary.csv and prints a table.

  summarize_bitplane_energy.py [OUT]
"""
from __future__ import annotations

import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

PERIOD_NS = 2.5
REF = {
    "SC T=128 (routed CSA, full)": 0.6034,
    "SC T=128 (u_pe only)": 0.508,
    "SC T=16 (routed CSA, full)": 0.1167,
    "SC T=16 (u_pe only)": 0.0850,
    "BOS binary INT8 (older flow, full)": 0.41,
}


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path(__file__).resolve().parents[2] / "build/power_char/int_mode_energy_20261003/bitplane"
    rows = list(csv.DictReader((out / "results.csv").open()))
    # power_hier.rpt rounds hierarchy totals to 3 s.f.; the same PT run's
    # cell_power.rpt lists u_pe / u_peripheral / u_a_rng / u_w_rng to 7 s.f.
    # (PT charges the forced operand boundary nets to u_peripheral, their
    # driver's hierarchy, so u_pe excludes them in SC and INT runs alike.)
    for r in rows:
        rpt = out / r["label"] / "power" / "cell_power.rpt"
        vals = {}
        for line in rpt.read_text().splitlines():
            f = line.split()
            if len(f) >= 5 and f[0] in ("u_pe", "u_peripheral", "u_a_rng", "u_w_rng"):
                vals[f[0]] = float(f[4]) * 1e3
        assert set(vals) == {"u_pe", "u_peripheral", "u_a_rng", "u_w_rng"}, rpt
        r["u_pe_mW_3sf"] = r["u_pe_mW"]
        r["u_pe_mW"] = vals["u_pe"]
        r["u_peripheral_mW"] = vals["u_peripheral"]
        r["sobol_mW"] = vals["u_a_rng"] + vals["u_w_rng"]
        r["array_pJ_MAC"] = vals["u_pe"] * PERIOD_NS / float(r["mac_per_cycle"])
        assert abs(vals["u_pe"] - float(r["u_pe_mW_3sf"])) <= 0.051, (r["label"], vals["u_pe"])
    with (out / "results_precise.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader(); w.writerows(rows)
    groups: dict[tuple, dict[int, dict]] = defaultdict(dict)
    for r in rows:
        if r["status"] != "PASS":
            continue
        groups[(r["precision"], r["dist"], int(r["L"]))][int(r["saif_mode"])] = r

    table, summary = [], []
    for (prec, dist, L), modes in sorted(groups.items()):
        any_row = next(iter(modes.values()))
        mpc = float(any_row["mac_per_data_cycle"])
        ba, bw = {"INT8": (8, 8), "INT4": (4, 4), "W4A8": (8, 4)}[prec]
        rec = dict(precision=prec, dist=dist, L=L, mac_per_data_cycle=mpc)
        for m, name in ((1, "data"), (0, "data_ring"), (2, "all")):
            if m in modes:
                r = modes[m]
                rec[f"{name}_power_mW"] = float(r["power_mW"])
                rec[f"{name}_u_pe_mW"] = float(r["u_pe_mW"])
                rec[f"{name}_peripheral_mW"] = float(r["u_peripheral_mW"])
                rec[f"{name}_sobol_mW"] = float(r["sobol_mW"])
                rec[f"{name}_toplevel_mW"] = (float(r["power_mW"]) - float(r["u_pe_mW"])
                                              - float(r["u_peripheral_mW"]) - float(r["sobol_mW"]))
                rec[f"{name}_mac_per_cycle"] = float(r["mac_per_cycle"])
                rec[f"{name}_pJ_MAC"] = float(r["pJ_MAC"])
                rec[f"{name}_array_pJ_MAC"] = float(r["array_pJ_MAC"])
                rec[f"{name}_cycles"] = int(r["active_cycles"])
        # exact class split (same stimulus across modes)
        if 1 in modes and 0 in modes:
            d, dr = modes[1], modes[0]
            nd, nr = int(d["data_cycles"]), int(dr["ring_cycles"])
            for key, col in (("full", "power_mW"), ("u_pe", "u_pe_mW")):
                e_d = float(d[col]) * PERIOD_NS * nd                  # pJ
                e_dr = float(dr[col]) * PERIOD_NS * int(dr["active_cycles"])
                rec[f"e_data_cycle_pJ_{key}"] = e_d / nd
                if nr:
                    rec[f"e_ring_cycle_pJ_{key}"] = (e_dr - e_d) / nr
                if 2 in modes:
                    a = modes[2]
                    e_all = float(a[col]) * PERIOD_NS * int(a["active_cycles"])
                    rec[f"e_drain_cycle_pJ_{key}"] = (e_all - e_dr) / int(a["drain_cycles"])
        summary.append(rec)
        table.append(rec)

    # composed pJ/MAC versus L from the L=1024 class energies (3-mode triples)
    composed = []
    for rec in summary:
        if "e_drain_cycle_pJ_full" not in rec:
            continue
        ba, bw = {"INT8": (8, 8), "INT4": (4, 4), "W4A8": (8, 4)}[rec["precision"]]
        for L in (128, 256, 512, 1024, 2048, 4096, 16384, 65536):
            nb = -(-L // 128)
            d, ring, drain = bw * nb, 8 * (bw - 1), 8
            macs = d * rec["mac_per_data_cycle"]
            row = dict(precision=rec["precision"], dist=rec["dist"], from_L=rec["L"], L=L)
            for key in ("full", "u_pe"):
                ed, er, edr = (rec[f"e_{c}_cycle_pJ_{key}"] for c in ("data", "ring", "drain"))
                row[f"pJ_MAC_{key}_data_ring"] = (d * ed + ring * er) / macs
                row[f"pJ_MAC_{key}_with_drain"] = (d * ed + ring * er + drain * edr) / macs
            row["mac_per_cycle_data_ring"] = macs / (d + ring)
            row["mac_per_cycle_with_drain"] = macs / (d + ring + drain)
            composed.append(row)

    (out / "summary.json").write_text(json.dumps(dict(points=summary, composed=composed,
                                                      references_pJ_MAC=REF), indent=2) + "\n")
    keys = sorted({k for r in summary for k in r}, key=lambda k: (k not in ("precision", "dist", "L"), k))
    with (out / "summary.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader(); w.writerows(summary)
    if composed:
        with (out / "composed_vs_L.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(composed[0]))
            w.writeheader(); w.writerows(composed)

    print(f"{'prec':5} {'dist':8} {'L':>6} | {'data pJ/MAC':>11} {'(u_pe)':>7} | "
          f"{'+ring':>7} {'(u_pe)':>7} | {'+drain':>7} {'(u_pe)':>7} | P_data mW  u_pe  periph sobol top")
    for r in table:
        def g(k):
            v = r.get(k)
            return f"{v:7.4f}" if isinstance(v, float) else "      -"
        print(f"{r['precision']:5} {r['dist']:8} {r['L']:>6} | {g('data_pJ_MAC'):>11} {g('data_array_pJ_MAC')} | "
              f"{g('data_ring_pJ_MAC')} {g('data_ring_array_pJ_MAC')} | {g('all_pJ_MAC')} {g('all_array_pJ_MAC')} | "
              f"{r.get('data_power_mW', float('nan')):8.3f} {r.get('data_u_pe_mW', float('nan')):6.3f} "
              f"{r.get('data_peripheral_mW', float('nan')):6.3f} {r.get('data_sobol_mW', float('nan')):5.3f} "
              f"{r.get('data_toplevel_mW', float('nan')):5.2f}")
    for r in summary:
        if "e_ring_cycle_pJ_full" in r:
            msg = (f"{r['precision']} {r['dist']} L={r['L']}: per-cycle energy data "
                   f"{r['e_data_cycle_pJ_full']:.2f} pJ (u_pe {r['e_data_cycle_pJ_u_pe']:.2f}), ring "
                   f"{r['e_ring_cycle_pJ_full']:.2f} pJ (u_pe {r['e_ring_cycle_pJ_u_pe']:.2f})")
            if "e_drain_cycle_pJ_full" in r:
                msg += (f", drain {r['e_drain_cycle_pJ_full']:.2f} pJ "
                        f"(u_pe {r['e_drain_cycle_pJ_u_pe']:.2f})")
            print(msg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
