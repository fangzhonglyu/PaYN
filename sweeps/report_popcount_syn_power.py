#!/usr/bin/env python3
"""Summarize matched pre-layout, unit-delay-SAIF popcount power estimates."""
from __future__ import annotations

import argparse
import csv
import math
import re
from pathlib import Path


def power_mw(text: str, label: str) -> float:
    match = re.search(
        rf"^\s*{re.escape(label)}\s*=\s*([-+\d.eE]+)(?:\s+(mW|uW|nW|W))?",
        text, re.M,
    )
    if not match:
        raise ValueError(f"missing {label}")
    return float(match[1]) * {None: 1000, "W": 1000, "mW": 1, "uW": 0.001, "nW": 0.000001}[match[2]]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("build/power_char/popcount_dc_power_20260930"))
    args = parser.parse_args()
    rows = []
    for arm in ("control", "inferred", "techmap"):
        work = args.root / arm
        dc_mode = (work / "pwr_saif.rpt").is_file()
        text = (work / ("pwr_saif.rpt" if dc_mode else "power.rpt")).read_text()
        internal = power_mw(text, "Cell Internal Power")
        switching = power_mw(text, "Net Switching Power")
        leakage = power_mw(text, "Cell Leakage Power")
        total = (power_mw(text, "Total Dynamic Power") + leakage
                 if dc_mode else power_mw(text, "Total Power"))
        if not math.isclose(total, internal + switching + leakage, rel_tol=1e-5, abs_tol=1e-7):
            raise ValueError(f"power components do not reconcile for {arm}")
        if dc_mode:
            lines = (work / "pwr_saif_hier.rpt").read_text().splitlines()
            blocks = {"tile_combinational": ""}
            for name in ("u_pe", "u_peripheral", "u_a_rng", "u_w_rng"):
                for index, line in enumerate(lines):
                    if re.match(rf"^  {name} \(", line):
                        fields = line.split(")", 1)[1].split() or lines[index + 1].split()
                        blocks[name] = float(fields[3])
                        break
                else:
                    raise ValueError(f"missing hierarchy block {name}")
            coverage = (work / "saif_coverage.rpt").read_text()
            for kind in ("Nets", "Ports", "Pins"):
                if not re.search(rf"^\s*{kind}\s+\d+\(100\.00%\)", coverage, re.M):
                    raise ValueError(f"incomplete SAIF annotation for {kind} in {arm}")
        else:
            with (work / "block_power.csv").open() as stream:
                blocks = {row["block"]: float(row["total_mW"]) for row in csv.DictReader(stream)}
        rows.append({
            "arm": arm, "internal_mW": internal, "switching_mW": switching,
            "dynamic_mW": total - leakage, "leakage_mW": leakage,
            "total_mW": total, "pJ_MAC": total / 25.6,
            "u_pe_mW": blocks["u_pe"], "tile_combinational_mW": blocks["tile_combinational"],
            "peripheral_mW": blocks["u_peripheral"],
            "rng_mW": blocks["u_a_rng"] + blocks["u_w_rng"],
            "change_percent": 0.0,
            "model": ("DC_unit_delay_SAIF_zero_WLM_preCTS_ICG_load_override"
                      if dc_mode else "PT_unit_delay_SAIF_no_SPEF_no_CTS"),
        })
    baseline = rows[0]["total_mW"]
    for row in rows:
        row["change_percent"] = 100 * (row["total_mW"] / baseline - 1)
        print(f"{row['arm']:8s} {row['total_mW']:.6f} mW "
              f"{row['change_percent']:+.3f}%  {row['pJ_MAC']:.6f} pJ/MAC "
              f"(pre-layout estimate)")
    output = args.root / "results.csv"
    with output.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Saved {output}")


if __name__ == "__main__":
    main()
