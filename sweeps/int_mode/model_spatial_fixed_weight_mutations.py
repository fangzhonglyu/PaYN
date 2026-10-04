#!/usr/bin/env python3
"""Mutation test for model_spatial_fixed_weight.py: inject faults and confirm
the register-level model reports them (mismatch vs numpy or an assertion).
A benign perturbation (a threshold that stays on the same side of the code
cut) must NOT change results.  No EDA tools.
Usage: python3 sweeps/int_mode/model_spatial_fixed_weight_mutations.py
"""
import importlib
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import model_spatial_fixed_weight as m  # noqa: E402


def run(fn, rng):
    importlib.reload(m)
    fn()
    A, W = m.data("INT8", "random", 4, 64, 8, rng)
    try:
        out = m.run_blocks("INT8", [(A, W)], 2, 2)[0][0]
        return "exact" if np.array_equal(out, A @ W) else "MISMATCH"
    except AssertionError as e:
        return f"ASSERT ({e})"


def drop_corr():
    orig = m.lane_signed

    def ls(a, w, sa, sw):
        v, r4, r1, n = orig(a, w, sa, sw)
        return v + 16 * n, r4, r1, n * 0
    m.lane_signed = ls


def benign_threshold():
    m.THR_A[3, 5] ^= 0x40


def cross_cut():
    low = np.argsort(m.THR_A[3])[:8]
    m.THR_A[3, low[0]] = 250


def bad_code():
    m.CODE_W[2, 5] += 40


def low_w7():
    m.LOW_W = 7


def no_w_sign_load():
    orig = m.Grid.step

    def st(self, *a, **kw):
        kw["load_w_sign_in"] = 0
        return orig(self, *a, **kw)
    m.Grid.step = st


def main():
    rng = np.random.default_rng(7)
    cases = [("baseline", lambda: None, "exact"),
             ("benign A threshold change", benign_threshold, "exact"),
             ("drop -16N correction", drop_corr, "fault"),
             ("A threshold across code cut", cross_cut, "fault"),
             ("wrong W code-table entry", bad_code, "fault"),
             ("LOW_W=7 (heap range too small)", low_w7, "fault"),
             ("W sign pipes never loaded", no_w_sign_load, "fault")]
    for name, fn, want in cases:
        got = run(fn, rng)
        ok = (got == "exact") == (want == "exact")
        print(f"  {'ok ' if ok else 'BAD'} {name:34s} -> {got}")
        assert ok, name
    print("mutation test passed: every injected fault was reported")


if __name__ == "__main__":
    main()
