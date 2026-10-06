# C-BSG RG: per-row generator on the carry-save array

The carry-save single-PE array (`signed_segmented_csa`, K8/M16/N8) running the scmp_kernels C-BSG
multiplication **bit-exactly**, design RG of [`sweeps/cbsg`](../../../../sweeps/cbsg/README.md): the
literal C-BSG, in which the kA A ones of an element in a block meet W samples 0..kA-1. The CSA tile
(`InnerTileSignedSegmentedCsa`) is used unchanged, included from `signed_segmented_csa`. The top keeps the
CSA top's port names and adds `row_len_in`, `block_start` and `slice_start`.

Status (2026-10-05, after review fixes): all RTL checks pass, and synthesis (run `cbsg_rg_20261005`) meets
2.5 ns with **+0.05 ns** slack at **88,196 um2, 2.03x the CSA baseline** (43,455 um2), i.e. about half the
GMAC/s/mm2. Nothing has been routed or simulated at gate level (see "Synthesis" and "Open items").

| file | module (instance) | what it holds |
|---|---|---|
| `payn_array_signed_segmented_csa_cbsg_rg.sv` | `payn_array_signed_segmented_csa_cbsg_rg` | top, block-phase register `phase_q` with its drain/reset arm `phase_rst_pend_q`, sequencer contract (header) |
| `cbsg_rg_edge.sv` | `cbsg_rg_sobol_q_bank` (`u_a_rng`) | A Sobol "q" bank in sample order, reduced to H(c) (8 flops) + cycle index c (4 flops, saturates at 8) |
| | `cbsg_rg_edge` (`u_peripheral`) | operand registers (A magnitude, A sign, per-row L, W magnitude, W sign); 1,024 A comparators with the `t < L_row` gate |
| `inner_pe_signed_segmented_csa_cbsg_rg.sv` | `InnerPESignedSegmentedCsaCbsgRg[Flat]` (`u_pe/u_array_core`) | bit and magnitude pipes, 64 W index generators, 8,192 per-tile W comparators, 64 CSA tiles |

## Timing fixes (2026-10-05, runs cbsg_rg_20261005b and cbsg_rg_20261005d)

These changes keep the function cycle for cycle; the RTL suite and the post-synthesis GL checks pass on both runs. Campaign notes:
`build/power_char/cbsg_20261005/rg/timing_fix_README.txt`.

- **j pre-clear (b).** The block-start clear of `j` is now part of each generator's own `j` next-state: `j`
  loads 0 while `first_in` is 1. It used to be applied after the register as `cur_j = first_pipe ? 0 : j`.
  The routed critical path started at `first_pipe`'s 512-load buffer tree, and that tree is now off the
  path. The change relies on `first_in` implying `valid_in`, which the top guarantees; a simulation `$error`
  checks it. Synthesis slack went from +0.05 to +0.21 ns, and area dropped by 137 um2.
- **Per-row A-edge state (d).** `u_a_rng` (`cbsg_rg_edge_state_rep`) holds one copy of the q bank and the
  block phase per A row. Row h's 128 comparators read copy h. Before, one copy fed all 1,024 comparators,
  and b's routed max-corner GL failed setup through that net's fan-out tree. The top's `phase_q` still feeds
  the PE. This costs 108 registers and adds 289 um2 over b.

## Datapath

**Operands.** `a_binary_in` and `w_binary_in` carry the kernel boundary `b = round(|q|*128/127)` (0..128)
in each 8-bit field. Signs are 1 = negative. `row_len_in` carries `L_h` (1..128) per A row. All of these
are latched with `load_a` / `load_w`.

**Mask.** `mask = {bitrev3(k), bitrev3(p), 2'b00}` = `bitrev8(d mod 64)` with `d = 8p + k`:
- Lane bits are wired.
- `p` is the 3-bit `phase_q`. On every block start it resets to 0 if the block opens a slice, otherwise it
  increments. A block opens a slice when `slice_start` is 1, or (`DRAIN_PHASE_RESET = 1`, the default) when
  a drain or a reset came since the previous block start: `phase_rst_pend_q` is set by reset and by the
  first shift edge of a drain, and cleared by the next block start.
