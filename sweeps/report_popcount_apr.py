#!/usr/bin/env python3
"""Compare qualified popcount routes with the exactly matched clean control."""
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

from validate_pt_power_coverage import audit_reports
from validate_routed_gl import audit as audit_routed_gl


def require_legal_placement(route: Path) -> int:
    text = (route / "apr.log").read_text(errors="replace")
    checks = list(re.finditer(r"Begin checking placement.*?Finished checkPlace[^\n]*", text, re.S))
    if not checks:
        raise ValueError(f"Missing placement verification: {route}")
    last = checks[-1]
    match = re.search(r"Overlapping with other instance:\s*(\d+)", last[0])
    overlaps = int(match[1]) if match else 0
    unplaced = re.search(r"Unplaced\s*=\s*(\d+)", last[0])
    counted_violations = re.findall(r"^([^*\n]+):\s*([1-9]\d*)\s*$", last[0], re.M)
    if not unplaced or int(unplaced[1]) or counted_violations or overlaps or "NRDB-2082" in text[last.end():]:
        raise ValueError(f"Route has unqualified placement overlaps: {route} ({overlaps} instances)")
    return overlaps


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("build/power_char/popcount_apr_20260930"))
    parser.add_argument("--arm-dir", action="append", default=[], metavar="ARM=DIR",
                        help="additional qualified arm living outside --root, e.g. "
                             "csa=build/power_char/popcount_apr_20261002/csa")
    parser.add_argument("--out", type=Path,
                        help="results CSV (default: <root>/results.csv)")
    args = parser.parse_args()
    arm_dirs = {arm: args.root / arm for arm in ("inferred", "techmap")}
    for item in args.arm_dir:
        arm, _, directory = item.partition("=")
        assert arm and directory and arm not in arm_dirs, item
        arm_dirs[arm] = Path(directory)
    provenance = json.loads((args.root / "control_provenance.json").read_text())
    control = json.loads((args.root / "control_power/full_timing/summary.json").read_text())
    assert control["status"] == "PASS"
    assert control["full_cell_timing_models"] and control["negative_timing_checks"]
    assert control["sdf_errors"] == 0 and control["timing_violations_after_reset"] == 0
    assert control["cosim"] == "PASS" and control["unannotated_activity_nets"] == 0
    assert provenance["verilog_tokens_identical"] and provenance["sdc_commands_identical"]
    control_overlaps = require_legal_placement(Path(provenance["reused_routed_control"]))
    control_coverage = audit_reports(
        args.root / "control_power/full_timing/power/reports",
        args.root / "control_power/full_timing/power/pt.log",
    )
    coverage_keys = tuple(key for key in control_coverage if key != "status")
    rows = [{
        "arm": "control", "area_um2": provenance["routed_area_um2"],
        "setup_wns_ns": provenance["setup_wns_ns"],
        "hold_wns_ns": provenance["hold_wns_ns"],
        "power_mW": control["power_mW"], "pJ_MAC": control["energy_pJ_per_MAC"],
        "area_change_percent": 0.0, "power_change_percent": 0.0,
        "combined_efficiency_relative_control": 1.0, "placement_overlapping_instances": control_overlaps, "status": "PASS",
        "route": provenance["reused_routed_control"],
        **{key: control_coverage[key] for key in coverage_keys},
    }]
    for arm, arm_dir in arm_dirs.items():
        path = arm_dir / "result.csv"
        if not path.is_file():
            print(f"{arm}: pending routed qualification and power")
            continue
        with path.open() as stream:
            result = next(csv.DictReader(stream))
        assert result["status"] == "PASS"
        for key in ("geometry_drc", "connectivity_violations", "antenna_violations"):
            assert int(result[key]) == 0, (arm, key)
        row = {key: float(result[key]) for key in ("area_um2", "setup_wns_ns", "hold_wns_ns", "power_mW", "pJ_MAC")}
        assert row["setup_wns_ns"] >= 0 and row["hold_wns_ns"] >= 0
        route = Path(f"apr/build/{result['target']}/{result['run']}")
        final_gl = arm_dir / "gl_final"
        # Re-audit with exactly the opt-in approvals recorded at qualification.
        recorded = json.loads((final_gl / "timing_qualification.json").read_text())
        timing = audit_routed_gl((final_gl / "simulation.log").read_text(errors="replace"),
                                 expected_pass=next(line for line in (final_gl / "simulation.log")
                                                    .read_text(errors="replace").splitlines()
                                                    if line.startswith("PASS: streaming SC SAIF captured;")
                                                    ).split(", drain")[0],
                                 approve_negative_iopath_clamp_ps=recorded.get(
                                     "approve_negative_iopath_clamp_ps"),
                                 approve_annotated_interconnect=recorded.get(
                                     "approve_annotated_interconnect", False))
        assert timing["status"] == "PASS", (arm, timing["rejection_reasons"])
        assert "[PASS]" in (final_gl / "cosim.log").read_text(), arm
        assert "validated SC SAIF:" in (final_gl / "saif_validation.log").read_text(), arm
        coverage = audit_reports(route / "reports", route / "power_apr.log")
        row.update(arm=arm, status="PASS", route=str(route),
                   placement_overlapping_instances=require_legal_placement(route),
                   **{key: coverage[key] for key in coverage_keys})
        row["area_change_percent"] = 100 * (row["area_um2"] / rows[0]["area_um2"] - 1)
        row["power_change_percent"] = 100 * (row["power_mW"] / rows[0]["power_mW"] - 1)
        row["combined_efficiency_relative_control"] = (
            rows[0]["area_um2"] * rows[0]["power_mW"] / (row["area_um2"] * row["power_mW"])
        )
        rows.append(row)
    for row in rows:
        print(f"{row['arm']:8s}: {row['area_um2']:.3f} um2; {row['power_mW']:.6f} mW "
              f"({row['power_change_percent']:+.3f}%); {row['pJ_MAC']:.6f} pJ/MAC; "
              f"setup/hold {row['setup_wns_ns']:+.3f}/{row['hold_wns_ns']:+.3f} ns")
    with (args.out or args.root / "results.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
