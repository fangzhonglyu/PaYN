`ifndef PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_IPD_ARRAY
`define PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_IPD_ARRAY

`timescale 1ns/1ps

// Carry-save single-PE array with BOTH
//   * SC mode = the C-BSG A-first (AF) edge, bit-exact with the scmp_kernels
//     C-BSG integer accumulator: exactly
//     ../signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv
//     (model cbsg_ref.hw_af_acc, sweeps/cbsg/README.md), and
//   * INT mode = the bit-plane (BP) INT contract with 1-edge IN-PLACE laps
//     (IPD): exactly ../signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv
//     (schedule T3 of doc/INT_mode_on_PaYN.md).
// Every block is a renamed copy (module suffix AfIpd, see README.md for the
// sources and their sha256); the CSA tile (InnerTileSignedSegmentedCsa) is
// included unchanged from ../signed_segmented_csa:
//   * u_rng (CbsgAfStreamGenAfIpd): the AF block clock (cycle counter, 3-bit
//     block phase with the structural slice restart, 16 W lane words);
//   * u_peripheral (CbsgAfPeripheralAfIpd): the AF edge (A magnitude, sign and
//     per-row L registers, 64 closed-form kA encoders + thermometers, W
//     magnitude/sign registers + W comparators) followed by the BP raw-bit
//     bypass bits = sc_bits | (raw & int_mode_q), after the AF stream logic and
//     before the PE bit pipes;
//   * mode register int_mode_q (drives the bypass select) and a two-edge MAC
//     guard around every int_mode change (BP top);
//   * u_pe (InnerPESignedSegmentedCsaBpIpdFlatAfIpd): the IPD PE, registered
//     per-PE lap enable ring_in -> ring_q (tile shift = shift_in | ring_q, every
//     tile reloads its own value << 1 on a ring_q edge), core u_pe/u_array_core
//     with the CSA instance names (g_row/g_col/u_inner, a_bits_pipe);
//   * u_combiner (PaynBpCombinerAfIpd): the BP east-edge plane shift-add,
//     int_out / int_out_valid.
// With int_mode = 0 this top is the AF top edge for edge, whatever a_raw_in,
// w_raw_in, int_prec and ring_in do.
//
// ============================================================== SC mode ==
// int_mode = 0.  The AF contract, unchanged (summary; the AF top header has
// the full text):
//   * Operands per element: magnitude b in 0..128 on a_binary_in /
//     w_binary_in (b = round(|q| * 128/127)), sign bit (1 = negative) on
//     a_signs_in / w_signs_in, per A row h a stream length L_h in 1..128 on
//     a_len_in[h*8 +: 8].  Lane k of a block holds column 8p + k of the slice.
//   * Block start, edge B: block_start with load_a, load_w, load_a_sign and
//     load_w_sign.  Loads go on block_start edges only, each magnitude load
//     with its sign load.  Phase: 0 on the first block of a slice, else p + 1.
//   * Block length C >= ceil(max_h L_h / 16); cycle c is accumulated at
//     B+c+2 (MAC edges B+2 .. B+C+1); back-to-back blocks load at B+C.
//     rng_en high on B+1 .. B+C (a stall is rng_en low at E with mac_en low
//     at E+2); mac_en high on every MAC edge (may stay high: idle edges add 0).
//   * Slices: the phase restarts structurally on the first block_start after
//     reset or after a drain (a shift_in edge in Bprev+2 .. B); slice_start on a
//     block_start edge also forces phase 0 (optional, only where the drain is
//     not visible by B, an N_W = 1 drain on the tightest schedule).
//   * Drain: shift_in for N_W edges with acc_in_west = 0, the first no earlier
//     than B+C+2; the next slice may load on the drain's second-to-last shift
//     edge.  Range: exact to 65,535 columns per slice at OWIDTH = 24.
//   * The INT inputs a_raw_in, w_raw_in, int_prec and ring_in are don't-cares.
//
// ============================================================= INT mode ==
// int_mode = 1.  The BP INT contract with IPD laps (the IPD top header has the
// full text; identical here):
//   * BP INT8 mapping (one PE = 1 activation row x 8 output columns): lane k,
//     position m of a data cycle carries reduction element x = 128*b + 16*k +
//     m on a_raw_in / w_raw_in (packing of the stream bits); tile row h carries
//     bit h of A[x]; in weight pass q (MSB pass first) tile column v carries
//     bit q of W[x, v].  a_signs = (h == top bit), w_signs = all ones in the
//     weight-MSB pass.  W4A8: 4 passes.  INT4 (int_prec = 1): rows 0-3 and 4-7
//     are two activation rows of 4 planes.  Defined for N_H = N_W = 8.
//   * int_mode is registered before the 2,048-pin select: a raw plane is
//     captured by the bit pipes at edge P only if int_mode was high at P-1.
//     The MAC guard drops mac_en on the two edges after any int_mode change.
//   * Silent AF streams: every load_a / load_w while int_mode is high carries
//     zero a_binary_in / w_binary_in (those loads carry the plane signs), and
//     after SC -> INT both sides are loaded before the first raw plane a MAC
//     uses is captured (the zero-load on INT entry).  b = 0 gives kA = 0 for
//     every L, lane and phase, so the thermometer is 0 for every cycle, and the
//     W comparators are 0: no gate on int_mode (see the peripheral header).
//     Checked below ([BP-CONTRACT], fatal, as in the BP top).
//   * AF-only inputs in INT mode: rng_en and a_len_in are don't-cares (b = 0
//     makes kA = 0 whatever L and the counter do).  block_start and
//     slice_start must be LOW: they are SC block strobes, and a block_start in
//     INT mode clears the slice restart that the INT drains armed, so the
//     first SC block after INT could inherit a phase (the INT datapath itself
//     does not see them).
//   * Lap (in-place doubling): ring_in high for ONE edge, one edge ahead of the
//     lap edge (ring_q lags it).  On the lap edge every tile loads its own
//     canonical value << 1 (pending carry/borrow folded in): exact doubling mod
//     2^OWIDTH.  shift_in is not needed on the lap edge (harmless if high on a
//     single PE).  The MAC on the lap edge is dropped (shift priority), so the
//     plane captured on the edge before it is a bubble: a non-final weight pass
//     of NB data edges takes NB + 1 edges, and a block takes
//         BW*NB + (BW-1) + N_W   edges   (single PE).
//     k consecutive ring_in edges multiply by 2^k: 8-edge BP-ring schedules are
//     NOT compatible.  ring_in is strict in INT mode (every high edge makes the
//     next edge a doubling edge); lower int_mode only after the last ring_in
//     edge.
//   * Drain: shift_in with ring_q low and acc_in_west = 0.  The combiner
//     captures on exactly those edges (int_mode & shift_in & ~ring_q) and
//     emits int_out / int_out_valid two edges later.
//   * Range: tiles exact mod 2^OWIDTH; INT8 L <= 65,535 per output block, W4A8
//     and INT4 L <= 1,048,575.
//   * PE grid: inner_pe_grid_signed_segmented_csa_cbsg_af_ipd.sv (ring wave,
//     PE (r,c) laps at offset r+c, block period BW*NB + (BW-1) + (P_R+P_C-2) +
//     8*P_C, global shift_in for drains only).  The AF edge there is per PE
//     row / column and not part of that wrapper.
//
// ======================================================== mode switches ==
// Calls of either mode run back to back with no reset:
//   * SC -> INT: drain the SC slice first (it clears the tiles), then raise
//     int_mode no earlier than the edge after the drain's last shift edge
//     (int_mode must be low on every SC drain edge, or the combiner captures SC
//     columns and int_out_valid fires).  The INT block's first raw capture
//     comes at least one edge after int_mode is first high, with the zero-load
//     (the pass-0 sign loads, zero magnitudes) on or before the edge ahead of
//     it: tightest, int_mode high from D_last+1, zero-load on D_last+1, first
//     raw capture D_last+2.
//   * INT -> SC: keep int_mode high through the last INT drain edge (the
//     combiner captures on it), then lower it.  The first SC block_start may
//     come on the first edge with int_mode low (tightest: D_last+1); it must
//     load both operand sides (A and W pairs, with L), since INT mode left zero
//     magnitudes and plane signs in the edge registers.  The INT drains armed
//     the slice restart, so that block runs at phase 0 without slice_start.
//   * Earlier SC block_starts lose the first cycle's MAC to the guard (checked
//     below as a dropped cycle).
//
// Checked in simulation below:
//   [BP-CONTRACT] (fatal): an INT MAC consumes a pipe sample in which an AF
//     stream bit (thermometer or W comparator) fired under the INT select.
//   [CBSG-AF-CONTRACT] (non-fatal, counted in contract_errors): every AF check
//     of the AF top on SC edges (int_mode low): operand ranges, loads without
//     block_start, magnitude loads without sign loads, blocks cut short
//     (against the per-row L of the last SC-edge A load, since INT-mode A
//     loads also load a_len_q with the don't-care a_len_in), slice
//     restarts, and MAC accounting (every SC sample with A ones accumulated
//     exactly once; samples captured under the INT select are skipped, and the
//     MAC guard counts as a dropped MAC); plus, for the modes: block_start or
//     slice_start while int_mode is high, and an SC block_start that does not
//     reload a side whose edge registers were loaded in INT mode.
//
// Shapes: K = 8 lanes, M = 16 positions and WIDTH = 8 are fixed by the C-BSG
// block; N_H, N_W and LOW_W are free for SC (2**LOW_W >= K*M); INT mode is
// defined for N_H = N_W = 8.

`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/cbsg_af_ipd_stream_gen.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/cbsg_af_ipd_peripheral.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/inner_pe_signed_segmented_csa_cbsg_af_ipd.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/bp_combiner_cbsg_af_ipd.sv"

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

