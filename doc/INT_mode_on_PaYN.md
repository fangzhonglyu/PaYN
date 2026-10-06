# Running INT layers on PaYN

Scope: the CSA variant (`designs/payn/variants/signed_segmented_csa/`), TSMC22 A7 SVT, 0.80 V, 400 MHz.
Date: 2026-10-03. Every number here passed the adversarial verification round. Where a verifier
corrected a number, this note uses the corrected value and marks it *(corrected)*.
Evidence: `sweeps/int_mode/` (models, `verify/`) and `build/power_char/int_mode_energy_20261003/` (GL energy).

Names: **BP** = bit-plane mode with a doubling ring (round-1 key `bitplane_throughput`); **CNSB** = spatial Booth digits made
by the existing comparators (`red_team_novel`, `spatial_fixed_weight`); **WO** = weight-outer Booth with a x4 ring
(`weight_outer_horner`); **ROT** = reduction-outer with a rotating accumulator, i.e. your "shift every cycle" idea
(`reduction_outer_rotating`); **BOS** = the dedicated binary 8x8 INT8 array (`designs/baselines/binary_os/`).
Area % is of the routed composite (1 PE 44,018 um², 4x4 521,892 um², 4x8 1,016,043 um²). **Inside** = cells inside that
composite, which SC pays for on every layer. **All-in** = inside plus the INT-only edge logic (feeders, east combiner,
controller), SRAM excluded. SC today: 581.6 / 784.8 / 806.3 GMAC/s/mm² (1 PE / 4x4 / 4x8).

## 1. The answer

1. The most efficient way to run INT on PaYN is **bit-plane mode (BP)**: each AND gate gets one bit of `a` and one bit of `w`,
   so every AND is one exact 1-bit partial product and an INT8 MAC needs 64 of them instead of SC T=128's 128.
2. The tile, counters, sign XOR and accumulators stay exactly as they are; what is added is an `int_mode`-gated OR per edge half
   (raw bits bypass the comparators), a small mux per PE that sends the accumulators once around the existing drain chain
   doubled (`<<1`) between weight bits, and a shift-add per PE row at the east edge that applies `2^h` to activation bit `h`.
3. It costs (cell count, not yet synthesized, *corrected*) 2.69% / 1.28% / 1.12% inside and 4.09% / 1.70% / 1.33% all-in
   (1 PE / 4x4 / 4x8), so SC on a 4x4 goes from 784.8 to 771.7 GMAC/s/mm² all-in.
4. Peak is 2 / 4 / 8 MAC/cycle/tile for INT8 / W4A8 / INT4 (SC T=128: 1); on a LLaMA-2-7B prefill (S=2048) a 4x4 delivers
   872 INT8 and 1,532 W4A8 GMAC/s/mm² against 770 for SC on the same layers (*corrected* from the 1,131 single-layer headline).
5. Measured on the routed CSA layout (max-SDF GL, bit-exact), INT8 costs 0.32 pJ/MAC at peak and 0.35 / 0.42 at L = 4096 / 1024
   including ring laps (SC T=128: 0.60), and INT4 costs 0.08-0.10; operand delivery and ~+0.02 pJ/MAC of estimated BP-only
   cells are not included.
6. The price is the memory side: 8,192 bits/cycle into a 4x4 (4 bits/MAC, ~7x SC), weights and attention K/V stored
   bit-plane-major, and poor short reductions (QK^T at L=128 gets 0.16 MAC/cycle/tile); with a feed of 4,608 bits/cycle or
   less, BP is no better than the Booth designs.
7. If that feed cannot be built, or the SC array must stay literally unchanged, use **spatial Booth (CNSB)**: no tile, PE or
   peripheral change, +101-103 um² inside (0.23% / 0.02% / 0.01%), 5.59% / 1.83% / 1.11% all-in (synthesized), INT8 at SC's
   peak rate (W4A8 2x, INT4 4x) but 667 GMAC/s/mm² on the S=2048 mix, 1.5 bits/MAC, and a measured 0.68-0.80 pJ/MAC
   (1.06-1.25x SC at 4x4).
8. Shifting inside every tile (your shift-down idea, ROT) works and has the lowest bandwidth (0.5 bits/MAC), but it puts
   5.98% of a 4x4 inside the array, so SC loses 5.6%; it ranks last of the on-grid options.

Ranked recommendation:

| Rank | Design | Choose it when |
|---|---|---|
| 1 | BP (bit-plane ring) | The buffer can feed about 8 kb/cycle into a 4x4, and INT8 is more than about 5-10% of the MACs (Section 5) |
| 2 | CNSB (spatial Booth) | The feed is 1.5-4.6 kb/cycle, or the array must not change. Lowest risk: synthesized and GL-measured |
| 3 | WO (weight-outer ring) | The feed is capped near 4.6 kb/cycle. It is the best of the three there (L=4096: 755 vs 720 / 718). Otherwise CNSB is cheaper and WO's energy is unmeasured |
| 4 | ROT (your per-cycle shift) | Only if operand bandwidth must stay at SC's level. It fails "SC must not lose area" |
| 5 | BOS sidecar | Only if INT8 is most of the work. It needs 48% more area for equal throughput |

## 2. How it works

### 2.1 What one tile computes (unchanged in every scheme)

```
for lane k = 0..7, position m = 0..15, every cycle:
  bits[k][m] = a_bits[k][m] & w_bits[k][m]
  count[k]   = sum_m bits[k][m]                          (0..16)
  sign[k]    = a_sign[k] ^ w_sign[k]
  d          = sum_k (sign[k] ? -count[k] : +count[k])   (|d| <= 128)
  acc        = acc + d
```

The CSA tile forms -count as (the 5 counter bits XOR 1) plus the -16·N row. This was verified exact for all 65,536 input patterns.
In SC, `a_bits` and `w_bits` are random streams; in INT mode we choose what they mean. Every INT scheme writes each operand as
small pieces times powers of two:

```
a = sum_i 2^i * a_i        w = sum_j 2^j * w_j
a * w = sum_i sum_j 2^(i+j) * (a_i * w_j)
```

For one fixed (i, j), a tile can add up `a_i * w_j` over many reduction elements; that sum is `d`. The only design question is
**where `2^(i+j)` gets applied** (Section 3).

### 2.2 Bit-plane mode (BP)

In two's complement each bit is 0 or 1, and the top bit counts negative:

```
a = -128*a_7 + sum_{h=0..6} 2^h * a_h        s_h = -1 if h == 7 else +1
w = -128*w_7 + sum_{q=0..6} 2^q * w_q        s_q = -1 if q == 7 else +1
a * w = sum_h sum_q s_h * s_q * 2^(h+q) * (a_h & w_q)
```

Mapping for INT8: one PE handles one activation row `i` and eight output columns `j_v`.

