# bitmod: routed results and comparison

Measured results for the bitmod bit-serial accelerator, for comparison against
the PaYN and binary baselines.

**Source.** `doc/bitmod_data - jul29.csv`, produced from the collaborator's
`cflow_output` runs (post-PnR gate-level simulation with SDF back-annotation,
PT-PX back-annotated power, uniform-random stimulus with no bubbles).  The RTL
is migrated into this repo at [`designs/baselines/bitmod/`](../designs/baselines/bitmod/);
see its README for provenance and the file split.

**Not independently verified.** Every figure below traces to the CSV.  The local
migration in [`designs/baselines/bitmod/`](../designs/baselines/bitmod/) is the
**BitMoD** variant (`pe_scratch` / `tile` / `fpadd`); the `Simple` variant
(`pe_simple` / `tile_simple`) was never migrated, so none of the `Simple`
numbers below have been reproduced here at all.

For the BitMoD tile the migration reproduces area closely — 69,337 µm²
synthesized against the CSV's 69,684 µm² routed, 0.5% apart, and 14,565
sequential cells — but not power: across seven route attempts it did not close
timing (best setup WNS +0.054 ns, the others −0.000 to −0.027 ns) and no PT-PX
workload-SAIF run was completed.  Its Innovus APR-stage estimate under default
activity was 40.90 mW against the CSV's SAIF-annotated 28.84 mW, but the two use
different activity methodologies and are not comparable.  Treat everything here
as reported results awaiting replication.

**Measurement boundary.** The `tile full` row measures `tile_simple`, which
contains **one** `pe_simple_common` plus **64** bare `pe_simple`, along with the
accumulate-row logic, output buffer and drain chain.  Per-tile control is
therefore amortized over 64 PEs, not replicated per PE (`pe_simple_with_control`
is a separate 1-PE wrapper used only by `tb_pe_simple_power` and is not what was
measured).  `tile array` is exactly 16x `tile full`, and `total` adds the
chip-level `controller_simple` and `skew_simple`:

| boundary | pJ/MAC (i8 x i8) |
|---|---:|
| tile array only (16 tiles, incl. per-tile control) | 0.4753 |
| **+ chip controller + skew (the quoted figure)** | **0.482** |

Chip-level control adds 0.0057 pJ/MAC, or 1.2%.

## The two variants are very different designs

| | `BitMoD` | `Simple` |
|---|---|---|
| activations | f16 | i8 |
| weights | i8 / i6 / f4 | i8 / i6 / i4 / i2 |
| dequantization | **yes** — per-group u8 scale, `S -> kS` | **no** (compiled out) |
| accumulate | 23b mantissa / 6b exponent float | 24b integer |
| tile area | 69,684 µm² | 21,906 µm² |

Both are 8x8 PEs per tile, 4x4 tiles = 1,024 PEs at 400 MHz.  `Simple` is 3.2x
smaller per tile, which is what removing f16 activations, the float accumulator,
and the dequantization stage buys.

## Area

| block | `BitMoD` (µm²) | `Simple` (µm²) |
|---|---:|---:|
| controller | 8,841 | 3,571 |
| skew | 6,132 | 3,788 |
| tile (8x8 PEs) | 69,684 | 21,906 |
| tile array (x16) | 1,114,937 | 350,500 |
| **total** | **1,129,910** (1.130 mm²) | **357,858** (0.358 mm²) |

Control is 1.3% of `BitMoD` and 2.1% of `Simple` — amortized over 16 tiles, the
control plane is nearly free in both.

## Energy and throughput

Total = controller + skew + tile array.  Throughput scales with weight precision
because a radix-4 Booth digit is retired per cycle per lane.

### BitMoD (f16 activations, with dequant)

| MAC type | throughput (GMAC/s) | power (W) | **pJ/MAC** | GMAC/(s·mm²) |
|---|---:|---:|---:|---:|
| i8 x f16 | 409.6 | 0.466 | **1.137** | 363 |
| i6 x f16 | 546.1 | 0.484 | **0.886** | 483 |
| f4 x f16 | 819.2 | 0.485 | **0.592** | 725 |

### Simple (integer only, no dequant)

| MAC type | throughput (GMAC/s) | power (W) | **pJ/MAC** | GMAC/(s·mm²) |
|---|---:|---:|---:|---:|
| i8 x i8 | 409.6 | 0.197 | **0.482** | 1,145 |
| i6 x i8 | 546.1 | 0.205 | **0.376** | 1,526 |
| i4 x i8 | 819.2 | 0.213 | **0.260** | 2,289 |
| i2 x i8 | 1,638.4 | 0.232 | **0.142** | 4,578 |

Power rises only 17.6% from i8 to i2 while throughput rises 4x, so energy per
MAC falls 3.4x.  The residual power rise is activation reload: at i2 an element
completes every cycle, so the activation registers and their broadcast network
toggle 4x more often than at i8, where operands are held for four Booth digits.

## Against the PaYN and binary baselines

All routed, TSMC22 A7/SVT, 400 MHz.  PaYN figures are the accepted `spp_fixed`
route, full-design boundary.

