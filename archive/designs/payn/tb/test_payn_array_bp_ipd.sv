`timescale 1ns/1ps

`include "common/clk_util.sv"

// Bit-plane (BP) INT bench for the IN-PLACE-DOUBLING top
// payn_array_signed_segmented_csa_bp_ipd (schedule T3), driving the REAL INT
// ports (no forces).  A copy of designs/payn/tb/test_payn_array_bp.sv (the
// csa_bp_20261004_lap bench, whose defaults are unchanged) with the lap length
// as a runtime knob:
//
//   +LAP_LEN=<n>  ring_in edges (= ring_q lap edges) between weight passes;
//                 default 1, the IPD contract (one edge doubles every tile in
//                 place).  A non-final pass takes NB + LAP_LEN edges, the
//                 final pass NB + N_W (the drain), so a block takes
//                     BLK_LEN = BW*NB + LAP_LEN*(BW-1) + N_W   edges.
//                 LAP_LEN=8 is the original bench's schedule exactly (the
//                 BP ring needs 8 edges): compiled with +define+BPT_DUT_BP
//                 against the BP top, this bench must reproduce the original
//                 bench's traces byte for byte (run_bp_ipd_rtl_checks.sh).
//                 On the IPD top, LAP_LEN=0 (no lap), 2 (double lap) and 8
//                 (the BP lap) are negative controls: the checker must fail.
//                 Opt-in: +define+BPT_DUT_SR compiles against the sub-ring top
//                 payn_array_signed_segmented_csa_bp_sr (LAP_G from
//                 +define+PAYN_LAP_G=<g>, default 2), run at +LAP_LEN=<g>
//                 (sweeps/int_mode/bp/sr/run_bp_sr_rtl_checks.sh).
//   +NEG_NO_BUBBLE  tightness control (lap term): every non-final pass is one
//                 edge shorter, so the first lap edge is the MAC edge of the
//                 pass's last data slice (dropped by shift priority).  Must
//                 FAIL.
//   +NEG_RING_STRAY_MID  negative control: one stray ring_in pulse that makes
//                 the edge of the middle data slice of the first block's
//                 second pass a lap edge (a doubling of non-zero partial sums
//                 plus a dropped MAC).  Must FAIL.
// The bench also writes bpt_sched.txt (LAP_LEN, PASS_LEN, LAST_LEN, BLK_LEN
// and the edge of every block's first drain step) for the period table.
//
// Everything below is the original bench's description, with "8-edge lap"
// read as "LAP_LEN-edge lap".
//
// Mapping (one PE): row h carries activation plane p = h % BA of activation
// row i = ig*ROWS_PE + h / BA; column v carries output column j = jg*8 + v.
// Lane k / position m of data cycle b carries reduction element
// x = 128*b + 16*k + m.  Weight planes go in time, MSB pass first: in pass q,
// w_raw_in[v][k][m] = bit q of W[x, j].  INT8: BA = BW = 8; W4A8: BA = 8,
// BW = 4; INT4: BA = BW = 4 (two activation rows per block, int_prec = 1).
//
// Ports, all launched at the negedge before the capturing posedge P_e, per the
// sequencer contract in the top's header:
//  * int_mode high from before reset (or from +MODE_AT); it is registered, so
//    raw planes reach the bit pipes from the second edge it is high on;
//  * a_raw_in / w_raw_in: the planes captured into the PE bit pipes at P_e;
//  * signs through the existing two-edge path (peripheral register, then PE
//    sign pipe): a_signs_in = (h % BA == BA-1), loaded once; w_signs_in = all
//    ones for the weight-MSB pass, else zero; load_w + load_w_sign at P_e for
//    a pass whose first raw plane is captured at P_{e+1}.  Every load carries
//    zero magnitudes (a_binary_in = w_binary_in = 0), so the comparators stay
//    silent;
//  * ring_in: the PE registers it (ring_q, the per-PE lap enable), so ring_in
//    sampled at P_e makes P_{e+1} a ring-lap edge.  It is driven one edge
//    ahead of each lap edge;
//  * shift_in on every tile-shift edge, lap edges included (the as-built
//    csa_bp_20261003b contract, still legal: tile shift = shift_in | ring_q),
//    or with +LAP_RING_ONLY on drain edges only (the csa_bp_20261004_lap
//    contract: ring_q alone shifts on lap edges); acc_in_west = 0 on drain
//    edges.  The combiner captures on drain edges only
//    (int_mode & shift_in & ~ring_q);
//  * zero raw planes (bubbles) while a lap or drain runs; int_prec = (BA == 4)
//    held for the whole run; mac_en = 1 from P_{E0+1}.
//
// Schedule (edge P_e = e-th posedge after the post-reset settle; E0 = first
// data capture).  Inside a block, non-final pass pi (q = BW-1-pi) occupies
// PASS_LEN = NB + LAP_LEN edges: u = 0..NB-1 capture data, the rest capture
// zero bubbles; its lap edges are the last LAP_LEN-1 edges of the pass and
// u = 0 of the following pass.  The final pass occupies LAST_LEN = NB + N_W
// edges; its shift edges u = NB+1..NB+N_W-1 and u = 0 of the next block are
// the drain, which overlaps the next block's first pass.  (LAP_LEN = N_W = 8:
// the original bench's PASS_LEN = NB + 8 schedule.)
//
// Trace (bpt_trace.txt): every drained column ("D blk t tile_h0..tile_h7",
// column v = 7 - t) and every combiner output ("C blk t lo hi"), checked
// against numpy int64 by sweeps/int_mode/bp/check_bp_trace.py.  The bench
// itself fails on X and on any int_out_valid edge that is not exactly two
// edges after a drain edge ([TIMING-FAIL]); the top's simulation check fails
// on a MAC that consumes live comparator bits ([BP-CONTRACT]).
//
// Runtime configuration (plusargs, one compile serves the whole matrix):
//   +BA=<4|8> +BW=<4|8> +L=<multiple of 128> +MROWS=<n> +NCOLS=<multiple of 8>
//   +MODE_AT=<e>  int_mode low until P_e (raised at the negedge before it);
//                 E0-1 = 3 is the latest legal edge
//   +JUNK         adversarial: Sobol running, random a/w_binary_in on every
//                 edge that does not load that side, extra load_a / load_w with
//                 random sign words (zero magnitudes) on random edges, random
//                 acc_in_west on every non-drain edge (lap edges included);
//                 the bypass, sign path and ring mux must hide them
//   +NEG_NO_RING  negative control: ring_in never asserted (laps become drains:
//                 the combiner fires off-schedule, [TIMING-FAIL])
//   +NEG_PREC     negative control: int_prec inverted (checker must FAIL)
//   +LAP_RING_ONLY  per-PE lap-enable contract (csa_bp_20261004_lap): shift_in
//                 only on drain edges, the laps run on ring_q alone.  (Was
//                 +NEG_NO_LAP_SHIFT, a negative control while ring_q only
//                 steered the west mux; on that RTL the checker FAILS.)
//   +NEG_RING_STRAY  negative control for the new contract: one stray ring_in
//                 pulse (shift_in low) one edge ahead of the first block's
//                 first MAC edge.  ring_q now shifts by itself, so that edge
//                 becomes a lap edge (MAC dropped, tiles rotated): checker
//                 must FAIL.  (On the csa_bp_20261003b RTL it was harmless.)
//   +NEG_MAG      negative control: Sobol running and every edge loads random
//                 magnitudes (the pre-contract JUNK): [BP-CONTRACT]
// Operands: bpt_a.hex (A row-major, MROWS x L) and bpt_w.hex (W column-major,
// W[x, j] at j*L + x), one two's-complement byte per line, from
// sweeps/int_mode/bp/gen_bp_workload.py.  RTL needs DesignWare (USE_DW=1).

