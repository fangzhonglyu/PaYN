# PaYN — Experiment Index

Handoff index for the PaYN SC accelerator + binary/unary baselines. For each
design: a **map** (where the RTL / TB / power bench / target live) followed by
its **experiments**, each with a one-line repro.  The concise current signoff
summary is in `doc/results.md`; historical detail remains here and in the
design-specific notes.

## Entry points

- **Flow**: `Makefile` includes `../ASTRAEA/Makefile` → `make {synth,apr,sim,power_apr} TARGET=<tech>/<name>`.
- **Env**: the `sweeps/*.sh` drivers `module load` the tools themselves. For a bare `make`, load the EDA modules and `export USE_DW=1` first.
- **Main driver**: `sweeps/run_power_char.sh <TARGET...>` runs synth → APR → routed-SDF GL sim (timing checks ON) → SAIF validate → PrimeTime-PX, appending to `build/power_char/results.csv`.
- **Reports**: `apr/build/TSMC22/<TARGET>/<run>/reports/` (`power.rpt`, `power_hier.rpt`, timing).

---

## Binary-parallel (BP) — 8×8 INT8 systolic

`designs/baselines/binary_parallel/`

| role | file |
|---|---|
| design | `array_8.sv` · native `array_8_native.sv` (`int7/int6`) · asym `array_8_asym_corr_v2.sv` |
| functional TB | `tb/test_array_8_power_workload.sv` (asym: `tb/tb_asym_peripheral_v2.sv`) |
| power bench | `power/power_array_8.sv`; asym: `power/power_array_8_asym_corr_v2.sv` (both per-cycle golden checked) |
| targets | `BP_ARRAY`, `BP_ARRAY_INT7`, `BP_ARRAY_INT6`, `BP_ARRAY_ASYM` |

**INT8 baseline** — 10.60 mW

```
bash sweeps/run_power_char.sh BP_ARRAY
```

**Native INT7 / INT6 designs** — 9.53 / 8.16 mW (narrower hardware)

```
for W in 7 6; do
  make synth TARGET=TSMC22/BP_ARRAY_INT$W
  make apr   TARGET=TSMC22/BP_ARRAY_INT$W SYNTH_RUN=<synth_run>
  make sim   GL=apr TARGET=TSMC22/BP_ARRAY_INT$W RUN=<apr_run> USE_DW=1 \
             TB=designs/baselines/binary_parallel/power/power_array_8.sv \
             VCS_ARGS="+define+BP_IWIDTH=$W +define+BP_GL_DUT=array_8_int$W +define+STIM_CYCLES_N=4096"
  make power_apr TARGET=TSMC22/BP_ARRAY_INT$W RUN=<apr_run> SAIF=<dut.saif> SAIF_STRIP_PATH=Top/dut
done
```

**BP + asymmetric zero-point correction** — 11.75 mW / 0.459 pJ/MAC (+11% vs plain BP; separate design, end-to-end output checked)

```
make synth TARGET=TSMC22/BP_ARRAY_ASYM
make apr   TARGET=TSMC22/BP_ARRAY_ASYM SYNTH_RUN=<synth_run>
make sim   GL=apr TARGET=TSMC22/BP_ARRAY_ASYM RUN=<apr_run> USE_DW=1 \
           TB=designs/baselines/binary_parallel/power/power_array_8_asym_corr_v2.sv
make power_apr TARGET=TSMC22/BP_ARRAY_ASYM RUN=<apr_run> SAIF=<dut.saif> SAIF_STRIP_PATH=Top/dut
```

**INT8 HW fed INT8 / INT7 / INT6 inputs** (signed & all-positive) — input precision on the *fixed* INT8 netlist. Signed ≈ flat (10.60→10.42 mW); all-positive is the lever (INT6-allpos 7.75 mW, −27%).

```
bash sweeps/run_bp_input_power.sh     # GL=apr + PT-PX, 6 regimes -> build/power_char/bp_input_regimes.csv
```
(RTL functional variants: `bash sweeps/run_bp_regimes.sh`.)

---

## Binary-serial (BS) — 8×8 bit-serial

`designs/baselines/binary_serial/`

