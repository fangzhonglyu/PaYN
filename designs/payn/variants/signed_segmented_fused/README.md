# Fused compensated signed segmented accumulator

`InnerTileSignedSegmentedFused` removes the eight product-dependent binary
popcount boundaries of the regular signed-segmented tile.  Each of its `K*M`
compensated one-bit products enters one `DW02_tree` together with:

- the unsigned `LOW_W` residue; and
- one signed correction, `-M * popcount(a_signs ^ w_signs)`.

The compensation identity is exact:

```text
popcount(products XOR negative) - M*negative
    = negative ? -popcount(products) : popcount(products)
```

The small `K`-bit correction count is product-independent and normally remains
static throughout an output-stationary block.  Pending carry/borrow handling,
canonical output, shift behavior, and arbitrary-duration accumulation are
otherwise identical to the accepted signed-segmented implementation.

The synthesis risk is the very high formal input count (`K*M+2`, 130 for
K=8/M=16).  DesignWare may flatten it into a favorable single bit heap, but it
may instead produce a larger or more globally wired compressor than the
lane-local hierarchy.

## Measured disposition

Both LOW_W=8 and LOW_W=9 pass the K8/M16/8x8/T128 post-synthesis workload
cosim and SAIF checks.  LOW_W=9 measures 47,688.56 um2, +1.43 ns slack, and
7.4190 mW.  It saves 2.7% synthesis area but only 0.46% power relative to the
accepted pending-bit LOW_W=9 design.  That margin is too small to justify an
APR run given the 130-input physical-wiring risk, so the fused heap is retained
as a synthesis-screened experiment.
