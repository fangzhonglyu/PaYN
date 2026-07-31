`ifndef PAYN_SIGNED_SEGMENTED_CLEAN_INNER_PE_GRID
`define PAYN_SIGNED_SEGMENTED_CLEAN_INNER_PE_GRID

`include "payn/variants/signed_segmented_clean/inner_pe_signed_segmented_clean.sv"

// Two-dimensional outer grid of cleaned signed-segmented InnerPEs.
//
// Each InnerPE contains an N_H x N_W output-stationary tile array.  A streams
// travel east across PE columns, W streams travel south across PE rows, and
// each global accumulator row drains east through every PE column.  This is
// what the PE's re-export rails (a_bits_out / w_bits_out / load_*_sign_out)
// exist for; a single-PE top ties them off, an outer grid chains them.
//
// The edge driver must apply the normal systolic skew:
//   A slice t enters PE row r on cycle t+r
//   W slice t enters PE column c on cycle t+c
// This makes the two copies of slice t meet in PE (r,c) on cycle t+r+c.
//
// Pure wiring: identical to inner_pe_grid_signed_segmented.sv apart from the
// PE it instantiates.  All arithmetic differences live in the tile.
module InnerPESignedSegmentedCleanGrid #(
    parameter int P_ROWS = 2,
    parameter int P_COLS = 2,
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9
) (
    input logic clk,
    input logic reset,
    input logic mac_en,
    input logic shift_in,

    input logic [M-1:0] a_bits_in  [P_ROWS][N_H][K],
    input logic         a_signs_in [P_ROWS][N_H][K],
    input logic [M-1:0] w_bits_in  [P_COLS][N_W][K],
    input logic         w_signs_in [P_COLS][N_W][K],
    input logic         load_a_sign_in [P_ROWS],
    input logic         load_w_sign_in [P_COLS],

    output logic [M-1:0] a_bits_out  [P_ROWS][N_H][K],
    output logic         a_signs_out [P_ROWS][N_H][K],
    output logic [M-1:0] w_bits_out  [P_COLS][N_W][K],
    output logic         w_signs_out [P_COLS][N_W][K],
    output logic         load_a_sign_out [P_ROWS],
    output logic         load_w_sign_out [P_COLS],

    input  logic signed [OWIDTH-1:0] acc_in_west  [P_ROWS][N_H],
    output logic signed [OWIDTH-1:0] acc_out_east [P_ROWS][N_H]
);
    initial begin
        assert (P_ROWS > 0 && P_COLS > 0)
            else $fatal(1, "P_ROWS and P_COLS must be positive");
    end

    logic [M-1:0] a_bits_link  [P_ROWS][P_COLS+1][N_H][K];
    logic         a_signs_link [P_ROWS][P_COLS+1][N_H][K];
    logic [M-1:0] w_bits_link  [P_COLS][P_ROWS+1][N_W][K];
    logic         w_signs_link [P_COLS][P_ROWS+1][N_W][K];
    logic         load_a_link  [P_ROWS][P_COLS+1];
    logic         load_w_link  [P_COLS][P_ROWS+1];
    logic signed [OWIDTH-1:0] acc_link [P_ROWS][P_COLS+1][N_H];

    for (genvar r = 0; r < P_ROWS; r++) begin : g_a_edges
        assign load_a_link[r][0] = load_a_sign_in[r];
        assign load_a_sign_out[r] = load_a_link[r][P_COLS];

        for (genvar h = 0; h < N_H; h++) begin : g_row
            assign acc_link[r][0][h] = acc_in_west[r][h];
            assign acc_out_east[r][h] = acc_link[r][P_COLS][h];

            for (genvar d = 0; d < K; d++) begin : g_depth
                assign a_bits_link[r][0][h][d] = a_bits_in[r][h][d];
                assign a_signs_link[r][0][h][d] = a_signs_in[r][h][d];
                assign a_bits_out[r][h][d] = a_bits_link[r][P_COLS][h][d];
                assign a_signs_out[r][h][d] = a_signs_link[r][P_COLS][h][d];
            end
        end
    end

    for (genvar c = 0; c < P_COLS; c++) begin : g_w_edges
        assign load_w_link[c][0] = load_w_sign_in[c];
        assign load_w_sign_out[c] = load_w_link[c][P_ROWS];

        for (genvar v = 0; v < N_W; v++) begin : g_col
            for (genvar d = 0; d < K; d++) begin : g_depth
                assign w_bits_link[c][0][v][d] = w_bits_in[c][v][d];
                assign w_signs_link[c][0][v][d] = w_signs_in[c][v][d];
                assign w_bits_out[c][v][d] = w_bits_link[c][P_ROWS][v][d];
                assign w_signs_out[c][v][d] = w_signs_link[c][P_ROWS][v][d];
            end
        end
    end

    for (genvar r = 0; r < P_ROWS; r++) begin : g_pe_row
        for (genvar c = 0; c < P_COLS; c++) begin : g_pe_col
            InnerPESignedSegmentedClean #(
                .K(K),
                .M(M),
                .N_H(N_H),
                .N_W(N_W),
                .OWIDTH(OWIDTH),
                .LOW_W(LOW_W)
            ) u_pe (
                .clk,
                .reset,
                .mac_en,
                .shift_in,
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
                .acc_in_west(acc_link[r][c]),
                .acc_out_east(acc_link[r][c+1])
            );
        end
    end
endmodule

`endif