| role | file |
|---|---|
| design | `array_8.sv` |
| functional TB | `tb/test_array_8.sv` |
| power bench | `power/power_array_8.sv` |
| target | `BS_ARRAY` |

**Power** — 5.95 mW

```
bash sweeps/run_power_char.sh BS_ARRAY
```

---

## Binary output-stationary (BOS) — 8×8 INT8, PaYN dataflow

`designs/baselines/binary_os/`

| role | file |
|---|---|
| design | `binary_os_pe.sv` (`BinaryOSPE`, one INT8 MAC + 2 hop regs + accumulator) · `binary_os_array.sv` (`BinaryOSArray`/`Flat` + `binary_os_array` synth top) · asym `binary_os_asym.sv` |
| functional TB | `tb/test_binary_os_array.sv` · asym `tb/test_binary_os_asym.sv` (both independent golden matmuls, not structural mirrors) |
| power bench | `power/power_binary_os_array.sv` (per-cycle output check + full drained-matrix check) · asym `power/power_binary_os_array_asym.sv` (drain inside the SAIF window) |
| targets | `BOS_ARRAY`, `BOS_ARRAY_ASYM` |
| breakdown | `sweeps/pt_binary_os_power.tcl` (emits the `bin_*` keys `pe_taxonomy.py` already reads) |

The point of this design is to be a **dataflow-matched binary control for PaYN**: same
stationary accumulator, same `mac_en`/`shift_in` contract, same row-serial east drain, same
OW24, same 64 MAC/cycle, with the K-lane stochastic popcount replaced by one INT8
multiplier. BP differs from PaYN in *both* arithmetic and dataflow; BOS differs in
arithmetic only.

Structurally it is a true systolic mesh: every PE owns its A and W hop registers, A moves
west→east, W moves north→south, and no operand net is shared by more than two PEs. The
caller must therefore apply the systolic skew — A slice t into row h at cycle t+h, W slice t
into column v at cycle t+v, meeting at PE (h,v) at t+h+v+1 — and zero-pad outside the slice
window. `mac_en`/`shift_in` are the one array-wide signal pair, and have to be: a row drains
as a lockstep shift register, so pipelining the drain enable would let PE v-1 overwrite its
accumulator one cycle before PE v reads it, losing one value per hop.

One PE is exactly one INT8 MAC: an 8-bit A hop register, an 8-bit W hop register, one
multiplier, and the 24-bit stationary accumulator — 40 flops, confirmed in the routed
netlist (64 PEs x 40 = 2,560, +1 for the array ICG = 2,561). That is what
throughput-matches PaYN: an `InnerTile` carries K=8 spatial lanes but needs T/M=8 cycles
to retire that K=8 dot product, so it too averages one MAC/cycle/accumulator.

**Power** — 10.56 mW / 0.412 pJ/MAC, routed area 15,797 µm², setup WNS +1.109 ns
(HPK/multibit flow: `run_power_char.sh` exports `TSMC22_HPK=1 APR_MULTIBIT_FLOP_OPT=1
APR_OPT_POWER=1`; the gate sim only links the HPK Verilog library when `TSMC22_HPK=1`,
so any script driving `make sim GL=apr` on these netlists must export it too)

```
bash sweeps/run_power_char.sh BOS_ARRAY
```

**Asymmetric variant** (`binary_os_asym.sv`, target `BOS_ARRAY_ASYM`) — 11.99 mW,
19,250 µm², setup WNS **+0.030 ns**.  Correction costs +10.25% power at the identical
workload and flow (reduction depth D=64; BP: +10.8%); see `doc/results.md` for why the shared-`za` term did
not make it cheaper.  The corrected output is combinational to the port and is the
critical path — register it before signoff.

```
bash sweeps/run_power_char.sh BOS_ARRAY_ASYM
make sim TOP=Top TB=designs/baselines/binary_os/tb/test_binary_os_asym.sv   # golden asym matmul
```

**Drain amortization** — `BOS_DRAIN_PERIOD` is the GEMM reduction depth D (the dot-product
length each PE accumulates before the array must be drained); `BOS_DRAIN_PERIOD=0`
is the pure-MAC point (PaYN methodology: drain taken after `$toggle_stop`).

```
bash sweeps/run_bos_drain_sweep.sh    # -> build/power_char/bos_drain_sweep.csv
```

