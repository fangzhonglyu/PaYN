`ifndef PAYN_ARRAY_SV
`define PAYN_ARRAY_SV

`timescale 1ns/1ps

// PaYN single-PE array: one N_H x N_W PE of carry-save tiles with two modes on
// the same datapath.  Shape: K lanes x M positions per tile with K*M = 128,
// K16/M8 (default) or K8/M16 (PAYN_M = 8 or 16).
//
//   SC mode   A-first C-BSG streams, bit-exact with the scmp_kernels C-BSG
//             integer accumulator for any per-row stream length L in 1..128
//             (model: designs/payn/model/cbsg.py).
//   INT mode  raw bit planes on the stream ports and in-place doubling laps
//             (every tile doubles its own value on a lap edge), for INT8,
//             INT6, INT4 and mixed precisions.
//
// Blocks:
//   u_rng         PaynStreamGen: block cycle counter, 3-bit block phase with
//                 the structural slice restart, M W lane words.
//   u_peripheral  PaynEdge: A magnitude / sign / per-row L registers, N_H*K
//                 closed-form kA encoders + thermometers, W magnitude / sign
//                 registers + W comparators, then the INT raw-bit bypass
//                 bits = sc_bits | (raw & int_mode_q).
//   int_mode_q    the mode register (drives the bypass select) and a two-edge
//                 MAC guard around every int_mode change.
//   u_pe          PaynPe: registered lap enable ring_in -> ring_q, tile shift =
//                 shift_in | ring_q, core u_pe/u_array_core.
//   u_combiner    PaynIntCombiner: east-edge plane shift-add for the bit-plane
//                 INT schedule, int_out / int_out_valid (DRAIN = 0 only).
// With int_mode = 0 the INT inputs a_raw_in, w_raw_in, int_prec and ring_in
// are don't-cares.
//
// Drain (DRAIN = `PAYN_DRAIN, a build-time choice):
//   0  in-tile chain (default): shift_in shifts the tile accumulators east,
//      read on acc_out_east; drain_in is ignored, dr_out / dr_out_valid are 0.
//   1  drain register: the PE's 32-value drain register (PaynPe), read on
//      dr_out / dr_out_valid.  drain_in high on edge P makes P+1 the half-0
//      and P+2 the half-1 read edge: the half (tile rows 0-3, then 4-7) is
//      loaded into dr_out on its read edge and its tiles clear; dr_out value
//      n = (h mod 4)*N_W + v.  dr_in_east / dr_in_east_valid are the drain
//      register's east input (an east neighbour's DR in a grid; hold valid low
//      on one PE), ports so that a single-PE route carries the grid PE's whole
//      chain stage, as acc_in_west does for the in-tile chain.  drain_in also
//      arms the slice restart, as a shift_in edge does.  acc_out_east is 0, acc_in_west is ignored,
//      shift_in only clears every tile, and the bit-plane INT schedule (its
//      combiner reads the in-tile chain) is not available: the combiner never
//      captures, int_out and int_out_valid stay 0.  The drain rules of
//      DRAIN = 1 are marked [DR] below.
//
// Lap fold (FOLD = `PAYN_LAP_FOLD, a build-time choice; default 0): with 1 a
// lap edge (ring_q) is a fold edge, a MAC edge that doubles every tile first
// (acc <- 2*acc + this edge's sum; PaynTile), so the all-bits-in-time
// schedule needs no bubble before a lap.  SC mode is unaffected (ring_in is
// gated by int_mode).  The bit-plane schedule is not run on FOLD = 1 builds.
// The FOLD = 1 rules are marked [FOLD] below.
//
// ============================================================== SC mode ==
// int_mode = 0.
//   * Operands per element: magnitude b in 0..128 on a_binary_in /
//     w_binary_in (b = round(|q| * 128/127)), sign bit (1 = negative) on
//     a_signs_in / w_signs_in, per A row h a stream length L_h in 1..128 on
//     a_len_in[h*8 +: 8].  Lane k of block p holds column K*p + k of the
//     slice; the phase p has 6 - log2(K) bits (2 at K16, 3 at K8).
//   * Block start, edge B: block_start with load_a, load_w, load_a_sign and
//     load_w_sign.  Loads go on block_start edges only, each magnitude load
//     with its sign load.  Phase: 0 on the first block of a slice, else p + 1.
//   * Block length C >= ceil(max_h L_h / M), at most 128/M cycles; cycle c
//     is accumulated at
//     B+c+2 (MAC edges B+2 .. B+C+1); back-to-back blocks load at B+C.
//     rng_en high on B+1 .. B+C (a stall is rng_en low at E with mac_en low
//     at E+2); mac_en high on every MAC edge (may stay high: idle edges add 0).
//   * Slices: the phase restarts structurally on the first block_start after
//     reset or after a drain (a shift_in edge in Bprev+2 .. B); slice_start on
//     a block_start edge also forces phase 0 (needed only where the drain is
//     not visible by B, an N_W = 1 drain on the tightest schedule).
//   * Drain: shift_in for N_W edges with acc_in_west = 0, the first no earlier
//     than B+C+2; the next slice may load on the drain's second-to-last shift
//     edge.  Range: exact to 65,535 columns per slice at OWIDTH = 24.
//   * [DR] Drain: drain_in high on one edge no earlier than B+C+1 (the
//     slice's last MAC edge), so half 0 is read on B+C+2 at the earliest and
//     half 1 one edge later; the next slice's first block_start no earlier
//     than the half-0 read edge (its first MAC lands after the half-1 read
//     edge).  Until then the last block's counter has run past its C cycles
//     (or holds there), so the samples consumed on the two read edges are
//     zero.  This needs rng_en high on the slice's last advance edge B+C (the
//     in-tile chain tolerates it low, its drain drops the repeated cycle): a
//     read edge consuming a sample with A ones is an [SC-CONTRACT] error (one
//     half drops it, the other accumulates it).  The read-out arms the slice
//     restart (drain_in on an edge in Bprev+2 .. B).
//
// ============================================================= INT mode ==
// int_mode = 1.  Lane k, position m of data cycle b carries reduction element
// x = 128*b + M*k + m on a_raw_in / w_raw_in (packing of the stream bits).
// Two schedules run on this hardware (block periods on a P_R x P_C grid in
// payn_pe_grid.sv):
//   * Bit-plane (A bits in space): tile row h carries bit h of A[x]; in
//     weight pass q (MSB pass first) tile column v carries bit q of W[x, v].
//     a_signs = (h == top bit), w_signs = all ones in the weight-MSB pass.
//     One lap between weight passes; the combiner forms sum_h 2^h T(h) on the
//     drain.  W4A8: 4 passes.  INT4 (int_prec = 1): rows 0-3 and 4-7 are two
//     activation rows of 4 planes.  Single-PE block: BW*NB + (BW-1) + N_W
//     edges.  Range: INT8 L <= 65,535 per output block.
//   * All bits in time: each tile holds one output (row h = activation row,
//     column v = weight column).  One pass per bit pair (h, q), grouped by
//     level h+q, MSB level first; one lap between levels.  The pass sign
//     (h = BA-1) ^ (q = BW-1) goes on the W side (A signs 0).  Read the raw
//     row values from acc_out_east on the drain; the combiner is unused.
//     Single-PE block: BA*BW*NB + (BA+BW-2) + N_W edges.  Range: INT8
//     L <= 511 worst case, INT6 L <= 8,191, INT4 L <= 131,071.
//     [DR] drain_in on the edge after the last capture (the bubble capture),
//     so half 0 is read on the bubble's MAC edge and half 1 on the next block's
//     first capture edge: single-PE block BA*BW*NB + (BA+BW-2) + 2 edges.
//     [FOLD] no bubble between levels: the next level's first plane is
//     captured on the edge after the previous level's last one, and ring_in
//     goes high on that capture edge, so the lap (fold) edge is that plane's
//     MAC edge.  Single-PE block BA*BW*NB + N_W edges ([DR] + 2).
// Common rules:
//   * int_mode is registered before the 2,048-pin select: a raw plane is
//     captured by the bit pipes at edge P only if int_mode was high at P-1.
//     The MAC guard drops mac_en on the two edges after any int_mode change.
//   * Silent SC streams: every load_a / load_w while int_mode is high carries
//     zero a_binary_in / w_binary_in (those loads carry the plane signs), and
//     after SC -> INT both sides are loaded before the first raw plane a MAC
//     uses is captured (the zero-load on INT entry).  b = 0 gives kA = 0 for
//     every L, lane and phase and silent W comparators (PaynEdge header).
//   * rng_en and a_len_in are don't-cares.  block_start and slice_start must
//     be LOW: a block_start in INT mode clears the slice restart that the INT
//     drains armed, so the first SC block after INT could inherit a phase.
//   * Lap: ring_in high for ONE edge, one edge ahead of the lap edge (ring_q
//     lags it).  On the lap edge every tile loads its own canonical value << 1
//     (pending carry/borrow folded in): exact doubling mod 2^OWIDTH.  The MAC
//     on the lap edge is dropped (shift priority), so the plane captured on
//     the edge before it is a bubble.  k consecutive ring_in edges multiply by
//     2^k; every high ring_in edge makes the next edge a doubling edge.
//     Lower int_mode only after the last ring_in edge.  [FOLD] the lap edge
//     keeps its MAC (2*value + that edge's sum): no bubble; mac_en must be
//     high and shift_in low on it ([FOLD-CONTRACT], PaynPeCore).
//   * Drain: shift_in with ring_q low and acc_in_west = 0.  The combiner
//     captures on exactly those edges (int_mode & shift_in & ~ring_q) and
//     emits int_out / int_out_valid two edges later.  [DR] the read-out above;
//     no combiner, and a read edge must not be a lap edge ([DR-CONTRACT]).
//
// ======================================================== mode switches ==
// Calls of either mode run back to back with no reset:
//   * SC -> INT: drain the SC slice first (it clears the tiles), then raise
//     int_mode no earlier than the edge after the drain's last shift edge
//     (int_mode must be low on every SC drain edge, or the combiner captures
//     SC columns).  The INT block's first raw capture comes at least one edge
//     after int_mode is first high, with the zero-load on or before the edge
//     ahead of it: tightest, int_mode high from D_last+1, zero-load on
//     D_last+1, first raw capture D_last+2.
//   * INT -> SC: keep int_mode high through the last INT drain edge, then
//     lower it.  The first SC block_start may come on the first edge with
//     int_mode low (tightest: D_last+1); it must load both operand sides (A
//     and W, with L), since INT mode left zero magnitudes and plane signs in
//     the edge registers.  The INT drains armed the slice restart, so that
//     block runs at phase 0 without slice_start.
//   * Earlier SC block_starts lose the first cycle's MAC to the guard
//     (checked below as a dropped cycle).
//
// Checked in simulation (not synthesized):
//   [INT-CONTRACT] (fatal): an INT MAC consumes a pipe sample in which an SC
//     stream bit (thermometer or W comparator) fired under the INT select.
//   [SC-CONTRACT] (non-fatal, counted in contract_errors): on SC edges,
//     operand ranges, loads without block_start, magnitude loads without sign
//     loads, blocks cut short (against the per-row L of the last SC-edge A
//     load), slice restarts, and MAC accounting (every SC sample with A ones
//     accumulated exactly once; samples captured under the INT select are
//     skipped, and the MAC guard counts as a dropped MAC); plus, for the
//     modes: block_start or slice_start while int_mode is high, and an SC
//     block_start that does not reload a side loaded in INT mode.
//
// Shapes: (K, M) = (16, 8) or (8, 16) and WIDTH = 8, fixed by the C-BSG block
// (K*M = 128 samples per lane-cycle of a tile); N_H, N_W and LOW_W are free
// for SC (2**LOW_W >= K*M); INT mode is defined for N_H = N_W = 8.

