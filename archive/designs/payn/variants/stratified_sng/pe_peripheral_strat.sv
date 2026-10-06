`ifndef PAYN_STRATIFIED_SNG_PERIPHERAL
`define PAYN_STRATIFIED_SNG_PERIPHERAL

`timescale 1ns/1ps

`include "payn/sobol.sv"

// Lane-stratified binary->stochastic edge peripheral.
//
// Same ports and held-operand registers as sc_pe_peripheral, but the M lanes of
// one (row/col, k) no longer each compare the magnitude against an unrelated
// 8-bit threshold.  Lane m owns a fixed coarse cell: its top G_A (A side) or
// G_W (W side) threshold bits are a per-lane constant, and lanes that differ
// only in those bits share one fine threshold drawn from an ordinary 8-bit
// Sobol lane.  With G_A + G_W = log2(M) every lane owns exactly one cell of the
// 2**G_A x 2**G_W coarse grid, so a block is stratified sampling with Sobol-
// randomized fine positions.
//
// One group of 2**G lanes therefore needs a single (WIDTH-G)-bit compare of the
// held fine magnitude bits; each lane adds only a constant-threshold test on
// the G high bits: bit = (x_hi > s) | (x_hi == s & fine_gt).
//
// Owen-style masks: fine bits get a digital shift per (k, group); stratum bits
// get one XOR per k for all lanes, which keeps the lane -> cell map bijective.
// Bit-exact model: sweeps/sng_accuracy_compare.py, strat_thresholds().
module ScPePeripheralStrat #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int WIDTH = 8,
    parameter int G_A = 2,
    parameter int G_W = 2,
    parameter int A_SCRAMBLE_SALT = 0,
    parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1)),
    localparam int LANE_BITS = $clog2(M),
    localparam int GROUPS_A = M >> G_A,
    localparam int GROUPS_W = M >> G_W
) (
    input logic clk,
    input logic reset,
    input logic load_a,
    input logic load_w,
    input logic [N_H*K*WIDTH-1:0] a_binary_in,
    input logic [N_H*K-1:0]       a_signs_in,
    input logic [N_W*K*WIDTH-1:0] w_binary_in,
    input logic [N_W*K-1:0]       w_signs_in,
    input logic [GROUPS_A*WIDTH-1:0] a_random_values,
    input logic [GROUPS_W*WIDTH-1:0] w_random_values,
    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0]   a_signs,
    output logic [N_W*K*M-1:0] w_bits,
    output logic [N_W*K-1:0]   w_signs
);
    localparam int LEVELS = 1 << WIDTH;
    localparam int SCRAMBLE_K_STRIDE = ((LEVELS * 79 / 128) | 1);
    localparam int SCRAMBLE_M_STRIDE = ((LEVELS * 49 / 128) | 1);

    function automatic int owen(input int d, input int g, input int salt);
        return (d*SCRAMBLE_K_STRIDE + g*SCRAMBLE_M_STRIDE + salt) & (LEVELS - 1);
    endfunction

    initial begin
        assert (M == (1 << LANE_BITS))
            else $fatal(1, "M=%0d must be a power of two", M);
        assert (G_A + G_W == LANE_BITS)
            else $fatal(1, "G_A + G_W (%0d) must equal log2(M) (%0d)",
                        G_A + G_W, LANE_BITS);
        assert (G_A > 0 && G_W > 0 && G_A < WIDTH && G_W < WIDTH)
            else $fatal(1, "stratum widths must be in (0, WIDTH)");
    end

    logic [N_H*K*WIDTH-1:0] a_binary_q;
    logic [N_H*K-1:0]       a_signs_q;
    logic [N_W*K*WIDTH-1:0] w_binary_q;
    logic [N_W*K-1:0]       w_signs_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            a_binary_q <= '0;
            a_signs_q <= '0;
        end else if (load_a) begin
            a_binary_q <= a_binary_in;
            a_signs_q <= a_signs_in;
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            w_binary_q <= '0;
            w_signs_q <= '0;
        end else if (load_w) begin
            w_binary_q <= w_binary_in;
            w_signs_q <= w_signs_in;
        end
    end

    assign a_signs = a_signs_q;
    assign w_signs = w_signs_q;

    localparam int FA = WIDTH - G_A;
    localparam int FW = WIDTH - G_W;

    for (genvar row = 0; row < N_H; row++) begin : g_a_row
        for (genvar d = 0; d < K; d++) begin : g_a_depth
            logic [WIDTH-1:0] x;
            logic [GROUPS_A-1:0] fine_gt;
            assign x = a_binary_q[(row*K + d)*WIDTH +: WIDTH];

            for (genvar g = 0; g < GROUPS_A; g++) begin : g_group
                localparam logic [WIDTH-1:0] MASK = WIDTH'(owen(d, g, A_SCRAMBLE_SALT));
                logic [FA-1:0] fine_thr;
                assign fine_thr = FA'((a_random_values[g*WIDTH +: WIDTH] ^ MASK) >> G_A);
                assign fine_gt[g] = x[FA-1:0] > fine_thr;
            end

            for (genvar m = 0; m < M; m++) begin : g_lane
                localparam int GRP = m & (GROUPS_A - 1);
                localparam int SMASK = owen(d, 0, A_SCRAMBLE_SALT) >> FA;
                localparam logic [G_A-1:0] S = G_A'((m >> (LANE_BITS - G_A)) ^ SMASK);
                assign a_bits[(row*K + d)*M + m] =
                    (x[WIDTH-1:FA] > S) | ((x[WIDTH-1:FA] == S) & fine_gt[GRP]);
            end
        end
    end

    for (genvar col = 0; col < N_W; col++) begin : g_w_col
        for (genvar d = 0; d < K; d++) begin : g_w_depth
            logic [WIDTH-1:0] y;
            logic [GROUPS_W-1:0] fine_gt;
            assign y = w_binary_q[(col*K + d)*WIDTH +: WIDTH];

            for (genvar g = 0; g < GROUPS_W; g++) begin : g_group
                localparam logic [WIDTH-1:0] MASK = WIDTH'(owen(d, g, W_SCRAMBLE_SALT));
                logic [FW-1:0] fine_thr;
                assign fine_thr = FW'((w_random_values[g*WIDTH +: WIDTH] ^ MASK) >> G_W);
                assign fine_gt[g] = y[FW-1:0] > fine_thr;
            end

            for (genvar m = 0; m < M; m++) begin : g_lane
                localparam int GRP = m >> G_W;
                localparam int SMASK = owen(d, 0, W_SCRAMBLE_SALT) >> FW;
                localparam logic [G_W-1:0] S = G_W'((m & ((1 << G_W) - 1)) ^ SMASK);
                assign w_bits[(col*K + d)*M + m] =
                    (y[WIDTH-1:FW] > S) | ((y[WIDTH-1:FW] == S) & fine_gt[GRP]);
            end
        end
    end
endmodule

`endif
