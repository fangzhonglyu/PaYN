# Folding the INT doubling lap into the next level's first MAC (plan)

Status: **implemented, verified, routed and measured** (2026-10-08) as `PAYN_LAP_FOLD=1`, default 0; section 9 has
the implementation and the measured results. Sections 1-8 are the original plan, kept as written. The motivation
and the effect numbers come from PaYN_eval (`tools/latency_split.py`, `tools/edp_levers.py`; tables in
`results/model_tables/sweep_bos_wedge_mp/latency_split.md` and
`results/model_tables/sweep_bos_wedge_mp_sc7int6/edp_levers.md`); they are first-order model arithmetic,
not measurements. Shape and grid throughout: **K16/M8 DR, 4x8 PEs**, 400 MHz.

## 1. Problem

All-bits-in-time INT runs BA*BW passes per output block, grouped by significance level, MSB level first,
with one in-place doubling lap between levels (`doc/cbsg_handoff.md` section 5). A lap is a whole edge in
which every tile reloads `2 * acc_out` and the MAC is dropped, so the feed inserts a bubble capture for it.
The drain-register block period is

    max(BA*BW*NB + (BA+BW-2) + 2, 2*P_C)          NB = ceil(L/128)

The measured sheet points are long reductions (L = 1,024 / 4,096), where BA+BW-2 laps hide behind
BA*BW*NB data edges. **In the workload they don't**: LLM linears use per-group (128-element) quantization,
so every INT block is one group, NB = 1, and the laps are a large share of the period:

| precision | data edges | laps | drain bubble | period (NB = 1) | laps share |
|---|---:|---:|---:|---:|---:|
| INT4 | 16 | 6 | 2 | 24 | 25% |
| INT6 | 36 | 10 | 2 | 48 | 21% |
| INT7 | 49 | 12 | 2 | 63 | 19% |
| INT8 | 64 | 14 | 2 | 80 | 18% |

In PaYN_eval (best setup: 4x8 + W-edge buffer, ladder-8 traces), INT-masked layers on the dense LLMs are
18-24% of MACs but 27-34% of PaYN's latency at t32. They run 1.3-1.7x slower than iso-area BOS INT6 does
on the same layers (14B: 12.6 s vs 8.9 s), and laps are 2.3 s of 14B's 12.6 s.

## 2. Today's lap (RTL)

- `payn_pe.sv` header and `PaynPeCore` (`g_col`): `tile_acc_in = lap ? {own acc_out, 1'b0} : west`
  (DRAIN=1: `: 0`). `PaynPe` drives the tile shift as `shift_in | ring_q` and `lap = ring_q`. So a lap
  edge is a shift edge that loads `2 * value mod 2^24`.
- `payn_tile.sv`, `PaynTile`: a shift has priority over `mac_en`, so the MAC on a lap edge is dropped. The
  shift also clears `pending_carry` / `pending_borrow`; `acc_out` already has the pending bit folded in.
- The schedule (`designs/payn/tb/test_payn_array.sv` `+MODE=abit`; `designs/payn/model/int_trace.py`
  abit/abit-grid): `ring_in` goes high one edge ahead, and there is one bubble capture plus one 1-edge lap
  per level step. The `ring_q` wave runs east one PE per edge, in step with the A skew.

## 3. Proposal: a fold edge

