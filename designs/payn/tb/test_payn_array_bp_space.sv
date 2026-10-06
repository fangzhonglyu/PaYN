`timescale 1ns/1ps

`include "common/clk_util.sv"

// BP-space (T2) INT bench for the UNCHANGED single-PE BP top
// payn_array_signed_segmented_csa_bp (csa_bp_20261004_lap RTL): weight bits
// in SPACE across tile columns, so the reduction runs straight through and
// the weight-bit factors are applied once, after the drain.
//
// Mapping (one PE, S weight bits in space, P = BW/S passes in time, CPE = 8/S
// output columns per PE):
//   tile row h     activation row i = ig*ROWS_PE + h / BA, plane h % BA
//                  (as built: INT8 / W4A8 one row of 8 planes, INT4 two rows
//                  of 4 planes, int_prec = 1)
//   tile column v  output column j = jg*CPE + v / S, weight-bit group
//                  s = v % S; in pass pi (p = P-1-pi, MSB pass first) it
//                  carries weight bit q = p + P*s
//   lane k, position m of data edge b: reduction element x = 128*b + 16*k + m.
// S = BW ("all weight bits in space", P = 1): tile (h, v=q) accumulates
// s_h * s_q * sum_x a_h[x] * w_q[x, j] (s = -1 for the top bit) through the
// existing sign path, with NO lap and NO ring: ring_in = 0 on every edge.
// a_signs row h = (h % BA == BA-1) on all lanes, w_signs column v =
// (v % S == S-1) on all lanes, both loaded ONCE before the first block and
// held for every block.  S < BW: P passes with the existing 8-edge per-PE ring
// laps between them (ring_in one edge ahead of each lap edge, shift_in only on
// drain edges: the csa_bp_20261004_lap contract); the w sign word is reloaded
// per pass ((v % S == S-1) in the first pass, zero otherwise).  S = 1 is the
// as-built T1 mapping and schedule (cross-check against test_payn_array_bp.sv
// +LAP_RING_ONLY: identical D / C records).
//
// Schedule (edge P_e = e-th posedge after the post-reset settle; E0 = first
// data capture, block base B = E0 + blk*BLK_LEN):
//   pass pi:  data captured on B + pi*(NB+8) + 0..NB-1 (MAC one edge later);
//   lap pi < P-1:  ring_q high on B + pi*(NB+8) + NB+1 .. NB+8;
//   drain:    shift_in (acc_in_west = 0) on D0 .. D0+7,
//             D0 = B + (P-1)*(NB+8) + NB + 1, the last drain edge being the
//             next block's first capture, so
//   BLK_LEN = P*NB + 8*(P-1) + 8       (P = 1: NB + 8).
// The combiner captures on the drain edges (int_mode & shift_in & ~ring_q) and
// gives, per drained column v, int_out = sum_h 2^h T(h, v) (int_prec = 0) or
// the two 4-plane halves (int_prec = 1).  The only combiner change T2 needs
// is a Horner accumulate across the drain edges of an output, east-first
// (s = S-1 first): R <- (R << P) + int_out word, R cleared on the output's
// first column; checked by the checker from the C records.
//
// Ports, all launched at the negedge before the capturing posedge P_e (the
// top's sequencer contract): int_mode = 1 from before reset; raw planes on
// a_raw_in / w_raw_in, zero planes (bubbles) outside the data edges;
// load_a / load_w carry zero magnitudes (silent comparators); mac_en = 1 from
// P_{E0+1}.
//
// Plusargs: +BA=<4|8> +BW=<4|8> +S=<1|2|4|8, S <= BW> +L=<multiple of 128>
//   +MROWS=<multiple of ROWS_PE> +NCOLS=<multiple of CPE> (defaults ROWS_PE, 8)
//   +JUNK  adversarial: Sobol running, random a/w_binary_in on every edge that
//          does not load that side, extra load_a / load_w with random sign words
//          (zero magnitudes, load_X_sign low) on random edges, random
//          acc_in_west on every non-drain edge, random int_prec on every edge
//          the combiner does not capture.
//   Negative controls (must FAIL in the checker with tile / output mismatches):
//   +NEG_WSIGN       column sign word on group s = 0 instead of s = S-1
//   +NEG_RING_STRAY  one ring_in pulse, so block 0's last pass-0 MAC edge
//                    (E0+NB) becomes a lap edge (MAC dropped, tiles rotated)
//   +NEG_DRAIN_MISS  shift_in dropped on drain step 3 of block 0
//   Tightness controls (must FAIL): +NEG_DRAIN_EARLY (drain starts on the last
//   MAC edge), +NEG_BLOCK_OVERLAP (BLK_LEN - 1: the next block's first MAC
//   lands on the last drain edge; needs >= 2 blocks).
//
// Trace (bps_trace.txt): header BPSCFG; "D blk t tile_h0..tile_h7" per
// scheduled drain read (pre-edge acc_out_east; column v = 7 - t), "E blk t e"
// its edge, "C blk t lo hi" per combiner word (two edges after each driven
// capture edge), "R e_first len" ring_q runs (RTL only).  The bench fails on X
// and on any int_out_valid edge that is not two edges after a driven capture
// ([TIMING-FAIL]); the top fails on a MAC consuming live comparator bits
// ([BP-CONTRACT]).  Checker: sweeps/int_mode/bp/space/check_bp_space_trace.py.
// Operands bpt_a.hex / bpt_w.hex (sweeps/int_mode/bp/space/gen_bp_space_workload.py).
// RTL needs DesignWare.

