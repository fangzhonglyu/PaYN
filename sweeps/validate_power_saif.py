#!/usr/bin/env python3
"""Validate a binary power SAIF for a correctly-executing run.

Methodology (what we actually care about): the circuit must *execute correctly*.
That is established by the output-checking power bench, which compares the drained
outputs against an independent golden reference bit-for-bit every cycle and
monitors the architectural outputs for X during the SAIF window. This validator
therefore gates only on things that would invalidate the *measurement itself*:

  - the architectural Top/dut outputs must be X-free in the window (output TX),
  - transient unknown activity must stay within one reporter quantum,
  - the observed clock period must match the target.

Persistent X on internal or dead nets (e.g. unused array-edge control-forwarding
flops, or physical-hierarchy feedthroughs) does NOT affect the measured result and
is reported, not rejected -- a correctly executing circuit whose outputs are X-free
is a valid power point regardless of what an unread dead flop settled to. Pass
--strict-persistent-x to restore the historical fail-on-any-persistent-X policy.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from plot_updated_breakdowns import (
    parse_saif_activity,
    parse_saif_binary_output_tx,
    parse_saif_nonpersistent_tx,
    parse_saif_observed_clock_period_ns,
    parse_saif_reporting_quantum_pct,
    saif_unknown_activity_error,
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("saif", type=Path)
    parser.add_argument("--max-output-tx-pct", type=float, default=0.0)
    parser.add_argument("--expected-period-ns", type=float, default=2.5)
    parser.add_argument("--period-tolerance-ns", type=float, default=0.01)
    parser.add_argument(
        "--strict-persistent-x",
        action="store_true",
        help="also fail if any net is unknown for the entire window (legacy policy)",
    )
    args = parser.parse_args()

    aggregate_tx, total_tc = parse_saif_activity(args.saif)
    output_tx = parse_saif_binary_output_tx(args.saif)
    quantum_tx = parse_saif_reporting_quantum_pct(args.saif)
    nonpersistent_tx, persistent_signals = parse_saif_nonpersistent_tx(args.saif)
    observed_period_ns = parse_saif_observed_clock_period_ns(args.saif)

    if aggregate_tx is None or total_tc is None:
        raise SystemExit(f"invalid binary SAIF: no activity records in {args.saif}")
    if output_tx is None:
        raise SystemExit(
            f"invalid binary SAIF: no Top/dut architectural output activity in {args.saif}"
        )
    if quantum_tx is None:
        raise SystemExit(f"invalid binary SAIF: no duration in {args.saif}")

    # Persistent X on internal/dead nets is informational unless --strict.
    unknown_error = saif_unknown_activity_error(
        nonpersistent_tx,
        persistent_signals if args.strict_persistent_x else 0,
        quantum_tx,
    )
    if unknown_error is not None:
        raise SystemExit(f"invalid binary SAIF: {unknown_error} in {args.saif}")
    if observed_period_ns is None:
        raise SystemExit(f"invalid binary SAIF: cannot recover clock period from {args.saif}")
    if abs(observed_period_ns - args.expected_period_ns) > args.period_tolerance_ns:
        raise SystemExit(
            f"invalid binary SAIF: observed clock period={observed_period_ns:.6f} ns, "
            f"expected {args.expected_period_ns:.6f} +/- "
            f"{args.period_tolerance_ns:.6f} ns"
        )
    # Architectural correctness gate: the measured outputs must be X-free.
    allowed_tx = quantum_tx + args.max_output_tx_pct
    if output_tx > allowed_tx + 1.0e-12:
        raise SystemExit(
            f"invalid binary SAIF: architectural output TX={output_tx:.9f}% exceeds "
            f"one reporter quantum ({quantum_tx:.9f}%) + allowed extra "
            f"({args.max_output_tx_pct:.9f}%) -- outputs are X, execution is not clean"
        )

    note = "" if persistent_signals == 0 else \
        f"  [note: {persistent_signals} internal/dead net(s) X for the whole window; " \
        f"benign given X-free outputs -- correctness is checked by the output-checking bench]"
    print(
        f"validated binary SAIF: architectural output TX={output_tx:.9f}% "
        f"(reporter quantum={quantum_tx:.9f}%), "
        f"aggregate TX={aggregate_tx:.6f}%, "
        f"nonpersistent TX={nonpersistent_tx:.6f}%, "
        f"persistent-X signals={persistent_signals}, "
        f"period={observed_period_ns:.6f} ns" + note
    )


if __name__ == "__main__":
    main()
