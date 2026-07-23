# PaYN — Results

Numbers referenced by `doc/experiments.md`. TSMC22, 2.5 ns, `svt_c30/sc7mcpp140z` @ 0.80 V.
Area = cell area (µm²). Slack/WNS in ns (positive = met). Workload power = routed-SDF SAIF → PrimeTime-PX.
`pJ/MAC = power · 2.5 ns / MAC-per-cycle` — SC = `K·M·N²/T`, BP/INT = 64, BS = 8, UR/UT = 64/RATE_LEN.

## Area & timing (per netlist)

| design | synth area | synth slack | APR area | APR WNS |
|---|---:|---:|---:|---:|
| BP INT8 (`BP_ARRAY`) | 14 784 | +1.42 | 24 944 | +1.040 |
| BP INT7 native | 13 386 | +1.47 | 23 139 | +1.109 |
| BP INT6 native | 11 516 | +1.50 | 21 316 | +1.104 |
| BP + asym corr (`BP_ARRAY_ASYM`) | 17 785 | +1.16 | 29 341 | +0.430 |
| BS (`BS_ARRAY`) | 11 537 | +1.40 | 21 813 | +0.802 |
| UR (`UR_ARRAY`) | 8 656 | +1.41 | 15 304 | +0.903 |
| UT (`UT_ARRAY`) | 8 427 | +1.50 | 15 158 | +1.027 |
| **SC array (`PAYN_SC`)** | 45 559 | +0.84 | 64 332 | **+0.083** |
| SC PE (`SC_INNER_PE`) | 31 237 | +1.10 | 53 126 | +0.225 |

Notes: SC array closes with only +0.083 ns margin (the svt/sc7 switch was needed to close at all). APR grows cell area ~1.4–1.7× over synth (CTS + buffering). `SC_INNER_PE` is the standalone compute PE (K6·M16·9×9·OW24).

## Workload power & pJ/MAC — **APR** (routed, output-checked)

| design | T / RATE_LEN | power (mW) | pJ/MAC |
|---|---:|---:|---:|
| BP INT8 | 4096 | 10.60 | 0.414 |
| BP INT7 native | 4096 | 9.53 | 0.372 |
| BP INT6 native | 4096 | 8.16 | 0.319 |
| BP + asym corr | 4096 | 11.75 | 0.459 |
| BS | 4096 | 5.95 | 1.860 |
| UR | 64 / 128 / 256 | 2.84 / 2.83 / 2.83 | 7.10 / 14.17 / 28.34 |
| UT | 64 / 128 / 256 | 2.48 / 2.03 / 1.92 | 6.20 / 10.17 / 19.23 |
| **SC array** | 64 / 128 / 256 | 23.69 / 23.71 / 23.57 | 0.487 / 0.976 / 1.940 |

SC pJ/MAC above is the **full array** (incl. peripheral + Sobol). Compute-PE only (`u_pe`, 90% of the array) is ~10% lower: **0.87 pJ/MAC** at T=128.

## Power composition — APR workload (dynamic vs leakage)

Dynamic = net-switching + cell-internal. Leakage is <2% everywhere. (BP/BS at T=4096; UR/UT/SC at T=256.)

| design | net switching | cell internal | leakage | total |
|---|---:|---:|---:|---:|
| BP INT8 | 4.79 (45%) | 5.76 (54%) | 0.053 | 10.60 |
| BP INT7 native | 4.21 | 5.27 | 0.050 | 9.53 |
| BP INT6 native | 3.53 | 4.58 | 0.045 | 8.16 |
| BP + asym | 5.31 | 6.38 | 0.062 | 11.75 |
| BS | 2.52 | 3.38 | 0.046 | 5.95 |
| UR | 1.14 | 1.66 | 0.035 | 2.83 |
| UT | 0.79 | 1.10 | 0.032 | 1.92 |
| **SC array** | 12.67 (54%) | 10.76 (46%) | 0.138 | 23.57 |

SC's **net-switching share (54%) > BP's (45%)** — the routed wire cap on the M-wide stochastic buses (the PnR-inflation signature).

## BP input precision — INT8 native HW fed quantized inputs (APR, output-checked)

Same `BP_ARRAY` netlist (INT8 hardware); inputs quantized to N bits, signed or all-positive. **Distinct** from the *native* INT7/6 rows above (which are narrower hardware). Driver: `sweeps/run_bp_input_power.sh` → `build/power_char/bp_input_regimes.csv`.

| input bits | signed (mW / pJ/MAC) | all-positive (mW / pJ/MAC) |
|---|---|---|
| INT8 | 10.60 / 0.414 | 9.01 / 0.352 |
| INT7 | 10.50 / 0.410 | 8.61 / 0.336 |
| INT6 | 10.42 / 0.407 | 7.75 / 0.303 |

