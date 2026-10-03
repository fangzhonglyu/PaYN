`ifndef PAYN_STRATIFIED_SNG_LANE_COUNT
`define PAYN_STRATIFIED_SNG_LANE_COUNT

`timescale 1ns/1ps

`include "payn/variants/signed_segmented_popcount/popcount16.sv"

// Per-lane unsigned hit count under the lane-stratified SNG, in closed form.
//
// With G_A = G_W = 2 and M = 16, lane m owns coarse cell
// (i, j) = ((m>>2) ^ SM_A, (m&3) ^ SM_W); within a block every A lane bit is
// 1 (i < alpha), 0 (i > alpha) or the shared fine bit F_A[group] (i == alpha),
// and likewise for W.  Summing the 16 ANDs therefore collapses to
//
//   alpha*beta + sum_{j<beta} F_A[j^SM_W] + sum_{i<alpha} F_W[i^SM_A]
//              + F_A[beta^SM_W] & F_W[alpha^SM_A]
//
// which equals the 16-input AND + popcount on the expanded lane bits exactly
// (checked over all masks in the stratified-SNG notes).  alpha/beta are the
// held magnitudes' top two bits; fine_a/fine_w are the shared fine compares.
module StratLaneCount #(
    parameter logic [1:0] SM_A = 2'd0,
    parameter logic [1:0] SM_W = 2'd0
) (
    input  logic [1:0] alpha,
    input  logic [1:0] beta,
    input  logic [3:0] fine_a,
    input  logic [3:0] fine_w,
    output logic [4:0] count
);
    logic [2:0] row_hits, col_hits;
    logic corner;
    always_comb begin
        row_hits = '0;
        col_hits = '0;
        for (int j = 0; j < 3; j++)
            if (j < beta) row_hits += 3'(fine_a[2'(j) ^ SM_W]);
        for (int i = 0; i < 3; i++)
            if (i < alpha) col_hits += 3'(fine_w[2'(i) ^ SM_A]);
    end
    assign corner = fine_a[beta ^ SM_W] & fine_w[alpha ^ SM_A];
    assign count = 5'(alpha * beta) + 5'(row_hits) + 5'(col_hits) + 5'(corner);
endmodule

// One tile's worth (K = 8 lanes) of each form, for a lane-logic area A/B.
// Inputs and outputs are registered so the flow's 2.5 ns clock constrains the
// counter logic as it does inside a tile; compare combinational area only.
module payn_lane_plain_x8 (
    input  logic clk,
    input  logic [8*16-1:0] a_bits,
    input  logic [8*16-1:0] w_bits,
    output logic [8*5-1:0]  counts
);
    logic [8*16-1:0] a_q, w_q;
    logic [8*5-1:0]  c;
    always_ff @(posedge clk) begin
        a_q <= a_bits;
        w_q <= w_bits;
        counts <= c;
    end
    for (genvar k = 0; k < 8; k++) begin : g_lane
        PaynPopcount16 u_popcount (
            .bits_in(a_q[k*16 +: 16] & w_q[k*16 +: 16]),
            .count(c[k*5 +: 5])
        );
    end
endmodule

module payn_lane_strat_x8 (
    input  logic clk,
    input  logic [8*2-1:0] alpha,
    input  logic [8*2-1:0] beta,
    input  logic [8*4-1:0] fine_a,
    input  logic [8*4-1:0] fine_w,
    output logic [8*5-1:0] counts
);
    logic [8*2-1:0] alpha_q, beta_q;
    logic [8*4-1:0] fa_q, fw_q;
    logic [8*5-1:0] c;
    always_ff @(posedge clk) begin
        alpha_q <= alpha;
        beta_q <= beta;
        fa_q <= fine_a;
        fw_q <= fine_w;
        counts <= c;
    end
    for (genvar k = 0; k < 8; k++) begin : g_lane
        StratLaneCount #(.SM_A(2'(k)), .SM_W(2'(3 - (k & 3)))) u_count (
            .alpha(alpha_q[k*2 +: 2]), .beta(beta_q[k*2 +: 2]),
            .fine_a(fa_q[k*4 +: 4]), .fine_w(fw_q[k*4 +: 4]),
            .count(c[k*5 +: 5])
        );
    end
endmodule

`endif
