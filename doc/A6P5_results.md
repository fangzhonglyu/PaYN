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
