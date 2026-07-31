# PaYN — Accepted A7/SVT Results

Current routed, workload-driven A7/SVT results for TSMC22 at 0.80 V and
2.5 ns (400 MHz).  This file is intentionally limited to accepted A7 results
and the comparisons needed to interpret them.  Experiment commands and
historical design points live in [`experiments.md`](experiments.md) and the
linked design notes.

## Workload used for the accepted PaYN result

| parameter | value |
|---|---|
| architecture | pending-bit signed segmented accumulator, `LOW_W=9` |
| shape | K8, M16, 8×8 outputs, OW24, T=128 |
| useful rate | 64 equivalent MAC/cycle = 25.6 GMAC/s |
| numeric input | logical 7-bit unsigned magnitude plus a separate sign |
| existing 8-bit converter encoding | logical magnitude `m` is driven as `m << 1`, preserving `P(1)=m/128` |
| block schedule | magnitude and sign reload every `T/M=8` cycles |
| stochastic activity | Sobol advances and emits a new M=16 slice every cycle |
| measurement window | 256 back-to-back blocks = 2,048 productive cycles |

The routed max-SDF drain matches the independent streaming reference
bit-for-bit.  The trace contains only even encoded values through 254,
corresponding to logical magnitudes through 127.  SAIF validation reports zero
unknown time in the accumulator.

The physical netlist still contains 8-bit magnitude registers, comparators, and
Sobol words.  This result models the correct 7-bit numeric behavior on that
netlist; it does not claim the area or capacitance savings of physically
narrowing the converter.

Two idle clocks after reset release let routed reset trees satisfy recovery
before the first operand load.  They occur before SAIF starts and do not change
the productive workload or its energy accounting.

## Headline routed results

All designs operate at 400 MHz and retire 64 MAC/cycle.  Energy is therefore
`power / 25.6` in pJ/MAC.

| design | routed area (µm²) | setup WNS (ns) | power (mW) | pJ/MAC |
|---|---:|---:|---:|---:|
| BP signed INT8 | 16,536 | +1.040 | 10.60000 | 0.41406 |
| BP signed INT8 + asymmetric correction | 19,606 | +0.430 | 11.74739 | 0.45888 |
| BOS signed INT8, output-stationary systolic | 15,797 | +1.109 | 10.55916 | 0.41247 |
| BOS signed INT8, same at D=64 † | 15,797 | +1.109 | 10.87263 | 0.47687 |
| BOS signed INT8 + asymmetric correction † | 19,250 | +0.030 | 11.98748 | 0.52577 |
| **PaYN pending-bit LOW_W=9** (`spp_fixed`) | **51,906** | **+0.499** | **18.17200** | **0.70984** |

† The two daggered rows are **drain-inclusive at D=64**: their pJ/MAC is energy per
*useful* MAC, not `power / 25.6`, because 448 of the 4,096 scored cycles are drain cycles
that retire no MACs.  Every undaggered row retires 64 MAC/cycle for the whole window, so
the plain convention holds there.

**Do not difference a daggered row against an undaggered one.**  The asym correction cost
is the two daggered BOS rows against each other: 0.47687 → 0.52577, **+10.25%**.
Differencing asym against the drain-excluded plain row instead gives +27.5%, which
double-counts the drain — the 0.41247 → 0.47687 step is the +15.6% cost of draining every
64 MAC cycles (reduction depth D=64), and it is paid by both designs.

The asym row has no drain-free counterpart by construction: its correction hardware only
runs on drain cycles.  Applying `power / 25.6` to it would give 0.46826 and understate it
by 10.9%.  The drain-excluded plain row is the one comparable to BP, which never drains.

At equal useful throughput, the accepted PaYN point consumes:

- 1.71× the energy of plain signed INT8 BP (+71.4%). ‡
- 1.55× the energy of BP with asymmetric zero-point correction (+54.7%). ‡
- 1.72× the energy of BOS, the dataflow-matched binary control (+72.1%).

‡ The two BP comparisons are **cross-flow**.  PaYN and BOS are routed with HPK multibit
flops (2,583 and 1,280 multibit cells); the BP netlist has **zero** — 2,896 single-bit
flops — because it was characterized before the campaign exported `TSMC22_HPK=1
APR_MULTIBIT_FLOP_OPT=1 APR_OPT_POWER=1`.  That flow alone moved BOS by 3.5%.  The PaYN
ratios survive it comfortably at ~1.7×; a BOS-versus-BP claim does not, since those two
sit 0.4% apart, well inside the flow effect.  BP needs rerouting on the multibit flow
before that row means anything.

The asymmetric correction costs BP 10.8% over its plain signed implementation.
The binary benches use long-running, output-checked signed INT8 workloads and
do not require stochastic probability scaling.  The accepted PaYN route also
has +0.031 ns hold WNS.

## Isolating the encoding cost: the BOS dataflow-matched control

BP differs from PaYN in **both** arithmetic and dataflow — it is weight-stationary
with 24-bit partial sums flowing north, while PaYN is output-stationary with a
row-serial east drain.  `BOS` (`designs/baselines/binary_os/`) removes that
confound: it is `InnerPE` with the K-lane stochastic popcount replaced by one INT8
multiplier.  Same stationary accumulator, same `mac_en`/`shift_in` contract, same
drain, same OW24, same 64 MAC/cycle.  The only difference from PaYN is the
arithmetic.

BOS is **symmetric** signed INT8: its PE is one multiply and one accumulate, with no
zero-point term and no asymmetric correction.  That is the right pairing, because PaYN
is symmetric too — a 7-bit unsigned magnitude plus a separate sign.  Every design in the
ratio below is symmetric; the `BP + asymmetric correction` row in the headline table is a
separate design point measuring what asymmetric quantization costs in binary (+10.8%),
not a term any of these three carries.

| comparison | power ratio | reads as |
|---|---:|---|
| PaYN total / BOS | 1.72× | encoding cost including the Sobol + comparator front end |
| PaYN `u_pe` / BOS | 1.48× | encoding cost of the PE array alone |

PaYN's headline 1.75× against plain BP factors exactly:

```
1.714  =  1.721        x  0.996
PaYN/BP   PaYN/BOS        BOS/BP
          encoding,       dataflow + operand reuse,
          dataflow fixed  arithmetic fixed
```

The encoding term is sound and carries the whole ratio: at fixed dataflow, stochastic
arithmetic costs **1.72×**.  The `BOS/BP` term is **not** currently meaningful — it reads
0.996 only because BOS is routed with multibit flops and BP is not (see ‡ above), so it
measures a flow difference, not a dataflow difference.  Treat the dataflow contribution
as unresolved pending a BP reroute.  What is established is that PaYN's overhead is an
encoding story, not a dataflow story.

### BOS power breakdown

