#!/usr/bin/env python3
"""
Per-component energy AND area breakdown of the SC-GEMM PEs.

Reads the per-run reports written by the two SCArch PT passes, keyed off the SC
rows of updated_area_energy_breakdown_<tech>.csv (run_dir + mac_per_cycle):
  * reports/pe_components.rpt       (sweeps/pt_pe_components.tcl)  -> energy/power
  * reports/pe_area_components.rpt  (sweeps/pt_pe_area.tcl)        -> cell area

Writes (per tech):
  * pe_components_<tech>.csv / .png       — energy (pJ/MAC) per component
  * pe_area_components_<tech>.csv / .png  — cell area (k um2) per component

Every flop bucket's ENERGY includes that flop's clock-pin internal power;
clock_dist is the clock tree only. Buckets reconcile to Total (power and area).
Regenerate inputs with: bash sweeps/run_pe_components.sh ; bash sweeps/run_pe_area.sh
"""
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

DEFAULT_PERIOD_NS = 2.5

# Unified taxonomy shared with plot_synth_vs_apr.py (SC + binary buckets).
from pe_taxonomy import (  # noqa: E402
    SEGMENTS, AREA_KEYS, PWR_KEYS, parse_kv,
    area_seg as area_segments, pwr_seg as pwr_segments,
)


def resolve_repo_path(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def stacked_plot(rows, seg_key, out_png, xlabel, title, scale=1.0, fmt="{:.3g}"):
    labels = [r["label"] for r in rows]
    y = list(range(len(rows)))
    fig, ax = plt.subplots(figsize=(12.0, 0.46 * len(rows) + 2.6))
    left = [0.0] * len(rows)
    for key, lab, color in SEGMENTS:
        vals = [r[seg_key][key] * scale for r in rows]
        ax.barh(y, vals, left=left, color=color, edgecolor="white", linewidth=0.6, label=lab)
        left = [a + b for a, b in zip(left, vals)]
    maxtot = max(left) if left else 1.0
    for i in range(len(rows)):
        ax.text(left[i] + maxtot * 0.01, i, fmt.format(left[i]), va="center",
                ha="left", fontsize=8, fontweight="bold", color="#222")
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=8.5)
    ax.invert_yaxis()
    ax.set_xlim(0, maxtot * 1.16)
    ax.set_xlabel(xlabel)
    ax.grid(axis="x", linestyle=":", linewidth=0.5, color="#B0AAA0", alpha=0.65)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.01), ncol=4, frameon=False,
              fontsize=8.2, handlelength=1.3, columnspacing=1.1)
    fig.suptitle(title, x=0.01, y=0.995, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0.0, 0.0, 1.0, 0.96))
    fig.savefig(out_png, dpi=170, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"wrote {out_png}")


def write_csv(rows, out_csv, seg_key, raw_keys, extra_cols):
    with out_csv.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            ["label", "target", "run", "run_dir"]
            + extra_cols
            + raw_keys
            + [f"{k}" for k, _, _ in SEGMENTS]
        )
        for r in rows:
            w.writerow(
                [r["label"], r["target"], r["run"], r["run_dir"]]
                + [f"{r[c]:.4f}" for c in extra_cols]
                + [f"{r['raw_' + seg_key].get(k, 0.0):.4f}" for k in raw_keys]
                + [f"{r[seg_key][k]:.4f}" for k, _, _ in SEGMENTS]
            )
    print(f"wrote {out_csv}")


def write_energy_csv(rows, out_csv):
    """Write power and energy with explicit units and a reconciliation audit."""
    seg_keys = [key for key, _, _ in SEGMENTS]
    with out_csv.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "label",
                "target",
                "run",
                "run_dir",
                "mac_per_cycle",
                "total_pj_per_mac",
                "component_sum_pj_per_mac",
                "reconciliation_error_pj_per_mac",
            ]
            + [f"{key}_mw" for key in PWR_KEYS]
            + [f"{key}_pj_per_mac" for key in seg_keys]
        )
        for r in rows:
            component_sum = sum(r["seg_pj"].values())
            error = component_sum - r["total_pj_per_mac"]
            w.writerow(
                [
                    r["label"],
                    r["target"],
                    r["run"],
                    r["run_dir"],
                    f'{r["mac_per_cycle"]:.4f}',
                    f'{r["total_pj_per_mac"]:.6f}',
                    f"{component_sum:.6f}",
                    f"{error:+.6f}",
                ]
                + [f'{r["raw_seg_pj"].get(key, 0.0):.6f}' for key in PWR_KEYS]
                + [f'{r["seg_pj"][key]:.6f}' for key in seg_keys]
            )
    print(f"wrote {out_csv}")


