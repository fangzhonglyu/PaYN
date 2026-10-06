# GF22 combinational inner-tile soft-error study

This study extracts the arithmetic cone of one PaYN `InnerTile`, implements a
matched combinational binary INT8 MAC, places and routes both in GF22, and runs
the layout-aware proton flow in the sibling `../ROC_flow` repository.

## Comparison boundary

`InnerTileComb` is factored directly out of the stateful `InnerTile`; the
production tile now instantiates that shared cone.  For `K=6`, `M=16`, and
`OWIDTH=24`, one evaluation computes

```
acc_out = acc_in + sum_i sign_i * popcount(a_bits[i] & w_bits[i])
sign_i  = (a_signs[i] ^ w_signs[i]) ? -1 : +1
```

The fixed physical-analysis top is `payn_inner_tile_comb`.  Its `clk` and
`reset` ports exist only for ASTRAEA/ROC_flow compatibility and do not feed the
data cone.  The binary reference, `binary_int8_mac_comb`, computes signed
`y = a * b + c` for two INT8 operands and a 32-bit accumulator.  Its
compatibility ports are likewise unused.  Final APR reports confirm that both
designs contain zero flops, latches, or clock gates.

The relevant sources are:

- `designs/payn/inner_tile_comb.sv`: reusable cone and flat K6/M16/OW24 top.
- `designs/payn/inner_tile.sv`: stateful production tile using the same cone.
- `designs/baselines/soft_error/binary_int8_mac_comb.sv`: binary reference.
- `syn/targets/GF22FDX/` and `apr/targets/GF22FDX/`: matched physical targets.
- `roc_flow/configs/`: PaYN and binary 1-million-trial campaign definitions.
- `sweeps/run_roc_{inner_tile,binary_mac}.sh`: artifact export and ROC drivers.

## Physical methodology

Both designs use GF22 TT, 0.80 V, 25 C, a 1 ns input-to-output constraint, and
60% target core utilization.  The headline ROC campaigns use the polar proton
spectrum, omnidirectional incidence, layout charge collection, and a uniformly
sampled strike time over the 1 ns evaluation window.  Omnidirectional incidence
is ROC_flow's cosine-weighted isotropic distribution for particles crossing a
flat surface; particle energy is interpolated across its angle-specific CDFs.
Each campaign contains 10,000,000 particles.

Synthesis is restricted to the intersection of the GF22 cells allowed by
ROC_flow and the cells present in its current sensitive-region database.  This
is important: an older ROC binary netlist contains an `AOAI211` cell that has no
current sensitive-region entry.  `syn/scripts/GF22_limit_cell_roc.tcl` removes
that cell and the other uncovered cells from both new mappings.  The ROC
preprocessor consequently reports zero gates skipped for missing cell CSV or
sensitive-region data in both campaigns.

The final routed implementations are:

| Metric | PaYN inner tile | Binary INT8 MAC | PaYN / binary |
|---|---:|---:|---:|
| APR combinational cells | 389 | 224 | 1.74x |
| APR cell area (um^2) | 201.576 | 100.224 | 2.01x |
| Core footprint (um^2) | 337.319 | 167.931 | 2.01x |
| Setup WNS at 1 ns (ns) | +0.053 | +0.028 | -- |
| Hold WNS (ns) | +0.053 | +0.052 | -- |
| Vectorless routed power (mW) | 0.2634 | 0.1228 | 2.15x |
| Vectorless energy/evaluation (pJ) | 0.2634 | 0.1228 | 2.15x |

Geometry, connectivity, antenna, setup, and hold signoff checks pass for both
runs.  The power figures are Innovus propagated-activity estimates with primary
input activity 0.2; no SAIF was supplied.  They are useful for a matched first
comparison, but are not workload-annotated power results.

## Omnidirectional 10M soft-error result

