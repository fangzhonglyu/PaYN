# PaYN area efficiency at fixed T

Analysis of 2026-10-02 on the routed `signed_segmented_popcount` library-mapped
point (K8/M16/N8, T=128, 46,648 um2, 17.539 mW, 0.6851 pJ/MAC). T is a
model-driven parameter, so every comparison here is at **equal T**: area
efficiency can only improve through less area per stochastic bit-lane.

Status labels: **routed** = existing APR result; **synth** = new matched DC
run in this study; **model** = Python, bit-exact to the RTL where stated.

## 1. Where the area is (routed, cell-level)

Per-reference cell areas from the routed netlist
(`sweeps/pt_area_anatomy.tcl` -> `build/area_anatomy/techmap_area_anatomy.rpt`):

| block | um2 | share |
|---|---:|---:|
| 2,048 8-bit comparators (8,691 CGENI carry cells + AOI/OAI22 + buffers) | ~10,330 | 22.1% |
| 512 lane counters (88 FA + 32 HA per tile) | 11,390 | 24.4% |
| per-tile sign, signed heap, CPA, high adder (177 um2/tile) | 11,320 | 24.3% |
| 8,192 product AND2 (128/tile) | 3,240 | 6.9% |
| stochastic bit pipes (1,024 two-bit flops) | 2,810 | 6.0% |
| accumulator/pending flops + tile ICGs | 2,450 | 5.3% |
| held binary operands (reset flops) | 1,700 | 3.6% |
| Sobol banks (32 generators) | 1,668 | 3.6% |
| other (sign pipes, buffers, glue) | ~1,740 | 3.7% |

The comparator array exists because every lane of every (row/col, k) compares
the held magnitude against its own unrelated 8-bit threshold. The Sobol
generator itself is small. What costs area is that the thresholds have no shared
structure, so nothing downstream of the RNG can be shared.

## 2. Lane-stratified SNG (synth + model)

Give every lane a fixed coarse cell. Lane m owns A stratum `m>>2` and W
stratum `m&3`: the top two threshold bits on each side are per-lane constants.
The 16 lanes therefore tile the 4x4 coarse grid exactly once. Lanes that
differ only in their A stratum share one fine threshold, the top six bits of
an ordinary 8-bit Sobol lane (likewise for W). Per-(k, group) Owen masks
shift the fine bits; one XOR per k permutes strata on every lane, which keeps
the lane -> cell map bijective.

A block is then stratified sampling over the coarse grid, with Sobol-randomized
fine positions that change every block. Hardware per (row/col, k) is four
shared 6-bit compares plus one constant-threshold gate per lane:
`bit = (x_hi > s) | (x_hi == s & fine_gt)`.

RTL: `designs/payn/variants/stratified_sng/pe_peripheral_strat.sv`
(`ScPePeripheralStrat`, same ports as `sc_pe_peripheral` except M>>2 Sobol lanes
per side). `designs/payn/tb/test_pe_peripheral_strat.sv` checks 20,000 random
trials. Every lane bit equals a direct 8-bit compare against the modeled
threshold, and all K lane->cell maps are bijective: PASS.

### Area (synth, matched knobs: A7 SVT+HPK, 2.5 ns, 1.25 ns input delay, CG, multibit)

| edge SNG (held operands + RNG + bit generation) | comb | flops | total um2 |
|---|---:|---:|---:|
| inside the synthesized popcount array (reference: `u_peripheral` + both Sobol banks) | — | — | 14,199 |
| current, standalone `payn_sng_baseline` | 11,618 | 2,770 | **14,388** |
| stratified, standalone `payn_sng_strat` | 3,018 | 2,054 | **5,072** |

The standalone baseline reproduces the in-array area within 1.3%. The stratified
SNG saves **9,317 um2, about 20% of the 45,498 um2 synthesized array**, at the
same T. Both meet 2.5 ns, with +1.13 ns and +1.18 ns slack. Runs:
`syn/build/TSMC22/PAYN_SNG_{BASELINE,STRAT}/sng_20261002_*`.

At equal throughput this is about +25% GMAC/s/mm2. If the routed overhead
matches the existing peripheral, that is 46,648 -> about 37,300 um2 and
549 -> about 690 GMAC/s/mm2.

### Accuracy at equal T (model)

`sweeps/sng_accuracy_compare.py`: RMSE of one K=8 signed block, and of a
D=256 output accumulated over 32 blocks. "Uniform" draws fresh operands per
block. "Repeat" reuses one operand set for all 32 blocks of an output, a
stress case in which deterministic errors add coherently.

| T | current: block / acc, uniform | stratified: block / acc, uniform | current acc, repeat | stratified acc, repeat |
|---:|---:|---:|---:|---:|
| 16 | 0.209 / 1.21 | **0.115 / 0.60** | 1.12 | **0.53** |
| 32 | 0.170 / 0.96 | **0.091 / 0.47** | 0.93 | **0.52** |
| 64 | 0.092 / 0.54 | **0.046 / 0.24** | 0.89 | **0.51** |
| 128 | 0.066 / 0.35 | **0.025 / 0.15** | 0.10 | **0.035** |

The stratified SNG is more accurate at every T on both workloads. Two design
details matter, and both were found by the model:

- The stratum permutation must be one XOR per k for all lanes. A per-group
  XOR can double-book coarse cells and gives a constant bias (+0.0097).
