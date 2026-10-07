`timescale 1ns/1ps

`include "common/clk_util.sv"

// Functional bench for payn_array: SC mode (A-first C-BSG, bit-exact with the
// scmp_kernels integer accumulator), INT mode with both schedules (bit-plane
// and all-bits-in-time, 1-edge in-place laps) and SC <-> INT switching on one
// DUT.  One compile serves every mode (+MODE=sc|int|switch|abit).  Shape from
// +define+PAYN_M=8 (K16/M8, default) or 16 (K8/M16); 8 x 8 tiles.
//
// ------------------------------------------------------------ +MODE=sc --
// Plays golden cases written by designs/payn/model/sc_cases.py, one PE per
// case, and compares every drain bit-exactly against acc_exp.mem; after every
// block the tile accumulators (acc_blk.mem), after every load edge the
// encoder outputs (ka.mem) and the phase register (phase.mem).
// +CASES=d1,d2,.. play back to back without reset.  Schedule options:
//   +SEED=n +FULL_CYCLES +GAPS +RNG_GAP_LOW +MAC_EXACT +LOOSE_DRAIN +STALL
//   +RNG_LOW_END +JUNK_BUS +MID_RESET +RESET_SETTLE=n +NO_CALL_SS +NO_SLICE_SS
//   +NO_SLICE_START +KILL_DRAIN_RESET
//   +INT_JUNK      random a_raw_in, w_raw_in, int_prec and ring_in on every
//                  edge while int_mode is low (own xorshift generator, so the
//                  $urandom stream and therefore the schedule are those of a
//                  run without it); SC must not change
//   +RNG_LOW_IDLE  rng_en low on every edge outside a running block, so the
//                  counter holds at the last block's cycle count instead of
//                  stepping to IDLE (legal: that cycle is past every row's L);
//                  in +MODE=switch the counter then reaches the next SC block
//                  after an INT segment still below IDLE
//   +DRAIN_SAMPLE_LATE_PS=n  read acc_out_east n ps before the shift edge that
//                  consumes it (the SDC output-delay point: OUTPUT_DELAY =
//                  0.05 ns -> n = 50) instead of at the negedge before it.  For
//                  routed netlists, whose drain rail settles up to ~1.45 ns
//                  after the edge; in RTL both points read the same value.
// Negative controls (must FAIL): +NEG_STALL_NOMAC +NEG_STRAY_LOAD +JUNK_SS
//   +NEG_LANE_REV +NEG_KA_EQ_B +NEG_ROW_LEN_MAX +NEG_LEN_128 +NEG_SHORT_BLOCK
//   +NEG_DRAIN_EARLY +NEG_NEXT_EARLY, and +NEG_SHORT_LAST=n (the last block of
//   every case runs n cycles short; with +RNG_LOW_IDLE in +MODE=switch the cut
//   is flagged, "cuts a block", only at the first SC block_start after the
//   INT segment that follows the case).
// A case ends on the negedge right after its last drain shift edge, so the
// next case's first block may load on the edge after the drain.
// Result tags: [CHECK] [BLOCK] [KA] [PHASE] [CONTRACT].  Last line
// PASS: / FAIL: PaYN array bench.
//
// ----------------------------------------------------------- +MODE=int --
// The bit-plane INT schedule (1-edge laps, +LAP_LEN, default 1) on the INT
// ports: +BA +BW +L +MROWS +NCOLS +MODE_AT +JUNK +NEG_NO_RING +NEG_PREC
// +LAP_RING_ONLY +NEG_RING_STRAY +NEG_MAG +LAP_LEN +NEG_NO_BUBBLE
// +NEG_RING_STRAY_MID.  Operands bpt_a.hex / bpt_w.hex in the run directory
// (designs/payn/model/int_workload.py), trace bpt_trace.txt (15-field BPTCFG
// header) checked by designs/payn/model/int_trace.py, schedule bpt_sched.txt.
// SC-only inputs in INT mode: block_start = slice_start = 0 (contract),
// rng_en = 0 and a_len_in = 0 by default; under +JUNK rng_en and a_len_in are
// random on every edge as well.  Magnitudes are driven 0 on every edge.  The
// JUNK extra loads (random sign words, load_X_sign low) come only on edges
// where int_mode is high (before that the edge is an SC edge, where a load
// without block_start breaks the SC contract).  Options:
//   +PARK_CYC0     one SC block_start (no loads) at edge 1 while int_mode is
//                  still low (needs MODE_AT >= 2), then rng_en = 0: the counter
//                  sits at cycle 0 for the whole INT run, so the A thermometer
//                  is live for any kA > 0; with zero magnitudes the run must PASS
//   +NEG_MAG_A     (with +PARK_CYC0) A loads carry random magnitudes 1..128 and
//                  L = 128: the thermometer fires, [INT-CONTRACT] must stop the run
//   +NEG_MAG_W     W loads carry random magnitudes 1..128: [INT-CONTRACT]
//   +INT_LEN_DC=v  a_len_in = v on every row in INT mode (a don't-care there;
//                  default 0; JUNK overrides).  With v > 128 after a short SC
//                  block it exercises the [SC-CONTRACT] cut-block check (it
//                  must read the L of the last SC load, not a_len_q)
//   +JUNK_SCSTROBE random block_start / slice_start in INT mode: the INT
//                  result stays exact (they reach only the block clock) but
//                  the [SC-CONTRACT] count must be > 0
// The drained columns and combiner words are read by one posedge monitor that
// knows every scheduled drain edge, so the timing check ([TIMING-FAIL]:
// int_out_valid exactly two edges after each drain edge, and never otherwise)
// covers every edge after reset in every mode.
//
// -------------------------------------------------------- +MODE=switch --
// +SWITCH=sc:<case dir>,int:<int dir>,...  SC golden cases and INT blocks on
// one DUT with no reset.  An INT dir holds bpt_a.hex, bpt_w.hex and bpt_cfg.txt
// ("BA BW L MROWS NCOLS MODE_AT JUNK LAP_RING_ONLY", MODE_AT 0..3); the bench
// writes bpt_trace.txt / bpt_sched.txt there.  Tightest transitions by
// default (+SW_GAP=n adds n idle edges at every switch):
//   SC -> INT: the SC case ends on the negedge after its last drain edge
//     D_last; the INT segment's edge 0 is D_last+1 and E0 = MODE_AT + 1
//     (MODE_AT = 0: int_mode high from D_last+1, zero-load on D_last+1,
//     first raw capture D_last+2);
//   INT -> SC: int_mode stays high through the INT segment's last drain edge
//     E_END and falls for E_END+1, where the next SC case's first block loads.
// +INT_JUNK applies to the SC segments.  Negative controls (must FAIL):
//   +NEG_SW_EARLY_INT     int_mode high on the SC drain's last edge before an
//                         INT segment: the combiner captures an SC column
//                         ([TIMING-FAIL])
//   +NEG_SW_LATE_DROP     int_mode falls one edge late after an INT segment: the
//                         SC block_start lands in INT mode and the guard drops
//                         its first MAC (CHECK + CONTRACT)
//   +NEG_SW_NO_ZERO_LOAD  INT segments do not zero the magnitudes after SC: the
//                         SC streams stay live ([INT-CONTRACT])
//   +NEG_SW_INT_DROP_EARLY int_mode falls on the INT segment's last drain edge:
//                         its last column is never combined (bench count FAIL)
//   +NEG_SW_NO_RELOAD     the first SC block after INT loads A but not W (W holds
//                         the INT zero magnitudes): CHECK + CONTRACT
//
// ---------------------------------------------------------- +MODE=abit --
// The all-bits-in-time INT schedule.  Every tile holds one output: tile row h
// = activation row ig*8 + h, column v = weight column jg*8 + v (block blk =
// ig*NJG + jg).  One pass per bit pair (p, q): row bus h carries bit p of its
// activation row, column bus v bit q of its weight column, chunk u of a pass
// = reduction elements 128u + M*k + m (lane k, position m), NB = L/128 data
// edges per pass.  Passes are grouped by level p + q, MSB level first (A bit
// ascending inside a level); passes of a level are contiguous (no bubble),
// and between two levels there is one bubble capture and one 1-edge lap
// (ring_in one edge ahead; every tile doubles in place).  Pass sign
// (p == BA-1) XOR (q == BW-1) on the W side through the load_w / load_w_sign
// wave one edge ahead of each pass (zero magnitudes); A signs 0, loaded once
// with the zero-load on INT entry.  After the last level one bubble (the last
// MAC edge), then the drain: shift_in for 8 edges with acc_in_west = 0, read
// on acc_out_east (8 raw rows; the combiner still captures, its words are not
// used), the 8th drain edge being the next block's first capture.  shift_in is
// high on drain edges only (laps on ring_q alone).  Block period
// BA*BW*NB + (BA+BW-2) + 8.  int_prec = 0.
//   +BA +BW (2..8) +L (multiple of 128, worst case L*2^(BA+BW-2) < 2^23;
//   +ABIT_RANGE_DATA skips that bound for workloads whose actual GEMM fits,
//   which the checker verifies) +MROWS +NCOLS (multiples of 8) +MODE_AT +JUNK
//   +PARK_CYC0 +SEED as +MODE=int; operands bpt_a.hex / bpt_w.hex
//   (int_workload.py), trace abit_trace.txt (format at run_abit_segment),
//   schedule abit_sched.txt, checked by int_trace.py.  Negative controls (the
//   checker must find wrong drains):
//   +NEG_ABIT_NO_LAP=n     no lap before level n of the order (bubble kept)
//   +NEG_ABIT_EXTRA_LAP=n  an extra bubble + lap after the first pass of level n
//   +NEG_ABIT_SIGN=1|2     1: pass sign (q == BW-1) only (A term dropped);
//                          2: the sign of pass BA*BW/2 flipped
//   +NEG_ABIT_ORDER=1|2    1: levels LSB first; 2: levels 1 and 2 of the order swapped
//   +NEG_ABIT_NO_BUBBLE    tightness: no bubble before a lap (the lap edge drops
//                          the level's last MAC)
//   +NEG_ABIT_DRAIN_EARLY  tightness: no bubble before the drain
//   +NEG_ABIT_OVERLAP      tightness: next block one edge early (its first MAC
//                          lands on the last drain edge)
//
// ------------------------------------------- drain register (PAYN_DRAIN=1) --
// With +define+PAYN_DRAIN=1 the DUT reads out through its drain register
// (payn_array.sv [DR]); +MODE=sc and +MODE=abit run, +MODE=int and
// +MODE=switch (bit-plane, combiner) need PAYN_DRAIN=0.
//   SC: a drain scheduled at D0 (the first drain edge above) drives drain_in
//   on D0-1 and reads dr_out after D0 (tile rows 0-3) and after D0+1 (rows
//   4-7; read DRAIN_SAMPLE_LATE_PS before the next edge when given); the next
//   slice may load on D0 (NEG_NEXT_EARLY: D0-1, its first MAC on the half-1
//   read edge); NEG_DRAIN_EARLY reads half 0 on the last MAC edge.  The bench
//   also counts the dr_out_valid edges: exactly two per drain ([DRVALID]).
//   RNG_LOW_END applies to blocks without a drain only (a slice's last advance
//   edge needs rng_en high: payn_array.sv [DR]); +NEG_RNG_LOW_END_DRAIN
//   applies it to slice-ending blocks too (must FAIL: CHECK + CONTRACT).
//   abit: drain_in on the bubble capture edge, half 0 read on the bubble's MAC
//   edge, half 1 on the next block's first capture: block period
//   BA*BW*NB + (BA+BW-2) + 2.  The trace logs the read edges as "X e blk h"
//   and every valid dr_out as "Q 0 e v0..v31" (loaded on segment edge e); the
//   ABITCFG header gains DRAIN.  shift_in stays low.
//
// Needs DesignWare for the tile heap (VCS -y $SYNOPSYS/dw/sim_ver).  GL runs:
// +define+GL_SIM, +define+PAYN_DUT=<netlist top> if it is not payn_array.

