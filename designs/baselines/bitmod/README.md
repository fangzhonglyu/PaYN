# bitmod baseline (mixed-datatype bit-serial array)

Migrated from the `bitmod` repo (commit `5cb051c`, `src/{main,pe}.sv`,
`src/defs.svh`).  All 13 RTL modules are **byte-identical** to upstream; the only
changes are file organization and include guards.

## Why it is here

It is a third datatype point next to the binary and stochastic baselines: a
term-serial mixture-of-datatypes datapath (FP4/FP3, INT6, INT8 selected by
`mode`) with group-scaled floating accumulation, in place of a binary multiplier
or a stochastic popcount.

## File split

Upstream keeps everything in two files.  Gate-level simulation of the tile needs
the controller as an RTL stimulus source *while* `tile` comes from the netlist,
so the modules are split along their existing boundaries:

| file | modules | upstream source |
|---|---|---|
| `bitmod_defs.svh` | `tech_icg`, `cg_dreg`, `cg_rf`, types, LUTs | `src/defs.svh` |
| `bitmod_pe.sv` | `pe_scratch_common`, `pe_scratch`, `pe_scratch_with_control` | `src/pe.sv` |
| `bitmod_tile.sv` | `fpadd`, `tile` | `src/main.sv` |
| `bitmod_ctrl.sv` | `skid`, `fixed6_from_float4`, `controller`, `skew` | `src/main.sv` |
| `bitmod_array.sv` | `Raptor_Lake_HX` | `src/main.sv` |

To re-verify fidelity against a fresh upstream checkout, compare module bodies
rather than files — the split moves them but never edits them.

## Shape and throughput

Each PE consumes 4 K-lanes per element and an element takes `MODE+1` beats, so
per-PE throughput is `4/(MODE+1)` MAC/cycle:

| DUT | PEs | INT8 MAC/cycle | GMAC/s @400 MHz |
|---|---:|---:|---:|
| `tile` (`BITMOD_TILE`) | 8×8 = 64 | **64** | 25.6 |
| `Raptor_Lake_HX` (`BITMOD_ARRAY`) | 4×4 tiles = 1024 | **1024** | 409.6 |

`tile` is the throughput match for `BP_ARRAY` / `BOS_ARRAY` / `PAYN_SC`, which
also retire 64 MAC/cycle at 400 MHz.  At FP4/FP3 (`BITMOD_MODE=1`) an element
takes 2 beats instead of 4, so both figures double.

Both benches print the measured `MAC/cycle` in their PASS line rather than
assuming it, so the pJ/MAC denominator is taken from the run.

## Reading the two rows

`BITMOD_TILE` excludes operand decode: booth term generation, group-scale
distribution and skew live in `controller`/`skew`, which the tile bench
instantiates *outside* the toggle region as the stimulus source (exactly as
upstream's `tb_tile_power` does).  `BITMOD_ARRAY` includes all of it.  This is
the same array-only vs whole-design split PaYN reports as `SC_INNER_PE` vs
`PAYN_SC`, and the tile row must not be quoted as the design's energy.

## Known methodology asymmetry

The other power benches check their outputs cycle-by-cycle inside the SAIF
window.  These two do not: the tile accumulates in a 23-bit-mantissa / 6-bit-exp
float format whose reference model only closes for a restricted
±1.0-activation / 3-bit-weight encoding, which is a far lower-activity workload
and would not be a fair power stimulus.  The power benches therefore run
full-range random operands and assert (a) no X on any drain rail during the
window and (b) every drained accumulator defined and not all-zero.

Golden-value checking runs separately as the target's `RTL_PREFLIGHT_CMD`:
`tb/test_bitmod_tile.sv` ports upstream's `check_en` reference (±1.0
activations, 3-bit weights, integer group scales) and compares all 64
accumulators against an independent integer sum.  A functional regression
there blocks gate-level power measurement.  That stimulus is deliberately
low-activity, so it verifies correctness only — the power number still comes
from the full-range random workload.

## Startup

The design's documented contract is that a dummy `fin` group must be issued at
startup to zero the tile output buffers and PE accumulators.  The benches issue
it **twice**: the first pass zeroes the accumulators and the output-buffer RF but
leaves the drain output register holding the (still unknown) first read, and the
second pass pushes zeros through it.  Everything is flushed with real traffic —
no forced or deposited nodes, unlike upstream's GLS `$deposit` bind.
