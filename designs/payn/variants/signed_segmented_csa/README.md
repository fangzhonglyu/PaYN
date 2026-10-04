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

## Energy versus stochastic length (2026-10-03)

This sweep reuses the routed layouts with no new synthesis or APR, at every
multiple of 16 from T=16 to 128. The two comparison arms are the matched
cleaned baseline and the library-mapped popcount route.
`bash sweeps/run_csa_t_sweep.sh` gives every point the final-stage
qualification of the routed campaign:
- full-library max-SDF GL with `+neg_tchk +sdfverbose`;
- `validate_routed_gl.py`, with the same 10 ps IOPATH-clamp approval for
  carry-save only;
- a bit-exact streaming cosim and SAIF validation;
- PT-PX with extracted parasitics and full activity/parasitic coverage.

Each point runs through its own APR view directory, so the accepted reports
are untouched.

Each point runs 3,072 productive clocks. The exceptions are T=80 (614 x 5 =
3,070) and T=112 (439 x 7 = 3,073). Magnitudes and signs reload every T/16
clocks. All 24 points pass, with zero post-reset timing violations. The T=128
reruns reproduce the accepted powers exactly: 15.44682, 17.53869 and
18.3265 mW. The layouts were power-optimized with T=128 activity and are not
re-optimized for each T.

| T | MAC/cycle | GMAC/s/mm2 (carry-save) | carry-save mW | pJ/MAC baseline | pJ/MAC popcount | **pJ/MAC carry-save** | power vs baseline | array pJ/MAC (carry-save) | combined vs baseline |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 512.0 | 4,653 | 23.898 | 0.1348 | 0.1306 | **0.1167** | -13.42% | 0.0850 | 1.258 |
| 32 | 256.0 | 2,326 | 18.572 | 0.2121 | 0.2041 | **0.1814** | -14.48% | 0.1406 | 1.273 |
| 48 | 170.7 | 1,551 | 17.609 | 0.3032 | 0.2915 | **0.2579** | -14.93% | 0.2080 | 1.280 |
| 64 | 128.0 | 1,163 | 16.490 | 0.3799 | 0.3647 | **0.3221** | -15.23% | 0.2637 | 1.285 |
| 80 | 102.4 | 931 | 16.335 | 0.4712 | 0.4521 | **0.3988** | -15.37% | 0.3320 | 1.287 |
| 96 | 85.3 | 775 | 15.805 | 0.5481 | 0.5250 | **0.4630** | -15.51% | 0.3867 | 1.289 |
| 112 | 73.1 | 665 | 15.790 | 0.6395 | 0.6127 | **0.5397** | -15.61% | 0.4546 | 1.290 |
| 128 | 64.0 | 582 | 15.447 | 0.7159 | 0.6851 | **0.6034** | -15.71% | 0.5078 | 1.292 |

Column definitions:
- **pJ/MAC** is full-design power x 2.5 ns / (8192/T).
- **array pJ/MAC** uses the `u_pe` hierarchy power, which has 3 significant
  figures.
- **combined** is `(GMAC/s/mm2)/(pJ/MAC)` relative to the baseline at the
  same T.

Per-arm rows, with the internal/switching/leakage split and the peripheral and
Sobol powers, are in `build/power_char/csa_t_sweep_20261003/results.csv`.

Reading it:
- **The carry-save saving holds at every T.** The `u_pe` power saving versus
  the popcount route is flat at -12.6% to -13.3%. The full-design saving
  versus the baseline narrows from -15.7% at T=128 to -13.4% at T=16. The
  peripheral is the same in all three designs and becomes a larger share of
  power as reloads speed up: 1.62 -> 5.65 mW for carry-save over T=128 -> 16.
- **Carry-save is the lowest-energy point at every T.** At T=16 the PE array
  is 0.085 pJ/MAC and the full design 0.117 pJ/MAC.
- **Non-power-of-two T/16 slows the power decline, identically in all
  arms.** At T=112, power equals T=96 within 0.1%, and T=80 is only 0.9% below
  T=64. The GL operand toggle count rises with it, for example 25.92 M at T=96
  versus 26.01 M at T=112 for carry-save. So it is a property of the
  stochastic workload at those block lengths, not of any one design.
  Energy per MAC still falls with T at every step.
