# payn_array reference models

Python (numpy only) reference models and checkers for the `payn_array` RTL in `designs/payn/rtl/`. Run every tool
with `PYTHONDONTWRITEBYTECODE=1`.

## SC mode

| file | what it is |
|---|---|
| `cbsg.py` | The spec and the hardware model. It holds the scmp_kernels C-BSG table path ported to numpy (`kernel_acc_*`, `from_float`), the A-first PE emulation (`hw_af_acc`, `hw_calls_acc`, `MASK_FAULTS`) at K8/M16 and K16/M8, the self-test (kernel == emulation on every path), the exhaustive kA check and the check against the emulator's tables. |
| `sc_cases.py` | Golden cases for the functional bench, in the sets `base` (12 cases), `extra` (24) and `review` (7). Each case is gated (emulation == kernel at every drain; base cases must also catch their declared mask faults), written as `.mem` files plus `case.json`, and then re-derived from the `.mem` files alone. |
| `sc_trace.py` | Checker for the SC streaming power-bench trace (`CBSGAFSTREAM`). It recomputes the drain with both the kernel and the emulation, checks the schedule, and writes workload statistics as JSON. |

```sh
python3 designs/payn/model/cbsg.py selftest [--shape k8m16|k16m8|all] [--quick] [--log FILE]   # about 45 s for both shapes
python3 designs/payn/model/cbsg.py ka-exhaustive                  # kA closed form vs its definition, 1,056,768 cases
python3 designs/payn/model/cbsg.py check-tables [SCMP_KERNELS]     # kA, W samples, product counts vs rng.py tables
python3 designs/payn/model/sc_cases.py emit --set base|extra|review --out DIR [--shape k16m8] [--case A,B] [--seed N]
python3 designs/payn/model/sc_cases.py check-golden DIR [DIR ...]  # case dirs, or dirs of case dirs; shape from cfg.mem
python3 designs/payn/model/sc_cases.py list [--set S]
python3 designs/payn/model/sc_trace.py TRACE [--json OUT] [--shape k8m16|k16m8]   # shape from the trace header
```

`cbsg.py` loads `~/repos/scmp_kernels/scmp_kernels/sc/rng.py` by file path (override the location with
`SCMP_KERNELS`). It never imports torch or triton. The self-test also cross-checks against
`~/repos/soren_PaYN/designs/payn/cosim/cosim_streaming.py` (read-only; the check is skipped if that file is absent).

### C-BSG settings

- Arithmetic: sc_prec 8 with halve, so stream length L is 1..128 and the grid is 128. The mode is bipolar, with
  64 scramble masks, owen bitrev. An operand is a magnitude `b = round(|q| * 128/127)` in 0..128 (64 never
  occurs) and a 1-bit sign; sign 0 is legal only with b = 0.
- Sobol words: A word t is `bitrev8(gray(t))` (identity directions). W word t comes from the directions
  `80 40 20 10 48 04 52 ff`. The column mask is `bitrev8(d mod 64)`, and the threshold is `(word ^ mask) >> 1`.
- Kernel count per (row, col, column d): `#{i < kA : bW > rB(d, i)}` with `kA = #{t < L_row : rA(d, t) < bA}`,
  signed by `sA * sW`. `acc` is the kernel's sum before the float scale.
- A-first PE: `kA` comes from the closed form `ka_closed`. L is split into dyadic blocks, with one comparator per set
  bit of L. The A bit at sample t is `[t < kA]`. The W bit is `[bW > rB(d, t)]`, from one stream per lane shared by
  every row. Each cycle accumulates the signed popcount of `A & W`.
- Shape (K lanes, M positions): lane k of block j holds slice-local column `d = K*j + k`. Its mask is
  `{bitrev(k) [7:8-log2 K], bitrev(p) [PB+1:2], 00}` with `PB = 6 - log2 K` and `p = j mod 2^PB` (K8: 3 bits, K16: 2).
  W sample `t = M*c + m`. A block runs `ceil(max_row L / M)` cycles, at most 128 / M.
- Slices are: the whole D (plain), chunk_d (chunked; 128 when deployed), one head (per-head), and each gathered
  half of a protected linear as its own call. The PE drains and clears per slice. The phase register resets at
  every slice start, and so at every call start; nothing else may feed d (no running base, no original channel
  index). Calls run back to back without reset.
- Row lengths change per (row, chunk) through rung tables over a ladder (`cbsg.TRACE_LADDERS`, the 118 deployed
  sets). `|acc| <= 128 * (columns in the slice)`.

