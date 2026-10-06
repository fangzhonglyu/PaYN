# PaYN SC wire-capacitance experiments

This note evaluates physical-design levers on the best tile-sweep point,
K8·M16·8×8 at 2.5 ns.  The accepted change is a soft distribution-aware
placement recipe: A pipeline registers use eight horizontal row bands and W
pipeline registers use eight vertical column bands.  It deliberately does not
constrain the 64 compute tiles.

The follow-up buffering experiment adds one explicit local branch per A/W bit.
For N=8, each source Q net drives four tile consumers plus the branch buffer
(extracted fanout five); the branch drives the remaining four consumers.  All
2,048 branch buffers are protected in both synthesis and APR.

All power results use the same T=128 workload.  A result is accepted only when
final setup and hold close, routed-SDF drain cosim passes bit-for-bit, the SAIF
passes `sweeps/validate_sc_power_saif.py`, and PrimeTime PX completes.

## Workload-aware reroute of the accepted pending-bit design

The current pending-bit `LOW_W=9` design was rerouted with the same row/column
distribution guides plus an opt-in ASTRAEA workload-power recipe.  Innovus
reads and propagates the validated long-running T=128 routed SAIF before
placement, sets `leakageToDynamicRatio=0`, retains high power effort, and uses
high-effort detailed wirelength optimization.

| metric | prior accepted route | workload-aware route | change |
|---|---:|---:|---:|
| final setup / hold WNS (ns) | +0.558 / +0.019 | **+0.627 / +0.029** | both improve |
| cell area (µm²) | 52,184.608 | **51,871.400** | −0.60% |
| routed wire (µm) | **1,121,179** | 1,129,843 | +0.77% |
| total net capacitance (pF) | 272.4983 | **269.8125** | −0.99% |
| A / W root capacitance (pF) | 26.6488 / 28.6527 | **26.6209 / 28.3546** | −0.11% / −1.04% |
| net switching power (mW) | 9.804828 | 9.804754 | effectively tied |
| cell internal power (mW) | 8.733778 | **8.572295** | −1.85% |
| leakage (mW) | **0.140370** | 0.154123 | +9.80% |
| total power (mW) | 18.678980 | **18.531170** | −0.79% |
| energy (pJ/MAC) | 0.729648 | **0.723874** | −0.79% |

The new route is accepted: APR is clean for geometry, connectivity, antenna,
setup, and hold; its max-SDF 256-block drain is bit-exact; the SAIF is valid;
and PT-PX annotates 99.26% of nets and 100% of cells.

This is not a pure geometric-wire win.  Total wire grows slightly while total
capacitance falls, and PT-PX net switching is unchanged.  The main benefit is
workload-aware cell remapping and downsizing: many generic X1 combinational
cells become X0P5/X0P7 variants, reducing area and internal power.  The tradeoff
is higher leakage.

The documented Innovus 21.14
`place_global/detail_activity_power_driven` modes are deliberately not part of
the accepted recipe.  This release emits `IMPSP-9532` and skips placement
activity weights even after the SAIF is fully propagated or converted to TCF.
ASTRAEA therefore exposes only the verified path used here.

## Results

| metric | baseline | tile guides | tile + global fanout 4 | row/column guides | row/column + two-level A/W |
|---|---:|---:|---:|---:|---:|
| final setup WNS (ns) | +0.127 | **−0.097** | +0.064 | +0.279 | +0.246 |
| final hold WNS (ns) | +0.040 | +0.009 | **−0.020** | +0.029 | +0.026 |
| cell area (µm²) | 51,053 | 50,913 | 57,889 | 51,023 | 51,731 |
| routed wire (µm) | 1,196,244 | 1,465,499 | 1,512,369 | **1,113,115** | **1,112,685** |
| total net capacitance (pF) | 293.12 | 340.18 | 360.04 | **278.38** | 279.16 |
| A root capacitance (pF) | 17.77 | 39.82 | 6.99 | 28.07 | 20.19 |
| W root capacitance (pF) | 32.48 | 53.32 | 12.10 | 31.48 | **17.93** |
| root maximum fanout | 8 | 8 | 4 | 8 | **5** |
| total power (mW) | 19.840 | 23.313 | 25.875* | **19.177** | 19.188 |
| energy (pJ/MAC) | 0.775 | 0.911 | 1.011* | **0.749** | 0.750 |
| routed-SDF drain cosim | PASS | PASS | **FAIL** | PASS | PASS |
| power SAIF | valid | valid | **invalid** | valid | valid |
| geometry / antenna markers | 0 / 9 | — | — | 0 / 9 | 0 / 7 |
| disposition | reference | reject | reject | **accept** | no power win |

