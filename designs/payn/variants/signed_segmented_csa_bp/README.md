# Carry-save array with a bit-plane INT mode (`signed_segmented_csa_bp`)

The [`signed_segmented_csa`](../signed_segmented_csa/README.md) SC array plus an exact
integer mode. The tile and the CSA PE core are unchanged.

In INT mode every AND position carries one real 1-bit product. Position `m` of
lane `k` holds reduction element `x = 128*b + 16*k + m`. Tile row `h` gets bit
`h` of the activation, and weight bits arrive one pass per bit, MSB pass first:

    bits[k][m] = a_h[x] & w_q[x]      (all 128 positions weigh 2^(h+q))
    sign       = (h is the top bit) XOR (q is the top bit), through the existing sign path

Between passes every accumulator is doubled by one lap around its PE's own
drain chain, with a `<<1` at the PE west input. The lap is started by a
registered per-PE lap enable (`ring_q`) that travels with the operand wave, so
on a PE grid every PE laps when its own skewed pass ends. After the last pass,
an east-edge combiner forms `out = sum_h 2^h * tile(h)`. INT8 is 64 one-bit
products per MAC, 2 MAC/tile-cycle, against SC T=128's 1. W4A8 runs at 4 and
INT4 at 8 (INT4 uses two 4-row groups).

The design study and the rejected alternatives are in
[`doc/INT_mode_on_PaYN.md`](../../../../doc/INT_mode_on_PaYN.md).

## Hardware added

| block | file | what | synthesized um2 |
|---|---|---|---:|
| edge bypass | `pe_peripheral_bp.sv` | `bits = cmp \| (raw & int_mode_q)` on all 2,048 operand bits (AO21); dedicated `a_raw_in`/`w_raw_in` ports | +1,244 |
| doubling ring | `inner_pe_signed_segmented_csa_bp.sv` | registered `ring_q`, the per-PE lap enable: shifts the tiles (`shift_in \| ring_q`, one OR2) and steers the west acc input to `acc_out_east << 1`; re-exported east as `ring_out`; the core keeps the name `u_pe/u_array_core` | +138 |
| combiner | `bp_combiner.sv` | capture register, two 4-row half-trees, output register and valid | +681 |
| top glue | `payn_array_signed_segmented_csa_bp.sv` | registered `int_mode`, MAC guard, ring gate, capture | +5.5 |
| PE grid | `inner_pe_grid_signed_segmented_csa_bp.sv` | P_R x P_C wrapper: A east, W south, ring wave east, drain chain west to east, `ring_in` gated by `int_mode` per PE row (verification wrapper, not synthesized; its header has the grid contract) | - |

Total synthesis area (`csa_bp_20261004_lap`) is 45,522.8 um2 versus 43,455.0
for CSA (+4.76%), worst slack +0.94 ns. The per-PE lap enable is area-neutral:
-7.0 um2 against `csa_bp_20261003b` (45,529.7 um2), which is synthesis noise.

**Port contract** (full text in the top header):
- `int_mode` is registered, so raise it one edge before the first raw capture.
- INT-mode loads carry zero magnitudes, with a zero-load on INT entry.
- Ring laps: `ring_in` high one edge ahead of each of the 8 lap edges. `ring_q`
  alone shifts the tiles, so `shift_in` is needed only for drains. On the
  single-PE top, asserting `shift_in` on lap edges as well (the
  `csa_bp_20261003b` contract) is still legal.
- `ring_in` is strict in INT mode: every high edge makes the next edge a lap
  edge, so keep it low otherwise and do not drop `int_mode` mid-lap.
- On a PE grid (wrapper header has the full text):
  - `shift_in` is global, so apart from drains it may be asserted only on edges
    where every PE laps. A 4x8 has no such edge.
  - `int_mode` gates only the west-edge `ring_in`. A wave already in a row still
    laps PE (r,c) up to c+1 edges after the row's last `ring_in` edge.
  - The operand bit pipes are not reset. The first MAC after a reset must come at
    least min(P_R,P_C) edges after the reset starts.
- A MAC guard drops MACs for two edges after any `int_mode` change.
- With `int_mode=0`, the raw inputs, `ring_in` and `int_prec` have no effect.
- Range: exact mod 2^24 per tile. INT8 L <= 65,535 per output block; W4A8 and
  INT4 up to 1,048,575.

## Per-PE lap enable (2026-10-04, `csa_bp_20261004_lap`)