- Every slice ends with a drain, so a sequencer that forgets `slice_start` at a call or chunk start (the
  deployed scrambling-mask bug, sweeps/cbsg README) still gets phase 0. `slice_start` is still needed for a
  slice that does not follow a drain (the power bench's undrained chunks), and it is the only reset with
  `DRAIN_PHASE_RESET = 0`. A drain in the middle of a slice (partial-sum readout) would restart the phase;
  such a sequencer needs `DRAIN_PHASE_RESET = 0`.

Thresholds are `(x ^ mask) >> 1` on the 7-bit grid.

**A edge (`u_a_rng`, `u_peripheral`).**
- Position m of cycle c is sample `t = 16c + m`, with `x[t] = H(c) ^ LANE(m)`.
- `LANE(m)` is a constant, so the 16 sample words are H with constant inversions. The bank needs no 128
  output flops, unlike soren's `sobol_bank`.
- A bit: `[b_A > ((x[t] ^ mask) >> 1)] & [t < L_h]`.

**W index generator, per (row h, lane k) in the PE.**
- `j` (IDX_W bits) counts the A ones of (h, k) in earlier cycles of the block. The block's first cycle
  clears it, and it advances only on valid (rng_en) cycles.
- `idx[m] = j + #(A ones at positions < m)`. With this prefix the i-th A one meets W sample i, but that
  order is neither observable nor required: the tile only sees the lane popcount of `a & w`, so a cycle with
  n A ones depends only on the index set {j, ..., j+n-1}, and any in-cycle assignment of those indices gives
  the same sum. What matters, and what the goldens pin, is that a block's kA A ones receive exactly the
  indices 0..kA-1 (reviewer mutants that reverse the in-cycle prefix survive; ones that shift the set die).
- `x = XOR_b gray(idx)[b] * V_k[b]`, with the k seed 80 40 20 10 48 04 52 ff.
- `thr = (x ^ mask) >> 1`.
- Tile (h, v) compares `w_bit[k][m] = b_W(v, k) > thr[h][k][m]` and feeds it to the CSA tile's `w_bits`.
  Its `a_bits` are the gated A bits.
- `w_bits_pipe` holds the 8-bit W magnitudes. It keeps the old name, so the APR distribution guides
  (`u_pe/u_array_core/w_bits_pipe_reg_*`) still match. `a_bits_pipe` is unchanged.

**IDX_W.** The default 8 holds the exact count, because a block has at most 128 A ones. IDX_W = 7 is also
bit-exact, because the wrap at 128 only reaches lanes with no A one. soren's 9 is wider than needed. Both 7
and 9 are verified.

**Pipeline.**
- Edge G generates a slice (bank register to comparators).
- Edge G+1 registers it in the PE pipes.
- Edge G+2 runs generator, compare and tile, and accumulates.

`first`, `valid` and `phase` travel with the bits. The sequencer contract in the top header covers loads on
the block's first generation edge, MAC two edges after generation, stalls, phase reset and drain timing. A
drain costs N_W generation slots, and the next block's loads and generation overlap the drain shifts.

**Differences from soren's `inner_pe.sv` (the reference RTL).**
- Per-row `L` with the gate at the edge, instead of one `stream_len` per PE.
- A 3-bit phase register reset by `slice_start` or a preceding drain, instead of a `d_base` port. Nothing
  else feeds the mask (sweeps/cbsg README, "the scrambling-mask fix").
- The H-only bank.
- A saturating cycle index, instead of an 8-bit slice counter.
- `j` gated by a valid flag, so stalls anywhere are legal.
- `IDX_W = 8`.
- A CSA tile instead of the plain-AND `InnerTile`.

## Verification (RTL, 2026-10-05, after review fixes)

Run with `bash sweeps/cbsg/rg/run_rtl_checks.sh` (about 4 minutes; it loads the six pinned EDA modules, and
every VCS compile and simv waits for a license instead of failing). Summary:
`build/cbsg/rg/rtl_checks_summary.log`.

| part | what | result |
|---|---|---|
| goldens | `cbsg_ref.py --check-golden` on the 12 shared cases (read only); `sweeps/cbsg/rg/gen_cases.py` writes 9 long multi-call cases to `build/cbsg/rg/golden_extra`, each written only after kernel == RG == AF, then re-derived | 12/12 + 9/9 PASS |
| playback, `[pass]` | `designs/payn/tb/test_payn_array_cbsg_rg.sv`: all 21 cases; FULL_CYCLES (8 cycles per block); random STALL edges; JUNK on every input that must be ignored; IDX_W = 7 and 9 builds; the slice_start-only build (`DRAIN_PHASE_RESET = 0`); drain-only `+NO_PEEK` runs and a GL_SIM-shaped build (no parameter overrides, no hierarchical reads) | 52/52 PASS: 241,280 drained accumulators (3,770 drains), 28,817 block checks (every tile after every block) and 28,817 phase checks, all bit-exact |
| playback, `[fail]` | negative controls; each must show drain mismatches, with **exactly** the counts `sweeps/cbsg/rg/predict_faults.py` predicts from the .mem files (drain, block and phase counts) | 33/33 PASS |
| playback, `[blind]` | negative controls a case cannot see (0 drain mismatches, as predicted); includes 12 runs of the three phase-reset sequencer mistakes on the default build, where block and phase counts are 0 too | 16/16 PASS |
| compile | `FAULT = 1` without `CBSG_RG_FAULT_HOOKS` stops at time 0 | PASS |
| streaming power bench | `designs/payn/power/power_payn_array_cbsg_rg.sv`, 384 back-to-back blocks, SAIF captured; drain recomputed by `sweeps/cbsg/rg/check_power_trace.py` (kernel `kernel_acc_chunked` and `hw_rg_acc`) | uniform L = 128: 3,072 window clocks, PASS; ladder_rowmix: 2,816 (8/6/4 cycles on 272/96/16 blocks), PASS; ladder_rowgrouped: 1,680 (8/6/4/3 cycles on 80/32/32/240 blocks), PASS |
| fault-hook guard | DC GTECH elaboration (no target library): FAULT = 1, 2, 4, 6 without the hooks define write the same netlist as FAULT = 0; with the define, FAULT = 2 and 4 change it | 6/6 PASS (5,082 registers) |

The extra cases:

| case | what it covers |
|---|---|
| `allL_plain` | every L = 1..128, one plain call each, D = 67 |
| `ladders_plain` | all 118 trace ladders with per-row L, D = 45 |
| `allL_chunk128` / `allL_chunk96` / `allL_chunk100` | every L, chunk_d 128 / 96 / 100 with tails of 5 / 8 / 30 columns |
| `allL_perhead` | every L, per-head, 2 heads of D = 40 or 64 |
| `calls_mix` | 11 heterogeneous calls back to back: plain, chunked with rungs, per-head, protected split, a 1-column call and a 1-block call |
| `extreme_mix` | all-128 with both product signs, all-1, all-127, all-64, zeros with random signs, and 0/1/127/128 magnitudes at boundary L |
| `range_2048` | one 2048-column slice, \|acc\| = 262,144 |

Calls always run back to back without reset. The DUT derives its phase from `slice_start` and the drain arm;
`phase.mem` is only compared against it. In every golden case each slice start follows a drain (or reset),
which is why the drain arm makes the sequencer's phase-reset mistakes harmless there.

Negative controls (`[fail]` runs; drain mismatches, matching prediction):

| control | how | build | example |
|---|---|---|---|
| phase not reset at a call start | bench withholds `slice_start` on call starts | `DRAIN_PHASE_RESET = 0` | calls_prot 60/384, calls_av257 62/128, allL_plain 6,596/8,192 |
| phase reset at call starts only | `slice_start` only on call starts | `DRAIN_PHASE_RESET = 0` | chunked_96 58/192, allL_chunk96 7,463/24,576 |
| phase never reset | `slice_start` only on block 0 | `DRAIN_PHASE_RESET = 0` | calls_prot 117/384, chunked_100 108/192 |
| one cycle short | ceil(max L/16) - 1 cycles | default, also `+NO_PEEK` and GL_SIM-shaped | plain_u97 60/64, calls_mix 718/1,408 |
| wrong mask lane bits | `FAULT=1` (k instead of bitrev3(k)) | hooks | plain_u128 58/64 |
| W index = t (no gating) | `FAULT=2` | hooks | plain_u97 64/64 |
| ignoring L_row | `FAULT=3` (no gate) | hooks | plain_ladder 56/64 (blind at L = 128, as predicted) |
| phase register never reset after the global reset | `FAULT=4` (ignores `slice_start` and the drain arm) | hooks | plain_u128 55/64 |
| W index not cleared per block | `FAULT=5` | hooks | plain_u128 59/64 |
| PE mask phase one cycle early | `FAULT=6` | hooks | plain_u128 60/64, allL_plain 6,940/8,192 |

On the default build the first three controls give 0/0/0 (drain, block, phase) on calls_prot, calls_av257,
calls_mix (also with STALL and JUNK), allL_plain, ladders_plain, chunked_100, allL_chunk96, allL_chunk100 and
allL_perhead: the `[blind]` runs `drblind_*`.

`FAULT` exists only for these mutations. The hooks compile in only with `+define+CBSG_RG_FAULT_HOOKS`
(verification builds); without it every module uses `F = 0`, so synthesis ignores any `FAULT` override (the
elaboration check above) and a simulation with `FAULT != 0` stops at time 0.

## Power bench

The bench (`power_payn_array_cbsg_rg.sv`) matches `power_payn_array.sv`:
- negedge launch (the targets' INPUT_DELAY = 1.25 ns), with `mac_en` rising right after the posedge before
  the first accumulating edge;
- uniform random |q| = 0..127 mapped to b, random signs, fresh every block;
- every load except block 0's inside the SAIF window;
- the drain outside it.

The drain raises `shift_in` at the negedge, as the target's SDC assumes for every input (and as
`power_payn_array.sv` actually does, despite its "align to a posedge" comment, which refers to an SDC with
`set_input_delay 0.05`). It reads `acc_out_east` 0.05 ns (the OUTPUT_DELAY) before each shift edge, the
latest point at which STA guarantees the output has settled, instead of at the negedge.

Workloads:

| workload | how to select it | L | cycles per block |
|---|---|---|---|
| uniform (headline, matches the baseline bench) | default | 128 | 8 |
| ladder_rowmix: rung-table **worst case**, per-row L mixed inside a tile | `CBSG_WL_LADDER` | drawn from [128, 96, 64, 48, 44, 42, 38] independently per (row, 128-column chunk) | ceil(max L/16); 272/384 blocks run 8 |
| ladder_rowgrouped: rows of one rung share the tile (scmp_llm row-split dispatch) | `CBSG_WL_LADDER_GROUPED` | one ladder L per chunk for all 8 rows | ceil(L/16) |

`slice_start` marks every chunk. The tiles are not drained between chunks, so the one drain holds the sum of
the per-chunk partials; the checker sums the kernel's per-chunk partials to match. (A deployed sequencer
drains every chunk.) Energy per MAC is `P * window_clocks * 2.5 ns / (blocks * 512)`. The trace records
`window_clocks`. Quote ladder energy from ladder_rowgrouped, not ladder_rowmix.

