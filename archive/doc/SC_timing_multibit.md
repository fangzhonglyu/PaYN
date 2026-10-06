# PaYN SC timing, sizing, and multi-bit flops

This note uses the accepted K8.M16.8x8 row/column-guide implementation
`apr/build/TSMC22/PAYN_SC_SWEEP/k8m16n8_distguide` at 2.5 ns.  Its routed
T=128 power is 19.177 mW.

## Critical path

The worst routed setup path is from a W bit-pipe flop to bit 23 of a tile
accumulator.  Its 2.255 ns data arrival contains all of the following in one
cycle:

1. stochastic product formation;
2. lane popcount and signed reduction;
3. carry-save reduction with the old accumulator; and
4. the final 24-bit carry-propagate tail.

The final carry tail accounts for roughly the last 1 ns of the path.  The
remaining near-critical paths have the same structure: among the 999 paths in
`reports/setup.rpt`, 376 start at a W bit pipe and end at an accumulator and
358 start at an A bit pipe and end at an accumulator.  Final WNS is +0.279 ns.

## Drive-strength headroom is family-specific

The routed design has 64,774 leaf standard cells.  Of these, 88.37% are X1,
9.45% are X0P7, and 2.05% are X0P5.  The compute tiles are more constrained:
95.21% of their 34,425 leaf cells are X1.

The dominant tile arithmetic is mapped as follows:

| cell family | approximate instances in 64 tiles | routed choice | library minimum |
|---|---:|---:|---:|
| full adder | 9,536 | X1 | X1 |
| half adder | 3,840 | X1 | X1 |
| AND2 | 7,168 | X1 | X0P5 |
| AO22 | 3,072 | X1 | X0P5 |
| AO21/AOI21 and related | hundreds each | X1 | X0P5 |

Thus, X1 is genuinely the minimum only for the full- and half-adder families.
The critical path is dominated by a long chain of those minimum-size adders,
but the product and complex-gate logic does retain drive-strength headroom.  In
the single worst routed path, 29 full adders and one half adder are already X1;
only six other gates on that path have a smaller available drive.

Many X0P5/X0P7/X1 variants share the same physical footprint in this library;
their differences are drive, input capacitance, internal power, and leakage.
For example, X0P5 versus X1 reduces summed input capacitance by about 6% for
AND2, 13% for AO22, 22% for AOI21, and 27% for XNOR3.  Leakage is not uniformly
lower, so an X0P5 substitution is not automatically a total-power win.  The
routed design already downsized all synthesis X1P4 adders to X1, while leaving
AND2/AO21/AO22 at X1 and AOI22 at X0P7.

## Routed power by tile cell family

PrimeTime-PX with the accepted routed SPEF and T=128 SAIF attributes the
10.030 mW tile-combinational bucket as follows:

| family | count | internal (mW) | output-net switching (mW) | total (mW) |
|---|---:|---:|---:|---:|
| full adder | 9,536 | 3.376 | 2.863 | 6.279 |
| half adder | 3,840 | 0.867 | 0.475 | 1.352 |
| AO22 | 3,072 | 0.574 | 0.400 | 0.979 |
| AND2 | 7,168 | 0.404 | 0.427 | 0.841 |
| inverter | 4,232 | 0.072 | 0.163 | 0.238 |
| AOI21 | 512 | 0.027 | 0.054 | 0.082 |
| AO21 | 512 | 0.028 | 0.029 | 0.058 |
| remaining tile logic | - | - | - | 0.200 |

The minimum-X1 full and half adders consume 7.631 mW, or 76% of tile logic.
The families selected for a possible X0P7/X0P5 resize consume 2.264 mW, but
1.100 mW of that is output-net switching that a weaker driver does not remove.

An in-memory PrimeTime what-if resized 17,024 tile cells while preserving the
existing placement, SPEF, and SAIF:

| scenario | WNS (ns) | total power (mW) | change |
|---|---:|---:|---:|
| routed baseline | +0.292 | 19.177 | - |
| eligible X1 to X0P7 | +0.279 | 19.016 | -0.162 mW (-0.84%) |
| eligible X1/X0P7 to X0P5 | +0.259 | 18.919 | -0.258 mW (-1.35%) |

