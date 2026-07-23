# Recurrent carry-save low accumulator

This experimental K=8 variant keeps only the low radix digit in redundant
carry-save form.  It is exact for arbitrary accumulation length and does not
have a fixed block, a periodic correction, or a normalization clock.

For `R = 2**LOW_W`, the registered state represents

```
X = (acc_high + high_debt)*R + acc_sum + acc_carry
                                                (mod 2**OWIDTH)
```

where `acc_sum` and `acc_carry` are unsigned `LOW_W`-bit rows.  They are not
required to be a canonical digit; their sum may be as large as `2*R-2`.

## Exact recurrent update

For signed lane contribution `x_i`, the heap receives

```
lane_residue_i = x_i mod R
lane_q_i       = -1 when x_i < 0, +1 when x_i = +R, otherwise 0
x_i            = lane_residue_i + lane_q_i*R
```

The two old state rows and eight lane residues enter an exact, width-growing
3:2 tree.  If its two final rows are `row0` and `row1`, then

```
U = acc_sum + acc_carry + sum(lane_residue_i)
  = row0 + row1
  = row0.low + row1.low
    + (row0.upper + row1.upper)*R
```

The next state is consequently

```
acc_sum'   = row0.low
acc_carry' = row1.low
q           = row0.upper + row1.upper + sum(lane_q_i)
high_debt'  = high_debt + q                    (mod 16)
acc_high'   = acc_high + 16*wrap(high_debt + q)
```

`high_debt` is a four-bit signed digit.  If `high_debt+q` leaves `[-8,7]`,
the wrapped digit and a `+16` or `-16` update to `acc_high` preserve their
sum exactly.  For K=8 the one-cycle correction is in `[-8,9]`, so at most one
such wrap occurs.  Substitution proves the invariant is preserved every cycle.
No assumption about accumulation duration appears in the recurrence.

The tree grows by one bit at each 3:2 stage.  This is important.  A
fixed-width `DW02_tree` guarantees its two-row result only modulo its output
width; converting its upper row fragments into an exact radix correction would
also require detecting a carry from adding the two complete output rows.  That
would silently put the carry-propagate path back into the recurrent MAC.

## Canonical output and shift contract

Canonicalization resolves `acc_sum + acc_carry`, adds signed `high_debt`, and
folds the low-row carry into `acc_high`.  It is operand-isolated while
`mac_en=1`:

```
acc_out_valid = shift_in || !mac_en
```

`acc_out` is the exact canonical accumulator when `acc_out_valid=1` and zero
otherwise.  Deasserting `mac_en` makes the result valid combinationally; it does
not require an edge or change the registered state.

During row-serial drain, `mac_en=0` and `shift_in=1`.  Every tile therefore
drives its canonical old state east while loading canonical `acc_in` into
`acc_sum` and clearing `acc_carry` on the same edge.  Back-to-back shift cycles
need no normalize bubble.

## Cost and screening recommendation

Relative to the current pending-bit `LOW_W=9` design, each tile adds one
nine-bit carry-save row and four debt bits while removing the two pending event
bits: a net eleven additional state bits.  It replaces the final recurrent low
CPA with:

- a five-level exact 3:2 tree for the ten K=8 operands;
- a small signed upper-row correction and four-bit debt update;
- a LOW_W-bit canonical CPA that switches only at observation/drain.

The two redundant row banks toggle every MAC and are the main power/area risk.
In the random bipolar tile stress at `LOW_W=9`, the raw high correction was
nonzero on 1,278/8,192 cycles (15.6%), but the debt digit absorbed every one:
the wide high bank retired zero times in that window.  This variant is therefore
worth a synthesis and workload-SAIF screen, but should not enter APR unless it
beats the existing segmented design clearly at synthesis.  The implementation
deliberately asserts `K==8`; another K needs a separately balanced exact
reduction schedule.

Tile validation:

```sh
make sim TOP=Top \
  TB=designs/payn/tb/test_inner_tile_signed_segmented_csa.sv
```

The test covers `LOW_W={7,8,9,11}`, long uninterrupted positive and negative
bursts, random bipolar MACs, observation without a flush clock, accumulator
wraparound, and back-to-back canonical shifting.

## Measured disposition

The synthesis and validated workload-SAIF screen rejects this variant before
APR:

| LOW_W | synth area (um2) | slack (ns) | power (mW) | pJ/MAC |
|---:|---:|---:|---:|---:|
| 8 | 53,657.06 | +0.59 | 8.0862 | 0.31587 |
| 9 | 54,303.47 | +0.65 | 8.2882 | 0.32376 |

LOW_W=8 is 9.4% larger and 8.5% higher power than the accepted pending-bit
LOW_W=9 synthesis point.  Avoiding the recurrent CPA does not repay the extra
redundant register row and the activity of two low-state rows.
