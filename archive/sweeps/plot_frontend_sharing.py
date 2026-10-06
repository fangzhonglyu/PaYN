#!/usr/bin/env python3
"""Conversion + RNG front-end overhead under P-way sharing, K8/M16 N-curve.

The front end (u_a_rng + u_w_rng Sobol banks, u_peripheral operand regs +
comparators, and the CTS/ICG cells inside those hierarchies) produces operand
bit-streams that P identical arrays could consume: its cost per MAC divides
by P while the rest of the array (u_pe + top-level clock/glue) is paid per
array.  First-order model -- the broadcast wiring to P arrays and the extra
drive on the shared streams are not in the measurement.

    pJ/MAC(P) = rest_pJMAC + fe_pJMAC / P

Reads reports/array_components.rpt (sweeps/pt_array_components.tcl); writes
sweeps/frontend_sharing.{png,pdf,csv}.  rng_a/rng_w are emitted separately in
the CSV so a half-shared tiling (a-streams shared, w-side per array) can be
read off without rerunning.
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
PERIOD_NS = 2.5
T = 128

# Two K/N configurations with M on the x axis: each M lane carries its own
# Sobol column, so RNG hardware grows with M exactly as fast as the MAC rate
# and M never amortizes the front end -- sharing it across P arrays is the
# only lever.  Left: the small-scale corner where the overhead dominates.
# Right: the accepted-regime grid points (M=8, 16 exist at K=8/N=8).
# Sub-bars within each M group are P, the number of arrays sharing one
# conversion + RNG front end.
PANELS = [
    ("K=1, N=1", "M",
     [("k1m1n1", 1), ("k1m2n1", 2), ("k1m4n1", 4),
      ("k1m8n1", 8), ("k1m16n1", 16)]),
    ("K=8, N=8", "M",
     [("k8m8n8", 8), ("k8m16n8", 16)]),
]
# kept in the CSV for reference even though no longer plotted
CSV_EXTRA = ["k2m1n1", "k4m1n1", "k8m1n1", "k16m1n1",
             "k8m16n1", "k8m16n2", "k8m16n4", "k8m16n6", "k8m16n10"]
P_VALUES = [1, 2, 4]

REST_C = "#b5b4ab"   # deliberate neutral: the per-array remainder
FE_C = "#fc8d62"     # the shared front end -- the subject of the figure
INK = "#000000"


def parse_rpt(path: Path) -> dict[str, float]:
    v: dict[str, float] = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^([a-z_]+)\s+([-+0-9.eE]+)", line)
        if m:
            v[m.group(1)] = float(m.group(2))
    return v


def find_rpt(cfg: str) -> Path:
    for tag in ("noguide", "distguide"):
        p = BASE / f"{cfg}_lw9_id125_{tag}_spp_fixed/reports/array_components.rpt"
        if p.exists():
            return p
    sys.exit(f"missing array_components.rpt for {cfg}")


def load_row(cfg: str) -> dict:
    rpt = find_rpt(cfg)
    v = parse_rpt(rpt)
    k, m, n = map(int, re.match(r"k(\d+)m(\d+)n(\d+)", cfg).groups())
    macpc = k * m * n * n / T
    to_pj = PERIOD_NS / macpc
    fe_mw = v["rng_total"] + v["periph_total"] + v["clock_fe"]
    total_mw = None
    for line in rpt.read_text().splitlines():
        mm = re.search(r"TOTAL\s+([0-9.]+)$", line)
        if mm:
            total_mw = float(mm.group(1))
            break
    return {
        "cfg": cfg,
        "fe_pj": fe_mw * to_pj, "rest_pj": (total_mw - fe_mw) * to_pj,
        "rng_a_pj": v["rng_a_total"] * to_pj,
        "rng_w_pj": v["rng_w_total"] * to_pj,
        "periph_pj": v["periph_total"] * to_pj,
        "clock_fe_pj": v["clock_fe"] * to_pj,
    }


def main() -> None:
    rows = {cfg: load_row(cfg)
            for _, _, pts in PANELS for cfg, _ in pts}
    for cfg in CSV_EXTRA:
        rows.setdefault(cfg, load_row(cfg))

    with open(REPO / "sweeps/frontend_sharing.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["config", "rest_pJ_MAC", "fe_pJ_MAC",
                    "rng_a_pJ_MAC", "rng_w_pJ_MAC", "periph_pJ_MAC",
                    "clock_fe_pJ_MAC"]
                   + [f"total_P{p}" for p in P_VALUES]
                   + [f"fe_share_P{p}_pct" for p in P_VALUES])
        for r in rows.values():
            tot = [r["rest_pj"] + r["fe_pj"] / p for p in P_VALUES]
            shr = [100.0 * (r["fe_pj"] / p) / t for p, t in zip(P_VALUES, tot)]
            w.writerow([r["cfg"]]
                       + [f"{r[k]:.6f}" for k in ("rest_pj", "fe_pj",
                          "rng_a_pj", "rng_w_pj", "periph_pj", "clock_fe_pj")]
                       + [f"{t:.6f}" for t in tot] + [f"{s:.2f}" for s in shr])

    # Publication figures, matching plot_low_corner_components.py: (7,3) in,
    # base font 12, no in-figure title (the caption carries it), vector PDF
    # alongside a 300 dpi PNG, and a STIX-serif variant.
    plt.rcParams.update({
        "font.size": 14,
        "axes.titlesize": 14,
        "axes.labelsize": 14,
        "xtick.labelsize": 14,
        "ytick.labelsize": 14,
        "legend.fontsize": 14,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    })
    draw(rows, REPO / "sweeps/frontend_sharing.png")
    with plt.rc_context({"font.family": "STIXGeneral",
                         "mathtext.fontset": "stix"}):
        draw(rows, REPO / "sweeps/frontend_sharing_serif.png")
    for _, _, pts in PANELS:
        for cfg, _ in pts:
            r = rows[cfg]
            line = ", ".join(
                f"P={p}: {100*(r['fe_pj']/p)/(r['rest_pj']+r['fe_pj']/p):.1f}%"
                for p in P_VALUES)
            print(f"  {cfg}: fe={r['fe_pj']:.3f} rest={r['rest_pj']:.3f} pJ/MAC"
                  f" | fe share {line}")


def draw(rows: dict, out_png: Path) -> None:
    """100%-normalized stacks: each bar is one (M, P) point; the orange
    fraction is the front end's share of array power at that sharing factor."""
    fig, axes = plt.subplots(
        1, 2, figsize=(7.0, 2.7), facecolor="white",
        gridspec_kw={"width_ratios": [len(p[2]) for p in PANELS]})
    gw, bw = 0.86, 0.26
    for ax, (title, axis_name, pts) in zip(axes, PANELS):
        ax.set_facecolor("white")
        first = ax is axes[0]
        for gi, (cfg, val) in enumerate(pts):
            r = rows[cfg]
            for pi, p in enumerate(P_VALUES):
                x = gi + (pi - 1) * (gw / 3)
                fe = 100.0 * (r["fe_pj"] / p) / (r["rest_pj"] + r["fe_pj"] / p)
                ax.bar(x, 100.0 - fe, bw, color=REST_C, edgecolor="white",
                       linewidth=0.8,
                       label="Core PEs" if first and gi == pi == 0 else None)
                ax.bar(x, fe, bw, bottom=100.0 - fe, color=FE_C,
                       edgecolor="white", linewidth=0.8,
                       label="Conversion + RNG"
                             if first and gi == pi == 0 else None)
                ax.text(x, -4.5, f"P{p}", ha="center", va="top",
                        fontsize=12, color=INK)
            ax.text(gi, -22, f"{axis_name}={val}", ha="center",
                    va="top", fontsize=14, color=INK)
        ax.set_xticks([])
        ax.set_title(title, color=INK, pad=4)
        ax.grid(axis="y", color="#e4e3dd", linewidth=0.8)
        ax.set_axisbelow(True)
        ax.set_ylim(0, 100)
        ax.set_yticks([0, 25, 50, 75, 100])
        ax.set_xlim(-0.6, len(pts) - 0.4)
        for s in ("top", "right", "left", "bottom"):
            ax.spines[s].set_visible(True)
            ax.spines[s].set_color(INK)
    axes[0].set_ylabel("Power Share (%)", color=INK)
    axes[1].tick_params(labelleft=False)
    leg = fig.legend(loc="upper center", bbox_to_anchor=(0.53, 1.01),
                     ncol=2, frameon=True, fancybox=True, edgecolor="none",
                     facecolor="#f2f3f5", framealpha=1.0, borderpad=0.4,
                     labelcolor=INK, handlelength=1.0, handletextpad=0.4,
                     columnspacing=0.9)
    for h in leg.legend_handles:
        h.set_edgecolor("none")
    fig.tight_layout(rect=(0, 0, 1, 0.88))
    fig.savefig(out_png, dpi=300, facecolor="white", bbox_inches="tight")
    fig.savefig(out_png.with_suffix(".pdf"), facecolor="white",
                bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out_png} (+ .pdf)")


if __name__ == "__main__":
    main()
