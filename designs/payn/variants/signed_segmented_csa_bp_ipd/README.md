# Bit-plane INT mode with in-place doubling (`signed_segmented_csa_bp_ipd`)

This is schedule **T3** from the "execute through the reduction dimension, then
shift" study. It is the [`signed_segmented_csa_bp`](../signed_segmented_csa_bp/README.md)
design (`csa_bp_20261004_lap`) with one change: what a weight-pass lap does.

| | BP ring (`csa_bp_20261004_lap`) | in-place doubling (this variant) |
|---|---|---|
| a lap | 8 edges of `ring_q`. Each edge shifts every row one tile east; the east tile, doubled, enters the west tile | **1 edge** of `ring_q`. Every tile reloads its own value `<< 1` |
| hardware | 8 x 24-bit `<<1` muxes at the PE west input, plus 192 ring-return wires from the east column | 64 x 24-bit muxes, one per tile, in front of the tile's `acc_in` (west neighbour, or own value `<< 1`). No west mux, no return wires |
| INT block period | `BW*NB + 8*(BW-1) + (P_R+P_C-2) + 8*P_C` | `BW*NB + 1*(BW-1) + (P_R+P_C-2) + 8*P_C` |

Everything else is shared with the BP variant: the INT8/W4A8/INT4 mapping, the
raw-plane bypass, the sign path, the per-PE `ring_q` wave (PE (r,c) laps at
offset r+c), the drain, the combiner and SC mode. The tile module is untouched.

**Bottom line** (synthesized, not routed):
- **INT throughput.** The 4x4 INT8 data-edge utilization at L=4096 rises from
  73.1% to **85.0%**. That confirms the ~85% expectation, measured on the RTL
  grid.
- **Area.** The cost is **+969.6 um2 per PE** (+2.13% of the single-PE total,
  **+3.30% of `u_pe`**).
- **SC efficiency.** The added area is all in `u_pe`, the block every PE of a
  grid repeats, so the composite grows by +2.9%. So the "~+2%" guess holds for
  one PE but not for a grid. SC GMAC/s/mm2 drops **2.1% (1 PE), 2.8% (4x4) and
  2.9% (4x8)** against the BP ring.
- **Against plain CSA (no INT mode)**, the reference for the primary SC
  metric, SC GMAC/s/mm2 drops **6.7% (1 PE), 4.7% (4x4) and 4.3% (4x8)**. The
  BP ring costs 4.7%, 1.9% and 1.4%. On a 4x4 the INT area tax over CSA rises
  from +10,221 um2 (+1.96%) to +25,730 um2 (+4.94%), about 2.5x.
- **INT efficiency.** INT8 GMAC/s/mm2 (estimate) rises **+13.0% (4x4) and
  +11.2% (4x8) at L=4096**, and **+40.8% / +29.9% at L=1024**.
- **A cheaper point on the same curve: 2-tile sub-rings.**
  [`signed_segmented_csa_bp_sr`](../signed_segmented_csa_bp_sr/README.md) has
  a mux only at every g-th tile, so a lap takes g edges. The BP ring is g = 8
  and this variant is g = 1.
  - **g = 2** (32 muxes, +423.5 um2 of `u_pe`, synthesized) reaches 1,265
    INT8 GMAC/s/mm2 on 4x4 at L=4096. That is 99.3% of IPD's 1,274, for an SC
    cost of -1.26% instead of -2.84%.
  - **g = 4** costs -0.43% SC for +8.2% INT8.
  - **The step from g = 2 to IPD** buys +0.7% INT8 for -1.6% SC, so IPD is
    the most expensive point on the curve.

## Files

| file | module | what |
|---|---|---|
| `inner_pe_core_signed_segmented_csa_ipd.sv` | `InnerPESignedSegmentedCsaIpd` | copy of the CSA PE core (`InnerPESignedSegmentedCsa`) with a `lap` input and a per-tile mux: `tile_acc_in = lap ? {acc_out[22:0],0} : acc_chain[v]`. Same instance names (`g_row`/`g_col`/`u_inner`, `a_bits_pipe`, `w_bits_pipe`) |
| `inner_pe_signed_segmented_csa_bp_ipd.sv` | `InnerPESignedSegmentedCsaBpIpdFlat` | BP PE wrapper: registered `ring_q`, `core_shift = shift_in \| ring_q`, `lap = ring_q`, no west ring mux; core instance `u_array_core` |
| `payn_array_signed_segmented_csa_bp_ipd.sv` | `payn_array_signed_segmented_csa_bp_ipd` | single-PE top. It is the BP top with the IPD PE as `u_pe`, and it reuses `sc_pe_peripheral_bp` and `PaynBpCombiner` from `../signed_segmented_csa_bp/`. The header holds the full sequencer contract |
| `inner_pe_grid_signed_segmented_csa_bp_ipd.sv` | `InnerPESignedSegmentedCsaBpIpdGrid` | P_R x P_C grid wrapper, the same wiring as the BP grid (verification wrapper, not synthesized) |
| `syn/targets/TSMC22/PAYN_SC_CSA_BP_IPD` | | copy of `PAYN_SC_CSA_BP`: identical knobs, new `TOP`/`SRC_SV` |

