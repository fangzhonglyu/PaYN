`ifndef PAYN_SIGNED_SEGMENTED_CLEAN_PE_TOP
`define PAYN_SIGNED_SEGMENTED_CLEAN_PE_TOP

`timescale 1ns/1ps

`include "payn/variants/signed_segmented_clean/inner_pe_signed_segmented_clean.sv"

// Standalone synthesis top for the cleaned compute core alone.  Port-for-port
// identical to sc_seg_pe_k8m16n8_lw9 in ../signed_segmented, so the two synth
// runs differ only in the PE instantiated -- see that file for why this boundary
// exists and what it is and is not good for.
module sc_seg_clean_pe_k8m16n8_lw9 #(
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
    InnerPESignedSegmentedCleanFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) u_pe (.*);
endmodule

`endif
