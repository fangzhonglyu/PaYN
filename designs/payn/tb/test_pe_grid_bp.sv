`timescale 1ns/1ps

`include "common/clk_util.sv"

// Bit-plane (BP) INT bench for a P_R x P_C PE grid of the carry-save BP PE
// (InnerPESignedSegmentedCsaBpGrid), testing the per-PE lap enable: every PE
// laps when its own skewed pass ends, and the global shift_in is used only for
// the final drain.
//
// Mapping: output block (ig, jg); PE (r,c) holds activation rows
// i = (ig*P_R + r)*ROWS_PE + h/BA (plane p = h % BA in tile row h) and output
// columns j = (jg*P_C + c)*8 + v.  Lane k / position m of data slice b carries
// reduction element x = 128*b + 16*k + m.  Weight planes go in time, MSB pass
// first.  INT8: BA = BW = 8; W4A8: BA = 8, BW = 4; INT4: BA = BW = 4 (two
// activation rows per PE).  The east-edge combiner is not in the grid; the
// checker forms out = sum_h 2^h tile(h) from the drained tiles.
//
// Edge drive (the edge peripherals' job; the bench plays them).  Every input
// is launched at the negedge before the capturing posedge P_e.  "Virtual edge"
// v is PE (0,0)'s schedule time; PE row r sees it r edges late, PE column c
// c edges late, PE (r,c) r+c edges late:
//  * a_bits_in[r] at P_e: raw activation planes of virtual edge e - r;
//    w_bits_in[c] at P_e: raw weight planes of virtual edge e - c (the
//    bypass's bits = comparator | raw with silent comparators);
//  * load_w_sign_in[c] one edge ahead of column c's pass start, w_signs_in[c]
//    = the pass's sign word (all ones in the weight-MSB pass) on that start
//    edge; a_signs_in[r] = (h % BA == BA-1), loaded once (load_a_sign_in[r]
//    one edge ahead of row r's first capture);
//  * ring_in[r] = 1 at P_e iff virtual edge e + 1 - r is a lap edge: row r's
//    A skew, one edge ahead (ring_q).  The grid moves the wave one PE east per
//    edge, so PE (r,c) laps at offset r+c;
//  * shift_in ONLY on the 8*P_C final drain edges of each block (acc_in_west
//    = 0 there); mac_en = 1 from P_{E0+1} to the end (bubbles add zero, shift
//    has priority); int_mode = 1.
//
// Schedule (virtual edges relative to the block base B = E0 + blk*BLK_LEN):
// pass pi starts at B + pi*(NB+GAP); NB data slices, then GAP bubble slices.
// PE (0,0) laps on B + pi*(NB+GAP) + NB + LO + 1 .. + 8 for pi < BW-1 (the
// last lap edge is the next pass's first capture).  Drain (real edges, global):
// D0 = B + (BW-1)*(NB+GAP) + NB + 1 + S, S = P_R + P_C - 2, for 8*P_C edges;
// the last drain edge is the next block's first capture, so
//     BLK_LEN = BW*NB + GAP*(BW-1) + S + 8*P_C.
// Per-PE laps: GAP = 8, LO = 0 (BLK_LEN = BW*NB + 8*(BW-1) + S + 8*P_C).
//
// Lap modes (+plusargs; the default is the per-PE lap enable):
//   +GLOBAL_LAP_WAIT  positive control, the as-built csa_bp_20261003b grid
//                     usage: one global ring signal forced into every PE's
//                     ring_in, shift_in on the global lap edges too, and every
//                     lap waits for the last PE: GAP = LO + 8, LO = S.  Must
//                     PASS with S*(BW-1) more edges per block.
//   +NEG_RING_NO_ROW_SKEW  negative control: ring_in[r] driven with row 0's
//                     timing (no r offset): rows r > 0 lap r edges early.
//   +NEG_RING_NO_COL_SKEW  negative control: every PE (r,c) takes the row's
//                     west ring input directly (forced; no east wave): PE
//                     columns c > 0 lap c edges early.
//   +NEG_GLOBAL_LAP   negative control: laps issued globally (one forced ring
//                     signal + shift_in) on PE (0,0)'s schedule, without
//                     waiting for the skew (GAP = 8, LO = 0).
//   +JUNK             random acc_in_west on every non-drain edge (lap edges
//                     included: the ring mux must hide it), random sign words
//                     on every edge where no PE latches them.
//
// Trace (bpg_trace.txt): header BPGCFG, every drained column
//   "D blk r t e tile_h0..tile_h7"   (PE column P_C-1-t/8, tile column 7-t%8)
// and every PE's lap runs "R r c e_first len" (ring_q high on edges
// e_first .. e_first+len-1).  sweeps/int_mode/bp/check_bp_grid_trace.py checks
// every tile and every combined output bit-exactly against numpy int64, the
// drain edges, the lap runs of every PE, and the measured block period.
//
//   +BA=<4|8> +BW=<4|8> +L=<multiple of 128> +MROWS=<n> +NCOLS=<n>
// MROWS multiple of P_R*ROWS_PE, NCOLS of P_C*8.  Shape: +define+BPG_PR=,
// +define+BPG_PC= (compile time).  Operands bpt_a.hex / bpt_w.hex from
// sweeps/int_mode/bp/gen_bp_workload.py.  RTL needs DesignWare (USE_DW=1).

