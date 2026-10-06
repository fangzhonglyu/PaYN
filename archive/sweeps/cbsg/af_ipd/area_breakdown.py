#!/usr/bin/env python3
"""Block-by-block post-synthesis area of the C-BSG AF + INT (IPD) array against AF, IPD and CSA.

Adapted from sweeps/cbsg/af/area_breakdown.py (unchanged).  Inputs, per design: the synthesis run directory
(hierarchical area.rpt) and the DC probe report of sweeps/cbsg/af_ipd/dc_af_ipd_probe.tcl, which puts every
leaf cell in exactly one class (AREA_CLASS lines; the same script for all four netlists).

Rows (um2, TSMC22 sc7mcpp140z svt_c30, DC cell area, no wires); main rows sum to the total:
  PE core (u_pe)       tiles | per-tile doubling muxes | lap select tree | bit/sign pipes + core clock gates |
                       core glue | PE wrapper (ring_q flop, shift_in | ring_q)
  A edge               A registers | A Sobol bank + 1,024 A comparators (CSA, IPD) | 64 kA encoders + input
                       buffering + 64 thermometers (AF, AF-IPD) | INT bypass gates + their select buffering
  W edge               W registers | 1,024 W comparators | INT bypass gates + select buffering
  bypass select, shared  int_mode buffering feeding both bit cones
  W bank               CSA / IPD u_w_rng; AF / AF-IPD u_rng (AF block clock)
  combiner             u_combiner
  top glue             top-level cells (INT tops: int_mode_q / int_mode_q2, MAC guard, ring gate, capture gate)
  other                leftover u_peripheral cells (reset buffers) + anything unclassed
Summary rows: edge = total - u_pe; mode / ring control = top glue + PE wrapper; INT additions.

  python3 sweeps/cbsg/af_ipd/area_breakdown.py --afipd D --afipd-probe P --af D --af-probe P \
      --ipd D --ipd-probe P --csa D --csa-probe P [--json out.json]
"""
import argparse
import json
import re
import statistics
import sys
from pathlib import Path


def parse_area_rpt(path):
    text = Path(path).read_text()
    m = re.search(r"Total cell area:\s+([\d.]+)", text)
    if not m:
        sys.exit(f"{path}: no 'Total cell area'")
    total = float(m.group(1))
    rows, top, in_table, seen = {}, None, False, False
    for line in text.splitlines():
        if not in_table:
            if line.startswith("Hierarchical cell"):
                seen = True
            elif seen and line.startswith("-----"):
                in_table = True
            continue
        f = line.split()
        if len(f) < 7:
            if f and f[0] == "Total":
                break
            continue
        try:
            vals = (float(f[1]), float(f[3]), float(f[4]))
        except ValueError:
            continue
        if top is None:
            top = f[0]
        rows[f[0]] = vals
    if top is None:
        sys.exit(f"{path}: no hierarchical table")
    return total, rows, top


def parse_probe(path):
    cls, regs, tot, info, refs = {}, {}, {}, [], {}
    for line in Path(path).read_text(errors="replace").splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "AREA_CLASS":
            cls[f[1]] = (int(f[2]), float(f[3]))
        elif f[0] == "AREA_REG":
            regs[f[1]] = (int(f[2]), float(f[3]))
        elif f[0] == "AREA_TOTAL":
            tot[f[1]] = (int(f[2]), float(f[3]))
        elif f[0] == "AREA_INFO":
            info.append(" ".join(f[1:]))
        elif f[0] == "AREA_REFS":
            refs[f[1]] = " ".join(f[2:])
    if not cls:
        sys.exit(f"{path}: no AREA_CLASS lines (did the probe run?)")
    return cls, regs, tot, info, refs


