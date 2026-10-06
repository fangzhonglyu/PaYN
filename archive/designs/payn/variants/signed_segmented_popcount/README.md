# Signed segmented popcount experiment

This isolated variant starts from `signed_segmented_clean` and replaces only
the unsigned M=16 population count in each K lane. The counter uses 11 full
adders and 4 half adders. Product ANDs, sign handling, cross-K reduction,
segmented accumulator, pipeline registers, Sobol generation and array ports
retain the cleaned baseline implementation. Other M values retain `$countones`.

The top is `payn_array_signed_segmented_popcount`. The copied hierarchy retains
`u_pe/u_array_core/g_row.../g_col.../u_inner`, its architectural state names and
all packed/unpacked ports. Each lane adds a named `u_popcount` child for the
technology mapping preservation hook.

## Final routed results (2026-10-01)

Both new implementations completed placement/routing, targeted physical
cleanup, full-library max-SDF simulation, independent output comparison,
SAIF validation, and PrimeTime-PX with extracted wire parasitics. Parameters:
**K=8, M=16, N_H=N_W=8, WIDTH=8, OWIDTH=24, LOW_W=9, T=128**, A7 SVT
C30 + HPK, **0.80 V, 400 MHz**. The workload is 384 back-to-back batches,
3,072 productive clocks, and 25.6 GMAC/s. The existing cleaned baseline layout
was reused and remeasured; it was not rerouted.

| implementation | routed cell area (um2) | power (mW) | pJ/MAC | setup / hold WNS (ns) | combined efficiency vs baseline |
|---|---:|---:|---:|---:|---:|
| cleaned baseline | 47,932.290 | 18.32650 | 0.715879 | +0.191 / +0.167 | 1.0000 |
| new inferred counter | 46,459.546 | 17.80263 | 0.695415 | +0.087 / +0.185 | 1.0621 |
| **new preserved library mapping** | **46,648.392** | **17.53869** | **0.685105** | **+0.100 / +0.177** | **1.0737** |

The mapped implementation is the new energy and combined-efficiency winner
among the recorded T128/400 MHz PaYN points: **4.30% lower power, 2.68% less
cell area, and 7.37% higher combined efficiency** than the matched cleaned
baseline. The inferred implementation is slightly smaller (3.07% below the
baseline) but saves only 2.86% power. The earlier approximately 20% savings
were pre-layout estimates and do not describe these routed results.

Combined efficiency means compute density times energy efficiency,
`(GMAC/s/mm2) / (pJ/MAC)`. For these equal-throughput arrays it is proportional
to `1 / (area * power)`. Across the broader recorded grid, the highest compute
density remains the cleaned **K12/M16/N10** point at 615.009 GMAC/s/mm2.
The previous combined winner was cleaned K8/M16/N10; the mapped K8/M16/N8
point now exceeds its combined score by approximately 2.95%. This is the best
**measured** point, not a proof of the global optimum; the new counter has not
been swept over K/N yet.

All final geometry, antenna, connectivity and placement checks are zero, and
both designs meet setup and hold. Each repaired layout passed its 384-batch
full-timing reference comparison with no post-reset timing violations and
zero SDF errors. The 192 SDF warnings are the enumerated boundary-output
UHICD warnings with DEVICE-delay fallback. All activity is file-annotated or
explicitly static on pinless nets; there are zero default/unannotated activity
nets and zero unannotated pin-to-pin parasitic nets.

The completed first final layouts required localized physical repair. Filler
congestion prevented antenna-diode insertion, so the repair opened small
filler regions and rerouted the specifically diagnosed geometry nets from
saved final checkpoints. Post-route via swapping was disabled for the repair.
Original layouts, reports and failed script attempts remain archived within
each run. Fresh SDF, netlist, SPEF, activity and power were generated afterward.

Final evidence:

- `build/power_char/popcount_apr_20260930/results.csv`: fully qualified matched comparison.
- `build/power_char/popcount_apr_20260930/ranked_area_energy_points.csv`: updated recorded-grid ranking.
- `build/power_char/popcount_apr_20260930/efficiency_winners.json`: energy, area-efficiency and combined winners.
- `apr/build/TSMC22/PAYN_SC_POPCOUNT_INFERRED/pc16_20260930_inferred_distguide_spp_fixed/`.
- `apr/build/TSMC22/PAYN_SC_POPCOUNT_TECHMAP/pc16_20260930_techmap_distguide_spp_fixed/`.