`include "payn/variants/signed_segmented_csa_bp/inner_pe_grid_signed_segmented_csa_bp.sv"

`ifndef BPG_PR
`define BPG_PR 2
`endif
`ifndef BPG_PC
`define BPG_PC 2
`endif
`ifndef BPG_LOW_W
`define BPG_LOW_W 9
`endif
`ifndef BPG_MAX_EDGES
`define BPG_MAX_EDGES 400000
`endif

module Top;
    localparam int P_R = `BPG_PR;
    localparam int P_C = `BPG_PC;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int OWIDTH = 24;
    localparam int LOW_W = `BPG_LOW_W;
    localparam int S = P_R + P_C - 2;           // skew of the far PE
    localparam int E0 = 4;                      // first capture, PE (0,0)
    localparam real PERIOD = 2.5;
    localparam int AB = N_H*K*M, AS = N_H*K, WB = N_W*K*M, WS = N_W*K, AW = N_H*OWIDTH;

    localparam int MODE_PE = 0, MODE_GLOBAL_WAIT = 1, MODE_NEG_ROW = 2,
                   MODE_NEG_COL = 3, MODE_NEG_GLOBAL = 4;

    int BA = 8, BW = 8, L = 128, MROWS = 0, NCOLS = 0;
    int mode = MODE_PE;
    bit junk = 1'b0;
    bit cfg_done = 1'b0;
    int NB, ROWS_PE, NIG, NJG, NBLK, GAP, LO, BLK_LEN, E_END, N_EDGES;
    int cur_e = -1000;
    logic [AS-1:0] a_sign_word;

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

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]
    integer trace_file;
    int n_drain = 0;

    ClkUtils #(.TIMEOUT(`BPG_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

    InnerPESignedSegmentedCsaBpGrid #(
        .P_ROWS(P_R), .P_COLS(P_C), .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (.*);

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] BP grid bench exceeded %0d cycles", `BPG_MAX_EDGES);

    // ------------------------------------------- forced ring (lap modes) --
    // Bench-only rewiring for the global-lap positive control and two negative
    // controls; the default mode forces nothing.
    for (genvar r = 0; r < P_R; r++) begin : g_force_r
        for (genvar c = 0; c < P_C; c++) begin : g_force_c
            initial begin
                wait (cfg_done);
                if (mode == MODE_NEG_COL)
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in = ring_in[r] & int_mode;
                else if (mode == MODE_GLOBAL_WAIT || mode == MODE_NEG_GLOBAL)
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in = ring_global & int_mode;
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

    // ---------------------------------------------------------- schedule --
    // Virtual edge v -> block, offset inside the block; 0 outside the run.
    function automatic bit decode(input int v, output int blk, output int u);
        if (v < E0 || v >= E0 + NBLK*BLK_LEN) return 1'b0;
        blk = (v - E0) / BLK_LEN;
        u = (v - E0) % BLK_LEN;
        return 1'b1;
    endfunction

    // Data slice captured at virtual edge v: returns 1 with block, pass, slice.
    function automatic bit data_at(input int v, output int blk, output int pi, output int b);
        int u;
        if (!decode(v, blk, u)) return 1'b0;
        pi = u / (NB + GAP);
        b = u % (NB + GAP);
        return pi < BW && b < NB;
    endfunction

    // Lap edge in PE (0,0) time (also the global lap edges in the global modes).
    function automatic bit lap_at(input int v);
        int blk, u, pi, w;
        if (!decode(v, blk, u)) return 1'b0;
        pi = (u - 1) / (NB + GAP);              // u = 0 belongs to the previous pass's lap
        w = u - pi*(NB + GAP);
        if (u == 0) return 1'b0;                // block start: the drain owns it
        return pi < BW - 1 && w >= NB + LO + 1 && w <= NB + LO + 8;
    endfunction

    // First capture of a pass at virtual edge v.
    function automatic bit pass_start_at(input int v);
        int blk, u;
        if (!decode(v, blk, u)) return 1'b0;
        return (u % (NB + GAP)) == 0 && (u / (NB + GAP)) < BW;
    endfunction

    // Pass whose sign word is in force at virtual edge v (0 before the run).
    function automatic int sign_pass(input int v);
        int blk, u, pi;
        if (!decode(v, blk, u)) return 0;
        pi = u / (NB + GAP);
        return (pi < BW) ? pi : BW - 1;
    endfunction

    // Global drain edge (real time): block and step.
    function automatic bit drain_at(input int e, output int blk, output int t);
        int d0;
        if (e <= E0) return 1'b0;
        blk = (e - E0 - 1) / BLK_LEN;
        if (blk >= NBLK) return 1'b0;
        d0 = E0 + blk*BLK_LEN + (BW-1)*(NB + GAP) + NB + 1 + S;
        t = e - d0;
        return t >= 0 && t < 8*P_C;
    endfunction

    // ----------------------------------------------------------- drivers --
    task automatic drive(input int e);
        int blk, pi, b, ig, jg, q, i, j, x, p, t, dblk;
        bit drain;
        // A, west edge: PE row r at virtual edge e - r.
        for (int r = 0; r < P_R; r++) begin
            logic [AB-1:0] a_next;
            a_next = '0;
            if (data_at(e - r, blk, pi, b)) begin
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
            a_signs_in[r*AS +: AS] = (junk && e - r != E0) ? AS'({$urandom, $urandom}) : a_sign_word;
        end
        // W, north edge: PE column c at virtual edge e - c.
        for (int c = 0; c < P_C; c++) begin
            logic [WB-1:0] w_next;
            w_next = '0;
            if (data_at(e - c, blk, pi, b)) begin
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
            load_w_sign_in[c] = pass_start_at(e + 1 - c);
            if (junk && !pass_start_at(e - c))
                w_signs_in[c*WS +: WS] = WS'({$urandom, $urandom});
            else
                w_signs_in[c*WS +: WS] = (sign_pass(e - c) == 0) ? '1 : '0;
        end
        // Ring and shift.
        for (int r = 0; r < P_R; r++)
            ring_in[r] = (mode == MODE_PE || mode == MODE_NEG_COL) ? lap_at(e + 1 - r) :
                         (mode == MODE_NEG_ROW) ? lap_at(e + 1) : 1'b0;
        ring_global = (mode == MODE_GLOBAL_WAIT || mode == MODE_NEG_GLOBAL) && lap_at(e + 1);
        drain = drain_at(e, dblk, t);
        shift_in = drain || ((mode == MODE_GLOBAL_WAIT || mode == MODE_NEG_GLOBAL) && lap_at(e));
        if (drain)
            acc_in_west = '0;
        else if (junk)
            for (int n = 0; n < P_R*AW; n++) acc_in_west[n] = $urandom & 1;
        mac_en = (e > E0);
    endtask

    // Pre-edge acc_out_east of every PE row on a drain edge.
    task automatic read_drain(input int e);
        int blk, t;
        if (!drain_at(e, blk, t)) return;
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

    initial begin
        trace_file = 0;
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        junk = $test$plusargs("JUNK");
        if ($test$plusargs("GLOBAL_LAP_WAIT")) mode = MODE_GLOBAL_WAIT;
        if ($test$plusargs("NEG_RING_NO_ROW_SKEW")) mode = MODE_NEG_ROW;
        if ($test$plusargs("NEG_RING_NO_COL_SKEW")) mode = MODE_NEG_COL;
        if ($test$plusargs("NEG_GLOBAL_LAP")) mode = MODE_NEG_GLOBAL;

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
        LO = (mode == MODE_GLOBAL_WAIT) ? S : 0;
        GAP = 8 + LO;
        BLK_LEN = BW*NB + GAP*(BW-1) + S + 8*P_C;
        E_END = E0 + NBLK*BLK_LEN;               // last drain edge
        N_EDGES = E_END + 2;
        if (N_EDGES + 16 > `BPG_MAX_EDGES) $fatal(1, "schedule exceeds BPG_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("bpg_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open bpg_trace.txt");
        $fwrite(trace_file, "BPGCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, NB, GAP, LO, S, BLK_LEN, E0, mode, junk);
        cfg_done = 1'b1;

        for (int e = 0; e < N_EDGES; e++) begin
            cur_e = e;
            drive(e);
            @(posedge clk);                      // P_e
            read_drain(e);
            @(negedge clk);
        end
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = '0;
        ring_global = 1'b0;
        cur_e = N_EDGES;
        @(posedge clk);                          // flush open lap runs
        @(negedge clk);

        if (n_drain != NBLK*P_R*8*P_C)
            $fatal(1, "drained %0d columns, expected %0d", n_drain, NBLK*P_R*8*P_C);
        $fclose(trace_file);
        trace_file = 0;
        $display("PASS: BP grid bench P=%0dx%0d BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d edges=%0d mode=%0d junk=%0d",
                 P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, BLK_LEN, N_EDGES, mode, junk);
        $finish;
    end
endmodule
