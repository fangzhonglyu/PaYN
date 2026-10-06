`timescale 1ns/1ps

`include "common/clk_util.sv"

// BP-space (T2) INT bench for a P_R x P_C grid of the UNCHANGED carry-save BP
// PE (InnerPESignedSegmentedCsaBpGrid, csa_bp_20261004_lap RTL): weight bits
// in SPACE across tile columns, so the reduction runs straight through and
// the weight-bit factors are applied once, after the drain.  Edge-drive
// conventions as designs/payn/tb/test_pe_grid_bp.sv (which is not changed).
//
// Mapping (S weight bits in space, P = BW/S passes in time, CPE = 8/S output
// columns per PE).  Output block (ig, jg); PE (r,c):
//   tile row h     activation row i = (ig*P_R + r)*ROWS_PE + h / BA, plane h % BA
//   tile column v  output column j = (jg*P_C + c)*CPE + v / S, weight-bit
//                  group s = v % S; in pass pi (p = P-1-pi, MSB pass first)
//                  it carries weight bit q = p + P*s
//   lane k, position m of data slice b: reduction element x = 128*b + 16*k + m.
// INT8 S = 8: PE (r,c) computes ONE output (i, j) = (ig*P_R + r, jg*P_C + c);
// tile (h, q) accumulates s_h * s_q * sum_x a_h[x] * w_q[x, j] (s = -1 for the
// top bit) through the existing sign path; ring_in = 0 on every edge, no lap.
// a_signs row h = (h % BA == BA-1), w_signs column v = (v % S == S-1), all
// lanes, both loaded ONCE before the first block (sign waves skewed like the
// operands) and held for every block.  S < BW: P passes with the existing
// 8-edge per-PE ring laps between them (ring_in[r] one edge ahead of PE (r,0)'s
// lap edges, with row r's A skew; PE (r,c) laps at offset r+c); the w sign
// word is reloaded per pass ((v % S == S-1) in the first pass, zero after).
// S = 1 is the as-built T1 mapping and schedule (cross-check against
// test_pe_grid_bp.sv: identical D / R records).
// The checker forms out = sum_{h in row} 2^(h % BA) sum_s 2^(P*s) T(h, jj*S+s)
// from the drained tiles (the east-edge combiner plus a Horner step over the
// S columns of an output).
//
// Edge drive (the edge peripherals' job; the bench plays them).  Every input
// is launched at the negedge before the capturing posedge P_e.  Virtual edge u
// is PE (0,0)'s schedule time; PE (r,c) sees it r+c edges late:
//  * a_bits_in[r] at P_e: raw activation planes of virtual edge e - r;
//    w_bits_in[c] at P_e: raw weight planes of virtual edge e - c;
//  * load_a_sign_in[r] one edge ahead of row r's first capture; load_w_sign_in[c]
//    one edge ahead of column c's first capture (P = 1) or of every pass start;
//  * shift_in ONLY on the 8*P_C final drain edges of each block (acc_in_west
//    = 0 there); mac_en = 1 from P_{E0+1}; int_mode = 1.
//
// Schedule (virtual edges relative to the block base B = E0 + blk*BLK_LEN):
// pass pi starts at B + pi*(NB+GAP); NB data slices, then GAP bubble slices.
// PE (0,0) laps on B + pi*(NB+GAP) + NB + LO + 1 .. + 8 for pi < P-1.  Drain
// (real edges, global): D0 = B + (P-1)*(NB+GAP) + NB + 1 + DS, DS = Sk =
// P_R + P_C - 2, for 8*P_C edges; the last drain edge is the next block's
// first capture, so
//     BLK_LEN = P*NB + GAP*(P-1) + Sk + 8*P_C     (GAP = 8, LO = 0)
// which for S = BW (P = 1) is NB + Sk + 8*P_C: the model's T2 period
// (sweeps/int_mode/bp/model_lap_schedules.py).
//
// Reset: the operand bit pipes are not reset, so the first MAC must come at
// least min(P_R,P_C) zero-plane edges after the reset starts (grid header):
// 1 pre-reset + 2 reset + 2 settle + (E0+1) = 10 edges here.
//
// Plusargs: +BA=<4|8> +BW=<4|8> +S=<1|2|4|8, S <= BW> +L=<multiple of 128>
//   +MROWS=<multiple of P_R*ROWS_PE> +NCOLS=<multiple of P_C*CPE>
//   +JUNK  random acc_in_west on every non-drain edge, random sign words on
//          every edge where no PE latches them.
//   Negative controls (must FAIL with tile / output mismatches):
//   +NEG_WSIGN       column sign word on group s = 0 instead of s = S-1
//   +NEG_RING_STRAY  one ring_in[0] pulse: PE (0,c) laps on its last pass-0
//                    MAC edge of block 0 (E0+NB+c; the wave rides row 0)
//   +NEG_DRAIN_MISS  shift_in dropped on drain step 3 of block 0
//   Tightness controls (must FAIL): +NEG_DRAIN_EARLY (DS = Sk-1: drain on the
//   far PE's last MAC), +NEG_BLOCK_OVERLAP (BLK_LEN - 1: the next block's
//   first MAC lands on the last drain edge; >= 2 blocks), +NEG_GAP_SHORT
//   (P > 1: GAP = 7, LO = -1, each lap starts on the PE's last MAC of the pass).
//
// Trace (bpg_trace.txt, the format of test_pe_grid_bp.sv with header
// BPSGCFG): "D blk r t e tile_h0..tile_h7" per scheduled drain read (PE row r,
// PE column P_C-1-t/8, tile column 7-t%8), "R r c e_first len" per PE ring_q
// run.  Checker: sweeps/int_mode/bp/space/check_bp_space_trace.py.
// Shape: +define+BPG_PR=, +define+BPG_PC= (compile time).  Operands
// bpt_a.hex / bpt_w.hex (sweeps/int_mode/bp/space/gen_bp_space_workload.py).
// RTL needs DesignWare.

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
`define BPG_MAX_EDGES 2000000
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
    localparam int SK = P_R + P_C - 2;          // skew of the far PE
    localparam int E0 = 4;                      // first capture, PE (0,0)
    localparam real PERIOD = 2.5;
    localparam int AB = N_H*K*M, AS = N_H*K, WB = N_W*K*M, WS = N_W*K, AW = N_H*OWIDTH;
    localparam int ZERO_EDGES_BEFORE_MAC = 10;  // see "Reset" above

    localparam int MODE_PE = 0, MODE_NEG_WSIGN = 1, MODE_NEG_RING_STRAY = 2,
                   MODE_NEG_DRAIN_MISS = 3, MODE_NEG_DRAIN_EARLY = 4,
                   MODE_NEG_BLOCK_OVERLAP = 5, MODE_NEG_GAP_SHORT = 6;

    int BA = 8, BW = 8, S = 8, L = 128, MROWS = 0, NCOLS = 0;
    int mode = MODE_PE;
    bit junk = 1'b0;
    bit cfg_done = 1'b0;
    int NB, P, CPE, ROWS_PE, NIG, NJG, NBLK, GAP, LO, DS, BLK_LEN, E_END, N_EDGES;
    int cur_e = -1000;
    logic [AS-1:0] a_sign_word;

    logic clk, reset, timeout;
    logic mac_en = 1'b0, shift_in = 1'b0, int_mode = 1'b1;
    logic [P_R-1:0] ring_in = '0;
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
        if (timeout) $fatal(1, "[TIMEOUT] BP space grid bench exceeded %0d cycles", `BPG_MAX_EDGES);

    // Lap-run monitor per PE: ring_q as used on each edge (pre-edge value).
    for (genvar r = 0; r < P_R; r++) begin : g_mon_r
        for (genvar c = 0; c < P_C; c++) begin : g_mon_c
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
    function automatic bit decode(input int v, output int blk, output int u);
        if (v < E0 || v >= E0 + NBLK*BLK_LEN) return 1'b0;
        blk = (v - E0) / BLK_LEN;
        u = (v - E0) % BLK_LEN;
        return 1'b1;
    endfunction

    // Data slice captured at virtual edge v: block, pass, slice.
    function automatic bit data_at(input int v, output int blk, output int pi, output int b);
        int u;
        if (!decode(v, blk, u)) return 1'b0;
        pi = u / (NB + GAP);
        b = u % (NB + GAP);
        return pi < P && b < NB;
    endfunction

    // Lap edge in PE (0,0) time.
    function automatic bit lap_at(input int v);
        int blk, u, pi, w;
        if (!decode(v, blk, u)) return 1'b0;
        if (u == 0) return 1'b0;                // block start: the drain owns it
        pi = (u - 1) / (NB + GAP);
        w = u - pi*(NB + GAP);
        return pi < P - 1 && w >= NB + LO + 1 && w <= NB + LO + 8;
    endfunction

    // First capture of a pass at virtual edge v (P = 1: only the run's first).
    function automatic bit w_load_at(input int v);
        int blk, pi, b;
        if (!data_at(v, blk, pi, b) || b != 0) return 1'b0;
        return P > 1 || v == E0;
    endfunction

    // Pass whose sign word is in force at virtual edge v (0 before the run).
    function automatic int sign_pass(input int v);
        int blk, u, pi;
        if (!decode(v, blk, u)) return 0;
        pi = u / (NB + GAP);
        return (pi < P) ? pi : P - 1;
    endfunction

    function automatic logic [WS-1:0] w_sign_word(input int pi);
        logic [WS-1:0] wd;
        for (int v = 0; v < N_W; v++)
            for (int k = 0; k < K; k++)
                wd[v*K + k] = (pi == 0) && ((v % S) == ((mode == MODE_NEG_WSIGN) ? 0 : S - 1));
        return wd;
    endfunction

    // Scheduled global drain edge (real time): block and step.
    function automatic bit drain_at(input int e, output int blk, output int t);
        int d0, bb;
        if (e <= E0) return 1'b0;
        bb = (e - E0) / BLK_LEN;
        for (int b = bb; b >= bb - 1 && b >= 0; b--) begin
            if (b >= NBLK) continue;
            d0 = E0 + b*BLK_LEN + (P-1)*(NB + GAP) + NB + 1 + DS;
            if (e - d0 >= 0 && e - d0 < 8*P_C) begin
                blk = b;
                t = e - d0;
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    // ----------------------------------------------------------- drivers --
    task automatic drive(input int e);
        int blk, pi, b, ig, jg, p, q, i, j, x, pa, t, dblk;
        bit drain;
        // A, west edge: PE row r at virtual edge e - r.
        for (int r = 0; r < P_R; r++) begin
            logic [AB-1:0] a_next;
            a_next = '0;
            if (data_at(e - r, blk, pi, b)) begin
                ig = blk / NJG;
                for (int h = 0; h < N_H; h++) begin
                    i = (ig*P_R + r)*ROWS_PE + h / BA;
                    pa = h % BA;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = b*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[i*L + x][pa];
                        end
                end
            end
            a_bits_in[r*AB +: AB] = a_next;
            load_a_sign_in[r] = (e + 1 - r == E0);
            a_signs_in[r*AS +: AS] = (junk && e - r != E0) ? AS'({$urandom, $urandom}) : a_sign_word;
        end
        // W, north edge: PE column c at virtual edge e - c.
        for (int c = 0; c < P_C; c++) begin
            logic [WB-1:0] w_next;
            w_next = '0;
            if (data_at(e - c, blk, pi, b)) begin
                jg = blk % NJG;
                p = P - 1 - pi;
                for (int v = 0; v < N_W; v++) begin
                    j = (jg*P_C + c)*CPE + v / S;
                    q = p + P*(v % S);
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = b*K*M + k*M + m;
                            w_next[(v*K + k)*M + m] = w_mem[j*L + x][q];
                        end
                end
            end
            w_bits_in[c*WB +: WB] = w_next;
            load_w_sign_in[c] = w_load_at(e + 1 - c);
            if (junk && !w_load_at(e - c))
                w_signs_in[c*WS +: WS] = WS'({$urandom, $urandom});
            else
                w_signs_in[c*WS +: WS] = w_sign_word(sign_pass(e - c));
        end
        // Ring (per-PE laps, row r's A skew) and the global drain shift.
        for (int r = 0; r < P_R; r++)
            ring_in[r] = lap_at(e + 1 - r);
        if (mode == MODE_NEG_RING_STRAY && e + 1 == E0 + NB)
            ring_in[0] = 1'b1;
        drain = drain_at(e, dblk, t);
        shift_in = drain && !(mode == MODE_NEG_DRAIN_MISS && dblk == 0 && t == 3);
        if (drain)
            acc_in_west = '0;
        else if (junk)
            for (int n = 0; n < P_R*AW; n++) acc_in_west[n] = $urandom & 1;
        mac_en = (e > E0);
    endtask

    // Pre-edge acc_out_east of every PE row on a scheduled drain edge.
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
        longint fmax;
        trace_file = 0;
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("S=%d", S));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        junk = $test$plusargs("JUNK");
        if ($test$plusargs("NEG_WSIGN")) mode = MODE_NEG_WSIGN;
        if ($test$plusargs("NEG_RING_STRAY")) mode = MODE_NEG_RING_STRAY;
        if ($test$plusargs("NEG_DRAIN_MISS")) mode = MODE_NEG_DRAIN_MISS;
        if ($test$plusargs("NEG_DRAIN_EARLY")) mode = MODE_NEG_DRAIN_EARLY;
        if ($test$plusargs("NEG_BLOCK_OVERLAP")) mode = MODE_NEG_BLOCK_OVERLAP;
        if ($test$plusargs("NEG_GAP_SHORT")) mode = MODE_NEG_GAP_SHORT;
        if (ZERO_EDGES_BEFORE_MAC < ((P_R < P_C) ? P_R : P_C))
            $fatal(1, "grid %0dx%0d needs %0d zero-plane edges before the first MAC (operand pipes are not reset)",
                   P_R, P_C, (P_R < P_C) ? P_R : P_C);

        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (!(S == 1 || S == 2 || S == 4 || S == 8) || S > BW)
            $fatal(1, "S must be 1, 2, 4 or 8 and at most BW (got S=%0d BW=%0d)", S, BW);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        NB = L / (K*M);
        P = BW / S;
        CPE = N_W / S;
        ROWS_PE = N_H / BA;
        if (mode == MODE_NEG_GAP_SHORT && P < 2) $fatal(1, "NEG_GAP_SHORT needs P = BW/S >= 2");
        if (MROWS <= 0) MROWS = P_R*ROWS_PE;
        if (NCOLS <= 0) NCOLS = P_C*CPE;
        if (MROWS % (P_R*ROWS_PE) != 0 || NCOLS % (P_C*CPE) != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", P_R*ROWS_PE, P_C*CPE);
        fmax = (S == 1) ? (longint'(1) << (BW-1))
                        : (((longint'(1) << P) - 1) > (longint'(1) << (P-1)) ?
                           ((longint'(1) << P) - 1) : (longint'(1) << (P-1)));
        if (fmax * L >= (longint'(1) << (OWIDTH-1)))
            $fatal(1, "L=%0d can overflow the %0d-bit accumulator (field max %0d)", L, OWIDTH, fmax);
        NIG = MROWS / (P_R*ROWS_PE);
        NJG = NCOLS / (P_C*CPE);
        NBLK = NIG * NJG;
        if (mode == MODE_NEG_BLOCK_OVERLAP && NBLK < 2) $fatal(1, "NEG_BLOCK_OVERLAP needs at least two blocks");
        LO = (mode == MODE_NEG_GAP_SHORT) ? -1 : 0;
        GAP = 8 + LO;
        DS = (mode == MODE_NEG_DRAIN_EARLY) ? SK - 1 : SK;
        BLK_LEN = P*NB + GAP*(P-1) + DS + 8*P_C - ((mode == MODE_NEG_BLOCK_OVERLAP) ? 1 : 0);
        E_END = E0 + (NBLK-1)*BLK_LEN + (P-1)*(NB + GAP) + NB + 1 + DS + 8*P_C - 1;   // last drain edge
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
        $fwrite(trace_file, "BPSGCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                P_R, P_C, BA, BW, S, L, MROWS, NCOLS, NBLK, NB, P, CPE, GAP, LO, SK, DS, BLK_LEN, E0,
                mode, int'(junk));
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
        cur_e = N_EDGES;
        @(posedge clk);                          // flush open lap runs
        @(negedge clk);

        if (n_drain != NBLK*P_R*8*P_C)
            $fatal(1, "drained %0d columns, expected %0d", n_drain, NBLK*P_R*8*P_C);
        $fclose(trace_file);
        trace_file = 0;
        $display("PASS: BP space grid bench P=%0dx%0d BA=%0d BW=%0d S=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d edges=%0d mode=%0d junk=%0d",
                 P_R, P_C, BA, BW, S, L, MROWS, NCOLS, NBLK, BLK_LEN, N_EDGES, mode, junk);
        $finish;
    end
endmodule
