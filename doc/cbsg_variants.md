# C-BSG on the carry-save PE: A-first, routed and qualified

This page reports how the A-first (AF) design performs when it runs the deployed scmp_kernels C-BSG multiplication on the
carry-save SC PE. The PE is K8/M16/N8 in TSMC22 at 400 MHz with T = 128, except in section 3. AF is compared with the CSA
pinned pass 2 baseline route. Section 3 measures both finished routes again at shorter stream lengths and on the per-row
ladder; its T = 128 runs reproduce both headlines exactly.

AF matches the kernel bit for bit at any per-row stream length L from 1 to 128. Supporting material:
- the reference model and hardware contract: [`sweeps/cbsg/README.md`](../sweeps/cbsg/README.md);
- the design: [`signed_segmented_csa_cbsg_af`](../designs/payn/variants/signed_segmented_csa_cbsg_af/README.md);
- the per-row-generator alternative (RG), which was dropped: section 6;
- AF with the bit-plane INT mode and every-tile doubling (AF-IPD), routed and measured: section 7.

The numbers come from [`sweeps/cbsg/compare_cbsg.py`](../sweeps/cbsg/compare_cbsg.py), which reads the routed
reports, the PT runs and the GL SAIFs. The tables and number-bearing bullets of sections 1 to 3 are its output, written
into this page between the `generated` markers by the `--doc` option, so a rerun refreshes them. The qualitative claims
in section 3's prose are asserted by the script, which stops if a rerun breaks one. The figures in the remaining prose
are transcribed from the script's `tables.md` or from the logs each section names. The full generated tables, including
all RG data, every sweep point and the derived ratios, are in `build/power_char/cbsg_20261005/variants/tables.md`.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/compare_cbsg.py --doc doc/cbsg_variants.md   # ~10 s, no EDA tools
```

Single-PE figures are measured runs. Grid figures (4x4, 4x8) are composites of those runs: the PE core, one A edge per PE
row, one W edge per PE column and one stream-generator set, with no skew, drain cycles or top-level rest. They are not
grid runs.

## 1. Bottom line (2026-10-05, qualified pinned route)

<!-- BEGIN generated:bottom_line -->
| | CSA (baseline) | AF | AF vs CSA |
|---|---:|---:|---:|
| area, 1 PE (um2) | 43,916.5 | 39,932.5 | -9.1% |
| SC power, uniform L = 128 (mW) | 15.726 | 11.583 | -26.3% |
| energy per kernel MAC, 1 PE (pJ) | 0.6143 | 0.4525 | -26.3% |
| SC GMAC/s/mm2, 1 PE / 4x4 / 4x8 grid composite | 582.9 / 786.0 / 807.5 | 641.1 / 803.9 / 831.5 | +10.0% / +2.3% / +3.0% |
| energy per MAC, 4x4 / 4x8 grid composite (pJ) | 0.5317 / 0.5265 | 0.4178 / 0.4151 | -21.4% / -21.2% |
| per-row ladder (L in {128..38}), 1 PE, pJ/MAC (each block as long as its longest row; both measured) | 0.5669 (ladder-equivalent) | 0.3611 | -36.3% |
| per-row ladder on a grid (every block 8 cycles), 4x4 / 4x8 composite pJ/MAC | 0.5317 / 0.5265 (T = 128) | 0.3374 / 0.3344 (blocks held 8 cycles) | -36.5% / -36.5% |
| energy per kernel MAC at T = 16 / 32 / 64 / 96, 1 PE (pJ, measured) | 0.1212 / 0.1871 / 0.3295 / 0.4722 | 0.0995 / 0.1828 / 0.2797 / 0.3741 | -17.9% / -2.3% / -15.1% / -20.8% (4x8 grid composite at T = 32: +6.8%) |
| setup / hold WNS (ns) | +0.116 / +0.166 | +0.153 / +0.164 | |
| placement basin (corr(tile x, column), skew) | grid (0.987, 20.5 ps) | grid (0.984, 38.0 ps) | |

The grid convention is 4x8 = 4 PE rows (one A edge each) x 8 PE columns (one W edge each). Grid figures are composites of the single-PE runs (section 3). The project's symmetric (P_R + P_C)/2 formula gives -1.7% area at 4x8 instead of -2.9%; both forms are in `tables.md`. The CSA cannot give rows different stream lengths, so its single-PE ladder figure runs the AF ladder's operands with each block as long as its longest row, the same block lengths AF runs. A grid runs one block length for all its PEs, 8 cycles for this ladder in all but 0.7% of chunks, so the grid row compares AF's ladder held at 8-cycle blocks with the CSA at T = 128 (section 3.1).
<!-- END generated:bottom_line -->

## 2. Why it wins

AF keeps the CSA tile and PE core and rebuilds only the stream generation:

<!-- BEGIN generated:why -->
| part (uniform L = 128) | area change (um2) | power change (mW) | what changed |
|---|---:|---:|---|
| 64 tiles | -20 | -1.573 | A's ones come first in each block, so tile inputs toggle 0.22 per clock against the CSA's 0.34-0.35 |
| PE-local logic (pipes, glue, clock buffers) | -28 | -1.117 | same reason: the a_bits/w_bits pipes carry fewer transitions |
| A edge | +1,961 | -0.319 | 64 kA encoders (6,521 um2) and thermometer decoders (788) replace 1,024 A comparators |
| W edge | -4,251 | -0.407 | the 16 W lane words per cycle differ only by constants, so the 1,024 comparators share logic (1.2 um2 each vs 5.4) |
| stream generators | -1,615 | -0.696 | one tiny sample-ordered W bank (59 um2) replaces the CSA's A and W Sobol pair (1,674 um2) |
| edge clock buffers + top-level rest | -32 | -0.032 |  |
| **total** | **-3,984** | **-4.143** | |

Operand activity is matched: the operand ports toggle +0.3% against the CSA bench's. The power excludes the drain.

This breakdown is for T = 128. At shorter T the tile and pipe savings shrink: the tiles alone cost more than the CSA's at T = 48 and 32, and the PE core (tiles, pipes and PE clock buffers) at T = 32 (section 3.2).
<!-- END generated:why -->

## 3. Energy vs stream length (measured)

Both finished pinned routes were measured again at shorter stream lengths: the CSA at every T from 16 to 128 in steps
of 16, and AF at the same lengths and at L = 38, 42, 43, 44 and 100. Three more runs use the AF ladder's operands: the
CSA ladder-equivalent, and AF with every row at its block's longest L or with every block held for the full 8 cycles
(section 3.1). Each single-PE point is its own run on the finished route, through a PT-only view that links the route's
netlist and SPEF, and no single-PE point is interpolated. The grid columns are composites of those runs. The method is
the headline's:
- full-timing max-SDF GL on the routed netlist, with the strict audit first;
- SAIF validation, then PT-PX with the routed SPEF, drain excluded, PT coverage validated;
- every drain checked bit-exact (CSA against `cosim_streaming`, AF against `cbsg_ref`);
- one operand set for all uniform points and another for all ladder runs, each asserted on the GL traces.

The T = 128 runs (CSA) and the L = 128 and ladder runs (AF) reproduce the headline powers exactly. The script asserts
this before it uses any other point.

<!-- BEGIN generated:tsweep -->
| T or L | cycles per block | CSA mW | CSA pJ/MAC | AF mW | AF pJ/MAC | AF vs CSA, 1 PE (measured) | AF vs CSA, 4x4 / 4x8 grid composite |
|---|---:|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 24.817 | 0.1212 | 20.382 | 0.0995 | -17.9% | -11.0% / -10.9% |
| 32 | 2 | 19.161 | 0.1871 | 18.714 | 0.1828 | -2.3% | +6.4% / +6.8% |
| 38 (AF only) | 3 | - | - | 15.992 | 0.2343 | -11.5% vs CSA T = 48 | -6.2% / -6.2% |
| 42 (AF only) | 3 | - | - | 16.267 | 0.2383 | -10.0% vs CSA T = 48 | -4.7% / -4.7% |
| 43 (AF only) | 3 | - | - | 16.322 | 0.2391 | -9.7% vs CSA T = 48 | -4.4% / -4.4% |
| 44 (AF only) | 3 | - | - | 16.339 | 0.2393 | -9.6% vs CSA T = 48 | -4.3% / -4.3% |
| 48 | 3 | 18.066 | 0.2646 | 16.265 | 0.2383 | -10.0% | -4.3% / -4.3% |
| 64 | 4 | 16.870 | 0.3295 | 14.322 | 0.2797 | -15.1% | -8.6% / -8.4% |
| 80 | 5 | 16.667 | 0.4069 | 13.592 | 0.3318 | -18.5% | -13.5% / -13.4% |
| 96 | 6 | 16.119 | 0.4722 | 12.770 | 0.3741 | -20.8% | -15.8% / -15.7% |
| 100 (AF only) | 7 | - | - | 11.798 | 0.4033 | -26.7% vs CSA T = 112 | -22.6% / -22.5% |
| 112 | 7 | 16.093 | 0.5500 | 12.082 | 0.4130 | -24.9% | -20.6% / -20.6% |
| 128 | 8 | 15.726 | 0.6143 | 11.583 | 0.4525 | -26.3% | -21.4% / -21.2% |

- Each point is 384 blocks of 512 kernel MACs (N_H x N_W x K) at 400 MHz; the window is 384 x cycles per block clocks, the drain is excluded, pJ/MAC = P x window x 2.5 ns / (384 x 512). The CSA's T is a whole number of 16-position cycles; AF's L can be any length, and a block runs ceil(L / 16) cycles. The AF-only lengths are compared with the CSA point that runs the same cycles per block.
- The 1 PE column compares two measured runs. The grid columns are composites, not runs: P_R x P_C x the point's PE core + one A edge per PE row + one W edge per PE column + one stream-generator set, from its single-PE class split (the top-level rest, skew and drain cycles are left out). A grid runs one T for every PE, so every uniform point composes.
- All uniform points drive the same operands (asserted on the GL traces: each design's uniform points equal its T = 128 point, and AF's magnitudes are round(|q| x 128 / 127) of the CSA's |q| with the same signs). Operand-port toggles in the window, AF vs CSA: +0.27% at every T. At T = 16 both benches load one block fewer inside the window (operand-port toggles vs T = 32: CSA -0.25%, AF -0.26%), so the two T = 16 points stay comparable with each other. The 4 ladder runs of section 3.1 share their own operand set, asserted equal among them: the same statistics, shifted by the bench's row-length draws (operand-port toggles 196,604 to 197,137 against 196,564 / 197,101 for CSA / AF T = 128).
- Gate (asserted): CSA T = 128 reproduces the qualified baseline exactly (15.72648 mW: power.rpt total, every PT class row, SAIF identical apart from its date, trace identical), and so does the bench-copy replay (15.72648 mW). AF L = 128 (11.58301 mW) and the ladder (10.08399 mW) reproduce the AF pinned measurement (total and every class row; AF gate: SAIF identical apart from its date, traces identical).
- All 26 runs: strict max-SDF GL audit PASS with 0 approvals and 0 post-reset violations; SDF warnings only SDFCOM_UHICD x192; worst clock-gate CK->ECK 0.039 ns; drains bit-exact (CSA vs the cosim_streaming cycle reference, its per-block-cycles copy for the ladder and replay; AF vs cbsg_ref); routed-SDF clock audit and PT coverage PASS. The AF checker's negative controls (each L relabelled L - 1, a drain off by one LSB) fail at all 13 lengths; the CSA bench copy's RTL checks: ALL RTL CHECKS PASS; the AF ladder-variant bench's RTL checks: ALL RTL CHECKS PASS (5 negative controls fail as required).
<!-- END generated:tsweep -->

Reading the table:

<!-- BEGIN generated:tsweep_reading -->
- **On one PE, AF uses less energy per MAC than the CSA at every T, but the margin is not monotonic** (both runs measured at every T). It is largest at T = 128 (-26.3%) and smallest at T = 32 (-2.3%); section 3.2 explains why.
- **In the grid composites the margin is smaller at every T**, because the edges, where AF saves at every T, are shared by a row or a column of PEs, so the PE core decides. At T = 32 the composite puts AF above the CSA (+6.4% / +6.8% at 4x4 / 4x8). These are modelled grid figures built from the single-PE runs, not grid runs.
- **AF lengths that are not a multiple of 16** run as many cycles as the next multiple of 16. With a uniform L, the cycle count sets the energy: within one cycle count the energy per block spans 2.2% (L = 38-48, 3 cycles), 2.4% (L = 100-112, 7 cycles), because those lengths fill 79-100% of their block. A row that fills less of its block costs less (section 3.1). They are compared with the CSA at the same cycles.
<!-- END generated:tsweep_reading -->

### 3.1 The per-row ladder

The CSA cannot give rows different stream lengths. Its fair single-PE counterpart runs the AF ladder's operands with
each block as long as that block's longest row, which is how long AF's block runs too. Two more AF runs on the same
operands split the saving and carry it to a grid:
- every row at its block's longest L: the A-first design at the ladder's block lengths, without the shorter rows;
- every block held for the full 8 cycles: the block length a grid runs, because all its PEs share one stream
  generator and every W edge feeds a whole PE column.

All of these are measured runs; none is interpolated from a T sweep.

<!-- BEGIN generated:tsweep_ladder -->
**One PE** (each line is a measured run):

| run | window clocks | cycles per block | mW | pJ per block | pJ/MAC | mean kA | AF ladder vs this |
|---|---:|---:|---:|---:|---:|---:|---:|
| AF ladder (rows L in {128, 96, 64, 48, 44, 42, 38}) | 2,816 | 7.33 | 10.084 | 184.87 | 0.3611 | 33.8 | - |
| AF ladder, every row at its block's longest L (same operands, same block cycles) | 2,816 | 7.33 | 11.890 | 217.99 | 0.4258 | 58.4 | -15.2% |
| CSA ladder-equivalent (same operands, same block cycles) | 2,816 | 7.33 | 15.831 | 290.23 | 0.5669 | - | -36.3% |
| CSA fixed T = 128 | 3,072 | 8 | 15.726 | 314.53 | 0.6143 | - | -41.2% |
| AF ladder, every block held 8 cycles (the grid block length) | 3,072 | 8 | 9.571 | 191.42 | 0.3739 | 33.8 | -3.4% |
| AF uniform L = 128 (reference) | 3,072 | 8 | 11.583 | 231.66 | 0.4525 | 64.3 | -20.2% |

- CSA ladder-equivalent: the AF ladder's operands and signs, each block run for ceil(max row L / 16) cycles (16 blocks x 4, 96 blocks x 6, 272 blocks x 8 cycles), so its window equals AF's (2,816 clocks). Asserted: the stimulus was built from the AF ladder trace (sha256), and its block cycles and operands equal that trace's.
- Where the -36.3% comes from, both parts measured: AF with every row at its block's longest L costs 217.99 pJ per block, -24.9% against the CSA ladder-equivalent (the A-first design at the same block lengths). The AF ladder is a further -15.2% below that, from its shorter rows.
- Cross-check: the uniform points weighted by this cycle mix give 290.27 pJ per block for the CSA (measured ladder-equivalent 290.23, -0.01%) and 217.95 for AF (measured with every row at its block's longest L 217.99, +0.02%). The ladder runs drive a different operand draw from the uniform points, so this also shows that the draw does not matter.
- Why the shorter rows save: a row's A stream has kA ones, about b x L / 128 (mean kA 33.8 against 58.4 with every row at its block's longest L), and they come first in the block, so fewer tile products see an A one. Tile energy per block: 91.3 pJ against 124.4 with every row at its block's longest L (-26.7%; the uniform points' cycle mix: 124.6). The tile input toggles hardly change (a_bits 0.228 per clock against 0.232; the uniform points' cycle mix: 0.233), so the saving is in the products, not in the inputs. The effect is large here because a ladder row fills on average 58% of its block (down to 30%: a 38-row in a block of 8 cycles), while a uniform-L row fills 79-100% of its block.

**On a grid** (composites of measured single-PE runs): a grid with one stream generator runs one block length for every PE, because each W edge feeds every PE row of its column. Its block is as long as the longest of all its A rows: with the ladder drawn per row, 8 cycles in all but 0.7% of the chunks of a 4-PE-row grid (32 rows; one PE alone: 29% of chunks shorter). So the grid composite uses the AF ladder run with every block held 8 cycles (measured: the ladder's operands and row lengths, drain identical, since the held cycles add zero), and the CSA's counterpart is T = 128.

| | AF ladder, blocks held 8 cycles, pJ/MAC | CSA T = 128, pJ/MAC | AF vs CSA |
|---|---:|---:|---:|
| 1 PE (measured) | 0.3739 | 0.6143 | -39.1% |
| 4x4 grid composite | 0.3374 | 0.5317 | -36.5% |
| 4x8 grid composite | 0.3344 | 0.5265 | -36.5% |

- Holding every block for 8 cycles costs AF +3.5% per block against the unheld ladder (191.42 against 184.87 pJ): the extra cycles clock the PE and the edges but add no products. Against its own uniform L = 128, the held ladder is -17.4% at 1 PE and -19.4% in the 4x8 composite.
- The single-PE figures above (-36.3% against the CSA ladder-equivalent) give each PE its own block length, which a grid cannot run, so they have no grid composite.
<!-- END generated:tsweep_ladder -->

### 3.2 Where the savings come from as T falls

<!-- BEGIN generated:tsweep_classes -->
| T | CSA pJ per block | AF pJ per block | AF vs CSA | tiles | PE pipes + glue | A edge | W edge | stream generators | other | tile a_bits toggles per clock, AF / CSA | tile w_bits, AF / CSA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 128 | 314.53 | 231.66 | -26.3% | -10.0 | -7.1 | -2.0 | -2.6 | -4.4 | -0.2 | 0.217 / 0.343 | 0.221 / 0.354 |
| 112 | 281.62 | 211.43 | -24.9% | -9.4 | -7.2 | -0.7 | -3.1 | -4.3 | -0.2 | 0.244 / 0.354 | 0.208 / 0.363 |
| 96 | 241.78 | 191.56 | -20.8% | -6.9 | -5.4 | -0.9 | -3.0 | -4.3 | -0.2 | 0.277 / 0.347 | 0.233 / 0.357 |
| 80 | 208.33 | 169.89 | -18.5% | -5.5 | -4.7 | -0.6 | -3.2 | -4.2 | -0.2 | 0.320 / 0.361 | 0.242 / 0.371 |
| 64 | 168.70 | 143.22 | -15.1% | -2.1 | -3.6 | -1.2 | -3.8 | -4.1 | -0.2 | 0.377 / 0.354 | 0.225 / 0.364 |
| 48 | 135.50 | 121.99 | -10.0% | +0.1 | -2.6 | +0.4 | -3.8 | -3.8 | -0.2 | 0.452 / 0.381 | 0.239 / 0.389 |
| 32 | 95.80 | 93.57 | -2.3% | +5.8 | +1.0 | -0.7 | -4.7 | -3.6 | -0.2 | 0.535 / 0.376 | 0.324 / 0.385 |
| 16 | 62.04 | 50.96 | -17.9% | -1.0 | -5.3 | -1.5 | -7.2 | -2.8 | -0.1 | 0.339 / 0.477 | 0.344 / 0.481 |

- 'other' = PE clock buffers + edge clock buffers + top-level rest. A edge = registers + A-side logic (CSA comparators, AF kA encoders + thermometers); the stream generators (CSA A and W Sobol banks, AF W bank) are separate. The class columns add up to 'AF vs CSA'.
- PE core (tiles + pipes + PE clock buffers), percentage points by T: 128: -17.1, 112: -16.6, 96: -12.4, 80: -10.3, 64: -5.8, 48: -2.6, 32: +6.8, 16: -6.3.
- Edges + stream generators by T: 128: -9.0, 112: -8.1, 96: -8.2, 80: -7.9, 64: -9.1, 48: -7.2, 32: -9.0, 16: -11.5 (a saving at every T, -7.2 to -11.5; of which the A edge -2.0 to +0.4).
- The tiles alone cost more than the CSA's at T = 48 (+0.1 points) and 32 (+5.8 points). The whole PE core (tiles, pipes and PE clock buffers) costs more only at T = 32 (+6.8 points); at T = 32 AF's tile a_bits toggle 0.535 per clock against 0.376. In the grid composites the edges are shared, so there AF vs CSA at T = 32 is +6.4% / +6.8% (4x4 / 4x8).
- Tile a_bits toggles per clock: the CSA's stay at 0.343-0.381 from T = 32 up; AF's fall from 0.535 to 0.217 as the blocks lengthen. With 2-4 cycles per block (T = 32, 48, 64) AF's toggle more than the CSA's; at T = 16 less (0.339 against 0.477), and the PE core saves again (-6.3 points).
- AF's tile w_bits toggle less than the CSA's at every T (0.208-0.344 against 0.354-0.481 per clock).
<!-- END generated:tsweep_classes -->

- **Together, the edges and stream generators save at every T.** The W comparators share logic and one small W bank
  replaces the CSA's two Sobol banks; the A edge's encoders cost about what the CSA's A comparators do. None of this
  depends on the order of the ones in the stream.
- **The PE-core saving comes from the ones-first A stream, and it needs long blocks.** In an 8-cycle block a row's A
  stream is 1 for its first kA positions and 0 after, so most tile inputs keep their value from one cycle to the next
  and the tiles see few toggles. With 2 to 4 cycles per block, the A bits flip between a full first cycle and an empty
  last cycle in nearly every block, more often than the CSA's.
- **At T = 16 the PE core saves again.** With one cycle per block, AF's A bits change only where consecutive blocks'
  kA values differ, which is less often than the CSA's comparator outputs change.

### 3.3 What "per MAC" means at shorter T

<!-- BEGIN generated:tsweep_permac -->
- Every block is the same 512 kernel MACs at every T; T sets how many stream positions each product gets. One PE finishes a block every T / 16 cycles: 204.8 GMAC/s at T = 16, 25.6 GMAC/s at T = 128, in the same area, so GMAC/s/mm2 scales by 128 / T for both designs and their area ratio does not change.
- A T-position stream resolves each operand to about 1/T of full scale, about log2(T) bits: 4 at T = 16, 7 at T = 128. So a pJ/MAC at short T is the energy of a lower-precision MAC: compare designs at the same T, not one T with another.
- Power rises as T falls (CSA 15.726 -> 24.817 mW, AF 11.583 -> 20.382 mW from T = 128 to 16): operand loads and the edge logic's switch to new operands come 8x as often (edges + edge clock buffers: CSA 1.784 -> 6.076 mW, AF 1.061 -> 3.945 mW), and the tiles see more input toggles (tiles: CSA 8.216 -> 11.398 mW, AF 6.643 -> 11.145 mW). Energy per block still falls (CSA -80.3%, AF -78.0%), because a block takes 16/128 of the cycles.
<!-- END generated:tsweep_permac -->

Files: the sweep scripts are in `sweeps/cbsg/tsweep/` and the runs in `build/power_char/cbsg_20261005/tsweep/{csa,af}/`.
The two AF ladder variants use the bench copy `designs/payn/power/power_payn_array_cbsg_af_lvar.sv` and its checker
`check_af_power_trace_lvar.py`; they are run by `run_af_lvar_point.sh`, proved on RTL by `run_af_lvar_rtl_checks.sh`,
and stored in `tsweep/af/ladder_variants/`. Every point, with its absolute class split, activity and grid composites,
is in `tables.md` and `tsweep.csv` under `build/power_char/cbsg_20261005/variants/`. `tables.md` also compares the CSA
points with the earlier floating-route T sweep in `doc/results.md`; that sweep is on a different route and is not used
here.

## 4. Bit-exactness and timing

- **RTL.** The kernel reference self-test agrees exactly over 25.8M MACs. That covers every L from 1 to 128, 118
  trace ladders, chunked calls with tails, per-head calls and back-to-back calls. The AF suite has 43 must-pass runs
  (321,728 drained accumulators) and 22 negative controls, and every negative control fails as it should.
- **Synthesized and routed netlists.** Every power run drains bit-exact against the kernel. The routed functional
  bench passes 6 of 6. The full-timing max-SDF GL audit passes strictly, with no approvals.
- **Pre-layout workarounds are not needed after CTS.** No ideal-clock view and no 2-edge reset settle are used; the
  worst clock-gate CK->ECK delay is 0.038 ns.
- **Timing.** Setup slack is +0.153 ns. The worst path is the `shift_in` port into the tile clock gate, as in the CSA.
  The kA encoder path has 1.49 ns of slack at synthesis.

## 5. The routing fix (what made the pinned route qualify)

The first pinned route left about 69k M1 markers after the flow's second filler pass. That pass inserts fillers
"without DRC checking", and every route in the repo relies on the router's search-and-repair to clean up the overlaps.
Here the router skipped that repair because of NanoRoute's auto-stop: it gives up when the marker count exceeds about
one marker per routable net.
- AF reached 1.09 markers per net; the CSA was at 0.99.
- AF has fewer nets than the CSA, because the encoders replace 1,024 comparators, but the same number of fillers.

Two other fixes were tried first and did not qualify: moving the 64 per-row L pins to the south edge, and using the
CSA's die. The fix that qualified is a hook that reruns the flow's own strong reroute with auto-stop off for that one
command (36 iterations, 0 left). The 191 + 3 residual via-swap markers then went through the standard targeted repair.
Placement, the pin plan, the die and the knobs are unchanged. This is recorded as a deviation from the CSA baseline,
whose targeted repair handled 1 + 1 markers.

Details are in `build/power_char/cbsg_20261005/af/pinned_fix/README.txt`. To reproduce:
`bash sweeps/cbsg/af/run_af_pinned_fix.sh postfill <dir>`, then `sweeps/cbsg/af/run_af_route_measure.sh`.

## 6. The dropped alternative: per-row W generators (RG)

RG is soren's literal gating: a W-index generator per (row, lane) and 8,192 per-tile W comparators. It was dropped:
- **Area:** 2.08x the CSA's at 1 PE. Measured on an unqualified route, it reaches 288 GMAC/s/mm2 at 4x4.
- **Energy:** about 3x the CSA's per MAC. This is indicative only, from a collapsed bootstrap route.
- **Timing:** both final routes miss setup by about 30 ps.
- **Grid shape doesn't help.** Moving the generators to the A edge halves their share per PE from 4x4 to 4x8, but
  the per-tile comparators never amortize, so per-PE area falls only about 3%.

## 7. A-first + INT with every-tile doubling

AF-IPD ([`signed_segmented_csa_cbsg_af_ipd`](../designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/README.md)) is
one top with two modes:
- **SC mode** is AF, edge for edge. The RTL suite runs it in lockstep with the AF top, so it stays bit-exact with the
  kernel at any per-row L.
- **INT mode** is the bit-plane (BP) INT contract of
  [`signed_segmented_csa_bp`](../designs/payn/variants/signed_segmented_csa_bp/README.md). The raw bit planes enter
  through a bypass OR placed after AF's thermometers and W comparators, whose magnitudes are held at 0 in INT mode.
- **The laps** are those of [`signed_segmented_csa_bp_ipd`](../designs/payn/variants/signed_segmented_csa_bp_ipd/README.md).
  A 24-bit mux per tile loads the tile's own accumulator shifted left by one, so a single `ring_q` edge doubles every
  tile in place. A lap takes 1 edge instead of the BP ring's 8.

The CSA tile is unchanged. Every other block is a suffixed copy of an AF, BP or IPD file; the source hashes are in
the variant README. The route is pinned pass 2 with AF's post-fill hook (section 5), final-qualified, in the grid
basin. It uses the synthesis of record, which carries the kA encoder remap: once the INT bypass is present, DC maps
the unchanged encoders to larger adder trees. Sections 7.1 and 7.2 show what that costs, and whether to fix it on
the synthesis side is still open.

The tables and number-bearing bullets of this section are written between the `af_ipd` markers by
[`sweeps/cbsg/af_ipd/report_af_ipd.py`](../sweeps/cbsg/af_ipd/report_af_ipd.py). Its marker prefix differs from
`compare_cbsg.py`'s, so neither script touches the other's blocks. It reads:
- the AF-IPD campaign (`build/power_char/cbsg_20261005/af_ipd/`);
- the AF and CSA measurements, and `compare_cbsg.py`'s outputs, whose CSA and AF grid composites it recomputes
  before it uses its own;
- the BP lap route's SC and INT results, and the lap-schedule model's composites, periods and bandwidth cases;
- the logs of the RTL, synthesized and routed GL checks.

It stops if an input disagrees with another, and it asserts the qualitative claims made in this section's prose.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/af_ipd/report_af_ipd.py --doc doc/cbsg_variants.md   # seconds, no EDA tools
```

