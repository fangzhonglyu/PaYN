`ifndef PAYN_SIGNED_SEGMENTED_CSA_BP_IPD_ARRAY
`define PAYN_SIGNED_SEGMENTED_CSA_BP_IPD_ARRAY

`timescale 1ns/1ps

// Carry-save single-PE array with bit-plane (BP) INT mode and IN-PLACE
// doubling (IPD; schedule T3 of doc/INT_mode_on_PaYN.md).  This is
// ../signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv with one
// change, inside u_pe: a weight-pass lap is ONE edge on which every tile
// reloads its own value << 1 (a per-tile mux in the PE core copy,
// inner_pe_core_signed_segmented_csa_ipd.sv), instead of N_W edges rotating
// each row once around its drain chain through a <<1 at the PE west input.
// Same parameters, ports, Sobol banks, peripheral (sc_pe_peripheral_bp),
// combiner (PaynBpCombiner), mode register, MAC guard, ring gate and instance
// names (u_pe/u_array_core/g_row/g_col/u_inner, a_bits_pipe) as the BP top;
// the tile module is untouched.  SC mode is the accepted
// payn_array_signed_segmented_csa (ring_in is gated by int_mode, so ring_q = 0
// and every tile takes its west neighbour, as in the CSA core).
//
// BP INT8 mapping (unchanged; one PE = 1 activation row x 8 output columns):
// lane k, position m of a data cycle carries reduction element
// x = 128*b + 16*k + m; tile row h carries bit h of A[x]; in weight pass q
// (MSB pass first) tile column v carries bit q of W[x, v].  a_signs = (h ==
// top bit), w_signs = all ones in the weight-MSB pass.  Between passes ONE
// lap edge doubles every tile in place; after the last pass a normal drain
// (shift_in, acc_in_west = 0) moves the columns east and the combiner forms
// out = sum_h 2^h * tile(h).  W4A8: 4 passes.  INT4 (int_prec = 1): rows 0-3
// and 4-7 are two activation rows of 4 planes, two outputs per column.  The
// mapping is defined for N_H = N_W = 8; other shapes elaborate (SC drop-in)
// but INT mode is not defined there.
//
// Sequencer contract (all inputs launched half a period before the edge).
// Identical to the BP top except the lap:
//   * SC mode: int_mode = 0.  a_raw_in, w_raw_in, int_prec and ring_in then
//     have no effect, whatever they toggle to.
//   * int_mode is registered before the 2,048-pin select (raise it one edge
//     before the first raw capture); the MAC guard drops mac_en on the two
//     edges after any int_mode change; INT-mode loads carry zero magnitudes,
//     with a zero-load on INT entry ([BP-CONTRACT] simulation check below).
//   * Lap (in-place doubling): ring_in high for ONE edge, one edge ahead of
//     the lap edge (ring_q lags it).  On the lap edge ring_q shifts the tiles
//     (tile shift = shift_in | ring_q) and every tile loads its own canonical
//     value << 1 (pending carry/borrow folded in, both cleared), so every tile
//     doubles exactly (mod 2^OWIDTH).  shift_in is not needed on the lap edge;
//     asserting it there too is harmless (the OR is idempotent and the doubling
//     mux follows ring_q).  The MAC on the lap edge is dropped (shift
//     priority), so the plane captured on the edge before it must be a bubble:
//     a weight pass of NB data edges takes NB + 1 edges.
//   * k consecutive ring_in edges multiply every tile by 2^k.  BP schedules
//     with N_W-edge laps (csa_bp_20261004_lap) therefore multiply by 2^N_W here
//     and are NOT compatible: only the lap length changes, the rest of the
//     schedule (sign loads, drain, combiner capture) is the same.
//   * ring_in is a strict control in INT mode: every high edge makes the next
//     edge a doubling edge (MAC dropped).  Keep it low otherwise, and lower
//     int_mode only after the last ring_in edge.
//   * In a PE grid (inner_pe_grid_signed_segmented_csa_bp_ipd.sv) ring_out
//     carries ring_q east one PE per edge: inject ring_in per PE row with that
//     row's A skew and PE (r,c) laps when its own pass ends, offset r+c.  The
//     global shift_in is then needed only for the final drain; since on a
//     grid larger than 1x1 no edge has every PE lapping (only the PEs of one
//     anti-diagonal r+c lap together), the global shift_in must be low on
//     every lap edge of a grid (drains only).  Block
//     period: BW*NB + (BW-1) + (P_R+P_C-2) + 8*P_C edges.
//   * Drain: shift_in with ring_q low and acc_in_west = 0.  The combiner
//     captures on exactly those edges (int_mode & shift_in & ~ring_q) and
//     emits int_out / int_out_valid two edges later; lap edges never capture.
//   * Range: as the BP top (tiles exact mod 2^OWIDTH; INT8 L <= 65,535 per
//     output block; W4A8 and INT4 L <= 1,048,575).

`include "payn/sobol.sv"
`include "payn/variants/signed_segmented_csa_bp/pe_peripheral_bp.sv"
`include "payn/variants/signed_segmented_csa_bp_ipd/inner_pe_signed_segmented_csa_bp_ipd.sv"
`include "payn/variants/signed_segmented_csa_bp/bp_combiner.sv"

`ifndef PAYN_K
`define PAYN_K 6
`endif
`ifndef PAYN_M
`define PAYN_M 16
`endif
`ifndef PAYN_NH
`define PAYN_NH 9
`endif
`ifndef PAYN_NW
`define PAYN_NW 9
`endif
`ifndef PAYN_SEG_LOW_W
`define PAYN_SEG_LOW_W 11
`endif