Reconciles exactly to the PT-PX total.  Produced by `sweeps/pt_binary_os_power.tcl`,
which emits the same `bin_*` keys `sweeps/pe_taxonomy.py` already consumes.

| block | power (mW) | share |
|---|---:|---:|
| PE compute cone (multiplier + accumulate adder) | 8.2614 | 75.5% |
| clock tree (CTS + ICG cells) | 1.2659 | 11.6% |
| accumulator registers (1,536 flops) | 0.7209 | 6.6% |
| glue / other combinational | 0.2956 | 2.7% |
| activation hop registers (512 flops) | 0.2014 | 1.8% |
| weight hop registers (512 flops) | 0.1920 | 1.8% |
| **total** | **10.9372** | **100%** |

Unlike BP/BS, the whole PE is a single module, so DC optimizes the product and the
accumulate add jointly and no instance-name split exists between them; the merged cone
is the meaningful unit and is what `pe_taxonomy.py` plots as "compute" for the SC
popcount+heap+CPA cone too.  Flop buckets include each flop's clock-pin power, so
`clock tree` is CTS buffers and ICG cells only.

With 75% of the power in the compute cone, at fixed dataflow the encoding question
reduces almost entirely to popcount+heap+CPA versus INT8 multiply-add.

### What operand broadcast costs: a measured structural variant

An earlier build of this design registered operands once at the *array* boundary and
broadcast them across each PE row and column, instead of hopping them PE-to-PE.  That
needs only 128 operand flops instead of 1,024, and it was measured on its own routed
netlist before being replaced.  Both points are real measurements at the same workload:

Both columns are the pre-HPK flow (no multibit flops, no `APR_OPT_POWER`), which is
what makes them comparable to each other; the headline table now carries the refreshed
HPK numbers for the mesh.

| | broadcast operands | **systolic mesh (shipped)** |
|---|---:|---:|
| sequential cells | 1,665 | 2,561 |
| routed area (µm²) | 14,134 | 15,950 |
| setup WNS (ns) | +0.760 | **+1.127** |
| power (mW) | 11.77915 | **10.93719** |
| pJ/MAC | 0.46012 | **0.42723** |

The mesh is 12.8% larger and still **7.1% lower power and 0.37 ns faster**.  Where the
0.842 mW goes:

| block | broadcast | mesh | Δ |
|---|---:|---:|---:|
| compute cone | 9.225 | 8.261 | **−0.964** |
| glue / other (broadcast buffer trees) | 0.674 | 0.296 | −0.379 |
| accumulator registers (1,536 flops both) | 0.980 | 0.721 | −0.259 |
| clock (CTS + ICG) | 0.741 | 1.266 | +0.525 |
| operand registers (128 → 1,024 flops) | 0.158 | 0.393 | +0.235 |
| **total** | **11.779** | **10.937** | **−0.842** |

The compute cone is the dominant term, and it is *not* a structural change: routed
combinational area is identical between the two netlists (9,350.3 vs 9,351.9 µm²).
Same gates, 10.4% less power, so it is pure switching activity.  The SAIF toggle counts
confirm the mechanism is glitch suppression:

| | compute nets | total TC | transitions / net / cycle |
|---|---:|---:|---:|
| broadcast | 26,813 | 103.5 M | 0.943 |
| mesh | 28,906 | 84.7 M | **0.715** |

The mesh has 7.8% *more* nets in the compute cones yet 18.2% fewer transitions.  A net
carrying uniformly random data transitions at most 0.5×/cycle functionally, so both
designs are glitch-dominated — but the mesh roughly halves the excess above that bound.
Feeding a multiplier from a local flop instead of a long, buffered, high-fanout bus
gives near-simultaneous bit arrivals and far less spurious switching through the
partial-product and compressor tree.  The same effect explains the accumulator flops:
at identical count, less glitching on their D inputs costs 26% less internal power.

The two costs are the clock tree (896 more flops on one always-on ICG, and the CTS
buffer area rises 27.4%) and the operand flops themselves — 8× the flop count for only
+0.235 mW, because each is a plain resetless DFF driving one short local net.

The practical reading: operand broadcast is a false economy at this size.  It saves 896
flops and pays for them several times over in glitch power on the shared buses, plus a
third of a nanosecond of slack.

### Output-stationary versus weight-stationary, at matched operand activity

BOS is 3.5% smaller than BP and draws 3.2% more power against BP's *accepted* point.
That comparison is confounded: BP's accepted workload loads one weight set and holds
it stationary for all 4,096 scored cycles, so its weight registers never toggle and
every multiplier has a constant operand.  An output-stationary array cannot do that by
construction — both operands are re-issued every cycle.

`BP_STREAM_WEIGHTS` reloads BP's weight column every cycle on the same routed netlist,
matching operand activity:

| point | power (mW) | pJ/MAC | routed area (µm²) |
|---|---:|---:|---:|
| BP, weights stationary (accepted) | 10.60177 | 0.41413 | 16,536 |
| BP, weights streaming (activity-matched) | 12.75826 | 0.49837 | 16,536 |
| BOS, output-stationary systolic | 10.93719 | 0.42723 | 15,950 |

At matched activity and excluding the drain, the output-stationary array is **14.3%
lower power and 3.5% smaller**.  Against BP's stationary-weight point it is 3.2%
higher.  Both are true and they bracket the honest answer: weight reuse is worth 20.3%
to BP, and it is a real advantage of weight-stationary dataflow whenever the same
weights multiply many activation vectors — not an artifact.  The drain section below
shows how much of the 14.3% survives at finite reduction depth.

Where the +0.335 mW against BP's accepted point comes from — the two terms have
opposite signs and the workload term is over five times the structural one:

```
BOS - BP_stationary = +0.335 mW
                    = +2.156 mW  lost weight reuse (BP stationary -> streaming, same netlist)
                      -1.821 mW  BOS structural savings (BOS vs BP streaming)
```

Block-level, at matched activity (both decompositions reconcile to their PT-PX totals):

| block | BP streaming (mW) | BOS mesh (mW) | Δ |
|---|---:|---:|---:|
| compute cone (mul + accumulate add) | 8.763 | 8.261 | −0.501 |
| operand registers | 1.905 | 0.393 | **−1.512** |
| accumulator registers | 0.853 | 0.721 | −0.132 |
| control flops | 0.178 | 0.000 | −0.178 |
| clock (CTS + ICG cells) | 0.466 | 1.266 | **+0.800** |
| glue / other | 0.593 | 0.296 | −0.298 |
| **total** | **12.758** | **10.937** | **−1.821** |

The dominant term is still the operand registers, and this is the surprise: both
designs hold exactly 1,024 operand flops toggling every cycle, yet BP burns 4.8× more
in them.  Flop count and activity do not explain it.  The structural difference is that
BP's `ireg`/`wreg` carry async reset plus `clr` and `en` muxing and sit behind per-PE
clock gates, where the mesh's hop registers are plain resetless DFFs — a plausible
cause that this measurement does not isolate.  Worth a targeted look before the number
is leaned on.