Make the level step's edge also the next level's first MAC:

    fold edge:   acc <- 2*acc + S          (S = this edge's heap sum, sign correction included)
    other edges: unchanged (MAC, shift / drain, DR read)

The segmented accumulator (`LOW_W` = 9, `HIGH_W` = 15) does this without a new adder:

- **Low segment.** Feed `{acc_low[LOW_W-2:0], 1'b0}` into the heap instead of `acc_low` (the heap input
  is SUM_W = 11 bits wide, so it fits). Then `low_sum = 2*(acc_low mod 2^8) + S` lies in [-K*M, 510 + K*M]
  = [-128, 638], inside today's range [-K*M, 2^(LOW_W+1)-1]. So carry and borrow are still at most one,
  and `pending_carry` / `pending_borrow` work unchanged.
- **High segment.** `acc_high <= {high_next[HIGH_W-2:0], acc_low[LOW_W-1]}`, i.e. 2*high_next + the bit
  that leaves the low segment. This is wiring plus a select; `high_next` already folds the previous
  edge's pending bit.
- **Check:** (2*high_next + a8)*2^9 + {a[7:0],0} + S = 2*(high_next*2^9 + acc_low) + S = 2*acc_out + S,
  mod 2^24, exactly what a lap followed by a MAC gives.

Schedule change: no bubble capture, and the `ring_q` edge keeps `mac_en`. The `ring_in` timing and the
per-PE wave are unchanged. The new period:

    dr:    max(BA*BW*NB + 2, 2*P_C)
    tile:  BA*BW*NB + (P_R+P_C-2) + 8*P_C

The first level needs no fold (the block starts from a cleared accumulator). A fold never coincides with a
DR read edge; the DR contract already forbids a read on a lap edge. In SC mode `ring_in` is held at 0, so
SC is unaffected. The bit-plane schedule's laps (between W passes) could fold the same way, but that
schedule is not available with `PAYN_DRAIN=1`, so it is out of scope.

## 4. RTL changes (behind a build define, e.g. `PAYN_LAP_FOLD=1`, like `PAYN_DRAIN`)

1. `PaynTile`: a `fold` input. On `fold && !shift_in`, the heap's accumulator row takes the shifted low
   segment and `acc_high` takes the shifted `high_next`. Pending-bit handling stays as on a MAC edge.
   Shift keeps priority.
2. `PaynPeCore`: `fold = lap`. The `lap` leg of `tile_acc_in` goes away: DRAIN=1 leaves `0` (the read
   clear), DRAIN=0 leaves `west`.
3. `PaynPe`: `core_shift = shift_in` (`ring_q` no longer forces a shift).
4. With the define at 0, the qualified hardware must be unchanged (Formality against the committed RTL,
   as was done for `PAYN_DRAIN`).

## 5. Timing and area

**Timing.** The DR route (`apr/build/TSMC22/PAYN/payn_k16m8_dr_20261007_final/reports/setup.rpt`) closes
at +51 ps WNS. But all 999 reported setup paths (+51 to +349 ps) start at an input port or a peripheral
register:
- Ports carry a 1.25 ns input delay (`payn_array.syn.sdc`). The worst path is
  `shift_in -> u_pe/U3 -> row_shift buffers -> acc_high_reg_0_/D`.
- The peripheral-register paths start at `a_len_q` and end at `a_bits_pipe`.

None starts at `acc_low_reg`, `acc_high_reg` or `ring_q`, so those register-to-register paths have more
than +349 ps of slack. The fold adds two things:
- A 2:1 mux on the `acc_low` leg into the CSA tree. That leg skips the popcount levels, so it is shorter
  than the operand legs.
- A select on `acc_high`'s D input, driven from `ring_q` (a flop), not from the port.

**Watch item:** the `acc_high` D-side logic is also the end of today's worst port path
(`shift_in -> acc_high/D`, +51 ps). The fold select must not sit after the shift select. Merge it into
the existing D-input mux (today's AO22), or keep the port-driven select last.

**Area:** per tile, a 9-bit select on the low leg and a 15-bit select on `acc_high`. Against that, the
24-bit lap leg of `tile_acc_in` is removed. The net is expected to be small; synthesis decides.

## 6. Energy

The lap edge clocks every tile and the operand pipes once more per level step and reloads every
accumulator. The fold removes the edge and keeps the doubling inside the MAC edge's update. In the INT fit
used by PaYN_eval (`payn_int_lut`, K16/M8 DR, 4x8 weights), the lap term is 19.2% (INT6) and 17.5% (INT7)
of a block's dynamic energy at NB = 1. That is an **upper bound** on the saving, because a fold edge
toggles the accumulator more than a plain MAC edge. Leakage also drops with the shorter period.

## 7. Effect (PaYN_eval, first order)

Grid INT throughput at NB = 1, 4x8 (MAC/clk; BOS INT6 8x13, iso-area: 6,656):

| precision | today | folded |
|---|---:|---:|
| INT4 | 10,923 | 14,564 |
| INT6 | 5,461 | 6,899 |
| INT7 | 4,161 | 5,140 |
| INT8 | 3,277 | 3,972 |

Whole models, t32. Latency comes from per-layer max(compute, DRAM) with the lap edges removed; energy uses
the fit's lap term (the upper bound above):

| setup | 4B | llama8B | 14B | 30B | ViT-L |
|---|---:|---:|---:|---:|---:|
| as run (INT7 masks), latency | -5% | -6% | -5% | -1% | -2% |
| 7-bit SC words + INT6 masks, latency | -4.1% | -5.6% | -4.1% | -0.9% | -1.7% |
| same, energy (upper bound) | -4.4% | -5.3% | -4.1% | -4.2% | -2.0% |
| same, EDP | -8.3% | -10.6% | -8.0% | -5.0% | -3.6% |

30B is DRAM-bound, so it gains energy but little latency. ViT has few INT layers.

## 8. Risks and verification

- **Bench and model:** an abit fold mode in `test_payn_array.sv` and `int_trace.py` (schedule and period
  formula). Regress abit and grid-abit on both drains.
- **Coverage:** the existing `LAP_COVERAGE` pending-carry/borrow counters, applied to fold edges. A fold
  that meets a pending bit is the corner the segmented accumulator must get right.
- **Negative controls** the checker must catch:
  - a fold that drops the MAC (today's lap with no bubble);
  - no fold before level n;
  - an extra fold;
  - a fold one edge late (on the level's second capture);
  - a fold on a DR read edge.
- **Equivalence:** Formality with the define at 0 against the committed RTL.
- **Characterization:** route with the same flow; PT-PX on the abit points (INT4/6/7/8 at L = 1,024 /
  4,096) plus an NB = 1 (L = 128) point, the one per-group quantization actually runs.
- **PaYN_eval follow-up:** in `payn_int_lut`, lap edges become 0 under the fold. Refit the energy (the lap
  coefficient goes) from the new measurements, and rerun the sweeps.

## 9. Implemented (2026-10-08)

Build-time define `PAYN_LAP_FOLD` (`designs/payn/rtl`, default 0), with either drain. Routed and measured on
**K16/M8 DR** (`PAYN_DRAIN=1 PAYN_LAP_FOLD=1`) and compared with the drain-register route `payn_k16m8_dr_20261007`
(the same flow, the same point set; `doc/payn_results.md`, "Lap fold vs in-place lap").

### 9.1 RTL

The fold is built as section 3 describes. `fold` reaches the tile from the existing `ring_q` wave, so there is
no new control.

- `PaynTile` (`FOLD` parameter, `fold` input):
  - **Low segment:** the heap's accumulator row is `fold ? {acc_low[7:0], 0} : acc_low`.
  - **High segment:** on a fold edge, `acc_high <= {high_next[13:0], acc_low[8]}` in place of the pending-bit
    update. Pending carry and borrow work as on any MAC edge.
  - **Priority:** shift keeps priority.
- `PaynPeCore`:
  - `fold = lap`, and the lap leg of `tile_acc_in` is gone.
  - Simulation-only checks, `[FOLD-CONTRACT]` (fatal): a fold on a shift edge, and a fold without `mac_en`. A fold
    is defined only on MAC edges, so no hold leg is built. In a legal schedule the fold edge is the first MAC of
    its level, far from the int_mode guard.
  - A fold on a drain-register read edge stays a `[DR-CONTRACT]` error.
- `PaynPe`: the tile shift is `shift_in` (with `FOLD` = 1, `ring_q` no longer forces a shift).
- `PaynPeGrid`, `payn_array`: the parameter. `payn_array`'s `[SC-CONTRACT]` MAC accounting treats a fold edge as a
  MAC edge.
- SC mode is unchanged: `ring_in` is gated by `int_mode`.

**Schedule.** Between levels there is no bubble: the next level's first plane is captured on the edge after the
previous level's last. `ring_in` goes high on that capture edge, so the fold edge is that plane's MAC edge.

**Block period.** The `(BA+BW-2)` term leaves both formulas:
- in-tile chain: `BA*BW*NB + (P_R+P_C-2) + 8*P_C`;
- drain register: `max(BA*BW*NB + 2, 2*P_C)`.

**Scope.** The bit-plane schedule is not run on fold builds: benches and flows refuse it, as on drain-register
builds.

### 9.2 Verification

- **Equivalence.** Formality with the define at 0 against the committed RTL: array K16/M8 7,687, array K16/M8 DR
  8,199, K8/M16 6,451, grid 2x2 22,420, grid 2x2 DR 25,504 compare points. All equivalent, none unmatched (the fold
  adds no port). Script: `build/lap_fold/equiv/run.sh`.
- **Tile unit test.** `test_payn_units.sv` part 5 checks `PaynTile` with `FOLD` = 1 against an integer model over
  200,000 random shift, fold+MAC, MAC and idle edges:
  - bit-exact;
  - 72,184 folds, 2,269 of them meeting a pending carry and 2,224 a pending borrow.

  Three mutants all fail it: the high segment dropping the bit that leaves the low segment; the heap row not
  doubled; the fold skipping the pending bit (`build/lap_fold/mutation/`).
- **Benches and model.**
  - Benches: `+MODE=abit` in `test_payn_array.sv`, `test_payn_pe_grid.sv` and `power_payn_int.sv` runs the fold
    schedule on fold builds. `+ABIT_FOLD=0|1` overrides the schedule.
  - Model: `int_trace.py` takes the header fields `fold` (the schedule) and `hw_fold` (the build). It checks the
    fold schedule rules (no bubble, the fold on the next level's first MAC edge) and replays the stimulus with the
    build's lap semantics.
  - A fold-schedule run also reports how many drained values a lap build would get wrong on the same stimulus.
- **Regression** (`python3 flow/regress.py --fold 1 [--drain 1] --shape both`, `build/lap_fold/regress/`). Both
  shapes, both drains: cases, units, sc, abit, grid-abit and power (without its bit-plane rows). Counts per drain:

  | suite | in-tile chain | drain register |
  |---|---:|---:|
  | cases | 3/3 | 3/3 |
  | units | 1/1 | 1/1 |
  | sc | 94/94 | 98/98 |
  | abit | 102/102 | 102/102 |
  | grid-abit | 49/49 | 67/67 |
  | power | 11/11 | 11/11 |

  New tables: `flow/cases/abit_fold.txt` and `grid_abit_fold.txt`, with a build column (lap / fold / both), including
  NB = 1 rows at INT2-INT8 and W4A8 on 1 PE and 4x8. Over the 60 fold-schedule abit runs per build, a lap build would
  get 8,320 drained values wrong, so the fold's MAC is exercised.

  The lap builds pass the edited tables too: abit 93/93, grid-abit 46/46 (in-tile) and 64/64 (DR), power 20/20. The
  K16/M8 grid suites were rerun in `build/lap_fold/regress_grid/` after a VCS license shortage; `regress.py` now
  queues its simulations for a license.
- **Negative controls**, all caught:

  | control | how it is run | caught by |
  |---|---|---|
  | a fold that drops the MAC | the fold schedule on a lap build, `ABIT_FOLD=1` (1 PE, 4x4) | checker: GEMM mismatch, RTL = replay |
  | no fold before level n | `NEG_ABIT_NO_LAP` | checker |
  | an extra fold | `NEG_ABIT_EXTRA_LAP` | checker |
  | a fold one edge late | `NEG_FOLD_LATE=n` (1 PE, 2x2, 4x4) | checker |
  | a fold one edge early | `NEG_FOLD_EARLY=n` (1 PE, 4x8), and the lap schedule without its bubble on a fold build | checker |
  | a fold on a drain edge | `NEG_FOLD_ON_DRAIN` | `[DR-CONTRACT]` with the drain register, `[FOLD-CONTRACT]` with the in-tile chain |
  | the old lap schedule on a fold build | `ABIT_FOLD=0` | must pass, and does: its bubbles add zero |

  Two drain-early controls moved from NB = 1 to NB = 2: `gneg2_int8_drainearly`, `drneg8_int8_drainearly`. At
  NB = 1 a fold build's last fold lands on the early drain edge, a contract stop instead of a checker catch.
- **Gate level.**
  - Post-synthesis: the netlist folds. With unit delay, three abit rows give traces byte-identical to the fold
    RTL's (`gl_abit.txt` rows now also run in syn-unit).
  - Routed functional GL: SC 14/14, abit 19/19 (fold schedule).

### 9.3 Measured (K16/M8 DR, single PE routed; grids by the report's composite)

The route, `payn_k16m8_dr_fold_20261008_final`:
- qualified final after the targeted repair of one residual marker;
- setup +0.053 / hold +0.182 ns (DR route: +0.051 / +0.170);
- grid basin, pin proof 6,418 / 0.

**Timing.** The worst paths are still the port and peripheral paths (`a_len_q` → `a_bits_pipe`). The fold select's
path, `ring_q` → heap row → `pending_carry/D`, has +0.224 ns of slack.

**Area.**

| | lap (DR) | fold (DR) | change |
|---|---:|---:|---:|
| 1 PE (routed) | 59,542 µm² | 59,006 µm² | −0.9% |
| 4x4 composite | 646,553 | 638,599 | −1.2% |
| 4x8 composite | 1,210,891 | 1,194,993 | −1.3% |
| `u_pe` | 34,196 | 33,694 | −1.5% |
| tiles | 27,842 | 28,076 | +0.8% |
| doubling mux (lap leg) | 709 | 0 | |

The 24-bit lap leg is removed. The fold's 9-bit row select and 15-bit high select are inside the tiles.

**INT, all bits in time.** The headline window is data + laps, drain excluded. GMAC/s/mm² is 4x8 at 400 MHz, with
each route's own period and area.

| point | period lap → fold | pJ/MAC lap → fold | 4x8 GMAC/s/mm² lap → fold | vs BOS |
|---|---:|---:|---:|---:|
| INT8 L=128 | 80 → 66 | 0.4926 → 0.4397 (−10.7%) | 1,082 → 1,330 (+22.8%) | 0.82x |
| INT7 L=128 | 63 → 51 | 0.3867 → 0.3406 (−11.9%) | 1,375 → 1,721 (+25.2%) | 0.95x |
| INT6 L=128 | 48 → 38 | 0.2928 → 0.2549 (−12.9%) | 1,804 → 2,309 (+28.0%) | 1.12x |
| INT4 L=128 | 24 → 18 | 0.1425 → 0.1184 (−17.0%) | 3,608 → 4,875 (+35.1%) | 1.96x |
| INT8 L=384 | 208 → 194 | 0.4142 → 0.3938 (−4.9%) | 1,249 → 1,357 (+8.6%) | 0.84x |
| INT7 L=1,024 | 406 → 394 | 0.2998 → 0.2899 (−3.3%) | 1,706 → 1,782 (+4.4%) | 0.99x |
| INT6 L=1,024 | 300 → 290 | 0.2223 → 0.2144 (−3.5%) | 2,309 → 2,421 (+4.8%) | 1.17x |
| INT4 L=1,024 | 136 → 130 | 0.1001 → 0.0960 (−4.1%) | 5,094 → 5,400 (+6.0%) | 2.17x |
| L=4,096 (INT4/6/7) | −0.8 to −1.2% | −2.3 to −2.5% | +2.1 to +2.5% | |

- **Periods:** the measured periods equal the formulas. At NB = 1 the throughput gain is the period ratio of
  section 7 (+33 / +26 / +24 / +21% for INT4 / 6 / 7 / 8) plus the 1.3% area.
- **Energy:** the measured energy saving at NB = 1 (INT6 −12.9%, INT7 −11.9%) is below the upper bound of section 6
  (19.2% / 17.5%), as expected. A fold edge toggles more than a plain MAC edge. The data-only window shows it in
  isolation: INT8 L=384 `d` +1.3% (14 folds per 192 data edges), against −1.5% at L=4,096.
- **Energy × period** per block at NB = 1: −26% (INT8) to −38% (INT4).

**SC.** −0.9% to −1.3% at every stream length (uniform L = 8 ... 128, ladder): the same hardware minus the lap leg.

### 9.4 Not done

- K8/M16 is not routed with the fold. Neither is the in-tile-chain build; it is verified in RTL only.
- The bit-plane schedule's laps could fold the same way. It is not run on fold builds.
- PaYN_eval: in `payn_int_lut` set lap edges to 0 and refit the energy model from these measurements. The lap
  coefficient goes, and the fold-edge cost appears in the `d` points. Then rerun the sweeps. That is in PaYN_eval,
  not here.
