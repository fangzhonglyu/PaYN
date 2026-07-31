# Signed segmented accumulator — cleaned

Same design point as [`../signed_segmented`](../signed_segmented/README.md): the
architecture, the pending-event proof, the `2**LOW_W >= K*M` constraint and the
`acc_out = {(acc_high + pending_carry - pending_borrow), acc_low}` contract are
all unchanged, and that README remains the reference for how and why the scheme
works.  This variant only changes how those equations are written in RTL.

Instance names (`u_a_rng` / `u_w_rng` / `u_peripheral` / `u_pe` / `u_array_core`
/ `g_row_*__g_col_*__u_inner`) and state net names (`acc_low`, `acc_high`,
`pending_carry`, `pending_borrow`, `*_pipe`) are preserved verbatim, because
`sweeps/pt_pe_components.tcl`, `sweeps/pt_pending_datapath_power.tcl` and
`sweeps/saif_pending_state_activity.py` all pattern-match on them.  Every
existing PT breakdown and SAIF script runs against this design unchanged.

## What changed

### 1. One shared adder for the upper segment

The original computes `+1` and `-1` as two independent structures and selects
between them twice — once for `acc_out`, once for the `acc_high` D input:

```systemverilog
always_comb begin                       // select bank #1
    visible_high = acc_high;
    if (pending_carry)       visible_high = acc_high + HIGH_W'(1);
    else if (pending_borrow) visible_high = acc_high - HIGH_W'(1);
end
...
if (pending_carry)       acc_high <= acc_high + HIGH_W'(1);   // select bank #2
else if (pending_borrow) acc_high <= acc_high - HIGH_W'(1);
```

Synthesis does CSE the two adders, but the +1 and -1 chains stay distinct and
both select banks survive.  In the accepted `k8m16n8_lw9` netlist that is a
13-cell `ADDH` incrementer, a separate NOR2/NAND2XB borrow-propagate chain with
its own XOR/XNOR sum gates, and two banks of 14 `AOI22` + 14 `OAI21` — **124 of
the tile's 586 combinational cells (21%)**.

Adding an all-ones addend is `-1`, a carry-in is `+1`, and neither is `+0`, so
all three cases fall out of one ripple:

```systemverilog
assign high_next =
    acc_high + {HIGH_W{pending_borrow}} + HIGH_W'(pending_carry);

assign acc_out = $signed({high_next, acc_low});   // no select bank at all
...
if (pending_carry || pending_borrow)
    acc_high <= high_next;                        // same net, same adder
```

`high_next` is simultaneously the retired value and the visible high segment, so
keeping `acc_out` canonical now costs **zero** extra gates.  That matters: the
drain has no bubble cycle — `shift_in` asserts on the clock immediately after
the last MAC, with an event still outstanding — so the correction cannot simply
be dropped.

The one behavioural difference is in an unreachable state.  Both bits set folds
to a hold here, where the original's priority chain would give `+1`;
`next_carry` and `next_borrow` are complementary on `low_sum[SUM_W-1]`, so it
cannot occur.  A runtime assertion now checks that rather than leaving it to a
comment (case-compared, so the pre-reset X state is not itself a failure).

### 2. Systolic re-export rails kept

`a_bits_out` / `a_signs_out` / `w_bits_out` / `w_signs_out` /
`load_a_sign_out` / `load_w_sign_out` are **retained unchanged**.  The
single-PE top ties all six to dangling `*_nc` nets, which reads like dead
weight, but that is a property of *this* topology, not of the PE: they are what
an outer PE grid chains together (A east, W south).

Removing them costs nothing and buys nothing.  Synthesis reports the same 2,178
unloaded nets either way, the same 47,703.07 um2, and the same cell counts —
DC drops the fanout of a tied-off output, so the ports are free in a single-PE
build and load-bearing in a tiled one.  Measured both ways; identical.

`inner_pe_grid_signed_segmented_clean.sv` carries the grid over so this variant
is actually tileable.  It is pure wiring, identical to
`inner_pe_grid_signed_segmented.sv` apart from the PE it instantiates.

### 3. Minor

Lane temporaries are scoped inside `g_lanes`; elaboration-time shape checks are
`$fatal` rather than `$error`, since a violated bound silently corrupts every
accumulation instead of failing visibly.

## Verification