- **Tiles.** Tile row `h` carries activation bit `h`. Tile column `v` is output column `j_v`.
- **Passes.** Weight bits go one pass at a time, q = 7, 6, ..., 0 (top bit first).
- **Per cycle.** In cycle `b` of a pass, a tile takes 128 new reduction elements `kk = 128b + 16k + m`:

```
a_bits[k][m] = bit h of a[i][kk]          (pure wiring from the A byte word)
w_bits[k][m] = bit q of w[kk][j_v]        (W stored bit-plane-major)
sign[k]      = (h == 7) ^ (q == 7)        (same on all 8 lanes)
between passes (8-cycle ring lap):  T = 2*T
after pass 0:                       T(h,v)  = s_h * sum_kk a_h[kk] * w[kk][j_v]
east edge, once per output:         y[i][j_v] = sum_h 2^h * T(h,v)
```

**Worked example**, one product: `a = -77` (bits a7..a0 = 1011 0011), `w = 93` (bits w7..w0 = 0101 1101),
so `a*w = -7161`. Rows h = 7, 5, 4, 1, 0 have a_h = 1. Row 7, pass by pass:

| pass q | w_q | a_7 & w_q | sign | d | T after pass | T after ring lap (x2) |
|---:|---:|---:|---:|---:|---:|---:|
| 7 | 0 | 0 | 0 (top x top = +) | 0 | 0 | 0 |
| 6 | 1 | 1 | 1 | -1 | -1 | -2 |
| 5 | 0 | 0 | 1 | 0 | -2 | -4 |
| 4 | 1 | 1 | 1 | -1 | -5 | -10 |
| 3 | 1 | 1 | 1 | -1 | -11 | -22 |
| 2 | 1 | 1 | 1 | -1 | -23 | -46 |
| 1 | 0 | 0 | 1 | 0 | -46 | -92 |
| 0 | 1 | 1 | 1 | -1 | -93 | (no lap) |

Row 7 ends at -93. Rows 5, 4, 1 and 0 end at +93, and rows 6, 3 and 2 end at 0. The east edge then forms
`2^7*(-93) + (2^5+2^4+2^1+2^0)*93 = -11,904 + 4,743 = -7,161`.

In a real lane, the 16 positions hold 16 different elements, so `count[k]` adds 16 such one-bit products per cycle.
A tile does 128 one-bit products per cycle, and an INT8 MAC needs 64, so the tile does **2 MAC/cycle**.

What has to change for BP (areas are cell counts *(corrected)*):

| Where | Change | Area |
|---|---|---|
| Tile | none | 0 |
| Edge half (2 per PE) | `a_bits = comparator_out OR (raw AND int_mode)`. 1,024 raw lines per half: 512 reuse `a_binary_in` and must be gated, 512 are new. Magnitude registers are held at 0 in INT mode | 511.6 um² per half (includes the +109.8 gate fix) |
| Per PE | Ring mux. When `ring_q` = 1, the west tile loads `acc_out_east << 1` from its own east tile, and the tile shift becomes `shift_in OR ring_q`. `ring_q` rides the A wave | 163 um² |
| East edge, per PE row | `y = sum_h 2^h T(h)`, a shift-add tree | 515.7 um² |
| Control | Sequencer for passes, ring laps, sign loads and drain | ~100 um² per grid |
| Memory | 1,024 bits/cycle per edge half; W bit-plane-major; A byte-major | not costed |

**Other schedules on the same hardware (2026-10-04).** The mapping above (called T1 in the schedule study, section 9) puts the 8
activation bits in space and the 8 weight bits in time. Any split of the bits between space and time runs on the same tile, PE and
grid wrapper. In the hybrid **H(TA,TW)**, each tile takes TA activation bits *and* TW weight bits in time:

```
GA = BA/TA bit groups per activation row on the tile rows   ->  8*TA/BA activation rows per PE
GW = BW/TW bit groups per output column on the tile columns ->  8*TW/BW output columns per PE
tile row h = (activation row h/GA, group g = h%GA)      tile column v = (output column v/GW, group s = v%GW)
pass (ta, q): a_bits = bit g*TA+ta of a, w_bits = bit s*TW+q of w; sign = (g*TA+ta == BA-1) ^ (s*TW+q == BW-1)
passes grouped by Horner level k = ta+q (highest first), one 8-cycle ring lap between levels: TA+TW-2 laps
after the drain: T((i,g),(j,s)) = sum_kk Afield_g[i][kk] * Wfield_s[kk][j]     (field signed iff it holds the MSB)
east edge:       y[i][j] = sum_g sum_s 2^(g*TA + s*TW) * T((i,g),(j,s))
```

INT8 H(4,8) holds 4 activation rows x 8 output columns = 32 outputs per PE (T1: 8); its east edge forms `y = T(i,g=0) + 16*T(i,g=1)`.
The 24-bit tile holds 15 x 128 x L, so one block takes L <= 4,369. T1 is H(1,8), "weight bits in space" (T2 S=8) is H(1,1), and the
round-1 "HB" mapping is H(8,8). What changes outside the array: the east combine, and the A feeder must deliver bit planes (A stored
bit-plane-major, or a TA:1 select per A line).

### 2.3 Spatial Booth (CNSB): the option that changes nothing in the array

Booth digits, with `a_-1 = w_-1 = 0`:

```
da[p] = -2*a_(2p+1) + a_(2p) + a_(2p-1)                              p = 0..3, da in -2..2
dw[q] = -8*w_(4q+3) + 4*w_(4q+2) + 2*w_(4q+1) + w_(4q) + w_(4q-1)    q = 0..1, dw in -8..8
a * w = sum_p sum_q 4^p * 16^q * da[p] * dw[q]
```

Treat a lane's 16 positions as a 2x8 grid (r = 0..1, c = 0..7):

```
a_bits[k][(r,c)] = (|da| > r)        -> 8*|da| ones
w_bits[k][(r,c)] = (|dw| > c)        -> 2*|dw| ones
count[k] = |da| * |dw|  (<= 16)      sign[k] = (da < 0) ^ (dw < 0)
tile (p,q) of one output:  T_pq = sum_kk da[p]*dw[q]
east edge:                 y = sum_p sum_q 4^p * 16^q * T_pq
```

- **PE layout.** A PE holds 2 activation rows x 4 weight columns x (4 p x 2 q) = 64 tiles: 8 outputs, 64 MAC/cycle.
- **Example.** -77 gives da = [-1, +1, -1, -1] and 93 gives dw = [-3, +6]. In tile (p=2, q=1), A has 8 ones (row 0) and W has
  12 ones (columns 0-5), so the AND has 6 ones; sign = 1 ^ 0 = 1, so d = -6, times the tile weight 4^2 * 16 = 256 = -1,536.
  The eight tiles sum to 3 - 96 - 12 + 384 + 48 - 1,536 + 192 - 6,144 = -7,161.