def main() -> None:
    here = Path(__file__).resolve()
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-root", type=Path, default=here.parents[1])
    ap.add_argument("--tech", default="TSMC22")
    ap.add_argument("--period-ns", type=float, default=DEFAULT_PERIOD_NS)
    ap.add_argument("--out-dir", type=Path, default=here.parent)
    args = ap.parse_args()
    args.repo_root = args.repo_root.resolve()

    tech_l = args.tech.lower()
    main_csv = args.out_dir / f"updated_area_energy_breakdown_{tech_l}.csv"

    erows, arows = [], []
    for r in csv.DictReader(main_csv.open()):
        if r["kind"] not in ("sc", "binary"):
            continue
        rd = resolve_repo_path(args.repo_root, r["run_dir"])
        component_report = rd / "reports" / "pe_components.rpt"
        power_report = rd / "reports" / "power.rpt"
        pv = parse_kv(component_report, PWR_KEYS)
        if pv is not None:
            if power_report.exists() and component_report.stat().st_mtime_ns < power_report.stat().st_mtime_ns:
                raise RuntimeError(
                    f"stale component report for {r['label']}: "
                    f"{component_report} predates {power_report}"
                )
            mac = float(r["mac_per_cycle"])
            period_ns = float(r["saif_target_period_ns"])
            if abs(period_ns - args.period_ns) > 1e-9:
                raise RuntimeError(
                    f"unexpected SAIF period for {r['label']}: "
                    f"row={period_ns:g} ns, required={args.period_ns:g} ns"
                )
            factor = period_ns / mac
            segs = pwr_segments(pv)
            seg_pj = {k: v * factor for k, v in segs.items()}
            total_pj = float(r["pj_per_mac"])
            component_sum = sum(seg_pj.values())
            # Historical component reports inherited report_power's default
            # three-significant-digit total. Accept only that bounded
            # quantization error, then normalize the segments to the precise
            # aggregate PT-PX result so stacked bars retain the exact total.
            tolerance = max(0.0005, total_pj * 0.005)
            if abs(component_sum - total_pj) > tolerance:
                raise RuntimeError(
                    f"component energy does not reconcile for {r['label']}: "
                    f"components={component_sum:.6f} pJ/MAC, "
                    f"total={total_pj:.6f} pJ/MAC"
                )
            if component_sum > 0.0:
                scale = total_pj / component_sum
                seg_pj = {key: value * scale for key, value in seg_pj.items()}
            erows.append({"label": r["label"],
                          "target": r["target"],
                          "run": r["run"],
                          "run_dir": r["run_dir"],
                          "mac_per_cycle": mac,
                          "total_pj_per_mac": total_pj,
                          "raw_seg_pj": pv,
                          "seg_pj": seg_pj})
        av = parse_kv(rd / "reports" / "pe_area_components.rpt", AREA_KEYS)
        if av is not None:
            segs = area_segments(av)
            arows.append({"label": r["label"],
                          "target": r["target"],
                          "run": r["run"],
                          "run_dir": r["run_dir"],
                          "cell_area_um2": float(r["cell_area_um2"]),
                          "raw_seg_area": av, "seg_area": segs})

    if erows:
        erows.sort(key=lambda x: x["total_pj_per_mac"])
        write_energy_csv(erows, args.out_dir / f"pe_components_{tech_l}.csv")
        stacked_plot(erows, "seg_pj", args.out_dir / f"pe_components_{tech_l}.png",
                     "Energy per MAC (pJ/MAC), by PE component",
                     f"PE per-component ENERGY breakdown (SC + uSystolic) ({args.tech}, "
                     f"{args.period_ns:g} ns, flop buckets incl. clock pins)")
    else:
        print("no pe_components.rpt found — run sweeps/run_pe_components.sh")

    if arows:
        arows.sort(key=lambda x: x["cell_area_um2"])
        write_csv(arows, args.out_dir / f"pe_area_components_{tech_l}.csv", "seg_area",
                  AREA_KEYS, ["cell_area_um2"])
        stacked_plot(arows, "seg_area", args.out_dir / f"pe_area_components_{tech_l}.png",
                     "Standard-cell area (k um2), by PE component",
                     f"PE per-component AREA breakdown (SC + uSystolic) ({args.tech}, cell area)",
                     scale=1e-3, fmt="{:.1f}")
    else:
        print("no pe_area_components.rpt found — run sweeps/run_pe_area.sh")


if __name__ == "__main__":
    main()