BOS gives back 0.800 mW in the clock tree.  Its 2,560 flops sit behind a *single*
always-enabled ICG, so nothing is ever gated during the MAC window, whereas BP's 192
ICGs let Innovus build a shallower gated tree.  The single clock gate saves 451 µm² of
ICG area and costs more than that back in CTS power.  (`clock_dist` is a name-matched
bucket, so treat the magnitude as indicative.)

Avoiding 24-bit partial-sum movement — the thing output-stationary is usually sold on
— contributes only −0.132 mW here, 7% of the structural saving.

### Asymmetric zero-point correction on BOS

`binary_os_asym.sv` adds the same exact identity BP uses, per output (h,v):

```
sum((qa-za)*(qw-zw)) = raw - zw*sum(qa) - za*sum(qw-zw)
```

`sum(qa)` is a per-row activation sum accumulated on-array; `sum(qw-zw)` is a
per-column centred weight sum precomputed off-array, exactly as in BP.  Verified
bit-exact against a golden asymmetric matmul with nonzero zero points on both
operands and a per-column weight zero point, on the routed netlist.

Measured at the **identical** workload as the plain mesh (3,648 MAC + 448 drain
cycles, D=64) on the **identical** HPK/multibit flow, so this is a single-basis
comparison:

| | plain | + asym correction | Δ |
|---|---:|---:|---:|
| power (mW) | 10.87263 | 11.98748 | **+10.25%** |
| pJ per useful MAC | 0.47687 | 0.52577 | **+10.25%** |
| routed area (µm²) | 15,797 | 19,250 | +21.9% |
| setup WNS (ns) | +1.109 | **+0.030** | −1.079 |

For reference the same correction costs BP **+10.8%** power and **+18.6%** area.

**A structural prediction that did not survive measurement.**  The drain emits one
column on all N_H rails at once, so the `za*sum(qw-zw)` term is a single shared
scalar and BOS needs only N_H+1 = 9 correction multipliers where BP replicates a
two-multiplier corrector per column, 16 in total.  That reasoning predicted a
clearly cheaper correction.  It is essentially a wash: 10.25% versus 10.8% on
power, and *worse* on area.

The count argument ignored width.  BOS's row sums are `IWIDTH + DEPTH_W` = 18 bits
because the reduction depth is a workload parameter (`DEPTH_W=10`, D up to 1024),
where BP's activation sums are `IWIDTH + log2(HEIGHT)` = 11 bits because its
reduction depth is fixed at the array height of 8.  Nine wide multipliers plus 144
row-sum flops is not cheaper than sixteen narrow ones.  `DEPTH_W` is the lever: a
design that only ever needs D ≤ 128 could drop it to 7 and shrink the whole
correction datapath.

The timing cost is the real problem.  The corrected value is combinational from the
accumulators through the multiplier and two subtractors to the output port, and it
becomes the critical path — `corr_en → ofm[47]`, +0.030 ns.  That is not a
signoff-able margin; registering the corrected output (and ideally the products)
would break the path at the cost of one or two cycles of drain latency.  Not built.

**Notation.**  `D` is the GEMM **reduction depth** — the length of the dot product each
PE accumulates, i.e. the shared inner dimension of the matmul, or
`in_channels × kernel_h × kernel_w` for a conv layer.  It is a property of the workload,
not of the array, and it sets how often the accumulators must be drained: D MAC cycles,
then N_W=8 drain cycles that retire no MACs.  `BOS_DRAIN_PERIOD` in the power bench is D.
Do not confuse it with PaYN's `K`, which is the number of spatial stochastic lanes inside
one `InnerTile` (K=8) — an unrelated quantity.

### Drain cost, and the skew fill the mesh pays

The headline BOS number, like PaYN's, is measured with the drain taken after
`$toggle_stop` on a continuous stream — it is pure MAC work with the fill amortized to
nothing, which is the right basis for the encoding comparison above and is exact.

Finite reduction depth is where the systolic mesh pays twice.  PE (h,v) retires slice t
at cycle t+h+v+1, so the corner PE finishes `N_H+N_W-2 = 14` cycles after PE (0,0).  The
drain is a lockstep shift, so no PE may begin the next block until the last one is done:
**every block costs D + 14 MAC-enabled cycles + 8 drain cycles for 64·D useful MACs.**
The superseded broadcast build paid none of the 14 — it fed every PE the same slice
index at the same cycle — and PaYN's `InnerPE` does not pay it either, since it also
broadcasts operands within its tile block.

Measured sweep on the HPK/multibit netlist, with the bench's `k` MAC cycles
reinterpreted as `D+14` (see the skew-fill discussion above):

| bench k | D = k−14 | MAC duty | power (mW) | pJ per useful MAC (as-run) |
|---:|---:|---:|---:|---:|
| — (D → ∞) | ∞ | 1.000 | 10.55916 | 0.41247 |
| 256 | 242 | 0.971 | 10.74704 | 0.43248 |
| 128 | 114 | 0.941 | 10.81188 | 0.44863 |
| 64 | 50 | 0.891 | 10.87263 | 0.47687 |
| 32 | 18 | 0.801 | 10.88714 | 0.53108 |

Drain cycles are also *more* expensive than MAC cycles: shifting a full 24-bit
accumulator between neighbours toggles more than adding a small product to a running
sum.

Comparing the two BOS builds at equal depth on their own asymptotic power and exact
cycle counts:

| D | mesh, D+22 cycles | broadcast, D+8 cycles |
|---:|---:|---:|
| 32 | 0.721 | **0.575** |
| 64 | 0.574 | **0.518** |
| 128 | 0.501 | **0.489** |
| 256 | **0.464** | 0.475 |
| 512 | **0.446** | 0.467 |

**The mesh's lower per-cycle power only becomes an energy win beyond D ≈ 174.**  Below
that the broadcast build wins despite drawing 7.1% more power, purely because it has no
skew to fill.  Against activity-matched BP — which never drains and never fills, since
its partial sums leave the array every cycle — the mesh crosses at D ≈ 150; against
BP's accepted stationary-weight point it does not win at any depth.

This is a fill cost, not a fundamental one: double-buffering the accumulator (a shadow
register per PE, +1,536 flops) would let the next block's fill overlap the current
block's drain and remove both penalties.  That trade has not been built or measured.

For the PaYN comparison specifically, note that the broadcast build is the more
structurally faithful control at finite depth, because PaYN broadcasts operands inside
its PE too.  The 1.69× encoding ratio is quoted on the drain- and fill-excluded basis
where the distinction vanishes.

## Binary precision: native hardware versus fixed INT8 hardware

