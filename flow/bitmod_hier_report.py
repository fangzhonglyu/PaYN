#!/usr/bin/env python3
"""doc/bitmod_breakdown.md: BitMoD tile area and power by function, from a flow/bitmod_hier.sh campaign.

  python3 flow/bitmod_hier_report.py bm_20261016

Area: synthesis at 2.5 ns of the flat tile (BITMOD_TILE, <c>_flat) and of tile_h (<c>_p25), whose PEs are pe_scratch
split into one submodule per function (bitmod_pe_h.sv); and the routed tile_h (<c>, synthesized at SYN_PERIOD).
Power: PrimeTime PX by hierarchy on the routed tile_h, one gated gate-level run per datatype mode.
Blocks are found by module (design) name, so instance renaming by DC / Innovus does not matter.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PERIOD_NS = 2.5

# (key, label, module-name regex); PE blocks first.  Each PE block is counted 64 times (one per PE).
PE_BLOCKS = [
    ("lanes", "lanes: FP16 / term decode, exponent add, gated significand", r"^bmh_lanes"),
    ("align", "pairwise exponent compare + 2 alignment shifters + sign XOR", r"^bmh_align"),
    ("pairadd", "2 pair adders (with negation carry-ins)", r"^bmh_pairadd"),
    ("merge", "pair merge + bsig shifter", r"^bmh_merge"),
    ("acc", "beat accumulator: look-ahead, swap + align + add, overflow", r"^bmh_acc"),
    ("norm", "end-of-group normalizer (leading-one detect)", r"^bmh_norm"),
    ("scale", "group-scale bit-serial multiply + output registers", r"^bmh_scale"),
]
TILE_BLOCKS = [
    ("rf", "output-buffer register file (8 x 232 b)", r"^cg_rf"),
    ("fpadd", "column FP adders (x8, 23b mantissa)", r"^fpadd"),
    ("dreg", "input / scale staging registers", r"^cg_dreg"),
    ("common", "per-tile PE control (pe_scratch_common)", r"^pe_scratch_common"),
]
PE_RE = r"^pe_scratch_h"


def parse_dc_area(path: Path):
    """[(instance path, absolute area, design)] from DC's 'Hierarchical area distribution' plus the top total."""
    rows, top = [], None
    pat = re.compile(r"^(\S+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\S+)\s*$")
    in_tab = False
    for line in path.read_text().splitlines():
        if line.startswith("Hierarchical cell"):
            in_tab = True
            continue
        if not in_tab:
            continue
        m = pat.match(line)
        if m:
            if top is None:
                top = float(m[2])
            else:
                rows.append((m[1], float(m[2]), m[7]))
    assert top is not None, f"no hierarchical area table in {path}"
    return top, rows


def parse_innovus_area(path: Path):
    rows, top = [], None
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith(("Hinst", "-")):
            continue
        t = line.split()
        if not line.startswith(" "):
            top = float(t[2])
        else:
            rows.append((t[0], float(t[3]), t[1]))
    return top, rows


def parse_pt_power(path: Path):
    """top total mW, [(path, total mW, design)] from report_power -hierarchy."""
    rows, stack, top = [], [], None
    pat = re.compile(r"^(\s*)(\S+)(?:\s+\(([^)]*)\))?\s+([-0-9.eE+]+)\s+([-0-9.eE+]+)\s+([-0-9.eE+]+)\s+([-0-9.eE+]+)\s+[0-9.]+\s*$")
    started = False
    for line in path.read_text().splitlines():
        if line.startswith("-----"):
            started = True
            continue
        m = pat.match(line) if started else None
        if not m:
            continue
        depth = len(m[1]) // 2
        tot = float(m[7]) * 1e3
        if depth == 0:
            top = tot
            continue
        stack = stack[: depth - 1] + [m[2]]
        rows.append(("/".join(stack), tot, m[3] or ""))
    return top, rows


GROUPS = ("clock_network", "register", "combinational")


def parse_power_groups(path: Path) -> dict[str, float]:
    """{group: total W} from PrimeTime's report_power group table, plus 'total'."""
    out = {}
    for line in path.read_text().splitlines():
        t = line.split()
        if t and t[0] in GROUPS and len(t) >= 5:
            out[t[0]] = float(t[4])
        m = re.match(r"\s*Total Power\s*=\s*([-0-9.eE+]+)", line)
        if m:
            out["total"] = float(m[1])
    assert all(g in out for g in GROUPS + ("total",)), f"incomplete power group table in {path}"
    return out