def breakdown(run_dir, probe, kind):
    total, rows, top = parse_area_rpt(Path(run_dir) / "area.rpt")
    cls, regs, tot, info, refs = parse_probe(probe)
    a = lambda c: cls.get(c, (0, 0.0))[1]
    n = lambda c: cls.get(c, (0, 0.0))[0]
    tiles = [v[0] for k, v in rows.items() if re.fullmatch(r"u_pe/u_array_core/g_row_\d+__g_col_\d+__u_inner", k)]
    if len(tiles) != 64:
        sys.exit(f"{run_dir}: expected 64 tiles, found {len(tiles)}")
    d = {"run": str(run_dir), "kind": kind, "total": total, "refs": refs, "info": info,
         "regs": {k: v[1] for k, v in regs.items()}, "cells": {k: v[0] for k, v in cls.items()}}
    # cross-checks against the hierarchical area report
    if abs(tot["design"][1] - total) > 0.1:
        sys.exit(f"{run_dir}: probe design total {tot['design'][1]:.3f} != area.rpt {total:.3f}")
    for h in ("u_pe", "u_peripheral"):
        if abs(tot[h][1] - rows[h][0]) > 0.05:
            sys.exit(f"{run_dir}: probe {h} {tot[h][1]:.3f} != area.rpt {rows[h][0]:.3f}")
    if abs(a("tiles") - sum(tiles)) > 0.05:
        sys.exit(f"{run_dir}: tile class {a('tiles'):.3f} != area.rpt tiles {sum(tiles):.3f}")
    if n("unclassed"):
        sys.exit(f"{run_dir}: {n('unclassed')} unclassed leaf cells")
    per = ("ka_enc", "a_regs", "w_regs", "ka_in_buf", "byp_a", "byp_w", "sel_a", "sel_w", "sel_both",
           "a_logic", "w_logic", "p_other")
    if abs(sum(a(c) for c in per) - rows["u_peripheral"][0]) > 0.05:
        sys.exit(f"{run_dir}: u_peripheral classes do not sum to its area")
    pe = ("tiles", "core_seq", "dbl_mux", "dbl_sel", "core_glue", "pe_local")
    if abs(sum(a(c) for c in pe) - rows["u_pe"][0]) > 0.05:
        sys.exit(f"{run_dir}: u_pe classes do not sum to its area")
    for c in per + pe + ("rng", "rng_a", "rng_w", "rng_words", "rng_ctrl", "combiner", "top_glue"):
        d[c] = a(c)
    d["tile_mean"] = statistics.mean(tiles)
    d["u_pe"] = rows["u_pe"][0]
    d["u_peripheral"] = rows["u_peripheral"][0]
    if kind in ("af", "afipd"):
        enc = [v[0] for k, v in rows.items() if re.fullmatch(r"u_peripheral/g_a_row_\d+__g_a_depth_\d+__u_ka", k)]
        if len(enc) != 64 or abs(sum(enc) - a("ka_enc")) > 0.05:
            sys.exit(f"{run_dir}: encoder hierarchies {len(enc)} / {sum(enc):.3f} vs probe {a('ka_enc'):.3f}")
        d.update(ka_enc_mean=statistics.mean(enc), ka_enc_min=min(enc), ka_enc_max=max(enc),
                 therm=a("a_logic"), a_cmp=None, a_bank=None, w_bank=a("rng"))
    else:
        d.update(therm=None, a_cmp=a("a_logic"), a_bank=a("rng_a"), w_bank=a("rng_w"))
    d["byp_a_all"] = a("byp_a") + a("sel_a")
    d["byp_w_all"] = a("byp_w") + a("sel_w")
    d["a_edge"] = (a("a_regs") + a("ka_enc") + a("ka_in_buf") + a("a_logic") + (d["a_bank"] or 0.0)
                   + d["byp_a_all"])
    d["w_edge"] = a("w_regs") + a("w_logic") + d["byp_w_all"]
    d["other"] = a("p_other")
    d["edge"] = total - d["u_pe"]
    d["mode_ring"] = a("top_glue") + a("pe_local")
    d["dbl_all"] = a("dbl_mux") + a("dbl_sel")
    d["int_add"] = d["byp_a_all"] + d["byp_w_all"] + a("sel_both") + a("combiner") + d["mode_ring"] + d["dbl_all"]
    check = (d["u_pe"] + d["a_edge"] + d["w_edge"] + a("sel_both") + d["w_bank"] + a("combiner")
             + a("top_glue") + d["other"])
    if abs(check - total) > 0.1:
        sys.exit(f"{run_dir}: rows sum {check:.3f} != total {total:.3f}")
    return d


