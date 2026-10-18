#!/usr/bin/env python3
"""doc/flexposit_results.md from a flow/flexposit.sh campaign, beside the PaYN study's baselines.

  python3 flow/flexposit_report.py fp_20261015            # build/flow/flexposit/fp_20261015 -> doc/flexposit_results.md

Reads the campaign's results.csv (one row per weight precision P, every row from a qualified route and gated
measurement), the route's reports/area.rpt (routed cell area by hierarchy) and each point's power_hier.rpt
(PrimeTime PX by hierarchy), and the baselines:
  * BOS INT8 / INT6 / INT4 8x8 arrays: doc/payn_results.md "Against BOS" (same flow, same gates);
  * the array-level comparison of the PaYN paper (PaYN_paper/src/evaluation/efficiency.tex, tab:array_spec):
    1,024 MAC/clock geometries, area in mm2 and operating points in mW | GMAC/s at 400 MHz, SRAM excluded.

FlexPosit normalization: like the BitMoD rows of that table (a weight-precision-scalable bit-serial array sized so
its 4-bit weight mode retires 1,024 MAC/clock), 64 FlexPosit 8x8 cores = 1,024 MAC/clock at P = 4, 512 at P = 8.
The cores share nothing, so area and power scale linearly from the measured core.  Power at an operating point is
the measured energy per useful MAC (whole tiles: decode fill, products, drain and FP16 readout) times the peak MAC
rate -- the convention of the BOS rows (pJ/MAC from the window, GMAC/s at peak).
"""
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PERIOD_NS = 2.5
CORES = 64  # 64 x (8x8 / 4) = 1,024 MAC/clock at P = 4

# PaYN paper, src/evaluation/efficiency.tex, tab:array_spec (Design, mm2, [(mode, mW, GMAC/s)]).
PAPER = [
    ("PaYN (SC, both operands)", 0.633, [("T=128", 260, 410), ("T=64", 272, 819), ("T=32", 295, 1638),
                                         ("T=16", 364, 3277)]),
    ("INT8 OS", 0.253, [("INT8", 169, 410)]),
    ("INT8 WS", 0.265, [("INT8", 170, 410)]),
    ("BitMoD INT-only", 0.183, [("i8 x i8", 100, 205), ("i6 x i8", 104, 273), ("i4 x i8", 108, 410),
                                ("i2 x i8", 118, 819)]),
    ("BitMoD", 0.572, [("i8 x f16", 235, 205), ("i6 x f16", 245, 273), ("f4 x f16", 245, 410)]),
    ("uSystolic", 0.171, [("T=128", 45, 3.2), ("T=64", 45, 6.4), ("T=32", 45, 12.8), ("T=16", 45, 25.6)]),
]
PAPER_SRC = "PaYN_paper/src/evaluation/efficiency.tex (tab:array_spec)"

CLASSES = [
    ("pe", "PEs (64): pipe registers, shift-add multiplier, block-floating accumulator",
     re.compile(r"^u_systolic/row_\d+__col_\d+__pe$")),
    ("decoder", "SerialPosit decoders + beat FIFOs (8)",
     re.compile(r"^u_systolic/decoder_loop_\d+__posit_decoder_and_fifo$")),
    ("readout", "readout datapath (8): normalize, power-of-two rescale, FP16 convert",
     re.compile(r"^u_systolic/gen_ship_col_\d+__u_(norm|rescale|to_fp16)$")),
    ("cycle_gen", "cycle generator (the paper's GPCU counter)", re.compile(r"^u_systolic/u_cyc$")),
]


def num(s: str) -> float:
    return float(s.replace(",", ""))


