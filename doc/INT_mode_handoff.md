# INT mode on PaYN: handoff (2026-10-04)

State of the INT-mode exploration, written so a fresh session can resume.
- Design study and all numbers: [`INT_mode_on_PaYN.md`](INT_mode_on_PaYN.md), sections 1-10.
- The implemented design: [`designs/payn/variants/signed_segmented_csa_bp/README.md`](../designs/payn/variants/signed_segmented_csa_bp/README.md).
- Architecture diagram: [`payn_datapath.html`](payn_datapath.html), published at https://claude.ai/artifact/3cRC32X3uhkQXrhSvmbH5b.

## 1. The goal and the constraints the user set

The goal is to run the INT layers of the model on the PaYN SC array (TSMC22, 400 MHz, carry-save tile `signed_segmented_csa`, K8/M16/N8,
LOW_W=9) instead of adding a separate binary engine.

Constraints:
- Area efficiency (GMAC/s/mm2) is the main metric.
- SC mode runs at a model-fixed T=128 and must not lose much.
- Judge at grid scale (4x4 / 4x8).
- Back claims with synthesis/routing.
- Only INT-specific costs matter; costs common to SC (inter-PE wiring etc.) are out of scope.
- The user wants explanations as plain equations in simple notation (`bits[k][m] = a_bits & w_bits`, `sign[k]`).

## 2. What was decided

Five mappings were designed and adversarially verified (section 5 of the study). Two survive:

| design | idea | array change | INT8 / W4A8 / INT4 peak (MAC/tile-cycle) | INT8 pJ/MAC (routed GL) | operand bits/MAC (4x4) |
|---|---|---|---|---|---|
| **bit-plane (BP)** | each AND = 1 real bit product (bit h of A x bit q of W), 16 different elements per lane; weight bits in time with an 8-cycle "ring lap" doubling between passes; east combiner applies 2^h | edge bypass (AO21/bit), ring mux per PE row, combiner | 2 / 4 / 8 | 0.349 peak, 0.38 at L=4096 | 4 (W side binds) |
| **spatial Booth (CNSB)** | one product per lane as Booth digit pairs (radix-4 a x radix-16 w, \|da\|x\|dw\| <= 16 on a 2x8 grid); each tile owns one digit pair, weights applied at the east edge | none inside the array (Sobol preset gate ~101 um2); feeder + combiner at the edges | 1 / 2 / 4 | 0.68-0.80 | 1.5 |

The user's "shift the result down every cycle" idea works but costs ~6% of a 4x4, 3.8% of it inside tiles. Rejected.

BP was chosen and implemented because of the user's point that INT8 needs 64 one-bit products per MAC against 128 for SC T=128.

## 3. The BP implementation (done)

**RTL:** `designs/payn/variants/signed_segmented_csa_bp/`. The tile and CSA PE core are unchanged.
- `pe_peripheral_bp.sv`: `bits = cmp | (raw & int_mode_q)` on all 2,048 operand bits. Raw bits come from new ports
  `a_raw_in`/`w_raw_in`. Magnitudes are held at 0 in INT mode, so the comparator outputs 0.
- `inner_pe_signed_segmented_csa_bp.sv`: ring mux at each row's west input, `acc_out_east << 1`.
- `bp_combiner.sv`.
- Top level `payn_array_signed_segmented_csa_bp.sv`: registered `int_mode`, MAC guard, port contract in its header.
- PE-grid wrapper `inner_pe_grid_signed_segmented_csa_bp.sv`.

**Data per cycle in INT8**, per PE (1 activation row x 8 weight columns):
- `a_raw_in`: bit h of A[128b+16k+m] goes to tile row h, lane k, position m. That is the next 128 activation bytes, rewired by bit.
- `w_raw_in`: bit q of W[x, v] goes to column v. Weights are stored bit-plane-major.

Raw bits are registered only once, in the PE bit pipe (latency 1 edge vs 2 for SC/signs).

**Verification scripts:**

| script | what it runs |
|---|---|
| `sweeps/run_csa_bp_rtl_checks.sh` | SC regression + INT matrix |
| `sweeps/int_mode/bp/verify/run_bpv.sh` | adversarial harness |
| `sweeps/int_mode/bp/run_bp_sc_isolation_review.sh` | SC isolation |
| `sweeps/run_csa_bp_syn_gl_checks.sh` | post-synthesis GL |
| `sweeps/int_mode/bp/run_bp_grid_checks.sh` | PE-grid RTL, 2x2..4x4 incl. negative controls |

**Synthesis runs** (`syn/build/TSMC22/PAYN_SC_CSA_BP/`):
- `csa_bp_20261003b`: global-lap contract, the routed one.
- `csa_bp_20261004_lap`: per-PE lap enable, routed (pinned and floating); now the reference BP netlist.
- The `*_superseded_*` runs are not to be used.

