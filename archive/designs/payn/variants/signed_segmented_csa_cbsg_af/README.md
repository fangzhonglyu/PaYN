# Carry-save array with C-BSG streams, A-first (`signed_segmented_csa_cbsg_af`)

The [`signed_segmented_csa`](../signed_segmented_csa/README.md) SC array with its edge replaced so that it
computes the scmp_kernels C-BSG multiplication **bit-exactly**: every drained accumulator equals the
kernel's integer `acc` before the float scale. The reference and the hardware contract are in
[`sweeps/cbsg/README.md`](../../../../sweeps/cbsg/README.md). This is design **AF** (A-first) from there.

The PE core is unchanged and is included from `../signed_segmented_csa`, not copied:
- `InnerPESignedSegmentedCsaFlat` as `u_pe/u_array_core`;
- the `InnerTileSignedSegmentedCsa` tiles;
- `a_bits_pipe` / `w_bits_pipe`, so the APR distribution guides still match;
- the west-to-east drain chain.

Status (2026-10-05): RTL verified (every check below passes, including after the review fixes, see
[Review fixes](#review-fixes-2026-10-05)) and synthesized: DC run `cbsg_af_20261005` is **39,926.0 um2, 8.1% below
the CSA baseline** (43,455.0), WNS +0.97 ns at 400 MHz, and the netlist passes the bit-exact bench at unit delay and
with the synthesis SDF (see [Synthesis](#synthesis-2026-10-05)). No APR or headline power yet.

## Arithmetic

One PE is 8 A rows x 8 W columns. A block is 8 consecutive reduction columns of a slice, with column
`d = 8p + k` in lane k. It runs `C = ceil(max_h L_h / 16)` cycles of 16 positions, with sample index
`t = 16c + m`. Each slice is a plain call's whole D, one chunk or one head.

| side | per element | hardware |
|---|---|---|
| A | `a_bit = t < kA`, `kA = ka_closed(b, L_h, mask)` = `#{t < L_h : rA(t) < b}` | one closed-form encoder per element (64 per PE) and a thermometer. No A Sobol bank and no A comparators |
| W | `w_bit = b_w > ((x_k(t) ^ mask) >> 1)` | one sample-ordered "k"-seed Sobol stream (16 registered lane words, shared by all rows) and the CSA-style comparators |
| mask | `bitrev8(d mod 64)` = `{bitrev3(k), bitrev3(p), 2'b00}` | lane bits wired; p from a 3-bit phase register that restarts at 0 on the first block after every drain and after reset (or on `slice_start`) |

Why this equals the kernel. The kernel counts `#{i < kA : bW > rB(i)}`. AF puts the kA A ones at
t = 0..kA-1 and ANDs them with W sample t. The CSA tile then accumulates
`sum_k sign * popcount_m(A & W)` every cycle. Because kA <= L, no length gate is needed.

**Encoder.** It is a direct port of `cbsg_ref.ka_closed`. Each set bit j of L is an aligned dyadic block of
2^j samples. Such a block adds `(b >> s) + [(b mod 2^s) > c_j]`, with s = 7-j and
`c_j = ((bitrev8(gray(s0)) ^ mask) mod 2^(8-j)) >> 1`. So the encoder is one s-bit compare per bit of L and
an adder of at most eight terms.

**Thermometer.** For each element, one 4-bit compare of `cyc` against `kA[7:4]` is shared by its 16
positions. Each position then adds a constant decode of `kA[3:0]`.

## Hardware (vs `signed_segmented_csa`)

| block | file | what |
|---|---|---|
| stream generator `u_rng` | `cbsg_af_stream_gen.sv` (`CbsgAfStreamGen`) | Replaces both `sobol_bank`s:<br>- a 4-bit block cycle counter: 0..7, then IDLE = 8, where A is 0;<br>- the 3-bit phase register;<br>- the slice restart: `slice_pending_q`, set by reset and by a `shift_in` edge and cleared by `block_start`, and `block_start_q`, so that the drain's tail on B+1 is ignored;<br>- 16 x 7-bit registered W lane words `(H(c) ^ LANE(m) ^ phase bits) >> 1`.<br>The phase is folded into the words on the `block_start` edge from the phase being loaded, so cycle 0 already carries the new mask |
| edge peripheral `u_peripheral` | `cbsg_af_peripheral.sv` (`CbsgAfPeripheral`, `CbsgAfKaEncoder`) | Replaces `sc_pe_peripheral` and keeps its output packing:<br>- A magnitude, sign and per-row L registers (`load_a`);<br>- W magnitude and sign registers (`load_w`), with asynchronous reset as before;<br>- 64 kA encoders (`ka_flat`) and the thermometer;<br>- 1,024 W comparators against `w_words[m] ^ {bitrev3(k), 0000}` |
| top | `payn_array_signed_segmented_csa_cbsg_af.sv` | CSA ports plus `a_len_in[N_H*8]`, `block_start` and `slice_start`. The sequencer contract is in the header. The `[CBSG-AF-CONTRACT]` simulation checks count into `contract_errors` |

Registers at the edge:

| | flops |
|---|---:|
| CSA edge (two Sobol banks) | 512 |
| AF stream generator (counter, phase, slice restart, words) | 4 + 3 + 2 + 112 |
| AF per-row L | 64 |

The magnitude and sign registers are the same as in the CSA edge.

DC preflight (`sweeps/cbsg/af/run_dc_elab.sh`) elaborates the top with the target's defines: 0 latches and
5,179 elaborated registers (5,177 before the two slice-restart flops). One `CbsgAfKaEncoder` compiled on its own came to 102.4 um2 (220 cells) and
0.64 ns. That compile was combinational, under a relaxed 2.5 ns max-delay constraint, not a synthesis of the
top. 64 encoders are roughly 6.6k um2 per PE before any sharing. Synthesis must decide whether this beats
the A comparators it removes (1,024 8-bit comparators in the CSA edge).

## Sequencer contract (summary; full text in the top header)

- **Block start, edge B.** Assert `block_start` together with `load_a`, `load_w`, `load_a_sign` and
  `load_w_sign`. On this edge:
  - the operands and the per-row L are captured;
  - the streams restart;
  - the phase register loads 0 on the first block of a slice, otherwise `p+1`.

  Loads go on `block_start` edges only, and each magnitude load comes with its sign load. An operand that
  does not change may skip its load pair, for example A reused after a drain.
- **Timing.**
  - Cycle c is accumulated at B+c+2, so the block's MAC edges are B+2..B+C+1.
  - Back-to-back blocks load at B+C, with no bubble.
  - C may exceed `ceil(max L/16)`: the extra cycles add exactly zero.
- **`rng_en`** must be high on B+1..B+C. A stall is `rng_en` low at edge E together with `mac_en` low at E+2.
  `rng_en` low at E repeats the presented cycle, so the MACs at E+1 and E+2 both see it.
- **`mac_en`** must be high on every MAC edge except the second copy of a stalled cycle. It may stay high for
  the whole run, because idle edges accumulate a zero A stream.
- **Phase restart.** The phase must be 0 on the first block of every slice: every chunk, every head and
  **every call**. Calls run back to back without a reset.
  - The restart is structural, because every slice ends with a drain. The phase loads 0 on the first
    `block_start` after reset, and on the first `block_start` after a drain. A drain counts when a `shift_in`
    edge lies in Bprev+2..B; the tail of the drain on B+1 is ignored.
  - For N_W >= 2, every legal drain has a shift edge in that window.
  - `slice_start` on a `block_start` edge also forces phase 0. It is optional. It is needed only where the
    drain cannot be seen by B: an N_W = 1 drain on the tightest schedule.
  - Asserting `slice_start` on a block that does not follow a drain is a contract error.
- **Drain** after the last block of each slice:
  - `shift_in` is high for N_W edges with `acc_in_west = 0`, starting at B+C+2 or later;
  - before the s-th shift edge, `acc_out_east` holds column N_W-1-s;
  - the drain also clears the accumulators;
  - the next slice may load on the drain's second-to-last shift edge.
- **Range.** Accumulators are exact to 65,535 columns per slice at OWIDTH = 24.

The `[CBSG-AF-CONTRACT]` simulation monitor in the top checks these points:
- **Operands:** the ranges of b and L; a load without `block_start`; a magnitude load without its sign load.
- **Blocks:** a block cut short of `ceil(max L/16)` cycles.
- **Slices:** the phase each slice's first block actually loads; `slice_start` without a drain.
- **MAC accounting:** every presented cycle whose sample holds A ones must be accumulated exactly once. It
  is an error if a sample is dropped by `shift_in` or by `mac_en` low, or if a stall without the `mac_en`
  kill counts it twice.

## Verification (RTL, 2026-10-05)

`bash sweeps/cbsg/af/run_rtl_checks.sh` gives **PASS**. Summary: `build/cbsg/af/rtl_checks_summary.log`.

| part | what | result |
|---|---|---|
| ref | `cbsg_ref.py --check-golden` on the 12 shipped cases | 12/12 |
| ref | `sweeps/cbsg/af/emit_af_cases.py`: 24 extra cases, 7,110 blocks. Each is gated by kernel == RG == AF and re-derived from its .mem files | 24/24 |
| ref | `sweeps/cbsg/af/review/emit_review_cases.py`: 7 review cases, 657 blocks (`build/cbsg/af/golden_rv`), same gate | 7/7 |
| units | `sweeps/cbsg/af/tb_cbsg_af_units.sv`: kA encoder against brute force, every lane x phase x L 1..128 x b 0..128 | 1,056,768 / 0 wrong |
| units | stream generator against the brute-force "k" Sobol: every cycle and phase, phase sequencing, IDLE park, freeze, restart, async reset, and the slice restart (after reset, after a drain, block on S7 with the S8 tail ignored, a shift on B, a shift on Bprev+2) | 3,013 / 0 wrong |
| func | `designs/payn/tb/test_payn_array_cbsg_af.sv`, 89 runs on one compile | 61 passing runs, 28 negative controls caught |
| power | `designs/payn/power/power_payn_array_cbsg_af.sv`, uniform and ladder workloads, 256 blocks each | drain bit-exact (kernel == AF model == RTL), contract 0 |

The 61 passing runs compared these values bit-exactly:

| compared | values |
|---|---:|
| blocks | 138,342 |
| drained accumulators | 960,960 |
| per-block accumulators (read hierarchically) | 8,853,888 |
| kA outputs | 8,853,888 |

Phase-register checks against `phase.mem` also match. The DUT derives the phase itself and never reads
that file.

**What the functional bench runs:**
- **Every case alone** (43 cases), on the tightest legal schedule:
  - back-to-back blocks;
  - the drain one edge after the last MAC;
  - the next slice loading on the second-to-last shift edge.
- **All 43 cases chained in one simulation without a reset.** That is 522 calls, 8,135 blocks and 883 drains,
  run in 16 variants:
  - plain;
  - all 8 cycles per block;
  - random gaps with `rng_en` toggling outside blocks, two seeds;
  - exact `mac_en`;
  - loose drains;
  - those combined;
  - legal stalls (`+STALL`, about 8,100 per run), alone and with gaps and exact `mac_en`;
  - `rng_en` low on each block's last advance edge (`+RNG_LOW_END`), with exact `mac_en` and on the tightest
    schedule;
  - junk operand and L buses on every non-load edge;
  - a DUT reset between cases;
  - `slice_start` never driven (`+NO_SLICE_START`): the drains alone restart the phase;
  - the drain-derived restart forced off (`+KILL_DRAIN_RESET`): `slice_start` alone restarts it;
  - each of those two combined with stalls, junk buses, gaps and loose drains (and, for `+NO_SLICE_START`, a
    reset between cases, exact `mac_en` and all 8 cycles).

**Extra cases** (`build/cbsg/af/golden_extra`):
- every uniform L from 1 to 128, one plain call per L;
- all 118 trace ladders, as plain per-row-L calls and as chunk_d-128 rung tables with tails;
- chunk_d 128 / 96 / 100 with tails 0..81;
- rung tables at chunk_d 96 and 100;
- per-head calls, including unaligned 72-column heads;
- a mixed call sequence: protected-first split, plain 257, rungs, per-head, gathered 21, chunk_d 96;
- the deployed odd block counts: 721, 584, 3973, 257 and 77;
- D = 2048;
- all b = 128 at D = 2048, giving accumulators of +-262,144;
- magnitudes only 0/1/63/64/65/127/128;
- negative zeros (b = 0 with the sign bit set).

**Review cases** (`build/cbsg/af/golden_rv`):
- chunk_d 8, so every block is drained;
- chunk_d 16;
- unaligned chunk_d 24 / 40 / 56 / 72 / 136;
- one-cycle blocks;
- plain D = 1000 with random per-row L;
- 60 back-to-back calls of 1..20 columns;
- long mixed protected splits.

**Negative controls.** Each must FAIL with the listed tags:
- CHECK: drain mismatch;
- BLOCK: per-block accumulator mismatch;
- KA: encoder output mismatch;
- PHASE: phase register mismatch;
- CONTRACT: `[CBSG-AF-CONTRACT]`.

The phase controls use `+KILL_DRAIN_RESET`, which models an edge where only `slice_start` restarts the phase.
Without it, withholding `slice_start` is harmless, and the chains above show that.

| control | case | drains wrong | tags |
|---|---|---:|---|
| restart missing at call starts | calls_av257 | 62 / 128 | CHECK BLOCK KA PHASE CONTRACT |
| | calls_prot | 60 / 384 | same |
| | af_calls_mixed | 410 / 896 | same |
| | af_uL_001_032 | 1484 / 2048 | same |
| | rv_tiny_calls (60 calls) | 2437 / 3840 | same |
| | 12 golden cases chained | 651 / 1792 | same |
| restart missing everywhere after the first block | 12 golden cases chained | 1505 / 1792 | same |
| restart missing at chunk / head starts | chunked_96 | 58 / 192 | CHECK BLOCK KA PHASE CONTRACT |
| | chunked_100 | 108 / 192 | CHECK BLOCK PHASE CONTRACT |
| | af_perhead | 162 / 640 | CHECK BLOCK KA PHASE CONTRACT |
| | rv_cd8 | 1392 / 1984 | CHECK BLOCK KA PHASE CONTRACT |
| stalls without the `mac_en` kill | plain_u97 + calls_prot | 381 / 448 | CHECK BLOCK CONTRACT |
| `rng_en` low on B+C with gaps and `mac_en` high | 12 golden cases chained | 827 / 1792 | CHECK BLOCK CONTRACT |
| stray A or W load pair, legal values, on 1/16 of the non-block edges | 12 golden cases chained | 1489 / 1792 | CHECK BLOCK CONTRACT |
| random `slice_start` on non-block edges (no effect) | 12 golden cases chained | 0 / 1792 | CONTRACT only |
| wrong mask lane bits (column k into lane 7-k) | plain_u97 / plain_u128 / af_ladders_0 | 61/64, 62/64, 1729/1920 | CHECK BLOCK KA |
| kA = min(b, L): no encoder (forced `ka_flat`) | plain_ladder / af_uL_033_064 | 56/64, 2031/2048 | CHECK BLOCK KA |
| | plain_u128 (control: identical at L = 128) | 0 / 64 | passes, as it must |
| per-row L ignored: every row gets the block max | plain_ladder / chunked_rung | 56/64, 167/192 | CHECK BLOCK KA |
| L ignored: L = 128 for every row, so kA = b | plain_u97 / af_uL_001_032 | 64/64, 2042/2048 | CHECK BLOCK KA |
| block one cycle short | plain_u97 / af_uL_065_096 | 54/64, 1856/2048 | CHECK BLOCK CONTRACT |
| drain one edge early | chunked_rung | 24 / 192 | CHECK BLOCK CONTRACT |
| next slice one edge early | chunked_rung | 127 / 192 | CHECK BLOCK KA PHASE CONTRACT |

In the last row, the next slice loads on S6, so S8 falls on B+2 and also restarts the second block's phase.
That gives one more wrong drain than before the fix (126). The schedule is illegal either way.

**Cross-check with the reference's fault model.** Three RTL controls land on exactly the reference's
predicted counts:

| RTL control | case | RTL drains wrong | reference fault | predicted |
|---|---|---:|---|---:|
| restart missing at call starts | calls_av257 | 62 | `no_phase_reset` | 62 |
| restart missing per chunk | chunked_96 | 58 | `no_slice_reset` | 58 |
| restart missing per chunk | chunked_100 | 108 | `no_slice_reset` | 108 |

In calls_av257 every call is one slice, so a missing restart there is a free-running phase.

**chunk_d 128 is a no-op, not a blind spot.** The reference README describes this shape as a blind spot: a
missing per-chunk restart does not show in the data. A 16-block chunk wraps the phase to 0 by itself, so
nothing goes wrong, and the run `slice_phase_rung128_noop` passes with the phase checks matching. The old
monitor flagged the missing `slice_start` there. The new one checks the phase each slice actually loads, and
correctly stays silent.

**Mutation test** (`sweeps/cbsg/af/review/run_mutants.sh`, summary
`build/cbsg/af/review/mutants_summary.log`):
- 20 single-bug copies of the RTL were each run with the unmodified bench, on all 43 cases chained.
- Three runs per mutant: plain, `+NO_SLICE_START` and `+KILL_DRAIN_RESET`.
- All 20 are killed:
  - 13 in the encoder, thermometer, W comparators, word generator and IDLE park;
  - 7 in the phase restart: no restart, `slice_start` ignored, drain path removed, the B+1 tail counted,
    pending not set on reset, set beating clear, pending unused.

**Power bench.**
- Operand activity matches `power_payn_array.sv`:
  - |q| uniform in 0..127 with random signs, mapped to `b = round(|q|*128/127)`;
  - new operands every block, with the loads inside the SAIF window;
  - the drain after `$toggle_stop`.
- One plain call of 256 blocks, two workloads:

| workload | define | window edges | mean kA | A-one density |
|---|---|---:|---:|---:|
| uniform L = 128 | default | 2,048 (8 cycles/block) | 64.2 | 0.50 |
| ladder: per-(row, 128-column chunk) L drawn uniformly from `[128, 96, 64, 48, 44, 42, 38]` | `CBSG_PWR_LADDER` | 1,952 (7.62 cycles/block) | 34.6 | 0.28 |

- The ladder chunks are not drained separately, because the drain stays outside the window. The checker
  therefore compares the sum of the per-chunk partials, which is exact: 16-block chunks start at phase 0.
- `sweeps/cbsg/af/check_power_trace.py` recomputes the drain with both the kernel and the AF model.

## Review fixes (2026-10-05)

The three minor review findings were all valid. All three are fixed.

1. **Contract monitor gaps.**
   - The old monitor did not check the stall rule, and did not flag loads without `block_start`.
   - It now checks MAC accounting exactly: a cycle with A ones must be accumulated once, never zero or two
     times.
   - It also flags a load without `block_start`, and a magnitude load without its sign load.
   - The bench gained these modes, folded in from the review bench: `+STALL`, `+NEG_STALL_NOMAC`,
     `+RNG_LOW_END`, `+JUNK_BUS`, `+JUNK_SS` and `+MID_RESET`. It also gained `+NEG_STRAY_LOAD`.
2. **Phase restart depended on `slice_start`.**
   - The restart is now structural: `slice_pending_q` and `block_start_q` in `CbsgAfStreamGen`, two flops.
     A drain or a reset arms the restart, so the next block runs at phase 0.
   - `slice_start` stays as an optional explicit restart.
   - Reset now arms the restart too, so the first block after reset runs at phase 0 without `slice_start`.
   - The old phase controls now also need `+KILL_DRAIN_RESET`.
3. **Shift check ignored `mac_en`.**
   - The check now uses the MAC accounting from item 1.
   - It no longer flags a shift that falls on a non-MAC edge or on the second copy of a stalled cycle.
   - As a result, `RNG_LOW_END` with exact `mac_en`, or on the tightest schedule, now passes with 0 contract
     errors.

## Synthesis (2026-10-05)

`RUN_NAME=cbsg_af_20261005 RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF NTFY_CHNL=`
(knobs identical to PAYN_SC_CSA). Log clean: no errors, no latches (21 inferred register groups, all flip-flops,
5,179 bits as in the preflight), no unresolved references; check_design lists only unloaded/undriven elaboration
leftovers (58 undriven operator cells, 56 of them unused bits inside the encoders).

**Area** (`bash sweeps/cbsg/af/run_syn_reports.sh` -> `build/cbsg/af/syn/area_breakdown.txt`; DC cell area, um2).
`u_peripheral` is flat in both netlists apart from the encoders, so its leaf cells are classed by name and by
fan-in cone (`sweeps/cbsg/af/dc_af_probe.tcl`, `sweeps/cbsg/af/area_breakdown.py`):

| block | CSA `csa_20261002` | AF `cbsg_af_20261005` | AF - CSA |
|---|---:|---:|---:|
| **total** | 43,455.0 | **39,926.0** | **-3,529.0 (-8.1%)** |
| PE core `u_pe` | 29,253.0 | 29,252.6 | -0.4 |
| &nbsp;&nbsp;64 tiles | 26,198.3 | 26,197.9 | -0.4 |
| &nbsp;&nbsp;bit/sign pipes + PE glue | 3,054.7 | 3,054.7 | 0 |
| A edge | 7,094.8 | 8,442.5 | +1,347.7 |
| &nbsp;&nbsp;A registers (mag + sign, AF + row L) | 933.0 | 1,036.3 | +103.4 |
| &nbsp;&nbsp;A Sobol bank `u_a_rng` | 698.2 | - | |
| &nbsp;&nbsp;1,024 A comparators | 5,463.7 | - | |
| &nbsp;&nbsp;64 kA encoders | - | 6,584.2 | |
| &nbsp;&nbsp;encoder input buffering | - | 34.5 | |
| &nbsp;&nbsp;64 thermometer decoders | - | 787.4 | |
| W edge | 6,384.7 | 2,162.9 | -4,221.8 |
| &nbsp;&nbsp;W registers | 932.9 | 932.9 | 0 |
| &nbsp;&nbsp;1,024 W comparators | 5,451.8 | 1,230.0 | -4,221.8 |
| W bank (`u_w_rng` / `u_rng`) | 707.9 | 55.0 | -652.9 |
| other (reset buffers, top cells) | 14.6 | 13.0 | -1.6 |

- `u_peripheral` 12,792.9 -> 10,617.8; both Sobol banks 1,406.1 -> `u_rng` 55.0.
- **kA encoder**: 102.9 um2 each (101.7..103.7), as in the standalone compile; the 64 encoders (6,584) cost more
  than the A comparators plus A bank they replace (6,162). The A edge is the only block that grows.
- **Thermometer**: 12.3 um2 per element (16 positions).
- **The W edge is where AF wins.** The lane words are `(H(c) ^ LANE(m) ^ mask) >> 1`: the 16 positions of a cycle
  differ only by compile-time constants. DC removes 16 of the 112 word flops as constant and merges 88 more
  (`OPT-1206` / `OPT-1215` in `synth.log`), leaving 8, and the 16 comparators per W element share their logic:
  1.20 um2 per comparator against 5.32 in the CSA edge. The GL runs below confirm that this is exact.

**DC timing** (tt 0.80 V 25 C, the only library; `build/cbsg/af/syn/timing_summary.txt`, probe report
`build/cbsg/af/syn/PAYN_SC_CSA_CBSG_AF_cbsg_af_20261005/probe.rpt`):
- WNS **+0.97 ns** (CSA +0.93): `reset` port -> tile `acc_low` (1.25 ns input delay), not new logic.
- Worst register-to-register path: `u_rng/phase_q` -> kA encoder (row 3, lane 4) -> thermometer -> `a_bits_pipe`,
  0.98 ns, **slack 1.49 ns**. The CSA's worst (`a_bits_pipe` -> tile `pending_carry`, 0.96 ns, slack 1.51) is
  essentially tied. The top ten register endpoints are all A bit-pipe bits at 0.96-0.98 ns.
- From `a_len_q` 0.94 ns, from `a_binary_q` 0.87 ns, from the cycle counter 0.37 ns. W words or magnitudes -> W bit
  pipe 0.39 / 0.21 ns.
- Control ports (`block_start`, `slice_start`, `shift_in`, `rng_en`) -> `u_rng` words: 1.35-1.38 ns arrival,
  including the 1.25 ns input delay, slack about 1.1 ns.
- Nothing is near-critical at 2.5 ns. The encoder path is about 40 cells deep (ripple adders chosen for area),
  so it is the path to watch at a slower corner.

**Post-synthesis GL** (`bash sweeps/cbsg/af/run_syn_gl_checks.sh`, summary
`build/cbsg/af/gl/cbsg_af_20261005/syn_gl_checks_summary.log`). Every run plays the same cases and plusargs on a
fresh RTL compile of the bench, and the GL RESULT line must equal the RTL one (calls, blocks, drains, edges,
drains wrong, stalls). Under `GL_SIM` the bench compares drains only.

| mode | runs | content |
|---|---|---|
| unit delay, `ARM_UD_MODEL` + `ARM_EN_X_SQUASH`, no timing checks | 26/26 PASS | 23 passing runs, including all 43 cases chained (522 calls, 8,135 blocks, 56,512 drains) without `slice_start`, and the same with stalls (8,113), junk buses, DUT resets, gaps, exact `mac_en`, loose drains and all 8 cycles; 3 negative controls fail with exactly the RTL counts (54/64, 127/192, 381/448) |
| synthesis SDF, ideal-clock view, max corner, `+neg_tchk`, timing checks on | 10/10 PASS | plain, per-row L, chunk rungs, call sequences (av257, mixed, 60 tiny calls), the 12 golden cases chained with stalls/junk/gaps, all 43 cases chained; 2 negative controls; 0 timing violations, SDF errors 0 |
| power bench smoke, same SDF view, 32 blocks, uniform and ladder | 2/2 PASS | drain bit-exact (kernel == AF model == GL), trace identical to RTL, SAIF validator PASS (acc TX 0), PT on the synthesized netlist annotates every net from the SAIF or the pinless policy |

Two pre-layout artifacts had to be handled for the SDF runs (`bash sweeps/cbsg/af/gl_sdf_ladder.sh` ->
`build/cbsg/af/gl/cbsg_af_20261005/ladder/ladder_summary.log`):
- **Gated clocks.** The raw synthesis SDF gives three unbuffered shared ICGs CK->ECK delays longer than the period
  (`clk_gate_a_signs_q_reg_0_` 3.82 ns, `clk_gate_w_binary_q_reg_0_` 3.36, `clk_gate_acc_low_reg_0_` 3.28; the
  CSA baseline SDF has the same three at 3.36/3.36/3.28). No gated pulse survives and the drains are X. The
  ideal-clock view (`sweeps/cbsg/af/sdf_ideal_clock.py`) zeroes only the ICG IOPATHs, which is the clock model DC
  timed with.
- **First load after reset.** DC's reset buffer tree reaches the operand registers' async resets 1.45-1.73 ns
  after the port. A load on the first edge after reset straddles that release (278 `$recrem` violations; wrong
  drains even without timing checks). With two idle edges after reset (`+RESET_SETTLE=2`, as
  `power_payn_array.sv` and the AF power bench already do) every SDF run is clean. Sequencer note: keep at least two
  edges between reset release and the first load until the routed reset tree is timed.
- The 620 `SDFCOM_CFTC` warnings are all `DFFRPQ*` removal checks (DC writes them as HOLD, the model has `$recrem`).

Bench changes for the GL runs (RTL results unchanged: the RTL references of all 26 unit runs reproduce the RTL
suite's RESULT lines exactly): `test_payn_array_cbsg_af.sv` annotates `SDF_FILE` under `GL_SIM` and takes
`+RESET_SETTLE=n` (default `` `CBSG_RESET_SETTLE `` = 0).

## Open items

- **No route or headline power yet.** `apr/targets/TSMC22/PAYN_SC_CSA_CBSG_AF` is ready (a copy of
  PAYN_SC_CSA with only TOP, SRC_SV and TARGET changed). The GL power bench is proven on the synthesized netlist.
  The PT figures in the smoke runs (7.75 mW uniform, 6.53 mW ladder; 32 blocks, no SPEF, ideal clocks) only show
  that the flow works.
- **Encoder area.** The encoder is the AF-specific cost: 64 per PE, 102.9 um2 each after synthesis (6,584 um2,
  16.5% of the design).
  - `FLATTEN=0` keeps each encoder a separate hierarchy, so the per-row gray(L) logic is not shared across
    the 8 lanes. Ungrouping could recover it.
  - kA is constant for a block. A registered, shared encoder would also work, but only when blocks are long
    enough.
- **Timing.** The A path `a_binary_q`/`a_len_q`/`phase` -> encoder -> 4-bit compare -> `a_bits_pipe` is one
  cycle, 0.98 ns at tt in DC (slack 1.49 ns). Check it again after APR.
- **PE grid.** This is a single-PE top. On a grid with skewed operands, each PE needs `block_start` (the
  counter and words) aligned to its own operand arrival. That is not addressed here.
- **BP INT mode** is not combined with this edge.

## Reproduce

```bash
bash sweeps/cbsg/af/run_rtl_checks.sh          # ref + units + func + power -> build/cbsg/af/rtl_checks_summary.log
PARTS="func" bash sweeps/cbsg/af/run_rtl_checks.sh
bash sweeps/cbsg/af/run_dc_elab.sh             # DC elaborate/check_design + standalone encoder compile
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/af/emit_af_cases.py --out build/cbsg/af/golden_extra
# one case by hand, after a run (simv in build/cbsg/af/func_build/...):
#   simv +CASES=$PWD/build/cbsg/golden/calls_prot[,...] [+GAPS +RNG_GAP_LOW +MAC_EXACT +LOOSE_DRAIN +FULL_CYCLES
#        +STALL +RNG_LOW_END +JUNK_BUS +MID_RESET +NO_SLICE_START +KILL_DRAIN_RESET ... +NEG_...]
bash sweeps/cbsg/af/review/run_mutants.sh      # 20 RTL mutants x 3 runs (after run_rtl_checks.sh ref)
RUN_NAME=<name> RTL_PREFLIGHT_CMD="bash sweeps/cbsg/af/run_rtl_checks.sh" make synth TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF NTFY_CHNL=
RUN_NAME=cbsg_af_20261005 RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF NTFY_CHNL=
bash sweeps/cbsg/af/run_syn_reports.sh        # area classes + timing probes, AF vs CSA -> build/cbsg/af/syn/
bash sweeps/cbsg/af/run_syn_gl_checks.sh      # unit / ideal-clock SDF / power smoke -> build/cbsg/af/gl/cbsg_af_20261005/
bash sweeps/cbsg/af/gl_sdf_ladder.sh          # delay-mode ladder on plain_u128 (diagnosis)
bash sweeps/cbsg/af/gl_divergence.sh          # edge-by-edge zero-delay vs ideal-SDF probe diff (diagnosis)
```
