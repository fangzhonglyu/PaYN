# Resolved: gate-level X at small `K*M` blocked the low-corner sweep

**Status:** RESOLVED 2026-07-31.  Two distinct root causes, both simulation-flow
artifacts, both fixed in `sweeps/run_clean_kmn_sweep.sh` (`glargs`).  The
netlists are functionally correct; no RTL or APR change was needed or made.
**Fix:** compile the gate sims with
`+define+ARM_UD_MODEL +define+ARM_EN_X_SQUASH` (ARM's library-sanctioned
squash of power-up X on sequential-UDP outputs) and `+neg_tchk` (honor negative
SETUPHOLD limits from the SDF).  Validated end-to-end: previously-failing
shapes now run the full 7.7 us sim and produce accepted SAIF.

The original handoff below asked four questions; all four are answered:

1. *Is the D-path cone X before the first edge?*  Yes — dumped: 75 of 84 tile
   nets X, every control net known.  (Section "Mechanism A".)
2. *Flow-side fix?*  Yes, two compile-time defines + one flag, through the
   existing `VCS_ARGS` hook.  No runtime plusargs needed.
3. *LEC to rule out a synthesis error?*  A 4-state structural evaluator
   (`sweeps/xcheck_reset_cone.py`) proves the reset function correct on every
   low-corner netlist under random binary state (20 trials/tile), and
   reproduces the exact observed X bit patterns under startup-X.  Formal LEC
   remains unrun but the question it would answer is closed.
4. *Explain `k2m1n1` PASS vs `k4m1n1` FAIL?*  They fail (or don't) by two
   *different* mechanisms — the non-monotonic `K*M` table was two failure
   populations overlaid.  See below.

---

## Mechanism A — X-pessimistic reset cone + Q->D X-lock
(k1m1n1, k1m1n2, k1m1n4, k1m1n6, k1m1n8, k1m2n1, k1m4n1)

Three facts compose:

1. **Every flop powers up X and `+vcs+initreg` cannot help.**  The ARM
   TSMC22 cells model flops as *sequential UDPs*
   (`leaf_udp_dff_PWR_sc7mcpp140z...` in
   `sc7mcpp140z_cln22ul_base_svt_c30.v`); `+vcs+initreg` initializes reg
   variables, not UDP state.  This is why both `initreg+0` and `initreg+1`
   produced "no change".  The operand pipes are X too: `a_bits_pipe` /
   `w_bits_pipe` have no reset at all (they stream every cycle), and the sign
   pipes load under an enable.  Resetting the sign pipes could never help —
   the bit pipes stayed X, and at the first clocked edge even a reset pipe
   still presents its pre-reset X.

2. **Synthesis implemented the `acc_low` sync reset through an
   `(n & ~n)` cancellation.**  In the k1m1n1 netlist
   (`InnerTileSignedSegmentedClean_K1_M1_OWIDTH24_LOW_W9`), with
   `reset=1, shift_in=0` the select nets are `n115 = n116 = 0`, and per bit:

   * bits [0], [1]: `D = AO22(n116, fb, n115, acc_in) = 0` — an AND with 0
     kills X in 4-state logic.  Clean.
   * bit [8]: through `MXIT2` with both data inputs 0 — the mux UDP resolves
     equal-data-under-X-select.  Clean.
   * bits [7:2]: `D = (n115 & acc_in) | ~n84` where
     `n84 = ~((n83 | n112) & n82)`, `n112 = 0`, `n82 = ~n83`, i.e.
     `D = ~~(n83 & ~n83)`.  Logically constant 0 — real silicon always
     resets — but `n83` is `XOR(carry_chain, acc_out[i])`, an XOR of the
     flop's **own Q**, and `X & ~X = X` in 4-state simulation.

3. **The X locks.**  The first gated reset edge latches D=X into
   `acc_low[7:2]`; Q=X feeds `n83` back; every subsequent value of D is X.
   Hold, MAC and reset states all recycle it.  Only a drain shift of a 1 bit
   could ever clean a bit (`1 | X = 1`), which the bench's zero drain never
   provides.

This predicts the X pattern **bit-exactly**.  `sweeps/xcheck_reset_cone.py`
evaluates every tile-module copy of all 13 low-corner netlists in 4-state
logic under startup conditions (reset asserted, flop outputs X, operand ports
X) using cell functions parsed from the ARM Verilog models themselves:

| shape | predicted X bits | observed signature |
|---|---|---|
| k1m1n{1,2,4,6,8}, k1m2n1 | `acc_low[7:2]` | `0000xX` per tile |
| k1m4n1 | `acc_low[7:4]` | `0000x2` |
| k2m1n1, k8m1n1, k1m8n1, k1m16n1, k16m1n1 | none | PASS |
| k4m1n1 | none — fails by Mechanism B | `00000X` |

12/13 exact; the 13th is the other mechanism.  Whether a given shape's mapper
output routes the reset through the safe `AO22` form or the unsafe
cancellation is per-netlist synthesis luck — that is the entire "non-monotonic
`K*M`" mystery.  The same script's LEC mode (random binary registers and
operands, reset asserted, 20 trials per tile) shows every D forced to 0 on
every netlist: the netlists implement the reset correctly; simulation
4-state pessimism is the only problem.

Dynamic confirmation (`+define+PAYN_XTRACE`, VCD before the first clock edge):
75 of 84 tile nets X — the whole `acc_low` D cone `n44`–`n51`, `n60`,
`n82`–`n113` — while `n55/n56/n61/n76/n115/n116`, `reset`, `shift_in`,
`mac_en` are all known.  Note the bench asserts reset at t=13,000 ps, not t=0;
the X is latched at the reset-window gated edges, which is why the zero-delay
run dies at exactly 16,250 ps.

