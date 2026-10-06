#!/usr/bin/env python3
# [ABIT COPY] of sweeps/cbsg/af_ipd/check_bp_power_trace.py (sha256 f121acf1...bbdc at copy time, 2026-10-06),
# rewritten for the all-bits-in-time energy bench (same role: the trace checker on the run dir plus the SAIF window
# record against the schedule; one JSON, exit 1 on any failure).
"""Bit-exact + SAIF-window check of the all-bits-in-time INT energy bench
(designs/payn/power/power_payn_array_cbsg_af_ipd_int_abit.sv).

1. Runs check_abit_trace.check() on RUN_DIR (abit_trace.txt, bpt_a.hex, bpt_w.hex): every drained acc_out_east
   value against the numpy int64 GEMM, every (block, step) and combiner word exactly once, the schedule rules, every
   block's measured period = BA*BW*NB + (BA+BW-2) + 8, and the replay of the logged stimulus; plus every D record's
   edge = the scheduled drain edge (X record).  The negative-control and junk fields must be at their defaults.
2. Checks abit_saif.txt against the schedule: the configuration must match the trace header and the active SAIF
   interval counts per class and the number of collection segments must be exactly what the window mode prescribes:
       data  = blocks * BA*BW*NB                      (every mode)
       lap   = blocks * (BA+BW-2)                     (modes 0, 2)
       drain = blocks * 8                             (mode 2)
       segments = blocks (mode 0), blocks * (BA+BW-1) (mode 1), 1 (mode 2)
   E_END = E0 + blocks * BLK and N_EDGES = E_END + 3, BLK the formula.
The JSON carries the fields the row writer reads (saif_window with key "ring" = the lap class, macs, lap_len 1).

Usage:  check_abit_power_trace.py RUN_DIR [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import abit_model as am  # noqa: E402
import check_abit_trace as cat  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    args = ap.parse_args()
    reasons: list[str] = []
    inner = cat.check(args.run_dir)
    if inner["status"] != "PASS":
        reasons.append(f"trace check FAIL: {inner['n_mismatch']} GEMM mismatches, {inner['n_replay_mismatch']} replay "
                       f"mismatches, {inner['n_schedule_errors']} schedule errors, coverage_ok={inner['coverage_ok']}")
    if inner["negative_run"] or inner["junk"] or inner["park_cyc0"]:
        reasons.append("trace header has negative-control / junk / park fields set; an energy run must have none")
    lines = (args.run_dir / "abit_trace.txt").read_text().splitlines()
    rec = am.parse_records(lines[1:])
    xedge = {(b, t): e for e, b, t in rec["X"]}
    bad_edges = [k for k, e in rec["Dedge"].items() if xedge.get(k) != e]
    if bad_edges or len(rec["Dedge"]) != len(rec["D"]):
        reasons.append(f"{len(bad_edges)} D records off their scheduled drain edge")

    srec = {l.split()[0]: [int(x) for x in l.split()[1:]]
            for l in (args.run_dir / "abit_saif.txt").read_text().splitlines() if l.strip()}
    if len(srec.get("ABITSAIF", [])) != 14 or len(srec.get("SAIFWIN", [])) != 5:
        raise SystemExit("abit_saif.txt malformed (need ABITSAIF x14, SAIFWIN x5)")
    ba, bw, L, mrows, ncols, nblk, nb, mode, mode_at, e0, e_end, n_edges, blk_len, d0 = srec["ABITSAIF"]
    win = dict(zip(("active", "data", "lap", "drain", "segments"), srec["SAIFWIN"]))
    for key, val in (("ba", ba), ("bw", bw), ("L", L), ("mrows", mrows), ("ncols", ncols), ("blocks", nblk),
                     ("nb", nb), ("mode_at", mode_at)):
        if inner.get(key) != val:
            reasons.append(f"abit_saif.txt {key}={val} disagrees with the trace header ({inner.get(key)})")
    blk = am.formula(ba, bw, nb)
    if blk_len != blk or e_end != e0 + nblk * blk or n_edges != e_end + 3:
        reasons.append(f"edge bookkeeping BLK_LEN={blk_len} E_END={e_end} N_EDGES={n_edges}, expected {blk} / "
                       f"{e0 + nblk * blk} / {e0 + nblk * blk + 3}")
    if mode not in (0, 1, 2):
        reasons.append(f"SAIF mode {mode} is not 0, 1 or 2")
    exp = dict(data=nblk * ba * bw * nb, lap=nblk * (ba + bw - 2) if mode in (0, 2) else 0,
               drain=nblk * 8 if mode == 2 else 0)
    exp["active"] = exp["data"] + exp["lap"] + exp["drain"]
    exp["segments"] = {0: nblk, 1: nblk * (ba + bw - 1), 2: 1}.get(mode, -1)
    for key, val in exp.items():
        if win[key] != val:
            reasons.append(f"SAIF window {key}={win[key]}, expected {val}")
    macs = nblk * 64 * L
    if win["data"] * 8192 != macs * ba * bw:
        reasons.append(f"window data cycles {win['data']} x 8192/(BA*BW) != {macs} MACs")

    result = dict(
        status="FAIL" if reasons else "PASS", rejection_reasons=reasons, schedule="abit",
        precision=am.precision_name(ba, bw), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols,
        blocks=nblk, nb=nb, saif_mode=mode, mode_at=mode_at, e0=e0, e_end=e_end, n_edges=n_edges,
        lap_ring_only=1, lap_len=1, block_period=blk, formula=inner["formula"],
        measured_periods=inner["measured_periods"],
        saif_window=dict(active=win["active"], data=win["data"], ring=win["lap"], drain=win["drain"],
                         segments=win["segments"]),
        expected_saif_window=exp, mac_per_data_cycle=8192 / (ba * bw), macs=macs,
        tiles_checked=inner["values_checked"], outputs_checked=inner["outputs_checked"],
        max_abs_tile=inner["max_abs_output"], max_abs_output=inner["max_abs_output"],
        n_mismatch=inner["n_mismatch"], trace_check=inner,
    )
    text = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    if reasons:
        print(f"[FAIL] {result['precision']} L={L} blocks={nblk} mode={mode}: " + "; ".join(reasons))
        return 1
    print(f"[PASS] {result['precision']} L={L} blocks={nblk} mode={mode} abit: {result['tiles_checked']} drained "
          f"values = {result['outputs_checked']} GEMM outputs bit-exact ({macs} MACs, max|out| "
          f"{result['max_abs_output']}); replay identical; block period {inner['measured_periods']} = formula "
          f"{inner['formula']}; SAIF window {win['active']} = {win['data']} data + {win['lap']} lap + "
          f"{win['drain']} drain in {win['segments']} segment(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
