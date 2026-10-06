# Bit-plane INT mode with sub-ring laps (`signed_segmented_csa_bp_sr`)

This variant puts the weight-pass lap length on a knob, `LAP_G`. It came out of
the review of in-place doubling (T3,
[`signed_segmented_csa_bp_ipd`](../signed_segmented_csa_bp_ipd/README.md)). The
review pointed out that the BP ring (8-edge laps) and IPD (1-edge laps) are the
two ends of one family.

**How it works.** Each tile row's 8-tile drain chain is split into 8/g sub-rings
of g tiles. Only the head tile of each sub-ring gets a 24-bit 2:1 mux on its
`acc_in`: it takes the west neighbour, or on a lap edge the sub-ring's tail
value << 1. A lap is g edges. Each edge rotates every sub-ring one tile east,
and the value that wraps from tail to head is doubled. After g edges, every
value is back in its own tile and has been doubled exactly once.

| g (`LAP_G`) | muxes / PE | lap edges | design |
|---|---:|---:|---|
| 8 | 8 | 8 | BP ring, `csa_bp_20261004_lap`. Here the mux sits in front of tile 0 rather than at the PE west input; the function is the same and the traces are byte-identical |
| 4 | 16 | 4 | `csa_bp_sr4_20261004` |
| 2 | 32 | 2 | `csa_bp_sr2_20261004` |
| 1 | 64 | 1 | in-place doubling, `csa_bp_ipd_20261004`; byte-identical traces |

The tile module, the drain, SC mode and the sign path are unchanged. The INT
block period is `BW*NB + g*(BW-1) + (P_R+P_C-2) + 8*P_C` edges.

## Bottom line

The areas are synthesized but not routed, and the g = 2 / 4 synthesis needs a
clean rerun (see Synthesis).

- **g = 2 gets almost all of in-place doubling's INT gain for 44% of its SC
  cost.**
  - **4x4 at L=4096:** INT8 runs 1,265 GMAC/s/mm2 against 1,274 for IPD
    (99.3%) and 1,128 for the BP ring.
  - **SC:** -1.26% on 4x4 and -1.30% on 4x8 against the BP ring, where IPD
    costs -2.84% and -2.92%.
  - **Area:** `u_pe` grows by +423.5 um2 per PE, against +969.3 for IPD.
- **g = 4 is the cheap step.** INT8 gains +8.2% on 4x4 at L=4096 and +21% at
  L=1024, for -0.43% SC.
- **Marginal returns on a 4x4 at L=4096, INT8 against SC:**

  | step | INT8 | SC |
  |---|---:|---:|
  | g 8 -> 4 | +8.2% | -0.43% |
  | g 4 -> 2 | +3.7% | -0.83% |
  | g 2 -> 1 | +0.7% | -1.60% |

  IPD's last step costs more than it returns.
- **Against plain CSA (no INT mode)**, 4x4 SC GMAC/s/mm2 changes by:

  | g = 8 | g = 4 | g = 2 | g = 1 |
  |---:|---:|---:|---:|
  | -1.92% | -2.35% | -3.16% | -4.71% |

- **What dominates after g = 2 is the drain.** On a 4x4 the overhead is
  14 lap + 6 skew + 32 drain edges out of 308. On a 4x8 it is 14 + 10 + 64
  out of 344.
- **The SRAM question decides whether any of this matters.** If the SC-sized
  SRAM delivers only the T=128 average, bit-plane INT is memory-bound (about 7%
  of peak), and the lap length does not matter at all. Any lap hardware beyond
  the BP ring is then pure SC cost.

## Files

