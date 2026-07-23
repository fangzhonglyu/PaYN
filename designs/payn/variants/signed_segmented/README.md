# Signed segmented accumulator

This design point keeps the exact full-width output-stationary accumulator but
confines the per-cycle signed reduction to a low residue bank.

For radix `R = 2**LOW_W`, one MAC computes the true signed contribution `d` and
forms `s = acc_low + d`.  The low bank takes `s mod R`; a carry or borrow event
records whether the upper bank must change by `+1` or `-1`.  That two-state
event is pipelined for one cycle so the low heap and upper increment/decrement
path are independent.

The visible accumulator includes the pending event:

```
acc_out = {(acc_high + pending_carry - pending_borrow), acc_low}
```

It is therefore canonical after every MAC and during row-serial drain, even
though the physical high register retires the event one cycle later.

Unlike the blockwise-biased design, this variant has no bias, block correction,
fixed block length, or stable-sign requirement.  `2**LOW_W` must be at least
`K*M`, ensuring a cycle produces at most one carry or borrow.
