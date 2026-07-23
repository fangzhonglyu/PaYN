# Centered-residue direct segmented accumulator

This variant combines direct carry/borrow retirement with a centered low-digit
representation:

```text
value = encoded_word - 2**(LOW_W-1)  (mod 2**OWIDTH)
```

Reset initializes the encoded word to the fixed bias. Internal row shifting
keeps values encoded, while the PE converts canonical values only at the west
and east row boundaries. The representation is exact for arbitrary run length
and does not require a block counter or end-of-block correction.

Centering moves numerical zero away from a radix boundary, reducing upper-bank
updates for bipolar accumulations that remain near zero.

At K8/M16/8x8/OW24, LOW_W=8 measures 7.3656 mW in synthesis workload PT-PX,
0.08% above the direct-residue variant. The row-boundary recenter logic cancels
the upper-bank activity benefit for this implementation, so it was not promoted
to APR.
