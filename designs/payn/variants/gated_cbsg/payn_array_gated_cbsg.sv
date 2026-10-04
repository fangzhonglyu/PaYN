`ifndef PAYN_GATED_CBSG_ARRAY
`define PAYN_GATED_CBSG_ARRAY

`timescale 1ns/1ps

// Traditional C-BSG PaYN array: W's generator is gated by A -- each A
// element's W generator advances only on that element's A ones
// (InnerPEGatedCbsg). W magnitudes are latched here and compared inside every
// tile. The bitstream definitions are a compile-time choice, STREAMS
// (PAYN_GATED_STREAMS):
//
//   STREAMS=0  PaYN's original generation.
//     A: legacy sobol_bank (MODE 0, A_* direction set / digital shifts,
//        free-running across K-blocks) + sc_pe_peripheral golden-stride mask.
//     W: the original W stream (W_* direction set / shifts, W salt) replayed
//        in sample order. Operands: logical magnitude m as m << 1 (8-bit).
//   STREAMS=1  The scmp_kernels emulator's generation (bit-exact with its
//        C-BSG). A: sample-ordered Sobol (sobol_bank MODE 1, "q" set) restarted
//        at every K-block, column mask bitrev((d_base+depth) mod 64), 7-bit
//        grid. W: emulator rB[d][i] ("k" set, same mask, 7-bit grid).
//        Operands: thresholds b = round(|q| * 128 / 127) for both A and W.
//
// Same ports as payn_array, so it drops into the benches via PAYN_ARRAY_DUT.
//   rng_restart : marks a K-block start (assert with that block's load);
//                 resets the gated W generators (and, STREAMS=1, the A bank).
//   stream_len  : samples per K-block (A ones at or past it are dropped).
//   d_base      : STREAMS=1 K-block's first column (latched with the loads);
//                 unused with STREAMS=0.
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
`ifndef PAYN_GATED_STREAMS
`define PAYN_GATED_STREAMS 0
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
    parameter logic [WIDTH-1:0] W_SHIFT_STRIDE = 8'h2b,
    parameter int STREAMS = `PAYN_GATED_STREAMS,   // 0 = original, 1 = emulator
    parameter int RNG_SHIFT = 1                    // STREAMS=1 7-bit grid
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
        .DIGITAL_SHIFT_STRIDE(A_SHIFT_STRIDE),
        .MODE(STREAMS == 1 ? 1 : 0)
    ) u_a_rng (
        .clk, .reset, .enable(rng_en), .restart(rng_restart),
        .random_values(a_random_values)
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
        .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT),
        .MASK_MODE(STREAMS == 1 ? 1 : 0),
        .A_RNG_SHIFT(STREAMS == 1 ? RNG_SHIFT : 0)
    ) u_peripheral (
        .clk, .reset,
        .load_a, .load_w(1'b0),
        .a_binary_in, .a_signs_in,
        .w_binary_in('0), .w_signs_in('0),
        .a_random_values, .w_random_values('0), .d_base,
        .a_bits, .a_signs, .w_bits(w_bits_nc), .w_signs(w_signs_nc)
    );

    // ---- W magnitudes/signs, latched like the peripheral's W registers -----
    logic [N_W*K*WIDTH-1:0] w_binary_q;
    logic [N_W*K-1:0]       w_signs_q;
    logic [15:0]            w_d_base_q;     // STREAMS=1 W column masks

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            w_binary_q <= '0;
            w_signs_q <= '0;
            w_d_base_q <= '0;
        end else if (load_w) begin
            w_binary_q <= w_binary_in;
            w_signs_q <= w_signs_in;
            w_d_base_q <= d_base;
        end
    end

    // Slice bookkeeping, aligned with the peripheral's A bits. A slice is fresh
    // when the A bank advanced on the last edge (rng_en). The first fresh slice
    // after rng_restart starts a K-block: with rng_en on the restart edge that
    // is the slice emitted on that edge; otherwise the next one.
    logic slice_valid_q, slice_first_q, restart_pending;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            slice_valid_q <= 1'b0;
            slice_first_q <= 1'b0;
            restart_pending <= 1'b0;
        end else begin
            slice_valid_q <= rng_en;
            slice_first_q <= rng_en && (rng_restart || restart_pending);
            if (rng_en)           restart_pending <= 1'b0;
            else if (rng_restart) restart_pending <= 1'b1;
        end
    end

    // ---- gated-W PE grid ------------------------------------------------------
    InnerPEGatedCbsgFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .WIDTH(WIDTH),
        .W_DIRECTION_SET(W_DIRECTION_SET),
        .W_SHIFT_BASE(W_SHIFT_BASE), .W_SHIFT_STRIDE(W_SHIFT_STRIDE),
        .W_SCRAMBLE_ENABLE(SCRAMBLE_ENABLE), .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT),
        .STREAMS(STREAMS), .RNG_SHIFT(RNG_SHIFT)
    ) u_pe (
        .clk, .reset, .mac_en, .shift_in,
        .valid_in(slice_valid_q), .first_in(slice_first_q), .stream_len,
        .d_base_in(w_d_base_q),
        .a_bits_in(a_bits), .a_signs_in(a_signs),
        .w_mag_in(w_binary_q), .w_signs_in(w_signs_q),
        .load_a_sign_in(load_a_sign), .load_w_sign_in(load_w_sign),
        .acc_in_west, .acc_out_east
    );
endmodule

`endif
