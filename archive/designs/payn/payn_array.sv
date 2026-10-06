`ifndef ASTRAEA_PAYN_ARRAY
`define ASTRAEA_PAYN_ARRAY

`timescale 1ns/1ps

`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"
`include "payn/inner_pe.sv"

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
    parameter logic [WIDTH-1:0] W_SHIFT_STRIDE = 8'h2b
) (
    input logic clk,
    input logic reset,        // sync for InnerPE, async for peripheral + Sobol

    input logic rng_en,       // advance both Sobol banks
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
        .DIGITAL_SHIFT_STRIDE(A_SHIFT_STRIDE)
    ) u_a_rng (
        .clk, .reset, .enable(rng_en), .random_values(a_random_values)
    );

    sobol_bank #(
        .WIDTH(WIDTH), .M(M),
        .DIRECTION_SET(W_DIRECTION_SET),
        .DIGITAL_SHIFT_BASE(W_SHIFT_BASE),
        .DIGITAL_SHIFT_STRIDE(W_SHIFT_STRIDE)
    ) u_w_rng (
        .clk, .reset, .enable(rng_en), .random_values(w_random_values)
    );

    // ---- edge peripheral: binary -> stochastic streams ----------------------
    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0]   w_signs;

    sc_pe_peripheral #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .SCRAMBLE_ENABLE(SCRAMBLE_ENABLE),
        .A_SCRAMBLE_SALT(A_SCRAMBLE_SALT),
        .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT)
    ) u_peripheral (
        .clk, .reset,
        .load_a, .load_w,
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in,
        .a_random_values, .w_random_values,
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