- **Signed narrowing ≈ flat** (~2% INT8→INT6): sign-extension keeps the upper bits toggling.
- **All-positive dominates**: −15% at INT8 alone (static sign bit), compounding to **−27%** at INT6 all-positive.
- **vs native narrowing**: for signed inputs, native narrower HW wins (native INT6 = 8.16 ≪ signed-INT6-input 10.42). But INT6 *all-positive inputs* on the full INT8 HW (7.75) undercut even native-INT6 HW (8.16) — activity reduction can beat datapath shrinking.

## Tool power estimates — synth statistical (rough, **not** workload)

DC `report_power` with default/assumed activity (no SAIF). **Inaccurate — reference only:** the binary designs read far too low (clock-gating constant-propagation zeros most nets), and SC reads high (wireload model balloons the high-fanout ICG/Sobol nets). The APR workload numbers above are the real ones.

| design | dynamic | leakage | total | vs APR workload |
|---|---:|---:|---:|---|
| BP INT8 | 0.19 | 0.041 | 0.24 | ~44× low |
| BP INT7 native | 0.31 | 0.036 | 0.35 | ~27× low |
| BP INT6 native | 0.30 | 0.033 | 0.33 | ~25× low |
| BS | 0.37 | 0.032 | 0.40 | ~15× low |
| UR | 0.29 | 0.025 | 0.31 | ~9× low |
| UT | 0.28 | 0.024 | 0.30 | ~6× low |
| SC array | 28.52 | 0.117 | 28.64 | ~1.2× high (WLM) |
| SC PE | 29.32 | 0.087 | 29.41 | — |

(For a *usable* pre-layout SC/BP estimate use the unit-delay workload numbers in the synth table above, not these.)

## Workload power & pJ/MAC — **synth** (pre-layout, unit-delay + `+notimingcheck`)

| design | power (mW) | pJ/MAC |
|---|---:|---:|
| SC PE (`SC_INNER_PE`, T=128) | 6.91 | 0.284 |
| BP INT8 (`BP_ARRAY`) | 5.03 | 0.196 |

## Headline: SC vs BP (pJ/MAC, PE-level)

| | SC PE | BP | **SC/BP** |
|---|---:|---:|---:|
| synth (intrinsic) | 0.284 | 0.196 | **1.45×** |
| APR (routed) | 0.872 | 0.414 | **2.11×** |

