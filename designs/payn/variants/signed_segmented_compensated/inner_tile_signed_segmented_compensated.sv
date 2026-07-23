`ifndef PAYN_SIGNED_SEGMENTED_COMPENSATED_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_COMPENSATED_INNER_TILE

// Exact signed segmented accumulator with a compensated unsigned input heap.
//
// For lane hit count c_i and negative-lane flag n_i, define
//
//     b_i = n_i ? M-c_i : c_i.
//
// The exact signed contribution is then
//
//     sum_i (+/- c_i) = sum_i b_i - M*sum_i n_i.
//
// This replaces K sign-extended, conditionally negated lane terms with K short
// non-negative terms and one correction term.  The correction depends only on
// the operand signs and is therefore stable throughout a normal MAC block.
//
// As in InnerTileSignedSegmented, only the LOW_W-bit residue participates in
// the per-cycle heap.  A carry/borrow across 2**LOW_W is captured as a pending
// event and retired into the high bank on the next clock.  acc_out includes the
// pending event combinationally, so it is canonical after every MAC and this
// accumulator can run for an arbitrary number of cycles without finalization.
module InnerTileSignedSegmentedCompensated #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9
) (
    input  logic clk,
    input  logic reset,
    input  logic         a_signs [K],
    input  logic [M-1:0] a_bits  [K],
    input  logic         w_signs [K],
    input  logic [M-1:0] w_bits  [K],
    input  logic shift_in,
    input  logic mac_en,
    input  logic signed [OWIDTH-1:0] acc_in,
    output logic signed [OWIDTH-1:0] acc_out
);
    localparam int LANE_W = $clog2(M + 1);
    localparam int NEG_W = $clog2(K + 1);
    localparam int SUM_W = LOW_W + 2;
    localparam int HIGH_W = OWIDTH - LOW_W;
    localparam int RADIX = 1 << LOW_W;

    initial begin
        assert (K > 0) else $error("K must be positive");
        assert (M > 0) else $error("M must be positive");
        assert (LOW_W > 0) else $error("LOW_W must be positive");
        assert (OWIDTH > LOW_W)
            else $error("OWIDTH must exceed LOW_W");
        assert (RADIX >= K*M)
            else $error("2**LOW_W must be at least K*M");
    end

    logic [K-1:0] negative_lanes;
    logic [LANE_W-1:0] biased_counts [K];
    logic [(K+2)*SUM_W-1:0] heap_inputs;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic [LANE_W-1:0] hit_count;

        assign products = a_bits[i] & w_bits[i];
        assign hit_count = LANE_W'($countones(products));
        assign negative_lanes[i] = a_signs[i] ^ w_signs[i];
        assign biased_counts[i] = negative_lanes[i]
            ? LANE_W'(M) - hit_count
            : hit_count;
        assign heap_inputs[i*SUM_W +: SUM_W] =
            SUM_W'($unsigned(biased_counts[i]));
    end

    // All negative lanes share one compensation term.  For M=16 this is only
    // a sign-count followed by a four-bit shift; the generic constant multiply
    // keeps the RTL exact for other M values as well.
    logic [NEG_W-1:0] negative_count;
    logic [SUM_W-1:0] correction_magnitude;
    logic signed [SUM_W-1:0] correction_term;

    assign negative_count = NEG_W'($countones(negative_lanes));
    assign correction_magnitude =
        SUM_W'(M) * SUM_W'($unsigned(negative_count));
    assign correction_term = -$signed(correction_magnitude);
    assign heap_inputs[K*SUM_W +: SUM_W] =
        $unsigned(correction_term);

    logic [LOW_W-1:0] acc_low;
    logic [HIGH_W-1:0] acc_high;
    logic pending_carry;
    logic pending_borrow;

    // SUM_W has signed range for acc_low plus one complete signed cycle
    // contribution because 2**LOW_W >= K*M.
    assign heap_inputs[(K+1)*SUM_W +: SUM_W] =
        SUM_W'($unsigned(acc_low));

    logic [SUM_W-1:0] heap_row0;
    logic [SUM_W-1:0] heap_row1;
    logic signed [SUM_W-1:0] low_sum;
    logic next_carry;
    logic next_borrow;

    DW02_tree #(
        .num_inputs(K + 2),
        .input_width(SUM_W),
        .verif_en(1)
    ) u_heap (
        .INPUT(heap_inputs),
        .OUT0(heap_row0),
        .OUT1(heap_row1)
    );

    assign low_sum = $signed(heap_row0) + $signed(heap_row1);
    assign next_borrow = low_sum[SUM_W-1];
    assign next_carry =
        !low_sum[SUM_W-1] && low_sum[LOW_W];

    logic [HIGH_W-1:0] visible_high;
    always_comb begin
        visible_high = acc_high;
        if (pending_carry)
            visible_high = acc_high + HIGH_W'(1);
        else if (pending_borrow)
            visible_high = acc_high - HIGH_W'(1);
    end

    assign acc_out = $signed({visible_high, acc_low});

    always_ff @(posedge clk) begin
        if (reset) begin
            acc_low <= '0;
            acc_high <= '0;
            pending_carry <= 1'b0;
            pending_borrow <= 1'b0;
        end else if (shift_in) begin
            acc_low <= acc_in[LOW_W-1:0];
            acc_high <= acc_in[OWIDTH-1:LOW_W];
            pending_carry <= 1'b0;
            pending_borrow <= 1'b0;
        end else begin
            if (pending_carry)
                acc_high <= acc_high + HIGH_W'(1);
            else if (pending_borrow)
                acc_high <= acc_high - HIGH_W'(1);

            if (mac_en) begin
                acc_low <= low_sum[LOW_W-1:0];
                pending_carry <= next_carry;
                pending_borrow <= next_borrow;
            end else begin
                pending_carry <= 1'b0;
                pending_borrow <= 1'b0;
            end
        end
    end
endmodule

`endif
