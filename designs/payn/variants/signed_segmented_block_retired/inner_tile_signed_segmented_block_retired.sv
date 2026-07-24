`ifndef PAYN_SIGNED_SEGMENTED_BLOCK_RETIRED_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_BLOCK_RETIRED_INNER_TILE

// Exact block-retired signed accumulator for one PaYN inner tile.
//
// The product signs are required to remain fixed for BLOCK_CYCLES=T/M enabled
// MACs.  For lane hit count c_i and negative-lane flag n_i, define
//
//     u_i = n_i ? M-c_i : c_i.
//
// Every enabled cycle adds only the non-negative u_i values to a radix-T low
// digit.  At the end of a complete block,
//
//     sum_t sum_i (+/- c_i)
//       = sum_t sum_i u_i - T*countones(n),
//
// so the high digit changes by the accumulated low-digit quotient minus the
// number of negative lanes.  The wide high bank therefore changes only once
// per block.  acc_out is canonical at block boundaries; mid-block observation
// or shift is intentionally outside this variant's interface contract.
module InnerTileSignedSegmentedBlockRetired #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int T = 128,
    parameter int OWIDTH = 24
) (
    input  logic clk,
    input  logic reset,
    input  logic         a_signs [K],
    input  logic [M-1:0] a_bits  [K],
    input  logic         w_signs [K],
    input  logic [M-1:0] w_bits  [K],
    input  logic block_last,
    input  logic shift_in,
    input  logic mac_en,
    input  logic signed [OWIDTH-1:0] acc_in,
    output logic signed [OWIDTH-1:0] acc_out
);
    localparam int BLOCK_CYCLES = T / M;
    localparam int LOW_W = $clog2(T);
    localparam int HIGH_W = OWIDTH - LOW_W;
    localparam int LANE_W = $clog2(M + 1);
    localparam int NEG_W = $clog2(K + 1);
    // One-cycle biased sum is at most K*M and acc_low is at most T-1.
    // This width also supports T<K*M, where one cycle may cross more than one
    // radix-T boundary.
    localparam int SUM_W = $clog2(T + K*M);
    localparam int CYCLE_Q_W = SUM_W - LOW_W;
    // Across T/M cycles, the total biased input is at most T*K, so the
    // complete block quotient is at most K independent of T and M.
    localparam int CARRY_W = $clog2(K + 1);
    localparam int DELTA_W = CARRY_W + 1;

    initial begin
        assert (K > 0) else $error("K must be positive");
        assert (M > 0) else $error("M must be positive");
        assert (T > 0) else $error("T must be positive");
        assert ((T & (T - 1)) == 0)
            else $error("T must be a power of two");
        assert ((T % M) == 0)
            else $error("T must be an integer multiple of M");
        assert (OWIDTH > LOW_W)
            else $error("OWIDTH must exceed log2(T)");
    end

    logic [K-1:0] negative_lanes;
    logic [LANE_W-1:0] biased_counts [K];
    logic [(K+1)*SUM_W-1:0] heap_inputs;

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

    logic [LOW_W-1:0] acc_low;
    logic [HIGH_W-1:0] acc_high;
    logic [CARRY_W-1:0] block_carry_count;

    assign heap_inputs[K*SUM_W +: SUM_W] =
        SUM_W'($unsigned(acc_low));

    logic [SUM_W-1:0] heap_row0;
    logic [SUM_W-1:0] heap_row1;
    logic [SUM_W-1:0] cycle_sum;
    logic [CYCLE_Q_W-1:0] cycle_quotient;

    DW02_tree #(
        .num_inputs(K + 1),
        .input_width(SUM_W),
        .verif_en(1)
    ) u_heap (
        .INPUT(heap_inputs),
        .OUT0(heap_row0),
        .OUT1(heap_row1)
    );

    // The low slice is the radix-T residue and the remaining upper slice is
    // the complete per-cycle quotient.  For the target T=128, K=8, M=16 this
    // quotient is one bit; smaller valid T values remain exact as well.
    assign cycle_sum = heap_row0 + heap_row1;
    assign cycle_quotient = cycle_sum[SUM_W-1:LOW_W];

    logic [NEG_W-1:0] negative_count;
    logic [CARRY_W-1:0] retiring_carry_count;
    logic signed [DELTA_W-1:0] block_high_delta;
    logic [HIGH_W-1:0] block_high_delta_mod;

    assign negative_count = NEG_W'($countones(negative_lanes));
    assign retiring_carry_count =
        block_carry_count + CARRY_W'(cycle_quotient);
    assign block_high_delta =
        DELTA_W'($signed({1'b0, retiring_carry_count}))
        - DELTA_W'($signed({1'b0, negative_count}));
    assign block_high_delta_mod = HIGH_W'(block_high_delta);

    assign acc_out = $signed({acc_high, acc_low});

    always_ff @(posedge clk) begin
        if (reset) begin
            acc_low <= '0;
            acc_high <= '0;
            block_carry_count <= '0;
        end else if (shift_in) begin
            acc_low <= acc_in[LOW_W-1:0];
            acc_high <= acc_in[OWIDTH-1:LOW_W];
            block_carry_count <= '0;
        end else if (mac_en) begin
            acc_low <= cycle_sum[LOW_W-1:0];

            if (block_last) begin
                acc_high <= acc_high + block_high_delta_mod;
                block_carry_count <= '0;
            end else begin
                block_carry_count <= retiring_carry_count;
            end
        end
    end
endmodule

`endif