`ifndef GL_SIM
`include "payn/rtl/payn_array.sv"
`endif

`ifndef TB_MAX_BLK
`define TB_MAX_BLK 4096
`endif
`ifndef TB_OWIDTH
`define TB_OWIDTH 24
`endif
`ifndef TB_LOW_W
`define TB_LOW_W 9
`endif
`ifndef TB_TIMEOUT
`define TB_TIMEOUT 50000000
`endif
`ifndef PAYN_M
`define PAYN_M 8                      // positions per lane: 8 (K16/M8) or 16 (K8/M16)
`endif
`ifndef PAYN_DRAIN
`define PAYN_DRAIN 0                  // drain: 0 in-tile chain, 1 drain register (payn_array.sv)
`endif
`ifndef PAYN_DUT
`define PAYN_DUT payn_array           // netlist top name (GL_SIM)
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif
`ifndef TB_RESET_SETTLE
`define TB_RESET_SETTLE 0            // default of +RESET_SETTLE
`endif

module Top;
    localparam int M = `PAYN_M;
    localparam int K = 128 / M;
    localparam int CYCLES = 128 / M;           // cycles per 128-sample block
    localparam int PB = 6 - $clog2(K);         // block phase bits
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = `TB_OWIDTH;
    localparam int LOW_W = `TB_LOW_W;
    localparam int MAX_BLK = `TB_MAX_BLK;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
    localparam int MAX_PRINT = 8;
    localparam int MAX_SEG = 64;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic block_start = 1'b0, slice_start = 1'b0;
    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*WIDTH-1:0]   a_len_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;
    // INT ports
    logic int_mode = 1'b0, int_prec = 1'b0, ring_in = 1'b0;
    logic [N_H*K*M-1:0] a_raw_in = '0;
    logic [N_W*K*M-1:0] w_raw_in = '0;
    logic [63:0] int_out;
    // Drain register ports (DRAIN = 1 builds; unused and 0 with the in-tile chain).
    localparam int DRAIN = `PAYN_DRAIN;
    localparam int DRW = (N_H / 2) * N_W * OWIDTH;
    logic drain_in = 1'b0;
    logic [DRW-1:0] dr_out;
    logic dr_out_valid;
    logic [DRW-1:0] dr_in_east = '0;           // one PE: no east neighbour
    logic dr_in_east_valid = 1'b0;
    logic int_out_valid;

    ClkUtils #(.TIMEOUT(`TB_TIMEOUT)) clk_utils (.clk, .reset, .timeout);

    always @(posedge timeout) $fatal(1, "[TIMEOUT] PaYN array bench");

`ifdef GL_SIM
    `PAYN_DUT dut (.*);
`else
    payn_array #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W), .DRAIN(DRAIN)
    ) dut (.*);
`endif