def classify(top, rows):
    """{key: value} for the PE blocks, PE remainder, tile blocks and tile remainder."""
    out = defaultdict(float)
    pe_total = sum(v for p, v, d in rows if re.match(PE_RE, d))
    for key, _, rx in PE_BLOCKS + TILE_BLOCKS:
        out[key] = sum(v for p, v, d in rows if re.match(rx, d))
    out["pe_total"] = pe_total
    out["pe_rest"] = pe_total - sum(out[k] for k, _, _ in PE_BLOCKS)
    out["tile_rest"] = top - pe_total - sum(out[k] for k, _, _ in TILE_BLOCKS)
    out["total"] = top
    out["n_pe"] = sum(1 for p, v, d in rows if re.match(PE_RE, d))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("campaign")
    ap.add_argument("--out", type=Path, default=REPO / "doc/bitmod_breakdown.md")
    a = ap.parse_args()
    c = a.campaign
    work = REPO / "build/flow/bitmod_hier" / c
    flat_top, _ = parse_dc_area(REPO / f"syn/build/TSMC22/BITMOD_TILE/{c}_flat/area.rpt")
    s25_top, s25_rows = parse_dc_area(REPO / f"syn/build/TSMC22/BITMOD_TILE_H/{c}_p25/area.rpt")
    s25 = classify(s25_top, s25_rows)
    route = REPO / f"apr/build/TSMC22/BITMOD_TILE_H/{c}"
    r_top, r_rows = parse_innovus_area(route / "reports/area.rpt")
    rt = classify(r_top, r_rows)
    assert s25["n_pe"] == 64 and rt["n_pe"] == 64, (s25["n_pe"], rt["n_pe"])
    results = {int(r["beats"]) - 1: r for r in csv.DictReader((work / "results.csv").open())} if (work / "results.csv").exists() else {}
    pw = {}
    for m in sorted(results, reverse=True):
        ptop, prows = parse_pt_power(work / f"power_m{m}" / "power_hier.rpt")
        pw[m] = classify(ptop, prows)

    L = []
    w = L.append
    w("# BitMoD tile: area and power by function")
    w("")
    w(f"Generated by `flow/bitmod_hier_report.py {c}` from `flow/bitmod_hier.sh {c}`; do not edit by hand.")
    w("")
    w("The tile is the migrated BitMoD 8x8 tile (`designs/baselines/bitmod`, upstream bitmod @ 5cb051c) with each PE "
      "split into one submodule per function (`bitmod_pe_h.sv`, `pe_scratch_h`).  Every expression is copied verbatim; "
      "`tb/eq_pe_scratch_h.sv` checks every pipeline register and output of `pe_scratch_h` against the original "
      "`pe_scratch`, X-exact, every cycle, over 2 x 200,000 random cycles.  TSMC22 sc7mcpp140z SVT C30 + HPK.  "
      "The tile excludes the chip-level controller (Booth term generation, FP4 conversion, special values) and skew, "
      "as the BITMOD_TILE baseline does.")
    w("")
    w("## Area")
    w("")
    w(f"Synthesis at 2.5 ns: flat tile {flat_top:,.0f} um2, split tile {s25_top:,.0f} um2 "
      f"({100 * (s25_top / flat_top - 1):+.1f}% for the added boundaries).  Routed split tile (synthesized at "
      f"SYN_PERIOD for timing margin, see below): {r_top:,.0f} um2.")
    w("")
    w("| block | synth 2.5 ns: tile um2 | % | per PE um2 | routed: tile um2 | % |")
    w("|---|---:|---:|---:|---:|---:|")
    for key, label, _ in PE_BLOCKS:
        w(f"| PE: {label} | {s25[key]:,.0f} | {100 * s25[key] / s25_top:.1f} | {s25[key] / 64:,.1f} | "
          f"{rt[key]:,.0f} | {100 * rt[key] / r_top:.1f} |")
    w(f"| PE: clock gates and glue | {s25['pe_rest']:,.0f} | {100 * s25['pe_rest'] / s25_top:.1f} | "
      f"{s25['pe_rest'] / 64:,.1f} | {rt['pe_rest']:,.0f} | {100 * rt['pe_rest'] / r_top:.1f} |")
    w(f"| **PEs (64)** | **{s25['pe_total']:,.0f}** | **{100 * s25['pe_total'] / s25_top:.1f}** | "
      f"**{s25['pe_total'] / 64:,.1f}** | **{rt['pe_total']:,.0f}** | **{100 * rt['pe_total'] / r_top:.1f}** |")
    for key, label, _ in TILE_BLOCKS:
        w(f"| tile: {label} | {s25[key]:,.0f} | {100 * s25[key] / s25_top:.1f} | - | {rt[key]:,.0f} | "
          f"{100 * rt[key] / r_top:.1f} |")
    w(f"| tile: drain chain, glue, clock tree | {s25['tile_rest']:,.0f} | {100 * s25['tile_rest'] / s25_top:.1f} | - | "
      f"{rt['tile_rest']:,.0f} | {100 * rt['tile_rest'] / r_top:.1f} |")
    w(f"| **total** | **{s25_top:,.0f}** | 100 | - | **{r_top:,.0f}** | 100 |")
    w("")
    q = json.loads((work / "qualification.json").read_text()) if (work / "qualification.json").exists() else None
    if q and q.get("status") == "PASS" and "primetime_at_op_clock" in q:
        pt = q["primetime_at_op_clock"]
        w("## Timing sign-off")
        w("")
        w(f"The route was synthesized at {q['syn_period_ns']} ns and fails there by a few ps "
          f"({q['timing_at_syn_clock']}).  It is qualified at its 2.5 ns operating clock with ASTRAEA's rules "
          "unchanged: Innovus restores the final database, reproduces the route's own reports "
          f"(setup {q['restored_slacks_at_syn_clock_ns']['setup']:+.3f} ns, hold "
          f"{q['restored_slacks_at_syn_clock_ns']['hold']:+.3f} ns), and re-times only the clock "
          "(`flow/tcl/innovus_opclock_reports.tcl`).")
        w("")
        fp_pt = REPO / "build/flow/flexposit/fp_20261015b/sta_opclock/pt.log"
        fp = re.search(r"OPCLOCK_STA period=[0-9.]+ uncertainty=[0-9.]+ setup_wns=([-+0-9.eE]+) hold_wns=([-+0-9.eE]+)",
                       fp_pt.read_text()) if fp_pt.exists() else None
        fp_inv = {k: float(re.search(r"Slack Time\s*([-+0-9.]+)", (REPO / f"apr/build/TSMC22/FLEXPOSIT_CORE/"
                  f"fp_20261015b/reports/{k}.rpt").read_text())[1]) for k in ("setup", "hold")} if fp else None
        w("| at 2.5 ns, uncertainty 0.125 ns | setup WNS (ns) | hold WNS (ns) |")
        w("|---|---:|---:|")
        w(f"| BitMoD tile, Innovus (gate) | {q['op_worst_setup_excluding_latch_borrow_ns']:+.3f} "
          f"(latch-borrow checks 0) | {q['hold_wns_ns']:+.3f} |")
        w(f"| BitMoD tile, PrimeTime (not gating) | {pt['setup_wns_ns']:+.3f} | {pt['hold_wns_ns']:+.3f} |")
        if fp:
            w(f"| FlexPosit core fp_20261015b, Innovus (gate) | {fp_inv['setup']:+.3f} | {fp_inv['hold']:+.3f} |")
            w(f"| FlexPosit core fp_20261015b, PrimeTime (not gating) | {float(fp[1]):+.3f} | {float(fp[2]):+.3f} |")
        w("")
        w("PrimeTime reads the same netlist and SPEF with the synthesis SDC re-timed to 2.5 ns.  Its register-to-register "
          "slacks are lower than Innovus's by about the clock insertion delay: after CTS, CCOpt writes the I/O "
          "compensation as `set_clock_latency -source` (-0.27 ns here) for the -max condition only, and ASTRAEA times "
          "in OCV mode, where the setup capture clock and the hold launch clock take the unset -min value (0).  "
          "Innovus therefore shifts only one side of each register-to-register check, in the optimistic direction, "
          "on every ASTRAEA route alike, so the gate is applied to both designs the same way and PrimeTime is "
          "recorded beside it.  Both designs are within the 0.125 ns uncertainty in PrimeTime; the gate-level runs "
          "below use the routed SDF (real clock-tree delays, no uncertainty) and must be free of timing-check "
          "violations (gl-audit).")
        w("")
    if pw:
        w("## Power and energy (routed, PrimeTime PX)")
        w("")
        w("Full-timing max-SDF gate-level runs of the routed split tile at 400 MHz with the BitMoD power bench "
          "(uniform random FP16 activations and weights, 8-bit group scales, groups of 128 K-elements); the drained "
          "64-accumulator matrix of each run equals the RTL run of the original tile bit for bit.  The window holds "
          "every MAC cycle and closes at the first drain beat (drain excluded, as for BOS).  pJ/MAC = P x window x "
          "2.5 ns / useful MAC.")
        w("")
        w("| mode | MAC/cycle | power (mW) | pJ/MAC | window cycles | useful MAC |")
        w("|---|---:|---:|---:|---:|---:|")
        for m, r in results.items():
            w(f"| {r['mode']} | {float(r['mac_per_cycle']):.0f} | {float(r['power_mW']):.3f} | {float(r['pJ_MAC']):.4f} | "
              f"{int(r['window_cycles']):,} | {int(r['useful_mac']):,} |")
        w("")
        w("Energy per MAC by cell class (PrimeTime `report_power` groups; pJ/MAC and share), with the FlexPosit "
          "core route of the same flow for comparison (`build/flow/flexposit/fp_20261015b`, uniform random operands, "
          "whole tiles in the window):")
        w("")
        w("| design, mode | pJ/MAC | clock network | registers | combinational |")
        w("|---|---:|---:|---:|---:|")
        def group_row(name, pj, g):
            cells = " | ".join(f"{pj * g[k] / g['total']:.3f} ({100 * g[k] / g['total']:.0f}%)" for k in GROUPS)
            w(f"| {name} | {pj:.3f} | {cells} |")
        for m, r in results.items():
            group_row(f"BitMoD tile, {r['mode']}", float(r["pJ_MAC"]), parse_power_groups(work / f"power_m{m}/power.rpt"))
        fpd = REPO / "build/flow/flexposit/fp_20261015b"
        for p in (4, 8):
            if (fpd / f"power_p{p}/power.rpt").exists() and (fpd / f"result_p{p}.csv").exists():
                r = next(csv.DictReader((fpd / f"result_p{p}.csv").open()))
                group_row(f"FlexPosit core, P={p}", float(r["pJ_MAC"]), parse_power_groups(fpd / f"power_p{p}/power.rpt"))
        w("")
        w("Power by block (mW) and energy per MAC by block (pJ):")
        w("")
        hdr = " | ".join(f"{results[m]['mode']} mW | pJ/MAC" for m in pw)
        w("| block | " + hdr + " |")
        w("|---|" + "---:|---:|" * len(pw))
        def per_mac(m, v):
            r = results[m]
            return v * int(r["window_cycles"]) * PERIOD_NS / int(r["useful_mac"])
        for key, label, _ in PE_BLOCKS + [("pe_rest", "clock gates and glue", "")]:
            w(f"| PE: {label} | " + " | ".join(f"{pw[m][key]:.2f} | {per_mac(m, pw[m][key]):.4f}" for m in pw) + " |")
        w("| **PEs (64)** | " + " | ".join(f"**{pw[m]['pe_total']:.2f}** | **{per_mac(m, pw[m]['pe_total']):.4f}**" for m in pw) + " |")
        for key, label, _ in TILE_BLOCKS + [("tile_rest", "drain chain, glue, clock tree", "")]:
            w(f"| tile: {label} | " + " | ".join(f"{pw[m][key]:.2f} | {per_mac(m, pw[m][key]):.4f}" for m in pw) + " |")
        w("| **total** | " + " | ".join(f"**{pw[m]['total']:.2f}** | **{per_mac(m, pw[m]['total']):.4f}**" for m in pw) + " |")
        w("")
    w("## Caveats")
    w("")
    w("* The split adds module boundaries, which limit cross-boundary optimization; the flat-vs-split synthesis "
      "totals above measure that cost.  Shares are the point of this report, not absolute totals.")
    w("* The power route was synthesized and routed at a tighter clock than 2.5 ns (SYN_PERIOD in the campaign log) "
      "because the earlier BITMOD_TILE routes missed 2.5 ns and their gate-level runs went X on stage-1 setup "
      "violations.  It is simulated and measured at 400 MHz; the over-constraint upsizes cells, so its absolute "
      "area and power are somewhat above a design closed exactly at 2.5 ns.")
    w("* Tile only: the chip-level controller and skew network (1.3% of the 4x4-tile array's area in the "
      "collaborator's data) are outside this DUT.")
    w("* Uniform random operands, like every bench in this repo; real LLM weights and activations toggle less.")
    w("* The power bench relaunches the controller's operand data 2-state (X to 0): the controller's resetless term "
      "registers otherwise held X on ~9 idle beats inside the window (the tile ignores non-valid beats; X toggles are "
      "not activity).  X operands on a valid beat are fatal.  Control signals are unchanged.")
    w("* Routed GL approval: one -2 ps extracted INTERCONNECT value on a drain-row output-port wire, clamped to 0 "
      "(`--approve-negative-iopath-clamp-ps=2`; `build/flow/bitmod_hier/<campaign>/gl_validator_args_rationale.txt`).")
    w("")
    w("## Sources")
    w("")
    w(f"* `syn/build/TSMC22/BITMOD_TILE/{c}_flat/area.rpt`, `syn/build/TSMC22/BITMOD_TILE_H/{c}_p25/area.rpt`")
    w(f"* `apr/build/TSMC22/BITMOD_TILE_H/{c}/reports/area.rpt`, `build/flow/bitmod_hier/{c}/qualification.json`, "
      f"`build/flow/bitmod_hier/{c}/power_m*/power_hier.rpt`, "
      "`results.csv`")
    a.out.write_text("\n".join(L) + "\n")
    print(a.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
