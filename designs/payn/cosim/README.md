# payn_array verification against the scmp_kernels emulator (C-BSG)

`payn_array` implements the emulator's C-BSG multiplication bit-exactly: A is
rate-encoded from the emulator's Sobol "q" words, and W's generator is gated by
A (the i-th A one of a K-block meets W sample `rB[d][i]`). Every check below
compares integer accumulators bit-for-bit.

| file | role |
|---|---|
| `emu_golden.py` | golden accumulators from the production `scmp_kernels` tables + tiled Triton kernel (`SC_MULT_SCHEME=cbsg`); GPU, or CPU via the Triton interpreter. `--check` first reproduces a case's `out_L*.mem`. |
| `gen_cases.py` | int8 operand cases of assorted shapes and value distributions |
| `run_matmul.sh` | `tb/test_payn_array.sv` vs. the t9 C-BSG vectors (`../gpu_aversion/t9_sc_matmul`) at L = 128/64/43/16 |
| `run_sweep.sh` | array configs × cases × lengths vs. `emu_golden.py` goldens |
| `run_power_array.sh` | `power/power_payn_array.sv` streaming power bench + `cosim_streaming.py` |
| `cosim_streaming.py` | bit-exact check of the power-bench drain, written from the emulator's definitions |

```bash
module load vcs/2023.12-SP2-1 synopsys-synth/2023.12-SP5

# t9 vectors
bash designs/payn/cosim/run_matmul.sh

# dimension sweep (goldens: PYTHONPATH=<scmp_kernels>)
python designs/payn/cosim/gen_cases.py --out cases
for c in cases/*/; do python designs/payn/cosim/emu_golden.py --case $c \
    --lengths 128,100,64,43,16,1 --out goldens/$(basename $c); done
CASES_DIR=cases GOLDEN_DIR=goldens bash designs/payn/cosim/run_sweep.sh

# streaming power bench (RTL; SV-SAIF needs -lca)
bash designs/payn/cosim/run_power_array.sh VCS_ARGS="-lca +define+SC_BATCHES=96" GL= TARGET=
```
