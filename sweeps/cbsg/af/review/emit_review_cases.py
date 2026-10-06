#!/usr/bin/env python3
"""Adversarial-review golden cases for the AF RTL (emitted by sweeps/cbsg/af/run_rtl_checks.sh into
build/cbsg/af/golden_rv and played by the functional matrix there).

Same .mem format and gate as cbsg_ref.py --emit (kernel == RG == AF at every block and drain, then
re-derived from the .mem files).  Shapes the AF build's own cases do not stress:
  rv_cd8          chunk_d = 8: every block is its own slice (a drain after every block), random per-(row, chunk)
                  L from 16 distinct values in 1..128 (odd ones included), so C changes block to block
  rv_cd16         chunk_d = 16: two blocks per slice, random rungs
  rv_cd_unaligned chunk_d 24 / 40 / 56 / 72 / 136 calls back to back, random rungs, short tails
  rv_c1_chain     every L <= 16 (one-cycle blocks) at chunk_d 8 and 16 and plain, back to back
  rv_plain_randL  plain D = 1000, per-row L = 8 random distinct values in 1..128, uniform magnitudes
  rv_tiny_calls   60 calls of D 1..20 columns, per-row L random 1..128 each call (1-3 block calls, phase must reset)
  rv_mixed_long   protected split + odd plain + cd 136 rungs, the two protected orders, back to back

  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/af/review/emit_review_cases.py --out build/cbsg/af/review/golden_rv
"""
import argparse
import importlib.util
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
import numpy as np  # noqa: E402

REPO = Path(__file__).resolve().parents[4]
_spec = importlib.util.spec_from_file_location("emit_af_cases", REPO / "sweeps" / "cbsg" / "af" / "emit_af_cases.py")
eac = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eac)
ref = eac.ref
R = eac.R


def _rand_ladder(rng, n, lo=1, hi=128):
    vals = rng.choice(np.arange(lo, hi + 1), size=n, replace=False)
    return [int(v) for v in vals]


def _rv_cd8(rng):
    lad = _rand_ladder(rng, 16)
    return [eac.chunked_call(rng, 8 * 30 + 3, 8, ladder=lad, mags="uniform")]


def _rv_cd16(rng):
    lad = _rand_ladder(rng, 16)
    return [eac.chunked_call(rng, 16 * 20 + 9, 16, ladder=lad, mags="uniform")]


def _rv_cd_unaligned(rng):
    out = []
    for cd, tail in ((24, 5), (40, 17), (56, 1), (72, 33), (136, 77)):
        out.append(eac.chunked_call(rng, 3 * cd + tail, cd, ladder=_rand_ladder(rng, 10)))
    return out


def _rv_c1_chain(rng):
    lad = _rand_ladder(rng, 8, 1, 16)
    return [eac.chunked_call(rng, 8 * 12 + 2, 8, ladder=lad), eac.chunked_call(rng, 16 * 6 + 3, 16, ladder=lad),
            eac.plain_call(rng, 77, np.array(_rand_ladder(rng, 8, 1, 16)))]


def _rv_plain_randL(rng):
    return [eac.plain_call(rng, 1000, np.array(_rand_ladder(rng, 8)), mags="uniform")]


def _rv_tiny_calls(rng):
    out = []
    for _ in range(60):
        D = int(rng.integers(1, 21))
        L = rng.integers(1, 129, size=R)
        out.append(eac.plain_call(rng, D, L))
    return out


def _rv_mixed_long(rng):
    out = eac.prot_calls(rng, 410, 93, 95, 128, [128, 97, 84, 64, 48, 32, 25, 18], protected_first=False)
    out.append(eac.plain_call(rng, 333, np.array(_rand_ladder(rng, 8))))
    out.append(eac.chunked_call(rng, 136 * 2 + 11, 136, ladder=_rand_ladder(rng, 12)))
    out += eac.prot_calls(rng, 300, 50, 68, 128, [128, 96, 64, 48, 44, 42, 38], protected_first=True)
    return out


RV = {
    "rv_cd8": (_rv_cd8, "chunk_d=8: a drain after every block, random per-(row, chunk) L"),
    "rv_cd16": (_rv_cd16, "chunk_d=16: two blocks per slice, random rungs"),
    "rv_cd_unaligned": (_rv_cd_unaligned, "chunk_d 24/40/56/72/136 calls back to back, random rungs"),
    "rv_c1_chain": (_rv_c1_chain, "all L <= 16 (one-cycle blocks), cd 8 / cd 16 / plain"),
    "rv_plain_randL": (_rv_plain_randL, "plain D=1000, random distinct per-row L, uniform magnitudes"),
    "rv_tiny_calls": (_rv_tiny_calls, "60 calls of 1..20 columns, per-row L random 1..128"),
    "rv_mixed_long": (_rv_mixed_long, "unprotected-first split, plain 333, cd 136 rungs, protected-first split"),
}


def build_case(name, seed=1):
    rng = np.random.default_rng(seed * 7919 + sum(map(ord, name)))
    calls = RV[name][0](rng)
    spec = ref.CASES[name]
    spec["catches"] = [f for f in ref.MASK_FAULTS if min(ref._fault_wrong(calls, f)) > 0]
    return spec, calls


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(REPO / "build" / "cbsg" / "af" / "review" / "golden_rv"))
    ap.add_argument("--case", default="all")
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args()
    for k, (_, doc) in RV.items():
        ref.CASES[k] = dict(path="af_review", doc=doc)
    ref.build_case = build_case
    names = list(RV) if args.case == "all" else args.case.split(",")
    rc = 0
    for n in names:
        t0 = time.time()
        out, nb, nd, nc, caught = ref.emit_case(args.out, n, args.seed)
        bad, *_ = ref.check_golden(out)
        cs = ", ".join(f"{f} {a}/{b}" for f, (a, b) in caught.items()) or "none"
        print(f"[{'PASS' if bad == 0 else 'FAIL'}] {n}: {nb} blocks, {nd} drains, {nc} calls; kernel == RG == AF; "
              f"re-derived; mask faults caught: {cs}; {time.time() - t0:.1f} s", flush=True)
        rc |= int(bad != 0)
    return rc


if __name__ == "__main__":
    sys.exit(main())