| design | precision | pJ/MAC | area (mm²) | GMAC/(s·mm²) |
|---|---|---:|---:|---:|
| BP signed INT8 | i8 x i8 | 0.414 | 0.017 | 1,548 |
| BOS signed INT8 | i8 x i8 | 0.427 | 0.016 | 1,605 |
| **bitmod Simple** | i8 x i8 | **0.482** | 0.358 | 1,145 |
| PaYN, T=128 | ~8-bit | 0.710 | 0.052 | 494 |
| **bitmod BitMoD** | i8 x f16 | **1.137** | 1.130 | 363 |
| PaYN, T=64 | ~7-bit | 0.379 | 0.052 | 987 |
| **bitmod Simple** | i4 x i8 | **0.260** | 0.358 | 2,289 |
| PaYN, T=32 | ~6-bit | 0.213 | 0.052 | 1,974 |
| **bitmod Simple** | i2 x i8 | **0.142** | 0.358 | 4,578 |
| PaYN, T=16 | ~4-bit | 0.137 | 0.052 | 3,948 |

Reading it:

- **At INT8, bitmod `Simple` sits between the binary baselines and PaYN**, 13%
  above BOS and 32% below PaYN at T=128.  A radix-4 Booth design retires the
  same four partial products per MAC as a Booth multiplier; it reorders them in
  time rather than doing less arithmetic, so landing near binary is expected.
- **`BitMoD` is the most expensive design measured**, 2.4x `Simple` and 1.6x
  PaYN.  f16 activations, the float accumulator, and the dequantization stage
  cost more than the datatype flexibility returns at these precisions.
- **At each design's lowest precision the two converge**: bitmod i2 at 0.142 and
  PaYN T=16 at 0.137, within 4%.  PaYN gets there in 7x less area, but
  bitmod has 16x the throughput, so bitmod wins area efficiency 4,578 vs 3,948.
- **Area efficiency favors bitmod at every matched tier**, roughly 2x, because
  its 1,024 PEs are far denser per unit throughput than PaYN's stochastic array.

## Why both scale the same way

Each design holds a **fixed primitive-event rate** and spends precision to buy
throughput:

| | primitive | rate | events per MAC |
|---|---|---:|---|
| bitmod | radix-4 Booth term | 1.638e12 /s | 4 (i8), 3 (i6), 2 (i4), 1 (i2) |
| PaYN | stochastic bit | 3.277e12 /s | T (128 … 16) |

bitmod's term rate is constant because every PE lane retires one Booth digit per
clock regardless of mode; PaYN's Sobol banks emit `M=16` bits per clock
regardless of `T`.  In both cases energy per MAC falls roughly linearly with
events per MAC, offset by a reload term that grows as operands are held for
fewer cycles.  That common structure is why the curves converge at their
low-precision ends.

## Comparability caveats

1. **Precision is not matched across rows.** `i2 x i8` and PaYN `T=16` are both
   low-precision modes, not the same numeric operation.  The bracketing in the
   table is by rough precision tier, not equivalence.
2. **`BitMoD` includes dequantization; `Simple` does not.** If the datatype
   claim requires per-group scales, `Simple`'s number is missing that hardware.
3. **bitmod totals are whole-design** (controller + skew + 16 tiles); PaYN's
   full-design boundary includes its peripheral and Sobol banks.  BP and BOS
   have no separate control plane.  These are the closest available like-for-like
   boundaries, but they are not identical in composition.
4. **PaYN's low-`T` points are drain-excluded** and increasingly oversubscribed
   (8x at `T=16`); see [`results.md`](results.md).  bitmod's windows include its
   drain.
5. **`Simple` is a single-stage PE and carries almost no pipeline registers.**
   `pe_simple` holds exactly two 24-bit registers (`s1_acc`, `o_acc`), both
   clock-gated, with `gclk_o` enabled only on `i_vld & i_last`.  It has **no
   operand input registers**: `a`, `w_sem` and `w_bsig_1hot` arrive
   combinationally, broadcast from the tile inputs, and are registered only once
   per tile (`cg_o_a`, itself gated by `i_vld_first_elem`).  The whole
   broadcast -> Booth -> adder-tree -> align -> 24-bit accumulate path fits in
   one 2.5 ns clock.  That is 48 flops per PE against `pe_scratch`'s ~228 and
   against PaYN, which registers every operand at every PE
   (`a_bits_pipe[N_H][K]`, `w_bits_pipe[N_W][K]`).  A large share of `Simple`'s
   energy advantage is avoided register and clock-tree power, not cheaper
   arithmetic — it buys that by spending timing margin.
6. **The measured `Simple` route does not close timing: setup WNS −0.004 ns at
   2.5 ns** (`cflow_output/tile_simple_jul30_0602_full_merged_s1`, 2 of 1,998
   reported paths violating; hold clean at +0.050).  The critical path is not
   the PE datapath — it is the partial-sum scratchpad read-modify-write:
   `accum_row` counter -> 6-deep buffer tree -> `cg_obuf` read mux -> a
   **30-stage ripple-carry adder** (~1.4 ns of the 2.451 ns arrival) -> `cg_obuf`
   write port.  Synthesis chose the smallest, lowest-power adder and stopped 4 ps
   short rather than buy a fast adder; closing that path would raise power.
   Every PaYN and binary row in the table has positive margin, and the accepted
   PaYN route closes at +0.499 ns — margin this design is not paying for.
