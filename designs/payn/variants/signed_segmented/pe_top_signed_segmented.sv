`ifndef PAYN_SIGNED_SEGMENTED_PE_TOP
`define PAYN_SIGNED_SEGMENTED_PE_TOP

`timescale 1ns/1ps

`include "payn/variants/signed_segmented/inner_pe_signed_segmented.sv"

// Standalone synthesis top for the segmented compute core alone -- the array
// without its Sobol banks, comparator peripheral and top-level glue.  Isolates
// u_pe, which is ~86% of full-design power, so a core-only A/B is not diluted
// by the ~14% that the RTL change cannot affect.
//
// Parameters are pinned rather than taken from `PAYN_* macros because DC
// elaborates this top with its defaults.  Matches the accepted array point:
// K=8, M=16, N=8x8, OWIDTH=24, LOW_W=9.
//
// Caveat: the M=16 stochastic streams are on-chip wires in the full array and
// become ~2.2k primary ports here, so this boundary is artificial by
// construction -- the same caveat the older SC_INNER_PE target carries.  Use it
// to compare two PEs against each other, not against the embedded u_pe.
module sc_seg_pe_k8m16n8_lw9 #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic [N_H*K*M-1:0] a_bits_in,
    input  logic [N_H*K-1:0]   a_signs_in,
    input  logic [N_W*K*M-1:0] w_bits_in,
    input  logic [N_W*K-1:0]   w_signs_in,
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,
    output logic [N_H*K*M-1:0] a_bits_out,
    output logic [N_H*K-1:0]   a_signs_out,
    output logic [N_W*K*M-1:0] w_bits_out,
    output logic [N_W*K-1:0]   w_signs_out,
    output logic load_a_sign_out,
    output logic load_w_sign_out,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    InnerPESignedSegmentedFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) u_pe (.*);
endmodule

`endif
