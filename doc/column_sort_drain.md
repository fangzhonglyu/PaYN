# Per-column row sorting with a west-shifting drain-register chain (plan)

Status: **array side implemented, routed and measured** (2026-10-07): `designs/payn/rtl` behind `PAYN_DRAIN=1`,
verified against the models, routed and qualified at K16/M8 with the same flow as the qualified route, gate-level
checked and power-measured on all 27 points (section 4.6; tables in `doc/payn_results.md`, "Drain register vs
in-tile chain").  The memory side (section 5), the sorter and the gather are not started. (Revised the same day after review: the wide read-out
with an edge staging buffer is replaced by a drain-register chain.) Evaluation numbers come from
PaYN_eval (`layer_energy.py`, `group_trace.py`; scripts and runs under
`PaYN_eval/runs/grid_colsort/`). Values marked *estimate* are first-order arithmetic, not
measurements; PaYN_eval's `column_sort` schedule will replace them. Shape and grid throughout:
**K16/M8, 4x8 PEs** (32 mesh rows, 64 mesh columns), 400 MHz.

## 1. Problem

A grid runs one block length for all its PEs, set by its longest A row
(`archive/doc/cbsg_variants.md:45`). Per-group mixed precision gives every (row, 128-column
chunk) its own length, so a 32-row tile runs at its longest row. On Qwen3-14B (per-group traces,
`prc2` best(all) cells) the array is only ~65% time-utilized in the original row order:

| 14B cell | MAC-weighted avg L | in-order tile-max L | SC clock utilization |
|---|---:|---:|---:|
| t32 | 32.7 | 50.8 | 0.657 |
| t48 | 48.5 | 75.4 | 0.647 |
| t96 | 95.1 | 120.5 | 0.790 |

Sorting whole rows (one order for all chunks) barely helps (t48: 0.647 -> 0.674): a token is long
in some chunks and short in others, and one order cannot line up the ~40 chunks of a 5120-wide
layer. Sorting **each 128-column chunk independently** within a window of W rows does (ample
drain, no stall; `window_sweep.py`):

| Sort window W | t32 | t48 | t96 | SC time vs in-order (t48) |
|---|---:|---:|---:|---:|
| in-order | 0.657 | 0.647 | 0.790 | 1.00 |
| whole-row sort | 0.679 | 0.674 | 0.806 | 0.96 |
| 128 | 0.859 | 0.865 | 0.932 | 0.75 |
| 256 | 0.917 | 0.925 | 0.964 | 0.70 |
| **512** | **0.954** | **0.960** | **0.981** | **0.67** |
| 2048 (whole call) | 0.987 | 0.989 | 0.995 | 0.65 |

