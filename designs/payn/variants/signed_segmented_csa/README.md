# Signed segmented, carry-save lane interface

Exact, bit-identical variant of
[`signed_segmented_popcount`](../signed_segmented_popcount/README.md) that
removes the per-lane binary count and the per-lane two's-complement negate.

## Final routed results (2026-10-02)

The standard two-pass popcount campaign was used: distribution-guided
bootstrap APR, 384-batch full-library max-SDF activity, workload-driven
`spp_fixed` APR, final max-SDF GL with cosim and SAIF validation, and PT-PX
with extracted parasitics. The command was
`CAMPAIGN=pc16_20261002 bash sweeps/run_popcount_apr.sh csa`. Parameters
match the popcount arms: K8/M16/N8, LOW_W=9, T=128, A7 SVT C30 + HPK,
0.80 V, 400 MHz, 384 batches = 3,072 productive clocks = 25.6 GMAC/s.

| implementation | routed cell area (um2) | power (mW) | pJ/MAC | setup / hold WNS (ns) | GMAC/s/mm2 | combined vs baseline |
|---|---:|---:|---:|---:|---:|---:|
| cleaned baseline | 47,932.290 | 18.32650 | 0.715879 | +0.191 / +0.167 | 534.1 | 1.0000 |
| popcount, inferred | 46,459.546 | 17.80263 | 0.695415 | +0.087 / +0.185 | 551.0 | 1.0621 |
| popcount, library-mapped | 46,648.392 | 17.53869 | 0.685105 | +0.100 / +0.177 | 548.8 | 1.0737 |
| **carry-save lane interface** | **44,017.974** | **15.44682** | **0.603391** | **+0.146 / +0.193** | **581.6** | **1.2919** |

Against the library-mapped popcount point, this is **-5.64% area, -11.93%
power and +20.3% combined efficiency** (`(GMAC/s/mm2)/(pJ/MAC)`). Against the
cleaned baseline it is -8.17% area and -15.71% power.

The saving is inside the PE array:

| block | library-mapped popcount | carry-save |
|---|---:|---:|
| u_pe routed area (um2) | 31,885.966 | 29,255.548 (-8.25%) |
| u_pe power (mW, 3 s.f.) | 15.0 | 13.0 |
| peripheral power (mW) | 1.79 | 1.62 |
| Sobol banks (mW) | 0.732 | 0.715 |

The peripheral and Sobol areas match within 0.1%. Total GL transitions over
the 3,072-clock window are 119.1 M, versus 145.5 M (library-mapped) and
149.1 M (inferred). Operand-input transitions agree within 0.11%, so the
workload is the same. Removing the half-adder ripple, the per-lane negate and
the heap's sign-extension bits removes a large share of glitch propagation as
well as area. In a 4x4 PE grid, where the edge peripheral amortizes, a
composed estimate (16 x u_pe + 8 edge halves + one Sobol pair) gives about -7.5%
area and -13% power versus the library-mapped point. No grid has been routed.

Qualification, all passing:

- APR: geometry, antenna, connectivity and placement all zero; setup and hold
  non-negative.
- GL: zero SDF errors, bit-exact streaming drain, validated SAIF (accumulator
  X-free), zero post-reset timing violations. The 14 timing-check events all
  precede reset completion.
- PT-PX: zero default or unannotated activity nets, zero unannotated
  pin-to-pin parasitic nets.
- `python3 sweeps/report_popcount_apr.py --arm-dir csa=build/power_char/popcount_apr_20261002/csa --out build/power_char/popcount_apr_20261002/results.csv`
  re-qualifies all four rows from their saved evidence.

Two documented exceptions:

1. **Checkpoint repair, as for both popcount arms.** The first final route had 3
   geometry markers (two peripheral M6 wires, one tile VIA1 cut-spacing) and
   12 process-antenna violations on peripheral nets, with legal placement.
   `sweeps/repair_popcount_apr.sh` targeted mode closed them on the first
   attempt with no global reroute. Ordinary antenna cells went 337 -> 343 and
   area 44,016.798 -> 44,017.974 um2. The original layout is preserved under
   `before_legalization_*` in the route directory. See
   `build/power_char/popcount_apr_20261002/csa/final_apr_adoption.txt`.
2. **One clamped negative SDF delay.** VCS reported SDFCOM_NDI three times, all
   on `u_peripheral/U13281` (AOI211_X0P5M), whose COND IOPATH C0->Y fall delay
   is `(-0.007::-0.002)` ns. It was present before the repair. VCS clamps it to
   0 and cannot honor it even with `-negdelay` (that attempt reported
   SDFCOM_NIOD and was discarded). `validate_routed_gl.py` gained an opt-in
   `--approve-negative-iopath-clamp-ps`. It accepts NDI only when the cited
   SDF line is an IOPATH entry within the bound, and lists every clamp in
   `timing_qualification.json`. The run used 10 ps. The default validator
   behavior is unchanged, and the popcount arms still pass without the
   option. Rationale: `build/power_char/popcount_apr_20261002/csa/gl_validator_args_rationale.txt`.