`ifndef GL_SIM
`include "payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv"
`endif

`ifndef PAYN_ARRAY_DUT
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa_bp
`endif
`ifndef BPS_LOW_W
`define BPS_LOW_W 9
`endif
`ifndef BPS_MAX_EDGES
`define BPS_MAX_EDGES 20000000
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int LOW_W = `BPS_LOW_W;
    localparam int E0 = 4;                      // first data capture edge
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    int BA = 8, BW = 8, S = 8, L = 128, MROWS = 0, NCOLS = 0;
    bit junk = 1'b0, neg_wsign = 1'b0, neg_ring_stray = 1'b0, neg_drain_miss = 1'b0;
    bit neg_drain_early = 1'b0, neg_block_overlap = 1'b0;
    logic [N_H*K-1:0] a_sign_word;
    int NB, P, CPE, ROWS_PE, NIG, NJG, NBLK, PASS_LEN, BLK_LEN, DS, E_END, N_EDGES;
    int cur_e = -1000;
    bit cfg_done = 1'b0;
    bit cap_hist [int];               // edges on which the bench drove a combiner capture

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    logic int_mode = 1'b1, int_prec = 1'b0, ring_in = 1'b0;
    logic [N_H*K*M-1:0] a_raw_in = '0;
    logic [N_W*K*M-1:0] w_raw_in = '0;
    logic [63:0] int_out;
    logic int_out_valid;

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]

    integer trace_file = 0;
    int n_drain = 0, n_comb = 0, n_cap = 0;

    ClkUtils #(.TIMEOUT(`BPS_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

`ifdef GL_SIM
    `PAYN_ARRAY_DUT dut (.*);
`else
    `PAYN_ARRAY_DUT #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH),
        .LOW_W(LOW_W)
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

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] BP space bench exceeded %0d cycles", `BPS_MAX_EDGES);

