# PaYN

Stochastic-computing (SC) GEMM accelerator, plus binary and unary systolic
baselines, with a self-contained synth / place-and-route / power-characterization
flow. PaYN is a **design repo**: it consumes the [ASTRAEA](../ASTRAEA) flow engine
(`make` targets, Tcl scripts, PDK setups) and depends on nothing in `SCArch`.

## Layout

```
designs/
  common/                 shared bench utils (clk_util, defines)
  payn/                   the SC accelerator (manual tile / PE / peripheral)
    inner_tile.sv           InnerTile — output-stationary MAC + row-serial drain
    inner_pe.sv             InnerPE / InnerPEFlat — the N_H×N_W tile array
    pe_peripheral.sv        sc_pe_peripheral — binary→stochastic edge streams
    sobol.sv                sobol_generator / sobol_bank — shared Sobol RNGs
    payn_array.sv           (Phase 1) integrated banks + peripheral + InnerPE top
    tb/                     functional testbenches
    power/                  SAIF power benches (output-checked)
    cosim/                  bit-exact array model (sc_kernel.py) + RTL cosim harness
  baselines/
    binary_parallel/        BP array_8 (+ asymmetric INT8 correction)
    binary_serial/          BS array_8
    unary_rate/             UR array_8 (Sobol rate coding)
    unary_temporal/         UT array_8 (temporal + Sobol)
syn/targets/TSMC22/         synthesis targets (parameterized)
apr/targets/TSMC22/         place-and-route targets
apr/scripts/                place_guides_sc_tiles.tcl
sweeps/                     power-characterization tooling (PT scripts, SAIF validators)
```

Every design keeps RTL at its top level; tests live in `tb/`, power benches in
`power/`.

## Prerequisites

- The ASTRAEA flow repo cloned next to this one (`../ASTRAEA`), or `ASTRAEA_FLOW=<path>`.
- EDA tools + PDK on the environment (VCS, DC, PrimeTime, Innovus; TSMC22 ARM kit).
  Load the standard modules before running the flow.

## Common commands

```bash
# Functional simulation (RTL). SC designs instantiate DesignWare DW02_tree, so
# they need the DesignWare sim library via USE_DW=1 (requires $SYNOPSYS):
make sim TB=designs/payn/tb/test_inner_pe.sv USE_DW=1
make sim TB=designs/payn/tb/test_peripheral.sv          # peripheral: no DW needed
make sim TB=designs/baselines/binary_parallel/tb/test_array_8_power_workload.sv

# Bit-exact array cosim (RTL vs the Python reference):
bash designs/payn/cosim/run_peripheral.sh

# Synthesis / APR / power (see syn/targets, apr/targets):
make synth TARGET=TSMC22/BP_ARRAY
make apr   TARGET=TSMC22/BP_ARRAY SYNTH_RUN=<run>
make power_apr TARGET=TSMC22/BP_ARRAY ...
```

Build artifacts land under `build/`, `syn/build/`, `apr/build/` (all git-ignored).
