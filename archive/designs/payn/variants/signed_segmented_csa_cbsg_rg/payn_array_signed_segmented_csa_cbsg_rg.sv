`ifndef PAYN_SIGNED_SEGMENTED_CSA_CBSG_RG_ARRAY
`define PAYN_SIGNED_SEGMENTED_CSA_CBSG_RG_ARRAY

`timescale 1ns/1ps

// Carry-save single-PE array running the scmp_kernels C-BSG multiplication
// bit-exactly, design RG (per-row generator, the literal C-BSG; reference
// sweeps/cbsg/cbsg_ref.py hw_rg_acc, contract in sweeps/cbsg/README.md).
// The CSA tile is the accepted InnerTileSignedSegmentedCsa, unchanged; the CSA
// top's ports keep their names.  What differs from payn_array_signed_segmented_csa:
//   * u_a_rng: the sample-ordered Sobol "q" bank (H register + cycle index;
//     position m of cycle c is sample t = 16c + m), restarted every block,
//     and a copy of the block phase, replicated once per A row (each row's
//     128 comparators read their own copy).  There is no W bank.
//   * u_peripheral (cbsg_rg_edge): A comparators b_A > ((x_q ^ mask) >> 1) gated
//     by t < L_row; the W magnitudes leave the edge raw.
//   * phase_q: the 3-bit block phase, mask bits [4:2] = bitrev3(p).  Lane k's
//     mask bits [7:5] = bitrev3(k) are wired: mask = bitrev8(d mod 64), d = 8p+k.
//   * u_pe: per (row, lane) W index generator (C-BSG: the block's kA A ones
//     meet W samples 0..kA-1) and 8,192 per-tile W comparators feeding the
//     tiles' w_bits.
//
// Operands: a_binary_in / w_binary_in carry the kernel boundary b = 0..128 in
// each 8-bit field (b = round(|q| * 128/127) = |q| + [|q| >= 64]); signs are
// 1 = negative.  A zero magnitude contributes 0 whatever its sign.
// row_len_in carries the stream length L_h = 1..128 of each A row (8 bits).
//
// Sequencer contract (all inputs launched half a period before the edge;
// "edge" = rising edge; block = 8 consecutive reduction columns of a slice,
// lane k = slice-local column 8j + k of the slice's j-th block, a partial last
// block padded with zero magnitude):
//   * Block length.  A block runs C = ceil(max_h L_h / 16) cycles (1..8) of 16
//     samples, t = 16c + m.  Any C' in C..8 gives the same result (rows past
//     their L_h, and t >= 128, generate zeros).
//   * Generation edges.  Block b occupies C rng_en edges G, ..., G+C-1.  On G:
//     rng_en = 1, block_start = 1, slice_start = [b is the first block of its
//     slice], and load_a = load_w = load_a_sign = load_w_sign = 1 carrying the
//     block's a_binary_in, a_signs_in, row_len_in (latched by load_a),
//     w_binary_in and w_signs_in.  On G+1 .. G+C-1: rng_en = 1, block_start = 0,
//     loads 0.  Blocks may follow back to back (next G = G + C).  block_start
//     and slice_start are ignored on edges without rng_en; slice_start is
//     ignored without block_start.  The loads belong on G: the magnitude and
//     length registers feed generation directly, and the PE sign pipes take
//     the new signs one edge later, after the previous block's last MAC.
//   * Stalls.  An edge with rng_en = 0 inside or between blocks holds the
//     generators; its pipeline slot must not be accumulated (next item).
//   * MAC.  The slice generated on edge E is accumulated on edge E+2:
//     mac_en at edge E must be 1 exactly when edge E-2 had rng_en = 1 (and is
//     not a drain edge).  The block's first MAC is G+2, its last G+C+1.
//   * Phase.  phase_q changes only on block_start edges: 0 if the block opens
//     a slice, else phase_q + 1 (mod 8).  A block opens a slice when
//     slice_start = 1 or (DRAIN_PHASE_RESET = 1, the default) when a drain or a
//     reset came since the previous block start: phase_rst_pend_q is set by
//     reset and by the first shift_in edge of a drain (shift_in rising), and
//     cleared by the next block start.  Every slice ends with a drain (next
//     item), so every slice start -- every chunk, every head and every call
//     (calls run back to back with no reset) -- resets the phase even when the
//     sequencer forgets slice_start; a phase carried into the next call would
//     corrupt it whenever the previous call's block count is not a multiple of
//     8 (sweeps/cbsg/README.md, the scrambling-mask fix).  slice_start is
//     still required for a slice that does not follow a drain (e.g. undrained
//     chunks that accumulate together, as in the power bench), and is the only
//     reset when DRAIN_PHASE_RESET = 0.  The drain arm needs the next block's
//     G at or after the drain's first shift edge X+1, which the drain timing
//     below guarantees for N_W >= 2.  No other column information enters the
//     mask.  Consequence: a drain in the middle of a slice (partial-sum
//     readout) restarts the phase; such a sequencer needs DRAIN_PHASE_RESET = 0.
//   * Drain (per slice).  After the slice's last MAC edge X (= G_last + C + 1),
//     drive shift_in = 1, mac_en = 0, acc_in_west = 0 on edges X+1 .. X+N_W.
//     acc_out_east between edge X+s and X+s+1 (s = 0..N_W-1) is tile column
//     N_W-1-s of each row (canonical, any pending carry included).  The N_W
//     shifts leave every accumulator 0, which is the clear.  The next block's
//     first MAC may be edge X+N_W+1, i.e. its G = X + N_W - 1: a drain costs
//     N_W generation slots, and the next block's loads and generation overlap
//     the drain's shifts.
//   * Reset.  Synchronous for the PE and asynchronous for the edge, held for
//     at least one edge; the first block after reset gets phase 0 (it should
//     carry slice_start like any slice start; with DRAIN_PHASE_RESET = 1 the
//     reset arms the phase reset too).  The accumulators reset to 0.
//   * Range.  Tiles are exact mod 2^OWIDTH; |acc| <= 128 * (columns in the
//     slice), so OWIDTH = 24 holds slices up to 65,535 columns (av at D = 2048
//     needs 20 bits).
//
// IDX_W: W index counter width (8 = exact count 0..128; 7 is also exact).
// DRAIN_PHASE_RESET: 1 (default) = a drain or reset arms the phase reset for
// the next block start (above); 0 = slice_start is the only phase reset.
// FAULT: mutation hooks for the bench's negative controls, compiled in only
// with +define+CBSG_RG_FAULT_HOOKS (verification builds).  Without that define
// the hooks do not exist: FAULT is ignored by synthesis and a simulation with
// FAULT != 0 stops at time 0.  1 = lane mask bits k, not bitrev3(k) (edge and
// PE); 2 = W index = t (no gating); 3 = no t < L_row gate; 4 = phase never
// reset after the global reset (ignores slice_start and the drain arm); 5 = W
// index counter not cleared per block; 6 = PE mask phase one cycle early
// (unregistered).

`include "payn/variants/signed_segmented_csa_cbsg_rg/cbsg_rg_edge.sv"
`include "payn/variants/signed_segmented_csa_cbsg_rg/inner_pe_signed_segmented_csa_cbsg_rg.sv"

`ifndef PAYN_K
`define PAYN_K 8
`endif
`ifndef PAYN_M
`define PAYN_M 16
`endif
`ifndef PAYN_NH
`define PAYN_NH 8
`endif
`ifndef PAYN_NW
`define PAYN_NW 8
`endif
`ifndef PAYN_SEG_LOW_W
`define PAYN_SEG_LOW_W 9
`endif

