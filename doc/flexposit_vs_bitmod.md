# FlexPosit vs BitMoD: analysis

Written by hand on 2026-10-17 from the measured campaigns below.  Every derived number (ratios, per-function
splits, fits, the system estimate) is computed by `flow/flexposit_vs_bitmod_numbers.py`.  Each number is tagged:
**[M]** measured in this repo's gated flow, **[R]** reported by others (BitMoD collaborator data, FlexPosit paper),
**[E]** my estimate from measured block numbers (not a run).

## Summary

1. **Same-flow hardware.** At 4-bit weights, BitMoD's tile does a MAC with **2.0x less energy** (0.70 vs
   1.39 pJ/MAC) and **4.4x more throughput per mm2** (626 vs 144 GMAC/s/mm2) than the FlexPosit core **[M]**.  This
   holds even though BitMoD carries FP16 activations against FlexPosit's FP8.  The energy gap narrows to 1.6x at 6 bits
   and 1.55x at 8 bits.  The area-efficiency gap stays at 4.4x at every width.
2. **The multiply is not the problem.** Both designs are weight-serial, and both spend the same **~0.11 pJ per weight
   bit** on product formation **[M]**.  At 4 bits their combinational energy per MAC is identical (0.513 pJ).
   FlexPosit loses on everything around the multiplier:
   * a full block-floating accumulator per single-lane PE (70% of the area gap);
   * in-core weight decoders that serve only 8 rows;
   * clocked state that does 1/P MAC per cycle.

   Its sequential (clock + register) energy is 0.87 pJ/MAC against BitMoD's 0.19.
3. **FlexPosit's format ideas are cheap and real; its microarchitecture is not.**
   * The per-channel power-of-two rescale costs 0.5% of core area and ~0% of energy **[M]**, while BitMoD's per-PE
     dequantization (normalizer + group-scale multiply) is 23% of its PE area.
   * In energy, though, BitMoD's dequantization is only 2–3% **[M]**, so the scale argument is about area, not energy.
4. **Accuracy and storage favour neither design at 4 bits.** At BitMoD-4b accuracy, FlexPosit needs 4.1–5.0 bits per
   weight (mean 4.42) against BitMoD's ~4.09 stored bits **[R, paper Table II]**.  FlexPosit's fractional precision pays
   off when the accuracy target sits between BitMoD's discrete modes, for example half of BitMoD-4b's ΔPPL at ~4.8
   bits, where BitMoD would need its 6-bit mode.
5. **System level.** Batch-1 decode is DRAM-bound, so the two designs are within ~10% (BitMoD lower).  As weight reuse
   grows (prefill, batching), the ratio climbs to the 2x compute gap **[E]**.  The paper's claim of 1.8x higher
   throughput than BitMoD at iso-area implies ~0.5 MAC/cycle per BitMoD PE **[E from R]**.  The BitMoD RTL's PE does
   2 MAC/cycle at FP4, and under that, BitMoD is ~2.2x faster at iso-area instead.

## 1. What was compared, and how fair it is

Both designs went through the same ASTRAEA/PaYN flow: TSMC22 sc7mcpp140z SVT C30 + HPK, 400 MHz, routed, full-timing
max-SDF gate-level simulation, PrimeTime PX with routed SPEF, and the same qualification gates.  Both use uniform random
operands.

