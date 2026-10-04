`ifndef ASTRAEA_PAYN_ARRAY
`define ASTRAEA_PAYN_ARRAY

`timescale 1ns/1ps

`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"
`include "payn/inner_pe.sv"
`include "payn/a_encoder.sv"

// Default shape is `ifndef-driven so the synth flow can sweep configs via
// SYN_DEFINES (e.g. SYN_DEFINES="PAYN_K=8 PAYN_M=8 PAYN_NH=4 PAYN_NW=4").
// Defaults are unchanged (K6/M16/9x9); benches pass explicit params, so this
// only affects synthesis elaboration.
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
`ifndef PAYN_STREAM_MODE
`define PAYN_STREAM_MODE 0
`endif
`ifndef PAYN_RNG_SHIFT
`define PAYN_RNG_SHIFT 1
`endif
`ifndef PAYN_A_ENCODER
`define PAYN_A_ENCODER 0
`endif
`ifndef PAYN_A_CBSG
`define PAYN_A_CBSG 0
`endif

// PaYN SC array: shared Sobol banks + edge peripheral + one InnerPE tile grid,
// wired into a single synth/PnR/power target. Binary edge operands
// (magnitude + sign) enter; the two Sobol banks drive the peripheral's
// stochastic-stream comparators; the InnerPE grid accumulates output-stationary
// and drains row-serially on `shift_in`.
//
// The default bank configuration (A: identity DVs seed 0x17/0x53; W: decorrelated
// DVs seed 0x9d/0x2b; peripheral salts 0 / 2^(WIDTH-1)) matches the sc_kernel.py
// ArrayCfg defaults so the array is bit-exact against the Python reference.
module payn_array #(
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
    // STREAM_MODE=0: legacy (both operands Sobol-compared, plain AND).
    // STREAM_MODE=1: unary temporal A + sample-ordered Sobol W, plain AND.
    //   A lanes are the sample index c*M+m, so a_binary_in = k gives a
    //   thermometer stream of k ones (k = round(b*L/G) is the host-side
    //   quantization of the A magnitude onto L samples). W lanes are samples
    //   c*M .. c*M+M-1 of the W_DIRECTION_SET Sobol sequence, XOR'd with the
    //   per-column mask bitrev((d_base+depth) mod 64) and shifted right by
    //   RNG_SHIFT. Because A's ones are contiguous from sample 0, this plain
    //   AND equals gating W's generator on the A bit, and samples past L
    //   are zero without extra masking (k <= L).
    parameter int STREAM_MODE = `PAYN_STREAM_MODE,
    parameter int RNG_SHIFT = `PAYN_RNG_SHIFT,  // STREAM_MODE=1 only
    // A_ENCODER=1 (STREAM_MODE=1 only): on-chip A encoder (sc_a_encoder).
    //   a_binary_in is then the A threshold bA (same encoding as W) for the
    //   NEXT K-block -- A runs one block ahead of W -- and the encoder turns it
    //   into kA under the compile-time scheme A_CBSG:
    //     0 = UT    : kA = round(bA * L / 128)
    //     1 = C-BSG : kA = #ones of A's Sobol stream (emulator k_table)
    //   L comes from stream_len. A_ENCODER=0 keeps a_binary_in = kA from the host.
    parameter int A_ENCODER = `PAYN_A_ENCODER,
    parameter int A_CBSG = `PAYN_A_CBSG       // A_ENCODER=1 only (synth: PAYN_A_CBSG)
) (
    input logic clk,
    input logic reset,        // sync for InnerPE, async for peripheral + Sobol

    input logic rng_en,       // advance both Sobol banks
    input logic rng_restart = 1'b0,   // STREAM_MODE=1: restart streams at t=0
    input logic [15:0] d_base = '0,   // STREAM_MODE=1: K-block's first column (latched with load_a/load_w)
    input logic [7:0] stream_len = 8'd128,  // A_ENCODER=1: stream length L
    input logic load_a,       // latch A binary operands into the peripheral
    input logic load_w,       // latch W binary operands into the peripheral
    input logic load_a_sign,  // load A signs into the InnerPE pipe
    input logic load_w_sign,  // load W signs into the InnerPE pipe
    input logic mac_en,       // accumulate one stochastic cycle
    input logic shift_in,     // row-serial drain shift (east)

    input logic [N_H*K*WIDTH-1:0] a_binary_in,
    input logic [N_H*K-1:0]       a_signs_in,
    input logic [N_W*K*WIDTH-1:0] w_binary_in,
    input logic [N_W*K-1:0]       w_signs_in,

    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    // ---- shared Sobol banks -------------------------------------------------
    logic [M*WIDTH-1:0] a_random_values;
    logic [M*WIDTH-1:0] w_random_values;

    sobol_bank #(
        .WIDTH(WIDTH), .M(M),
        .DIRECTION_SET(A_DIRECTION_SET),
        .DIGITAL_SHIFT_BASE(A_SHIFT_BASE),
        .DIGITAL_SHIFT_STRIDE(A_SHIFT_STRIDE),
        .MODE(STREAM_MODE == 1 ? 2 : 0)
    ) u_a_rng (
        .clk, .reset, .enable(rng_en), .restart(rng_restart),
        .random_values(a_random_values)
    );

    sobol_bank #(
        .WIDTH(WIDTH), .M(M),
        .DIRECTION_SET(W_DIRECTION_SET),
        .DIGITAL_SHIFT_BASE(W_SHIFT_BASE),
        .DIGITAL_SHIFT_STRIDE(W_SHIFT_STRIDE),
        .MODE(STREAM_MODE == 1 ? 1 : 0)
    ) u_w_rng (
        .clk, .reset, .enable(rng_en), .restart(rng_restart),
        .random_values(w_random_values)
    );

    // ---- optional A encoder (STREAM_MODE=1, A_ENCODER=1) --------------------
    logic [N_H*K*WIDTH-1:0] periph_a_binary;
    logic [N_H*K-1:0]       periph_a_signs;
    logic [15:0]            periph_d_base;

    if (STREAM_MODE == 1 && A_ENCODER == 1) begin : g_a_encoder
        sc_a_encoder #(
            .K(K), .M(M), .N_H(N_H), .WIDTH(WIDTH), .RNG_SHIFT(RNG_SHIFT),
            .CBSG(A_CBSG)
        ) u_a_encoder (
            .clk, .reset,
            .load(load_a), .enable(rng_en),
            .stream_len,
            .a_binary_in, .a_signs_in, .d_base_in(d_base),
            .a_k_out(periph_a_binary), .a_signs_out(periph_a_signs),
            .d_base_out(periph_d_base)
        );
    end else begin : g_no_a_encoder
        assign periph_a_binary = a_binary_in;
        assign periph_a_signs = a_signs_in;
        assign periph_d_base = d_base;
    end

    // ---- edge peripheral: binary -> stochastic streams ----------------------
    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0]   w_signs;

    sc_pe_peripheral #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .SCRAMBLE_ENABLE(SCRAMBLE_ENABLE),
        .A_SCRAMBLE_SALT(A_SCRAMBLE_SALT),
        .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT),
        .A_SCRAMBLE_ENABLE(STREAM_MODE == 1 ? 1'b0 : SCRAMBLE_ENABLE),
        .MASK_MODE(STREAM_MODE == 1 ? 1 : 0),
        .W_RNG_SHIFT(STREAM_MODE == 1 ? RNG_SHIFT : 0)
    ) u_peripheral (
        .clk, .reset,
        .load_a, .load_w,
        .a_binary_in(periph_a_binary), .a_signs_in(periph_a_signs),
        .w_binary_in, .w_signs_in,
        .a_random_values, .w_random_values, .d_base(periph_d_base),
        .a_bits, .a_signs, .w_bits, .w_signs
    );

    // ---- InnerPE tile grid (single PE) --------------------------------------
    // Systolic passthrough outputs are unused for a single PE.
    logic [N_H*K*M-1:0] a_bits_out_nc;
    logic [N_H*K-1:0]   a_signs_out_nc;
    logic [N_W*K*M-1:0] w_bits_out_nc;
    logic [N_W*K-1:0]   w_signs_out_nc;
    logic load_a_sign_out_nc, load_w_sign_out_nc;

    InnerPEFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) u_pe (
        .clk, .reset, .mac_en, .shift_in,
        .a_bits_in(a_bits),   .a_signs_in(a_signs),
        .w_bits_in(w_bits),   .w_signs_in(w_signs),
        .load_a_sign_in(load_a_sign), .load_w_sign_in(load_w_sign),
        .a_bits_out(a_bits_out_nc),   .a_signs_out(a_signs_out_nc),
        .w_bits_out(w_bits_out_nc),   .w_signs_out(w_signs_out_nc),
        .load_a_sign_out(load_a_sign_out_nc),
        .load_w_sign_out(load_w_sign_out_nc),
        .acc_in_west, .acc_out_east
    );
endmodule

`endif
