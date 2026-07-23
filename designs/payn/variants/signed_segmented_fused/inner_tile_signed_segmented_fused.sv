`ifndef PAYN_SIGNED_SEGMENTED_FUSED_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_FUSED_INNER_TILE

// Exact signed segmented accumulator with one fused raw-product bit heap.
//
// For lane i, let p_ij be a one-bit product and n_i select a negative lane:
//
//   sum_j ((p_ij ^ n_i)) - M*n_i
//     = popcount(p_i)                 when n_i == 0
//     = (M-popcount(p_i)) - M
//     = -popcount(p_i)                when n_i == 1
//
// Every compensated raw product is therefore presented directly to the same
// compressor tree as the old low residue.  Only the K-bit, sign-only
// correction is formed separately; unlike the product data, it is stationary
// while operand signs are resident in the PE.
//
// The accumulator boundary protocol matches InnerTileSignedSegmented: a
// carry/borrow is visible immediately and retires into acc_high one cycle
// later.  acc_out is consequently canonical after combinational settling.
module InnerTileSignedSegmentedFused #(
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
    localparam int RAW_BITS = K*M;
    localparam int NEG_W = $clog2(K + 1);
    localparam int SUM_W = LOW_W + 2;
    localparam int HIGH_W = OWIDTH - LOW_W;
    localparam int N_HEAP_INPUTS = RAW_BITS + 2;
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
    logic [NEG_W-1:0] negative_count;
    logic [SUM_W-1:0] correction_magnitude;
    logic signed [SUM_W-1:0] correction;
    logic [N_HEAP_INPUTS*SUM_W-1:0] heap_inputs;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic [M-1:0] compensated_products;

        assign negative_lanes[i] = a_signs[i] ^ w_signs[i];
        assign products = a_bits[i] & w_bits[i];
        assign compensated_products =
            products ^ {M{negative_lanes[i]}};

        for (genvar j = 0; j < M; j++) begin : g_raw_bits
            localparam int RAW_INDEX = i*M + j;
            assign heap_inputs[RAW_INDEX*SUM_W +: SUM_W] =
                {{(SUM_W-1){1'b0}}, compensated_products[j]};
        end
    end

    // This is the sole binary count boundary before the fused heap, and it
    // depends only on K resident sign bits rather than K*M switching products.
    assign negative_count = NEG_W'($countones(negative_lanes));
    assign correction_magnitude =
        SUM_W'($unsigned(negative_count) * M);
    assign correction = -$signed(correction_magnitude);

    logic [LOW_W-1:0] acc_low;
    logic [HIGH_W-1:0] acc_high;
    logic pending_carry;
    logic pending_borrow;

    assign heap_inputs[RAW_BITS*SUM_W +: SUM_W] = correction;
    assign heap_inputs[(RAW_BITS+1)*SUM_W +: SUM_W] =
        SUM_W'($unsigned(acc_low));

    logic [SUM_W-1:0] heap_row0;
    logic [SUM_W-1:0] heap_row1;
    logic signed [SUM_W-1:0] low_sum;
    logic next_carry;
    logic next_borrow;

    DW02_tree #(
        .num_inputs(N_HEAP_INPUTS),
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