The updated ranking excludes the historical K=1 or M=1 low-corner campaign: its no-guide recipe differs, and later points used unit-delay models. Excluded rows remain in `excluded_historical_low_corner_points.csv` beside the new ranking.

The final activity mechanism section below explains the observed switching
changes. The historical synthesis and bootstrap sections remain stage-labeled;
the final mapped implementation wins even though bootstrap activity favored
the inferred implementation.

## Mapping modes

- Default: infer the FA/HA compressor operations from RTL; synthesis may rewrite
  the network and absorb neighboring logic.
- `PAYN_POPCOUNT_TECHMAP` together with `SYNTHESIS`: instantiate
  `ADDF_X1M_A7PP140ZTS_C30` and `ADDH_X1M_A7PP140ZTS_C30`. The dedicated target
  preserves these exact cells to measure this library topology.
- `PAYN_POPCOUNT_TECHMAP` without `SYNTHESIS`: use equivalent behavioral logic
  for ordinary RTL simulation. This alone does not validate cell model wiring.

These are alternative implementations of one design, not changes to the
accepted or cleaned baseline. Nominal counter area is 22.246 um2 per lane
(11 x 1.666 + 4 x 0.980), before its 16 product ANDs and physical repair.
Real area, timing and energy require synthesis and implementation measurements.

## Verification and reproduction

Load the exact environment before running EDA commands:

```bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
PAYN_VCS='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
```

The new `designs/payn/tb/test_popcount16.sv` checks all 65,536 input patterns
against `$countones`, as well as the M=16 wrapper and M=8/M=1 fallback paths.

```bash
make sim TOP=Top TB=designs/payn/tb/test_popcount16.sv \
  BUILD_DIR=build/rtl_preflight/popcount16_inferred NTFY_CHNL= "VCS=$PAYN_VCS"
make sim TOP=Top TB=designs/payn/tb/test_popcount16.sv \
  BUILD_DIR=build/rtl_preflight/popcount16_techmap_rtl \
  VCS_ARGS=+define+PAYN_POPCOUNT_TECHMAP NTFY_CHNL= "VCS=$PAYN_VCS"
```

The existing bit-exact model comparison exercises the full K8/M16/N8 array,
T=128, OWIDTH=24, LOW_W=9:

```bash
BUILD_DIR=build/rtl_preflight/ss_popcount_inferred \
SIM_SRCS=designs/payn/variants/signed_segmented_popcount/payn_array_signed_segmented_popcount.sv \
VCS_ARGS=+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_popcount+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128 \
  bash designs/payn/cosim/run_array.sh NTFY_CHNL= "VCS=$PAYN_VCS"
```

Repeat with `BUILD_DIR=build/rtl_preflight/ss_popcount_techmap_rtl` and prepend
`+define+PAYN_POPCOUNT_TECHMAP` to `VCS_ARGS` for the alternate RTL mode.
The explicit-cell branch is checked against the actual A7 C30 model:

```bash
make sim TOP=Top TB=designs/payn/tb/test_popcount16.sv \
  BUILD_DIR=build/rtl_preflight/popcount16_techmap_cells \
  SIM_SRCS=/afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/sc7mcpp140z_base_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_base_svt_c30.v \
  VCS_ARGS=+define+PAYN_POPCOUNT_TECHMAP+define+SYNTHESIS+define+TETRAMAX+define+ARM_UD_MODEL \
  NTFY_CHNL= "VCS=$PAYN_VCS"
```

`ARM_UD_MODEL` supplies 1 ps propagation delay per combinational cell; the
counter test samples after 1 ns. This is a functional test, not timing
signoff. The VCS override omits optional `-debug_access+all`, whose
`cfs_ident_exec` database extraction stalled on this host; xprop and assertions
remain enabled.

Results on 2026-09-30 (all process exit codes zero):