<!-- BEGIN af_ipd:summary -->
- **Area.** 44,430.6 um2 for one PE: +1.2% against the CSA and +11.3% against AF. In the 4x4 / 4x8 grid composites it is +3.3% / +1.5% against the CSA. The kA encoder remap is 1,897.6 um2 of it per A edge.
- **SC mode.** 0.4714 pJ/MAC at uniform L = 128 (-23.3% against the CSA, +4.2% against AF) and 0.3779 on the per-row ladder (-33.3% against the CSA ladder-equivalent, +4.7% against AF). Carrying INT adds +0.484 mW to AF's SC power, +0.161 of it the encoder remap.
- **INT energy, one PE.** With laps at L = 1024, energy per MAC against the routed BP lap route is -13.8% / -11.0% / -11.1% (INT8 / W4A8 / INT4); without laps (peak) it is +1.1% / +1.2% (INT8 / INT4).
- **INT throughput with 1-edge laps (compute-bound).** INT8 on 4x4: 893.6 against 624.5 GMAC/s/mm2 at L = 1024 (+43.1%), 1,294.3 against 1,127.7 at L = 4096 (+14.8%). An SRAM sized for SC can take that gain away (section 7.6): with section 10's wider reading and prefetch it is up to +39% at L = 1024 on the grids and none at L = 4096; with the narrower one, essentially none.
<!-- END af_ipd:summary -->

