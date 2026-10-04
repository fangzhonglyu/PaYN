`ifndef ASTRAEA_SC_INNER_PE
`define ASTRAEA_SC_INNER_PE

`timescale 1ns/1ps

`include "payn/inner_tile.sv"

// InnerPE: N_H x N_W grid of InnerTiles with conditional bitstream generation
// (C-BSG) -- W's generator advances only on A ones.
//
// A arrives rate-encoded (M samples per cycle, sample s = cycle*M + lane). For
// every A element (row h, depth k) a W index j counts the A ones of the current
// K-block; the A one in lane m of a cycle is paired with W sample
// i = j + #(A ones in lanes < m), and j advances by the cycle's A ones. W
// sample i is the scmp_kernels emulator's rB[d][i]:
//
//   thr_W(d, i) = (X(i) ^ bitrev_WIDTH((d_base + k) mod N_MASKS)) >> RNG_SHIFT
//   X(i)        = XOR_j gray(i)[j] * V[j]       Sobol word i (W_DIRECTION_SET)
//
// so each product counts #{i < kA : rB[d][i] < bB} with kA the A stream's ones
// -- the emulator's C-BSG count, bit-exact. j is shared along a row; the W
// comparison against each column's magnitude happens inside the tile
// (N_H*N_W*K*M comparators).
//
// valid_in marks a fresh slice (the A bank advanced) and first_in the first
// fresh slice of a K-block, both aligned with a_bits_in. j and the slice index
// advance only on fresh slices, so idle cycles between blocks are harmless;
// first_in resets them. Samples at or past stream_len are dropped. Requires M
// to be a power of two.
module InnerPE #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int WIDTH = 8,
    parameter int W_DIRECTION_SET = 1,
    parameter int N_MASKS = 64,
    parameter int RNG_SHIFT = 1
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic valid_in,
    input  logic first_in,
    input  logic [7:0] stream_len,
    input  logic [15:0] d_base_in,

    input  logic [M-1:0]     a_bits_in  [N_H][K],
    input  logic             a_signs_in [N_H][K],
    input  logic [WIDTH-1:0] w_mag_in   [N_W][K],
    input  logic             w_signs_in [N_W][K],
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,

    input  logic signed [OWIDTH-1:0] acc_in_west  [N_H],
    output logic signed [OWIDTH-1:0] acc_out_east [N_H]
);
    localparam int LM = (M > 1) ? $clog2(M) : 1;
    localparam int IDX_W = WIDTH + 1;          // W sample index, up to 2**WIDTH
    localparam int MASK_BITS = (N_MASKS > 1) ? $clog2(N_MASKS) : 1;

    initial begin
        assert (K > 0 && N_H > 0 && N_W > 0) else $fatal(1, "K, N_H, N_W must be positive");
        assert (M >= 2 && (1 << LM) == M)
            else $fatal(1, "C-BSG PE needs M a power of two >= 2 (M=%0d)", M);
        assert (W_DIRECTION_SET inside {0, 1})
            else $fatal(1, "W_DIRECTION_SET must be 0 or 1");
    end

    function automatic logic [WIDTH-1:0] dv(input int j);
        logic [7:0] k_table [8];
        begin
            k_table = '{8'h80, 8'h40, 8'h20, 8'h10, 8'h48, 8'h04, 8'h52, 8'hff};
            dv = '0;
            if (j >= 0 && j < WIDTH) begin
                if (W_DIRECTION_SET == 0) dv[WIDTH-1-j] = 1'b1;
                else                      dv = WIDTH'(k_table[j] >> (8 - WIDTH));
            end
        end
    endfunction

    //------------------------------------------------------ operand pipes --
    // Operand registers are resetless. Stream bits and W magnitudes advance
    // every cycle; signs update only when their registered load wave arrives.
    logic [M-1:0]     a_bits_pipe  [N_H][K];
    logic             a_signs_pipe [N_H][K];
    logic [WIDTH-1:0] w_mag_pipe   [N_W][K];
    logic             w_signs_pipe [N_W][K];
    logic load_a_sign_q, load_w_sign_q, valid_pipe, first_pipe;
    logic [15:0] d_base_pipe;

    always_ff @(posedge clk) begin
        if (reset) begin
            load_a_sign_q <= 1'b0;
            load_w_sign_q <= 1'b0;
            valid_pipe <= 1'b0;
            first_pipe <= 1'b0;
        end else begin
            load_a_sign_q <= load_a_sign_in;
            load_w_sign_q <= load_w_sign_in;
            valid_pipe <= valid_in;
            first_pipe <= first_in;
        end
        d_base_pipe <= d_base_in;
    end

    always_ff @(posedge clk) begin
        for (int h = 0; h < N_H; h++)
            for (int d = 0; d < K; d++) begin
                a_bits_pipe[h][d] <= a_bits_in[h][d];
                if (load_a_sign_q) a_signs_pipe[h][d] <= a_signs_in[h][d];
            end
        for (int v = 0; v < N_W; v++)
            for (int d = 0; d < K; d++) begin
                w_mag_pipe[v][d] <= w_mag_in[v][d];
                if (load_w_sign_q) w_signs_pipe[v][d] <= w_signs_in[v][d];
            end
    end

    //------------------------------------------- slice index / lane valid --
    logic [WIDTH-1:0] slice, cur_slice;
    assign cur_slice = first_pipe ? '0 : slice;

    always_ff @(posedge clk) begin
        if (reset)                              slice <= '0;
        else if (valid_pipe && cur_slice != '1) slice <= cur_slice + 1'b1;
    end

    logic [M-1:0] lane_valid;
    for (genvar lane = 0; lane < M; lane++) begin : g_valid
        assign lane_valid[lane] =
            (IDX_W + LM)'(cur_slice) * (IDX_W + LM)'(M) + (IDX_W + LM)'(lane)
            < (IDX_W + LM)'(stream_len);
    end

    //---------------------------------------- gated W generator per A elt --
    logic [M-1:0]     a_eff [N_H][K];          // A ones that belong to the stream
    logic [WIDTH-1:0] w_thr [N_H][K][M];       // W threshold paired with each lane

    for (genvar h = 0; h < N_H; h++) begin : g_gen_row
        for (genvar d = 0; d < K; d++) begin : g_gen_depth
            logic [IDX_W-1:0] j, cur_j;
            logic [IDX_W-1:0] prefix [M+1];
            logic [WIDTH-1:0] col_mask;
            logic [MASK_BITS-1:0] column;

            assign column = d_base_pipe[MASK_BITS-1:0] + MASK_BITS'(d);
            for (genvar i = 0; i < WIDTH; i++) begin : g_mask_bit
                assign col_mask[WIDTH-1-i] = (i < MASK_BITS) ? column[i] : 1'b0;
            end

            assign a_eff[h][d] = a_bits_pipe[h][d] & lane_valid;
            assign cur_j = first_pipe ? '0 : j;

            assign prefix[0] = cur_j;
            for (genvar lane = 0; lane < M; lane++) begin : g_lane
                logic [IDX_W-1:0] idx, gray;
                logic [WIDTH-1:0] x;

                assign prefix[lane+1] = prefix[lane] + IDX_W'(a_eff[h][d][lane]);
                assign idx = prefix[lane];
                assign gray = idx ^ (idx >> 1);

                always_comb begin
                    x = '0;
                    for (int b = 0; b < WIDTH; b++)
                        if (gray[b]) x ^= dv(b);
                end

                assign w_thr[h][d][lane] = (x ^ col_mask) >> RNG_SHIFT;
            end

            always_ff @(posedge clk) begin
                if (reset)           j <= '0;
                else if (valid_pipe) j <= prefix[M];
            end
        end
    end

    //------------------------------------------------------------- tiles --
    for (genvar h = 0; h < N_H; h++) begin : g_row
        logic signed [OWIDTH-1:0] acc_chain [N_W:0];
        assign acc_chain[0] = acc_in_west[h];
        assign acc_out_east[h] = acc_chain[N_W];

        for (genvar v = 0; v < N_W; v++) begin : g_col
            logic [M-1:0] w_local [K];
            for (genvar d = 0; d < K; d++) begin : g_w_local
                for (genvar lane = 0; lane < M; lane++) begin : g_cmp
                    assign w_local[d][lane] = w_mag_pipe[v][d] > w_thr[h][d][lane];
                end
            end

            InnerTile #(
                .K(K),
                .M(M),
                .OWIDTH(OWIDTH)
            ) u_inner (
                .clk,
                .reset,
                .a_signs(a_signs_pipe[h]),
                .a_bits(a_eff[h]),
                .w_signs(w_signs_pipe[v]),
                .w_bits(w_local),
                .shift_in,
                .mac_en,
                .acc_in(acc_chain[v]),
                .acc_out(acc_chain[v+1])
            );
        end
    end
