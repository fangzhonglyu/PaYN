# C-BSG A-first array with bit-plane INT mode and in-place doubling (`signed_segmented_csa_cbsg_af_ipd`)

One top, `payn_array_signed_segmented_csa_cbsg_af_ipd`, with two modes:

- **SC mode** is the [`signed_segmented_csa_cbsg_af`](../signed_segmented_csa_cbsg_af/README.md) design (AF, A-first C-BSG),
  edge for edge. It is bit-exact with the scmp_kernels C-BSG integer accumulator for any per-row L, with the same
  slice and phase rules.
- **INT mode** is the bit-plane (BP) INT contract of [`signed_segmented_csa_bp`](../signed_segmented_csa_bp/README.md),
  with the 1-edge in-place laps of [`signed_segmented_csa_bp_ipd`](../signed_segmented_csa_bp_ipd/README.md) (IPD).
  It covers INT8, W4A8 and INT4. A block takes `BW*NB + (BW-1) + 8` edges on one PE.

The CSA tile (`InnerTileSignedSegmentedCsa`, [`signed_segmented_csa`](../signed_segmented_csa/README.md)) is included
unchanged. Every other block is a copy of an AF, BP or IPD file, with the module names suffixed `AfIpd`. The originals
are not touched.

**Status (2026-10-05): RTL verified, synthesized, routed (pinned, qualified, grid basin), SC power and INT energy
measured on the route.**
- Every part of `sweeps/cbsg/af_ipd/run_rtl_checks.sh` passes; the results are under
  [Verification](#verification-rtl-2026-10-05). The review findings of 2026-10-05 are fixed and rerun; see
  [Review fixes](#review-fixes-2026-10-05).
- Synthesis run `cbsg_af_ipd_20261005`: **44,690.6 um2**, WNS **+0.88 ns**, 5,441 registers, 0 latches. That is
  +4,764.7 um2 over AF (39,926.0) and +1,235.7 over CSA (43,455.0). Of the +4,764.7, **+1,976.1 is the 64 kA
  encoders, whose RTL is unchanged**: DC maps them to a larger adder structure once the INT bypass is present. See
  [Synthesis](#synthesis-cbsg_af_ipd_20261005-2026-10-05).
- Post-synthesis GL: 63/63 unit-delay runs and 24/24 ideal-clock SDF runs PASS (SC goldens, INT8 / W4A8 / INT4,
  SC <-> INT switching, negative controls).
- Route `cbsg_af_ipd_20261005_distguide_spp_pins_postfill` (pinned pass 2 with the AF post-fill hook from the start):
  **44,430.6 um2**, setup **+0.104** / hold **+0.142 ns**, final-qualified after the targeted repair, **grid** basin.
  SC uniform L=128 **12.067 mW, 0.4714 pJ/MAC** (AF route 11.583 mW / 0.4525, **+4.2 %**); ladder 10.553 mW
  (AF 10.084, +4.7 %). INT8 L=1024 with laps **0.3906 pJ/MAC** (BP lap route 0.4533, **-13.8 %**), INT4 0.0972
  (0.1094), W4A8 0.1945 (0.2186); peak INT8 0.3521 (0.3481, +1.1 %), INT4 0.0883 (0.0873). Routed functional GL
  32/32 PASS. See [Route and power](#route-and-power-2026-10-05).

## Hardware

| block | file | module | what |
|---|---|---|---|
| top | `payn_array_signed_segmented_csa_cbsg_af_ipd.sv` | `payn_array_signed_segmented_csa_cbsg_af_ipd` | AF ports plus the BP INT ports. Contains the AF block clock `u_rng`, the mode register `int_mode_q`/`int_mode_q2`, the MAC guard `mac_core = mac_en & (int_mode ~^ int_mode_q2)`, the ring gate `ring_in & int_mode`, and the combiner capture `int_mode & shift_in & ~ring_q`. The header holds the full sequencer contract. Simulation checks: `[BP-CONTRACT]` and a mode-aware `[CBSG-AF-CONTRACT]` |
| AF block clock | `cbsg_af_ipd_stream_gen.sv` | `CbsgAfStreamGenAfIpd` | rename-only copy of `CbsgAfStreamGen` |
| AF edge + INT bypass | `cbsg_af_ipd_peripheral.sv` | `CbsgAfPeripheralAfIpd`, `CbsgAfKaEncoderAfIpd` | copy of `CbsgAfPeripheral` plus the BP raw-bit bypass `bits = sc_bits \| (raw & int_mode_q)`, placed after the thermometer and W comparators and before the PE bit pipes. Every AF register and instance name is kept (`a_binary_q`, `a_len_q`, `ka_flat`, `g_a_row/g_a_depth/u_ka`) |
| IPD PE | `inner_pe_signed_segmented_csa_cbsg_af_ipd.sv` | `InnerPESignedSegmentedCsaBpIpdFlatAfIpd` | rename-only copy: registered `ring_q`, `core_shift = shift_in \| ring_q`, `lap = ring_q`, core `u_array_core` |
| IPD core | `inner_pe_core_signed_segmented_csa_cbsg_af_ipd.sv` | `InnerPESignedSegmentedCsaIpdAfIpd` | rename-only copy: CSA core plus the per-tile mux `acc_in = lap ? own << 1 : west`. Instance names `g_row/g_col/u_inner` and `a_bits_pipe` |
| combiner | `bp_combiner_cbsg_af_ipd.sv` | `PaynBpCombinerAfIpd` | rename-only copy of `PaynBpCombiner` |
| PE grid | `inner_pe_grid_signed_segmented_csa_cbsg_af_ipd.sv` | `InnerPESignedSegmentedCsaBpIpdGridAfIpd` | rename-only copy of the IPD grid wrapper. It is a verification wrapper and is not synthesized. It has no AF edge, INT bypass, mode register, guard or combiner, so it is not an AF-IPD grid (see Open items) |

`sweeps/cbsg/af_ipd/check_copies.sh` checks the copies against their sources:

- The five rename-only RTL copies equal their sources after `sweeps/cbsg/af_ipd/rename_af_ipd.pl`.
- The peripheral differs only by the bypass: 38 lines added, and 2 lines changed (the two stream assigns now drive
  `sc_a_bits` / `sc_w_bits`). The diff is in `build/cbsg/af_ipd/copies/cbsg_af_ipd_peripheral.diff`.

**INT-mode silence of the AF side: no gate.**

- **A side.** Zero magnitudes give kA = 0:
  - with b = 0, every encoder term `(b >> s) + [(b mod 2^s) > c_j]` is 0, for every L in 0..255, every lane and every
    phase;
  - so the thermometer `(cyc < kA[7:4]) | ((cyc == kA[7:4]) & (m < kA[3:0]))` is 0 for every cycle.
- **W side.** Zero magnitudes make every W comparator `0 > threshold` false.
- **Cost.** The INT sign loads already exist and carry those zero magnitudes, so silence costs nothing. A gate on
  `int_mode` instead would cost:
  - **A side:** about 64 AND2 on the eight per-row L buses (L = 0 gives kA = 0 for any b; checked in the unit bench),
    or 128 on the per-element `ka_hi_gt` / `ka_hi_eq` (64 elements x 2);
  - **W side:** about 512 AND2 on the W magnitudes. There is no cheaper W point: b_w = 128 beats every 7-bit threshold,
    so gating the thresholds does not silence W.
  - W needs its zero-load unless that 512 is paid, and the A zero-load rides the same INT sign loads at no cost, so an
    A-only gate would buy nothing. (An earlier version of this README said 512 AND2 per side; that overstated A.)
- **How it is checked:**
  - exhaustively in the unit bench;
  - in every INT run by `[BP-CONTRACT]`, which stops the run if an INT MAC consumes a sample in which an AF stream bit
    fired;
  - by `PARK_CYC0`. After reset the AF counter parks in IDLE, where A is 0 whatever kA is. So `PARK_CYC0` keeps the
    counter at cycle 0, where the A side is live, and zero magnitudes still pass while nonzero A magnitudes are caught.

**Registers** (DC elaboration, `sweeps/cbsg/af_ipd/run_dc_elab.sh`):

| top | registers | latches |
|---|---:|---:|
| AF-IPD | 5,441 | 0 |
| AF | 5,179 | 0 |
| IPD | 5,768 | 0 |

The AF-IPD count is the AF count plus 262: `int_mode_q`/`int_mode_q2` (2), `ring_q` (1) and the combiner (259).
`check_design` gives the same LINT counts as the AF top.

**Area expectation (pre-synthesis estimate).** Start from AF synthesis (39,926.0 um2) and add the BP deltas
(bypass +1,244, ring and glue, combiner +681; 2,067.8 in total over CSA) and the IPD delta over the BP ring (+969.6).
That gives about 42,960 um2, against 43,455.0 for CSA synthesis. **Measured: 44,690.6 um2.** The INT blocks cost
what the estimate said (the bypass even less), but DC remapped the unchanged kA encoders (+1,976.1); see
[Synthesis](#synthesis-cbsg_af_ipd_20261005-2026-10-05).

## Contract (summary; the full text is in the top header)

- **SC mode** (`int_mode = 0`). The AF contract, unchanged. The INT inputs (`a_raw_in`, `w_raw_in`, `int_prec`,
  `ring_in`) are don't-cares.
- **INT mode** (`int_mode = 1`). The IPD contract, unchanged:
  - `int_mode` is registered, and the MAC guard covers 2 edges after every change;
  - INT loads carry zero magnitudes, with a zero-load on INT entry;
  - a lap is one `ring_in` edge, one edge ahead of it, followed by a bubble;
  - drains are `shift_in` with `acc_in_west = 0`;
  - the combiner output comes 2 edges after each drain edge.
- **New: AF-only inputs in INT mode.**
  - `rng_en` and `a_len_in` are don't-cares.
  - `block_start` and `slice_start` must be low. They reach only the AF block clock, but a `block_start` in INT mode
    clears the slice restart that the INT drains armed, so the next SC block could inherit a phase.
  - Gating them with `int_mode` would cost 2 gates and is the alternative if a sequencer cannot guarantee this.
- **New: mode switches** (no reset, tightest by default).
  - **SC to INT.** The SC slice drains first. `int_mode` stays low on every SC drain edge, otherwise the combiner
    captures an SC column. The tightest sequence:
    - `int_mode` high from D_last+1;
    - the zero-load on D_last+1;
    - the first raw capture on D_last+2.
  - **INT to SC.**
    - Keep `int_mode` high through the last INT drain edge E_END.
    - The first SC `block_start` may come on E_END+1.
    - That block must reload both A and W (with L), because INT mode left zero magnitudes and plane signs in the edge
      registers.
    - The INT drains armed the slice restart, so the block runs at phase 0 without `slice_start`.
- **Simulation checks.**
  - `[BP-CONTRACT]` (fatal): an INT MAC consumed live AF stream bits.
  - `[CBSG-AF-CONTRACT]` (counted): every AF check, applied on SC edges. MAC accounting runs only on samples captured
    under the SC select, and counts with the guarded `mac_core`. The cut-block check compares against `sc_a_len`, the
    per-row L of the last SC-edge A load (INT-mode A loads also load `a_len_q`, with the don't-care `a_len_in`). Two
    new checks: `block_start` or `slice_start` while `int_mode` is high, and an SC block after INT mode that does not
    reload a side.

## Verification (RTL, 2026-10-05)

`bash sweeps/cbsg/af_ipd/run_rtl_checks.sh` gives **PASS**. Summary: `build/cbsg/af_ipd/rtl_checks_summary.log`.

| part | what | result |
|---|---|---|
| copies | source hashes against `copied_from.sha256`; RTL copies against their renamed sources; python tool copies; the Sources table of this README against `copied_from.sha256` | all unchanged since the copy; 5 RTL copies are rename-only, the peripheral is rename plus the bypass; 5 tools are identical; 30 README prefixes match |
| ref | `cbsg_ref.py --check-golden` on the 12 shipped cases; AF extra cases (24, 7,110 blocks) and review cases (7, 657 blocks) emitted into `build/cbsg/af_ipd/golden_{extra,rv}` | 12 / 24 / 7 PASS; identical to the AF campaign's sets |
| units | `sweeps/cbsg/af_ipd/tb_cbsg_af_ipd_units.sv` | encoder 1,056,768 cases and stream generator 3,013 checks (the AF unit bench, run on the copies); INT silence 32,768 checks; copied peripheral against the original 32,001 checks (SC select equal, INT select = original \| raw); L = 0 gives kA = 0 for every b, 16,384 checks (the A-side gate point); 0 wrong |
| sc | `designs/payn/tb/test_payn_array_cbsg_af_ipd.sv +MODE=sc` with `CAI_LOCKSTEP`: an AF top runs on the same SC inputs and is compared every edge. This is the AF functional matrix with random raw planes, `int_prec` and `ring_in` on every edge (`+INT_JUNK`), plus two tied-off chains, two `RNG_LOW_IDLE` chains (the AF counter holds between blocks) and `NEG_SHORT_LAST=2` with `RNG_LOW_IDLE` | 94 runs: 65 passing runs (170,882 blocks, 1,187,008 drained accumulators, 10,936,448 per-block accumulators and 10,936,448 kA values bit-exact; 1,503,789 lockstep edges identical to the AF top) and all 29 negative controls caught with the AF tags. Lockstep is clean in every run, negative controls included, and lockstep includes equal `[CBSG-AF-CONTRACT]` counts, so in SC mode the fixed cut-block check counts exactly what the AF top counts |
| sctrace | SC traces (every drain, per-block tile accumulator, load-edge phase and kA) of the bench on the AF-IPD top with INT junk, against the same bench compiled on the AF top (`+define+CAI_DUT_AF`) | 7 runs (4 chained-suite schedules, 3 negative controls), traces and RESULT lines byte-identical |
| int | `+MODE=int`: the IPD single-PE matrix plus AF-specific cases. Checker `sweeps/cbsg/af_ipd/check_bp_trace.py` (numpy int64) | 72 cases: 47 passing runs bit-exact; 25 negative controls caught (see below the table); block period = `BW*NB + (BW-1) + 8` in all 49 bit-exact runs, with drain spacing measured on multi-block runs; lap coverage: 30,144 tile-laps, 1,693 folding a pending carry and 289 a pending borrow; 114,853 INT MACs consumed with the AF streams silent |
| intx | the original IPD bench on the original IPD top, with the same workloads | 15 cases, INT traces and schedules byte-identical |
| switch | `+MODE=switch`: SC golden cases and INT blocks on one DUT, no reset, tightest transitions | 17 runs: 11 positive runs, all bit-exact with contract 0, including all 43 SC cases interleaved with 43 INT blocks twice (8,135 SC blocks, 56,512 drained accumulators, 131,072 INT MACs each; the second with `RNG_LOW_IDLE` and INT `a_len_in` = 255) and the two short-block cut-block review runs; 6 negative controls caught (see below the table) |
| grid (IPD grid wrapper, rename check) | `designs/payn/tb/test_pe_grid_cbsg_af_ipd.sv` on the copied grid wrapper, a rename-only copy of the IPD grid with no AF edge, INT bypass, mode register, guard or combiner; 2x2 and 4x4, 1-edge per-PE laps, checker `sweeps/cbsg/af_ipd/check_bp_ipd_grid_trace.py`. Evidence for the copied IPD lap wave only, **not** for the AF + INT integration on a grid | 51 cases: 21 passing runs and 20 negative controls from the IPD grid matrix, plus 10 traces byte-identical to the original IPD grid bench on the original IPD grid. 4x4 INT8 L=4096 takes 301 edges (85.0%), W4A8 and INT4 169 |
| power | SC streaming bench (INT tied off, and INT junk), uniform and ladder, 256 blocks; INT energy bench, 9 points | SC traces byte-identical to the AF power bench on the AF top, drains bit-exact (kernel == AF model == RTL); INT points bit-exact with exact SAIF windows (INT8 / W4A8 / INT4 L=1024 and INT8 L=2048, modes 0/1/2, both shift contracts) |
| elab | `sweeps/cbsg/af_ipd/run_dc_elab.sh` (DC elaborate, link, `check_design`); PASS needs the AF-IPD, AF and IPD elaborations all to succeed | 0 latches, 5,441 registers (AF 5,179, IPD 5,768); a broken AF reference path now gives `CAI_ELAB FAIL` |

**What the int matrix covers.**
- **Positive runs:**
  - INT8, W4A8 and INT4;
  - extremes, ReLU and alternating data;
  - L from 128 to 4096, plus near-limit lengths (INT8 65,408; W4A8 and INT4 1,048,448);
  - multi-block runs, `JUNK`, `MODE_AT` = 2 and 3;
  - both shift contracts (`shift_in` on the lap edge, and `LAP_RING_ONLY`).
- **AF-specific runs:**
  - `PARK_CYC0` with zero magnitudes passes;
  - nonzero A magnitudes (`NEG_MAG_A` with `PARK_CYC0`) and nonzero W magnitudes (`NEG_MAG_W`) are caught by
    `[BP-CONTRACT]`;
  - SC strobes in INT mode (`JUNK_SCSTROBE`) stay bit-exact but are flagged by `[CBSG-AF-CONTRACT]`.
- **Negative controls (25):**

  | control | caught by |
  |---|---|
  | no lap (`LAP_LEN=0`, `NEG_NO_RING`) | checker, or `[TIMING-FAIL]` |
  | double lap (`LAP_LEN=2`, every precision), BP-length lap (`LAP_LEN=8`) | checker |
  | stray ring, one edge ahead of the first MAC and mid-pass | checker |
  | lap on the last MAC (`NEG_NO_BUBBLE`) | checker |
  | wrong `int_prec`, `int_mode` one edge late | checker |
  | live magnitudes (`NEG_MAG`, `NEG_MAG_A`, `NEG_MAG_W`) | `[BP-CONTRACT]` |
  | SC strobes in INT mode | `[CBSG-AF-CONTRACT]` |

**What the switch runs cover.**
- **Positive runs:**
  - INT junk in SC segments, and junk INT segments;
  - stalls, gaps, exact `mac_en` and loose drains;
  - the phase restart from drains only (`NO_SLICE_START`, including after INT segments), and from `slice_start` only;
  - `SW_GAP=3`;
  - INT first, and back-to-back INT segments;
  - the review case for the cut-block check: SC cases ending in short blocks (C = 1, 1, 2, 3, 7), `rng_en` held low
    after every block and through the INT segments (`RNG_LOW_IDLE`), INT `a_len_in` = 255 or 128 (`INT_LEN_DC`), on
    E_END+1 and E_END+2, and over all 43 cases interleaved.
- **Negative controls (6):**

  | control | caught by |
  |---|---|
  | `int_mode` high on the last SC drain edge | `[TIMING-FAIL]` |
  | `int_mode` falling one edge late | CHECK + CONTRACT |
  | no zero-load after SC | `[BP-CONTRACT]` |
  | `int_mode` dropped before the last INT drain | `[TIMING-FAIL]` |
  | first SC block after INT not reloading W | CHECK + CONTRACT |
  | last SC block cut 2 cycles short before an INT segment (`NEG_SHORT_LAST=2`, `RNG_LOW_IDLE`, INT `a_len_in` = 0) | CHECK + CONTRACT + "cuts a block" at the first SC `block_start` after the INT segment |

**Differences from the source benches** (marked `[AF-IPD]` in the files):
- **SC part:**
  - A case now ends on the negedge right after its last drain shift edge. The AF bench could end one edge later,
    depending on thread order.
  - INT junk comes from its own xorshift generator, so the schedule is the same with or without it.
  - New plusargs: `RNG_LOW_IDLE` (`rng_en` low on every edge outside a running block, so the AF counter holds instead
    of stepping to IDLE) and `NEG_SHORT_LAST=n` (the last block of every case n cycles short).
- **INT part:**
  - The drained columns and combiner words are read by one posedge monitor that knows every scheduled drain edge, so
    `[TIMING-FAIL]` covers every edge after reset in every mode. The trace bytes are unchanged; `intx` shows this.
  - Magnitudes are driven 0 on every edge.
  - New plusarg `INT_LEN_DC=v`: `a_len_in` = v on every row in INT mode (default 0).
  - The JUNK extra loads come only on edges where `int_mode` is high. Before that, the edge is an SC edge, where a load
    without `block_start` breaks the AF contract.
- **Power benches:**
  - The INT energy bench defaults are `BPE_LAP_LEN=1` and `BPE_LAP_RING_ONLY=1`; check it with
    `--lap-len 1 --lap-ring-only`.
  - The SC power bench writes the AF trace file and format unchanged.
- **Route step (2026-10-05):** the functional bench gains `+DRAIN_SAMPLE_LATE_PS=n` (default off): read
  `acc_out_east` n ps before the shift edge that consumes it instead of at the negedge before it. RTL-neutral (with
  and without `+DRAIN_SAMPLE_LATE_PS=50`, all 43 cases chained with INT junk and `calls_prot` give byte-identical
  traces and RESULT lines: `build/cbsg/af_ipd/route_debug/rtl_drain_sample_equiv.log`); every earlier run is
  unchanged. Why: [Route and power](#route-and-power-2026-10-05), routed functional GL.

## Review fixes (2026-10-05)

| finding | fix | evidence |
|---|---|---|
| The `[CBSG-AF-CONTRACT]` cut-block check read `u_peripheral.a_len_q`, which INT-mode A loads also load with the don't-care `a_len_in`. A legal SC -> INT -> SC sequence (short last SC block, `rng_en` low in INT mode, INT `a_len_in` > 16*(C+1)) counted a false error. Monitor only: the hardware was right | The monitor keeps `sc_a_len`, the per-row L of the last SC-edge `load_a` (`a_len_q` as the AF top would hold it), and checks against it. In INT mode the counter can only hold or step towards IDLE, so the check is the AF top's check on the same SC history, at most more lenient. A really cut last SC block before an INT segment is still flagged at the first SC `block_start` after it; the old check missed that whenever the INT A loads carried L = 0 (the bench default) | `sweeps/cbsg/af_ipd/review_fix_ab.sh` -> `build/cbsg/af_ipd/review_fix/ab_summary.log` (pre-fix top snapshot against the fixed top). Reviewer's directed bench (`tb_review_cutblock.sv`), 20 cases L_int x C: pre-fix counts 1 false error in exactly the 5 cases with L_int > 16*(C+1); fixed counts 0 in all 20; drains equal to the AF top in all 40 runs. New switch runs `sw_len_dc_hold`, `sw_len_dc128_gap1`, `all_interleaved_len_dc`: pre-fix FAIL with 5 / 2 / 6 "cuts a block" errors, fixed PASS with 0. `neg_sw_cut_across_int`: pre-fix has no "cuts a block" (only 4 MAC-accounting errors), fixed flags it. In SC runs the counts equal the AF top's (lockstep) |
| `build_int()` reused `build_int/simv` when it was newer than the bench only; `run_sctrace` reused `build_sc/simv` whenever it existed. An RTL-only edit could be tested with stale binaries | The runner touches `build/cbsg/af_ipd/.run_stamp` at start; `build_int` and `build_sc` are reused only if newer than that stamp, i.e. compiled by the same invocation (int -> switch, sc -> sctrace). A standalone `PARTS=switch` or `PARTS=sctrace` recompiles | final run: stamp 12:55:19, `build_int` 12:56:37 and `build_sc` 12:56:38 (compiled by int and sc), reused by switch and sctrace from 13:02; the reuse predicate is false against a fresh stamp, so a standalone part recompiles |
| The grid part was presented as evidence for this variant, but the copied grid wrapper is a rename of the IPD grid with no AF edge, bypass, mode register, guard or combiner | Labeled "IPD grid wrapper, rename check" in the runner header, the runner's summary line, the Hardware table, the Verification table and Open items: evidence for the copied IPD lap wave only | `rtl_checks_summary.log` grid line |
| The INT-silence gate cost said 512 AND2 per side; A needs far fewer | Restated in the peripheral header and above: A about 64 AND2 (per-row L buses; L = 0 gives kA = 0 for any b, now checked in the unit bench) or 128 (`ka_hi_gt` / `ka_hi_eq`); W about 512 (magnitudes; no cheaper W point). W's zero-load requirement is why an A gate buys nothing; the no-gate decision stands | units: "L=0 gate point 16384 checks", 0 wrong |
| README Sources table: wrong prefix for `sweeps/cbsg/af/tb_cbsg_af_units.sv` (`10b4ec8ad3d99458`, true `10b4ec8ad3d9945c`) | Corrected; `check_copies.sh` now checks every README prefix against `copied_from.sha256` and that every recorded source has a row | the new check failed on the old README (1 wrong prefix) and passes now (30 rows) |
| `dc_elab_check.tcl` printed PASS even if the AF or IPD reference elaboration failed | PASS needs `$ok && $ok_af && $ok_ipd`; the FAIL line names which failed | rerun: PASS (5,441 / 5,179 / 5,768 registers, 0 latches); with the AF path broken: `CAI_ELAB FAIL (afipd 1 af 0 ipd 1)` |

New bench plusargs used by these checks (`designs/payn/tb/test_payn_array_cbsg_af_ipd.sv`): `RNG_LOW_IDLE`,
`NEG_SHORT_LAST=n` (SC) and `INT_LEN_DC=v` (INT).

## Synthesis (`cbsg_af_ipd_20261005`, 2026-10-05)

`RUN_NAME=cbsg_af_ipd_20261005 RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF_IPD NTFY_CHNL=`
(PAYN_SC_CSA knobs; only TOP and SRC_SV differ from the AF target). Log `build/cbsg/af_ipd/syn/make_synth.log`.

- **Clean.** No errors. 0 latches. 5,441 register bits, as in the DC preflight.
- **Warnings** are the union of the AF and IPD runs' sets: the IPD core's `VER-318`, the combiner's `UCN-1` / `VO-4`.
- **`check_design`** equals AF's: 58 LINT-1, 2,178 LINT-2.
- **Final design-rule cost 46.4** (min_capacitance). The IPD run has the same cost, from the combiner; AF has 0.

**Area** (`bash sweeps/cbsg/af_ipd/run_syn_reports.sh` -> `build/cbsg/af_ipd/syn/area_breakdown.txt`; DC cell area,
um2). One probe, `sweeps/cbsg/af_ipd/dc_af_ipd_probe.tcl`, classes every leaf cell of all four netlists (by name and
fan-in / fan-out cone); every class sum is checked against `area.rpt`.

| block | CSA `csa_20261002` | AF `cbsg_af_20261005` | IPD `csa_bp_ipd_20261004` | **AF-IPD** | AF-IPD - AF | AF-IPD - CSA |
|---|---:|---:|---:|---:|---:|---:|
| **total** | 43,455.0 | 39,926.0 | 46,492.4 | **44,690.6** | **+4,764.7 (+11.9%)** | **+1,235.7 (+2.8%)** |
| PE core `u_pe` | 29,253.0 | 29,252.6 | 30,359.7 | 30,471.4 | +1,218.8 | +1,218.4 |
| &nbsp;&nbsp;64 tiles | 26,198.3 | 26,197.9 | 26,218.1 | 26,329.9 | +131.9 | +131.5 |
| &nbsp;&nbsp;per-tile doubling muxes (1,472 AO22 + 56 NOR2XB) | - | - | 1,031.7 | 1,031.7 | +1,031.7 | |
| &nbsp;&nbsp;lap select tree (`ring_q` -> 1,536 selects) | - | - | 52.9 | 52.9 | +52.9 | |
| &nbsp;&nbsp;bit/sign pipes + core clock gates | 2,992.8 | 2,992.8 | 2,992.8 | 2,992.8 | 0 | 0 |
| &nbsp;&nbsp;core glue | 61.8 | 61.8 | 61.8 | 61.8 | 0 | 0 |
| &nbsp;&nbsp;PE wrapper (`ring_q` flop, `shift_in \| ring_q`) | - | - | 2.3 | 2.3 | +2.3 | |
| A edge | 7,094.8 | 8,442.5 | 7,707.9 | 10,881.7 | +2,439.2 | +3,786.9 |
| &nbsp;&nbsp;A registers (mag + sign [+ row L]) | 933.0 | 1,036.3 | 933.0 | 1,036.3 | 0 | +103.4 |
| &nbsp;&nbsp;A Sobol bank + 1,024 A comparators | 6,161.9 | - | 6,162.0 | - | | |
| &nbsp;&nbsp;**64 kA encoders** | - | 6,584.2 | - | **8,560.3** | **+1,976.1** | |
| &nbsp;&nbsp;encoder input buffering | - | 34.5 | - | 37.9 | +3.4 | |
| &nbsp;&nbsp;thermometers + A INT bypass (merged) | - | 787.4 | 613.0 (bypass) | 1,247.1 | +459.7 | |
| W edge | 6,384.7 | 2,162.9 | 7,004.0 | 2,549.3 | +386.4 | -3,835.4 |
| &nbsp;&nbsp;W registers | 932.9 | 932.9 | 932.9 | 933.0 | 0 | |
| &nbsp;&nbsp;1,024 W comparators + W INT bypass (merged) | 5,451.8 | 1,230.0 | 5,451.9 + 619.2 | 1,616.3 | +386.3 | |
| bypass select buffering shared by A and W | - | - | 12.1 | 33.8 | +33.8 | |
| W bank (`u_w_rng`; AF `u_rng` block clock) | 707.9 | 55.0 | 707.9 | 55.0 | 0 | -652.9 |
| combiner `u_combiner` | - | - | 680.8 | 680.9 | +680.9 | |
| mode / ring control (top glue + PE wrapper) | 3.0 | 0.6 | 10.8 | 8.3 | +7.7 | |
| other (u_peripheral reset buffers) | 11.6 | 12.4 | 11.6 | 12.4 | 0 | |

- **The INT blocks cost what was expected, or less.**
  - Doubling muxes plus select tree: 1,084.7, identical to IPD to the 0.1 um2 (0.706 um2 per bit).
  - Combiner: 680.9.
  - Mode / ring control: 8.3.
  - INT bypass: +879.8 against AF's thermometer and comparators (A +459.7, W +386.3, shared select 33.8). On the
    BP / IPD Sobol edge it costs 1,244.4 as 2,048 separate AO21. Here DC folds the OR into the thermometer's and the W
    comparators' last gates, so the "bypass" cone classes are not standalone gates. The table therefore gives
    thermometer + bypass and comparator + bypass as single rows.
  - Tiles: +131.9 from load-driven sizing (IPD +19.8).
- **The kA encoders grew by 1,976.1 um2 (+30%) with unchanged RTL.**
  - Each encoder went from 102.9 to 133.8 um2.
  - The netlist cell mix changed. In the lane-3 instance, AF uses 24 CGENI + 24 XNOR2 + 16 XOR2 + 3 ADDF (a
    decomposed ripple adder). AF-IPD uses 28 ADDF + 21 ADDH + 2 CGENI (a full-adder tree). Over all 64 encoders the
    counts are ADDF / ADDH / CGENI = 192 / 0 / 1,600 (AF) against 1,792 / 1,344 / 176 (AF-IPD).
  - The new mapping is also slower: L reg -> encoder -> thermometer arrives at 1.22 ns, against 0.94 in AF. So it is
    not a timing-driven upsizing.
  - Diagnostic compiles (`bash sweeps/cbsg/af_ipd/syn_encoder_experiment.sh` -> `build/cbsg/af_ipd/syn/exp/exp_summary_all.txt`)
    use the same `synth.tcl` and knobs, with experiment tops generated into `build/`:

    | compile | total | 64 encoders | encoder cells ADDF / ADDH / CGENI |
    |---|---:|---:|---|
    | AF-IPD rerun | 44,690.6 | 8,560.3 | 1,792 / 1,344 / 176 (deterministic, identical) |
    | AF rerun | 39,926.0 | 6,584.2 | 192 / 0 / 1,600 (identical to `cbsg_af_20261005`) |
    | AF-IPD without combiner | 43,998.1 | 8,560.7 | 1,792 / 1,344 / 176 |
    | AF-IPD with the AF/CSA PE (no ring, no doubling muxes) | 43,572.1 | 8,560.3 | 1,792 / 1,344 / 176 |
    | **AF-IPD without the INT bypass** | **41,674.1** | **6,553.7** | 192 / 0 / 1,600 |
    | AF-IPD, bypass OR in its own submodule (no merging) | 45,042.4 | 8,546.0 | 1,792 / 1,344 / 176 |
    | AF-IPD, raw ports 2-cycle (`MULTICYCLE_INPUT_PORTS`) | 44,690.7 | 8,559.7 | 1,792 / 1,344 / 176 |

  - The remap follows the INT bypass, and only the bypass. Removing the combiner or the IPD PE does not undo it.
    Keeping the OR out of the thermometer cone does not undo it, and relaxing the raw-port timing does not either.
    It is a DC architecture choice for the encoder adders, not a hardware need. The bypass therefore costs about
    3,016 um2 in this flow: 44,690.6 against 41,674.1 without it. That splits into the gates (about 880), the encoder
    remap (about 2,006) and tile sizing (about 120).
  - Without the remap, AF-IPD would be about 42,714 um2 (-1.7% vs CSA), close to the 42,960 estimate.
  - Recovering it needs a synthesis-side change, for example a fixed implementation for the encoder adders, or the
    encoders compiled bottom-up and dont_touched. That is outside the fixed PAYN_SC_CSA knobs, and a fair comparison
    would apply it to AF as well. An RTL hierarchy change does not help, as the submodule compile shows. Open item.

**DC timing** (tt 0.80 V 25 C, ideal clock, 2.5 ns, 1.25 ns input delay; all four netlists probed by the same script:
`build/cbsg/af_ipd/syn/timing_summary.txt`, probe reports `build/cbsg/af_ipd/syn/<target>_<run>/probe.rpt`):

| path (slack, ns) | CSA | AF | IPD | **AF-IPD** |
|---|---:|---:|---:|---:|
| worst (reset port -> AF-IPD: combiner `out_reg`, as IPD) | +0.93 | +0.97 | +0.91 | **+0.88** |
| register -> register (combiner `east_q` -> `out`) | +1.51 | +1.49 | +1.06 | +1.06 |
| -> A bit pipe, any start (`a_raw_in` port -> bypass) | +2.06 | +1.49 | +1.20 | +1.18 |
| row L reg -> kA encoder -> thermometer -> A bit pipe | - | +1.53 | - | +1.25 (1.22 ns) |
| phase reg -> encoder -> thermometer -> A bit pipe | - | +1.49 | - | +1.30 |
| A magnitude reg -> encoder -> thermometer -> A bit pipe | - | +1.60 | - | +1.34 |
| `int_mode_q` -> bypass select -> A / W bit pipe | - | - | +2.15 | +2.16 |
| `int_mode_q2` -> MAC guard -> tiles | - | - | +2.30 | +2.30 |
| self path: tile (3,4) -> `<<1` -> doubling mux -> tile (3,4) acc | +1.68 | +1.68 | +1.65 | +1.65 |
| chain path: tile (3,3) -> tile (3,4) acc (drain) | +1.68 | +1.68 | +1.66 | +1.66 |
| `ring_q` -> anywhere (tile `acc_low`, doubling-mux select) | - | - | +2.09 | +2.10 |
| `ring_q` -> tile `acc_high` clock-gate enable | - | - | +2.25 | +2.25 |
| `ring_q` -> combiner capture clock gate | - | - | +2.36 | +2.36 |
| east column -> combiner `east_q` | - | - | +1.71 | +1.71 |
| `shift_in` -> anywhere / -> tile clock-gate enable | +1.04 / +1.09 | +1.04 / +1.09 | +1.01 / +1.06 | +1.01 / +1.06 |
| `shift_in` -> `u_rng` slice restart / -> combiner capture | - | +1.09 / - | - / +1.17 | +1.10 / +1.17 |
| `mac_en` / `int_mode` / `ring_in` / `int_prec` ports | +1.15 / - / - / - | +1.15 / - / - / - | +1.09 / +1.07 / +1.19 / +1.21 | +1.09 / +1.07 / +1.19 / +1.21 |
| `block_start` / `slice_start` / `rng_en` / `a_len_in` ports | - | +1.13 / +1.12 / +1.11 / +1.22 | - | +1.13 / +1.12 / +1.11 / +1.22 |

- No combinational loops (`report_timing -loops`), and `check_timing` is clean in all four.
- **Lap paths.** The lap paths are the IPD numbers. `ring_q` drives 1,536 mux selects through a 108 BUFH + 92 INV tree
  with more than 2.0 ns of slack. The self path is a one-cycle register-to-register path at +1.65.
- **A path.** The A path lost 0.28 ns to the encoder remap, not to the bypass: the OR is folded into the
  thermometer's last gate. It is still far from critical.
- **`ring_q` fanout.** The routing risk noted under Open items still holds.

**Post-synthesis GL** (`bash sweeps/cbsg/af_ipd/run_syn_gl_checks.sh`, summary
`build/cbsg/af_ipd/gl/cbsg_af_ipd_20261005/syn_gl_checks_summary.log`). It uses the AF recipe and the AF ideal-clock
SDF view:
- Every run plays the same inputs on a fresh RTL compile of the bench.
- SC: the GL RESULT line must equal the RTL one.
- INT and switch: every GL `bpt_trace.txt` must be byte-identical to the RTL trace and pass `check_bp_trace.py`.

| mode | runs | content |
|---|---|---|
| unit delay, `ARM_UD_MODEL` + `ARM_EN_X_SQUASH`, no timing checks | **63/63 PASS** | **SC 28:** the AF unit list, 25 passing runs, including all 43 cases chained three ways (56,512 drains each): no `slice_start`; the same with INT junk; stalls, junk buses, DUT resets, gaps and INT junk. Also the 12 golden cases with `rng_en` low between blocks and INT junk. Plus 3 negative controls that fail with exactly the RTL counts (54/64, 127/192, 381/448). **INT 30:** INT8, W4A8, INT4; extremes; JUNK; MODE_AT = 3; INT8 L = 65,408; both shift contracts; `PARK_CYC0`; INT `a_len_in` = 255. Negative controls, one per precision: stray ring (INT8), double lap (W4A8), wrong `int_prec` (INT4); no ring (`[TIMING-FAIL]`); and two gl-only controls, `NEG_MAG_A` and `NEG_MAG_W` (the RTL run stops at `[BP-CONTRACT]`, and the GL trace fails the checker with 72 mismatches). **Switch 5:** mixed SC / INT with INT junk; INT first with `rng_en` held low; all 43 cases interleaved with 43 INT blocks (8,135 SC blocks, 56,512 drains); no-reload (`[CHECK]`) and early `int_mode` (`[TIMING-FAIL]`) controls |
| synthesis SDF, ideal-clock view, max corner, `+neg_tchk`, timing checks on | **24/24 PASS** | **SC 10:** the AF SDF list, with INT junk on the chains: plain, ladder, rung, av257, mixed, tiny calls, 12 golden cases chained with stalls / junk / gaps, all 43 chained; 2 negative controls. **INT 8 + 4 controls**, all three precisions in both shift contracts, plus JUNK and `PARK_CYC0`. **Switch 2**, INT first: a mixed run and a no-reload control. Every run: 0 timing violations, SDF errors 0. The only warnings are 621 `SDFCOM_CFTC`, all the `DFFRPQ*` async-reset removal check (AF had 620) |

- **SDF view.** `sweeps/cbsg/af/sdf_ideal_clock.py` (invoked read-only) zeroes 3 shared ICGs over 3.2 ns, as in AF,
  plus the combiner's `clk_gate_east_q_reg_0_` (1.08 ns raw).
- **Reset settle.** As in AF, SC SDF runs wait `+RESET_SETTLE=2` edges. INT runs already have more than two idle
  edges before their first load.
  SDF switch runs start with an INT segment at MODE_AT = 3, because the switch mode would otherwise load on the first
  edge after reset (the same reset-tree artifact as in AF).
- **Bench.** Unchanged for these runs.
- **Not run.** The power-bench smoke on the synthesized netlist was not run in this step; the RTL `power` part covers
  the benches.

## Route and power (2026-10-05)

Campaign `build/power_char/cbsg_20261005/af_ipd/` (README.txt there; comparison `comparison.txt`, written by
`sweeps/cbsg/af_ipd/compare_af_ipd_route.py`). Recipe = the AF and BP campaigns': PAYN_SC_CSA knobs, synthesis of
record `cbsg_af_ipd_20261005` (encoder remap included), bootstrap (floating pins, activity seed) then pinned pass 2,
basin gate, strict-then-approved GL audit with rationale files, drain-excluded PT-PX, bit-exact drains.

**Route.**

| step | result |
|---|---|
| bootstrap `cbsg_af_ipd_20261005_distguide` (`run_af_ipd_bootstrap.sh`) | 44,810.2 um2, setup +0.090 / hold +0.170 ns, geometry 0; uniform GL bit-exact; audited SAIF installed as the pass-2 seed |
| pinned pass 2 `..._spp_pins_postfill` (`run_af_ipd_pinned.sh`) | `apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_postfill.tcl` (unchanged): the C-BSG pin plan already places the BP INT ports (raw A per row band east, raw W per column band north, `int_mode`/`int_prec`/`ring_in` south control, `int_out` south out); **3,727 pins fixed**, min same-layer pitch 0.308 um; die 273.56 x 272.02 um (AF 259.14 x 258.72, BP lap 275.52 x 274.82) |
| post-fill | as AF: 23,779 + 40,460 (no-DRC) fillers; 77,432 router markers for 71,795 routable nets (1.079 per net), NanoRoute auto-stop skipped search-and-repair; the hook's strong reroute (`-drouteAutoStop false`) ran 39 iterations to 0, the via swap left 105 -> **182 markers + 4 antenna** (AF: 191 + 3) |
| qualify | residual markers only -> `sweeps/repair_popcount_apr.sh REPAIR_MODE=targeted` (in place; original in `before_legalization_20261005_144526_2792996/`): local fix markers_after_fix = 0, +2 antenna diodes, filler refill 177 + 12; strict **final**: geometry 0, antenna 0, connectivity 0, placement legal, **setup +0.104 / hold +0.142 ns** |
| basin gate (shared `sweeps/pinned_pass2/run_basin_gate.sh`) | **grid**: corr(tile x, column) 0.982, mean \|a-w skew\| 38.6 ps (p90 74.2), wire 1,010.3 mm, pin proof PASS (3,727 fixed, 0 mismatches) |
| area | **44,430.6 um2** (u_pe 30,084.4, u_peripheral 13,521.0, u_combiner 701.8, u_rng 57.3): AF route +4,498.1 (+11.3 %), CSA +514.0 (+1.2 %), BP lap -1,665.9 (-3.6 %) |

Shared edit: `sweeps/repair_popcount_apr.sh` line 16, `TSMC22/PAYN_SC_CSA_CBSG_AF_IPD` added to the target list
(the one allowed line; `git diff` showed only the AF campaign's line before, sha256 `bc14192f...` as recorded by AF;
after: `fb27cc44...`).

**GL audit.** Every routed GL (bootstrap, uniform, ladder, routed_func, INT) failed the strict audit on one reason
only, 4 `SDFCOM_IWSBA`: zero-delay INTERCONNECT from a hold-fix cell to `int_out[60..63]`, the combiner word's
sign-extension aliases (`assign out[59..62] = out[63]` in `u_combiner`), the mechanism the BP routes approved.
`--approve-annotated-interconnect` only, with rationale files (`bootstrap/`, `pinned/`, `int_energy/<route>/
gl_validator_args_rationale.txt`). 0 SDF errors, no NDI clamps, 0 post-reset timing violations everywhere; ICG
CK->ECK <= 0.039 ns (77 ICGs), raw routed SDF, no ideal-clock view.

**SC power** (PT-PX, routed SPEF, max-SDF GL SAIF, drain excluded; same stimulus as AF; drains bit-exact 64/64):

| workload | AF-IPD | AF route | delta | CSA pinned | BP lap pinned |
|---|---:|---:|---:|---:|---:|
| uniform L=128, mW | **12.067** | 11.583 | +0.484 (+4.2 %) | 15.726 | 16.494 |
| uniform pJ/MAC | **0.4714** | 0.4525 | +0.0189 | 0.6143 | 0.6443 |
| ladder (7.33 cyc/blk), mW | **10.553** | 10.084 | +0.469 (+4.7 %) | | |
| ladder pJ/MAC | **0.3779** | 0.3611 | +0.0168 | | |
| GMAC/s/mm2 (uniform, 1 PE) | 576.2 | 641.1 | -10.1 % | 582.9 | 555.4 |

Where the +0.484 mW (uniform) goes (`classes_uniform/`; rows sum to the PT total; the same split as AF's):

| class | AF-IPD | AF | delta mW | why |
|---|---:|---:|---:|---|
| 64 kA encoders | 0.400 | 0.239 | **+0.161** | the DC remap (full-adder trees, +1,897.6 um2 routed); RTL unchanged |
| bit/sign pipes + core glue | 2.718 | 2.569 | **+0.149** | same flops and activity; w_bits_pipe +0.129, a_bits_pipe +0.053, core glue -0.036 (`build/cbsg/af_ipd/route_debug/core_*`): longer broadcast nets on the 5.6 %-wider die |
| tiles | 6.708 | 6.643 | +0.065 | |
| per-tile doubling muxes + select | 0.062 | - | +0.062 | selects static in SC; inputs toggle with acc_out |
| thermometer + A bypass (merged) | 0.246 | 0.202 | +0.044 | |
| W comparators + W bypass (merged) | 0.382 | 0.401 | -0.018 | |
| combiner | 0.012 | - | +0.012 | |
| A / W registers, ka input buffering, W bank, peripheral CTS, shared select | 0.259 | 0.248 | +0.011 | |
| PE / top clock buffers, other | 1.282 | 1.282 | +0.000 | PE CTS -0.031, top CTS +0.030 |
| **total** | **12.067** | **11.583** | **+0.484** | |

Without the encoder remap the SC overhead over AF would be about +0.32 mW (+2.8 %) and the area about 42,533 um2.

**INT energy** (`run_af_ipd_int_energy.sh`: the BP lap campaign's seven points, its operands and windows; 1-edge
in-place laps, `lap_ring_only=1`; GL bit-exact on every tile and combiner word and byte-identical to RTL; INT SAIF
audit PASS on every point: AF magnitudes, row L, edge registers and all 64 kA encoder outputs at 0, block-clock
outputs static, `int_mode` high, bypass transparent bit for bit):

| point | MAC/cycle AF-IPD / BP | pJ/MAC AF-IPD | BP lap | ratio | u_pe pJ/MAC AF-IPD / BP | GMAC/s/mm2 AF-IPD / BP |
|---|---|---:|---:|---:|---|---|
| INT8 L=49,152 peak (d) | 128.0 / 128.0 | 0.3521 | 0.3481 | 1.011 | 0.3383 / 0.3353 | 1,152 / 1,111 |
| INT8 L=1024 data + laps (dr) | 115.4 / 68.3 | **0.3906** | 0.4533 | **0.862** | 0.3741 / 0.4350 | 1,039 / 592 |
| INT8 L=1024 drain incl. (all) | 103.7 / 64.0 | 0.4068 | 0.4695 | 0.866 | 0.3883 / 0.4492 | 934 / 555 |
| W4A8 L=1024 (dr) | 234.1 / 146.3 | **0.1945** | 0.2186 | 0.890 | 0.1864 / 0.2097 | 2,107 / 1,269 |
| INT4 L=98,304 peak (d) | 512.0 / 512.0 | 0.0883 | 0.0873 | 1.012 | 0.0848 / 0.0841 | 4,609 / 4,443 |
| INT4 L=1024 (dr) | 468.1 / 292.6 | **0.0972** | 0.1094 | 0.889 | 0.0932 / 0.1050 | 4,214 / 2,539 |
| INT4 L=1024 (all) | 381.0 / 256.0 | 0.1044 | 0.1165 | 0.896 | 0.0995 / 0.1113 | 3,430 / 2,221 |

- The laps are where the variant wins: 7 lap cycles per INT8 block instead of 56, so at L=1024 the array is busy
  90 % of the cycles instead of 53 %, and the per-cycle power (18.0 mW vs 12.4) buys 69 % more MACs.
- Peak (no laps) is 1.1 % above BP: u_pe +0.15 mW (doubling muxes see every acc_out toggle; longer wires) and
  u_peripheral +0.09 mW (the bypass is merged into larger thermometer / comparator gates that the raw planes
  drive); the frozen AF block clock costs 0.002 mW against BP's Sobol banks 0.036.

**Routed functional GL** (`sweeps/cbsg/af_ipd/run_routed_gl_checks.sh`, the `routed_func` stage; raw routed SDF,
`+neg_tchk`, every run against a fresh RTL compile): **32/32 PASS** (SC 15: the AF triple at `+RESET_SETTLE=2` and
`=0`, `calls_prot` with and without INT junk, ladder, mixed calls, tiny calls, 12 golden chained with stalls / gaps /
INT junk, all 43 chained with INT junk, 2 negative controls; INT 13: INT8 / W4A8 / INT4, both shift contracts, JUNK,
`PARK_CYC0`, 4 negative controls; switch 4: INT-first and SC-first mixed runs, all 43 SC cases interleaved with 43
INT blocks, a no-reload control). No ideal-clock view and no reset settle needed after CTS.
- **Drain sampling (attempt 1: 26/30).** The SC part of the bench (the AF bench's) reads `acc_out_east` at the
  negedge, 1.25 ns after the shift edge. On this route the drain rail arrives up to **1.45 ns** after the edge (PT,
  propagated clock: tile (0,7) `pending_borrow` -> 15-bit +-1 ripple -> `XOR3_X0P7M` 0.42 ns -> `acc_out_east[23]`;
  the AF route has the same path at 1.19 ns, its XOR3 0.17 ns), so a drain right after a pending carry/borrow read
  unsettled MSBs (`calls_prot`: -180 read as 8,388,428). The hardware is right: unit delay on the same netlist
  passes, and a VCD of row 0 shows every tile register and the drain rail equal to the unit-delay run 1 ps before
  each of the 559 edges. The SDC output delay is 0.05 ns, so the slack is +1.00 ns. The bench now reads at the SDC
  point (`+DRAIN_SAMPLE_LATE_PS=50`, RTL-neutral) in the routed runs. Evidence: `build/cbsg/af_ipd/route_debug/`,
  `pinned/routed_func_deviation.txt`.
- **Grid consequence.** In a PE row, `acc_out_east` feeds the next PE's `acc_in_west`, whose SDC input delay is 1.25
  ns: composing this route leaves 0.20 ns to the neighbour's `acc_in_west` path slack (AF fits with 0.06 ns to spare).
  Upsizing the column-7 output drivers (or a drain-rail flop) would remove it if a grid needs it.

## Sources (sha256 at copy time; `copied_from.sha256`, snapshots in `build/cbsg/af_ipd/source_snapshot/`)

| sha256 | source | used for |
|---|---|---|
| 2edd1b5a918da929... | `designs/payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_stream_gen.sv` | `cbsg_af_ipd_stream_gen.sv` |
| 80d6a729471ef8ff... | `designs/payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_peripheral.sv` | `cbsg_af_ipd_peripheral.sv` |
| e0df585fc2766bf5... | `designs/payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv` | top: AF header and `[CBSG-AF-CONTRACT]` monitor |
| f848db56a0f8e02d... | `designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_core_signed_segmented_csa_ipd.sv` | `inner_pe_core_signed_segmented_csa_cbsg_af_ipd.sv` |
| 2ae7f01e4193e49e... | `designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_signed_segmented_csa_bp_ipd.sv` | `inner_pe_signed_segmented_csa_cbsg_af_ipd.sv` |
| 870abbb82cd55df9... | `designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_grid_signed_segmented_csa_bp_ipd.sv` | `inner_pe_grid_signed_segmented_csa_cbsg_af_ipd.sv` |
| a98b85c4a6d079ba... | `designs/payn/variants/signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv` | top: mode register, guard, ring gate, combiner hookup, `[BP-CONTRACT]`, INT header |
| 898acc72757a57b4... | `designs/payn/variants/signed_segmented_csa_bp/bp_combiner.sv` | `bp_combiner_cbsg_af_ipd.sv` |
| 79be5d6fd17b2ba7... | `designs/payn/variants/signed_segmented_csa_bp/pe_peripheral_bp.sv` | the bypass expression in the peripheral |
| 08f0bd36386b8cd6... | `designs/payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv` | INT contract text (through the IPD top) |
| e4ba0b5299826985... | `designs/payn/tb/test_payn_array_cbsg_af.sv` | `designs/payn/tb/test_payn_array_cbsg_af_ipd.sv` (SC part) |
| a0da9b9f4862e0f4... | `designs/payn/tb/test_payn_array_bp_ipd.sv` | `designs/payn/tb/test_payn_array_cbsg_af_ipd.sv` (INT part); run unchanged in `intx` |
| ccbc18ebed9cf6a5... | `designs/payn/tb/test_pe_grid_bp_ipd.sv` | `designs/payn/tb/test_pe_grid_cbsg_af_ipd.sv` (DUT include only); run unchanged in `grid` (xc) |
| e405e886476a1b29... | `designs/payn/power/power_payn_array_cbsg_af.sv` | `designs/payn/power/power_payn_array_cbsg_af_ipd.sv`; run unchanged in `power` |
| e68f2bcd840d9673... | `designs/payn/power/power_payn_array_bp_int.sv` | `designs/payn/power/power_payn_array_cbsg_af_ipd_int.sv` |
| 10b4ec8ad3d9945c... | `sweeps/cbsg/af/tb_cbsg_af_units.sv` | `sweeps/cbsg/af_ipd/tb_cbsg_af_ipd_units.sv` (parts 1-2) |
| cbd1b7da017fdc3d... | `sweeps/cbsg/af/run_rtl_checks.sh` | `sweeps/cbsg/af_ipd/run_rtl_checks.sh` (ref, units, SC matrix) |
| afd173b0728c2eaa... | `sweeps/int_mode/bp/ipd/run_bp_ipd_rtl_checks.sh` | `sweeps/cbsg/af_ipd/run_rtl_checks.sh` (INT matrix, periods, coverage) |
| 46de13c57a08d40e... | `sweeps/int_mode/bp/ipd/run_bp_ipd_grid_checks.sh` | `sweeps/cbsg/af_ipd/run_rtl_checks.sh` (grid matrix) |
| ac374e3a4e514296... | `sweeps/int_mode/bp/gen_bp_workload.py` | `sweeps/cbsg/af_ipd/gen_bp_workload.py` (import path only) |
| 2da034dc49fd25d1... | `sweeps/int_mode/gen_bitplane_workload.py` | `sweeps/cbsg/af_ipd/gen_bitplane_workload.py` |
| 4bdfa947ad3557ac... | `sweeps/int_mode/bp/check_bp_trace.py` | `sweeps/cbsg/af_ipd/check_bp_trace.py` |
| 1bdef0fcff078dc9... | `sweeps/int_mode/bp/check_bp_power_trace.py` | `sweeps/cbsg/af_ipd/check_bp_power_trace.py` |
| 27770262a4c73760... | `sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py` | `sweeps/cbsg/af_ipd/check_bp_ipd_grid_trace.py` |
| a73d93ef892f3c62... | `designs/payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv` | included unchanged (tile) |
| 35622e1b94c28b0c... | `designs/payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv` | included unchanged by the AF top, which is the lockstep reference |
| d3048079da530b8b... | `sweeps/cbsg/cbsg_ref.py` | invoked read-only (golden check) |
| 955624612185d26f... | `sweeps/cbsg/af/emit_af_cases.py` | invoked read-only (extra cases) |
| 4a43ad9429ff611e... | `sweeps/cbsg/af/review/emit_review_cases.py` | invoked read-only (review cases) |
| 838f1d05752706a2... | `sweeps/cbsg/af/check_power_trace.py` | invoked read-only (SC power check) |
| 17c1f7649303ba17... | `sweeps/cbsg/af/dc_af_probe.tcl` | `sweeps/cbsg/af_ipd/dc_af_ipd_probe.tcl` (area classes, AF timing probes) |
| 7dd5bfc2b43c6ec9... | `sweeps/int_mode/bp/ipd/dc_bp_ipd_new_paths.tcl` | `sweeps/cbsg/af_ipd/dc_af_ipd_probe.tcl` (loop checks, lap / ring / combiner probes) |
| 6dd1c3765eff10d0... | `sweeps/cbsg/af/area_breakdown.py` | `sweeps/cbsg/af_ipd/area_breakdown.py` |
| 991e27180183302c... | `sweeps/cbsg/af/run_syn_reports.sh` | `sweeps/cbsg/af_ipd/run_syn_reports.sh` |
| dedd5ea842859ce8... | `sweeps/cbsg/af/run_syn_gl_checks.sh` | `sweeps/cbsg/af_ipd/run_syn_gl_checks.sh` (SC part, unit / ideal-clock SDF recipe, qualification) |
| 0a27f62d0c021a9b... | `sweeps/int_mode/bp/ipd/run_bp_ipd_syn_gl_checks.sh` | `sweeps/cbsg/af_ipd/run_syn_gl_checks.sh` (INT part) |
| 9eb29c03e65dea16... | `sweeps/cbsg/af/sdf_ideal_clock.py` | invoked read-only (ideal-clock SDF view) |
| 1d8559685759bef8... | `sweeps/validate_routed_gl.py` | invoked read-only (SDF run qualification) |
| 20dd7d573b877753... | `sweeps/cbsg/cbsg_campaign_lib.sh` | `sweeps/cbsg/af_ipd/af_ipd_campaign_lib.sh` (arm afipd added; GL / audit helpers verbatim) |
| 7e393cf397fa6349... | `sweeps/cbsg/run_cbsg_apr.sh` | `sweeps/cbsg/af_ipd/run_af_ipd_bootstrap.sh` (bootstrap stages) |
| a9f35e343a787ed3... | `sweeps/cbsg/run_cbsg_pinned_pass2.sh` | `sweeps/cbsg/af_ipd/run_af_ipd_pinned.sh` (pinned pass 2 and its measurement stages) |
| 6429ab356fb63195... | `sweeps/cbsg/af/run_af_pinned_fix.sh` | `sweeps/cbsg/af_ipd/run_af_ipd_pinned.sh` (post-fill hook checks, qualify rule) |
| 2ac1ab40fc47ef15... | `sweeps/cbsg/af/run_af_route_measure.sh` | `sweeps/cbsg/af_ipd/run_af_ipd_pinned.sh` (class-split stages) |
| 4b15b2fbdef86276... | `sweeps/cbsg/pin_dryrun/run_pin_dryrun.sh` | `sweeps/cbsg/af_ipd/run_pin_dryrun_af_ipd.sh` |
| cbff767615a0b206... | `sweeps/cbsg/af/pt_power_classes.tcl` | `sweeps/cbsg/af_ipd/pt_power_classes_af_ipd.tcl` (PT setup verbatim; AF-IPD classes) |
| 4b9628e64615ba6b... | `sweeps/cbsg/af/run_pt_power_classes.sh` | `sweeps/cbsg/af_ipd/run_pt_power_classes_af_ipd.sh` |
| 4052a431d120ae5e... | `sweeps/cbsg/af/power_classes.py` | `sweeps/cbsg/af_ipd/power_classes_af_ipd.py` |
| 89da35cba3c83a9b... | `sweeps/int_mode/bp/run_bp_int_energy.sh` | `sweeps/cbsg/af_ipd/run_af_ipd_int_energy.sh` (frozen copy; the original is being edited elsewhere) |
| 5b352505beab7993... | `sweeps/int_mode/bp/bp_int_energy_lib.sh` | `sweeps/cbsg/af_ipd/af_ipd_int_energy_lib.sh` (frozen copy) |
| 218a9e3d95e38e98... | `sweeps/int_mode/bp/bp_saif_int_audit.py` | `sweeps/cbsg/af_ipd/af_ipd_saif_int_audit.py` (AF edge groups) |
| 489e2eb470946c33... | `sweeps/int_mode/bp/bp_int_energy_row.py` | `sweeps/cbsg/af_ipd/af_ipd_int_energy_row.py` (u_rng) |
| e4e091a9b2965744... | `apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_postfill.tcl` | invoked read-only (pinned pass 2 PRE_PLACE_SCRIPT, post-fill hook) |
| 455afcaf7b81cf41... | `apr/scripts/cbsg/postfill_search_repair.tcl` | invoked read-only (through the hook) |
| 930268e038b9524d... | `apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl` | invoked read-only (pin plan, sourced by the postfill script) |
| 6cfc369e7a19dcc0... | `sweeps/pinned_pass2/run_basin_gate.sh` | invoked read-only (basin gate + pin proof) |
| adff51e6d9ad0894... | `sweeps/cbsg/routed_sdf_clock_audit.py` | invoked read-only (routed ICG CK->ECK audit) |
| cdbdbc3836f2e612... | `sweeps/cbsg/af/filler_drc_trace.py` | invoked read-only (post-filler DRC trace) |
| bc14192f63de8ecc... | `sweeps/repair_popcount_apr.sh` | invoked read-only if the qualify stage needs the targeted repair (hash before any edit) |
| c8be7a9cb328d331... | `sweeps/cbsg/pin_dryrun/innovus_mock.tcl` | invoked read-only (pin dry run) |
| fae4dcda53f98892... | `sweeps/cbsg/pin_dryrun/netlist_mockdb.py` | invoked read-only (pin dry run) |
| 36851587ca69a203... | `sweeps/validate_sc_power_saif.py` | invoked read-only (SAIF validation) |
| f0ce0f369c0ca950... | `sweeps/validate_pt_power_coverage.py` | invoked read-only (PT coverage audit) |

The full 64-hex-digit hashes are in `copied_from.sha256`.

## Open items

- **kA encoder remap (+1,976.1 um2 synthesized, +1,897.6 routed; +0.161 mW SC uniform).** With the INT bypass present,
  DC maps the unchanged encoders to full-adder trees: 133.8 um2 each, against 102.9 in AF; see
  [Synthesis](#synthesis-cbsg_af_ipd_20261005-2026-10-05). The route of record carries it.
  - Without it the route would be about 42,533 um2 (-3.2 % vs the CSA route) and the SC overhead over AF about
    +0.32 mW (+2.8 %) instead of +0.48 mW (+4.2 %).
  - Moving the OR into its own hierarchy does not recover it, and neither does relaxing the raw-port timing.
  - A fixed encoder-adder implementation, or a bottom-up encoder compile, would. Either changes the synthesis recipe,
    so it should be applied to AF too: **user decision**, still open.
- **Drain rail settle (1.45 ns, PT).** Inside the SDC (slack +1.00 ns) but after the negedge at which the inherited SC
  bench used to read it; in a PE row it eats 0.20 ns of the neighbour's `acc_in_west` slack. Upsize the column-7
  `acc_out` drivers or register the drain rail if a grid needs margin. See
  [Route and power](#route-and-power-2026-10-05).
- **`ring_q` fanout.** Not critical on this route (setup WNS +0.104 ns is elsewhere); `ring_q` drives the shift of all
  64 tiles and 1,536 doubling-mux selects. A duplicated `ring_q` per tile row is the obvious fix if a grid route needs it.
- **Timing of the A path.** `a_len_q`/phase/`a_binary_q` -> kA encoder -> thermometer (with the folded-in bypass OR)
  -> `a_bits_pipe` arrived at 1.22 ns post-synthesis (slack +1.25); the route closed at +0.104 ns overall.
- **PE grid.** The copied grid wrapper is PE-level. As in AF, a grid needs per-PE-row and per-PE-column AF edges whose
  `block_start` is aligned to the skewed operands. That is not addressed here. The runner's `grid` part is therefore
  a rename check of the IPD grid wrapper (evidence for the copied IPD lap wave), not evidence for the AF + INT
  integration on a grid; that needs a grid with the AF edges and the INT bypass.
- **`block_start` / `slice_start` in INT mode** are a contract rule, not hardware. Gating them with `int_mode` would
  cost 2 gates if a sequencer cannot guarantee it.
- **Not measured on the route:** gauss / relu INT distributions (the BP lap campaign measured uniform only, so the
  seven uniform points are the comparison set); the floating-pin final (`FLOATING_FINAL=1` of the bootstrap driver).

## Reproduce

```bash
bash sweeps/cbsg/af_ipd/run_rtl_checks.sh                  # copies ref units sc sctrace int intx switch grid power
PARTS="int switch" bash sweeps/cbsg/af_ipd/run_rtl_checks.sh
bash sweeps/cbsg/af_ipd/check_copies.sh                    # provenance only
bash sweeps/cbsg/af_ipd/run_dc_elab.sh                     # DC elaborate / check_design (AF-IPD, AF, IPD)
bash sweeps/cbsg/af_ipd/review_fix_ab.sh                   # cut-block monitor fix: pre-fix top vs fixed top
RUN_NAME=cbsg_af_ipd_20261005 RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF_IPD NTFY_CHNL=
bash sweeps/cbsg/af_ipd/run_syn_reports.sh                 # area classes + timing probes, AF-IPD vs AF / IPD / CSA -> build/cbsg/af_ipd/syn/
bash sweeps/cbsg/af_ipd/run_syn_gl_checks.sh               # unit / ideal-clock SDF GL -> build/cbsg/af_ipd/gl/cbsg_af_ipd_20261005/
bash sweeps/cbsg/af_ipd/syn_encoder_experiment.sh          # diagnostic DC compiles (encoder remap attribution) -> build/cbsg/af_ipd/syn/exp/
# route + power (2026-10-05), outputs build/power_char/cbsg_20261005/af_ipd/:
bash sweeps/cbsg/af_ipd/run_pin_dryrun_af_ipd.sh postfill  # tclsh pin-plan dry run on the netlist (INT-port audit included)
bash sweeps/cbsg/af_ipd/run_af_ipd_bootstrap.sh            # bootstrap route + uniform GL; audited SAIF = pass-2 seed
                                                           #   (strict audit fails on 4 SDFCOM_IWSBA: rerun with
                                                           #   AFIPD_GL_VALIDATOR_ARGS='--approve-annotated-interconnect' RETRY_FAILED=1,
                                                           #   rationale file in the stage directory)
AFIPD_GL_VALIDATOR_ARGS='--approve-annotated-interconnect' bash sweeps/cbsg/af_ipd/run_af_ipd_pinned.sh
                                                           # pinned pass 2 (post-fill hook), qualify (+targeted repair),
                                                           # basin gate, uniform / ladder GL + PT, class split, routed_func
MAX_JOBS=7 AFIPD_GL_VALIDATOR_ARGS='--approve-annotated-interconnect' bash sweeps/cbsg/af_ipd/run_af_ipd_int_energy.sh
                                                           # 7 INT points on the qualified route
python3 sweeps/cbsg/af_ipd/compare_af_ipd_route.py         # comparison.txt / .json / results.csv
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/af_ipd/report_af_ipd.py --doc doc/cbsg_variants.md
                                                           # doc/cbsg_variants.md section 7 (af_ipd blocks); also
                                                           #   build/power_char/cbsg_20261005/af_ipd/report/
# one run by hand (after run_rtl_checks.sh; simv in build/cbsg/af_ipd/build_sc or build_int):
#   build_sc/simv  +MODE=sc +CASES=<dir>[,...] [+INT_JUNK +SC_TRACE=f + any AF bench plusarg]
#   build_int/simv +MODE=int +BA=8 +BW=8 +L=1024 +MROWS=1 +NCOLS=8 [+JUNK +MODE_AT=n +LAP_RING_ONLY +PARK_CYC0 ...]
#   build_int/simv +MODE=switch +SWITCH=sc:<case dir>,int:<dir with bpt_cfg.txt>,... [+INT_JUNK +SW_GAP=n ...]
```
