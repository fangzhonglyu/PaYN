# Gated C-BSG

Traditional conditional bitstream generation: W's generator advances only on
A ones. Each A element (row, depth) owns a W index `j`; the A one in lane m of
a cycle takes W sample `j + #(A ones in lanes < m)`, and `j` advances by the
cycle's A ones. `j` is shared along the row; the W comparison against each
column's magnitude happens per tile (N_H·N_W·K·M comparators vs N_W·K·M for a
shared W stream).

The bitstream definitions are a compile-time choice, `STREAMS`
(`PAYN_GATED_STREAMS` in `SYN_DEFINES`):

| | `STREAMS=0` — PaYN original | `STREAMS=1` — emulator |
|---|---|---|
| A | legacy `sobol_bank` (MODE 0, `A_*` shifts, free-running across K-blocks) + golden-stride mask | `sobol_bank` MODE 1 ("q" Sobol words in sample order), restarted every K-block, column mask `bitrev((d_base+depth) mod 64)`, 7-bit grid |
| W sample i | original W bank, lane `i % M` of productive cycle `i / M`, golden-stride W mask | emulator `rB[d][i]`: "k" Sobol word i, the same column mask, 7-bit grid |
| operands | logical magnitude m as `m << 1` (8-bit) | thresholds `b = round(\|q\|·128/127)` for A and W |
| matches | `cosim_streaming.py` gated reference (built from `sc_kernel.py`) | the scmp_kernels emulator's C-BSG, bit-exact |

`payn_array_gated_cbsg` has `payn_array`'s ports, so benches take it via
`PAYN_ARRAY_DUT`. `rng_restart` marks each K-block start (assert with its load);
`stream_len` is the samples per block; `d_base` is the block's first column
(`STREAMS=1` only). The W index only advances on fresh slices (cycles where
`rng_en` advanced the A bank), so idle cycles between blocks are harmless.
There is no `u_w_rng`; W thresholds are generated inside `u_pe`.

Gating and the thermometer packing used by `payn_array`'s C-BSG build
(`A_ENCODER=1 A_CBSG=1`) give identical counts on the same streams — C-BSG
depends on A only through its number of ones. `STREAMS=1` therefore matches
that build and the emulator exactly; `STREAMS=0` differs from them only
because its streams differ.

```bash
# STREAMS=1 vs. emulator C-BSG goldens (tiled matmul sweep)
MODES=gated CASES_DIR=<cases> GOLDEN_DIR=<ut> GOLDEN_CBSG_DIR=<cbsg> \
  bash designs/payn/cosim/run_ut_sweep.sh

# STREAMS=0 streaming power bench + bit-exact check
SIM_SRCS=designs/payn/variants/gated_cbsg/payn_array_gated_cbsg.sv \
bash designs/payn/cosim/run_power_array.sh VCS_ARGS="-lca \
  +define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_gated_cbsg \
  +define+PAYN_GATED_CBSG+define+SC_K=8+define+SC_M=16+define+SC_NH=8 \
  +define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=48" GL= TARGET=

# synth/APR/power: bash sweeps/run_stream_mode_power.sh gated_orig gated_emu
```

Verified (RTL):
- `STREAMS=1`: the t9 C-BSG vectors at L = 128/64/43/16; the 240-case
  sweep (4 array configs × 10 shapes × 6 lengths) against emulator C-BSG
  goldens; streaming bench bit-exact.
- `STREAMS=0`: streaming bench bit-exact at K8/M16/8x8 T=128 and 64,
  K4/M8/4x4 T=64, K6/M4/3x5 T=32, K16/M2/2x2 T=16. At K8/M16/8x8 T=128 its
  NRMSE vs the exact matmul is 0.047, against 0.078 for the ungated original.
