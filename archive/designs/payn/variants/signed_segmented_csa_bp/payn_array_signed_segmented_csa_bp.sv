`ifndef PAYN_SIGNED_SEGMENTED_CSA_BP_ARRAY
`define PAYN_SIGNED_SEGMENTED_CSA_BP_ARRAY

`timescale 1ns/1ps

// Carry-save single-PE array with bit-plane (BP) INT mode.  SC mode is the
// accepted payn_array_signed_segmented_csa: same parameters, SC ports, Sobol
// banks, peripheral and PE (tiles untouched), same instance names.  Added:
//   * mode register int_mode_q, which drives the peripheral's select tree, and
//     a two-edge MAC guard around every int_mode change;
//   * u_peripheral: bits = comparator | (raw & int_mode_q)
//     (sc_pe_peripheral_bp around the unchanged sc_pe_peripheral);
//   * u_pe: the per-PE doubling ring (ring_in -> ring_q, the per-PE lap
//     enable, which shifts the tiles and steers the west mux);
//   * u_combiner: the east-edge plane shift-add, int_out / int_out_valid.
//
// BP INT8 mapping (one PE = 1 activation row x 8 output columns): lane k,
// position m of a data cycle carries reduction element x = 128*b + 16*k + m;
// tile row h carries bit h of A[x]; in weight pass q (MSB pass first) tile
// column v carries bit q of W[x, v].  a_signs = (h == top bit), w_signs = all
// ones in the weight-MSB pass.  Between passes a ring lap doubles every tile;
// after the last pass a normal drain (shift_in, acc_in_west = 0) moves the
// columns east and the combiner forms out = sum_h 2^h * tile(h).  W4A8: 4
// passes.  INT4 (int_prec = 1): rows 0-3 and 4-7 are two activation rows of 4
// planes, two outputs per column.  The mapping is defined for N_H = N_W = 8;
// other shapes elaborate (SC drop-in) but INT mode is not defined there.
//
// Sequencer contract (all inputs launched half a period before the edge):
//   * SC mode: int_mode = 0.  a_raw_in, w_raw_in, int_prec and ring_in then
//     have no effect, whatever they toggle to.
//   * int_mode is registered before the 2,048-pin select: a raw plane is
//     captured by the bit pipes at edge P only if int_mode was already high at
//     edge P-1.  Symmetrically the comparators reach the pipes again one edge
//     after int_mode falls.
//   * MACs never mix modes: on the two edges after any int_mode change the
//     guard drops mac_en, because those MACs would consume a pipe sample
//     captured under the other mode (pipes register one edge before the MAC).
//     A schedule never needs such a MAC, so the guard only removes hazards.
//   * INT mode needs silent comparators: the magnitude registers are held at
//     zero.  Every load_a / load_w while int_mode is high carries zero
//     a_binary_in / w_binary_in (those loads carry the plane signs), and after
//     SC -> INT both sides are loaded before the first raw plane a MAC uses is
//     captured.  Checked in simulation below ([BP-CONTRACT]).
//   * Ring lap (per-PE lap enable, csa_bp_20261004_lap): ring_in high for N_W
//     consecutive edges, one edge ahead (ring_q lags it).  ring_q alone makes
//     the N_W lap edges shift edges (tile shift = shift_in | ring_q) and steers
//     the west mux to the doubled east column; shift_in is not needed on lap
//     edges.  Asserting it there too, as the as-built csa_bp_20261003b
//     contract required, is still legal (the OR is idempotent), so every
//     schedule written for that contract still runs unchanged on this
//     single-PE top (for grids see below).  Zero raw planes during a lap.
//   * ring_in is a strict control in INT mode: ring_in high at edge P makes
//     P+1 a lap (shift) edge whatever shift_in is, so it must be low except
//     one edge ahead of each lap edge.  A stray pulse drops that edge's MAC
//     and rotates the tiles.  (Before csa_bp_20261004_lap, ring_in without
//     shift_in did nothing.)  Lower int_mode only after the last ring_in edge
//     of a lap: ring_in is gated by the int_mode port, so a lap edge already
//     registered in ring_q still shifts on the next edge.
//   * In a PE grid (inner_pe_grid_signed_segmented_csa_bp.sv) ring_out
//     carries ring_q east one PE per edge: inject ring_in per PE row with that
//     row's A skew, and PE (r,c) laps when its own pass ends, offset r+c.  The
//     global shift_in is then needed only for the final drain.  On a grid,
//     shift_in reaches every PE at once, so besides drains it is legal only on
//     edges where every PE laps (none when P_R+P_C-2 >= 8); the old contract
//     (one global ring signal plus shift_in on every lap edge) needs a
//     broadcast ring, i.e. P_C = 1 or a forced bench signal as in the grid
//     bench's GLOBAL_LAP_WAIT control.  The grid gates only the west-edge
//     ring_in with int_mode, so a wave already in a row still laps PE (r,c)
//     up to c+1 edges after the row's last ring_in edge.  The grid's operand
//     bit pipes are not reset: the first MAC after a reset must come at least
//     min(P_R,P_C) edges after the reset starts (grid header).
//   * Drain: shift_in with ring_q low and acc_in_west = 0.  The combiner
//     captures on exactly those edges (int_mode & shift_in & ~ring_q) and
//     emits int_out / int_out_valid two edges later; lap edges never capture,
//     with or without shift_in.
//   * Range: tiles are exact mod 2^OWIDTH and wrap silently.  |tile| <=
//     2^(BW-1) * L < 2^23 bounds the reduction length per output block:
//     INT8 L <= 65,535; W4A8 and INT4 L <= 1,048,575.  Longer reductions must
//     be split into blocks and summed downstream.

`include "payn/sobol.sv"
`include "payn/variants/signed_segmented_csa_bp/pe_peripheral_bp.sv"
`include "payn/variants/signed_segmented_csa_bp/inner_pe_signed_segmented_csa_bp.sv"
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

module payn_array_signed_segmented_csa_bp #(
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

    InnerPESignedSegmentedCsaBpFlat #(
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
    // do not.
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
