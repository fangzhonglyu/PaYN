`ifndef PAYN_SIGNED_SEGMENTED_CSA_BP_SR_INNER_PE
`define PAYN_SIGNED_SEGMENTED_CSA_BP_SR_INNER_PE

`include "payn/variants/signed_segmented_csa_bp_sr/inner_pe_core_signed_segmented_csa_sr.sv"

// Carry-save PE with bit-plane (BP) INT mode and SUB-RING laps of LAP_G edges
// (the knob between the BP ring and in-place doubling).  Same ports, same
// registered per-PE lap enable (ring_q) and same ring wave (ring_out) as
// ../signed_segmented_csa_bp/inner_pe_signed_segmented_csa_bp.sv
// (InnerPESignedSegmentedCsaBpFlat) and
// ../signed_segmented_csa_bp_ipd/inner_pe_signed_segmented_csa_bp_ipd.sv
// (InnerPESignedSegmentedCsaBpIpdFlat); what a lap does depends on LAP_G:
//
//     tile shift      = shift_in | ring_q                       (unchanged)
//     head tile acc_in = ring_q ? sub-ring tail acc_out << 1 : west
//                       (N_W/LAP_G muxes per tile row, in the core
//                        InnerPESignedSegmentedCsaSr)
//     PE west input   = acc_in_west                              (no ring mux, no return wires)
//
// A lap is LAP_G consecutive ring_q edges; the INT block period is
//     BW*NB + LAP_G*(BW-1) + (P_R+P_C-2) + 8*P_C   edges
// (BP ring: LAP_G = N_W = 8; in-place doubling: LAP_G = 1).
//
// Contract (difference to the BP PE): ring_in high for exactly LAP_G
// consecutive edges, one edge ahead of the lap edges, per weight-pass
// boundary.  Any other run length permutes the tiles of a sub-ring (k edges
// rotate every sub-ring by k and double the k values that wrap), so BP
// schedules (8-edge laps) and IPD schedules (1-edge laps) are NOT compatible
// unless LAP_G equals their lap length.  ring_in is strict in INT mode, as in
// the BP PE.  The MAC on every lap edge is dropped (shift has priority), so the
// plane captured one edge before the first lap edge must be a bubble.
// Asserting shift_in on a lap edge is harmless (the OR is idempotent and the
// muxes follow ring_q).
//
// ring_q is reset, as in the BP PE.  With ring_in = 0 the PE is exactly
// InnerPESignedSegmentedCsaFlat; the SR top and grid gate ring_in with
// int_mode.  Packed ports as InnerPESignedSegmentedCsaFlat; the core keeps the
// instance name u_array_core so the APR distribution guides still apply.
module InnerPESignedSegmentedCsaBpSrFlat #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 11,
    parameter int LAP_G = 2
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
    // selects every sub-ring head's doubled-tail input.  shift_in stays the
    // drain (and SC) shift.
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
        assign acc_in_west_array[h] = $signed(acc_in_west[h*OWIDTH +: OWIDTH]);
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

    InnerPESignedSegmentedCsaSr #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W), .LAP_G(LAP_G)
    ) u_array_core (
        .clk,
        .reset,
        .mac_en,
        .shift_in(core_shift),
        .lap(ring_q),
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