module payn_array_signed_segmented_csa_cbsg_rg #(
    parameter int K = `PAYN_K,
    parameter int M = `PAYN_M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = `PAYN_SEG_LOW_W,
    parameter int LEN_W = 8,
    parameter int IDX_W = 8,
    parameter bit DRAIN_PHASE_RESET = 1'b1,
    parameter int FAULT = 0
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
    // C-BSG control and per-row length
    input logic [N_H*LEN_W-1:0] row_len_in,
    input logic block_start,
    input logic slice_start
);
`ifdef CBSG_RG_FAULT_HOOKS
    localparam int F = FAULT;       // verification build: mutation hooks live
`else
    localparam int F = 0;           // hooks compiled out; FAULT has no effect
`endif

    initial begin
        assert (K == 8 && M == 16 && WIDTH == 8 && LEN_W == 8)
            else $fatal(1, "C-BSG RG needs K=8, M=16, WIDTH=8, LEN_W=8 (got K=%0d M=%0d WIDTH=%0d)",
                        K, M, WIDTH);
        assert (FAULT >= 0 && FAULT <= 6) else $fatal(1, "unknown FAULT %0d", FAULT);
`ifndef SYNTHESIS
`ifdef CBSG_RG_FAULT_HOOKS
        if (FAULT != 0)
            $display("[CBSG-RG] WARNING: fault injection FAULT=%0d is active (verification only)", FAULT);
