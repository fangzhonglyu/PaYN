# Source-isolated signed segmented accumulator

This design point keeps the arithmetic state and pending carry/borrow recurrence
of `signed_segmented` unchanged.  Its only functional difference is the tile
output boundary:

```text
canonical_acc = {visible_high, acc_low}
acc_out       = shift_in ? canonical_acc : 0
```

The receiving tile uses `acc_in` only on a `shift_in` edge.  During ordinary
MAC cycles, continuously exporting `canonical_acc` therefore switches a long
bus whose value is functionally ignored.  Clamping at the source holds all 56
internal links of an 8x8 array—1,344 routed accumulator-chain bits—at zero.
Asserting `shift_in` makes the boundary transparent before the clock edge, so
the existing simultaneous row-serial drain operation is unchanged.

Unlike the accepted design, `acc_out` is intentionally not an observable
canonical accumulator while `shift_in=0`; it is a drain-only interface.  The
tile's private `canonical_acc` remains exact throughout computation.

## Synthesis preservation

A whole-PE optimizer can otherwise remove the clamp algebraically:

```text
shift_in ? (shift_in ? canonical_acc : 0) : mac_path
    == shift_in ? canonical_acc : mac_path
```

The clamp is therefore an explicit
`AccChainIsolationSignedSegmented` instance carrying the Synopsys
`dont_touch` and `keep_hierarchy` attributes.  Only this 24-bit boundary is
protected; the enclosing tile and accumulator remain free to flatten and
optimize.

Before accepting synthesis or power results, inspect the synthesized netlist
to confirm that every `u_acc_chain_isolation` instance remains at the tile
source.  A workload SAIF should also show zero compute-phase activity on
`g_row[*].acc_chain[1:N_W]`.  Results are invalid if the clamps were absorbed
into the receiving shift muxes.

## RTL validation

The equivalence test instantiates both the accepted pending design and this
variant as 2x4 PEs.  It checks:

- private canonical accumulator equality after every MAC;
- zero on every isolated chain link throughout compute;
- transparent equality immediately when `shift_in` asserts, without a flush
  clock;
- identical state and east outputs through repeated row drains;
- 9,216 extreme/random MAC cycles and 17 drain rounds.

Run it with the pinned EDA modules:

```sh
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
make sim TOP=Top USE_DW=1 \
  TB=designs/payn/tb/test_inner_pe_signed_segmented_isolated.sv
```

## Measured result

The clamp survived synthesis in all 64 tiles.  Synthesis was effectively
power-neutral versus the accepted pending design (+0.017%) but added 647 um2
(+1.32%).

The row/column-guided analysis route passed setup (+0.169 ns), hold
(+0.034 ns), antenna, connectivity, max-SDF output checking, and SAIF
validation.  It retained two geometry DRCs.  On the matched 3,072-cycle T=128
workload:

| design | area (um2) | total wire (um) | power (mW) | pJ/MAC |
|---|---:|---:|---:|---:|
| accepted pending control | 52,185 | 1,121,614 | 18.69109 | 0.730121 |
| source-isolated | 52,751 | 1,172,575 | 19.20351 | 0.750137 |

The source links are quiet during compute, but the isolation implementation
increases area 1.08%, routed wire 4.54%, and matched energy 2.74%.  It is
therefore a rejected analysis point; no DRC-cleaning ECO was justified.