`Native` means the multiplier, registers, and routing are physically narrowed.
The fixed-INT8 columns keep the complete INT8 netlist and only restrict input
values.  All measurements are routed and output-checked.

| input precision | native HW area (µm²) | native HW mW / pJ/MAC | fixed INT8 HW, signed inputs mW / pJ/MAC | fixed INT8 HW, all-positive inputs mW / pJ/MAC |
|---|---:|---:|---:|---:|
| INT8 | 16,536 | 10.60 / 0.414 | 10.60 / 0.414 | 9.01 / 0.352 |
| INT7 | 15,136 | 9.53 / 0.372 | 10.50 / 0.410 | 8.61 / 0.336 |
| INT6 | 13,343 | 8.16 / 0.319 | 10.42 / 0.407 | 7.75 / 0.303 |

Signed input narrowing on fixed INT8 hardware saves only about 2% from INT8 to
INT6 because sign extension keeps upper bits active.  Native narrowing removes
hardware and is substantially more effective.  Holding the sign bit positive
is the strongest activity lever: INT6 all-positive inputs on the fixed INT8
netlist consume less than the native signed-INT6 design.

## Accepted PaYN power breakdown

The headline is now the `spp_fixed` route.  Its block split, from that run's
`reports/power_hier.rpt` (three significant figures — that is the report's native
precision, not a rounded version of a finer measurement):

| block | total (mW) | share | total energy (pJ/MAC) |
|---|---:|---:|---:|
| InnerPE array (`u_pe`) | 15.60 | 85.8% | **0.6094** |
| binary-to-unary peripheral (`u_peripheral`) | 1.75 | 9.6% | 0.0684 |
| Sobol banks (`u_a_rng` + `u_w_rng`) | 0.638 | 3.5% | 0.0249 |
| **full array** | **18.17** | 100% | **0.70984** |

The six-decimal table below is the **superseded `wlpwr` route**, retained because its
dynamic/leakage decomposition and the converter/Sobol native accounting were measured
at full precision there and have not been regenerated for `spp_fixed`.  Block shares are
within a point of each other, so the structural conclusions carry over; the absolute
numbers do not.

| block | total power (mW) | dynamic energy (pJ/MAC) | static leakage (mW) | total energy (pJ/MAC) |
|---|---:|---:|---:|---:|
| InnerPE array (`u_pe`) | 15.824571 | **0.613971** | 0.106901 | 0.618147 |
| binary-to-unary peripheral (`u_peripheral`) | 1.840630 | **0.070468** | 0.036652 | 0.071900 |
| Sobol banks (`u_a_rng` + `u_w_rng`) | 0.721971 | **0.027954** | 0.006356 | 0.028202 |
| shared/top-level overhead | 0.144001 | **0.005460** | 0.004214 | 0.005625 |
| **full array** (wlpwr) | **18.531170** | **0.717854** | **0.154123** | **0.723874** |

Dynamic energy is each block's cell-internal plus net-switching power divided
by 25.6 GMAC/s.  Static leakage remains in mW; total energy includes its
throughput-amortized contribution.  In their native accounting, the
converter's total is 0.002247 pJ/output bit and the Sobol banks' total is
0.056404 pJ/Sobol word.

The full-chip PT-PX split is:

| component | power (mW) | share |
|---|---:|---:|
| net switching | 9.804754 | 52.91% |
| cell internal | 8.572295 | 46.26% |
| leakage | 0.154123 | 0.83% |

Expressed as dynamic energy plus static leakage, the accepted result is:

Also the superseded `wlpwr` route (see above — not regenerated for `spp_fixed`):

| metric | value |
|---|---:|
| dynamic power (net switching + cell internal) | 18.377049 mW |
| **dynamic energy** | **0.717854 pJ/MAC** |
| **static leakage** | **0.154123 mW** |
| leakage energy at 25.6 GMAC/s | 0.006020 pJ/MAC |
| total energy (dynamic + amortized leakage) | 0.723874 pJ/MAC |

Dynamic energy is `(9.804754 + 8.572295) / 25.6`.  Leakage is reported
separately in mW because it is paid with wall-clock time rather than per
operation; the leakage-energy row is its throughput-dependent equivalent.

Wire and net switching remain the main physical limiter.  The accepted
row/column distribution guides are combined with workload-aware dynamic-power
optimization and high-effort detailed wirelength placement.  Relative to the
previous accepted route, the new route cuts total capacitance 0.99%, cell
internal power 1.85%, and total power 0.79%; see
[`SC_wire_optimization.md`](SC_wire_optimization.md).

## Routed power versus stochastic length

The accepted `spp_fixed` pending-bit `LOW_W=9` route was reused without
synthesis or APR.  Every point contains 3,072 productive clocks; magnitude and
sign reload every `T/M` clocks while all `M=16` generated stochastic bits
continue changing every clock.  Each max-SDF drain matches the independent
streaming reference, and every SAIF has zero unknown time in the accumulator.

`T=16` (`T/M = 1`) is the true floor: `T` must be a positive multiple of
`M=16`, so no shorter sequence exists without narrowing the Sobol slice.
Reaching it needed a bench change, not an RTL change.  The operand load path is
two registers deep (one in the peripheral, one in the InnerPE `a_bits_pipe`), so
the original bench issued the next batch at
`(cycle % MAC_CYCLES) == MAC_CYCLES - 2` and asserted `MAC_CYCLES >= 2` because
that index goes negative at `T/M = 1`.  The issue point is now
`((cycle + 2) % MAC_CYCLES) == 0` — algebraically identical for
`MAC_CYCLES >= 2` — and the prologue preloads a second batch when
`MAC_CYCLES < 2`, so the feed runs two batches ahead of the accumulator.
Re-measuring `T=32` after the change reproduced 0.213036 exactly.

### Compute-array boundary only

| T | reuse cycles | useful MAC/cycle | array power (mW) | array pJ/MAC |
|---:|---:|---:|---:|---:|
| 16 | 1 | 512.000 | 20.6 | **0.10059** |
| 32 | 2 | 256.000 | 17.2 | **0.16797** |
| 48 | 3 | 170.667 | 17.0 | **0.24902** |
| 64 | 4 | 128.000 | 16.1 | **0.31445** |
| 96 | 6 | 85.333 | 15.8 | **0.46289** |
| 128 | 8 | 64.000 | 15.6 | **0.60938** |

The compute-array boundary is the complete `u_pe`: all 64 arithmetic tiles,
their stochastic-bit/sign pipeline registers, and in-array distribution.  It
excludes the binary-to-unary peripheral, both Sobol banks, and shared top-level
overhead.  These are therefore the isolated array-compute MAC energies, not
full-design energies.  `u_pe` power is three significant figures — the
hierarchy report's native precision — so the derived energies carry that.

