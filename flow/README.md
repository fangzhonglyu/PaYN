# PaYN flow

Everything that takes `designs/payn` from RTL to a results report: functional regression, synthesis, two-pass APR,
gate-level verification, routed power and the report.  The engine is ASTRAEA (`make synth | apr | sim | power_apr`,
in `../ASTRAEA`); this directory drives it, gates every artifact and keeps the evidence.

## Entry points

| file | what it does |
|---|---|
| `env.sh` | the tool environment: the exact EDA module versions, `ASTRAEA_FLOW`, `SYNOPSYS`, the APR / gate-level settings of the qualified routes, `SNPSLMD_QUEUE=true`, `PYTHONDONTWRITEBYTECODE=1`.  Every tool command of every entry point runs under it (`source flow/env.sh` for a shell). |
| `regress.py` | functional regression.  RTL suites against the bit-exact models (`--suite ...`, unchanged), and a gate-level mode (`--gl syn-unit,syn-sdf,apr`): the same bench on a netlist and on RTL with the same inputs, compared field by field and trace by trace (tables `cases/gl_*.txt`).  `--drain 1` runs the RTL suites on the drain-register build (`+define+PAYN_DRAIN=1`: cases, units, sc, abit, grid-abit plus `cases/grid_abit_dr.txt`; the bit-plane suites read the in-tile chain and do not run there). |
| `route.py` | the physical flow of one shape: synthesis, post-synthesis GL, bootstrap APR, bootstrap GL power simulation, final APR, qualification (with the targeted repair), basin gate, routed functional GL.  `--drain 1` builds the drain-register hardware (`PAYN_DRAIN=1`). |
| `measure.py` | routed gate-level power of a qualified route: SC (uniform L=128, per-row ladder, stream-length points) and INT (bit-plane, all bits in time, controls), each point gated end to end, plus the per-class power and area split.  `--drain 1` for a drain-register route (bit-plane points skipped). |
| `report.py` | `doc/payn_results.md` from the run directories: area, timing, SC and INT energy, throughput and GMAC/s/mm2 for one PE and grids, the comparison against BOS. |
| `bos.sh` | the BOS baseline (binary output-stationary INT8 / INT6 / INT4 arrays) from RTL to routed power with the same tools and gates. |
| `qualify.py` | every gate (routed APR, routed and post-synthesis GL timing, SAIFs, PT coverage, SDF clock gates, the basin); `python3 flow/qualify.py -h`. |
| `flowlib.py` | shared plumbing: the environment, command logging, resumable stages, netlist helpers. |
| `tcl/` | `pt_libraries.tcl` (the TSMC22 PrimeTime libraries every PT script sources), `pt_power_classes.tcl` (power and area by functional class), `pt_basin_skew.tcl` (operand skew for the basin gate), `repair_route.tcl` (the targeted residual-marker repair). |

## From RTL to the report

```sh
python3 flow/regress.py --shape k16m8                                 # 1. RTL regression (every suite)
python3 flow/route.py k16m8 payn_k16m8_20261006 --dry-run             # 2. the plan
python3 flow/route.py k16m8 payn_k16m8_20261006                       # 3. synthesis to a verified route
python3 flow/measure.py k16m8 payn_k16m8_20261006                     # 4. routed power, every point
python3 flow/report.py                                                # 5. doc/payn_results.md
```

The shape is `k16m8` (PAYN_M = 8, the default) or `k8m16` (PAYN_M = 16).  The second argument names the synthesis
run; the routes derive from it: `<synth>_distguide` (bootstrap) and `<synth>_final`.  A failed stage stops the run
with its log path; inspect it, fix the cause, rerun with `--retry-failed` (the failed output is moved aside, finished
stages are reused).  `--stages a,b` runs only those stages (their prerequisites must have passed), e.g. `syn-gl` while
the final APR runs; `--adopt` accepts a synthesis or bootstrap route that was launched outside the flow with the same
environment, after the stage's own checks.

### route.py stages

