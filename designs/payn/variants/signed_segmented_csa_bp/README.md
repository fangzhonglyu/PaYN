# Carry-save array with a bit-plane INT mode (`signed_segmented_csa_bp`)

The [`signed_segmented_csa`](../signed_segmented_csa/README.md) SC array plus an exact
integer mode. The tile and the CSA PE core are unchanged.

In INT mode every AND position carries one real 1-bit product. Position `m` of
lane `k` holds reduction element `x = 128*b + 16*k + m`. Tile row `h` gets bit
`h` of the activation, and weight bits arrive one pass per bit, MSB pass first:

    bits[k][m] = a_h[x] & w_q[x]      (all 128 positions weigh 2^(h+q))
    sign       = (h is the top bit) XOR (q is the top bit), through the existing sign path

Between passes every accumulator is doubled by one lap around its PE's own
drain chain, with a `<<1` at the PE west input. After the last pass, an
east-edge combiner forms `out = sum_h 2^h * tile(h)`. INT8 is 64 one-bit
products per MAC, 2 MAC/tile-cycle, against SC T=128's 1. W4A8 runs at 4 and
INT4 at 8 (INT4 uses two 4-row groups).

The design study and the rejected alternatives are in
[`doc/INT_mode_on_PaYN.md`](../../../../doc/INT_mode_on_PaYN.md).

## Hardware added

| block | file | what | synthesized um2 |
|---|---|---|---:|
| edge bypass | `pe_peripheral_bp.sv` | `bits = cmp \| (raw & int_mode_q)` on all 2,048 operand bits (AO21); dedicated `a_raw_in`/`w_raw_in` ports | +1,244 |
| doubling ring | `inner_pe_signed_segmented_csa_bp.sv` | registered `ring_q` steers the west acc input to `acc_out_east << 1`; the core keeps the name `u_pe/u_array_core` | +138 |
| combiner | `bp_combiner.sv` | capture register, two 4-row half-trees, output register and valid | +681 |
| top glue | `payn_array_signed_segmented_csa_bp.sv` | registered `int_mode`, MAC guard, ring gate, capture | +5.5 |

Total synthesis area is 45,529.7 um2 versus 43,455.0 for CSA (+4.77%), with
worst slack +0.93 ns, the same as CSA.

**Port contract** (full text in the top header):
- `int_mode` is registered, so raise it one edge before the first raw capture.
- INT-mode loads carry zero magnitudes, with a zero-load on INT entry.
- Ring laps assert `shift_in` on lap edges, with `ring_in` one edge ahead.
- A MAC guard drops MACs for two edges after any `int_mode` change.
- With `int_mode=0`, the raw inputs, `ring_in` and `int_prec` have no effect.
- Range: exact mod 2^24 per tile. INT8 L <= 65,535 per output block; W4A8 and
  INT4 up to 1,048,575.

## Verification

- `sweeps/run_csa_bp_rtl_checks.sh` (RTL):
  - SC array and streaming cosim, bit-exact and identical to the CSA top,
    including random junk on every INT input while `int_mode=0`;
  - 35 INT8/W4A8/INT4 cases (extremes, ReLU, multi-block, back-to-back),
    bit-exact against numpy, plus negative controls.
- An independent adversarial harness (49 scenarios, `sweeps/int_mode/bp/verify/`)
  and an SC-isolation review.
- Post-synthesis functional GL: `sweeps/run_csa_bp_syn_gl_checks.sh`.

## Routed results (2026-10-04)

**Placement basin.** The first routed pass 2 (floating IO pins,
`csa_bp_20261003b_distguide_spp_fixed`) fell into a "row-collapsed" placement
basin and measured 20.74 mW in SC mode. The unchanged CSA netlist's own pass 1
landed in the same basin, at 20.80 mW. Root cause: `build/sc_power_regression/README.md`.

**Like-for-like comparison.** Pass 2 was re-run for both designs with the same
grid-matched fixed IO pins (`apr/scripts/place_pins_and_guides_sc.tcl`,
`sweeps/run_pinned_pass2.sh`). Both held the grid basin. Evidence:
`build/power_char/pinned_pass2_20261004/`.