**Routed results:**
- **Floating pins.** The first floating-pin route (`csa_bp_20261003b_distguide_spp_fixed`) fell into a row-collapsed placement basin (SC 20.74 mW).
  Root cause: `build/sc_power_regression/README.md`. The CSA netlist's own pass 1 did the same.
- **Pinned pass 2, like for like** (`apr/scripts/place_pins_and_guides_sc.tcl`, `sweeps/run_pinned_pass2.sh`; evidence
  `build/power_char/pinned_pass2_20261004/`):
  - BP `csa_bp_20261003b_distguide_spp_pins`: 46,130 um2, SC 16.491 mW.
  - CSA control `csa_20261002_distguide_spp_pins`: 43,917 um2, 15.726 mW.
  - So the SC cost is +5.0% area on 1 PE, +2.0% on a 4x4 composite, and +4.9% power. Of the power, ~0.2 mW is hardware and ~0.5 mW
    is tile glitch from a larger a/w skew, n=1 per arm.
- **INT energy on the pinned BP route** (45 points, real ports, max-SDF GL, bit-exact):
  `build/power_char/int_mode_energy_20261003/bp/csa_bp_20261003b_distguide_spp_pins/results.csv`.

  | | pJ/MAC peak | at L=4096 |
  |---|---:|---:|
  | INT8 | 0.349 | 0.380 |
  | W4A8 | 0.175 | 0.191 |
  | INT4 | 0.088 | 0.095 |

**Grid comparison:** `sweeps/int_mode/compare_grid_configs.py`, giving
`build/power_char/int_mode_energy_20261003/grid_config_comparison.csv` (study section 9).

**GL validator approvals used for BP** (rationales are next to each run):
- `--approve-annotated-interconnect`: SDFCOM_IWSBA on the int_out sign-extension alias.
- `--approve-negative-iopath-clamp-ps 12`.

## 4. Per-PE lap enable (completed 2026-10-04)

**Per-PE lap enable workflow** (session workflow `wf_6d51346f-6a5`, journal
`~/.claude/projects/-home-barrylyu-repos-PaYN/79588d69-e5ca-4493-9934-e7540653cc42/subagents/workflows/wf_6d51346f-6a5/journal.jsonl`).

**The change.** The core shift is now `shift_in | ring_q`, and ring_q travels east with the A operands. Each PE laps on its own skewed schedule.
Without it, global laps cost P_R+P_C-2 bubble cycles per pass: INT8 4x4 L=4096 is 1,007 vs 1,128 GMAC/s/mm2.

**Done:**
- RTL, contract, grid wrapper + grid bench (50/50 grid checks incl. negative controls).
- All single-PE checks.
- Adversarial harness (58 scenarios).
- SC isolation.
- Synthesis `csa_bp_20261004_lap` (timing met in DC).
- Post-synthesis GL.

**Review findings, all minor, fixed in the Fix stage:**
- the grid reset requirement is undocumented;
- int_mode gates ring_in only at the west edge;
- README wording on the shift_in timing risk;
- `run_bp_grid_checks.sh` breaks with an absolute OUT;
- study section 9 note is stale (now updated below).

**Routed (Route stage).** Bootstrap campaign `build/power_char/popcount_apr_csa_bp_20261004_lap/`, pinned pass 2
`build/power_char/pinned_pass2_csa_bp_20261004_lap/` (`comparison.txt`, `results.csv`, `deviations.txt`, GL rationale):
- Pinned `csa_bp_20261004_lap_distguide_spp_pins`, grid basin: 46,096 um2, SC 16.494 mW (03b pinned: 46,130 um2, 16.491 mW; noise),
  WNS +0.078 / +0.158 ns. `shift_in` is now the critical start point (it was +0.361 ns on 03b pinned); the ~30 ps DC estimate was low.
- Floating-IO final stayed in the grid basin this time: 16.771 mW.
- GL approvals as before: 4 IWSBA on the int_out alias, 9 NDI clamps of at most -9 ps (12 ps bound, 0 max_tran).
- Routed INT energy, new contract: `build/power_char/int_mode_energy_20261004_lap/bp/`, 0.1-0.2% below the 03b route (INT8 peak
  0.348, INT4 0.087 pJ/MAC).
- Routed full-timing functional GL: 8/8 (`build/rtl_preflight/csa_bp_routed_func_gl/`); the 03b netlist fails the ring-only cases.
- New scripts: `sweeps/int_mode/bp/{compare_pinned_lap.py,compare_int_energy_routes.py,run_bp_routed_func_gl.sh}`; new
  `csa_bp_lap` arm in `sweeps/run_pinned_pass2.sh`; `BPE_LAP_RING_ONLY` mode in the INT power bench.