module payn_array_signed_segmented_csa_bp_ipd #(
    parameter int K = `PAYN_K,
    parameter int M = `PAYN_M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = `PAYN_SEG_LOW_W,
    parameter logic SCRAMBLE_ENABLE = 1'b1,
    parameter int A_SCRAMBLE_SALT = 0,
    parameter int W_SCRAMBLE_SALT = (1 << (WIDTH - 1)),
    parameter int A_DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] A_SHIFT_BASE = 8'h17,
    parameter logic [WIDTH-1:0] A_SHIFT_STRIDE = 8'h53,
    parameter int W_DIRECTION_SET = 1,
    parameter logic [WIDTH-1:0] W_SHIFT_BASE = 8'h9d,
    parameter logic [WIDTH-1:0] W_SHIFT_STRIDE = 8'h2b,
    parameter logic RNG_FULL_PERIOD_WRAP = 1'b0
) (
    input logic clk,
    input logic reset,
    input logic rng_en,
    input logic load_a,
    input logic load_w,
    input logic load_a_sign,
    input logic load_w_sign,
    input logic mac_en,
    input logic shift_in,
    input logic [N_H*K*WIDTH-1:0] a_binary_in,
    input logic [N_H*K-1:0] a_signs_in,
    input logic [N_W*K*WIDTH-1:0] w_binary_in,
    input logic [N_W*K-1:0] w_signs_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east,
    // BP INT mode
    input  logic int_mode,
    input  logic int_prec,
    input  logic ring_in,
    input  logic [N_H*K*M-1:0] a_raw_in,
    input  logic [N_W*K*M-1:0] w_raw_in,
    output logic [63:0] int_out,
    output logic int_out_valid
);
    logic [M*WIDTH-1:0] a_random_values;
    logic [M*WIDTH-1:0] w_random_values;

    sobol_bank #(
        .WIDTH(WIDTH), .M(M),
        .DIRECTION_SET(A_DIRECTION_SET),
        .DIGITAL_SHIFT_BASE(A_SHIFT_BASE),
        .DIGITAL_SHIFT_STRIDE(A_SHIFT_STRIDE),
        .FULL_PERIOD_WRAP(RNG_FULL_PERIOD_WRAP)
    ) u_a_rng (
        .clk, .reset, .enable(rng_en), .random_values(a_random_values)
    );

    sobol_bank #(
        .WIDTH(WIDTH), .M(M),
        .DIRECTION_SET(W_DIRECTION_SET),
        .DIGITAL_SHIFT_BASE(W_SHIFT_BASE),
        .DIGITAL_SHIFT_STRIDE(W_SHIFT_STRIDE),
        .FULL_PERIOD_WRAP(RNG_FULL_PERIOD_WRAP)
    ) u_w_rng (
        .clk, .reset, .enable(rng_en), .random_values(w_random_values)
    );

    //------------------------------------------------------------- mode --
    // int_mode_q drives the peripheral's 2,048-pin select from a flop.  The
    // bit pipes register one edge before the MAC, so the MAC at edge E uses a
    // sample captured under int_mode_q2 (as seen at E); the guard drops mac_en
    // whenever that differs from the mode the sequencer declares at E.
    logic int_mode_q, int_mode_q2;
    logic mac_core;

    always_ff @(posedge clk) begin
        if (reset) begin
            int_mode_q <= 1'b0;
            int_mode_q2 <= 1'b0;
        end else begin
            int_mode_q <= int_mode;
            int_mode_q2 <= int_mode_q;
        end
    end

    assign mac_core = mac_en & (int_mode ~^ int_mode_q2);

    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0]   w_signs;

    sc_pe_peripheral_bp #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .SCRAMBLE_ENABLE(SCRAMBLE_ENABLE),
        .A_SCRAMBLE_SALT(A_SCRAMBLE_SALT),
        .W_SCRAMBLE_SALT(W_SCRAMBLE_SALT)
    ) u_peripheral (
        .clk, .reset, .load_a, .load_w,
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in,
        .a_random_values, .w_random_values,
        .int_mode(int_mode_q), .a_raw_in, .w_raw_in,
        .a_bits, .a_signs, .w_bits, .w_signs
    );

    // This top is a single PE, so the systolic re-export rails terminate here.
    // Synthesis drops their fanout; they exist for an outer PE grid.
    logic [N_H*K*M-1:0] a_bits_out_nc;
    logic [N_H*K-1:0]   a_signs_out_nc;
    logic [N_W*K*M-1:0] w_bits_out_nc;
    logic [N_W*K-1:0]   w_signs_out_nc;
    logic load_a_sign_out_nc, load_w_sign_out_nc;
    logic ring_q;

    InnerPESignedSegmentedCsaBpIpdFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) u_pe (
        .clk, .reset, .mac_en(mac_core), .shift_in,
        .ring_in(ring_in & int_mode),
        .a_bits_in(a_bits), .a_signs_in(a_signs),
        .w_bits_in(w_bits), .w_signs_in(w_signs),
        .load_a_sign_in(load_a_sign), .load_w_sign_in(load_w_sign),
        .a_bits_out(a_bits_out_nc), .a_signs_out(a_signs_out_nc),
        .w_bits_out(w_bits_out_nc), .w_signs_out(w_signs_out_nc),
        .load_a_sign_out(load_a_sign_out_nc),
        .load_w_sign_out(load_w_sign_out_nc),
        .ring_out(ring_q),
        .acc_in_west, .acc_out_east
    );

    // Drain edges (shift_in with ring_q low in INT mode) sample the east
    // column before it shifts; lap edges (ring_q high, shift_in high or low)
    // do not.  Unchanged from the BP top: an IPD lap edge is also a ring_q
    // edge, it just doubles in place instead of rotating.
    PaynBpCombiner #(
        .N_H(N_H), .OWIDTH(OWIDTH), .OUT_W(32)
    ) u_combiner (
        .clk, .reset,
        .capture(int_mode & shift_in & ~ring_q),
        .int_prec,
        .acc_east(acc_out_east),
        .out(int_out),
        .out_valid(int_out_valid)
    );

`ifndef SYNTHESIS
    // [BP-CONTRACT] INT magnitudes: a MAC must not consume a pipe sample in
    // which a comparator fired under the INT select (magnitude registers not
    // held at zero).  int_sample_dirty describes the sample captured on the
    // previous edge, which is the one the MAC on this edge consumes.
    logic int_sample_dirty = 1'b0;
    always @(posedge clk) begin
        if (!reset && mac_core === 1'b1 && int_sample_dirty === 1'b1)
            $fatal(1, "[BP-CONTRACT] INT MAC consumed live comparator bits: load zero magnitudes in INT mode");
        int_sample_dirty <= int_mode_q &&
            (|u_peripheral.sc_a_bits || |u_peripheral.sc_w_bits);
    end
`endif
endmodule

`endif