## Synthesis (2026-10-05, run `cbsg_rg_20261005`)

`syn/build/TSMC22/PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005/` (target knobs identical to PAYN_SC_CSA; zero wire
load). Paths from `bash sweeps/cbsg/rg/report_rg_paths.sh` (report:
`build/cbsg/rg/syn_paths/PAYN_SC_CSA_CBSG_RG_cbsg_rg_20261005/rg_paths.rpt`); the baseline column is the same
probe on `PAYN_SC_CSA/csa_20261003_bp_baseline`.

| | RG | CSA baseline |
|---|---|---|
| total cell area | **88,196 um2** (2.03x) | 43,455 um2 |
| 64 CSA tiles | 25,609 | 26,198 |
| `u_array_core` outside the tiles (pipes, 64 W index generators, 8,192 W comparators) | 59,360 | 3,055 |
| `u_peripheral` (operand registers, A comparators) | 3,177 | 12,793 |
| Sobol banks | 29 | 1,406 |
| GMAC/s/mm2 at 400 MHz, single PE, synthesis basis | **290** (0.49x) | 589 |
| worst setup slack at 2.5 ns | **+0.05 ns**: `first_pipe` (j clear) -> prefix -> Gray -> XOR map -> compare -> tile -> `pending_carry` | +0.93 ns (reset port) |
| `a_bits_pipe` -> tile `acc_low` | +0.21 ns | +1.52 ns |
| `j` -> tile `acc_low` | +0.21 ns | - |
| `w_bits_pipe` -> tile `acc_low` | +1.18 ns | +1.52 ns |
| power report (synthesis default activity, not a SAIF number) | 1.055 mW | 0.835 mW |

