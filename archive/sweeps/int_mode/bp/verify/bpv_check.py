#!/usr/bin/env python3
"""Checker for tb_bp_vec.sv traces against bpv_gen.py's numpy int64 reference.

Checks, per trace line n (pre-edge state of P_n):
  * every drain edge: acc_out_east == the reference tile column (row h = slice h),
    as signed OWIDTH=24 values vs the TRUE int64 value (no wrap allowed);
  * every combiner slot (drain edge + 2): int_out_valid == 1 and
    int_out == {hi, lo} as signed 32-bit vs the TRUE int64 GEMM value;
  * int_out_valid == 0 on every other line after the first reset edge, never X;
  * no X on acc_out_east at drain edges or on int_out at valid slots.
Prints [PASS] or [FAIL] with the first mismatches; exit 0 on PASS, 1 on FAIL.
For a failing tile it also reports whether the observed value equals the
reference wrapped mod 2^24 (range limit, not a datapath error).

Usage: bpv_check.py RUN_DIR [--json OUT]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

OW, NH, NW = 24, 8, 8


def s(v: int, w: int) -> int:
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    exp = json.loads((a.run_dir / "bpv_expect.json").read_text())
    lines = (a.run_dir / "bpv_trace.txt").read_text().split("\n")
    lines = [ln for ln in lines if ln.strip()]
    if len(lines) != exp["n_trace"]:
        print(f"[FAIL] trace has {len(lines)} lines, expected {exp['n_trace']}")
        return 1
    trace = [ln.split() for ln in lines]
    errs: list[str] = []
    n_tile = n_comb = 0
    wrap_only = True

    def unknown(h: str) -> bool:
        return any(c in "xXzZ" for c in h)

    for d in exp["drains"]:
        n = d["n"]
        acc = trace[n][2]
        if unknown(acc):
            errs.append(f"X on acc_out_east at drain n={n} blk={d['blk']} t={d['t']}")
            continue
        val = int(acc, 16)
        for h in range(NH):
            got = s(val >> (h * OW), OW)
            ref = d["tiles"][h]
            n_tile += 1
            if got != ref:
                wrapped = s(ref, OW)
                if got != wrapped:
                    wrap_only = False
                errs.append(f"tile blk={d['blk']} v={d['v']} h={h} (drain n={n}): got {got}, ref {ref}"
                            f"{' (== ref mod 2^24)' if got == wrapped else ''}")
    comb_slots = {c["n"]: c for c in exp["combs"]}
    for n in range(exp["first_check"], exp["n_trace"]):
        vld, out = trace[n][0], trace[n][1]
        if unknown(vld):
            errs.append(f"int_out_valid X at n={n}")
            continue
        want = n in comb_slots
        if int(vld, 16) != int(want):
            errs.append(f"int_out_valid={vld} at n={n}, expected {int(want)}")
            continue
        if not want:
            continue
        c = comb_slots[n]
        if unknown(out):
            errs.append(f"X on int_out at n={n}")
            continue
        v = int(out, 16)
        lo, hi = s(v, 32), s(v >> 32, 32)
        n_comb += 1
        if lo != c["lo"] or hi != c["hi"]:
            wrap_only = wrap_only and (lo == s(c["lo"], 32) and hi == s(c["hi"], 32))
            errs.append(f"comb blk={c['blk']} v={c['v']} (n={n}): got lo={lo} hi={hi}, ref lo={c['lo']} hi={c['hi']}")

    meta = exp["meta"]
    res = dict(scenario=meta["scenario"], expect=meta["expect"], n_tile_checks=n_tile,
               n_comb_checks=n_comb, n_errors=len(errs), first_errors=errs[:12],
               tiles_in_owidth=exp["tiles_in_owidth"], errors_are_mod2_24_wrap=bool(errs) and wrap_only,
               ops=exp["ops_summary"])
    if a.json:
        a.json.write_text(json.dumps(res, indent=2) + "\n")
    if not errs and (n_tile != NH * len(exp["drains"]) or n_comb != len(exp["combs"])):
        errs.append("coverage mismatch")
    if errs:
        for e in errs[:12]:
            print("  " + e)
        print(f"[FAIL] {meta['scenario']}: {len(errs)} errors / {n_tile} tile + {n_comb} combiner checks"
              f"{' (all errors equal the reference mod 2^24: range limit)' if wrap_only else ''}")
        return 1
    print(f"[PASS] {meta['scenario']}: {n_tile} tiles ({len(exp['drains'])} columns) and {n_comb} combiner words "
          f"bit-exact, valid exact on {exp['n_trace'] - exp['first_check']} lines; ops {exp['ops_summary']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