| Check | Result | Log under `build/rtl_preflight/` |
|---|---|---|
| Exhaustive inferred counter, wrapper and fallback paths | PASS, 65,536 patterns | `popcount16_inferred/run.log` |
| Exhaustive techmap-select behavioral RTL | PASS, 65,536 patterns | `popcount16_techmap_rtl/run.log` |
| Exhaustive explicit A7 cell branch | PASS, 65,536 patterns | `popcount16_techmap_cells/run.log` |
| Full inferred array vs `sc_kernel.py` | PASS, all 64 outputs bit-exact | `ss_popcount_inferred/run.log` |
| Full techmap-select behavioral array vs `sc_kernel.py` | PASS, all 64 outputs bit-exact | `ss_popcount_techmap_rtl/run.log` |

Synthesis and routed results must be treated separately from functional checks.

## Matched synthesis campaign

The PaYN Makefile delegates to the sibling `/home/barrylyu/repos/ASTRAEA`
checkout. The campaign keeps K8/M16/N8, LOW_W9, WIDTH8/OWIDTH24, 2.5 ns,
INPUT_DELAY=1.25 ns, A7 SVT C30 plus HPK, clock gating and multibit inference
fixed. The unchanged cleaned array is synthesized again as the control.

```bash
bash sweeps/run_popcount_synth.sh control inferred techmap
python3 sweeps/report_popcount_synth.py
bash sweeps/check_popcount_syn.sh control inferred techmap
```

Each synthesis arm has a separate target/run directory. The drivers refuse
existing runs/logs; set `CAMPAIGN=pc16_<new_tag>` for a fresh campaign and use
`--prefix pc16_<new_tag>` when reporting it. The optional
`SKIP_PREFLIGHT=1` requires the same sources/settings to have already passed
RTL preflight. The gate checker runs 64 back-to-back stochastic batches and
checks every drained output against the independent streaming model.
Its no-SDF unit-delay simulation is functional verification only.

Targets are `PAYN_SC_SIGNED_SEGMENTED_CLEAN` (control),
`PAYN_SC_POPCOUNT_INFERRED`, and `PAYN_SC_POPCOUNT_TECHMAP`.
The techmap hook requires exactly 11 FA and 4 HA per counter before compile;
it does not preserve the rest of the array. Generated-block names require
matching the `u_popcount` token rather than a literal `/u_popcount/` path.
The first 2026-09-30 techmap attempt stopped at this selector check and is
retained as `pc16_20260930_techmap_failed_selector`.

Synthesis default-activity power is not a replacement for routed,
workload-annotated energy. No energy improvement is implied by an area result.

The arithmetic counter propagates unknown input bits in four-state simulation,
whereas `$countones` counts known ones. Binary-input behavior is equivalent;
the existing reset and MAC-enable prologue must keep uninitialized operand
pipes from updating architectural state.

## 2026-09-30 synthesis results

Fresh matched full-array runs through ASTRAEA, under the settings above:

| arm | cell area (um2) | change vs control | setup slack (ns) | counter FA / HA cells |
|---|---:|---:|---:|---:|
| unchanged cleaned control | 47,700.912 | — | +0.980 | baseline inline popcounts |
| inferred 11-FA/4-HA network | 45,611.552 | -4.380% | +0.980 | 5,632 / 0 |
| preserved A7 library mapping | 45,497.676 | -4.619% | +0.980 | 5,632 / 2,048 |

The inferred arm implements its half-adder functions with other gates; zero
`ADDH` cells inside its counters does not mean those functions disappeared.
Both alternatives retain 2,583 two-bit flop cells. The explicit mapping is
only 0.250% smaller than the inferred arm, so the main gain comes from the
counter topology. These are synthesis cell areas and pre-layout timing;
the completed routed measurements are reported near the top of this document.

Reports are in `syn/build/TSMC22/<target>/pc16_20260930_<arm>/`.
The machine-readable comparison is
`build/power_char/popcount_synth_20260930/results.csv`.

