# C-BSG bit-exact reference (`sweeps/cbsg/`)

This directory holds the integer golden for porting the scmp_kernels C-BSG multiplication onto the carry-save SC
datapath. Each tile has 8 lanes x 16 AND positions; a PE has 8 x 8 tiles. Two hardware designs are modelled here
and proven bit-exact against the kernel:

- **RG**: per-row generator, the literal C-BSG.
- **AF**: A-first.

The models stop at the integer accumulator. No RTL is involved.

| file | what it is |
|---|---|
| `cbsg_ref.py` | Library and CLI: kernel port, the RG and AF models, self-test, golden writer, golden re-checker |
| `check_vs_emulator_tables.py`, `ka_closed_form.py` | Earlier table-level checks: closed-form kA, W stream, product counts. Still valid; the self-test repeats them |
| `build/cbsg/ref_selftest.log` | Log of the last `--selftest` run |
| `build/cbsg/golden/<case>/` | Golden vectors for a SystemVerilog bench (format below); `build/cbsg/golden_{emit,check}.log` |
| `build/cbsg/verify/` | Independent review harness (`adv_verify.py`, `mask_fault_cd128.py`, `fromfloat_paths.py`) and its logs |

```sh
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/cbsg_ref.py --selftest                       # ~40 s, exit 1 on any mismatch
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/cbsg_ref.py --emit build/cbsg/golden --case all
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/cbsg_ref.py --check-golden build/cbsg/golden  # re-derive from the .mem files
PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/cbsg_ref.py --list-cases
```

The script needs only numpy. It reads `~/repos/scmp_kernels/scmp_kernels/sc/rng.py` by file path, so the package
`__init__` (torch/triton) is never imported, and writes no bytecode. Paths can be overridden with `SCMP_KERNELS`,
`SOREN_SC_TRACES` and `SOREN_PAYN`.

## Library API

| function | returns |
|---|---|
| `kernel_acc_plain(ba, sa, bb, sb, L)` | Unchunked per-row / per-tensor path, `(N, M)`. `L` is a scalar or per row |
| `kernel_acc_plain_kstack(ba, sa, bb, sb, L_rows, stoc_len=128)` | The same in one `PER_ROW_LEN` call: cum at `stoc_len`, k_table stack |
| `kernel_acc_chunked(ba, sa, bb, sb, chunk_d, stoc_len, rung_table=None, level_lens=None)` | Chunked MLP path, `(n_chunks, N, M)` per-chunk partials |
| `kernel_acc_chunked_rowsplit(ba, sa, bb, sb, chunk_d, L_rows)` | Per-row L on the chunked path as the scmp_llm wrapper calls it (one call per level) |
| `kernel_acc_batched(ba, sa, bb, sb, L)` | 3D per_head / per_row path, `(BH, N, M)` |
| `from_float(x, path, chunk_d=0)` | The kernel quantizer for a path: `(b, sign, scale)`. See the exactness note below |
| `hw_rg_acc(ba, sa, bb, sb, L, slice_len=0)`, `hw_af_acc(...)` | RG / AF model of one call from reset, `(n_slices, N, M)`. `L` is scalar, `(N,)` or `(N, n_slices)` |
| `hw_calls_acc(design, calls, fault=None)` | RG / AF on several calls back to back on one instance, no reset in between; one `(n_slices, N, M)` per call. A call is `dict(ba, sa, bb, sb, L, slice_len=0, cols=None)`, `cols` = original channel of each column of a gathered call |
| `hw_acc_batched(design, ...)` | RG / AF on 3D operands, one slice per head |
| `MASK_FAULTS` | The injected mask faults (`fault=` of the hw functions), see "Column mask" |
| `trace_call_shapes()` | Deployed `(chunk_d, d_in)` call shapes from the traces, with the ones whose block count is not a multiple of 8 and the ones with a padded last block |
| `ka_closed(b, L, mask)`, `hw_mask(k, p)`, `block_schedule(D, slice_len)` | Hardware primitives |

