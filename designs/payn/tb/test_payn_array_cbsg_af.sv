`timescale 1ns/1ps

`include "common/clk_util.sv"

// Functional bench for the C-BSG A-first array (payn_array_signed_segmented_csa_cbsg_af).
//
// Plays golden cases written by sweeps/cbsg/cbsg_ref.py --emit (or
// sweeps/cbsg/af/emit_af_cases.py), one 8 x 8 PE per case, and compares every
// drain bit-exactly against acc_exp.mem.  Several cases can run back to back
// on one DUT with no reset in between (+CASES=dir1,dir2,...), so the end state
// of one case (phase register, counter, pipes) carries into the next, exactly
// like consecutive calls.  The DUT derives the block phase itself (restart
// after every drain and reset, or on slice_start); phase.mem is only
// compared, never driven.
//
// Schedule (top header contract): block b loads at edge B with block_start,
// load_a/load_w/load_a_sign/load_w_sign and slice_start = slice_start.mem[b];
// it runs C = cycles.mem[b] cycles; back-to-back blocks load at B+C.  After a
// drain block the drain starts at B+C+2 (one edge after the last MAC edge) and
// the next slice's first block loads at the drain's second-to-last shift edge,
// so its first MAC follows the last shift edge: the tightest legal schedule.
// mac_en and rng_en are held high (the IDLE counter makes extra MACs zero).
//
// Extra checks (RTL only): after every block the tile accumulators are read
// hierarchically and compared with acc_blk.mem; after every load edge the
// encoder outputs with ka.mem and the phase register with phase.mem.
// Under GL_SIM (netlist runs, sweeps/cbsg/af/run_syn_gl_checks.sh) only the
// drains are compared: the peeks, the forces behind +NEG_KA_EQ_B and
// +KILL_DRAIN_RESET (no-ops there) and the contract count are RTL-only.
//
// Plusargs:
//   +CASES=d1,d2,..  case directories (or +CASE=dir)
//   +SEED=n          random seed for the robustness modes
// Robustness modes (must still PASS):
//   +FULL_CYCLES     run all 8 cycles in every block
//   +GAPS            0..3 idle edges before every block
//   +RNG_GAP_LOW     with GAPS: rng_en random outside a block's advance edges B+1..B+C
//   +MAC_EXACT       mac_en high only on the blocks' MAC edges
//   +LOOSE_DRAIN     0..3 extra edges before each drain and before the next slice
//   +STALL           0..2 legal stalls per block: rng_en low at an edge E inside the
//                    block, mac_en low at E+2 (the block span grows by the stalls)
//   +RNG_LOW_END     rng_en low on the block's last advance edge B+C.  Legal with
//                    MAC_EXACT, or when the next block_start or the drain falls on B+C
//                    resp. B+C+2 (the repeated last cycle is never accumulated twice);
//                    with GAPS and mac_en high it is a negative control
//   +JUNK_BUS        random operand / L buses on every non-load edge
//   +MID_RESET       DUT reset between cases
//   +RESET_SETTLE=n  n idle edges (no loads, rng_en low) after every reset before the
//                    first block (default `CBSG_RESET_SETTLE, 0).  Netlist runs with real delays need it:
//                    the operand registers' asynchronous reset reaches them through the
//                    synthesized reset buffer tree, as power_payn_array.sv's two settle
//                    clocks allow for (sweeps/cbsg/af/run_syn_gl_checks.sh passes 2)
//   +NO_CALL_SS      slice_start withheld at call starts (after the first block of the run)
//   +NO_SLICE_SS     slice_start only at call starts (none at chunk / head starts)
//   +NO_SLICE_START  slice_start never driven: the drains alone restart the phase
//   +KILL_DRAIN_RESET  force the DUT's drain/reset-derived phase restart off
//                    (u_rng.drain_seen = 0): slice_start alone must do it
// Negative controls (must FAIL):
//   +NO_CALL_SS / +NO_SLICE_SS / +NO_SLICE_START with +KILL_DRAIN_RESET
//                        phase carried across calls / chunks / heads
//   +NEG_STALL_NOMAC     the STALL schedule without the mac_en kill (cycle counted twice)
//   +NEG_STRAY_LOAD      a load pair (A or W, legal values) on ~1/16 of the non-block edges
//   +JUNK_SS             random slice_start on non-block edges (no effect: CONTRACT only)
//   +NEG_LANE_REV        column k fed to lane 7-k (wrong mask lane bits)
//   +NEG_KA_EQ_B         encoder output forced to min(b, L) (no closed-form encoder)
//   +NEG_ROW_LEN_MAX     every row gets the block's max L (per-row L ignored)
//   +NEG_LEN_128         every row gets L = 128 and 8 cycles (L ignored: kA = b)
//   +NEG_SHORT_BLOCK     blocks of >= 2 cycles run one cycle short
//   +NEG_DRAIN_EARLY     drain one edge early (on the last MAC edge)
//   +NEG_NEXT_EARLY      next slice starts one edge early (first MAC on the last shift edge)
// Result tags: [CHECK] drain mismatch, [BLOCK] per-block accumulator mismatch,
// [KA] encoder mismatch, [PHASE] phase mismatch, [CONTRACT] the top's
// [CBSG-AF-CONTRACT] count.  Last line: PASS: / FAIL: CBSG AF bench.
// (STALL, NEG_STALL_NOMAC, RNG_LOW_END, JUNK_BUS, JUNK_SS and MID_RESET come
// from the review bench sweeps/cbsg/af/review/test_cbsg_af_review.sv.)
//
// Needs DesignWare for the CSA tile heap: make sim ... USE_DW=1