`ifndef GL_SIM
`ifdef BPT_DUT_SR
`include "payn/variants/signed_segmented_csa_bp_sr/payn_array_signed_segmented_csa_bp_sr.sv"
`elsif BPT_DUT_BP
`include "payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv"
`else
`include "payn/variants/signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv"
`endif
`endif

`ifndef PAYN_ARRAY_DUT
`ifdef BPT_DUT_SR
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa_bp_sr
`elsif BPT_DUT_BP
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa_bp
`else
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa_bp_ipd
`endif
`endif
`ifndef BPT_LOW_W
`define BPT_LOW_W 9
`endif
`ifndef BPT_MAX_EDGES
`define BPT_MAX_EDGES 1000000
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
    localparam int LOW_W = `BPT_LOW_W;
    localparam int E0 = 4;                      // first data capture edge
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    // Runtime configuration and derived schedule constants.
    int BA = 8, BW = 8, L = 128, MROWS = 1, NCOLS = 8, MODE_AT = -1;
    bit junk = 1'b0, neg_no_ring = 1'b0, neg_prec = 1'b0;
    bit lap_ring_only = 1'b0, neg_ring_stray = 1'b0, neg_mag = 1'b0;
    int LAP_LEN = 1;
    bit neg_no_bubble = 1'b0, neg_ring_stray_mid = 1'b0;
    integer sched_file;
    logic [N_H*K-1:0] a_sign_word;
    int NB, ROWS_PE, NIG, NJG, NBLK, PASS_LEN, LAST_LEN, BLK_LEN;
    int E_DATA_END, E_END, N_EDGES;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    logic int_mode = 1'b0, int_prec = 1'b0, ring_in = 1'b0;
    logic [N_H*K*M-1:0] a_raw_in = '0;
    logic [N_W*K*M-1:0] w_raw_in = '0;
    logic [63:0] int_out;
    logic int_out_valid;

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]

    integer trace_file;
    int n_drain = 0, n_comb = 0;

    ClkUtils #(.TIMEOUT(`BPT_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

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
        if (timeout) $fatal(1, "[TIMEOUT] BP INT bench exceeded %0d cycles", `BPT_MAX_EDGES);

`ifndef GL_SIM
    // Lap coverage (RTL only): on every lap edge (ring_q high, pre-edge
    // values) count the tiles whose pending carry / borrow is set, i.e. lap
    // edges that must fold a pending +-1 into the doubled value.  Printed as
    // LAP_COVERAGE at the end; the exactness itself is checked by the trace.
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
`endif

    // ---------------------------------------------------------- schedule --
    function automatic void decode(input int e, output int blk, output int pi,
                                   output int u);
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

    // The shift at P_e is a ring-lap shift.
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

    // Drain edge P_e -> (block, step t); step t delivers column v = 7 - t.
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

    // Raw planes captured into the bit pipes at P_e.
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

    // Sign loads captured by the peripheral at P_e, so the PE sign pipes
    // take them at P_{e+1}, the pass's first raw-plane capture edge.  JUNK
    // adds loads with random sign words on other edges: load_X_sign stays low
    // there, so the PE sign pipes never take them.
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
        if (neg_mag) begin
            load_a = 1'b1;
            load_w = 1'b1;
        end
    endtask

    // Magnitude lines: zero on every edge that loads that side (INT contract);
    // under JUNK random on the others, where nothing loads them.  NEG_MAG loads
    // random magnitudes.
    task automatic set_binary();
        if (!(junk || neg_mag)) return;
        if (load_a && !neg_mag)
            a_binary_in = '0;
        else
            for (int n = 0; n < N_H*K*WIDTH; n++) a_binary_in[n] = $urandom & 1;
        if (load_w && !neg_mag)
            w_binary_in = '0;
        else
            for (int n = 0; n < N_W*K*WIDTH; n++) w_binary_in[n] = $urandom & 1;
    endtask

    // Random west data on every edge that is not a drain (lap edges take the
    // ring value, every other edge does not shift).
    task automatic set_west_junk(input int e);
        if (drain_at(e))
            acc_in_west = '0;
        else
            for (int n = 0; n < N_H*OWIDTH; n++) acc_in_west[n] = $urandom & 1;
    endtask

    // Pre-edge acc_out_east on a drain edge.
    task automatic read_drain(input int e);
        int bd, t;
        if (!drain_at(e)) return;
        drain_slot(e, bd, t);
        if (t == 0) $fwrite(sched_file, "DRAIN_START %0d %0d\n", bd, e);
        if ($isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drained column X: block %0d step %0d", bd, t);
        $fwrite(trace_file, "D %0d %0d", bd, t);
        for (int h = 0; h < N_H; h++)
            $fwrite(trace_file, " %0d", $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
        $fwrite(trace_file, "\n");
        n_drain++;
    endtask

    // Pre-edge combiner output: valid exactly two edges after each drain edge.
    task automatic read_comb(input int e);
        int bd, t;
        bit expect_valid;
        if ($isunknown(int_out_valid))
            $fatal(1, "[X-FAIL] int_out_valid X at edge %0d", e);
        expect_valid = (e >= 2) && drain_at(e - 2);
        if (int_out_valid !== expect_valid)
            $fatal(1, "[TIMING-FAIL] int_out_valid=%0b at edge %0d, expected %0b",
                   int_out_valid, e, expect_valid);
        if (!int_out_valid) return;
        drain_slot(e - 2, bd, t);
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
        if (LAP_LEN < 0 || LAP_LEN > 64) $fatal(1, "LAP_LEN=%0d out of range", LAP_LEN);
        if (neg_no_bubble && LAP_LEN < 1) $fatal(1, "NEG_NO_BUBBLE needs LAP_LEN >= 1");

        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        NB = L / (K*M);
        ROWS_PE = N_H / BA;
        if (MROWS < ROWS_PE || MROWS % ROWS_PE != 0 || NCOLS < N_W || NCOLS % N_W != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", ROWS_PE, N_W);
        // |tile value| <= 2^(BW-1) * L must fit the OWIDTH-bit accumulator.
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
        N_EDGES = E_END + 3;                     // + combiner latency
        if (N_EDGES + 16 > `BPT_MAX_EDGES) $fatal(1, "schedule exceeds BPT_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);
        a_signs_in = a_sign_word;
        int_mode = (MODE_AT < 0);
        int_prec = (BA == 4) ^ neg_prec;
        rng_en = junk || neg_mag;

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("bpt_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open bpt_trace.txt");
        sched_file = $fopen("bpt_sched.txt", "w");
        if (sched_file == 0) $fatal(1, "cannot open bpt_sched.txt");
        $fwrite(sched_file, "SCHED lap_len=%0d pass_len=%0d last_len=%0d blk_len=%0d nb=%0d bw=%0d nblk=%0d formula=%0d\n",
                LAP_LEN, PASS_LEN, LAST_LEN, BLK_LEN, NB, BW, NBLK, BW*NB + LAP_LEN*(BW-1) + N_W);
        $fwrite(trace_file, "BPTCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, int_prec, junk, neg_no_ring, neg_prec,
                lap_ring_only, neg_mag, MODE_AT, neg_ring_stray);

        // Each iteration starts at the negedge before P_e, where every input
        // is launched (the route's SDC input delay is half a period).
        for (int e = 0; e < N_EDGES; e++) begin
            if (e == MODE_AT) int_mode = 1'b1;
            set_raw(e);
            set_signs(e);
            set_binary();
            if (junk) set_west_junk(e);
            ring_in = (!neg_no_ring && ring_at(e + 1)) || (neg_ring_stray && e + 1 == E0 + 1) ||
                      (neg_ring_stray_mid && e + 1 == E0 + PASS_LEN + NB/2 + 1);
            shift_in = lap_ring_only ? drain_at(e) : core_shift_at(e);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            @(posedge clk);                      // P_e
            read_drain(e);
            read_comb(e);
            @(negedge clk);
        end
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = 1'b0;

        if (n_drain != NBLK*N_W || n_comb != NBLK*N_W)
            $fatal(1, "drained %0d columns and %0d combiner outputs, expected %0d each",
                   n_drain, n_comb, NBLK*N_W);
        $fclose(trace_file);
        $fclose(sched_file);
`ifndef GL_SIM
        $display("LAP_COVERAGE lap_edges=%0d tile_laps=%0d with_pending_carry=%0d with_pending_borrow=%0d",
                 cov_lap_edges, cov_tile_laps, cov_pending_carry, cov_pending_borrow);
`endif
        $display("PASS: BP INT bench BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d edges=%0d junk=%0d mode_at=%0d lap_ring_only=%0d lap_len=%0d block_len=%0d",
                 BA, BW, L, MROWS, NCOLS, NBLK, N_EDGES, junk, MODE_AT, lap_ring_only, LAP_LEN, BLK_LEN);
        $finish;
    end
endmodule
