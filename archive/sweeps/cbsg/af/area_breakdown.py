#!/usr/bin/env python3
"""Block-by-block post-synthesis area of the C-BSG AF array vs the CSA baseline.

Inputs, per design: the synthesis run directory (its hierarchical area.rpt,
report_area -hier -nosplit) and the DC probe report written by
sweeps/cbsg/af/dc_af_probe.tcl (AREA_CLASS lines: every leaf cell of
u_peripheral, and of the AF stream generator, put in exactly one class by name
and by fan-in cone).  The probe is needed because u_peripheral is flat in both
netlists apart from the AF encoders: the thermometer, the comparators and the
operand registers share one hierarchy level.

Rows (um2, TSMC22 sc7mcpp140z svt_c30, DC cell area, no wires):
  total                 the top
  PE core               u_pe (identical RTL in both designs)
    tiles               the 64 InnerTileSignedSegmentedCsa instances
    pipes + glue        u_pe minus the tiles: a_bits_pipe / w_bits_pipe / sign pipes, clock gates
  A edge                CSA: A registers + 1,024 A comparators + A Sobol bank (u_a_rng)
                        AF:  A + per-row L registers + 64 kA encoders + encoder input
                             buffering + thermometer decode
  W edge                W registers + 1,024 W comparators (same structure in both)
  W bank                CSA: u_w_rng (16 Sobol generators); AF: u_rng (CbsgAfStreamGen:
                        16 lane words + counter + phase + slice restart)
  other                 leftover u_peripheral cells (reset buffers), top-level cells and
                        top-level clock gates

  python3 sweeps/cbsg/af/area_breakdown.py --af <af_run_dir> --af-probe <probe.rpt> \
      --csa <csa_run_dir> --csa-probe <probe.rpt> [--json out.json]
"""
import argparse
import json
import re
import statistics
import sys
from pathlib import Path


def parse_area_rpt(path):
    """Return (total, {hier_name: (abs_total, comb, noncomb)}, top_name)."""
    text = Path(path).read_text()
    m = re.search(r"Total cell area:\s+([\d.]+)", text)
    if not m:
        sys.exit(f"{path}: no 'Total cell area'")
    total = float(m.group(1))
    rows = {}
    top = None
    in_table = False
    seen_header = False
    for line in text.splitlines():
        if not in_table:
            if line.startswith("Hierarchical cell"):
                seen_header = True
            elif seen_header and line.startswith("-----"):
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
    """AREA_CLASS / AREA_REG / AREA_TOTAL lines -> dicts."""
    cls, regs, tot, info = {}, {}, {}, []
    for line in Path(path).read_text().splitlines():
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
    if not cls:
        sys.exit(f"{path}: no AREA_CLASS lines (did the probe run?)")
    return cls, regs, tot, info


def top_children(rows, top):
    return {k: v for k, v in rows.items() if k != top and "/" not in k}