Operands follow the kernel's tiled-kernel convention:
- A is `(N rows, D)`, W is `(M cols, D)`;
- `b` is the boundary, 0..128;
- `sign` is -1, 0 or +1;
- all accumulators are the kernel's `acc` **before** the float scale (`q_max^2 / L`, then `scale_a * scale_b`).

**`from_float` exactness.** It is checked only for internal consistency (kernel == RG == AF on its operands), never
against GPU output; there is no torch, Triton or GPU here. Details:
- `'chunked'` with `0 < chunk_d < D` reproduces the fused per-row quantizer. That Triton kernel computes
  `scale = abs_max / q_max` and `1.0 / scale` with fp32 `/` (fused.py:76-81). The NVIDIA backend probably lowers this
  to the approximate `div.full.f32` (up to 2 ulp; not confirmed here) rather than IEEE division, so `b` can differ
  by ±1 where `x * inv_scale` lies within a few ulp of `k + 0.5` (about 1e-6 of random elements). The boundary step
  `mag * (128/127)` is safe, because `k * 128/127` never comes within 0.003 of a half.
- `'chunked'` with `D <= chunk_d` (or `chunk_d = 0`) uses the grouped quantizer, because the kernel takes the
  standard path there (kernels.py:1840, then `_sc_matmul_enable_triton_bipolar_mlp` 1477-1500). `from_float` returns
  the `'per_row'` result with scale `(rows, 1)`. Deployed small gathered calls do this: d_in 21, 26, 41, 47, 52, 62,
  77, 98 and 123 at chunk_d 128.
- `'per_row'`, `'per_row_3d'`, `'per_head'` and `'per_tensor'` divide in torch or Python (IEEE); the kernel only
  multiplies.

The hardware contract starts at `(b, sign)`, so the golden vectors are generated from integer operands, not from
`from_float`.

## Hardware contract

**Operand.** Each element is a magnitude `b` in 0..128 (the kernel boundary, `round(|q| * 128/127)`) and a 1-bit
sign.
- Every kernel quantizer maps an exact zero to `b = 0`. The grouped quantizer gives it sign +1, the fused ones give
  sign 0. Either way it contributes nothing, so a 1-bit sign suffices.
- Sign 0 with `b > 0` is rejected as outside the contract.
- The quantizers never produce `b = 64`, because `round(k * 128/127)` skips it. The models still accept it, and the
  tests use it.

**Calls, slices, blocks, drains.** A call is one `sc_matmul` on the hardware. Calls run back to back, with no DUT
reset in between: consecutive (B, H) attention slices, or the unprotected and protected halves of one linear. The
reduction axis of a call is cut into slices:

| path | slice |
|---|---|
| plain | the whole D of the call |
| chunked | one chunk of `chunk_d` |
| per-head and 3D per_row | one head |
| protected / unprotected half of a linear | its own call on the gathered columns (see trace settings), with its own slices |

- Each slice is cut into blocks of 8 consecutive reduction columns (lanes k = 0..7), starting at the slice's first
  column. A partial last block is padded with zero magnitude.
- A block runs `ceil(max L_row / 16)` cycles of 16 positions; W sample index at cycle c, position m is `t = 16c + m`.
  Streams restart at `t = 0` every block. Running all 8 cycles gives the same result (checked).
- The accumulators drain and clear at the end of each slice. The kernel scales every chunk (and every head)
  separately, so drains must be per slice.

**Column mask.** `mask = bitrev8(d mod 64)`, and the threshold is `(x ^ mask) >> 1` on the 7-bit grid. Here d is
the column index **inside the slice of the current call**:
- for plain, the column index along the call's D;
- restarting at 0 in every chunk and every head;
- restarting at 0 at every call start;
- for a gathered (protected / unprotected) call, the index inside the gathered call, not the original channel index.

The proposed split is verified. With `d = 8p + k`:

| mask bits | source |
|---|---|
| `[7:5]` | `bitrev3(k)`, hard-wired per lane |
| `[4:2]` | `bitrev3(p)`, with p = (block index in slice) mod 8: a 3-bit phase register |
| `[1:0]` | 0 |

After the `>> 1`, the 7-bit mask is `{bitrev3(k), bitrev3(p), 0}`. The self-test checks `hw_mask` against
`bitrev8(d mod 64)` for d < 4096, and against the kernel's `_owen_scramble` row masks.

**The scrambling-mask fix.** The phase register must reset to 0 at the first block of every slice, and every call
starts a slice. The simplest RTL is to reset it with the drain/clear, or on the slice-start flag. Nothing else may
feed d: no global `d_base`, and no channel IDs. Where each way of getting this wrong bites, from self-test T7/T8
(RG and AF give identical counts; entries are accumulators wrong):

| sequence (deployed shape) | accs | `call_d` | `no_slice_reset` | `global_mask` | `no_phase_reset` | `orig_channel_d` |
|---|---:|---:|---:|---:|---:|---:|
| one call, chunk_d 128, D 3973 (tail 5) | 2048 | 0 | 0 | 0 | 0 | 0 |
| unprotected 9144 (1143 blocks), then protected 584 | 4928 | 0 | 0 | 300 | 300 | 4651 |
| protected 584 (73 blocks), then unprotected 9144 | 4928 | 0 | 0 | 4290 | 4290 | 4651 |
| ViT av: 3 calls at D 257 (33 blocks each) | 192 | 0 | 0 | 126 | 124 | 0 |
| ViT qk per_head: 3 heads at D 64 | 192 | 0 | 0 | 0 | 0 | 0 |
| one call, chunk_d 96, D 296 (not deployed) | 256 | 114 | 114 | 114 | 114 | n/a |

Fault meanings (`MASK_FAULTS`):
- `call_d`: d counted inside the call but not restarted per chunk.
- `no_slice_reset`: phase reset at call start only.
- `global_mask`: d never reset, so it continues across calls.
- `no_phase_reset`: free-running phase register.
- `orig_channel_d`: d = original channel index of a gathered column.

What this means for deployment:
- **Inside one call, the per-chunk restart never matters at the deployed shapes.** Chunks of 128, heads of 64 or
  128, and attention D of 128 or 2048 all start at d ≡ 0 (mod 64) and at phase 0, so a per-call d, a global d or a
  free-running phase give exactly the slice-local masks. The first row of the table pins this. The restart only
  matters for chunk_d not a multiple of 64, which no trace uses.
- **The deployed failure is state carried across calls.** A phase register that does not reset at a call start, or
  a `d_base` that continues, corrupts the next call whenever the previous call's block count is not a multiple of 8.
  This affects 24 of the 35 deployed chunk_d 128 `d_in` values, including both halves of the 4B down_proj split
  (9144 gives 1143 blocks, 584 gives 73), and ViT av at D 257 for consecutive (B, H) calls. `trace_call_shapes()`
  lists them, and the self-test log prints them.
- **Gathered calls must use the gathered index.** Using the original channel index breaks both halves of the
  protected split.
- **Padded tails do occur at chunk_d 128,** but not at 9144 or 584: their tails, 56 and 72, are multiples of 8.
  The tails that need padding come from d_in 3973 (tail 5), 2483 (51), 721 (81) and 21 others (golden case
  `chunked_tail5`).

An earlier version of this README claimed that the chunk-local restart matters at chunk_d = 128 because of short
last chunks. That was wrong: at chunk_d = 128 the only requirements are the call-start reset and the gathered index.

**RG design** (per-row generator, literal C-BSG):
- A bit at t: `[rA(d,t) < bA] & [t < L_row]`, with `rA = (Xq(t) ^ mask) >> 1` from one sample-ordered q bank per
  lane, shared by all rows.