ROWS = [
    ("total", "total"),
    ("PE core (u_pe)", "u_pe"),
    ("  tiles (64 x InnerTileSignedSegmentedCsa)", "tiles"),
    ("  per-tile doubling muxes (acc_in = lap ? own<<1 : west)", "dbl_mux"),
    ("  lap select tree (ring_q -> 1,536 mux selects)", "dbl_sel"),
    ("  bit/sign pipes + core clock gates", "core_seq"),
    ("  core glue", "core_glue"),
    ("  PE wrapper (ring_q flop, shift_in | ring_q)", "pe_local"),
    ("edge (total - PE core)", "edge"),
    ("A edge", "a_edge"),
    ("  A registers (mag + sign [+ row L])", "a_regs"),
    ("  A Sobol bank u_a_rng (CSA, IPD)", "a_bank"),
    ("  A comparators x1024 (CSA, IPD)", "a_cmp"),
    ("  kA encoders x64 (AF)", "ka_enc"),
    ("  encoder input buffering (AF)", "ka_in_buf"),
    ("  thermometer decoders x64 (AF)", "therm"),
    ("  INT bypass, A: 1,024 gates (raw & int_mode | sc)", "byp_a"),
    ("  INT bypass, A: select buffering", "sel_a"),
    ("W edge", "w_edge"),
    ("  W registers (mag + sign)", "w_regs"),
    ("  W comparators x1024", "w_logic"),
    ("  INT bypass, W: 1,024 gates", "byp_w"),
    ("  INT bypass, W: select buffering", "sel_w"),
    ("INT bypass select buffering, shared A/W", "sel_both"),
    ("W bank (CSA/IPD u_w_rng; AF u_rng block clock)", "w_bank"),
    ("  AF u_rng: lane words (regs + logic)", "rng_words"),
    ("  AF u_rng: counter + phase + restart", "rng_ctrl"),
    ("combiner (u_combiner)", "combiner"),
    ("top glue (mode regs, MAC guard, ring/capture gates)", "top_glue"),
    ("other (u_peripheral leftovers: reset buffers)", "other"),
    ("-- summary", None),
    ("mode / ring control (top glue + PE wrapper)", "mode_ring"),
    ("doubling muxes + lap select tree", "dbl_all"),
    ("INT bypass, A (gates + select)", "byp_a_all"),
    ("INT bypass, W (gates + select)", "byp_w_all"),
    ("INT additions (bypass + select + doubling + combiner + control)", "int_add"),
]
INT_ONLY = {"dbl_mux", "dbl_sel", "pe_local", "byp_a", "sel_a", "byp_w", "sel_w", "sel_both", "combiner",
            "byp_a_all", "byp_w_all", "dbl_all", "int_add", "mode_ring"}


