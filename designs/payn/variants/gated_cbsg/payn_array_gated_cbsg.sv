`ifndef PAYN_GATED_CBSG_ARRAY
`define PAYN_GATED_CBSG_ARRAY

`timescale 1ns/1ps

// Traditional C-BSG PaYN array: W's generator is gated by A, with PaYN's
// original bitstream generation.
//
//   A: exactly the original payn_array A path -- legacy sobol_bank (MODE 0,
//      A_* direction set / digital shifts, free-running across K-blocks) and the
//      sc_pe_peripheral comparator with its golden-stride Owen mask.
//   W: PaYN's original W stream (W_* direction set / shifts, W salt), but each
//      A element's W generator advances only on that element's A ones
//      (InnerPEGatedCbsg). W magnitudes are latched here and compared inside
//      every tile.
//
// Same ports as payn_array, so it drops into the benches via PAYN_ARRAY_DUT.
//   rng_restart : marks a K-block start (assert with that block's load);
//                 resets the gated W generators. The A bank keeps running.
//   stream_len  : samples per K-block (A ones at or past it are dropped).
//   d_base      : unused (the original masks are per depth/lane).
// Instance names u_a_rng / u_peripheral / u_pe / u_array_core /
// g_row_*__g_col_*__u_inner follow payn_array. There is no u_w_rng: W
// thresholds are generated per A element inside u_pe.

`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"
`include "payn/variants/gated_cbsg/inner_pe_gated_cbsg.sv"

`ifndef PAYN_K
`define PAYN_K 6
`endif
`ifndef PAYN_M
`define PAYN_M 16
`endif
`ifndef PAYN_NH
`define PAYN_NH 9
`endif
`ifndef PAYN_NW
`define PAYN_NW 9
`endif

module payn_array_gated_cbsg #(
    parameter int K = `PAYN_K,
    parameter int M = `PAYN_M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8,
    parameter int OWIDTH = 24,
    parameter logic SCRAMBLE_ENABLE = 1'b1,
    parameter int A_SCRAMBLE_SALT = 0,
    parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1)),
    parameter int A_DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] A_SHIFT_BASE   = 8'h17,
    parameter logic [WIDTH-1:0] A_SHIFT_STRIDE = 8'h53,
    parameter int W_DIRECTION_SET = 1,
    parameter logic [WIDTH-1:0] W_SHIFT_BASE   = 8'h9d,
    parameter logic [WIDTH-1:0] W_SHIFT_STRIDE = 8'h2b
) (
    input logic clk,
    input logic reset,
    input logic rng_en,
    input logic rng_restart,
    input logic [15:0] d_base,
    input logic [7:0] stream_len,
    input logic load_a,
    input logic load_w,
    input logic load_a_sign,
    input logic load_w_sign,
    input logic mac_en,
    input logic shift_in,

    input logic [N_H*K*WIDTH-1:0] a_binary_in,
    input logic [N_H*K-1:0]       a_signs_in,
    input logic [N_W*K*WIDTH-1:0] w_binary_in,
    input logic [N_W*K-1:0]       w_signs_in,

    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    // ---- A: original Sobol bank + peripheral --------------------------------
    logic [M*WIDTH-1:0] a_random_values;

    sobol_bank #(
        .WIDTH(WIDTH), .M(M),
        .DIRECTION_SET(A_DIRECTION_SET),
        .DIGITAL_SHIFT_BASE(A_SHIFT_BASE),
        .DIGITAL_SHIFT_STRIDE(A_SHIFT_STRIDE)
    ) u_a_rng (
        .clk, .reset, .enable(rng_en), .random_values(a_random_values)
    );

    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits_nc;
    logic [N_W*K-1:0]   w_signs_nc;

    // Only the A half is used; the W inputs are tied off and synthesize away.
    sc_pe_peripheral #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .SCRAMBLE_ENABLE(SCRAMBLE_ENABLE),
        .A_SCRAMBLE_SALT(A_SCRAMBLE_SALT),
        .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT)
    ) u_peripheral (
        .clk, .reset,
        .load_a, .load_w(1'b0),
        .a_binary_in, .a_signs_in,
        .w_binary_in('0), .w_signs_in('0),
        .a_random_values, .w_random_values('0), .d_base('0),
        .a_bits, .a_signs, .w_bits(w_bits_nc), .w_signs(w_signs_nc)
    );

    // ---- W magnitudes/signs, latched like the peripheral's W registers -----
    logic [N_W*K*WIDTH-1:0] w_binary_q;
    logic [N_W*K-1:0]       w_signs_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            w_binary_q <= '0;
            w_signs_q <= '0;
        end else if (load_w) begin
            w_binary_q <= w_binary_in;
            w_signs_q <= w_signs_in;
        end
    end

    // Block-start marker, registered so it lines up with the first slice of
    // the block at the peripheral output (the PE pipes it once more).
    logic restart_q;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) restart_q <= 1'b0;
        else       restart_q <= rng_restart;
    end

    // ---- gated-W PE grid ------------------------------------------------------
    InnerPEGatedCbsgFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .WIDTH(WIDTH),
        .W_DIRECTION_SET(W_DIRECTION_SET),
        .W_SHIFT_BASE(W_SHIFT_BASE), .W_SHIFT_STRIDE(W_SHIFT_STRIDE),
        .W_SCRAMBLE_ENABLE(SCRAMBLE_ENABLE), .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT)
    ) u_pe (
        .clk, .reset, .mac_en, .shift_in,
        .restart_in(restart_q), .stream_len,
        .a_bits_in(a_bits), .a_signs_in(a_signs),
        .w_mag_in(w_binary_q), .w_signs_in(w_signs_q),
        .load_a_sign_in(load_a_sign), .load_w_sign_in(load_w_sign),
        .acc_in_west, .acc_out_east
    );
endmodule

`endif