`else
        if (FAULT != 0)
            $fatal(1, "[CBSG-RG] FAULT=%0d needs +define+CBSG_RG_FAULT_HOOKS (verification builds only)", FAULT);
`endif
`endif
    end

    //------------------------------------------------------ block control --
    // phase_q is the block phase of the cycle now on the edge comparators;
    // first_q / valid_q mark that cycle as a block's cycle 0 / a fresh cycle.
    // phase_rst_pend_q: a reset or a drain came since the last block start, so
    // the next block opens a slice (DRAIN_PHASE_RESET).  shift_q finds the
    // drain's first shift edge; the combinational term covers a block start on
    // that very edge (N_W = 2).
    logic [2:0] phase_q;
    logic first_q, valid_q;
    logic shift_q, phase_rst_pend_q;
    logic drain_rise, slice_open;

    assign drain_rise = shift_in & ~shift_q;
    assign slice_open = (F != 4) &&
        (slice_start || (DRAIN_PHASE_RESET && (phase_rst_pend_q || drain_rise)));

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            phase_q <= '0;
            first_q <= 1'b0;
            valid_q <= 1'b0;
            shift_q <= 1'b0;
            phase_rst_pend_q <= 1'b1;
        end else begin
            valid_q <= rng_en;
            first_q <= rng_en & block_start;
            shift_q <= shift_in;
            if (rng_en && block_start) begin
                phase_q <= slice_open ? 3'd0 : phase_q + 3'd1;
                phase_rst_pend_q <= 1'b0;
            end else if (drain_rise) begin
                phase_rst_pend_q <= 1'b1;
            end
        end
    end

    // The A-edge generation state, one copy per A row (cbsg_rg_edge.sv): each
    // copy is a q bank plus a phase register updated exactly like phase_q, so
    // row h's comparators read x = H ^ {000, bitrev3(p), 00} and c from their
    // own copy.  phase_q above still feeds the PE (mask phase pipe).
    logic [N_H*WIDTH-1:0] a_word_row;
    logic [N_H*4-1:0]     a_cycle_row;

    cbsg_rg_edge_state_rep #(.WIDTH(WIDTH), .N_COPY(N_H)) u_a_rng (
        .clk, .reset, .enable(rng_en), .restart(block_start), .slice_open,
        .word(a_word_row), .cycle(a_cycle_row)
    );

    logic [N_H*K*M-1:0]     a_bits;
    logic [N_H*K-1:0]       a_signs;
    logic [N_W*K*WIDTH-1:0] w_mags;
    logic [N_W*K-1:0]       w_signs;

    cbsg_rg_edge #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .LEN_W(LEN_W), .FAULT(F)
    ) u_peripheral (
        .clk, .reset, .load_a, .load_w,
        .a_binary_in, .a_signs_in, .row_len_in, .w_binary_in, .w_signs_in,
        .a_word_row, .a_cycle_row,
        .a_bits, .a_signs, .w_mags, .w_signs
    );

    InnerPESignedSegmentedCsaCbsgRgFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W), .WIDTH(WIDTH), .IDX_W(IDX_W), .FAULT(F)
    ) u_pe (
        .clk, .reset, .mac_en, .shift_in,
        .a_bits_in(a_bits), .a_signs_in(a_signs),
        .w_mag_in(w_mags), .w_signs_in(w_signs),
        .load_a_sign_in(load_a_sign), .load_w_sign_in(load_w_sign),
        .phase_in(phase_q), .first_in(first_q), .valid_in(valid_q),
        .acc_in_west, .acc_out_east
    );
endmodule

`endif
