#!/usr/bin/env python3
# [ABIT COPY] of sweeps/cbsg/af_ipd/check_bp_trace.py (sha256 35847e70...cbc8 at copy time, 2026-10-06; the
# variant's copy of sweeps/int_mode/bp/check_bp_trace.py), rewritten for the all-bits-in-time schedule: same
# role (independent numpy int64 reference, every (block, step) exactly once, JSON + [PASS]/[FAIL] line), new trace
# format, reference and schedule checks (sweeps/cbsg/af_ipd/abit/abit_model.py).
"""Bit-exact and schedule check of the all-bits-in-time INT bench (+MODE=abit of
designs/payn/tb/test_payn_array_cbsg_af_ipd.sv; the abit INT energy bench writes the same records).

RUN_DIR holds abit_trace.txt, bpt_a.hex, bpt_w.hex.  Checks (abit_model.py has the details):
  * data: every drained acc_out_east value of every (block, step) against the numpy int64 GEMM (A @ W): tile row h
    of block (ig, jg) = output row ig*8 + h, drain step t = output column jg*8 + 7 - t; bit-exact, exactly once;
    every combiner word present exactly once (its value is not used by this schedule);
  * schedule: the logged stimulus against the rules (MSB-first levels, one bubble + one lap per level step, no lap
    inside a level, pass sign (p == BA-1) XOR (q == BW-1), contiguous captures, drain placement);
  * block period: every block's measured period equals BA*BW*NB + (BA+BW-2) + 8;
  * replay: the drained values the logged stimulus implies (edge model) must equal the RTL's.
PASS needs all four.  A negative control is CAUGHT when the data check fails while the RTL still equals the replay
(--expect-fail prints that verdict and exits 0 only then).

Usage:  check_abit_trace.py RUN_DIR [--json out.json] [--expect-fail]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import abit_model as am  # noqa: E402

FIELDS = ("ba", "bw", "L", "mrows", "ncols", "nblk", "nb", "e0", "e_end", "blk_len", "d0", "formula_bench",
          "nlev", "junk", "mode_at", "neg_no_lap", "neg_extra_lap", "neg_sign", "neg_order", "neg_no_bubble",
          "neg_drain_early", "neg_overlap", "park_cyc0")


def check(run_dir: Path, trace_name: str = "abit_trace.txt", header: str = "ABITCFG") -> dict:
    lines = (run_dir / trace_name).read_text().splitlines()
    if not lines or not lines[0].startswith(header):
        raise SystemExit(f"missing {header} header")
    vals = [int(x) for x in lines[0].split()[1:]]
    if len(vals) < 13:
        raise SystemExit(f"{header} has {len(vals)} fields")
    cfg = dict(zip(FIELDS, vals))
    ba, bw, L, mrows, ncols, nblk, nb = (cfg[k] for k in ("ba", "bw", "L", "mrows", "ncols", "nblk", "nb"))
    njg = ncols // 8
    if nblk != (mrows // 8) * njg or nb != L // 128:
        raise SystemExit(f"{header} shape fields are inconsistent")
    rec = am.parse_records(lines[1:])
    A, W = am.load_operands(run_dir, ba, bw, mrows, ncols, L)
    exp, C = am.gemm_tiles(A, W, nblk, njg)
    if abs(C).max() >= (1 << (am.OWIDTH - 1)):
        raise SystemExit("GEMM output exceeds the 24-bit tile; workload invalid")
    want = {(b, t) for b in range(nblk) for t in range(8)}
    coverage_ok = set(rec["D"]) == want and set(rec["C"]) == want and not rec["dup"]
    mism = []
    for (b, t), got in sorted(rec["D"].items()):
        e = exp.get((b, 0, t))
        if e is None:
            continue
        for h in range(8):
            if got[h] != e[h]:
                mism.append(dict(block=b, step=t, h=h, v=7 - t, got=got[h], exp=e[h]))
    sched = am.check_schedule(cfg, rec)
    rep = am.replay(cfg, rec, A, W)
    rep_mism = [dict(block=b, step=t, got=rec["D"][(b, t)], replay=rep.get((b, t)))
                for (b, t) in sorted(rec["D"]) if rep.get((b, t)) != rec["D"][(b, t)]]
    if set(rep) != set(rec["D"]):
        rep_mism.append(dict(note=f"replay drained {len(rep)} columns, RTL {len(rec['D'])}"))
    status = "PASS" if (not mism and coverage_ok and not sched["errors"] and not rep_mism) else "FAIL"
    negs = {k: cfg.get(k, 0) for k in FIELDS[15:22]}
    is_neg = any(v not in (0, -1) for v in negs.values())
    caught = status == "FAIL" and bool(mism) and not rep_mism
    return dict(
        status=status, precision=am.precision_name(ba, bw), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols,
        blocks=nblk, nb=nb, junk=cfg.get("junk"), mode_at=cfg.get("mode_at"), park_cyc0=cfg.get("park_cyc0"),
        negative_controls=negs, negative_run=is_neg, negative_caught=caught,
        coverage_ok=coverage_ok, duplicates=rec["dup"][:8],
        values_checked=len(rec["D"]) * 8, outputs_checked=nblk * 64, macs=nblk * 64 * L,
        max_abs_output=int(abs(C).max()),
        n_mismatch=len(mism), mismatches=mism[:16],
        n_replay_mismatch=len(rep_mism), replay_mismatches=rep_mism[:4],
        schedule_errors=sched["errors"][:16], n_schedule_errors=len(sched["errors"]),
        formula=sched["formula"], measured_periods=sorted(set(sched["periods"])), period_ok=sched["period_ok"],
        bench_block_len=cfg.get("blk_len"), laps=sched["laps"], passes=sched["passes"],
        data_edges_per_block=ba * bw * nb,
        data_utilization=round(ba * bw * nb / sched["formula"], 4),
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    ap.add_argument("--expect-fail", action="store_true")
    args = ap.parse_args()
    r = check(args.run_dir)
    text = json.dumps(r, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    tag = f"{r['precision']} L={r['L']} blocks={r['blocks']}"
    if args.expect_fail:
        if r["negative_caught"]:
            print(f"[CAUGHT] {tag}: {r['n_mismatch']} of {r['values_checked']} drained values differ from the GEMM, "
                  f"RTL equals the replay of the logged schedule; {r['n_schedule_errors']} schedule-rule errors "
                  f"(periods {r['measured_periods']} vs formula {r['formula']})")
            return 0
        print(f"[NOT-CAUGHT] {tag}: status {r['status']}, {r['n_mismatch']} GEMM mismatches, "
              f"{r['n_replay_mismatch']} replay mismatches")
        return 1
    if r["status"] != "PASS":
        print(f"[FAIL] {tag}: {r['n_mismatch']} GEMM mismatches, {r['n_replay_mismatch']} replay mismatches, "
              f"{r['n_schedule_errors']} schedule errors, coverage_ok={r['coverage_ok']}, "
              f"periods {r['measured_periods']} vs {r['formula']}")
        return 1
    print(f"[PASS] {tag}: {r['values_checked']} drained values = {r['outputs_checked']} GEMM outputs bit-exact "
          f"({r['macs']} MACs, max|out| {r['max_abs_output']}); replay identical; schedule rules hold "
          f"({r['passes']} passes, {r['laps']} laps); measured block period {r['measured_periods']} = formula "
          f"{r['formula']} (data utilization {r['data_utilization']:.1%})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
