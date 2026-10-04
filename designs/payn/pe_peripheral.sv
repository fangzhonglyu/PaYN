`ifndef ASTRAEA_SC_PE_PERIPHERAL
`define ASTRAEA_SC_PE_PERIPHERAL

`timescale 1ns/1ps

// Binary edge operands to packed stochastic streams for one current-generation
// inner PE. Sobol values are supplied separately so one pair of banks can be
// shared across every west/south edge peripheral in an array.
module sc_pe_peripheral #(
    parameter int K = 6,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int WIDTH = 8,
    parameter logic SCRAMBLE_ENABLE = 1'b1,
    parameter int A_SCRAMBLE_SALT = 0,
    parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1)),
    // Per-side overrides of SCRAMBLE_ENABLE (a unary-temporal A stream must
    // not be scrambled).
    parameter logic A_SCRAMBLE_ENABLE = SCRAMBLE_ENABLE,
    parameter logic W_SCRAMBLE_ENABLE = SCRAMBLE_ENABLE,
    // MASK_MODE=0: golden-stride mask per (depth, lane, salt) — legacy.
    // MASK_MODE=1: emulator mask per column, lane- and side-independent:
    //   mask[d] = bitrev_WIDTH((d_base + depth) mod N_MASKS)
    // where d_base is the K-block's first column (runtime input, latched with
    // the operands on load_a / load_w).
    parameter int MASK_MODE = 0,
    parameter int N_MASKS = 64,
    // Compare against (scrambled_random >> *_RNG_SHIFT): 1 maps an 8-bit
    // Sobol word onto the emulator's 7-bit grid (halve_bipolar_stoc_len).
    parameter int A_RNG_SHIFT = 0,
    parameter int W_RNG_SHIFT = 0
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
    input logic [15:0] d_base = '0,     // MASK_MODE=1 only

    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0] a_signs,
    output logic [N_W*K*M-1:0] w_bits,
    output logic [N_W*K-1:0] w_signs
);
    localparam int LEVELS = 1 << WIDTH;
    localparam int SCRAMBLE_K_STRIDE = ((LEVELS * 79 / 128) | 1);
    localparam int SCRAMBLE_M_STRIDE = ((LEVELS * 49 / 128) | 1);

    logic [N_H*K*WIDTH-1:0] a_binary_q;
    logic [N_H*K-1:0] a_signs_q;
    logic [N_W*K*WIDTH-1:0] w_binary_q;
    logic [N_W*K-1:0] w_signs_q;

    initial begin
        assert (K > 0) else $error("K must be positive");
        assert (M > 0) else $error("M must be positive");
        assert (N_H > 0) else $error("N_H must be positive");
        assert (N_W > 0) else $error("N_W must be positive");
        assert (WIDTH > 0 && WIDTH < 31)
            else $error("WIDTH must be between 1 and 30");
        assert (MASK_MODE inside {0, 1}) else $error("MASK_MODE must be 0 or 1");
        if (MASK_MODE == 1)
            assert (N_MASKS > 0 && (N_MASKS & (N_MASKS - 1)) == 0)
                else $error("N_MASKS must be a power of two");
    end

    // MASK_MODE=1 column masks, shared by A and W at the same depth. d_base is
    // latched with the operands (load_a or load_w) so the column index changes
    // on the same edge as the K-block it belongs to.
    localparam int MASK_BITS = (N_MASKS > 1) ? $clog2(N_MASKS) : 1;
    logic [WIDTH-1:0] column_mask [K];
    if (MASK_MODE == 1) begin : g_column_mask
        logic [MASK_BITS-1:0] d_base_q;
        always_ff @(posedge clk or posedge reset) begin
            if (reset)                 d_base_q <= '0;
            else if (load_a || load_w) d_base_q <= d_base[MASK_BITS-1:0];
        end
        for (genvar depth = 0; depth < K; depth++) begin : g_depth
            logic [MASK_BITS-1:0] column;
            assign column = d_base_q + MASK_BITS'(depth);
            for (genvar i = 0; i < WIDTH; i++) begin : g_bit
                assign column_mask[depth][WIDTH-1-i] =
                    (i < MASK_BITS) ? column[i] : 1'b0;
            end
        end
    end else begin : g_no_column_mask
        for (genvar depth = 0; depth < K; depth++) begin : g_depth
            assign column_mask[depth] = '0;
        end
    end

    // Independent enables let synthesis clock-gate the A and W boundary
    // register banks separately. Reset is asynchronous to avoid a reset mux on
    // every held binary bit.
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

    for (genvar row = 0; row < N_H; row++) begin : g_a_row
        for (genvar depth = 0; depth < K; depth++) begin : g_a_depth
            for (genvar lane = 0; lane < M; lane++) begin : g_a_lane
                localparam int MASK_INT =
                    (depth*SCRAMBLE_K_STRIDE + lane*SCRAMBLE_M_STRIDE +
                     A_SCRAMBLE_SALT) & (LEVELS - 1);
                localparam logic [WIDTH-1:0] MASK = WIDTH'(MASK_INT);
                logic [WIDTH-1:0] mask;
                logic [WIDTH-1:0] scrambled_random;

                assign mask = !A_SCRAMBLE_ENABLE ? '0 :
                              (MASK_MODE == 1) ? column_mask[depth] : MASK;
                assign scrambled_random =
                    (a_random_values[lane*WIDTH +: WIDTH] ^ mask) >> A_RNG_SHIFT;
                assign a_bits[(row*K + depth)*M + lane] =
                    a_binary_q[(row*K + depth)*WIDTH +: WIDTH] >
                    scrambled_random;
            end
        end
    end

    for (genvar col = 0; col < N_W; col++) begin : g_w_col
        for (genvar depth = 0; depth < K; depth++) begin : g_w_depth
            for (genvar lane = 0; lane < M; lane++) begin : g_w_lane
                localparam int MASK_INT =
                    (depth*SCRAMBLE_K_STRIDE + lane*SCRAMBLE_M_STRIDE +
                     W_SCRAMBLE_SALT) & (LEVELS - 1);
                localparam logic [WIDTH-1:0] MASK = WIDTH'(MASK_INT);
                logic [WIDTH-1:0] mask;
                logic [WIDTH-1:0] scrambled_random;

                assign mask = !W_SCRAMBLE_ENABLE ? '0 :
                              (MASK_MODE == 1) ? column_mask[depth] : MASK;
                assign scrambled_random =
                    (w_random_values[lane*WIDTH +: WIDTH] ^ mask) >> W_RNG_SHIFT;
                assign w_bits[(col*K + depth)*M + lane] =
                    w_binary_q[(col*K + depth)*WIDTH +: WIDTH] >
                    scrambled_random;
            end
        end
    end
endmodule

`endif
