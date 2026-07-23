# Compensated signed segmented accumulator

This exact design point preserves the pending carry/borrow high segment from
`signed_segmented`, but removes the sign-extended signed lane operands from its
low heap.

For lane hit count `c_i` and negative flag `n_i`:

```
b_i = n_i ? M-c_i : c_i
signed_delta = sum(b_i) - M*countones(n)
```

The heap therefore contains `K` short non-negative counts, one shared signed
correction, and the unsigned low residue.  With `M=16`, the shared correction
is a popcount of the loaded lane signs followed by a four-bit shift.  It is
stable during a normal stochastic MAC block.

The correction is applied on every enabled MAC.  There is no accumulated bias,
block length, sign-stability requirement, or `block_finalize` interface.
`acc_out` is canonical after every MAC and arbitrary-duration output-stationary
accumulation remains exact modulo `2**OWIDTH`.

As in the original signed segmented design, `2**LOW_W >= K*M` ensures that one
cycle can produce at most one carry or borrow.  `LOW_W=7` is therefore valid at
`K=8, M=16`, although physical results determine whether 8 or 9 is preferable.

## Measured disposition

At K8/M16/8x8/T128, the validated post-synthesis workload result favored
`LOW_W=8`: 48,904 um2, +1.44 ns slack, and 7.2886 mW.  That is 2.2% below the
pending-bit LOW_W=9 synthesis result.

The matched distribution-guide APR result reversed the apparent gain:

- 52,332.98 um2, +0.321/+0.038 ns setup/hold WNS;
- 1,302,466 um final routed wire, 16.2% above the accepted pending-bit route;
- 19.36658 mW and 0.75651 pJ/MAC, 11.0% above the accepted pending-bit route;
- 2 geometry DRC and 72 process-antenna violations after the configured repair
  sequence.

The routed increase is dominated by net switching power (10.78818 versus
9.14355 mW).  This variant is therefore retained as an exact experiment but is
rejected as a physical power optimization.
