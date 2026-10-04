`ifndef ASTRAEA_PAYN_ARRAY
`define ASTRAEA_PAYN_ARRAY

`timescale 1ns/1ps

`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"
`include "payn/inner_pe.sv"

// Default shape is `ifndef-driven so the synth flow can sweep configs via
// SYN_DEFINES (e.g. SYN_DEFINES="PAYN_K=8 PAYN_M=16 PAYN_NH=8 PAYN_NW=8").
`ifndef PAYN_K
`define PAYN_K 8
`endif
`ifndef PAYN_M
`define PAYN_M 16
`endif
`ifndef PAYN_NH
`define PAYN_NH 8
`endif
`ifndef PAYN_NW
`define PAYN_NW 8
`endif

// PaYN SC array with conditional bitstream generation (C-BSG), bit-exact with
// the scmp_kernels emulator's C-BSG (sc_matmul, SC_MULT_SCHEME=cbsg):
//
//   A: rate-encoded. u_a_rng emits M consecutive Sobol "q" words per cycle,
//      restarted at every K-block; u_peripheral compares bA against
//      (word ^ bitrev((d_base+depth) mod 64)) >> RNG_SHIFT  (= rA[d][t] < bA).
//   W: generated per A element inside u_pe, advancing only on A ones; the
//      i-th A one of a K-block meets W sample i = rB[d][i] ("k" words, the same
//      column mask), compared against each column's bB per tile.
//
// Operands are the emulator's comparator thresholds b = round(|q| * 128 / 127)
// (0..128) for both A and W, with separate sign bits.
//
//   rng_en      : advance A's Sobol bank (one M-sample slice per cycle)
//   rng_restart : K-block start -- assert with that block's loads; restarts
//                 A's bank and the gated W generators (gapless with rng_en)
//   d_base      : K-block's first column (latched with the loads)
//   stream_len  : samples per K-block, L (1..128); samples past it are dropped
//   load_a/w    : latch this K-block's A / W operands (and d_base)
//   load_*_sign : load signs into the PE pipe
//   mac_en      : accumulate one slice
//   shift_in    : row-serial drain (east)
module payn_array #(
    parameter int K = `PAYN_K,
    parameter int M = `PAYN_M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8,
    parameter int OWIDTH = 24,
    parameter int A_DIRECTION_SET = 0,
    parameter int W_DIRECTION_SET = 1,
    parameter int N_MASKS = 64,
    parameter int RNG_SHIFT = 1
) (
    input logic clk,
    input logic reset,        // sync for InnerPE, async for peripheral + Sobol
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
    // ---- A: Sobol bank + peripheral -----------------------------------------
    logic [M*WIDTH-1:0] a_random_values;

    sobol_bank #(
        .WIDTH(WIDTH), .M(M), .DIRECTION_SET(A_DIRECTION_SET)
    ) u_a_rng (
        .clk, .reset, .enable(rng_en), .restart(rng_restart),
        .random_values(a_random_values)
    );

    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;

    sc_pe_peripheral #(
        .K(K), .M(M), .N_H(N_H), .WIDTH(WIDTH),
        .N_MASKS(N_MASKS), .RNG_SHIFT(RNG_SHIFT)
    ) u_peripheral (
        .clk, .reset, .load_a,
        .a_binary_in, .a_signs_in, .d_base, .a_random_values,
        .a_bits, .a_signs
    );

    // ---- W magnitudes / signs / column base, latched per K-block ------------
    logic [N_W*K*WIDTH-1:0] w_binary_q;
    logic [N_W*K-1:0]       w_signs_q;
    logic [15:0]            w_d_base_q;

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

    // ---- slice bookkeeping, aligned with the peripheral's A bits ------------
    // A slice is fresh when the A bank advanced on the last edge (rng_en). The
    // first fresh slice after rng_restart starts a K-block: with rng_en on the
    // restart edge that is the slice emitted on that edge; otherwise the next.
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

    // ---- C-BSG PE grid -------------------------------------------------------
    InnerPEFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .WIDTH(WIDTH),
        .W_DIRECTION_SET(W_DIRECTION_SET), .N_MASKS(N_MASKS), .RNG_SHIFT(RNG_SHIFT)
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
