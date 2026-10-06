#!/usr/bin/env python3
"""Array-level cross-design spec table with precision scaling, one row per
(arm, precision) point.  Every arm is fixed at the geometry that gives
1024 MAC/clock (409.6 GMAC/s) at its 8-bit point -- the LLM-Timeloop study
geometries -- and precision then moves along that arm's rows.

Compute only (no SRAM/DRAM: at this scale the study adds ~6.2 mm2 of SRAM to
every arm, flattening chip-area comparisons -- see soren_scmp MODELLING.md
4.3).  Serial arms (PaYN, bitmod, uSystolic) sweep precision on ONE piece of
silicon: area is constant down their rows and throughput rises.  Binary BP's
native-width rows are DIFFERENT netlists (area changes, throughput does not).
bitmod scales weight precision only (activations stay i8 / f16); PaYN scales
both operands (T = 2^(bits+1) magnitude); UR's precision is its rate length.

Caveats: PaYN T<128 rows are drain-limited (compute energy valid, sustained
throughput needs a wider drain, doc/results.md); all bitmod rows are
collaborator-reported and unreplicated (Simple's route misses timing by
-0.004 ns); BP INT7/6 have no measured dynamic/leakage split.

Emits sweeps/design_spec_table_array.csv and prints a markdown table.
Sources: soren_scmp/simulator/accelergy-sc-plugin LUTs (measured TSMC22
characterization); BP native INT7/6 from doc/results.md (unit-level, x16).
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

sys.path.insert(0, "/home/barrylyu/repos/soren_scmp/simulator/accelergy-sc-plugin")
import sc_energy_lut as sc
import bos_energy_lut as bos
import bp_energy_lut as bp
import ur_energy_lut as ur
import bitmod_energy_lut as bm

REPO = Path(__file__).resolve().parent.parent

# (arm, precision_label, bits, geometry, GMAC_s, mm2, dyn_pj, leak_mw, tot_mw, tot_pj)
rows: list[tuple] = []


def add(arm, plabel, bits, geometry, gmacs, mm2, dyn_pj, leak_mw):
    tot_mw = dyn_pj * gmacs + leak_mw
    rows.append((arm, plabel, bits, geometry, gmacs, mm2, dyn_pj, leak_mw,
                 tot_mw, tot_mw / gmacs))


g = sc.array_geometry(4, 4)
for T, bits in ((128, 8), (64, 7), (32, 6), (16, 5)):
    gm = sc.peak_macs_per_second(g, T=T) / 1e9
    add("PaYN 4x4 mesh (both operands)", f"T={T}", bits,
        "4x4 PEs x 64 tiles", gm, sc.area_um2(g) / 1e6,
        sum(sc.dyn_pj_by_component(T, g).values()),
        sc.leak_pj_per_mac(T, g) * gm)

gb = bos.array_geometry(4, 4)
gm = bos.peak_macs_per_second(gb) / 1e9
add("Binary BOS", "INT8", 8, "16x 8x8 arrays", gm, bos.area_um2(gb) / 1e6,
    bos.dyn_pj(geom=gb), bos.leak_pj_per_mac(geom=gb) * gm)

# BP: INT8 only -- native INT7/6 narrowings are separate netlists at fixed
# throughput and are deliberately excluded from this table (see results.md
# for those points).  Run 20260718_165153: dynamic 10.550009 mW, leakage
# 0.053443 mW per 8x8 unit.
rows.append(("Binary BP (weight-stationary)", "INT8", 8, "16x 8x8 arrays",
             409.6, 16536.226 * 16 / 1e6, 10.550009 * 16 / 409.6, 0.855,
             10.60345 * 16, 10.60345 * 16 / 409.6))

for arm, modes in (("bitmod Simple (weights only)",
                    (("s8", 8), ("s6", 6), ("s4", 4), ("s2", 2))),
                   ("bitmod BitMoD f16 act (weights only)",
                    (("i8", 8), ("i6", 6), ("f4", 4)))):
    for mode, bits in modes:
        bm.set_mode(mode)
        gbm = bm.array_geometry(4, 4)
        gm = bm.peak_macs_per_second(gbm) / 1e9
        tot_mw = bm.total_power_w(gbm) * 1e3
        rows.append((arm, mode, bits, "4x4 tiles (1024 PEs)", gm,
                     bm.area_um2(gbm) / 1e6, None, None, tot_mw, tot_mw / gm))

# uSystolic on the same T ladder as PaYN.  T=128/64 are measured; T=32/16
# extrapolate the measured power, which is flat in T to 0.2% across the
# characterized 64..256 range (rate-coded toggling is stream-length
# independent; only throughput moves).  Flagged with * in the labels.
gu = ur.array_geometry(32, 64)
N_UR = 2048
for T, bits in ((128, 7), (64, 6)):
    gm = ur.peak_macs_per_second(gu, T=T) / 1e9
    add("uSystolic UR x2048 (rate length)", f"T={T}", bits,
        "2048x 8x8 arrays", gm, ur.area_um2(gu) / 1e6,
        ur.dyn_pj(T, gu), ur.leak_pj_per_mac(T, gu) * gm)
for T, bits in ((32, 5), (16, 4)):
    gm = N_UR * (64 / T) * 0.4          # 2048 arrays x 64/T MAC/cyc x 0.4 GHz
    tot_mw = N_UR * ur.TOTAL_W_BY_T[64] * 1e3
    leak_mw = N_UR * ur.LEAK_W_BY_T[64] * 1e3
    add("uSystolic UR x2048 (rate length)", f"T={T}*", bits,
        "2048x 8x8 arrays", gm, ur.area_um2(gu) / 1e6,
        (tot_mw - leak_mw) / gm, leak_mw)

# ---- wide layout: one row per arm, up to 4 positional operating points ----
# Each point is (label, total mW, GMAC/s); labels are the arm's own precision
# naming (T=..., i4xi8, INT7, ...).  Area and leakage are anchor columns:
# constant down every fixed-silicon sweep.  BP re-spins shrink (0.265/0.242/
# 0.214 mm2 for INT8/7/6) -- the 8-bit value is shown, variation footnoted.
POINT_LABEL = {"s8": "i8xi8", "s6": "i6xi8", "s4": "i4xi8", "s2": "i2xi8",
               "i8": "i8xf16", "i6": "i6xf16", "f4": "f4xf16"}
MAX_PTS = 4
arms: dict[str, dict] = {}
for arm, plabel, bits, geometry, gmacs, mm2, dyn, leak, tot, pj in rows:
    a = arms.setdefault(arm, {"geometry": geometry, "pts": []})
    a["pts"].append((POINT_LABEL.get(plabel, plabel), tot, gmacs))
    if "mm2" not in a:
        a.update(mm2=mm2, leak=leak)

out = REPO / "sweeps/design_spec_table_array.csv"
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    hdr = ["arm", "geometry", "compute_mm2", "leakage_mW"]
    for i in range(1, MAX_PTS + 1):
        hdr += [f"p{i}_point", f"p{i}_total_mW", f"p{i}_GMAC_s"]
    w.writerow(hdr)
    for arm, a in arms.items():
        row = [arm, a["geometry"], f"{a['mm2']:.4f}",
               f"{a['leak']:.3f}" if a.get("leak") is not None else ""]
        for i in range(MAX_PTS):
            if i < len(a["pts"]):
                lab, tot, gm = a["pts"][i]
                row += [lab, f"{tot:.1f}", f"{gm:.1f}"]
            else:
                row += ["", "", ""]
        w.writerow(row)
print(f"wrote {out}")

print("\n| arm | mm2 | " + " | ".join(f"point {i+1}" for i in range(MAX_PTS))
      + " |")
print("|---|--:|" + "---|" * MAX_PTS)
for arm, a in arms.items():
    cells = []
    for i in range(MAX_PTS):
        if i < len(a["pts"]):
            lab, tot, gm = a["pts"][i]
            cells.append(f"{lab}: {tot:.0f} mW @ {gm:.0f}")
        else:
            cells.append("")
    print(f"| {arm} | {a['mm2']:.3f} | " + " | ".join(cells) + " |")

# ---- LaTeX (booktabs + multirow + colortbl, single column) ---------------
# Display names track the user's edits; \sysname{} comes from the paper
# preamble.  Label cells carry a strut so the gray band reaches the cell top.
TEX_ARM = {
    "PaYN 4x4 mesh (both operands)": (r"\sysname{} (This work)", "0.633"),
    "Binary BOS": (r"INT8 OS", "0.253"),
    "Binary BP (weight-stationary)": (r"INT8 WS", "0.265"),
    "bitmod Simple (weights only)": (r"BitMoD INT-Only", "0.358"),
    "bitmod BitMoD f16 act (weights only)": (r"BitMoD", "1.130"),
    "uSystolic UR x2048 (rate length)": (r"uSystolic", "21.8"),
}


def tex_label(lab: str) -> str:
    star = lab.endswith("*")
    lab = lab.rstrip("*")
    if lab.startswith("T="):
        out = rf"$T{{=}}{lab[2:]}{'^*' if star else ''}$"
    elif "x" in lab and lab[0] in "if":
        a_, b_ = lab.split("x")
        out = rf"{a_}$\times${b_}"
    else:
        out = lab
    return out


tex = REPO / "sweeps/design_spec_table_array.tex"
with open(tex, "w") as f:
    f.write("\n".join([
        r"% Generated by sweeps/make_design_spec_table.py -- do not hand-edit.",
        r"% Requires: \usepackage{booktabs, multirow}, "
        r"\usepackage[table]{xcolor}.",
        r"\begin{table}[t]",
        r"\centering",
        r"\caption{Array-level comparison at iso-8-bit silicon "
        r"(1024\,MAC/clock geometries, TSMC22, 0.80\,V, 400\,MHz, compute "
        r"only).  Multi-point rows sweep precision on one piece of silicon "
        r"(PaYN scales both operands; bitmod scales weights, activations "
        r"stay i8/f16).  PaYN points below $T{=}128$ are drain-limited; "
        r"bitmod rows are collaborator-reported and unreplicated; starred "
        r"uSystolic points extrapolate its measured, $T$-flat power.}",
        r"\label{tab:array_spec}",
        r"\providecommand{\opsep}{\,\rule[-0.4ex]{0.6pt}{2ex}\,}",
        r"\scriptsize",
        r"\setlength{\tabcolsep}{3pt}",
        r"\begin{tabular}{@{}l r llll@{}}",
        r"\toprule",
        r"Design & mm$^2$ & "
        r"\multicolumn{4}{l}{Operating Points (mW\,\opsep\,GMAC/s)} \\",
        r"\specialrule{\lightrulewidth}{\aboverulesep}{0pt}",
    ]) + "\n")
    for arm, a in arms.items():
        name, mm2 = TEX_ARM.get(arm, (arm, f"{a['mm2']:.3f}"))
        labs, vals = [], []
        for i in range(MAX_PTS):
            if i < len(a["pts"]):
                lab, tot, gm = a["pts"][i]
                labs.append(rf"\cellcolor{{gray!12}}\rule{{0pt}}{{1.9ex}}"
                            rf"{tex_label(lab)}")
                vals.append(rf"{tot:.0f}\opsep{gm:.0f}")
            else:
                labs.append("")
                vals.append("")
        f.write(rf"\multirow{{2}}{{*}}{{{name}}} & "
                rf"\multirow{{2}}{{*}}{{{mm2}}} & "
                + " & ".join(labs) + r" \\" + "\n")
        f.write("& & " + " & ".join(vals) + r" \\" + "\n")
        f.write(r"\addlinespace[3pt]" + "\n")
    f.write("\n".join([
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table}",
    ]) + "\n")
print(f"wrote {tex}")
