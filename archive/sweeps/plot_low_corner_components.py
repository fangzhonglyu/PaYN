#!/usr/bin/env python3
"""Low-corner K/M/N rays: inner-PE power per component.

Reads reports/array_components.rpt (sweeps/pt_array_components.tcl) from the
13 low-corner spp_fixed APR runs and plots the three rays side by side as
stacked bars: a normalized figure (pJ/MAC, shared axis -- which components
each axis amortizes) and an unnormalized one (pJ/cycle, per-ray axis -- the
absolute cost being amortized).  Writes
sweeps/pe_components_low_corner{,_raw}.{png,pdf,csv}.

Conventions (cell-attribute walk, each leaf counted once): every flop bucket
includes that flop's clock-pin INTERNAL power -- register clocking rides with
the register's function, not the clock tree.  "Clock tree" is CTS buffers +
ICG cells (the BOS convention) plus the clock-net switching they drive.
Cross-check: PT's group-mode clock_network minus this clock bucket equals the
register clock-pin power (e.g. k2m1n1: 0.0465 - 0.0318 = 0.0147 mW, which
lands distributed in the flop buckets).  Segment totals reconcile to the PT
total, which is cross-checked against the sweep's results.csv pJ/MAC.
"""
from __future__ import annotations

import csv
import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

REPO = Path(__file__).resolve().parent.parent
BASE = REPO / "apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN"
RESULTS = REPO / "build/power_char/clean_kmn/results.csv"
PERIOD_NS = 2.5
T = 128

# Inner-PE scope only (u_pe hierarchy): the Sobol RNG, operand converters and
# any clock cells outside the PE are peripheral and excluded.  (key, label,
# color) -- stack order bottom->top.  Colors are the seaborn Set2 palette,
# assigned in the one order of its first five that passes the adjacent-pair
# CVD check (pink and blue-purple must not touch: protan dE 1.5 in canonical
# order vs 10.0 here); the white segment gaps are the secondary encoding for
# Set2's inherently low pastel contrast.
SEGMENTS = [
    ("compute", "Comb", "#66c2a5"),
    ("acc", "Accumulator", "#fc8d62"),
    ("pipeline", "Pipeline regs", "#8da0cb"),
    ("clock", "Clock tree", "#a6d854"),
    ("glue", "Glue", "#e78ac3"),
]

RAYS = [
    ("K ray (M=1, N=1)", "K", [("k1m1n1", 1), ("k2m1n1", 2), ("k4m1n1", 4),
                                ("k8m1n1", 8), ("k16m1n1", 16)]),
    ("M ray (K=1, N=1)", "M", [("k1m1n1", 1), ("k1m2n1", 2), ("k1m4n1", 4),
                                ("k1m8n1", 8), ("k1m16n1", 16)]),
    ("N ray (K=1, M=1)", "N", [("k1m1n1", 1), ("k1m1n2", 2), ("k1m1n4", 4),
                                ("k1m1n6", 6), ("k1m1n8", 8)]),
]

SURFACE = "#fcfcfb"
INK = "#000000"


def parse_rpt(path: Path) -> dict[str, float]:
    v: dict[str, float] = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^([a-z_]+)\s+([-+0-9.eE]+)", line)
        if m:
            v[m.group(1)] = float(m.group(2))
    return v


def segments_mw(v: dict[str, float]) -> dict[str, float]:
    return {
        "compute": v["popcount_logic"],
        "acc": v["acc_reg"],
        "pipeline": v["in_bit_reg"] + v["in_sign_reg"]
                    + v["w_bit_reg"] + v["w_sign_reg"],
        "clock": v["clock_pe"],
        "glue": v["glue_pe"] + v["load_ctrl_reg"] + v["other_reg"]
                + v["drain_reg"],
    }


def sweep_pj(cfg: str) -> float:
    with open(RESULTS) as f:
        for row in csv.DictReader(f):
            if row["config"] == cfg and row["status"] == "OK":
                pj = float(row["pJ_MAC"])
    return pj


def draw_rays(data: dict[str, dict[str, float]], ylabel: str, out_png: Path,
              sharey: bool, figsize: tuple[float, float] = (7.0, 3.0)) -> None:
    """One 1x3 rays figure; sharey=False gives each ray its own scale."""
    fig, axes = plt.subplots(1, 3, figsize=figsize, sharey=sharey,
                             facecolor="white")
    gmax = max(sum(d.values()) for d in data.values())
    for ax, (title, axis_name, pts) in zip(axes, RAYS):
        ax.set_facecolor("white")
        xs = range(len(pts))
        bottom = [0.0] * len(pts)
        for key, label, color in SEGMENTS:
            vals = [data[cfg][key] for cfg, _ in pts]
            ax.bar(xs, vals, 0.66, bottom=bottom, color=color,
                   edgecolor="white", linewidth=0.8,
                   label=label if ax is axes[0] else None)
            bottom = [a + b for a, b in zip(bottom, vals)]
        amax = gmax if sharey else max(bottom)
        for x, tot in zip(xs, bottom):
            ax.text(x, tot + amax * 0.02, f"{tot:.2f}", ha="center",
                    va="bottom", fontsize=9, color=INK)
        ax.set_xticks(list(xs))
        ax.set_xticklabels([f"{v}" for _, v in pts], color=INK)
        ax.set_xlabel(axis_name, color=INK, labelpad=1, loc="center")
        ax.set_title(title, color=INK, pad=4, loc="center")
        ax.tick_params(colors=INK)
        ax.grid(axis="y", color="#e4e3dd", linewidth=0.8)
        ax.set_axisbelow(True)
        ax.set_ylim(0, amax * 1.14)
        # full box: all four spines, black
        for s in ("top", "right", "left", "bottom"):
            ax.spines[s].set_visible(True)
            ax.spines[s].set_color(INK)
    if sharey:
        axes[0].set_ylabel(ylabel, color=INK)
    else:
        for ax in axes:
            ax.set_ylabel(ylabel, color=INK)
    handle = fig.legend(loc="upper center", bbox_to_anchor=(0.53, 1.005), ncol=5,
               frameon=True, fancybox=True, edgecolor="none",
               facecolor="#f2f3f5", framealpha=1.0, borderpad=0.4,
               labelcolor=INK, handlelength=1.0,
               handletextpad=0.4, columnspacing=0.9)

    for handle in handle.legend_handles:
        handle.set_edgecolor('none') 

    fig.tight_layout(rect=(0, 0, 1, 0.90))
    fig.savefig(out_png, dpi=300, facecolor="white", bbox_inches="tight")
    fig.savefig(out_png.with_suffix(".pdf"), facecolor="white",
                bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out_png} (+ .pdf)")


