#!/usr/bin/env python3
"""Summarize matched pc16 synthesis runs; default-activity power is not energy.

Usage: python3 sweeps/report_popcount_synth.py [--prefix pc16_20260930]
"""
from __future__ import annotations

import argparse
import csv
import re
from collections import Counter
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
ARMS = {
    "control": ("PAYN_SC_SIGNED_SEGMENTED_CLEAN", "payn_array_signed_segmented_clean"),
    "inferred": ("PAYN_SC_POPCOUNT_INFERRED", "payn_array_signed_segmented_popcount"),
    "techmap": ("PAYN_SC_POPCOUNT_TECHMAP", "payn_array_signed_segmented_popcount"),
}


def cell_counts(netlist: Path, top: str) -> tuple[Counter, Counter]:
    """Expand module instances so reused counter modules count at every lane."""
    modules = {}
    for match in re.finditer(r"\bmodule\s+(\S+)\s*\((.*?)\bendmodule", netlist.read_text(), re.S):
        modules[match[1]] = re.findall(
            r"^\s*(\w+)\s+(\\\S+|[\w$]+)\s*\((.*?)\);", match[2], re.M | re.S
        )
    all_cells, counters = Counter(), Counter()

    def visit(module: str, path: str, stack: tuple[str, ...]) -> None:
        if module in stack:
            raise ValueError(f"recursive module hierarchy: {module}")
        for ref, instance, _ in modules[module]:
            child = f"{path}/{instance}"
            if ref in modules:
                visit(ref, child, (*stack, module))
            elif "_A7" in ref:
                all_cells[ref.split("_")[0]] += 1
                if "u_popcount" in child:
                    counters[ref.split("_")[0]] += 1
            else:
                raise ValueError(f"unresolved mapped reference {ref} at {child}")

    visit(top, top, ())
    return all_cells, counters


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default="pc16_20260930")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.out is None:
        args.out = REPO / "build/power_char" / f"popcount_synth_{args.prefix.removeprefix('pc16_')}" / "results.csv"
    rows = []
    for arm, (target, top) in ARMS.items():
        run = REPO / "syn/build/TSMC22" / target / f"{args.prefix}_{arm}"
        if not (run / "area.rpt").is_file():
            print(f"{arm}: pending ({run})")
            continue
        area_text = (run / "area.rpt").read_text()
        timing_text = (run / "timing.rpt").read_text()
        area = float(re.search(r"Total cell area:\s*(\S+)", area_text)[1])
        slack = min(float(m[1]) for m in re.finditer(r"slack \((?:MET|VIOLATED)\)\s+([-+\d.]+)", timing_text))
        cells, counter = cell_counts(run / f"{top}.syn.v", top)
        rows.append({
            "arm": arm, "target": target, "run": run.name,
            "syn_area_um2": area, "setup_slack_ns": slack,
            "area_change_percent": "", "full_adders": cells["ADDF"],
            "half_adders": cells["ADDH"], "counter_full_adders": counter["ADDF"],
            "counter_half_adders": counter["ADDH"],
            "two_bit_flops": sum(n for family, n in cells.items()
                                 if family.startswith(("DFF", "SDFF")) and family.endswith("2W")),
        })
    control = next((r["syn_area_um2"] for r in rows if r["arm"] == "control"), None)
    for row in rows:
        if control:
            row["area_change_percent"] = 100 * (row["syn_area_um2"] / control - 1)
        print(f"{row['arm']:8s}: area={row['syn_area_um2']:.3f} um2, "
              f"setup slack={row['setup_slack_ns']:+.3f} ns, "
              f"FA/HA={row['full_adders']}/{row['half_adders']}, "
              f"counter FA/HA={row['counter_full_adders']}/{row['counter_half_adders']}")
    if rows:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(f"Saved {args.out}")


if __name__ == "__main__":
    main()