- **How the unchanged comparators make these patterns.** Today `a_bits[k][m] = code[k] > (R[m] ^ MASK[k][m])`, with R the 16
  shared Sobol values. Freeze R to a searched constant (the "Sobol preset"): every position then has a fixed threshold, and a
  per-lane 8-bit code turns on exactly the wanted positions. Verified for every lane, every code pair and all three preset sets;
  no reachable Sobol state works, so the preset hardware is required.
- **What changes** (all synthesized): Sobol preset 102.7 um²; feeder per edge half (Booth recode, per-lane code table, SC/INT
  port mux) 432.2 um² radix-4 side / 957.3 um² radix-16 side; east combiner 969.4 um² per PE row (2-stage, 36-bit,
  *corrected* from 566-741); control holds `load_*` = 1 and `rng_en` = 0.

## 3. Where the 2^s goes, and why the tile accumulator should not shift

There are three places to apply a weight:

1. **In space, once per output.** Each tile, or tile row, holds one weight class. The east edge combines the drained totals:
   `y = sum_s 2^s * T_s`. BP does this for activation bits, CNSB for all digits. Cost: one adder tree per PE row, and no tile change.
2. **In time, once per pass.** Between passes the whole accumulator is multiplied by 2 (BP) or 4 (WO): the accumulators make one
   8-cycle trip around the PE's own drain chain, with the shift wired in at the PE's west input, and no tile change. It is exact
   because a shift loads the canonical `{acc_high + pending, acc_low}` and clears the pending carry/borrow (existing RTL);
   verified at RTL for WO and in an independent simulator for BP.
3. **In time, every cycle, inside every tile.** This is your idea.

No scheme needs a shift every cycle. In any one cycle, all 128 ANDs of a tile carry products of the same weight 2^s
(one bit pair or one digit pair), so within a pass the tile only adds. Weights change only between tiles (space) or between passes (time).

Your shift-down idea, as built and verified (ROT): the accumulator rotates down 2 bits whenever the digit weight rises.
The 2 bits that fall out wrap into the top, and the next block runs the weights in reverse. The model is bit-exact. Its verified cost:

- **Area** *(corrected)*. 19.5 um² per tile (+4.8% of a tile) across all 1,024 tiles of a 4x4 is 3.83% of the grid.
  With its edge logic it is 5.98% (1 PE 8.83%, 4x8 5.72%). SC drops from 784.8 to 740.5 (-5.6%), on every SC layer.
- **Range** *(corrected from 5.87%)*. A 24-bit accumulator holds only 496 worst-case INT8 MACs, so long reductions drain in segments.
  That needs 32 extra 32-bit adders and a 32,768-bit partial-sum store at the east edge: 7.6-8.2% all-in.
- **What it buys.** 0.5 bits/MAC and 64 outputs per PE, so short reductions do well: QK^T at L=128 gets 572 GMAC/s/mm²,
  against CNSB 227, WO 483 and BP 121. On whole layers it gets 675-683 (714-725 with weight-aware segmentation),
  below WO's 726-750 at every S.
- **Doing x4 in one cycle in the existing tile** (`acc = 4*acc + d`) gives up to 4 carries per cycle
  (low_sum up to 4*511 + 128 = 2,172). That breaks the LOW_W=9 single-carry segmented accumulator, so the low segment would need a redesign.

The once-per-pass version of your idea also passes bit-exact RTL tests: LSB first, a `>>2` ring lap, and the low bits captured
at the edge. In WO it gains +1.5-8.5% INT8 GMAC/s/mm² for 512 <= L <= ~1.5k (4x4) or ~2.5k (4x8), because it keeps 64 outputs
per PE. But its 640-flop-per-PE emit buffer costs SC 784.8 -> 760.8 (-3.1%), against 781.1 for shifting up.
Under the SC rule, shift up (MSB first), not down.

**Bottom line:** each piece needs a weight, not a per-cycle shift. Apply `2^s` once per output (space) or once per pass (ring),
and never put a shifter in the tile.

## 4. Your 64-vs-128 point

AND-gate-cycles per INT8 MAC:

| Scheme | per MAC | Why |
|---|---:|---|
| SC T=128 | 128 | 8 cycles x 16 ANDs of one lane |
| Booth (CNSB, WO, ROT) | 128 | 8 digit pairs. Each takes a whole 16-AND lane for one cycle, although only `abs(da)*abs(dw)` ANDs fire (about 4 of 16 on uniform data) |
| Bit-plane (BP) | 64 | 8 x 8 one-bit products, one per AND |

You are right, and only BP achieves it: a peak of 2 MAC/cycle/tile.

**Measured energy**, 1 PE (routed CSA, max-SDF GL, PT-PX, 3,072 cycles, bit-exact, validators pass). Values are pJ/MAC:

| Point | INT8 | W4A8 | INT4 |
|---|---:|---:|---:|
| SC T=128 reference (64 MAC/cycle) / SC T=16 (512 MAC/cycle) | 0.603 | - | 0.117 (T=16) |
| BP peak (data cycles), uniform / signed Gaussian / post-ReLU | 0.322 / 0.322 / 0.199 | - | 0.081 / 0.076 / 0.042 |
| BP incl. ring laps, L=1024 (uniform / ReLU) | 0.422 / 0.285 | - | 0.102 / 0.060 |
| BP incl. ring laps, L = 128 / 512 / 4096 / 16384 (uniform) | 1.11 / 0.52 / 0.35 / 0.33 | - | - |
| CNSB, uniform / DNN-like Gaussian (sigma = range/8) | 0.795 / 0.683 | 0.397 / 0.306 | 0.198 / 0.146 |
| CNSB composed to 4x4 (SC T=128 composes to 0.530) | 0.662 / 0.561 | 0.331 / 0.248 | 0.165 / 0.118 |
| BOS dedicated INT8 / INT4 (routed earlier, different flow) | 0.412 | - | 0.155 |

- **Per position.** One BP data cycle costs 41.2 pJ, or 5.03 fJ per AND position, against 4.71 fJ for SC T=128.
  Each position costs 7% more, but INT8 needs half as many. At L=1024, including the drain, BP is 0.435.
- **Data statistics.** Signed small-valued data does not help BP INT8: the upper bits of a small two's-complement number copy its sign,
  so every bit-plane toggles at 0.5. Non-negative (post-ReLU) activations cut energy by 38%.
- **Not in the netlist** (estimated): bypass ORs, raw-bit wires, ring muxes and return wires add about +0.02 pJ/MAC at the INT8 peak.
  Operand delivery is excluded: each 10 fJ/bit adds 0.04 pJ/MAC at 4x4.

**What BP costs:**