### 7.1 Area

Grid figures follow section 1's convention: composites of the single-PE route, not grid runs. The combiner is
counted once per PE row, as in the INT doc's composites.

<!-- BEGIN af_ipd:area -->
| | CSA | AF | AF-IPD | AF-IPD vs CSA | AF-IPD vs AF |
|---|---:|---:|---:|---:|---:|
| area, 1 PE route (um2) | 43,916.5 | 39,932.5 | **44,430.6** | +1.2% | +11.3% |
| area, 4x4 grid composite (um2) | 521,100.2 | 509,517.8 | **538,299.2** | +3.3% | +5.6% |
| area, 4x8 grid composite (um2) | 1,014,548.4 | 985,174.3 | **1,030,200.4** | +1.5% | +4.6% |
| area per PE in the 4x8 composite (um2) | 31,704.6 | 30,786.7 | 32,193.8 | | |
| SC GMAC/s/mm2, 1 PE / 4x4 / 4x8 | 582.9 / 786.0 / 807.5 | 641.1 / 803.9 / 831.5 | **576.2 / 760.9 / 795.2** | -1.2% / -3.2% / -1.5% | -10.1% / -5.3% / -4.4% |
| AF-IPD without the kA encoder remap (estimate), 1 PE / 4x4 / 4x8 (um2) | | | 42,533 / 530,709 / 1,022,610 | -3.2% / +1.8% / +0.8% | +6.5% / +4.2% / +3.8% |