| file | module | what |
|---|---|---|
| `inner_pe_core_signed_segmented_csa_sr.sv` | `InnerPESignedSegmentedCsaSr #(LAP_G)` | copy of the CSA PE core with a `lap` input and a head mux at every LAP_G-th tile: `tile_acc_in = lap ? acc_out(tail) << 1 : acc_chain[v]`. Instance names unchanged (`g_row`/`g_col`/`u_inner`, `a_bits_pipe`, `w_bits_pipe`) |
| `inner_pe_signed_segmented_csa_bp_sr.sv` | `InnerPESignedSegmentedCsaBpSrFlat #(LAP_G)` | PE wrapper: registered `ring_q`, `core_shift = shift_in \| ring_q`, `lap = ring_q`, no west mux; core instance `u_array_core` |
| `payn_array_signed_segmented_csa_bp_sr.sv` | `payn_array_signed_segmented_csa_bp_sr` | single-PE top. `LAP_G` defaults to `` `PAYN_LAP_G `` (2). It reuses `sc_pe_peripheral_bp` and `PaynBpCombiner`, and the header holds the full sequencer contract |
| `inner_pe_grid_signed_segmented_csa_bp_sr.sv` | `InnerPESignedSegmentedCsaBpSrGrid` | P_R x P_C grid wrapper with the BP grid's wiring (verification wrapper, not synthesized) |
| `syn/targets/TSMC22/PAYN_SC_CSA_BP_SR2`, `_SR4` | | copies of `PAYN_SC_CSA_BP` that differ only in `TOP`, `SRC_SV` and `PAYN_LAP_G=<g>` in `SYN_DEFINES` |

If LAP_G does not divide N_W, the last sub-ring is shorter. This only matters
for the default 9x9 SC drop-in shape, which elaborates with `lap = 0`. INT mode
is defined for 8x8 PEs with g in {1, 2, 4, 8}.

## Contract (difference from the BP top)

- **Lap length.** A lap is exactly g consecutive `ring_in` edges, driven one
  edge ahead (`ring_q` lags it).
  - A run of k != g edges permutes each sub-ring: it rotates by k and doubles
    the k values that wrap.
  - BP (8-edge) and IPD (1-edge) schedules are therefore compatible only when
    g matches their lap length.
- **Lap edges drop the MAC.** The MACs on all g lap edges are dropped (shift
  priority), so a non-final weight pass takes NB + g edges.
- **`shift_in` on a single PE.** Asserting `shift_in` on lap edges is harmless.
- **Grid.** Laps are at offset r+c, so on any grid larger than 1x1 no edge has
  every PE lapping. The global `shift_in` must be low on lap edges and is used
  for drains only.
- **SC mode.** `ring_in` is gated by `int_mode`, so every tile takes its west
  neighbour, as in the CSA core.

## Verification (RTL; all logs in `build/rtl_preflight/bp_sr/`)

- **Opt-in bench extensions.** Both IPD benches gained an opt-in define that
  selects the SR DUT: `BPT_DUT_SR` in `test_payn_array_bp_ipd.sv` and
  `BPG_DUT_SR` in `test_pe_grid_bp_ipd.sv`, with `+define+PAYN_LAP_G=<g>`.
  The IPD single-PE check script gained an opt-in `OUT` override.
  - **Defaults unchanged:** I re-ran the IPD checks: `run_bp_ipd_rtl_checks.sh`
    with `PARTS="int xcheck"`, and `run_bp_ipd_grid_checks.sh`.
  - **Result:** all 488 trace, schedule and check files are byte-identical to
    the earlier run (`regress_ipd_compare.txt`).
- **SC** (`sweeps/int_mode/bp/sr/run_bp_sr_rtl_checks.sh`, part `sc`).
  - Run for g = 2 and 4, with the INT inputs tied off and with INT junk.
  - The array cosim and the 384-batch streaming traces are byte-identical to a
    fresh CSA top run.
  - The default 9x9/K6 shape with junk matches as well.
- **INT, single PE** (part `int`). 69 cases per g, with every drained tile and
  combiner word bit-exact against numpy.
  - **Positive cases (42 per g):** INT8, W4A8 and INT4; extremes; near-limit
    lengths (INT8 65,408 and W4A8/INT4 1,048,448); multi-block runs; JUNK;
    MODE_AT=3; both shift contracts.
  - **Negative controls (27 per g), all failing as required:**
    - `LAP_LEN` = 0, g-1, g+1, 2g, 1 (the IPD schedule) and 8 (the BP schedule);
    - no ring, stray ring and mid-pass stray ring;
    - no bubble, wrong precision, live magnitudes, `int_mode` one edge late.
  - **Periods:** every period equals `BW*NB + g*(BW-1) + 8`.
  - **Pending carries:** lap edges folded a pending carry 1,625 times and a
    pending borrow 277 times.
- **Collapse cross-check** (part `xcheck`).
  - The SR top at g = 1 reproduces the IPD top's traces byte for byte (14/14
    cases).
  - At g = 8 it reproduces the BP top's traces (14/14).
- **INT, PE grid** (`run_bp_sr_grid_checks.sh`). 196 cases, ALL AS EXPECTED.
  - **Matrix, run per g:** the IPD grid matrix on 4x1, 2x2, 2x3, 3x2, 4x4 and
    4x8 (93 cases per g, 47 of them negative), plus per-g lap-length negatives.
    The checker confirms bit-exact tiles and outputs, lap runs of g edges at
    offset r+c, and the period formula.
  - **Grid collapse cross-check (10 cases):** SR g = 1 matches the IPD grid and
    g = 8 the BP grid, with full traces byte-identical.
- **PE random bench** (`run_bp_sr_pe_review.sh`, `tb_sr_pe_review.sv`,
  generalized from the IPD review bench). Run for g = 1, 2, 4 and 8, 3 seeds of
  200k cycles each.
  - **Phase A** compares against the CSA PE with `ring_in` = 0.
  - **Phase B** compares against a per-edge bit-exact model with random lap runs
    (exactly g edges, or any length), reset on lap edges, pending carries and
    borrows at lap edges, and doubling across the sign bit. A full-lap check
    tests that every tile doubles after each g-edge lap.
  - **Mutants:** a DUT built with a different g than the model must fail.
  - Results: `pe_review/rtl_g*.log` and `pe_review_run.log`.
- **Adversarial grid harness, ported** (`sweeps/int_mode/bp/sr/verify_grid/run_vg_lap.sh`).
  `verify_grid/run_vg.sh` now has a lap-length knob. It covers reset and abort
  in the middle of a lap and of a pass, one-edge ring-wave and schedule faults,
  SC ring junk and INT->SC->INT. Shapes are 1x1, 1x4, 1x8, 4x1, 8x1, 2x3, 4x4
  (LOW_W=7) and 4x8.
  - **Coverage:** 209 scenarios each on the BP, IPD, SR2 and SR4 grids, ALL AS
    EXPECTED (110 negative controls caught per DUT).
  - **Port check:** the ported generator at lap length 8 writes byte-identical
    files to the original.
  - **BP rows:** all 209 traces equal the original 16:43 run
    (`verify_grid/bp_vs_original.txt`).

## Synthesis (DC, TSMC22, 400 MHz, `PAYN_SC_CSA_BP` knobs)

| um2 | BP ring (g=8) `csa_bp_20261004_lap` | g=4 `csa_bp_sr4_20261004` | g=2 `csa_bp_sr2_20261004` | IPD (g=1) |
|---|---:|---:|---:|---:|
| total | 45,522.8 | 45,613.3 (+90.6) | 45,893.4 (+370.6) | 46,492.4 (+969.6) |
| `u_pe` | 29,390.4 | 29,534.5 (**+144.1**, +0.49%) | 29,813.9 (**+423.5**, +1.44%) | 30,359.7 (+969.3, +3.30%) |
| 64 tiles | 26,197.9 | 26,206.4 (+8.5) | 26,214.6 (+16.7) | 26,218.1 (+20.2) |
| core-local muxes and select tree | 61.8 | 333.0 (+271.2) | 604.2 (+542.3) | 1,146.5 (+1,084.7) |
| `u_pe` outside the core (BP west mux) | 137.8 | 2.3 (-135.5) | 2.3 (-135.5) | 2.3 (-135.5) |
| `u_peripheral` (RTL unchanged) | 14,037.0 | 13,983.5 (-53.5) | 13,984.2 (-52.8) | 14,037.3 (+0.3) |
| worst slack (ns) | +0.94 | +0.94 | +0.93 | +0.91 |

- **Cost per mux bit.** The muxes cost about 0.706 um2 per bit locally,
  including the select tree, in every run; the BP west mux costs the same. The
  tiles grow slightly from sizing.
- **Against the review's estimate** of 0.721 um2/bit: it predicted +138.5
  (g=4) and +415.5 (g=2), against the synthesized `u_pe` deltas of +144.1 and
  +423.5.
- **Peripheral.** The -53 um2 in `u_peripheral` for g = 2 / 4 is DC run-to-run
  noise: its RTL is unchanged. The GMAC/s/mm2 estimates therefore carry only
  the `u_pe` delta.
- **Warnings.** The warning set equals the lap run's, with one exception
  (next bullet).

**These two runs need a clean rerun.** The AFS token expired during them.
- **What happened:** both loaded the libraries, but DC could not write its
  library-analysis cache. It logged `Loaded alib file ... (placeholder)` and
  `Warning: Only placeholder alibs were found. Proceeding with library analysis.
  (OPT-1311)`.
- **Earlier runs:** the CSA, lap and IPD runs all wrote full 3.9 MB alibs.
- **Effect on QoR:** probably small. The mux cost per bit agrees with the IPD
  run to within 1%. It is unverified, though.
- **Missing results:** a sequential rerun failed at setup (`incomplete TSMC22
  base library flavor`, AFS Permission denied). The first runs' `area.rpt`,
  `synth.log` and `check_design.rpt` are kept in
  `build/rtl_preflight/bp_sr/syn/placeholder_alib_runs/`; their netlists were
  not kept. So DC path probes, post-synthesis GL and power have **not** been run
  for g = 2 / 4.

## Block periods (bit-exact RTL runs, edges per output block)

| grid | prec | L | g=8 | g=4 | g=2 | g=1 |
|---|---|---:|---:|---:|---:|---:|
| 1 PE | INT8 | 1024 | 128 (50.0%) | 100 (64.0%) | 86 (74.4%) | 79 (81.0%) |
| 1 PE | INT8 | 4096 | 320 (80.0%) | 292 (87.7%) | 278 (92.1%) | 271 (94.5%) |
| 4x4 | INT8 | 1024 | 158 (40.5%) | 130 (49.2%) | 116 (55.2%) | 109 (58.7%) |
| 4x4 | INT8 | 4096 | 350 (73.1%) | 322 (79.5%) | **308 (83.1%)** | 301 (85.0%) |
| 4x8 | INT8 | 1024 | 194 (33.0%) | 166 (38.6%) | 152 (42.1%) | 145 (44.1%) |
| 4x8 | INT8 | 4096 | 386 (66.3%) | 358 (71.5%) | 344 (74.4%) | 337 (76.0%) |
| 4x4 | W4A8/INT4 | 4096 | 190 (67.4%) | 178 (71.9%) | 172 (74.4%) | 169 (75.7%) |
| 4x8 | W4A8/INT4 | 4096 | 226 (56.6%) | 214 (59.8%) | 208 (61.5%) | 205 (62.4%) |

## GMAC/s/mm2 (g < 8: ESTIMATE = routed pinned lap blocks + synthesized `u_pe` delta)

The script is `sweeps/int_mode/bp/sr/sr_area_efficiency.py`, with output in
`build/rtl_preflight/bp_sr/area_efficiency.txt`.
- **Composites (um2):**

  | | 1 PE | 4x4 | 4x8 |
  |---|---:|---:|---:|
  | g=8 | 46,096.5 | 531,321.5 | 1,029,540.4 |
  | g=4 | 46,240.5 | 533,626.5 | 1,034,150.3 |
  | g=2 | 46,519.9 | 538,096.8 | 1,043,091.0 |
  | g=1 | 47,065.8 | 546,830.6 | 1,060,558.5 |
  | routed pinned CSA | 43,916.5 | 521,100.2 | 1,014,576.3 |

- **Other estimation methods:** block-by-block deltas and ratio scaling move
  the 4x4 composites by at most 226 um2 (0.04%).

| mode | grid | L | CSA | g=8 | g=4 | g=2 | g=1 |
|---|---|---:|---:|---:|---:|---:|---:|
| SC T=128 peak | 1 PE | - | 582.9 | 555.4 | 553.6 | 550.3 | 543.9 |
| SC T=128 peak | 4x4 | - | 786.0 | 770.9 | 767.6 (-0.43%) | 761.2 (-1.26%) | 749.0 (-2.84%) |
| SC T=128 peak | 4x8 | - | 807.4 | 795.7 | 792.1 (-0.45%) | 785.4 (-1.30%) | 772.4 (-2.92%) |
| INT8 | 4x4 | 1024 | - | 624.5 | 755.8 (+21.0%) | 839.9 (+34.5%) | 879.6 (+40.8%) |
| INT8 | 4x4 | 4096 | - | 1,127.7 | 1,220.5 (+8.2%) | **1,265.4 (+12.2%)** | 1,274.1 (+13.0%) |
| INT8 | 4x8 | 1024 | - | 525.0 | 610.8 (+16.3%) | 661.4 (+26.0%) | 681.9 (+29.9%) |
| INT8 | 4x8 | 4096 | - | 1,055.4 | 1,132.9 (+7.3%) | 1,168.9 (+10.8%) | 1,173.5 (+11.2%) |
| W4A8 | 4x4 | 4096 | - | 2,077.4 | 2,207.9 | 2,265.9 | 2,269.3 |
| INT4 | 4x8 | 4096 | - | 3,605.3 | 3,790.5 | 3,866.4 | 3,858.3 |

The INT area tax over CSA on a 4x4 composite is:

| g = 8 | g = 4 | g = 2 | g = 1 |
|---:|---:|---:|---:|
| +10,221 um2 (+1.96%) | +12,526 (+2.40%) | +16,997 (+3.26%) | +25,730 (+4.94%) |

## Blocked: needs a valid AFS token (`kinit && aklog`)

Every step below reads the ARM libraries or cell models on AFS. The scripts are
written but **not yet run**:

```bash
bash sweeps/int_mode/bp/sr/synth_bp_sr.sh 2 && bash sweeps/int_mode/bp/sr/synth_bp_sr.sh 4   # clean rerun, one at a time
python3 sweeps/int_mode/bp/syn_area_delta.py syn/build/TSMC22/PAYN_SC_CSA_BP/csa_bp_20261004_lap syn/build/TSMC22/PAYN_SC_CSA_BP_SR2/csa_bp_sr2_20261004
python3 sweeps/int_mode/bp/sr/sr_area_efficiency.py                 # picks the new runs up automatically
bash sweeps/int_mode/bp/sr/report_bp_sr_new_paths.sh csa_bp_sr2_20261004 PAYN_SC_CSA_BP_SR2 2   # loops, head path, ring_q fanout
G=2 bash sweeps/int_mode/bp/sr/run_bp_sr_syn_gl_checks.sh           # post-synthesis GL (SC + INT vs RTL traces)
PARTS=gl G=2 bash sweeps/int_mode/bp/sr/run_bp_sr_pe_review.sh      # synthesized SR PE in lock step with the RTL PE
bash sweeps/int_mode/bp/sr/run_sc_prelayout_power_ab.sh             # SC pJ/MAC A/B: csa, lap, sr4, sr2, ipd
```

Also open: none of g = 1, 2 or 4 is routed, and INT energy is not measured.

## Reproduce (RTL, no AFS needed)

```bash
bash sweeps/int_mode/bp/sr/run_bp_sr_rtl_checks.sh       # SC equivalence, INT matrix (g=2,4), collapse cross-check (g=1,8)
bash sweeps/int_mode/bp/sr/run_bp_sr_grid_checks.sh      # PE grids, g-edge per-PE laps, grid collapse cross-check
bash sweeps/int_mode/bp/sr/run_bp_sr_pe_review.sh        # PE random bench g=1,2,4,8 + mutants
bash sweeps/int_mode/bp/sr/verify_grid/run_vg_lap.sh     # adversarial grid harness on BP / IPD / SR2 / SR4 grids
python3 sweeps/int_mode/bp/sr/sr_area_efficiency.py      # GMAC/s/mm2 estimate (needs the bench runs)
```