**The problem.** In `csa_bp_20261003b` the tiles shifted on the global
`shift_in` only, and `ring_q` just steered the west mux. That kept an OR off the
`shift_in` -> tile clock-gate path. On a P_R x P_C grid the operand wave
reaches PE (r,c) r+c edges late, so a global lap has to wait for the last PE.
That costs P_R+P_C-2 idle edges after every weight pass.

**The fix.** Inside `InnerPESignedSegmentedCsaBpFlat` the core shift is
`shift_in | ring_q`. `ring_q` was already registered per PE and re-exported as
`ring_out`. On a grid:
- `ring_in` is injected per PE row at the west edge, with that row's A skew;
- the wave moves one PE east per edge, so PE (r,c) laps exactly when its own
  pass ends;
- the global `shift_in` is used only for the final drain.

The block period becomes

    BW*NB + 8*(BW-1) + (P_R+P_C-2) + 8*P_C   edges   (NB = L/128 data edges per pass)

so the skew is paid once per output block instead of once per pass.

**Contract changes** (full text in the top header and the grid header):
1. `shift_in` is not needed on lap edges. Old single-PE schedules still run
   unchanged, because the OR is idempotent.
2. `ring_in` is now a strict control in INT mode. A stray pulse shifts the
   tiles; before, it did nothing without `shift_in`.
3. Do not lower `int_mode` mid-lap: a lap edge already in `ring_q` still shifts.
4. On a grid, the old contract (one global ring signal, with `shift_in` on every
   lap edge) needs a broadcast ring. That works for P_C = 1, or with a forced
   bench signal as in the `GLOBAL_LAP_WAIT` control. The grid's own ring wave
   cannot make simultaneous laps when P_C > 1. With the ring wave:
   - use `shift_in` for drains;
   - on any other edge, use it only where every PE laps. When P_R+P_C-2 >= 8
     there is no such edge (4x8).

   One stray global `shift_in` on an edge where some PE is not lapping
   corrupts that PE's tiles.
5. On a grid, `int_mode` must be high on every edge where a row injects. The
   links between PEs are not gated, so a wave already in a row finishes after
   `int_mode` falls: up to P_C edges for the far column. SC work that needs
   `ring_q = 0` must wait that long. In practice, lower `int_mode` after the
   drain.

Not new, but now documented: the operand bit pipes (one register per PE, in
the CSA core) are neither reset nor gated by `mac_en`. After a reset, PE (r,c)
can still add a product of pre-reset planes while min(r,c) >= the number of
edges since the reset started. So:
- from the first reset edge on, drive no planes of an aborted block;
- hold reset for min(P_R,P_C) edges, or keep `mac_en` low for min(P_R,P_C)-n
  edges after an n-edge reset.

A single PE needs one reset edge. The clean grid's core has the same pipes.

SC mode is unchanged: `ring_in` is gated by `int_mode`, so `ring_q = 0` and the
tiles shift on `shift_in` exactly as in the CSA top.

**Grid results** (RTL, `sweeps/int_mode/bp/run_bp_grid_checks.sh`). Each cell
is the scheduled edges per output block at L=4096, with data-edge utilization.
The bench runs that schedule on the RTL and checks it bit-exactly, which shows
the schedule is feasible. It is also tight: three negative controls each
shorten one term by one edge, and each fails with tile mismatches:
- a lap starting on the last MAC of a pass;
- the drain one edge early;
- the next block one edge early.

The L=4096 cells are single-block runs. Multi-block runs, 4x8 included, also
measure the drain-start spacing, and it equals the formula.

| grid | precision | per-PE laps (this RTL) | global laps (`csa_bp_20261003b` usage, ring forced to a broadcast) |
|---|---|---:|---:|
| 4x4 | INT8 | 350 (73.1%) | 392 (65.3%) |
| 4x4 | W4A8 | 190 (67.4%) | 208 (61.5%) |
| 4x4 | INT4 | 190 (67.4%) | 208 (61.5%) |
| 4x8 | INT8 | 386 (66.3%) | 456 (56.1%) |
| 4x8 | W4A8 | 226 (56.6%) | 256 (50.0%) |
| 4x8 | INT4 | 226 (56.6%) | 256 (50.0%) |

Both columns are bit-exact and match their formulas. So the grid L=4096
figures in section 9 of the INT doc (INT8 1,128 on 4x4 and 1,055 on 4x8
GMAC/s/mm2) hold for this RTL. The correction note's 1,007 and 893 describe
`csa_bp_20261003b`.