- Each (row, lane) has a W index counter: the number of that row's A ones before t in position order `16c + m`,
  reset every block.
- The W bit for tile (row, col) is `[bW > rB(d, index)]`, with `rB = (Xk(index) ^ mask) >> 1` from a Gray-code,
  index-addressed generator.
- Product: `A & W`.
- The `t < L_row` gate is required; removing it is caught by the self-test.

**AF design** (A-first):
- The edge computes `kA = ka_closed(bA, L_row, mask)`, with no Sobol bank. The closed form splits [0, L) into aligned
  dyadic blocks, and each set bit j of L adds `(b >> s) + [(b mod 2^s) > c_j]`, with s = 7 - j.
- A bit: `[t < kA]`.
- W bit: `[bW > rB(d, t)]`, from one sample-ordered k bank per lane, shared by every row.
- Product: `A & W`.
- No length gate is needed, because kA <= L_row.

**Accumulate.** Per (row, col), every cycle: `acc += sum_k sign(A[row,k]) * sign(W[k,col]) * popcount_m(A & W)`.
This is the signed per-cycle popcount of the CSA tile.

Accumulator range: |acc| <= 128 * (columns in the slice). That is 16384 per 128-column chunk (16-bit signed) and
262144 for a 2048-column av call (20-bit signed).

**Why both designs equal the kernel.** The kernel computes `count = cum[d, kA, bW] = #{i < kA : bW > rB(d, i)}`, with
`kA = k_table[d, bA] = #{t < L : rA(d,t) < bA}`.
- RG feeds W sample i to the i-th A one.
- AF puts the kA ones at t = 0..kA-1.

Either way the AND count is the same sum.

## Trace settings this assumes

All read-only, under `~/repos/soren_scmp/sc_traces/`.

| setting | value | read from |
|---|---|---|
| `sc_prec`, halve, `rng_levels` | 8, true, 128. The stream and grid are `2^(sc_prec-1) = 128` (matmul.py:243-259), so L <= 128 | every `*_trace.json` header (`sc_prec`, `sc_halve`) and group (`halve`, `rng_levels`); `mp_best/configs/*/*/runtime.json` |
| scramble | `owen_mode = bitrev`, `scramble_masks = 64` (also `HW_MAX_MASKS`) | trace headers, `runtime.json` |
| mode | bipolar | trace groups |
| granularity | per_row everywhere (`attn_granularity = per_row`). The only per_head is in the ViT trace `r64_amax_s41_trace.json`: qk D=64, L=64 | trace groups / headers |
| chunk_d | 0 for qk (D = head_dim 128) and av (D = ctx 2048; 257 in the ViT trace); 128 for every linear | trace groups |
| kernel path | The **table** path (`enable_matmul_triton` / tiled kernel), which assumes `SC_FORCE_COMPACT` is unset. That is the default (kernels.py:378-388: table preferred on the deployment GPU), but neither `runtime.json` nor the trace headers record the variable | kernels.py |
| per-row L, attention (chunk_d 0) | Assigned per row and dispatched as one call per level on that level's row subset, per (B,H) slice. The trace has one chunk_d-0 group per (op, unit, stoc_len); the row-split code is the local scmp_llm (dc3c8a2) `model/sc_common.py:289-316`. Modelled exactly by `kernel_acc_plain` with per-row L; equal to the single-call `PER_ROW_LEN` form (checked) | traces + local scmp_llm (read-only) |
| per-row L, linear (chunk_d 128) | Per-(row, chunk) rung table (kernel), or per-row row-split calls (scmp_llm `sc_common.py:149-179`). The trace's rung groups sum to all rows per call, which suggests one L per row; both are modelled and shown equal when the rung is constant along the chunks | traces, kernel, scmp_llm |
| ladders | 118 distinct L sets. The rung `levels` come from `metadata.json`/`wrapper.json`. The gate adds `escape_stoc_len = 128`, and protected channels add `protected_stoc_len` (68/80/84/95/112). Examples: `[97,64,48,32,25,18]` + 128 + 84 (4B t32); `[128,96,64,48,44,42,38]` + 112 (14B t48). All are listed at the top of the log | `mp_best/configs/*/target*/{metadata,wrapper}.json`, per-op `stoc_len` sets of every trace |
| protected channels | `table.json:protected_channels` gives per-(op, layer) input-channel indices that run at `protected_stoc_len` for **all** rows. In the trace the D of an op splits into two groups, e.g. 4B down_proj `d_in` 584 @ L=84 + 9144 @ rungs = 9728. Modelled as two independent calls on gathered columns, run back to back, each with its own slices, masks (d = index inside the gathered call) and scales. This is inferred from the trace; the deployed wrapper is not in any local repo, and neither is the call order (both orders are tested) | `mp_best/configs/4B/target32/table.json`, `mp_best/mp/4B_t32_awq_trace.json` |
| call shapes | chunk_d 128: 35 distinct `d_in`. In 24 the block count is not a multiple of 8 (the phase register ends the call at a non-zero value), and 24 end in a padded block (tail not a multiple of 8). chunk_d 0: `d_in` 64, 128, 257, 2048; 257 is odd in both senses. Small gathered calls (`d_in` <= 128) take the standard path (one slice) | `trace_call_shapes()` over all 43 traces |
| hybrid | INT7 per (op, layer) from `hybrid_config.json` (`chunk_size 128`, `int_bits 7`). Out of scope here: it runs in INT mode | `hybrid_config.json` |