Post-synthesis functional verification also passed for **all three arms**:
each vendor-cell netlist processed 64 back-to-back T=128 batches and all
64 drained outputs matched `cosim_streaming.py`. The generated SDCs were
checked to have identical 2.5 ns clocks, 1.25 ns input delays and 0.05 ns
output delays. Per-arm manifests, logs, traces and `check.status` files are
under `build/power_char/popcount_synth_20260930/<arm>_syn_functional/` (logs
are adjacent). `validation.json` records the combined verification status.

## Matched pre-layout workload power

On 2026-09-30, ASTRAEA's existing `make power` DC flow annotated each
synthesized netlist with its own validated gate-level SAIF. All three operand
and drain traces are identical: 64 back-to-back batches, 512 productive
clocks, K8/M16/N8, T128, 400 MHz. Nets, ports and pins each report 100% SAIF
annotation; accumulator unknown time is zero.

| arm | estimated power (mW) | change | estimated pJ/MAC |
|---|---:|---:|---:|
| cleaned control | 16.11621 | — | 0.629539 |
| inferred counter | 12.94255 | -19.692% | 0.505568 |
| preserved A7 mapping | 13.16885 | -18.288% | 0.514408 |

The compute-array hierarchy accounts for essentially the entire reduction:
14.749 mW becomes 11.575 mW (inferred) or 11.801 mW (techmap). The peripheral
and combined Sobol banks stay at 0.865 and 0.439 mW, respectively, at the
hierarchy report's precision. Internal and switching power dominate the
saving; the leakage changes are small.

These are **pre-layout estimates**, using unit-delay activity, a zero wire-load
model and ASTRAEA's existing pre-CTS ICG output-load override. There are no
routed parasitics or clock tree. The figures establish a synthesis-level
trend, not an accepted routed energy improvement. PrimeTime attempts stalled
while loading its AFS executable and were stopped before producing results;
the table above is solely the completed DC comparison.

```bash
bash sweeps/run_popcount_dc_power.sh
python3 sweeps/report_popcount_syn_power.py
```

Reports, complete coverage tables and the CSV comparison are under
`build/power_char/popcount_dc_power_20260930/`. The driver refuses existing
annotated reports; use a fresh synthesis campaign for a new measurement.

## Why the pre-layout power estimate improves

The counter restructuring reduces activity as well as gate count. The two
implementations consume the same registered stochastic samples and signs;
all observed accumulator Q transition counts match. A leaf-driver-only SAIF
analysis (one parent-net lookup per physical output pin, with hierarchy aliases
excluded) gives the following inferred-versus-control changes over the same
512 clocks:

| observation | control transitions | inferred transitions | change |
|---|---:|---:|---:|
| 5,632 counter FAs, both S and CO outputs | 2,602,773 | 1,955,968 | -24.85% |
| 3,008 cross-K/low-reduction FAs, both outputs | 6,027,582 | 4,853,948 | -19.47% |
| low-accumulator D inputs | 1,145,625 | 979,479 | -14.50% |
| low-accumulator Q outputs | 105,406 | 105,406 | 0% |

The conservative downstream-FA transition excess beyond one transition per
pin per clock falls from 3,180,599 to 2,146,351 (-32.52%). This supports reduced
transient evaluation, but the remaining activity difference also includes
changed internal Boolean functions and cell mapping. SAIF IG values are zero;
these figures are not a direct measurement of routed glitch energy.

Synthesis also chooses fewer X1.4 adders. An isolated in-memory DC experiment
normalizing every full/half adder to X1 reproduces the original estimates
before changing references, then gives 15.783995 mW for control and
12.868674 mW for inferred (-18.47%). Thus most of the original -19.69% power
advantage remains when adder sizes are matched. This sensitivity experiment
preserves the unit-delay activity and does not modify the synthesized netlists
or qualify timing. It is not an additive attribution of physical power.

Detailed evidence and the reproducible analysis are under
`build/power_char/popcount_mechanism_20260930/`, including `report.txt`,
`fa_activity_summary.csv`, `references.csv`, and `sizing_whatif/results.csv`.
`mechanism.png` / `mechanism.pdf` visualize the activity and estimated power.

## Routed campaign

```bash
bash sweeps/run_popcount_apr.sh inferred techmap
python3 sweeps/report_popcount_apr.py
```

