#!/usr/bin/env python3
"""Area by block of the C-BSG RG array (TSMC22/PAYN_SC_CSA_CBSG_RG) against the carry-save baseline (PAYN_SC_CSA).

Sources (all from the synthesis runs; nothing is re-synthesized):
  * <run>/area.rpt         DC `report_area -hierarchy` of both runs: total, A/W banks, edge, PE core, tiles, the core's
                           local (non-tile) cells and clock-gate wrappers.
  * rg_area_cones.txt      DC fan-in cones on the RG netlist (sweeps/cbsg/rg/dc_rg_area_cones.tcl), used to split
                           the RG core's ~100k flattened U* cells, which carry no RTL names:
       gen_j      in the fan-in of row h's j registers (prefix chain -> j): W index generator
       gen_row    in the w_bits cones of >1 tile, all in one row h: W index generator (Gray / k-direction XOR
                  map / mask, plus any threshold-side logic DC shares across the row's 8 tiles)
       cmp_tile   in the w_bits cone of exactly one tile: that tile's W comparators (w_mag > thr)
       col_shared in the w_bits cones of tiles of one column only (>1 row): W-magnitude-side logic/buffers
       global     in w_bits cones spanning rows and columns: control fan-out (first/phase/valid buffers)
       dist       only in the cones of the other tile inputs (a_bits, signs, mac_en, shift_in, reset, acc_in)
       other      none of the above
    Registers are split by name (a_bits_pipe, w_bits_pipe = W magnitudes, sign pipes, j, control).
The split is by netlist structure, so it is exact for what DC built; "W comparator" and "W generator" mean the
cells only one tile uses vs the cells a row's tiles share.

  python3 sweeps/cbsg/rg/area_breakdown.py                 # runs DC for the cone dump if it is missing
  python3 sweeps/cbsg/rg/area_breakdown.py --json build/cbsg/rg/area/area_breakdown.json
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
N_H = N_W = 8
K = 8
M = 16
F_MHZ = 400.0
T = 128


def parse_hier(area_rpt: Path) -> dict:
    """{cell: (total, local_comb, local_noncomb, design)} plus '__top__' totals from report_area -hierarchy."""
    text = area_rpt.read_text(errors="replace")
    out = {}
    top = {}
    for key, pat in (("comb", r"Combinational area:\s+([\d.]+)"), ("noncomb", r"Noncombinational area:\s+([\d.]+)"),
                     ("total", r"Total cell area:\s+([\d.]+)"), ("bufinv", r"Buf/Inv area:\s+([\d.]+)")):
        top[key] = float(re.search(pat, text)[1])
    sec = text.split("Hierarchical area distribution", 1)[1]
    lines = sec.splitlines()
    i = 0
    num = r"([\d.]+)"
    row = re.compile(rf"^(\S+)\s+{num}\s+{num}\s+{num}\s+{num}\s+{num}\s+(\S+)\s*$")
    rest = re.compile(rf"^\s+{num}\s+{num}\s+{num}\s+{num}\s+{num}\s+(\S+)\s*$")
    while i < len(lines):
        ln = lines[i]
        m = row.match(ln)
        if m:
            out[m[1]] = (float(m[2]), float(m[4]), float(m[5]), m[7])
        elif re.match(r"^\S+\s*$", ln) and i + 1 < len(lines) and rest.match(lines[i + 1]):
            m2 = rest.match(lines[i + 1])        # long name wrapped onto its own line
            out[ln.strip()] = (float(m2[1]), float(m2[3]), float(m2[4]), m2[6])
            i += 1
        i += 1
    out["__top__"] = top
    return out


def hier_blocks(h: dict, top: str) -> dict:
    """Block areas from the hierarchy (both designs)."""
    core = next(k for k, v in h.items() if k.endswith("u_pe/u_array_core"))
    tiles = {k: v for k, v in h.items() if re.fullmatch(re.escape(core) + r"/g_row_\d+__g_col_\d+__u_inner", k)}
    core_cg = {k: v for k, v in h.items() if k.startswith(core + "/clk_gate_") and k.count("/") == core.count("/") + 1}
    per = {k: v for k, v in h.items() if k.startswith("u_peripheral")}
    b = {
        "total": h["__top__"]["total"],
        "top_local": h[top][1] + h[top][2] + sum(v[0] for k, v in h.items() if "/" not in k and k.startswith("clk_gate_")),
        "a_bank": h.get("u_a_rng", (0.0,))[0],
        "w_bank": h.get("u_w_rng", (0.0,))[0],
        "edge": h["u_peripheral"][0],
        "edge_comb": h["u_peripheral"][1],
        "edge_regs": h["u_peripheral"][2],
        "edge_cg": sum(v[0] for k, v in per.items() if "/clk_gate_" in k and k.count("/") == 1),
        "pe": h["u_pe"][0],
        "tiles": sum(v[0] for v in tiles.values()),
        "n_tiles": len(tiles),
        "tile_min": min(v[0] for v in tiles.values()),
        "tile_max": max(v[0] for v in tiles.values()),
        "core_local_comb": h[core][1],
        "core_local_regs": h[core][2],
        "core_cg": sum(v[0] for v in core_cg.values()),
    }
    # edge comb outside its clock gates (the clock-gate wrappers are children, not local)
    return b


def run_dc(run_dir: Path, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = f"""
set -e
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
export ASTRAEA_FLOW=${{ASTRAEA_FLOW:-{REPO.parent / 'ASTRAEA'}}} DESIGN_ROOT={REPO} SNPSLMD_QUEUE=true
set -a; . {run_dir}/TARGET_DEF; set +a
export RG_RUN_DIR={run_dir}
cd {out_dir}
dc_shell -f {REPO}/sweeps/cbsg/rg/dc_rg_area_cones.tcl > dc_rg_area_cones.log 2>&1
grep -q RG_AREA_DONE dc_rg_area_cones.log
"""
    subprocess.run(["bash", "-c", cmd], check=True)


def parse_cones(path: Path):
    cells, hier, wcone, jcone, tcone = {}, {}, {}, {}, set()
    for ln in path.read_text().splitlines():
        f = ln.split()
        if not f:
            continue
        if f[0] == "CELL":
            cells[f[1]] = (f[2], float(f[3]), f[4] == "1")
        elif f[0] == "HIER":
            hier[f[1]] = (f[2], float(f[3]))
        elif f[0] == "WCONE":
            wcone[(int(f[1]), int(f[2]))] = set(f[3:])
        elif f[0] == "JCONE":
            jcone[int(f[1])] = set(f[2:])
        elif f[0] == "TCONE":
            tcone = set(f[1:])
    assert len(wcone) == N_H * N_W and len(jcone) == N_H, "incomplete cone dump"
    return cells, hier, wcone, jcone, tcone


def classify_rg(cells, wcone, jcone, tcone):
    member = defaultdict(set)
    for hv, s in wcone.items():
        for c in s:
            member[c].add(hv)
    jrow = defaultdict(set)
    for h, s in jcone.items():
        for c in s:
            jrow[c].add(h)
    area = defaultdict(float)
    count = defaultdict(int)
    per_tile_cmp = defaultdict(float)
    per_row_gen = defaultdict(float)
    for name, (ref, a, seq) in cells.items():
        if seq:
            if "a_bits_pipe_reg" in name:
                k = "reg_a_bits_pipe"
            elif "w_bits_pipe_reg" in name:
                k = "reg_w_mag_pipe"
            elif "signs_pipe_reg" in name:
                k = "reg_sign_pipes"
            elif re.match(r"g_gen_row_\d+__g_gen_lane_\d+__j_reg", name):
                k = "reg_gen_j"
                per_row_gen[int(re.match(r"g_gen_row_(\d+)", name)[1])] += a
            else:
                k = "reg_control"
        else:
            tiles = member.get(name, set())
            rows = {h for h, _ in tiles}
            cols = {v for _, v in tiles}
            if name in jrow:
                k = "gen_j"
                if len(jrow[name]) == 1:
                    per_row_gen[next(iter(jrow[name]))] += a
            elif len(tiles) == 1:
                k = "cmp_tile"
                per_tile_cmp[next(iter(tiles))] += a
            elif tiles and len(rows) == 1:
                k = "gen_row"
                per_row_gen[next(iter(rows))] += a
            elif tiles and len(cols) == 1:
                k = "col_shared"
            elif tiles:
                k = "global"
            elif name in tcone:
                k = "dist"
            else:
                k = "other"
        area[k] += a
        count[k] += 1
    return area, count, per_tile_cmp, per_row_gen


def fmt(x):
    return f"{x:,.1f}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rg-run", type=Path, default=REPO / "syn/build/TSMC22/PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005")
    ap.add_argument("--csa-run", type=Path, default=REPO / "syn/build/TSMC22/PAYN_SC_CSA/csa_20261002")
    ap.add_argument("--cones", type=Path, default=None,
                    help="cone dump (default build/cbsg/rg/area/<run>/rg_area_cones.txt; DC runs if missing)")
    ap.add_argument("--json", type=Path, default=None)
    args = ap.parse_args()

    rg_h = parse_hier(args.rg_run / "area.rpt")
    csa_h = parse_hier(args.csa_run / "area.rpt")
    rg = hier_blocks(rg_h, "payn_array_signed_segmented_csa_cbsg_rg")
    csa = hier_blocks(csa_h, "payn_array_signed_segmented_csa")

    cone_dir = REPO / "build/cbsg/rg/area" / args.rg_run.name
    cones = args.cones or cone_dir / "rg_area_cones.txt"
    if not cones.exists():
        print(f"[area] running DC for the cone dump -> {cones.relative_to(REPO)}", file=sys.stderr)
        run_dc(args.rg_run, cone_dir)
    cells, hier, wcone, jcone, tcone = parse_cones(cones)
    area, count, per_tile_cmp, per_row_gen = classify_rg(cells, wcone, jcone, tcone)

    # Cross-check: the cone dump's core-local cells must add up to report_area's core local area.
    dump_comb = sum(a for _, a, s in cells.values() if not s)
    dump_seq = sum(a for _, a, s in cells.values() if s)
    assert abs(dump_comb - rg["core_local_comb"]) < 0.5, (dump_comb, rg["core_local_comb"])
    assert abs(dump_seq - rg["core_local_regs"]) < 0.5, (dump_seq, rg["core_local_regs"])

    gen = area["gen_j"] + area["gen_row"] + area["reg_gen_j"]
    cmp_ = area["cmp_tile"]
    pipes_rg = area["reg_a_bits_pipe"] + area["reg_w_mag_pipe"] + area["reg_sign_pipes"] + area["reg_control"]
    other_rg = area["col_shared"] + area["global"] + area["dist"] + area["other"] + rg["core_cg"]
    pipes_csa = csa["core_local_regs"]
    other_csa = csa["core_local_comb"] + csa["core_cg"]

    rows = [
        ("Total (cell area)", csa["total"], rg["total"]),
        ("A bank (u_a_rng)", csa["a_bank"], rg["a_bank"]),
        ("W bank (u_w_rng)", csa["w_bank"], rg["w_bank"]),
        ("Edge (u_peripheral)", csa["edge"], rg["edge"]),
        ("  operand registers (A, W, signs; RG adds L)", csa["edge_regs"], rg["edge_regs"]),
        ("  comparators (CSA: A+W; RG: A only) + length gate", csa["edge_comb"], rg["edge_comb"]),
        ("  clock gates", csa["edge_cg"], rg["edge_cg"]),
        ("Top-level control (phase, ICGs)", csa["top_local"], rg["top_local"]),
        ("PE core (u_pe)", csa["pe"], rg["pe"]),
        ("  CSA tiles (64, unchanged RTL)", csa["tiles"], rg["tiles"]),
        ("  W index generators (64 = row h x lane k)", 0.0, gen),
        ("    j registers (8 b each)", 0.0, area["reg_gen_j"]),
        ("    prefix chain -> j (gen_j cone)", 0.0, area["gen_j"]),
        ("    row-shared map / threshold logic (gen_row)", 0.0, area["gen_row"]),
        ("  per-tile W comparators (8,192 = 64 tiles x 128)", 0.0, cmp_),
        ("  pipes: a_bits / W (CSA bits, RG magnitudes) / signs / ctrl", pipes_csa, pipes_rg),
        ("    a_bits_pipe", None, area["reg_a_bits_pipe"]),
        ("    w_bits_pipe (RG: 8-b magnitudes)", None, area["reg_w_mag_pipe"]),
        ("    sign pipes", None, area["reg_sign_pipes"]),
        ("    control (first/valid/phase/load)", None, area["reg_control"]),
        ("  other core logic (buffers, col-shared, ICGs)", other_csa, other_rg),
        ("    col_shared (W-magnitude side)", None, area["col_shared"]),
        ("    global (control fan-out)", None, area["global"]),
        ("    dist (other tile inputs)", None, area["dist"]),
        ("    other", None, area["other"]),
        ("    core clock gates", csa["core_cg"], rg["core_cg"]),
    ]
    print(f"C-BSG RG area by block vs CSA baseline (um2, TSMC22, zero wire load)")
    print(f"  RG : {args.rg_run.relative_to(REPO)}")
    print(f"  CSA: {args.csa_run.relative_to(REPO)}")
    print(f"  {'block':<62} {'CSA':>10} {'RG':>10} {'RG-CSA':>10}")
    for name, c, r in rows:
        cs = fmt(c) if c is not None else "-"
        ds = fmt(r - c) if c is not None else ""
        print(f"  {name:<62} {cs:>10} {fmt(r):>10} {ds:>10}")
    tile_csa = csa["tiles"] / csa["n_tiles"]
    tile_rg = rg["tiles"] / rg["n_tiles"]
    tc = sorted(per_tile_cmp.values())
    rgv = sorted(per_row_gen.values())
    print()
    print(f"  per tile: CSA {tile_csa:.1f}, RG {tile_rg:.1f} (min {rg['tile_min']:.1f}, max {rg['tile_max']:.1f})")
    print(f"  per-tile W comparators: {cmp_ / 64:.1f} um2/tile (min {tc[0]:.1f}, max {tc[-1]:.1f}), "
          f"{cmp_ / (64 * K * M):.2f} um2 per comparator; {count['cmp_tile']} cells")
    print(f"  W index generators: {gen / 64:.1f} um2 per (h, k) generator, {gen / 8:.1f} per row "
          f"(rows min {rgv[0]:.1f}, max {rgv[-1]:.1f}); {count['gen_j'] + count['gen_row'] + count['reg_gen_j']} cells")
    print(f"  CSA edge comparators: {csa['edge_comb'] / (2 * N_H * K * M):.2f} um2 per comparator (2,048, incl. misc); "
          f"RG A edge {rg['edge_comb'] / (N_H * K * M):.2f} um2 per comparator (1,024 + 128 length gates; "
          f"sample-ordered thresholds share their low bits)")
    gmac = N_H * N_W * K * F_MHZ * 1e6 / (T / M) / 1e9      # MACs per second at L = T = 128
    print(f"  GMAC/s/mm2 at {F_MHZ:.0f} MHz, T = {T} ({gmac:.1f} GMAC/s): CSA {gmac / (csa['total'] * 1e-6):.0f}, "
          f"RG {gmac / (rg['total'] * 1e-6):.0f} (RG/CSA area {rg['total'] / csa['total']:.3f}x)")
    print(f"  cone-dump cross-check: core-local comb {dump_comb:.1f} / regs {dump_seq:.1f} um2 = report_area "
          f"{rg['core_local_comb']:.1f} / {rg['core_local_regs']:.1f}")
    print(f"  cells per class: {dict(sorted(count.items()))}")
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        json.dump({"rg_run": str(args.rg_run), "csa_run": str(args.csa_run), "csa": csa, "rg": rg,
                   "rg_core_classes_um2": dict(area), "rg_core_class_cells": dict(count),
                   "rg_w_generators_um2": gen, "rg_w_comparators_um2": cmp_,
                   "rg_per_tile_cmp_um2": {f"{h},{v}": a for (h, v), a in per_tile_cmp.items()},
                   "rg_per_row_gen_um2": dict(per_row_gen),
                   "gmacs_per_mm2": {"csa": gmac / (csa["total"] * 1e-6), "rg": gmac / (rg["total"] * 1e-6)}},
                  open(args.json, "w"), indent=1)
        print(f"  json: {args.json}")


if __name__ == "__main__":
    main()