Evidence: `build/power_char/popcount_apr_20261002/csa/` (stage logs,
`gl_bootstrap/`, `gl_final/`, `power_result/`, `result.csv`) and
`apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_fixed/`.

## Idea

The 11-FA popcount network ends in a four-half-adder ripple (ha0..ha3) that
turns five redundant bits into a binary count:

    count = s0a + s0b + 2*s1 + 4*s2 + 8*s3      (s0a=fs5, s0b=fs6, s1=fs9, s2=fs10, s3=fc10)

The five weights sum to exactly M = 16. So for lane negative flag n,

    n ? -count : count  =  sum_j (bit_j ^ n) * weight_j  -  16*n.

`PaynPopcount16Csa` stops before the ripple. Each lane feeds its five bits,
XOR'd with n, straight into the cross-K `DW02_tree`. One shared correction,
`-16 * countones(a_signs ^ w_signs)`, enters the heap once per tile. Signs are
held for a whole stochastic block, so that input does not toggle within a block.
Pending carry/borrow, the shared HIGH_W adder, canonical `acc_out` and the
drain are unchanged.

One PE-level change: the carry-save tile XORs the sign into the counter
bits, so an unknown sign is no longer masked by an empty lane. In the binary
form, `X ? -0 : 0` stays 0. The power bench's early `mac_en` edge reaches the
tiles before the resetless sign pipes are first loaded. The sign pipes
therefore get a synchronous reset. Any defined sign value already gives an
exact zero for an empty lane, so this matters only for 4-state and gate-level
simulation. It adds no flop area at synthesis.

## Verification (RTL, 2026-10-02)

| check | result | log |
|---|---|---|
| full K8/M16/N8 array vs `sc_kernel.py`, T=128, LOW_W=9 | PASS, all 64 outputs bit-exact | `build/rtl_preflight/ss_csa.log` |
| 384-batch streaming power bench vs `cosim_streaming.py` (signs reload every block) | PASS, bit-exact | `build/rtl_preflight/ss_csa_stream.log` |

Without the sign-pipe reset, the streaming bench drained all-X. The unmodified
popcount variant passes the same bench. That run is retained as
`syn/build/TSMC22/PAYN_SC_CSA/csa_20261002_aborted_unreset_signs`, a synthesis
run stopped when the problem was found.

## Matched synthesis (2026-10-02)

Target `TSMC22/PAYN_SC_CSA` uses the same knobs as
`PAYN_SC_POPCOUNT_INFERRED`: A7 SVT + HPK, 2.5 ns, 1.25 ns input delay,
clock gating, multibit. K8/M16/N8, LOW_W=9.

| arm | total um2 | u_pe um2 | one tile um2 | setup slack |
|---|---:|---:|---:|---:|
| cleaned baseline | 47,700.912 | 33,498.948 | 476.378 | +0.98 |
| popcount, inferred | 45,611.552 | 31,409.588 | 442.862 | +0.98 |
| popcount, library-mapped | 45,497.676 | 31,295.712 | 442.470 | +0.98 |
| **carry-save lane interface** | **43,454.964** | **29,253.000** | **408.170** | +0.93 |

Relative to the inferred popcount arm, the tile is 7.8% smaller, u_pe 6.9% and
the single-PE array 4.7%. Non-combinational area is identical. These are
synthesis numbers. The routed result above is larger: u_pe is 8.25% smaller
and the power saving was not predicted at synthesis.

Tile composition (`sweeps/pt_area_anatomy.tcl` on the synthesized netlists,
`build/area_anatomy/{csa,popcount_inferred}_syn_area_anatomy.rpt`):

| cells per tile | popcount inferred | carry-save |
|---|---:|---:|
| full adders | 149 | 149 |
| half adders | 36 (4 + inferred HA logic) | 11 |
| AND2 | 161 | 129 |
| XOR/XNOR | 42 | 51 |
| OA1B2 / NAND2 / NOR2 / OR3 / OAI21 / AOI2XB1 (negate + HA substitutes) | 96 | 4 |

The full-adder count is unchanged and is essentially the arithmetic floor:
128 product bits plus the 9-bit residue and correction must reduce to an 11-bit
sum, and each FA removes one bit. What remains per tile is 128 product ANDs,
about 40 sign XORs, 26 state flops plus a 24-bit drain mux, and the 15-bit
high-segment adder.

## Reproduce

```bash
SRC=designs/payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv
DEF=+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_csa+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128
VCS_PP='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'

BUILD_DIR=build/rtl_preflight/ss_csa SIM_SRCS=$SRC VCS_ARGS=$DEF \
  bash designs/payn/cosim/run_array.sh NTFY_CHNL= "VCS=$VCS_PP"
BUILD_DIR=build/rtl_preflight/ss_csa_stream SIM_SRCS=$SRC \
  bash designs/payn/cosim/run_power_array.sh NTFY_CHNL= "VCS=$VCS_PP" \
  VCS_ARGS="$DEF+define+SC_BATCHES=384"

RUN_NAME=<fresh_name> make synth TARGET=TSMC22/PAYN_SC_CSA NTFY_CHNL=
```

Load the six pinned EDA modules first. The power bench needs `-debug_access+pp`
for its SAIF calls.