The area matches `doc/cbsg_port_plan.md`'s 80,000-94,000 um2 estimate for this structure. The generator
adds about 1.3 ns in front of the tile path.

## Reproduce

```bash
bash sweeps/cbsg/rg/run_rtl_checks.sh                       # all four parts
PARTS="tb" bash sweeps/cbsg/rg/run_rtl_checks.sh            # playback only (needs golden_extra)
# one case by hand:
make sim TOP=Top TB=designs/payn/tb/test_payn_array_cbsg_rg.sv BUILD_DIR=$PWD/build/cbsg/rg/build/base USE_DW=1 \
  GL= TARGET= RTL_PREFLIGHT_CMD= NTFY_CHNL= \
  'VCS=vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait 60 $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
build/cbsg/rg/build/base/designs/payn/tb/test_payn_array_cbsg_rg.sv/simv +vcs+lic+wait +CASE=$PWD/build/cbsg/golden/calls_prot
# synthesis (needs an AFS token for the TSMC22 kit) and the path probe:
RUN_NAME=cbsg_rg_20261005 make synth TARGET=TSMC22/PAYN_SC_CSA_CBSG_RG NTFY_CHNL=
bash sweeps/cbsg/rg/report_rg_paths.sh cbsg_rg_20261005
# gate level (not run yet): the functional bench compiles drain-only under the flow's GL_SIM define; make runs
# the compile-only simv, then play a case with the built simv (+CASE=..., plus +sdf=<run>/<top>.syn.sdf for SDF)
make sim GL=syn TARGET=TSMC22/PAYN_SC_CSA_CBSG_RG RUN=cbsg_rg_20261005 TOP=Top \
  TB=designs/payn/tb/test_payn_array_cbsg_rg.sv BUILD_DIR=$PWD/build/cbsg/rg/gl NTFY_CHNL=
```