For reference, the corresponding full-design results are:

| T | full power (mW) | full pJ/MAC |
|---:|---:|---:|
| 16 | 27.98184 | **0.136630** |
| 32 | 21.81484 | **0.213036** |
| 48 | 20.67288 | **0.302825** |
| 64 | 19.39580 | **0.378824** |
| 96 | 18.58618 | **0.544517** |
| 128 | 18.18701 | **0.710430** |

Energy falls with `T`, but with diminishing returns as reload power grows:
−46.7% from `T=128` to `64`, −43.8% from `64` to `32`, −35.9% from `32` to `16`.
Power rises 12.3 mW per unit reload rate (`M/T`) over the final halving versus
about 9.7 mW/unit across `T=128…32`, so the trend steepens rather than
flattening.  At `T=16` the array boundary crosses 0.1 pJ/MAC.

These low-`T` points are drain-excluded, and increasingly so: at `T=16` a block
completes every clock while the row-serial east drain needs `N_W = 8` clocks to
empty the array, an 8x oversubscription.  They are valid energies for the
compute performed, not sustainable system throughputs, and reaching them
without a wider drain or a double-buffered accumulator is not possible.

### What separates the two boundaries

`full` minus `array` is the binary-to-unary peripheral, the two Sobol banks, and
shared top-level glue.  Block totals from each point's `reports/power_hier.rpt`
(three significant figures, the report's native precision):

| T | total (mW) | `u_pe` (mW) | `u_peripheral` (mW) | `u_a_rng` (mW) | `u_w_rng` (mW) |
|---:|---:|---:|---:|---:|---:|
| 16 | 28.000 | 20.600 | **6.180** | 0.309 | 0.329 |
| 32 | 21.800 | 17.200 | **3.670** | 0.309 | 0.329 |
| 48 | 20.700 | 17.000 | **2.810** | 0.309 | 0.329 |
| 64 | 19.400 | 16.100 | **2.390** | 0.309 | 0.329 |
| 96 | 18.600 | 15.800 | **1.970** | 0.309 | 0.329 |
| 128 | 18.200 | 15.600 | **1.750** | 0.309 | 0.329 |

Two structural facts fall out.

**The Sobol banks are invariant at 0.638 mW.**  They emit a fresh `M=16` slice
every clock regardless of sequence length, so their cost is fixed per cycle and
amortizes over more MACs as `T` shrinks.

**The peripheral drives the entire low-`T` power rise.**  It reloads and
re-compares magnitudes every clock at `T=16` instead of every eighth clock at
`T=128`, going 1.75 -> 6.18 mW (3.5x).  That accounts for essentially all of the
18.2 -> 28.0 mW total increase; the compute array itself only moves
15.6 -> 20.6 mW.

So the overhead grows in absolute terms while shrinking per MAC:

| T | overhead (pJ/MAC) | share of full |
|---:|---:|---:|
| 16 | 0.03604 | 26.4% |
| 32 | 0.04507 | 21.2% |
| 64 | 0.06437 | 17.0% |
| 128 | 0.10106 | 14.2% |

When comparing against BP or BOS — neither of which has an analogous conversion
or RNG cost — the **full** column is the honest one.  The array boundary is
comparable only against another array-boundary number such as `SC_INNER_PE`.

The superseded `distguide` sweep, retained because the dynamic/leakage
decompositions below were measured there and have not been regenerated:

| T | full power (mW) | full pJ/MAC | array power (mW) | array pJ/MAC |
|---:|---:|---:|---:|---:|
| 32 | 22.45022 | 0.219240 | 17.66294 | 0.172490 |
| 48 | 21.28062 | 0.311728 | 17.41351 | 0.255081 |
| 64 | 19.94216 | 0.389495 | 16.53351 | 0.322920 |
| 96 | 19.10784 | 0.559800 | 16.15920 | 0.473414 |
| 128 | 18.69109 | 0.730121 | 15.97527 | 0.624034 |

`spp_fixed` is 2.7–2.9% lower at every T, a uniform offset consistent with a
better route rather than a workload effect.  Leakage is flat at 0.15406 mW
across the sweep, confirming one netlist throughout.

The corresponding dynamic-energy split, measured on the superseded `distguide`
sweep and not regenerated for `spp_fixed` (shares carry over; absolute values
do not):

| T | PE core | conversion | Sobol | shared | **total dynamic** |
|---:|---:|---:|---:|---:|---:|
| 32 | 0.171510 | 0.036453 | 0.007075 | 0.002831 | **0.217869** |
| 48 | 0.253612 | 0.042180 | 0.010613 | 0.003265 | **0.309671** |
| 64 | 0.320964 | 0.047934 | 0.014151 | 0.003706 | **0.386754** |
| 96 | 0.470482 | 0.059402 | 0.021226 | 0.004579 | **0.555689** |
| 128 | 0.620126 | 0.070760 | 0.028301 | 0.005453 | **0.724640** |

All entries above are pJ/MAC and exclude leakage.  Static leakage by component
is:

| T | PE core (mW) | conversion (mW) | Sobol (mW) | shared (mW) | **total leakage (mW)** |
|---:|---:|---:|---:|---:|---:|
| 32 | 0.100346 | 0.031338 | 0.005395 | 0.003388 | **0.140466** |
| 48 | 0.100228 | 0.031392 | 0.005395 | 0.003388 | **0.140403** |
| 64 | 0.100164 | 0.031413 | 0.005395 | 0.003389 | **0.140361** |
| 96 | 0.100084 | 0.031441 | 0.005395 | 0.003388 | **0.140308** |
| 128 | 0.100060 | 0.031456 | 0.005395 | 0.003389 | **0.140300** |

These component values come from each saved `cell_power.rpt`; shared overhead
is the full-chip PT-PX total minus the three named hierarchies.

Shorter reuse raises instantaneous power because the held binary magnitudes and
signs reload more frequently.  From T=128 to T=32, total power rises 20.1%,
but useful throughput rises 4x, so energy per completed MAC falls 70.0%.
Sobol power stays constant at 0.72991 mW because it advances every cycle.
The T sweep reuses the previous accepted route.  Its matched T=128 control is
within 0.07% of that route's 18.67898 mW result; it has not been regenerated
on the new 18.53117 mW workload-aware route.

### Padded T: power when T is not a multiple of M

The hardware consumes `M=16` stochastic bits per clock, so a stream of length
`T % 16 != 0` executes in `ceil(T/16)` clocks with the top `16 - T%16` lanes
of the final slice dead (zero).  Measured on the same accepted `spp_fixed`
route with the same methodology: bench `power_payn_array_tpad.sv` forces the
dead lanes to zero at the `u_pe` boundary (modeling a mask-after-compare
implementation -- peripheral and Sobol banks run full width every clock), the
streaming reference masks identically, and every point passes the bit-exact
drain cosim at RTL and gate level, which also proves the mask hits the right
slice and lanes.  Controls through the padded bench reproduce the T sweep:
T=32 exact to the reported digits, T=128 within 0.5 ppm.  The measurement is
insensitive to mask *timing*: moving the force release across half a clock
changed three points by 4-9 ppm and the rest not at all.

`sweeps/run_pending_t_pad_power.sh`; results
`build/power_char/t_pad/results.csv`.  Accuracy column: SC dot-product RMSE
from `sweeps/sc_tpad_accuracy.py` (bit-exact kernel model, 4000 random blocks,
same pad masking), `build/power_char/t_pad/accuracy_vs_T.csv`.

| T | slices | pad lanes | power mW | pJ/MAC | vs P(16*ceil) | RMSE |
|---:|---:|---:|---:|---:|---:|---:|
| 17 | 2 | 15 | 21.107 | 0.206121 | -3.2% | 0.2113 |
| 24 | 2 | 8 | 21.859 | 0.213462 | +0.2% | 0.1821 |
| 32 | 2 | 0 | 21.815 | 0.213036 | -- | 0.1583 |
| 40 | 3 | 8 | 20.452 | 0.299597 | -1.1% | 0.1265 |
| 56 | 4 | 8 | 19.712 | 0.385007 | +1.6% | 0.0983 |
| 72 | 5 | 8 | 19.064 | 0.465421 | (no T=80 ref) | 0.0906 |
| 88 | 6 | 8 | 18.599 | 0.544905 | +0.1% | 0.0865 |
| 104 | 7 | 8 | 18.458 | 0.630900 | (no T=112 ref) | 0.0773 |
| 120 | 8 | 8 | 18.410 | 0.719150 | +1.2% | 0.0687 |
| 128 | 8 | 0 | 18.187 | 0.710430 | -- | 0.0655 |

Three conclusions:

1. **Energy per MAC is a step function of `ceil(T/16)`.**  A block completes
   `K*N^2` MACs in `ceil(T/16)` clocks whether or not the final slice is
   full, so pJ/MAC(120) = 0.719 ~= pJ/MAC(128), nowhere near the ~0.66 a
   smooth interpolation would suggest.  Padding buys back none of the slice
   cost.
2. **Masking has a measurable toggle tax, and at pad=8 it exceeds the compute
   saving.**  The deviations against the full multiples are systematic, not
   noise: rerunning T=120 and T=128 with a second operand seed moves each
   point by only ~0.1% but reproduces the +1.25% gap exactly.  A full SAIF
   diff localizes it: each pad-lane operand-broadcast bit goes from 1064 to
   1312 toggles (+23%), because the forced entry/exit transitions
   (~`2*q_bar` per block at bit duty `q_bar ~= 0.5`) replace a natural
   slice-boundary toggle rate of only `2*q_bar*(1-q_bar)`, and every such
   bit fans out to `N` tiles' AND gates (+0.49M downstream tile-net
   toggles).  The dead products save less than that until the dead fraction
   is large: T=17 (15 of 16 lanes, 47% of samples dead) nets a clear -3.2%.
   Implementation note: a product bit dies when EITHER operand bit is zero,
   so masking only the W side is functionally identical (bit-exact same
   drain) and pays the tax on half the nets.  Measured
   (`PAYN_TPAD_MASK_W_ONLY`, `build/power_char/t_pad_wonly/`): T=120 drops
   from 18.410 to 18.301 mW, +1.23% -> +0.63% over T=128 -- the tax halves
   with the masked-net count, confirming the mechanism causally.  A real
   padded design should mask one side only, ideally before the Sobol
   compare, where the tax would mostly vanish.
