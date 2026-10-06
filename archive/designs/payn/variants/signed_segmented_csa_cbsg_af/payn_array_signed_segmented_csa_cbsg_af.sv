`ifndef PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_ARRAY
`define PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_ARRAY

`timescale 1ns/1ps

// Carry-save single-PE array with the scmp_kernels C-BSG multiplication,
// A-first (AF) form, bit-exact with the kernel's integer accumulator
// (sweeps/cbsg/README.md, model cbsg_ref.hw_af_acc).  The PE core is the
// accepted CSA one, unchanged and included from ../signed_segmented_csa:
// InnerPESignedSegmentedCsaFlat as u_pe/u_array_core, InnerTileSignedSegmentedCsa
// tiles, a_bits_pipe / w_bits_pipe, the drain chain.  Only the edge changes:
//   * u_rng (CbsgAfStreamGen) replaces both Sobol banks: block cycle counter,
//     3-bit block-phase register that restarts after every drain, 16
//     registered W lane words (sample-ordered "k" Sobol, phase folded in);
//   * u_peripheral (CbsgAfPeripheral) replaces sc_pe_peripheral: A magnitude,
//     sign and per-row L registers, one closed-form kA encoder per A element
//     and a thermometer a_bit = (16c + m) < kA (no A Sobol bank, no A
//     comparators); W magnitude and sign registers and the W comparators
//     b_w > ((x_k ^ mask) >> 1).
//
// Mapping.  One PE = N_H A rows x N_W W columns (tile (h, v) is A row h times
// W column v).  A block is 8 consecutive reduction columns of a slice, one per
// lane k; it runs C cycles of 16 positions, sample t = 16c + m, and every
// stream restarts at t = 0 each block.  Column mask = bitrev8(d mod 64) with
// d = 8p + k the column index inside the slice: bits [7:5] = bitrev3(k) are
// wired per lane, bits [4:2] = bitrev3(p) come from the phase register,
// bits [1:0] = 0.  Thresholds use the 7-bit grid, (word ^ mask) >> 1.  The
// tile accumulates sum_k sign * popcount_m(A & W) every MAC edge.
//
// Sequencer contract (all inputs launched half a period before the edge; B is
// a block's block_start edge, C its cycle count):
//   * Operands per element: magnitude b in 0..128 on a_binary_in / w_binary_in
//     (8-bit field; b = round(|q| * 128/127)), sign bit (1 = negative) on
//     a_signs_in / w_signs_in, and per A row h a stream length L_h in 1..128
//     on a_len_in[h*8 +: 8].  Padded lanes of a short last block carry b = 0
//     (either sign).  Lane k of a block holds column 8p + k of the slice.
//   * Block start, edge B: block_start = 1 with load_a, load_w, load_a_sign
//     and load_w_sign all high (the sign pipes in the PE lag the sign
//     registers by one edge, as in the CSA top).  The edge registers capture
//     b, sign and L; the streams restart (cycle 0 is presented right after B);
//     the phase register loads 0 on the first block of a slice (see Slices),
//     else p + 1 (mod 8).  rng_en is a don't-care on edge B.  Loads belong on
//     block_start edges only (a load without a restart changes kA under a
//     running counter), and each magnitude load comes with its sign load
//     (load_a with load_a_sign, load_w with load_w_sign).  An operand that
//     does not change may skip its load pair, e.g. A reused after a drain.
//   * Block length: C >= ceil(max_h L_h / 16) (at most 8 at L <= 128).  Every
//     A one of the block lies in t < kA <= L_h, so cycles past that add zero:
//     C may be longer, and after 8 cycles the counter parks in IDLE (A bits
//     0).  A block cut shorter loses A ones (checked below).
//   * Cycle c of the block is presented after edge B+c, captured by the PE bit
//     pipes at B+c+1 and accumulated at B+c+2.  So the block's MAC edges are
//     B+2 .. B+C+1, and back-to-back blocks put the next block_start at B+C
//     with no bubble.  rng_en advances the counter and must be high on
//     B+1 .. B+C: C-1 edges present cycles 1..C-1 and edge B+C moves off the
//     last cycle (unless the next block_start is on B+C).  rng_en low on an
//     edge E repeats the presented cycle: the pipes capture it at E and E+1,
//     so the MACs at E+1 and E+2 both see it.  A stall is rng_en low at E
//     together with mac_en low at E+2 (the second copy; a shift edge there
//     drops it too).  Outside B+1 .. B+C, rng_en is free.
//   * mac_en must be high on every block's MAC edges, except the second copy
//     of a stalled cycle.  It may be high on any other edge too, including
//     the whole run: the pipes then hold a zero A stream (IDLE, or a cycle
//     past every kA of the last block), so those MACs add exactly 0.
//   * Slices and phase.  A slice is the whole D of a plain call, one chunk
//     (chunk_d) of a chunked call, or one head.  Every call starts a slice;
//     calls run back to back with no reset.  The phase must restart at 0 on
//     the first block of every slice and must not carry over a call boundary
//     (a call whose block count is not a multiple of 8 leaves p != 7; a
//     carried phase corrupts 24 of the 35 deployed chunk_d-128 shapes).
//     Every slice ends with a drain, so the restart is structural: the phase
//     loads 0 on the first block_start after reset and on the first
//     block_start after a drain, i.e. when a shift_in edge lies in Bprev+2 ..
//     B (Bprev the previous block_start; the drain's tail on B+1 is ignored).
//     For N_W >= 2 every legal drain has a shift edge there.  slice_start = 1
//     on a block_start edge also forces phase 0 (sampled only with
//     block_start); it is optional, needed only where the drain is not visible
//     by B (an N_W = 1 drain on the tightest schedule), and is an error on a
//     block that does not follow a drain (two slices would share the
//     accumulators).  Nothing else feeds d: no column base, no channel index
//     (gathered calls use the index inside the gathered call).
//   * Drain (end of every slice): shift_in high for N_W consecutive edges with
//     acc_in_west = 0, the first no earlier than B+C+2 of the slice's last
//     block (one edge after its last MAC edge).  Before the s-th shift edge
//     acc_out_east[h] holds column N_W-1-s of row h; after the N_W-th the
//     accumulators are zero (drain = clear).  shift_in takes priority over
//     mac_en in the tiles.  The next slice's first block_start may come as
//     early as the drain's second-to-last shift edge, so its first MAC edge
//     follows the last shift edge (no other bubble).
//   * Range: |acc| <= 128 * (columns in the slice); exact for OWIDTH = 24 up
//     to 65,535 columns per slice (a 2,048-column attention call is 262,144).
//   * Reset: asynchronous for the edge registers (the counter parks in IDLE,
//     a slice restart is pending, so the first block runs at phase 0),
//     synchronous for the PE.  Hold it for at least one clock edge; the PE bit
//     pipes are not reset but capture the zero streams on that edge.
//
// Checked in simulation below ([CBSG-AF-CONTRACT], non-fatal $error, count in
// contract_errors):
//   - magnitudes > 128 or L outside 1..128 on load edges; a load without
//     block_start; a magnitude load without its sign load or the reverse;
//   - a block_start that cuts the running block short of ceil(max L / 16)
//     cycles;
//   - slices, attributing a drain to the next block when a shift edge falls
//     strictly between the two blocks' first MAC edges (Bprev+3 .. B+1;
//     reset counts as a drain): the first block after a drain not at phase 0
//     (drain not seen by B and no slice_start); slice_start, or a phase
//     restart by a shift on Bprev+2, without such a drain; slice_start without
//     block_start;
//   - MAC accounting: every presented cycle whose pipe sample holds A ones
//     must be accumulated exactly once.  A sample never accumulated (shift_in
//     or mac_en low on its MAC edge: a drain or next slice overlapping live
//     MACs, a missing mac_en) or accumulated twice (an rng_en stall without
//     the mac_en kill) is an error.
//
// Shapes: K = 8 lanes, M = 16 positions and WIDTH = 8 are fixed by the C-BSG
// block; N_H, N_W and LOW_W are free (2**LOW_W >= K*M).

`include "payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_stream_gen.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_peripheral.sv"
`include "payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv"

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

module payn_array_signed_segmented_csa_cbsg_af #(
    parameter int K = `PAYN_K,
    parameter int M = `PAYN_M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = `PAYN_SEG_LOW_W
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
    // C-BSG AF
    input logic [N_H*WIDTH-1:0] a_len_in,
    input logic block_start,
    input logic slice_start
);
    initial begin
        assert (K == 8 && M == 16 && WIDTH == 8)
            else $fatal(1, "payn_array_signed_segmented_csa_cbsg_af needs K=8, M=16, WIDTH=8 (got K=%0d M=%0d WIDTH=%0d)",
                        K, M, WIDTH);
    end

    logic [3:0] cyc;
    logic [2:0] phase;
    logic [M*(WIDTH-1)-1:0] w_words;

    CbsgAfStreamGen #(
        .M(M), .WIDTH(WIDTH)
    ) u_rng (
        .clk, .reset, .rng_en, .block_start, .slice_start, .shift_in,
        .cyc, .phase, .w_words
    );

    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0]   w_signs;

    CbsgAfPeripheral #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH)
    ) u_peripheral (
        .clk, .reset, .load_a, .load_w,
        .a_binary_in, .a_signs_in, .a_len_in, .w_binary_in, .w_signs_in,
        .cyc, .phase, .w_words,
        .a_bits, .a_signs, .w_bits, .w_signs
    );

    // This top is a single PE, so the systolic re-export rails terminate here.
    // Synthesis drops their fanout; they exist for an outer PE grid.
    logic [N_H*K*M-1:0] a_bits_out_nc;
    logic [N_H*K-1:0]   a_signs_out_nc;
    logic [N_W*K*M-1:0] w_bits_out_nc;
    logic [N_W*K-1:0]   w_signs_out_nc;
    logic load_a_sign_out_nc, load_w_sign_out_nc;

    InnerPESignedSegmentedCsaFlat #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) u_pe (
        .clk, .reset, .mac_en, .shift_in,
        .a_bits_in(a_bits), .a_signs_in(a_signs),
        .w_bits_in(w_bits), .w_signs_in(w_signs),
        .load_a_sign_in(load_a_sign), .load_w_sign_in(load_w_sign),
        .a_bits_out(a_bits_out_nc), .a_signs_out(a_signs_out_nc),
        .w_bits_out(w_bits_out_nc), .w_signs_out(w_signs_out_nc),
        .load_a_sign_out(load_a_sign_out_nc),
        .load_w_sign_out(load_w_sign_out_nc),
        .acc_in_west, .acc_out_east
    );