`ifndef GL_SIM
`include "payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv"
`endif

`ifndef CBSG_MAX_BLK
`define CBSG_MAX_BLK 4096
`endif
`ifndef CBSG_OWIDTH
`define CBSG_OWIDTH 24
`endif
`ifndef CBSG_LOW_W
`define CBSG_LOW_W 9
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif
`ifndef CBSG_RESET_SETTLE
`define CBSG_RESET_SETTLE 0            // default of +RESET_SETTLE
`endif

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = `CBSG_OWIDTH;
    localparam int LOW_W = `CBSG_LOW_W;
    localparam int MAX_BLK = `CBSG_MAX_BLK;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
    localparam int MAX_PRINT = 8;

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

    ClkUtils #(.TIMEOUT(50_000_000)) clk_utils (.clk, .reset, .timeout);

    always @(posedge timeout) $fatal(1, "[TIMEOUT] CBSG AF bench");

    payn_array_signed_segmented_csa_cbsg_af #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (.*);

`ifdef GL_SIM
    // Gate-level runs (make sim GL=syn|apr): annotate the netlist SDF unless
    // NO_SDF, as power_payn_array_cbsg_af.sv does.  RTL runs never see this.
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
    bit opt_full, opt_gaps, opt_rng_gap_low, opt_mac_exact, opt_loose;
    bit opt_stall, opt_rng_low_end, opt_junk_bus, opt_mid_reset;
    bit opt_no_call_ss, opt_no_slice_ss, opt_no_slice_start, opt_kill_drain_reset;
    bit neg_lane_rev, neg_ka_eq_b, neg_row_len_max;
    bit neg_len_128, neg_short, neg_drain_early, neg_next_early;
    bit neg_stall_nomac, neg_stray_load, opt_junk_ss;
    bit stall_edge [int unsigned];
    bit mac_kill [int unsigned];
    int total_stalls = 0, total_stray = 0;

    //------------------------------------------------------------- golden --
    logic [31:0] cfg_m   [8];
    logic [7:0]  a_mag_m [MAX_BLK*64];
    logic [3:0]  a_sgn_m [MAX_BLK*64];
    logic [7:0]  w_mag_m [MAX_BLK*64];
    logic [3:0]  w_sgn_m [MAX_BLK*64];
    logic [7:0]  len_m   [MAX_BLK*8];
    logic [3:0]  ss_m    [MAX_BLK];
    logic [3:0]  cs_m    [MAX_BLK];
    logic [3:0]  ph_m    [MAX_BLK];
    logic [3:0]  cy_m    [MAX_BLK];
    logic [3:0]  dr_m    [MAX_BLK];
    logic [7:0]  ka_m    [MAX_BLK*64];
    logic [31:0] accb_m  [MAX_BLK*64];
    logic [31:0] acce_m  [MAX_BLK*64];

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
        $readmemh({dir, "/a_mag.mem"}, a_mag_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/a_sgn.mem"}, a_sgn_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/w_mag.mem"}, w_mag_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/w_sgn.mem"}, w_sgn_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/row_len.mem"}, len_m, 0, n_blk*8 - 1);
        $readmemh({dir, "/slice_start.mem"}, ss_m, 0, n_blk - 1);
        $readmemh({dir, "/call_start.mem"}, cs_m, 0, n_blk - 1);
        $readmemh({dir, "/phase.mem"}, ph_m, 0, n_blk - 1);
        $readmemh({dir, "/cycles.mem"}, cy_m, 0, n_blk - 1);
        $readmemh({dir, "/drain.mem"}, dr_m, 0, n_blk - 1);
        $readmemh({dir, "/ka.mem"}, ka_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/acc_blk.mem"}, accb_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/acc_exp.mem"}, acce_m, 0, n_drn*64 - 1);
    endtask

    //----------------------------------------------------------- counters --
    int drain_vals = 0, drain_bad = 0;
    int blk_vals = 0, blk_bad = 0;
    int ka_vals = 0, ka_bad = 0;
    int ph_vals = 0, ph_bad = 0;
    int total_blocks = 0, total_drains = 0, total_calls = 0;
    string case_name;

    //------------------------------------------------------- edge counter --
    // edge_n = posedges so far; at a negedge the upcoming edge is edge_n + 1.
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
                exp_v = $signed(accb_m[b*64 + h*8 + v]);
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

    initial begin
        drain_t dr;
        logic signed [OWIDTH-1:0] got [N_H][N_W];
        forever begin
            wait (drain_q.size() > 0);
            dr = drain_q.pop_front();
            drain_busy = 1'b1;
            while (edge_n + 1 < dr.d0) @(negedge clk);
            acc_in_west = '0;
            for (int s = 0; s < N_W; s++) begin
                for (int h = 0; h < N_H; h++)
                    got[h][N_W-1-s] = acc_out_east[h*OWIDTH +: OWIDTH];
                shift_in = 1'b1;
                @(negedge clk);
            end
            shift_in = 1'b0;
            for (int h = 0; h < N_H; h++)
                for (int v = 0; v < N_W; v++) begin
                    logic signed [31:0] exp_v;
                    exp_v = $signed(acce_m[dr.di*64 + h*8 + v]);
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

    //---------------------------------------------------------- stimulus --
    int unsigned cur_end = 0;          // last advance edge (B+C) of the running block
    bit first_block_of_run = 1'b1;

    task automatic idle_controls();
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        block_start = 1'b0;
        slice_start = 1'b0;
        if (edge_n + 1 <= cur_end)
            rng_en = !stall_edge.exists(edge_n + 1) && !(opt_rng_low_end && edge_n + 1 == cur_end);
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
            if (int'(len_m[b*8 + h]) > max_len) max_len = int'(len_m[b*8 + h]);
        for (int h = 0; h < N_H; h++) begin
            int len;
            len = int'(len_m[b*8 + h]);
            if (neg_row_len_max) len = max_len;
            if (neg_len_128) len = 128;
            a_len_in[h*WIDTH +: WIDTH] = WIDTH'(len);
            for (int k = 0; k < K; k++) begin
                int kk;
                kk = neg_lane_rev ? (K - 1 - k) : k;
                a_binary_in[(h*K + kk)*WIDTH +: WIDTH] = a_mag_m[b*64 + h*8 + k];
                a_signs_in[h*K + kk] = a_sgn_m[b*64 + h*8 + k][0];
            end
        end
        for (int k = 0; k < K; k++) begin
            int kk;
            kk = neg_lane_rev ? (K - 1 - k) : k;
            for (int v = 0; v < N_W; v++) begin
                w_binary_in[(v*K + kk)*WIDTH +: WIDTH] = w_mag_m[b*64 + k*8 + v];
                w_signs_in[v*K + kk] = w_sgn_m[b*64 + k*8 + v][0];
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
        if (opt_gaps) rng_en = 1'($urandom & 1);   // don't-care on the restart edge
        first_block_of_run = 1'b0;
    endtask

    task automatic check_load(input int b);
`ifndef GL_SIM
        ph_vals++;
        if (dut.phase !== 3'(ph_m[b])) begin
            ph_bad++;
            if (ph_bad <= MAX_PRINT)
                $display("[PHASE] %s block %0d: phase register %0d, expected %0d", case_name, b, dut.phase, ph_m[b]);
        end
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++) begin
                ka_vals++;
                if (dut.u_peripheral.ka_flat[(h*K + k)*WIDTH +: WIDTH] !== ka_m[b*64 + h*8 + k]) begin
                    ka_bad++;
                    if (ka_bad <= MAX_PRINT)
                        $display("[KA] %s block %0d row %0d lane %0d: %0d, expected %0d", case_name, b, h, k,
                                 dut.u_peripheral.ka_flat[(h*K + k)*WIDTH +: WIDTH], ka_m[b*64 + h*8 + k]);
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
            if (C < 1 || C > 8) $fatal(1, "[BENCH] %s block %0d: cycles %0d", dir, b, C);
            if (opt_full || neg_len_128) C = 8;
            if (neg_short && C > 1) C = C - 1;
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
            peek_q.push_back('{B + C + 1, b});
            if (dr_m[b][0]) begin
                D0 = B + C + 2 + (opt_loose ? $urandom_range(0, 3) : 0);
                if (neg_drain_early) D0 = D0 - 1;
                drain_q.push_back('{D0, di});
                di++;
                next_free = D0 + N_W - 2 + (opt_loose ? $urandom_range(0, 3) : 0);
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
        while (drain_q.size() > 0 || drain_busy || peek_q.size() > 0) begin
            idle_controls();
            @(negedge clk);
        end
    endtask

    initial begin
        string arg, dirs [$];
        int seed, start, contract, reset_settle;
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
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        void'($urandom(seed));
        if (!$value$plusargs("CASES=%s", arg) && !$value$plusargs("CASE=%s", arg)) begin
            // `make sim` runs simv without plusargs: take the list from
            // cbsg_cases.txt in the run directory (one comma-separated line).
            int fd;
            fd = $fopen("cbsg_cases.txt", "r");
            if (fd == 0 || $fgets(arg, fd) == 0)
                $fatal(1, "[BENCH] give +CASES=dir1,dir2,... (or +CASE=dir, or a cbsg_cases.txt)");
            $fclose(fd);
            while (arg.len() > 0 && (arg[arg.len()-1] == "\n" || arg[arg.len()-1] == " "))
                arg = arg.substr(0, arg.len() - 2);
        end
        start = 0;
        for (int i = 0; i <= arg.len(); i++)
            if (i == arg.len() || arg[i] == ",") begin
                if (i > start) dirs.push_back(arg.substr(start, i - 1));
                start = i + 1;
            end

        if (!$value$plusargs("RESET_SETTLE=%d", reset_settle)) reset_settle = `CBSG_RESET_SETTLE;
        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        @(negedge clk);
        repeat (reset_settle) @(negedge clk);
        rng_en = 1'b1;
        run_active = 1'b1;

        foreach (dirs[i]) begin
            int db, dd, bb, kb, pb;
            db = drain_bad; dd = drain_vals; bb = blk_bad; kb = ka_bad; pb = ph_bad;
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

`ifndef GL_SIM
        contract = dut.contract_errors;
`else
        contract = 0;
`endif
        $display("RESULT cases=%0d calls=%0d blocks=%0d drains=%0d edges=%0d | drain values %0d bad %0d | block values %0d bad %0d | kA values %0d bad %0d | phase checks %0d bad %0d | contract %0d | stalls %0d stray loads %0d",
                 dirs.size(), total_calls, total_blocks, total_drains, edge_n, drain_vals, drain_bad,
                 blk_vals, blk_bad, ka_vals, ka_bad, ph_vals, ph_bad, contract, total_stalls, total_stray);
        if (drain_bad) $display("[CHECK] %0d of %0d drained accumulators wrong", drain_bad, drain_vals);
        if (blk_bad) $display("[BLOCK] %0d of %0d per-block accumulators wrong", blk_bad, blk_vals);
        if (ka_bad) $display("[KA] %0d of %0d encoder outputs wrong", ka_bad, ka_vals);
        if (ph_bad) $display("[PHASE] %0d of %0d phases wrong", ph_bad, ph_vals);
        if (contract) $display("[CONTRACT] %0d [CBSG-AF-CONTRACT] errors", contract);
        if (drain_bad == 0 && blk_bad == 0 && ka_bad == 0 && ph_bad == 0 && contract == 0 && drain_vals > 0)
            $display("PASS: CBSG AF bench, %0d cases, %0d blocks, %0d drained accumulators bit-exact",
                     dirs.size(), total_blocks, drain_vals);
        else
            $display("FAIL: CBSG AF bench");
        $finish;
    end
endmodule
