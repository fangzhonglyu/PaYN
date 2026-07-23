# PaYN W-bus data-bit inversion experiments

This note defines two W-only temporal data-bit-inversion (DBI) architecture
points for the K8·M16·8×8 PaYN array.  Both are bit-exact with the baseline and
leave PaYN's deliberately separate numeric sign path unchanged.  Direct bit
decode has also completed routed-SDF, SAIF, and PrimeTime PX analysis.  It
substantially reduces W-transport switching, but increases whole-chip power;
count correction remains RTL- and synthesis-qualified only.

The designs live below `designs/payn/variants/wdbi/` rather than behind an
architecture switch in `inner_pe.sv`.  Each has its own top, synthesis target,
and APR target.  The baseline therefore remains the reference implementation
and each generated netlist identifies its architecture unambiguously.

## Encoding

For each M-bit W stochastic word `W[t]`, the encoder compares the two legal
representations against the word currently held by the transport register:

```text
d_keep   = popcount(W[t]  XOR encoded[t-1])
d_invert = popcount(~W[t] XOR encoded[t-1]) = M - d_keep
```

It sends the lower-distance representation plus one `keep` bit.  `keep=1`
means the encoded word is raw W; `keep=0` means it is the complement.  A tie
retains the previous `keep` value so the sideband does not toggle needlessly.
The first post-reset word is sent normally.  Only the valid and keep state is
reset; the M-wide encoded bank remains an unconditional, resetless data pipe,
matching the baseline and avoiding a reset-controlled clock enable over all W
data flops.

The encoder acts on stochastic data bits, not on the separately transported
bipolar sign.  DBI therefore changes representation and switching activity,
but never changes the numeric sign convention.

Trace screening on the validated T=128 workload motivated W-only DBI.  With
M=16 words, ideal encoded-data transitions plus keep transitions fell from
42,227 to 28,405 for W (−32.7%) and from 42,769 to 28,218 for A (−34.0%).  W was
chosen first because its routed transport roots were the more expensive side
and W-only avoids paying two encoder/sideband networks at once.  These counts
are an upper-bound screen, not a power result; receiver logic and sideband
routing must be included after APR.

## Receiver alternatives

### Bit decode

`payn_array_wdbi_bitdecode` restores each W bit immediately before partial
product generation:

```text
W       = encoded_W XNOR keep
product = A AND W
```

This is the direct interpretation of adding an XNOR before the partial-product
AND.  Its advantage is local, regular logic with no additional wide arithmetic.

### Count correction

`payn_array_wdbi_countcorrect` avoids bitwise decode.  If W was inverted,

```text
popcount(A & W)
  = popcount(A & ~encoded_W)
  = popcount(A) - popcount(A & encoded_W)
```

`popcount(A)` is computed once per row and depth and shared by all columns.
The correction is **not** generally `M - popcount(A & encoded_W)`: the A mask
means only positions where A is one can contribute.  The full-width formula is
the special case `A = all_ones`.

## Synthesis comparison

All three points use TSMC22 SVT C30, 2.5 ns, K=8, M=16, and an 8×8 array.

| design | synthesis target | area (µm²) | vs baseline | setup slack (ns) |
|---|---|---:|---:|---:|
| baseline | `PAYN_SC_SWEEP` | 47,848.7 | — | +0.86 |
| W-DBI bit decode | `PAYN_SC_WDBI_BITDECODE` | 54,870.6 | +14.7% | +0.77 |
| W-DBI count correction | `PAYN_SC_WDBI_COUNTCORRECT` | 56,336.8 | +17.7% | +0.76 |

Both variants pass timing.  Their only synthesis nets above 1,000 fanout are
real clocks; the DBI data/reset logic does not create a high-fanout clock-enable
net.  Count correction is 2.7% larger than direct decode, so direct decode is
the preferred candidate for the first routed experiment.  DC's statistical
power report is not used here: DBI's purpose is workload-dependent routed-wire
switching, which requires routed-SDF simulation, validated SAIF, and PrimeTime
PX.

The physical pass/fail criterion is whether the W-root switching reduction
outweighs encoder, keep-sideband, decode, clock, and routing overhead.  The
accepted row/column distribution guides should be enabled for that comparison,
and the decision must use the same final setup/hold, drain-cosim, SAIF, total
wire, total capacitance, and PT-PX checks as the existing wire experiments.

## Routed direct-decode result

The direct-decode point was routed from the accepted row/column-guided
placement.  Its routed SDF simulation passes the bit-exact drain checker and
its T=128 SAIF passes the SC activity validator.  The comparison below uses the
same 2.5 ns SVT C30 corner and workload as the accepted guided baseline.