| SC mode, T=128 | CSA (pinned) | BP (pinned) | delta |
|---|---:|---:|---:|
| routed area (um2) | 43,916.5 | 46,130.5 | +5.04% |
| 4x4 composite area (um2) | 521,100 | 531,415 | +1.98% |
| power (mW) | 15.726 | 16.491 | +0.76 (+4.9%) |
| pJ/MAC | 0.6143 | 0.6442 | +4.9% |
| GMAC/s/mm2, 1 PE / 4x4 | 582.9 / 786.0 | 554.9 / 770.8 | -4.8% / -1.9% |
| setup / hold WNS (ns) | +0.116 / +0.166 | +0.061 / +0.140 | |

An independent audit splits the +0.76 mW into about 0.2 mW of bypass hardware
and about 0.5 mW of tile glitching. The tile part comes from a larger a/w
operand skew in BP layouts (37 vs 20 ps): it is a layout effect, untested
beyond one sample per arm. Same-netlist layout noise is about +-0.3 mW.

**INT mode, measured on the routed BP netlist.** Real ports, max-SDF GL, all 45
points bit-exact, PT-PX. Uniform data:

| precision | MAC/cycle/PE | pJ/MAC peak (1 PE / 4x4) | pJ/MAC long GEMM L=4096 (1 PE) | GMAC/s/mm2 peak (1 PE / 4x4) | dedicated binary 8x8 array |
|---|---:|---:|---:|---:|---|
| INT8 | 128 | 0.349 / 0.338 | 0.380 | 1,110 / 1,542 | 1,621 GMAC/s/mm2, 0.412 pJ/MAC (older flow) |
| W4A8 | 256 | 0.175 / 0.169 | 0.191 | 2,220 / 3,083 | - |
| INT4 | 512 | 0.088 / 0.085 | 0.095 | 4,440 / 6,166 | 2,491 GMAC/s/mm2, 0.155 pJ/MAC |

Post-ReLU activations: INT8 0.215 and INT4 0.046 pJ/MAC at peak.

At L=4096 on a 4x4, ring laps, skew and drain cut INT8 to about 1,130 GMAC/s/mm2
(1.46 MAC/tile-cycle). Operand delivery and SRAM energy are excluded, as they
are for the binary arrays. INT needs 4 bits/MAC into a 4x4 (INT8), against 2
for the binary array.

Data: `build/power_char/int_mode_energy_20261003/bp/csa_bp_20261003b_distguide_spp_pins/`
(`results.csv`, `composed_vs_L.csv`, `routed_summary.txt` one level up). The
floating-pin layout's INT results are kept beside it for reference; they are
1.28-1.39x higher.

**Exceptions**, documented beside each run:
1. **Targeted checkpoint repair:** one M6 MINCUT on the pinned BP route; one
   MINCUT and one antenna sink on the pinned CSA control.
2. **GL validator approvals for BP:**
   - `--approve-annotated-interconnect`: 4 SDFCOM_IWSBA on the `int_out[60:63]`
     sign-extension alias.
   - `--approve-negative-iopath-clamp-ps 12`: 3 SDFCOM_NDI on one AOI211 COND
     arc, -1 ps at the max corner on the pinned route. The 12 ps bound was set
     for 26 clamps of up to -11 ps on the floating-pin route.

   CSA needs no approvals.
3. **Pass-2 driver deviation:** the pinned pass 2 sets `SC_DISTRIBUTION_GUIDES=0`
   and sources the unchanged guide script from the pin script, because the
   target files override `PRE_PLACE_SCRIPT`.

## Reproduce

```bash
bash sweeps/run_csa_bp_rtl_checks.sh
RUN_NAME=csa_bp_20261003b RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/PAYN_SC_CSA_BP NTFY_CHNL=
BP_SYNTH_RUN=csa_bp_20261003b CAMPAIGN=csa_bp_20261003 \
  GL_VALIDATOR_ARGS="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12" \
  bash sweeps/run_popcount_apr.sh csa_bp            # bootstrap pass (floating pins)
bash sweeps/run_pinned_pass2.sh                     # pinned pass 2, BP + CSA control
ROUTE_RUN=csa_bp_20261003b_distguide_spp_pins APR_CAMPAIGN_WORK=build/power_char/pinned_pass2_20261004/csa_bp \
  TAG=intBPpin GL_VALIDATOR_ARGS="--approve-annotated-interconnect --approve-negative-iopath-clamp-ps 12" \
  bash sweeps/int_mode/bp/run_bp_int_energy.sh
```
