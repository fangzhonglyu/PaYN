`ifndef PAYN_GATED_CBSG_INNER_PE
`define PAYN_GATED_CBSG_INNER_PE

`timescale 1ns/1ps

`include "payn/inner_tile.sv"

// InnerPE for traditional (gated) C-BSG: W's generator advances only on A ones.
//
// A arrives as PaYN's original rate-encoded stream (M samples per cycle, sample
// s = cycle*M + lane). For every A element (row h, depth k) a W index j counts
// the A ones of the current K-block; the A one in lane m of a cycle is paired
// with W sample i = j + #(A ones in lanes < m). W sample i is PaYN's original W
// stream replayed in sample order:
//
//   thr_W(k, i) = SHIFT(i mod M) ^ MASK(k, i mod M) ^ X(i / M + 1)
//     SHIFT(m) = W_SHIFT_BASE ^ (W_SHIFT_STRIDE * m)       sobol_bank lane seed
//     MASK(k,m) = golden-stride Owen mask, W salt          sc_pe_peripheral
//     X(n)     = XOR_j gray(n)[j] * DV[j]                  value a legacy
//                sobol_generator has XOR'd in after n enables (W_DIRECTION_SET)
//
// i.e. the threshold the original W bank would have shown in lane i mod M of
// productive cycle i / M (STREAMS=0). With STREAMS=1 W sample i is instead the
// scmp_kernels emulator's rB[d][i]:
//
//   thr_W(d, i) = (X(i) ^ bitrev_WIDTH((d_base + k) mod N_MASKS)) >> RNG_SHIFT
//
// the emulator's Sobol "k" word i with its per-column mask on the 7-bit grid.
// Because j differs per row, the W thresholds are
// shared along a row but compared against each column's W magnitude inside the
// tile (N_H*N_W*K*M comparators, vs N_W*K*M for a shared W stream).
//
// valid_in marks a fresh slice (the A bank advanced) and first_in the first
// fresh slice of a K-block, both aligned with a_bits_in. j and the slice index
// advance only on fresh slices, so idle cycles between blocks are harmless;
// first_in resets them. Samples at or past stream_len are dropped. Requires M
// to be a power of two.
module InnerPEGatedCbsg #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int WIDTH = 8,
    parameter int W_DIRECTION_SET = 1,
    parameter logic [WIDTH-1:0] W_SHIFT_BASE = 8'h9d,
    parameter logic [WIDTH-1:0] W_SHIFT_STRIDE = 8'h2b,
    parameter logic W_SCRAMBLE_ENABLE = 1'b1,
    parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1)),
    parameter int STREAMS = 0,              // 0 = PaYN original, 1 = emulator
    parameter int N_MASKS = 64,             // STREAMS=1 column masks
    parameter int RNG_SHIFT = 1             // STREAMS=1 threshold grid shift
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic valid_in,
    input  logic first_in,
    input  logic [7:0] stream_len,
    input  logic [15:0] d_base_in,          // STREAMS=1: block's first column

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
    localparam int LEVELS = 1 << WIDTH;
    localparam int SCRAMBLE_K_STRIDE = ((LEVELS * 79 / 128) | 1);
    localparam int SCRAMBLE_M_STRIDE = ((LEVELS * 49 / 128) | 1);
    localparam int MASK_BITS = (N_MASKS > 1) ? $clog2(N_MASKS) : 1;

    initial begin
        assert (M >= 2 && (1 << LM) == M)
            else $fatal(1, "gated C-BSG needs M a power of two >= 2 (M=%0d)", M);
        assert (W_DIRECTION_SET inside {0, 1})
            else $fatal(1, "W_DIRECTION_SET must be 0 or 1");
        assert (STREAMS inside {0, 1})
            else $fatal(1, "STREAMS must be 0 (original) or 1 (emulator)");
    end

    // Direction vector j of the legacy sobol_generator (same tables).
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

    // Lane constant: the W bank lane's digital shift XOR its peripheral mask.
    function automatic logic [WIDTH-1:0] lane_const(input int depth, input int lane);
        int mask;
        begin
            mask = W_SCRAMBLE_ENABLE ?
                ((depth*SCRAMBLE_K_STRIDE + lane*SCRAMBLE_M_STRIDE +
                  W_SCRAMBLE_SALT) & (LEVELS - 1)) : 0;
            lane_const = (W_SHIFT_BASE ^ WIDTH'(W_SHIFT_STRIDE * lane)) ^ WIDTH'(mask);
        end
    endfunction

    //------------------------------------------------------ operand pipes --
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

            logic [WIDTH-1:0] col_mask;            // STREAMS=1 column mask
            logic [MASK_BITS-1:0] column;
            assign column = d_base_pipe[MASK_BITS-1:0] + MASK_BITS'(d);
            for (genvar i = 0; i < WIDTH; i++) begin : g_mask_bit
                assign col_mask[WIDTH-1-i] = (i < MASK_BITS) ? column[i] : 1'b0;
            end

            assign a_eff[h][d] = a_bits_pipe[h][d] & lane_valid;
            assign cur_j = first_pipe ? '0 : j;

            assign prefix[0] = cur_j;
            for (genvar lane = 0; lane < M; lane++) begin : g_lane
                logic [IDX_W-1:0] idx;

                assign prefix[lane+1] = prefix[lane] + IDX_W'(a_eff[h][d][lane]);
                assign idx = prefix[lane];

                if (STREAMS == 0) begin : g_original
                    // Original W bank, lane idx % M of productive cycle idx / M.
                    logic [LM-1:0] w_lane;
                    logic [IDX_W-LM:0] n;           // productive cycle + 1
                    logic [IDX_W-LM:0] gray;
                    logic [WIDTH-1:0] x, lc;

                    assign w_lane = idx[LM-1:0];
                    assign n = (IDX_W-LM+1)'(idx >> LM) + 1'b1;
                    assign gray = n ^ (n >> 1);

                    always_comb begin
                        x = '0;
                        for (int b = 0; b < WIDTH; b++)
                            if (b <= IDX_W - LM && gray[b]) x ^= dv(b);
                        lc = '0;
                        for (int m = 0; m < M; m++)
                            if (w_lane == LM'(m)) lc = lane_const(d, m);
                    end

                    assign w_thr[h][d][lane] = lc ^ x;
                end else begin : g_emulator
                    // Emulator rB[d][idx]: Sobol word idx, column mask, grid shift.
                    logic [IDX_W-1:0] gray;
                    logic [WIDTH-1:0] x;

                    assign gray = idx ^ (idx >> 1);

                    always_comb begin
                        x = '0;
                        for (int b = 0; b < WIDTH; b++)
                            if (gray[b]) x ^= dv(b);
                    end

                    assign w_thr[h][d][lane] = (x ^ col_mask) >> RNG_SHIFT;
                end
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

// Packed-port adapter, mirroring InnerPEFlat (keeps u_pe/u_array_core names).
module InnerPEGatedCbsgFlat #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int WIDTH = 8,
    parameter int W_DIRECTION_SET = 1,
    parameter logic [WIDTH-1:0] W_SHIFT_BASE = 8'h9d,
    parameter logic [WIDTH-1:0] W_SHIFT_STRIDE = 8'h2b,
    parameter logic W_SCRAMBLE_ENABLE = 1'b1,
    parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1)),
    parameter int STREAMS = 0,
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

    InnerPEGatedCbsg #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .WIDTH(WIDTH),
        .W_DIRECTION_SET(W_DIRECTION_SET),
        .W_SHIFT_BASE(W_SHIFT_BASE), .W_SHIFT_STRIDE(W_SHIFT_STRIDE),
        .W_SCRAMBLE_ENABLE(W_SCRAMBLE_ENABLE), .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT),
        .STREAMS(STREAMS), .N_MASKS(N_MASKS), .RNG_SHIFT(RNG_SHIFT)
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
