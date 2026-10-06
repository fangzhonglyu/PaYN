# A6P5/SVT experimental results

These results are intentionally separate from the accepted A7/SVT results in
`results.md`.  A6P5 uses separate synthesis/APR targets and build directories,
and none of the measurements below changes the accepted A7 headline.

The pending-bit PaYN RTL and binary INT8 control were mapped to the installed
`A6P5PP140ZTS_C30` 6.5-track SVT library.  PaYN synthesis uses the
SCArch-proven X0P5 full-adder and AND2 mapping; binary is allowed to optimize
naturally in the same A6P5/SVT library.

## Headline A6P5 results

| design | array | area (µm²) | wire (µm) | setup / hold WNS (ns) | power (mW) | pJ/MAC | physical status |
|---|---:|---:|---:|---:|---:|---:|---|
| PaYN pending | 8×8 | 48,004 | 1,023,758 | +0.290 / +0.039 | 17.18954 | 0.671466 | 3 geometry DRCs, 21 antenna violations |
| **PaYN pending** | **10×10** | **68,517** | **1,438,467** | **+0.166 / +0.039** | **25.64424** | **0.641106** | 4 geometry DRCs, 34 antenna violations |
| Binary signed INT8 | 8×8 | 15,122 | 139,152 | +0.989 / +0.050 | 9.60705 | 0.375276 | 3 local VIA1 DRCs; connectivity and antenna clean |

The N=8 and N=10 PaYN routes passed the unchanged 384-block routed max-SDF
workload, independent bit-exact streaming model, and SAIF validation.  N=10
reduces energy 4.52% relative to N=8.  Its inner-PE energy is effectively
unchanged (0.567112 versus 0.564974 pJ/MAC); the improvement comes from
amortizing fixed peripheral and Sobol costs over 100 rather than 64 MACs per
cycle.

The N=10 breakdown is 0.564974 pJ/MAC for the inner PE array, 0.053029 for
binary-unary conversion, 0.018561 for Sobol generation, and 0.004543 for
shared/top-level overhead.

All routed A6P5 points remain analysis results because of physical violations.
The clean A7/SVT checkpoints remain the accepted results.

## Matched synthesis

| A6P5 design | cell area (µm²) | setup WNS (ns) | power (mW) | pJ/MAC |
|---|---:|---:|---:|---:|
| PaYN pending, 8×8 | 44,734.51 | +1.35 | 6.9159 | 0.270152 |
| Binary signed INT8, 8×8 | 13,853.20 | +1.34 | 4.6367 | 0.181121 |

Against the matched A7 controls, A6P5 reduces PaYN synthesis area 8.77% and
power 13.98%; binary area falls 6.30% and power falls 8.76%.  At routed 8×8,
PaYN area, wire, and energy fall 8.0%, 8.7%, and 8.0%, respectively.  Routed
binary area, wire, and energy fall 8.6%, 2.7%, and 9.4%.

The synthesis powers above are fully SAIF-annotated, zero-wire-load estimates:

| design | cell internal (mW) | net switching (mW) | dynamic (mW) | dynamic (pJ/MAC) | leakage (mW) | total (pJ/MAC) |
|---|---:|---:|---:|---:|---:|---:|
| PaYN pending, 8×8 | 4.4255 | 2.3797 | 6.8051 | 0.265824 | 0.110808 | 0.270152 |
| Binary signed INT8, 8×8 | 2.9246 | 1.6794 | 4.6041 | 0.179848 | 0.032662 | 0.181121 |

PaYN is 1.48× binary in synthesis dynamic energy and 1.49× in total energy.
Even the PaYN inner array alone is about 5.646 mW / 0.2205 pJ/MAC, 22% above
the complete binary array before conversion and Sobol overhead are added.

## A6P5 library flavors and cell sizing

The installed A6P5 kit has complete synthesis, timing, LEF, Verilog, and GDS
views for these base-library flavors:

| channel length | available threshold flavors |
|---|---|
| C30 | LVT, SVT, HVT |
| C35 | SVT, HVT |
| C40 | SVT, HVT, EHVT, UHVT |

The flow can also expose more than one base flavor to synthesis and APR, for
example HVT first with SVT available for timing repair.  There is no
A6P5-compatible HPK add-on in this installation; A6P5 multi-bit flops used by
the current netlist come from the base library.

The current PaYN target explicitly restricts its two dominant arithmetic
families to the weakest available drive:

- all 8,640 full adders are `ADDF_X0P5M`;
- all 7,232 `AND2` cells are `AND2_X0P5M`;
- the 4,568 half adders use `ADDH_X1M`, the minimum available half adder;
- all 9,990 `CGENI_X1M` cells are in `u_peripheral`, where they implement the
  carry/borrow chains of the binary-to-unary comparators; none are in `u_pe`.