| | FlexPosit core `fp_20261015b` | BitMoD tile `bm_20261016b` |
|---|---|---|
| DUT | 8x8 core: 8 SerialPosit decoders, 64 bit-serial PEs, cycle generator, per-column FP16 readout with power-of-two rescale | 8x8 tile, 64 four-lane PEs (split into per-function submodules, equivalence-checked), output RF, column `fpadd` |
| Source | FlexPosit repo e42a219 (12 nm test-chip RTL: 1 accumulator per PE, FP8 E4M3 activations) | upstream bitmod 5cb051c, migrated into PaYN |
| Weights / activations | Posit(P,1), P = 4..8 / FP8 | FP4 / INT6 / INT8 with 8-bit group scale (group 128) / FP16 |
| Routed area | 44,569 um2 | 81,791 um2 (synthesized at 2.25 ns for timing margin; flat 2.5 ns synthesis 69,783; collaborator's route 69,684) |
| Window | whole tiles: decode fill, products, drain, readout | MAC cycles; drain excluded |
| Gate-level check | every FP16 lane bit-exact vs model | drained 64-accumulator matrix bit-exact vs RTL of the original tile |

Known biases, none large enough to flip a conclusion:

| Difference | Favours | Size |
|---|---|---|
| FP8 vs FP16 activations | FlexPosit | FP16 aligners and adders are wider; not separable from this data |
| FlexPosit's weight decoders sit inside the core; BitMoD's controller (term generation, FP4 conversion, skew) sits outside the tile | BitMoD | FlexPosit decode is 10% of area and 12% of energy at P=4.  BitMoD's controller is ~1.3% of area and ~1% of power at 32x32 **[R]** |
| FlexPosit's window includes fill, drain and readout | BitMoD | ~5% at K = 256 |
| BitMoD route over-constrained (2.25 ns) and split into submodules | FlexPosit | BitMoD +17% area and +18% pJ/MAC against the collaborator's numbers (0.592 / 1.137 pJ/MAC f4 / i8 **[R]**) |
| FlexPosit RTL lacks the paper's 4-PE shared accumulator | BitMoD | ~2x area efficiency (section 10), little energy |

Timing: both routes pass ASTRAEA's Innovus-based qualification at 2.5 ns.  PrimeTime at 2.5 ns with 0.125 ns
uncertainty puts FlexPosit at -0.120 ns setup and BitMoD at 0.000 ns, both inside the uncertainty.  Innovus reports are
optimistic by the clock insertion delay on every ASTRAEA route (`doc/bitmod_breakdown.md`, Timing sign-off).

## 2. The two architectures

| | FlexPosit (this RTL) | BitMoD |
|---|---|---|
| Serial unit | 1 weight bit per cycle; P cycles per weight | 1 Booth term (~2 bits) per beat: 2 beats FP4, 3 INT6, 4 INT8 |
| Lanes per PE | 1 (one activation x one weight) | 4 (four FP16 activations x four weight terms, adder tree in the PE) |
| MAC/cycle per PE | 1/P: 0.25 at P = 4, 0.125 at P = 8 | 4/beats: 2 (FP4), 1.33 (INT6), 1 (INT8) |
| Reduction | temporal only: each product joins the PE's own accumulator every P cycles | spatial over 4 lanes per beat, temporal in a beat accumulator, then per-group in a column `fpadd` |
| Accumulator | block-floating per PE (7b exp, 16b mantissa, RNE), commits once per product | shared by the 4 lanes, commits every beat |
| Scale | one power of two per output channel, applied once at readout | 8-bit scale per group of 128, applied in every PE (bit-serial), then groups combined in the column adder |
| Precision steps | any P in 4..8, mixed per channel window (fractional averages) | discrete modes (FP4, INT6, INT8) |
| Weight decode | SerialPosit decoder per column, in the core | controller at the array edge (outside the tile) |

## 3. Measured results (same flow)

| Weight bits | Design | MAC/cycle | GMAC/s/mm2 | um2 per MAC/cycle | pJ/MAC | BitMoD advantage (area eff. / energy) |
|---:|---|---:|---:|---:|---:|---|
| 4 | FlexPosit P=4 | 16 | 144 | 2,786 | 1.386 | |
| 4 | BitMoD f4 x f16 | 128 | 626 | 639 | 0.698 | 4.4x / 2.0x |
| 6 | FlexPosit P=6 | 10.7 | 96 | 4,178 | 1.734 | |
| 6 | BitMoD i6 x f16 | 85.3 | 417 | 958 | 1.058 | 4.4x / 1.6x |
| 8 | FlexPosit P=8 | 8 | 72 | 5,571 | 2.098 | |
| 8 | BitMoD i8 x f16 | 64 | 313 | 1,278 | 1.352 | 4.4x / 1.55x |

FlexPosit P=5 and P=7: 1.556 and 1.920 pJ/MAC, 115 and 82 GMAC/s/mm2.  Against the collaborator's 69,684 um2 BitMoD
route, the area-efficiency ratio is 5.1x.

The 4.4x is constant because both throughputs scale as 1/bits, and a BitMoD PE does 8x the MACs per cycle of a
FlexPosit PE (2 vs 0.25 at 4 bits) in 1.8x the routed area.  At the paper-table sizing of 1,024 MAC/clock:
FlexPosit is 2.852 mm2, 568 mW, 410 GMAC/s; BitMoD is 0.572 mm2, 245 mW **[R]** (8 measured tiles would be 0.654 mm2
and 286 mW).

## 4. Where the energy goes

Energy per MAC by function, in pJ **[M]** (FlexPosit PE sub-blocks from PrimeTime's split of `U_COMPUTE` / `U_ACC`;
BitMoD from the split PE):

| Function | FlexPosit P=4 | BitMoD f4 | Gap | FlexPosit P=8 | BitMoD i8 | Gap |
|---|---:|---:|---:|---:|---:|---:|
| Weight decode (in the DUT) | 0.161 | 0 (outside) | +0.161 | 0.252 | 0 (outside) | +0.252 |
| Product formation (+ BitMoD's 4-lane reduction) | 0.479 | 0.430 | +0.049 | 0.865 | 0.836 | +0.029 |
| Accumulation | 0.396 | 0.143 | +0.253 | 0.392 | 0.315 | +0.077 |
| Scale / dequant / column combine | 0.004 | 0.024 | -0.020 | 0.004 | 0.028 | -0.024 |
| Pipe registers, staging, control, top-level clock tree, glue | 0.346 | 0.100 | +0.247 | 0.589 | 0.174 | +0.415 |
| **Total** | **1.386** | **0.698** | **+0.688** | **2.098** | **1.352** | **+0.746** |

**Product formation is ~0.11 pJ per weight bit in both designs.**

| | Product-formation energy per weight bit |
|---|---:|
| FlexPosit P=4 | 0.120 pJ/bit |
| FlexPosit P=8 | 0.108 pJ/bit |
| BitMoD f4 | 0.108 pJ/bit |
| BitMoD i6 | 0.110 pJ/bit |
| BitMoD i8 | 0.104 pJ/bit |

Serial weight processing costs about the same per bit whichever way it is cut: one bit per cycle on one lane, or a
two-bit term per beat on four lanes.

**A two-term model fits both.** Fitting E/MAC = slope x weight bits + fixed **[M]**:

| | slope (pJ per weight bit) | fixed (pJ/MAC) |
|---|---:|---:|
| FlexPosit | 0.179 | 0.665 |
| BitMoD | 0.164 | 0.054 |

The marginal cost of a weight bit is nearly identical.  FlexPosit carries an extra ~0.6 pJ on every MAC whatever the
precision.  About 0.39 pJ of it is the per-product accumulation, which is constant in P (0.396 / 0.392).  BitMoD
accumulates per beat, so its accumulation grows with bits (0.143 / 0.239 / 0.315).  That is why the gap narrows at
8 bits, where BitMoD accumulates about once per MAC, like FlexPosit.

**By cell class** (PrimeTime `report_power` groups) **[M]**:

| | pJ/MAC | Clock network | Registers | Combinational |
|---|---:|---:|---:|---:|
| BitMoD f4 | 0.698 | 0.111 (16%) | 0.074 (11%) | 0.513 (74%) |
| BitMoD i8 | 1.352 | 0.214 (16%) | 0.148 (11%) | 0.990 (73%) |
| FlexPosit P=4 | 1.386 | 0.672 (49%) | 0.201 (14%) | 0.513 (37%) |
| FlexPosit P=8 | 2.098 | 1.233 (59%) | 0.275 (13%) | 0.591 (28%) |

At 4 bits the combinational energy per MAC is identical.  FlexPosit's extra 0.69 pJ/MAC is clock and registers: 0.87
against 0.19.  Each FlexPosit PE clocks its state every cycle for 1/P of a MAC, while a BitMoD PE retires 2 MACs per
cycle on a comparable clock load (its tile clock network is 1.4x FlexPosit's for 8x the throughput).

**BitMoD's per-PE dequantization is cheap in energy.** The normalizer and group-scale multiply are 23% of the PE's area
but 0.015 pJ/MAC at f4 (2%), because they fire once per group of 128.  The column `fpadd` and output RF add another
1.4%.

## 5. Where the area goes

um2 per MAC/cycle at 4-bit weights, routed **[M]**:

| Function | FlexPosit P=4 | BitMoD f4 | Gap | Share of gap |
|---|---:|---:|---:|---:|
| Accumulation | 1,633 | 132 | +1,501 | 70% |
| PE pipe registers, staging, control, top-level clock tree, glue | 324 | 38 | +286 | 13% |
| Weight decode (in the DUT) | 275 | 0 (controller ~7 outside) | +275 | 13% |
| Product formation (+ BitMoD's 4-lane reduction) | 492 | 305 | +187 | 9% |
| Column output (readout / `fpadd` + RF) | 47 | 39 | +8 | 0% |
| Scale / dequant | 15 | 125 | **-110** | -5% |
| **Total** | **2,786** | **639** | **+2,147** | |

* **Accumulation is most of the gap.** A FlexPosit PE's accumulator (408 um2) is 72% of the PE and commits once per
  P cycles.  BitMoD's beat accumulator (249 um2 in synthesis) serves 4 lanes and commits every beat.
* **Product formation is close.** Per lane, the multipliers are similar in size: FlexPosit 123 um2; BitMoD 129 um2
  (lanes + align + pair adders + merge, divided by 4).  The 1.6x per MAC/cycle comes from BitMoD's 2 bits per beat
  against FlexPosit's 1 bit per cycle.
* **Decode is geometry.** FlexPosit decodes in each 8-row core: 551 um2 per column, of which the beat FIFO is 251, the
  K·P budget gate 204 and the decoder 96.  BitMoD decodes once at the edge of a 32x32 array.
* **Scale is FlexPosit's real win.** It saves 110 um2 per MAC/cycle against BitMoD's in-PE normalizer and scale.

## 6. Precision scaling

| Weight bits | 4 | 5 | 6 | 7 | 8 |
|---|---:|---:|---:|---:|---:|
| FlexPosit MAC/cycle per core | 16 | 12.8 | 10.7 | 9.1 | 8 |
| FlexPosit pJ/MAC | 1.386 | 1.556 | 1.734 | 1.920 | 2.098 |
| BitMoD MAC/cycle per tile | 128 | (6b mode) | 85.3 | (8b mode) | 64 |
| BitMoD pJ/MAC | 0.698 | 1.058 | 1.058 | 1.352 | 1.352 |

* FlexPosit's throughput and energy move smoothly with P.  Fractional per-window precision averages anywhere in
  between.  Its power falls with P (8.39 to 6.43 mW) because the accumulator commits less often.
* BitMoD's power is flat across modes (34.5 / 36.0 / 35.6 mW), so energy per MAC follows the beat count.  A 5-bit
  requirement costs BitMoD its 6-bit mode.
* Even so, BitMoD i6 (1.058) beats FlexPosit at P=5 (1.556) by 1.5x per MAC.

## 7. Accuracy and storage

From the FlexPosit paper, Table II **[R]** (WikiText-2, 9 models, FP16 activations, mean ΔPPL vs FP16):

| Scheme | Weight bits | Mean ΔPPL |
|---|---|---:|
| MX-FP8 (group) | 8 | 0.02 |
| BitMoD (group) | 4 (+8-bit scale and 3-bit type id per 128: ~4.09 stored) | 0.40 |
| Posit(4,1), per-channel power-of-two scale | 4 | 1.57 |
| FlexPosit (channel windows) | 4.1 | 0.64 |
| FlexPosit, minimum p for BitMoD-4b PPL ("PEB") | 4.1–5.0 per model (mean 4.42) | 0.33 |
| FlexPosit, best within 4–5 b | 4.7–5.0 | 0.20 (below BitMoD on all 9 models, below FP16 on 3) |

* At iso-accuracy with BitMoD-4b, FlexPosit stores ~0.33 more bits per weight (8% more weight traffic).  Its
  advantages are regularity (channel-wise, no per-group scales or type ids in memory) and the continuous
  accuracy–precision knob.
* FP8 activations (Table VI) cost FlexPosit at most +0.36 PPL (Phi-2), ~0.02 on the 7B models.  So the FP8 test-chip
  RTL measured here is a fair accuracy proxy.

## 8. System level, first order **[E]**

Weight-stationary energy per MAC = DRAM energy (8 pJ/bit flat, PaYN_eval `docs/MODELLING.md` §3.1) x stored bits /
reuse B, plus compute pJ/MAC.  Activations, KV cache and on-chip buffers are ignored.  FlexPosit is at the iso-PPL mean
of 4.42 b (1.46 pJ/MAC compute, interpolated); BitMoD at 4.09 stored bits (0.70 measured).

| Weight reuse B | FlexPosit (pJ/MAC) | BitMoD (pJ/MAC) | FlexPosit / BitMoD |
|---:|---:|---:|---:|
| 1 (batch-1 decode) | 36.8 | 33.4 | 1.10 |
| 4 | 10.3 | 8.9 | 1.16 |
| 16 | 3.7 | 2.7 | 1.34 |
| 64 | 2.0 | 1.2 | 1.66 |
| 256 (prefill) | 1.6 | 0.83 | 1.93 |

* At iso-accuracy with BitMoD-4b there is no regime where FlexPosit wins on energy.  In decode the extra stored bits
  dominate; in prefill the 2x compute gap does.
* FlexPosit wins when the target is higher accuracy than BitMoD-4b but BitMoD's next mode is 6 bits.  For example,
  FlexPosit's Best-PPL point (mean ΔPPL 0.20 at ~4.8 b) costs 39.9 pJ against BitMoD i6 at 49.7 pJ in batch-1 decode,
  20% lower.  That assumes BitMoD needs its 6-bit mode for that accuracy, which Table II does not report.

## 9. Reconciling with the FlexPosit paper

The paper (16 nm DC synthesis, cycle-level simulator, iso-area 32x16 FlexPosit vs 8x16 BitMoD, iso-PPL, DRAM
included) reports 1.8x higher throughput and 1.2x lower energy than BitMoD **[R]**.

* **Per-PE area agrees.** Table VII gives a FlexPosit/BitMoD real-PE ratio of 214.3/887.2 = 0.24.  Ours is 0.50–0.58
  for the test-chip RTL (own accumulator per PE).  With the paper's 4-PE shared accumulator **[E]** it becomes
  0.26–0.30.  The paper's area model is consistent with ours once the sharing is in.
* **Per-PE throughput is where they part.** 512 FlexPosit PEs at 4.42 b give 116 MAC/cycle.  A 1.8x speedup over
  128 BitMoD PEs implies ~0.5 MAC/cycle per BitMoD PE at 4 bits, i.e. one lane.  The BitMoD RTL's PE has 4 lanes and
  does 2 MAC/cycle at FP4.  With it, the iso-area BitMoD array does 256 MAC/cycle, 2.2x FlexPosit's.  This is my
  inference from the paper's table and headline; the text doesn't state BitMoD's per-PE throughput.  It is the first
  thing to check in their simulator configuration.
* **The energy attribution is not supported by the RTL.** The paper says BitMoD's "per-PE rescaling and FP
  accumulation of group partial sums raise switching activity and keep compute energy high".  Measured: BitMoD's
  per-PE dequant plus column group combine is 3.5% of its energy, and its compute energy per MAC is half FlexPosit's.
* **The paper's own claims hold up.** Its "minimal dequantization overhead" claim is confirmed: the rescale is 0.5% of
  area and 0.06% of power.  So is its point that BitMoD's PE is larger (1.8x routed).

## 10. What would close the gap **[E]**

Ranked by measured leverage at 4 bits:

| Change | Area per MAC/cycle | Energy per MAC | Notes |
|---|---|---|---|
| Share the accumulator across 4 PEs (the paper's design) | 2,786 → ~1,560 (core ~25,000 um2) | small | Accumulator energy is per commit (it halves from P=4 to P=8 with the commit rate), so little is idle power to save |
| K-lane reduction in the PE (BitMoD-style adder tree before one accumulator) | similar to sharing | accumulation ~0.40 → ~0.15 | lanes of one column share P, so they stay in lockstep |
| 2 weight bits per cycle | product ~1.6x denser | clock/register ~halved (0.87 → ~0.45) | the regime's run-length code makes 2-bit steps harder for the SerialPosit decoder |
| Decode once per 32 rows instead of 8 | decode 275 → ~70 | 0.16 → ~0.04 | geometry only; also the K·P budget gate can be global |

All four together would land roughly at BitMoD's efficiency.  At that point the design is BitMoD's microarchitecture
carrying a posit format with per-channel power-of-two scales.  That combination keeps FlexPosit's two real advantages:
no per-PE dequantization area, and fractional precision.  It is the design worth measuring next.

## 11. Open items

1. **Build and measure a FlexPosit cluster with a shared accumulator or K-lanes.** This replaces the section 10
   estimates; the flow (`flow/flexposit.sh`) is ready.
2. **Add FlexPosit to PaYN_eval** with the measured numbers.  This replaces the section 8 first-order model with
   workload results (decode vs prefill, buffers, KV cache).
3. **Ask the FlexPosit authors** what per-PE throughput their simulator assumes for BitMoD (section 9).
4. **ASTRAEA timing optimism** (CCOpt's -max-only source latency under OCV) applies to both routes alike.  A fix would
   re-qualify every route but not change this comparison.

## Sources

* `doc/flexposit_results.md`, `build/flow/flexposit/fp_20261015b/` (result_p*.csv, power_p*/power.rpt,
  power_hier.rpt); FlexPosit PE sub-block split from PrimeTime on the same route.
* `doc/bitmod_breakdown.md`, `build/flow/bitmod_hier/bm_20261016b/` (results.csv, power_m*/power.rpt,
  power_hier.rpt, qualification.json).
* BitMoD collaborator data: `archive/doc/bitmod_data - jul29.csv`; PaYN paper `tab:array_spec`.
* FlexPosit paper (`FlexPosit/2609.04724v2.pdf`): Tables I, II, VI, VII, VIII, X and section VI text.
* PaYN_eval `docs/MODELLING.md` §3.1 (DRAM 8 pJ/bit).
* `flow/flexposit_vs_bitmod_numbers.py` (every derived number).