**Still open from this work:** raw-plane edge skew is not in RTL (the grid benches apply it). The floating-route repair was run by hand,
because the campaign script has no repair stage.

**Commands used** (kept for reproduction):

```bash
bash sweeps/run_csa_bp_rtl_checks.sh && bash sweeps/int_mode/bp/run_bp_grid_checks.sh     # confirm the fixes
BP_SYNTH_RUN=csa_bp_20261004_lap CAMPAIGN=csa_bp_20261004_lap \
  GL_VALIDATOR_ARGS="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12" \
  bash sweeps/run_popcount_apr.sh csa_bp                     # bootstrap pass (stop after final_apr fails/passes; pass 2 below replaces it)
# then a pinned pass 2 for this synthesis run with sweeps/run_pinned_pass2.sh (parameterize the arm), basin gate, repair,
# GL + PT; then routed INT functional GL in the new contract (laps without shift_in).
```

If the synthesis was re-run in the fix stage, use the newest `csa_bp_20261004_lap*` run under `syn/build/TSMC22/PAYN_SC_CSA_BP/`.

**Git:** the user committed `1a797e9 INT` mid-session. Later edits are uncommitted: the lap-enable follow-ups, README, benches, grid
checks, `payn_datapath.html`, these docs. `.gitignore` was updated to drop synthesis scratch.

## 4b. Lap schedules (2026-10-04): reduction first, shift at the end?

The user asked whether the reduction could run first, with the shift at the end, avoiding the laps. Model:
`sweeps/int_mode/bp/model_lap_schedules.py` (log, CSV), validated against every measured period, a value-level simulator and the RTL runs below.

- **T2 (all weight bits in space, no laps, one shift at the end) ties T1 on one PE and loses on grids.** On 4x4 INT8 at L=4096 it
  reaches 45.7% of peak against T1's 73.1%. With one output per PE, every output pays its own row-wide drain and skew, and a lap is
  only 8 cycles inside one PE. Verified in RTL with no RTL change (`sweeps/int_mode/bp/space/`, `build/rtl_preflight/bp_space/`).
- **The schedule that wins is the hybrid H(TA,TW): activation bits partly in time too.** INT8 H(4,8) holds 32 outputs per PE and
  reaches 4x4 89.7% / 1,376 and 4x8 86.9% / 1,380 at L=4096 (T1 1,128 / 1,055; T3 1,274 / 1,174).
  - No tile, PE or grid change: bit-exact on the unchanged RTL, on grids 1x1 to 4x8 and on the single-PE top.
  - Needs a new east combine (+601 um2 per PE row, cell count) and A delivered as bit planes. L <= 4,369 per block.
  - W4A8 H(8,4) and INT4 H(4,4) (the round-1 "HB" mapping) gain about 33% and 27% over T1 on 4x4 at L=4096.
  - Benches and runners: `designs/payn/tb/test_pe_grid_bp_hybrid.sv`, `designs/payn/tb/test_payn_array_bp_hybrid.sv`, and
    `sweeps/int_mode/bp/hybrid/run_bp_hybrid_{checks,fix_checks,top_checks}.sh`. Results in `build/rtl_preflight/bp_hybrid*/`.
- **T3 (1-cycle self-doubling, +2.92% of a 4x4) adds +3.6% on top of H(4,8)** on 4x4 at L=4096 (95.5% / 1,425). That is marginal.
  - T3 is built and synthesized as `designs/payn/variants/signed_segmented_csa_bp_ipd/` (`csa_bp_ipd_20261004`): +969 um2 per PE,
    SC -2.84% on 4x4 vs the BP ring (-4.71% vs CSA). Not routed; SC and INT energy not measured.
  - Cheaper point on the same line: sub-rings of g tiles (`designs/payn/variants/signed_segmented_csa_bp_sr/`, laps of g cycles).
    g=2 keeps 99.3% of T3's 4x4 INT8 gain at L=4096 for SC -1.26%; g=4 gives +8.2% INT8 for SC -0.43% (vs the BP ring).
    **Caveat:** the g=2/g=4 syntheses ran into placeholder alibs when the AFS token expired. Rerun after `kinit && aklog` with
    the commands in that README's "Blocked" section before quoting them.
- **Not run:** gate level for H (AFS token expired), synthesis of the hybrid combiner, and a hybrid sequencer in the top.

## 5. Open question: memory bandwidth (the main open issue)

The SRAM is sized for SC. BP needs 1,024 operand bits per edge half per cycle on BOTH sides. A is 128 activation bytes; W is bit q of
128 weights x 8 columns. SC T=128 needs 576 bits once per 8 cycles, i.e. 72 b/cycle.

The weight side binds and cannot be fixed by an activation replay buffer. The 8 tile rows hold the 8 bits of ONE activation row, so the
output footprint and the weight reuse are 8x smaller than SC. Throughput on 4x4 for two readings of "SRAM sized for SC":