Where the area goes (route cell area, um2) and how each part scales on a grid:

| part | one per | AF-IPD | AF | change |
|---|---|---:|---:|---:|
| PE core: tiles, bit/sign pipes, PE clock buffers | PE | 28,979.7 | 29,172.3 | -192.7 |
| PE core: per-tile doubling muxes + lap select tree | PE | 1,104.8 | - | +1,104.8 |
| A edge: 64 kA encoders (DC remap with the INT bypass; RTL unchanged) | PE row | 8,419.0 | 6,521.4 | +1,897.6 |
| A edge: thermometers (+ A bypass, merged), registers, encoder input buffers | PE row | 2,416.6 | 1,890.0 | +526.6 |
| W edge: comparators (+ W bypass, merged), registers | PE column | 2,589.7 | 2,185.7 | +404.1 |
| combiner | PE row | 701.8 | - | +701.8 |
| edge clock buffers, leftovers, shared bypass select | half per edge | 95.6 | 78.1 | +17.5 |
| W bank (AF block clock) | grid | 57.3 | 59.3 | -2.0 |
| top-level rest (not in the composites) | - | 66.1 | 25.6 | +40.5 |
| **total** | | **44,430.6** | **39,932.5** | **+4,498.1** |

- Per PE the INT hardware adds +912.1 um2 (+3.1% of the PE core): the doubling muxes and lap select (1,104.8), less 192.7 by which the rest of the core (tiles, pipes, clock buffers) routed smaller than AF's. Per PE row it adds +3,125.9 (A edge and combiner), of which 1,897.6 is the kA encoder remap; per PE column +404.1 (W edge).
- So the overhead over AF shrinks on a grid (+11.3% at 1 PE, +5.6% at 4x4, +4.6% at 4x8). Against the CSA, AF-IPD's PE core is +864.1 um2 (+3.0%), each PE row's A edge and combiner +5,090.7 and each PE column's W edge -3,843.0, so AF-IPD is +1.2% at 1 PE, +3.3% at 4x4, and +1.5% at 4x8, where the eight W edges win part of it back.
- Without the remap (the encoders mapped as in AF, 1,897.6 um2 less per A edge) AF-IPD would be -3.2% / +1.8% / +0.8% against the CSA at 1 PE / 4x4 / 4x8. This is an estimate: it assumes the routed encoders would shrink by exactly the routed difference.
- The composite is compare_cbsg.py's (section 1) plus one combiner per PE row, and it reproduces that script's CSA and AF composites (asserted). The symmetric form, (P_R + P_C)/2 x the whole peripheral, gives 538,299.2 / 1,046,692.0 um2 for AF-IPD at 4x4 / 4x8 (+1.6% at 4x8), because AF-IPD's A edge is 4.2x its W edge.
<!-- END af_ipd:area -->