endmodule

// Packed-port adapter for synthesis and gate benches (keeps the
// u_pe/u_array_core/g_row_*__g_col_*__u_inner hierarchy).
module InnerPEFlat #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int WIDTH = 8,
    parameter int W_DIRECTION_SET = 1,
    parameter int N_MASKS = 64,
    parameter int RNG_SHIFT = 1
) (
    input logic clk,
    input logic reset,
    input logic mac_en,
    input logic shift_in,
    input logic valid_in,
    input logic first_in,
    input logic [7:0] stream_len,
    input logic [15:0] d_base_in,

    input logic [N_H*K*M-1:0]     a_bits_in,
    input logic [N_H*K-1:0]       a_signs_in,
    input logic [N_W*K*WIDTH-1:0] w_mag_in,
    input logic [N_W*K-1:0]       w_signs_in,
    input logic load_a_sign_in,
    input logic load_w_sign_in,

    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic [M-1:0]     a_bits_array  [N_H][K];
    logic             a_signs_array [N_H][K];
    logic [WIDTH-1:0] w_mag_array   [N_W][K];
    logic             w_signs_array [N_W][K];
    logic signed [OWIDTH-1:0] acc_in_west_array  [N_H];
    logic signed [OWIDTH-1:0] acc_out_east_array [N_H];

    for (genvar h = 0; h < N_H; h++) begin : g_a_ports
        for (genvar d = 0; d < K; d++) begin : g_lane
            assign a_bits_array[h][d] = a_bits_in[(h*K + d)*M +: M];
            assign a_signs_array[h][d] = a_signs_in[h*K + d];
        end
        assign acc_in_west_array[h] = $signed(acc_in_west[h*OWIDTH +: OWIDTH]);
        assign acc_out_east[h*OWIDTH +: OWIDTH] = acc_out_east_array[h];
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_ports
        for (genvar d = 0; d < K; d++) begin : g_lane
            assign w_mag_array[v][d] = w_mag_in[(v*K + d)*WIDTH +: WIDTH];
            assign w_signs_array[v][d] = w_signs_in[v*K + d];
        end
    end

    InnerPE #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .WIDTH(WIDTH),
        .W_DIRECTION_SET(W_DIRECTION_SET), .N_MASKS(N_MASKS), .RNG_SHIFT(RNG_SHIFT)
    ) u_array_core (
        .clk, .reset, .mac_en, .shift_in, .valid_in, .first_in, .stream_len,
        .d_base_in,
        .a_bits_in(a_bits_array),
        .a_signs_in(a_signs_array),
        .w_mag_in(w_mag_array),
        .w_signs_in(w_signs_array),
        .load_a_sign_in, .load_w_sign_in,
        .acc_in_west(acc_in_west_array),
        .acc_out_east(acc_out_east_array)
    );
endmodule

`endif