- Fine bits must come from full 8-bit Sobol lanes. A 6-bit generator repeats
  every 64 clocks and re-pairs the same A/W fine samples, so long reductions
  stop improving (repeat acc stuck at 0.54).

Caveat: uniform 7-bit magnitudes only. Real layer activations and weights
still need checking.

## 3. Follow-on enabled by the stratified streams (exact, partly synth)

Within a block, each group of four lanes carries the shared fine bit on
exactly one lane; the other three are constant 0 or 1. The 16-lane AND +
popcount of one (tile, k) therefore equals, exactly,

    alpha*beta + sum_{j<beta} F_A[j^smW] + sum_{i<alpha} F_W[i^smA]
               + F_A[beta^smW] & F_W[alpha^smA]

where alpha and beta are the top two magnitude bits and F are the four shared
fine compares per side. It was checked exhaustively in RTL against the
expanded lane bits for all 16 mask pairs (`designs/payn/tb/test_strat_lane_count.sv`,
PASS). Consequences:

- **Lane logic per tile (synth, registered I/O at 2.5 ns, combinational area):**
  225.0 um2 for 16 AND + counter per lane, versus 167.7 um2 in closed form
  (`StratLaneCount`). That is -25%, about -3.7k um2 over 64 tiles. Both meet timing
  with +1.22 ns slack (`syn/build/TSMC22/PAYN_LANE_{PLAIN,STRAT}_X8/lane_20261002_*`;
  the `*_unconstrained_failed` runs lacked a clock port and are kept only as a
  record). Taking the block-constant `sum_k s_k alpha_k beta_k` out of the
  per-lane path should save more. Not yet built.
- **Bit pipes (estimate):** a (row/col, k) needs only alpha (2 bits, block-constant)
  plus 4 fine bits, not 16 lane bits. That is 2,048 -> 768 pipe bits, about -1.75k um2,
  and 62% fewer broadcast wires.

Together with Section 2, the projection is about 45.5k -> 30.8k um2 at
synthesis (-32%). Section 2's 9.3k and the lane logic's 3.7k are synthesized;
the pipe saving is an estimate. That is about +48% area efficiency at the same T
and better accuracy. Section 3 does not change results relative to Section 2.

## 3b. At grid scale the edge saving mostly amortizes away

In a `P_R x P_C` grid of InnerPEs (the re-export rails of
`inner_pe_grid_signed_segmented_clean.sv`), the edge SNG exists only on the
boundary: one A side per PE row and one W side per PE column. The PEs, with
their own bit pipes, repeat. The table below is composed from the routed
single-PE areas: u_pe 31,886 um2, peripheral 13,034 um2 split evenly A/W, and
one shared Sobol pair 1,668 um2. Stratified ratios come from the synthesis A/B
above. Grid-level wiring and the cross-PE drain are not modeled, and no grid
has been routed.

| grid | current total (um2) | edge share | Section 2 alone | Sections 2 + 3 |
|---|---:|---:|---:|---:|
| 1x1 | 46,588 | 31.6% | -20.5% | -32% (synth) |
| 4x4 | 563,978 | 9.5% | **-6.1%** | **-21.5%** |
| 4x8 | 1,100,220 | 7.3% | **-4.6%** | **-20.4%** |

The single-PE measurement overstates the edge about 3x. At realistic sizes
the stratified edge is worth about 5-6%. The scalable part is Section 3
(closed-form lane logic plus 6-bit pipes, about -17% of each PE). At scale,
about 64% of the area is lane counters plus the signed heap/CPA/high adder,
so any further large saving has to come from those.

## 4. Smaller items

- **Shared Sobol register (bit-exact):** every lane of a bank holds
  `LANE_SHIFT ^ common`, but the netlist keeps 16 copies. About -1.5k um2.
  Section 2 already removes 24 of the 32 generators.
- **Held-operand registers** use async-reset flops. Plain flops would save about 0.3k um2.
- **Shape:** the best pre-counter area efficiency was K12/M16/N10
  (615 vs 534 GMAC/s/mm2). A larger N also amortizes the edge SNG.
- **Sobol traversal order (bit-exact, energy only):** reversing the priority of the
  lowest three direction indices cuts comparator-output toggles 33%
  (`sweeps/sobol_order_activity.py`). Energy only; superseded if Section 2 is adopted.

## 5. Context: the accuracy-matched binary gap

Combined `(GMAC/s/mm2)/(pJ/MAC)`: PaYN 801, BOS INT8 3,929, INT6 7,934,
INT4 16,049. On the uniform metric, current PaYN T=128 (0.066) sits between
3-bit (0.095) and 4-bit (0.044) magnitude rounding, so the accuracy-matched
reference is INT4/INT5. The stratified SNG at T=128 (0.025) moves PaYN to
INT6-class (5-bit: 0.021) at the same T, in addition to the area cut.

## Reproduce

```bash
python3 sweeps/sng_accuracy_compare.py            # uniform operands
python3 sweeps/sng_accuracy_compare.py --repeat   # repeated-operand stress
make sim TOP=Top TB=designs/payn/tb/test_pe_peripheral_strat.sv BUILD_DIR=build/rtl_preflight/pe_peripheral_strat
make sim TOP=Top TB=designs/payn/tb/test_strat_lane_count.sv BUILD_DIR=build/rtl_preflight/strat_lane_count
bash sweeps/run_strat_sng_synth.sh <new_tag>   # all four synthesis arms
```
