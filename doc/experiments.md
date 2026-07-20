# PaYN — Experiment Index

Handoff index for the PaYN SC accelerator + binary/unary baselines. For each design:
a **map** (where the RTL / TB / power bench / target live) followed by its **experiments**,
each with a one-line repro. Numbers are headline results; full tables in `doc/results.md`.

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
| design | `array_8.sv` (+ `array_8_native.sv` → `array_8_int7/int6`) |
| functional TB | `tb/test_array_8_power_workload.sv` |
| power bench | `power/power_array_8.sv` (per-cycle check vs in-TB systolic golden) |
| targets | `BP_ARRAY`, `BP_ARRAY_INT7`, `BP_ARRAY_INT6` |

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

**INT8 HW fed INT8 / INT7 / INT6 inputs** (signed & all-positive) — input precision on the *fixed* INT8 netlist

```
bash sweeps/run_bp_regimes.sh                                          # RTL functional
EXTRA="GL=apr TARGET=TSMC22/BP_ARRAY RUN=<apr_run>" bash sweeps/run_bp_regimes.sh   # gate power
```

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
| power benches | `power/power_payn_array.sv` (array), `power/power_inner_pe.sv` (PE, real Sobol-driven) |
| bit-exact model | `cosim/sc_kernel.py` + checker `cosim/cosim_array.py` |
| targets | `PAYN_SC` (array), `SC_INNER_PE` (standalone PE) |

**Array power vs T∈{64,128,256}** — 23.69 / 23.71 / 23.57 mW

```
bash sweeps/run_power_char.sh PAYN_SC          # power
bash designs/payn/cosim/run_power_array.sh     # bit-exact drain check
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

**Tile-config sweep** M∈{8,16} × N∈{4,8,12} — ⏳ planned (needs param mechanism: define-driven defaults on `payn_array`, or wrapper tops).

---

## Cross-comparison

**SC PE vs BP, pJ/MAC** (SC ÷ K·M·N²/T = 60.75; BP ÷ 64) — **synth 1.45×, APR 2.11×**; the gap is PnR wire cap on the M-wide buses. Uses the SC and BP numbers above.

**SCArch reproduction (hvt/sc6.5)** — ⏳ planned; re-target BP + SC with `TSMC22_LIB_FLAVORS=hvt_c30 TSMC22_CELL_TIER=sc6p5mcpp140z`.

---

## Methodology notes

- **MAC/cyc**: SC = `K·M·N_H·N_W/T`; BP = 64; BS = 8; UR/UT = 64/RATE_LEN.
- **Sim invariants**: negedge input driving (golden/DUT sample alignment); SC SAIF opens after a SETTLE window (resetless bit-pipe startup); validators (`sweeps/validate_*_saif.py`) reject persistent-X on architectural outputs.
- **Synth-level GL power**: use `+delay_mode_unit +notimingcheck` — the pre-CTS clock-gating ICG races in zero/path-delay sim (X or wrong drain); APR (post-CTS) is the signoff target and sims clean with timing checks ON.