**Activity-matched BP control** — BP's accepted point holds one weight set stationary for the
whole 4,096-cycle window; an output-stationary array cannot, so `BP_STREAM_WEIGHTS` reloads
the weight column every cycle to isolate dataflow from operand reuse.

```
make sim GL=apr TARGET=TSMC22/BP_ARRAY RUN=<apr_run> USE_DW=1 \
         TB=designs/baselines/binary_parallel/power/power_array_8.sv \
         VCS_ARGS="+define+BP_STREAM_WEIGHTS +define+STIM_CYCLES_N=4096"
make power_apr TARGET=TSMC22/BP_ARRAY RUN=<apr_run> SAIF=<dut.saif> SAIF_STRIP_PATH=Top/dut
```

---

## Unary-rate (UR) / Unary-temporal (UT) — 8×8 stochastic streams

`designs/baselines/unary_{rate,temporal}/`

| role | file |
|---|---|
| design | `array_8.sv` + `sobol8.sv` |
| functional TB | `tb/test_array_8.sv` |
| power bench | `power/power_array_8.sv` |
| targets | `UR_ARRAY`, `UT_ARRAY` |

**Power vs stream length** RATE_LEN∈{64,128,256} — UR 2.84/2.83/2.83 mW, UT 2.48/2.03/1.92 mW

```
bash sweeps/run_power_char.sh UR_ARRAY UT_ARRAY
```

---

## SC accelerator (PaYN) — `payn_array`, K6·M16·9×9·OW24

`designs/payn/`

| role | file |
|---|---|
| design | `payn_array.sv` = `sobol.sv`×2 + `pe_peripheral.sv` + `inner_pe.sv` (`inner_tile.sv`) |
| standalone PE top | `sc_inner_pe_manual_k6m16n9_ow24` (in `inner_pe.sv`) |
| functional TB | `tb/test_payn_array.sv` (bit-exact vs cosim); also `test_inner_pe/peripheral/sobol.sv` |
| power benches | `power/power_payn_array.sv` (array), `power/power_inner_pe.sv` (PE, real Sobol-driven); both run 256 batches by default |
| bit-exact model | `cosim/sc_kernel.py`; fixed-input checker `cosim/cosim_array.py`; long-running power checker `cosim/cosim_streaming.py` |
| targets | `PAYN_SC` (array), `SC_INNER_PE` (standalone PE) |

**Array power vs T∈{64,128,256}** — 23.69 / 23.71 / 23.57 mW

These headline sweep values predate the corrected workload schedule.  The
current power bench holds binary magnitude and sign for exactly `T/M` clocks,
advances Sobol and generates a fresh `M`-bit slice every clock, then reloads the
next batch without a compute bubble.  `SC_BATCHES` controls run length and
defaults to 256.  The accepted pending-bit K8/M16/8×8/T128 checkpoint has been
regenerated with this schedule using the intended 7-bit unsigned magnitude plus
separate sign distribution.  Each logical magnitude `m` is encoded as `m << 1`
for the existing 8-bit comparator/Sobol hardware, preserving `m/128`
probability.  The accepted workload-aware reroute measures
**18.17200 mW / 0.70984 pJ/MAC** (route `k8m16n8_lw9_distguide_spp_fixed`, setup WNS
+0.499 ns, hold +0.031 ns; 2.0% below the previously accepted `..._wlpwr` route at
18.53117 mW / 0.72387 pJ/MAC, from the same synthesis netlist and the same
2,583-multibit / 231-single-bit flop mix).  This is a
workload-correct result on the existing 8-bit netlist, not yet the result of
physically narrowing the magnitude registers, comparators, and Sobol words.
The prior guides-only route remains preserved at
18.67898 mW / 0.729648 pJ/MAC.
The older shape/T sweep still needs regeneration before its headline values
are treated as final intended-workload power.

```
bash sweeps/run_power_char.sh PAYN_SC          # power
bash designs/payn/cosim/run_power_array.sh     # 256-batch bit-exact drain check
```

**A6P5/SVT library experiment** — separate targets keep the accepted A7/SVT
checkpoint untouched.  PaYN uses the SCArch X0P5 ADDF/AND2 mapping; the binary
INT8 control uses the same A6P5/SVT C30 library without SC-specific mapping
constraints.