`CGENI` computes an inverted three-input carry,
`~((A & B) | (A & CI) | (B & CI))`.  DC uses it to realize the 2,048 unsigned
8-bit `binary > scrambled_random` comparisons that emit the A and W stochastic
bits.  Constant scrambling and surrounding AOI/OAI logic reduce the result to
about 4.88 `CGENI` cells per comparator.  These cells occupy 6,364 µm², 54.3%
of the peripheral and 14.2% of the complete synthesized PaYN design.

This is not a global minimum-drive mapping.  Thousands of inverters and
AOI/OAI/AO cells remain X1 although X0P5 variants exist.  However, X0P5 does
not mean a smaller physical cell in this library: X0P5 and X1 have identical
area for `ADDF`, `AND2`, `AO22`, `AOI22`, and several other important
families.  X0P5 leakage is also higher than X1 for the characterized
SVT/C30 `ADDF` and `AND2`; its potential benefit is lower input capacitance
and dynamic power.  A matched natural-mapping run is therefore needed to
prove that forcing X0P5 is optimal for this particular PaYN workload.

The synthesis gap is consistent with the implemented arithmetic.  Each PaYN
output evaluates `K*M = 128` stochastic bit products per cycle and then
popcounts and reduces them, whereas an INT8 binary multiplier starts from 64
one-bit partial products and maps heavily into complex AOI/OAI gates.  The
PaYN synthesis has 60,249 cells versus 18,958 for binary and 3.61× as many
`ADDF` cells.  Its inner-array area alone is 31,638 µm² versus 13,853 µm² for
the complete binary array.  Routing then increases the disadvantage: the
A6P5 N=8 PaYN-to-binary power ratio grows from 1.49× at synthesis to 1.79×
after APR.

The binary route used the same signed-INT8, 4,097-cycle output-checked workload
as its A7 control.  Checkpoint-only finalization reduced its geometry count
from five to three without repeating placement or CTS.  The remaining errors
are localized VIA1 access violations within multiplier cells.

## Array-size screen

The symmetric K8.M16 synthesis screen keeps T=128 and the 384-block workload
fixed:

| N | cell area (µm²) | setup WNS (ns) | power (mW) | synthesis pJ/MAC |
|---:|---:|---:|---:|---:|
| 4 | 15,909 | +1.36 | 2.5103 | 0.392234 |
| 6 | 28,517 | +1.36 | 4.3793 | 0.304118 |
| 8 | 44,735 | +1.35 | 6.9159 | 0.270152 |
| 10 | 64,488 | +1.35 | 9.7827 | 0.244568 |
| 12 | 87,873 | +1.34 | 13.3145 | 0.231155 |
| 14 | 114,697 | +1.34 | 17.4202 | 0.222196 |

Synthesis continues to improve through N=14 because fixed binary-unary and
Sobol energy is amortized over more simultaneous MACs.  Physical scaling is
less favorable.  N=10 is the largest fully power-qualified routed point and
the best validated A6P5 result.

The N=12 route closes setup and hold (+0.246/+0.029 ns), and its zero-delay
routed netlist passes all 384 blocks.  Max-SDF delay annotation, however,
causes deterministic missed high-segment updates in eleven PEs.  Its SAIF is
rejected and no N=12 power number is reported.  N=14 was not routed.

## N=10 placement screen

| placement recipe | estimated wire (µm) | density | H / V overflow | blocked hotspot max / total |
|---|---:|---:|---:|---:|
| **hierarchical + row/column guides** | **1,337,647** | 70.288% | **0.00% / 0.00%** | **0.00 / 0.00** |
| hierarchical, unguided | 1,762,390 | 70.424% | 0.01% / 0.02% | 0.26 / 1.31 |
| fully flattened, unguided | 1,720,930 | 70.480% | 0.01% / 0.01% | 3.41 / 4.72 |
| fully flattened + row/column guides | 1,353,277 | 70.293% | 0.00% / 0.01% | 0.00 / 0.00 |

The row/column guides reduce estimated wire 24.10% versus the matched
hierarchical unguided placement.  Flattening recovers only 2.35% without
guides and is 1.17% worse when combined with them.  The flat variants were
therefore stopped after placement rather than sent through full APR.

## Provenance

- Synthesis screen: `build/power_char/a6p5_n_screen/results.csv`
- Placement QoR: `build/power_char/a6p5_n_screen/placement_qor.csv`
- N=8 PaYN route:
  `apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED_A6P5_SVT/a6p5_svt_k8m16n8_lw9_distguide`
- N=10 PaYN route:
  `apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED_A6P5_SVT/a6p5_svt_k8m16n10_lw9_distguide`
- Binary route:
  `apr/build/TSMC22/BP_ARRAY_A6P5_SVT/a6p5_svt_int8`

Reproduction commands remain in `experiments.md`.
