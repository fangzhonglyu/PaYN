`ifndef PAYN_STRATIFIED_SNG_AREA_TOPS
`define PAYN_STRATIFIED_SNG_AREA_TOPS

`timescale 1ns/1ps

// Matched synthesis tops for the edge stochastic number generator alone:
// held binary operands + Sobol banks + comparator/decoder logic, with the M-bit
// lane outputs as ports.  payn_sng_baseline is exactly the logic the popcount
// array instantiates outside u_pe; payn_sng_strat swaps in the lane-stratified
// peripheral and needs only M >> G Sobol lanes per side.

`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"
`include "payn/variants/stratified_sng/pe_peripheral_strat.sv"

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

module payn_sng_baseline #(
    parameter int K = `PAYN_K,
    parameter int M = `PAYN_M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8
) (
    input  logic clk,
    input  logic reset,
    input  logic rng_en,
    input  logic load_a,
    input  logic load_w,
    input  logic [N_H*K*WIDTH-1:0] a_binary_in,
    input  logic [N_H*K-1:0]       a_signs_in,
    input  logic [N_W*K*WIDTH-1:0] w_binary_in,
    input  logic [N_W*K-1:0]       w_signs_in,
    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0]   a_signs,
    output logic [N_W*K*M-1:0] w_bits,
    output logic [N_W*K-1:0]   w_signs
);
    logic [M*WIDTH-1:0] a_random_values, w_random_values;

    sobol_bank #(.WIDTH(WIDTH), .M(M), .DIRECTION_SET(0),
                 .DIGITAL_SHIFT_BASE(8'h17), .DIGITAL_SHIFT_STRIDE(8'h53))
        u_a_rng (.clk, .reset, .enable(rng_en), .random_values(a_random_values));
    sobol_bank #(.WIDTH(WIDTH), .M(M), .DIRECTION_SET(1),
                 .DIGITAL_SHIFT_BASE(8'h9d), .DIGITAL_SHIFT_STRIDE(8'h2b))
        u_w_rng (.clk, .reset, .enable(rng_en), .random_values(w_random_values));

    sc_pe_peripheral #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH))
        u_peripheral (.clk, .reset, .load_a, .load_w,
                      .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in,
                      .a_random_values, .w_random_values,
                      .a_bits, .a_signs, .w_bits, .w_signs);
endmodule

module payn_sng_strat #(
    parameter int K = `PAYN_K,
    parameter int M = `PAYN_M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8,
    parameter int G_A = 2,
    parameter int G_W = 2
) (
    input  logic clk,
    input  logic reset,
    input  logic rng_en,
    input  logic load_a,
    input  logic load_w,
    input  logic [N_H*K*WIDTH-1:0] a_binary_in,
    input  logic [N_H*K-1:0]       a_signs_in,
    input  logic [N_W*K*WIDTH-1:0] w_binary_in,
    input  logic [N_W*K-1:0]       w_signs_in,
    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0]   a_signs,
    output logic [N_W*K*M-1:0] w_bits,
    output logic [N_W*K-1:0]   w_signs
);
    localparam int GA = M >> G_A;
    localparam int GW = M >> G_W;
    logic [GA*WIDTH-1:0] a_random_values;
    logic [GW*WIDTH-1:0] w_random_values;

    sobol_bank #(.WIDTH(WIDTH), .M(GA), .DIRECTION_SET(0),
                 .DIGITAL_SHIFT_BASE(8'h17), .DIGITAL_SHIFT_STRIDE(8'h53))
        u_a_rng (.clk, .reset, .enable(rng_en), .random_values(a_random_values));
    sobol_bank #(.WIDTH(WIDTH), .M(GW), .DIRECTION_SET(1),
                 .DIGITAL_SHIFT_BASE(8'h9d), .DIGITAL_SHIFT_STRIDE(8'h2b))
        u_w_rng (.clk, .reset, .enable(rng_en), .random_values(w_random_values));

    ScPePeripheralStrat #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
                          .G_A(G_A), .G_W(G_W))
        u_peripheral (.clk, .reset, .load_a, .load_w,
                      .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in,
                      .a_random_values, .w_random_values,
                      .a_bits, .a_signs, .w_bits, .w_signs);
endmodule

`endif
