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
| BP + asym corr | 4096 | 11.62 | 0.454 |
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
| BP + asym | 5.26 | 6.31 | 0.061 | 11.62 |
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