**Exactness.** `acc_out = {high_next, acc_low}` is the tile's canonical value:
the pending carry or borrow is already folded into `high_next`. A shift loads
`acc_in` and clears both pending flags. So the lap edge loads exactly
2 x value mod 2^24, as a drain shift or a BP ring lap does. Coverage over the
42 bit-exact single-PE cases: of 26,688 tile-laps, 1,625 folded a pending carry
and 277 a pending borrow.

**No combinational loop.** `acc_out` is a function of the tile's registers
only, and `acc_in` reaches only register D pins. DC on the synthesized netlist
reports `report_timing -loops`: "No loops.", and `check_timing` gives no loop
warning. The self path is a one-cycle register-to-register path (slack +1.65 ns).

## Contract (difference from the BP top)

- A lap is **one** `ring_in` edge, driven one edge ahead (`ring_q` lags it).
  k consecutive `ring_in` edges multiply by 2^k. BP schedules with 8-edge laps
  therefore multiply by 2^8 here and are **not** compatible. Only the lap
  length changes; sign loads, drains and combiner capture are the same.
- The MAC on the lap edge is dropped (shift priority), so the plane captured
  one edge before it must be a bubble. A non-final weight pass takes NB + 1
  edges.
- Single PE: `shift_in` on the lap edge is harmless. The OR is idempotent and
  the mux follows `ring_q`.
- Grid: laps are at offset r+c. On a grid larger than 1x1 no edge has every
  PE lapping: the PEs of one anti-diagonal r+c lap together, the others do
  not. The global `shift_in` must therefore be low on lap edges and is used
  for drains only.
- SC mode: `ring_in` is gated by `int_mode`, so `ring_q = 0` and every tile
  takes its west neighbour, exactly as in the CSA core.

## Synthesis (`csa_bp_ipd_20261004`, DC, TSMC22, 400 MHz, knobs identical to `PAYN_SC_CSA_BP`)

| area (um2) | CSA `csa_20261002` | BP ring `csa_bp_20261004_lap` | IPD `csa_bp_ipd_20261004` | IPD - lap | IPD - CSA |
|---|---:|---:|---:|---:|---:|
| total | 43,455.0 | 45,522.8 | **46,492.4** | **+969.6 (+2.13%)** | +3,037.4 (+6.99%) |
| `u_pe` | 29,253.0 | 29,390.4 | 30,359.7 | +969.3 (+3.30%) | +1,106.7 (+3.78%) |
| `u_pe/u_array_core` | 29,253.0 | 29,252.6 | 30,357.5 | +1,104.9 | |
| `u_pe` outside the core (ring_q, OR, west mux) | - | 137.8 | 2.3 | -135.5 | |
| `u_peripheral`, `u_combiner`, Sobol | | 14,037.0 / 680.8 / 1,406.0 | 14,037.3 / 680.8 / 1,406.0 | +0.3 / 0 / 0 | |
| noncombinational | 8,164.7 | 8,522.2 | 8,522.2 | 0 | |
| worst slack (ns) | +0.93 | +0.94 | **+0.91** | | |

- **Where the area went.**
  - **Tiles:** the tile RTL is unchanged, because the mux sits outside
    `u_inner`. The synthesized 64 tiles still grew by +20.2 um2 (26,197.9 ->
    26,218.1), most likely from load-driven sizing.
  - **Core:** the area local to the core (muxes and select tree) grew by
    +1,084.7 um2 (61.8 -> 1,146.5). It gained 1,472 AO22 (23 bits x 64 tiles),
    64 NOR2XB (bit 0), 108 BUFH and 92 INV. The inverters and buffers drive the
    `ring_q` select and its complement.
  - **PE wrapper:** it lost the west mux (-135.5 um2: 184 AO22, 9 NOR2XB, 13
    BUFH, 12 INV).
  - **Net:** that is 1,344 more mux bits at about 0.72 um2 per bit, tile
    sizing and select tree included. Locally the muxes cost 0.706 um2 per bit,
    the same as the BP west mux.