| ROC result, 10M particles | PaYN inner tile | Binary INT8 MAC |
|---|---:|---:|
| Runtime-injected trials | 1,521 | 1,623 |
| Logic-masked | 26 | 99 |
| Timing-masked | 1,302 | 1,342 |
| Observable errors | 193 | 182 |
| Error / injected | 12.69% | 11.21% |
| Error / incident particle | 1.930e-5 | 1.820e-5 |
| 95% Wilson interval for raw rate | [1.676e-5, 2.222e-5] | [1.574e-5, 2.104e-5] |
| Effective error cross-section (um^2) | 0.006510 | 0.003056 |

Because a trial samples a particle uniformly over each design's full core
footprint, the physical metric is the effective error cross-section

```
sigma_error = core_area * observable_errors / incident_particles.
```

PaYN therefore has **2.130x** the binary error cross-section per evaluation.
An independent-Poisson approximation gives a 95% interval of
**[1.74x, 2.61x]** for that ratio.

PaYN performs `K*M/T = 96/T` equivalent MACs per tile evaluation, whereas the
binary reference performs one.  At the repository's `T=128` operating point,

```
cross-section ratio per equivalent MAC
    = 2.1301 * (128 / 96)
    = 2.840x                 (approx. 95% interval [2.32x, 3.48x])
```

Using the vectorless power estimate at 1 GHz gives 0.351 pJ/equivalent-MAC for
PaYN at T=128 versus 0.123 pJ/MAC for binary, or 2.86x.  This energy ratio is
only provisional until both designs have workload-derived activity.

### Directional theta-80 reference

The earlier 1M-particle theta-80 campaigns remain available as a directional
reference.  Both happened to produce 134 observable errors, or `1.340e-4` per
incident particle.  Their cross-sections were 0.04520 um^2 for PaYN and
0.02250 um^2 for binary: a 2.009x per-evaluation ratio and 2.678x per equivalent
MAC at T=128.  The omnidirectional 10M campaign above is the primary result.

## Reproduction

Load the project-required tool versions before synthesis and APR:

```sh
module load synopsys-lib-compiler/2022.03-SP3 \
            synopsys-synth/2021.06-SP1 \
            primetime/2021.06-SP1 \
            vcs/2020.12-SP2-1 \
            innovus/21.14.000 \
            genus/21.14.000

RUN_NAME=roc_k6m16_20260722_cov \
make synth TARGET=GF22FDX/PAYN_INNER_TILE_COMB
SYNTH_RUN=roc_k6m16_20260722_cov RUN_NAME=roc_k6m16_20260722_cov \
make apr TARGET=GF22FDX/PAYN_INNER_TILE_COMB

RUN_NAME=roc_binary_20260722_cov \
make synth TARGET=GF22FDX/BINARY_INT8_MAC_COMB_ROC
SYNTH_RUN=roc_binary_20260722_cov RUN_NAME=roc_binary_20260722_cov \
make apr TARGET=GF22FDX/BINARY_INT8_MAC_COMB_ROC

ROC_ANGLE=omni ROC_TRIALS=10000000 APR_RUN=roc_k6m16_20260722_cov \
bash sweeps/run_roc_inner_tile.sh all
ROC_ANGLE=omni ROC_TRIALS=10000000 APR_RUN=roc_binary_20260722_cov \
bash sweeps/run_roc_binary_mac.sh all
```

The drivers copy the routed Verilog, SDF, LEF, and SPEF into the ignored local
`build/roc_flow/` tree, then invoke `../ROC_flow` without modifying it.

Functional verification uses 1,000 randomized vectors at RTL and again on each
routed, SDF-annotated netlist.  The existing stateful `InnerTile`/`InnerPE`
regression also passes after factoring out the cone.

## Interpretation limits

The current PaYN campaign uses independent uniform bit patterns for stochastic
bits, signs, and `acc_in`; the binary campaign uses ROC_flow's signed
`int8_mac_uniform` operands and a 32-term partial-sum distribution.  Thus the
physical implementation, radiation spectrum, timing, and trial count are
matched, but the architectural operand distributions are not yet derived from
the same inference workload.  Logical masking is data-dependent, so this result
should be treated as the controlled physical baseline.  A publication-quality
workload result should add a PaYN-specific ROC sampler fed by matched quantized
operands and report the ratio for each chosen stream length `T`.
