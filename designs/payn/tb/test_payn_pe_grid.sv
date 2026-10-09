`timescale 1ns/1ps

`include "common/clk_util.sv"

// INT bench for a P_R x P_C grid of PaYN PEs (PaynPeGrid), with the two INT
// schedules on one compile: +MODE=bp (bit-plane, default) or +MODE=abit
// (all bits in time).  Every PE laps when its own skewed pass ends; a lap is
// ONE ring_q edge that doubles every tile in place, and the global shift_in is
// used only for the final drain.  The bench drives the grid's PE inputs
// directly (no edge peripheral, INT bypass or combiner: the grid has none).
// Shape from +define+PAYN_M=8 (K16/M8, default) or 16 (K8/M16), K = 128/M;
// 8 x 8 tiles per PE; grid from +define+GRID_PR=<P_R> +define+GRID_PC=<P_C>
// (default 2 x 2).  Needs DesignWare for the tile heap (VCS -y
// $SYNOPSYS/dw/sim_ver).
//
// Common plumbing (both schedules):
//  * Edge drive (the edge peripherals' job; the bench plays them).  Every
//    input is launched at the negedge before the capturing posedge P_e.
//    "Virtual edge" v is PE (0,0)'s schedule time; PE row r sees it r edges
//    late, PE column c c edges late, PE (r,c) r+c edges late: a_bits_in[r] at
//    P_e carries the raw activation planes of virtual edge e - r, w_bits_in[c]
//    the raw weight planes of virtual edge e - c; load_a_sign_in[r] fires one
//    edge ahead of row r's first capture, load_w_sign_in[c] one edge ahead of
//    column c's pass start (w_signs_in[c] = the pass's sign word on that
//    start edge).
//  * Laps: ring_in[r] = 1 at P_e iff virtual edge e + 1 - r is a lap edge
//    (row r's A skew, one edge ahead of ring_q).  The grid moves the wave one
//    PE east per edge, so PE (r,c) laps at offset r+c.
//  * Drain: shift_in ONLY on the N_W*P_C final drain edges of each block, with
//    acc_in_west = 0 there; mac_en = 1 from P_{E0+1} on (bubbles add zero,
//    shift has priority); int_mode = 1 (it gates the west ring inputs).
//  * Data mapping: lane k / position m of data slice u carries reduction
//    element x = 128*u + M*k + m (NB = L/128 slices per pass).
//  * Reset: the operand bit pipes are not reset, so the first MAC must come at
//    least min(P_R,P_C) zero-plane edges after the reset starts.  Every edge up
//    to PE (0,0)'s first data capture drives zero planes: 1 pre-reset + 2 reset
//    + 2 settle + (E0+1) = 10 edges before the first MAC (E0 = 4).
//  * Monitors: every drained column "D blk r t e tile_h0..tile_h7" (PE row r,
//    drain step t at real edge e: PE column P_C-1-t/8, tile column 7-t%8; read
//    pre-edge on acc_out_east) and every PE's lap runs "R r c e_first len"
//    (ring_q high on edges e_first .. e_first+len-1).  X on a drained column or
//    a ring_q stops the run ([X-FAIL]).
//
// --------------------------------------------------------------- +MODE=bp --
// Bit-plane schedule (A bits in space).  Output block (ig, jg); PE (r,c) holds
// activation rows i = (ig*P_R + r)*ROWS_PE + h/BA (plane p = h % BA in tile row
// h, ROWS_PE = 8/BA) and output columns j = (jg*P_C + c)*8 + v.  Weight planes
// go in time, MSB pass first (pass pi carries bit q = BW-1-pi).  INT8: BA = BW
// = 8; W4A8: BA = 8, BW = 4; INT4: BA = BW = 4 (two activation rows per PE).
// a_signs_in[r] = (h % BA == BA-1), loaded once; w_signs_in = all ones in the
// weight-MSB pass.  The east-edge combiner is not in the grid; the checker
// forms out = sum_h 2^h tile(h) from the drained tiles.
// Schedule (virtual edges relative to the block base B = E0 + blk*BLK_LEN):
// pass pi starts at B + pi*(NB+GAP); NB data slices, then GAP bubble slices.
// PE (0,0) laps on B + pi*(NB+GAP) + NB + LO + 1 .. + LAP_LEN for pi < BW-1
// (the last lap edge is the next pass's first capture).  Drain (real edges,
// global): D0 = B + (BW-1)*(NB+GAP) + NB + 1 + DS, DS = S = P_R + P_C - 2, for
// N_W*P_C edges; the last drain edge is the next block's first capture, so
//     BLK_LEN = BW*NB + GAP*(BW-1) + S + N_W*P_C.
// Per-PE laps: GAP = LAP_LEN, LO = 0.  The run shows this BLK_LEN is feasible
// (bit exact) and the tightness controls show that no term can shrink by one.
// Options:
//   +BA=<4|8> +BW=<4|8> +L=<multiple of 128> +MROWS=<n> +NCOLS=<n>  (MROWS a
//                     multiple of P_R*ROWS_PE, default one block; NCOLS of
//                     P_C*8)
//   +LAP_LEN=<n>      lap edges per weight-pass boundary, default 1 (the
//                     in-place lap).  LAP_LEN = 0 (no lap), 2 (double lap) and
//                     8 must FAIL.
//   +JUNK             random acc_in_west on every non-drain edge (lap edges
//                     included: the ring mux must hide it), random sign words
//                     on every edge where no PE latches them.
//   +RING_GATE_JUNK   (per-PE laps only) int_mode is high only on edges where
//                     some row injects a lap (west ring_in high), random
//                     ring_in on every edge with int_mode low.  Checks the
//                     west-edge gate and that a wave already in a row finishes
//                     after int_mode falls (PE (r,c) laps up to c edges later).
//   +GLOBAL_LAP_WAIT  positive control, global-ring usage: one global ring
//                     signal forced into every PE's ring_in, shift_in on the
//                     global lap edges too, and every lap waits for the last
//                     PE: GAP = LO + LAP_LEN, LO = S.  Must PASS with S*(BW-1)
//                     more edges per block.
// Negative controls (the checker must find wrong tiles):
//   +NEG_RING_NO_ROW_SKEW  ring_in[r] driven with row 0's timing (no r
//                     offset): rows r > 0 lap r edges early.
//   +NEG_RING_NO_COL_SKEW  every PE (r,c) takes the row's west ring input
//                     directly (forced; no east wave): PE columns c > 0 lap c
//                     edges early.
//   +NEG_GLOBAL_LAP   laps issued globally (one forced ring signal + shift_in)
//                     on PE (0,0)'s schedule, without waiting for the skew
//                     (GAP = LAP_LEN, LO = 0).
//   +OLDC_UNFORCED    one global ring signal on every row's west ring_in, with
//                     nothing forced, shift_in on every global lap edge, each
//                     lap waiting S edges (GAP = LAP_LEN + S).  The ring wave
//                     reaches PE column c c edges late, so this PASSES only for
//                     P_C = 1 and must FAIL for P_C > 1.
//   +NEG_GAP_SHORT    tightness (lap term): GAP = LAP_LEN - 1, LO = -1, so each
//                     lap starts on the edge of PE (r,c)'s last MAC of the pass.
//   +NEG_DRAIN_EARLY  tightness (skew term): the drain starts one edge early
//                     (DS = S - 1), on the far PE's last MAC; the block is one
//                     edge shorter.
//   +NEG_BLOCK_OVERLAP tightness (drain/next-block term): BLK_LEN one edge
//                     short with the drain in place, so the next block's first
//                     MAC lands on the last drain edge (multi-block runs).
//   +NEG_GATE_BYPASS  with RING_GATE_JUNK: PE (r,0)'s ring_in is forced to the
//                     raw west ring_in[r] (the int_mode gate bypassed), so the
//                     junk starts stray laps.
//   +NEG_RING_STRAY   one stray ring_in[0] pulse in the middle of PE row 0's
//                     first pass (a lap that doubles non-zero partial sums and
//                     drops a MAC in every PE of row 0).
// When several lap modes are given the last of GLOBAL_LAP_WAIT,
// NEG_RING_NO_ROW_SKEW, NEG_RING_NO_COL_SKEW, NEG_GLOBAL_LAP, NEG_GAP_SHORT,
// NEG_DRAIN_EARLY, NEG_BLOCK_OVERLAP, OLDC_UNFORCED (in that order) wins.
// Trace bpg_trace.txt: header
//   BPGCFG P_R P_C BA BW L MROWS NCOLS NBLK NB GAP LO S BLK_LEN E0 MODE FLAGS LAP_LEN
// (MODE: 0 per-PE laps, 1 GLOBAL_LAP_WAIT, 2 NEG_RING_NO_ROW_SKEW,
// 3 NEG_RING_NO_COL_SKEW, 4 NEG_GLOBAL_LAP, 5 NEG_GAP_SHORT, 6 NEG_DRAIN_EARLY,
// 7 NEG_BLOCK_OVERLAP, 8 OLDC_UNFORCED; FLAGS = JUNK | RING_GATE_JUNK << 1 |
// NEG_RING_STRAY << 2), then the D and R records.  Checker:
// designs/payn/model/int_trace.py bp-grid (every tile and combined output bit
// exact against numpy int64, drain edges, lap runs of every PE, measured block
// period).  Last line PASS: PaYN bit-plane grid bench ...
//
// ------------------------------------------------------------- +MODE=abit --
// All-bits-in-time schedule.  Output block blk = ig*NJG + jg; PE (r,c), tile
// (h,v) holds C[i, j] with i = (ig*P_R + r)*8 + h, j = (jg*P_C + c)*8 + v.  One
// pass per bit pair (p, q): PE row r's A bus carries bit p of its eight
// activation rows, PE column c's W bus bit q of its eight weight columns.
// Passes grouped by level p + q, MSB level first (A bit ascending inside a
// level), contiguous inside a level; between levels one bubble slice and one
// 1-edge lap (on the next level's first capture).  Pass sign (p == BA-1) XOR
// (q == BW-1) on the W sign wave; A signs 0, loaded once.
// Schedule (virtual edges): a block's slots are those of the single-PE abit
// schedule (data slots, a bubble before every level step, one final bubble);
// the drain starts DS = S = P_R+P_C-2 edges after the single-PE drain point
// (the far PE's last MAC is S edges late) and lasts N_W*P_C edges, the last
// drain edge being the next block's first capture.  Block period
//     BLK_LEN = BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + N_W*P_C.
// Options: +BA +BW (2..8) +L (multiple of 128; worst case L*2^(BA+BW-2) < 2^23
// unless +ABIT_RANGE_DATA, for workloads whose actual GEMM fits, which the
// checker verifies) +MROWS +NCOLS (multiples of P_R*8 / P_C*8, default one
// block) +JUNK (random acc_in_west on every non-drain edge, random sign words
// on every edge where no PE latches them).  Negative controls (the checker must
// find wrong drains):
//   +NEG_RING_NO_ROW_SKEW  ring_in[r] with row 0's timing: rows r > 0 lap early
//   +NEG_RING_NO_COL_SKEW  every PE (r,c) takes the row's west ring_in directly
//                          (forced): columns c > 0 lap early
//   +NEG_ABIT_NO_BUBBLE    no bubble before a lap (each lap on a PE's last MAC
//                          of the level)
//   +NEG_DRAIN_EARLY       DS = S - 1 (the drain starts on the far PE's last MAC)
//   +NEG_BLOCK_OVERLAP     BLK_LEN one short (the next block's first MAC lands
//                          on the last drain edge)
//   +NEG_ABIT_NO_LAP=n     no lap before level n of the order (bubble kept)
//   +NEG_ABIT_EXTRA_LAP=n  an extra bubble + lap after the first pass of level n
//   +NEG_ABIT_SIGN=1       pass sign (q == BW-1) only (A term dropped)
//   +NEG_ABIT_ORDER=1      levels LSB first
// Trace abit_grid_trace.txt: header
//   ABITGCFG P_R P_C BA BW L MROWS NCOLS NBLK NB E0 E_END BLK_LEN D0 DS FORMULA NLEV
//            JUNK NEG_ROW NEG_COL NEG_NO_BUBBLE NEG_DRAIN_EARLY NEG_OVERLAP
//            NEG_NO_LAP NEG_EXTRA_LAP NEG_SIGN NEG_ORDER
// then the virtual schedule at the negedge before each edge ("P e blk j p q
// sign" first capture of pass j, "K e blk j u" raw-plane capture, "L e" lap
// edge, "M e" first MAC edge), the real drain edges ("X e blk t"), and the D
// and R records.  Checker: designs/payn/model/int_trace.py abit-grid.  Last
// line PASS: PaYN abit grid bench ...
//
// ------------------------------------------- drain register (PAYN_DRAIN=1) --
// With +define+PAYN_DRAIN=1 the grid has the drain-register chain
// (payn_pe_grid.sv) and only +MODE=abit runs.  The read-out replaces the
// global drain: PE (0,0) reads half 0 on virtual edge RD = the edge after the
// final bubble capture (the single-PE drain point; no skew wait), half 1 on
// RD+1, every PE (r,c) r+c edges later; drain_in[r] = 1 at real edge e iff
// e + 1 - r is an RD edge.  The next block's first capture is the half-1
// read edge, unless the DR chain is still busy:
//     BLK_LEN = max(D0 + 1, 2*P_C) = max(BA*BW*NB + (BA+BW-2) + 2, 2*P_C).
// shift_in stays low.  Monitors: every valid west DR "Q r e v0..v31" (PE row
// r, loaded on real edge e, value n = tile (h mod 4, v) with n = (h mod 4)*8 +
// v; read pre-edge at P_{e+1}), and every PE's drain-wave runs "W r c e len"
// (drain_q high on e .. e+len-1).  The trace logs the virtual read edges as
// "X e blk h" (h = 0, 1).  Negative controls (DRAIN=1): +NEG_DRAIN_EARLY (RD
// one edge early: half 0 read on the last MAC), +NEG_BLOCK_OVERLAP (BLK_LEN
// one short), +NEG_DR_NO_ROW_SKEW (drain_in[r] with row 0's timing),
// +NEG_DR_NO_COL_SKEW (every PE takes its row's drain_in, forced: the chain
// collides, [DR-CONTRACT]), +NEG_DR_BUSY (BLK_LEN = 2*P_C - 1 where the busy
// rule binds: [DR-CONTRACT]), and the lap controls of +MODE=abit.  The
// ABITGCFG header gains DRAIN NEG_DR_ROW NEG_DR_COL NEG_DR_BUSY.
//
// ------------------------------------------ lap fold (PAYN_LAP_FOLD=1) --
// With +define+PAYN_LAP_FOLD=1 a lap edge is a fold edge (payn_pe_grid.sv:
// it keeps its MAC and doubles first) and only +MODE=abit runs.  +MODE=abit
// runs the fold schedule by default: no bubble between levels, PE (0,0)'s lap
// on the MAC edge of the next level's first capture (the virtual edge after
// it), the same per-PE wave (ring_in[r] one edge ahead with row r's skew).
// Block period BA*BW*NB + (P_R+P_C-2) + N_W*P_C (DRAIN=1: max(BA*BW*NB + 2,
// 2*P_C)).  +ABIT_FOLD=0|1 picks the schedule (default: the build), as in
// test_payn_array.sv; +NEG_FOLD_LATE=n / +NEG_FOLD_EARLY=n move the fold
// before level n one edge late / early.  The ABITGCFG header gains FOLD
// HW_FOLD NEG_FOLD_LATE NEG_FOLD_EARLY.
//
// Operands (both modes): bpt_a.hex (A row-major, MROWS x L) and bpt_w.hex (W
// column-major, W[x, j] at j*L + x), one two's-complement byte per line, in the
// run directory (designs/payn/model/int_workload.py bp / abit).  A plusarg of
// the other schedule is an error.

