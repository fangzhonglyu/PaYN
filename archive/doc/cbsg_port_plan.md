# C-BSG port plan: soren_PaYN to our carry-save SC (+ BP INT)

**Status (2026-10-04):** read-only analysis. Nothing was synthesized, routed or simulated. Small numpy checks ran in the session scratchpad and one in the workspace (Appendix).

**Sources.** Line references use these prefixes:
- `S:` soren_PaYN @ 9fa9b8f (`S@<sha>:` for an earlier soren commit)
- `E:` soren_scmp_kernel @ 9f1dead
- `P:` this repo

Local scmp_kernels (ce3d7e5) was also read. ~/repos/soren_scmp was not accessed.

**Recommendation.** Port soren's own **STREAM_MODE=1, host-kA build** (S@b257021 with `A_ENCODER=0`), not his final gated-W architecture. That build has a thermometer A and a shared, ungated, sample-ordered W at the edge, with a plain AND in an unchanged tile. soren RTL-verified it against the Triton goldens (31dc0ea: 720/720, including host-UT, which equals cbsg at L = 128 and 64). At the model-fixed T = L = 128 it is bit-exact with cbsg, because kA = bA for every column mask (section 2). On our side the port is an edge-only change:
- a new stream generator replaces both Sobol banks;
- a new peripheral replaces `sc_pe_peripheral`;
- the CSA PE, CSA tile, BP ring and BP combiner stay untouched.

soren's final per-tile gated-W structure (e8a5915) is not needed for exactness. By estimate it would cut GMAC/s/mm2 by more than half.

---

## 1. What changed (soren_PaYN 78057a8 -> 9fa9b8f)

### 1.1 Old scheme vs C-BSG

| | ours (= 78057a8) | soren final C-BSG (e8a5915) |
|---|---|---|
| A stream | 16 per-lane, digitally shifted Sobol "q" generators. Position m of cycle c = step c of generator m. Weyl mask per (k,m), salt 0. 8-bit compare `mag > thr` | One Sobol "q" sequence in sample order: position m of cycle c = sample 16c+m. Restarts every K-block. Mask `bitrev8((d_base+k) mod 64)`, shared by all rows. 7-bit grid `thr = (x^mask)>>1`. Compare `bA > thr` |
| W stream | Same structure with the "k" direction set and salt 128. Free-running, independent of A | **Gated by A.** The j-th A one of element (h,k) in the block meets W sample j: `rB[j] = (Sk[j]^mask)>>1`, then `bB > rB[j]` |
| product | AND, then popcount over 128 samples per lane per block | AND. count = #{i < kA : rB[i] < bB}, where kA = #{t < L : rA[t] < bA} |
| operand code | 7-bit magnitude << 1 | `b = round(128\|q\|/127) = \|q\| + [\|q\| >= 64]`, range 0..128, computed on the host, plus a sign bit |
| block | RNG free-running; block b uses steps 8b+1..8b+8 | Each K-block restarts at sample 0. Runtime `stream_len` L <= 255 |

### 1.2 Worked example: one A element meets its W samples

Setup: column d=3 (mask 0xC0), bA=20, bB=50, L=128.

- **A stream.** `rA[t] = (Sq[t]^0xC0)>>1`. Cycle 0 gives 96,32,0,64,80,16,48,112,120,56,24,88,72,8,40,104. The A ones (rA < 20) fall at samples 2,5,13 | 18,29 | 34,45 | 50,58,61 | ... There are 20 in total, so kA = 20.
- **C-BSG pairing.**
  - Cycle 0: lane 2 gets W index 0 (rB=96, bit 0); lane 5 gets index 1 (32, bit 1); lane 13 gets index 2 (0, bit 1). j becomes 3.
  - Cycle 1: lane 2 gets index 3 (64, bit 0); lane 13 gets index 4 (80, bit 0).
  - The pattern continues; cycle 7 ends at index 19.
  - In hardware this is a prefix popcount over the A bits in lanes below m, plus the per-element register j.
  - count = #{i < 20 : rB[i] < 50} = **9** (exact value 20·50/128 = 7.8).
