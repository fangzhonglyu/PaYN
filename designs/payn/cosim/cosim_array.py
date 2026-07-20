#!/usr/bin/env python3
"""Check payn_array RTL drain against the sc_kernel.py reference, bit-for-bit."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from payn_sim import array_reference, parse_trace


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", type=Path)
    args = ap.parse_args()

    cfg, a_mag, a_sign, w_mag, w_sign, rtl = parse_trace(args.trace)
    expected = array_reference(a_mag, a_sign, w_mag, w_sign, cfg)

    shape = f"K={cfg.K} M={cfg.M} N={cfg.N_H}x{cfg.N_W} T={cfg.T}"
    if np.array_equal(expected, rtl):
        print(f"[PASS] payn_array drain matches sc_kernel.py bit-for-bit ({shape})")
        return 0

    print(f"[FAIL] payn_array drain mismatch ({shape})")
    print("RTL drain:\n", rtl)
    print("expected:\n", expected)
    print("RTL - expected:\n", rtl - expected)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
