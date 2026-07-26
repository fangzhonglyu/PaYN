# PaYN — Accepted A7/SVT Results

Current routed, workload-driven A7/SVT results for TSMC22 at 0.80 V and
2.5 ns (400 MHz).  This file is intentionally limited to accepted A7 results
and the comparisons needed to interpret them.  Experiment commands and
historical design points live in [`experiments.md`](experiments.md) and the
linked design notes.

## Workload used for the accepted PaYN result

| parameter | value |
|---|---|
| architecture | pending-bit signed segmented accumulator, `LOW_W=9` |
| shape | K8, M16, 8×8 outputs, OW24, T=128 |
| useful rate | 64 equivalent MAC/cycle = 25.6 GMAC/s |
| numeric input | logical 7-bit unsigned magnitude plus a separate sign |
| existing 8-bit converter encoding | logical magnitude `m` is driven as `m << 1`, preserving `P(1)=m/128` |
| block schedule | magnitude and sign reload every `T/M=8` cycles |
| stochastic activity | Sobol advances and emits a new M=16 slice every cycle |
| measurement window | 256 back-to-back blocks = 2,048 productive cycles |

The routed max-SDF drain matches the independent streaming reference
bit-for-bit.  The trace contains only even encoded values through 254,
corresponding to logical magnitudes through 127.  SAIF validation reports zero
unknown time in the accumulator.

The physical netlist still contains 8-bit magnitude registers, comparators, and
Sobol words.  This result models the correct 7-bit numeric behavior on that
netlist; it does not claim the area or capacitance savings of physically
narrowing the converter.

Two idle clocks after reset release let routed reset trees satisfy recovery
before the first operand load.  They occur before SAIF starts and do not change
the productive workload or its energy accounting.

## Headline routed results

All designs operate at 400 MHz and retire 64 MAC/cycle.  Energy is therefore
`power / 25.6` in pJ/MAC.

| design | routed area (µm²) | setup WNS (ns) | power (mW) | pJ/MAC |
|---|---:|---:|---:|---:|
| BP signed INT8 | 16,536 | +1.040 | 10.60000 | 0.41406 |
| BP signed INT8 + asymmetric correction | 19,606 | +0.430 | 11.74739 | 0.45888 |
| **PaYN pending-bit LOW_W=9** | **51,871** | **+0.627** | **18.53117** | **0.72387** |

At equal useful throughput, the accepted PaYN point consumes:

- 1.75× the energy of plain signed INT8 BP (+74.8%).
- 1.58× the energy of BP with asymmetric zero-point correction (+57.7%).

The asymmetric correction costs BP 10.8% over its plain signed implementation.
The binary benches use long-running, output-checked signed INT8 workloads and
do not require stochastic probability scaling.  The accepted PaYN route also
has +0.029 ns hold WNS.

## Binary precision: native hardware versus fixed INT8 hardware

`Native` means the multiplier, registers, and routing are physically narrowed.
The fixed-INT8 columns keep the complete INT8 netlist and only restrict input
values.  All measurements are routed and output-checked.

| input precision | native HW area (µm²) | native HW mW / pJ/MAC | fixed INT8 HW, signed inputs mW / pJ/MAC | fixed INT8 HW, all-positive inputs mW / pJ/MAC |
|---|---:|---:|---:|---:|
| INT8 | 16,536 | 10.60 / 0.414 | 10.60 / 0.414 | 9.01 / 0.352 |
| INT7 | 15,136 | 9.53 / 0.372 | 10.50 / 0.410 | 8.61 / 0.336 |
| INT6 | 13,343 | 8.16 / 0.319 | 10.42 / 0.407 | 7.75 / 0.303 |

Signed input narrowing on fixed INT8 hardware saves only about 2% from INT8 to
INT6 because sign extension keeps upper bits active.  Native narrowing removes
hardware and is substantially more effective.  Holding the sign bit positive
is the strongest activity lever: INT6 all-positive inputs on the fixed INT8
netlist consume less than the native signed-INT6 design.

## Accepted PaYN power breakdown

