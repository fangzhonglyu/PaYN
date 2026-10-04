`ifndef ASTRAEA_SC_PE_PERIPHERAL
`define ASTRAEA_SC_PE_PERIPHERAL

`timescale 1ns/1ps

// A-edge peripheral: binary A thresholds to packed rate-encoded streams.
//
// A bit (row, depth, lane) = bA > ((x_q ^ mask[d]) >> RNG_SHIFT), i.e. the
// emulator's rA[d][t] < bA, where x_q is the A Sobol bank's sample and
//   mask[d] = bitrev_WIDTH((d_base + depth) mod N_MASKS)
// is the emulator's per-column scramble. d_base (the K-block's first column)
// is latched with the operands so the mask changes on the same edge as the
// block it belongs to. W is not converted here: its generator is gated by A
// inside the PE (inner_pe.sv).
module sc_pe_peripheral #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int WIDTH = 8,
    parameter int N_MASKS = 64,
    parameter int RNG_SHIFT = 1
) (
    input logic clk,
    input logic reset,
    input logic load_a,

    input logic [N_H*K*WIDTH-1:0] a_binary_in,
    input logic [N_H*K-1:0] a_signs_in,
    input logic [15:0] d_base,
    input logic [M*WIDTH-1:0] a_random_values,

    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0] a_signs
);
    localparam int MASK_BITS = (N_MASKS > 1) ? $clog2(N_MASKS) : 1;

    logic [N_H*K*WIDTH-1:0] a_binary_q;
    logic [N_H*K-1:0] a_signs_q;
    logic [MASK_BITS-1:0] d_base_q;

    initial begin
        assert (K > 0 && M > 0 && N_H > 0) else $error("K, M, N_H must be positive");
        assert (WIDTH > 0 && WIDTH < 31) else $error("WIDTH must be between 1 and 30");
        assert (N_MASKS > 0 && (N_MASKS & (N_MASKS - 1)) == 0)
            else $error("N_MASKS must be a power of two");
    end

    // Reset is asynchronous to avoid a reset mux on every held binary bit.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            a_binary_q <= '0;
            a_signs_q <= '0;
            d_base_q <= '0;
        end else if (load_a) begin
            a_binary_q <= a_binary_in;
            a_signs_q <= a_signs_in;
            d_base_q <= d_base[MASK_BITS-1:0];
        end
    end

    assign a_signs = a_signs_q;

    for (genvar depth = 0; depth < K; depth++) begin : g_a_depth
        logic [MASK_BITS-1:0] column;
        logic [WIDTH-1:0] mask;
        assign column = d_base_q + MASK_BITS'(depth);
        for (genvar i = 0; i < WIDTH; i++) begin : g_bit
            assign mask[WIDTH-1-i] = (i < MASK_BITS) ? column[i] : 1'b0;
        end

        // Thresholds are shared by every row at this depth.
        for (genvar lane = 0; lane < M; lane++) begin : g_a_lane
            logic [WIDTH-1:0] thr;
            assign thr = (a_random_values[lane*WIDTH +: WIDTH] ^ mask) >> RNG_SHIFT;
            for (genvar row = 0; row < N_H; row++) begin : g_a_row
                assign a_bits[(row*K + depth)*M + lane] =
                    a_binary_q[(row*K + depth)*WIDTH +: WIDTH] > thr;
            end
        end
    end
endmodule

`endif
