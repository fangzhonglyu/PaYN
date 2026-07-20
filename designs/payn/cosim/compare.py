"""Compare RTL drain outputs (rtl_out.txt) against numpy expected (expected.txt).

Both files: one signed decimal per line, in (spatial_tile, h, v) order that
matches the sc_kernel's spatial iteration and sc_inner_pe.acc_flat layout.
"""
from __future__ import annotations

import sys


def read_ints(path: str) -> list[int]:
    with open(path) as f:
        return [int(x.strip()) for x in f if x.strip()]


def main() -> int:
    exp = read_ints("expected.txt")
    rtl = read_ints("rtl_out.txt")

    if len(exp) != len(rtl):
        print(f"[FAIL] length mismatch: expected={len(exp)} rtl={len(rtl)}")
        return 1

    errs = [(i, e, r) for i, (e, r) in enumerate(zip(exp, rtl)) if e != r]
    print(f"total elements: {len(exp)}")
    print(f"matches: {len(exp) - len(errs)}/{len(exp)}")
    if errs:
        print("[FAIL] mismatches:")
        for i, e, r in errs[:20]:
            print(f"  idx={i:4d} expected={e:6d} rtl={r:6d} (diff={r-e:+d})")
        if len(errs) > 20:
            print(f"  ... and {len(errs)-20} more")
        return 1
    print("[PASS] all outputs bit-exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
