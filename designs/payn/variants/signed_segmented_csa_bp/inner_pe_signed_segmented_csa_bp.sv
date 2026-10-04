`ifndef PAYN_SIGNED_SEGMENTED_CSA_BP_INNER_PE
`define PAYN_SIGNED_SEGMENTED_CSA_BP_INNER_PE

`include "payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv"

// Carry-save PE with the bit-plane (BP) doubling ring.  The array core is the
// unchanged InnerPESignedSegmentedCsa; the PE adds a registered per-PE lap
// enable (ring_q), one OR in front of the core's shift input, and a mux at the
// west boundary of each row.
//
// BP INT mode applies the weight-plane factor 2^q in time, MSB pass first: between
// weight passes every tile value is doubled by one lap around this PE's own
// drain chain.  A lap is N_W edges on which ring_q is high:
//
//     tile shift      = shift_in | ring_q         (ring_q alone shifts the tiles)
//     west input[h]   = ring_q ? acc_out_east[h] << 1 : acc_in_west[h]
//
// so after N_W lap edges every value is back in its home tile, doubled exactly
// once.  A shift loads the west tile's canonical {high_next, acc_low} with any
// pending carry/borrow already folded in and clears both pending flags, so the
// doubling is exact (mod 2^OWIDTH) and the heap never sees a shifted operand.
// Shift has priority over MAC, so the data mover sends zero bubbles during a
// lap.
//
// Per-PE lap enable (2026-10-04, synthesis run csa_bp_20261004_lap): ring_q is
// registered from ring_in and re-exported as ring_out, like the sign-load wave,
// so in an outer grid the lap rides the systolic skew: inject ring_in per PE
// row at the west edge with that row's A skew, and PE (r,c) laps exactly when
// its own pass ends (offset r+c, like its operands), with no global bubble.
// The global shift_in is then needed only for the final drain (and SC drains).
// Asserting shift_in on lap edges as well (the as-built csa_bp_20261003b
// contract, where ring_q only steered the west mux and the tiles shifted on
// shift_in alone) still works: the OR is idempotent.  Timing: ring_q is a flop
// with a full cycle; shift_in -> tile clock-gate enable gains one OR2 and
// keeps the shift_in input budget.  A registered shift enable would give that
// path a full cycle, but the tiles would then shift one edge after shift_in,
// which changes the SC drain timing the CSA drop-in contract fixes, so it was
// not taken (README, "Per-PE lap enable").
//
// ring_q is reset so a reset never leaves a stray lap.  Because ring_q now
// shifts the tiles by itself, ring_in must be low except one edge ahead of
// each lap edge.  With ring_in = 0 the PE is exactly
// InnerPESignedSegmentedCsaFlat; the BP top and the BP grid gate ring_in with
// int_mode.
//
// Packed ports as InnerPESignedSegmentedCsaFlat (DC flattens unpacked array
// ports inconsistently).  The core keeps the instance name u_array_core so the
// APR distribution guides (u_pe/u_array_core/a_bits_pipe_reg_*) still apply.
module InnerPESignedSegmentedCsaBpFlat #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 11
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic ring_in,
    input  logic [N_H*K*M-1:0] a_bits_in,
    input  logic [N_H*K-1:0]   a_signs_in,
    input  logic [N_W*K*M-1:0] w_bits_in,
    input  logic [N_W*K-1:0]   w_signs_in,
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,
    output logic [N_H*K*M-1:0] a_bits_out,
    output logic [N_H*K-1:0]   a_signs_out,
    output logic [N_W*K*M-1:0] w_bits_out,
    output logic [N_W*K-1:0]   w_signs_out,
    output logic load_a_sign_out,
    output logic load_w_sign_out,
    output logic ring_out,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic [M-1:0] a_bits_in_array   [N_H][K];
    logic         a_signs_in_array  [N_H][K];
    logic [M-1:0] w_bits_in_array   [N_W][K];
    logic         w_signs_in_array  [N_W][K];
    logic [M-1:0] a_bits_out_array  [N_H][K];
    logic         a_signs_out_array [N_H][K];
    logic [M-1:0] w_bits_out_array  [N_W][K];
    logic         w_signs_out_array [N_W][K];
    logic signed [OWIDTH-1:0] acc_in_west_array  [N_H];
    logic signed [OWIDTH-1:0] acc_out_east_array [N_H];

    //------------------------------------------------------------- ring --
    // ring_q is the per-PE lap enable: it shifts the core on its own and
    // steers the west mux.  shift_in stays the drain (and SC) shift.
    logic ring_q;
    logic core_shift;

    always_ff @(posedge clk) begin
        if (reset)
            ring_q <= 1'b0;
        else
            ring_q <= ring_in;
    end

    assign ring_out = ring_q;
    assign core_shift = shift_in | ring_q;

    for (genvar h = 0; h < N_H; h++) begin : g_a_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign a_bits_in_array[h][d] = a_bits_in[(h*K + d)*M +: M];
            assign a_signs_in_array[h][d] = a_signs_in[h*K + d];
            assign a_bits_out[(h*K + d)*M +: M] = a_bits_out_array[h][d];
            assign a_signs_out[h*K + d] = a_signs_out_array[h][d];
        end
        // Ring lap: the west tile takes this row's own east value, doubled.
        assign acc_in_west_array[h] = ring_q
            ? {acc_out_east_array[h][OWIDTH-2:0], 1'b0}
            : $signed(acc_in_west[h*OWIDTH +: OWIDTH]);
        assign acc_out_east[h*OWIDTH +: OWIDTH] = acc_out_east_array[h];
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign w_bits_in_array[v][d] = w_bits_in[(v*K + d)*M +: M];
            assign w_signs_in_array[v][d] = w_signs_in[v*K + d];
            assign w_bits_out[(v*K + d)*M +: M] = w_bits_out_array[v][d];
            assign w_signs_out[v*K + d] = w_signs_out_array[v][d];
        end
    end

    InnerPESignedSegmentedCsa #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) u_array_core (
        .clk,
        .reset,
        .mac_en,
        .shift_in(core_shift),
        .a_bits_in(a_bits_in_array),
        .a_signs_in(a_signs_in_array),
        .w_bits_in(w_bits_in_array),
        .w_signs_in(w_signs_in_array),
        .load_a_sign_in,
        .load_w_sign_in,
        .a_bits_out(a_bits_out_array),
        .a_signs_out(a_signs_out_array),
        .w_bits_out(w_bits_out_array),
        .w_signs_out(w_signs_out_array),
        .load_a_sign_out,
        .load_w_sign_out,
        .acc_in_west(acc_in_west_array),
        .acc_out_east(acc_out_east_array)
    );
endmodule

`endif