Targets `syn/targets/TSMC22/PAYN_SC_CSA_CBSG_RG` and `apr/targets/TSMC22/PAYN_SC_CSA_CBSG_RG` are copies of
the PAYN_SC_CSA ones with only TOP, SRC_SV and TARGET changed.

## Open items

- **Post-route timing.** Synthesis meets 2.5 ns by only +0.05 ns with zero wire load, against +0.93 ns for
  the baseline. Each row now broadcasts 8 lanes x 16 positions x 7 threshold bits to its 8 tiles (about
  8.7k broadcast nets against 2.0k), and `apr/scripts/place_guides_sc_distribution.tcl` guides only
  `a_bits_pipe_reg_*` and `w_bits_pipe_reg_*`, not the 64 generators, so the route will likely lose this
  margin. Not routed yet. If it fails, the fallback is the review's: compute the per-(h, k) W index generator
  in the generation stage from the edge's a_bits and register `w_thr` into the PE pipe (+7,168 flops, about
  +10k um2 at the measured 1.46 um2 per flop, less any upsizing DC no longer needs). The MAC stays at E+2, so
  the contract, benches and goldens do not change. A cheaper first step is to replicate `first_pipe` per row
  (about 0.2 ns of the worst path is `first_pipe`'s fan-out buffers and delay cells before the j-clear AND).
- **Area.** 2.03x the baseline, so GMAC/s/mm2 is about halved at iso-T. In a grid the cost multiplies by
  every PE, not by the edges.
- **Gate level.** Not run. The functional bench compiles under `GL_SIM` (drain-only, no parameter
  overrides); the GL_SIM-shaped RTL build passes. In the power bench `mac_en` still rises right after a
  posedge, copied from `power_payn_array.sv`; that is 1.25 ns earlier than the SDC's input delay, harmless
  for the accumulators (the slot it could capture is all zero) but a possible hold notifier at gate level.
