`ifndef PAYN_SIGNED_SEGMENTED_DIRECT_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_DIRECT_INNER_TILE

// Exact direct-retire signed segmented accumulator for one PaYN inner tile.
//
// The true signed K-lane contribution is added only to a LOW_W-bit residue.
// A carry/borrow across the 2**LOW_W boundary updates the upper accumulator on
// the same edge as the residue. This removes the two always-clocked pending
// event bits used by the first signed-segmented implementation.
module InnerTileSignedSegmentedDirect #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 11
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
    localparam int TERM_W = LANE_W + 1;
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

    logic signed [TERM_W-1:0] lane_terms [K];
    logic [(K+1)*SUM_W-1:0] heap_inputs;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic [LANE_W-1:0] hit_count;
        logic signed [TERM_W-1:0] hit_magnitude;
        logic negate;

        assign products = a_bits[i] & w_bits[i];
        assign hit_count = LANE_W'($countones(products));
        assign hit_magnitude = $signed({1'b0, hit_count});
        assign negate = a_signs[i] ^ w_signs[i];
        assign lane_terms[i] = negate ? -hit_magnitude : hit_magnitude;
        assign heap_inputs[i*SUM_W +: SUM_W] =
            SUM_W'($signed(lane_terms[i]));
    end

    logic [LOW_W-1:0] acc_low;
    logic [HIGH_W-1:0] acc_high;

    // Zero-extend the unsigned residue.  SUM_W has enough signed range for
    // [0, 2**LOW_W-1] plus one full-cycle contribution in [-K*M, K*M].
    assign heap_inputs[K*SUM_W +: SUM_W] = SUM_W'($unsigned(acc_low));

    logic [SUM_W-1:0] heap_row0;
    logic [SUM_W-1:0] heap_row1;
    logic signed [SUM_W-1:0] low_sum;
    logic next_carry;
    logic next_borrow;

    DW02_tree #(
        .num_inputs(K + 1),
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

    assign acc_out = $signed({acc_high, acc_low});

    always_ff @(posedge clk) begin
        if (reset) begin
            acc_low <= '0;
            acc_high <= '0;
        end else if (shift_in) begin
            acc_low <= acc_in[LOW_W-1:0];
            acc_high <= acc_in[OWIDTH-1:LOW_W];
        end else if (mac_en) begin
            acc_low <= low_sum[LOW_W-1:0];
            if (next_carry)
                acc_high <= acc_high + HIGH_W'(1);
            else if (next_borrow)
                acc_high <= acc_high - HIGH_W'(1);
        end
    end
endmodule

`endif