- **Bandwidth.** 2,048 fresh bits/cycle per PE (16 bits/MAC on 1 PE); 8,192 bits/cycle into a 4x4 (409.6 GB/s, 4 bits/MAC),
  against 576 for SC (0.56). A 16-43 KiB activation replay buffer brings this to 2.25 bits/MAC; it has to be SRAM.
- **Data layout.** W must be stored bit-plane-major. In attention the "weights" are K and V, produced at run time,
  so a bit-plane-major KV write path is needed. It is not costed.
- **Output footprint.** A block is P_R x 8*P_C outputs (4x32 on 4x4, against 32x32 for SC), so W is re-fetched M/4 times (8x SC).
  Batch-1 decode is actually BP's best case (218 GMAC/s/mm², against CNSB 83), but it is DRAM-bound in practice.
- **Fixed overhead.** Every block on a 4x4 pays 56 ring + 6 skew + 32 drain cycles. Data cycles are 7.8% of the total at L=128,
  40.5% at 1024, 73.1% at 4096 and 88% at 11,008. A ring or drain cycle costs 13-14.5 pJ, about 35% of a data cycle.
- **Effective INT8 rate**, 4x4, MAC/cycle/tile:

  | L | 128 | 512 | 1024 | 2048 | 4096 | 11008 |
  |---|---:|---:|---:|---:|---:|---:|
  | BP | 0.157 | 0.51 | 0.81 | 1.15 | 1.46 | 1.76 |
  | SC | 0.77 | 0.93 | 0.96 | 0.98 | 0.99 | 1.00 |

  BP overtakes SC only above about L = 1,400 (my interpolation). Its energy beats SC from about L = 512.

**When BP is worth it.**

- **Workload.** Long reductions (projections, FFN, SV at S >= 2048), a feed near 8 kb/cycle, and INT8 above a few percent of MACs.
- **Long sequences.** At S=4096 the L=128 attention dominates and BP falls to 724, against SC 763 and WO 727.
  Allowing the single-block "HB" schedule for L <= 511 restores 1,055, but needs Q and K in bit-plane form at run time (not costed).
- **Feed cap**, 4x4 at L=4096, MAC/cycle/tile:

  | Feed (b/cycle) | 8,192 | 4,608 | 1,536 |
  |---|---:|---:|---:|
  | BP | 1.46 | 0.93 | 0.35 |
  | CNSB | 0.93 | 0.93 | 0.93 |
  | WO | 0.97 | 0.97 | 0.33 |

## 5. Comparison (corrected numbers)

**5a. Area and what SC pays**

| Design | Inside, 1 PE / 4x4 / 4x8 | All-in (no SRAM), 1 PE / 4x4 / 4x8 | SC GMAC/s/mm² at 4x4 (784.8 today): inside / all-in | Basis |
|---|---|---|---|---|
| BP ring | 2.69 / 1.28 / 1.12% | 4.09 / 1.70 / 1.33% | 774.9 / 771.7 | cell count *(corrected: +gate fix, +controller)* |
| CNSB | 0.23 / 0.02 / 0.01% | 5.59 / 1.83 / 1.11% | 784.7 / 770.7 | synthesized *(corrected: claimed "SC: none")* |
| WO ring | 0.54 / 0.44 / 0.44% | 6.91 / 2.53 / 2.01% | 781.4 / 765.5 | synthesized *(corrected: claimed 0.47-0.96%, feeder omitted)* |
| ROT | 8.83 / 5.98 / 5.72% | - / 7.6-8.2 / - % | 740.5 / ~727 | cell count, +-30% *(corrected)* |
| BOS sidecar, equal INT8 rate | 0 | - / 48.4 / ~48% | 784.8 / 528.8 | routed 8x8 array, 15,797 um² |

Systolic skew (no design counted it originally): the table assumes each edge half has its own offset-addressed SRAM stream.
Building the skew from delay flops instead adds, on a 4x4, CNSB +3,161 um² (2.43% all-in), WO about +6.3k (about 3.7%) and
BP +16,859 (about 4.9%, because it carries 1,024 raw bits per half).

**5b. INT8 performance** (4x4 unless noted; GMAC/s/mm² on the all-in area of 5a)

| Design | Peak MAC/cycle/tile, INT8 / W4A8 / INT4 | Effective at L = 128 / 1024 / 4096 | LLaMA-2-7B prefill, S = 512 / 2048 / 4096 | Operand bits/MAC | INT8 pJ/MAC (1 PE) |
|---|---|---|---|---|---|
| SC T=128 (reference) | 1 | 0.771 / 0.964 / 0.991 | 776 / 770 / 763 | 0.56 | 0.603 measured |
| BP ring | 2 / 4 / 8 | 0.157 / 0.810 / 1.463 | 1,058 / **872** / 724 | 4.0 (2.25 with replay buffer) | 0.32 peak, 0.42 at L=1024, measured |
| CNSB | 1 / 2 / 4 | 0.296 / 0.771 / 0.931 | 705 / 667 / 627 | 1.5 | 0.68-0.80 measured |
| WO ring | 1 / 2 / 4 | 0.621 / 0.892 / 0.971 | 738 / 728 / 715 | 3.0-4.0 (4.5 at the port) | not measured (estimate: about CNSB plus ring laps) |
| ROT (worst-case segments) | 1 / 2 / 4 | 0.771 / 0.900 / 0.923 | 683 / 679 / 675 (excludes its partial-sum store) | 0.5 (+ partial-sum traffic) | not measured |
| BOS, 16 dedicated 8x8 arrays | 1 per BOS MAC | 0.853 / 0.979 / 0.995 | 1,610 / 1,602 / 1,594 | 2.0 (0.5 as one 32x32 mesh) | 0.412 measured |

Notes on 5b:

- **W4A8 on the S=2048 mix**: BP 1,532, CNSB 1,334. WO gets 1,486 on FFN layers. BOS INT6, as a proxy, gets 2,041.
- **INT4 on 4x4 FFN**: WO 2,930, which is 1.18x BOS INT4 (2,491).
- **Utilization** is MAC/cycle/tile including skew and drain, with large M and N. Short attention reductions (L = 64-128) are where every on-grid INT mode loses the most.
- **Grid orientation.** For 32 PEs, orient the grid 8x4, so the drain runs along the 4-PE side.
  On the S=2048 mix that gives BP 881 against 771 for 4x8, and CNSB 673-677 against 608-612.
- **Mixed workloads** (my arithmetic on the numbers above, S=2048 mix). With a fraction f of the MACs in INT8 and the rest SC,
  BP beats CNSB once f > ~5% (inside-array area only), f > ~9% (all-in with skew delay flops), or at any f (all-in, SRAM skew).
- **Dedicated BOS.** It is 1.84x BP and 2.4x CNSB in INT8 density. But as a sidecar it adds 48% area for equal throughput.
  At 10% INT8, the best-sized sequential sidecar gives 565 GMAC/s/mm² against 742 for CNSB INT mode on the grid
  (5%: 603 vs 747; 30%: 520 vs 723). BOS wins only if INT8 is most of the work, and then the right answer is a BOS chip, not PaYN.