`ifndef GL_SIM
    // Ring-run monitor: ring_q as used on each edge (pre-edge value).
    int run_start = -1, run_len = 0;
    always @(posedge clk) begin
        if (cfg_done && trace_file != 0) begin
            if (dut.u_pe.ring_q === 1'b1) begin
                if (run_len == 0) run_start = cur_e;
                run_len++;
            end else begin
                if (dut.u_pe.ring_q !== 1'b0)
                    $fatal(1, "[X-FAIL] ring_q X at edge %0d", cur_e);
                if (run_len != 0) $fwrite(trace_file, "R %0d %0d\n", run_start, run_len);
                run_len = 0;
            end
        end
    end
`endif

    // ---------------------------------------------------------- schedule --
    function automatic bit decode(input int e, output int blk, output int u);
        if (e < E0 || e >= E0 + NBLK*BLK_LEN) return 1'b0;
        blk = (e - E0) / BLK_LEN;
        u = (e - E0) % BLK_LEN;
        return 1'b1;
    endfunction

    // Data slice captured into the bit pipes at P_e.
    function automatic bit data_at(input int e, output int blk, output int pi, output int b);
        int u;
        if (!decode(e, blk, u)) return 1'b0;
        pi = u / PASS_LEN;
        b = u % PASS_LEN;
        return pi < P && b < NB;
    endfunction

    // First capture of a pass at P_e.
    function automatic bit pass_start_at(input int e);
        int blk, pi, b;
        return data_at(e, blk, pi, b) && b == 0;
    endfunction

    // P_e is a lap edge (ring_q high).
    function automatic bit lap_at(input int e);
        int blk, u, pi, w;
        if (!decode(e, blk, u)) return 1'b0;
        if (u == 0) return 1'b0;                // block start: the drain owns it
        pi = (u - 1) / PASS_LEN;
        w = u - pi*PASS_LEN;
        return pi < P - 1 && w >= NB + 1 && w <= NB + 8;
    endfunction

    // Scheduled drain edge P_e -> block and step (column v = 7 - t).  Checks
    // the block the edge decodes to and the one before.
    function automatic bit drain_at(input int e, output int blk, output int t);
        int d0, bb;
        if (e <= E0) return 1'b0;
        bb = (e - E0) / BLK_LEN;
        for (int b = bb; b >= bb - 1 && b >= 0; b--) begin
            if (b >= NBLK) continue;
            d0 = E0 + b*BLK_LEN + (P-1)*PASS_LEN + NB + 1 + DS;
            if (e - d0 >= 0 && e - d0 < N_W) begin
                blk = b;
                t = e - d0;
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    function automatic bit drain_driven(input int e);
        int blk, t;
        if (!drain_at(e, blk, t)) return 1'b0;
        return !(neg_drain_miss && blk == 0 && t == 3);
    endfunction

    // Raw planes captured into the bit pipes at P_e.
    task automatic set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, pi, b, ig, jg, p, q, i, pa, j, x;
        a_next = '0;
        w_next = '0;
        if (data_at(e, blk, pi, b)) begin
            ig = blk / NJG;
            jg = blk % NJG;
            p = P - 1 - pi;
            for (int h = 0; h < N_H; h++) begin
                i = ig*ROWS_PE + h / BA;
                pa = h % BA;
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = b*K*M + k*M + m;
                        a_next[(h*K + k)*M + m] = a_mem[i*L + x][pa];
                    end
            end
            for (int v = 0; v < N_W; v++) begin
                j = jg*CPE + v / S;
                q = p + P*(v % S);
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = b*K*M + k*M + m;
                        w_next[(v*K + k)*M + m] = w_mem[j*L + x][q];
                    end
            end
        end
        a_raw_in = a_next;
        w_raw_in = w_next;
    endtask

    function automatic logic [N_W*K-1:0] w_sign_word(input int pi);
        logic [N_W*K-1:0] wd;
        for (int v = 0; v < N_W; v++)
            for (int k = 0; k < K; k++)
                wd[v*K + k] = (pi == 0) && ((v % S) == (neg_wsign ? 0 : S - 1));
        return wd;
    endfunction

    // Sign loads captured by the peripheral at P_e; the PE sign pipes take
    // them at P_{e+1}, the pass's first raw-plane capture edge.  P = 1: one
    // load before the first block, held for every block.
    task automatic set_signs(input int e);
        int blk, pi, b;
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
        if (e + 1 == E0) begin
            a_signs_in = a_sign_word;
            load_a = 1'b1;
            load_a_sign = 1'b1;
        end
        if (data_at(e + 1, blk, pi, b) && b == 0 && (P > 1 || e + 1 == E0)) begin
            w_signs_in = w_sign_word(pi);
            load_w = 1'b1;
            load_w_sign = 1'b1;
        end
        if (junk) begin
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

    task automatic set_binary();
        if (!junk) return;
        if (load_a)
            a_binary_in = '0;
        else
            for (int n = 0; n < N_H*K*WIDTH; n++) a_binary_in[n] = $urandom & 1;
        if (load_w)
            w_binary_in = '0;
        else
            for (int n = 0; n < N_W*K*WIDTH; n++) w_binary_in[n] = $urandom & 1;
    endtask

    // Pre-edge acc_out_east on every scheduled drain edge.
    task automatic read_drain(input int e);
        int bd, t;
        if (!drain_at(e, bd, t)) return;
        if ($isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drained column X: block %0d step %0d", bd, t);
        $fwrite(trace_file, "D %0d %0d", bd, t);
        for (int h = 0; h < N_H; h++)
            $fwrite(trace_file, " %0d", $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
        $fwrite(trace_file, "\n");
        $fwrite(trace_file, "E %0d %0d %0d\n", bd, t, e);
        n_drain++;
    endtask

    // Pre-edge combiner output: valid exactly two edges after each driven capture.
    task automatic read_comb(input int e);
        int bd, t;
        bit expect_valid;
        if ($isunknown(int_out_valid))
            $fatal(1, "[X-FAIL] int_out_valid X at edge %0d", e);
        expect_valid = cap_hist.exists(e - 2);
        if (int_out_valid !== expect_valid)
            $fatal(1, "[TIMING-FAIL] int_out_valid=%0b at edge %0d, expected %0b",
                   int_out_valid, e, expect_valid);
        if (!int_out_valid) return;
        void'(drain_at(e - 2, bd, t));
        if ($isunknown(int_out))
            $fatal(1, "[X-FAIL] int_out X: block %0d step %0d", bd, t);
        $fwrite(trace_file, "C %0d %0d %0d %0d\n", bd, t,
                $signed(int_out[31:0]), $signed(int_out[63:32]));
        n_comb++;
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
        int bd, t;
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("S=%d", S));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        junk = $test$plusargs("JUNK");
        neg_wsign = $test$plusargs("NEG_WSIGN");
        neg_ring_stray = $test$plusargs("NEG_RING_STRAY");
        neg_drain_miss = $test$plusargs("NEG_DRAIN_MISS");
        neg_drain_early = $test$plusargs("NEG_DRAIN_EARLY");
        neg_block_overlap = $test$plusargs("NEG_BLOCK_OVERLAP");

        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (!(S == 1 || S == 2 || S == 4 || S == 8) || S > BW)
            $fatal(1, "S must be 1, 2, 4 or 8 and at most BW (got S=%0d BW=%0d)", S, BW);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        NB = L / (K*M);
        P = BW / S;
        CPE = N_W / S;
        ROWS_PE = N_H / BA;
        if (MROWS <= 0) MROWS = ROWS_PE;
        if (NCOLS <= 0) NCOLS = N_W;
        if (MROWS % ROWS_PE != 0 || NCOLS % CPE != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", ROWS_PE, CPE);
        // |tile| <= fmax * L must fit OWIDTH: the weight field of one column
        // group is the full BW-bit value for S = 1, else P bits (top group
        // signed, lower groups unsigned).
        fmax = (S == 1) ? (longint'(1) << (BW-1))
                        : (((longint'(1) << P) - 1) > (longint'(1) << (P-1)) ?
                           ((longint'(1) << P) - 1) : (longint'(1) << (P-1)));
        if (fmax * L >= (longint'(1) << (OWIDTH-1)))
            $fatal(1, "L=%0d can overflow the %0d-bit accumulator (field max %0d)", L, OWIDTH, fmax);
        NIG = MROWS / ROWS_PE;
        NJG = NCOLS / CPE;
        NBLK = NIG * NJG;
        if (neg_block_overlap && NBLK < 2) $fatal(1, "NEG_BLOCK_OVERLAP needs at least two blocks");
        PASS_LEN = NB + 8;
        DS = neg_drain_early ? -1 : 0;
        BLK_LEN = P*NB + 8*(P-1) + 8 - (neg_block_overlap ? 1 : 0);
        E_END = E0 + (NBLK-1)*BLK_LEN + (P-1)*PASS_LEN + NB + 1 + DS + N_W - 1;   // last drain edge
        N_EDGES = E_END + 3;                     // + combiner latency
        if (N_EDGES + 16 > `BPS_MAX_EDGES) $fatal(1, "schedule exceeds BPS_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);
        int_mode = 1'b1;
        int_prec = (BA == 4);
        rng_en = junk;

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("bps_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open bps_trace.txt");
        $fwrite(trace_file, "BPSCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, S, L, MROWS, NCOLS, NBLK, NB, P, CPE, BLK_LEN, E0, DS, int'(BA == 4),
                junk, neg_wsign, neg_ring_stray, neg_drain_miss, neg_drain_early, neg_block_overlap);
        cfg_done = 1'b1;

        for (int e = 0; e < N_EDGES; e++) begin
            cur_e = e;
            set_raw(e);
            set_signs(e);
            set_binary();
            if (junk) begin
                if (drain_at(e, bd, t))
                    acc_in_west = '0;
                else
                    for (int n = 0; n < N_H*OWIDTH; n++) acc_in_west[n] = $urandom & 1;
            end
            ring_in = lap_at(e + 1) || (neg_ring_stray && e + 1 == E0 + NB);
            shift_in = drain_driven(e);
            if (shift_in && !lap_at(e)) begin
                cap_hist[e] = 1'b1;
                n_cap++;
            end
            int_prec = (junk && !cap_hist.exists(e)) ? ($urandom & 1) : (BA == 4);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            @(posedge clk);                      // P_e
            read_drain(e);
            read_comb(e);
            @(negedge clk);
        end
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = 1'b0;
        cur_e = N_EDGES;
        @(posedge clk);                          // flush an open ring run
        @(negedge clk);

        if (n_drain != NBLK*N_W || n_comb != n_cap)
            $fatal(1, "read %0d drained columns and %0d combiner outputs, expected %0d and %0d",
                   n_drain, n_comb, NBLK*N_W, n_cap);
        $fclose(trace_file);
        trace_file = 0;
        $display("PASS: BP space bench BA=%0d BW=%0d S=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d edges=%0d junk=%0d",
                 BA, BW, S, L, MROWS, NCOLS, NBLK, BLK_LEN, N_EDGES, junk);
        $finish;
    end
endmodule
