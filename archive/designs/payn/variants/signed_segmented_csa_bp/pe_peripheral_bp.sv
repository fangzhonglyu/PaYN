`ifndef PAYN_SC_PE_PERIPHERAL_BP
`define PAYN_SC_PE_PERIPHERAL_BP

`timescale 1ns/1ps

`include "payn/pe_peripheral.sv"

// Bit-plane (BP) INT bypass around the unchanged SC edge peripheral.
//
// In BP INT mode every AND position carries one exact bit-plane bit supplied by
// the data mover on the raw operand lines:
//
//     bits = comparator | (raw & int_mode)          (one AO21 per stream bit)
//
// SC transparency is unconditional: with int_mode = 0 the raw lines reach
// nothing, whatever they toggle to.  INT exactness needs the comparators
// silent, which the sequencer guarantees by holding the magnitude registers at
// zero in INT mode (comparator = binary_q > random is 0 for binary_q = 0):
// every load_a / load_w while in INT mode carries a_binary_in / w_binary_in = 0
// (those loads exist for the plane signs), and on entering INT mode both sides
// are loaded before the first raw plane a MAC will use is captured.  The BP top
// checks this in simulation.  An OR instead of a full 2:1 select saves the
// inverted-select tree and 0.098 um2 per bit (AO21 vs AO22).
//
// The signs are untouched: load_a / load_w still register them, and in INT
// mode they carry the plane sign classes (MSB plane negative) through the
// existing two-edge sign path.  int_mode here is the top's registered mode
// bit, so the 2,048-pin select tree hangs off a flop, not a port.
module sc_pe_peripheral_bp #(
    parameter int K = 6,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int WIDTH = 8,
    parameter logic SCRAMBLE_ENABLE = 1'b1,
    parameter int A_SCRAMBLE_SALT = 0,
    parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1))
) (
    input logic clk,
    input logic reset,
    input logic load_a,
    input logic load_w,

    input logic [N_H*K*WIDTH-1:0] a_binary_in,
    input logic [N_H*K-1:0] a_signs_in,
    input logic [N_W*K*WIDTH-1:0] w_binary_in,
    input logic [N_W*K-1:0] w_signs_in,

    input logic [M*WIDTH-1:0] a_random_values,
    input logic [M*WIDTH-1:0] w_random_values,

    // BP INT mode: raw bit-plane operands, same packing as a_bits / w_bits.
    input logic int_mode,
    input logic [N_H*K*M-1:0] a_raw_in,
    input logic [N_W*K*M-1:0] w_raw_in,

    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0] a_signs,
    output logic [N_W*K*M-1:0] w_bits,
    output logic [N_W*K-1:0] w_signs
);
    logic [N_H*K*M-1:0] sc_a_bits;
    logic [N_W*K*M-1:0] sc_w_bits;

    sc_pe_peripheral #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .SCRAMBLE_ENABLE(SCRAMBLE_ENABLE),
        .A_SCRAMBLE_SALT(A_SCRAMBLE_SALT),
        .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT)
    ) u_sc (
        .clk, .reset, .load_a, .load_w,
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in,
        .a_random_values, .w_random_values,
        .a_bits(sc_a_bits), .a_signs,
        .w_bits(sc_w_bits), .w_signs
    );

    assign a_bits = sc_a_bits | (a_raw_in & {(N_H*K*M){int_mode}});
    assign w_bits = sc_w_bits | (w_raw_in & {(N_W*K*M){int_mode}});
endmodule

`endif
