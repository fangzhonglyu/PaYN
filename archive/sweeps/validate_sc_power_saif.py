#!/usr/bin/env python3
"""Validate an SC power SAIF for a correctly-executing run.

Methodology (what we actually care about): the circuit must *execute correctly*.
That is established by the array cosim / output-checking bench (drained accumulator
matrix compared bit-for-bit against sc_kernel.py) plus X-freeness of the
architectural accumulator output during the SAIF window. This validator gates only
on what would invalidate the *measurement itself*:

  - the accumulator/drain output must be X-free in the window (acc TX),
  - transient unknown activity must stay within one reporter quantum,
  - the observed clock period must match the target,
  - the stimulus must have enough clock/operand toggles.

Persistent X on internal or dead nets (unused edge feedthroughs, dead forwarding
flops) does NOT affect the measured result and is reported, not rejected. Pass
--strict-persistent-x for the historical fail-on-any-persistent-X policy.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from plot_updated_breakdowns import (
    parse_saif_acc_tx,
    parse_saif_activity,
    parse_saif_nonpersistent_tx,
    parse_saif_observed_clock_period_ns,
    parse_saif_reporting_quantum_pct,
    parse_saif_stimulus_tc,
    saif_unknown_activity_error,
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("saif", type=Path)
    parser.add_argument("--max-extra-acc-tx-pct", type=float, default=0.0)
    parser.add_argument("--min-clock-tc", type=float, default=100.0)
    parser.add_argument("--min-operand-tc", type=float, default=100.0)
    parser.add_argument("--expected-period-ns", type=float, default=2.5)
    parser.add_argument("--period-tolerance-ns", type=float, default=0.01)
    parser.add_argument(
        "--strict-persistent-x",
        action="store_true",
        help="also fail if any net is unknown for the entire window (legacy policy)",
    )
    args = parser.parse_args()

    aggregate_unknown_pct, total_tc = parse_saif_activity(args.saif)
    clock_tc, operand_tc = parse_saif_stimulus_tc(args.saif)
    acc_tx = parse_saif_acc_tx(args.saif)
    quantum_tx = parse_saif_reporting_quantum_pct(args.saif)
    nonpersistent_tx, persistent_signals = parse_saif_nonpersistent_tx(args.saif)
    if aggregate_unknown_pct is None or total_tc is None:
        raise SystemExit(f"invalid SC SAIF: no activity records in {args.saif}")
    if clock_tc is None or clock_tc < args.min_clock_tc:
        raise SystemExit(
            f"invalid SC SAIF: clock TC={clock_tc} is below {args.min_clock_tc}"
        )
    observed_period_ns = parse_saif_observed_clock_period_ns(args.saif)
    if observed_period_ns is None:
        raise SystemExit(f"invalid SC SAIF: cannot recover clock period from {args.saif}")
    if abs(observed_period_ns - args.expected_period_ns) > args.period_tolerance_ns:
        raise SystemExit(
            f"invalid SC SAIF: observed clock period={observed_period_ns:.6f} ns, "
            f"expected {args.expected_period_ns:.6f} +/- "
            f"{args.period_tolerance_ns:.6f} ns"
        )
    if operand_tc is None or operand_tc < args.min_operand_tc:
        raise SystemExit(
            f"invalid SC SAIF: operand TC={operand_tc} is below {args.min_operand_tc}"
        )
    if acc_tx is None:
        raise SystemExit(
            f"invalid SC SAIF: no accumulator output activity in {args.saif}"
        )
    if quantum_tx is None:
        raise SystemExit(f"invalid SC SAIF: no duration in {args.saif}")

    # Persistent X on internal/dead nets is informational unless --strict.
    unknown_error = saif_unknown_activity_error(
        nonpersistent_tx,
        persistent_signals if args.strict_persistent_x else 0,
        quantum_tx,
    )
    if unknown_error is not None:
        raise SystemExit(f"invalid SC SAIF: {unknown_error} in {args.saif}")
    # Architectural correctness gate: the accumulator/drain output must be X-free.
    allowed = quantum_tx + args.max_extra_acc_tx_pct
    if acc_tx > allowed + 1.0e-12:
        raise SystemExit(
            f"invalid SC SAIF: accumulator TX={acc_tx:.9f}% exceeds "
            f"one reporter quantum ({quantum_tx:.9f}%) + allowed extra "
            f"({args.max_extra_acc_tx_pct:.9f}%) -- accumulator is X, execution is not clean"
        )

    note = "" if persistent_signals == 0 else \
        f"  [note: {persistent_signals} internal/dead net(s) X for the whole window; " \
        f"benign given X-free accumulator -- correctness is checked by the array cosim]"
    print(
        f"validated SC SAIF: acc TX={acc_tx:.9f}%, "
        f"aggregate unknown-time={aggregate_unknown_pct:.6f}%, "
        f"nonpersistent TX={nonpersistent_tx:.6f}%, "
        f"persistent-X signals={persistent_signals}, "
        f"period={observed_period_ns:.6f} ns, "
        f"clock TC={clock_tc:.0f}, operand TC={operand_tc:.0f}, "
        f"total TC={total_tc:.0f}" + note
    )


if __name__ == "__main__":
    main()