def fmt(x):
    return f"{x:10.1f}" if isinstance(x, (int, float)) else f"{'-':>10s}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for k in ("afipd", "af", "ipd", "csa"):
        ap.add_argument(f"--{k}", required=True)
        ap.add_argument(f"--{k}-probe", required=True)
    ap.add_argument("--json")
    args = ap.parse_args()
    D = {k: breakdown(getattr(args, k), getattr(args, f"{k}_probe"), k) for k in ("csa", "af", "ipd", "afipd")}
    cs, af, ip, ai = D["csa"], D["af"], D["ipd"], D["afipd"]
    out = ["C-BSG AF + INT (IPD) post-synthesis area (um2, DC cell area, one probe for all four netlists)"]
    for k, lab in (("afipd", "AF-IPD"), ("af", "AF"), ("ipd", "IPD"), ("csa", "CSA")):
        out.append(f"  {lab:6s} {D[k]['run']}")
    hdr = (f"{'block':62s} {'CSA':>10s} {'AF':>10s} {'IPD':>10s} {'AF-IPD':>10s} {'AFIPD-AF':>10s} "
           f"{'AFIPD-CSA':>10s} {'IPD-CSA':>10s}")
    out.append(hdr)
    for label, key in ROWS:
        if key is None:
            out.append(label)
            continue
        v = [D[k].get(key) for k in ("csa", "af", "ipd", "afipd")]
        dl = lambda x, y: f"{x - y:+10.1f}" if isinstance(x, (int, float)) and isinstance(y, (int, float)) else f"{'':>10s}"
        out.append(f"{label[:62]:62s} {fmt(v[0])} {fmt(v[1])} {fmt(v[2])} {fmt(v[3])} {dl(v[3], v[1])} "
                   f"{dl(v[3], v[0])} {dl(v[2], v[0])}")
    out.append("")
    out.append(f"AF-IPD total vs AF : {ai['total'] - af['total']:+.1f} um2 ({100 * (ai['total'] / af['total'] - 1):+.2f}%)")
    out.append(f"AF-IPD total vs CSA: {ai['total'] - cs['total']:+.1f} um2 ({100 * (ai['total'] / cs['total'] - 1):+.2f}%)")
    out.append(f"AF-IPD total vs IPD: {ai['total'] - ip['total']:+.1f} um2 ({100 * (ai['total'] / ip['total'] - 1):+.2f}%)")
    out.append(f"INT cost on the AF edge (AF-IPD - AF) {ai['total'] - af['total']:+.1f} vs on the Sobol edge (IPD - CSA) "
               f"{ip['total'] - cs['total']:+.1f}; additivity estimate AF + (IPD - CSA) = "
               f"{af['total'] + ip['total'] - cs['total']:.1f}, measured {ai['total']:.1f} "
               f"({ai['total'] - (af['total'] + ip['total'] - cs['total']):+.1f})")
    out.append(f"A thermometer + A bypass (gates + select): AF-IPD {ai['therm'] + ai['byp_a_all']:.1f} vs AF thermometer "
               f"{af['therm']:.1f} ({ai['therm'] + ai['byp_a_all'] - af['therm']:+.1f}); "
               f"W comparators + W bypass: AF-IPD {ai['w_logic'] + ai['byp_w_all']:.1f} vs AF comparators "
               f"{af['w_logic']:.1f} ({ai['w_logic'] + ai['byp_w_all'] - af['w_logic']:+.1f})")
    out.append(f"bypass per bit (gates only): A {ai['byp_a'] / 1024:.3f}, W {ai['byp_w'] / 1024:.3f} um2; "
               f"IPD (BP peripheral) A {ip['byp_a'] / 1024:.3f}, W {ip['byp_w'] / 1024:.3f} um2")
    out.append(f"doubling mux per bit (1,536 tile acc_in bits): AF-IPD {ai['dbl_mux'] / 1536:.3f} (+select "
               f"{ai['dbl_all'] / 1536:.3f}), IPD {ip['dbl_mux'] / 1536:.3f} (+select {ip['dbl_all'] / 1536:.3f}) um2")
    out.append(f"kA encoder: AF-IPD {ai['ka_enc_mean']:.1f} um2 mean ({ai['ka_enc_min']:.1f}..{ai['ka_enc_max']:.1f}), "
               f"AF {af['ka_enc_mean']:.1f}; thermometer per element: AF-IPD {ai['therm'] / 64:.2f}, AF {af['therm'] / 64:.2f}")
    out.append(f"W comparator: AF-IPD {ai['w_logic'] / 1024:.2f}, AF {af['w_logic'] / 1024:.2f}, CSA {cs['w_logic'] / 1024:.2f}, "
               f"IPD {ip['w_logic'] / 1024:.2f} um2 each")
    out.append(f"tile mean: CSA {cs['tile_mean']:.1f}, AF {af['tile_mean']:.1f}, IPD {ip['tile_mean']:.1f}, AF-IPD {ai['tile_mean']:.1f} um2")
    out.append("registers (um2): " + "; ".join(
        f"{k} AF {af['regs'].get(k, 0):.1f} AF-IPD {ai['regs'].get(k, 0):.1f}"
        for k in ("a_binary_q", "a_signs_q", "a_len_q", "w_binary_q", "w_signs_q", "bit_sign_pipes")))
    out.append("cell mix (AF-IPD):")
    for c in ("byp_a", "byp_w", "sel_a", "sel_w", "sel_both", "dbl_mux", "dbl_sel", "core_glue", "pe_local",
              "top_glue", "a_logic", "w_logic"):
        out.append(f"  {c:10s} {ai['cells'].get(c, 0):6d} cells {ai.get(c, 0.0):9.1f} um2:{ai['refs'].get(c, '')}")
    out.append("cell mix (AF): " + "; ".join(f"{c} {af['cells'].get(c, 0)} cells{af['refs'].get(c, '')}"
                                             for c in ("a_logic", "w_logic", "core_glue", "top_glue")))
    out.append("cell mix (IPD): " + "; ".join(f"{c} {ip['cells'].get(c, 0)} cells{ip['refs'].get(c, '')}"
                                              for c in ("byp_a", "byp_w", "sel_both", "dbl_mux", "dbl_sel", "pe_local", "top_glue")))
    out.append(f"leaf cells per class: CSA {cs['cells']}")
    out.append(f"                      AF  {af['cells']}")
    out.append(f"                      IPD {ip['cells']}")
    out.append(f"                   AF-IPD {ai['cells']}")
    print("\n".join(out))
    if args.json:
        Path(args.json).write_text(json.dumps(D, indent=1, default=str) + "\n")


if __name__ == "__main__":
    main()