- **Why gating matters.** rA and rB are *identical* for t < 16, because the q and k direction sets share their first four vectors. A plain AND of these two streams is badly correlated (section 1.8).
- **Thermometer equivalent** (soren's STREAM_MODE=1). Let A be ones at samples 0..19 (cycle 0 all 16 lanes, cycle 1 lanes 0-3), with W ungated in sample order. The products see the same W samples 0..19, so the count is again **9**.

### 1.3 What moved where (final RTL, e8a5915)

- **Sobol.** `sobol_bank` is now one 8-bit H register, an 8-bit cycle counter, 128 lane output flops and a sync `restart` (S:sobol.sv:72-103). There is no W bank.
- **A edge.** `sc_pe_peripheral` handles A only. `d_base` is latched on `load_a`, and thresholds are shared by all rows. It keeps 1,024 comparators (S:pe_peripheral.sv:49-80).
- **W magnitudes** go raw into the PE through `w_mag_pipe` (512 flops). The W edge comparators and `w_bits_pipe` are gone. W magnitudes and a second `d_base` copy are latched on `load_w` at the top (S:payn_array.sv:102-117).
- **Per (h,k) generator, 64 per PE** (S:inner_pe.sv:139-180). Each has:
  - a 9-bit `j` register;
  - a 16-step prefix chain;
  - 16 gray-to-Sobol GF(2) maps;
  - a mask copy.
- **W comparators sit inside the tiles:** `w_mag_pipe[v][k] > w_thr[h][k][m]`. That is 8x8x8x16 = **8,192 per PE**, against 1,024 at our edge (S:inner_pe.sv:188-194).
- **Stream-length logic.** A `slice` counter and `lane_valid` drop samples at or past L. The top adds `rng_restart`, `d_base`, `stream_len` and valid/first bookkeeping (S:inner_pe.sv:123-136; S:payn_array.sv:119-135).
- **Tile unchanged.** It is still the plain AND + `$countones` + DW02_tree InnerTile. Our CSA tile postdates the fork.

### 1.4 Schedule (final RTL)

- **Fill.** Two edges: Sobol register -> peripheral -> PE pipe -> (generator + compare + tile) -> accumulator.
- **Single cycle.** The generator, compare and tile run in one cycle at 2.5 ns. No timing was reported. A is not fed ahead of W.
- **Throughput.** Blocks run gapless at T/16 = 8 cycles each, the same as ours. The next block's restart and loads are issued at `(cycle+2)%8==0` (S:power/power_payn_array.sv:223-234).
- **Drain.** Unchanged: row-serial, OWIDTH 24.

### 1.5 The in-fork builds that matter for the port

These builds existed in ce6affb..71e481d and were deleted in e8a5915. They still exist in history and can be read with `git show`.

| build | A | W | where W is compared | status |
|---|---|---|---|---|
| **STREAM_MODE=1, A_ENCODER=0** (ce6affb, b257021) | `sobol_bank` MODE=2: lane m of cycle c = sample index 16c+m, so `a_bit = kA > idx` (8-bit compare, no mask). Host sends kA | `sobol_bank` MODE=1, "k" set, H(c)^LANE(m), `MASK_MODE=1` bitrev mask, `W_RNG_SHIFT=1` | edge, N_W·K·M (as today) | RTL-verified. **This is the reference RTL for our port** |
| STREAM_MODE=1, A_ENCODER=1, A_CBSG=1 (31dc0ea, b257021) | `sc_a_encoder` counts kA from A's own "q" Sobol stream; A runs one K-block ahead | same as above | edge | RTL-verified at every L. It keeps an A Sobol bank, A comparators and per-element counters |
| gated, STREAMS=0 (812f365) | legacy PaYN streams | gated, replayed from PaYN streams | per tile | not emulator-exact (NRMSE 0.047 vs 0.078 ungated) |
| gated, STREAMS=1 (71e481d) | emulator streams | gated | per tile | promoted to the only design in e8a5915 |

Two quotes settle the equivalence:
- S@b257021:payn_array.sv (STREAM_MODE comment): "Because A's ones are contiguous from sample 0, this plain AND equals gating W's generator on the A bit, and samples past L are zero without extra masking (k <= L)."
- S@b257021:a_encoder.sv:20: "C-BSG's count ... depends on A only through kA."

ce6affb's `run_ut_matmul.sh` already checked the UT RTL against the t9 C-BSG vectors at L = 128 and 64, "where ut and cbsg are identical".

### 1.6 Removed (net diff 78057a8 -> 9fa9b8f, plus in-fork churn)

- **Generation logic:** `sobol_generator`, digital shifts and salts, `FULL_PERIOD_WRAP`, `u_w_rng`, the peripheral's W ports.
- **PE interface:** all PE pass-through outputs and the `SC_MANUAL_PE_TOP` tops.
- **Multi-PE grid support:** `tb/test_systolic_pe_grid.sv`, `tb/test_systolic_matmul.sv`, `cosim/cosim_systolic_matmul.py`, `cosim/run_systolic_matmul.sh`, `cosim/run_systolic_pe_grid.sh`. soren's fork has **no PE-grid support at all**.
- **Variants:** signed_segmented and signed_segmented_clean (all files).
- **Benches and cosim:**
  - `power/power_inner_pe.sv`, `power/power_payn_array_tpad.sv`;
  - unit benches `test_sobol`, `test_peripheral`, `test_peripheral_cosim`, `test_inner_pe`, `test_inner_tile_signed_segmented`;
  - the `sc_kernel.py` cosim with `stim.py`, `compare.py`, `payn_sim.py`, `cosim_array.py`, `cosim_peripheral.py`, `run_array.sh`, `run_peripheral.sh`.
- **Sweeps:** 13 scripts (T-pad/T-reuse power, tile sweeps, clean KMN, wire opts and others), plus many syn/apr targets.
- **Added and then removed inside the fork:**
  - in e8a5915: the STREAM_MODE=1/UT and A-encoder builds (`a_encoder.sv`, `test_payn_array_ut.sv`, `power_payn_array_ut.sv`, `cosim_streaming_ut.py`, `gen_ut_cases.py`, `run_ut_sweep.sh`, `run_ut_matmul.sh`, `run_power_array_ut.sh`, `vectors_ut/`, `run_stream_mode_power.sh`);
  - the gated_cbsg variant and its `PAYN_SC_GATED_CBSG` syn/apr targets (added in 812f365/71e481d, removed in e8a5915).
- **No reason is given** anywhere for dropping the STREAM_MODE=1 builds. No commit reports area or power for them, so "cheaper" is an inference. It is clearly true only for host-kA. The on-chip C-BSG encoder still carries an A Sobol bank, A comparators and per-element counting.

**Interface breaks:**
- `payn_array` now requires `rng_restart`, `d_base[15:0]` and `stream_len[7:0]`.
- `*_binary_in` now carries b (0..128).
- Our CSA/BP variants instantiate the old `sobol_bank`/`sc_pe_peripheral`, so soren's same-named files cannot be dropped in.

### 1.7 What was verified (soren's claims, RTL only, not rerun here)

- **Final design (e8a5915):** 240/240 against emu_golden (4 array configs x 10 shapes x L in {128,100,64,43,16,1}); the t9 C-BSG vectors at L = 128/64/43/16; the streaming power bench at 3 unnamed shapes.
- **31dc0ea:** 720/720 bit-exact (4 configs x {host-UT, enc-UT, enc-CBSG} x 10 shapes x 6 L); enc-CBSG matches the t9 vectors at every L.
- **Not on this machine:** the t9 operands and the C-BSG goldens (`../gpu_aversion/t9_sc_matmul`). soren's UT goldens for the same t9 cases (`vectors_ut/{gaussian,uniform}/out_L{128,64,43,16}.mem`, SC_MULT_SCHEME=ut, at S@ce6affb) are in history. At L = 128 and 64 they equal cbsg, but they need the missing operands.
- **No area, power, timing or GL result exists in any soren commit.**

### 1.8 Emulator side (soren_scmp_kernel 9f1dead vs scmp_kernels ce3d7e5)

**What 9f1dead adds.** `SC_MULT_SCHEME` with values `cbsg` (default), `ut` and `and` (E:kernels.py:835-851). All three are the same lookup, `cum[d, k_table[d,bA], bB]`:
- `cbsg` is the existing code.
- `ut` replaces k_table with `min(L, (bA·L+64)>>7)` for every d (E:854-866, 1205-1206).
- `and` reorders rB by `argsort(rA)` (E:869-887) and rejects per-row L.

**What cbsg computes:**
- rA = (Sobol_q ^ bitrev8(d mod 64)) >> 1, and rB the same with Sobol_k, on grid 128;
- kA = #{t < L : rA < bA};
- count = #{i < kA : rB[i] < bB};
- acc += sa·sb·count, then × 127²/L.

**The default path is unchanged:**
- Local kernels.py is byte-identical to ce3d7e5.
- With the variable unset or set to cbsg, the tables and cache keys are identical. The only change is that an invalid value now raises.
- Local scmp_kernels already *is* cbsg (`sc_enable.py:4-7`), so you do not need the fork for cbsg goldens.

**Also new in the fork:**
- `make_sobol_2d_config` (Joe–Kuo dimension 2, needed by `and`).
- `simulator/`, which models the *old* PaYN (shared banks, free AND, 8-bit grid). Do not reuse it for C-BSG.

**What the fork's bench and tests establish:**
- `tests/test_mult_scheme.py` checks invariants only: for all 3 schemes the table lookup equals literal bitstreams, plus one end-to-end per_tensor test at L=64, G=128. It needs CUDA or TRITON_INTERPRET=1.
- `bench/mult_scheme.py` has no committed results.

**Numbers below** come from an independent numpy re-implementation of its `multiplier_error`: single-multiplier error at G=128, err = count/L − bA·bB/G², rms / bias, ×1e3.

| L | cbsg | ut | and, simple seeds | and, sobol2d |
|---|---|---|---|---|
| 128 | 4.38 / +0.96 | identical | 86.2 / +65.7 | 4.43 / +1.04 |
| 64 | 9.74 / +3.89 | identical | 90.3 / +70.5 | 10.13 / +4.91 |
| 43 | 16.1 / +4.0 | 13.4 / +2.0 | 88.3 / +66.6 | 18.3 / +5.1 |
| 16 | 36.6 / +4.2 | 32.9 / +3.9 | 110.6 / +85.9 | 38.3 / +5.2 |

- C-BSG is immune to A/W seed correlation.
- It breaks even with a well-chosen AND pair at L=128 and wins at L <= 64.
- It carries a small positive bias.

**Our current SNG on the same metric** (T=128, operands 0..127, 384 blocks x 8 lanes):

| | our SNG | cbsg |
|---|---|---|
| per multiplier rms | 23.3 | 4.42 |
| bias | about 0 | +0.98 |
| mean of 64 terms with the same operands (our 8 lanes x 8 blocks; cbsg 64 masks), rms | 10.4 | 1.6 |

- Our current streams match none of the emulator's schemes, so model-accuracy numbers from scmp_kernels do not transfer to our hardware today.

### 1.9 soren RTL vs emulator cbsg: every mismatch found

**No arithmetic mismatch at the deployed parameters** (WIDTH=8, RNG_SHIFT=1, N_MASKS=64, L <= 128). Checked:
- Sobol words for both direction sets;
- sample order: `H(c)^LANE(m)` = word 16c+m for all 256 samples, both seeds;
- the gray-to-Sobol map X(i) = word i;
- the mask and the >>1 grid;
- strict compares;
- gating order (ascending lanes = the sequential reference);
- lane_valid;
- sign.

Scope mismatches (each one is a divergence outside those conditions):
1. `stream_len` is 8 bits, so L=256 cannot be expressed. The emulator allows up to 256; the deployed halve mode caps it at 128.
2. There is one array-wide `stream_len`, so the emulator's per-(row, chunk) `rung_table` lengths are not supported.
3. The RTL keeps one integer accumulator over all K-blocks. Production `sc_matmul` dequantizes per (row, chunk_d=128) and sums in FP, which needs a drain every chunk_d/K = 16 blocks. emu_golden sidesteps this with unit-scale int8 and row_scale=1.
4. The mask index is the host's `d_base mod 64`. The emulator uses the column index within the call or chunk, so the two agree only if chunk_d is a multiple of 64 or the host passes a chunk-local d_base.
5. Masks are hard-wired to bitrev with 64 masks. Non-default `SC_OWEN_MODE` / `SC_SCRAMBLE_MASKS` / `SC_HW_MAX_MASKS` diverge.
6. `sobol.sv`'s assertion allows WIDTH=7, but that cannot hold b=128, so it is not emulator-exact.
7. The A d_base (latched by `load_a`) and the W d_base (latched by `load_w`) are separate registers and must be loaded on the same block. In b257021 a single `d_base_q` was latched on `load_a || load_w`.
8. There is no on-chip q-to-b map; it lives in the host or bench and equals `nearbyint` at G=128 (there are no ties).
   - The main fused quantizer clamps to ±127, so b <= 128 there.
   - The per-head batched attention path clamps to −128 (E:kernels.py:520, quant/fused.py:267), which gives b = 129.
   - Both the RTL's 8-bit compare and the emulator (cum is built over the padded 256-entry v range) treat 129 like 128.

Emulator-side trap: the CPU reference `sc_enable.py` hard-codes stoc_len = grid = 256 with no Owen scramble. Its methods are `k_shortcut` and `cycle_by_cycle`, reached from `sc_matmul(method="table"|"compact")`. Goldens must come from the Triton tables path.

---

## 2. Key fact for the port: C-BSG at T=128 = thermometer A AND shared W

This is soren's STREAM_MODE=1 equivalence. It is restated here with exhaustive checks.

**Why kA = bA.** At G=128 and L=128, the first 128 values of rA (and of rB) are a permutation of 0..127 for **every** mask:
- V[0..6] are even and GF(2)-independent in their top 7 bits;
- the bitrev mask has bits 1:0 = 0.

So kA = bA. Because cbsg depends on A only through kA:

    count = #{i < kA : rB[i] < bB} = sum_s [kA > s] AND [rB[s] < bB]

**Checks (numpy, exhaustive, against the cycle-level gated reference):**
- L=128: k_table is the identity for all 64 masks; 0 mismatches over 64 masks x 129² (bA, bB).
- L=64: kA = ceil(bA/2) for every mask (0 mismatches).
- Any L: the same hardware is exact when the host sends **kA = k_table[d mod 64][bA]** (0 mismatches at L = 100, 43, 32, 16).
  - That kA has a closed form with no Sobol stream: `sweeps/cbsg/ka_closed_form.py` (already in the workspace). Re-run here: 0 mismatches over L = 1..128 x 64 masks x b = 0..128 (1,056,768 cases).

**Consequences:**
- No A Sobol bank, no gating, no per-tile W comparators, no lane_valid.
- A needs no mask.
- W thresholds do not depend on the row h or the column v. They are generated at the edge and broadcast exactly as today.

**W words at T=128, M=16:** `x[16c+m] = H(c) ^ LANE(m)`, with H(0..7) = 00,58,4c,14,56,0e,1a,42.
- For K=8 and K-aligned d_base: `bitrev8((d_base+k) mod 64) = bitrev8(k) ^ bitrev8(d_base[5:3]<<3)` (checked). bitrev8(k) folds into each comparator as a constant. The variable part is 3 bits (word bits 4..2).
- x bit 0 is 0 for t < 128, so a 7-bit word (112 lane flops instead of 128) is bit-identical at T <= 128.

---

## 3. Port plan (staged)

**Rules:**
- New variant directories only.
- The existing variants, `sobol.sv`, `pe_peripheral.sv` and `inner_pe.sv` stay untouched.
- Do not import soren's same-named modules (`sobol_bank`, `sc_pe_peripheral`, `InnerPE` would clash). Read his RTL with `git -C ~/repos/soren_PaYN show <sha>:<path>` and re-implement it under new names.
- Follow the PaYN RTL idiom.

### Stage 1: generator + peripheral (`designs/payn/variants/signed_segmented_csa_cbsg/`)

Reference RTL: S@b257021 `sobol.sv` (MODE 1 for W, MODE 2 for A), `pe_peripheral.sv` (`MASK_MODE=1`, `W_RNG_SHIFT=1`, `A_SCRAMBLE_ENABLE=0`) and `payn_array.sv` (`STREAM_MODE=1`, `A_ENCODER=0`).

**`cbsg_stream_gen.sv` -> `CbsgStreamGen #(WIDTH=8, M=16, T=128)`.** It replaces both `sobol_bank`s.
- A block cycle counter of log2(T/M) = 3 bits.
- A sync `restart` with soren's semantics: restart + enable emits cycle 0 on the same edge (gapless blocks); restart alone rewinds.
- Outputs:
  - `cyc_q`: a registered copy of the cycle index of the words currently presented. It drives the A thermometer.
  - `w_words[m] = H(c) ^ LANE(m)` with the "k" direction set: 16 **registered** lane words (soren's MODE-1 bank). Each word bit then fans out to N_W·K = 64 comparators, as today. Do not drive all 1,024 W comparators from one 8-bit register.
- No d_base inside the generator.

**`pe_peripheral_cbsg.sv` -> `CbsgPePeripheral #(K, M, N_H, N_W, WIDTH=8, N_MASKS=64)`.** It keeps the outputs and packing of `sc_pe_peripheral` (`a_bits[(h*K+k)*M+m]`, `w_bits`, signs), so the CSA PE and the BP wrapper see the same interface.
- **A bit:** `a_binary_q[h][k] > {cyc_q, m}`. This is soren's MODE-2 compare, and `a_binary_q` holds kA.
  - Optimized form: per element, compute `gt = a_q[7:4] > cyc_q` and `eq = a_q[7:4] == cyc_q` once, shared by 16 lanes. Per lane, `bit = gt | (eq & (a_q[3:0] > m))`, with m constant (an AO21 on a low-nibble thermometer).
  - kA = 128 sets `a_q[7]`, so every bit is 1.
- **W bit:** `w_binary_q[v][k] > (((w_words[m] ^ dmask_q) ^ BR8(k)) >> 1)`, with `BR8(k) = bitrev8(k)` a localparam.
  - `dmask_q = bitrev8(d_base[5:3] << 3)` is latched on `load_w`. That is the same edge as `rng_restart`, and the XOR is applied **after** the bank register (soren's arrangement).
  - Do not register the mask into the lane words from the `load_w`-latched copy. Cycle 0 of every block would then use the previous block's mask.
  - A non-K-aligned d_base would need soren's per-depth `(d_base_q + k) mod 64` adder. Assert `d_base % K == 0` instead.
- **Registers:**
  - 8-bit magnitudes (kA and bB, 0..128), so the field width is unchanged;
  - signs, with async reset as today;
  - `dmask_q` (3 bits).

**`payn_array_signed_segmented_csa_cbsg.sv` -> top `payn_array_signed_segmented_csa_cbsg`:**
- `u_rng` (CbsgStreamGen) and `u_peripheral` (CbsgPePeripheral).
- `u_pe` = the unchanged `InnerPESignedSegmentedCsaFlat`, included from signed_segmented_csa.
- Ports = the CSA top's ports + `rng_restart` + `d_base[15:0]`. There is no `stream_len`: the host sets the block length with `rng_en`/`mac_en`.
- Keep the instance names `u_pe/u_array_core/*bits_pipe*` so the APR distribution guides still apply.

**Host contract** (soren's A_ENCODER=0):
- `a_binary_in = kA`: bA at L=128, ceil(bA/2) at L=64, otherwise `ka_closed(bA, L, d_base+k)`.
- `w_binary_in = bB`.
- b = |q| + [|q| >= 64].

### Stage 2: PE / tile

**Recommended path: no change.** The CSA tile applies as is:
- 16 positions per lane;
- the 11-FA `PaynPopcount16Csa`;
- XOR of its five redundant bits with negate, plus one `-16*countones(negative lanes)` row (P:inner_tile_signed_segmented_csa.sv:116-148).

Why it still holds:
- The XOR+correction gives −popcount for any popcount, including 0, so zero products (thermometer past kA) need no adjustment.
- Signs stay block-held. The per-cycle range stays |d| <= 128.
- Block length is ceil(L/16) cycles. Since kA <= L, no sample at or past L can count, so no lane_valid is needed.

**Fallback, only if the hardware must literally gate W at arbitrary L:** `variants/signed_segmented_csa_cbsg_gated/inner_pe_signed_segmented_csa_cbsg_gated.sv` -> `InnerPESignedSegmentedCsaCbsgGated`.
- soren's per-(h,k) j / prefix / GF generator (64 per PE) plus 128 W comparators per tile, in front of the unchanged `InnerTileSignedSegmentedCsa`.
- `w_mag_pipe` replaces `w_bits_pipe`.
- It probably needs a pipeline stage (section 4).

**Cheaper ways to get arbitrary L with W kept at the edge:**
- host kA via the closed form;
- an on-chip closed-form kA encoder at the A edge (N_H·K = 64 elements per A half, no Sobol bank, not costed);
- soren's 31dc0ea Sobol-counting encoder.

### Stage 3: BP INT interaction (`designs/payn/variants/signed_segmented_csa_bp_cbsg/`)

**`pe_peripheral_cbsg_bp.sv` -> `CbsgPePeripheralBp`:**
- `u_sc` = CbsgPePeripheral.
- Keep the wrapper nets named **`sc_a_bits` / `sc_w_bits`**, because the `[BP-CONTRACT]` check reads `u_peripheral.sc_a_bits` / `u_peripheral.sc_w_bits` (P:payn_array_signed_segmented_csa_bp.sv:255-256).
- Keep `a_bits = sc_a_bits | (a_raw_in & int_mode)` (AO21). Optionally merge the thermometer AO21 and the bypass into one AO221 per bit, decided by synthesis.

**`payn_array_signed_segmented_csa_bp_cbsg.sv`:** a copy of the BP top with `u_rng`/`u_peripheral` swapped.
- Includes `InnerPESignedSegmentedCsaBpFlat` and `PaynBpCombiner` unchanged.
- Keeps `int_mode_q`, the MAC guard, the ring and `[BP-CONTRACT]`.

**Why INT stays exact:**
- Magnitudes are held at 0, so `0 > {cyc_q,m}` = 0 and `0 > thr` = 0 for any counter state, including JUNK with `rng_en=1`. This is the same strict-compare contract as today.
- There is no gating to disable. `rng_en=0` freezes the counter, and `rng_restart`/`d_base` are don't-cares in INT.
- Raw packing (x = 128b + 16k + m) and plane signs (through the SC sign path) are unchanged.

**SC feed bandwidth is unchanged:** 8-bit kA/bB + sign per element per block, plus 3 d_base bits per block. The INT-vs-SC bandwidth basis in `doc/INT_mode_on_PaYN.md` still holds.

The gated fallback would instead need a raw-W pipe into the tiles: +1,024 flops and +8,192 OR gates per PE.

### Stage 4: verification against emulator goldens

**Reference: `designs/payn/cosim/cbsg_reference.py`.**
- A numpy cbsg port of soren's `cosim/cosim_streaming.py` (9fa9b8f) and `cosim_streaming_ut.py` (b257021).
- The closed-form kA from `sweeps/cbsg/ka_closed_form.py`.
- A streaming trace checker, using our power-bench trace format plus `d_base` per BATCH.
- Self-tests: k_table is the identity at L=128, cbsg == thermometer, and closed form == k_table.

**Goldens: `designs/payn/cosim/cbsg_emu_golden.py`.** It mirrors soren's `emu_golden.py`: `_get_cached_sequences`, `build_enable_tables(..., rng_levels=128)`, `enable_matmul_tiled_kernel(IS_BIPOLAR, PER_ROW_LEN, row_scale=1)`, `SC_MULT_SCHEME=cbsg`.
- **Source:** soren_scmp_kernel's cbsg path, read-only. Nothing is copied into it and nothing runs inside it. Run from a separate copy in the workspace, made with `git clone` or `git archive 9f1dead | tar -x`, via `PYTHONPATH`. Do not use `git worktree add`, which writes into the source repo's `.git`.
- **Requirements:** torch + triton; CUDA, or TRITON_INTERPRET=1 with emu_golden's CPU `nearbyint` shim.
- **Never use** the CPU `sc_enable` path.
- **Needs your approval** to run.
- **Cross-check:** local scmp_kernels must produce identical goldens.

**Benches** (ported from S@b257021 under new names):
- **`designs/payn/tb/test_payn_array_csa_cbsg.sv`** (from `test_payn_array_ut.sv`, A_ENCODER=0 contract):
  - shapes from soren's `gen_cases.py`, including 1x1x8 and 9x9x9 with his extreme set {−127,−64,−63,−1,0,1,63,64,127}, and 17x3x77 (partial K);
  - **new:** q = −128 (b = 129), for the per-head path;
  - L in {128, 64, 100, 43, 16, 1}, with host kA from the closed form.
- **`designs/payn/power/power_payn_array_cbsg.sv`** (from our `power_payn_array.sv` plus soren's `power_payn_array_ut.sv`):
  - gapless 384 batches, with restart on the load edge;
  - a d_base sweep covering all 64 masks;
  - the b map `|q|+[|q|>=64]`.
- **`designs/payn/tb/test_payn_array_bp_cbsg.sv`:** all current BP INT cases, including JUNK with `rng_en=1` and junk on `rng_restart`/`d_base`, plus SC transparency against the CSA-CBSG top.
- **Driver:** `sweeps/run_csa_cbsg_rtl_checks.sh` (modelled on soren's `run_ut_sweep.sh` / `run_ut_matmul.sh`).

**Pass criteria:**
- drain bit-exact against `cbsg_reference` on every case;
- reference = emulator goldens on the shared cases;
- BP INT bit-exact;
- SC transparency bit-identical.

**GL:** zero-delay, then unit-delay, then SDF (`+neg_tchk`, `ARM_EN_X_SQUASH`), using your mandated module versions. soren documented vcs/synth 2023.12.

**Extra goldens, optional:** soren's `vectors_ut` (S@ce6affb; equal to cbsg at L = 128 and 64) and the t9 C-BSG vectors. Both need the t9 operands, which are not on this machine.

### Stage 5: synthesis / route A/B

**Targets:**
- `syn/targets/TSMC22/PAYN_SC_CSA_CBSG` and `PAYN_SC_CSA_BP_CBSG`, plus `apr/targets/TSMC22` entries with the same names.
- They are copies of PAYN_SC_CSA / PAYN_SC_CSA_BP with the new top and file list.
- Preflight = `run_csa_cbsg_rtl_checks.sh`, not soren's `run_matmul.sh` (which needs the absent t9 directory).

**Synthesis A/B** against `csa_20261002` and `csa_bp_20261004_lap`:
- area by `u_rng`, `u_peripheral` (A half and W half) and `u_pe`;
- reg-to-reg WNS on the W path (lane word -> compare -> `w_bits_pipe`).

**Route:**
- Two-pass distguide, then the pinned pass 2 with fixed grid pins (`apr/scripts/place_pins_and_guides_sc.tcl`).
- Run the basin gate before quoting power: `sweeps/pinned_pass2/run_basin_gate.sh`, corr >= 0.8, mean |a−w skew| <= 50 ps.
- New driver `sweeps/run_pinned_pass2_cbsg.sh` with arms `csa_cbsg` and `csa_bp_cbsg`, writing its own campaign directory. It compares read-only against `pinned_pass2_20261004/csa` and `pinned_pass2_csa_bp_20261004_lap`.

**Power:**
- Drain-excluded.
- The same q operand sets in both arms (activity-matched; note that b ≠ m<<1).
- 400 MHz, T=128.
- A new `sweeps/pt_block_power_cbsg.tcl` adds a `u_rng` bucket, because `pt_block_power.tcl` keys off `u_a_rng`/`u_w_rng`.
- Report the 4x4 composite area and GMAC/s/mm2.

---

## 4. Cost and risk

**Anchors (measured):**
- **Synthesis, csa_20261002:**
  - Sobol banks 698 + 708 um2 (16 flops per generator = 26.1 um2);
  - `u_peripheral` 12,793 um2, of which 10,927 is combinational (2,048 comparators, about 5.34 um2 each);
  - BP bypass AO21: 1,244 um2 for 2,048 bits (0.61 um2/bit);
  - bit pipes: 2,810 um2 for 2,048 bits (1.37 um2/bit).
- **Routed, pinned (`pinned_pass2_csa_bp_20261004_lap/comparison.txt`):**
  - CSA 43,916.5 um2, 15.726 mW, of which Sobol is 0.725 mW; 582.9 / 786.0 GMAC/s/mm2 (1 PE / 4x4);
  - BP lap 46,096.5 um2, 16.494 mW; 555.4 / 770.9 GMAC/s/mm2.
  - 4x4 composite = 16·u_pe + 4·u_peripheral + one Sobol pair: CSA 521,100 um2, BP lap 531,322 um2.
- **Throughput:** 64 MAC/cycle per PE at 400 MHz = 25.6 GMAC/s; 409.6 GMAC/s for a 4x4.

**Area and GMAC/s/mm2.** Rows marked "est." are scaled from the anchors and have not been synthesized. soren published no area numbers.

| design | single-PE um2 | GMAC/s/mm2 | 4x4 um2 | GMAC/s/mm2 |
|---|---|---|---|---|
| CSA pinned (measured) | 43,917 | 583 | 521,100 | 786 |
| **CSA-CBSG thermometer (est.)** | 37,900–39,100 | 654–675 (+12..16%) | 500,600–505,100 | 811–818 (+3.2..4.1%) |
| CSA gated-W, soren-style (est., no pipe stage) | 80,000–94,000 | 272–320 (−45..53%) | 1.175–1.399M | 293–349 (−56..63%) |
| BP lap pinned (measured) | 46,097 | 555 | 531,322 | 771 |
| **BP-CBSG thermometer (est.)** | 40,100–41,300 | 620–638 (+12..15%) | 510,800–515,300 | 795–802 (+3.1..4.0%) |

**Thermometer path, per-unit deltas (synthesis basis):**
- **A half:** −1,024 comparators (−5.47k). Add per-element gt/eq plus a low-nibble thermometer (64 x about 10–13 um2) and 1,024 AO21 (about 0.62k), +1.0..1.5k in total. Net **−4.0..4.5k per A edge half**.
- **Banks:** −1.41k. CbsgStreamGen adds 128 lane flops (about 0.21k) + H/counter/cyc_q logic, about +0.3..0.4k. Net **about −1.0..1.1k** (×1.19 routed).
- **W half:** the same 1,024 comparators, 7-bit + OR instead of 8-bit; 48 XOR2 for dmask. About ±0.3k.
- **Grid:** only 4 A halves and one generator exist per 4x4, which is why the gain shrinks from +12..16% (1 PE) to +3..4% (4x4).
- With T model-fixed, this is an iso-T saving and therefore counts toward GMAC/s/mm2.

**Gated-W path, per-PE deltas:**
- **Adds:**
  - +8,192 comparators (+37..44k);
  - 64 generators (+6..13k);
  - `w_mag_pipe` (512 flops, +0.7k).
- **Removals:**
  - `w_bits_pipe` (−1.4k);
  - the W edge comparators (−5.5k per W half, 4 per 4x4);
  - the W bank (−0.7k).
- Net **+36..50k per PE** (about 2x). In a grid it multiplies by every PE, not by the edges.
- A pipeline stage, if needed, adds +7,168 threshold or +8,192 compare flops (+9.8..11.2k per PE). That is not in the table.

**Power (estimate):**
- **Thermometer:**
  - Banks: 512 flops become about 150, so −0.4..0.5 mW of today's 0.725 mW.
  - A bits toggle at most twice per position per block, against Sobol-driven toggling every cycle today. The A comparators, the A half of `a_bits_pipe`, and the 4.9 mW pipes/broadcast share should drop. Plausible but unmeasured.
  - Products cluster into the first ceil(kA/16) cycles, which changes tile glitching. Measure it with activity-matched operands in pinned, basin-gated routes.
- **soren** published no power numbers.

**Timing:**
- **Measured today (pinned routes):**
  - The worst setup paths start at the `reset`/`shift_in` ports (IO-constrained): +0.116 ns CSA, +0.078 ns BP lap.
  - The worst internal reg-to-reg paths start at the Sobol bank registers and end at the bit pipes: +0.43 ns CSA (W bank), +0.36 ns BP lap (W bank).
  - Tile reg-to-reg paths (bit pipe -> CSA -> accumulator) are not among the 999 reported paths, so their slack is above +0.49 ns.
  - The +0.053 ns path of the floating, collapsed-basin 03b route also starts at the W bank (`u_w_rng/g_lane_2__u_generator/random_value_reg_0_` -> `w_bits_pipe`).
- **Thermometer (estimate):**
  - The A path becomes `cyc_q` -> 4-bit compare -> AO21 (-> BP AO21) -> pipe. That is shallower than today's 8-bit compare, but it does not touch today's critical internal path, which is on W.
  - The W path keeps 16 registered lane words, fan-out 64 each as today. It gains one XOR level on 3 bits and loses one compare bit. Expect slack similar to today's +0.36..0.43 ns. Confirm in synthesis.
- **Gated-W (estimate):** the prefix chain + GF map + 8-bit compare (roughly 0.6–1.0 ns) lands in front of the tile path, whose margin is known only to be above +0.49 ns. It probably needs a pipeline stage. soren ran it single-cycle on the plain popcount tile and reported no timing.

**INT-mode interaction:**
- **Thermometer:** the bypass AO21 (1,340 um2 routed), the contract and the raw packing are unchanged, and the counter is frozen in INT.
- **Gated-W:** needs a raw-W path into the tiles (+1,024 flops and +8,192 OR per PE).

**Correctness risks:**
1. **L and kA.**
   - At L=128 the host sends kA = bA. At L=64 it sends ceil(bA/2). At other L, or with per-row or per-chunk rungs, it sends kA = k_table[d mod 64][bA] from the closed form, keyed to the same d_base as the hardware mask.
   - If the host sends **unconverted bA at L < 128**, the hardware computes kA = min(bA, L). The count scale is then off by about 128/L, which is grossly wrong.
   - Sending round(bA·L/128) gives `ut`. That is within 2 counts per element of cbsg at L = 100 and 43, 1 at L = 32 and 16, and exact at L = 128 and 64.
2. **Mask index.** Needs d_base K-aligned (assert it), chunk_d a multiple of 64, and the default `SC_OWEN_MODE=bitrev` with 64 masks.
3. **Mask timing.** dmask must be latched on the restart/`load_w` edge and XORed after the bank register. Otherwise cycle 0 (16 samples per block) uses the previous block's mask.
4. **Per-chunk dequantization.** Drain every chunk_d/K = 16 K-blocks to match production `sc_matmul`. Otherwise goldens are integer-only.
5. **Restart alignment.** Each block must start at sample 0. Today's bench consumes steps 8b+1..8b+8 (off by one); repeating that breaks bit-exactness.
6. **Operand map.** The host now sends b = |q| + [|q| >= 64] (0..128; 129 only from the per-head path), not m<<1. Old SC vectors and the `sc_kernel.py` goldens no longer apply.
7. **Grid skew.** soren's fork has no PE-grid support at all. Each skewed edge needs its own restart-aligned counter and lane words, or delayed copies of them. No SC grid with real peripherals exists in either repo.
8. **Bias.** cbsg has a +0.96e-3 systematic bias at L=128; ours is about 0. The emulator already models it.

**Verification gaps:**
- The architecture itself was RTL-verified by soren (31dc0ea host-UT = cbsg at L = 128 and 64). Not yet verified:
  - the port onto the CSA tile;
  - the optimized thermometer compare;
  - the closed-form host kA, which is checked in Python only.
- Emulator goldens have not been run here (that needs approval and torch/triton). soren's pass claims were not rerun.
- The t9 operands are absent.
- No synthesis, route, power or GL numbers exist for any C-BSG arm, soren's included.

---

## 5. Open questions

1. Does the deployed model use exactly L=128 for every layer (no `rung_table` / per-row L)? If not, is host-side kA (closed form, keyed by d mod 64) acceptable, or is an on-chip encoder required?
2. What are chunk_d and the drain cadence? Is the column index chunk-local? This matters for the mask and for the per-chunk scales.
3. Do bit-exact emulator counts suffice, or must the hardware literally gate W, for example for a paper claim? This decides between the thermometer path (est. +3..4% GMAC/s/mm2 at 4x4) and soren's structure (est. −56..63%).
4. May I run the emulator goldens from a separate clone/archive of soren_scmp_kernel @ 9f1dead (or local scmp_kernels, which gives the same numbers by default), on GPU or with TRITON_INTERPRET=1 on CPU?
5. Where are the t9 operands and vectors (`gpu_aversion/t9_sc_matmul`)? They would unlock soren's `vectors_ut` and the t9 C-BSG goldens as extra checks.
6. Why did soren drop the STREAM_MODE=1 host-kA build in e8a5915? It was RTL-verified and keeps W at the edge. Worth asking him.
7. Should the scratch evidence scripts (`cbsg_equiv.py`, `mult_scheme_np.py`, `cur_scheme_err.py`, `cbsg_example.py`) move into `sweeps/cbsg/` next to `ka_closed_form.py` as kept evidence?

---

## Appendix: evidence

**Workspace:** `sweeps/cbsg/ka_closed_form.py` gives the closed-form kA. It was re-run for this plan: 0 mismatches over 1,056,768 cases.

**Session scratchpad (not in the repo):** `/tmp/claude-20001/-home-barrylyu-repos-PaYN/79588d69-e5ca-4493-9934-e7540653cc42/scratchpad/`. None of these scripts imports any repo.
- **`cbsg_equiv.py`:**
  - k_table identity at L=128 and ceil(bA/2) at L=64;
  - the cycle-level gated cbsg against a thermometer with host kA (0 mismatches at L = 128, 64, 100, 43, 32, 16);
  - max |ut − cbsg| (2, 2, 1, 1 at L = 100, 43, 32, 16; 0 at 128 and 64);
  - the H^LANE bank identity;
  - the K-aligned mask split;
  - x bit0 = 0 for t < 128.
- **`mult_scheme_np.py`:** the table in section 1.8.
- **`cur_scheme_err.py`:** our current SNG against cbsg (23.3 / 4.42 per multiplier; 10.4 / 1.6 for a 64-term mean).
- **`cbsg_example.py`:** the worked example in section 1.2 and the H(c) table.