### 7.2 SC power

The stimulus is the AF campaign's (uniform L = 128 and the per-row ladder), measured the same way: full-timing
max-SDF GL on the routed netlist, PT-PX with the routed SPEF, drain excluded, drains bit-exact.

<!-- BEGIN af_ipd:sc -->
| | CSA | AF | AF-IPD | AF-IPD vs CSA | AF-IPD vs AF |
|---|---:|---:|---:|---:|---:|
| SC power, uniform L = 128, 1 PE (mW) | 15.726 | 11.583 | **12.067** | -23.3% | +4.2% |
| energy per kernel MAC, uniform, 1 PE (pJ) | 0.6143 | 0.4525 | **0.4714** | -23.3% | +4.2% |
| energy per MAC, uniform, 4x4 / 4x8 grid composite (pJ) | 0.5317 / 0.5265 | 0.4178 / 0.4151 | **0.4294 / 0.4255** | -19.2% / -19.2% | +2.8% / +2.5% |
| per-row ladder, 1 PE (mW; CSA: ladder-equivalent) | 15.831 | 10.084 | **10.553** | -33.3% | +4.7% |
| per-row ladder, 1 PE (pJ/MAC) | 0.5669 | 0.3611 | **0.3779** | -33.3% | +4.7% |

Where the SC power difference to AF goes (PT cell power by class, mW; rows add up to the PT totals):