| block | total power (mW) | dynamic energy (pJ/MAC) | static leakage (mW) | total energy (pJ/MAC) |
|---|---:|---:|---:|---:|
| InnerPE array (`u_pe`) | 15.824571 | **0.613971** | 0.106901 | 0.618147 |
| binary-to-unary peripheral (`u_peripheral`) | 1.840630 | **0.070468** | 0.036652 | 0.071900 |
| Sobol banks (`u_a_rng` + `u_w_rng`) | 0.721971 | **0.027954** | 0.006356 | 0.028202 |
| shared/top-level overhead | 0.144001 | **0.005460** | 0.004214 | 0.005625 |
| **full array** | **18.531170** | **0.717854** | **0.154123** | **0.723874** |

Dynamic energy is each block's cell-internal plus net-switching power divided
by 25.6 GMAC/s.  Static leakage remains in mW; total energy includes its
throughput-amortized contribution.  In their native accounting, the
converter's total is 0.002247 pJ/output bit and the Sobol banks' total is
0.056404 pJ/Sobol word.

The full-chip PT-PX split is:

| component | power (mW) | share |
|---|---:|---:|
| net switching | 9.804754 | 52.91% |
| cell internal | 8.572295 | 46.26% |
| leakage | 0.154123 | 0.83% |

Expressed as dynamic energy plus static leakage, the accepted result is:

| metric | value |
|---|---:|
| dynamic power (net switching + cell internal) | 18.377049 mW |
| **dynamic energy** | **0.717854 pJ/MAC** |
| **static leakage** | **0.154123 mW** |
| leakage energy at 25.6 GMAC/s | 0.006020 pJ/MAC |
| total energy (dynamic + amortized leakage) | 0.723874 pJ/MAC |

Dynamic energy is `(9.804754 + 8.572295) / 25.6`.  Leakage is reported
separately in mW because it is paid with wall-clock time rather than per
operation; the leakage-energy row is its throughput-dependent equivalent.

Wire and net switching remain the main physical limiter.  The accepted
row/column distribution guides are combined with workload-aware dynamic-power
optimization and high-effort detailed wirelength placement.  Relative to the
previous accepted route, the new route cuts total capacitance 0.99%, cell
internal power 1.85%, and total power 0.79%; see
[`SC_wire_optimization.md`](SC_wire_optimization.md).

## Routed power versus stochastic length

The accepted pending-bit `LOW_W=9` route was reused without synthesis or APR.
Every point contains 3,072 productive clocks; magnitude and sign reload every
`T/M` clocks while all `M=16` generated stochastic bits continue changing
every clock.  Each max-SDF drain matches the independent streaming reference,
and every SAIF has zero unknown time in the accumulator.

### Compute-array boundary only

| T | reuse cycles | useful MAC/cycle | array power (mW) | array pJ/MAC |
|---:|---:|---:|---:|---:|
| 32 | 2 | 256.000 | 17.66294 | **0.172490** |
| 48 | 3 | 170.667 | 17.41351 | **0.255081** |
| 64 | 4 | 128.000 | 16.53351 | **0.322920** |
| 96 | 6 | 85.333 | 16.15920 | **0.473414** |
| 128 | 8 | 64.000 | 15.97527 | **0.624034** |

The compute-array boundary is the complete `u_pe`: all 64 arithmetic tiles,
their stochastic-bit/sign pipeline registers, and in-array distribution.  It
excludes the binary-to-unary peripheral, both Sobol banks, and shared top-level
overhead.  These are therefore the isolated array-compute MAC energies, not
full-design energies.

For reference, the corresponding full-design results are:

| T | full power (mW) | full pJ/MAC |
|---:|---:|---:|
| 32 | 22.45022 | 0.219240 |
| 48 | 21.28062 | 0.311728 |
| 64 | 19.94216 | 0.389495 |
| 96 | 19.10784 | 0.559800 |
| 128 | 18.69109 | 0.730121 |

The corresponding dynamic-energy split is:

