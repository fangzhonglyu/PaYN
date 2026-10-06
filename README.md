# PaYN

Stochastic-computing (SC) GEMM accelerator with an integer (INT) mode on the same datapath, plus binary and unary
baselines. PaYN is a **design repo**: it consumes the [ASTRAEA](../ASTRAEA) flow engine (`make synth|apr|power_apr`,
Tcl scripts, PDK setups).

## Layout

```
designs/
  payn/                 PaYN: A-first C-BSG SC + INT (bit-plane, all-bits-in-time), K16/M8 or K8/M16
    rtl/                  the RTL (top payn_array, grid PaynPeGrid)
    model/                numpy reference models and checkers
    tb/  power/           functional and power benches
  baselines/            binary_os (BOS), binary_parallel, binary_serial, unary_rate, unary_temporal, bitmod
  common/               shared bench utilities
flow/                   regression, route, measure, report (see flow/README.md)
syn/targets/TSMC22/     synthesis targets: PAYN and the baselines
apr/targets/TSMC22/     APR targets
apr/scripts/            APR hooks (PaYN pre-place: guides + fixed pins + post-fill repair; clock uncertainty)
doc/                    results and handoff notes
archive/                superseded designs, studies and scripts, untouched (see archive/README.md)
```

Start with `designs/payn/README.md` (the design and its files) and `flow/README.md` (how to verify, route, measure
and report).

## Prerequisites

- The ASTRAEA flow repo next to this one (`../ASTRAEA`), or `ASTRAEA_FLOW=<path>`.
- VCS, DC, PrimeTime, Innovus, Formality and the TSMC22 ARM kit; `flow/env.sh` loads the exact module versions.

## Common commands

```bash
python3 flow/regress.py --shape both                 # RTL regression of PaYN, both shapes
make sim TB=designs/baselines/binary_os/tb/test_binary_os_array.sv   # a baseline bench
make synth TARGET=TSMC22/BOS_ARRAY                   # synthesis of a baseline
```

Build artifacts land under `build/`, `syn/build/` and `apr/build/` (all git-ignored).
