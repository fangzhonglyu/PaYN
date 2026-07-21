# PaYN SC — functional power decomposition

Deep breakdown of the SC accelerator's **APR PrimeTime-PX SAIF** power, classifying every
leaf cell by its architectural role. Complements the coarse hierarchical split in
`doc/results.md` (`u_pe` 90% / peripheral 5% / Sobol 4%) by cutting the *same* total along
function (compute vs. bit-pipes vs. accumulators vs. clock) instead of hierarchy.

Two configs, both TSMC22 svt_c30/sc7mcpp140z @ 0.80 V, 2.5 ns, T=256 workload SAIF:

- **Reference** — `PAYN_SC`, K6·M16·9×9·OW24 (the headline design), 23.57 mW.
  Run `apr/build/TSMC22/PAYN_SC/20260719_152217/`.
- **Best sweep config** — `k8·m16·n8` (lowest pJ/MAC, 0.78), 19.84 mW.
  Run `apr/build/TSMC22/PAYN_SC_SWEEP/k8m16n8/`.

Each decomposition reconciles to its `power.rpt` Total exactly.

## Breakdown by function

| component | ref K6·M16·9×9 | best k8·m16·n8 | what it is |
|---|---:|---:|---|
| **popcount_logic** | 13.75 (58.3%) | 11.08 (55.9%) | tile combinational — DW02 CSA tree + XNOR/AND SC compute |
| **glue_other** (comb) | 1.83 (7.8%) | 1.48 (7.5%) | peripheral comparators + Sobol comb + InnerPE glue |
| → **combinational total** | **15.58 (66.1%)** | **12.56 (63.3%)** | |
| w_bit pipe | 2.78 (11.8%) | 2.14 (10.8%) | weight stochastic bit pipe |
| acc | 1.41 (6.0%) | 1.10 (5.5%) | output-stationary accumulators (24 b × N²) |
| a_bit pipe | 1.06 (4.5%) | 1.46 (7.3%) | input stochastic bit pipe |
| Sobol RNG | 0.49 (2.1%) | 0.40 (2.0%) | counters + LFSR value regs |
| sign / periph-reg / load / other | 0.16 | 0.15 | sign pipes, held-binary regs, load wave, ICG latches |
| → **sequential total** (incl. clock pins) | **5.90 (25.0%)** | **5.24 (26.4%)** | |
| **clock tree** (buffers/gates only) | 2.08 (8.8%) | 2.04 (10.3%) | `clock_network` − register clock pins |
| **TOTAL** | **23.57** | **19.84** | |
| pJ/MAC (MAC/cyc 60.75 / 64) | 0.97 | **0.78** | |

Three-way rollup: **~64–66% combinational · ~25% sequential · ~9–10% clock tree.**

Flop buckets fold in each flop's clock-pin internal power, so `acc` is the honest sequential
cost — the accumulators hold static in-window but their clock pins toggle every cycle (the
clock-pin attribution caveat: a bare `register` group would understate them).

## Two findings

**1. SC is ~two-thirds combinational, robustly.** The popcount / DW-tree compute cone is the
whole ballgame (66% at the reference, 63% at the best config) — the fundamental SC signature,
and the inverse of BP (~54% cell-internal, MAC folded into compact multipliers). SC trades
BP's dense arithmetic for a large, always-toggling combinational popcount. The best config's
slightly lower share is just tile count: 64 cones (8×8) vs. 81 (9×9), each deeper (K8 vs K6).

**2. The weight-pipe switching asymmetry is partly a layout artifact, not fundamental.**
Splitting the two bit-pipes (equal flop counts) into internal vs. switching:

| pipe | ref: internal / switching | best: internal / switching |
|---|---:|---:|
| a_bit (input) | 0.57 / 0.49 | 0.68 / 0.77 |
| w_bit (weight) | 0.59 / **2.19** | 0.69 / **1.44** |
| w:a switching ratio | **4.5×** | **1.9×** |

Both configs show the weight bus carrying more *net-switching* (routed cap) than the input
bus — the same net-cap-limited behavior seen array-wide in the sweep (net-switching share
42→54% with size). But the extreme 4.5× at the 9×9 reference collapses to 1.9× at the
well-routed best config, so most of that gap was **the reference placement**, not an inherent
A/W difference. The durable claim: SC bit-pipe power is switching- (wire-) dominated on the
weight side; the magnitude is layout-sensitive.

## Reproduce

```
# in the APR run dir; TOP + workload SAIF + APR netlist/SPEF/SDC must be present
cd apr/build/TSMC22/PAYN_SC/<run>            # or PAYN_SC_SWEEP/k8m16n8
TOP=payn_array SAIF_FILE=activity/dut.saif \
  TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1 TSMC22_CELL_TIER=sc7mcpp140z \
  pt_shell -file <repo>/sweeps/pt_pe_components.tcl
# -> reports/pe_components.rpt  (CSVROW line is machine-parseable)
```

`sweeps/pt_pe_components.tcl` reloads netlist + SPEF + SAIF in PrimeTime, classifies each
physical sequential leaf by RTL signal name (`a_bits_pipe`/`w_bits_pipe`/`acc_out`/
`*_binary_q`/`random_value`+`count`/…), derives `popcount = tile_total − acc` and
`glue = Total − flops − popcount − clock_dist`, and reconciles to Total. Pass `NL=…syn.v
SPEF=""` to run the identical classification on the pre-layout synth netlist (zero-wireload).
