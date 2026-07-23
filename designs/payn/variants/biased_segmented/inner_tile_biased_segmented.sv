`ifndef PAYN_BIASED_SEGMENTED_INNER_TILE
`define PAYN_BIASED_SEGMENTED_INNER_TILE

// Exact blockwise-biased accumulator for the bipolar PaYN inner tile.
//
// During one BLOCK_T-cycle stochastic block, a signed lane contribution
//
//     negate ? -count(products) : count(products)
//
// is represented as the non-negative value
//
//     negate ? M-count(products) : count(products).
//
// The resulting offset is BLOCK_T*M for every negative lane.  This variant
// requires BLOCK_T*M to be a power of two, so the block-finalize correction
// changes only the upper accumulator segment.  The full OWIDTH-bit state is
// canonical at every block boundary and may persist across arbitrarily many
// blocks subject to the normal OWIDTH overflow contract.
module InnerTileBiasedSegmented #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int OWIDTH = 24,
    parameter int BLOCK_T = 128
) (
    input  logic clk,
    input  logic reset,
    input  logic         a_signs [K],
    input  logic [M-1:0] a_bits  [K],
    input  logic         w_signs [K],
    input  logic [M-1:0] w_bits  [K],
    input  logic shift_in,
    input  logic mac_en,
    input  logic block_finalize,
    input  logic signed [OWIDTH-1:0] acc_in,
    output logic signed [OWIDTH-1:0] acc_out
);
    localparam int LANE_W = $clog2(M + 1);
    localparam int BLOCK_RADIX = BLOCK_T * M;
    localparam int RADIX_W = $clog2(BLOCK_RADIX);
    localparam int HIGH_W = OWIDTH - RADIX_W;
    // One extra bit captures the single radix-boundary carry.  BLOCK_T >= K
    // guarantees that the K lane contributions cannot produce two carries in
    // one cycle.
    localparam int HEAP_W = RADIX_W + 1;
    localparam int NEG_W = $clog2(K + 1);

    initial begin
        assert (K > 0) else $error("K must be positive");
        assert (M > 0) else $error("M must be positive");
        assert (BLOCK_T > 0) else $error("BLOCK_T must be positive");
        assert ((BLOCK_RADIX & (BLOCK_RADIX - 1)) == 0)
            else $error("BLOCK_T*M must be a power of two");
        assert (BLOCK_T >= K)
            else $error("BLOCK_T must be >= K for a single boundary carry");
        assert (OWIDTH > RADIX_W)
            else $error("OWIDTH must exceed log2(BLOCK_T*M)");
    end

    logic [K-1:0] negative_lanes;
    logic [NEG_W-1:0] negative_count;
    logic [LANE_W-1:0] biased_lane_counts [K];
    logic [(K+1)*HEAP_W-1:0] heap_inputs;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic [LANE_W-1:0] hit_count;

        assign products = a_bits[i] & w_bits[i];
        assign hit_count = LANE_W'($countones(products));
        assign negative_lanes[i] = a_signs[i] ^ w_signs[i];
        assign biased_lane_counts[i] = negative_lanes[i]
            ? LANE_W'(M) - hit_count
            : hit_count;
        assign heap_inputs[i*HEAP_W +: HEAP_W] =
            HEAP_W'(biased_lane_counts[i]);
    end

    assign negative_count = NEG_W'($countones(negative_lanes));

    logic [RADIX_W-1:0] acc_low;
    logic [HIGH_W-1:0] acc_high;

    // Compress the K biased lane counts together with only the low accumulator
    // segment.  This retains the current DesignWare carry-save reduction while
    // reducing its width from OWIDTH to RADIX_W+1.
    assign heap_inputs[K*HEAP_W +: HEAP_W] = HEAP_W'(acc_low);

    logic [HEAP_W-1:0] heap_row0;
    logic [HEAP_W-1:0] heap_row1;
    logic [HEAP_W-1:0] heap_total;

    DW02_tree #(
        .num_inputs(K + 1),
        .input_width(HEAP_W),
        .verif_en(1)
    ) u_heap (
        .INPUT(heap_inputs),
        .OUT0(heap_row0),
        .OUT1(heap_row1)
    );

    assign heap_total = heap_row0 + heap_row1;
    assign acc_out = $signed({acc_high, acc_low});

    // State priority matches the baseline shift/MAC behavior.  Finalize must
    // be pulsed once after exactly BLOCK_T MAC cycles and before the associated
    // signs are replaced.  It subtracts negative_count*BLOCK_RADIX by changing
    // only acc_high.
    always_ff @(posedge clk) begin
        if (reset) begin
            acc_low <= '0;
            acc_high <= '0;
        end else if (shift_in) begin
            acc_low <= acc_in[RADIX_W-1:0];
            acc_high <= acc_in[OWIDTH-1:RADIX_W];
        end else if (block_finalize) begin
            acc_high <= acc_high - HIGH_W'(negative_count);
        end else if (mac_en) begin
            acc_low <= heap_total[RADIX_W-1:0];
            if (heap_total[RADIX_W])
                acc_high <= acc_high + HIGH_W'(1);
        end
    end
endmodule

`endif
