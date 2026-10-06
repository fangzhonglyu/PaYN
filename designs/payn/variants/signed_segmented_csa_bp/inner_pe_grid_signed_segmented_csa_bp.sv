`ifndef PAYN_SIGNED_SEGMENTED_CSA_BP_INNER_PE_GRID
`define PAYN_SIGNED_SEGMENTED_CSA_BP_INNER_PE_GRID

`timescale 1ns/1ps

`include "payn/variants/signed_segmented_csa_bp/inner_pe_signed_segmented_csa_bp.sv"

// P_ROWS x P_COLS outer grid of bit-plane carry-save PEs
// (InnerPESignedSegmentedCsaBpFlat).  Same wiring as
// ../signed_segmented_clean/inner_pe_grid_signed_segmented_clean.sv, plus the
// ring wave:
//
//   A bits / signs and load_a_sign   wave east across PE columns
//   W bits / signs and load_w_sign   wave south across PE rows
//   ring (ring_q -> ring_out)        waves east across PE columns
//   accumulators                     chain west -> east through every PE column
//
// Every PE re-registers what it forwards, so each wave advances one PE per
// edge.  The grid is pure wiring apart from one AND per PE row: the west-edge
// ring inputs are gated by int_mode, as in the single-PE top, so in SC mode
// no lap can start.
//
// The edge driver applies the usual systolic skew (the edge peripherals'
// job; this module has none):
//   A slice t enters PE row r on edge t + r      (a_bits_in / a_signs_in [r])
//   W slice t enters PE column c on edge t + c   (w_bits_in / w_signs_in [c])
// so both copies of slice t meet in PE (r,c) on edge t + r + c.  In BP INT
// mode the bits are the raw planes (bits = comparator | raw, comparators
// silent) and the per-pass sign loads ride the same skew.
//
// Per-PE ring laps: inject ring_in[r] with row r's A skew, i.e. drive it one
// edge ahead of PE (r,0)'s lap edges.  The wave then reaches PE (r,c) c edges
// later, so every PE laps exactly when its own pass ends, offset r+c, with no
// global bubble.  The global shift_in is used only for the final drain (and
// SC drains): 8*P_COLS edges with acc_in_west = 0 once the last PE,
// (P_ROWS-1, P_COLS-1), has finished its last pass.  The INT block period is
//
//     BW*NB + 8*(BW-1) + (P_ROWS + P_COLS - 2) + 8*P_COLS   edges
//
// (NB data edges per weight pass, BW passes): the skew is paid once per output
// block, before the drain, not once per pass.  This is the schedule of
// designs/payn/tb/test_pe_grid_bp.sv (sweeps/int_mode/bp/run_bp_grid_checks.sh):
// the RTL runs it bit-exactly (multi-block runs also measure the drain-start
// spacing), and tightness controls fail when any term is one edge shorter
// (lap on the last MAC, drain one edge early, next block one edge early).
// A per-PE-row drain (shift_in skewed by r, not in this wrapper) would cut the
// skew term from P_ROWS+P_COLS-2 to P_COLS-1.
//
// Global shift_in on a grid.  shift_in reaches every PE on the same edge, so
// besides drains it is legal only on edges where every PE is lapping (the OR
// with ring_q is idempotent there); on any other edge it shifts PEs that are
// not lapping.  When P_ROWS+P_COLS-2 >= 8 no such edge exists (4x8).  The
// single-PE csa_bp_20261003b contract (one global ring signal, shift_in on
// every lap edge) therefore needs a broadcast ring: it holds for P_COLS = 1
// (with each lap waiting for the skew), but this wrapper's ring wave cannot
// make simultaneous laps for P_COLS > 1 (the bench's OLDC_UNFORCED case passes
// on 4x1 and fails on 2x2 and 4x8; its GLOBAL_LAP_WAIT control forces every
// PE's ring_in).
//
// int_mode only gates the west-edge ring inputs; the links between PEs are
// not gated.  So int_mode must be high on every edge where a row injects
// (ring_in[r] high), and a wave already in a row finishes whatever int_mode
// does: PE (r,c) still laps up to c+1 edges after the row's last west ring_in
// edge (P_COLS edges for the far column).  SC work that relies on ring_q = 0
// must wait those edges; in practice lower int_mode after the drain.
//
// Reset.  The operand bit pipes (a_bits / w_bits, one register per PE) are
// not reset and are not gated by mac_en; ring_q, the sign pipes, the sign
// load wave and the tiles are reset.  After a reset, PE (r,c) still holds
// planes driven before the reset until c (A) or r (W) fresh edges have
// flowed in, so a MAC at PE (r,c) can add a stale product while
// min(r,c) >= (edges since the reset started).  Rule: from the first reset
// edge on, drive no planes of an aborted block (zero planes or the next
// block's), and let the first MAC edge (mac_en high) come at least
// min(P_ROWS,P_COLS) edges after the first reset edge: hold reset that long,
// or keep mac_en low for min(P_ROWS,P_COLS) - n edges after an n-edge reset.
// The same holds for X after power-up.  A single PE needs one reset edge.
// This is a property of the CSA core's pipes (the clean grid shares it), not
// of the ring.  Characterized by sweeps/int_mode/bp/verify_grid/run_vg.sh
// (reset_pass_n<n>_f<f>).
//
// ring_out[r] is PE (r, P_COLS-1)'s ring_q: an east-edge plane combiner for
// PE row r captures on int_mode & shift_in & ~ring_out[r], as the single-PE
// top does.  mac_en is global; zero planes (bubbles) contribute exactly zero,
// so it can stay high through skew, laps and drains (shift has priority).
//
// Packed ports, PE row / column major: a_bits_in[(r*N_H*K + h*K + d)*M +: M]
// is PE row r's lane d of tile row h, w_bits_in[(c*N_W*K + v*K + d)*M +: M]
// PE column c's lane d of tile column v, acc_in_west[(r*N_H + h)*OWIDTH +:
// OWIDTH] PE row r's accumulator row h.
module InnerPESignedSegmentedCsaBpGrid #(
    parameter int P_ROWS = 2,
    parameter int P_COLS = 2,
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic int_mode,
    input  logic [P_ROWS-1:0] ring_in,

    input  logic [P_ROWS*N_H*K*M-1:0] a_bits_in,
    input  logic [P_ROWS*N_H*K-1:0]   a_signs_in,
    input  logic [P_COLS*N_W*K*M-1:0] w_bits_in,
    input  logic [P_COLS*N_W*K-1:0]   w_signs_in,
    input  logic [P_ROWS-1:0]         load_a_sign_in,
    input  logic [P_COLS-1:0]         load_w_sign_in,

    output logic [P_ROWS*N_H*K*M-1:0] a_bits_out,
    output logic [P_ROWS*N_H*K-1:0]   a_signs_out,
    output logic [P_COLS*N_W*K*M-1:0] w_bits_out,
    output logic [P_COLS*N_W*K-1:0]   w_signs_out,
    output logic [P_ROWS-1:0]         load_a_sign_out,
    output logic [P_COLS-1:0]         load_w_sign_out,
    output logic [P_ROWS-1:0]         ring_out,

    input  logic [P_ROWS*N_H*OWIDTH-1:0] acc_in_west,
    output logic [P_ROWS*N_H*OWIDTH-1:0] acc_out_east
);
    localparam int AB = N_H*K*M;     // one PE row's A bits
    localparam int AS = N_H*K;
    localparam int WB = N_W*K*M;     // one PE column's W bits
    localparam int WS = N_W*K;
    localparam int AW = N_H*OWIDTH;  // one PE row's accumulator rows

    initial begin
        assert (P_ROWS > 0 && P_COLS > 0)
            else $fatal(1, "P_ROWS and P_COLS must be positive");
    end

    logic [AB-1:0] a_bits_link  [P_ROWS][P_COLS+1];
    logic [AS-1:0] a_signs_link [P_ROWS][P_COLS+1];
    logic          load_a_link  [P_ROWS][P_COLS+1];
    logic          ring_link    [P_ROWS][P_COLS+1];
    logic [AW-1:0] acc_link     [P_ROWS][P_COLS+1];
    logic [WB-1:0] w_bits_link  [P_COLS][P_ROWS+1];
    logic [WS-1:0] w_signs_link [P_COLS][P_ROWS+1];
    logic          load_w_link  [P_COLS][P_ROWS+1];

    for (genvar r = 0; r < P_ROWS; r++) begin : g_a_edges
        assign a_bits_link[r][0] = a_bits_in[r*AB +: AB];
        assign a_signs_link[r][0] = a_signs_in[r*AS +: AS];
        assign load_a_link[r][0] = load_a_sign_in[r];
        assign ring_link[r][0] = ring_in[r] & int_mode;
        assign acc_link[r][0] = acc_in_west[r*AW +: AW];
        assign a_bits_out[r*AB +: AB] = a_bits_link[r][P_COLS];
        assign a_signs_out[r*AS +: AS] = a_signs_link[r][P_COLS];
        assign load_a_sign_out[r] = load_a_link[r][P_COLS];
        assign ring_out[r] = ring_link[r][P_COLS];
        assign acc_out_east[r*AW +: AW] = acc_link[r][P_COLS];
    end

    for (genvar c = 0; c < P_COLS; c++) begin : g_w_edges
        assign w_bits_link[c][0] = w_bits_in[c*WB +: WB];
        assign w_signs_link[c][0] = w_signs_in[c*WS +: WS];
        assign load_w_link[c][0] = load_w_sign_in[c];
        assign w_bits_out[c*WB +: WB] = w_bits_link[c][P_ROWS];
        assign w_signs_out[c*WS +: WS] = w_signs_link[c][P_ROWS];
        assign load_w_sign_out[c] = load_w_link[c][P_ROWS];
    end

    for (genvar r = 0; r < P_ROWS; r++) begin : g_pe_row
        for (genvar c = 0; c < P_COLS; c++) begin : g_pe_col
            InnerPESignedSegmentedCsaBpFlat #(
                .K(K), .M(M), .N_H(N_H), .N_W(N_W),
                .OWIDTH(OWIDTH), .LOW_W(LOW_W)
            ) u_pe (
                .clk,
                .reset,
                .mac_en,
                .shift_in,
                .ring_in(ring_link[r][c]),
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
                .ring_out(ring_link[r][c+1]),
                .acc_in_west(acc_link[r][c]),
                .acc_out_east(acc_link[r][c+1])
            );
        end
    end
endmodule

`endif
