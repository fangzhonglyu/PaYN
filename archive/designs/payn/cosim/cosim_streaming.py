#!/usr/bin/env python3
"""Check the long-running PaYN power trace cycle-by-cycle.

Each binary magnitude/sign batch is held for T/M clocks.  On every clock, the
two Sobol banks advance and the peripheral produces a fresh M-bit stochastic
slice.  The checker accumulates every issued batch and compares the final
row-serial drain bit-for-bit.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from sc_kernel import (
    ArrayCfg,
    edge_operand_bits,
    inner_tile_2bit_contribution,
)


@dataclass(frozen=True)
class StreamingTrace:
    cfg: ArrayCfg
    n_batches: int
    a_mag: list[np.ndarray]
    a_sign: list[np.ndarray]
    w_mag: list[np.ndarray]
    w_sign: list[np.ndarray]
    drain: np.ndarray


def _read_vector(
    lines: list[list[str]], cursor: int, tag: str, count: int, dtype: np.dtype
) -> tuple[np.ndarray, int]:
    if cursor >= len(lines) or not lines[cursor] or lines[cursor][0] != tag:
        found = "<EOF>" if cursor >= len(lines) else " ".join(lines[cursor][:2])
        raise ValueError(f"expected {tag}, found {found}")
    values = lines[cursor][1:]
    if len(values) != count:
        raise ValueError(f"{tag} has {len(values)} values, expected {count}")
    return np.asarray(values, dtype=dtype), cursor + 1


def parse_streaming_trace(path: Path) -> StreamingTrace:
    lines = [line.split() for line in path.read_text().splitlines() if line.split()]
    if not lines or lines[0][0] != "STREAMCFG" or len(lines[0]) not in (9, 10):
        raise ValueError(
            "missing STREAMCFG K M NH NW WIDTH OWIDTH T NBATCHES [RNG_WRAP]"
        )

    values = [int(value) for value in lines[0][1:]]
    k, m, nh, nw, width, owidth, t, n_batches = values[:8]
    rng_wrap = bool(values[8]) if len(values) == 9 else False
    # T need not be a multiple of M: the padded-T bench executes ceil(T/M)
    # slices per block and zeroes the top M - T%M lanes of the final slice
    # (power_payn_array_tpad.sv).  The reference masks identically below.
    if t <= 0 or m <= 0:
        raise ValueError(f"T={t} and M={m} must be positive")
    cfg = ArrayCfg(
        K=k,
        M=m,
        N_H=nh,
        N_W=nw,
        WIDTH=width,
        OWIDTH=owidth,
        T=t,
        RNG_FULL_PERIOD_WRAP=rng_wrap,
    )

    a_mag: list[np.ndarray] = []
    a_sign: list[np.ndarray] = []
    w_mag: list[np.ndarray] = []
    w_sign: list[np.ndarray] = []
    cursor = 1
    for expected_batch in range(n_batches):
        if (
            cursor >= len(lines)
            or len(lines[cursor]) != 2
            or lines[cursor][0] != "BATCH"
            or int(lines[cursor][1]) != expected_batch
        ):
            raise ValueError(f"missing or out-of-order BATCH {expected_batch}")
        cursor += 1

        values, cursor = _read_vector(
            lines, cursor, "AMAG", nh * k, np.int64
        )
        a_mag.append(values.reshape(nh, k))
        values, cursor = _read_vector(
            lines, cursor, "ASIGN", nh * k, np.uint8
        )
        a_sign.append(values.reshape(nh, k))
        values, cursor = _read_vector(
            lines, cursor, "WMAG", nw * k, np.int64
        )
        w_mag.append(values.reshape(nw, k))
        values, cursor = _read_vector(
            lines, cursor, "WSIGN", nw * k, np.uint8
        )
        w_sign.append(values.reshape(nw, k))

    values, cursor = _read_vector(
        lines, cursor, "DRAIN", nh * nw, np.int64
    )
    if cursor != len(lines):
        raise ValueError(f"unexpected trailing trace record: {' '.join(lines[cursor])}")

    return StreamingTrace(
        cfg=cfg,
        n_batches=n_batches,
        a_mag=a_mag,
        a_sign=a_sign,
        w_mag=w_mag,
        w_sign=w_sign,
        drain=values.reshape(nh, nw),
    )


def streaming_reference(trace: StreamingTrace) -> np.ndarray:
    cfg = trace.cfg
    cycles_per_batch = -(-cfg.T // cfg.M)  # ceil: partial final slice
    pad_lanes = cycles_per_batch * cfg.M - cfg.T
    rng_a = cfg.make_rng_in()
    rng_w = cfg.make_rng_w()
    acc = np.zeros((cfg.N_H, cfg.N_W), dtype=np.int64)

    for batch in range(trace.n_batches):
        for cyc in range(cycles_per_batch):
            threshold_a = rng_a.step()
            threshold_w = rng_w.step()
            a_bits = edge_operand_bits(
                trace.a_mag[batch],
                threshold_a,
                cfg.K,
                cfg.M,
                cfg.WIDTH,
                0,
            )
            w_bits = edge_operand_bits(
                trace.w_mag[batch],
                threshold_w,
                cfg.K,
                cfg.M,
                cfg.WIDTH,
                1 << (cfg.WIDTH - 1),
            )
            if pad_lanes and cyc == cycles_per_batch - 1:
                # padded-T: the top pad_lanes lanes of the final slice are
                # dead -- mirrors the bench's force at the u_pe boundary
                a_bits[:, :, cfg.M - pad_lanes:] = 0
                w_bits[:, :, cfg.M - pad_lanes:] = 0

            for h in range(cfg.N_H):
                for v in range(cfg.N_W):
                    acc[h, v] += inner_tile_2bit_contribution(
                        a_bits[h],
                        w_bits[v],
                        trace.a_sign[batch][h],
                        trace.w_sign[batch][v],
                        cfg.K,
                        cfg.M,
                    )

    mask = (1 << cfg.OWIDTH) - 1
    sign_bit = 1 << (cfg.OWIDTH - 1)
    wrapped = acc & mask
    return np.where(wrapped & sign_bit, wrapped - (1 << cfg.OWIDTH), wrapped)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()

    trace = parse_streaming_trace(args.trace)
    expected = streaming_reference(trace)
    cfg = trace.cfg
    shape = (
        f"K={cfg.K} M={cfg.M} N={cfg.N_H}x{cfg.N_W} "
        f"T={cfg.T} batches={trace.n_batches}"
    )

    if np.array_equal(expected, trace.drain):
        print(f"[PASS] streaming PaYN drain matches cycle reference ({shape})")
        return 0

    print(f"[FAIL] streaming PaYN drain mismatch ({shape})")
    print("RTL drain:\n", trace.drain)
    print("expected:\n", expected)
    print("RTL - expected:\n", trace.drain - expected)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