| part | AF-IPD, uniform | AF, uniform | change, uniform | change, ladder |
|---|---:|---:|---:|---:|
| 64 kA encoders (the DC remap) | 0.400 | 0.239 | +0.161 | +0.168 |
| PE bit/sign pipes + core glue | 2.718 | 2.569 | +0.149 | +0.174 |
| 64 tiles | 6.708 | 6.643 | +0.065 | +0.028 |
| per-tile doubling muxes + lap select | 0.062 | 0.000 | +0.062 | +0.039 |
| thermometers (+ A bypass, merged) | 0.246 | 0.202 | +0.044 | +0.058 |
| W comparators (+ W bypass, merged) | 0.382 | 0.401 | -0.018 | -0.017 |
| combiner | 0.012 | 0.000 | +0.012 | +0.008 |
| A / W registers, encoder input buffers, W bank, edge clock buffers, shared select | 0.259 | 0.248 | +0.011 | +0.012 |
| PE clock buffers + top-level rest | 1.282 | 1.282 | +0.000 | +0.000 |
| **total** | **12.067** | **11.583** | **+0.484** | **+0.469** |

- Same stimulus as the AF campaign (asserted: blocks, window, mean kA and A-one density equal AF's for both workloads); drains bit-exact; power excludes the drain.
- The kA encoder remap costs +0.161 mW of the +0.484 mW. Without it AF-IPD would be +0.323 mW (+2.8%) over AF at uniform L = 128 (estimate).
- The pipes and core glue carry the same flops in both designs; their +0.149 mW is attributed to longer broadcast wiring on a die 5.6% wider (273.56 x 272.02 um against 259.14 x 258.72); the register-level split is in `build/cbsg/af_ipd/route_debug/core_{af,afipd}/`.
- The ladder has no grid composite here: a grid runs one block length (section 3.1), and AF-IPD has no held-ladder run.
<!-- END af_ipd:sc -->

### 7.3 INT energy against the BP lap route

These are the BP lap campaign's seven points, run with its operands and windows on the AF-IPD route. Every tile and
combiner word is bit-exact, and every GL trace is byte-identical to RTL. The only difference in the schedule is the
lap length.

<!-- BEGIN af_ipd:int -->
| point | window | MAC/cycle, AF-IPD / BP lap | power (mW), AF-IPD / BP lap | pJ/MAC AF-IPD | pJ/MAC BP lap | AF-IPD vs BP lap | PE core (u_pe) pJ/MAC, AF-IPD / BP lap |
|---|---|---:|---:|---:|---:|---:|---:|
| INT8, L = 49,152 | data only (peak) | 128.0 / 128.0 | 18.028 / 17.825 | **0.3521** | 0.3481 | +1.1% | 0.3383 / 0.3353 |
| INT8, L = 1024 | data + laps | 115.4 / 68.3 | 18.026 / 12.378 | **0.3906** | 0.4533 | -13.8% | 0.3741 / 0.4350 |
| INT8, L = 1024 | data + laps + drain | 103.7 / 64.0 | 16.872 / 12.019 | **0.4068** | 0.4695 | -13.4% | 0.3883 / 0.4492 |
| W4A8, L = 1024 | data + laps | 234.1 / 146.3 | 18.212 / 12.789 | **0.1945** | 0.2186 | -11.0% | 0.1864 / 0.2097 |
| INT4, L = 98,304 | data only (peak) | 512.0 / 512.0 | 18.084 / 17.873 | **0.0883** | 0.0873 | +1.2% | 0.0848 / 0.0841 |
| INT4, L = 1024 | data + laps | 468.1 / 292.6 | 18.210 / 12.801 | **0.0972** | 0.1094 | -11.1% | 0.0932 / 0.1050 |
| INT4, L = 1024 | data + laps + drain | 381.0 / 256.0 | 15.907 / 11.930 | **0.1044** | 0.1165 | -10.4% | 0.0995 / 0.1113 |

- Same operands, block counts and windows as the BP lap campaign (asserted per point: blocks, data and drain cycles, MACs, tiles and outputs checked, max |tile| and |output|). INT8 L = 1024 runs 48 blocks, W4A8 and INT4 96, all with 3,072 data cycles. Every MAC/cycle equals peak x data / (data + laps [+ drain]) with BW - 1 lap cycles per block for AF-IPD and 8 (BW - 1) for BP lap (asserted).
- **The gain comes from the laps.** INT8 at L = 1024 has 7 lap cycles per block instead of 56, so the array does MACs in 90% of its cycles instead of 53%. Power per cycle is 45.6% higher and MACs per cycle 69.0% higher, so energy per MAC is 13.8% lower.
- **Without laps (the peak points) AF-IPD costs slightly more**: INT8 +1.1%, INT4 +1.2%. At INT8 peak the PE core draws 0.154 mW more (doubling muxes that see every acc_out toggle, and longer wires) and the peripheral 0.090 mW more (the bypass sits in larger merged gates that the raw planes drive), against 0.035 mW saved by the frozen AF block clock in place of BP's Sobol banks.
- INT density on one PE at INT8 L = 1024 (data + laps window, the SC convention): 1,039 GMAC/s/mm2 against 592 for BP lap. Section 7.4 includes the drain and the grids.
<!-- END af_ipd:int -->

### 7.4 INT throughput with 1-edge laps

<!-- BEGIN af_ipd:tput -->
| precision | grid | L | edges per block, AF-IPD / BP lap | % of peak, AF-IPD / BP lap | GMAC/s/mm2 AF-IPD | GMAC/s/mm2 BP lap | AF-IPD vs BP lap | AF-IPD period run bit-exact in RTL |
|---|---|---:|---:|---:|---:|---:|---:|---|
| INT8 | 1 PE | 1024 | 79 / 128 | 81.0% / 50.0% | **933.6** | 555.4 | +68.1% | AF-IPD top |
| INT8 | 1 PE | 4096 | 271 / 320 | 94.5% / 80.0% | **1,088.6** | 888.6 | +22.5% | AF-IPD top |
| INT8 | 4x4 | 1024 | 109 / 158 | 58.7% / 40.5% | **893.6** | 624.5 | +43.1% | IPD grid, IPD grid copy |
| INT8 | 4x4 | 4096 | 301 / 350 | 85.0% / 73.1% | **1,294.3** | 1,127.7 | +14.8% | IPD grid, IPD grid copy |
| INT8 | 4x8 | 1024 | 145 / 194 | 44.1% / 33.0% | **702.0** | 525.0 | +33.7% | IPD grid |
| INT8 | 4x8 | 4096 | 337 / 386 | 76.0% / 66.3% | **1,208.1** | 1,055.4 | +14.5% | IPD grid |
| W4A8 | 1 PE | 1024 | 43 / 64 | 74.4% / 50.0% | **1,715.1** | 1,110.7 | +54.4% | AF-IPD top |
| W4A8 | 1 PE | 4096 | 139 / 160 | 92.1% / 80.0% | **2,122.3** | 1,777.1 | +19.4% | - (formula) |
| W4A8 | 4x4 | 1024 | 73 / 94 | 43.8% / 34.0% | **1,334.2** | 1,049.7 | +27.1% | - (formula) |
| W4A8 | 4x4 | 4096 | 169 / 190 | 75.7% / 67.4% | **2,305.3** | 2,077.4 | +11.0% | IPD grid, IPD grid copy |
| W4A8 | 4x8 | 1024 | 109 / 130 | 29.4% / 24.6% | **933.8** | 783.5 | +19.2% | - (formula) |
| W4A8 | 4x8 | 4096 | 205 / 226 | 62.4% / 56.6% | **1,986.0** | 1,802.6 | +10.2% | IPD grid |
| INT4 | 1 PE | 1024 | 43 / 64 | 74.4% / 50.0% | **3,430.3** | 2,221.4 | +54.4% | AF-IPD top |
| INT4 | 1 PE | 4096 | 139 / 160 | 92.1% / 80.0% | **4,244.7** | 3,554.3 | +19.4% | - (formula) |
| INT4 | 4x4 | 1024 | 73 / 94 | 43.8% / 34.0% | **2,668.4** | 2,099.5 | +27.1% | - (formula) |
| INT4 | 4x4 | 4096 | 169 / 190 | 75.7% / 67.4% | **4,610.5** | 4,154.8 | +11.0% | IPD grid, IPD grid copy |
| INT4 | 4x8 | 1024 | 109 / 130 | 29.4% / 24.6% | **1,867.6** | 1,566.9 | +19.2% | - (formula) |
| INT4 | 4x8 | 4096 | 205 / 226 | 62.4% / 56.6% | **3,972.0** | 3,605.3 | +10.2% | IPD grid |

- Block period on a P_R x P_C grid: `BW*NB + LAP*(BW-1) + (P_R+P_C-2) + 8*P_C` edges, NB = L/128, LAP = 1 for AF-IPD and 8 for BP lap; % of peak = BW*NB / period. 1 PE has no skew and an 8-edge drain, so its rows include the drain (section 7.3's 'data + laps + drain').
- The last column names the RTL benches that ran that exact schedule bit-exact: 'AF-IPD top' is this variant's single-PE INT matrix, 'IPD grid copy' this variant's renamed copy of the IPD grid wrapper (4x4 only), 'IPD grid' the original IPD grid bench (`build/rtl_preflight/bp_ipd/grid/periods.txt`). Every listed period equals the formula (asserted). No AF-IPD grid exists (section 7.6).
- GMAC/s/mm2 = P_R x P_C x peak x % of peak x 0.4 GHz / area, with peak 128 / 256 / 512 MAC per PE per data edge (INT8 / W4A8 / INT4). AF-IPD uses its route area at 1 PE and the split composites of section 7.1 on grids. BP lap uses its route and the INT doc's routed symmetric composites (531,321.5 / 1,029,540.4 um2; reproduced here, and its periods and GMAC/s/mm2 equal `model_lap_schedules.csv`'s T1 rows, asserted). BP lap keeps the CSA's comparator edges, whose two forms differ by 0.003% at 4x8 (`compare_cbsg.py`'s grid.csv); AF-IPD in the symmetric form would read 1,294.3 / 1,189.1 at INT8 L = 4096 on 4x4 / 4x8.
- The laps drop from 8 (BW - 1) to BW - 1 edges; the skew and the 8 P_C drain are unchanged and now dominate what is left on grids: at INT8 L = 1024 on 4x8 the 64-edge drain and 10 skew edges are 51% of the 145-edge block (4x4: 35%).
- INT8 peak, no laps, skew or drain: 1,152.4 / 1,521.8 / 1,590.4 GMAC/s/mm2 at 1 PE / 4x4 / 4x8 (BP lap 1,110.7 / 1,541.8 / 1,591.4). On grids AF-IPD's larger PE core outweighs its smaller edges, so the 1-edge laps are what puts it ahead.
- The IPD estimate on the Sobol edge (`model_lap_schedules.csv` T3: routed BP lap + synthesized IPD delta) has the same periods; AF-IPD's composites from its own route land 1.6% to 2.9% above that estimate on the grids.
<!-- END af_ipd:tput -->