| metric | guided baseline | W-DBI bit decode | change |
|---|---:|---:|---:|
| logical area (µm²) | 51,022.8 | 57,924.0 | +13.5% |
| setup WNS (ns) | +0.279 | +0.140 | passes |
| hold WNS (ns) | +0.029 | +0.029 | passes |
| routed wire (µm) | 1,113,115 | 1,255,978 | +12.8% |
| all-net capacitance (pF) | 278.383 | 315.772 | +13.4% |
| W-root capacitance (pF) | 31.479 | 3.079 | **−90.2%** |
| W-root average fanout | 8.00 | 2.04 | **−74.5%** |
| W-root switching (mW) | 1.400 | 0.087 | **−93.8%** |
| total net switching (mW) | 10.036 | 12.133 | +20.9% |
| cell internal power (mW) | 8.998 | 10.961 | +21.8% |
| total power (mW) | 19.177 | 23.251 | **+21.2%** |
| energy (pJ/MAC) | 0.749 | 0.908 | +21.2% |

The intended saving is real: the encoded W roots save 1.313 mW of switching.
The encoder, keep network, local XNOR decode, extra clocked state, and placement
pressure add 15,168 reported nets, 37.39 pF of total capacitance, 3.41 mW of
non-W net switching, and 1.96 mW of internal power.  The direct-decode design
is therefore rejected as a whole-chip power optimization for this random
operand workload.  Since count correction is already 2.7% larger at synthesis,
it is not the next routed candidate unless a workload shows much stronger W
temporal correlation.

The W-DBI result is an **analysis APR checkpoint**: physical-only filler
insertion was skipped after routing.  It is DRC-clean, antenna-clean (17 local
`ANTENNA2_A7PP140ZTS_C30` diodes), connectivity-clean, and fully extracted,
but it is not a filler-complete tapeout database.  This qualification favors
DBI by avoiding filler-driven rerouting, so the measured +21.2% power result is
still sufficient for the architecture decision.

## APR-flow observation

The legacy finalization inserted post-route `FILLSGCAP*` cells, exposed more
than 270k M1 conflicts, and then unconditionally ran
`editDeleteViolations/globalDetailRoute`.  That control rerouted 99.56% of the
area, took 2:41:32, and finished with setup WNS −0.119 ns, one geometry marker,
and 12 antenna markers.  Resuming the clean routed checkpoint, skipping the
already-clean +29 ps final hold guard-band pass and physical filler, inserting
17 local antenna diodes, and conditionally avoiding the global fallback took
11:22 and finished at 0 geometry/0 antenna violations with +0.140/+0.029 ns
setup/hold WNS.

Ordinary `FILL*` spacers are preferable to `FILLSGCAP*` for post-route gap
fill, but Innovus still forced 49,011 spacers into M1-occupied sites in this
database.  Filler-complete closure should therefore be treated as a separate
signoff task: reserve filler-compatible M1 sites during routing or insert the
required physical cells before final signal routing, rather than globally
rebuilding a clean analysis route.

## Reproduce

Load the repository's pinned tool versions before invoking a flow:

```sh
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
```

The dedicated synthesis targets run their own small bit-exact RTL preflight:

```sh
RUN_NAME=k8m16n8_wdbi \
SYN_DEFINES='PAYN_K=8 PAYN_M=16 PAYN_NH=8 PAYN_NW=8' \
make synth TARGET=TSMC22/PAYN_SC_WDBI_BITDECODE

RUN_NAME=k8m16n8_wdbi \
SYN_DEFINES='PAYN_K=8 PAYN_M=16 PAYN_NH=8 PAYN_NW=8' \
make synth TARGET=TSMC22/PAYN_SC_WDBI_COUNTCORRECT
```

Direct decode can be rerun with the accepted distribution guides.  The three
trim flags below deliberately produce an analysis checkpoint; omit
`SKIP_FILLER` for filler-complete signoff work.

```sh
SC_DISTRIBUTION_GUIDES=1 SC_NH=8 SC_NW=8 \
DISABLE_POSTROUTE_SWAPVIA=1 CONDITIONAL_FINAL_DRC=1 \
SKIP_FINAL_HOLD_OPT=1 SKIP_FILLER=1 \
RUN_NAME=k8m16n8_distguide_analysis \
make apr TARGET=TSMC22/PAYN_SC_WDBI_BITDECODE \
    SYNTH_RUN=k8m16n8_wdbi
```