The accumulators are output-stationary, so a token that changes PE row between chunks cannot keep
its partial sum in a tile: **every chunk is its own slice**, drained and accumulated outside the
array by token address. That needs two things today's drain does not have: **overlap** (the
array must keep computing while a slice drains) and **bandwidth** (a 4x8 slice of 2,048 psums
must leave in about one chunk's compute time).

## 2. Today's drain (RTL)

- Each tile's accumulator loads `acc_in` on `shift_in` and clears its pending bits; shift has
  priority over the MAC (`rtl/payn_tile.sv:206-208`).
- In the PE the tile input is `lap ? (own acc) << 1 : west neighbour` (`rtl/payn_pe.sv:123-124`):
  **the accumulators themselves are the drain chain**, west -> east, 8 psums per PE row per edge on
  `acc_out_east[N_H]` (`rtl/payn_pe.sv:119-120`).
- The grid chains those rows through every PE column; **one global `shift_in`** drains for 8*P_C
  edges with `acc_in_west = 0` once the far PE has finished (`rtl/payn_pe_grid.sv:27-28`).
  Clearing is the shift of zeros.

So the drain stops the whole row (`cbsg_handoff.md` 3b), waits out the grid skew, and moves 32
psums per edge on 4x8. With per-chunk slices it is drain-bound: total drain-out 57.7 s against
50.9 s of SC streaming at t48 (15.8 s exposed even with perfect buffering of one slice; 26 s of
35 s at t32; `drain_bw.py`, `buffer_depth.py`).

## 3. Plan

| Item | Setting |
|---|---|
| Schedule | per-column (per 128-column chunk) sort within **512-row windows**; each (32-row tile, chunk, output block) is one slice |
| Loop order | per window: output-column block (8*P_C = 64 columns) outer, chunks inner, the window's 16 tiles innermost |
| Array side (overlap + bandwidth) | **west-shifting drain-register chain**: one 768-bit drain register (DR, 32 psums x 24 b) per PE (section 4) |
| Per-chunk stall | **2 edges, carrying zero samples** (section 4.3) |
| Memory side | **PsumBuffer, 128 KiB in 4 banks** (or 2 dual-port 1R+1W), read-modify-write at 128 psums per edge, banks interleaved by token (section 5) |
| Sorter | per window and chunk: bucket sort of 512 rows by their length (few ladder values); permutation 512 x 9 b = 4.6 kbit per chunk, one chunk of lookahead |
| A feed | GLB gather in the chunk's sorted order; `a_len_in` follows the same permutation |
| Fallback | build-time `PAYN_DRAIN`: 0 = today's in-tile chain (default, the qualified hardware), 1 = drain register |

## 4. Array: the drain-register chain

### 4.1 Mechanism

- Each PE gets one **drain register (DR)** of 32 x OWIDTH = 768 bits and a 3:1 mux in front of
  it: own half 0, own half 1, east neighbour's DR. A half is tile rows 0-3 (half 0) or 4-7 (half 1)
  of the PE's 8x8 tiles, i.e. 4 tokens x 8 output columns; DR value n = (h mod 4)*8 + v.
- A **drain wave**, built like the INT lap `ring` (`dr_in[r]` injected with row r's A skew,
  forwarded east one PE per edge), reaches PE (r,c) on its slice-end edge t_r + c. On that edge
  the DR loads half 0 and those tiles clear (shift-load with `acc_in = 0`, which the tile already
  does); on the next edge it loads half 1 and those tiles clear. On every other edge the DR loads
  its east neighbour's DR, so items move **one PE west per edge**.
- Collision-free by construction: column c's half h leaves the west edge at **t_r + 2c + h**, a
  distinct edge for each of the 16 items of a PE row. The chain must run **against** the operand
  wave: shifting east, every column would reach the edge at t_r + (P_C - 1) + h and collide. (This
  is also why a two-sided chain, west half west and east half east, does not work.)
- The DR is busy ~2*P_C edges per chunk: clock-gate it.

### 4.2 Sizing rules (any P_R x P_C)

- **Peak output** = P_R x 32 psums per edge, independent of P_C: 128 psums/edge (3,072 b) on 4x4
  and on 4x8; average = 64*P_R*P_C psums per (chunk compute + 2) edges (4x8, t48: ~36/edge).
- **Chain busy** = 2*P_C edges per chunk, so back-to-back chunks need chunk compute >= 2*P_C - 2
  edges. 4x8: 14 edges, i.e. tile-max L > 8 (K16/M8 chunk compute = 8*ceil(L/8)); shorter tiles
  wait. Measured on 14B with the W = 512 sort: 3.9% of slices at t32 (+0.64% SC time), 0.55% at t48
  (+0.06%). 4x4: no limit.
- 768 b (half a PE) is the minimum width, not just the best one: with a PE's reads on consecutive
  edges and one hop per edge, item (c, h) sits in PE p's DR on edge t_r + 2c + h - p, which is
  collision-free only for h in {0, 1}. A 16-psum DR needs its reads spread out (a longer stall).

### 4.3 Slice contract (SC), per chunk

- Blocks stream back to back as today (`payn_array.sv:40-47`). At a chunk boundary the edges
  **delay the next block_start by two edges**: the cycle counter runs past the block, so the A
  thermometers emit zeros, and a zero sample adds exactly 0 for any signs. A stall that holds
  `rng_en` low would instead repeat a live sample, and the half still accumulating while the
  other half is read would count it twice (`mac_en` is global and cannot drop it per PE).
- The drain wave reaches PE (r,c) on its last MAC edge + 1; the next slice's first MAC in that PE
  lands after its second read-out edge, two edges behind in the same wavefront, so the grid skew
  is paid once, not per slice.
- That needs `rng_en` high on the slice's last advance edge B+C. The in-tile chain tolerated it low
  (its drain drops the repeated last cycle); with the DR one half drops it and the other counts it
  twice, so the RTL's `[SC-CONTRACT]` check flags any read edge that consumes a live sample.
- The read-out is the slice end, so it re-arms the stream generator's phase restart as today's
  drain does (`payn_array.sv:48-51`; `drain_in` goes to the restart input). For full 128-column
  chunks this is only a safety net: the phase is already 0 at every chunk boundary.
- SC <-> INT switch rules that rely on the drain clearing the tiles (`payn_array.sv:100-111`)
  still hold: the read-out clears.

### 4.4 RTL changes

| Module | Change |
|---|---|
| `PaynTile` | **none** (clear = shift-load of `acc_in = 0`) |
| `PaynPeCore` (`payn_pe.sv`) | DR (768 flops, valid bit, load enable = read or east item), its 3:1 mux, per-half shift (`shift_in \| rd_half`); the tile input is `lap ? acc<<1 : '0` (no chain mux); `[DR-CONTRACT]` checks (a read while an item arrives, both halves on one edge, a read on a lap edge) |
| `PaynPe` (`payn_pe.sv`) | drain wave registers `drain_q` / `drain_q2` (half-0 / half-1 read edges), `drain_out` east, packed DR ports |
| `PaynPeGrid` (`payn_pe_grid.sv`) | drain wave links east (like `ring`); 768-bit DR links west, all registered locally; west outputs `dr_out_west` / `dr_valid_west` |
| `payn_array` top | `drain_in`, `dr_out`, `dr_out_valid`; `drain_in` arms the slice restart; the combiner never captures (bit-plane INT needs `PAYN_DRAIN = 0`); `[SC-CONTRACT]` counts read edges as drain edges |
| `PaynEdge` | none: the A edge loads whatever rows it is fed |
| in-tile east chain | `PAYN_DRAIN = 0`, the default; Formality: equal to the committed RTL (section 4.6) |

Wires: each PE boundary gains 768 registered bits (today: ~1,150 A or W operand bits) and loses the
192-bit in-tile drain link. No long wires, so no new timing path to the array edge.

### 4.5 INT mode

abit results are read raw from `acc_out_east` today (`payn_array.sv:72`); with the chain they leave
west through the DRs. With a per-PE drain wave the next block follows two edges behind, so both
the drain (8*P_C) and the per-block skew (P_R + P_C - 2) drop out, bounded by the chain's busy time:
E = max(BA*BW*ceil(L/128) + (BA+BW-2) + 2, 2*P_C) (measured in RTL, section 4.6).  4x8, K16/M8, with the
routed area (4x8 composite +4.5%):

| point | GMAC/s/mm2 | vs BOS | in-tile chain |
|---|---:|---:|---:|
| INT8, L = 384 | 1,249 | 0.77x (INT8 1,621) | 970 (0.60x) |
| INT7, L = 1,024 | 1,706 | 0.94x (INT7 1,806) | 1,515 (0.84x) |
| INT7, L = 4,096 | 1,752 | 0.97x | 1,752 |
| INT6, L = 1,024 | 2,309 | 1.12x (INT6 2,064) | 1,947 |

This also closes the open "better draining" item (`cbsg_handoff.md` 3b).

### 4.6 Implementation (2026-10-06)

- **RTL**: `designs/payn/rtl` (`payn_pe.sv`, `payn_pe_grid.sv`, `payn_array.sv`), build-time define
  `PAYN_DRAIN` (0 default, 1 drain register); instance names unchanged. With 1 the bit-plane INT
  schedule (combiner on the in-tile chain) is not available; SC and all bits in time run.
- **Default unchanged** (Formality, `build/dr_chain/equiv/`): `PAYN_DRAIN = 0` against the committed
  RTL, array K16/M8 6,918 / 6,918 and K8/M16 5,682 / 5,682 compare points, 2x2 grid 20,882 / 20,882;
  the only unmatched points are the new DR ports (constant 0 or unread).
- **Regression** (`python3 flow/regress.py --drain 1 --shape both`, tables `sc_dr.txt`,
  `grid_abit_dr.txt`): see `doc/cbsg_handoff.md` item 3b for the counts. Measured block periods equal
  max(BA*BW*NB + (BA+BW-2) + 2, 2*P_C) on 2x2, 4x4 and 4x8 (e.g. INT8 L = 384: 208 edges, against 214
  single-PE / 224 on 2x2 / 280 on 4x8 with the in-tile chain); every DR item leaves on t_r + 2c + h.
- **Route** (K16/M8, `apr/build/TSMC22/PAYN/payn_k16m8_dr_20261007_final`, `flow/route.py --drain 1`):
  final qualification (setup +0.051 / hold +0.170 ns, one residual marker repaired), grid basin (corr 0.981,
  skew 30.8 ps), all 6,418 pins fixed as planned.  `payn_array` carries the drain register's east input as ports
  (`dr_in_east`), so the single-PE route holds the grid PE's whole chain stage (with it tied off, synthesis drops
  a mux leg: +3.3% instead of +4.1% per PE).  Area: single PE 59,542 vs 58,129 um2 (+2.4%), `u_pe` 34,196 vs
  32,461 (+5.3%; the drain register itself 1,912 um2), combiner removed; composites 4x4 646,553 (+4.0%), 4x8
  1,210,891 (+4.5%).