### 7.5 Verification

<!-- BEGIN af_ipd:verify -->
| level | what ran | result |
|---|---|---|
| provenance (`check_copies.sh`, in the RTL run) | 30 recorded sources unchanged since the copy (the record now holds 62, with the synthesis and route scripts); 5 RTL copies rename-only; the peripheral is the AF one plus the INT bypass (42 lines added, 2 changed) | PASS |
| kernel reference and units | golden cases 12 shipped, 24 extra (7,110 blocks), 7 review (657 blocks); kA encoder 1,056,768 cases, stream generator 3,013, INT silence 32,768, copied peripheral vs the original 32,001, L = 0 gate point 16,384 | PASS, 0 wrong |
| RTL, SC mode (lockstep against the AF top every edge, random INT inputs) | 94 runs: 65 passing (170,882 blocks, 1,187,008 drained accumulators and 10,936,448 kA values bit-exact, 1,503,789 lockstep edges identical) and 29 negative controls caught; SC traces byte-identical to the AF top's in 7 of 7 runs | PASS |
| RTL, INT mode | 72 cases: 47 positive runs bit-exact, 25 negative controls caught (2 of them SC strobes in INT mode, which stay bit-exact and are flagged by the AF contract monitor); block period `BW*NB + (BW-1) + 8` in 49 rows, 0 mismatches; 30,144 tile laps (1,693 folding a pending carry, 289 a borrow); 114,853 INT MACs with the AF streams silent; 15 cases byte-identical to the IPD top | PASS |
| RTL, SC <-> INT switching (no reset) | 17 runs: 11 bit-exact, 6 negative controls caught | PASS |
| RTL, IPD grid wrapper (rename check) | 51 cases on 2x2 and 4x4; evidence for the copied lap wave only, not for AF + INT on a grid | PASS |
| synthesized netlist GL | unit delay 63/63 (SC 28, INT 30, switch 5); ideal-clock max SDF 24/24 (SC 10, INT 12, switch 2), 0 timing violations, SDF warnings only 621 `SDFCOM_CFTC`, all async-reset removal checks of `DFFRPQ` cells | PASS |
| route qualification | final: geometry 0, antenna 0, connectivity 0, placement legal; setup +0.104 / hold +0.142 ns; grid basin (corr 0.982, mean \|skew\| 38.6 ps); 3,727 pins fixed, pin proof PASS | PASS |
| routed GL, SC power (bootstrap, uniform, ladder) | strict audit fails only on 4 `SDFCOM_IWSBA` (the combiner's `int_out[60..63]` sign-extension aliases), approved with rationale files; 0 clamps, 0 post-reset violations; worst ICG CK->ECK 0.039 ns; drains bit-exact (64 accumulators per run) | PASS |
| routed GL, INT energy | 7/7 points: 24,704 tiles, 4,632 combiner outputs, 6,684,672 MACs bit-exact, GL traces byte-identical to RTL; INT SAIF audit (AF side silent, bypass transparent) 7/7; the same 4 approvals, 0 clamps, 0 post-reset violations | PASS |
| routed GL, functional | 32/32 (SC 15/15, INT 13/13, switch 4/4), 7 of them negative controls; no ideal-clock view or reset settle; SC drains read at the SDC output-delay point (section 7.6) | PASS |
<!-- END af_ipd:verify -->

The full matrices, their negative controls and the review fixes are in the variant README; the campaign's
deviations from the AF and BP recipes are in `build/power_char/cbsg_20261005/af_ipd/README.txt`.

### 7.6 Caveats

<!-- BEGIN af_ipd:caveats -->
- **Memory bandwidth (doc/INT_mode_on_PaYN.md section 10) still applies, and the 1-edge laps make it bind sooner.** INT takes 1,024 operand bits per edge half on every data edge, for any precision; SC T = 128 takes a 576-bit block every 8 cycles. The laps change the data-edge fraction, not the bits per data edge, so with no reuse at the array edge the throughput is capped by the supply. % of peak, AF-IPD / BP lap, for section 10's two readings of an SC-sized SRAM, (i) 72 b/cycle per edge half and (ii) 576 b/cycle; 'prefetch' fetches the next data edges' operands during laps and drain (an upper bound), 'stall' stops the array while it loads:

| precision | grid | L | compute-bound | (ii), prefetch | (ii), stall | (i), prefetch | (i), stall |
|---|---|---:|---:|---:|---:|---:|---:|
| INT8 | 4x4 | 1024 | 58.7% / 40.5% | 56.2% / 40.5% | 40.3% / 30.8% | 7.0% / 7.0% | 6.7% / 6.4% |
| INT8 | 4x4 | 4096 | 85.0% / 73.1% | 56.2% / 56.2% | 51.2% / 46.6% | 7.0% / 7.0% | 6.9% / 6.9% |
| INT8 | 4x8 | 1024 | 44.1% / 33.0% | 44.1% / 33.0% | 32.9% / 26.3% | 7.0% / 7.0% | 6.5% / 6.2% |
| INT8 | 4x8 | 4096 | 76.0% / 66.3% | 56.2% / 56.2% | 47.8% / 43.8% | 7.0% / 7.0% | 6.9% / 6.8% |
| INT4 | 4x4 | 1024 | 43.8% / 34.0% | 43.8% / 34.0% | 32.7% / 26.9% | 7.0% / 7.0% | 6.5% / 6.2% |
| INT4 | 4x4 | 4096 | 75.7% / 67.4% | 56.2% / 56.2% | 47.7% / 44.2% | 7.0% / 7.0% | 6.9% / 6.8% |
| INT4 | 4x8 | 1024 | 29.4% / 24.6% | 29.4% / 24.6% | 23.9% / 20.7% | 7.0% / 7.0% | 6.0% / 5.8% |
| INT4 | 4x8 | 4096 | 62.4% / 56.6% | 56.2% / 56.2% | 42.0% / 39.3% | 7.0% / 7.0% | 6.7% / 6.7% |

  W4A8 has INT4's schedule and the same bits per data edge, so its percentages are INT4's. AF-IPD's gain over BP lap in MACs per cycle is +10% to +45% compute-bound. Under (ii) with prefetch it is +19% to +39% at L = 1024 and none at L = 4096, where both designs hit the 56.25% cap; without prefetch it is +7% to +31%. Under (i) both sit at the 7.03% cap with prefetch, and within 5% of each other without it. Section 10's edge buffers (an A replay buffer per PE row, a W block buffer per PE column) were modelled for the 8-edge laps and the hybrid schedules, not for 1-edge laps.
- **PE-grid skew is not built.** Every grid figure in this section is a composite of the single-PE route. As for AF (section 8), each PE row's and column's AF edge needs its `block_start` and phase aligned to the skewed operands, and the INT raw planes need edge skew (doc/INT_mode_on_PaYN.md section 9, correction item 2); neither is in the composites. The variant's grid wrapper is a renamed copy of the IPD grid, with no AF edge, INT bypass, mode register, guard or combiner, so it checks the lap wave only.
- **Drain rail timing on a PE row.** On this route `acc_out_east[23]` settles 1.45 ns after the clock (PT, routed SPEF, propagated clock; AF route 1.19 ns), inside its own output constraint (slack +1.00 ns). In a PE row it drives the next PE's `acc_in_west`, which the SDC budgets at 1.25 ns, so a grid must absorb 0.20 ns on the neighbour's `acc_in_west` paths (the AF route arrives 0.06 ns before it), or upsize or register the column-7 drain outputs. The same late settle is why the inherited SC functional bench, which read at the falling edge, failed 4 of 30 routed runs until it read at the SDC point; the netlist matched unit delay at every clock edge (`build/cbsg/af_ipd/route_debug/README.txt`).
- **The kA encoder remap is a synthesis-side choice that is still open** (sections 7.1 and 7.2): a fixed encoder-adder implementation or a bottom-up encoder compile would change the recipe, so it would apply to AF as well.
- **Workloads measured.** SC at uniform L = 128 and the per-row ladder only (no stream-length sweep as in section 3); INT at the BP lap campaign's seven uniform-operand points.
<!-- END af_ipd:caveats -->

## 8. Not done yet

- **PE-grid skew.** Only single-PE routes exist, so every grid figure on this page is a composite. On a grid, each
  PE's block restart and phase have to follow its operand skew, and this is not built. For AF-IPD the INT raw planes
  need edge skew too (section 7.6).
- **BP INT integration** is done (section 7). What it leaves open: the kA encoder remap, the drain-rail margin on a
  PE row, and an AF-IPD grid with the AF edges and the INT bypass.
- **Encoder area.** The kA encoders (6.5k um2) are the largest new block. Computing kA where activations are
  quantized, outside the array, would remove them.
- **Real kernels.** Triton is not available here, so the kernel model is a line-by-line numpy port of scmp_kernels.
  Goldens can be checked against the GPU kernels wherever Triton runs.