`include "payn/rtl/payn_stream_gen.sv"
`include "payn/rtl/payn_edge.sv"
`include "payn/rtl/payn_pe.sv"
`include "payn/rtl/payn_int_combiner.sv"

`ifndef PAYN_M
`define PAYN_M 8
`endif
`ifndef PAYN_NH
`define PAYN_NH 8
`endif
`ifndef PAYN_NW
`define PAYN_NW 8
`endif
`ifndef PAYN_LOW_W
`define PAYN_LOW_W 9
`endif
`ifndef PAYN_DRAIN
`define PAYN_DRAIN 0
`endif
`ifndef PAYN_LAP_FOLD
`define PAYN_LAP_FOLD 0
`endif

module payn_array #(
    parameter int M = `PAYN_M,
    parameter int K = 128 / M,
    parameter int N_H = `PAYN_NH,
    parameter int N_W = `PAYN_NW,
    parameter int WIDTH = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = `PAYN_LOW_W,
    parameter int DRAIN = `PAYN_DRAIN,
    parameter int FOLD = `PAYN_LAP_FOLD,
    parameter int DRW = (N_H / 2) * N_W * OWIDTH  // drain register bits (derived)
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
    // drain register (DRAIN = 1)
    input  logic drain_in,
    output logic [DRW-1:0] dr_out,
    output logic dr_out_valid,
    input  logic [DRW-1:0] dr_in_east,
    input  logic dr_in_east_valid,
    // SC mode
    input logic [N_H*WIDTH-1:0] a_len_in,
    input logic block_start,
    input logic slice_start,
    // INT mode
    input  logic int_mode,
    input  logic int_prec,
    input  logic ring_in,
    input  logic [N_H*K*M-1:0] a_raw_in,
    input  logic [N_W*K*M-1:0] w_raw_in,
    output logic [63:0] int_out,
    output logic int_out_valid
);
    initial begin
        assert (((K == 16 && M == 8) || (K == 8 && M == 16)) && WIDTH == 8)
            else $fatal(1, "payn_array needs K16/M8 or K8/M16, WIDTH=8 (got K=%0d M=%0d WIDTH=%0d)",
                        K, M, WIDTH);
    end

    localparam int CYCLES = 128 / M;               // cycles per 128-sample block
    localparam int CW = $clog2(CYCLES + 1);
    localparam int PB = 6 - $clog2(K);

    //------------------------------------------------------- block clock --
    logic [CW-1:0] cyc;
    logic [PB-1:0] phase;
    logic [M*(WIDTH-1)-1:0] w_words;

    // The read-out ends a slice like a drain does: it arms the slice restart.
    logic rng_drain;
    assign rng_drain = shift_in | ((DRAIN == 1) & drain_in);

    PaynStreamGen #(
        .M(M), .WIDTH(WIDTH)
    ) u_rng (
        .clk, .reset, .rng_en, .block_start, .slice_start, .shift_in(rng_drain),
        .cyc, .phase, .w_words
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

    //------------------------------------------------- edge + INT bypass --
    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0]   w_signs;

    PaynEdge #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH)
    ) u_peripheral (
        .clk, .reset, .load_a, .load_w,
        .a_binary_in, .a_signs_in, .a_len_in, .w_binary_in, .w_signs_in,
        .cyc, .phase, .w_words,
        .int_mode(int_mode_q), .a_raw_in, .w_raw_in,
        .a_bits, .a_signs, .w_bits, .w_signs
    );

    //--------------------------------------------------------------- PE --
    // A single PE, so the systolic re-export rails terminate here; synthesis
    // drops their fanout.  They exist for PaynPeGrid.
    logic [N_H*K*M-1:0] a_bits_out_nc;
    logic [N_H*K-1:0]   a_signs_out_nc;
    logic [N_W*K*M-1:0] w_bits_out_nc;
    logic [N_W*K-1:0]   w_signs_out_nc;
    logic load_a_sign_out_nc, load_w_sign_out_nc;
    logic ring_q;
    logic drain_out_nc;

    PaynPe #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W), .DRAIN(DRAIN), .FOLD(FOLD)
    ) u_pe (
        .clk, .reset, .mac_en(mac_core), .shift_in,
        .ring_in(ring_in & int_mode),
        .drain_in, .drain_out(drain_out_nc),
        .dr_east_in(dr_in_east), .dr_east_valid_in(dr_in_east_valid),
        .dr_west_out(dr_out), .dr_west_valid_out(dr_out_valid),
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

    //--------------------------------------------------------- combiner --
    // Drain edges (shift_in with ring_q low in INT mode) sample the east
    // column before it shifts; lap edges (ring_q high) do not.
    // DRAIN = 1: never captures (acc_out_east is 0 there), so synthesis keeps
    // nothing of it; the instance stays for the power-class hierarchy.
    PaynIntCombiner #(
        .N_H(N_H), .OWIDTH(OWIDTH), .OUT_W(32)
    ) u_combiner (
        .clk, .reset,
        .capture((DRAIN == 0) & int_mode & shift_in & ~ring_q),
        .int_prec,
        .acc_east(acc_out_east),
        .out(int_out),
        .out_valid(int_out_valid)
    );