```sh
make synth TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED_A6P5_SVT \
           RUN_NAME=a6p5_svt_k8m16n8_lw9
make synth TARGET=TSMC22/BP_ARRAY_A6P5_SVT \
           RUN_NAME=a6p5_svt_int8

SYNTH_RUN=a6p5_svt_k8m16n8_lw9 \
RUN_NAME=a6p5_svt_k8m16n8_lw9_distguide \
SC_DISTRIBUTION_GUIDES=1 SC_NH=8 SC_NW=8 \
make apr TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED_A6P5_SVT

# K8.M16 symmetric-array synthesis screen (N=4,6,10,12,14).
bash sweeps/run_a6p5_n_syn_screen.sh 4 6 10 12 14

# Best fully power-qualified A6P5 route.
PAYN_A6P5_N=10 \
SYNTH_RUN=a6p5_svt_k8m16n10_lw9 \
RUN_NAME=a6p5_svt_k8m16n10_lw9_distguide \
SC_DISTRIBUTION_GUIDES=1 SC_NH=10 SC_NW=10 \
make apr TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED_A6P5_SVT

SYNTH_RUN=a6p5_svt_int8 RUN_NAME=a6p5_svt_int8 \
make apr TARGET=TSMC22/BP_ARRAY_A6P5_SVT
```

Matched synthesis power is 6.9159 mW for PaYN and 4.6367 mW for binary, 13.98%
and 8.76% below their A7/SVT controls.  The guided 8×8 PaYN analysis route
measures 17.18954 mW / 0.671466 pJ/MAC.  The fully qualified 10×10 route
improves this to 25.64424 mW / 0.641106 pJ/MAC by amortizing the fixed
peripheral and Sobol energy, but retains four geometry DRCs and 34 antenna
violations.  The 12×12 route closes STA and its zero-delay netlist passes, but
its max-SDF run misses high-segment updates; its SAIF is rejected.

The N=10 placement-QoR controls stop after the normal pre-CTS optimization via
`apr/scripts/stop_after_place.tcl`.  Their retained run names are
`a6p5_svt_k8m16n10_lw9_unguided_placeonly`,
`a6p5_svt_k8m16n10_lw9_flat_unguided_placeonly`, and
`a6p5_svt_k8m16n10_lw9_flat_distguide_placeonly`.  The matched hierarchical
guided placement is the `place.enc` checkpoint inside the full N=10 route.
See [`A6P5_results.md`](A6P5_results.md) for estimated wire, overflow, density,
and hotspot results.

The binary analysis route measures 9.60705 mW / 0.375276 pJ/MAC and passes
4,097 routed output checks; setup, hold, connectivity, and antenna are clean,
with three local VIA1 cut-spacing DRCs remaining.  None of the A6P5 analysis
routes replaces its accepted clean A7 checkpoint.

**Accepted-route power versus T/reuse** — reuses the pending-bit LOW_W=9
checkpoint, keeps 3,072 productive clocks per point, and runs max-SDF cosim,
SAIF validation, and PT-PX for T=32/48/64/96/128.  No synthesis or APR is
performed, and per-T lightweight report views preserve the accepted reports.

```sh
bash sweeps/run_pending_t_reuse_power.sh
# -> build/power_char/pending_t_reuse/results.csv
```

**Internal breakdown** — compute PE 90% / peripheral 5% / Sobol 4%

```
grep -iE "u_pe|u_peripheral|u_.*rng" apr/build/TSMC22/PAYN_SC/<run>/reports/power_hier.rpt
```

**Synth vs APR (PnR/wiring inflation)** — SC PE 6.91 → 21.2 mW (3.8×), APR 54% net-switching

```
make sim GL=syn TARGET=TSMC22/SC_INNER_PE RUN=<synth_run> USE_DW=1 \
         TB=designs/payn/power/power_inner_pe.sv \
         VCS_ARGS="+delay_mode_unit +notimingcheck +define+SC_T=128"
make power TARGET=TSMC22/SC_INNER_PE RUN=<synth_run> SAIF=<dut.saif> SAIF_STRIP_PATH=Top/dut
```

