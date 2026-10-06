#!/usr/bin/env python3
"""Report disaggregated SC-array energy from a PT-PX cell-power report.

This is deliberately separate from the established full-array pJ/MAC metric.
It reports:

* peripheral energy per binary-to-unary comparator evaluation;
* Sobol-bank energy per generated threshold word; and
* InnerPE-array energy per equivalent MAC.

PrimeTime's top-level hierarchical rows include the power of all descendants
and the switching power of nets driven by those descendants.  Power left at
the design root (for example top-level CTS/buffer cells) is reported as shared
overhead so the block powers reconcile to the unchanged full-array total.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


POWER_ROW_RE = re.compile(
    r"^\s*(?P<name>\S+)\s+"
    r"(?P<internal>[0-9.eE+-]+)\s+"
    r"(?P<switching>[0-9.eE+-]+)\s+"
    r"(?P<leakage>[0-9.eE+-]+)\s+"
    r"(?P<total>[0-9.eE+-]+)"
)
TOTAL_ROW_RE = re.compile(
    r"^\s*Totals \([0-9]+ cells?\)\s+"
    r"(?P<internal>[0-9.eE+-]+)\s+"
    r"(?P<switching>[0-9.eE+-]+)\s+"
    r"(?P<leakage>[0-9.eE+-]+)\s+"
    r"(?P<total>[0-9.eE+-]+)"
)


@dataclass(frozen=True)
class Power:
    internal_w: float
    switching_w: float
    leakage_w: float
    total_w: float

    @property
    def total_mw(self) -> float:
        return self.total_w * 1.0e3


def parse_report(path: Path, block_names: tuple[str, ...]) -> tuple[Power, dict[str, Power]]:
    blocks: dict[str, Power] = {}
    design_total: Power | None = None

    for line in path.read_text().splitlines():
        total_match = TOTAL_ROW_RE.match(line)
        if total_match:
            design_total = Power(
                float(total_match["internal"]),
                float(total_match["switching"]),
                float(total_match["leakage"]),
                float(total_match["total"]),
            )
            continue

        row_match = POWER_ROW_RE.match(line)
        if not row_match or row_match["name"] not in block_names:
            continue
        blocks[row_match["name"]] = Power(
            float(row_match["internal"]),
            float(row_match["switching"]),
            float(row_match["leakage"]),
            float(row_match["total"]),
        )

    missing = sorted(set(block_names) - blocks.keys())
    if missing:
        raise ValueError(f"missing hierarchical power row(s): {', '.join(missing)}")
    if design_total is None:
        raise ValueError("missing PrimeTime 'Totals (... cells)' row")
    return design_total, blocks


def energy_pj(power_mw: float, period_ns: float, events_per_cycle: float) -> float:
    # mW * ns = pJ
    return power_mw * period_ns / events_per_cycle


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cell_power_report", type=Path)
    parser.add_argument("--k", type=int, required=True)
    parser.add_argument("--m", type=int, required=True)
    parser.add_argument("--nh", type=int, required=True)
    parser.add_argument("--nw", type=int, required=True)
    parser.add_argument("--t", type=int, required=True)
    parser.add_argument("--period-ns", type=float, default=2.5)
    parser.add_argument("--core-name", default="u_pe")
    parser.add_argument("--peripheral-name", default="u_peripheral")
    parser.add_argument("--a-rng-name", default="u_a_rng")
    parser.add_argument("--w-rng-name", default="u_w_rng")
    args = parser.parse_args()

    positive_args = {
        "K": args.k,
        "M": args.m,
        "N_H": args.nh,
        "N_W": args.nw,
        "T": args.t,
        "period": args.period_ns,
    }
    for name, value in positive_args.items():
        if value <= 0:
            parser.error(f"{name} must be positive")

    names = (
        args.core_name,
        args.peripheral_name,
        args.a_rng_name,
        args.w_rng_name,
    )
    total, blocks = parse_report(args.cell_power_report, names)

    core_mw = blocks[args.core_name].total_mw
    peripheral_mw = blocks[args.peripheral_name].total_mw
    sobol_mw = (
        blocks[args.a_rng_name].total_mw + blocks[args.w_rng_name].total_mw
    )
    shared_mw = total.total_mw - core_mw - peripheral_mw - sobol_mw

    macs_per_cycle = args.k * args.m * args.nh * args.nw / args.t
    # One comparator evaluation emits one unary/stochastic output bit.
    conversions_per_cycle = (args.nh + args.nw) * args.k * args.m
    # One vector conversion emits M parallel unary bits for one binary operand.
    vectors_per_cycle = (args.nh + args.nw) * args.k
    # There are independent A and W banks, each containing M generators.
    sobol_words_per_cycle = 2 * args.m

    print(
        f"Source: {args.cell_power_report}\n"
        f"Shape: K={args.k}, M={args.m}, N={args.nh}x{args.nw}, "
        f"T={args.t}, period={args.period_ns:g} ns\n"
    )
    print(
        "| block/account | power (mW) | events/cycle | "
        "native energy | pJ/MAC equivalent |"
    )
    print("|---|---:|---:|---:|---:|")
    print(
        f"| InnerPE array (`{args.core_name}`) | {core_mw:.6f} | "
        f"{macs_per_cycle:g} MAC | "
        f"{energy_pj(core_mw, args.period_ns, macs_per_cycle):.9f} pJ/MAC | "
        f"{energy_pj(core_mw, args.period_ns, macs_per_cycle):.9f} |"
    )
    print(
        f"| Binary-unary peripheral (`{args.peripheral_name}`) | "
        f"{peripheral_mw:.6f} | {conversions_per_cycle:g} unary bits | "
        f"{energy_pj(peripheral_mw, args.period_ns, conversions_per_cycle):.9f} "
        f"pJ/conversion | "
        f"{energy_pj(peripheral_mw, args.period_ns, macs_per_cycle):.9f} |"
    )
    print(
        f"| Sobol banks (`{args.a_rng_name}` + `{args.w_rng_name}`) | "
        f"{sobol_mw:.6f} | {sobol_words_per_cycle:g} words | "
        f"{energy_pj(sobol_mw, args.period_ns, sobol_words_per_cycle):.9f} "
        f"pJ/Sobol | "
        f"{energy_pj(sobol_mw, args.period_ns, macs_per_cycle):.9f} |"
    )
    print(
        f"| Shared/top-level overhead | {shared_mw:.6f} | — | — | "
        f"{energy_pj(shared_mw, args.period_ns, macs_per_cycle):.9f} |"
    )
    print(
        f"| **Full array (unchanged)** | **{total.total_mw:.6f}** | "
        f"**{macs_per_cycle:g} MAC** | "
        f"**{energy_pj(total.total_mw, args.period_ns, macs_per_cycle):.9f} "
        f"pJ/MAC** | "
        f"**{energy_pj(total.total_mw, args.period_ns, macs_per_cycle):.9f}** |"
    )
    print(
        "\nBinary-unary vector equivalent "
        f"(one binary operand -> {args.m} parallel unary bits): "
        f"{energy_pj(peripheral_mw, args.period_ns, vectors_per_cycle):.9f} "
        "pJ/vector."
    )


if __name__ == "__main__":
    main()
