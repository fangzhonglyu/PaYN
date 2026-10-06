// Copied from build/cbsg/af_ipd/adv_review/tb_adv_directed.sv (review of the AF-IPD variant, 2026-10-05),
// sha256 1317f6b13a48d4cef428759560974bf917355b7d8f3e91f6e2a09daeff05e40b; module renamed TbReviewCutBlock.
// Run by sweeps/cbsg/af_ipd/review_fix_ab.sh on the pre-fix and the fixed AF-IPD top.
`timescale 1ns/1ps
// Reviewer directed bench: a contract-legal SC -> INT -> SC sequence in which
// the INT zero-loads carry a nonzero a_len_in (a don't-care in INT mode per the
// top header) and rng_en stays low in INT mode, after an SC block of C = 1
// cycle (the AF counter stays at cyc = 1, not IDLE).  The AF-IPD top's
// [CBSG-AF-CONTRACT] monitor must not count an error.  The SC block after INT
// is compared against an AF top that ran the same SC blocks with no INT
// segment in between (same operands, fresh slice).
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/payn_array_signed_segmented_csa_cbsg_af_ipd.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv"

module TbReviewCutBlock;
    localparam int K = 8, M = 16, N_H = 8, N_W = 8, WIDTH = 8, OWIDTH = 24, LOW_W = 9;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset, rng_en, load_a, load_w, load_a_sign, load_w_sign, mac_en, shift_in;
    logic [N_H*K*WIDTH-1:0] a_binary_in;
    logic [N_H*K-1:0] a_signs_in;
    logic [N_W*K*WIDTH-1:0] w_binary_in;
    logic [N_W*K-1:0] w_signs_in;
    logic [N_H*OWIDTH-1:0] acc_in_west = '0, east_dut, east_af;
    logic [N_H*WIDTH-1:0] a_len_in;
    logic block_start, slice_start;
    logic int_mode, int_prec, ring_in;
    logic [N_H*K*M-1:0] a_raw_in;
    logic [N_W*K*M-1:0] w_raw_in;
    logic [63:0] int_out;
    logic int_out_valid;
    // AF reference: its own inputs (SC blocks only)
    logic r_rng_en, r_load, r_mac_en, r_shift, r_block_start;
    logic [N_H*WIDTH-1:0] sc_len;

    payn_array_signed_segmented_csa_cbsg_af_ipd #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)) dut (
        .clk, .reset, .rng_en, .load_a, .load_w, .load_a_sign, .load_w_sign, .mac_en, .shift_in,
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in, .acc_in_west, .acc_out_east(east_dut),
        .a_len_in, .block_start, .slice_start, .int_mode, .int_prec, .ring_in, .a_raw_in, .w_raw_in,
        .int_out, .int_out_valid);

    payn_array_signed_segmented_csa_cbsg_af #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)) ref_af (
        .clk, .reset, .rng_en(r_rng_en), .load_a(r_load), .load_w(r_load), .load_a_sign(r_load),
        .load_w_sign(r_load), .mac_en(r_mac_en), .shift_in(r_shift),
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in, .acc_in_west, .acc_out_east(east_af),
        .a_len_in(sc_len), .block_start(r_block_start), .slice_start(1'b0));

    logic [N_H*OWIDTH-1:0] d_dut [$], d_af [$];
    int len_int, c_blk;

    task automatic idle();
        rng_en = 0; load_a = 0; load_w = 0; load_a_sign = 0; load_w_sign = 0; mac_en = 0; shift_in = 0;
        block_start = 0; slice_start = 0; ring_in = 0; int_prec = 0;
        r_rng_en = 0; r_load = 0; r_mac_en = 0; r_shift = 0; r_block_start = 0;
    endtask

    // one SC block of C cycles + drain, on both tops (dut_too = 0: the AF top only)
    task automatic sc_block(input bit dut_too, input bit af_too);
        // B
        @(negedge clk); idle();
        if (dut_too) begin block_start = 1; load_a = 1; load_w = 1; load_a_sign = 1; load_w_sign = 1; a_len_in = sc_len; end
        if (af_too) begin r_block_start = 1; r_load = 1; end
        for (int c = 0; c < c_blk; c++) begin
            @(negedge clk); idle();
            if (dut_too) rng_en = 1;
            if (af_too) r_rng_en = 1;
            if (c >= 1) begin if (dut_too) mac_en = 1; if (af_too) r_mac_en = 1; end
        end
        @(negedge clk); idle(); if (dut_too) mac_en = 1; if (af_too) r_mac_en = 1;   // MAC of the last cycle (B+C+1)
        for (int s = 0; s < N_W; s++) begin
            @(negedge clk); idle();
            if (dut_too) shift_in = 1;
            if (af_too) r_shift = 1;
            if (s > 0) begin
                if (dut_too) d_dut.push_back(east_dut);
                if (af_too) d_af.push_back(east_af);
            end
        end
        @(negedge clk); idle();
        if (dut_too) d_dut.push_back(east_dut);
        if (af_too) d_af.push_back(east_af);
    endtask

    initial begin
        if (!$value$plusargs("LEN_INT=%d", len_int)) len_int = 128;
        if (!$value$plusargs("C=%d", c_blk)) c_blk = 1;
        idle(); int_mode = 0; a_raw_in = '0; w_raw_in = '0;
        void'($urandom(5));
        for (int i = 0; i < N_H*K; i++) a_binary_in[i*WIDTH +: WIDTH] = $urandom % 129;
        for (int i = 0; i < N_W*K; i++) w_binary_in[i*WIDTH +: WIDTH] = $urandom % 129;
        a_signs_in = {$urandom, $urandom}; w_signs_in = {$urandom, $urandom};
        for (int h = 0; h < N_H; h++) sc_len[h*WIDTH +: WIDTH] = 8'(16 * c_blk);
        a_len_in = sc_len;
        reset = 1; repeat (3) @(negedge clk); reset = 0;
        // SC block 1 on both tops
        sc_block(1, 1);
        // INT segment on the AF-IPD top only: zero-load with a nonzero a_len_in
        // (don't-care), rng_en low, a few raw MAC edges, an 8-edge drain
        @(negedge clk); idle(); int_mode = 1;
        load_a = 1; load_w = 1; load_a_sign = 1; load_w_sign = 1;
        a_binary_in = '0; w_binary_in = '0;
        for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = 8'(len_int);
        for (int e = 0; e < 6; e++) begin
            @(negedge clk); idle();
            for (int i = 0; i < N_H*K*M; i += 32) begin a_raw_in[i +: 32] = $urandom; w_raw_in[i +: 32] = $urandom; end
            if (e >= 1) mac_en = 1;
        end
        @(negedge clk); idle(); mac_en = 1; a_raw_in = '0; w_raw_in = '0;
        for (int s = 0; s < N_W; s++) begin @(negedge clk); idle(); shift_in = 1; end
        // INT -> SC on E_END+1 (the AF top runs the same SC block; restore operands)
        @(negedge clk); idle(); int_mode = 0;
        void'($urandom(5));
        for (int i = 0; i < N_H*K; i++) a_binary_in[i*WIDTH +: WIDTH] = $urandom % 129;
        for (int i = 0; i < N_W*K; i++) w_binary_in[i*WIDTH +: WIDTH] = $urandom % 129;
        a_signs_in = {$urandom, $urandom}; w_signs_in = {$urandom, $urandom};
        // sc_block starts with its own negedge; the previous negedge stays idle (gap of 1)
        sc_block(1, 1);
        repeat (3) @(negedge clk);
        $display("DIR len_int %0d C %0d: AF-IPD contract_errors %0d, AF contract_errors %0d", len_int, c_blk,
                 dut.contract_errors, ref_af.contract_errors);
        if (d_dut.size() != d_af.size()) $display("DIR drain count %0d vs %0d", d_dut.size(), d_af.size());
        begin
            int bad = 0;
            for (int i = 0; i < d_dut.size() && i < d_af.size(); i++) if (d_dut[i] !== d_af[i]) bad++;
            $display("DIR drains differing from the AF top: %0d of %0d", bad, d_dut.size());
        end
        $finish;
    end
endmodule
