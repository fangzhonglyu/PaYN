#!/usr/bin/env python3
# [ABIT COPY] of sweeps/cbsg/af_ipd/check_bp_ipd_grid_trace.py (sha256 6f9f8d01...4653 at copy time, 2026-10-06),
# rewritten for the all-bits-in-time schedule (same role: independent numpy int64 reference, drain edges, lap runs
# of every PE, block period; new trace format and reference, sweeps/cbsg/af_ipd/abit/abit_model.py).
"""Bit-exact and timing check of the all-bits-in-time P_R x P_C grid bench
(designs/payn/tb/test_pe_grid_cbsg_af_ipd_abit.sv) on the copied IPD grid wrapper.

RUN_DIR holds abit_grid_trace.txt, bpt_a.hex, bpt_w.hex.  Checks:
  * data: every drained column "D blk r t e v0..v7" against numpy int64 A @ W: PE row r, step t = PE column
    P_C-1-t//8, tile column 7-t%8, tile row h -> C[(ig*P_R + r)*8 + h, (jg*P_C + c)*8 + v]; every (blk, r, t) once;
  * schedule rules on the logged virtual (PE (0,0)) schedule and the real drain edges (abit_model.check_schedule
    with S = P_R+P_C-2 and 8*P_C drain edges); each D record's edge must be the scheduled drain edge;
  * block period: every block's measured period = BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + 8*P_C;
  * lap runs (ring_q of every PE, from the RTL): PE (r,c) laps exactly on the virtual lap edges + r + c, one edge
    each, and nowhere else.
Exits 1 on any failure; --expect-fail exits 0 only if the data check fails (a negative control caught by wrong
drains).

Usage:  check_abit_grid_trace.py RUN_DIR [--json out.json] [--expect-fail]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import abit_model as am  # noqa: E402

FIELDS = ("pr", "pc", "ba", "bw", "L", "mrows", "ncols", "nblk", "nb", "e0", "e_end", "blk_len", "d0", "ds",
          "formula_bench", "nlev", "junk", "neg_row", "neg_col", "neg_no_bubble", "neg_drain_early", "neg_overlap",
          "neg_no_lap", "neg_extra_lap", "neg_sign", "neg_order")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    ap.add_argument("--expect-fail", action="store_true")
    args = ap.parse_args()
    lines = (args.run_dir / "abit_grid_trace.txt").read_text().splitlines()
    if not lines or not lines[0].startswith("ABITGCFG"):
        raise SystemExit("missing ABITGCFG header")
    cfg = dict(zip(FIELDS, (int(x) for x in lines[0].split()[1:])))
    pr, pc, ba, bw, L, mrows, ncols, nblk, nb = (cfg[k] for k in ("pr", "pc", "ba", "bw", "L", "mrows", "ncols",
                                                                   "nblk", "nb"))
    njg = ncols // (pc * 8)
    if nblk != (mrows // (pr * 8)) * njg or nb != L // 128:
        raise SystemExit("ABITGCFG shape fields are inconsistent")
    body, runs, drains = [], {}, {}
    dup = []
    for line in lines[1:]:
        f = line.split()
        if f and f[0] == "R":
            runs.setdefault((int(f[1]), int(f[2])), []).append((int(f[3]), int(f[4])))
        elif f and f[0] == "D":
            key = (int(f[1]), int(f[2]), int(f[3]))
            if key in drains:
                dup.append(key)
            drains[key] = (int(f[4]), [int(x) for x in f[5:]])
        else:
            body.append(line)
    rec = am.parse_records(body)
    A, W = am.load_operands(args.run_dir, ba, bw, mrows, ncols, L)
    exp, C = am.gemm_tiles(A, W, nblk, njg, pr, pc)
    if abs(C).max() >= (1 << (am.OWIDTH - 1)):
        raise SystemExit("GEMM output exceeds the 24-bit tile; workload invalid")
    coverage_ok = set(drains) == set(exp) and not dup
    mism = []
    for key, (e, got) in sorted(drains.items()):
        want = exp.get(key)
        if want is None or len(got) != 8:
            continue
        for h in range(8):
            if got[h] != want[h]:
                mism.append(dict(block=key[0], pe_row=key[1], step=key[2], h=h, got=got[h], exp=want[h]))
    sched = am.check_schedule(cfg, rec, pr, pc)
    xedge = {(b, t): e for e, b, t in rec["X"]}
    edge_err = [dict(block=b, row=r, step=t, edge=e, scheduled=xedge.get((b, t)))
                for (b, r, t), (e, _) in sorted(drains.items()) if xedge.get((b, t)) != e]
    lap_err = []
    vlaps = sorted(rec["L"])
    for r in range(pr):
        for c in range(pc):
            want_runs = [(x + r + c, 1) for x in vlaps]
            got_runs = sorted(runs.get((r, c), []))
            if got_runs != want_runs:
                lap_err.append(dict(pe=[r, c], got=got_runs[:4], exp=want_runs[:4], n_got=len(got_runs),
                                    n_exp=len(want_runs)))
    status = "PASS" if (not mism and coverage_ok and not sched["errors"] and not edge_err and not lap_err) else "FAIL"
    res = dict(status=status, grid=f"{pr}x{pc}", precision=am.precision_name(ba, bw), ba=ba, bw=bw, L=L,
               mrows=mrows, ncols=ncols, blocks=nblk, nb=nb, junk=cfg["junk"],
               negative_controls={k: cfg[k] for k in FIELDS[17:]},
               coverage_ok=coverage_ok, duplicates=[list(d) for d in dup[:8]],
               values_checked=8 * len(drains), outputs_checked=nblk * pr * pc * 64, macs=nblk * pr * pc * 64 * L,
               max_abs_output=int(abs(C).max()), n_mismatch=len(mism), mismatches=mism[:16],
               n_schedule_errors=len(sched["errors"]), schedule_errors=sched["errors"][:16],
               formula=sched["formula"], measured_periods=sorted(set(sched["periods"])), period_ok=sched["period_ok"],
               bench_block_len=cfg["blk_len"], n_drain_edge_errors=len(edge_err), drain_edge_errors=edge_err[:8],
               n_lap_errors=len(lap_err), lap_errors=lap_err[:8],
               lap_runs_checked=sum(len(v) for v in runs.values()),
               data_utilization=round(ba * bw * nb / sched["formula"], 4))
    text = json.dumps(res, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    tag = f"{pr}x{pc} {res['precision']} L={L} blocks={nblk}"
    if args.expect_fail:
        if mism:
            print(f"[CAUGHT] {tag}: {len(mism)} of {res['values_checked']} drained values differ from the GEMM; "
                  f"{len(lap_err)} PEs off the lap schedule, {len(sched['errors'])} schedule-rule errors, "
                  f"periods {res['measured_periods']} vs formula {res['formula']}")
            return 0
        print(f"[NOT-CAUGHT] {tag}: status {status}, no GEMM mismatch")
        return 1
    if status != "PASS":
        print(f"[FAIL] {tag}: {len(mism)} mismatches, coverage_ok={coverage_ok}, {len(sched['errors'])} schedule "
              f"errors, {len(edge_err)} drain-edge errors, {len(lap_err)} lap errors, periods "
              f"{res['measured_periods']} vs {res['formula']}")
        return 1
    print(f"[PASS] {tag}: {res['values_checked']} drained values = {res['outputs_checked']} GEMM outputs bit-exact "
          f"({res['macs']} MACs, max|out| {res['max_abs_output']}); {res['lap_runs_checked']} lap runs on the per-PE "
          f"wave; measured block period {res['measured_periods']} = formula {res['formula']} "
          f"(data utilization {res['data_utilization']:.1%})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