The 1.45×→2.11× widening is **PnR wire cap on the M=16-wide stochastic buses**: SC APR power is 54% net-switching vs BP's 45%, a 3.8× synth→APR jump vs BP's ~2×. (SCArch's hvt/sc6.5 reference kept its routed ratio near ~1.5×.)

## SC internal power split (`PAYN_SC`, APR)

| block | power | share |
|---|---:|---:|
| `u_pe` — InnerPE compute grid | 21.2 mW | 90.0% |
| `u_peripheral` — binary→stochastic | 1.28 mW | 5.4% |
| `u_w_rng` / `u_a_rng` — Sobol banks | 0.50 / 0.46 mW | 4.1% |

For the **functional** decomposition (cutting the total along compute vs. bit-pipes vs.
accumulators vs. clock — ~64–66% combinational for both the reference and the best sweep
config `k8·m16·n8`, bit-pipe power switching-dominated on the weight side) see
[`doc/SC_breakdown.md`](SC_breakdown.md).

## SC tile-config sweep (K∈{4,6,8} · M∈{8,16} · N∈{2,4,8}, OW24, T=128)

Trends the wiring/PnR cost vs array shape. **Complete: 18/18.** Full CSV: `build/power_char/sc_sweep.csv` (+ `sc_sweep_synpwr.csv`); per-config target = `PAYN_SC_SWEEP` driven by `SYN_DEFINES`/`RUN_NAME`. All configs cosim-verified (RTL + GL).

pJ/MAC given as **synth → APR (PnR inflation ×)**; synth = unit-delay, drain-cosim-verified.

| cfg (K·M·N) | area syn→APR (µm²) | WNS | mW | pJ/MAC syn→APR (×) | net-sw% |
|---|---|---|---|---|---|
| 4·8·2 | 2 672 → 5 384 | +0.96 | 0.90 | 1.33 → 2.26 (1.7) | 43 |
| 4·8·4 | 6 006 → 11 300 | +0.89 | 2.01 | 0.71 → 1.26 (1.8) | 46 |
| 4·8·8 | 17 394 → 32 808 | +0.68 | 7.19 | 0.52 → 1.12 (2.2) | 50 |
| 4·16·2 | 4 480 → 8 164 | +0.83 | 1.63 | 1.21 → 2.03 (1.7) | 42 |
| 4·16·4 | 9 618 → 16 685 | +0.73 | 3.40 | 0.59 → 1.06 (1.8) | 47 |
| 4·16·8 | 27 044 → 41 082 | +0.40 | 11.78 | 0.40 → 0.92 (2.3) | 50 |
| 6·8·2 | 3 357 → 6 319 | +0.83 | 1.10 | 1.04 → 1.83 (1.8) | 43 |
| 6·8·4 | 7 913 → 14 572 | +0.68 | 2.64 | 0.58 → 1.10 (1.9) | 48 |
| 6·8·8 | 23 801 → 36 295 | +0.42 | 10.72 | 0.45 → 1.12 (2.5) | 49 |
| 6·16·2 | 5 809 → 10 168 | +0.78 | 1.97 | 0.95 → 1.64 (1.7) | 44 |
| 6·16·4 | 13 028 → 22 291 | +0.53 | 4.38 | 0.49 → 0.91 (1.9) | 49 |
| 6·16·8 | 37 452 → 53 822 | +0.25 | 16.34 | 0.35 → 0.85 (2.4) | 53 |
| 8·8·2 | 4 118 → 7 576 | +0.77 | 1.28 | 0.92 → 1.60 (1.7) | 44 |
| 8·8·4 | 9 820 → 17 867 | +0.69 | 3.46 | 0.53 → 1.08 (2.0) | 50 |
| 8·8·8 | 29 702 → 44 682 | +0.33 | 14.17 | 0.41 → 1.11 (2.7) | 50 |
| 8·16·2 | 7 154 → 12 392 | +0.57 | 2.40 | 0.85 → 1.50 (1.8) | 46 |
| 8·16·4 | 16 877 → 26 274 | +0.46 | 6.00 | 0.47 → 0.94 (2.0) | 50 |
| 8·16·8 | 47 849 → 67 920 | +0.21 | 19.84 | 0.33 → 0.78 (2.4) | 54 |

Trends (full grid): **pJ/MAC ↓ with size** — 2.26 (smallest) → **0.78** at 8·16·8 (intrinsic 0.33); M16 beats M8 ~10–15%; K and N amortize, diminishing after N4. **PnR inflation ↑ with size** — synth→APR ratio **1.7× (small) → 2.7× (8·8·8)**: the biggest / N8 configs route worst, so the configs with the best *intrinsic* pJ/MAC take the largest routing hit (amortization partly clawed back by wiring). Corroborated by **net-switching** (42 → 54%) and **WNS** (+0.96 → **+0.21** at 8·16·8, near the 9×9's +0.083). Net: bigger arrays give the best pJ/MAC but the worst wiring metrics — routing is the SC's scaling limiter.

Follow-up physical experiments on K8·M16·8×8 found a successful row/column
distribution-guide recipe: routed wire 1.196M→1.113M µm, net capacitance
293.1→278.4 pF, and validated power 19.840→19.177 mW with positive setup/hold
WNS.  The measured two-level A/W tree cuts root fanout 8→5 but does not improve
whole-chip power beyond the guides.  See
[`doc/SC_wire_optimization.md`](SC_wire_optimization.md) for the full comparison.

## SC exact signed segmented accumulators

K8·M16·8×8, OW24, T=128, MBFF inference and clock gating enabled.  All listed
synthesis powers use the same validated unit-delay workload SAIF.  `Direct`
removes the two pending carry/borrow bits per tile; `centered` also shifts the
stored residue by half a radix.

| design | LOW_W | synth area (µm²) | synth WNS | synth power (mW) | pJ/MAC |
|---|---:|---:|---:|---:|---:|
| direct | 7 | 47,397 | +0.52 | 7.4303 | 0.29025 |
| direct | **8** | **47,312** | +0.76 | **7.3600** | **0.28750** |
| direct | 9 | 47,352 | +0.77 | 7.3775 | 0.28818 |
| direct | 10 | 47,319 | +0.78 | 7.3722 | 0.28798 |
| centered | 7 | 47,638 | +0.52 | 7.4328 | 0.29034 |
| centered | 8 | 47,544 | +0.76 | 7.3656 | 0.28772 |

The centered code reduces high-digit activity but adds row-boundary conversion
logic; at LOW_W=8 the net result is 0.08% more power than direct.  Direct
LOW_W=8 was therefore the only point promoted to APR.

| routed point | area (µm²) | setup / hold WNS | net / internal / leakage (mW) | total (mW) | pJ/MAC |
|---|---:|---:|---:|---:|---:|
| distribution-guide baseline | — | clean | — | 19.17723 | 0.74911 |
| pending-bit signed segmented, LOW_W=9 | 52,185 | +0.558 / +0.019 | 9.14355 / 8.16030 / 0.14091 | **17.44477** | **0.68144** |
| direct signed segmented, LOW_W=8 | 50,786 | +0.230 / +0.049 | 9.33385 / 8.07421 / 0.13577 | 17.54384 | 0.68531 |

The direct route is 8.52% below the baseline but 0.57% above the pending-bit
route.  Its final checkpoint adds two `ANTENNA2_A7PP140ZTS_C30` cells in place
of adjacent fillers; final placement, DRC, connectivity, and antenna checks are
clean.  The refreshed max-SDF netlist remains bit-exact with a validated SAIF,
although VCS emits timing-check warnings inside MBFF-packed operand pipes
despite positive routed STA.  The pending-bit LOW_W=9 implementation remains
the recommended routed design.

### Signed heap and recurrent-CSA follow-ups

Three isolated experimental tops preserve arbitrary-duration exactness:

- `compensated` replaces signed lane terms with `M-c` plus one shared
  `-M*negative_count` correction;
- `fused` puts all 128 compensated raw product bits in one heap; and
- `CSA` stores the low digit in two carry-save rows with a four-bit high-debt
  digit.

All rows below use the same validated K8/M16/8x8/T128 post-synthesis workload
SAIF methodology.

| design | LOW_W | synth area (um2) | synth WNS | synth power (mW) | pJ/MAC |
|---|---:|---:|---:|---:|---:|
| pending-bit reference | 9 | 49,034 | +1.44 | 7.4536 | 0.29116 |
| compensated | **8** | 48,904 | +1.44 | **7.2886** | **0.28471** |
| compensated | 9 | 48,858 | +1.44 | 7.2959 | 0.28500 |
| fused | 8 | 47,792 | +1.43 | 7.4221 | 0.28993 |
| fused | **9** | **47,689** | +1.43 | **7.4190** | **0.28980** |
| recurrent CSA | 8 | 53,657 | +0.59 | 8.0862 | 0.31587 |
| recurrent CSA | 9 | 54,303 | +0.65 | 8.2882 | 0.32376 |

Only compensated LOW_W=8 was promoted to the same row/column distribution-guide
APR screen:

| routed point | area (um2) | setup / hold WNS | routed wire (um) | net / internal / leakage (mW) | total (mW) | pJ/MAC |
|---|---:|---:|---:|---:|---:|---:|
| pending-bit LOW_W=9 | 52,185 | +0.558 / +0.019 | 1,121,179 | 9.14355 / 8.16030 / 0.14091 | **17.44477** | **0.68144** |
| compensated LOW_W=8 | 52,333 | +0.321 / +0.038 | 1,302,466 | 10.78818 / 8.43735 / 0.14105 | 19.36658 | 0.75651 |

Compensation reduces pre-layout power but introduces another heap operand plus
`M-c` logic on every negative lane.  Physical routing exposes the cost: final
wire is 16.2% longer and net switching power is 18.0% higher.  The 64 tiles
rise from about 10.575 to 11.401 mW, and the rest of `u_pe`/distribution wiring
accounts for most of the remaining increase.  The routed candidate passes
setup, hold, connectivity, max-SDF drain cosim, and SAIF validation, but retains
2 geometry DRC and 72 process-antenna violations.  It is an analysis-only
rejected route; the pending-bit LOW_W=9 design remains the winner.

## SC W-bus DBI candidates

Two W-only temporal-DBI receivers were added as distinct architecture tops.
Both are bit-exact at M=16 and close the 2.5 ns synthesis target.  Direct XNOR
decode also completed routed SDF/cosim, validated SAIF, and PT-PX.

| K·M·N | design | synth area (µm²) | vs baseline | synth slack (ns) |
|---|---|---:|---:|---:|
| 8·16·8 | baseline | 47,849 | — | +0.86 |
| 8·16·8 | W-DBI direct XNOR decode | 54,871 | +14.7% | +0.77 |
| 8·16·8 | W-DBI shared count correction | 56,337 | +17.7% | +0.76 |

At the routed direct-decode point, W-root capacitance falls 31.48→3.08 pF and
W-root switching falls 1.400→0.087 mW.  The added encode/decode/control network
nevertheless raises total capacitance 278.38→315.77 pF and validated power
19.177→23.251 mW (+21.2%); setup/hold remain positive at +0.140/+0.029 ns.
Direct decode is rejected as a power optimization for this workload, and the
larger count-correction design is not promoted to APR.  The DBI physical result
is an analysis-only, no-filler checkpoint; see [`doc/SC_dbi.md`](SC_dbi.md) for
the full metrics, equations, flow qualification, and reproduction commands.