The X0P5 what-if has no max-transition or max-capacitance violations.  It is
not a routed ECO result, but it shows that the present design already has enough
margin for this direct downsizing; pipelining is not required to unlock it.

Routed transition rates also show real glitch opportunity.  Approximately 20%
of full-adder output pins and 28% of AO22 output pins toggle more than once per
cycle.  Counting only transitions beyond the one-per-cycle functional maximum
proves a substantial glitch component; weighting those excess-transition
fractions by each family's switching power estimates a 0.691 mW output-net
glitch opportunity.  This is not an achievable pipeline saving: both the
reduction stage and a ripple accumulator adder will still glitch.

## Multi-bit flop result

`TSMC22_HPK=1` is required in addition to `MULTIBIT_INFER=1`; the base library
does not contain the physically compatible two-bit flops.  A fresh K8.M16.8x8
synthesis (`k8m16n8_mbff`) gives:

| metric | single-bit baseline | HPK multi-bit | change |
|---|---:|---:|---:|
| banked register bits | 0 / 5,378 | 5,294 / 5,378 | 98.44% banked |
| physical flop cells | 5,378 | 2,731 | -49.2% |
| non-combinational area (um2) | 8,311.18 | 7,869.89 | -5.31% |
| total cell area (um2) | 47,848.70 | 47,391.53 | -0.96% |
| synthesis setup slack (ns) | +0.86 | +0.85 | effectively unchanged |

The DFFQA2W cell is 6.7% smaller than two DFFQA cells and has about 18% less
combined clock-pin capacitance.  The full post-synthesis functional cell-model
simulation matches `sc_kernel.py` bit-for-bit.  Routed clock-tree and power
benefits still need APR measurement.

The unannotated vendor timing model defaults to 1 ns path delays, so it must not
be used as a zero-delay functional model.  `ARM_UD_MODEL` is the appropriate
unit-delay branch for functional gate checking.  A post-synthesis SDF run with
timing checks disabled annotated without errors but retained X values at the
drain; therefore that mode is not accepted as signoff evidence.  Post-route SDF
with timing checks enabled remains the acceptance test.

## Pipeline assessment

The clean cut is after the signed per-cycle contribution and before the
output-stationary accumulator add:

```
products -> popcounts -> signed K-lane reduction -> delta register
                                                   |
old accumulator -------------------------------> 24-bit add -> accumulator
```

For K8.M16, one contribution is in [-128, +128], so the delta register needs
9 signed bits.  Across 64 tiles this adds 576 state bits, approximately 288
two-bit flops (about 790 um2 before clock-tree effects).  Throughput remains one
stochastic cycle per clock, but the MAC window needs one final flush cycle.

This cut should separate the two halves of the present critical path and is
likely to make a roughly 1.2--1.5 ns data path possible.  At the current 2.5 ns
period, however, the expected power mechanisms are limited to:

- stopping popcount/reduction glitches from propagating directly into the
  24-bit accumulator adder;
- enabling a faster clock for higher throughput; or
- creating margin for lower voltage or higher-Vt cells in a library/flow that
  supports those operating points.

Pipelining cannot downsize the dominant full- and half-adder chain below X1,
but it may allow thousands of product and complex gates to move from X1 to
X0P7/X0P5.  The likely gain is therefore limited rather than zero.  The
pipeline should be evaluated as a separate downsizing/glitch/voltage experiment
and accepted only if routed SAIF power repays the 576 extra clocked bits.  It
should not be merged on timing margin alone.

Scaling the existing 1.100 mW accumulator-register measurement by 576/1536
estimates about 0.413 mW for the new delta bits before multi-bit-flop savings and
incremental clock-tree routing.  With two-bit flops, a reasonable first-order
register-plus-clock estimate is 0.45--0.55 mW.  Therefore a pipeline must remove
at least 0.45--0.55 mW (4.5--5.5% of tile-combinational power) to beat the
non-pipelined X0P5 solution.  The measured glitch pool is large enough that this
is plausible, but not large enough to conclude that it will win analytically.
