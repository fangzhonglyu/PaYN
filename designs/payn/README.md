# PaYN

A stochastic-computing (SC) GEMM array with an integer (INT) mode on the same datapath. One PE is an 8 x 8 grid of
output-stationary tiles; each tile ANDs K lanes x M stream positions (K*M = 128 products) per cycle into a
carry-save counter and a segmented accumulator.

- **SC mode:** A-first C-BSG streams, bit-exact with the scmp_kernels C-BSG integer accumulator for any per-row
  stream length L in 1..128. A is a thermometer of kA ones (closed-form kA encoder per element at the edge); W is
  one Gray-code Sobol stream compared against each magnitude.
- **INT mode:** raw bit planes on the stream ports, with in-place doubling (every tile doubles its own value on a
  1-edge lap). Two schedules: bit-plane (A bits in space, W bits in time) and all bits in time (one pass per bit
  pair, grouped by significance level).
- **Shapes:** K16/M8 (default) or K8/M16, chosen by the `PAYN_M` define (8 or 16).
- **Drain:** `PAYN_DRAIN` (build time). 0 (default, the qualified hardware): the tile accumulators are the drain
  chain, west to east, 8 values per PE row per edge, global `shift_in`. 1: one 32-value drain register per PE and a
  per-PE drain wave: a PE reads its two halves on the two edges after its own last MAC and the registers shift west
  against the operand wave, so the array keeps computing while a slice leaves at 32 values per PE row per edge
  (`doc/column_sort_drain.md`). The bit-plane INT schedule needs 0; SC and all bits in time run on both.
- **Lap fold:** `PAYN_LAP_FOLD` (build time). 0 (default): a lap edge doubles every tile and drops its MAC, so the
  INT schedules put a bubble before it. 1: a lap edge is a fold edge, acc <- 2*acc + that edge's sum, built into
  the segmented accumulator (doubled low row into the heap, shifted high segment; no new adder), so the
  all-bits-in-time schedule has no bubble or lap edge per level step (`doc/int_lap_fold.md`). Either drain; the
  bit-plane schedule needs 0.

## Layout

| path | contents |
|---|---|
| `rtl/payn_array.sv` | top `payn_array`: block clock, edge, mode register and MAC guard, one PE, INT combiner; the full SC / INT / mode-switch contract and its simulation checks are in the header |
| `rtl/payn_pe_grid.sv` | `PaynPeGrid`: P_R x P_C PEs with skewed operand and lap waves (no edges); with `DRAIN` = 1 the drain wave (east) and the drain-register links (west) |
| `rtl/payn_pe.sv` | `PaynPeCore` (tiles, operand / sign pipes, in-place doubling mux, the drain register when `DRAIN` = 1) and `PaynPe` (packed ports, lap enable, drain wave) |
| `rtl/payn_tile.sv` | `PaynTile` (with the fold when `FOLD` = 1), `PaynCount16`, `PaynCount8`, `PaynFA` |
| `rtl/payn_edge.sv` | `PaynEdge` (operand registers, kA encoders + thermometers, W comparators, INT bypass) and `PaynKaEncoder` |
| `rtl/payn_stream_gen.sv` | `PaynStreamGen`: block cycle counter, block phase with the slice restart, W lane words |
| `rtl/payn_int_combiner.sv` | `PaynIntCombiner`: east-edge plane shift-add for the bit-plane schedule |
| `model/` | numpy reference models and checkers (C-BSG kernel, A-first emulation, golden cases, INT workloads and trace checkers); see `model/README.md` |
| `tb/` | functional benches: `test_payn_array.sv` (+MODE=sc, int, switch, abit), `test_payn_pe_grid.sv` (+MODE=bp, abit), `test_payn_units.sv` (edge blocks, and the tile fold against an integer model) |
| `power/` | power benches for gate-level SAIF capture: `power_payn_sc.sv`, `power_payn_int.sv` (+MODE=bp, abit) |

Synthesis and APR targets are `syn/targets/TSMC22/PAYN` and `apr/targets/TSMC22/PAYN`; the flow that drives
them, and the regression, are in `flow/` (see `flow/README.md`).

The tile heap uses DesignWare `DW02_tree`, so RTL simulation needs `-y $SYNOPSYS/dw/sim_ver`.