- **Flops.** No flop was added or removed.
- **Warnings.** The synthesis warning set equals the lap run's.

**Possible saving, not explored.** Because `FLATTEN=0` keeps the tile
hierarchy, DC cannot merge the AO22 with the tile's own shift/MAC D-mux. A
tile-internal 3:1 load mux might recover part of the +1,105 um2, but it would
modify the tile module, which this variant leaves untouched.

**DC timing** (ideal clock, 1.25 ns input delay, both runs probed by the same
script, `sweeps/int_mode/bp/ipd/report_bp_ipd_new_paths.sh`):

| path | lap | IPD |
|---|---:|---:|
| combinational loops | none | none |
| self path: tile (3,4) regs -> `<<1` -> doubling mux -> tile (3,4) acc regs | +1.68 (MAC path; no self mux) | +1.65 |
| chain path: tile (3,3) -> tile (3,4) (drain) | +1.68 | +1.66 |
| BP ring return: col-7 tile -> `<<1` -> west mux -> col-0 tile | +1.65 | no path |
| any tile reg -> any tile acc reg | +1.65 | +1.65 |
| `shift_in` -> tile `acc_high` clock-gate enable | +1.06 | +1.06 |
| `shift_in` -> anywhere | +1.01 | +1.01 |
| `ring_q` -> tile clock-gate enable | +2.17 | +2.25 |
| `ring_q` -> tile `acc_low` (doubling-mux select) | +2.12 | +2.09 |
| `ring_q` -> tile `acc_high` | +2.12 | +2.11 |
| worst (reset port) | +0.94 (-> tile `acc_low`) | +0.91 (-> combiner `out_reg`, unchanged logic) |

`shift_in` timing is unchanged. `ring_q` now drives 1,536 mux selects instead
of 192 and still has more than 2 ns of synthesis slack. **Routing risk**: on
the floating-pin lap route, `ring_q` was already the critical start point
(+0.076 ns, a long weak buffer chain to the combiner clock gate). In this
variant it fans out to every tile. A duplicated `ring_q` flop per tile row is
the obvious fix if a route needs it. Not routed.

## Verification

- **SC** (`run_bp_ipd_rtl_checks.sh`, part `sc`). The IPD top runs with its
  INT inputs tied off and again with random raw planes, `int_prec` and
  `ring_in` every cycle:
  - array cosim and the 384-batch streaming bench: all four traces are
    byte-identical to the CSA top, run fresh;
  - default 9x9/K6 shape with INT junk: identical to the CSA top;
  - the default-parameter probe elaborates.
- **INT, single PE** (part `int`, `designs/payn/tb/test_payn_array_bp_ipd.sv`,
  1-edge laps). 42 positive cases, every drained tile and combiner word
  bit-exact against numpy int64 (`check_bp_trace.py`, unchanged):
  - INT8, W4A8 and INT4;
  - uniform, all-min, all-max, min x max, max x min, -1 x min, alternating
    and ReLU data;
  - L = 128 to 4096, plus the near-limit lengths INT8 65,408 and
    W4A8/INT4 1,048,448;
  - multi-block runs, JUNK, `MODE_AT=3`;
  - both shift contracts (`shift_in` on the lap edge, and `LAP_RING_ONLY`).

  19 negative controls fail as required:

  | control | caught by |
  |---|---|
  | no lap: `LAP_LEN=0` | checker |
  | no lap: `NEG_NO_RING` | checker, or `[TIMING-FAIL]` without `LAP_RING_ONLY` |
  | double lap: `LAP_LEN=2` (INT8, W4A8, INT4) | checker |
  | BP-length lap: `LAP_LEN=8` | checker |
  | stray ring: `NEG_RING_STRAY`, and `NEG_RING_STRAY_MID` (mid-pass, doubles non-zero sums) | checker |
  | lap on the last MAC: `NEG_NO_BUBBLE` (tightness of the lap term) | checker |
  | wrong `int_prec`, `int_mode` one edge late | checker |
  | live magnitudes | `[BP-CONTRACT]` |

  Every passing case's scheduled block period equals
  `BW*NB + (BW-1) + 8`. Multi-block runs also measure the drain-start spacing.
