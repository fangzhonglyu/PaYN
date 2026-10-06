#!/usr/bin/env python3
"""Summarize semantic pending-accumulator nets from a routed gate SAIF.

The APR netlist preserves each ``g_row_*__g_col_*__u_inner`` hierarchy and the
architectural ``acc_out``, ``acc_high``, and pending-event net names.  This
parser intentionally reads only nets directly in those tile instances; mapped
cell subinstances and unrelated top-level nets are ignored.
"""

from __future__ import annotations

import argparse
import re
from collections import defaultdict
from pathlib import Path


INSTANCE_RE = re.compile(r"^\s*\(INSTANCE\s+(\S+)")
NET_RE = re.compile(
    r"^\s*\((pending_carry|pending_borrow|acc_high\\\[(\d+)\\\]|"
    r"acc_out\\\[(\d+)\\\])\s*$"
)
TIME_RE = re.compile(r"\((T0|T1|TX|TC)\s+([0-9.]+)\)")


def parse(path: Path) -> tuple[dict[str, list[dict[str, float]]], float]:
    depth = 0
    instances: list[tuple[str, int]] = []
    current: tuple[str, int, dict[str, float]] | None = None
    groups: dict[str, list[dict[str, float]]] = defaultdict(list)
    duration = 0.0

    with path.open() as stream:
        for line in stream:
            before = depth
            if not duration:
                match = re.search(r"\(DURATION\s+([0-9.]+)\)", line)
                if match:
                    duration = float(match.group(1))

            match = INSTANCE_RE.match(line)
            if match:
                instances.append((match.group(1), before + 1))

            direct_tile_net = (
                instances
                and re.fullmatch(
                    r"g_row_\d+__g_col_\d+__u_inner", instances[-1][0]
                )
            )
            match = NET_RE.match(line) if direct_tile_net else None
            if match:
                raw_name = match.group(1)
                if raw_name == "pending_carry":
                    group = "pending_carry_q"
                elif raw_name == "pending_borrow":
                    group = "pending_borrow_q"
                elif match.group(2) is not None:
                    group = "acc_high_q_named"
                else:
                    bit = int(match.group(3))
                    group = "acc_low_q" if bit <= 8 else "visible_high_out"
                current = (group, before + 1, {})

            if current is not None:
                for field, value in TIME_RE.findall(line):
                    current[2][field] = float(value)

            depth += line.count("(") - line.count(")")

            if current is not None and depth < current[1]:
                groups[current[0]].append(current[2])
                current = None
            while instances and depth < instances[-1][1]:
                instances.pop()

    return groups, duration


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("saif", type=Path)
    parser.add_argument(
        "--cycles",
        type=int,
        default=2048,
        help="productive cycles in the SAIF window (default: 2048)",
    )
    args = parser.parse_args()

    groups, duration = parse(args.saif)
    print(f"SAIF {args.saif}")
    print(f"duration_ps {duration:.0f}  productive_cycles {args.cycles}")
    print(
        f"{'group':22s} {'signals':>8s} {'TC_total':>12s} "
        f"{'TC/signal':>11s} {'trans/bit/cycle':>17s} {'duty_1':>10s}"
    )
    for name in (
        "acc_low_q",
        "visible_high_out",
        "acc_high_q_named",
        "pending_carry_q",
        "pending_borrow_q",
    ):
        records = groups.get(name, [])
        tc = sum(record.get("TC", 0.0) for record in records)
        t1 = sum(record.get("T1", 0.0) for record in records)
        signals = len(records)
        per_signal = tc / signals if signals else 0.0
        density = tc / (signals * args.cycles) if signals else 0.0
        duty = t1 / (signals * duration) if signals and duration else 0.0
        print(
            f"{name:22s} {signals:8d} {tc:12.0f} {per_signal:11.2f} "
            f"{density:17.6f} {duty:10.6f}"
        )
    print(
        "note: acc_high_q_named contains bits [14:1]; bit 0 was mapped to an "
        "inverted anonymous net and is not included"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