**Tile-config sweep** — 18 configs (K∈{4,6,8} × M∈{8,16} × N∈{2,4,8}), each synth+APR+GL, cosim-verified. pJ/MAC 0.78 (8·16·8) → 2.26 (4·8·2); PnR inflation 1.7×→2.7× with size (the wiring limiter). `payn_array` shape is `` `ifndef ``-driven so one target sweeps all shapes.

```
bash sweeps/run_sc_tile_sweep.sh      # synth→APR→GL→PT-PX per config (MAX-wide), -> build/power_char/sc_sweep.csv
bash sweeps/run_sc_tile_synpwr.sh     # unit-delay synth pJ/MAC per config    -> build/power_char/sc_sweep_synpwr.csv
```

**Wire-capacitance optimization** — row/column distribution guides are the
accepted recipe: versus baseline they reduce routed wire 6.9%, total net
capacitance 5.0%, and current-workload power 4.62%
(21.62573→20.62757 mW), while closing timing.  An explicit two-level A/W tree
reduces root fanout 8→5 and combined root switching 36% relative to the guides,
but branch overhead raises whole-chip power to 21.61643 mW and adds 1.4% area.
Tile-only guides and global `MAX_FANOUT=4` remain rejected.
Full analysis is in [`doc/SC_wire_optimization.md`](SC_wire_optimization.md).

```sh
bash sweeps/run_sc_wire_opts.sh       # -> build/power_char/wire_opts/sc_wire_opts.csv
```

**Rejected PaYN architecture experiments** — the repository previously kept
separate RTL and targets for DBI, direct/centered retirement, compensated,
fused, recurrent-CSA, block-retired, drain-isolated, native/projected 7-bit,
explicit distribution-tree, grouped-heap, and registered-delta variants.
None beat the pending-bit `LOW_W=9` implementation at its applicable power
gate.  Their implementations and reproduction targets were removed to keep
the active design surface small; the compact measurements and rejection
reasons remain in [`results.md`](results.md).

**GF22 combinational inner-tile soft errors** — the exact K6/M16/OW24 tile
arithmetic cone and a signed binary INT8 MAC were rebuilt using only cells with
current ROC sensitive-region characterization, routed at 1 ns, and checked with
routed SDF.  In matched 10M-particle omnidirectional proton campaigns, PaYN and
binary produced 193 and 182 observable errors (`1.93e-5` and `1.82e-5` per
incident particle).  After physical area normalization, PaYN's effective error
cross-section is 2.13x per evaluation and 2.84x per equivalent MAC at T=128.
Vectorless routed power is 0.263 mW versus 0.123 mW; workload activity remains
to be measured.  Full methodology and caveats are in
[`doc/ROC_inner_tile.md`](ROC_inner_tile.md).

```sh
ROC_ANGLE=omni ROC_TRIALS=10000000 bash sweeps/run_roc_inner_tile.sh all
ROC_ANGLE=omni ROC_TRIALS=10000000 bash sweeps/run_roc_binary_mac.sh all
```

---

## Cross-comparison

**SC PE vs BP, pJ/MAC** (SC ÷ K·M·N²/T = 60.75; BP ÷ 64) — **synth 1.45×, APR 2.11×**; the gap is PnR wire cap on the M-wide buses. Uses the SC and BP numbers above.

**SCArch reproduction (hvt/sc6.5)** — ⏳ planned; re-target BP + SC with `TSMC22_LIB_FLAVORS=hvt_c30 TSMC22_CELL_TIER=sc6p5mcpp140z`.

---

## Methodology notes

- **MAC/cyc**: SC = `K·M·N_H·N_W/T`; BP = 64; BS = 8; UR/UT = 64/RATE_LEN.
- **Sim invariants**: negedge input driving (golden/DUT sample alignment); SC SAIF opens after a SETTLE window (resetless bit-pipe startup); validators (`sweeps/validate_*_saif.py`) reject persistent-X on architectural outputs.
- **Synth-level GL power**: use `+delay_mode_unit +notimingcheck` — the pre-CTS clock-gating ICG races in zero/path-delay sim (X or wrong drain); APR (post-CTS) is the signoff target and sims clean with timing checks ON.