- These are drain-excluded energies. Below T=64 the 8-clock row-serial drain
  cannot keep up with block completion (see `doc/results.md`, "Routed power
  versus stochastic length").

## M=8 shapes (2026-10-03)

The tile also supports M=8. `PaynPopcount8Csa` uses four full adders, which
leave the count in four redundant bits with weights 1, 1, 2 and 4. Those
weights sum to 8, so a negative lane needs four XORs plus one shared
`-8 * negatives` heap row. The M=16 path elaborates to identical logic; only
its counter now sits one generate scope deeper (`g_lanes[i].g_m16.u_popcount`).

RTL checks (`sweeps/run_csa_shape_rtl_checks.sh`), all passing:
- the M=8 counter, exhaustively over all 256 inputs;
- K8M8N8, K12M8N8 and K16M8N8 against `sc_kernel.py` and in the streaming
  power bench;
- K8M16N8, rechecked.

Each shape was synthesized and routed with the same two-pass recipe as M=16
(`CAMPAIGN=csa_20261003 bash sweeps/run_popcount_apr.sh csa_k8m8n8 csa_k12m8n8 csa_k16m8n8`),
at T=128 and 3,072 productive clocks. The matched clean-baseline M=8 routes
from the K x M x N sweep were re-measured with full-timing GL (`run_csa_t_sweep.sh`
arms `control_k8m8n8` and `control_k12m8n8`). They reproduce the sweep's
numbers exactly. The 4x4 composite is 16 x u_pe + 4 peripherals + one Sobol
pair, with powers taken from each route's hierarchy report.

| design | MAC/cycle | routed um2 | mW | GMAC/s/mm2 | pJ/MAC | 4x4 GMAC/s/mm2 | 4x4 pJ/MAC | combined vs CSA M16 (1 PE / 4x4) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **CSA K8M16N8** | 64 | 44,018.0 | 15.447 | **581.6** | **0.6034** | **784.8** | **0.5254** | 1.000 / 1.000 |
| CSA K16M8N8 | 64 | 47,302.4 | 16.373 | 541.2 | 0.6396 | 723.4 | 0.5811 | 0.878 / 0.833 |
| CSA K12M8N8 | 48 | 37,267.1 | 12.309 | 515.2 | 0.6411 | 682.8 | 0.5772 | 0.834 / 0.792 |
| CSA K8M8N8 | 32 | 27,393.5 | 8.890 | 467.3 | 0.6945 | 608.8 | 0.6219 | 0.698 / 0.655 |
| clean K8M16N8 | 64 | 47,932.3 | 18.327 | 534.1 | 0.7159 | 700.5 | 0.6355 | 0.774 / 0.738 |
| clean K12M8N8 | 48 | 41,906.7 | 14.875 | 458.2 | 0.7748 | 586.3 | 0.7171 | 0.614 / 0.547 |
| clean K8M8N8 | 32 | 30,218.5 | 10.130 | 423.6 | 0.7914 | 536.9 | 0.7234 | 0.555 / 0.497 |

Reading it:
- **M=8 lags M=16 at every shape.** The best M=8 point, K16M8N8, has the
  same 128 ANDs per tile and the same throughput. It is -6.9% in area
  efficiency and +6.0% in energy on one PE, and -7.8% / +10.6% on a 4x4 grid.
  The gap widens on the grid because the edge amortizes and the per-tile gap
  remains: u_pe area per MAC/cycle is 494.6 versus 457.1 um2 (+8.2%), and u_pe
  energy is 0.566 versus 0.508 pJ/MAC.
- **Why.** Halving M halves the bits each lane counter compresses. Lane
  overhead does not shrink: two heap rows, the sign XORs and sign glue per lane
  (the heap grows from 18 to 34 rows at K16), and the per-tile accumulator,
  high adder and drain mux, the same at every M. The four-FA M=8 counter is
  efficient, but the reduction work moves into the larger heap.
- **The carry-save gain is larger at M=8.** Against the matched clean routes
  it is -9.3% area and -12.2% power at K8M8N8, and -11.1% / -17.3% at K12M8N8,
  versus -8.2% / -15.7% at K8M16N8. CSA K16M8N8 even edges out the clean
  K8M16N8 baseline: +1.3% area efficiency on one PE and +3.3% on 4x4, with
  -10.7% energy.

**Iso-T with the ceiling.** M=16 runs ceil(T/16) clocks per block and M=8
runs ceil(T/8), so M=8 avoids padding when T is an odd multiple of 8.
K16M8N8 was re-measured on its routed layout at every multiple of 8 from 16
to 128 (`run_csa_t_sweep.sh` arm `csa_k16m8n8`; all 15 points pass, with
`--approve-annotated-interconnect`). Padded M=16 is charged the measured power
of 16*ceil(T/16). The padded-T study found padded power within +-1-3% of that,
including a ~1% mask tax that is not added here, so M=16 is favored by about
1%. 4x4 energy uses the composite power (16 x u_pe + 4 peripherals + Sobol).

| T | 16 | 24 | 32 | 40 | 48 | 56 | 64 | 72 | 80 | 88 | 96 | 104 | 112 | 120 | 128 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4x4 area eff., M8/M16 | 0.92 | **1.23** | 0.92 | **1.11** | 0.92 | **1.05** | 0.92 | **1.02** | 0.92 | 1.01 | 0.92 | 0.99 | 0.92 | 0.98 | 0.92 |
| 4x4 energy, M8/M16 | 0.97 | 0.86 | 1.07 | 0.91 | 1.06 | 0.97 | 1.09 | 0.98 | 1.08 | 1.02 | 1.10 | 1.02 | 1.09 | 1.05 | 1.11 |
| 4x4 combined, M8/M16 | 0.95 | **1.43** | 0.86 | **1.21** | 0.87 | **1.08** | 0.85 | **1.04** | 0.86 | 0.99 | 0.84 | 0.98 | 0.85 | 0.94 | 0.83 |

On one PE, M=8's smaller edge helps: half the Sobol lanes and fewer comparator
updates per MAC. That gives it lower energy at T=16 (0.1056 versus 0.1167
pJ/MAC). On a grid the edge is shared, and M=8's 9-11% costlier PE array
dominates. **M=8 pays off only for a model-fixed T of 24, 40, 56 or 72.** At
T=88-120 the padding saving no longer covers the regression. At any multiple
of 16, including T=128, M=16 is 13-17% better combined.
Data: `build/power_char/popcount_apr_csa_20261003/m8_vs_m16_vs_T.csv`.

Qualification, all three routes:
- APR: geometry, antenna, connectivity and placement zero; setup/hold
  +0.210/+0.138 (K8), +0.066/+0.167 (K12) and +0.099/+0.168 ns (K16).
- GL: max-SDF with `+neg_tchk`, bit-exact streaming drain, validated SAIF,
  zero post-reset timing violations.
- PT-PX: full activity and parasitic coverage.

Exceptions, each documented beside the run:
1. **Targeted checkpoint repair**, as on every popcount and CSA route. K8 had
   5 antenna violations; K12 and K16 had 1 geometry marker and 2 antenna
   violations each. K8 and K12 closed on the first attempt. K16 needed a
   second attempt, because its antenna violations moved to two other sinks of
   the same peripheral net. Records are in each arm's
   `final_apr_adoption.txt`, and the original layouts are under
   `before_legalization_*`.
2. **Two opt-in validator approvals** (`build/power_char/popcount_apr_csa_20261003/gl_validator_args_rationale.txt`):
   - `--approve-annotated-interconnect`, new, covers SDFCOM_IWSBA: K8 x5 and
     K16 x12. Innovus wrote `assign` aliases on Sobol output nets, and VCS
     states that the INTERCONNECT is still annotated.
   - The existing `--approve-negative-iopath-clamp-ps 10` covers one -1 ps
     IOPATH on K8.

   K12 needs neither. Default validator behavior is unchanged.

Evidence: `build/power_char/popcount_apr_csa_20261003/` (per-arm stage logs,
`result.csv`, `m8_vs_m16.csv`, `results_requalified.csv` from
`report_popcount_apr.py`).

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
