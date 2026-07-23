# Blockwise-biased segmented accumulator

This design point keeps the full `OWIDTH` output-stationary accumulator.  It
does not assume that one `BLOCK_T` stochastic block is the accumulator's whole
lifetime.

For lane product count `c_i` and bipolar sign `n_i`, the MAC cycles accumulate
the exact non-negative bias `n_i ? M-c_i : c_i`.  After exactly `BLOCK_T` MAC
cycles, `block_finalize` subtracts `BLOCK_T*M*countones(n)` and restores the
canonical signed accumulator before the next K block or drain.

The current design requires `BLOCK_T*M` to be a power of two.  At M16/T128 the
accumulator is split at bit 11.  The low 11 bits update every MAC cycle; the
upper 13 bits update only on a low-segment carry and once at block finalize.
All arithmetic is modulo `2**OWIDTH`, matching the baseline accumulator's
overflow behavior.

Control contract:

1. Hold one block's signs stable for its `BLOCK_T` MAC cycles.
2. After the final MAC capture, deassert `mac_en` and assert
   `block_finalize` so it is stable at the following active clock edge.
3. Hold `block_finalize` for that clock before replacing the signs.
4. Begin the next block or drain the now-canonical accumulator.

`block_finalize`, `shift_in`, and `mac_en` are mutually exclusive.  A natural
implementation uses the existing inter-block sign/load pipeline bubble for the
finalize pulse.

The routed testbench changes these controls 300 ps after the source-clock edge.
This models clock-to-Q from a controller register on the same clock tree and
avoids racing the final MAC capture after CTS; 300 ps is a testbench timing
choice, not an architectural delay requirement.  A zero-delay transition at
the ideal source-clock edge is not a valid post-CTS control model.

## K8/M16/8x8/T128 result

The variant was checked over multiple consecutive blocks at RTL, through the
synthesized gate netlist, and with maximum-delay SDF from the routed netlist.
The routed simulation remained bit-exact against `sc_kernel.py`; the
architectural accumulator had zero unknown time in the power SAIF.

At 2.5 ns, compared with the accepted `k8m16n8_distguide` baseline:

| Metric | Baseline | Biased segmented | Change |
|---|---:|---:|---:|
| Synthesis cell area (um^2) | 47,391.5 | 46,846.4 | -1.15% |
| Routed cell area (um^2) | 51,022.8 | 50,254.1 | -1.51% |
| Routed wire length (um) | 1,113,115 | 1,208,294 | +8.55% |
| Setup slack (ns) | +0.279 | +0.324 | +0.045 |
| Hold slack (ns) | +0.029 | +0.028 | -0.001 |
| PrimeTime PX total power (mW) | 19.177 | 18.973 | -1.06% |
| Clock-network power (mW) | 4.006 | 2.690 | -32.85% |
| Register power (mW) | 3.692 | 4.156 | +12.59% |
| Combinational power (mW) | 11.480 | 12.127 | +5.63% |
| Net-switching power (mW) | 10.036 | 10.299 | +2.62% |

The high-bank clock suppression works, but the extra state/control and longer
routing consume most of its benefit.  This is therefore a useful research
variant, not a compelling replacement for the baseline at this point.

The reported variant checkpoint was finalized from the clean routed checkpoint
with filler insertion skipped to avoid repeating the long global filler-repair
tail.  Final DRC and antenna checks were clean and setup/hold both passed, but
the checkpoint is intended for comparative PPA analysis rather than as a
filler-complete tapeout deliverable.
