// [CBSG-AF-IPD COPY] of designs/payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_stream_gen.sv (sha256 in README.md / copied_from.sha256), module names suffixed AfIpd.
// [CBSG-AF-IPD COPY] Rename only: sweeps/cbsg/af_ipd/check_copies.sh shows no other difference.
`ifndef PAYN_CBSG_AF_IPD_STREAM_GEN
`define PAYN_CBSG_AF_IPD_STREAM_GEN

`timescale 1ns/1ps

// Block clock of the A-first (AF) C-BSG edge.  It replaces both Sobol banks of
// the CSA top and holds three things:
//
//   cyc     the block cycle counter: the words presented now are samples
//           t = 16*cyc + m.  0..7 inside a block; 8 is IDLE (past the
//           128-sample grid), where the A thermometer is 0 because
//           t >= 128 >= kA, so idle edges and over-long blocks add nothing.
//   phase   the 3-bit block-phase register p, mask bits [4:2] = bitrev3(p).
//           block_start loads 0 on the first block of a slice (below),
//           else p + 1 (mod 8).
//   w_words the W stream: M registered lane words, one Gray-code Sobol
//           sequence with the scmp_kernels "k" direction numbers
//           [80 40 20 10 48 04 52 ff] in sample order.
//
// W sample order.  For M = 16 the Gray index of t = 16c + m splits,
//     gray(16c + m) = (gray(c) << 4) ^ ((c & 1) << 3) ^ gray(m),
// so x(16c + m) = H(c) ^ LANE(m) with
//     H(c)    = XOR_{j<3} gray(c)[j] * dv[4+j]  ^  (c & 1) * dv[3]
//     LANE(m) = XOR_{j<4} gray(m)[j] * dv[j]          (a constant per lane)
// (the sample-ordered bank of soren_PaYN designs/payn/sobol.sv, re-implemented
// here under a variant-unique name; checked against rng.py by cbsg_ref.py).
//
// Each lane word holds bits [7:1] of x ^ {3'b0, bitrev3(p), 2'b0}: the 7-bit
// grid drops bit 0, and the block phase is folded in on the block_start edge
// from the phase being loaded, so cycle 0 already carries the new block's
// mask.  The lane bits bitrev3(k) of the mask are constants, applied at the
// comparators.  The words stay registered, one per lane, so each word bit
// fans out to N_W*K comparators as the Sobol lane words of the CSA top do.
//
// Slice start.  The phase must restart at 0 on the first block of every slice
// (chunk, head, call).  Every slice ends with a drain, so the drain itself is
// the restart: slice_pending_q is set by reset and by a shift_in edge, and
// cleared by block_start.  A drain may overlap the next slice: its last shift
// edges can fall on that slice's first block_start edge B and on B+1.  A
// shift on B counts for B (drain_seen); a shift on the edge right after a
// block_start (block_start_q) is the tail of the drain that block already
// saw and does not count.  So a block restarts the phase when a shift edge
// lies in Bprev+2 .. B (Bprev the previous block_start).  This needs the
// drain's first shift edge no later than B, true for every N_W >= 2 under the
// tightest legal schedule; slice_start forces the restart where it is not
// (an N_W = 1 drain whose only shift edge is B+1).
//
// Controls (synchronous to clk; reset is asynchronous like the CSA edge):
//   block_start  restart: cyc <= 0 and the cycle-0 words, phase updated.
//                rng_en is a don't-care on this edge.
//   slice_start  with block_start: force phase 0 (optional; see above).
//   shift_in     the drain strobe; arms the slice restart.
//   rng_en       advance one cycle (cyc < 8); held at IDLE once cyc = 8.
module CbsgAfStreamGenAfIpd #(
    parameter int M = 16,
    parameter int WIDTH = 8
) (
    input  logic clk,
    input  logic reset,
    input  logic rng_en,
    input  logic block_start,
    input  logic slice_start,
    input  logic shift_in,
    output logic [3:0] cyc,
    output logic [2:0] phase,
    output logic [M*(WIDTH-1)-1:0] w_words
);
    localparam int TW = WIDTH - 1;                 // 7-bit threshold grid
    localparam logic [3:0] CYC_IDLE = 4'd8;

    initial begin
        assert (M == 16 && WIDTH == 8)
            else $fatal(1, "CbsgAfStreamGenAfIpd is the C-BSG stream: M=16, WIDTH=8 (got M=%0d WIDTH=%0d)",
                        M, WIDTH);
    end

    function automatic logic [7:0] dv_k(input int j);
        case (j)
            0: dv_k = 8'h80;
            1: dv_k = 8'h40;
            2: dv_k = 8'h20;
            3: dv_k = 8'h10;
            4: dv_k = 8'h48;
            5: dv_k = 8'h04;
            6: dv_k = 8'h52;
            7: dv_k = 8'hff;
            default: dv_k = 8'h00;
        endcase
    endfunction

    // LANE(m): constant per lane.
    function automatic logic [7:0] lane_word(input int m);
        int g;
        begin
            g = m ^ (m >> 1);
            lane_word = '0;
            for (int j = 0; j < 4; j++)
                if ((g >> j) & 1) lane_word ^= dv_k(j);
        end
    endfunction

    // H(c) for c = 0..7.
    function automatic logic [7:0] cycle_word(input logic [2:0] c);
        logic [2:0] g;
        begin
            g = c ^ (c >> 1);
            cycle_word = c[0] ? dv_k(3) : 8'h00;
            for (int j = 0; j < 3; j++)
                if (g[j]) cycle_word ^= dv_k(4 + j);
        end
    endfunction

    function automatic logic [2:0] bitrev3(input logic [2:0] x);
        bitrev3 = {x[0], x[1], x[2]};
    endfunction

    logic [3:0] cyc_q;
    logic [2:0] phase_q;
    logic [TW-1:0] words_q [M];
    logic block_start_q;    // block_start on the previous edge
    logic slice_pending_q;  // reset or a drain since the last block_start

    logic drain_edge;
    logic drain_seen;
    logic slice_reset;
    logic [2:0] start_phase;
    logic [2:0] next_cyc;
    logic [7:0] start_high;
    logic [7:0] next_high;
    logic advance;
    logic advance_words;

    assign drain_edge = shift_in && !block_start_q;
    assign drain_seen = slice_pending_q || drain_edge;
    assign slice_reset = slice_start || drain_seen;
    assign start_phase = slice_reset ? 3'd0 : phase_q + 3'd1;
    assign next_cyc = cyc_q[2:0] + 3'd1;
    assign start_high = cycle_word(3'd0) ^ {3'b000, bitrev3(start_phase), 2'b00};
    assign next_high = cycle_word(next_cyc) ^ {3'b000, bitrev3(phase_q), 2'b00};
    assign advance = rng_en && !cyc_q[3];
    // The step into IDLE leaves the words alone: nothing reads them there.
    assign advance_words = advance && (cyc_q[2:0] != 3'd7);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            cyc_q <= CYC_IDLE;
            phase_q <= '0;
        end else if (block_start) begin
            cyc_q <= '0;
            phase_q <= start_phase;
        end else if (advance) begin
            cyc_q <= cyc_q + 4'd1;
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            block_start_q <= 1'b0;
            slice_pending_q <= 1'b1;
        end else begin
            block_start_q <= block_start;
            if (block_start)
                slice_pending_q <= 1'b0;
            else if (drain_edge)
                slice_pending_q <= 1'b1;
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (int m = 0; m < M; m++)
                words_q[m] <= '0;
        end else if (block_start) begin
            for (int m = 0; m < M; m++)
                words_q[m] <= TW'((start_high ^ lane_word(m)) >> 1);
        end else if (advance_words) begin
            for (int m = 0; m < M; m++)
                words_q[m] <= TW'((next_high ^ lane_word(m)) >> 1);
        end
    end

    assign cyc = cyc_q;
    assign phase = phase_q;
    for (genvar m = 0; m < M; m++) begin : g_word
        assign w_words[m*TW +: TW] = words_q[m];
    end
endmodule

`endif