The new variants use guided bootstrap APR, 384-batch routed max-SDF activity,
and a second workload-driven `spp_fixed` APR pass. Final results require
setup/hold closure, clean geometry/connectivity/antenna checks, routed cosim,
validated SAIF and PrimeTime-PX. The matched clean routed control is reused:
its input Verilog tokens and SDC commands are identical to the fresh control,
and an isolated PT-PX rerun reproduced 18.32650 mW without changing accepted
artifacts. Campaign outputs are under
`build/power_char/popcount_apr_20260930/`.

Routed activity must use the library's full timing models and `+neg_tchk`.
Do **not** define `ARM_UD_MODEL` for routed power: the A7 base and HPK
unit-delay branches have no `specify` blocks, so SDF cannot annotate their
cell paths or timing checks. The first techmap bootstrap simulation used this
mode and is retained as a rejected, functional-only attempt. Removing that
define reduced SDF annotation warnings from 438,669 to 192 (zero errors).
`ARM_EN_X_SQUASH` is also omitted from the corrected routed simulations.
This does not change the explicitly unit-delay synthesis power comparison
above. The saved baseline layout was simulated again with matching full timing
models and passed all checks. The corrected PT-PX measurement reproduced
18.32650 mW exactly; see `control_power/full_timing/summary.json` under the
campaign directory.

`sweeps/validate_routed_gl.py` requires zero SDF annotation errors, complete
warning details, and only the known UHICD hierarchy-output warning with its
DEVICE-delay fallback. Timing violations are recorded individually. Only
startup events strictly before the bench's reset-complete timestamp are
permitted; later violations fail qualification. Independent output cosim and
SAIF checks still have to pass. The corrected baseline's measured transition
totals exactly match its historical activity; its two startup timing events
occur before reset completes and outside the measured workload.

## Provisional routed activity mechanism audit

The qualified **full-library, max-SDF** simulations now provide a provisional
activity comparison over 384 T128 batches (3,072 compute clocks). The control
is the **existing cleaned final layout**
`k8m16n8_lw9_id125_distguide_spp_fixed`; the alternatives are the new
`pc16_20260930_<arm>_distguide` **bootstrap layouts**, before the final
workload-driven route. These stage differences are intentional and must remain
visible when citing the comparison. This is not a final power measurement or
an acceptance of the bootstrap physical diagnostics.

| observation | cleaned final control | inferred bootstrap | change | techmap bootstrap | change |
|---|---:|---:|---:|---:|---:|
| 5,632 counter FAs, both S and CO transitions | 14,040,097 | 12,065,635 | -14.06% | 13,530,901 | -3.63% |
| 3,008 cross-K/low-reduction FAs, both outputs | 22,329,090 | 21,015,181 | -5.88% | 23,600,483 | +5.69% |
| low-accumulator D transitions | 4,117,464 | 3,773,314 | -8.36% | 4,319,256 | +4.90% |
| low-accumulator Q transitions | 630,879 | 630,879 | 0% | 630,879 | 0% |

All tile stochastic-input and sign-input transition totals, and all 1,664
accumulator/pending Q-output totals, match across the three simulations.
Every counter and downstream FA/HA is already **X1** in these routed netlists;
the synthesis adder-sizing advantage is absent from this comparison.
Each reported FA output is counted once from its physical leaf driver; S and
CO are both included, with no hierarchy-alias duplication or missing compute
output annotations.

The inferred network still reduces activity under the actual routed delays,
but its advantage is smaller than the earlier unit-delay estimate. The
techmapped bootstrap produces **more downstream and accumulator-D activity**
than the cleaned final control. Thus the synthesis power saving must not be
carried forward as a routed result. The changed counter arrival times and
following logic produce different transient behavior; transition counts alone
do not determine capacitance-weighted power. Final-layout activity and PT-PX
remain the decision criteria.