A per-PE-row drain is not in this wrapper. It would mean `shift_in` skewed by
r, like the A data, and it would cut the skew term from P_R+P_C-2 to P_C-1
edges per block.

**Timing** (DC, `csa_bp_20261004_lap` vs `csa_bp_20261003b`, ideal clock,
1.25 ns input delay; `sweeps/int_mode/bp/report_bp_new_paths.sh`):

| path | 20261003b | 20261004_lap |
|---|---:|---:|
| `shift_in` -> tile `acc_high` clock-gate enable | +1.09 | +1.06 |
| `shift_in` -> anywhere (tile `acc_low` D) | +1.04 | +1.01 |
| `ring_q` -> tile clock-gate enable | - | +2.17 |
| `ring_q` -> tile `acc_low` (shift mux select) | +2.21 | +2.12 |
| worst slack (reset port) | +0.93 | +0.94 |

- **Cost:** `shift_in` gets slower, not faster. The OR2 adds 30 ps to it in DC,
  which uses a zero wire-load model. Only the lap path (`ring_q`, a flop) gets a
  full cycle.
- **Routed (2026-10-04):** `csa_bp_20261004_lap` is routed with both IO pin
  styles, and both layouts close 400 MHz (section "Routed results, per-PE lap
  enable" below). The table is from Innovus on copies of the final databases
  (`sweeps/int_mode/bp/report_bp_routed_shift_in.sh`); each run reproduces its
  route's `setup.rpt` WNS exactly.

  | route | WNS (from) | worst from `shift_in` | `shift_in` -> clock-gate enable | worst from `ring_q` |
  |---|---:|---:|---:|---:|
  | `csa_bp_20261003b`, floating IO (`..._spp_fixed`) | +0.053 (Sobol reg) | +0.066 (tile `acc_low` D) | +0.266 | - |
  | `csa_bp_20261003b`, pinned IO (`..._spp_pins`) | +0.061 (`reset`) | +0.361 (clock-gate enable) | +0.361 | - |
  | `csa_bp_20261004_lap`, floating IO (`..._spp_fixed`) | +0.076 (`ring_q`) | +0.172 (tile `acc_low` D) | +0.189 | +0.076 (combiner clock gate) |
  | `csa_bp_20261004_lap`, pinned IO (`..._spp_pins`) | +0.078 (`shift_in`) | +0.078 (tile `pending_carry` D) | +0.093 | +1.090 |

  On the pinned layout `shift_in` lost 0.28 ns against `csa_bp_20261003b` and
  is now the critical start point. The OR2 itself is 40 ps on that path; the
  rest is a longer chain of X0P5M buffers that the optimizer built on the core
  shift net (it stops sizing once timing is met, so the leftover slack is what
  every route ends with: +0.05 to +0.15 ns). On the floating layout the
  critical path is `ring_q` -> AND3 -> combiner capture clock gate, also behind
  a long weak buffer chain: `ring_q` now drives the shift of all 64 tiles as
  well as the west acc mux selects and the combiner capture. Neither layout has a
  negative-slack path, and the CSA floating route's worst path is also from
  `shift_in` (+0.146 ns).
- **Rejected alternative:** a registered per-PE shift enable would give the
  clock-gate path a full cycle. But the tiles would then shift one edge after
  `shift_in`. That changes the SC drain timing the CSA drop-in contract fixes,
  and with 1.06 ns of synthesis slack it is not justified.

## Verification

- `sweeps/run_csa_bp_rtl_checks.sh` (RTL):
  - SC array and streaming cosim, bit-exact and identical to the CSA top,
    including random junk on every INT input while `int_mode=0`;
  - 47 INT8/W4A8/INT4 cases (extremes, ReLU, multi-block, back-to-back),
    bit-exact against numpy, plus negative controls. The cases cover both
    contracts: `shift_in` on lap edges, and `LAP_RING_ONLY` (laps on `ring_q`
    alone) for every precision, JUNK, `MODE_AT=3` and a near-limit length.
    Negative controls include a stray `ring_in` pulse;
  - `PARTS=asbuilt` (optional): the same bench on the `csa_bp_20261003b` RTL
    snapshot. `LAP_RING_ONLY` fails there and the stray pulse passes, so the
    cases tell the two RTLs apart.
- `sweeps/int_mode/bp/run_bp_grid_checks.sh` (RTL, PE grid, bench-side skew):
  - shapes 4x1, 2x2, 2x3, 3x2, 4x4 and 4x8; INT8, W4A8 and INT4; multi-block
    back to back (4x8 included); extremes; JUNK;
  - `RING_GATE_JUNK`: `int_mode` is high only while a row injects, with random
    `ring_in` on every other edge. This checks the west-edge gate, and that a
    wave in flight finishes after `int_mode` falls;
  - what is checked: every drained tile and every combined output vs numpy;
    every PE's lap runs, taken from the RTL `ring_q` (offset r+c); the
    scheduled block period vs the formula; and, on multi-block runs, the
    measured drain-start spacing;
  - positive control: the global-lap schedule, with every PE's `ring_in`
    forced to one broadcast signal. It needs S more edges per pass;
  - `OLDC_UNFORCED`: the old contract applied to the grid with nothing forced
    (one global ring signal on every row, `shift_in` on the lap edges). It
    passes on 4x1 and fails on 2x2 and 4x8;
  - negative controls must fail with tile mismatches:
    - ring not skewed per row;
    - ring not skewed per column;
    - laps issued globally without waiting;
    - the three tightness controls (lap on the last MAC, drain one edge early,
      next block one edge early);
    - `RING_GATE_JUNK` with the west `int_mode` gate bypassed by force;
  - the grid built from the `csa_bp_20261003b` RTL fails per-PE laps and
    passes global laps.
- An independent adversarial grid harness, `sweeps/int_mode/bp/verify_grid/run_vg.sh`,
  with its own generator, player and checker:
  - shapes 1x1, 1x4, 1x8, 4x1, 8x1, 2x3, 4x4 (LOW_W=7) and 4x8;
  - back-to-back and mixed-precision blocks, 1-slice passes, extremes, junk
    planes, and old-contract `shift_in` on all-lapping edges;
  - SC ring junk, and INT -> SC -> INT with `int_mode` dropped while a wave is
    in flight;
  - reset/abort characterization (`reset_pass_n<n>_f<f>`, `reset_lap_*`);
  - one-edge fault negatives, including a stray global `shift_in` and the
    ungated ring in SC;
  - `ASBUILT=1` adds the as-built cross-check.
- An independent adversarial harness (`sweeps/int_mode/bp/verify/`), with 58
  scenarios. Ten cover the lap enable:
  - `neg_lap_without_shift` became the positive `lap_without_shift`;
  - ring-only laps with junk, with idle gaps inside laps, and with a dirty
    reset mid-lap;
  - four ring-only soaks;
  - two stray-ring negatives.
- An SC-isolation review (`sweeps/int_mode/bp/run_bp_sc_isolation_review.sh`).
  Its hooks baseline is now the commit before the hooks went in, since HEAD
  carries them.
- Post-synthesis functional GL: `sweeps/run_csa_bp_syn_gl_checks.sh`
  (default run `csa_bp_20261004_lap`; it includes `LAP_RING_ONLY` cases and the
  stray-ring negative).
- Routed functional GL, full timing (max SDF, `+neg_tchk`):
  `sweeps/int_mode/bp/run_bp_routed_func_gl.sh` runs the functional bench on a
  routed netlist. Eight cases: six `LAP_RING_ONLY` cases (INT8, W4A8, INT4,
  JUNK, `MODE_AT=3`), the old contract, and the stray-ring negative. Each GL
  trace must equal the RTL trace. On `csa_bp_20261004_lap_distguide_spp_pins`
  all eight pass (the negative is caught). On `csa_bp_20261003b_distguide_spp_pins`
  the six `LAP_RING_ONLY` cases fail, as they should
  (`build/rtl_preflight/csa_bp_routed_func_gl/`).
- Routed INT energy runs in the new contract: the power bench takes
  `BPE_LAP_RING_ONLY=1` (`shift_in` on drain edges only), and
  `check_bp_power_trace.py --lap-ring-only` requires it. On the
  `csa_bp_20261003b` RTL that mode fails (3,456 tile mismatches,
  `build/rtl_preflight/csa_bp_power_lapring/`).

## Routed results, per-PE lap enable (`csa_bp_20261004_lap`, 2026-10-04)

Same recipe as the `csa_bp_20261003b` campaign below:
- bootstrap route with floating pins, which seeds the workload power
  optimization;
- the floating-pin final;
- the pinned pass 2 with the same pin plan, guide script, flow and knobs
  (`sweeps/run_pinned_pass2.sh csa_bp_lap`);
- basin gate, max-SDF GL with cosim and SAIF, then PT-PX.

Evidence:
- `build/power_char/popcount_apr_csa_bp_20261004_lap/` (bootstrap and floating
  final);
- `build/power_char/pinned_pass2_csa_bp_20261004_lap/` (pinned final;
  `comparison.txt`, `results.csv`, `deviations.txt`,
  `gl_validator_args_rationale.txt`).

| SC mode, T=128 | CSA pinned | BP `03b` pinned | BP lap pinned | BP lap floating |
|---|---:|---:|---:|---:|
| route | `csa_20261002_..._spp_pins` | `csa_bp_20261003b_..._spp_pins` | `csa_bp_20261004_lap_..._spp_pins` | `csa_bp_20261004_lap_..._spp_fixed` |
| basin (corr, mean a/w skew) | grid (0.987, 20.5 ps) | grid (0.982, 37.3 ps) | grid (0.981, 37.7 ps) | grid (0.864, 43.1 ps) |
| routed area (um2) | 43,916.5 | 46,130.5 | 46,096.5 | 46,168.4 |
| 4x4 composite area (um2) | 521,100 | 531,415 | 531,322 | 531,410 |
| power (mW) | 15.726 | 16.491 | 16.494 | 16.771 |
| pJ/MAC | 0.6143 | 0.6442 | 0.6443 | 0.6551 |
| GMAC/s/mm2, 1 PE / 4x4 | 582.9 / 786.0 | 554.9 / 770.8 | 555.4 / 770.9 | 554.5 / 770.8 |
| setup / hold WNS (ns) | +0.116 / +0.166 | +0.061 / +0.140 | +0.078 / +0.158 | +0.076 / +0.158 |
| targeted repair | 1 MINCUT + 1 antenna | 1 MINCUT | 2 MINCUT | 1 SPACING + 1 MINCUT + 2 antenna pins |
| GL approvals (NDI / IWSBA) | 0 / 0 | 3 (-5 ps) / 4 | 9 (-9 ps) / 4 | 3 (-5 ps) / 4 |

**SC mode: the lap enable costs nothing measurable.** Both BP pinned layouts
are in the grid basin. Against `csa_bp_20261003b` pinned, the lap route is:
- power +0.004 mW (+0.02%);
- routed area -34 um2, 4x4 composite -94 um2;
- setup WNS +0.017 ns.

By hierarchy the tiles are +0.020 mW, pipes and ring +0.033, and the bypass
-0.020. That is inside the ±0.3 mW same-netlist layout noise. So every SC
number of the `csa_bp_20261003b` campaign holds for the lap RTL: +4.9% power
and +5.0% area per PE against CSA, and +2.0% 4x4 composite area.

The floating-pin lap final landed in the grid basin this time (corr 0.864); the
`csa_bp_20261003b` floating final had collapsed (20.74 mW). It measures 16.77
mW, 0.28 mW above the pinned one. That is within the ±0.3 mW spread between
layouts of one netlist: the CSA's floating and pinned finals also differ by
0.28 mW, in the other direction.

**INT mode in the new contract**, on the pinned route. Laps run on `ring_q`
alone, with `shift_in` only on drain edges (`BPE_LAP_RING_ONLY=1`). Each point
is max-SDF GL, bit-exact, with a GL trace identical to RTL, and 0 post-reset
timing violations, then PT-PX. Data:
`build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins/`
(`results.csv`, `vs_csa_bp_20261003b_pins.txt`).

| point (uniform data) | MAC/cycle/PE | pJ/MAC, lap route | pJ/MAC, `03b` pinned (old contract) | delta |
|---|---:|---:|---:|---:|
| INT8 L=1024, data + ring | 68.3 | 0.4533 | 0.4542 | -0.19% |
| INT8 L=1024, drain included | 64.0 | 0.4695 | 0.4704 | -0.20% |
| INT8 peak (L=49,152, data) | 128 | 0.3481 | 0.3489 | -0.21% |
| W4A8 L=1024, data + ring | 146.3 | 0.2186 | 0.2188 | -0.10% |
| INT4 L=1024, data + ring | 292.6 | 0.1094 | 0.1095 | -0.13% |
| INT4 L=1024, drain included | 256.0 | 0.1165 | 0.1167 | -0.13% |
| INT4 peak (L=98,304, data) | 512 | 0.0873 | 0.0875 | -0.23% |

The INT energy is unchanged. The small decrease is layout, and SC mode shows
the same shifts:

| | INT points | SC mode |
|---|---:|---:|
| top-level nets | -0.028 mW (even in data-only windows) | -0.029 mW |
| bypass (`u_peripheral`) | -0.015 to -0.021 mW | -0.020 mW |
| `u_pe` | +0.008 to +0.031 mW | |

The
INT GMAC/s/mm2 figures move with the area: about +0.07% on one PE and +0.02%
on the 4x4. So the routed INT table below and the grid L=4096 figures (1,128 on
4x4 and 1,055 on 4x8 GMAC/s/mm2, INT8) stand, and the per-PE lap enable that
the grid figures need is now routed and verified.

**Exceptions** (each documented beside its run):
1. **Targeted checkpoint repair** (`sweeps/repair_popcount_apr.sh`, in place,
   original archived under `before_legalization_*`):
   - pinned final: 2 M6 MINCUT, applied by the pinned pass 2 driver;
   - floating final: 1 M6 SPACING, 1 MINCUT and 3 antenna violations on 2
     pins, applied by hand with the same script. The campaign script has no
     repair stage; see `final_apr_adoption.txt`.
2. **GL validator approvals.** The strict audit ran first; approvals were used
   only after it failed:
   - `--approve-annotated-interconnect`: the 4 SDFCOM_IWSBA on the
     `int_out[60:63]` sign-extension alias. These appear on every BP route,
     bootstrap included;
   - `--approve-negative-iopath-clamp-ps 12`: COND IOPATH fall arcs on X0P5M
     AOI21/AOI211 cells of the SC comparator. The pinned route has 9 arcs on 3
     cells, worst -9 ps; the floating route has 3 arcs on 1 cell, worst -5 ps.
     Both are inside the existing 12 ps BP bound and the 10 ps CSA bound. Both
     routes have 0 max_tran.

   The same two approvals cover the INT runs and the routed functional GL on
   the same netlist and SDF.
3. **Side effect of the repair script:** it creates its lock files under
   `build/power_char/popcount_apr_20260930/repair_notes/`. These are new empty
   files; nothing existing was changed.

## Routed results (2026-10-04)

These results are for `csa_bp_20261003b`, the RTL before the per-PE lap enable.
A single PE schedules the same way in both RTLs, because a single PE has no
skew. Its area matches within 7 um2.

**Placement basin.** The first routed pass 2 (floating IO pins,
`csa_bp_20261003b_distguide_spp_fixed`) fell into a "row-collapsed" placement
basin and measured 20.74 mW in SC mode. The unchanged CSA netlist's own pass 1
landed in the same basin, at 20.80 mW. Root cause: `build/sc_power_regression/README.md`.

**Like-for-like comparison.** Pass 2 was re-run for both designs with the same
grid-matched fixed IO pins (`apr/scripts/place_pins_and_guides_sc.tcl`,
`sweeps/run_pinned_pass2.sh`). Both held the grid basin. Evidence:
`build/power_char/pinned_pass2_20261004/`.

| SC mode, T=128 | CSA (pinned) | BP (pinned) | delta |
|---|---:|---:|---:|
| routed area (um2) | 43,916.5 | 46,130.5 | +5.04% |
| 4x4 composite area (um2) | 521,100 | 531,415 | +1.98% |
| power (mW) | 15.726 | 16.491 | +0.76 (+4.9%) |
| pJ/MAC | 0.6143 | 0.6442 | +4.9% |
| GMAC/s/mm2, 1 PE / 4x4 | 582.9 / 786.0 | 554.9 / 770.8 | -4.8% / -1.9% |
| setup / hold WNS (ns) | +0.116 / +0.166 | +0.061 / +0.140 | |

An independent audit splits the +0.76 mW into about 0.2 mW of bypass hardware
and about 0.5 mW of tile glitching. The tile part comes from a larger a/w
operand skew in BP layouts (37 vs 20 ps): it is a layout effect, untested
beyond one sample per arm. Same-netlist layout noise is about +-0.3 mW.

**INT mode, measured on the routed BP netlist.** Real ports, max-SDF GL, all 45
points bit-exact, PT-PX. Uniform data:

| precision | MAC/cycle/PE | pJ/MAC peak (1 PE / 4x4) | pJ/MAC long GEMM L=4096 (1 PE) | GMAC/s/mm2 peak (1 PE / 4x4) | dedicated binary 8x8 array |
|---|---:|---:|---:|---:|---|
| INT8 | 128 | 0.349 / 0.338 | 0.380 | 1,110 / 1,542 | 1,621 GMAC/s/mm2, 0.412 pJ/MAC (older flow) |
| W4A8 | 256 | 0.175 / 0.169 | 0.191 | 2,220 / 3,083 | - |
| INT4 | 512 | 0.088 / 0.085 | 0.095 | 4,440 / 6,166 | 2,491 GMAC/s/mm2, 0.155 pJ/MAC |

Post-ReLU activations: INT8 0.215 and INT4 0.046 pJ/MAC at peak.

At L=4096 on a 4x4, ring laps, skew and drain cut INT8 to about 1,130 GMAC/s/mm2
(1.46 MAC/tile-cycle). That figure needs the per-PE lap enable
(`csa_bp_20261004_lap`). With the global laps of `csa_bp_20261003b` it is about
1,007. Operand delivery and SRAM energy are excluded, as they
are for the binary arrays. INT needs 4 bits/MAC into a 4x4 (INT8), against 2
for the binary array.

Data: `build/power_char/int_mode_energy_20261003/bp/csa_bp_20261003b_distguide_spp_pins/`
(`results.csv`, `composed_vs_L.csv`, `routed_summary.txt` one level up). The
floating-pin layout's INT results are kept beside it for reference; they are
1.28-1.39x higher.

**Exceptions**, documented beside each run:
1. **Targeted checkpoint repair:** one M6 MINCUT on the pinned BP route; one
   MINCUT and one antenna sink on the pinned CSA control.
2. **GL validator approvals for BP:**
   - `--approve-annotated-interconnect`: 4 SDFCOM_IWSBA on the `int_out[60:63]`
     sign-extension alias.
   - `--approve-negative-iopath-clamp-ps 12`: 3 SDFCOM_NDI on one AOI211 COND
     arc, -1 ps at the max corner on the pinned route. The 12 ps bound was set
     for 26 clamps of up to -11 ps on the floating-pin route.

   CSA needs no approvals.
3. **Pass-2 driver deviation:** the pinned pass 2 sets `SC_DISTRIBUTION_GUIDES=0`
   and sources the unchanged guide script from the pin script, because the
   target files override `PRE_PLACE_SCRIPT`.

## Other schedules on this RTL (2026-10-04, no RTL change)

The sequencer contract above allows other splits of the operand bits between space and time. The model is
`sweeps/int_mode/bp/model_lap_schedules.py`; the study is `doc/INT_mode_on_PaYN.md`, sections 2.2 and 9.

- **T2, weight bits in space** (reduction first, one shift at the end). It ties the as-built schedule on one PE and loses on grids:
  4x4 INT8 L=4096 reaches 45.7% of peak against 73.1%.
  - Benches: `designs/payn/tb/test_payn_array_bp_space.sv` and `designs/payn/tb/test_pe_grid_bp_space.sv`.
  - Results: `build/rtl_preflight/bp_space/`. That run has 127 simulation cases plus 6 cross-checks, all as expected.
- **H(TA,TW), activation bits partly in time as well.** INT8 H(4,8) holds 32 outputs per PE. On 4x4 at L=4096 it reaches 89.7%
  (1,142 cycles per block), on 4x8 86.9%.
  - Grid bench: `designs/payn/tb/test_pe_grid_bp_hybrid.sv`.
  - Single-PE top bench: `designs/payn/tb/test_payn_array_bp_hybrid.sv`.
  - All runs are bit-exact on this RTL, and their periods match the formula `TA*TW*NB + 8*(TA+TW-2) + (P_R+P_C-2) + 8*P_C`.
  - What it needs outside this RTL:
    - per-pass reloads of both sign words, which the contract already allows;
    - an east combine `y = sum_g 2^(g*TA) T` that the top's `bp_combiner.sv` does not do. A proposal is in
      `designs/payn/variants/signed_segmented_csa_bp_hyb/bp_hybrid_combiner.sv`, checked as a sidecar and not synthesized;
    - activations delivered as bit planes.
  - Range: `|Afield| * |Wfield| * L < 2^23`, so INT8 H(4,8) allows L <= 4,369 per block.

```bash
bash sweeps/int_mode/bp/space/run_bp_space_checks.sh       # T2 (proof stage)
bash sweeps/int_mode/bp/hybrid/run_bp_hybrid_checks.sh     # H on grids + extra T2 (review stage)
bash sweeps/int_mode/bp/hybrid/run_bp_hybrid_fix_checks.sh # H: range edge, 3x2, 4x8 W4A8/INT4, H(2,4)
bash sweeps/int_mode/bp/hybrid/run_bp_hybrid_top_checks.sh # H on the single-PE top + hybrid combiner sidecar
python3 sweeps/int_mode/bp/model_lap_schedules.py > sweeps/int_mode/bp/model_lap_schedules.log
```

## Reproduce

```bash
bash sweeps/run_csa_bp_rtl_checks.sh
PARTS=asbuilt bash sweeps/run_csa_bp_rtl_checks.sh  # optional: as-built cross-check
bash sweeps/int_mode/bp/run_bp_grid_checks.sh       # PE grid, per-PE laps
ASBUILT=1 bash sweeps/int_mode/bp/verify_grid/run_vg.sh   # independent grid harness
bash sweeps/int_mode/bp/verify/run_bpv.sh
bash sweeps/int_mode/bp/run_bp_sc_isolation_review.sh
RUN_NAME=csa_bp_20261004_lap RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_BP NTFY_CHNL=
bash sweeps/run_csa_bp_syn_gl_checks.sh             # RUN=csa_bp_20261004_lap
bash sweeps/int_mode/bp/report_bp_new_paths.sh csa_bp_20261004_lap
bash sweeps/int_mode/bp/report_bp_routed_shift_in.sh  # routed shift_in slack, 20261003b layouts
# Routed campaign (csa_bp_20261003b RTL):
RUN_NAME=csa_bp_20261003b RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_BP NTFY_CHNL=
BP_SYNTH_RUN=csa_bp_20261003b CAMPAIGN=csa_bp_20261003 \
  GL_VALIDATOR_ARGS="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12" \
  bash sweeps/run_popcount_apr.sh csa_bp            # bootstrap pass (floating pins)
bash sweeps/run_pinned_pass2.sh                     # pinned pass 2, BP + CSA control
ROUTE_RUN=csa_bp_20261003b_distguide_spp_pins APR_CAMPAIGN_WORK=build/power_char/pinned_pass2_20261004/csa_bp \
  TAG=intBPpin GL_VALIDATOR_ARGS="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12" \
  bash sweeps/int_mode/bp/run_bp_int_energy.sh
# Routed campaign (csa_bp_20261004_lap RTL, per-PE lap enable):
BP_SYNTH_RUN=csa_bp_20261004_lap CAMPAIGN=csa_bp_20261004_lap bash sweeps/run_popcount_apr.sh csa_bp
#   (strict first; then GL_VALIDATOR_ARGS per popcount_apr_csa_bp_20261004_lap/gl_validator_args_rationale.txt,
#    RETRY_FAILED=1; the floating final was repaired by hand, csa_bp/final_apr_adoption.txt)
bash sweeps/run_pinned_pass2.sh csa_bp_lap          # -> build/power_char/pinned_pass2_csa_bp_20261004_lap
bash sweeps/int_mode/bp/report_bp_routed_shift_in.sh csa_bp_20261004_lap_distguide_spp_pins csa_bp_20261004_lap_distguide_spp_fixed
BPE_LAP_RING_ONLY=1 ROUTE_RUN=csa_bp_20261004_lap_distguide_spp_pins \
  APR_CAMPAIGN_WORK=build/power_char/pinned_pass2_csa_bp_20261004_lap/csa_bp_lap TAG=intLAPpin \
  OUT=build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins \
  GL_VALIDATOR_ARGS="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12" \
  POINTS="int8_uniform_L1024_dr int4_uniform_L1024_dr int8_uniform_L1024_all int4_uniform_L1024_all w4a8_uniform_L1024_dr int8_uniform_L49152_d int4_uniform_L98304_d" \
  bash sweeps/int_mode/bp/run_bp_int_energy.sh
ROUTE_RUN=csa_bp_20261004_lap_distguide_spp_pins \
  GL_VALIDATOR_ARGS="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12" \
  bash sweeps/int_mode/bp/run_bp_routed_func_gl.sh
```