`ifdef GL_SIM
    initial begin
`ifndef NO_SDF
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
`endif
    end
`endif

    //------------------------------------------------------------ options --
    string bench_mode = "sc";
    bit opt_full, opt_gaps, opt_rng_gap_low, opt_mac_exact, opt_loose;
    bit opt_stall, opt_rng_low_end, opt_junk_bus, opt_mid_reset;
    bit opt_no_call_ss, opt_no_slice_ss, opt_no_slice_start, opt_kill_drain_reset;
    bit neg_lane_rev, neg_ka_eq_b, neg_row_len_max;
    bit neg_len_128, neg_short, neg_drain_early, neg_next_early;
    bit neg_stall_nomac, neg_stray_load, opt_junk_ss;
    bit opt_int_junk;
    bit neg_sw_early_int, neg_sw_late_drop, neg_sw_no_zero_load, neg_sw_int_drop_early, neg_sw_no_reload;
    int sw_gap = 0;
    bit opt_rng_low_idle;
    int neg_short_last = 0;
    int drain_sample_late_ps = 0;                       // +DRAIN_SAMPLE_LATE_PS
    bit stall_edge [int unsigned];
    bit mac_kill [int unsigned];
    int total_stalls = 0, total_stray = 0;

    //------------------------------------------------------------- golden --
    logic [31:0] cfg_m   [8];
    // Per-block arrays, row-major: A [blk][h][k], W [blk][k][v], row length
    // [blk][h], tiles [blk][h][v].
    logic [7:0]  a_mag_m [MAX_BLK*N_H*K];
    logic [3:0]  a_sgn_m [MAX_BLK*N_H*K];
    logic [7:0]  w_mag_m [MAX_BLK*K*N_W];
    logic [3:0]  w_sgn_m [MAX_BLK*K*N_W];
    logic [7:0]  len_m   [MAX_BLK*N_H];
    logic [3:0]  ss_m    [MAX_BLK];
    logic [3:0]  cs_m    [MAX_BLK];
    logic [3:0]  ph_m    [MAX_BLK];
    logic [7:0]  cy_m    [MAX_BLK];           // up to 128/M cycles (16 at M8)
    logic [3:0]  dr_m    [MAX_BLK];
    logic [7:0]  ka_m    [MAX_BLK*N_H*K];
    logic [31:0] accb_m  [MAX_BLK*N_H*N_W];
    logic [31:0] acce_m  [MAX_BLK*N_H*N_W];

    int n_blk, n_drn;

    task automatic load_case(input string dir);
        $readmemh({dir, "/cfg.mem"}, cfg_m, 0, 6);
        n_blk = int'(cfg_m[0]);
        n_drn = int'(cfg_m[1]);
        if (cfg_m[2] != N_H || cfg_m[3] != N_W || cfg_m[4] != K || cfg_m[5] != M)
            $fatal(1, "[BENCH] %s: shape %0d x %0d, %0d lanes x %0d positions; bench is %0d x %0d, %0d x %0d",
                   dir, cfg_m[2], cfg_m[3], cfg_m[4], cfg_m[5], N_H, N_W, K, M);
        if (n_blk < 1 || n_blk > MAX_BLK || n_drn < 1 || n_drn > n_blk)
            $fatal(1, "[BENCH] %s: %0d blocks / %0d drains (MAX_BLK %0d)", dir, n_blk, n_drn, MAX_BLK);
        $readmemh({dir, "/a_mag.mem"}, a_mag_m, 0, n_blk*N_H*K - 1);
        $readmemh({dir, "/a_sgn.mem"}, a_sgn_m, 0, n_blk*N_H*K - 1);
        $readmemh({dir, "/w_mag.mem"}, w_mag_m, 0, n_blk*K*N_W - 1);
        $readmemh({dir, "/w_sgn.mem"}, w_sgn_m, 0, n_blk*K*N_W - 1);
        $readmemh({dir, "/row_len.mem"}, len_m, 0, n_blk*N_H - 1);
        $readmemh({dir, "/slice_start.mem"}, ss_m, 0, n_blk - 1);
        $readmemh({dir, "/call_start.mem"}, cs_m, 0, n_blk - 1);
        $readmemh({dir, "/phase.mem"}, ph_m, 0, n_blk - 1);
        $readmemh({dir, "/cycles.mem"}, cy_m, 0, n_blk - 1);
        $readmemh({dir, "/drain.mem"}, dr_m, 0, n_blk - 1);
        $readmemh({dir, "/ka.mem"}, ka_m, 0, n_blk*N_H*K - 1);
        $readmemh({dir, "/acc_blk.mem"}, accb_m, 0, n_blk*N_H*N_W - 1);
        $readmemh({dir, "/acc_exp.mem"}, acce_m, 0, n_drn*N_H*N_W - 1);
    endtask

    //----------------------------------------------------------- counters --
    int drain_vals = 0, drain_bad = 0;
    int blk_vals = 0, blk_bad = 0;
    int ka_vals = 0, ka_bad = 0;
    int ph_vals = 0, ph_bad = 0;
    int total_blocks = 0, total_drains = 0, total_calls = 0;
    string case_name;
    int case_idx = 0;

    //------------------------------------------------------- edge counter --
    // edge_n = posedges so far; at a negedge the upcoming edge is edge_n + 1,
    // and in a posedge process (before the nonblocking update) the current
    // edge is edge_n + 1 as well.
    int unsigned edge_n = 0;
    always @(posedge clk) edge_n <= edge_n + 1;

    bit run_active = 1'b0;
    bit mac_edge [int unsigned];

    always @(negedge clk) begin
        if (run_active) begin
            if (opt_mac_exact)
                mac_en = mac_edge.exists(edge_n + 1);
            else
                mac_en = 1'b1;
        end
        if (mac_edge.exists(edge_n + 1))
            mac_edge.delete(edge_n + 1);
        if (mac_kill.exists(edge_n + 1)) begin
            if (run_active) mac_en = 1'b0;
            mac_kill.delete(edge_n + 1);
        end
    end

    //------------------------------------------------------------ INT junk --
    // Random INT inputs while int_mode is low (SC segments), from an own
    // xorshift32 so the bench's $urandom stream is untouched.
    bit sc_int_junk_on = 1'b0;
    int unsigned jx = 32'h2545_F491;
    function automatic int unsigned jrand();
        jx ^= jx << 13;
        jx ^= jx >> 17;
        jx ^= jx << 5;
        return jx;
    endfunction
    int unsigned junk_edges = 0;
    always @(negedge clk) begin
        if (sc_int_junk_on && int_mode === 1'b0) begin
            for (int i = 0; i < N_H*K*M; i += 32) a_raw_in[i +: 32] = jrand();
            for (int i = 0; i < N_W*K*M; i += 32) w_raw_in[i +: 32] = jrand();
            int_prec = jrand() & 1;
            ring_in = jrand() & 1;
            junk_edges++;
        end
    end

`ifndef GL_SIM
    //------------------------------------------- hierarchical observation --
    logic signed [OWIDTH-1:0] tile_acc [N_H][N_W];
    for (genvar h = 0; h < N_H; h++) begin : g_peek_row
        for (genvar v = 0; v < N_W; v++) begin : g_peek_col
            assign tile_acc[h][v] = dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_out;
        end
    end

    // NEG_KA_EQ_B: the naive encoder kA = min(b, L) in place of the closed form.
    logic [N_H*K*WIDTH-1:0] neg_ka;
    for (genvar h = 0; h < N_H; h++) begin : g_neg_row
        for (genvar k = 0; k < K; k++) begin : g_neg_lane
            logic [7:0] nb, nl;
            assign nb = dut.u_peripheral.a_binary_q[(h*K + k)*WIDTH +: WIDTH];
            assign nl = dut.u_peripheral.a_len_q[h*WIDTH +: WIDTH];
            assign neg_ka[(h*K + k)*WIDTH +: WIDTH] = (nb < nl) ? nb : nl;
        end
    end
    initial begin
        #0;
        if ($test$plusargs("NEG_KA_EQ_B"))
            force dut.u_peripheral.ka_flat = neg_ka;
        // Model of an edge without the structural slice restart: only
        // slice_start resets the phase.
        if ($test$plusargs("KILL_DRAIN_RESET"))
            force dut.u_rng.drain_seen = 1'b0;
    end

`endif

    //-------------------------------------------------------- block peeks --
    typedef struct { int unsigned at; int b; } peek_t;
    peek_t peek_q [$];

    task automatic check_block(input int b);
`ifndef GL_SIM
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) begin
                logic signed [31:0] exp_v;
                exp_v = $signed(accb_m[(b*N_H + h)*N_W + v]);
                blk_vals++;
                if (tile_acc[h][v] !== OWIDTH'(exp_v)) begin
                    blk_bad++;
                    if (blk_bad <= MAX_PRINT)
                        $display("[BLOCK] %s block %0d tile (%0d,%0d): %0d, expected %0d",
                                 case_name, b, h, v, tile_acc[h][v], exp_v);
                end
            end
`endif
    endtask

    always @(negedge clk) begin
        while (peek_q.size() > 0 && peek_q[0].at <= edge_n) begin
            if (peek_q[0].at == edge_n)
                check_block(peek_q[0].b);
            void'(peek_q.pop_front());
        end
    end

    //------------------------------------------------------------- drains --
    typedef struct { int unsigned d0; int di; } drain_t;
    drain_t drain_q [$];
    bit drain_busy = 1'b0;
    int unsigned drain_last_edge = 0;     // last shift edge of the drain in flight / last drain
    bit early_int_arm = 1'b0;             // NEG_SW_EARLY_INT on the case's last drain

    initial begin
        drain_t dr;
        logic signed [OWIDTH-1:0] got [N_H][N_W];
        forever begin
            wait (drain_q.size() > 0);
            dr = drain_q.pop_front();
            drain_busy = 1'b1;
            if (DRAIN == 1) begin
                // drain_in on D0-1: half 0 (tile rows 0-3) loaded into dr_out
                // on D0, half 1 on D0+1.  The case ends one edge later: half 1
                // is read up to just before D0+2 (DRAIN_SAMPLE_LATE_PS), and the
                // compare must finish before the next case loads its expected
                // values.
                drain_last_edge = dr.d0 + 2;
                while (edge_n + 1 < dr.d0 - 1) @(negedge clk);
                drain_in = 1'b1;
                @(negedge clk);
                drain_in = 1'b0;
                for (int hf = 0; hf < 2; hf++) begin
                    @(negedge clk);              // edge D0 + hf has happened
                    if (drain_sample_late_ps != 0) #(PERIOD / 2.0 - drain_sample_late_ps / 1000.0);
                    if (dr_out_valid !== 1'b1) begin
                        drain_bad++;
                        $display("[CHECK] %s drain %0d half %0d: dr_out_valid %b after edge %0d",
                                 case_name, dr.di, hf, dr_out_valid, edge_n);
                    end
                    for (int h = 0; h < N_H / 2; h++)
                        for (int v = 0; v < N_W; v++)
                            got[hf*(N_H/2) + h][v] = dr_out[(h*N_W + v)*OWIDTH +: OWIDTH];
                end
            end else begin
            drain_last_edge = dr.d0 + N_W - 1;
            while (edge_n + 1 < dr.d0) @(negedge clk);
            acc_in_west = '0;
            for (int s = 0; s < N_W; s++) begin
                if (drain_sample_late_ps == 0) begin
                    for (int h = 0; h < N_H; h++)
                        got[h][N_W-1-s] = acc_out_east[h*OWIDTH +: OWIDTH];
                end else begin
                    // read drain_sample_late_ps before the shift edge
                    // (this negedge + PERIOD/2); done before the loop's next negedge.
                    fork
                        automatic int ss = s;
                        begin
                            #(PERIOD / 2.0 - drain_sample_late_ps / 1000.0);
                            for (int h = 0; h < N_H; h++)
                                got[h][N_W-1-ss] = acc_out_east[h*OWIDTH +: OWIDTH];
                        end
                    join_none
                end
                shift_in = 1'b1;
                if (s == N_W - 1 && early_int_arm && dr.di == n_drn - 1)
                    int_mode = 1'b1;              // NEG_SW_EARLY_INT: int_mode high on the last SC drain edge
                @(negedge clk);
            end
            shift_in = 1'b0;
            end
            for (int h = 0; h < N_H; h++)
                for (int v = 0; v < N_W; v++) begin
                    logic signed [31:0] exp_v;
                    exp_v = $signed(acce_m[(dr.di*N_H + h)*N_W + v]);
                    drain_vals++;
                    if (got[h][v] !== OWIDTH'(exp_v)) begin
                        drain_bad++;
                        if (drain_bad <= MAX_PRINT)
                            $display("[CHECK] %s drain %0d (%0d,%0d): %0d, expected %0d",
                                     case_name, dr.di, h, v, got[h][v], exp_v);
                    end
                end
            total_drains++;
            drain_busy = 1'b0;
        end
    end

    // DRAIN=1: edges with a valid dr_out (pre-edge), every mode.
    int dr_valid_edges = 0;
    always @(posedge clk)
        if (DRAIN == 1 && reset === 1'b0 && dr_out_valid === 1'b1) dr_valid_edges++;

    //---------------------------------------------------------- stimulus --
    int unsigned cur_end = 0;          // last advance edge (B+C) of the running block
    bit cur_drain = 1'b0;              // the running block ends a slice (a drain follows)
    bit neg_rng_low_end_drain = 1'b0;  // DRAIN=1: RNG_LOW_END on slice-ending blocks too
    bit first_block_of_run = 1'b1;
    bit first_block_after_int = 1'b0;  // NEG_SW_NO_RELOAD

    task automatic idle_controls();
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        block_start = 1'b0;
        slice_start = 1'b0;
        if (edge_n + 1 <= cur_end)
            // DRAIN=1: RNG_LOW_END skips slice-ending blocks (it would repeat a
            // live cycle onto the half-0 read edge) unless NEG_RNG_LOW_END_DRAIN.
            rng_en = !stall_edge.exists(edge_n + 1) &&
                     !(opt_rng_low_end && edge_n + 1 == cur_end &&
                       !(DRAIN == 1 && cur_drain && !neg_rng_low_end_drain));
        else if (opt_rng_low_idle)               // RNG_LOW_IDLE: the counter holds after the block
            rng_en = 1'b0;
        else if (!(opt_gaps && opt_rng_gap_low))
            rng_en = 1'b1;
        else
            rng_en = 1'($urandom & 1);
        if (opt_junk_ss) slice_start = 1'($urandom & 1);
        if (opt_junk_bus) begin
            for (int i = 0; i < N_H*K; i++) begin
                a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
                a_signs_in[i] = 1'($urandom);
            end
            for (int i = 0; i < N_W*K; i++) begin
                w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
                w_signs_in[i] = 1'($urandom);
            end
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'($urandom);
        end
        if (neg_stray_load && $urandom_range(0, 15) == 0) begin
            // A legal-valued load pair with no restart: only the operands change.
            total_stray++;
            if ($urandom & 1) begin
                for (int i = 0; i < N_H*K; i++) begin
                    a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(0, 128));
                    a_signs_in[i] = 1'($urandom);
                end
                for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'($urandom_range(1, 128));
                load_a = 1'b1;
                load_a_sign = 1'b1;
            end else begin
                for (int i = 0; i < N_W*K; i++) begin
                    w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(0, 128));
                    w_signs_in[i] = 1'($urandom);
                end
                load_w = 1'b1;
                load_w_sign = 1'b1;
            end
        end
    endtask

    task automatic drive_block(input int b);
        int max_len;
        bit ss;
        max_len = 0;
        for (int h = 0; h < N_H; h++)
            if (int'(len_m[b*N_H + h]) > max_len) max_len = int'(len_m[b*N_H + h]);
        for (int h = 0; h < N_H; h++) begin
            int len;
            len = int'(len_m[b*N_H + h]);
            if (neg_row_len_max) len = max_len;
            if (neg_len_128) len = 128;
            a_len_in[h*WIDTH +: WIDTH] = WIDTH'(len);
            for (int k = 0; k < K; k++) begin
                int kk;
                kk = neg_lane_rev ? (K - 1 - k) : k;
                a_binary_in[(h*K + kk)*WIDTH +: WIDTH] = a_mag_m[(b*N_H + h)*K + k];
                a_signs_in[h*K + kk] = a_sgn_m[(b*N_H + h)*K + k][0];
            end
        end
        for (int k = 0; k < K; k++) begin
            int kk;
            kk = neg_lane_rev ? (K - 1 - k) : k;
            for (int v = 0; v < N_W; v++) begin
                w_binary_in[(v*K + kk)*WIDTH +: WIDTH] = w_mag_m[(b*K + k)*N_W + v];
                w_signs_in[v*K + kk] = w_sgn_m[(b*K + k)*N_W + v][0];
            end
        end
        ss = ss_m[b][0];
        if (opt_no_call_ss && cs_m[b][0] && !first_block_of_run) ss = 1'b0;
        if (opt_no_slice_ss) ss = cs_m[b][0];
        if (opt_no_slice_start) ss = 1'b0;
        slice_start = ss;
        block_start = 1'b1;
        load_a = 1'b1;
        load_w = 1'b1;
        load_a_sign = 1'b1;
        load_w_sign = 1'b1;
        if (neg_sw_no_reload && first_block_after_int) begin
            load_w = 1'b0;                       // NEG_SW_NO_RELOAD: W keeps the INT zero magnitudes
            load_w_sign = 1'b0;
        end
        first_block_after_int = 1'b0;
        if (opt_gaps) rng_en = 1'($urandom & 1);   // don't-care on the restart edge
        first_block_of_run = 1'b0;
    endtask

    task automatic check_load(input int b);
`ifndef GL_SIM
        ph_vals++;
        if (dut.phase !== PB'(ph_m[b])) begin
            ph_bad++;
            if (ph_bad <= MAX_PRINT)
                $display("[PHASE] %s block %0d: phase register %0d, expected %0d", case_name, b, dut.phase, ph_m[b]);
        end
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++) begin
                ka_vals++;
                if (dut.u_peripheral.ka_flat[(h*K + k)*WIDTH +: WIDTH] !== ka_m[(b*N_H + h)*K + k]) begin
                    ka_bad++;
                    if (ka_bad <= MAX_PRINT)
                        $display("[KA] %s block %0d row %0d lane %0d: %0d, expected %0d", case_name, b, h, k,
                                 dut.u_peripheral.ka_flat[(h*K + k)*WIDTH +: WIDTH], ka_m[(b*N_H + h)*K + k]);
                end
            end
`endif
    endtask

    task automatic run_case(input string dir);
        int unsigned next_free, B, D0;
        int C, di, gap, ns, slots, nst;
        load_case(dir);
        case_name = dir;
        next_free = edge_n + 1;
        di = 0;
        for (int b = 0; b < n_blk; b++) begin
            C = int'(cy_m[b]);
            if (C < 1 || C > CYCLES) $fatal(1, "[BENCH] %s block %0d: cycles %0d", dir, b, C);
            if (opt_full || neg_len_128) C = CYCLES;
            if (neg_short && C > 1) C = C - 1;
            if (neg_short_last > 0 && b == n_blk - 1)   // NEG_SHORT_LAST
                C = (C > neg_short_last) ? C - neg_short_last : 1;
            gap = opt_gaps ? $urandom_range(0, 3) : 0;
            B = ((edge_n + 1 > next_free) ? edge_n + 1 : next_free) + gap;
            while (edge_n + 1 < B) begin
                idle_controls();
                @(negedge clk);
            end
            drive_block(b);
            // Stalls: ns of the C-1+ns edges B+1 .. B+C+ns-1 hold the counter;
            // each kills the MAC two edges later (the cycle's second copy).
            ns = (opt_stall || neg_stall_nomac) ? $urandom_range(0, 2) : 0;
            slots = C - 1 + ns;
            nst = ns;
            for (int i = 1; i <= slots; i++)
                if (nst > 0 && $urandom_range(1, slots - i + 1) <= nst) begin
                    stall_edge[B + i] = 1'b1;
                    if (!neg_stall_nomac) mac_kill[B + i + 2] = 1'b1;
                    nst--;
                    total_stalls++;
                end
            C = C + ns;                          // block span in edges from here on
            for (int unsigned e = B + 2; e <= B + C + 1; e++) mac_edge[e] = 1'b1;
            cur_end = B + C;
            cur_drain = dr_m[b][0];
            peek_q.push_back('{B + C + 1, b});
            if (dr_m[b][0]) begin
                D0 = B + C + 2 + (opt_loose ? $urandom_range(0, 3) : 0);
                if (neg_drain_early) D0 = D0 - 1;
                drain_q.push_back('{D0, di});
                di++;
                // DRAIN=1: the next slice may load on the half-0 read edge D0.
                next_free = ((DRAIN == 1) ? D0 : D0 + N_W - 2) + (opt_loose ? $urandom_range(0, 3) : 0);
                if (neg_next_early) next_free = next_free - 1;
            end else begin
                next_free = B + C;
            end
            total_blocks++;
            if (cs_m[b][0]) total_calls++;
            @(negedge clk);                      // edge B has happened
            check_load(b);
            idle_controls();
        end
        if (di != n_drn) $fatal(1, "[BENCH] %s: %0d drains scheduled, %0d expected", dir, di, n_drn);
        // Deterministic tail: end on the negedge after the last drain's
        // last shift edge (and after the last block peek).
        while (drain_q.size() > 0 || (drain_busy && drain_last_edge > edge_n) || peek_q.size() > 0) begin
            idle_controls();
            @(negedge clk);
        end
    endtask

    //======================================================== INT part ==
    // The bit-plane single-PE schedule, as a segment that starts on the
    // current negedge (edge 0 = the next posedge).
    int E0 = 4;                                  // first data capture edge (relative)
    int BA = 8, BW = 8, L = 128, MROWS = 1, NCOLS = 8, MODE_AT = -1;
    bit junk = 1'b0, neg_no_ring = 1'b0, neg_prec = 1'b0;
    bit lap_ring_only = 1'b0, neg_ring_stray = 1'b0, neg_mag = 1'b0;
    int LAP_LEN = 1;
    bit neg_no_bubble = 1'b0, neg_ring_stray_mid = 1'b0;
    bit park_cyc0 = 1'b0, neg_mag_a = 1'b0, neg_mag_w = 1'b0, junk_scstrobe = 1'b0;
    int int_len_dc = -1;                         // +INT_LEN_DC
    logic [N_H*K-1:0] a_sign_word;
    int NB, ROWS_PE, NIG, NJG, NBLK, PASS_LEN, LAST_LEN, BLK_LEN;
    int E_DATA_END, E_END;

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]

    // Per INT segment bookkeeping.
    int n_seg = 0;
    integer seg_trace [MAX_SEG];
    integer seg_sched [MAX_SEG];
    int seg_ndrain [MAX_SEG];
    int seg_ncomb [MAX_SEG];
    int seg_nblk [MAX_SEG];
    string seg_dir [MAX_SEG];
    int seg_base [MAX_SEG];

    // Drain / combiner monitor: scheduled drain edges (absolute) -> what they drain.
    typedef struct { int seg; int blk; int t; } cap_t;
    cap_t drain_expect [int unsigned];
    cap_t comb_expect [int unsigned];
    bit int_mon_on = 1'b0;
    int comb_unexpected = 0;

    always @(posedge clk) begin
        int unsigned a;
        cap_t c;
        a = edge_n + 1;
        if (drain_expect.exists(a)) begin
            c = drain_expect[a];
            drain_expect.delete(a);
            if (c.t == 0) $fwrite(seg_sched[c.seg], "DRAIN_START %0d %0d\n", c.blk, int'(a) - seg_base[c.seg]);
            if ($isunknown(acc_out_east))
                $fatal(1, "[X-FAIL] drained column X: segment %0d block %0d step %0d", c.seg, c.blk, c.t);
            $fwrite(seg_trace[c.seg], "D %0d %0d", c.blk, c.t);
            for (int h = 0; h < N_H; h++)
                $fwrite(seg_trace[c.seg], " %0d", $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
            $fwrite(seg_trace[c.seg], "\n");
            seg_ndrain[c.seg]++;
            comb_expect[a] = c;
        end
        if (int_mon_on) begin
            if ($isunknown(int_out_valid))
                $fatal(1, "[X-FAIL] int_out_valid X at edge %0d", a);
            if (int_out_valid !== comb_expect.exists(a - 2))
                $fatal(1, "[TIMING-FAIL] int_out_valid=%0b at edge %0d, expected %0b",
                       int_out_valid, a, comb_expect.exists(a - 2));
            if (int_out_valid) begin
                c = comb_expect[a - 2];
                comb_expect.delete(a - 2);
                if ($isunknown(int_out))
                    $fatal(1, "[X-FAIL] int_out X: segment %0d block %0d step %0d", c.seg, c.blk, c.t);
                $fwrite(seg_trace[c.seg], "C %0d %0d %0d %0d\n", c.blk, c.t,
                        $signed(int_out[31:0]), $signed(int_out[63:32]));
                seg_ncomb[c.seg]++;
            end
        end
    end

`ifndef GL_SIM
    // Lap coverage (RTL only): lap edges (ring_q high) whose
    // tiles fold a pending carry / borrow into the doubled value.
    int cov_lap_edges = 0, cov_tile_laps = 0, cov_pending_carry = 0, cov_pending_borrow = 0;
    for (genvar h = 0; h < N_H; h++) begin : g_cov_r
        for (genvar v = 0; v < N_W; v++) begin : g_cov_c
            always @(posedge clk)
                if (!reset && dut.u_pe.ring_q === 1'b1) begin
                    cov_tile_laps++;
                    if (dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_carry === 1'b1)
                        cov_pending_carry++;
                    if (dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_borrow === 1'b1)
                        cov_pending_borrow++;
                end
        end
    end
    always @(posedge clk)
        if (!reset && dut.u_pe.ring_q === 1'b1) cov_lap_edges++;
    // INT samples consumed with the SC streams silent (the [INT-CONTRACT] check
    // in the top stops the run otherwise): counted for the report.
    int int_mac_samples = 0;
    always @(posedge clk)
        if (!reset && dut.int_mode_q2 === 1'b1 && dut.mac_core === 1'b1) int_mac_samples++;
`endif

    function automatic void decode(input int e, output int blk, output int pi, output int u);
        int r;
        r = e - E0;
        blk = r / BLK_LEN;
        r = r % BLK_LEN;
        pi = r / PASS_LEN;
        if (pi > BW - 1) pi = BW - 1;           // the final pass is LAST_LEN long
        u = r - pi*PASS_LEN;
    endfunction

    // The tile array shifts at P_e (ring lap or drain).  u = 0 closes the
    // previous pass's lap (pi >= 1; none for LAP_LEN = 0) or the previous
    // block's drain (pi = 0); a non-final pass laps on its last LAP_LEN-1
    // edges, the final pass drains on u >= NB+1.
    function automatic bit core_shift_at(input int e);
        int blk, pi, u;
        if (e <= E0 || e > E_END) return 1'b0;
        decode(e, blk, pi, u);
        if (u == 0) return (pi == 0) || (LAP_LEN >= 1);
        if (pi < BW - 1) return (LAP_LEN >= 1) && (u >= PASS_LEN - LAP_LEN + 1);
        return u >= NB + 1;
    endfunction

    function automatic bit ring_at(input int e);
        int blk, pi, u;
        if (!core_shift_at(e)) return 1'b0;
        decode(e, blk, pi, u);
        if (u == 0) return pi >= 1;     // closes the lap after pass pi-1
        return pi < BW - 1;
    endfunction

    function automatic bit drain_at(input int e);
        return core_shift_at(e) && !ring_at(e);
    endfunction

    function automatic void drain_slot(input int e, output int bd, output int t);
        int blk, pi, u;
        decode(e, blk, pi, u);
        if (u == 0) begin
            bd = blk - 1;
            t = N_W - 1;
        end else begin
            bd = blk;
            t = u - NB - 1;
        end
    endfunction

    task automatic set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, pi, u, ig, jg, q, i, p, j, x;
        a_next = '0;
        w_next = '0;
        if (e >= E0 && e < E_DATA_END) begin
            decode(e, blk, pi, u);
            if (u < NB) begin
                ig = blk / NJG;
                jg = blk % NJG;
                q = BW - 1 - pi;
                for (int h = 0; h < N_H; h++) begin
                    i = ig*ROWS_PE + h / BA;
                    p = h % BA;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[i*L + x][p];
                        end
                end
                for (int v = 0; v < N_W; v++) begin
                    j = jg*N_W + v;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            w_next[(v*K + k)*M + m] = w_mem[j*L + x][q];
                        end
                end
            end
        end
        a_raw_in = a_next;
        w_raw_in = w_next;
    endtask

    task automatic set_signs(input int e);
        int blk, pi, u;
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
        if (e + 1 >= E0 && e + 1 < E_DATA_END) begin
            decode(e + 1, blk, pi, u);
            if (u == 0) begin
                w_signs_in = (pi == 0) ? '1 : '0;
                load_w = 1'b1;
                load_w_sign = 1'b1;
                if (e + 1 == E0) begin
                    a_signs_in = a_sign_word;
                    load_a = 1'b1;
                    load_a_sign = 1'b1;
                end
            end
        end
        // Junk loads only on INT edges: before int_mode rises (MODE_AT
        // >= 0) the edge is an SC edge, where a load without block_start is an
        // SC contract error.
        if (junk && int_mode) begin
            if (!load_a && ($urandom & 1)) begin
                load_a = 1'b1;
                a_signs_in = {$urandom, $urandom};
            end
            if (!load_w && ($urandom & 1)) begin
                load_w = 1'b1;
                w_signs_in = {$urandom, $urandom};
            end
        end
        if (neg_mag) begin
            load_a = 1'b1;
            load_w = 1'b1;
        end
    endtask

    // Magnitude lines: zero on every edge (the zero-load on INT
    // entry and every INT load); under JUNK random on the edges that do not
    // load that side; NEG_MAG random everywhere; NEG_MAG_A / NEG_MAG_W random
    // 1..128 on that side's loads; NEG_SW_NO_ZERO_LOAD leaves them as the SC
    // segment left them.
    task automatic set_binary();
        if (neg_sw_no_zero_load) return;
        if (neg_mag || (junk && !load_a))
            for (int n = 0; n < N_H*K*WIDTH; n++) a_binary_in[n] = $urandom & 1;
        else if (neg_mag_a && load_a)
            for (int i = 0; i < N_H*K; i++) a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(1, 128));
        else
            a_binary_in = '0;
        if (neg_mag || (junk && !load_w))
            for (int n = 0; n < N_W*K*WIDTH; n++) w_binary_in[n] = $urandom & 1;
        else if (neg_mag_w && load_w)
            for (int i = 0; i < N_W*K; i++) w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(1, 128));
        else
            w_binary_in = '0;
    endtask

    // SC-only inputs in INT mode.
    task automatic set_af_side(input int e);
        block_start = park_cyc0 && (e == 1);
        slice_start = 1'b0;
        if (junk_scstrobe && int_mode) begin
            block_start = $urandom & 1;
            slice_start = $urandom & 1;
        end
        if (park_cyc0)
            rng_en = 1'b0;
        else if (junk)
            rng_en = $urandom & 1;
        else
            rng_en = neg_mag;
        if (junk)
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'($urandom);
        else if (int_len_dc >= 0)
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'(int_len_dc);
        else
            a_len_in = '0;
        if (neg_mag_a && load_a)
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = 8'd128;
    endtask

    task automatic set_west_junk(input int e);
        if (drain_at(e))
            acc_in_west = '0;
        else
            for (int n = 0; n < N_H*OWIDTH; n++) acc_in_west[n] = $urandom & 1;
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

    // Derived schedule constants and range checks for the current INT config.
    task automatic int_config();
        if (LAP_LEN < 0 || LAP_LEN > 64) $fatal(1, "LAP_LEN=%0d out of range", LAP_LEN);
        if (neg_no_bubble && LAP_LEN < 1) $fatal(1, "NEG_NO_BUBBLE needs LAP_LEN >= 1");
        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        if (park_cyc0 && !(MODE_AT >= 2 && MODE_AT <= E0 - 1))
            $fatal(1, "PARK_CYC0 needs MODE_AT 2..%0d (an SC block_start on edge 1)", E0 - 1);
        if (neg_mag_a && !park_cyc0) $fatal(1, "NEG_MAG_A needs PARK_CYC0 (after reset the counter parks in IDLE, where A is 0)");
        NB = L / (K*M);
        ROWS_PE = N_H / BA;
        if (MROWS < ROWS_PE || MROWS % ROWS_PE != 0 || NCOLS < N_W || NCOLS % N_W != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", ROWS_PE, N_W);
        if ((longint'(1) << (BW-1)) * L >= (longint'(1) << (OWIDTH-1)))
            $fatal(1, "L=%0d can overflow the %0d-bit accumulator", L, OWIDTH);
        NIG = MROWS / ROWS_PE;
        NJG = NCOLS / N_W;
        NBLK = NIG * NJG;
        PASS_LEN = NB + LAP_LEN - (neg_no_bubble ? 1 : 0);
        LAST_LEN = NB + N_W;
        BLK_LEN = (BW - 1) * PASS_LEN + LAST_LEN;
        if (neg_ring_stray_mid && BW < 2) $fatal(1, "NEG_RING_STRAY_MID needs BW >= 2");
        E_DATA_END = E0 + NBLK*BLK_LEN;
        E_END = E_DATA_END;                      // final drain edge
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);
    endtask

    // One INT segment, starting on the current negedge (edge 0 = next posedge),
    // ending on the negedge after edge E_END + tail.  int_mode is raised at
    // MODE_AT (or already high) and left high.
    task automatic run_int_segment(input string dir, input int tail);
        int seg;
        string pfx;
        if (n_seg >= MAX_SEG) $fatal(1, "more than %0d INT segments", MAX_SEG);
        seg = n_seg++;
        pfx = (dir == "") ? "" : {dir, "/"};
        seg_dir[seg] = dir;
        seg_nblk[seg] = NBLK;
        seg_ndrain[seg] = 0;
        seg_ncomb[seg] = 0;
        read_hex({pfx, "bpt_a.hex"}, MROWS*L, a_mem);
        read_hex({pfx, "bpt_w.hex"}, NCOLS*L, w_mem);
        seg_trace[seg] = $fopen({pfx, "bpt_trace.txt"}, "w");
        if (seg_trace[seg] == 0) $fatal(1, "cannot open %sbpt_trace.txt", pfx);
        seg_sched[seg] = $fopen({pfx, "bpt_sched.txt"}, "w");
        if (seg_sched[seg] == 0) $fatal(1, "cannot open %sbpt_sched.txt", pfx);
        $fwrite(seg_sched[seg], "SCHED lap_len=%0d pass_len=%0d last_len=%0d blk_len=%0d nb=%0d bw=%0d nblk=%0d formula=%0d\n",
                LAP_LEN, PASS_LEN, LAST_LEN, BLK_LEN, NB, BW, NBLK, BW*NB + LAP_LEN*(BW-1) + N_W);
        $fwrite(seg_trace[seg], "BPTCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, int_prec, junk, neg_no_ring, neg_prec,
                lap_ring_only, neg_mag, MODE_AT, neg_ring_stray);
        seg_base[seg] = int'(edge_n) + 1;
        for (int e = 0; e <= E_END + tail; e++) begin
            if (e == MODE_AT) int_mode = 1'b1;
            if (neg_sw_int_drop_early && e == E_END) int_mode = 1'b0;
            set_raw(e);
            set_signs(e);
            set_binary();
            set_af_side(e);
            if (junk) set_west_junk(e);
            ring_in = (!neg_no_ring && ring_at(e + 1)) || (neg_ring_stray && e + 1 == E0 + 1) ||
                      (neg_ring_stray_mid && e + 1 == E0 + PASS_LEN + NB/2 + 1);
            shift_in = lap_ring_only ? drain_at(e) : core_shift_at(e);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            if (drain_at(e)) begin
                cap_t c;
                c.seg = seg;
                drain_slot(e, c.blk, c.t);
                drain_expect[edge_n + 1] = c;
            end
            @(posedge clk);                      // P_e
            @(negedge clk);
        end
        // Leave the INT-side strobes idle for whatever comes next (the next
        // edge may be an SC block_start).
        shift_in = 1'b0;
        ring_in = 1'b0;
        a_raw_in = '0;
        w_raw_in = '0;
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        block_start = 1'b0;
        slice_start = 1'b0;
        acc_in_west = '0;
    endtask

    //========================================================= abit part ==
    // +MODE=abit, the all-bits-in-time INT schedule (header, +MODE=abit).  No
    // other mode calls these tasks or reads these variables.
    int AB_NLEV, AB_NP, AB_NBLK, AB_D0, AB_BLK_NOM, AB_BLK_LEN, AB_FORMULA, AB_E_END, AB_N;
    int ab_lev_k [$];                            // processing order n -> level k = p + q
    int ab_pp [$], ab_pq [$], ab_ps [$], ab_pn [$];   // pass j: A bit p, W bit q, sign, level index n
    int ab_cap_blk [], ab_cap_pass [], ab_cap_u [];   // raw data captured at P_e (blk -1: zero planes)
    int ab_start_pass [];                        // pass whose first plane is captured at P_e (-1: none)
    bit ab_lap [];                               // P_e is a lap edge (ring_q high; ring_in at P_{e-1})
    int ab_drn_blk [], ab_drn_t [];              // P_e is drain step t of block ab_drn_blk (-1: none)
    int ab_neg_no_lap = -1, ab_neg_extra_lap = -1, ab_neg_sign = 0, ab_neg_order = 0;
    bit ab_neg_no_bubble = 1'b0, ab_neg_drain_early = 0, ab_neg_overlap = 1'b0;

    // Pass order, per-block slot list and the per-edge schedule of one segment.
    task automatic abit_config();
        int sl_kind [$], sl_pass [$], sl_u [$];   // slot: 0 data / 1 bubble, pass, chunk
        bit sl_lap [$];
        bit lap_next;
        int first_in_level, base, e;
        if (BA < 2 || BA > 8 || BW < 2 || BW > 8) $fatal(1, "[BENCH] BA, BW must be 2..8 (got %0d, %0d)", BA, BW);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "[BENCH] L=%0d must be a positive multiple of %0d", L, K*M);
        if (MROWS < N_H || MROWS % N_H != 0 || NCOLS < N_W || NCOLS % N_W != 0)
            $fatal(1, "[BENCH] MROWS must be a multiple of %0d and NCOLS of %0d", N_H, N_W);
        // Worst case |C| = L * 2^(BA-1) * 2^(BW-1) must fit the signed OWIDTH-bit tile.
        if (longint'(L) * (longint'(1) << (BA + BW - 2)) > (longint'(1) << (OWIDTH-1)) - 1 &&
            !$test$plusargs("ABIT_RANGE_DATA"))
            $fatal(1, "[BENCH] L=%0d at BA=%0d BW=%0d can overflow the %0d-bit tile (worst case L*2^%0d)",
                   L, BA, BW, OWIDTH, BA + BW - 2);
        if (park_cyc0 && !(MODE_AT >= 2 && MODE_AT <= E0 - 1))
            $fatal(1, "[BENCH] PARK_CYC0 needs MODE_AT 2..%0d", E0 - 1);
        NB = L / (K*M);
        NIG = MROWS / N_H;
        NJG = NCOLS / N_W;
        AB_NBLK = NIG * NJG;
        AB_NLEV = BA + BW - 1;
        AB_NP = BA * BW;
        AB_FORMULA = BA*BW*NB + (BA + BW - 2) + N_W;     // + (P_R+P_C-2) = 0, 8*P_C = 8
        // Levels MSB first (NEG_ORDER=1: LSB first; 2: levels 1 and 2 of the order swapped).
        ab_lev_k.delete();
        for (int n = 0; n < AB_NLEV; n++) ab_lev_k.push_back(AB_NLEV - 1 - n);
        if (ab_neg_order == 1) ab_lev_k.reverse();
        if (ab_neg_order == 2) begin
            int tmp;
            if (AB_NLEV < 3) $fatal(1, "[BENCH] NEG_ORDER=2 needs 3 levels");
            tmp = ab_lev_k[1]; ab_lev_k[1] = ab_lev_k[2]; ab_lev_k[2] = tmp;
        end
        // Passes: level by level, A bit ascending inside a level.  Sign of pass
        // (p, q) = (p == BA-1) XOR (q == BW-1), applied on the W side (A sign 0).
        ab_pp.delete(); ab_pq.delete(); ab_ps.delete(); ab_pn.delete();
        for (int n = 0; n < AB_NLEV; n++)
            for (int p = 0; p < BA; p++) begin
                int q;
                q = ab_lev_k[n] - p;
                if (q < 0 || q >= BW) continue;
                ab_pp.push_back(p);
                ab_pq.push_back(q);
                ab_pn.push_back(n);
                if (ab_neg_sign == 1) ab_ps.push_back(q == BW - 1);   // NEG_SIGN=1: A sign term dropped
                else ab_ps.push_back((p == BA - 1) ^ (q == BW - 1));
            end
        if (ab_pp.size() != AB_NP) $fatal(1, "[BENCH] %0d passes, expected %0d", ab_pp.size(), AB_NP);
        if (ab_neg_sign == 2) ab_ps[AB_NP/2] = !ab_ps[AB_NP/2];      // NEG_SIGN=2: one pass flipped
        if (ab_neg_extra_lap >= AB_NLEV || ab_neg_no_lap >= AB_NLEV || ab_neg_no_lap == 0)
            $fatal(1, "[BENCH] NEG_NO_LAP must be 1..%0d, NEG_EXTRA_LAP 0..%0d", AB_NLEV - 1, AB_NLEV - 1);
        if (ab_neg_extra_lap >= 0) begin
            int np_lev;
            np_lev = 0;
            foreach (ab_pn[j]) np_lev += (ab_pn[j] == ab_neg_extra_lap);
            if (np_lev < 2) $fatal(1, "[BENCH] NEG_EXTRA_LAP=%0d: that level has %0d pass(es), needs 2", ab_neg_extra_lap, np_lev);
        end
        // Slots of one block: every pass NB data slots; before every level but
        // the first a bubble slot (the MAC on the lap edge is dropped), the lap
        // on the next level's first capture; after the last level one bubble
        // (the last MAC edge), then the drain.
        lap_next = 1'b0;
        for (int j = 0; j < AB_NP; j++) begin
            first_in_level = (j == 0) || (ab_pn[j] != ab_pn[j-1]);
            if (first_in_level && j > 0) begin
                if (!ab_neg_no_bubble) begin
                    sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);
                end
                lap_next = (ab_pn[j] != ab_neg_no_lap);               // NEG_NO_LAP: this level's lap dropped
            end
            if (!first_in_level && ab_pn[j] == ab_neg_extra_lap && ab_pn[j-1] == ab_neg_extra_lap &&
                (j < 2 || ab_pn[j-2] != ab_neg_extra_lap)) begin       // NEG_EXTRA_LAP: lap after the level's first pass
                if (!ab_neg_no_bubble) begin
                    sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);
                end
                lap_next = 1'b1;
            end
            for (int u = 0; u < NB; u++) begin
                sl_kind.push_back(0); sl_pass.push_back(j); sl_u.push_back(u);
                sl_lap.push_back(lap_next && u == 0);
            end
            lap_next = 1'b0;
        end
        if (!ab_neg_drain_early) begin
            sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);
        end
        AB_D0 = sl_kind.size();                  // first drain slot
        if (DRAIN == 1) begin
            AB_BLK_NOM = AB_D0 + 1;              // half-1 read edge = next block's slot 0
            AB_FORMULA = BA*BW*NB + (BA + BW - 2) + 2;
        end else
            AB_BLK_NOM = AB_D0 + N_W - 1;        // 8th drain edge = next block's slot 0
        AB_BLK_LEN = AB_BLK_NOM - (ab_neg_overlap ? 1 : 0);
        AB_E_END = E0 + (AB_NBLK - 1)*AB_BLK_LEN + AB_BLK_NOM;
        AB_N = AB_E_END + 8;
        ab_cap_blk = new[AB_N]; ab_cap_pass = new[AB_N]; ab_cap_u = new[AB_N];
        ab_start_pass = new[AB_N]; ab_lap = new[AB_N]; ab_drn_blk = new[AB_N]; ab_drn_t = new[AB_N];
        for (int i = 0; i < AB_N; i++) begin
            ab_cap_blk[i] = -1; ab_cap_pass[i] = -1; ab_cap_u[i] = -1; ab_start_pass[i] = -1;
            ab_lap[i] = 1'b0; ab_drn_blk[i] = -1; ab_drn_t[i] = -1;
        end
        for (int b = 0; b < AB_NBLK; b++) begin
            base = E0 + b*AB_BLK_LEN;
            for (int s = 0; s < AB_D0; s++) begin
                e = base + s;
                if (sl_lap[s]) ab_lap[e] = 1'b1;
                if (sl_kind[s] == 0) begin
                    ab_cap_blk[e] = b; ab_cap_pass[e] = sl_pass[s]; ab_cap_u[e] = sl_u[s];
                    if (sl_u[s] == 0) ab_start_pass[e] = sl_pass[s];
                end
            end
            for (int t = 0; t < ((DRAIN == 1) ? 2 : N_W); t++) begin   // DRAIN=1: t = half
                e = base + AB_D0 + t;
                if (ab_drn_blk[e] >= 0) $fatal(1, "[BENCH] two drains on edge %0d", e);
                ab_drn_blk[e] = b; ab_drn_t[e] = t;
            end
        end
    endtask

    function automatic bit abit_drain_at(input int e);
        return e >= 0 && e < AB_N && ab_drn_blk[e] >= 0;
    endfunction

    // DRAIN=1: segment edge e is a half-0 read edge.
    function automatic bit abit_rd0_at(input int e);
        return abit_drain_at(e) && ab_drn_t[e] == 0;
    endfunction

    // DRAIN=1: every valid dr_out of an abit segment, "Q 0 e v0..v31" (loaded
    // on segment edge e, read pre-edge at P_{e+1}).
    int ab_q_seg = -1, ab_items = 0;
    always @(posedge clk)
        if (DRAIN == 1 && ab_q_seg >= 0 && dr_out_valid === 1'b1) begin
            if ($isunknown(dr_out))
                $fatal(1, "[X-FAIL] dr_out X at edge %0d", edge_n);
            $fwrite(seg_trace[ab_q_seg], "Q 0 %0d", int'(edge_n) - seg_base[ab_q_seg]);
            for (int n = 0; n < (N_H/2)*N_W; n++)
                $fwrite(seg_trace[ab_q_seg], " %0d", $signed(dr_out[n*OWIDTH +: OWIDTH]));
            $fwrite(seg_trace[ab_q_seg], "\n");
            ab_items++;
        end

    function automatic bit abit_lap_at(input int e);
        return e >= 0 && e < AB_N && ab_lap[e];
    endfunction

    // Raw planes captured at P_e: tile row h = activation row ig*8 + h (bit p),
    // tile column v = weight column jg*8 + v (bit q).
    task automatic abit_set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, j, u, ig, jg, p, q, x;
        a_next = '0;
        w_next = '0;
        if (e >= 0 && e < AB_N && ab_cap_blk[e] >= 0) begin
            blk = ab_cap_blk[e]; j = ab_cap_pass[e]; u = ab_cap_u[e];
            ig = blk / NJG; jg = blk % NJG;
            p = ab_pp[j]; q = ab_pq[j];
            for (int h = 0; h < N_H; h++)
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = u*K*M + k*M + m;
                        a_next[(h*K + k)*M + m] = a_mem[(ig*N_H + h)*L + x][p];
                    end
            for (int v = 0; v < N_W; v++)
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = u*K*M + k*M + m;
                        w_next[(v*K + k)*M + m] = w_mem[(jg*N_W + v)*L + x][q];
                    end
        end
        a_raw_in = a_next;
        w_raw_in = w_next;
    endtask

    // W sign load one edge ahead of every pass start (the existing load_w_sign
    // wave; zero magnitudes); A signs 0, loaded once with the zero-load on entry.
    task automatic abit_set_signs(input int e);
        int j;
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
        if (e + 1 >= 0 && e + 1 < AB_N && ab_start_pass[e + 1] >= 0) begin
            j = ab_start_pass[e + 1];
            w_signs_in = ab_ps[j] ? '1 : '0;
            load_w = 1'b1;
            load_w_sign = 1'b1;
            if (e + 1 == E0) begin
                a_signs_in = '0;
                load_a = 1'b1;
                load_a_sign = 1'b1;
            end
        end
        if (junk && int_mode) begin                  // as set_signs: sign words that no pipe latches
            if (!load_a && ($urandom & 1)) begin
                load_a = 1'b1;
                a_signs_in = {$urandom, $urandom};
            end
            if (!load_w && ($urandom & 1)) begin
                load_w = 1'b1;
                w_signs_in = {$urandom, $urandom};
            end
        end
    endtask

    // One all-bits-in-time segment (edge 0 = next posedge), trace abit_trace.txt:
    //   ABITCFG BA BW L MROWS NCOLS NBLK NB E0 E_END BLK_LEN D0 FORMULA NLEV JUNK MODE_AT
    //           NEG_NO_LAP NEG_EXTRA_LAP NEG_SIGN NEG_ORDER NEG_NO_BUBBLE NEG_DRAIN_EARLY NEG_OVERLAP PARK_CYC0
    //   P e blk j p q sign    first capture of pass j (the sign the W wave loaded for it)
    //   K e blk j u           raw-plane capture (chunk u of pass j)
    //   L e                   lap edge (ring_in driven on e-1)
    //   X e blk t             drain step t (shift_in, acc_in_west = 0)
    //   M e                   first edge with mac_en high
    //   D blk t v0..v7 / C blk t lo hi   (the INT monitor: acc_out_east, combiner word)
    task automatic run_abit_segment(input int tail);
        int seg;
        cap_t c;
        if (n_seg >= MAX_SEG) $fatal(1, "more than %0d INT segments", MAX_SEG);
        seg = n_seg++;
        seg_dir[seg] = "abit";
        seg_nblk[seg] = AB_NBLK;
        seg_ndrain[seg] = 0;
        seg_ncomb[seg] = 0;
        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        seg_trace[seg] = $fopen("abit_trace.txt", "w");
        if (seg_trace[seg] == 0) $fatal(1, "cannot open abit_trace.txt");
        seg_sched[seg] = $fopen("abit_sched.txt", "w");
        if (seg_sched[seg] == 0) $fatal(1, "cannot open abit_sched.txt");
        $fwrite(seg_trace[seg], "ABITCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, AB_NBLK, NB, E0, AB_E_END, AB_BLK_LEN, AB_D0, AB_FORMULA, AB_NLEV,
                junk, MODE_AT, ab_neg_no_lap, ab_neg_extra_lap, ab_neg_sign, ab_neg_order,
                ab_neg_no_bubble, ab_neg_drain_early, ab_neg_overlap, park_cyc0, DRAIN);
        $fwrite(seg_sched[seg], "SCHED abit=1 blk_len=%0d d0=%0d nb=%0d ba=%0d bw=%0d nblk=%0d formula=%0d\n",
                AB_BLK_LEN, AB_D0, NB, BA, BW, AB_NBLK, AB_FORMULA);
        seg_base[seg] = int'(edge_n) + 1;
        ab_q_seg = seg;
        for (int e = 0; e <= AB_E_END + tail; e++) begin
            if (e == MODE_AT) int_mode = 1'b1;
            abit_set_raw(e);
            abit_set_signs(e);
            set_binary();
            set_af_side(e);
            if (junk) begin
                if (abit_drain_at(e)) acc_in_west = '0;
                else for (int n = 0; n < N_H*OWIDTH; n++) acc_in_west[n] = $urandom & 1;
            end
            ring_in = abit_lap_at(e + 1);
            if (DRAIN == 1) begin
                drain_in = abit_rd0_at(e + 1);   // one edge ahead of the half-0 read edge
                shift_in = 1'b0;
            end else
                shift_in = abit_drain_at(e);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            if (e == E0 + 1) $fwrite(seg_trace[seg], "M %0d\n", e);
            if (e < AB_N && ab_start_pass[e] >= 0)
                $fwrite(seg_trace[seg], "P %0d %0d %0d %0d %0d %0d\n", e, ab_cap_blk[e], ab_start_pass[e],
                        ab_pp[ab_start_pass[e]], ab_pq[ab_start_pass[e]], ab_ps[ab_start_pass[e]]);
            if (e < AB_N && ab_cap_blk[e] >= 0)
                $fwrite(seg_trace[seg], "K %0d %0d %0d %0d\n", e, ab_cap_blk[e], ab_cap_pass[e], ab_cap_u[e]);
            if (abit_lap_at(e)) $fwrite(seg_trace[seg], "L %0d\n", e);
            if (abit_drain_at(e)) begin
                $fwrite(seg_trace[seg], "X %0d %0d %0d\n", e, ab_drn_blk[e], ab_drn_t[e]);
                c.seg = seg;
                c.blk = ab_drn_blk[e];
                c.t = ab_drn_t[e];
                if (DRAIN != 1) drain_expect[edge_n + 1] = c;   // DRAIN=1: the Q monitor reads dr_out
            end
            @(posedge clk);                      // P_e
            @(negedge clk);
        end
        shift_in = 1'b0;
        ring_in = 1'b0;
        a_raw_in = '0;
        w_raw_in = '0;
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        block_start = 1'b0;
        slice_start = 1'b0;
        acc_in_west = '0;
    endtask

    //=========================================================== main ==
    int seed, reset_settle;

    function automatic void split_list(input string arg, ref string out [$]);
        int start;
        start = 0;
        for (int i = 0; i <= arg.len(); i++)
            if (i == arg.len() || arg[i] == ",") begin
                if (i > start) out.push_back(arg.substr(start, i - 1));
                start = i + 1;
            end
    endfunction

    function automatic int dut_contract();
`ifndef GL_SIM
        return dut.contract_errors;
`else
        return 0;
`endif
    endfunction

    task automatic finish_sc_result(input int n_cases);
        int contract;
        string extra;
        contract = dut_contract();
        extra = "";
        $display("RESULT cases=%0d calls=%0d blocks=%0d drains=%0d edges=%0d | drain values %0d bad %0d | block values %0d bad %0d | kA values %0d bad %0d | phase checks %0d bad %0d | contract %0d | stalls %0d stray loads %0d%s",
                 n_cases, total_calls, total_blocks, total_drains, edge_n, drain_vals, drain_bad,
                 blk_vals, blk_bad, ka_vals, ka_bad, ph_vals, ph_bad, contract, total_stalls, total_stray, extra);
        if (opt_int_junk) $display("INT_JUNK edges %0d", junk_edges);
        if (drain_bad) $display("[CHECK] %0d of %0d drained accumulators wrong", drain_bad, drain_vals);
        if (blk_bad) $display("[BLOCK] %0d of %0d per-block accumulators wrong", blk_bad, blk_vals);
        if (ka_bad) $display("[KA] %0d of %0d encoder outputs wrong", ka_bad, ka_vals);
        if (ph_bad) $display("[PHASE] %0d of %0d phases wrong", ph_bad, ph_vals);
        if (contract) $display("[CONTRACT] %0d [SC-CONTRACT] errors", contract);
    endtask

    initial begin
        string arg, dirs [$], items [$];
        int contract;
        bit ok;
        void'($value$plusargs("MODE=%s", bench_mode));
        opt_full = $test$plusargs("FULL_CYCLES");
        opt_gaps = $test$plusargs("GAPS");
        opt_rng_gap_low = $test$plusargs("RNG_GAP_LOW");
        opt_mac_exact = $test$plusargs("MAC_EXACT");
        opt_loose = $test$plusargs("LOOSE_DRAIN");
        opt_stall = $test$plusargs("STALL");
        opt_rng_low_end = $test$plusargs("RNG_LOW_END");
        opt_junk_bus = $test$plusargs("JUNK_BUS");
        opt_mid_reset = $test$plusargs("MID_RESET");
        opt_no_call_ss = $test$plusargs("NO_CALL_SS");
        opt_no_slice_ss = $test$plusargs("NO_SLICE_SS");
        opt_no_slice_start = $test$plusargs("NO_SLICE_START");
        opt_kill_drain_reset = $test$plusargs("KILL_DRAIN_RESET");
        neg_stall_nomac = $test$plusargs("NEG_STALL_NOMAC");
        neg_stray_load = $test$plusargs("NEG_STRAY_LOAD");
        opt_junk_ss = $test$plusargs("JUNK_SS");
        neg_lane_rev = $test$plusargs("NEG_LANE_REV");
        neg_ka_eq_b = $test$plusargs("NEG_KA_EQ_B");
        neg_row_len_max = $test$plusargs("NEG_ROW_LEN_MAX");
        neg_len_128 = $test$plusargs("NEG_LEN_128");
        neg_short = $test$plusargs("NEG_SHORT_BLOCK");
        neg_drain_early = $test$plusargs("NEG_DRAIN_EARLY");
        neg_next_early = $test$plusargs("NEG_NEXT_EARLY");
        opt_int_junk = $test$plusargs("INT_JUNK");
        neg_sw_early_int = $test$plusargs("NEG_SW_EARLY_INT");
        neg_sw_late_drop = $test$plusargs("NEG_SW_LATE_DROP");
        neg_sw_no_zero_load = $test$plusargs("NEG_SW_NO_ZERO_LOAD");
        neg_sw_int_drop_early = $test$plusargs("NEG_SW_INT_DROP_EARLY");
        neg_sw_no_reload = $test$plusargs("NEG_SW_NO_RELOAD");
        void'($value$plusargs("SW_GAP=%d", sw_gap));
        opt_rng_low_idle = $test$plusargs("RNG_LOW_IDLE");
        neg_rng_low_end_drain = $test$plusargs("NEG_RNG_LOW_END_DRAIN");
        if (neg_rng_low_end_drain && !(DRAIN == 1 && $test$plusargs("RNG_LOW_END")))
            $fatal(1, "[BENCH] NEG_RNG_LOW_END_DRAIN needs RNG_LOW_END and PAYN_DRAIN=1");
        void'($value$plusargs("NEG_SHORT_LAST=%d", neg_short_last));
        void'($value$plusargs("DRAIN_SAMPLE_LATE_PS=%d", drain_sample_late_ps));
        if (drain_sample_late_ps < 0 || drain_sample_late_ps >= int'(PERIOD * 500.0))
            $fatal(1, "[BENCH] DRAIN_SAMPLE_LATE_PS=%0d out of 0..%0d", drain_sample_late_ps, int'(PERIOD * 500.0) - 1);
        void'($value$plusargs("INT_LEN_DC=%d", int_len_dc));
        if (int_len_dc > 255) $fatal(1, "[BENCH] INT_LEN_DC=%0d out of 0..255", int_len_dc);
        // INT options (+MODE=int; switch segments take theirs from bpt_cfg.txt)
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        void'($value$plusargs("MODE_AT=%d", MODE_AT));
        junk = $test$plusargs("JUNK");
        neg_no_ring = $test$plusargs("NEG_NO_RING");
        neg_prec = $test$plusargs("NEG_PREC");
        lap_ring_only = $test$plusargs("LAP_RING_ONLY");
        neg_ring_stray = $test$plusargs("NEG_RING_STRAY");
        neg_mag = $test$plusargs("NEG_MAG");
        void'($value$plusargs("LAP_LEN=%d", LAP_LEN));
        neg_no_bubble = $test$plusargs("NEG_NO_BUBBLE");
        neg_ring_stray_mid = $test$plusargs("NEG_RING_STRAY_MID");
        park_cyc0 = $test$plusargs("PARK_CYC0");
        neg_mag_a = $test$plusargs("NEG_MAG_A");
        neg_mag_w = $test$plusargs("NEG_MAG_W");
        junk_scstrobe = $test$plusargs("JUNK_SCSTROBE");
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("RESET_SETTLE=%d", reset_settle)) reset_settle = `TB_RESET_SETTLE;

        if (DRAIN == 1 && (bench_mode == "int" || bench_mode == "switch"))
            $fatal(1, "[BENCH] +MODE=%s uses the bit-plane combiner on the in-tile chain: build with PAYN_DRAIN=0",
                   bench_mode);

        if (bench_mode == "sc") begin
            //----------------------------------------------------- SC --
            void'($urandom(seed));
            if (!$value$plusargs("CASES=%s", arg) && !$value$plusargs("CASE=%s", arg)) begin
                // `make sim` runs simv without plusargs: take the list from
                // cases.txt in the run directory (one comma-separated line).
                int fd;
                fd = $fopen("cases.txt", "r");
                if (fd == 0 || $fgets(arg, fd) == 0)
                    $fatal(1, "[BENCH] give +CASES=dir1,dir2,... (or +CASE=dir, or a cases.txt)");
                $fclose(fd);
                while (arg.len() > 0 && (arg[arg.len()-1] == "\n" || arg[arg.len()-1] == " "))
                    arg = arg.substr(0, arg.len() - 2);
            end
            split_list(arg, dirs);

            clk_utils.set_clock(PERIOD);
            clk_utils.do_reset();
            @(negedge clk);
            repeat (reset_settle) @(negedge clk);
            rng_en = 1'b1;
            run_active = 1'b1;
            sc_int_junk_on = opt_int_junk;
            int_mon_on = 1'b1;

            foreach (dirs[i]) begin
                int db, dd, bb, kb, pb;
                db = drain_bad; dd = drain_vals; bb = blk_bad; kb = ka_bad; pb = ph_bad;
                case_idx = i;
                if (opt_mid_reset && i > 0) begin
                    run_active = 1'b0;
                    clk_utils.do_reset();
                    @(negedge clk);
                    repeat (reset_settle) @(negedge clk);
                    rng_en = 1'b1;
                    run_active = 1'b1;
                end
                run_case(dirs[i]);
                $display("CASE %s: %0d blocks, %0d drains; drain %0d/%0d bad, block %0d bad, kA %0d bad, phase %0d bad",
                         dirs[i], n_blk, n_drn, drain_bad - db, drain_vals - dd, blk_bad - bb, ka_bad - kb, ph_bad - pb);
            end
            repeat (4) @(negedge clk);
            finish_sc_result(dirs.size());
            contract = dut_contract();
            ok = drain_bad == 0 && blk_bad == 0 && ka_bad == 0 && ph_bad == 0 && contract == 0 && drain_vals > 0;
            if (DRAIN == 1 && dr_valid_edges != 2*total_drains) begin
                $display("[DRVALID] %0d dr_out_valid edges, expected %0d (two per drain)", dr_valid_edges, 2*total_drains);
                ok = 1'b0;
            end
            if (ok)
                $display("PASS: PaYN array bench, %0d cases, %0d blocks, %0d drained accumulators bit-exact",
                         dirs.size(), total_blocks, drain_vals);
            else
                $display("FAIL: PaYN array bench");
            $finish;
        end

        if (bench_mode == "int") begin
            //---------------------------------------------------- INT --
            int_config();
            int_mode = (MODE_AT < 0);
            int_prec = (BA == 4) ^ neg_prec;
            rng_en = park_cyc0 ? 1'b0 : (junk || neg_mag);

            clk_utils.set_clock(PERIOD);
            clk_utils.do_reset();
            repeat (2) @(negedge clk);
            int_mon_on = 1'b1;
            run_int_segment("", 2);
            mac_en = 1'b0;
            shift_in = 1'b0;
            ring_in = 1'b0;
            @(negedge clk);                      // monitor reads the last combiner word at E_END+2
            if (seg_ndrain[0] != NBLK*N_W || seg_ncomb[0] != NBLK*N_W)
                $fatal(1, "drained %0d columns and %0d combiner outputs, expected %0d each",
                       seg_ndrain[0], seg_ncomb[0], NBLK*N_W);
            $fclose(seg_trace[0]);
            $fclose(seg_sched[0]);
            contract = dut_contract();
`ifndef GL_SIM
            $display("LAP_COVERAGE lap_edges=%0d tile_laps=%0d with_pending_carry=%0d with_pending_borrow=%0d",
                     cov_lap_edges, cov_tile_laps, cov_pending_carry, cov_pending_borrow);
            $display("INT_SILENT_MAC_SAMPLES %0d", int_mac_samples);
`endif
            $display("PASS: PaYN bit-plane INT bench BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d edges=%0d junk=%0d mode_at=%0d lap_ring_only=%0d lap_len=%0d block_len=%0d sc_contract=%0d park_cyc0=%0d",
                     BA, BW, L, MROWS, NCOLS, NBLK, E_END + 3, junk, MODE_AT, lap_ring_only, LAP_LEN, BLK_LEN,
                     contract, park_cyc0);
            $finish;
        end

        if (bench_mode == "switch") begin
            //------------------------------------------------- switch --
            string prev;
            int n_sc, int_fd, code, cj, cl;
            void'($urandom(seed));
            if (!$value$plusargs("SWITCH=%s", arg)) $fatal(1, "[BENCH] +MODE=switch needs +SWITCH=sc:dir,int:dir,...");
            split_list(arg, items);
            clk_utils.set_clock(PERIOD);
            clk_utils.do_reset();
            @(negedge clk);
            rng_en = 1'b1;
            int_mon_on = 1'b1;
            prev = "";
            n_sc = 0;
            foreach (items[it]) begin
                string kind, dir;
                if (items[it].len() < 4 || items[it][2] != ":" && items[it][3] != ":")
                    $fatal(1, "[BENCH] bad +SWITCH item %s", items[it]);
                kind = items[it].substr(0, 1) == "sc" ? "sc" : "int";
                dir = (kind == "sc") ? items[it].substr(3, items[it].len() - 1)
                                     : items[it].substr(4, items[it].len() - 1);
                repeat (prev == "" ? 0 : sw_gap) begin
                    if (prev == "sc") idle_controls();
                    @(negedge clk);
                end
                if (kind == "sc") begin
                    if (prev == "int") begin
                        if (neg_sw_late_drop)
                            fork begin @(negedge clk); int_mode = 1'b0; end join_none
                        else
                            int_mode = 1'b0;
                        first_block_after_int = 1'b1;
                        rng_en = 1'b1;
                        mac_en = 1'b1;
                    end
                    run_active = 1'b1;
                    sc_int_junk_on = opt_int_junk;
                    early_int_arm = neg_sw_early_int && it + 1 < items.size() &&
                                    items[it + 1].substr(0, 2) == "int";
                    case_idx = n_sc++;
                    run_case(dir);
                    early_int_arm = 1'b0;
                    $display("SWITCH SC %s: %0d blocks, %0d drains, drain bad so far %0d, contract %0d",
                             dir, n_blk, n_drn, drain_bad, dut_contract());
                end else begin
                    run_active = 1'b0;
                    sc_int_junk_on = 1'b0;
                    int_fd = $fopen({dir, "/bpt_cfg.txt"}, "r");
                    if (int_fd == 0) $fatal(1, "cannot open %s/bpt_cfg.txt", dir);
                    code = $fscanf(int_fd, "%d %d %d %d %d %d %d %d", BA, BW, L, MROWS, NCOLS, MODE_AT, cj, cl);
                    $fclose(int_fd);
                    if (code != 8) $fatal(1, "%s/bpt_cfg.txt: need BA BW L MROWS NCOLS MODE_AT JUNK LAP_RING_ONLY", dir);
                    if (MODE_AT < 0 || MODE_AT > 3) $fatal(1, "%s: switch segments need MODE_AT 0..3", dir);
                    junk = cj;
                    lap_ring_only = cl;
                    E0 = MODE_AT + 1;
                    int_config();
                    int_prec = (BA == 4);
                    run_int_segment(dir, 0);
                    $display("SWITCH INT %s: BA=%0d BW=%0d L=%0d blocks=%0d block_len=%0d E0=%0d",
                             dir, BA, BW, L, NBLK, BLK_LEN, E0);
                end
                prev = kind;
            end
            if (prev == "int") begin
                mac_en = 1'b0;
                shift_in = 1'b0;
                ring_in = 1'b0;
                repeat (3) @(negedge clk);
                int_mode = 1'b0;
            end
            repeat (4) @(negedge clk);
            finish_sc_result(n_sc);
            contract = dut_contract();
            ok = drain_bad == 0 && blk_bad == 0 && ka_bad == 0 && ph_bad == 0 && contract == 0 && drain_vals > 0;
            for (int s = 0; s < n_seg; s++) begin
                $display("SEGMENT %0d %s: drained %0d combined %0d expected %0d",
                         s, seg_dir[s], seg_ndrain[s], seg_ncomb[s], seg_nblk[s]*N_W);
                if (seg_ndrain[s] != seg_nblk[s]*N_W || seg_ncomb[s] != seg_nblk[s]*N_W) begin
                    ok = 1'b0;
                    $display("[INTCOUNT] segment %0d (%s): drained %0d, combined %0d, expected %0d each",
                             s, seg_dir[s], seg_ndrain[s], seg_ncomb[s], seg_nblk[s]*N_W);
                end
                $fclose(seg_trace[s]);
                $fclose(seg_sched[s]);
            end
`ifndef GL_SIM
            $display("LAP_COVERAGE lap_edges=%0d tile_laps=%0d with_pending_carry=%0d with_pending_borrow=%0d",
                     cov_lap_edges, cov_tile_laps, cov_pending_carry, cov_pending_borrow);
`endif
            $display("SWITCH_RESULT sc_cases=%0d int_segments=%0d edges=%0d", n_sc, n_seg, edge_n);
            if (ok)
                $display("PASS: PaYN switch bench, %0d SC cases, %0d INT segments", n_sc, n_seg);
            else
                $display("FAIL: PaYN switch bench");
            $finish;
        end

        if (bench_mode == "abit") begin
            //---------------------------------------------------------- abit --
            void'($value$plusargs("NEG_ABIT_NO_LAP=%d", ab_neg_no_lap));
            void'($value$plusargs("NEG_ABIT_EXTRA_LAP=%d", ab_neg_extra_lap));
            void'($value$plusargs("NEG_ABIT_SIGN=%d", ab_neg_sign));
            void'($value$plusargs("NEG_ABIT_ORDER=%d", ab_neg_order));
            ab_neg_no_bubble = $test$plusargs("NEG_ABIT_NO_BUBBLE");
            ab_neg_drain_early = $test$plusargs("NEG_ABIT_DRAIN_EARLY");
            ab_neg_overlap = $test$plusargs("NEG_ABIT_OVERLAP");
            if (!(ab_neg_sign >= 0 && ab_neg_sign <= 2) || !(ab_neg_order >= 0 && ab_neg_order <= 2))
                $fatal(1, "[BENCH] NEG_ABIT_SIGN and NEG_ABIT_ORDER must be 0..2");
            void'($urandom(seed));
            abit_config();
            int_mode = (MODE_AT < 0);
            int_prec = 1'b0;                     // the combiner is not used (raw rows from acc_out_east)
            rng_en = park_cyc0 ? 1'b0 : junk;

            clk_utils.set_clock(PERIOD);
            clk_utils.do_reset();
            repeat (2) @(negedge clk);
            int_mon_on = 1'b1;
            run_abit_segment(2);
            mac_en = 1'b0;
            shift_in = 1'b0;
            ring_in = 1'b0;
            @(negedge clk);                      // monitor reads the last combiner word at E_END+2
            if (DRAIN == 1 && (ab_items != 2*AB_NBLK || seg_ndrain[0] != 0 || seg_ncomb[0] != 0))
                $fatal(1, "read %0d drain-register items (expected %0d), %0d acc_out_east columns and %0d combiner outputs (expected 0)",
                       ab_items, 2*AB_NBLK, seg_ndrain[0], seg_ncomb[0]);
            if (DRAIN != 1 && (seg_ndrain[0] != AB_NBLK*N_W || seg_ncomb[0] != AB_NBLK*N_W))
                $fatal(1, "drained %0d columns and %0d combiner outputs, expected %0d each",
                       seg_ndrain[0], seg_ncomb[0], AB_NBLK*N_W);
            ab_q_seg = -1;
            $fclose(seg_trace[0]);
            $fclose(seg_sched[0]);
            contract = dut_contract();
`ifndef GL_SIM
            $display("LAP_COVERAGE lap_edges=%0d tile_laps=%0d with_pending_carry=%0d with_pending_borrow=%0d",
                     cov_lap_edges, cov_tile_laps, cov_pending_carry, cov_pending_borrow);
            $display("INT_SILENT_MAC_SAMPLES %0d", int_mac_samples);
`endif
            $display("PASS: PaYN abit INT bench BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d formula=%0d edges=%0d junk=%0d mode_at=%0d sc_contract=%0d park_cyc0=%0d neg=%0d/%0d/%0d/%0d/%0d/%0d/%0d drain=%0d",
                     BA, BW, L, MROWS, NCOLS, AB_NBLK, AB_BLK_LEN, AB_FORMULA, AB_E_END + 3, junk, MODE_AT,
                     contract, park_cyc0, ab_neg_no_lap, ab_neg_extra_lap, ab_neg_sign, ab_neg_order,
                     ab_neg_no_bubble, ab_neg_drain_early, ab_neg_overlap, DRAIN);
            $finish;
        end
        $fatal(1, "[BENCH] unknown +MODE=%s (sc | int | switch | abit)", bench_mode);
    end
endmodule