`ifndef SYNTHESIS
    // [CBSG-AF-CONTRACT] sequencer checks (see the header).  Non-fatal so a
    // bench can still compare its drains; benches read contract_errors.
    //
    // Slice attribution: a drain lies between the previous block's MACs and
    // this block's first MAC edge (B+2), and its last two shift edges may
    // overlap B and B+1.  So a block starts a new slice exactly when a shift
    // edge falls strictly between the previous block's first MAC edge and its
    // own; that is evaluated on its own first MAC edge against the phase the
    // block loaded on B.  Reset counts as a drain.
    //
    // MAC accounting: on every edge the PE accumulates the bit-pipe sample
    // (a_bits_out_nc, captured on the previous edge) when mac_en is high and
    // shift_in low.  The sample repeats the previous edge's one when the
    // counter held two edges ago (no block_start, rng_en low, cyc < 8).  A run
    // of identical samples that holds A ones must be accumulated exactly once.
    typedef struct { int unsigned at; bit ss; bit dseen; logic [2:0] ph; int unsigned prev; } slice_ck_t;
    int contract_errors = 0;
    int unsigned ck_edge = 0;         // posedges since reset
    int unsigned last_shift = 1;      // edge of the last shift (reset: 1)
    int unsigned prev_first_mac = 0;  // first MAC edge of the last block
    slice_ck_t slice_q [$];
    bit drained;
    int max_len;
    bit held_d1, held_d2;             // the counter held on the previous edge / two edges ago
    bit run_ones, run_counted, run_shift;
    bit smp_ones, smp_counted;

    always @(posedge clk) begin
        if (reset === 1'b1) begin
            ck_edge = 0;
            last_shift = 1;
            prev_first_mac = 0;
            slice_q.delete();
            held_d1 = 1'b0;
            held_d2 = 1'b0;
            run_ones = 1'b0;
            run_counted = 1'b0;
            run_shift = 1'b0;
        end else begin
            ck_edge++;
            while (slice_q.size() > 0 && slice_q[0].at <= ck_edge) begin
                drained = last_shift > slice_q[0].prev;
                if (drained && slice_q[0].ph !== 3'd0) begin
                    contract_errors++;
                    $error("[CBSG-AF-CONTRACT] first block after a drain or reset loaded phase %0d, not 0 (drain not seen by its block_start edge and no slice_start)",
                           slice_q[0].ph);
                end
                if (!drained && slice_q[0].ss) begin
                    contract_errors++;
                    $error("[CBSG-AF-CONTRACT] slice_start without a drain since the last block (slices mixed in the accumulators)");
                end
                if (!drained && !slice_q[0].ss && slice_q[0].dseen) begin
                    contract_errors++;
                    $error("[CBSG-AF-CONTRACT] phase restarted by a shift edge on the previous block's first MAC edge (no drain between the blocks)");
                end
                void'(slice_q.pop_front());
            end

            smp_ones = ((|a_bits_out_nc) === 1'b1);
            smp_counted = (mac_en === 1'b1) && (shift_in !== 1'b1);
            if (held_d2) begin
                if (smp_ones && smp_counted && run_counted) begin
                    contract_errors++;
                    $error("[CBSG-AF-CONTRACT] stalled cycle accumulated twice: rng_en low two edges ago repeated a sample with A ones and mac_en is high on both of its MAC edges");
                end
                run_counted = run_counted || smp_counted;
                run_shift = run_shift || (shift_in === 1'b1);
            end else begin
                if (run_ones && !run_counted) begin
                    contract_errors++;
                    if (run_shift)
                        $error("[CBSG-AF-CONTRACT] shift_in on the MAC edge of a sample with A ones: that cycle is dropped (drain or next slice overlaps live MACs)");
                    else
                        $error("[CBSG-AF-CONTRACT] mac_en low on the MAC edge of a sample with A ones: that cycle is dropped");
                end
                run_ones = smp_ones;
                run_counted = smp_counted;
                run_shift = (shift_in === 1'b1);
            end
            held_d2 = held_d1;
            held_d1 = (block_start !== 1'b1) && (rng_en !== 1'b1) && (cyc < 4'd8);

            if (shift_in === 1'b1)
                last_shift = ck_edge;
            if (block_start !== 1'b1 && (load_a === 1'b1 || load_w === 1'b1 ||
                                         load_a_sign === 1'b1 || load_w_sign === 1'b1)) begin
                contract_errors++;
                $error("[CBSG-AF-CONTRACT] load without block_start (load_a %b load_w %b load_a_sign %b load_w_sign %b): operands change under a running block",
                       load_a, load_w, load_a_sign, load_w_sign);
            end
            if (load_a !== load_a_sign || load_w !== load_w_sign) begin
                contract_errors++;
                $error("[CBSG-AF-CONTRACT] magnitude and sign loads differ (load_a %b load_a_sign %b load_w %b load_w_sign %b): stale signs",
                       load_a, load_a_sign, load_w, load_w_sign);
            end
            if (load_a === 1'b1)
                for (int i = 0; i < N_H*K; i++)
                    if (a_binary_in[i*WIDTH +: WIDTH] > 8'd128) begin
                        contract_errors++;
                        $error("[CBSG-AF-CONTRACT] A magnitude %0d > 128 (element %0d)",
                               a_binary_in[i*WIDTH +: WIDTH], i);
                    end
            if (load_a === 1'b1)
                for (int h = 0; h < N_H; h++)
                    if (a_len_in[h*WIDTH +: WIDTH] < 8'd1 || a_len_in[h*WIDTH +: WIDTH] > 8'd128) begin
                        contract_errors++;
                        $error("[CBSG-AF-CONTRACT] row %0d stream length %0d outside 1..128",
                               h, a_len_in[h*WIDTH +: WIDTH]);
                    end
            if (load_w === 1'b1)
                for (int i = 0; i < N_W*K; i++)
                    if (w_binary_in[i*WIDTH +: WIDTH] > 8'd128) begin
                        contract_errors++;
                        $error("[CBSG-AF-CONTRACT] W magnitude %0d > 128 (element %0d)",
                               w_binary_in[i*WIDTH +: WIDTH], i);
                    end
            if (slice_start === 1'b1 && block_start !== 1'b1) begin
                contract_errors++;
                $error("[CBSG-AF-CONTRACT] slice_start without block_start has no effect");
            end
            if (block_start === 1'b1) begin
                // cyc is the cycle presented before this edge; it reaches the
                // pipes on this edge, so the running block has had cyc+1.
                max_len = 0;
                for (int h = 0; h < N_H; h++)
                    if (int'(u_peripheral.a_len_q[h*WIDTH +: WIDTH]) > max_len)
                        max_len = int'(u_peripheral.a_len_q[h*WIDTH +: WIDTH]);
                if (cyc < 4'd8 && 16 * (int'(cyc) + 1) < max_len) begin
                    contract_errors++;
                    $error("[CBSG-AF-CONTRACT] block_start after %0d cycles cuts a block of max L %0d (needs %0d)",
                           int'(cyc) + 1, max_len, (max_len + 15) / 16);
                end
                slice_q.push_back('{ck_edge + 2, slice_start === 1'b1, u_rng.drain_seen === 1'b1,
                                    u_rng.start_phase, prev_first_mac});
                prev_first_mac = ck_edge + 2;
            end
        end
    end
`endif
endmodule

`endif