`include "payn/rtl/payn_pe_grid.sv"

`ifndef PAYN_M
`define PAYN_M 8                      // positions per lane: 8 (K16/M8) or 16 (K8/M16)
`endif
`ifndef GRID_PR
`define GRID_PR 2
`endif
`ifndef GRID_PC
`define GRID_PC 2
`endif
`ifndef GRID_LOW_W
`define GRID_LOW_W 9
`endif
`ifndef GRID_MAX_EDGES
`define GRID_MAX_EDGES 400000
`endif
`ifndef PAYN_DRAIN
`define PAYN_DRAIN 0                  // drain: 0 in-tile chain, 1 drain register (payn_pe_grid.sv)
`endif
`ifndef PAYN_LAP_FOLD
`define PAYN_LAP_FOLD 0               // lap: 0 in-place lap (drops the MAC), 1 fold (payn_pe_grid.sv)
`endif

module Top;
    localparam int M = `PAYN_M;
    localparam int K = 128 / M;
    localparam int P_R = `GRID_PR;
    localparam int P_C = `GRID_PC;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int OWIDTH = 24;
    localparam int LOW_W = `GRID_LOW_W;
    localparam int S = P_R + P_C - 2;           // skew of the far PE
    localparam int E0 = 4;                      // first capture, PE (0,0)
    localparam real PERIOD = 2.5;
    localparam int AB = N_H*K*M, AS = N_H*K, WB = N_W*K*M, WS = N_W*K, AW = N_H*OWIDTH;
    localparam int ZERO_EDGES_BEFORE_MAC = 10;  // see "Reset" above

    // bit-plane lap modes (BPGCFG MODE field)
    localparam int MODE_PE = 0, MODE_GLOBAL_WAIT = 1, MODE_NEG_ROW = 2,
                   MODE_NEG_COL = 3, MODE_NEG_GLOBAL = 4, MODE_NEG_GAP_SHORT = 5,
                   MODE_NEG_DRAIN_EARLY = 6, MODE_NEG_BLOCK_OVERLAP = 7,
                   MODE_OLDC_UNFORCED = 8;

    initial begin
        assert ((K == 16 && M == 8) || (K == 8 && M == 16))
            else $fatal(1, "PaYN grid bench needs K16/M8 or K8/M16 (got K=%0d M=%0d)", K, M);
    end

    //----------------------------------------------------- common state --
    string sched = "bp";                        // +MODE
    bit abit;
    int BA = 8, BW = 8, L = 128, MROWS = 0, NCOLS = 0;
    bit junk = 1'b0;
    bit cfg_done = 1'b0;
    int NB, NIG, NJG, NBLK, BLK_LEN, E_END, N_EDGES;
    int cur_e = -1000;

    logic clk, reset, timeout;
    logic mac_en = 1'b0, shift_in = 1'b0, int_mode = 1'b1;
    logic [P_R-1:0] ring_in = '0;
    logic ring_global = 1'b0;
    logic [P_R*AB-1:0] a_bits_in = '0;
    logic [P_R*AS-1:0] a_signs_in = '0;
    logic [P_C*WB-1:0] w_bits_in = '0;
    logic [P_C*WS-1:0] w_signs_in = '0;
    logic [P_R-1:0] load_a_sign_in = '0;
    logic [P_C-1:0] load_w_sign_in = '0;
    logic [P_R*AB-1:0] a_bits_out;
    logic [P_R*AS-1:0] a_signs_out;
    logic [P_C*WB-1:0] w_bits_out;
    logic [P_C*WS-1:0] w_signs_out;
    logic [P_R-1:0] load_a_sign_out;
    logic [P_C-1:0] load_w_sign_out;
    logic [P_R-1:0] ring_out;
    logic [P_R*AW-1:0] acc_in_west = '0;
    logic [P_R*AW-1:0] acc_out_east;
    localparam int DRAIN = `PAYN_DRAIN;
    localparam int DRN = (N_H / 2) * N_W;      // values per drain register
    localparam int DRW = DRN * OWIDTH;
    logic [P_R-1:0] drain_in = '0;
    logic [P_R*DRW-1:0] dr_out_west;
    logic [P_R-1:0] dr_valid_west;
    localparam int FOLD = `PAYN_LAP_FOLD;

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]
    integer trace_file;
    int n_drain = 0;

    // Forced-ring rewiring (set from the options before cfg_done).
    bit force_col = 1'b0;             // every PE takes its row's west ring_in
    bit force_global = 1'b0;          // every PE takes the global ring signal
    bit gate_bypass = 1'b0;           // PE (r,0) takes the raw west ring_in[r]
    bit neg_dr_row = 1'b0;            // DRAIN=1: drain_in[r] with row 0's timing
    bit neg_dr_col = 1'b0;            // DRAIN=1: every PE takes its row's west drain_in
    bit neg_dr_busy = 1'b0;           // DRAIN=1: BLK_LEN = 2*P_C - 1
    int n_items = 0;                  // DRAIN=1: valid west DR items read

    ClkUtils #(.TIMEOUT(`GRID_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

    PaynPeGrid #(
        .P_ROWS(P_R), .P_COLS(P_C), .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W), .DRAIN(DRAIN), .FOLD(FOLD)
    ) dut (.*);

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] PaYN grid bench exceeded %0d cycles", `GRID_MAX_EDGES);

    // ----------------------------------------- forced ring + lap monitor --
    for (genvar r = 0; r < P_R; r++) begin : g_force_r
        for (genvar c = 0; c < P_C; c++) begin : g_force_c
            initial begin
                wait (cfg_done);
                if (force_col)
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in = ring_in[r] & int_mode;
                else if (force_global)
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in = ring_global & int_mode;
                else if (gate_bypass && c == 0)
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in = ring_in[r];
            end

            // Drain wave (DRAIN = 1): forced row input, and its runs (drain_q
            // pre-edge, the half-0 read edges).
            if (DRAIN == 1) begin : g_dr_mon
                initial begin
                    wait (cfg_done);
                    if (neg_dr_col)
                        force dut.g_pe_row[r].g_pe_col[c].u_pe.drain_in = drain_in[r];
                end
                int dr_start = -1, dr_len = 0;
                always @(posedge clk) begin
                    if (cfg_done && trace_file != 0) begin
                        if (dut.g_pe_row[r].g_pe_col[c].u_pe.g_drain.drain_q === 1'b1) begin
                            if (dr_len == 0) dr_start = cur_e;
                            dr_len++;
                        end else begin
                            if (dut.g_pe_row[r].g_pe_col[c].u_pe.g_drain.drain_q !== 1'b0)
                                $fatal(1, "[X-FAIL] PE (%0d,%0d) drain_q X at edge %0d", r, c, cur_e);
                            if (dr_len != 0) $fwrite(trace_file, "W %0d %0d %0d %0d\n", r, c, dr_start, dr_len);
                            dr_len = 0;
                        end
                    end
                end
            end

            // Lap-run monitor: ring_q as used on each edge (pre-edge value).
            int run_start = -1, run_len = 0;
            always @(posedge clk) begin
                if (cfg_done && trace_file != 0) begin
                    if (dut.g_pe_row[r].g_pe_col[c].u_pe.ring_q === 1'b1) begin
                        if (run_len == 0) run_start = cur_e;
                        run_len++;
                    end else begin
                        if (dut.g_pe_row[r].g_pe_col[c].u_pe.ring_q !== 1'b0)
                            $fatal(1, "[X-FAIL] PE (%0d,%0d) ring_q X at edge %0d", r, c, cur_e);
                        if (run_len != 0) $fwrite(trace_file, "R %0d %0d %0d %0d\n", r, c, run_start, run_len);
                        run_len = 0;
                    end
                end
            end
        end
    end

    // Random sign words (no PE latches them), 32 bits per $urandom.
    function automatic logic [AS-1:0] rand_a_signs();
        logic [AS-1:0] w;
        for (int i = AS/32 - 1; i >= 0; i--) w[i*32 +: 32] = $urandom;
        return w;
    endfunction

    function automatic logic [WS-1:0] rand_w_signs();
        logic [WS-1:0] w;
        for (int i = WS/32 - 1; i >= 0; i--) w[i*32 +: 32] = $urandom;
        return w;
    endfunction

    //====================================================== bit-plane ==
    int bp_mode = MODE_PE;
    bit gate_junk = 1'b0;
    int LAP_LEN = 1;
    bit neg_ring_stray = 1'b0;
    int ROWS_PE, GAP, LO, DS;
    logic [AS-1:0] a_sign_word;

    // Virtual edge v -> block, offset inside the block; 0 outside the run.
    function automatic bit bp_decode(input int v, output int blk, output int u);
        if (v < E0 || v >= E0 + NBLK*BLK_LEN) return 1'b0;
        blk = (v - E0) / BLK_LEN;
        u = (v - E0) % BLK_LEN;
        return 1'b1;
    endfunction

    // Data slice captured at virtual edge v: returns 1 with block, pass, slice.
    function automatic bit bp_data_at(input int v, output int blk, output int pi, output int b);
        int u;
        if (!bp_decode(v, blk, u)) return 1'b0;
        pi = u / (NB + GAP);
        b = u % (NB + GAP);
        return pi < BW && b < NB;
    endfunction

    // Lap edge in PE (0,0) time (also the global lap edges in the global modes).
    function automatic bit bp_lap_at(input int v);
        int blk, u, pi, w;
        if (!bp_decode(v, blk, u)) return 1'b0;
        pi = (u - 1) / (NB + GAP);              // u = 0 belongs to the previous pass's lap
        w = u - pi*(NB + GAP);
        if (u == 0) return 1'b0;                // block start: the drain owns it
        return pi < BW - 1 && w >= NB + LO + 1 && w <= NB + LO + LAP_LEN;
    endfunction

    // First capture of a pass at virtual edge v.
    function automatic bit bp_pass_start_at(input int v);
        int blk, u;
        if (!bp_decode(v, blk, u)) return 1'b0;
        return (u % (NB + GAP)) == 0 && (u / (NB + GAP)) < BW;
    endfunction

    // Pass whose sign word is in force at virtual edge v (0 before the run).
    function automatic int bp_sign_pass(input int v);
        int blk, u, pi;
        if (!bp_decode(v, blk, u)) return 0;
        pi = u / (NB + GAP);
        return (pi < BW) ? pi : BW - 1;
    endfunction

    // Global drain edge (real time): block and step.  Checks the block the
    // edge decodes to and the one before (NEG_BLOCK_OVERLAP: the last drain
    // edge of block k is the second edge of block k+1).
    function automatic bit bp_drain_at(input int e, output int blk, output int t);
        int d0, b0;
        if (e <= E0) return 1'b0;
        b0 = (e - E0 - 1) / BLK_LEN;
        for (int b = b0; b >= b0 - 1 && b >= 0; b--) begin
            if (b >= NBLK) continue;
            d0 = E0 + b*BLK_LEN + (BW-1)*(NB + GAP) + NB + 1 + DS;
            if (e - d0 >= 0 && e - d0 < N_W*P_C) begin
                blk = b;
                t = e - d0;
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    task automatic bp_drive(input int e);
        int blk, pi, b, ig, jg, q, i, j, x, p, t, dblk;
        bit drain;
        // A, west edge: PE row r at virtual edge e - r.
        for (int r = 0; r < P_R; r++) begin
            logic [AB-1:0] a_next;
            a_next = '0;
            if (bp_data_at(e - r, blk, pi, b)) begin
                ig = blk / NJG;
                for (int h = 0; h < N_H; h++) begin
                    i = (ig*P_R + r)*ROWS_PE + h / BA;
                    p = h % BA;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = b*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[i*L + x][p];
                        end
                end
            end
            a_bits_in[r*AB +: AB] = a_next;
            // Sign wave: one load ahead of row r's first capture.
            load_a_sign_in[r] = (e + 1 - r == E0);
            a_signs_in[r*AS +: AS] = (junk && e - r != E0) ? rand_a_signs() : a_sign_word;
        end
        // W, north edge: PE column c at virtual edge e - c.
        for (int c = 0; c < P_C; c++) begin
            logic [WB-1:0] w_next;
            w_next = '0;
            if (bp_data_at(e - c, blk, pi, b)) begin
                jg = blk % NJG;
                q = BW - 1 - pi;
                for (int v = 0; v < N_W; v++) begin
                    j = (jg*P_C + c)*N_W + v;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = b*K*M + k*M + m;
                            w_next[(v*K + k)*M + m] = w_mem[j*L + x][q];
                        end
                end
            end
            w_bits_in[c*WB +: WB] = w_next;
            load_w_sign_in[c] = bp_pass_start_at(e + 1 - c);
            if (junk && !bp_pass_start_at(e - c))
                w_signs_in[c*WS +: WS] = rand_w_signs();
            else
                w_signs_in[c*WS +: WS] = (bp_sign_pass(e - c) == 0) ? '1 : '0;
        end
        // Ring and shift.
        for (int r = 0; r < P_R; r++)
            ring_in[r] = (bp_mode == MODE_NEG_ROW || bp_mode == MODE_OLDC_UNFORCED) ? bp_lap_at(e + 1) :
                         (bp_mode == MODE_GLOBAL_WAIT || bp_mode == MODE_NEG_GLOBAL) ? 1'b0 :
                         bp_lap_at(e + 1 - r);
        // NEG_RING_STRAY: one extra west ring_in[0] edge, one edge ahead of
        // the MAC edge of PE (0,0)'s data slice NB/2 in its first pass.
        if (neg_ring_stray && e + 1 == E0 + NB/2 + 1) ring_in[0] = 1'b1;
        if (gate_junk) begin
            int_mode = 1'b0;
            for (int r = 0; r < P_R; r++) int_mode |= bp_lap_at(e + 1 - r);
            if (!int_mode) ring_in = P_R'($urandom);
        end
        ring_global = (bp_mode == MODE_GLOBAL_WAIT || bp_mode == MODE_NEG_GLOBAL) && bp_lap_at(e + 1);
        drain = bp_drain_at(e, dblk, t);
        shift_in = drain || ((bp_mode == MODE_GLOBAL_WAIT || bp_mode == MODE_NEG_GLOBAL ||
                              bp_mode == MODE_OLDC_UNFORCED) && bp_lap_at(e));
        if (drain)
            acc_in_west = '0;
        else if (junk)
            for (int n = 0; n < P_R*AW; n++) acc_in_west[n] = $urandom & 1;
        mac_en = (e > E0);
    endtask

    task automatic bp_config();
        if ($test$plusargs("GLOBAL_LAP_WAIT")) bp_mode = MODE_GLOBAL_WAIT;
        if ($test$plusargs("NEG_RING_NO_ROW_SKEW")) bp_mode = MODE_NEG_ROW;
        if ($test$plusargs("NEG_RING_NO_COL_SKEW")) bp_mode = MODE_NEG_COL;
        if ($test$plusargs("NEG_GLOBAL_LAP")) bp_mode = MODE_NEG_GLOBAL;
        if ($test$plusargs("NEG_GAP_SHORT")) bp_mode = MODE_NEG_GAP_SHORT;
        if ($test$plusargs("NEG_DRAIN_EARLY")) bp_mode = MODE_NEG_DRAIN_EARLY;
        if ($test$plusargs("NEG_BLOCK_OVERLAP")) bp_mode = MODE_NEG_BLOCK_OVERLAP;
        if ($test$plusargs("OLDC_UNFORCED")) bp_mode = MODE_OLDC_UNFORCED;
        gate_junk = $test$plusargs("RING_GATE_JUNK");
        gate_bypass = $test$plusargs("NEG_GATE_BYPASS");
        void'($value$plusargs("LAP_LEN=%d", LAP_LEN));
        neg_ring_stray = $test$plusargs("NEG_RING_STRAY");
        if (gate_bypass && !gate_junk) $fatal(1, "NEG_GATE_BYPASS needs RING_GATE_JUNK");
        if (LAP_LEN < 0 || LAP_LEN > 64) $fatal(1, "LAP_LEN=%0d out of range", LAP_LEN);
        if (bp_mode == MODE_NEG_GAP_SHORT && LAP_LEN < 1) $fatal(1, "NEG_GAP_SHORT needs LAP_LEN >= 1");
        if (gate_junk && bp_mode != MODE_PE) $fatal(1, "RING_GATE_JUNK needs the per-PE lap mode");
        force_col = (bp_mode == MODE_NEG_COL);
        force_global = (bp_mode == MODE_GLOBAL_WAIT || bp_mode == MODE_NEG_GLOBAL);

        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        NB = L / (K*M);
        ROWS_PE = N_H / BA;
        if (MROWS <= 0) MROWS = P_R*ROWS_PE;
        if (NCOLS <= 0) NCOLS = P_C*N_W;
        if (MROWS % (P_R*ROWS_PE) != 0 || NCOLS % (P_C*N_W) != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", P_R*ROWS_PE, P_C*N_W);
        if ((longint'(1) << (BW-1)) * L >= (longint'(1) << (OWIDTH-1)))
            $fatal(1, "L=%0d can overflow the %0d-bit accumulator", L, OWIDTH);
        NIG = MROWS / (P_R*ROWS_PE);
        NJG = NCOLS / (P_C*N_W);
        NBLK = NIG * NJG;
        LO = (bp_mode == MODE_GLOBAL_WAIT || bp_mode == MODE_OLDC_UNFORCED) ? S :
             (bp_mode == MODE_NEG_GAP_SHORT) ? -1 : 0;
        GAP = LAP_LEN + LO;
        DS = (bp_mode == MODE_NEG_DRAIN_EARLY) ? S - 1 : S;
        BLK_LEN = BW*NB + GAP*(BW-1) + DS + N_W*P_C - ((bp_mode == MODE_NEG_BLOCK_OVERLAP) ? 1 : 0);
        E_END = E0 + NBLK*BLK_LEN;               // last drain edge
        N_EDGES = E_END + 2;
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);
    endtask

    //=========================================================== abit ==
    bit neg_row = 1'b0, neg_no_bubble = 1'b0, neg_drain_early = 1'b0, neg_overlap = 1'b0;
    int neg_no_lap = -1, neg_extra_lap = -1, neg_sign = 0, neg_order = 0;
    int ab_fold = FOLD;               // the schedule: 0 lap (bubble), 1 fold
    int neg_fold_late = -1, neg_fold_early = -1;
    int NLEV, NP, D0, AB_DS, BLK_NOM, FORMULA, NV;
    int RD_OFF;                       // DRAIN=1: half-0 read edge (virtual) from the block base

    // Passes and the per-virtual-edge schedule.
    int lev_k [$];
    int pp [$], pq [$], ps [$], pn [$];
    int cap_blk [], cap_pass [], cap_u [], start_pass [], drn_blk [], drn_t [];
    bit lap_v [];
    int sign_now [];                  // sign word in force at virtual edge v (latest pass start <= v)

    task automatic abit_schedule();
        int sl_kind [$], sl_pass [$], sl_u [$];
        int lap_slot [$];
        bit sl_lap [];
        bit lap_next, first;
        int lap_off;
        int base, e, s;
        NLEV = BA + BW - 1;
        NP = BA * BW;
        lev_k.delete();
        for (int n = 0; n < NLEV; n++) lev_k.push_back(NLEV - 1 - n);
        if (neg_order == 1) lev_k.reverse();
        for (int n = 0; n < NLEV; n++)
            for (int p = 0; p < BA; p++) begin
                int q;
                q = lev_k[n] - p;
                if (q < 0 || q >= BW) continue;
                pp.push_back(p); pq.push_back(q); pn.push_back(n);
                ps.push_back(neg_sign == 1 ? (q == BW - 1) : ((p == BA - 1) ^ (q == BW - 1)));
            end
        // Lap schedule: a bubble before every level step, the lap on the next
        // level's first capture; fold schedule: no bubble, the lap (fold) on
        // the slot after that capture (its MAC edge).
        lap_next = 1'b0;
        lap_off = 0;
        for (int j = 0; j < NP; j++) begin
            first = (j == 0) || (pn[j] != pn[j-1]);
            if (first && j > 0) begin
                if (!ab_fold && !neg_no_bubble) begin
                    sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1);
                end
                lap_next = (pn[j] != neg_no_lap);
                lap_off = !ab_fold ? 0 : (pn[j] == neg_fold_late) ? 2 : (pn[j] == neg_fold_early) ? 0 : 1;
            end
            if (!first && pn[j] == neg_extra_lap && pn[j-1] == neg_extra_lap && (j < 2 || pn[j-2] != neg_extra_lap)) begin
                if (!ab_fold && !neg_no_bubble) begin
                    sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1);
                end
                lap_next = 1'b1;
                lap_off = ab_fold ? 1 : 0;
            end
            for (int u = 0; u < NB; u++) begin
                sl_kind.push_back(0); sl_pass.push_back(j); sl_u.push_back(u);
                if (lap_next && u == 0) lap_slot.push_back(sl_kind.size() - 1 + lap_off);
            end
            lap_next = 1'b0;
        end
        sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1);   // last MAC
        D0 = sl_kind.size();
        sl_lap = new[D0];
        foreach (lap_slot[i]) begin
            if (lap_slot[i] >= D0) $fatal(1, "[BENCH] a lap lands on slot %0d, past the block's last MAC slot %0d", lap_slot[i], D0 - 1);
            sl_lap[lap_slot[i]] = 1'b1;
        end
        AB_DS = neg_drain_early ? S - 1 : S;
        if (DRAIN == 1) begin
            // Per-PE read-out: half 0 on the edge after the bubble capture, half 1
            // on the next block's first capture, unless the DR chain is busy.
            RD_OFF = D0 - (neg_drain_early ? 1 : 0);
            BLK_NOM = (D0 + 1 > 2*P_C) ? D0 + 1 : 2*P_C;
            FORMULA = (BA*BW*NB + (ab_fold ? 0 : BA + BW - 2) + 2 > 2*P_C) ? BA*BW*NB + (ab_fold ? 0 : BA + BW - 2) + 2 : 2*P_C;
            if (neg_dr_busy && D0 + 1 >= 2*P_C)
                $fatal(1, "NEG_DR_BUSY needs a block shorter than 2*P_C = %0d edges (D0 + 1 = %0d)", 2*P_C, D0 + 1);
            BLK_LEN = neg_dr_busy ? 2*P_C - 1 : BLK_NOM - (neg_overlap ? 1 : 0);
            // The far PE's half-1 item reaches the west DR of its row last.
            E_END = E0 + (NBLK - 1)*BLK_LEN + RD_OFF + 1 + (P_R - 1) + 2*(P_C - 1);
        end else begin
            BLK_NOM = D0 + AB_DS + N_W*P_C - 1;  // last drain edge = next block's first capture
            BLK_LEN = BLK_NOM - (neg_overlap ? 1 : 0);
            FORMULA = BA*BW*NB + (ab_fold ? 0 : BA + BW - 2) + S + N_W*P_C;
            E_END = E0 + (NBLK - 1)*BLK_LEN + BLK_NOM;
        end
        N_EDGES = E_END + 2;
        NV = E_END + P_R + P_C + N_W;
        cap_blk = new[NV]; cap_pass = new[NV]; cap_u = new[NV]; start_pass = new[NV];
        drn_blk = new[NV]; drn_t = new[NV]; lap_v = new[NV];
        for (int i = 0; i < NV; i++) begin
            cap_blk[i] = -1; cap_pass[i] = -1; cap_u[i] = -1; start_pass[i] = -1;
            drn_blk[i] = -1; drn_t[i] = -1; lap_v[i] = 1'b0;
        end
        for (int b = 0; b < NBLK; b++) begin
            base = E0 + b*BLK_LEN;
            for (int sl = 0; sl < D0; sl++) begin
                e = base + sl;
                if (sl_lap[sl]) lap_v[e] = 1'b1;
                if (sl_kind[sl] == 0) begin
                    cap_blk[e] = b; cap_pass[e] = sl_pass[sl]; cap_u[e] = sl_u[sl];
                    if (sl_u[sl] == 0) start_pass[e] = sl_pass[sl];
                end
            end
            for (int t = 0; t < ((DRAIN == 1) ? 2 : N_W*P_C); t++) begin
                e = (DRAIN == 1) ? base + RD_OFF + t : base + D0 + AB_DS + t;
                if (drn_blk[e] >= 0) $fatal(1, "two drains on edge %0d", e);
                drn_blk[e] = b; drn_t[e] = t;
            end
        end
        sign_now = new[NV];
        s = 0;
        for (int v = 0; v < NV; v++) begin
            if (start_pass[v] >= 0) s = ps[start_pass[v]];
            sign_now[v] = s;
        end
    endtask

    function automatic bit in_v(input int v);
        return v >= 0 && v < NV;
    endfunction

    // DRAIN=1: virtual edge v is a half-0 read edge of PE (0,0).
    function automatic bit rd_at(input int v);
        return in_v(v) && drn_blk[v] >= 0 && drn_t[v] == 0;
    endfunction

    task automatic abit_drive(input int e);
        int v, blk, j, u, ig, jg, p, q, x;
        for (int r = 0; r < P_R; r++) begin
            logic [AB-1:0] a_next;
            a_next = '0;
            v = e - r;
            if (in_v(v) && cap_blk[v] >= 0) begin
                blk = cap_blk[v]; j = cap_pass[v]; u = cap_u[v];
                ig = blk / NJG; p = pp[j];
                for (int h = 0; h < N_H; h++)
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[((ig*P_R + r)*N_H + h)*L + x][p];
                        end
            end
            a_bits_in[r*AB +: AB] = a_next;
            load_a_sign_in[r] = (e + 1 - r == E0);
            a_signs_in[r*AS +: AS] = (junk && e - r != E0) ? rand_a_signs() : '0;
        end
        for (int c = 0; c < P_C; c++) begin
            logic [WB-1:0] w_next;
            w_next = '0;
            v = e - c;
            if (in_v(v) && cap_blk[v] >= 0) begin
                blk = cap_blk[v]; j = cap_pass[v]; u = cap_u[v];
                jg = blk % NJG; q = pq[j];
                for (int vv = 0; vv < N_W; vv++)
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            w_next[(vv*K + k)*M + m] = w_mem[((jg*P_C + c)*N_W + vv)*L + x][q];
                        end
            end
            w_bits_in[c*WB +: WB] = w_next;
            load_w_sign_in[c] = in_v(e + 1 - c) && start_pass[e + 1 - c] >= 0;
            if (junk && !(in_v(v) && start_pass[v] >= 0))
                w_signs_in[c*WS +: WS] = rand_w_signs();
            else
                w_signs_in[c*WS +: WS] = (in_v(v) && sign_now[v]) ? '1 : '0;
        end
        for (int r = 0; r < P_R; r++)
            ring_in[r] = neg_row ? (in_v(e + 1) && lap_v[e + 1]) : (in_v(e + 1 - r) && lap_v[e + 1 - r]);
        if (DRAIN == 1) begin
            // drain_in[r] one edge ahead of PE (r,0)'s half-0 read edge.
            for (int r = 0; r < P_R; r++)
                drain_in[r] = neg_dr_row ? rd_at(e + 1) : rd_at(e + 1 - r);
            shift_in = 1'b0;
        end else
            shift_in = in_v(e) && drn_blk[e] >= 0;
        if (shift_in)
            acc_in_west = '0;
        else if (junk)
            for (int n = 0; n < P_R*AW; n++) acc_in_west[n] = $urandom & 1;
        mac_en = (e > E0);
    endtask

    task automatic abit_log_schedule(input int e);
        if (!in_v(e)) return;
        if (e == E0 + 1) $fwrite(trace_file, "M %0d\n", e);
        if (start_pass[e] >= 0)
            $fwrite(trace_file, "P %0d %0d %0d %0d %0d %0d\n", e, cap_blk[e], start_pass[e],
                    pp[start_pass[e]], pq[start_pass[e]], ps[start_pass[e]]);
        if (cap_blk[e] >= 0) $fwrite(trace_file, "K %0d %0d %0d %0d\n", e, cap_blk[e], cap_pass[e], cap_u[e]);
        if (lap_v[e]) $fwrite(trace_file, "L %0d\n", e);
        if (drn_blk[e] >= 0) $fwrite(trace_file, "X %0d %0d %0d\n", e, drn_blk[e], drn_t[e]);
    endtask

    task automatic abit_config();
        neg_row = $test$plusargs("NEG_RING_NO_ROW_SKEW");
        force_col = $test$plusargs("NEG_RING_NO_COL_SKEW");
        neg_no_bubble = $test$plusargs("NEG_ABIT_NO_BUBBLE");
        neg_drain_early = $test$plusargs("NEG_DRAIN_EARLY");
        neg_overlap = $test$plusargs("NEG_BLOCK_OVERLAP");
        void'($value$plusargs("NEG_ABIT_NO_LAP=%d", neg_no_lap));
        void'($value$plusargs("NEG_ABIT_EXTRA_LAP=%d", neg_extra_lap));
        void'($value$plusargs("NEG_ABIT_SIGN=%d", neg_sign));
        void'($value$plusargs("NEG_ABIT_ORDER=%d", neg_order));
        neg_dr_row = $test$plusargs("NEG_DR_NO_ROW_SKEW");
        neg_dr_col = $test$plusargs("NEG_DR_NO_COL_SKEW");
        neg_dr_busy = $test$plusargs("NEG_DR_BUSY");
        void'($value$plusargs("ABIT_FOLD=%d", ab_fold));
        void'($value$plusargs("NEG_FOLD_LATE=%d", neg_fold_late));
        void'($value$plusargs("NEG_FOLD_EARLY=%d", neg_fold_early));
        if (BA < 2 || BA > 8 || BW < 2 || BW > 8) $fatal(1, "BA, BW must be 2..8");
        if (!(ab_fold == 0 || ab_fold == 1)) $fatal(1, "[BENCH] ABIT_FOLD must be 0 or 1");
        if (neg_no_bubble && ab_fold) $fatal(1, "[BENCH] NEG_ABIT_NO_BUBBLE needs the lap schedule (+ABIT_FOLD=0)");
        if ((neg_fold_late >= 0 || neg_fold_early >= 0) && !ab_fold)
            $fatal(1, "[BENCH] NEG_FOLD_LATE / NEG_FOLD_EARLY need the fold schedule");
        if (neg_fold_late == 0 || neg_fold_early == 0 || neg_fold_late >= BA + BW - 1 || neg_fold_early >= BA + BW - 1)
            $fatal(1, "[BENCH] NEG_FOLD_LATE / NEG_FOLD_EARLY must be 1..%0d", BA + BW - 2);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        NB = L / (K*M);
        if (MROWS <= 0) MROWS = P_R*N_H;
        if (NCOLS <= 0) NCOLS = P_C*N_W;
        if (MROWS % (P_R*N_H) != 0 || NCOLS % (P_C*N_W) != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", P_R*N_H, P_C*N_W);
        if (longint'(L) * (longint'(1) << (BA + BW - 2)) > (longint'(1) << (OWIDTH-1)) - 1 &&
            !$test$plusargs("ABIT_RANGE_DATA"))
            $fatal(1, "L=%0d at BA=%0d BW=%0d can overflow the %0d-bit tile (+ABIT_RANGE_DATA: data-dependent range)",
                   L, BA, BW, OWIDTH);
        NIG = MROWS / (P_R*N_H);
        NJG = NCOLS / (P_C*N_W);
        NBLK = NIG * NJG;
        abit_schedule();
    endtask

    //===================================================== common tail ==
    // Drain edge e (real time) -> block and step, for either schedule.
    function automatic bit drain_slot(input int e, output int blk, output int t);
        if (abit) begin
            if (!(in_v(e) && drn_blk[e] >= 0)) return 1'b0;
            blk = drn_blk[e];
            t = drn_t[e];
            return 1'b1;
        end
        return bp_drain_at(e, blk, t);
    endfunction

    // DRAIN=1: every valid west DR item, read pre-edge at P_e (loaded on e-1).
    task automatic read_dr(input int e);
        for (int r = 0; r < P_R; r++) begin
            if (dr_valid_west[r] === 1'b1) begin
                if ($isunknown(dr_out_west[r*DRW +: DRW]))
                    $fatal(1, "[X-FAIL] west DR item X: row %0d at edge %0d", r, e - 1);
                $fwrite(trace_file, "Q %0d %0d", r, e - 1);
                for (int n = 0; n < DRN; n++)
                    $fwrite(trace_file, " %0d", $signed(dr_out_west[(r*DRN + n)*OWIDTH +: OWIDTH]));
                $fwrite(trace_file, "\n");
                n_items++;
            end else if (dr_valid_west[r] !== 1'b0)
                $fatal(1, "[X-FAIL] dr_valid_west[%0d] X at edge %0d", r, e);
        end
    endtask

    // Pre-edge acc_out_east of every PE row on a drain edge.
    task automatic read_drain(input int e);
        int blk, t;
        if (!drain_slot(e, blk, t)) return;
        for (int r = 0; r < P_R; r++) begin
            if ($isunknown(acc_out_east[r*AW +: AW]))
                $fatal(1, "[X-FAIL] drained column X: block %0d row %0d step %0d", blk, r, t);
            $fwrite(trace_file, "D %0d %0d %0d %0d", blk, r, t, e);
            for (int h = 0; h < N_H; h++)
                $fwrite(trace_file, " %0d", $signed(acc_out_east[(r*N_H + h)*OWIDTH +: OWIDTH]));
            $fwrite(trace_file, "\n");
            n_drain++;
        end
    endtask

    task automatic read_hex(input string path, input int n, output logic [7:0] mem []);
        int fd, code;
        logic [7:0] v;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", path);
        mem = new[n];
        for (int idx = 0; idx < n; idx++) begin
            code = $fscanf(fd, "%h", v);
            if (code != 1 || $isunknown(v)) $fatal(1, "%s short/invalid at entry %0d", path, idx);
            mem[idx] = v;
        end
        code = $fscanf(fd, "%h", v);
        if (code == 1) $fatal(1, "%s has more than %0d entries", path, n);
        $fclose(fd);
    endtask

    // Plusargs that belong to the other schedule are an error.
    task automatic reject_plusargs(input string names [$]);
        foreach (names[i])
            if ($test$plusargs(names[i]))
                $fatal(1, "[BENCH] +%s is not an option of +MODE=%s", names[i], sched);
    endtask

    initial begin
        trace_file = 0;
        void'($value$plusargs("MODE=%s", sched));
        if (sched != "bp" && sched != "abit") $fatal(1, "[BENCH] unknown +MODE=%s (bp | abit)", sched);
        abit = (sched == "abit");
        if (DRAIN == 1 && !abit)
            $fatal(1, "[BENCH] +MODE=%s reads the in-tile chain: build with PAYN_DRAIN=0 (DRAIN=1 runs +MODE=abit)", sched);
        if (DRAIN != 1)
            reject_plusargs('{"NEG_DR_NO_ROW_SKEW", "NEG_DR_NO_COL_SKEW", "NEG_DR_BUSY"});
        if (FOLD == 1 && !abit)
            $fatal(1, "[BENCH] +MODE=%s is not run on a fold build: build with PAYN_LAP_FOLD=0 (PAYN_LAP_FOLD=1 runs +MODE=abit)", sched);
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        junk = $test$plusargs("JUNK");
        if (ZERO_EDGES_BEFORE_MAC < ((P_R < P_C) ? P_R : P_C))
            $fatal(1, "grid %0dx%0d needs %0d zero-plane edges before the first MAC (operand pipes are not reset)",
                   P_R, P_C, (P_R < P_C) ? P_R : P_C);
        if (abit) begin
            reject_plusargs('{"GLOBAL_LAP_WAIT", "NEG_GLOBAL_LAP", "NEG_GAP_SHORT", "OLDC_UNFORCED",
                              "RING_GATE_JUNK", "NEG_GATE_BYPASS", "LAP_LEN", "NEG_RING_STRAY"});
            abit_config();
        end else begin
            reject_plusargs('{"NEG_ABIT_NO_BUBBLE", "NEG_ABIT_NO_LAP", "NEG_ABIT_EXTRA_LAP", "NEG_ABIT_SIGN",
                              "NEG_ABIT_ORDER", "ABIT_RANGE_DATA", "ABIT_FOLD", "NEG_FOLD_LATE", "NEG_FOLD_EARLY"});
            bp_config();
        end
        if (N_EDGES + 16 > `GRID_MAX_EDGES) $fatal(1, "schedule exceeds GRID_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        if (abit) begin
            trace_file = $fopen("abit_grid_trace.txt", "w");
            if (trace_file == 0) $fatal(1, "cannot open abit_grid_trace.txt");
            $fwrite(trace_file, "ABITGCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, NB, E0, E_END, BLK_LEN, D0, AB_DS, FORMULA, NLEV,
                    junk, neg_row, force_col, neg_no_bubble, neg_drain_early, neg_overlap, neg_no_lap, neg_extra_lap,
                    neg_sign, neg_order, DRAIN, neg_dr_row, neg_dr_col, neg_dr_busy,
                    ab_fold, FOLD, neg_fold_late, neg_fold_early);
        end else begin
            trace_file = $fopen("bpg_trace.txt", "w");
            if (trace_file == 0) $fatal(1, "cannot open bpg_trace.txt");
            $fwrite(trace_file, "BPGCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, NB, GAP, LO, S, BLK_LEN, E0, bp_mode,
                    int'(junk) | (int'(gate_junk) << 1) | (int'(neg_ring_stray) << 2), LAP_LEN);
        end
        cfg_done = 1'b1;

        for (int e = 0; e < N_EDGES; e++) begin
            cur_e = e;
            if (abit) begin
                abit_drive(e);
                abit_log_schedule(e);
            end else begin
                bp_drive(e);
            end
            @(posedge clk);                      // P_e
            if (DRAIN == 1) read_dr(e);
            else read_drain(e);
            @(negedge clk);
        end
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = '0;
        ring_global = 1'b0;
        drain_in = '0;
        cur_e = N_EDGES;
        @(posedge clk);                          // flush open lap runs
        if (DRAIN == 1) read_dr(N_EDGES);
        @(negedge clk);

        if (DRAIN == 1 && n_items != NBLK*P_R*P_C*2)
            $fatal(1, "read %0d DR items, expected %0d", n_items, NBLK*P_R*P_C*2);
        if (DRAIN != 1 && n_drain != NBLK*P_R*N_W*P_C)
            $fatal(1, "drained %0d columns, expected %0d", n_drain, NBLK*P_R*N_W*P_C);
        $fclose(trace_file);
        trace_file = 0;
        if (abit)
            $display("PASS: PaYN abit grid bench P=%0dx%0d BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d formula=%0d edges=%0d junk=%0d drain=%0d fold=%0d hw_fold=%0d",
                     P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, BLK_LEN, FORMULA, N_EDGES, junk, DRAIN, ab_fold, FOLD);
        else
            $display("PASS: PaYN bit-plane grid bench P=%0dx%0d BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d edges=%0d mode=%0d junk=%0d gate_junk=%0d lap_len=%0d",
                     P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, BLK_LEN, N_EDGES, bp_mode, junk, gate_junk, LAP_LEN);
        $finish;
    end
endmodule