The full-timing profile uses the corrected baseline SAIF in
`build/power_char/popcount_apr_20260930/control_power/full_timing/gl/` and the
new arms' qualified `gl_bootstrap/` SAIFs. Both new simulations passed the
routed timing-log validator with zero SDF errors and zero post-reset timing
violations; independent output cosimulation also passed. Rejected unit-delay
bootstrap artifacts are excluded. The earlier synthesis profile remains
separate: fresh synthesis netlists, 64 batches, and unit-delay models.
Comparing percentages between profiles is not an isolated experiment on delay
models because the netlists, physical stages, and workload lengths also differ.

Reproduce the activity audit and compact comparison plot without running EDA:

```bash
python3 build/power_char/popcount_mechanism_20260930/analyze_routed.py --stage bootstrap
python3 build/power_char/popcount_mechanism_20260930/plot_routed.py --stage bootstrap
```

Outputs are in `build/power_char/popcount_mechanism_20260930/routed_bootstrap/`:
`fa_activity_summary.csv`, `boundaries.csv`, `references.csv`, per-driver CSVs,
source paths in `results.json`, and `mechanism_comparison.png` / `.pdf`.
After qualified `gl_final/` activity is available, `--stage final` reads the
corresponding `*_distguide_spp_fixed` netlists and writes a separate
`routed_final/` profile without replacing either earlier analysis.

## Final routed activity mechanism audit

The final mechanism profile uses the **repaired, physically qualified final
layouts** `pc16_20260930_<arm>_distguide_spp_fixed` and their qualified
`gl_final/` simulations. The control remains the existing cleaned final layout
`k8m16n8_lw9_id125_distguide_spp_fixed`, simulated with matching full library
models. All three profiles cover 384 T128 batches, 3,072 compute clocks at
400 MHz, with routed max-SDF delays and timing checks enabled. This section
reports activity; final area and PrimeTime-PX power are reported separately.

| observation | cleaned final control | inferred final | change | techmap final | change |
|---|---:|---:|---:|---:|---:|
| 5,632 counter FAs, both S and CO transitions | 14,040,097 | 12,533,301 | -10.73% | 12,303,285 | -12.37% |
| 3,008 cross-K/low-reduction FAs, both outputs | 22,329,090 | 22,849,740 | +2.33% | 20,857,718 | -6.59% |
| low-accumulator D transitions | 4,117,464 | 4,195,146 | +1.89% | 3,883,597 | -5.68% |
| low-accumulator Q transitions | 630,879 | 630,879 | 0% | 630,879 | 0% |

The per-pin check compares all **19,072 corresponding tile input and state-Q
pins** and finds zero transition-count differences, with no missing pins.
All counter and downstream full/half adders are X1 in all three final
netlists. Each full adder contributes both outputs exactly once, and every
queried compute output has activity annotation. The observed combinational
activity changes therefore occur with identical useful input/state activity
and equal adder drive strengths.

The final routes preserve lower activity inside both new unsigned counters.
However, **the downstream result differs from the bootstrap**: techmap now
reduces reduction-tree and low-accumulator-D activity, while inferred increases
both slightly. Pending carry/borrow D activity also increases in both final
alternatives (141,401 control transitions versus 162,040 inferred and 163,910
techmap); this is not a uniform reduction in every cone. These findings show
why the unit-delay saving and bootstrap ranking cannot predict final power.
Mapping, placement, and routed delays change signal arrival times and transient
propagation. The counts are not capacitance-weighted, so they explain mechanism
without supplying a power percentage on their own.

Reproduce the final activity audit and its profile-qualified plot:

```bash
python3 build/power_char/popcount_mechanism_20260930/analyze_routed.py --stage final
python3 build/power_char/popcount_mechanism_20260930/plot_routed.py --stage final
```

The final artifacts are under
`build/power_char/popcount_mechanism_20260930/routed_final/`:
`profile.json` records exact netlist/SAIF provenance,
`matched_boundary_checks.json` records the per-pin equivalence check,
`fa_activity_summary.csv`, `boundaries.csv`, and `references.csv` contain the
measurements, and `mechanism_comparison.png` / `.pdf` compare synthesis and
final-route activity changes. Per-driver CSVs preserve individual source nets
and pins. The synthesis and bootstrap directories remain unchanged; their
64-batch/unit-delay and provisional-route profiles are historical evidence,
not substitutes for these final-route measurements.
