#!/usr/bin/env python3
"""Compare the v1 Sobol/peripheral RTL trace against sc_kernel.py."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np

from sc_kernel import ArrayCfg, edge_operand_bits


def pack(values: np.ndarray, width: int) -> int:
    packed = 0
    for index, value in enumerate(values.reshape(-1)):
        packed |= int(value) << (index * width)
    return packed


def expected_operands(cfg: ArrayCfg) -> tuple[np.ndarray, ...]:
    a_mag = np.zeros((cfg.N_H, cfg.K), dtype=np.int32)
    a_sign = np.zeros((cfg.N_H, cfg.K), dtype=np.uint8)
    w_mag = np.zeros((cfg.N_W, cfg.K), dtype=np.int32)
    w_sign = np.zeros((cfg.N_W, cfg.K), dtype=np.uint8)

    for index in range(cfg.N_H * cfg.K):
        a_mag.reshape(-1)[index] = (index * 29 + 7) & 0xFF
        a_sign.reshape(-1)[index] = int(index % 3 == 1)
    for index in range(cfg.N_W * cfg.K):
        w_mag.reshape(-1)[index] = (index * 43 + 11) & 0xFF
        w_sign.reshape(-1)[index] = int(index % 4 >= 2)
    return a_mag, a_sign, w_mag, w_sign


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()

    cfg = ArrayCfg(K=4, M=4, N_H=2, N_W=2, WIDTH=8)
    rng_a = cfg.make_rng_in()
    rng_w = cfg.make_rng_w()
    a_mag, a_sign, w_mag, w_sign = expected_operands(cfg)
    expected_a_signs = pack(a_sign, 1)
    expected_w_signs = pack(w_sign, 1)

    mismatches: list[str] = []
    with args.trace.open(newline="") as trace_file:
        rows = list(csv.DictReader(trace_file))

    for expected_cycle, row in enumerate(rows):
        cycle = int(row["cycle"])
        a_random = rng_a.step()
        w_random = rng_w.step()
        a_bits = edge_operand_bits(
            a_mag, a_random, cfg.K, cfg.M, cfg.WIDTH, salt=0
        )
        w_bits = edge_operand_bits(
            w_mag, w_random, cfg.K, cfg.M, cfg.WIDTH,
            salt=1 << (cfg.WIDTH - 1),
        )
        expected = {
            "a_rng": pack(a_random, cfg.WIDTH),
            "w_rng": pack(w_random, cfg.WIDTH),
            "a_bits": pack(a_bits, 1),
            "w_bits": pack(w_bits, 1),
            "a_signs": expected_a_signs,
            "w_signs": expected_w_signs,
        }

        if cycle != expected_cycle:
            mismatches.append(
                f"row {expected_cycle}: RTL cycle field is {cycle}"
            )
        for field, expected_value in expected.items():
            rtl_value = int(row[field], 16)
            if rtl_value != expected_value:
                mismatches.append(
                    f"cycle {cycle:3d} {field}: "
                    f"python=0x{expected_value:x} rtl=0x{rtl_value:x}"
                )

    if mismatches:
        print(f"[FAIL] {len(mismatches)} RTL/Python mismatches")
        for mismatch in mismatches[:20]:
            print(f"  {mismatch}")
        return 1

    print(f"[PASS] {len(rows)} cycles match sc_kernel.py bit-for-bit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
