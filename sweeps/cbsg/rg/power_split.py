#!/usr/bin/env python3
"""Power and area of the C-BSG RG array by functional block, from sweeps/cbsg/rg/pt_rg_power_split.tcl's dump.

The core's flattened leaf cells are classified exactly as sweeps/cbsg/rg/area_breakdown.py classifies them on the
synthesized netlist (its classify_rg, imported): W index generators (j registers, prefix -> j cone, row-shared
Gray / XOR map / mask logic), per-tile W comparators (cells in exactly one tile's w_bits cone), pipes, column-
shared W-magnitude logic, control fan-out, distribution and other.  Cells APR added (buffers, hold-fix delay
cells, resized copies keep their names) are classified by the same cone membership, so e.g. a hold buffer in front
of one tile's w_bits counts as that tile's comparator logic; their share is listed separately.

  python3 sweeps/cbsg/rg/power_split.py DUMP --flow-power POWER_RPT [--window W --blocks B] [--json OUT]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from area_breakdown import classify_rg  # noqa: E402

GROUPS = [
    ("W index generators", ("reg_gen_j", "gen_j", "gen_row")),
    ("per-tile W comparators", ("cmp_tile",)),
    ("pipes (a_bits, W magnitudes, signs, control)", ("reg_a_bits_pipe", "reg_w_mag_pipe", "reg_sign_pipes", "reg_control")),
    ("col_shared (W-magnitude side)", ("col_shared",)),
    ("global (control fan-out)", ("global",)),
    ("dist (other tile inputs)", ("dist",)),
    ("other core-local (clock tree, unconed)", ("other",)),
]


def parse(path: Path):
    d = dict(cells={}, hier={}, wcone={}, jcone={}, tcone=set(), pcells={}, phier={}, toph={}, total=None)
    for ln in path.read_text().splitlines():
        f = ln.split()
        if not f:
            continue
        t = f[0]
        if t == "TOTAL":
            d["total"] = tuple(float(x) for x in f[1:5])
        elif t == "CELL":
            d["cells"][f[1]] = dict(ref=f[2], area=float(f[3]), seq=f[4] == "1", p=float(f[5]), pi=float(f[6]),
                                    ps=float(f[7]), pl=float(f[8]))
        elif t == "HIER":
            d["hier"][f[1]] = dict(ref=f[2], area=float(f[3]), p=float(f[4]), n=int(f[5]))
        elif t == "PCELL":
            d["pcells"][f[1]] = dict(ref=f[2], area=float(f[3]), seq=f[4] == "1", p=float(f[5]))
        elif t == "PHIER":
            d["phier"][f[1]] = dict(area=float(f[2]), p=float(f[3]), n=int(f[4]))
        elif t == "TOPH":
            d["toph"][f[1]] = dict(area=float(f[2]), p=float(f[3]), n=int(f[4]))
        elif t == "WCONE":
            d["wcone"][(int(f[1]), int(f[2]))] = set(f[3:])
        elif t == "JCONE":
            d["jcone"][int(f[1])] = set(f[2:])
        elif t == "TCONE":
            d["tcone"] = set(f[1:])
    assert d["total"] and len(d["wcone"]) == 64 and len(d["jcone"]) == 8, "incomplete dump"
    return d


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump", type=Path)
    ap.add_argument("--flow-power", type=Path, help="the run's PT power.rpt (total must match)")
    ap.add_argument("--window", type=int, default=0, help="window clocks (for pJ)")
    ap.add_argument("--blocks", type=int, default=0)
    ap.add_argument("--label", default="")
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    d = parse(a.dump)
    mw = 1e3
    total = d["total"][0] * mw
    flow_total = None
    if a.flow_power:
        m = re.search(r"Total Power\s*=\s*([0-9.eE+-]+)", a.flow_power.read_text())
        flow_total = float(m[1]) * mw
        assert abs(flow_total - total) <= max(1e-3, 1e-4 * flow_total), \
            f"cell-sum total {total:.6f} mW != flow power.rpt {flow_total:.6f} mW"

    cells = d["cells"]
    area_cells = {n: (c["ref"], c["area"], c["seq"]) for n, c in cells.items()}
    pow_cells = {n: (c["ref"], c["p"], c["seq"]) for n, c in cells.items()}
    area, count, tile_cmp_a, row_gen_a = classify_rg(area_cells, d["wcone"], d["jcone"], d["tcone"])
    power, _, tile_cmp_p, row_gen_p = classify_rg(pow_cells, d["wcone"], d["jcone"], d["tcone"])
    # APR-added cells (Innovus names them FE_* / CTS_* / *_PHC*); their share per class
    added_a, added_p, added_n = defaultdict(float), defaultdict(float), defaultdict(int)
    one = {n: v for n, v in area_cells.items() if re.match(r"(FE_|CTS_|ccl_|PHC|HFS|RSZ|place)", n)}
    if one:
        a1, n1, _, _ = classify_rg(one, d["wcone"], d["jcone"], d["tcone"])
        p1, _, _, _ = classify_rg({n: pow_cells[n] for n in one}, d["wcone"], d["jcone"], d["tcone"])
        added_a.update(a1); added_p.update(p1); added_n.update(n1)

    tiles = {k: v for k, v in d["hier"].items() if k.endswith("__u_inner")}
    core_cg = {k: v for k, v in d["hier"].items() if k not in tiles}
    assert len(tiles) == 64, len(tiles)
    toph = d["toph"]
    per = toph.get("u_peripheral", dict(area=0, p=0, n=0))
    per_regs = sum(c["p"] for c in d["pcells"].values() if c["seq"])
    per_comb = sum(c["p"] for c in d["pcells"].values() if not c["seq"])
    per_cg = sum(v["p"] for v in d["phier"].values())
    per_regs_a = sum(c["area"] for c in d["pcells"].values() if c["seq"])
    per_comb_a = sum(c["area"] for c in d["pcells"].values() if not c["seq"])
    per_cg_a = sum(v["area"] for v in d["phier"].values())
    core_local_p = sum(c["p"] for c in cells.values())
    core_local_a = sum(c["area"] for c in cells.values())
    tiles_p = sum(v["p"] for v in tiles.values()); tiles_a = sum(v["area"] for v in tiles.values())
    cg_p = sum(v["p"] for v in core_cg.values()); cg_a = sum(v["area"] for v in core_cg.values())
    upe = toph["u_pe"]
    core_sum_p = core_local_p + tiles_p + cg_p
    upe_rest_p = upe["p"] - core_sum_p      # u_pe-local cells outside u_array_core (if any)
    upe_rest_a = upe["area"] - (core_local_a + tiles_a + cg_a)

    rows = []
    def row(name, p, ar, indent=0):
        rows.append(("  " * indent + name, p * mw, ar))
    row("TOTAL (sum of leaf cells)", d["total"][0], sum(v["area"] for v in toph.values()))
    for k in sorted(toph):
        row(f"{k}", toph[k]["p"], toph[k]["area"], 1)
        if k == "u_pe":
            row("CSA tiles (64)", tiles_p, tiles_a, 2)
            for gname, keys in GROUPS:
                row(gname, sum(power[x] for x in keys), sum(area[x] for x in keys), 2)
                if gname == "W index generators":
                    row("j registers", power["reg_gen_j"], area["reg_gen_j"], 3)
                    row("prefix -> j (gen_j cone)", power["gen_j"], area["gen_j"], 3)
                    row("row-shared Gray/XOR map/mask (gen_row)", power["gen_row"], area["gen_row"], 3)
            row("core clock gates", cg_p, cg_a, 2)
            row("u_pe outside u_array_core", upe_rest_p, upe_rest_a, 2)
        if k == "u_peripheral":
            row("operand registers (A mag/sign, L, W mag/sign)", per_regs, per_regs_a, 2)
            row("A comparators + t<L gate (comb)", per_comb, per_comb_a, 2)
            row("clock gates", per_cg, per_cg_a, 2)
    w = a.window; b = a.blocks
    print(f"C-BSG RG power/area by block {a.label}  (PT-PX cell sums; cones as sweeps/cbsg/rg/area_breakdown.py)")
    if flow_total is not None:
        print(f"  flow power.rpt total {flow_total:.6f} mW == cell sum {total:.6f} mW")
    hdr = f"  {'block':<58} {'mW':>10} {'%':>6} {'um2':>11}"
    if w and b:
        hdr += f" {'pJ/MAC':>8} {'nJ/block':>9}"
    print(hdr)
    for name, p, ar in rows:
        s = f"  {name:<58} {p:>10.4f} {100 * p / total:>6.1f} {ar:>11.1f}"
        if w and b:
            e = p * 1e-3 * w * 2.5e-9          # J over the window
            s += f" {e / (b * 512) * 1e12:>8.4f} {e / b * 1e9:>9.4f}"
        print(s)
    print(f"  per tile: CSA tile {tiles_p * mw / 64:.4f} mW, W comparators {power['cmp_tile'] * mw / 64:.4f} mW "
          f"(tiles min/max {min(tile_cmp_p.values()) * mw:.4f}/{max(tile_cmp_p.values()) * mw:.4f}); "
          f"W generators per row {sum(power[x] for x in GROUPS[0][1]) * mw / 8:.4f} mW")
    if one:
        print(f"  APR-added (FE_/CTS_...) core-local cells by class: "
              + ", ".join(f"{k} {added_n[k]} cells {added_p[k] * mw:.4f} mW {added_a[k]:.1f} um2" for k in sorted(added_n)))
    print(f"  cells per class: {dict(sorted(count.items()))}")
    if a.json:
        out = dict(label=a.label, total_mW=total, flow_total_mW=flow_total,
                   internal_mW=d["total"][1] * mw, switching_mW=d["total"][2] * mw, leakage_mW=d["total"][3] * mw,
                   top_children={k: dict(mW=v["p"] * mw, um2=v["area"], cells=v["n"]) for k, v in toph.items()},
                   tiles_mW=tiles_p * mw, tiles_um2=tiles_a, core_clock_gates_mW=cg_p * mw,
                   core_classes_mW={k: v * mw for k, v in power.items()}, core_classes_um2=dict(area),
                   core_class_cells=dict(count),
                   w_generators_mW=sum(power[x] for x in GROUPS[0][1]) * mw,
                   w_generators_um2=sum(area[x] for x in GROUPS[0][1]),
                   w_comparators_mW=power["cmp_tile"] * mw, w_comparators_um2=area["cmp_tile"],
                   peripheral=dict(regs_mW=per_regs * mw, comb_mW=per_comb * mw, cg_mW=per_cg * mw,
                                   regs_um2=per_regs_a, comb_um2=per_comb_a, cg_um2=per_cg_a),
                   apr_added=dict(cells=dict(added_n), mW={k: v * mw for k, v in added_p.items()}, um2=dict(added_a)),
                   window_clocks=w, blocks=b, rows=[dict(block=n.strip(), depth=(len(n) - len(n.lstrip())) // 2,
                                                         mW=p, um2=ar) for n, p, ar in rows])
        a.json.parent.mkdir(parents=True, exist_ok=True)
        json.dump(out, open(a.json, "w"), indent=1)
        print(f"  json: {a.json}")


if __name__ == "__main__":
    main()