## 6. What is verified, what is estimated, risks, next steps

**Verified:**

- **Arithmetic.** All four mappings, through the re-run Python models plus independent checks: exhaustive Booth identities,
  the comparator identity for every lane and code pair, Horner range bounds, and the OWIDTH=24 limits.
- **RTL.** CNSB on the unmodified CSA RTL in VCS (real 1x1 top; grids up to 4x4 from the real peripheral and PE): 27 bit-exact
  cases plus 3 built-to-fail cases that failed. WO: 33/33 RTL cases at every chunk limit, grids up to 3x2. BP: independent
  register-level simulator up to 4x4 (no VCS grid run).
- **Energy.** CNSB 10 points and BP 30 points on the routed CSA single PE. All are RTL+GL bit-exact, and validate_routed_gl, the SAIF check and PT coverage all pass.
- **Synthesis** (DC, PAYN_SC_CSA settings): the CNSB preset, feeders and combiner, and the WO ring, feeders and collector.
- **Routed timing** (PT): loading new operands every cycle already fits (binary_q -> bit pipe +1.70 ns, sign pipe -> acc_low +1.39 ns).
  The routed T=16 run already loads every cycle with 0 violations. The Sobol preset sits on the D side (+1.93 ns).

**Estimated only:**

- **Area.** All BP areas and all ROT areas (cell count), the skew-line flop counts, and the 100 um² controllers.
  **The BP ranking rests on its 1.28% / 1.70%, which is not synthesized.**
- **Timing** (all untimed): BP's ring return path (192 wires per PE, 170-250 um, ~1.2 ns estimated); BP's bypass OR on the
  Sobol -> comparator -> bit-pipe path (+0.307 ns slack); WO's `ring_q` ORed into `shift_in`, on the routed worst path (+0.146 ns).
- **Energy and scale.** WO and ROT energy are not measured. No grid is routed; grid figures are composites.
  The memory system (SRAM banks for the feed) is not costed for any design, SC included.

**Open risks:**

1. **BP SC safety.** The 512 shared raw lines must be gated by `int_mode` (ungated, 48 of 64 SC tiles came out wrong, verified);
   each SC -> INT switch needs one zero-load of the magnitude registers; `ring_q` needs a reset, or reset held >= P_C clocks.
2. **Mode switching (CNSB/WO).** After an INT layer the Sobol registers still hold the preset, so SC needs a reset or a Sobol restore.
   The preset must also open the 48 per-generator clock-gate enables, not one enable per bank.
3. **Padding, all designs.** The feeder must drive zero codes and zero signs on every padding cycle.
   One X sign made 64/64 accumulators X, and held data double-counted (56/64 wrong).
4. **Re-closing SC.** Any change inside the array means re-synthesis and re-APR. The accepted 44,018 um², 15.447 mW and +0.146 ns must then be re-established.
5. **Bench timing.** When `shift_in` falls while both mux inputs carry live data (rings, repeated drains), launch inputs at the SDC input delay (negedge).
   Launching 1 ps after the posedge silently corrupted 5 tiles per block in the first BP run.
6. **Range limits** per output pass: BP INT8 L <= 65,535; CNSB L <= 524,287 (combiner >= 34 bits); WO 511 (FH) or 8,191 (HYS); ROT 496.
7. **CNSB-specific.** Its code tables have zero slack: 3-4 lane entries have exactly one valid code, so they must be re-searched if the masks change.
   It needs a zero-point shift for UINT8; BP handles UINT8 directly (a_sign = 0).

**Next steps:**

1. Agree the feed budget (bits/cycle into the grid) with the memory-system side. That number picks BP or CNSB.
2. Write the BP RTL as a new variant: the gated bypass OR in the peripheral, the ring mux and `ring_q` in the PE, the plane combiner, and the sequencer.
3. Synthesize the BP pieces in the PAYN_SC_CSA flow, to confirm or overturn the 1.28% / 1.70%.
4. Build a CSA grid wrapper and an RTL grid test (2x2 to 4x4) with per-cycle sign loads. None exists today.
5. Re-synthesize and re-APR the single PE with the chosen array changes. Re-measure SC T=128 power and the +0.146 / +0.307 ns paths.
6. Time the ring return wires, and route a small grid.
7. Measure grid-level INT energy with the drain included. Measure WO only if it is still in contention.
8. For the CNSB fallback: write the Sobol preset into `sobol.sv`, re-deriving the clock-gate enables, then synthesize the recoders, code tables and combiner as one edge block.

## 7. Against dedicated INT8 / INT6 / INT4 arrays (estimate, 2026-10-03)

Script: `sweeps/int_mode/compare_int_vs_bos.py`. Output: `build/power_char/int_mode_energy_20261003/int_vs_bos_estimate.csv`.
All workloads are uniform random over the full range, which is what the BOS benches use.

BOS is the dedicated binary output-stationary 8x8 array at 64 MAC/cycle. Its area efficiency does not depend on how many
arrays are tiled together.

PaYN rows give "peak" (drain-excluded, as BOS and SC are) and "L=4096". The L=4096 figure includes ring laps, skew and drain:
- 1 PE: 8 cycles per ring lap and 8 drain cycles.
- 4x4: 6 skew cycles and 32 drain cycles per output block.

pJ/MAC on 4x4 is a composite: 16 x u_pe + 4 peripherals + Sobol. No grid has been routed.

The INT-mode areas include the whole SC array plus the INT additions:
- bit-plane: +1,802 / +8,863 um2, a cell-count estimate;
- spatial Booth: +2,462 / +9,538 um2, synthesized edge blocks.

| precision | design | GMAC/s/mm2 peak (1 PE / 4x4) | at L=4096 (1 PE / 4x4) | pJ/MAC (1 PE / 4x4) | fJ per bit-product (4x4) |
|---|---|---:|---:|---:|---:|
| INT8 | **BOS binary** | 1,621 | 1,621 | 0.412 * | 6.4 |
| INT8 | PaYN bit-plane | 1,117 / 1,543 | 894 / 1,129 | 0.370 / 0.383 | 6.0 |
| INT8 | PaYN spatial Booth | 551 / 771 | 543 / 718 | 0.795 / 0.662 | 10.3 |
| INT8 | PaYN SC T=128 (approx.) | 582 / 785 | 582 / 785 | 0.603 / 0.525 | - |
| INT6 | **BOS binary** | 2,064 | 2,064 | 0.260 | 7.2 |
| INT6 | PaYN bit-plane (estimate) | 1,490 / 2,058 | 1,192 / 1,463 | 0.22-0.25 / 0.23-0.27 | 6.4-7.4 |
| INT6 | PaYN spatial Booth (estimate) | 551 / 771 | 543 / 718 | 0.69 / 0.56 | 15.5 |
| INT6 | PaYN SC T=32 (approx.) | 2,326 / 3,139 | 2,326 / 3,139 | 0.181 / 0.149 | - |
| INT4 | **BOS binary** | 2,491 | 2,491 | 0.155 | 9.7 |
| INT4 | PaYN bit-plane | 4,470 / 6,174 | 3,576 / 4,159 | 0.093 / 0.099 | 6.2 |
| INT4 | PaYN spatial Booth | 2,203 / 3,083 | 2,170 / 2,870 | 0.198 / 0.165 | 10.3 |
| INT4 | PaYN SC T=16 (approx.) | 4,653 / 6,279 | 4,653 / 6,279 | 0.117 / 0.092 | - |

