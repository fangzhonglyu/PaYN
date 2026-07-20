#!/usr/bin/env python3
"""
Synthesis (pre-APR) vs post-APR area & power comparison for the SC PEs.

Area: both are standard-cell area (fair). Power: BOTH SAIF-annotated with the
same dut.saif — the synth side (sweeps/pt_synth_power.tcl) has no SPEF/CTS
(zero-wireload, ideal clock), so the synth->APR gap is the interconnect +
clock-tree cost. NOTE: the DC synth `pwr.rpt` uses DEFAULT activity and is
unreliable for SC (inconsistent, ~0.3-80 mW), so it is NOT used here.

Inputs:
  * sweeps/updated_area_energy_breakdown_<tech>.csv  (APR numbers + run_dir)
  * sweeps/synth_runs_<tech>.txt                     (target<TAB>synth_run_dir;
                                                      written by run_synth_area.sh)
  * <syn_run>/reports/pe_area_components.rpt         (synth per-component area)
  * <syn_run>/reports/synth_saif_power.rpt           (synth SAIF power)
  * <apr_run>/reports/pe_area_components.rpt         (APR per-component area)

Regenerate inputs: bash sweeps/run_synth_area.sh ; bash sweeps/run_synth_power.sh

Outputs (per tech):
  * synth_vs_apr_<tech>.csv
  * synth_vs_apr_<tech>.png   (area + power, synth vs APR)
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

# Unified taxonomy shared with plot_pe_components.py (SC + binary buckets).
from pe_taxonomy import SEGMENTS, AREA_KEYS, PWR_KEYS, parse_kv, area_seg, pwr_seg  # noqa: E402


def resolve_repo_path(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def repo_path(repo_root: Path, path: Path) -> str:
    try:
        return str(path.resolve().relative_to(repo_root.resolve()))
    except ValueError:
        return str(path)


def component_plot(rows, seg_key, out_png, title, xlabel, fmt="{:.1f}"):
    """Stacked per-component bar; rows[seg_key] is a {segment: plot_value} dict."""
    rows = [r for r in rows if r.get(seg_key)]
    if not rows:
        return
    labels = [r["label"] for r in rows]
    y = list(range(len(rows)))
    fig, ax = plt.subplots(figsize=(12.0, 0.46 * len(rows) + 2.6))
    left = [0.0] * len(rows)
    for key, lab, color in SEGMENTS:
        vals = [r[seg_key].get(key, 0.0) for r in rows]
        ax.barh(y, vals, left=left, color=color, edgecolor="white", linewidth=0.6, label=lab)
        left = [a + b for a, b in zip(left, vals)]
    mx = max(left) if left else 1.0
    for i in y:
        ax.text(left[i] + mx * 0.01, i, fmt.format(left[i]), va="center", ha="left",
                fontsize=8, fontweight="bold", color="#222")
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=8.5)
    ax.invert_yaxis()
    ax.set_xlim(0, mx * 1.16)
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


def parse_synth_area_total(run_dir: Path) -> float | None:
    p = run_dir / "area.rpt"
    if not p.exists():
        return None
    for line in p.read_text(errors="replace").splitlines():
        m = re.match(r"^\s*Total cell area:\s*([0-9.]+)", line)
        if m:
            return float(m.group(1))
    return None


def parse_synth_power(
    run_dir: Path,
) -> tuple[float | None, dict[str, float], float | None, float | None]:
    """SAIF-annotated synth power: total mW, group totals mW, net-annotated %.

    From reports/synth_saif_power.rpt (sweeps/pt_synth_power.tcl) — same SAIF as
    APR but no SPEF, so the synth<APR gap is interconnect + clock tree. This
    REPLACES the DC pwr.rpt default-activity estimate (unreliable for SC)."""
    p = run_dir / "reports" / "synth_saif_power.rpt"
    if not p.exists():
        return None, {}, None, None
    result = None
    period_ns = None
    for line in p.read_text(errors="replace").splitlines():
        if line.startswith("TARGET_PERIOD_NS "):
            period_ns = float(line.split()[1])
        if line.startswith("SYNTHPWR,"):
            f = line.split(",")
            # SYNTHPWR,design,total,comb,reg,clk,netpct
            groups = {"combinational": float(f[3]), "register": float(f[4]),
                      "clock_network": float(f[5])}
            cov = float(f[6]) if f[6] else None
            result = (float(f[2]), groups, cov)
    if result is None:
        return None, {}, None, period_ns
    return result[0], result[1], result[2], period_ns


def grouped_hbar(ax, labels, synth, apr, xlabel, colors=("#6A9EC0", "#B84A24"),
                 legend=("Synthesis", "Post-APR")):
    y = list(range(len(labels)))
    h = 0.38
    ys = [i + h / 2 for i in y]
    ya = [i - h / 2 for i in y]
    synth_plot = [0.0 if value is None else value for value in synth]
    apr_plot = [0.0 if value is None else value for value in apr]
    ax.barh(ys, synth_plot, height=h, color=colors[0], label=legend[0], edgecolor="white", linewidth=0.4)
    ax.barh(ya, apr_plot, height=h, color=colors[1], label=legend[1], edgecolor="white", linewidth=0.4)
    mx = max([v for v in synth + apr if v is not None] or [1.0])
    for i in y:
        if synth[i] is not None:
            ax.text(synth[i] + mx * 0.01, ys[i], f"{synth[i]:.3g}", va="center", fontsize=7)
        if apr[i] is not None:
            ax.text(apr[i] + mx * 0.01, ya[i], f"{apr[i]:.3g}", va="center", fontsize=7, fontweight="bold")
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=8.2)
    ax.invert_yaxis()
    ax.set_xlim(0, mx * 1.16)
    ax.set_xlabel(xlabel)
    ax.grid(axis="x", linestyle=":", linewidth=0.5, color="#B0AAA0", alpha=0.65)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)


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
    # totals cover SC + binary baselines; per-component stays SC-only (below)
    apr = {r["target"]: r for r in csv.DictReader(main_csv.open())
           if r["kind"] in ("sc", "binary")}

    manifest = args.out_dir / f"synth_runs_{tech_l}.txt"
    if not manifest.exists():
        print(f"missing {manifest} — run sweeps/run_synth_area.sh first")
        return
    synth_run = {}
    for line in manifest.read_text().splitlines():
        if "\t" in line:
            parts = line.split("\t")  # target<TAB>kind<TAB>run_dir
            synth_run[parts[0]] = resolve_repo_path(args.repo_root, parts[-1])

    rows = []
    for target, r in apr.items():
        sdir = synth_run.get(target)
        if sdir is None:
            continue
        s_pwr, s_grp, s_cov, s_period = parse_synth_power(sdir)
        synth_power_report = sdir / "reports" / "synth_saif_power.rpt"
        accepted_saif = resolve_repo_path(args.repo_root, r["saif_path"])
        apr_run_dir = resolve_repo_path(args.repo_root, r["run_dir"])
        if s_pwr is not None and synth_power_report.stat().st_mtime_ns < accepted_saif.stat().st_mtime_ns:
            print(f"skip stale synthesis power for {target}")
            s_pwr, s_grp, s_cov, s_period = None, {}, None, None
        if s_pwr is not None and (s_period is None or abs(s_period - args.period_ns) > 1.0e-9):
            print(
                f"skip synthesis power with unexpected period for {target}: "
                f"report={s_period}, required={args.period_ns:g} ns"
            )
            s_pwr, s_grp, s_cov, s_period = None, {}, None, None
        s_comp = parse_kv(sdir / "reports" / "pe_area_components.rpt", AREA_KEYS)
        a_comp = parse_kv(apr_run_dir / "reports" / "pe_area_components.rpt", AREA_KEYS)
        synth_component_report = sdir / "reports" / "pe_components.rpt"
        s_pcomp = (
            parse_kv(synth_component_report, PWR_KEYS)
            if s_pwr is not None
            and synth_component_report.exists()
            and synth_component_report.stat().st_mtime_ns >= accepted_saif.stat().st_mtime_ns
            else {}
        )
        a_pcomp = parse_kv(apr_run_dir / "reports" / "pe_components.rpt", PWR_KEYS)
        # synth cell area = sum of classifier buckets (consistent with the run in
        # the manifest); fall back to DC area.rpt.
        s_area = sum(s_comp.values()) if s_comp else parse_synth_area_total(sdir)
        mac = float(r["mac_per_cycle"])
        pjf = args.period_ns / mac
        rows.append({
            "label": r["label"], "target": target,
            "apr_run": r["run"],
            "apr_run_dir": repo_path(args.repo_root, apr_run_dir),
            "synth_run_dir": repo_path(args.repo_root, sdir), "mac": mac,
            "syn_cell_area": s_area,
            "apr_cell_area": float(r["cell_area_um2"]) if r["cell_area_um2"] else None,
            "apr_die_area": float(r["die_area_um2"]) if r["die_area_um2"] else None,
            "syn_power_mw": s_pwr, "apr_power_mw": float(r["power_mw"]), "syn_cov": s_cov,
            "syn_period_ns": s_period,
            "syn_pj": (s_pwr * args.period_ns / mac) if s_pwr else None,
            "apr_pj": float(r["pj_per_mac"]),
            "syn_grp": s_grp, "syn_comp": s_comp or {}, "apr_comp": a_comp or {},
            # precomputed plot-unit segment dicts: area in k um2, power in pJ/MAC
            "syn_area_seg": {k: v / 1e3 for k, v in area_seg(s_comp).items()} if s_comp else None,
            "syn_pwr_seg": {k: v * pjf for k, v in pwr_seg(s_pcomp).items()} if s_pcomp else None,
            "apr_pwr_seg": {k: v * pjf for k, v in pwr_seg(a_pcomp).items()} if a_pcomp else None,
        })
    if not rows:
        print("no synth runs matched — run sweeps/run_synth_area.sh")
        return
    rows.sort(key=lambda x: x["apr_cell_area"] or 0.0)

    # ---- CSV ----
    out_csv = args.out_dir / f"synth_vs_apr_{tech_l}.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.writer(f)
        head = ["label", "target", "apr_run", "apr_run_dir", "synth_run_dir",
                "mac_per_cycle",
                "syn_cell_area_um2", "apr_cell_area_um2", "apr_die_area_um2", "area_growth_pct",
                "syn_saif_power_mw", "apr_power_mw", "power_ratio_apr_over_syn",
                "syn_net_annot_pct", "syn_target_period_ns", "syn_pj_per_mac", "apr_pj_per_mac"]
        head += [f"syn_{k}" for k in AREA_KEYS] + [f"apr_{k}" for k in AREA_KEYS]
        w.writerow(head)
        for r in rows:
            growth = ((r["apr_cell_area"] / r["syn_cell_area"] - 1) * 100
                      if r["syn_cell_area"] and r["apr_cell_area"] else "")
            pratio = (r["apr_power_mw"] / r["syn_power_mw"] if r["syn_power_mw"] else "")
            row = [r["label"], r["target"], r["apr_run"],
                   r["apr_run_dir"], r["synth_run_dir"], r["mac"],
                   f"{r['syn_cell_area']:.2f}" if r["syn_cell_area"] else "",
                   f"{r['apr_cell_area']:.2f}" if r["apr_cell_area"] else "",
                   f"{r['apr_die_area']:.2f}" if r["apr_die_area"] else "",
                   f"{growth:.2f}" if growth != "" else "",
                   f"{r['syn_power_mw']:.4f}" if r["syn_power_mw"] else "",
                   f"{r['apr_power_mw']:.4f}",
                   f"{pratio:.2f}" if pratio != "" else "",
                   f"{r['syn_cov']:.1f}" if r["syn_cov"] is not None else "",
                   f"{r['syn_period_ns']:.6g}" if r["syn_period_ns"] is not None else "",
                   f"{r['syn_pj']:.4f}" if r["syn_pj"] else "", f"{r['apr_pj']:.4f}"]
            row += [f"{r['syn_comp'].get(k, 0.0):.2f}" for k in AREA_KEYS]
            row += [f"{r['apr_comp'].get(k, 0.0):.2f}" for k in AREA_KEYS]
            w.writerow(row)
    print(f"wrote {out_csv}")

    # ---- plot ----
    labels = [r["label"] for r in rows]
    fig, (axA, axP) = plt.subplots(1, 2, figsize=(15.0, 0.46 * len(rows) + 3.0), sharey=True)

    grouped_hbar(axA, labels,
                 [(r["syn_cell_area"] or 0) / 1e3 for r in rows],
                 [(r["apr_cell_area"] or 0) / 1e3 for r in rows],
                 "Standard-cell area (k um2)")
    axA.set_title("Cell area: synthesis vs post-APR", fontsize=11, fontweight="bold")
    axA.legend(loc="lower right", fontsize=8.5, frameon=False)

    grouped_hbar(axP, labels, [r["syn_power_mw"] for r in rows],
                 [r["apr_power_mw"] for r in rows], "Total power (mW)")
    axP.set_title("Power: synthesis vs post-APR (both SAIF-annotated)",
                  fontsize=11, fontweight="bold")
    # (legend shown on the area panel; colors are identical here)
    # flag low SAIF coverage on the synth side
    for i, r in enumerate(rows):
        if r["syn_power_mw"] is None:
            axP.text(0, i + 0.19, "  not refreshed", va="center",
                     ha="left", fontsize=6.5, color="#7a2a12", style="italic")
        elif r["syn_cov"] is not None and r["syn_cov"] < 95.0:
            axP.text(0, i + 0.19, f"  {r['syn_cov']:.0f}% cov", va="center",
                     ha="left", fontsize=6.5, color="#7a2a12", style="italic")
    axP.text(0.98, 0.02,
             "Both SAIF-annotated (same activity). Synth = zero-wireload, no CTS;\n"
             "the synth->APR gap is interconnect (SPEF) + clock-tree cost.\n"
             "(DC pwr.rpt default-activity power is unreliable for SC and is not used.)",
             transform=axP.transAxes, ha="right", va="bottom", fontsize=7.2,
             color="#33475b", style="italic",
             bbox=dict(boxstyle="round,pad=0.3", fc="#eef3f7", ec="#4A7A9E", lw=0.6))

    fig.suptitle(
        f"Synthesis vs post-APR — SC PEs + uSystolic baselines ({args.tech})",
        x=0.01, y=0.995, ha="left", fontsize=13, fontweight="bold")
    fig.tight_layout(rect=(0.0, 0.0, 1.0, 0.965))
    out_png = args.out_dir / f"synth_vs_apr_{tech_l}.png"
    fig.savefig(out_png, dpi=170, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"wrote {out_png}")

    # ---- synth per-component AREA (stacked), sorted by synth cell area ----
    srows = sorted([r for r in rows if r.get("syn_area_seg")], key=lambda x: x["syn_cell_area"] or 0.0)
    component_plot(srows, "syn_area_seg",
                   args.out_dir / f"synth_pe_area_components_{tech_l}.png",
                   f"SYNTHESIS per-component AREA (SC + uSystolic) ({args.tech}, cell area)",
                   "Standard-cell area (k um2), by PE component", fmt="{:.1f}")

    # ---- synth per-component POWER (stacked pJ/MAC), sorted by synth total ----
    prows = sorted([r for r in rows if r.get("syn_pwr_seg")],
                   key=lambda x: sum(x["syn_pwr_seg"].values()))
    component_plot(prows, "syn_pwr_seg",
                   args.out_dir / f"synth_pe_components_{tech_l}.png",
                   f"SYNTHESIS per-component ENERGY (SC + uSystolic) ({args.tech}, {args.period_ns:g} ns, "
                   "SAIF, zero-wireload; flop buckets incl. clock pins)",
                   "Energy per MAC (pJ/MAC), by PE component", fmt="{:.3g}")


if __name__ == "__main__":
    main()