`ifndef SYNTHESIS
    //---------------------------------------------------- [INT-CONTRACT] --
    // A MAC must not consume a pipe sample in which an SC stream bit fired
    // under the INT select (magnitude registers not held at zero).
    // int_sample_dirty describes the sample captured on the previous edge,
    // which is the one the MAC on this edge consumes.
    logic int_sample_dirty = 1'b0;
    always @(posedge clk) begin
        if (!reset && mac_core === 1'b1 && int_sample_dirty === 1'b1)
            $fatal(1, "[INT-CONTRACT] INT MAC consumed live SC stream bits (thermometer / W comparators): load zero magnitudes in INT mode");
        int_sample_dirty <= int_mode_q &&
            (|u_peripheral.sc_a_bits || |u_peripheral.sc_w_bits);
    end

    //----------------------------------------------------- [SC-CONTRACT] --
    // Sequencer checks on SC edges (int_mode low), with the MAC accounting on
    // the samples captured under the SC select (int_mode_q2 low at the MAC
    // edge) and the real core MAC (mac_core, the guard included; tile shift =
    // shift_in | ring_q, or shift_in with FOLD = 1, where a lap edge keeps the
    // MAC).  Non-fatal, so a bench can still compare its drains;
    // benches read contract_errors.
    //
    // Slice attribution: a block starts a new slice exactly when a shift edge
    // falls strictly between the previous block's first MAC edge and its own;
    // evaluated on its own first MAC edge against the phase the block loaded
    // on B.  Reset counts as a drain; so do INT drains (their shift_in edges
    // arm the hardware restart as SC drains do).  [DR] drain_in edges and the
    // two read edges count as drain edges; a read edge drops the MAC of the
    // half it reads, so the accounting treats it like a shift edge (the
    // sample it consumes must have no A ones).
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
    bit drain_d1, drain_d2;           // [DR] drain_in one / two edges ago
    bit rd_edge, mac_drop;            // [DR] a read edge; any edge that drops the MAC
    bit sc_edge;                      // int_mode low on this edge
    bit smp_int, prev_smp_int;        // sample captured under the INT select
    bit a_stale, w_stale;             // edge registers loaded in INT mode since the last SC load
    // Per-row L of the last SC block, loaded only by SC-edge load_a.  INT-mode
    // A loads also load a_len_q (a_len_in is a don't-care there), so the
    // cut-block check reads this shadow: a legal SC -> INT -> SC sequence with
    // a short last SC block and a nonzero INT a_len_in is not flagged, and a
    // really cut last SC block before an INT segment is still flagged at the
    // first SC block_start after it.
    logic [N_H*WIDTH-1:0] sc_a_len;

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
            drain_d1 = 1'b0;
            drain_d2 = 1'b0;
            prev_smp_int = 1'b0;
            a_stale = 1'b0;
            w_stale = 1'b0;
            sc_a_len = '0;                // a_len_q's reset value
        end else begin
            ck_edge++;
            sc_edge = (int_mode !== 1'b1);
            while (slice_q.size() > 0 && slice_q[0].at <= ck_edge) begin
                drained = last_shift > slice_q[0].prev;
                if (drained && slice_q[0].ph !== 3'd0) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] first block after a drain or reset loaded phase %0d, not 0 (drain not seen by its block_start edge and no slice_start)",
                           slice_q[0].ph);
                end
                if (!drained && slice_q[0].ss) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] slice_start without a drain since the last block (slices mixed in the accumulators)");
                end
                if (!drained && !slice_q[0].ss && slice_q[0].dseen) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] phase restarted by a shift edge on the previous block's first MAC edge (no drain between the blocks)");
                end
                void'(slice_q.pop_front());
            end

            // MAC accounting.  A sample captured under the INT select ends the
            // SC run before it and is not accounted.
            smp_int = (int_mode_q2 === 1'b1);
            smp_ones = !smp_int && ((|a_bits_out_nc) === 1'b1);
            rd_edge = (DRAIN == 1) && (drain_d1 || drain_d2);
            mac_drop = (shift_in === 1'b1) || rd_edge;
            smp_counted = (mac_core === 1'b1) && !mac_drop && (FOLD == 1 || ring_q !== 1'b1);
            // [DR] one half drops the MAC of a read edge and the other half
            // takes it, so a live sample there is always wrong (a repeated
            // last cycle double-counts in the other half).
            if (rd_edge && smp_ones && mac_core === 1'b1) begin
                contract_errors++;
                $error("[SC-CONTRACT] read-out edge consumed a sample with A ones (one half drops it, the other accumulates it): the counter had not run past the slice's last block");
            end
            if (!smp_int && held_d2 && !prev_smp_int) begin
                if (smp_ones && smp_counted && run_counted) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] stalled cycle accumulated twice: rng_en low two edges ago repeated a sample with A ones and mac_en is high on both of its MAC edges");
                end
                run_counted = run_counted || smp_counted;
                run_shift = run_shift || mac_drop;
            end else begin
                if (run_ones && !run_counted) begin
                    contract_errors++;
                    if (run_shift)
                        $error("[SC-CONTRACT] drain edge (shift_in or a read-out edge) on the MAC edge of a sample with A ones: that cycle is dropped (drain or next slice overlaps live MACs)");
                    else
                        $error("[SC-CONTRACT] mac_en low (or the int_mode MAC guard) on the MAC edge of a sample with A ones: that cycle is dropped");
                end
                run_ones = smp_ones;
                run_counted = smp_counted;
                run_shift = mac_drop;
            end
            prev_smp_int = smp_int;
            held_d2 = held_d1;
            held_d1 = (block_start !== 1'b1) && (rng_en !== 1'b1) && (cyc < CYCLES);

            if (mac_drop || (DRAIN == 1 && drain_in === 1'b1))
                last_shift = ck_edge;
            drain_d2 = drain_d1;
            drain_d1 = (DRAIN == 1) && (drain_in === 1'b1);
            if (!sc_edge) begin
                // INT mode: the loads carry plane signs (zero magnitudes,
                // [INT-CONTRACT]); the SC block strobes must stay low.
                if (block_start === 1'b1 || slice_start === 1'b1) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] block_start %b / slice_start %b while int_mode is high: SC strobes in INT mode (a block_start clears the slice restart the INT drains armed)",
                           block_start, slice_start);
                end
                if (load_a === 1'b1) a_stale = 1'b1;
                if (load_w === 1'b1) w_stale = 1'b1;
            end else begin
                if (block_start !== 1'b1 && (load_a === 1'b1 || load_w === 1'b1 ||
                                             load_a_sign === 1'b1 || load_w_sign === 1'b1)) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] load without block_start (load_a %b load_w %b load_a_sign %b load_w_sign %b): operands change under a running block",
                           load_a, load_w, load_a_sign, load_w_sign);
                end
                if (load_a !== load_a_sign || load_w !== load_w_sign) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] magnitude and sign loads differ (load_a %b load_a_sign %b load_w %b load_w_sign %b): stale signs",
                           load_a, load_a_sign, load_w, load_w_sign);
                end
                if (load_a === 1'b1)
                    for (int i = 0; i < N_H*K; i++)
                        if (a_binary_in[i*WIDTH +: WIDTH] > 8'd128) begin
                            contract_errors++;
                            $error("[SC-CONTRACT] A magnitude %0d > 128 (element %0d)",
                                   a_binary_in[i*WIDTH +: WIDTH], i);
                        end
                if (load_a === 1'b1)
                    for (int h = 0; h < N_H; h++)
                        if (a_len_in[h*WIDTH +: WIDTH] < 8'd1 || a_len_in[h*WIDTH +: WIDTH] > 8'd128) begin
                            contract_errors++;
                            $error("[SC-CONTRACT] row %0d stream length %0d outside 1..128",
                                   h, a_len_in[h*WIDTH +: WIDTH]);
                        end
                if (load_w === 1'b1)
                    for (int i = 0; i < N_W*K; i++)
                        if (w_binary_in[i*WIDTH +: WIDTH] > 8'd128) begin
                            contract_errors++;
                            $error("[SC-CONTRACT] W magnitude %0d > 128 (element %0d)",
                                   w_binary_in[i*WIDTH +: WIDTH], i);
                        end
                if (slice_start === 1'b1 && block_start !== 1'b1) begin
                    contract_errors++;
                    $error("[SC-CONTRACT] slice_start without block_start has no effect");
                end
                if (block_start === 1'b1) begin
                    if ((a_stale && load_a !== 1'b1) || (w_stale && load_w !== 1'b1)) begin
                        contract_errors++;
                        $error("[SC-CONTRACT] first SC block after INT mode does not reload %s: the edge registers hold INT-mode zero magnitudes and plane signs",
                               (a_stale && load_a !== 1'b1) ? ((w_stale && load_w !== 1'b1) ? "A and W" : "A") : "W");
                    end
                    // cyc is the cycle presented before this edge; it reaches
                    // the pipes on this edge, so the running block has had
                    // cyc+1 cycles.  In INT mode the counter can only hold or
                    // step towards IDLE (block_start is low there).
                    max_len = 0;
                    for (int h = 0; h < N_H; h++)
                        if (int'(sc_a_len[h*WIDTH +: WIDTH]) > max_len)
                            max_len = int'(sc_a_len[h*WIDTH +: WIDTH]);
                    if (cyc < CYCLES && M * (int'(cyc) + 1) < max_len) begin
                        contract_errors++;
                        $error("[SC-CONTRACT] block_start after %0d cycles cuts a block of max L %0d (needs %0d)",
                               int'(cyc) + 1, max_len, (max_len + M - 1) / M);
                    end
                    slice_q.push_back('{ck_edge + 2, slice_start === 1'b1, u_rng.drain_seen === 1'b1,
                                        u_rng.start_phase, prev_first_mac});
                    prev_first_mac = ck_edge + 2;
                end
                if (load_a === 1'b1) begin
                    a_stale = 1'b0;
                    sc_a_len = a_len_in;
                end
                if (load_w === 1'b1) w_stale = 1'b0;
            end
        end
    end
`endif
endmodule

`endif