3. **A non-multiple T is never Pareto-optimal here.**  Within a step the full
   multiple has strictly better accuracy at equal energy (RMSE 0.0655 at
   T=128 vs 0.0687 at T=120, same 0.71-0.72 pJ/MAC) -- and the toggle tax
   only reinforces it.  The padded mode's value is its cost model for an
   externally pinned T: pay the ceiling multiple's energy plus ~1% mask
   overhead, keep the smooth accuracy curve at that exact T.

Error bars: operand-seed sensitivity +-0.1% (T=120/128 re-measured at
`SC_SEED=0xCAFEF00D`: 18.4354 / 18.2046 mW vs 18.4102 / 18.1870), mask-timing
sensitivity 4-9 ppm, controls exact to 0.5 ppm.  Seed study:
`build/power_char/t_pad_seed2/results.csv`.

## Routed PaYN checkpoint comparison

Every row below was rerun with the same corrected 256-block workload, passed
the streaming bit-exact drain check, and produced a valid routed max-SDF SAIF.
Energy uses the common 25.6 GMAC/s useful rate.

| routed checkpoint | area (µm²) | setup / hold WNS (ns) | power (mW) | pJ/MAC | physical status |
|---|---:|---:|---:|---:|---|
| **pending-bit, LOW_W=9 + guides + spp_fixed (accepted)** | **51,906** | **+0.499 / +0.031** | **18.17200** | **0.70984** | clean |
| pending-bit, LOW_W=9 + guides + spp_lean | 52,007 | +0.225 / +0.030 | 18.27660 | 0.71393 | clean |
| pending-bit, LOW_W=9 + workload power opt + guides (prior accepted) | 51,871 | +0.627 / +0.029 | 18.53117 | 0.723874 | clean |
| pending-bit, LOW_W=9 + guides (prior route) | 52,185 | +0.558 / +0.019 | 18.67898 | 0.729648 | clean |
| direct segmented, LOW_W=8 + guides | 50,786 | +0.230 / +0.049 | 18.78374 | 0.733740 | clean antenna-ECO export |
| baseline + row/column guides | 51,023 | +0.279 / +0.029 | 20.62757 | 0.805764 | 9 antenna violations |
| compensated segmented, LOW_W=8 + guides | 52,333 | +0.321 / +0.038 | 20.65121 | 0.806688 | 2 DRC, 72 antenna violations |
| baseline + guides + preserved fanout tree | 51,731 | +0.246 / +0.026 | 21.61643 | 0.844392 | 7 antenna violations |
| unguided baseline | 51,053 | +0.127 / +0.040 | 21.62573 | 0.844755 | 2 DRC, 9 antenna violations |
| WDBI bit-decode + guides | 57,924 | +0.140 / +0.029 | 24.99178 | 0.976241 | clean analysis route |

The row/column guides save 4.62% versus the unguided baseline.  Preserving an
explicit low-fanout tree gives that gain back.  Direct segmented is 2.7%
smaller than pending but consumes 0.56% more energy.  WDBI reduces activity on
the encoded W roots, but its decoder/control network raises whole-array energy
21.2% above the guided baseline.

Two subsequent accumulator experiments did not beat pending:

- Source-isolating the 24-bit drain chain passed RTL, synthesized, routed, and
  passed max-SDF output checking.  Against the matched 3,072-cycle T=128
  control it consumed 19.20351 mW / 0.750137 pJ/MAC, **2.74% more energy**.
  Area rose 1.08% and total routed wire rose 4.54%; the analysis route also
  retained two geometry DRCs.  The isolation gates eliminated compute-phase
  activity on the drain links, but their placement and control routing cost
  more net power than the links saved.
- Block-retired sign compensation passed RTL and synthesized 2.40% smaller,
  but matched synthesis power rose from 8.0398 to 8.3091 mW (**+3.35%**).
  Its biased `M-hit` negative operands switch too densely, so it was rejected
  before spending an APR run.

Earlier binary tables mistakenly reported routed instance counts (24,944,
23,139, and 21,316) as square-micron area.  They now use Innovus functional
standard-cell area, excluding physical-only filler and antenna cells, which is
the same metric used for the PaYN route comparisons.

## Experimental library results

A6P5/SVT measurements are intentionally excluded from the A7 headline and
accepted-result tables in this document.  They are tracked separately in
[`A6P5_results.md`](A6P5_results.md).

The rejected physical native-seven-bit A7 experiment reduced routed area by
4.83% and wire by 9.24%, but changed stochastic-stream activity, increased
energy by 5.02%, and retained four geometry plus 28 antenna violations.  Its
implementation was removed after this result was recorded.

## K x M x N shape sweep

Every point below is routed with the accepted `spp_fixed` two-pass recipe,
gate-level cosim bit-exact against the cycle reference, and PT-PX annotated with
a SAIF the validator accepted at `acc TX = 0.000000000%`.  Fixed across the
sweep: `LOW_W=9`, `T=128`, `OWIDTH=24`, 2.5 ns, 3072 productive cycles.

Two deliberate differences from the accepted checkpoint, both required to run
the sweep at all:

* the RTL is [`signed_segmented_clean`](../designs/payn/variants/signed_segmented_clean/README.md),
  which is behaviourally identical (drain bit-identical to the original at
  K8/M16/N8) but ~2.9% smaller;
* `INPUT_DELAY=1.25` instead of the flow default 0.05 -- see the N>8 recovery
  below.  This is the honest constraint: the bench launches every control at the
  negedge, so a control signal really has half a period, not the ~2.45 ns the
  default declares.

Driver: `sweeps/run_clean_kmn_sweep.sh`.  Results:
`build/power_char/clean_kmn/results.csv`.

### pJ/MAC across the grid

| | N=6 | N=8 | N=10 |
|---|---:|---:|---:|
| K=4, M=8 | **0.917576** | 1.009791 | 1.075632 |
| K=4, M=16 | 0.845846 | **0.843114** | 0.962240 |
| K=8, M=8 | 0.851035 | **0.791400** | 0.827033 |
| **K=8, M=16** | 0.806819 | **0.715879** | 0.745769 |
| K=12, M=8 | 0.810498 | **0.774763** | 0.844223 |
| K=12, M=16 | 0.781460 | **0.744532** | 0.793241 |

**The accepted K=8 / M=16 / N=8 is the global minimum of the swept space**, and
it sits at an interior optimum on all three axes simultaneously.  The shape is
now empirically justified rather than inherited.

### Each axis in isolation

**M** -- monotonic, no interior optimum.  M=16 beats M=8 in all nine matched
(K, N) cells, by 5.2% to 16.5%.  M multiplies the work per clock without
touching the per-tile accumulator, pending logic or clock tree, so the fixed
cost amortizes almost purely.  It is the only axis with no penalty for pushing
further within the range swept.

**N** -- interior optimum at 8 in five of six rows.  The full curve at
K=8/M=16, where MAC/cycle = N^2 exactly, so pJ/MAC = 2.5*P/N^2:

| N | tiles | routed um2 | power mW | pJ/MAC |
|---:|---:|---:|---:|---:|
| 1 | 1 | 4,190.872 | 1.26379 | 3.159467 |
| 2 | 4 | 7,445.844 | 2.19775 | 1.373593 |
| 4 | 16 | 17,325.616 | 6.00723 | 0.938629 |
| 6 | 36 | 30,763.866 | 11.61819 | 0.806819 |
| **8** | **64** | **47,932.290** | **18.32650** | **0.715879** |
| 10 | 100 | 68,932.808 | 29.83077 | 0.745769 |

A 4.4x span from N=1 to the optimum.  The left flank is the fixed Sobol and
peripheral cost falling as 1/N^2; the turn at N=10 is interconnect growth along
the accumulator chain and the operand broadcast overtaking it.  The optimum
migrates right as K*M grows -- at K=4/M=8 it is already at or below N=6, at
K=4/M=16 it is flat between 6 and 8, and at K*M >= 128 it is firmly 8.

**K** -- interior optimum whose location depends on M:

| at N=8 | K=4 | K=8 | K=12 |
|---|---:|---:|---:|
| M=16 | 0.843114 | **0.715879** | 0.744532 |
| M=8 | 1.009791 | 0.791400 | **0.774763** |

At M=16 the best K is 8; at M=8 it is 12.  Both land near `K*M` = 96-128, which
suggests compute density per tile is the controlling variable with an optimum
around 128 -- reached at K=8 when M=16, needing more lanes when M is halved.
`K*M` is not a complete statistic, though: K=8/M=8 and K=4/M=16 have the same
product and differ by 6.5%, so how the product is split also matters.

### N>8 is measurable again

N=10 and N=12 previously routed and closed STA but failed the drain
bit-exactness check, so the N-scaling study had no data above N=8.  The cause
was a constraint/bench mismatch, not the design: the bench launches `shift_in`
and `mac_en` at the NEGEDGE, giving them 1.25 ns, while the flow declared
`set_input_delay 0.05` and STA therefore signed off ~2.45 ns of propagation that
does not exist.  APR spent the difference, and on wide arrays `shift_in` reached
a far tile's ICG enable inside its setup window.

`INPUT_DELAY=1.25` makes the constraint match the bench.  Confirmed by direct
replication -- `k8m16n10` is the exact shape that produced
`[FAIL] streaming PaYN drain mismatch` on the original design and is now
bit-exact, along with `k4m8n10`, `k12m8n10`, `k12m16n10`.

This is a constraint fix, not an RTL fix, so it should also recover N=10/N=12 on
the original accepted design.  Those synthesis runs already exist.

### Low-corner limit (resolved 2026-07-31)