- **Measured** (routed GL + PT-PX, the qualified route's 27 points): SC energy within -1.6% .. +1.6% of the
  in-tile chain at every T (ladder -0.9%); INT all bits in time +0.7 .. +1.5%.  Throughput, 4x8: INT8 L = 384
  +28.8%, INT7 L = 1,024 +12.6% (0.94x BOS INT7), INT6 L = 1,024 +18.6% (1.12x BOS INT6), INT4 L = 1,024 +46%,
  L = 4,096 within +-2%; in-order SC -4.4% (area only; the per-column sort is what it enables).
- **Flow fixes found on the way**: the INT power bench primes the drain register before the SAIF window (its
  data flops have no reset, so X would resolve inside the window); the single-PE bench ends a case one edge after
  the half-1 read (a race with the late drain sample); `flow/qualify.py` accepts VCS's line-wrapped IWSBA text;
  `flow/route.py`'s pin check discounts the inputs that drive no cell in this build (acc_in_west, int_prec); the
  57k-edge chained SC run is unit-delay only (SDF modes run rows of at most a few thousand edges).

## 5. Memory side: banked PsumBuffer (outside the array; nothing here exists in this repo)

- **Bandwidth.** The chain delivers up to 128 psums per edge in 16-edge bursts per chunk; each is
  read and written, 256 psum accesses per edge. Today: one 1,536-bit row (64 psums) per edge.
  Plan: **4 banks of 32 KiB** single-port, or 2 dual-port (1R + 1W). Banking alone cannot fix the
  drain: the psums cannot leave the array faster than the in-array chain moves them.
- **Capacity.** Window footprint 512 rows x 64 columns x 24 b = 96 KiB of the 128 KiB.
- **Bank mapping.** The binding limit is addresses, not psums: each edge delivers 4 items = 16
  tokens x 8 columns, i.e. 16 independent 192-bit read-modify-writes, and a token's 64 columns arrive
  over 8 edges. Plan: token-interleaved banks with a 192-bit word (one token x 8-column piece),
  **64-128 banks** (1R+1W), and a small **shared conflict buffer** that holds a piece until its bank is
  free; no sort constraint. Simulated over 3,200 random-sort slices at 4x8
  (`build/colsort_bank_sim/sim.py`): at most 37 waiting pieces with 64 banks, 23 with 128 (about 7.5 / 5
  kbit), waits up to 31 / 17 edges (the same address is not touched again until the next chunk). A
  hard bound needs a loose sorter cap (at most a few tokens of one bank per tile) or backpressure.
  Alternative: a one-slice row assembler (49 kbit, flops) feeding 4 banks of 1,536-bit rows.
- **Energy.** The per-chunk read-modify-write is the largest new energy term: 2.98 pJ per output
  per chunk for one 128 KiB bank (CACTI, 1,536-bit row: read 68.4 pJ, write 122.2 pJ per row),
  ~+2.2 J on 14B t48. Smaller banks should lower it (CACTI per word: 32 KiB ~1/3 of 128 KiB).
- **Collectors.** West edge, beside the A edges: floorplan room for P_R x 768 output bits.
- Also new: the per-chunk sorter, and GLB gather of A rows in sorted order.

## 6. Expected effect (estimates; 14B t48, 4x8)

| | in-order today | this plan (W = 512) |
|---|---:|---:|
| SC clock utilization | 0.647 | ~0.925 (2-edge stall included; t32 0.904, t96 0.962) |
| Latency | 82.2 s | ~59-60 s (-28%) |
| Array area | 1.158 mm2 | 1.211 mm2 (+4.5%, routed: section 4.6); PsumBuffer banking to be priced in CACTI |
| On-chip energy | 46.8 J | -7% if idle rows burn until the tile-max (PaYN_eval's current pricing); close to 0 if idle rows burn ~half of that, as the ladder point suggests. The latency gain does not depend on this. |
| On-chip EDP vs BOS INT8 8x9 (iso-area) | 1.07x | ~0.72-0.78x |

## 7. Alternatives considered

| Drain | Overlap | Bandwidth out (4x8) | Area | Why not |
|---|---|---:|---|---|
| Today (in-tile chain, global shift) | no, 74 edges per slice | 32 psums/edge | 0 | drain-bound and stalls every chunk |
| Both-way in-tile drain (4*P_C) | no | 64 psums/edge | small | still stalls 32 edges per chunk |
| Shadow register per tile | yes | 32 psums/edge | +10-13% | bandwidth still short on 4x8 |
| Wide read-out + edge staging buffer | yes | 1,024 psums/edge burst | +6-13% (staging must be flops: 24.6 kbit written per edge) | 24.6k long wires to the edge; costs more than per-PE buffering |
| **West-shifting DR chain** | **yes, 2-edge stall** | **128 psums/edge** | **+4.5% on 4x8 (routed)** | **chosen, implemented** |
| North-shifting DR chain (against the W wave) | yes, 2-edge stall | 256 psums/edge peak | ~+4% | needs 2x the PsumBuffer bandwidth or staging; use only if the west floorplan has no room. No short-L limit (busy 2*P_R edges) |
| Two-sided DR chain | - | - | - | the east-moving half travels with the wave and collides |

## 8. Risks and verification

- **Floorplan**: the west edge already hosts the A edges; place the collectors and P_R x 768 output
  pins there (north chain is the fallback).
- **PsumBuffer bank mapping** (section 5): settle before RTL of the memory side.
- **RTL (done, section 4.6)**: the `PAYN_DRAIN = 1` regression (SC slices with the 2-edge zero
  bubble, bit-exact against the C-BSG kernel; INT abit through the chain on 2x2 to 4x8; the busy
  rule; negative controls); Formality: `PAYN_DRAIN = 0` equals the committed RTL. SC per-chunk
  slices with permuted rows need no separate bench: a PE sees a slice as a slice, and the sliced sum
  is exact because each element's product depends only on (a, w, L, x mod 64).
- **Gate level**, then area/power of `PAYN_DRAIN` 1 vs 0 (DR flops, mux, clock gating).
- **APR**: route the DR links and the west read-out; qualify as today.
- **PaYN_eval**: implement the `column_sort` schedule (per-chunk slices, 2-edge stall, DR-chain
  busy rule, PsumBuffer read-modify-write priced through the mapping with banking, DR area) to
  replace the estimates in sections 4.5 and 6. Optional study: hold one row order for R chunks
  (sorted on their max L) to divide slices, stalls and psum traffic by R.