def main() -> None:
    data: dict[str, dict[str, float]] = {}
    data_cyc: dict[str, dict[str, float]] = {}
    cfgs = sorted({c for _, _, pts in RAYS for c, _ in pts})
    for cfg in cfgs:
        rpt = BASE / f"{cfg}_lw9_id125_noguide_spp_fixed/reports/array_components.rpt"
        if not rpt.exists():
            sys.exit(f"missing {rpt} -- run pt_array_components.tcl first")
        v = parse_rpt(rpt)
        k, m, n = map(int, re.match(r"k(\d+)m(\d+)n(\d+)", cfg).groups())
        mac_per_cycle = k * m * n * n / T
        seg = segments_mw(v)
        for s, p in seg.items():
            if p < -1e-4:
                sys.exit(f"{cfg}: negative component {s} = {p} mW -- "
                         f"decomposition bug, refusing to plot")
        pj = {s: max(0.0, p) * PERIOD_NS / mac_per_cycle
              for s, p in seg.items()}
        # segments must reconcile to the PE hierarchy total, and the PE total
        # must not exceed the sweep's whole-array measurement
        pe_ref = v["pe_total"] * PERIOD_NS / mac_per_cycle
        total = sum(pj.values())
        if abs(total - pe_ref) > max(0.005 * pe_ref, 1e-4):
            sys.exit(f"{cfg}: component total {total:.4f} pJ/MAC != "
                     f"PE total {pe_ref:.4f}")
        if total > sweep_pj(cfg) * 1.001:
            sys.exit(f"{cfg}: PE total {total:.4f} exceeds array total "
                     f"{sweep_pj(cfg):.4f} from results.csv")
        data[cfg] = pj
        data_cyc[cfg] = {s: max(0.0, p) * PERIOD_NS for s, p in seg.items()}

    for name, d, unit in (("pe_components_low_corner.csv", data, "pJ_MAC"),
                          ("pe_components_low_corner_raw.csv", data_cyc,
                           "pJ_cycle")):
        with open(REPO / "sweeps" / name, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["config"] + [s for s, _, _ in SEGMENTS]
                       + [f"total_{unit}"])
            for cfg in cfgs:
                row = [d[cfg][s] for s, _, _ in SEGMENTS]
                w.writerow([cfg] + [f"{x:.6f}" for x in row]
                           + [f"{sum(row):.6f}"])

    # Publication figures: (7,3) in, base font 12, no in-figure title (the
    # caption carries it), vector PDF alongside a 300 dpi PNG.
    plt.rcParams.update({
        "font.size": 12,
        "axes.titlesize": 12,
        "axes.labelsize": 12,
        "xtick.labelsize": 12,
        "ytick.labelsize": 12,
        "legend.fontsize": 12,
        "pdf.fonttype": 42,   # embed TrueType so text stays editable
        "ps.fonttype": 42,
    })
    draw_rays(data, "pJ/MAC",
              REPO / "sweeps/pe_components_low_corner.png", sharey=True,
              figsize=(7.0, 3.3))
    # Same figure with LaTeX-look serif typography (STIX ships with
    # matplotlib, so this renders identically everywhere; swap to
    # text.usetex for camera-ready if the venue demands real CM).
    with plt.rc_context({"font.family": "STIXGeneral",
                         "mathtext.fontset": "stix"}):
        draw_rays(data, "pJ/MAC",
                  REPO / "sweeps/pe_components_low_corner_serif.png",
                  sharey=True, figsize=(7.0, 3.3))
    # Unnormalized: energy per clock (= mW x 2.5 ns).  Per-ray axes: the N
    # ray grows with the tile count and would flatten K/M on a shared scale.
    draw_rays(data_cyc, "pJ/cycle",
              REPO / "sweeps/pe_components_low_corner_raw.png", sharey=False)
    for cfg in cfgs:
        top = max(SEGMENTS, key=lambda s: data[cfg][s[0]])
        print(f"  {cfg}: total {sum(data[cfg].values()):8.3f} pJ/MAC, "
              f"largest = {top[1]} ({data[cfg][top[0]]:.3f})")


if __name__ == "__main__":
    main()