| mode | (i) SC T=128 average, 72 b/cycle per edge | (ii) 576-bit SC block every cycle (= SC T=16) |
|---|---|---|
| SC T=128 | 1.0 MAC/tile-cycle (771 GMAC/s/mm2) | 1.0 |
| BP INT8 | 0.14 (7%), 108 | 1.12 (56%), 867 |
| BP INT4 | 0.56, 434 | 4.5, 3,469 |
| spatial Booth INT8 | 0.28 (28%), 217 | 1.0 (100%), 771 |
| spatial Booth INT4 | 1.12, 867 | 4.0, 3,083 |

**The question to ask the user:** does the memory deliver (i) or (ii)?
- **Under (i):** BP is memory-bound and slower than SC; spatial Booth is the better INT mode.
- **Under (ii):** BP still wins on energy at similar throughput.
- **BP at its full peak** needs about 1,024 b/cycle per edge half (1.8x the SC block width).

**Correction (2026-10-04, schedule-study review):** the table assumes no operand reuse at the array edge.
- With an A replay buffer per PE row and a W block buffer per PE column (M as the inner loop), reading (i) gives BP INT8
  1.11 MAC/tile-cycle against spatial Booth's 0.56 on 4x4 at L=4096 (study section 10, model section 6b).
- The buffers cost 160-256 KB on a 4x4 at L=4096 and need 1,024-bit ports.
- So the decision has a second part: can edge buffers of that size and width be built?
- "W binds because the footprint is 8x smaller" is a property of the as-built schedule, not of BP: the hybrid H(4,8) holds 32
  outputs per PE (section 4b below).

Fairness note: a standalone binary 8x8 array also needs ~2 bits/MAC.

## 6. Candidate next steps

1. Get the user's answer on memory bandwidth (section 5); it decides between BP and spatial Booth.
2. ~~Route the lap-enable netlist~~ (done, section 4).
3. If BP stays:
   - share half the raw lines with `a_binary_in`/`w_binary_in` (-1,024 pins, ~+110 um2; may remove the ~0.5 mW layout penalty);
   - put the raw-plane edge skew in the feeder (free) rather than flops (~3% of 4x4);
   - ~~consider the 64-pass variant~~: evaluated as the hybrid family H(TA,TW) (section 4b); H(4,8) is the INT8 pick for
     L <= 4,369, H(8,8) (the 64-pass variant) only for L <= 511;
   - build the hybrid's east combine into the top (proposed RTL `designs/payn/variants/signed_segmented_csa_bp_hyb/bp_hybrid_combiner.sv`,
     sidecar-verified, not synthesized: needs an AFS token) and decide how A reaches the array as bit planes.
4. If spatial Booth: RTL for the edge recoder/combiner/skew (synthesized estimates exist under `sweeps/int_mode/verify/`); the array is
   unchanged.
5. Make fixed pins plus the basin gate the default for single-PE A/B routes (`sweeps/pinned_pass2/basin_gate.py`). The accepted CSA
   headline 15.447 mW is a lucky floating-pin layout; pinned CSA is 15.726 mW.

## 7. Other results from the same session (not INT)

- **CSA energy vs T** (T=16..128, 3 arms, all qualified): `build/power_char/csa_t_sweep_20261003/results.csv`, CSA README, `doc/results.md`.
- **CSA M=8 shapes** (K8/K12/K16 x M8 x N8), routed: M=8 lags M=16 at every shape (K16M8N8 -7.8% area efficiency / +10.6% energy on 4x4). It only pays
  for a model T of 24/40/56/72. See `build/power_char/popcount_apr_csa_20261003/`, CSA README "M=8 shapes", `m8_vs_m16_vs_T.csv`.

## 8. File index

| what | where |
|---|---|
| study, all sections | `doc/INT_mode_on_PaYN.md` |
| round-1 designs (JSON) and models | `sweeps/int_mode/design_round1.json`, `sweeps/int_mode/model_*.py` |
| adversarial verification of the 5 designs | `sweeps/int_mode/verify/` |
| emulated INT energy (forced nets, old netlist) | `build/power_char/int_mode_energy_20261003/{bitplane,cnsb_booth}/` |
| BP energy bench and driver | `designs/payn/power/power_payn_array_bp_int.sv`, `sweeps/int_mode/bp/run_bp_int_energy.sh` |
| placement-basin root cause | `build/sc_power_regression/README.md` |
| pinned pass 2 (BP + CSA) | `build/power_char/pinned_pass2_20261004/` |
| INT vs binary tables | `sweeps/int_mode/compare_int_vs_bos.py`, `compare_grid_configs.py` |
| diagram source | `doc/payn_datapath.html`, generated by `python3 doc/gen_payn_datapath.py` (edit the generator, not the HTML) |
