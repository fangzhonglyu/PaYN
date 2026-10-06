#!/usr/bin/env python3
"""Block-period table of the BP-space (T2) RTL runs (run_bp_space_checks.sh).

Reads every passing nominal-schedule check.json under OUT/p1 and OUT/grid and
prints, per (shape, precision, S, L): the scheduled block period (feasible:
the run is bit-exact), the drain-start spacing measured in the trace
(multi-block runs), the model's T2 period (sweeps/int_mode/bp/model_lap_schedules.py
block_terms) and whether they agree, outputs per PE, MAC per tile-cycle and %
of peak (peak = 128/(BA*BW) MAC per tile per data edge), and, for reference,
the model's T1 (as-built, per-PE laps) period and % of peak at the same point
plus the edges each schedule spends per 8 outputs per PE.  Then the one-edge-
short tightness controls by shape and the negative controls.

Writes OUT/periods.json; prints the table.  Exit status 1 if any measured
period differs from the model's T2 period.

Usage:  bp_space_periods.py OUT_DIR
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model_lap_schedules as m  # noqa: E402

SHAPE_ORDER = {"1x1": 0, "2x2": 1, "4x4": 2, "4x8": 3}


def main() -> int:
    out = Path(sys.argv[1])
    rows, negs = {}, []
    for p in sorted(list((out / "p1").glob("*/check.json")) + list((out / "grid").glob("*/check.json"))):
        d = json.loads(p.read_text())
        name = p.parent.name
        if d["mode"] != "nominal":
            negs.append((d["kind"], d["grid"], d["precision"], d["S"], d["L"], d["mode"], d["status"],
                         d["n_mismatch"], d["block_len"], d["formula_nominal"], name))
            continue
        if d["status"] != "PASS":
            continue
        key = (d["kind"], d["grid"], d["precision"], d["S"], d["L"])
        r = rows.setdefault(key, dict(d, cases=[], spacings=set()))
        r["cases"].append(name)
        r["spacings"].update(d["measured_periods"])
        if d["block_len"] != r["block_len"]:
            raise SystemExit(f"inconsistent block_len for {key}")

    bad = 0
    table = []
    for key in sorted(rows, key=lambda k: (k[0] != "single_pe_top", SHAPE_ORDER.get(k[1], 9), k[2], -k[3], k[4])):
        r = rows[key]
        kind, grid, prec, S, L = key
        pr, pc = map(int, grid.split("x"))
        ba, bw = m.PREC[prec]
        peak = 128 / (ba * bw)
        mac_tc = r["outputs_per_pe"] * L / (64 * r["block_len"])
        t1s = m.schedule(m.Sch("T1"), prec, L, pr, pc)   # split into 24-bit-safe blocks if needed
        t1, t1_split = t1s["period"], t1s["nsplit"]
        t1_pct = 8 * (8 // ba) * L / (64 * t1) / peak
        spac = sorted(r["spacings"])
        ok = r["model_period"] == r["block_len"] and (not spac or spac == [r["block_len"]])
        bad += not ok
        rec = dict(top="single-PE top" if kind == "single_pe_top" else "grid", grid=grid, precision=prec,
                   S=S, L=L, outputs_per_pe=r["outputs_per_pe"], block_period=r["block_len"],
                   measured_spacing=spac, model_T2=r["model_period"], agree=ok,
                   mac_per_tile_cycle=round(mac_tc, 4), pct_peak=round(100 * mac_tc / peak, 1),
                   edges_per_8_outputs_per_pe=round(8 * r["block_len"] / r["outputs_per_pe"], 1),
                   model_T1=t1, T1_blocks=t1_split, T1_pct_peak=round(100 * t1_pct, 1),
                   T1_edges_per_8_outputs_per_pe=round(8 * t1 / (8 * (8 // ba)), 1),
                   cases=r["cases"])
        table.append(rec)

    print("BP-space (T2) block periods on the unchanged BP RTL (csa_bp_20261004_lap); passing nominal runs.")
    print("period = scheduled block period (feasible: bit-exact run); spacing = drain-start spacing measured in")
    print("multi-block traces; model = block_terms(T2 S) of model_lap_schedules.py.  T1 = as-built per-PE laps")
    print("(model schedule(), split into 24-bit-safe blocks where L needs it; = measured RTL periods where those")
    print("exist).  e/8o = edges per 8 outputs per PE.\n")
    hdr = (f"{'top':<14} {'grid':<4} {'prec':<5} {'S':>2} {'L':>5} {'out/PE':>6} {'period':>7} {'spacing':>9} "
           f"{'model':>6} {'ok':>3} {'%peak':>6} {'e/8o':>7} | {'T1':>5} {'T1%pk':>6} {'T1e/8o':>7}")
    print(hdr)
    print("-" * len(hdr))
    for t in table:
        sp = ",".join(map(str, t["measured_spacing"])) or "-"
        print(f"{t['top']:<14} {t['grid']:<4} {t['precision']:<5} {t['S']:>2} {t['L']:>5} {t['outputs_per_pe']:>6} "
              f"{t['block_period']:>7} {sp:>9} {t['model_T2']:>6} {'yes' if t['agree'] else 'NO':>3} "
              f"{t['pct_peak']:>5.1f}% {t['edges_per_8_outputs_per_pe']:>7} | {t['model_T1']:>5} "
              f"{t['T1_pct_peak']:>5.1f}% {t['T1_edges_per_8_outputs_per_pe']:>7}"
              + (f"  (T1: {t['T1_blocks']} blocks, 24-bit limit)" if t["T1_blocks"] > 1 else ""))

    print("\nNegative and tightness controls (must FAIL with tile/output mismatches):")
    for n in sorted(negs, key=lambda x: (x[0] != "single_pe_top", SHAPE_ORDER.get(x[1], 9), x[5])):
        kind, grid, prec, S, L, mode, st, nm, bl, fn = n[:10]
        top = "single-PE top" if kind == "single_pe_top" else f"grid {grid}"
        extra = f" (scheduled period {bl} vs nominal {fn})" if bl != fn else ""
        verdict = "caught" if st == "FAIL" and nm > 0 else "NOT CAUGHT"
        print(f"  {top:<14} {prec:<5} S={S} L={L:<5} {mode:<18} {verdict}: {nm} mismatches{extra}  [{n[10]}]")
        bad += verdict != "caught"

    (out / "periods.json").write_text(json.dumps(dict(periods=table, controls=[
        dict(zip(("kind", "grid", "precision", "S", "L", "mode", "status", "n_mismatch", "block_len",
                  "formula_nominal", "case"), n)) for n in negs]), indent=2) + "\n")
    print(f"\n{len(table)} period points, {len(negs)} controls; "
          f"{'all periods equal the model T2 prediction, all controls caught' if not bad else f'{bad} PROBLEMS'}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