### Single PE — `run_array.sh` against `sc_kernel.py`, K=8 M=16 N=8x8 T=128

| run | result |
|---|---|
| clean, `LOW_W=9` | PASS — drain bit-exact |
| clean, `LOW_W=11` | PASS — drain bit-exact |
| original, `LOW_W=9` (control) | PASS — drain bit-exact |

The clean and original drained 64-element matrices are **identical**, not merely
both correct.

```bash
BUILD_DIR=build/rtl_preflight/ss_clean SIM_SRCS=designs/payn/variants/signed_segmented_clean/payn_array_signed_segmented_clean.sv \
VCS_ARGS=+define+PAYN_ARRAY_EXTERNAL_RTL+define+PAYN_ARRAY_DUT=payn_array_signed_segmented_clean+define+PAYN_SEG_LOW_W=9+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128 \
  bash designs/payn/cosim/run_array.sh
```

### Tiled — `run_systolic_matmul.sh`, 8x8 grid of full K8/M16/N8 PEs, T=128

4,096 outputs of a 64x64 matmul checked against `sc_kernel.py`.  This is what
exercises the re-export rails through a real chained topology.

| run | result |
|---|---|
| clean grid | PASS — NRMSE 0.0630 <= 0.1000 |
| original grid (control) | PASS — NRMSE 0.0630 <= 0.1000 |

The two traces are **byte-identical**.

`test_systolic_matmul.sv` takes `PAYN_GRID_EXTERNAL_RTL` / `PAYN_GRID_DUT`,
mirroring the `PAYN_ARRAY_DUT` pattern in `test_payn_array.sv`; the defaults
still select the original grid, so the existing invocation is unaffected.

```bash
BUILD_DIR=build/rtl_systolic_matmul_clean \
SIM_SRCS=designs/payn/variants/signed_segmented_clean/inner_pe_grid_signed_segmented_clean.sv \
VCS_ARGS=+define+PAYN_GRID_EXTERNAL_RTL+define+PAYN_GRID_DUT=InnerPESignedSegmentedCleanGrid \
  bash designs/payn/cosim/run_systolic_matmul.sh
```

`test_systolic_pe_grid.sv` (the small 2x3 smoke test) still instantiates the
original grid only.

## Synthesis A/B

`make synth TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN`, K8/M16/N8, `LOW_W=9`,
2.5 ns, A7 SVT C30 + HPK — the same recipe as the accepted target.

| | original | clean | |
|---|---:|---:|---:|
| total cell area (um2) | 49,034.20 | 47,703.07 | **-2.7%** |
| combinational cells | 59,644 | 53,804 | **-9.8%** |
| sequential cells | 3,041 | 3,041 | 0 |
| clock-gating elements | 354 | 354 | 0 |
| setup slack (MET, ns) | 1.44 | 1.44 | 0 |
| unloaded nets | 2,178 | 2,178 | 0 |

Per tile:

| | original | clean | |
|---|---:|---:|---:|
| tile area (um2) | 498.918 | 476.770 | **-4.4%** |
| of which combinational | 461.384 | 439.236 | -4.8% |
| of which sequential | 36.064 | 36.064 | 0 |
| combinational cells | 586 | 496 | **-15.4%** |
| high-segment logic cells | 124 | 35 | **-71.8%** |
| `acc_out[23:9]` cone | 88 | 15 | |
| adder cells (ADDF/ADDH) | 208 | 209 | +1 |

The adder count is flat by design: the shared chain is full-adder rather than
half-adder cells, and what disappears is the second ripple and one select bank.
Area falls less than cell count because the removed gates (`AOI22`, `OAI21`,
`NOR2`, `NAND2XB`) are the small ones.

**All of the saving is the tile.** 90 combinational cells per tile x 64 tiles =
5,760 of the 5,840 design-wide reduction; the rest is boundary logic.  Nothing
is attributable to port pruning — the design was synthesized both with and
without the re-export rails and the totals match to the last digit.

**Power is not yet measured.** These are synthesis numbers; the accepted
`spp_fixed` result of 0.70984 pJ/MAC belongs to `../signed_segmented` and no
routed or PT-PX figure exists for this variant.  The removed cells sit on
`pending_*`, which toggles at roughly the boundary-crossing rate, so the routed
power delta should exceed the area delta — but that is a prediction until an APR
+ gate-sim + PT-PX run confirms it.