\* BOS INT8 keeps its older flow and constraints; the flow difference moved BOS by about 3.5% before. BOS INT6 and INT4 were routed
on 2026-10-02.

Notes:
- **How the INT8 / INT4 energies were built.** The per-cycle energies of the data and ring cycles are measured. The schedule
  composition at L=4096 is arithmetic. About 1 mW of unmodelled bit-plane cells is added during data cycles.
- **INT6 PaYN rows are estimates: no INT6 mapping was built or measured.**
  - Bit-plane uses 6 of 8 activation-plane rows and 6 weight passes, with the data-cycle energy assumed at 0.75-0.9x of INT8.
  - Spatial Booth runs INT6 on the INT8 Booth mapping: 3 of 4 digit rows are active and the MAC rate is the same.
- **SC rows are approximate arithmetic** at the nominal precision-equivalent T from `doc/bitmod_results.md`. They are not
  integer-exact.
- **Operand delivery and SRAM energy are excluded for every design.** Bits per MAC at the array boundary on 4x4:
  - BOS, b/4 per array;
  - bit-plane, 4 (INT8), 3 (INT6) and 1 (INT4), plus activation replay reads;
  - spatial Booth, 1.5.

## 8. Routed implementation (2026-10-04)

Bit-plane was implemented, verified, synthesized and routed:
[`designs/payn/variants/signed_segmented_csa_bp/README.md`](../designs/payn/variants/signed_segmented_csa_bp/README.md).

The measured numbers replace the estimates in sections 1, 5 and 7:

| | estimate | measured |
|---|---:|---:|
| SC-mode cost, 1 PE area | +4.1% | +5.0% |
| SC-mode cost, 4x4 area | +1.7% | +2.0% |
| SC-mode power | +0.5% | +4.9% |
| INT8 pJ/MAC, peak | 0.32 | 0.349 |
| INT8 pJ/MAC, L=4096 | 0.37 | 0.380 |
| INT4 pJ/MAC, peak | 0.08 | 0.088 |
| INT4 pJ/MAC, L=4096 | 0.093 | 0.095 |

Notes on the SC-mode cost:
- The 4x4 area is a composite of routed blocks.
- About 0.2 mW of the power is bypass hardware. About 0.5 mW is tile glitching
  from a larger a/w skew in the BP layouts, a layout effect measured on one sample
  per arm.

Against the dedicated binary arrays, at 4x4 peak:
- INT8: 0.95x the area efficiency at 0.82x the energy.
- INT4: 2.5x the area efficiency at 0.56x the energy.

## 9. 4x4 and 4x8 grid side by side (2026-10-04)

Script: `sweeps/int_mode/compare_grid_configs.py`. Output: `build/power_char/int_mode_energy_20261003/grid_config_comparison.csv`.

**Composite.** N_PE x routed u_pe + edge halves / 2 x peripheral + one combiner per PE row (BP only) + one Sobol pair, with the
matching routed hierarchy powers. No grid has been routed.

**Measured inputs.** The pinned BP and CSA routes, and the INT per-cycle energies of the routed BP (data, ring and drain cycles).

**L=4096 column.** Adds the schedule overhead of an output block. INT has passes x 32 data cycles, 8-cycle ring laps, skew and
an 8*P_C drain. SC has L*T/128 data cycles plus skew and drain.

Each cell is peak / L=4096.

| precision | design | 4x4 GMAC/s/mm2 | 4x4 pJ/MAC | 4x8 GMAC/s/mm2 | 4x8 pJ/MAC |
|---|---|---:|---:|---:|---:|
| INT8 | binary 8x8 OS * | 1,621 / 1,612 | 0.412 / 0.415 | 1,621 / 1,612 | 0.412 / 0.415 |
| INT8 | PaYN bit-plane INT | 1,542 / 1,128 | 0.338 / 0.380 | 1,591 / 1,055 | 0.337 / 0.396 |
| ~INT8 | PaYN SC T=128, carry-save only (pinned) | 786 / 779 | 0.532 / 0.534 | 807 / 793 | 0.526 / 0.531 |
| ~INT8 | PaYN SC T=128, with bit-plane HW (pinned) | 771 / 764 | 0.554 / 0.556 | 796 / 781 | 0.548 / 0.553 |
| INT6 | binary 8x8 OS | 2,064 / 2,053 | 0.260 / 0.262 | 2,064 / 2,053 | 0.260 / 0.262 |
| INT6 | PaYN bit-plane INT (estimate) | 2,055 / 1,462 | 0.19-0.23 / 0.23-0.26 | 2,122 / 1,331 | 0.19-0.23 / 0.24-0.28 |
| ~INT6 | PaYN SC T=32 (approx.) | 3,139 / 3,027 | 0.149 / 0.152 | 3,225 / 3,008 | 0.147 / 0.152 |
| W4A8 | PaYN bit-plane INT | 3,083 / 2,077 | 0.169 / 0.195 | 3,182 / 1,802 | 0.169 / 0.209 |
| INT4 | binary 8x8 OS | 2,491 / 2,478 | 0.155 / 0.156 | 2,491 / 2,478 | 0.155 / 0.156 |
| INT4 | PaYN bit-plane INT | 6,166 / 4,154 | 0.085 / 0.098 | 6,365 / 3,605 | 0.085 / 0.105 |
| ~INT4 | PaYN SC T=16 (approx.) | 6,279 / 5,845 | 0.092 / 0.095 | 6,450 / 5,636 | 0.090 / 0.095 |

\* Older flow (+-~4%). Binary arrays tile with no shared edge, so their numbers do not change with grid shape.

How the rows were built:
- **SC T=32 and T=16** are from the floating-pin carry-save T sweep, which has no BP hardware.
- **INT6 PaYN** is an estimate: no INT6 mapping was built. It assumes 6 activation-plane rows and 6 passes.

What the table shows:
- **4x8 vs 4x4.** 4x8 amortizes the edge further, so peak efficiency is slightly higher. It also doubles the drain (8*P_C), so
  INT at L=4096 drops more.
