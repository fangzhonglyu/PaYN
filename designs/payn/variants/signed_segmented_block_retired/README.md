# Block-retired signed segmented accumulator

This is an isolated exact design point for the PaYN bipolar accumulator.  It
uses the fact that operand signs remain fixed for all `T/M` parallel stochastic
cycles, while the `M` generated bits and their hit counts change every cycle.
It has its own tile, PE, array wrapper, and testbench; it does not select a
datapath with compile-time conditionals inside another variant.

## Arithmetic

For lane hit count `c_i` and negative-lane flag `n_i`, each enabled MAC forms
the non-negative value

```
u_i = n_i ? M-c_i : c_i
```

Let `L=T/M` be the number of enabled MACs in one sign block and let
`Nneg=countones(n)`.  Because the signs are constant for the complete block,

```
sum_t sum_i (+/- c_i)
  = sum_t sum_i u_i - L*M*Nneg
  = sum_t sum_i u_i - T*Nneg.
```

`T` is constrained to a power of two, so the accumulator is segmented at
radix `T`.  Every cycle, the heap adds the `K` unsigned `u_i` values to the
`log2(T)`-bit low digit.  The low residue is registered and the quotient is
accumulated in a small counter.  On the final enabled MAC in the block, the
high bank is updated once:

```
high_next = high + block_quotient - Nneg
low_next  = (low + sum(u_i)) mod T
```

The final cycle's quotient is included in `block_quotient`.

For the target `K=8, M=16, T=128`:

- the hot low heap is 8 bits wide, versus 11 bits in the accepted pending-bit
  implementation;
- the low state is 7 bits and the block quotient counter is 4 bits;
- one cycle crosses at most one radix-128 boundary;
- the 17-bit high bank is enabled once every 8 productive MACs;
- one shared 3-bit PE phase counter generates `block_last` for all 64 tiles.

There is no per-tile phase or saved-sign-count register.  The live sign count
is stable by contract and is sampled on the block's last MAC.

## Exactness over arbitrary complete blocks

At a block boundary, write the modulo-`2**OWIDTH` state as

```
X = H*T + r,  0 <= r < T.
```

For the complete block, let

```
r + sum_t sum_i u_i = q*T + r'.
```

The implemented update produces

```
X' = (H + q - Nneg)*T + r'
   = H*T + r + sum_t sum_i u_i - T*Nneg
   = X + sum_t sum_i (+/- c_i).
```

Therefore every completed block is exact modulo `2**OWIDTH`, and any number
of completed blocks may accumulate without a growing bias or deferred debt.

The generic RTL also supports smaller power-of-two `T` values divisible by
`M`.  A cycle may then cross multiple radix boundaries.  The cycle quotient
width is derived from `T+K*M`, while the full-block quotient is always at most
`K` because the block contains `T/M` cycles and at most `K*M` biased hits per
cycle.

## Control contract

- Signs must remain unchanged across all `T/M` enabled MACs in a block,
  including the sampling edge of its final MAC.
- Idle clocks do not advance the shared phase or any tile state.
- The final MAC retires its own block.  No following load or finalize pulse is
  required, which is important for the last workload block before drain.
- `acc_out` is canonical at block boundaries.  `shift_in` and architectural
  observation are supported at those boundaries, not in a partial block.
- `shift_in` has priority over MAC, loads the canonical west value, clears the
  local block quotient, and resets the shared PE phase for the next block.

## RTL validation

Run with the repository's pinned EDA modules loaded:

```sh
make sim TOP=Top \
  TB=designs/payn/variants/signed_segmented_block_retired/tb/test_inner_tile_signed_segmented_block_retired.sv \
  USE_DW=1
```

The independent reference adds the actual signed
`countones(a_bits & w_bits)` contribution; it does not reuse the biased
identity from the DUT.  The regression covers:

- `T={32,64,128}`, including the multi-quotient `T=32` case;
- all-positive, all-negative, zero-hit negative, and mixed cancellation blocks;
- positive and negative modulo wrap;
- 4,000 random `T=128` bipolar blocks with new magnitudes each cycle;
- random idle gaps that must not advance phase;
- immediate drain after the final block without another load/finalize pulse;
- two consecutive shifts through a three-tile serial accumulator chain.

The regression passes with VCS 2020.12-SP2-1 and the DesignWare simulation
library.  The complete array wrapper also compiles and elaborates successfully.

## Synthesis screening result

The full K8/M16/8x8/T128 array closes the 2.5 ns clock:

| design | synthesized area (um2) | setup WNS (ns) | matched power (mW) |
|---|---:|---:|---:|
| accepted pending control | 49,034.20 | +1.44 | 8.0398 |
| block-retired | 47,855.75 | +0.68 | 8.3091 |

Block retirement reduces synthesized area 2.40%, but raises matched
workload-driven synthesis power 3.35%.  The dense biased negative operand
`M-c_i` switches more heavily than the signed pending-bit representation; its
cost exceeds the savings from the narrower hot heap and infrequent high-bank
update.  The design was therefore rejected at the pre-APR power gate and was
not routed.