| T | PE core | conversion | Sobol | shared | **total dynamic** |
|---:|---:|---:|---:|---:|---:|
| 32 | 0.171510 | 0.036453 | 0.007075 | 0.002831 | **0.217869** |
| 48 | 0.253612 | 0.042180 | 0.010613 | 0.003265 | **0.309671** |
| 64 | 0.320964 | 0.047934 | 0.014151 | 0.003706 | **0.386754** |
| 96 | 0.470482 | 0.059402 | 0.021226 | 0.004579 | **0.555689** |
| 128 | 0.620126 | 0.070760 | 0.028301 | 0.005453 | **0.724640** |

All entries above are pJ/MAC and exclude leakage.  Static leakage by component
is:

| T | PE core (mW) | conversion (mW) | Sobol (mW) | shared (mW) | **total leakage (mW)** |
|---:|---:|---:|---:|---:|---:|
| 32 | 0.100346 | 0.031338 | 0.005395 | 0.003388 | **0.140466** |
| 48 | 0.100228 | 0.031392 | 0.005395 | 0.003388 | **0.140403** |
| 64 | 0.100164 | 0.031413 | 0.005395 | 0.003389 | **0.140361** |
| 96 | 0.100084 | 0.031441 | 0.005395 | 0.003388 | **0.140308** |
| 128 | 0.100060 | 0.031456 | 0.005395 | 0.003389 | **0.140300** |

These component values come from each saved `cell_power.rpt`; shared overhead
is the full-chip PT-PX total minus the three named hierarchies.

Shorter reuse raises instantaneous power because the held binary magnitudes and
signs reload more frequently.  From T=128 to T=32, total power rises 20.1%,
but useful throughput rises 4x, so energy per completed MAC falls 70.0%.
Sobol power stays constant at 0.72991 mW because it advances every cycle.
The T sweep reuses the previous accepted route.  Its matched T=128 control is
within 0.07% of that route's 18.67898 mW result; it has not been regenerated
on the new 18.53117 mW workload-aware route.

## Routed PaYN checkpoint comparison

Every row below was rerun with the same corrected 256-block workload, passed
the streaming bit-exact drain check, and produced a valid routed max-SDF SAIF.
Energy uses the common 25.6 GMAC/s useful rate.

| routed checkpoint | area (µm²) | setup / hold WNS (ns) | power (mW) | pJ/MAC | physical status |
|---|---:|---:|---:|---:|---|
| **pending-bit, LOW_W=9 + workload power opt + guides** | **51,871** | **+0.627 / +0.029** | **18.53117** | **0.723874** | clean |
| pending-bit, LOW_W=9 + guides (prior route) | 52,185 | +0.558 / +0.019 | 18.67898 | 0.729648 | clean |
| direct segmented, LOW_W=8 + guides | 50,786 | +0.230 / +0.049 | 18.78374 | 0.733740 | clean antenna-ECO export |
| baseline + row/column guides | 51,023 | +0.279 / +0.029 | 20.62757 | 0.805764 | 9 antenna violations |
| compensated segmented, LOW_W=8 + guides | 52,333 | +0.321 / +0.038 | 20.65121 | 0.806688 | 2 DRC, 72 antenna violations |
| baseline + guides + preserved fanout tree | 51,731 | +0.246 / +0.026 | 21.61643 | 0.844392 | 7 antenna violations |
| unguided baseline | 51,053 | +0.127 / +0.040 | 21.62573 | 0.844755 | 2 DRC, 9 antenna violations |
| WDBI bit-decode + guides | 57,924 | +0.140 / +0.029 | 24.99178 | 0.976241 | clean analysis route |

The row/column guides save 4.62% versus the unguided baseline.  Preserving an
explicit low-fanout tree gives that gain back.  Direct segmented is 2.7%
smaller than pending but consumes 0.56% more energy.  WDBI reduces activity on
the encoded W roots, but its decoder/control network raises whole-array energy
21.2% above the guided baseline.

Two subsequent accumulator experiments did not beat pending:

- Source-isolating the 24-bit drain chain passed RTL, synthesized, routed, and
  passed max-SDF output checking.  Against the matched 3,072-cycle T=128
  control it consumed 19.20351 mW / 0.750137 pJ/MAC, **2.74% more energy**.
  Area rose 1.08% and total routed wire rose 4.54%; the analysis route also
  retained two geometry DRCs.  The isolation gates eliminated compute-phase
  activity on the drain links, but their placement and control routing cost
  more net power than the links saved.
- Block-retired sign compensation passed RTL and synthesized 2.40% smaller,
  but matched synthesis power rose from 8.0398 to 8.3091 mW (**+3.35%**).
  Its biased `M-hit` negative operands switch too densely, so it was rejected
  before spending an APR run.

Earlier binary tables mistakenly reported routed instance counts (24,944,
23,139, and 21,316) as square-micron area.  They now use Innovus functional
standard-cell area, excluding physical-only filler and antenna cells, which is
the same metric used for the PaYN route comparisons.

## Experimental library results

A6P5/SVT measurements are intentionally excluded from the A7 headline and
accepted-result tables in this document.  They are tracked separately in
[`A6P5_results.md`](A6P5_results.md).

The rejected physical native-seven-bit A7 experiment reduced routed area by
4.83% and wire by 9.24%, but changed stochastic-stream activity, increased
energy by 5.02%, and retained four geometry plus 28 antenna violations.  Its
implementation was removed after this result was recorded.

## Current architecture verdict

| design point | status | reason |
|---|---|---|
| pending-bit signed segmented, `LOW_W=9` | **accepted** | best clean routed PaYN checkpoint; current workload rerun complete |
| native 7-bit converter/Sobol | rejected | 4.83% smaller routed area, but InnerPE activity raises energy 5.02%; route also has DRC/antenna violations |
| direct / centered segmented | rejected | direct is 0.56% higher energy than pending after the clean-route rerun |
| compensated / fused / recurrent CSA heaps | rejected | compensated is 10.6% above pending; other pre-layout gains did not survive |
| 24-bit drain-chain source isolation | rejected | matched routed energy is 2.74% higher and routed wire is 4.54% longer |
| block-retired sign compensation | rejected before APR | 2.40% smaller at synthesis, but matched synthesis power is 3.35% higher |
| W-bus temporal DBI | rejected | clean routed WDBI is 21.2% above the guided baseline |
| explicit two-level A/W tree | rejected | 4.8% above simple guides and 1.4% larger |
| projected 7-bit converter | rejected | matched routed energy is 3.36% above pending |
| W-only distribution tree | rejected | matched routed energy is 3.04% above pending |
| registered-delta pipeline | rejected | matched routed energy is 24.9% above pending |
| grouped G2/G4 heaps | rejected at N=1 | both routed screens consume more energy than the lane-popcount control |
| zero-extended 7-bit power workload | invalid | halved stochastic density by comparing `0..127` directly against 8-bit thresholds |

Architecture details:

- Pending accumulator: [`signed_segmented/README.md`](../designs/payn/variants/signed_segmented/README.md)
- Wire placement: [`SC_wire_optimization.md`](SC_wire_optimization.md)
- Timing and multibit flops: [`SC_timing_multibit.md`](SC_timing_multibit.md)
- Power anatomy: [`SC_breakdown.md`](SC_breakdown.md)

## Result provenance

Accepted PaYN checkpoint:

```text
apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED/k8m16n8_lw9_distguide
```

Current artifacts:

```text
reports/power.rpt
reports/power_hier.rpt
reports/cell_power.rpt
activity/dut.saif
```

Reproduce the hierarchy accounting without rerunning APR or PT-PX:

```sh
python3 sweeps/report_sc_arch_energy.py \
  apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED/k8m16n8_lw9_distguide/reports/cell_power.rpt \
  --k 8 --m 16 --nh 8 --nw 8 --t 128
```

## Superseded results

The old `PAYN_SC` T sweep, tile sweep, vectorless synthesis estimates,
held-magnitude routed comparisons, and variants absent from the table above are
not current headline results.  They were generated before the long-running
`T/M` reload schedule and normalized 7-bit magnitude encoding were fixed.
Rerun any additional candidate with the current bench before using it for an
architecture decision.