- **The INT long-GEMM gap is schedule overhead.** At L=4096 the 7 ring laps, skew and drain cost 27% (4x4) and 34% (4x8) of
  INT8 cycles. A per-tile self-shift (~+2% area) or a parallel drain would recover most of it.

**Correction: grid-level INT items the composite misses (2026-10-04).**

1. **Ring laps were global in the first routed RTL (`csa_bp_20261003b`).** After review, laps use the global `shift_in` to keep the tile clock-gate path
   untouched. On a grid, each lap must wait for the last PE's skewed pass, so every pass pays P_R+P_C-2 bubble cycles. The
   L=4096 figures in the table above assumed per-PE skewed laps.

   As-built at L=4096:

   | | INT8 | W4A8 | INT4 |
   |---|---:|---:|---:|
   | 4x4 GMAC/s/mm2 | 1,007 (vs 1,128) | 1,897 | 3,795 |
   | 4x8 GMAC/s/mm2 | 893 (vs 1,055) | 1,591 | 3,182 |

   pJ/MAC rises by about 0.01-0.03.

   Restoring skewed laps needs a per-PE lap enable that travels with the operand wave (`ring_q`). That is a few gates per PE. A
   registered per-PE shift enable would also give the clock-gate path a full cycle instead of the 1.25 ns input budget.

2. **The INT raw planes need edge skew.** SC staggers the held-operand load strobes for free. INT takes new bits every cycle, so
   either the feeder staggers its reads per edge half (free) or skew flops are added (4x4: ~12k flops, ~16k um2, ~3% of the
   grid).

Everything else at grid level is either common to SC or already counted: inter-PE operand forwarding, the drain chain, the
clock, the edge bypass, the combiners, and the 1-bit ring wave.

**Update to the correction above (2026-10-04).** Item 1 is fixed. The per-PE lap enable (core shift = `shift_in | ring_q`) is
verified at RTL on single PEs and on 2x2 to 4x8 PE grids, synthesized as `csa_bp_20261004_lap`, and routed with pinned IO
(`csa_bp_20261004_lap_distguide_spp_pins`, grid basin). Measured on the 4x4 grid at L=4096, every PE laps at offset r+c with no
per-pass bubbles: INT8 runs 350 edges per block instead of 392. The skewed-lap figures in the table above hold again (INT8 L=4096:
1,128 on 4x4, 1,055 on 4x8).

Against the `csa_bp_20261003b` pinned route:
- SC power is 16.494 vs 16.491 mW and area 46,096 vs 46,130 um2, both layout noise.
- Routed INT energy is 0.1-0.2% lower (INT8 peak 0.348 pJ/MAC, INT4 0.087).
- Routed full-timing functional GL in the new contract is 8/8, including a negative control. On the 03b netlist the ring-only cases
  fail, which shows the test can tell the two netlists apart.
- Timing costs more than the DC estimate. `shift_in` becomes the critical start point, at +0.078 ns (it was +0.361 ns), because of
  the OR2 plus weaker buffering on the core shift net. It still closes 400 MHz.

The registered per-PE shift enable mentioned above was not used. Item 2 (raw-plane edge skew) is still open. Evidence:
`build/power_char/pinned_pass2_csa_bp_20261004_lap/comparison.txt`, `build/power_char/int_mode_energy_20261004_lap/bp/`.

**Lap schedules: can the reduction run first and the shift come at the end? (2026-10-04)**

Model: `sweeps/int_mode/bp/model_lap_schedules.py` (log and CSV next to it). Every period below is also measured in RTL on the
unchanged `csa_bp_20261004_lap` design. One output block on a P_R x P_C grid costs (NB = L/128):

```
T1 as built      BW*NB    + 8*(BW-1)      + (P_R+P_C-2) + 8*P_C     8 outputs per PE
T2 S=8           NB       + 0             + (P_R+P_C-2) + 8*P_C     1 output per PE (all 8 weight bits in space)
T3 self-doubling BW*NB    + 1*(BW-1)      + (P_R+P_C-2) + 8*P_C     8 outputs per PE (PE change)
H(TA,TW)         TA*TW*NB + 8*(TA+TW-2)   + (P_R+P_C-2) + 8*P_C     (8*TA/BA) x (8*TW/BW) outputs per PE
```

INT8, % of peak / GMAC/s/mm2 (routed `csa_bp_20261004_lap` composite; H includes an unsynthesized +601 um2 combiner per PE row,
T3 the synthesized +969 um2 per PE):

| INT8 schedule | 4x4 L=1024 | 4x4 L=4096 | 4x8 L=1024 | 4x8 L=4096 | change |
|---|---:|---:|---:|---:|---|
| T1 as built | 40.5% / 625 | 73.1% / 1,128 | 33.0% / 525 | 66.3% / 1,055 | - |
| T2 S=8: reduction first, shift at the end | 17.4% / 269 | 45.7% / 707 | 9.8% / 156 | 30.2% / 482 | none |
| T3: 1-cycle in-place doubling | 58.7% / 880 | 85.0% / 1,274 | 44.1% / 682 | 76.0% / 1,174 | 64 tile muxes per PE |
| **H(4,8): 4 activation bits in time too** | **68.4% / 1,051** | **89.7% / 1,376** | **62.4% / 991** | **86.9% / 1,380** | none in the array |
| H(4,8) with T3's 1-cycle laps | 84.2% / 1,256 | 95.5% / 1,425 | 75.3% / 1,161 | 92.4% / 1,424 | as T3 |
| T1 with 2-tile sub-rings (2-cycle laps) | 55.2% / 840 | 83.1% / 1,265 | 42.1% / 661 | 74.4% / 1,169 | 32 muxes per PE, synthesis to be rerun (AFS) |

W4A8 H(8,4) and INT4 H(4,4) (the round-1 "HB" corner) reach 89.7% / 2,753 and 85.6% / 5,257 on 4x4 at L=4096, against T1's
67.4% / 2,077 and 67.4% / 4,155.

What the table shows:
- **Running the reduction first (T2) ties T1 on one PE and loses on grids.** It removes the laps, but each PE then holds one output
  instead of 8, so every output pays its own drain across the PE row (8*P_C cycles) and skew. A lap stays inside one PE (8 cycles).
- **The lever is outputs per PE per block, not where the 2^s is applied.** 4x4 INT8 L=4096, cycles per 8 outputs per PE: T2 S=8 560,
  T1 350, H(4,8) 285.5. The hybrid amortizes the same drain and skew, and 10 laps instead of 7, over 4x more MACs.
- **H beats T3 on every grid point above without touching the PE.** On one PE, T3 is ahead (L=4096: 1,028 vs 1,010), because the
  1-PE drain is short and H's combiner is a larger fraction of one PE.