module payn_array_signed_segmented_csa_cbsg_af_ipd #(
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
    // C-BSG AF (SC mode)
    input logic [N_H*WIDTH-1:0] a_len_in,
    input logic block_start,
    input logic slice_start,
    // BP INT mode (IPD laps)
    input  logic int_mode,
    input  logic int_prec,
    input  logic ring_in,
    input  logic [N_H*K*M-1:0] a_raw_in,
    input  logic [N_W*K*M-1:0] w_raw_in,
    output logic [63:0] int_out,
    output logic int_out_valid
);
    initial begin
        assert (K == 8 && M == 16 && WIDTH == 8)
            else $fatal(1, "payn_array_signed_segmented_csa_cbsg_af_ipd needs K=8, M=16, WIDTH=8 (got K=%0d M=%0d WIDTH=%0d)",
                        K, M, WIDTH);
    end

    //---------------------------------------------------- AF block clock --
    logic [3:0] cyc;
    logic [2:0] phase;
    logic [M*(WIDTH-1)-1:0] w_words;

    CbsgAfStreamGenAfIpd #(
        .M(M), .WIDTH(WIDTH)
    ) u_rng (
        .clk, .reset, .rng_en, .block_start, .slice_start, .shift_in,
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

    //------------------------------------------------ AF edge + bypass --
    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0]   w_signs;

    CbsgAfPeripheralAfIpd #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH)
    ) u_peripheral (
        .clk, .reset, .load_a, .load_w,
        .a_binary_in, .a_signs_in, .a_len_in, .w_binary_in, .w_signs_in,
        .cyc, .phase, .w_words,
        .int_mode(int_mode_q), .a_raw_in, .w_raw_in,
        .a_bits, .a_signs, .w_bits, .w_signs
    );

    //--------------------------------------------------------- IPD PE --
    // This top is a single PE, so the systolic re-export rails terminate here.
    // Synthesis drops their fanout; they exist for an outer PE grid.
    logic [N_H*K*M-1:0] a_bits_out_nc;
    logic [N_H*K-1:0]   a_signs_out_nc;
    logic [N_W*K*M-1:0] w_bits_out_nc;
    logic [N_W*K-1:0]   w_signs_out_nc;
    logic load_a_sign_out_nc, load_w_sign_out_nc;
    logic ring_q;

    InnerPESignedSegmentedCsaBpIpdFlatAfIpd #(
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

    //------------------------------------------------------- combiner --
    // Drain edges (shift_in with ring_q low in INT mode) sample the east
    // column before it shifts; lap edges (ring_q high) do not.
    PaynBpCombinerAfIpd #(
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
    //----------------------------------------------------- [BP-CONTRACT] --
    // INT magnitudes (BP top check, AF stream bits in place of the Sobol
    // comparators): a MAC must not consume a pipe sample in which an AF stream
    // bit fired under the INT select (magnitude registers not held at zero).
    // int_sample_dirty describes the sample captured on the previous edge,
    // which is the one the MAC on this edge consumes.
    logic int_sample_dirty = 1'b0;
    always @(posedge clk) begin
        if (!reset && mac_core === 1'b1 && int_sample_dirty === 1'b1)
            $fatal(1, "[BP-CONTRACT] INT MAC consumed live AF stream bits (thermometer / W comparators): load zero magnitudes in INT mode");
        int_sample_dirty <= int_mode_q &&
            (|u_peripheral.sc_a_bits || |u_peripheral.sc_w_bits);
    end

    //----------------------------------------------- [CBSG-AF-CONTRACT] --
    // The AF top's sequencer checks, applied on SC edges (int_mode low), with
    // the MAC accounting on the samples captured under the SC select
    // (int_mode_q2 low at the MAC edge) and the real core MAC (mac_core, the
    // guard included; tile shift = shift_in | ring_q).  Non-fatal, so a bench
    // can still compare its drains; benches read contract_errors.
    //
    // Slice attribution (AF top): a block starts a new slice exactly when a
    // shift edge falls strictly between the previous block's first MAC edge
    // and its own; evaluated on its own first MAC edge against the phase the
    // block loaded on B.  Reset counts as a drain; so do INT drains (their
    // shift_in edges arm the hardware restart as SC drains do).
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
    bit sc_edge;                      // [AF-IPD] int_mode low on this edge
    bit smp_int, prev_smp_int;        // [AF-IPD] sample captured under the INT select
    bit a_stale, w_stale;             // [AF-IPD] edge registers loaded in INT mode since the last SC load
    // [AF-IPD] The per-row L of the last SC block: a_len_q as the AF top would
    // hold it, i.e. loaded only by SC-edge load_a.  INT-mode A loads also load
    // a_len_q (a_len_in is a don't-care there), so the cut-block check reads
    // this shadow, not u_peripheral.a_len_q: a legal SC -> INT -> SC sequence
    // with a short last SC block, rng_en low in INT mode and a nonzero INT
    // a_len_in is not flagged, and a really cut last SC block before an INT
    // segment is still flagged at the first SC block_start after it.
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

            // MAC accounting.  A sample captured under the INT select ends the
            // SC run before it and is not accounted.
            smp_int = (int_mode_q2 === 1'b1);
            smp_ones = !smp_int && ((|a_bits_out_nc) === 1'b1);
            smp_counted = (mac_core === 1'b1) && (shift_in !== 1'b1) && (ring_q !== 1'b1);
            if (!smp_int && held_d2 && !prev_smp_int) begin
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
                        $error("[CBSG-AF-CONTRACT] mac_en low (or the int_mode MAC guard) on the MAC edge of a sample with A ones: that cycle is dropped");
                end
                run_ones = smp_ones;
                run_counted = smp_counted;
                run_shift = (shift_in === 1'b1);
            end
            prev_smp_int = smp_int;
            held_d2 = held_d1;
            held_d1 = (block_start !== 1'b1) && (rng_en !== 1'b1) && (cyc < 4'd8);

            if (shift_in === 1'b1)
                last_shift = ck_edge;
            if (!sc_edge) begin
                // INT mode: the loads carry plane signs (zero magnitudes,
                // [BP-CONTRACT]); the SC block strobes must stay low.
                if (block_start === 1'b1 || slice_start === 1'b1) begin
                    contract_errors++;
                    $error("[CBSG-AF-CONTRACT] block_start %b / slice_start %b while int_mode is high: SC strobes in INT mode (a block_start clears the slice restart the INT drains armed)",
                           block_start, slice_start);
                end
                if (load_a === 1'b1) a_stale = 1'b1;
                if (load_w === 1'b1) w_stale = 1'b1;
            end else begin
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
                    if ((a_stale && load_a !== 1'b1) || (w_stale && load_w !== 1'b1)) begin
                        contract_errors++;
                        $error("[CBSG-AF-CONTRACT] first SC block after INT mode does not reload %s: the edge registers hold INT-mode zero magnitudes and plane signs",
                               (a_stale && load_a !== 1'b1) ? ((w_stale && load_w !== 1'b1) ? "A and W" : "A") : "W");
                    end
                    // cyc is the cycle presented before this edge; it reaches the
                    // pipes on this edge, so the running block has had cyc+1.
                    // [AF-IPD] L of the last SC block (sc_a_len, see above).  In
                    // INT mode the counter can only hold or step towards IDLE
                    // (block_start is low there), so this is the AF top's check
                    // on the same SC history, at most more lenient.
                    max_len = 0;
                    for (int h = 0; h < N_H; h++)
                        if (int'(sc_a_len[h*WIDTH +: WIDTH]) > max_len)
                            max_len = int'(sc_a_len[h*WIDTH +: WIDTH]);
                    if (cyc < 4'd8 && 16 * (int'(cyc) + 1) < max_len) begin
                        contract_errors++;
                        $error("[CBSG-AF-CONTRACT] block_start after %0d cycles cuts a block of max L %0d (needs %0d)",
                               int'(cyc) + 1, max_len, (max_len + 15) / 16);
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
