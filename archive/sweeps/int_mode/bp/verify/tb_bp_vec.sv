`timescale 1ns/1ps

// Independent vector-driven bench for payn_array_signed_segmented_csa_bp
// (adversarial INT-mode verification; does not share code with
// designs/payn/tb/test_payn_array_bp.sv or sweeps/int_mode/bp/*.py).
//
// The whole cycle schedule (reset, int_mode, int_prec, ring_in, shift_in,
// mac_en, load strobes, sign words, raw planes, acc_in_west) is computed by
// sweeps/int_mode/bp/verify/bpv_gen.py and written one record per clock edge
// to bpv_vec.hex.  This bench only applies the records and dumps the DUT
// outputs, so timing errors can be injected from Python without touching RTL.
//
// Timing convention: record n is launched at the negedge before posedge P_n.
// Immediately before launching record n the bench samples the outputs (the
// state after P_{n-1}, i.e. the pre-edge values P_n will see) and writes trace
// line n: "<int_out_valid> <int_out> <acc_out_east>" in hex (x on unknowns).
// Sampling at the negedge is race-free with respect to the posedge NBAs.
//
// Record layout (one hex word per line, LSB = bit 0):
//   [0] reset  [1] int_mode  [2] int_prec  [3] ring_in  [4] shift_in
//   [5] mac_en [6] load_a    [7] load_w    [8] load_a_sign [9] load_w_sign
//   [10] rng_en [11] junk_bin (bench drives random a/w_binary_in this edge)
//   [12] zero_bin (bench drives a/w_binary_in = 0 this edge; added for the
//        post-review contract: INT-mode loads carry zero magnitudes)
//   [16 +: 1024]   a_raw_in     [1040 +: 1024] w_raw_in
//   [2064 +: 64]   a_signs_in   [2128 +: 64]   w_signs_in
//   [2192 +: 192]  acc_in_west  (record width 2384 bits = 596 hex digits)
// First line of bpv_vec.hex: "<n_records>" in decimal.

`include "payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv"

`ifndef BPV_LOW_W
`define BPV_LOW_W 9
`endif

module TbBpVec;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int REC_W = 2384;
    localparam real PERIOD = 2.5;

    logic clk = 1'b0;
    always #(PERIOD/2) clk = ~clk;

    logic reset = 1'b1, rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
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

    payn_array_signed_segmented_csa_bp #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH),
        .LOW_W(`BPV_LOW_W)
    ) dut (.*);

    logic [REC_W-1:0] rec;
    int fd_in, fd_out, n_rec, code;

    initial begin
        fd_in = $fopen("bpv_vec.hex", "r");
        if (fd_in == 0) $fatal(1, "cannot open bpv_vec.hex");
        code = $fscanf(fd_in, "%d\n", n_rec);
        if (code != 1 || n_rec <= 0) $fatal(1, "bad record count");
        fd_out = $fopen("bpv_trace.txt", "w");
        if (fd_out == 0) $fatal(1, "cannot open bpv_trace.txt");

        for (int n = 0; n < n_rec; n++) begin
            code = $fscanf(fd_in, "%h\n", rec);
            if (code != 1) $fatal(1, "short vector file at record %0d", n);
            if (n > 0) @(negedge clk);
            $fwrite(fd_out, "%h %h %h\n", int_out_valid, int_out, acc_out_east);
            reset       = rec[0];
            int_mode    = rec[1];
            int_prec    = rec[2];
            ring_in     = rec[3];
            shift_in    = rec[4];
            mac_en      = rec[5];
            load_a      = rec[6];
            load_w      = rec[7];
            load_a_sign = rec[8];
            load_w_sign = rec[9];
            rng_en      = rec[10];
            if (rec[11]) begin
                for (int b = 0; b < N_H*K*WIDTH; b++) a_binary_in[b] = $urandom;
                for (int b = 0; b < N_W*K*WIDTH; b++) w_binary_in[b] = $urandom;
            end
            if (rec[12]) begin
                a_binary_in = '0;
                w_binary_in = '0;
            end
            a_raw_in    = rec[16 +: N_H*K*M];
            w_raw_in    = rec[1040 +: N_W*K*M];
            a_signs_in  = rec[2064 +: N_H*K];
            w_signs_in  = rec[2128 +: N_W*K];
            acc_in_west = rec[2192 +: N_H*OWIDTH];
        end
        // One more sample: the state after the last record's edge.
        @(negedge clk);
        $fwrite(fd_out, "%h %h %h\n", int_out_valid, int_out, acc_out_east);
        $fclose(fd_out);
        $display("BPV_DONE records=%0d", n_rec);
        $finish;
    end
endmodule