- **The best split depends on L** (4x4 and 4x8 alike):
  - H(8,8) for L <= 511;
  - H(4,8) up to L = 4,369;
  - H(4,4) up to about L = 37,000 (16 outputs per PE);
  - H(2,4) beyond that (8 outputs per PE, range 186k). It gives 98.3% at L = 65,536, where T1 must split the block.
- **Costs of H, none inside the array:** the east combine changes (and the 1-PE top's combiner does not do it); A must arrive as
  bit planes (bit-plane-major storage, written at run time by the previous layer, or a TA:1 select per A line: +7.2k um2, -1.3%
  GMAC/s/mm2 on 4x4); the per-block working set grows 4x on the A side (A replay buffer) and W is re-sent TA times per block. Operand bits
  per MAC and per-GEMM sends are the same as T1.

RTL evidence (unchanged RTL, bit-exact against numpy):
- PE grids 1x1 to 4x8: 26 nominal hybrid runs plus 6 controls from the review (`build/rtl_preflight/bp_hybrid/`, reproduced
  identically in `bp_hybrid_rerun/`), and 16 more plus 5 controls (`bp_hybrid_fix/`). They include the INT8 H(4,8) range edge
  L = 4,352 with |tile| = 8,355,840.
- The single-PE top with a proposed hybrid combiner as a sidecar (`designs/payn/variants/signed_segmented_csa_bp_hyb/bp_hybrid_combiner.sv`):
  16 runs, 4 controls and 3 byte-identical cross-checks against the T2 bench at S=1 (`build/rtl_preflight/bp_hybrid_top/`).
- 58 measured block periods all equal the formula. Gate level was not run (the AFS token had expired).
- T2 runs: `build/rtl_preflight/bp_space/` has 127 simulation cases (single PE: 28 positive, 14 period, 8 controls; grids: 29 positive,
  28 period, 20 controls) plus 6 cross-checks, all as expected.

## 10. Memory bandwidth: can an SC-sized SRAM feed the INT mode? (2026-10-04)

BP needs 1,024 operand bits per edge half per cycle on both sides. SC T=128 needs 576 bits per edge half once every 8 cycles.

The weight side binds: in pass q, column v needs bit q of 128 weights x 8 columns every cycle. An activation replay buffer cannot help
it. In the as-built schedule the 8 tile rows carry the 8 bits of one activation row, so a block holds 8x fewer outputs than in SC.
*(Corrected 2026-10-04: this is a property of the schedule, not of BP. The hybrid H(4,8) of section 9 holds 4x more outputs per block
on the same hardware, and a W block buffer at the array edge removes the weight-side re-fetch; see "edge buffers" below.)*

4x4 throughput, for two readings of "sized for SC", **assuming no operand reuse at the array edge** (every bit a data cycle needs
comes from the SRAM; peak x supply / demand):

| mode | (i) SC T=128 average, 72 b/cycle per edge half | (ii) the 576-bit block every cycle (what SC T=16 needs) |
|---|---|---|
| SC T=128 | 1.0 MAC/tile-cycle (771 GMAC/s/mm2) | 1.0 |
| BP INT8 | 0.14 (7% of peak), 108 | 1.12 (56%), 867 |
| BP W4A8 | 0.28, 217 | 2.25, 1,734 |
| BP INT4 | 0.56, 434 | 4.5, 3,469 |
| spatial Booth INT8 | 0.28 (28%), 217 | 1.0 (100%), 771 |
| spatial Booth INT4 | 1.12, 867 | 4.0, 3,083 |

What follows from each reading:
- **(i):** BP is memory-bound and slower than SC itself, and spatial Booth is the better INT mode.
- **(ii):** BP INT8 lands just above SC T=128 at about half the energy per MAC, and INT4 still beats the binary array.
- **BP at peak** needs about 1,024 b/cycle per edge half (1.8x the SC block width).

The answer depends on how the SRAM is actually provisioned, which is still open. A standalone binary 8x8 array also needs about
2 bits/MAC, so the binary area-efficiency figures assume their own feed.

**With edge buffers (added 2026-10-04, review of the schedule study).** The table above assumes no reuse at the array edge. Two
buffers change it:
- an A replay buffer per PE-row edge, holding one block's activations (double-buffered);
- a W block buffer per PE-column edge (8 columns x BW x L bits), kept for a whole sweep over M (M as the inner loop).

Then the SRAM delivers each A bit once per block and each W bit once per M sweep. The buffers serve the full 1,024 b per cycle per
edge half, so they are wide local SRAMs.

Model section 6b, 4x4, L=4096, M = 2,048, N = 4,096. Cells: MAC/tile-cycle / GMAC/s/mm2 [buffer capacity on the grid]:

| mode | (i) 72 b/cycle, no buffers | (i) with buffers | (ii) 576 b/cycle, no buffers | (ii) with buffers |
|---|---|---|---|---|
| BP INT8, T1 as built | 0.14 / 108 | 1.11 / 854 [160 KB] | 1.12 / 867 | 1.46 / 1,125 [160 KB] |
| BP INT8, H(4,8) | 0.14 / 108 | 1.11 / 850 [256 KB] | 1.12 / 863 | 1.79 / 1,372 [256 KB] |
| BP W4A8, H(8,4) | 0.28 / 216 | 2.22 / 1,700 [256 KB] | 2.25 / 1,727 | 3.58 / 2,744 [256 KB] |
| BP INT4, H(4,4) | 0.56 / 432 | 2.23 / 1,713 [192 KB] | 4.50 / 3,453 | 6.81 / 5,225 [192 KB] |
| spatial Booth INT8 | 0.28 / 217 | 0.56 / 430 [128 KB] | 0.93 / 718 | 0.93 / 716 [128 KB] |
| spatial Booth INT4 | 1.12 / 867 | 2.22 / 1,708 [128 KB] | 3.72 / 2,871 | 3.71 / 2,861 [128 KB] |

Spatial Booth is on the same area basis as the table above (the BP-lap composite; its own edge blocks are not added). Its no-buffer
(ii) cells include skew and drain (0.93), unlike the peak figure above.

What the buffers change:
- **Under (i) with buffers, BP INT8 and W4A8 run at about 2x spatial Booth, and INT4 ties.** Each BP data cycle then needs about
  128 b of A from the SRAM, and spatial Booth needs 128 b per cycle for half as many MACs. So reading (i) alone no longer picks spatial
  Booth. It does if the buffers are not built.
- **The rescheduling gain shows only where the array is compute-bound** (reading (ii) with buffers). Memory-bound points run at the
  same rate whatever the schedule.
- **T2 S=8 gains nothing from the buffers**: with one output per PE there is no reuse inside a block.
- **The cost is the buffers**: 128-256 KB on a 4x4 at L=4096, with 1,024-bit ports for BP (128 / 256-bit for spatial Booth).

So the open decision has a second part. Besides "72 b/cycle average or the full 576-bit block every cycle", it matters whether edge
buffers of this size and port width can be built.