### Golden case files (`sc_cases.py emit`)

One directory per case: one PE with ROWS = COLS = 8 and K lanes. Every `.mem` file is plain hex, one word per line,
after a `//` header line. Blocks are numbered in issue order (call, slice, block) and drains in drain order.

| file | entry index | meaning |
|---|---|---|
| `cfg.mem` | 7 words | `N_BLOCKS N_DRAINS ROWS COLS LANES(K) POS(M) N_CALLS` |
| `a_mag.mem`, `a_sgn.mem`, `ka.mem` | `blk*ROWS*K + row*K + lane` | A magnitude (0 in padded lanes); A sign bit (1 = negative); closed-form kA |
| `w_mag.mem`, `w_sgn.mem` | `blk*K*COLS + lane*COLS + col` | W magnitude; W sign bit (lane-major) |
| `row_len.mem` | `blk*ROWS + row` | L of the row in this block |
| `slice_start.mem`, `call_start.mem`, `drain.mem` | `blk` | First block of a slice (the phase resets) or of a call (not a reset); last block of a slice |
| `phase.mem`, `cycles.mem` | `blk` | Expected phase p (the DUT derives it from slice_start); `ceil(max L / M)`. cycles has 1 hex digit at M16, 2 at M8 |
| `acc_blk.mem` | `blk*ROWS*COLS + row*COLS + col` | Accumulator after each block since the last drain, int32 |
| `acc_exp.mem` | `drain*ROWS*COLS + row*COLS + col` | Expected accumulator at each drain, int32 two's complement |
| `case.json` | | Spec, seed, mask faults caught (`af_wrong`), and per-block call, slice, columns, `local_d`, `orig_ch`, phase, cycles and flags |

The kernel accumulators (`acc_exp`) do not depend on the PE shape; only the schedule does. `check-golden` also
reports what a DUT gets if its phase resets at call starts only, or never. A case that declares the matching fault
fails if that DUT is not caught.

## INT mode

INT mode computes A (BA-bit) x W (BW-bit) two's-complement GEMMs on raw bit planes through the edge's raw-bit
bypass, with the SC streams silent (zero magnitudes). Two schedules run on the same hardware, with NB = L/128 data
cycles per pass at both shapes. Element x = 128*b + M*k + m sits on raw-port bit 128*h + x%128, so operand files and
traces are the same for K16/M8 and K8/M16; `--shape` only validates and labels.

- **bit-plane (`bp`):** A bits in space (tile row h = bit h%BA of activation row h//BA), W bits in time MSB first, one
  1-edge in-place lap between weight passes, east combiner sums 2^h. Period BW*NB + (BW-1) + (P_R+P_C-2) + 8*P_C.
- **all bits in time (`abit`):** each tile holds one output; one pass per bit pair (p, q) grouped by level p+q, MSB
  level first, one bubble and one lap per level step, pass sign on the W side, raw acc_out_east readout. Period
  BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + 8*P_C.

| file | what it is |
|---|---|
| `int_workload.py` | `{bp,abit,energy}`: the operands the benches read (bpt_a.hex row-major A, bpt_w.hex column-major W, bpt_meta.json; `energy` writes intb_* with plane densities and toggle rates). |
| `int_trace.py` | `{bp,bp-grid,bp-power,abit,abit-grid,abit-power} RUN_DIR`: checks a bench run against an independent numpy int64 GEMM (abit also: schedule rules and an edge replay of the logged stimulus; power: SAIF window counts). For a drain-register build (trace header field `drain` = 1) abit and abit-grid check every drain-register item on its predicted edge with its predicted values, the per-PE drain-wave runs and the block period max(BA*BW*NB + (BA+BW-2) + 2, 2*P_C). Lap fold (header fields `fold` = the schedule, `hw_fold` = the build): fold schedule rules (no bubble, the fold on the next level's first MAC edge), a replay with the build's lap semantics (a fold edge doubles and adds its MAC), periods without the BA+BW-2 term, and how many drained values a lap build would get wrong on the same stimulus. Prints JSON plus one [PASS]/[FAIL] line. |

```sh
python3 designs/payn/model/int_workload.py bp --ba 8 --bw 8 --L 1024 --mrows 2 --ncols 16 --dist uniform --seed 3 --out-dir RUN [--shape k16m8]
python3 designs/payn/model/int_trace.py bp RUN --json RUN/check.json [--shape k16m8]
#   bp-power: [--lap-ring-only]; abit, abit-grid: [--expect-fail] (a negative control must be caught)
```
