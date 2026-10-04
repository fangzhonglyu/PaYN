`ifndef ASTRAEA_SC_A_ENCODER
`define ASTRAEA_SC_A_ENCODER

`timescale 1ns/1ps

`include "payn/sobol.sv"

// A-operand encoder for payn_array STREAM_MODE=1: turns each A threshold bA
// (0..2**(WIDTH-1), the same encoding as the W operand) into the thermometer
// length kA that the unary-temporal A stream carries. The rest of the array
// then computes count = #{s < kA : rB[s] < bB} for both schemes. The scheme is
// a compile-time choice (parameter CBSG); only its logic is elaborated:
//
//   CBSG = 0  (UT):    kA = round(bA * L / 128) = (bA*L + 64) >> 7
//   CBSG = 1  (C-BSG): kA = #{t < L : rA[d][t] < bA}, the number of ones in
//                           A's own Sobol stream, rA[d][t] = (x_q[t] ^ mask[d])
//                           >> RNG_SHIFT with identity ("q") direction vectors
//                           and the same per-column mask as W.
//
// C-BSG's count #{i < kA : rB[i] < bB} depends on A only through kA (W's
// generator advances once per A one), so the shared, ungated W datapath gives
// the emulator's C-BSG result exactly; only kA differs between the schemes.
//
// One-block pipeline (both schemes, so the array protocol does not depend on
// the build). On `load` the downstream peripheral captures this block's
// kA/signs/d_base (the outputs, valid before the edge) while the encoder
// latches the NEXT block's bA/signs/d_base and restarts its Sobol bank. The
// C-BSG count then runs on `enable` cycles (rng_en), M samples per cycle; it is
// complete once ceil(L/M) slices have been emitted, which a block's own MAC
// window guarantees. The count output is combinational over the slice in
// flight (counter + current slice), so no extra cycle is needed.
module sc_a_encoder #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int WIDTH = 8,
    parameter int N_MASKS = 64,
    parameter int RNG_SHIFT = 1,
    parameter int CBSG = 0                   // 0 = UT, 1 = C-BSG (compile time)
) (
    input  logic clk,
    input  logic reset,
    input  logic load,                       // = load_a
    input  logic enable,                     // = rng_en
    input  logic [7:0] stream_len,           // L, 1..128

    input  logic [N_H*K*WIDTH-1:0] a_binary_in,  // bA of the NEXT block
    input  logic [N_H*K-1:0]       a_signs_in,
    input  logic [15:0]            d_base_in,

    output logic [N_H*K*WIDTH-1:0] a_k_out,      // kA of the staged block
    output logic [N_H*K-1:0]       a_signs_out,
    output logic [15:0]            d_base_out
);
    localparam int MASK_BITS = (N_MASKS > 1) ? $clog2(N_MASKS) : 1;
    localparam int CNT_W = WIDTH + 1;            // counts up to 2**WIDTH

    logic [N_H*K*WIDTH-1:0] b_q;
    logic [N_H*K-1:0]       signs_q;
    logic [15:0]            d_base_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            b_q <= '0;
            signs_q <= '0;
            d_base_q <= '0;
        end else if (load) begin
            b_q <= a_binary_in;
            signs_q <= a_signs_in;
            d_base_q <= d_base_in;
        end
    end

    assign a_signs_out = signs_q;
    assign d_base_out = d_base_q;

    initial begin
        assert (CBSG inside {0, 1}) else $error("CBSG must be 0 (UT) or 1 (C-BSG)");
    end

    if (CBSG == 0) begin : g_ut
        //------------------------------------------------------- UT: kA = bA*L --
        for (genvar e = 0; e < N_H*K; e++) begin : g_elem
            logic [WIDTH+8:0] k_ut_wide;
            assign k_ut_wide = ((WIDTH+9)'(b_q[e*WIDTH +: WIDTH]) * (WIDTH+9)'(stream_len)
                                + (WIDTH+9)'(64)) >> 7;
            assign a_k_out[e*WIDTH +: WIDTH] = WIDTH'(k_ut_wide);
        end
    end else begin : g_cbsg
        //------------------------------------------------ C-BSG count stream --
        logic [M*WIDTH-1:0] x_q;                     // Sobol "q" words, M per slice

        sobol_bank #(
            .WIDTH(WIDTH), .M(M), .DIRECTION_SET(0), .MODE(1)
        ) u_q_rng (
            .clk, .reset, .enable, .restart(load),
            .random_values(x_q)
        );

        // Slice in flight: out_valid marks that x_q holds a slice of the staged
        // block, out_slice is its index. A load with enable emits slice 0 at once
        // (gapless); a load without enable rewinds and the next enable emits it.
        logic out_valid;
        logic [WIDTH-1:0] out_slice, next_slice;

        // Lane m of the slice in flight is sample out_slice*M + m; samples past L
        // are not part of the stream.
        logic [M-1:0] lane_valid;
        for (genvar lane = 0; lane < M; lane++) begin : g_valid
            assign lane_valid[lane] = out_valid &&
                ((CNT_W + 8)'(out_slice) * (CNT_W + 8)'(M) + (CNT_W + 8)'(lane)
                 < (CNT_W + 8)'(stream_len));
        end

        // Thresholds are shared by every row at the same depth.
        logic [WIDTH-1:0] thr [K][M];
        for (genvar depth = 0; depth < K; depth++) begin : g_thr
            logic [MASK_BITS-1:0] column;
            logic [WIDTH-1:0] mask;
            assign column = d_base_q[MASK_BITS-1:0] + MASK_BITS'(depth);
            for (genvar i = 0; i < WIDTH; i++) begin : g_bit
                assign mask[WIDTH-1-i] = (i < MASK_BITS) ? column[i] : 1'b0;
            end
            for (genvar lane = 0; lane < M; lane++) begin : g_lane
                assign thr[depth][lane] = (x_q[lane*WIDTH +: WIDTH] ^ mask) >> RNG_SHIFT;
            end
        end

        always_ff @(posedge clk or posedge reset) begin
            if (reset) begin
                out_valid <= 1'b0;
                out_slice <= '0;
                next_slice <= '0;
            end else if (load) begin
                out_valid <= enable;
                out_slice <= '0;
                next_slice <= enable ? WIDTH'(1) : '0;
            end else if (enable) begin
                out_valid <= 1'b1;
                out_slice <= next_slice;
                if (next_slice != '1) next_slice <= next_slice + 1'b1;
            end
        end

        for (genvar e = 0; e < N_H*K; e++) begin : g_elem
            localparam int DEPTH = e % K;
            logic [WIDTH-1:0] b;
            logic [M-1:0] hits;
            logic [CNT_W-1:0] slice_count, counter, k_cbsg;

            assign b = b_q[e*WIDTH +: WIDTH];

            for (genvar lane = 0; lane < M; lane++) begin : g_cmp
                assign hits[lane] = lane_valid[lane] && (b > thr[DEPTH][lane]);
            end
            assign slice_count = CNT_W'($countones(hits));

            always_ff @(posedge clk or posedge reset) begin
                if (reset)              counter <= '0;
                else if (load)          counter <= '0;
                else if (enable)        counter <= counter + slice_count;
            end
            assign k_cbsg = counter + slice_count;
            assign a_k_out[e*WIDTH +: WIDTH] = WIDTH'(k_cbsg);
        end
    end
endmodule

`endif