\* The global-fanout-four power is diagnostic only.  Routed drain cosim and
SAIF validation fail, so it is not a signoff power result.

The final WNS values come from `reports/setup.rpt` and `reports/hold.rpt`, not
the optimistic `postRoute.summary.gz` checkpoint.  The two accepted/diagnostic
distribution runs have zero geometry DRC; the antenna counts are residual
process-antenna markers, comparable to the baseline's nine.

## Interpretation

### Distribution-aware placement works

The row/column guides reduce wire 6.95%, total net capacitance 5.03%, and
validated power 3.34% relative to baseline.  They also improve setup WNS from
+0.127 ns to +0.279 ns without a hold failure.  This is the best whole-chip
result and should be the default physical recipe.

The improvement is global rather than uniform at each source.  W root
capacitance falls 3%, while A root capacitance rises 58%.  Total capacitance and
PrimeTime power still improve, demonstrating why root-net capacitance alone is
not a sufficient objective.

### The local tree moves power; it does not remove it

The protected two-level tree is physically and functionally sound.  Relative to
row/column guides alone, it reduces combined A/W root capacitance and switching
power by about 36%, and root fanout falls from eight to five.  W benefits most:
its root capacitance falls 43% versus guides and 45% versus baseline.

Those gains reappear in the branch nets and buffer cells.  Relative to guides
alone, the tree changes:

- routed wire by −0.04% (effectively tied);
- total net capacitance by +0.28%;
- total power by +0.06% (19.188 versus 19.177 mW); and
- cell area by +1.39%.

The tiny power difference is below the small activity-count difference between
the two routed simulations, so the correct conclusion is no measurable
whole-chip power benefit.  The tree is useful only if root slew, electrical
reliability, or local load is itself the objective.

### Rejected recipes

The 8×8 tile-guide grid separates whole compute tiles without co-locating the A
and W source registers with their row/column sinks.  It raises wire 22.5%, net
capacitance 16.1%, and validated power 17.5%, and final setup fails.

Global `MAX_FANOUT=4` reduces the measured root loads but inserts a large tree
throughout the design.  Area rises 13.4%, wire 26.4%, and total capacitance
22.8%; final hold fails and routed cosim/SAIF are invalid.  It shifts
capacitance into branches rather than eliminating it.

## Recommendation

- Enable row/column distribution guides without tile guides.
- Enable ASTRAEA workload-aware power optimization with a validated,
  representative SAIF for final candidates.
- Do not enable global `MAX_FANOUT=4` or an explicit A/W distribution tree for
  power optimization.  The later W-only follow-up also regressed matched
  routed energy, by 3.04%.
- Continue gating every candidate on final setup/hold, routed cosim, SAIF
  validation, PrimeTime PX, total wire, and total capacitance.

## Reproduce

```sh
bash sweeps/run_sc_wire_opts.sh
```

The driver loads the pinned EDA versions, reuses completed runs, and writes
`build/power_char/wire_opts/sc_wire_opts.csv`.  Net-load characterization is in
`sweeps/pt_sc_net_loads.tcl`.  The accepted placement recipe is enabled opt-in
through `SC_DISTRIBUTION_GUIDES=1`.

The accepted workload-aware reroute additionally uses:

```sh
APR_WORKLOAD_POWER_OPT=1 \
APR_ACTIVITY_FILE=/abs/path/to/validated/dut.saif \
APR_ACTIVITY_SCOPE=Top/dut \
APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 \
APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
make apr TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED
```

The rejected two-level-tree measurements are retained above as historical
results, but its technology-specific RTL was retired instead of leaving an
architecture `ifdef` in the baseline.  The runner now reproduces the baseline,
tile-guide, global-fanout, and accepted row/column-guide points.
