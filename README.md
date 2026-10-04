# PaYN

Stochastic-computing (SC) GEMM accelerator, plus binary and unary systolic
baselines, with a self-contained synth / place-and-route / power-characterization
flow. PaYN is a **design repo**: it consumes the [ASTRAEA](../ASTRAEA) flow engine
(`make` targets, Tcl scripts, PDK setups) and depends on nothing in `SCArch`.

## Layout

```
designs/
  common/                 shared bench utils (clk_util, defines)
  payn/                   the SC accelerator: C-BSG, bit-exact with the
                          scmp_kernels emulator (SC_MULT_SCHEME=cbsg)
    inner_tile.sv           InnerTile — output-stationary MAC + row-serial drain
    inner_tile_comb.sv      combinational tile cone + flat GF22/ROC analysis top
    inner_pe.sv             InnerPE / InnerPEFlat — the N_H×N_W tile array with
                            W generators gated by A (per row/depth) and per-tile
                            W comparators
    pe_peripheral.sv        sc_pe_peripheral — A binary→rate-encoded streams
                            (emulator column mask, 7-bit grid)
    sobol.sv                sobol_bank — M consecutive Sobol words per cycle
    payn_array.sv           A bank + A peripheral + C-BSG InnerPE top
    tb/                     functional testbenches
    power/                  SAIF power bench (output-checked)
    cosim/                  emulator goldens + RTL comparison (see cosim/README.md)
  baselines/
    binary_parallel/        BP array_8 (+ asymmetric INT8 correction)
    binary_serial/          BS array_8
    binary_os/              BOS binary_os_array — output-stationary INT8 8x8 PE
                            array with the PaYN dataflow (stationary accumulator,
                            row-serial east drain), binary MACs instead of SC lanes
      binary_os_pe.sv         BinaryOSPE — one INT8 MAC + A/W hop regs + accumulator
      binary_os_array.sv      BinaryOSArray/Flat + binary_os_array synth top
    unary_rate/             UR array_8 (Sobol rate coding)
    unary_temporal/         UT array_8 (temporal + Sobol)
syn/targets/TSMC22/         synthesis targets (parameterized)
apr/targets/TSMC22/         place-and-route targets
apr/scripts/                place_guides_sc_tiles.tcl
roc_flow/configs/           PaYN-local configurations for sibling ROC_flow
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
make sim TB=designs/baselines/binary_parallel/tb/test_array_8_power_workload.sv

# Binary output-stationary array vs an independent golden matmul:
make sim TB=designs/baselines/binary_os/tb/test_binary_os_array.sv

# payn_array vs. the emulator's C-BSG vectors, bit-exact (needs ../gpu_aversion):
bash designs/payn/cosim/run_matmul.sh

# Dimension sweep vs. emulator goldens; streaming power bench (cosim/README.md):
CASES_DIR=<cases> GOLDEN_DIR=<goldens> bash designs/payn/cosim/run_sweep.sh
bash designs/payn/cosim/run_power_array.sh VCS_ARGS="-lca" GL= TARGET=

# PaYN area / power through synth -> apr -> GL SAIF -> power_apr:
bash sweeps/run_sc_power.sh

# Synthesis / APR / power (see syn/targets, apr/targets):
make synth TARGET=TSMC22/BP_ARRAY
make apr   TARGET=TSMC22/BP_ARRAY SYNTH_RUN=<run>
make power_apr TARGET=TSMC22/BP_ARRAY ...

# GF22 combinational inner-tile soft-error comparison (requires ../ROC_flow):
ROC_ANGLE=omni ROC_TRIALS=10000000 bash sweeps/run_roc_inner_tile.sh all
ROC_ANGLE=omni ROC_TRIALS=10000000 bash sweeps/run_roc_binary_mac.sh all
```

The GF22 extraction, matched binary reference, results, and caveats are in
[`doc/ROC_inner_tile.md`](doc/ROC_inner_tile.md).

Build artifacts land under `build/`, `syn/build/`, `apr/build/` (all git-ignored).