The deployed wrapper (`/home/allenjin/Projects/scmp_llm`, July 2026) is newer than the local scmp_llm (June 2026)
and adds the escape gate and protected channels. Only their effect on the call structure was inferred, from the
traces. The local scmp_llm also maps level `sl <= 0` to a zero output; no deployed ladder has it.

## What is ported from where

All lines are in local scmp_kernels ce3d7e5. soren_scmp_kernel 9f1dead only adds `SC_MULT_SCHEME`; with the default
`cbsg`, the tables and kernels are unchanged.

| piece | source |
|---|---|
| Sobol q/k (q seed all ones = identity directions; k seed [1,1,1,1,9,1,41,255] gives 80 40 20 10 48 04 52 ff) | `sc/rng.py` (loaded, not ported) |
| sequences per column (config broadcast, scramble None) | `kernels.py:67-87`, `config_helpers.py:583-607`, `sng.py:69-116, 218-220` |
| `_resolve_rng_levels`, `_bit_reverse`, `_scramble_mask_count`, `_owen_scramble` (bitrev) | `kernels.py:667-678, 722-727, 746-767, 770-811` |
| `_prepare_rng_prefix` (prefix, then scramble, then `floor(x*128/256)`) | `kernels.py:814-849` |
| `build_cum_indicator_kernel` (strict `v > r`), `compute_k_table_kernel` | `kernels.py:103-139, 141-171` |
| `build_enable_tables` (V = 129 padded to 256), `build_k_table_only`, k_table stack | `kernels.py:883-930, 1113-1136, 1008-1036` |
| `enable_matmul_tiled_kernel` bipolar, incl. `PER_ROW_LEN` rung indexing `k_base = rung*D*V` | `kernels.py:177-302` (gather 256-263) |
| plain path dispatch | `kernels.py:1931-2015` (per_row 2D), `1297-1396` (per_tensor), `1039-1110` |
| chunked path: config of chunk_d rows (d restarts per chunk), shared cum, short last chunk, rung table, per-chunk partials | `kernels.py:1840-1856, 1517-1708` (1651-1706) |
| chunked request with D <= chunk_d: standard path, grouped quantizer | `kernels.py:1840, 1880-1911, 1477-1500` |
| 3D paths (per_head, per_row batched) | `kernels.py:475-631, 397-472, 2136-2252`; `matmul.py:391-426` |
| halve | `matmul.py:243-259` |
| quantizers (`from_float`) | grouped: `quant/grouped.py:13-71, 136-162` with `kernels.py:1489-1500, 2036-2037, 2221-2222`; fused: `quant/fused.py:36-121, 134-192, 238-280` with `kernels.py:520-529, 1660-1665` |
| hardware Sobol bank (sample order `H(c) ^ LANE(m)`) and index generator | soren_PaYN `designs/payn/sobol.sv`, `inner_pe.sv:142-180` (rewritten, checked against rng.py) |
| closed-form kA | `sweeps/cbsg/ka_closed_form.py` (vectorized) |