Shapes with `K*M <= 4` originally could not be measured: the gate-level run
ended in an X on the drain rail during the SAIF window.  Root-caused as **two
independent simulation-flow artifacts, not a design defect** — (1) the ARM
cells model flops as sequential UDPs that `+vcs+initreg` cannot initialize,
and on some netlists synthesis maps the `acc_low` sync reset through an
`(n & ~n)` cancellation that 4-state logic cannot resolve, so the power-up X
latches and self-sustains through the Q->D feedback; (2) without `+neg_tchk`
VCS zeroes the SDF's negative SETUPHOLD limits and manufactures false ICG
enable setup violations whose notifiers X the gated clock (k4m1n1).  Which
shapes hit (1) is per-netlist mapper luck, which is why the pass/fail pattern
was not monotonic in `K*M`.  The netlist reset function itself is verified
against random binary state by `sweeps/xcheck_reset_cone.py`, which also
reproduces every observed X bit pattern statically.

Fixed in the sweep's gate sims with
`+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +neg_tchk` (steady-state
activity, and therefore SAIF comparability, is unchanged).  Note the original
handoff's "unit-delay PASS" row was non-diagnostic — that mode logs ~10k
timing violations and completes on degraded notifier semantics.  Full
write-up: [`handoff_low_corner_gl_x.md`](handoff_low_corner_gl_x.md).

Measured low-corner points below were run without
distribution guides (which need per-row register names that multibit banking
merges away at small `K*M`) and therefore **not** recipe-comparable to the grid
above.  All 13 points are now measured; the eight `K*M <= 4` points were run
after the gate-sim fix above.

| ray | config | routed um2 | pJ/MAC |
|---|---|---:|---:|
| origin | k1m1n1 | 295.470 | 25.066480 |
| K (M=1, N=1) | k2m1n1 | 345.254 | 11.105294 |
| | k4m1n1 | 451.878 | 7.543990 |
| | k8m1n1 | 678.258 | 4.121108 |
| | k16m1n1 | 1,129.548 | 2.739192 |
| M (K=1, N=1) | k1m2n1 | 426.692 | 20.985072 |
| | k1m4n1 | 685.216 | 19.871512 |
| | k1m8n1 | 1,225.882 | 16.713452 |
| | k1m16n1 | 2,276.638 | 16.244708 |
| N (K=1, M=1) | k1m1n2 | 683.648 | 8.961216 |
| | k1m1n4 | 2,113.664 | 5.360228 |
| | k1m1n6 | 4,417.448 | 4.559156 |
| | k1m1n8 | 7,613.228 | 4.329302 |

Three readings from that corner, all three rays now sharing a measured origin
at 25.07 pJ/MAC.  Along K at M=1/N=1, energy falls **9.2x** from K=1 to K=16
and is still falling -- K amortizes the fixed RNG cost almost purely when
there is only one tile.  Along M at K=1/N=1 the same x16 buys only **1.54x**,
flattening by M=8 (16.713 to 16.245 is 2.8%), because with a single tile the
Sobol banks are M lanes each and their cost grows with M exactly as fast as
the MAC rate does.  **M only pays once N is large enough to amortize the
RNG** -- which is why it is the strongest lever at N=8 and nearly worthless at
N=1.  Along N at K=1/M=1, x64 tiles buy 5.8x and the curve is still falling
at N=8 toward the main grid's interior optimum -- pure amortization of the
per-die fixed cost, consistent with the K8/M16 N-curve above.

## Current architecture verdict

| design point | status | reason |
|---|---|---|
| pending-bit signed segmented, `LOW_W=9` | **accepted** | best clean routed PaYN checkpoint; current workload rerun complete |
| shape `K=8 / M=16 / N=8` | **accepted** | global minimum of the 18-config K x M x N sweep; interior optimum on all three axes |
| `INPUT_DELAY=1.25` constraint | **adopt** | matches the bench's negedge launch; recovers N>8, which previously failed the drain check |
| `signed_segmented_clean` RTL | neutral | -2.9% PE area, drain bit-identical, power a wash; adopt for area, not for energy |
| native 7-bit converter/Sobol | rejected | 4.83% smaller routed area, but InnerPE activity raises energy 5.02%; route also has DRC/antenna violations |
| direct / centered segmented | rejected | direct is 0.56% higher energy than pending after the clean-route rerun |
| compensated / fused / recurrent CSA heaps | rejected | compensated is 10.6% above pending; other pre-layout gains did not survive |
| 24-bit drain-chain source isolation | rejected | matched routed energy is 2.74% higher and routed wire is 4.54% longer |
| block-retired sign compensation | rejected before APR | 2.40% smaller at synthesis, but matched synthesis power is 3.35% higher |
| W-bus temporal DBI | rejected | clean routed WDBI is 21.2% above the guided baseline |
| explicit two-level A/W tree | rejected | 4.8% above simple guides and 1.4% larger |
| projected 7-bit converter | rejected | matched routed energy is 3.36% above pending |
| W-only distribution tree | rejected | matched routed energy is 3.04% above pending |
| registered-delta pipeline | rejected | matched routed energy is 24.9% above pending |
| grouped G2/G4 heaps | rejected at N=1 | both routed screens consume more energy than the lane-popcount control |
| zero-extended 7-bit power workload | invalid | halved stochastic density by comparing `0..127` directly against 8-bit thresholds |

Architecture details:

- Pending accumulator: [`signed_segmented/README.md`](../designs/payn/variants/signed_segmented/README.md)
- Wire placement: [`SC_wire_optimization.md`](SC_wire_optimization.md)
- Timing and multibit flops: [`SC_timing_multibit.md`](SC_timing_multibit.md)
- Power anatomy: [`SC_breakdown.md`](SC_breakdown.md)

## Result provenance

Accepted PaYN checkpoint:

```text
apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED/k8m16n8_lw9_distguide_spp_fixed
```

Superseded routes, retained for the measurements still quoted from them:

```text
k8m16n8_lw9_distguide_wlpwr   18.53117 mW / 0.72387   (dynamic/leakage split)
k8m16n8_lw9_distguide         18.67898 mW / 0.72965   (T sweep, energy splits)
```

Current artifacts:

```text
reports/power.rpt
reports/power_hier.rpt
reports/cell_power.rpt
activity/dut.saif
```

Reproduce the hierarchy accounting without rerunning APR or PT-PX:

```sh
python3 sweeps/report_sc_arch_energy.py \
  apr/build/TSMC22/PAYN_SC_SIGNED_SEGMENTED/k8m16n8_lw9_distguide_spp_fixed/reports/cell_power.rpt \
  --k 8 --m 16 --nh 8 --nw 8 --t 128
```

## Superseded results

The old `PAYN_SC` T sweep, tile sweep, vectorless synthesis estimates,
held-magnitude routed comparisons, and variants absent from the table above are
not current headline results.  They were generated before the long-running
`T/M` reload schedule and normalized 7-bit magnitude encoding were fixed.
Rerun any additional candidate with the current bench before using it for an
architecture decision.