def breakdown(run_dir, probe, kind):
    total, rows, top = parse_area_rpt(Path(run_dir) / "area.rpt")
    cls, regs, tot, info = parse_probe(probe)
    a = lambda c: cls.get(c, (0, 0.0))[1]
    tiles = [v[0] for k, v in rows.items() if re.fullmatch(r"u_pe/u_array_core/g_row_\d+__g_col_\d+__u_inner", k)]
    if len(tiles) != 64:
        sys.exit(f"{run_dir}: expected 64 tiles, found {len(tiles)}")
    u_pe = rows["u_pe"][0]
    u_per = rows["u_peripheral"][0]
    if abs(tot["u_peripheral"][1] - u_per) > 0.05:
        sys.exit(f"{run_dir}: probe u_peripheral {tot['u_peripheral'][1]} != area.rpt {u_per}")
    per_cls = sum(v[1] for k, v in cls.items() if k in
                  ("ka_enc", "a_regs", "w_regs", "ka_in_buf", "a_logic", "w_logic", "p_other"))
    if abs(per_cls - u_per) > 0.05:
        sys.exit(f"{run_dir}: u_peripheral classes sum {per_cls:.3f} != {u_per:.3f}")
    kids = top_children(rows, top)
    local_top = rows[top][1] + rows[top][2]
    d = {"run": str(run_dir), "total": total, "u_pe": u_pe, "tiles": sum(tiles),
         "tile_mean": statistics.mean(tiles), "u_peripheral": u_per,
         "a_regs": a("a_regs"), "w_regs": a("w_regs"), "a_logic": a("a_logic"),
         "w_logic": a("w_logic"), "p_other": a("p_other"),
         "regs": {k: v[1] for k, v in regs.items()}, "info": info,
         "cells": {k: v[0] for k, v in cls.items()}}
    d["pe_pipes"] = u_pe - d["tiles"]
    named = {"u_pe", "u_peripheral"}
    if kind == "af":
        enc = [v[0] for k, v in rows.items() if re.fullmatch(r"u_peripheral/g_a_row_\d+__g_a_depth_\d+__u_ka", k)]
        if len(enc) != 64:
            sys.exit(f"{run_dir}: expected 64 kA encoder hierarchies, found {len(enc)}")
        if abs(sum(enc) - a("ka_enc")) > 0.05:
            sys.exit(f"{run_dir}: encoder hierarchy sum {sum(enc):.3f} != probe {a('ka_enc'):.3f}")
        by_lane = {}
        for k, v in rows.items():
            m = re.fullmatch(r"u_peripheral/g_a_row_\d+__g_a_depth_(\d+)__u_ka", k)
            if m:
                by_lane.setdefault(int(m.group(1)), []).append(v[0])
        d.update(ka_enc=sum(enc), ka_enc_mean=statistics.mean(enc), ka_enc_min=min(enc),
                 ka_enc_max=max(enc), ka_enc_lane_mean={k: statistics.mean(v) for k, v in sorted(by_lane.items())},
                 ka_in_buf=a("ka_in_buf"), therm=a("a_logic"),
                 a_bank=0.0, w_bank=rows["u_rng"][0],
                 rng_words=a("rng_words"), rng_ctrl=a("rng_ctrl"))
        d["a_edge"] = d["a_regs"] + d["ka_enc"] + d["ka_in_buf"] + d["therm"]
        named.add("u_rng")
    else:
        d.update(ka_enc=0.0, ka_in_buf=0.0, therm=0.0, a_cmp=a("a_logic"),
                 a_bank=rows["u_a_rng"][0], w_bank=rows["u_w_rng"][0])
        d["a_edge"] = d["a_regs"] + d["a_cmp"] + d["a_bank"]
        named |= {"u_a_rng", "u_w_rng"}
    d["w_cmp"] = d["w_logic"]
    d["w_edge"] = d["w_regs"] + d["w_cmp"]
    d["top_other"] = local_top + sum(v[0] for k, v in kids.items() if k not in named)
    d["other"] = d["p_other"] + d["top_other"]
    d["edge"] = total - u_pe
    check = d["u_pe"] + d["a_edge"] + d["w_edge"] + d["w_bank"] + d["other"]
    if abs(check - total) > 0.1:
        sys.exit(f"{run_dir}: rows sum {check:.3f} != total {total:.3f}")
    return d


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--af", required=True)
    ap.add_argument("--af-probe", required=True)
    ap.add_argument("--csa", required=True)
    ap.add_argument("--csa-probe", required=True)
    ap.add_argument("--json")
    args = ap.parse_args()
    af = breakdown(args.af, args.af_probe, "af")
    cs = breakdown(args.csa, args.csa_probe, "csa")

    rows = [
        ("total", "total", "total"),
        ("PE core (u_pe)", "u_pe", "u_pe"),
        ("  tiles (64 x InnerTileSignedSegmentedCsa)", "tiles", "tiles"),
        ("  bit/sign pipes + PE glue", "pe_pipes", "pe_pipes"),
        ("edge (total - PE core)", "edge", "edge"),
        ("A edge", "a_edge", "a_edge"),
        ("  A registers (mag + sign [+ row L])", "a_regs", "a_regs"),
        ("  A Sobol bank u_a_rng (CSA)", "a_bank", "a_bank"),
        ("  A comparators x1024 (CSA)", None, "a_cmp"),
        ("  kA encoders x64 (AF)", "ka_enc", None),
        ("  encoder input buffering (AF)", "ka_in_buf", None),
        ("  thermometer decoders x64 (AF)", "therm", None),
        ("W edge", "w_edge", "w_edge"),
        ("  W registers (mag + sign)", "w_regs", "w_regs"),
        ("  W comparators x1024", "w_cmp", "w_cmp"),
        ("W bank (CSA u_w_rng / AF u_rng)", "w_bank", "w_bank"),
        ("  AF u_rng: lane words (regs + logic)", "rng_words", None),
        ("  AF u_rng: counter + phase + restart", "rng_ctrl", None),
        ("other (reset buffers, top cells)", "other", "other"),
    ]
    out = []
    out.append(f"C-BSG AF vs CSA post-synthesis area (um2, DC cell area)")
    out.append(f"  AF : {af['run']}")
    out.append(f"  CSA: {cs['run']}")
    out.append(f"{'block':44s} {'CSA':>10s} {'AF':>10s} {'AF-CSA':>10s} {'AF/CSA':>7s}")
    for label, ka, kc in rows:
        va = af.get(ka) if ka else None
        vc = cs.get(kc) if kc else None
        fa = f"{va:10.1f}" if va is not None else f"{'-':>10s}"
        fc = f"{vc:10.1f}" if vc is not None else f"{'-':>10s}"
        if va is not None and vc is not None:
            dl = f"{va - vc:+10.1f}"
            rt = f"{va / vc:7.3f}" if vc else f"{'-':>7s}"
        else:
            dl, rt = f"{'':>10s}", f"{'':>7s}"
        out.append(f"{label:44s} {fc} {fa} {dl} {rt}")
    out.append("")
    out.append(f"AF total vs CSA: {af['total'] - cs['total']:+.1f} um2 ({100 * (af['total'] / cs['total'] - 1):+.2f}%)")
    out.append(f"AF A edge vs CSA A edge (incl. A bank): {af['a_edge'] - cs['a_edge']:+.1f} um2")
    out.append(f"kA encoder: {af['ka_enc_mean']:.1f} um2 mean, {af['ka_enc_min']:.1f}..{af['ka_enc_max']:.1f}; "
               "per lane mean " + ", ".join(f"k{k} {v:.1f}" for k, v in af["ka_enc_lane_mean"].items()))
    out.append(f"thermometer: {af['therm'] / 64:.2f} um2 per element (64 elements x 16 positions)")
    out.append(f"A comparators (CSA): {cs['a_cmp'] / 1024:.2f} um2 per comparator; "
               f"W comparators: CSA {cs['w_cmp'] / 1024:.2f}, AF {af['w_cmp'] / 1024:.2f} um2 per comparator")
    out.append(f"tile mean: CSA {cs['tile_mean']:.1f}, AF {af['tile_mean']:.1f} um2")
    out.append("registers (um2): " + "; ".join(
        f"{k} CSA {cs['regs'].get(k, 0):.1f} AF {af['regs'].get(k, 0):.1f}"
        for k in ("a_binary_q", "a_signs_q", "a_len_q", "w_binary_q", "w_signs_q"))
        + f"; AF words_q {af['regs'].get('words_q', 0):.1f}")
    out.append(f"leaf cells: CSA {cs['cells']}, AF {af['cells']}")
    print("\n".join(out))
    if args.json:
        Path(args.json).write_text(json.dumps({"af": af, "csa": cs}, indent=1, default=str) + "\n")


if __name__ == "__main__":
    main()