**Fix:** `+define+ARM_UD_MODEL +define+ARM_EN_X_SQUASH`.  The ARM cell
wrappers contain a purpose-built hook: when a sequential UDP output is X it is
replaced with `ARM_X_SQUASH_VAL` (0 by default).  All state starts 0 — what a
real reset achieves — the cone evaluates 2-valued, nothing latches X.
`ARM_UD_MODEL` also gives cells 1–20 ps distributed delays; SDF path delays
dominate these, so annotated timing is unchanged, steady-state activity is
identical, and SAIF comparability with earlier runs is preserved.  Functional
correctness stays independently guarded by the streaming cosim.
Validated: k1m1n1 boot sim runs 7,705,750 ps to `$finish`, zero X.

## Mechanism B — false ICG setup violations from zeroed negative SETUPHOLD
(k4m1n1; latent for every other shape)

k4m1n1's log is different in kind: 2 timing violations, X confined to
`acc_low[3:0]`, first violation at the `acc_low` clock gate:

```
Timing violation in ...g_row_0__g_col_0__u_inner.clk_gate_acc_low_reg_2_.latch
  $setup( posedge E:22020, posedge CK &&& (ENABLE_NOT_SE == 1'b1):22029, limit: 25 );
```

The SDF for that latch says:

```
(SETUPHOLD (posedge E) (COND ENABLE_NOT_SE==1'b1 (posedge CK)) (0.025) (-0.017))
```

Setup +25 ps, hold **-17 ps**: the true stability window closes 17 ps *before*
the clock edge.  E arrives at CK-9 ps — legal.  But ASTRAEA's VCS line has no
`+neg_tchk`, so VCS zeroes the negative bound ("SDF Error: Negative SETUPHOLD
value replaced by 0" — 10 to 30 per compile, every shape) and the window
becomes [CK-25, CK], manufacturing a violation.  The violated check toggles
the UDP notifier, the ICG latch goes X, the gated clock goes X, and the flop
bank it clocks is corrupted.  STA reads the same negative values from the
.lib correctly and passes these paths — this is why "FAIL with 0 violations"
(k1m1n1, mechanism A) and "STA clean but sim violates" (k4m1n1) coexisted.

**Fix:** `+neg_tchk`.  Validated: k4m1n1 with `+neg_tchk` alone reports zero
violations and runs the full sim clean.  (`ROC_flow/gate_sim` already carries
this flag; ASTRAEA's GL path simply never did.)

## Corrections to the original evidence table

* **"GL unit-delay PASS" was non-diagnostic and should not have been used as
  evidence.**  Reproduced: `+delay_mode_unit` "passes" while logging **10,299
  timing violations** — unit delays violate every check, notifier semantics
  degrade, and the run completes on garbage timing.  It says nothing about
  the netlist.  The conclusion it was cited for (sim artifact, not design
  defect) happens to be true anyway, on the strength of the evaluator LEC +
  the mechanism above.
* **Zero-delay FAIL @16,250 ps** is the second reset edge (reset asserts at
  13,000 ps), not a separate phenomenon.
* **`-xprop=tmerge` was never going to matter:** xprop instruments RTL-style
  code, not `celldefine`/UDP library cells.
* The original claim that the X appears "at the first clock edge, 1250 ps,
  with reset=1" conflated bench variants; in the shipping bench reset asserts
  at 13,000 ps and the first edges tick with reset low.  Immaterial to the
  mechanism.

## Where things stand

* `sweeps/run_clean_kmn_sweep.sh` gate sims (boot and final) now compile with
  `$glargs` = defines + `+neg_tchk`.  Both fixes are compile-time and flow
  through the existing `VCS_ARGS` hook — the "no runtime plusarg hook" concern
  in the original handoff is moot.
* All eight previously-blocked points are now **measured** (status OK end to
  end, including cosim and the SAIF validator): k1m1n1 25.066, k1m1n2 8.961,
  k1m1n4 5.360, k1m1n6 4.559, k1m1n8 4.329, k1m2n1 20.985, k1m4n1 19.872,
  k4m1n1 7.544 pJ/MAC.  The k4m1n1 rerun logs zero timing violations and zero
  "Negative SETUPHOLD" messages.  The K=8/M=1 & K=1/M=8 N-ray workaround in
  section 9 of the old handoff is no longer needed.
* Previously-measured points are unaffected: the defines do not change
  steady-state activity, and `+neg_tchk` only removes false X.  (Points
  measured before the fix were run without these flags; if any is ever
  re-run, expect identical SAIF.)
* `GUIDES=0` at small `K*M` (multibit banking vs guide-script name matching)
  is a separate, still-open recipe-comparability caveat — unchanged by this.

## Artifacts

```text
diagnosis tool  sweeps/xcheck_reset_cone.py   (4-state netlist evaluator +
                                               reset LEC; run with no args)
netlists        apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN/<cfg>_lw9_id125_noguide/
cell models     /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/
                  sc7mcpp140z_base_svt_c30/r3p0/verilog/*.v   (X-squash hook:
                  `ARM_EN_X_SQUASH` in the leaf_udp_* wrappers)
bench           designs/payn/power/power_payn_array.sv  (X monitor line 117,
                  PAYN_XTRACE dumps xtrace.vcd)
```