The kernel accumulates `counts * sa * sb` in float32. Every term is an integer, and the port asserts |acc| < 2^24, so
the float32 sum equals the int64 one. The kernel's skip of all-zero-sign tiles only skips zero terms.

**Kernel caveats.**
- **Larger config.** The `PER_ROW_LEN` stride `rung * D * V` assumes the config has exactly `chunk_d` rows (the
  default `config=None`). A caller passing a larger config would index the wrong k_table slice. The traces do not
  show the config.
- **`SC_FORCE_COMPACT=1` drops samples (upstream bug, not modelled).** With this variable set, 2D per-row attention
  (kernels.py:2048), per_tensor (1433), per_head (568) and 3D per_row (2182 / 2205, per-slice 2D) run
  `enable_matmul_compact_dot_kernel`. That kernel counts only `t < 32 * floor(L / 32)` (`num_batches = stoc_len //
  BATCH_T`, kernels.py:342, 350; `BATCH_T = 32` at 1177). So for L >= 32 that is not a multiple of 32 (48, 84, 97,
  44, ... all deployed) it drops samples with t < kA and no longer matches this reference. L < 32 falls back to the
  table (1165). The MLP compact variant (`enable_matmul_compact_mlp`, 1196+) builds per-128-column cum tables and
  stays exact. The chunked fast path always uses the table.

## Verification results

Run `--selftest` (2026-10-05, 40 s). Full log: `build/cbsg/ref_selftest.log`. Result: **PASS**, 0 mismatches.

| path | cases | MACs | RG mismatches | AF mismatches |
|---|---:|---:|---:|---:|
| plain, uniform L = every value 1..128 (D 200 / 203) | 128 | 6,602,752 | 0 | 0 |
| plain per-row (118 trace ladders at D 128/257/136, random per-row L at D 72 and 2048) | 120 | 4,992,832 | 0 | 0 |
| chunked: every L 1..128 at chunk_d 96/100/128 with short tails; rung tables for all 118 ladders at D 440/584/296/330, with stoc_len 128 or max(ladder); row-split; protected split | 262 | 10,087,040 | 0 | 0 |
| batched (per_head / per_row 3D), every L 1..128, D 64/128, 3 heads | 128 | 2,359,296 | 0 | 0 |
| from_float end to end (5 quantizers, plus a chunked request at D 77 <= chunk_d) | 6 | 157,824 | 0 | 0 |
| calls back to back (T8): D 3973 single call; 9144 + 584 protected split in both orders; 3 ViT av calls at D 257; 3 per-head D 64 | 5 | 1,561,088 | 0 | 0 |
| **total** | | **25,760,832** | **0** | **0** |

Also PASS:

**Primitives:**
- the hardware q/k banks equal rng.py;
- the mask split equals `bitrev8(d mod 64)` and the kernel `_owen_scramble`;
- closed-form kA equals the kernel k_table over all 1,056,768 (L, mask, b) cases;
- the hardware A/W samples equal the kernel rA/rB prefixes for 64 masks x 128 t;
- cum prefix nesting holds.

**Path equivalences:**
- row-split equals `PER_ROW_LEN` k-stack;
- chunked row-split equals a constant-rung table;
- chunked with D <= chunk_d equals plain;
- `from_float('chunked', 128)` at D 77 equals the grouped `'per_row'` quantizer.

