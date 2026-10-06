`ifndef PAYN_STREAM_GEN_SV
`define PAYN_STREAM_GEN_SV

`timescale 1ns/1ps

// Block clock of the C-BSG edge, for M = 16 or 8 samples per lane per cycle
// (K = 128/M lanes; a block is 128/M cycles of the 128-sample grid).  It
// holds three things:
//
//   cyc     the block cycle counter: the words presented now are samples
//           t = M*cyc + m.  0..CYCLES-1 inside a block (CYCLES = 128/M);
//           CYCLES is IDLE (past the 128-sample grid), where the A
//           thermometer is 0 because t >= 128 >= kA, so idle edges and
//           over-long blocks add nothing.
//   phase   the PB-bit block-phase register p, PB = 6 - log2(K) (3 at K8,
//           2 at K16): lane k of block p holds column d = K*p + k, so with
//           mask = bitrev8(d mod 64) the phase sits in mask bits
//           [PB+1:2] = bitrev_PB(p).  block_start loads 0 on the first block
//           of a slice (below), else p + 1 (mod 2^PB).
//   w_words the W stream: M registered lane words, one Gray-code Sobol
//           sequence with the scmp_kernels "k" direction numbers
//           [80 40 20 10 48 04 52 ff] in sample order.
//
// W sample order.  With LM = log2(M), the Gray index of t = M*c + m splits,
//     gray(M*c + m) = (gray(c) << LM) ^ ((c & 1) << (LM-1)) ^ gray(m),
// so x(M*c + m) = H(c) ^ LANE(m) with
//     H(c)    = XOR_j gray(c)[j] * dv[LM+j]  ^  (c & 1) * dv[LM-1]
//     LANE(m) = XOR_{j<LM} gray(m)[j] * dv[j]        (a constant per lane)
// (checked against the kernel's rng by designs/payn/model/cbsg.py).
//
// Each lane word holds bits [7:1] of x ^ (bitrev_PB(p) << 2): the 7-bit grid
// drops bit 0, and the block phase is folded in on the block_start edge from
// the phase being loaded, so cycle 0 already carries the new block's mask.
// The lane bits bitrev(k) of the mask are constants, applied at the W
// comparators.  The words stay registered, one per lane, so each word bit
// fans out to N_W*K comparators.
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
// Controls (synchronous to clk; reset is asynchronous):
//   block_start  restart: cyc <= 0 and the cycle-0 words, phase updated.
//                rng_en is a don't-care on this edge.
//   slice_start  with block_start: force phase 0 (optional; see above).
//   shift_in     the drain strobe; arms the slice restart.
//   rng_en       advance one cycle (cyc < CYCLES); held at IDLE once there.
module PaynStreamGen #(
    parameter int M = 8,
    parameter int WIDTH = 8
) (
    input  logic clk,
    input  logic reset,
    input  logic rng_en,
    input  logic block_start,
    input  logic slice_start,
    input  logic shift_in,
    output logic [$clog2(128/M + 1)-1:0] cyc,      // CW bits
    output logic [6 - $clog2(128/M) - 1:0] phase,  // PB bits
    output logic [M*(WIDTH-1)-1:0] w_words
);
    localparam int K = 128 / M;
    localparam int LM = $clog2(M);
    localparam int CYCLES = 128 / M;
    localparam int CW = $clog2(CYCLES + 1);        // cycle counter width
    localparam int PB = 6 - $clog2(K);             // phase bits
    localparam int TW = WIDTH - 1;                 // 7-bit threshold grid
    localparam logic [CW-1:0] CYC_IDLE = CW'(CYCLES);

    initial begin
        assert ((M == 16 || M == 8) && WIDTH == 8)
            else $fatal(1, "PaynStreamGen is the C-BSG stream: M=16 or 8, WIDTH=8 (got M=%0d WIDTH=%0d)",
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
            for (int j = 0; j < LM; j++)
                if ((g >> j) & 1) lane_word ^= dv_k(j);
        end
    endfunction

    // H(c) for c = 0..CYCLES-1.
    function automatic logic [7:0] cycle_word(input logic [CW-2:0] c);
        logic [CW-2:0] g;
        begin
            g = c ^ (c >> 1);
            cycle_word = c[0] ? dv_k(LM - 1) : 8'h00;
            for (int j = 0; j < CW - 1; j++)
                if (g[j]) cycle_word ^= dv_k(LM + j);
        end
    endfunction

    // bitrev_PB(p) << 2: the phase's bits of the mask.
    function automatic logic [7:0] phase_mask(input logic [PB-1:0] p);
        phase_mask = '0;
        for (int i = 0; i < PB; i++)
            phase_mask[2 + PB - 1 - i] = p[i];
    endfunction

    logic [CW-1:0] cyc_q;
    logic [PB-1:0] phase_q;
    logic [TW-1:0] words_q [M];
    logic block_start_q;    // block_start on the previous edge
    logic slice_pending_q;  // reset or a drain since the last block_start

    logic drain_edge;
    logic drain_seen;
    logic slice_reset;
    logic [PB-1:0] start_phase;
    logic [CW-2:0] next_cyc;
    logic [7:0] start_high;
    logic [7:0] next_high;
    logic advance;
    logic advance_words;

    assign drain_edge = shift_in && !block_start_q;
    assign drain_seen = slice_pending_q || drain_edge;
    assign slice_reset = slice_start || drain_seen;
    assign start_phase = slice_reset ? '0 : phase_q + 1'b1;
    assign next_cyc = cyc_q[CW-2:0] + 1'b1;
    assign start_high = cycle_word('0) ^ phase_mask(start_phase);
    assign next_high = cycle_word(next_cyc) ^ phase_mask(phase_q);
    assign advance = rng_en && !cyc_q[CW-1];
    // The step into IDLE leaves the words alone: nothing reads them there.
    assign advance_words = advance && (cyc_q[CW-2:0] != (CW-1)'(CYCLES - 1));

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            cyc_q <= CYC_IDLE;
            phase_q <= '0;
        end else if (block_start) begin
            cyc_q <= '0;
            phase_q <= start_phase;
        end else if (advance) begin
            cyc_q <= cyc_q + 1'b1;
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