- **Bench cross-check** (part `xcheck`). The new bench at `+LAP_LEN=8`,
  compiled against the BP top, reproduces the original bench byte for byte on
  13 cases. Those cases cover all precisions, JUNK, `MODE_AT=3`,
  `LAP_RING_ONLY`, near-limit runs and two negatives. The BP top run with the
  IPD schedule (`LAP_LEN=1`) fails.
- **INT, PE grid** (`run_bp_ipd_grid_checks.sh`,
  `designs/payn/tb/test_pe_grid_bp_ipd.sv`,
  `check_bp_ipd_grid_trace.py`). 102 cases, all as expected:
  - **Shapes and data.** 4x1, 2x2, 2x3, 3x2, 4x4 and 4x8; all precisions;
    multi-block runs, at L=4096 included; extremes; JUNK, which includes
    random west accumulators on lap edges, so the mux must ignore them;
    `RING_GATE_JUNK`.
  - **Positive controls.** `GLOBAL_LAP_WAIT` with 1-edge laps, and
    `OLDC_UNFORCED` on 4x1.
  - **What the checker verifies.** Every tile and combined output is
    bit-exact. Every PE's lap runs, taken from the RTL `ring_q`, are 1 edge at
    offset r+c. Every block period equals the formula.
  - **Negative controls**, all of which fail with tile mismatches:
    - `LAP_LEN=0`, 2 and 8;
    - `NEG_RING_STRAY`;
    - ring not skewed per row, and not skewed per column;
    - global laps without waiting;
    - lap on the last MAC, drain one edge early, next block one edge early;
    - the int_mode gate bypassed;
    - the old contract on 2x2 and 4x8.

  On top of that:
  - 16 cross-check cases run the original grid bench and the new bench at
    `LAP_LEN=8` on the BP grid. Their traces are identical, so the BP-ring
    periods below are RTL runs too.
  - The BP grid run with the IPD schedule fails.
- **Reset and abort in the middle of a lap** (added after review; the benches
  above reset only at power-up).
  - **Reviewer's PE bench** (`sweeps/int_mode/bp/ipd/review/`): random laps
    against a bit-exact model, about 500 resets on a lap edge per seed. It
    found no mismatch in RTL or in the synthesized PE (lock step, unit delay).
  - **Generalized PE bench** (`sweeps/int_mode/bp/sr/tb_sr_pe_review.sv` at
    g = 1): 3 seeds of 200k cycles each with reset on lap edges and a full-lap
    check; it passes.
  - **Adversarial grid harness** (`sweeps/int_mode/bp/verify_grid/run_vg.sh`):
    ported to a lap-length knob as
    `sweeps/int_mode/bp/sr/verify_grid/run_vg_lap.sh` and run on the IPD grid.
    209 scenarios on 1x1, 1x4, 1x8, 4x1, 8x1, 2x3, 4x4 and 4x8 are ALL AS
    EXPECTED. They cover reset or abort mid-lap and mid-pass, one-edge
    ring-wave and schedule faults (110 negatives caught), SC ring junk and
    INT->SC->INT.
  - **Port check:** the port at lap length 8 reproduces the original harness's
    209 BP-grid traces byte for byte.
- **Bench extensions (opt-in).**
  - `test_payn_array_bp_ipd.sv` and `test_pe_grid_bp_ipd.sv` gained
    `+define+BPT_DUT_SR` / `+define+BPG_DUT_SR`, which select the sub-ring
    variant.
  - `run_bp_ipd_rtl_checks.sh` gained an `OUT` override.
  - With the defaults, a re-run of the IPD single-PE (`int`, `xcheck`) and grid
    checks reproduces all 488 trace, schedule and check files byte for byte
    (`build/rtl_preflight/bp_sr/regress_ipd_compare.txt`).
- **Comment fix in the RTL headers** (after review). The top and grid headers
  wrongly said that laps at r+c "never coincide". Only comments changed: with
  comments stripped, the code is identical
  (`build/rtl_preflight/bp_sr/ipd_comment_fix/comment_only_check.txt`). The
  synthesized netlist is unaffected.
- **Post-synthesis GL** (`run_bp_ipd_syn_gl_checks.sh`: netlist, unit delay,
  NO_SDF):
  - SC streaming, 384 batches: the trace is identical to the IPD RTL and to
    the CSA RTL;
  - 16 INT cases (all precisions, JUNK, `MODE_AT=3`, INT8 L=65,408, both
    contracts): GL trace identical to RTL;
  - 4 negatives (stray ring, mid-pass stray ring, double lap, no lap): caught,
    with GL traces identical to RTL.

