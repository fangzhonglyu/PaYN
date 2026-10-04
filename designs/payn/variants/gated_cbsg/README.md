# Gated C-BSG with PaYN's original bitstream generation

Traditional conditional bitstream generation: W's generator advances only on
A ones. A and W use PaYN's original generators, unchanged.

| | |
|---|---|
| A | original `sobol_bank` (MODE 0, `A_*` direction set / digital shifts, free-running across K-blocks) + `sc_pe_peripheral` golden-stride mask |
| W | original W stream (`W_*` direction set / shifts, W salt), replayed per A element: the i-th A one of a K-block (sample order) gets W sample i = lane `i % M` of productive cycle `i / M` |
| sharing | W index `j` per A element (row, depth), shared along the row; W comparison against each column's magnitude per tile (N_H·N_W·K·M comparators vs N_W·K·M for a shared W stream) |

`payn_array_gated_cbsg` has `payn_array`'s ports, so benches take it via
`PAYN_ARRAY_DUT`. `rng_restart` marks each K-block start (assert with its load),
`stream_len` is the samples per block, `d_base` is unused. There is no
`u_w_rng`; W thresholds are generated inside `u_pe`.

This is **not** bit-exact with the scmp_kernels emulator, whose C-BSG uses its
own A/W streams (Sobol "q"/"k" seeds, bitrev column masks). It is checked
bit-exact against `cosim_streaming.py`'s gated reference, built from
`sc_kernel.py`'s original generator definitions.

```bash
# RTL: streaming power bench + bit-exact check
SIM_SRCS=designs/payn/variants/gated_cbsg/payn_array_gated_cbsg.sv \
bash designs/payn/cosim/run_power_array.sh VCS_ARGS="-lca \
  +define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_gated_cbsg \
  +define+PAYN_GATED_CBSG+define+SC_K=8+define+SC_M=16+define+SC_NH=8 \
  +define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=48" GL= TARGET=

# synth/APR/power: bash sweeps/run_stream_mode_power.sh gated
```

Verified (RTL): K8/M16/8x8 at T=128 and 64, K4/M8/4x4 T=64, K6/M4/3x5 T=32,
K16/M2/2x2 T=16 -- drain bit-exact. At K8/M16/8x8 T=128 its NRMSE vs the exact
matmul is 0.047, against 0.078 for the ungated original on the same workload.
