# Direct-retire signed segmented accumulator

This variant keeps the exact two-segment representation from
`signed_segmented`, but applies each low-digit carry or borrow to the high
digit on the same clock edge. It removes the two per-tile pending-event flops
and the combinational visible-high correction.

For `2**LOW_W >= K*M`, one stochastic MAC cycle can cross at most one radix
boundary, so the direct update is exact for arbitrary run length. The external
accumulator representation and row-shift protocol remain canonical.

At K8/M16/8x8/OW24, LOW_W=8 is the best tested synthesis point
(7.3600 mW workload PT-PX). Its antenna-clean distribution-guide route is
17.54384 mW, slightly above the earlier pending-bit LOW_W=9 route
(17.44477 mW), so this variant is retained as a clean design point rather than
the current power winner.
