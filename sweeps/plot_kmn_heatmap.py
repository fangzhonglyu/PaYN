#!/usr/bin/env python3
"""K x M x N grid heatmap around the accepted PaYN shape (K8, M16, N8).

Plots inner-PE (u_pe scope) pJ/MAC for the 18-point spp_fixed grid
(K in {4,8,12} x M in {8,16} x N in {6,8,10}): pe_total from each run's
reports/array_components.rpt (sweeps/pt_array_components.tcl; Sobol RNG,
converters and top-level clock/glue excluded) x 2.5 ns / (K*M*N^2/T).
One annotated heatmap per M, K rows x N columns, shared color scale, the
accepted point outlined.  Writes sweeps/kmn_heatmap.{png,pdf} (STIX serif).

Style matches plot_low_corner_components.py: (7,2.1) in, serif, base font 12, all
text and boxes black, sequential single-hue colormap (Greens; darker =
more energy), 300 dpi PNG + vector PDF.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

REPO = Path(__file__).resolve().parent.parent
BASE = REPO / "apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN"
PERIOD_NS = 2.5
T = 128

KS = [4, 8, 12]
KS_LABEL = ["K=4", "K=8", "K=12"]
MS = [8, 16]
NS = [6, 8, 10]
NS_LABEL=["N=6", "N=8", "N=10"]
SELECTED = (8, 16, 8)  # accepted shape
INK = "#000000"


def load_grid() -> dict[tuple[int, int, int], float]:
    """Inner-PE pJ/MAC per grid point, from pe_total of the PT walk."""
    vals: dict[tuple[int, int, int], float] = {}
    for k in KS:
        for m in MS:
            for n in NS:
                rpt = (BASE / f"k{k}m{m}n{n}_lw9_id125_distguide_spp_fixed"
                       / "reports" / "array_components.rpt")
                if not rpt.exists():
                    sys.exit(f"missing {rpt} -- run pt_array_components.tcl")
                for line in rpt.read_text().splitlines():
                    g = re.match(r"^pe_total\s+([-+0-9.eE]+)", line)
                    if g:
                        pe_mw = float(g.group(1))
                        break
                else:
                    sys.exit(f"no pe_total in {rpt}")
                mac_per_cycle = k * m * n * n / T
                vals[(k, m, n)] = pe_mw * PERIOD_NS / mac_per_cycle
    return vals


def draw(vals: dict[tuple[int, int, int], float], out_png: Path) -> None:
    vmin = min(vals.values())
    vmax = max(vals.values())
    cmap = plt.get_cmap("Greens")
    fig, axes = plt.subplots(1, 2, figsize=(7.0, 1.5), facecolor="white",
                             constrained_layout=True)
    fig.get_layout_engine().set(wspace=0.08)
    for ax, m in zip(axes, MS):
        grid = np.array([[vals[(k, m, n)] for n in NS] for k in KS])
        im = ax.imshow(grid, cmap=cmap, vmin=vmin, vmax=vmax,
                       origin="lower", aspect="auto")
        for i, k in enumerate(KS):
            for j, n in enumerate(NS):
                v = vals[(k, m, n)]
                frac = (v - vmin) / (vmax - vmin)
                ax.text(j, i, f"{v:.3f}", ha="center", va="center",
                        fontsize=14,
                        color="white" if frac > 0.65 else INK)
                if (k, m, n) == SELECTED:
                    ax.add_patch(plt.Rectangle(
                        (j - 0.5, i - 0.5), 1, 1, fill=False,
                        edgecolor=INK, linewidth=2.2))
        ax.set_xticks(range(len(NS)))
        ax.set_xticklabels(NS_LABEL, color=INK)
        ax.set_yticks(range(len(KS)))
        ax.set_yticklabels(KS_LABEL, color=INK)
        # ax.set_xlabel("N", color=INK, labelpad=1, loc="center")
        # ax.set_ylabel("K", color=INK, labelpad=1, loc="center")
        ax.set_title(f"M = {m}", color=INK, pad=4, loc="center")
        ax.tick_params(colors=INK)
        for s in ax.spines.values():
            s.set_visible(True)
            s.set_color(INK)
    cbar = fig.colorbar(im, ax=axes, fraction=0.05, pad=0.03)
    cbar.set_label("pJ/MAC", color=INK)
    cbar.ax.tick_params(colors=INK)
    cbar.outline.set_edgecolor(INK)
    fig.savefig(out_png, dpi=300, facecolor="white", bbox_inches="tight")
    fig.savefig(out_png.with_suffix(".pdf"), facecolor="white",
                bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out_png} (+ .pdf)")


def main() -> None:
    vals = load_grid()
    sel = vals[SELECTED]
    if sel != min(vals.values()):
        best = min(vals, key=vals.get)
        print(f"NOTE: at PE scope the grid minimum is "
              f"k{best[0]}m{best[1]}n{best[2]} = {vals[best]:.6f}, "
              f"not the selected point ({sel:.6f})")
    plt.rcParams.update({
        "font.size": 14,
        "axes.titlesize": 14,
        "axes.labelsize": 14,
        "xtick.labelsize": 14,
        "ytick.labelsize": 14,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    })
    plt.rcParams.update({"font.family": "STIXGeneral",
                         "mathtext.fontset": "stix"})
    draw(vals, REPO / "sweeps/kmn_heatmap.png")
    k, m, n = SELECTED
    print(f"selected k{k}m{m}n{n} = {sel:.6f} pJ/MAC (grid min); "
          f"K-line {[vals[(kk, m, n)] for kk in KS]}, "
          f"N-line {[vals[(k, m, nn)] for nn in NS]}, "
          f"M-line {[vals[(k, mm, n)] for mm in MS]}")


if __name__ == "__main__":
    main()