| stage | what | gate |
|---|---|---|
| `synth` | `make synth TARGET=TSMC22/PAYN` with the shape's `SYN_DEFINES` | netlist / SDC / SDF written, setup met, 1.25 ns input delays, port widths = the shape |
| `syn-gl` | `regress.py --gl syn-unit,syn-sdf`: SC goldens, INT bit-plane blocks, switching, negative controls on the netlist vs RTL; unit delay, then the ideal-clock synthesis SDF with timing checks | GL == RTL; checkers; `qualify.py routed-gl` + `syn-gl` |
| `boot-apr` | `make apr <synth>_distguide`: soft A-row / W-column guides, floating pins | guide line = the netlist's count; `routed-apr --stage bootstrap` (markers allowed: activity seed only) |
| `boot-sim` | uniform L=128 SC power GL of the bootstrap route (measure.py's gl / audit / saif steps); the audited SAIF becomes the route's `activity/dut.saif` | bit-exact drain, `sdf-clock`, `gl-audit`, `saif-sc` |
| `final-apr` | `make apr <synth>_final`: `apr/scripts/payn_pre_place.tcl` (the guides, every pin fixed on the tile grid, the post-fill search-and-repair hook), workload power optimization from the bootstrap SAIF | log checks: every pin fixed, hook and final placement check ran |
| `qualify` | `routed-apr --stage final`; if only residual geometry / antenna markers remain (< 1,000, no overlap), the targeted repair from the final checkpoint, in place, then again | `route/qualification.json` |
| `gate` | `qualify.py basin` | grid basin, pin proof (`route/basin/`) |
| `routed-func` | `regress.py --gl apr`: SC at reset settle 2 and 0, INT bit-plane and all-bits-in-time blocks, switching, negative controls on the routed netlist with its raw SDF | GL == RTL; `gl-audit` per log |

### measure.py points and steps

Points (`--points`, names or groups `sc`, `tsweep`, `bp`, `abit`, `ctl`, `int`, `all`; default `sc,int`):
`sc_uniform`, `sc_ladder`; `bp_<prec>_L<L>_<win>` (bit-plane INT) and `abit_<prec>_L<L>_<win>` (all bits in time) for
INT8 / INT6 / INT4 / W4A8 at the lengths of the BOS comparison; `bp_..._ctl` (bit-plane on the abit operands).
Windows: `dr` data + laps (drain excluded, the headline), `d` data only (peak), `all` drain included.  SC runs
`--sc-columns` 3,072 reduction columns (384 blocks at K8/M16, 192 at K16/M8: the same 3,072-edge window and 196,608
MACs at either shape).  `sc_T<L>` (group `tsweep`, T = 16..112 by 16) is uniform L = T on every row (bench define
`SC_UNIFORM_L`): energy vs stream length.  SC points read the post-window drain at the SDC output-delay point
(`SC_DRAIN_SAMPLE_LATE_PS=50`), because a routed drain rail settles up to ~1.45 ns after the edge; the drain is outside
the SAIF window, so the energy does not depend on it.

Each point runs these steps under `OUT/<point>/`, each resumable from its own marker:
`gl` (gate-level simulation with the routed max-corner SDF, the bench's exact PASS line, the model checker:
bit-exact drain or GEMM, SAIF window counts; `sdf-clock`), `audit` (`gl-audit`), `saif` (`saif-sc`, and `saif-int`
for INT), `power` (`make power_apr` on a PT-only view `apr/build/TSMC22/PAYN/<route>_pt_<point>` that symlinks the
route's outputs; `pt-coverage`; the view's SAIF snapshot byte-identical to the audited one), `row` (`row.csv`), and
`classes` for the SC points (`tcl/pt_power_classes.tcl`; must reproduce the PT total).  Rows are collected in
`OUT/sc_results.csv` and `OUT/int_results.csv`.  The route itself is never written.

Any qualified route can be measured, e.g. one written under an earlier module name:
```sh
python3 flow/measure.py --shape k8m16 --route apr/build/<target>/<run> --top <netlist top> \
    --evidence <dir with qualification.json and basin/basin_gate.json> --out build/flow/<synth>/measure
```
(`--top` sets `PAYN_TOP`, which `syn/targets/TSMC22/PAYN` takes as the netlist top for `make sim` / `power_apr`.)

### report.py

Reads every `build/flow/*/measure` (or the directories given), each measure's `inputs.txt` (route, top, shape,
qualification evidence), the route's `reports/area.rpt` and DEF, the evidence, and the BOS results; writes
`doc/payn_results.md`.  Throughput uses the block periods (bit-plane `BW*NB + (BW-1) + (P_R+P_C-2) + 8*P_C`, all bits
in time `BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + 8*P_C`, NB = L/128) and the split grid composite of the per-PE class
areas; BOS throughput is its drain-excluded peak.

### bos.sh

```sh
DRY_RUN=1 bash flow/bos.sh <campaign> 8 6 4      # plan
bash flow/bos.sh <campaign> 6 4                  # RTL tests, workload SAIF, synthesis, unit-delay netlist test,
                                                 # APR, routed GL, PT-PX -> build/flow/bos/<campaign>/results.csv
python3 flow/report.py --bos-results build/flow/bos/<campaign>/results.csv
```

## GL approvals

`qualify.py gl-audit` runs strict first.  An approval (`--gl-approve "--approve-annotated-interconnect"` on route.py /
measure.py / regress.py) is applied only after a strict failure and only if the work directory's
`gl_validator_args_rationale.txt` cites the flag; every outcome is appended to `gl_validator_args.txt` there and each
run's `timing_qualification.json` lists every approved item.  Investigate the strict failure before writing the
rationale.

## Where results go

| what | where |
|---|---|
| route stage markers, logs, qualification, basin, pin plan, bootstrap GL | `build/flow/<synth>/route/` |
| post-synthesis / routed functional GL | `build/flow/<synth>/syn_gl/<shape>/`, `build/flow/<synth>/routed_func/<shape>/` |
| measurements | `build/flow/<synth>/measure/<point>/` (`gl/`, `saif/`, `power/`, `row.csv`, `classes/`) |
| synthesis, routes, PT views | `syn/build/TSMC22/PAYN/<synth>`, `apr/build/TSMC22/PAYN/<synth>_{distguide,final}`, `..._final_pt_<point>` |
| BOS | `build/flow/bos/<campaign>/`, `syn/build/TSMC22/BOS_ARRAY*/`, `apr/build/TSMC22/BOS_ARRAY*/` |
| report | `doc/payn_results.md` |