**Independent and invariance checks:**
- `from_float` contract: b in 0..128 without 64, and sign 0 only at b = 0;
- all-8-cycles equals `ceil(L/16)` cycles;
- soren's independent `cosim_streaming.reference` equals `kernel_acc_plain` at L = 128/97/64/43/16/1.

**Sensitivity:**
- T7 (one call): each injected fault is caught: the four slice-mask faults at chunk_d 96, RG W index = t, RG
  without the length gate, and AF with `kA = min(bA, L)`.
- T8: every mask fault is caught exactly where the table above says, and leaves 0 accumulators wrong everywhere else.
  Both directions are asserted.

**Independent review harness** (`build/cbsg/verify/`, rerun after these changes; logs `*_postfix.log`):
- `adv_verify.py` re-derives Sobol, the tables, the chunk loop and a literal per-element bitstream without using
  cbsg_ref's primitives. Results: 600 cases at the default seed (5,547,483 MACs), 600 at seed 8 (6,241,394 MACs),
  and 60 at the default seed (549,015 MACs, the same count as the reviewer's run). All have 0 mismatches for the kernel port, RG
  and AF. All 12 golden cases match the literal model with the mask taken from `case.json` `local_d`.
- `mask_fault_cd128.py`: 0 wrong for both single-call faults at every chunk_d 128 shape. A protected call started
  at phase 7 has 150 of 160 accumulators wrong.
- `fromfloat_paths.py`: after the fix, `'chunked'` at D <= 128 differs from `'per_row'` in 0 of 7,116,800 elements
  (it was 7 before).

**Golden vectors:** 12 cases. Each case is emitted only after kernel == RG == AF at every block and drain, and
after its declared mask faults are confirmed to leave accumulators wrong. `--check-golden` re-derives all of them
from the .mem files alone: 12/12 PASS.

## Golden vector format (`--emit DIR --case NAME|all`)

Each case is one 8 x 8 tile (8 A rows, 8 W columns) in `DIR/<case>/`, made of one or more calls run back to back.
Every file is plain hex, one word per line, with a `//` header line that `$readmemh` skips.
- Blocks are numbered 0..N_BLOCKS-1 in issue order: call by call, then slice by slice, then block by block.
- Drains are numbered 0..N_DRAINS-1.
- **Do not reset the DUT between calls.** The DUT must derive the phase itself: reset the phase register when
  `slice_start` is 1, otherwise increment it. `phase.mem` is the expected value, for comparison. A bench that feeds
  `phase.mem` straight into the mask cannot catch the scrambling-mask bug.

| file | entries (index) | width | meaning |
|---|---|---|---|
| `cfg.mem` | 7 | 32 b | `N_BLOCKS N_DRAINS ROWS COLS LANES POS N_CALLS` |
| `a_mag.mem` | blk*64 + row*8 + lane | 2 hex | A magnitude 0..0x80 (0 in padded lanes) |
| `a_sgn.mem` | blk*64 + row*8 + lane | 1 hex | A sign bit, 1 = negative |
| `w_mag.mem` | blk*64 + lane*8 + col | 2 hex | W magnitude 0..0x80 |
| `w_sgn.mem` | blk*64 + lane*8 + col | 1 hex | W sign bit, 1 = negative |
| `row_len.mem` | blk*8 + row | 2 hex | Stream length L of the row in this block, 0x01..0x80 (changes per chunk with rungs) |
| `slice_start.mem` | blk | 1 hex | 1 = first block of a slice (chunk, head or call): the phase register is 0 for this block |
| `call_start.mem` | blk | 1 hex | 1 = first block of a new call (implies `slice_start`); not a reset |
| `phase.mem` | blk | 1 hex | Expected block phase p; mask bits [4:2] = bitrev3(p), lane bits [7:5] = bitrev3(lane) |
| `cycles.mem` | blk | 1 hex | `ceil(max_row L / 16)` |
| `drain.mem` | blk | 1 hex | 1 = this is the last block of a slice: compare `acc_exp[drain]` after it, then clear |
| `ka.mem` | blk*64 + row*8 + lane | 2 hex | AF A count kA (debug, or input for a host-kA build) |
| `acc_blk.mem` | blk*64 + row*8 + col | 8 hex | Accumulator after each block, since the last drain (debug), int32 |
| `acc_exp.mem` | drain*64 + row*8 + col | 8 hex | Expected accumulator at each drain, int32 two's complement |
| `case.json` | | | Spec, seed, `catches` (below), and per block: `call`, `slice` (= drain index), `call_slice`, `cols` (call-local columns), `local_d` (slice-local columns), `orig_ch` (original channels, gathered calls only), phase, cycles, drain, `slice_start`, `call_start` |

`--check-golden` also checks the control files:
- a slice starts after every drain;
- `call_start` implies `slice_start`, and the flags number `N_CALLS`;
- `phase.mem` equals a phase register reset at `slice_start`.

It also reports what two wrong DUTs would get: one whose phase resets at call starts only (`no_slice_reset`), and
one whose phase never resets (`no_phase_reset`). A case whose `case.json` lists either fault under `catches` fails
if that DUT is not caught. The `global_mask` and `orig_channel_d` catches need the column numbers, so they are
confirmed at emit time with `hw_calls_acc`.

| case | blocks / drains / calls | what it covers | mask faults caught (RG = AF accumulators wrong) |
|---|---|---|---|
| `plain_u128` | 8 / 1 / 1 | plain, uniform L = 128, all 8 phases | none (single 64-aligned slice) |
| `plain_u97` | 17 / 1 / 1 | plain, L = 97, phase wraps | none |
| `plain_ladder` | 17 / 1 / 1 | per-row L from the 14B t48 ladder, D = 133 (last block has 5 lanes) | none |
| `plain_extreme` | 9 / 1 / 1 | magnitudes only 0/1/127/128; per-row L includes 1 and 17 | none |
| `chunked_rung` | 39 / 3 / 1 | chunk_d = 128, D = 312 (56-column tail), per-(row, chunk) rungs from 4B t32 + escape + protected | none |
| `chunked_tail5` | 33 / 3 / 1 | chunk_d = 128, D = 261 (5-column tail, like d_in 3973): padded block at the deployed chunk_d, rungs | none |
| `chunked_96` | 25 / 3 / 1 | chunk_d = 96 (not a multiple of 64), per-(row, chunk) rungs | `call_d`, `no_slice_reset`, `global_mask`, `no_phase_reset`: 58 each of 192 |
| `chunked_100` | 30 / 3 / 1 | chunk_d = 100 (not a multiple of 8): every chunk ends in a padded block | `call_d` 115, `no_slice_reset` 108, `global_mask` 115, `no_phase_reset` 108, of 192 |
| `perhead_64`, `perhead_128` | 16 / 2 / 1, 32 / 2 / 1 | two heads, one drain per head; at D = 128 the mask repeats at d + 64 | none (64-aligned heads) |
| `calls_prot` | 76 / 6 / 2 | **protected split, two calls without reset.** Unprotected: 461 gathered channels (3x128 + 77; 58 blocks, so a free-running phase enters call 2 at 2), rungs. Protected: 139 scattered channels (128 + 11) at L = 84 | `no_phase_reset` 117, `global_mask` 124, `orig_channel_d` 355, of 384 |
| `calls_av257` | 66 / 2 / 2 | **two consecutive attention calls at D = 257** (ViT av, 33 blocks each), per-row L | `no_phase_reset` 62, `global_mask` 63, of 128 |

Of the deployed-shape cases, only `calls_prot` and `calls_av257` catch the deployed form of the mask bug. Every
single-call case at chunk_d 128, per-head or plain is blind to it by construction, as shown above.