Logs: `build/rtl_preflight/bp_ipd/` (`sc/`, `int/`, `xcheck/`, `grid/` with
`periods.txt`, `syn_gl/`, `bp_paths/`, `syn/` area deltas, `area_efficiency.txt`).

## Block periods (RTL benches, bit-exact runs; edges per output block)

| grid | precision | L | BP ring (8-edge laps) | IPD (1-edge laps) | utilization ring -> IPD |
|---|---|---:|---:|---:|---|
| 1 PE | INT8 | 1024 | 128 | 79 | 50.0% -> 81.0% |
| 1 PE | INT8 | 4096 | 320 | 271 | 80.0% -> 94.5% |
| 4x4 | INT8 | 1024 | 158 | 109 | 40.5% -> 58.7% |
| 4x4 | INT8 | 4096 | 350 | **301** | 73.1% -> **85.0%** |
| 4x8 | INT8 | 1024 | 194 | 145 | 33.0% -> 44.1% |
| 4x8 | INT8 | 4096 | 386 | 337 | 66.3% -> 76.0% |
| 4x4 | W4A8 / INT4 | 4096 | 190 | 169 | 67.4% -> 75.7% |
| 4x8 | W4A8 / INT4 | 4096 | 226 | 205 | 56.6% -> 62.4% |

Each IPD row equals `BW*NB + (BW-1) + (P_R+P_C-2) + 8*P_C`, and each ring row
equals `BW*NB + 8*(BW-1) + (P_R+P_C-2) + 8*P_C`. The lap term drops from
8*(BW-1) to BW-1 edges (56 -> 7 for INT8). The skew and the 8*P_C drain are
unchanged, so they now dominate the overhead on grids.

## GMAC/s/mm2 (ESTIMATE: routed lap areas + synthesized IPD delta)

The IPD netlist is not routed. Its routed areas are estimated block by block
as `routed lap (pinned, csa_bp_20261004_lap_..._spp_pins) + (syn IPD - syn lap)`.
Ratio scaling (`routed lap x syn IPD / syn lap`) gives the same composites
within 42 um2 (under 0.01%).

- Composites: `N*u_pe + (P_R+P_C)/2*u_peripheral + P_R*u_combiner + Sobol`.
- 1 PE: 46,096.5 -> 47,066.1 um2.
- 4x4: 531,321.5 -> 546,831.8 um2.
- 4x8: 1,029,540.4 -> 1,060,560.3 um2.

The script is `sweeps/int_mode/bp/ipd/ipd_area_efficiency.py`.

| mode | grid | L | CSA, no INT (routed) | BP ring (routed) | IPD (estimate) | change vs ring | change vs CSA |
|---|---|---:|---:|---:|---:|---:|---:|
| SC T=128 peak | 1 PE | - | 582.9 | 555.4 | 543.9 | -2.06% | -6.69% |
| SC T=128 peak | 4x4 | - | 786.0 | 770.9 | 749.0 | -2.84% | -4.71% |
| SC T=128 peak | 4x8 | - | 807.4 | 795.7 | 772.4 | -2.92% | -4.34% |

| mode | grid | L | BP ring (routed) | IPD (estimate) | change |
|---|---|---:|---:|---:|---:|
| INT8 peak (no schedule) | 1 PE / 4x4 | - | 1,110.7 / 1,541.8 | 1,087.8 / 1,498.1 | -2.1% / -2.8% |
| INT8 | 1 PE | 1024 / 4096 | 555.4 / 888.6 | 881.3 / 1,027.6 | +58.7% / +15.6% |
| INT8 | 4x4 | 1024 | 624.5 | 879.6 | +40.8% |
| INT8 | 4x4 | 4096 | 1,127.7 | **1,274.1** | **+13.0%** |
| INT8 | 4x8 | 1024 | 525.0 | 681.9 | +29.9% |
| INT8 | 4x8 | 4096 | 1,055.4 | **1,173.5** | **+11.2%** |
| W4A8 | 4x4 | 4096 | 2,077.4 | 2,269.3 | +9.2% |
| INT4 | 4x8 | 4096 | 3,605.3 | 3,858.3 | +7.0% |

The BP-ring L=4096 grid rows reproduce the INT doc's 1,128 (4x4) and 1,055
(4x8). Operand delivery and SRAM bandwidth are excluded, as in the BP numbers.
IPD needs the same operand bits per data edge (and per MAC); it only removes
idle lap edges. The average operand demand therefore rises with utilization
(4x4 INT8 L=4096: 85.0% instead of 73.1% of edges carry planes), which matters
for the open SRAM-bandwidth question in `doc/INT_mode_handoff.md`.