def parse_area(path: Path) -> tuple[float, dict[str, float]]:
    """(top total, {hierarchical path: total area}) from Innovus' hierarchical area report."""
    top, areas = None, {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith(("Hinst", "-")):
            continue
        tok = line.split()
        if not line.startswith(" "):
            top = float(tok[2])
        else:
            areas[tok[0]] = float(tok[3])
    assert top is not None, f"no top line in {path}"
    return top, areas


def parse_power(path: Path) -> tuple[float, dict[str, tuple[float, float, float, float]]]:
    """(top total mW, {path: (internal, switching, leakage, total) mW}) from PT's report_power -hierarchy."""
    rows, stack, top = {}, [], None
    pat = re.compile(r"^(\s*)(\S+)(?:\s+\([^)]*\))?\s+([-0-9.eE+]+)\s+([-0-9.eE+]+)\s+([-0-9.eE+]+)\s+([-0-9.eE+]+)\s+[0-9.]+\s*$")
    started = False
    for line in path.read_text().splitlines():
        if line.startswith("-----"):
            started = True
            continue
        m = pat.match(line) if started else None
        if not m:
            continue
        depth = len(m[1]) // 2
        vals = tuple(float(m[i]) * 1e3 for i in range(3, 7))
        if depth == 0:
            top, stack = vals[3], []
            continue
        stack = stack[: depth - 1] + [m[2]]
        rows["/".join(stack)] = vals
    assert top is not None, f"no top line in {path}"
    return top, rows


def split(total: float, sys_total: float, items: dict[str, float]) -> dict[str, float]:
    """Class totals: the CLASSES, the rest of u_systolic (control, stage registers, row mux), the top level."""
    out = {key: 0.0 for key, _, _ in CLASSES}
    for path, v in items.items():
        for key, _, rx in CLASSES:
            if rx.match(path):
                out[key] += v
    out["systolic_rest"] = sys_total - sum(out[k] for k, _, _ in CLASSES)
    out["top_rest"] = total - sys_total
    return out


def bos_rows() -> list[dict]:
    text = (REPO / "doc/payn_results.md").read_text()
    sec = text.split("## Against BOS", 1)[1].split("\n## ", 1)[0]
    rows = []
    for m in re.finditer(r"^\| INT(\d) \| ([\d,.]+) \| ([\d.]+) \| ([\d.]+) \| ([\d,]+) \|", sec, re.M):
        rows.append(dict(width=int(m[1]), area=num(m[2]), power=float(m[3]), pj=float(m[4]), gmacmm2=num(m[5])))
    assert rows, "no BOS rows in doc/payn_results.md"
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("campaign")
    ap.add_argument("--out", type=Path, default=REPO / "doc/flexposit_results.md")
    a = ap.parse_args()
    work = REPO / "build/flow/flexposit" / a.campaign
    rows = list(csv.DictReader((work / "results.csv").open()))
    assert rows, f"no rows in {work / 'results.csv'}"
    run = rows[0]["run"]
    route = REPO / "apr/build/TSMC22/FLEXPOSIT_CORE" / run
    area_total, areas = parse_area(route / "reports/area.rpt")
    a_cls = split(area_total, areas["u_systolic"], areas)
    pe_count = sum(1 for p in areas if CLASSES[0][2].match(p))
    assert pe_count == 64, f"expected 64 PE hierarchies in area.rpt, found {pe_count}"

    pts = []
    for r in sorted(rows, key=lambda r: int(r["P"])):
        p = int(r["P"])
        ptot, prow = parse_power(work / f"power_p{p}" / "power_hier.rpt")
        sys_tot = prow["u_systolic"][3]
        p_cls = split(ptot, sys_tot, {k: v[3] for k, v in prow.items()})
        leak = sum(v[2] for k, v in prow.items() if "/" not in k) + 0.0
        pj = float(r["pJ_MAC"])
        peak_core = float(r["peak_GMAC_s"])
        pts.append(dict(P=p, row=r, ptot=ptot, p_cls=p_cls, pj=pj, peak_core=peak_core,
                        eff_core=float(r["effective_GMAC_s"]), power=float(r["power_mW"]),
                        window=int(r["window_cycles"]), useful=int(r["useful_mac"]),
                        lanes=int(r["lanes_checked"]), K=int(r["K"]), tiles=int(r["tiles"])))

    L = []
    w = L.append
    w("# FlexPosit core results")
    w("")
    w(f"Generated by `flow/flexposit_report.py {a.campaign}` from `build/flow/flexposit/{a.campaign}` "
      "(`flow/flexposit.sh`); do not edit by hand.  Every number is read from the qualified route and its gated "
      "measurements; the baselines are quoted from the files named under Sources.")
    w("")
    w("Design: `designs/baselines/flexposit` -- the FlexPosit RTL (github.com/hplp/FlexPosit, commit e42a219, "
      "byte-identical), 8x8 core: per-column SerialPosit decoders, 64 bit-serial Posit(P, es) x FP8 PEs with "
      "block-floating accumulators, cycle generator, per-column FP16 readout with power-of-two rescale.  TSMC22 "
      "sc7mcpp140z SVT C30 + HPK, 400 MHz, the BOS route knobs (flow/bos.sh).  N*N/P MAC/cycle per core.")
    w("")
    q = rows[0]
    w("## Route")
    w("")
    w("| route | area (um2) | setup / hold WNS (ns) | qualification |")
    w("|---|---:|---:|---|")
    wns = q.get("setup_wns_ns") or q.get("setup_wns") or "?"
    hws = q.get("hold_wns_ns") or q.get("hold_wns") or "?"
    w(f"| {run} | {area_total:,.1f} | {wns} / {hws} | routed-apr PASS; every point routed-gl, saif-binary, "
      "pt-coverage PASS |")
    w("")
    w("## Area by block")
    w("")
    w("| block | um2 | % | per unit (um2) |")
    w("|---|---:|---:|---:|")
    units = dict(pe=64, decoder=8, readout=8, cycle_gen=1)
    for key, label, _ in CLASSES:
        w(f"| {label} | {a_cls[key]:,.1f} | {100 * a_cls[key] / area_total:.1f} | {a_cls[key] / units[key]:,.1f} |")
    w(f"| rest of the array (readout stage registers + row mux, completion counters, skew registers, clock gates) "
      f"| {a_cls['systolic_rest']:,.1f} | {100 * a_cls['systolic_rest'] / area_total:.1f} | - |")
    w(f"| top level (port buffers) | {a_cls['top_rest']:,.1f} | {100 * a_cls['top_rest'] / area_total:.1f} | - |")
    w(f"| **total** | **{area_total:,.1f}** | 100 | - |")
    w("")
    w("## Measured, one 8x8 core")
    w("")
    w("Window: whole tiles back to back (decode fill, K products, systolic drain, row-by-row FP16 readout); "
      f"{pts[0]['tiles']} tiles of K = {pts[0]['K']}, es = 1, uniform random FP8 activations, uniform random "
      "non-NaR Posit(P, 1) weights, column scales in [-8, 7]; every FP16 lane checked bit-exact against the model "
      "in the gate-level run.  pJ/MAC = P_avg x window x 2.5 ns / useful MAC.")
    w("")
    w("| P | power (mW) | window cycles | useful MAC | pJ/MAC | peak MAC/cycle | peak GMAC/s | effective GMAC/s | "
      "peak GMAC/s/mm2 | lanes checked |")
    w("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for t in pts:
        w(f"| {t['P']} | {t['power']:.3f} | {t['window']:,} | {t['useful']:,} | {t['pj']:.4f} | "
          f"{64 / t['P']:.2f} | {t['peak_core']:.2f} | {t['eff_core']:.2f} | "
          f"{t['peak_core'] / (area_total / 1e6):,.0f} | {t['lanes']} |")
    w("")
    w("Power by block (mW, PrimeTime PX, routed SPEF):")
    w("")
    w("| block | " + " | ".join(f"P={t['P']}" for t in pts) + " |")
    w("|---|" + "---:|" * len(pts))
    for key, label, _ in CLASSES:
        w(f"| {label} | " + " | ".join(f"{t['p_cls'][key]:.3f}" for t in pts) + " |")
    w("| rest of the array | " + " | ".join(f"{t['p_cls']['systolic_rest']:.3f}" for t in pts) + " |")
    w("| top level | " + " | ".join(f"{t['p_cls']['top_rest']:.3f}" for t in pts) + " |")
    w("| **total** | " + " | ".join(f"**{t['ptot']:.3f}**" for t in pts) + " |")
    w("")
    w("## Core parameters at 1,024 MAC/clock")
    w("")
    w(f"FlexPosit: {CORES} cores of 8x8 = 1,024 MAC/clock at P = 4 (4-bit weights), the sizing of the BitMoD "
      "rows (4-bit weight mode = 1,024 MAC/clock).  Area and power scale linearly (the cores share nothing).  "
      "Operating points: mW | peak GMAC/s at 400 MHz; mW = measured pJ/MAC x peak GMAC/s.  The other rows are "
      f"quoted from {PAPER_SRC}; SRAM excluded everywhere.")
    w("")
    fp_area = CORES * area_total / 1e6
    w("| design | operands | mm2 | operating points (mW \\| GMAC/s) |")
    w("|---|---|---:|---|")
    ops = "; ".join(f"P={t['P']}: {CORES * t['pj'] * t['peak_core']:.0f} \\| {CORES * t['peak_core']:.0f}" for t in pts)
    w(f"| **FlexPosit (this flow)** | Posit(P,1) W x FP8 A | **{fp_area:.3f}** | {ops} |")
    operands = {"PaYN (SC, both operands)": "SC both, T bits", "INT8 OS": "INT8 x INT8", "INT8 WS": "INT8 x INT8",
                "BitMoD INT-only": "INT W x INT8 A", "BitMoD": "INT/FP4 W x FP16 A", "uSystolic": "unary, T bits"}
    for name, mm2, pts_p in PAPER:
        w(f"| {name} | {operands[name]} | {mm2:.3f} | " +
          "; ".join(f"{m}: {mw:g} \\| {g:g}" for m, mw, g in pts_p) + " |")
    w("")
    w("Efficiency at those points (GMAC/s/mm2 and pJ/MAC = mW / GMAC/s):")
    w("")
    w("| design | point | GMAC/s/mm2 | pJ/MAC |")
    w("|---|---|---:|---:|")
    for t in pts:
        w(f"| FlexPosit | P={t['P']} | {t['peak_core'] / (area_total / 1e6):,.0f} | {t['pj']:.4f} |")
    for name, mm2, pts_p in PAPER:
        for m, mw, g in pts_p:
            w(f"| {name} | {m} | {g / mm2:,.0f} | {mw / g:.4f} |")
    w("")
    w("## Same-flow comparison: one FlexPosit core vs the BOS 8x8 arrays")
    w("")
    w("BOS: binary output-stationary 8x8, 64 MAC/cycle, routed and measured with the same tools and gates "
      "(doc/payn_results.md, Against BOS).  BOS GMAC/s/mm2 is its drain-excluded peak; FlexPosit's is its peak, "
      "its pJ/MAC includes fill, drain and readout.")
    w("")
    w("| design | area (um2) | MAC/cycle | pJ/MAC | GMAC/s/mm2 |")
    w("|---|---:|---:|---:|---:|")
    for b in bos_rows():
        w(f"| BOS INT{b['width']} (W{b['width']}A{b['width']}) | {b['area']:,.0f} | 64 | {b['pj']:.4f} | "
          f"{b['gmacmm2']:,.0f} |")
    for t in pts:
        w(f"| FlexPosit P={t['P']} (Posit W x FP8 A) | {area_total:,.0f} | {64 / t['P']:.1f} | {t['pj']:.4f} | "
          f"{t['peak_core'] / (area_total / 1e6):,.0f} |")
    w("")
    w("## Caveats")
    w("")
    w("* The RTL is FlexPosit's 12 nm test-chip version (hardware/README.md of the FlexPosit repo): FP8 E4M3 "
      "activations and one accumulator per PE, not the paper's FP16 activations and 4-PE clusters sharing an FP16 "
      "accumulator.  The paper's own area/energy numbers (16 nm) are a different design point.")
    w("* Operands are uniform random codes (like the BOS benches), not LLM weight distributions; Posit activity "
      "depends on the weight distribution.")
    w("* FlexPosit scales only the weight precision; activations stay FP8.  BitMoD keeps INT8 or FP16 "
      "activations; PaYN scales both operands.  The operating points are not iso-precision.")
    w("* The 1,024 MAC/clock row is a grid of independent 8x8 cores.  One large FlexPosit array would amortize "
      "the per-column decoders and readout over more rows (see Area by block) but adds an N:1 row mux per column.")
    w("* The BitMoD rows are reported data, not reproduced in this project (PaYN_eval docs/MODELLING.md 2.3).")
    w("")
    w("## Sources")
    w("")
    w(f"* `build/flow/flexposit/{a.campaign}/results.csv`, `result_p*.csv`, `power_p*/power_hier.rpt`")
    w(f"* `apr/build/TSMC22/FLEXPOSIT_CORE/{run}/reports/area.rpt`")
    w("* `doc/payn_results.md` (Against BOS)")
    w(f"* `{PAPER_SRC}`")
    a.out.write_text("\n".join(L) + "\n")
    print(a.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
