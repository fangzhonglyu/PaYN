`ifndef PAYN_PE_GRID_SV
`define PAYN_PE_GRID_SV

`timescale 1ns/1ps

`include "payn/rtl/payn_pe.sv"

// P_ROWS x P_COLS outer grid of PEs (PaynPe).  Pure wiring apart from one AND
// per PE row:
//
//   A bits / signs and load_a_sign   wave east across PE columns
//   W bits / signs and load_w_sign   wave south across PE rows
//   ring (lap enable)                waves east across PE columns
//   accumulators                     chain west -> east through every PE column
//
// Every PE re-registers what it forwards, so each wave advances one PE per
// edge.  The west-edge ring inputs are gated by int_mode, so in SC mode no lap
// can start.
//
// Edge skew (the edge peripherals' job; this module has none): A slice t
// enters PE row r on edge t + r, W slice t enters PE column c on edge t + c,
// so both meet in PE (r,c) on edge t + r + c.
//
// Laps.  Inject ring_in[r] for one edge with row r's A skew, one edge ahead of
// PE (r,0)'s lap edge; the wave reaches PE (r,c) c edges later, so every PE
// laps exactly when its own pass ends (offset r+c).  The MAC on a lap edge is
// dropped, so a pass is followed by one bubble slice.  The global shift_in is
// used only for the final drain (8*P_COLS edges with acc_in_west = 0 once the
// far PE has finished): PEs on different anti-diagonals lap on different
// edges, so a global shift on a lap edge would shift PEs that are not lapping.
// A wave already in a row finishes whatever int_mode does.
//
// INT block periods (edges), NB = L/128 data slices per pass:
//   bit-plane schedule (A bits in space)    BW*NB + (BW-1) + (P_ROWS+P_COLS-2) + 8*P_COLS
//   all-bits-in-time schedule               BA*BW*NB + (BA+BW-2) + (P_ROWS+P_COLS-2) + 8*P_COLS
//
// Reset: the operand bit pipes are not reset, so the first MAC after a reset
// must come at least min(P_ROWS,P_COLS) edges after the reset starts.
// ring_out[r] is PE (r, P_COLS-1)'s ring_q, for an east-edge combiner per PE
// row (capture on int_mode & shift_in & ~ring_out[r]).  mac_en is global;
// zero planes contribute exactly zero.
module PaynPeGrid #(
    parameter int P_ROWS = 2,
    parameter int P_COLS = 2,
    parameter int K = 16,
    parameter int M = 8,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic int_mode,
    input  logic [P_ROWS-1:0] ring_in,

    input  logic [P_ROWS*N_H*K*M-1:0] a_bits_in,
    input  logic [P_ROWS*N_H*K-1:0]   a_signs_in,
    input  logic [P_COLS*N_W*K*M-1:0] w_bits_in,
    input  logic [P_COLS*N_W*K-1:0]   w_signs_in,
    input  logic [P_ROWS-1:0]         load_a_sign_in,
    input  logic [P_COLS-1:0]         load_w_sign_in,

    output logic [P_ROWS*N_H*K*M-1:0] a_bits_out,
    output logic [P_ROWS*N_H*K-1:0]   a_signs_out,
    output logic [P_COLS*N_W*K*M-1:0] w_bits_out,
    output logic [P_COLS*N_W*K-1:0]   w_signs_out,
    output logic [P_ROWS-1:0]         load_a_sign_out,
    output logic [P_COLS-1:0]         load_w_sign_out,
    output logic [P_ROWS-1:0]         ring_out,

    input  logic [P_ROWS*N_H*OWIDTH-1:0] acc_in_west,
    output logic [P_ROWS*N_H*OWIDTH-1:0] acc_out_east
);
    localparam int AB = N_H*K*M;     // one PE row's A bits
    localparam int AS = N_H*K;
    localparam int WB = N_W*K*M;     // one PE column's W bits
    localparam int WS = N_W*K;
    localparam int AW = N_H*OWIDTH;  // one PE row's accumulator rows

    initial begin
        assert (P_ROWS > 0 && P_COLS > 0)
            else $fatal(1, "P_ROWS and P_COLS must be positive");
    end

    logic [AB-1:0] a_bits_link  [P_ROWS][P_COLS+1];
    logic [AS-1:0] a_signs_link [P_ROWS][P_COLS+1];
    logic          load_a_link  [P_ROWS][P_COLS+1];
    logic          ring_link    [P_ROWS][P_COLS+1];
    logic [AW-1:0] acc_link     [P_ROWS][P_COLS+1];
    logic [WB-1:0] w_bits_link  [P_COLS][P_ROWS+1];
    logic [WS-1:0] w_signs_link [P_COLS][P_ROWS+1];
    logic          load_w_link  [P_COLS][P_ROWS+1];

    for (genvar r = 0; r < P_ROWS; r++) begin : g_a_edges
        assign a_bits_link[r][0] = a_bits_in[r*AB +: AB];
        assign a_signs_link[r][0] = a_signs_in[r*AS +: AS];
        assign load_a_link[r][0] = load_a_sign_in[r];
        assign ring_link[r][0] = ring_in[r] & int_mode;
        assign acc_link[r][0] = acc_in_west[r*AW +: AW];
        assign a_bits_out[r*AB +: AB] = a_bits_link[r][P_COLS];
        assign a_signs_out[r*AS +: AS] = a_signs_link[r][P_COLS];
        assign load_a_sign_out[r] = load_a_link[r][P_COLS];
        assign ring_out[r] = ring_link[r][P_COLS];
        assign acc_out_east[r*AW +: AW] = acc_link[r][P_COLS];
    end

    for (genvar c = 0; c < P_COLS; c++) begin : g_w_edges
        assign w_bits_link[c][0] = w_bits_in[c*WB +: WB];
        assign w_signs_link[c][0] = w_signs_in[c*WS +: WS];
        assign load_w_link[c][0] = load_w_sign_in[c];
        assign w_bits_out[c*WB +: WB] = w_bits_link[c][P_ROWS];
        assign w_signs_out[c*WS +: WS] = w_signs_link[c][P_ROWS];
        assign load_w_sign_out[c] = load_w_link[c][P_ROWS];
    end

    for (genvar r = 0; r < P_ROWS; r++) begin : g_pe_row
        for (genvar c = 0; c < P_COLS; c++) begin : g_pe_col
            PaynPe #(
                .K(K), .M(M), .N_H(N_H), .N_W(N_W),
                .OWIDTH(OWIDTH), .LOW_W(LOW_W)
            ) u_pe (
                .clk,
                .reset,
                .mac_en,
                .shift_in,
                .ring_in(ring_link[r][c]),
                .a_bits_in(a_bits_link[r][c]),
                .a_signs_in(a_signs_link[r][c]),
                .w_bits_in(w_bits_link[c][r]),
                .w_signs_in(w_signs_link[c][r]),
                .load_a_sign_in(load_a_link[r][c]),
                .load_w_sign_in(load_w_link[c][r]),
                .a_bits_out(a_bits_link[r][c+1]),
                .a_signs_out(a_signs_link[r][c+1]),
                .w_bits_out(w_bits_link[c][r+1]),
                .w_signs_out(w_signs_link[c][r+1]),
                .load_a_sign_out(load_a_link[r][c+1]),
                .load_w_sign_out(load_w_link[c][r+1]),
                .ring_out(ring_link[r][c+1]),
                .acc_in_west(acc_link[r][c]),
                .acc_out_east(acc_link[r][c+1])
            );
        end
    end
endmodule

`endif