**Trade-off.** SC mode, the primary mode, pays about -2.8% GMAC/s/mm2 on
grids against the BP ring, and -4.3 to -4.7% against plain CSA. In exchange,
INT8 gains +11 to +13% at L=4096, and +30 to +41% at L=1024, where laps are a
larger share of the block.
- **g = 2 sub-rings** (`signed_segmented_csa_bp_sr`) keep 99% of the L=4096
  gain and 85% of the L=1024 gain for less than half the SC cost.
- **If the SRAM delivers only the T=128 average,** bit-plane INT is
  memory-bound, and no lap hardware beyond the BP ring pays for itself.

The pinned CSA 4x8 composite (1,014,576 um2) uses the same formula as
`sweeps/int_mode/compare_grid_configs.py`. The routed composites are computed
by `sweeps/int_mode/bp/sr/sr_area_efficiency.py`, which reproduces the IPD
numbers above to within 0.1 GMAC/s/mm2. That script holds RTL-unchanged blocks
at their routed lap values; the IPD script uses block-by-block deltas, and the
4x4 composite moves by 1.2 um2.

## Not done / open

- **Not routed.** The area and GMAC/s/mm2 figures for IPD are estimates
  (routed lap + synthesized delta). The ring_q fanout (see Timing) is the
  thing to watch in a route.
- **INT energy not measured.** A block now has 7 lap edges instead of 56 for
  INT8, so the energy the laps add should drop, but there is no GL/PT-PX run.
- **SC energy not measured** (raised in review). Every tile's west input now
  passes through an AO22.
  - **Why it matters:** in SC mode the AO22's B input (the west accumulator)
    toggles on every MAC edge, and its masked A input (the tile's own
    accumulator) toggles too. So SC pJ/MAC may rise, by a rough guess of
    around 1%.
  - **DC's estimate is unusable:** `pwr.rpt` uses default activity (1.18 mW
    against 16.5 mW measured).
  - **Script ready, not run:** an activity-matched pre-layout A/B (CSA, lap,
    g=4, g=2, IPD; unit-delay GL SAIF of the 384-batch streaming bench, drain
    excluded; PT-PX without SPEF) is in
    `sweeps/int_mode/bp/sr/run_sc_prelayout_power_ab.sh`.
  - **Blocked:** it needs the ARM cell models and libraries on AFS, and the
    AFS token expired during this work. It has not been run.
- **No per-PE-row drain.** As in the BP grid, a skewed drain would cut the
  skew term from P_R+P_C-2 to P_C-1.
- **Array-edge skew.** The skew on the raw-plane inputs at the array edge is
  not in RTL; the grid benches apply it (inherited from the BP variant).

## Reproduce

```bash
bash sweeps/int_mode/bp/ipd/run_bp_ipd_rtl_checks.sh          # SC equivalence, INT matrix, bench cross-check
bash sweeps/int_mode/bp/ipd/run_bp_ipd_grid_checks.sh         # PE grids, 1-edge per-PE laps, BP-ring cross-check
RUN_NAME=csa_bp_ipd_20261004 RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_BP_IPD NTFY_CHNL=
python3 sweeps/int_mode/bp/syn_area_delta.py syn/build/TSMC22/PAYN_SC_CSA_BP/csa_bp_20261004_lap \
  syn/build/TSMC22/PAYN_SC_CSA_BP_IPD/csa_bp_ipd_20261004      # area delta vs lap (also vs PAYN_SC_CSA/csa_20261002)
bash sweeps/int_mode/bp/ipd/report_bp_ipd_new_paths.sh                                    # DC paths, IPD
bash sweeps/int_mode/bp/ipd/report_bp_ipd_new_paths.sh csa_bp_20261004_lap PAYN_SC_CSA_BP # same probes, lap
bash sweeps/int_mode/bp/ipd/run_bp_ipd_syn_gl_checks.sh       # post-synthesis GL (needs the RTL checks' traces)
python3 sweeps/int_mode/bp/ipd/ipd_area_efficiency.py         # GMAC/s/mm2 estimate (needs the bench runs)
```

The synthesis needs the EDA modules of the user setup (`synopsys-synth/2021.06-SP1`,
`synopsys-lib-compiler/2022.03-SP3`); the scripts load all six.
