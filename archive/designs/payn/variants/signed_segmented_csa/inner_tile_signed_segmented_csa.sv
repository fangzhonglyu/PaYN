`ifndef PAYN_SIGNED_SEGMENTED_CSA_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_CSA_INNER_TILE

`include "payn/variants/signed_segmented_popcount/popcount16.sv"

// The 11-FA popcount network without its final half-adder ripple.  Before
// ha0..ha3 the count already sits in five redundant bits,
//
//     count = s0a + s0b + 2*s1 + 4*s2 + 8*s3,
//
// whose weights sum to exactly M = 16.  Inverting all five therefore gives
// 16 - count, which is what makes the sign handling below free of adders.
module PaynPopcount16Csa (
    input  logic [15:0] bits_in,
    output logic s0a, s0b, s1, s2, s3
);
    logic [10:0] fs, fc;

    for (genvar i = 0; i < 5; i++) begin : g_first
        PaynPopcountFA u_fa (
            .a(bits_in[3*i]), .b(bits_in[3*i+1]), .ci(bits_in[3*i+2]),
            .s(fs[i]), .co(fc[i])
        );
    end
    PaynPopcountFA u_fa5 (.a(fs[0]), .b(fs[1]), .ci(fs[2]), .s(fs[5]), .co(fc[5]));
    PaynPopcountFA u_fa6 (.a(fs[3]), .b(fs[4]), .ci(bits_in[15]), .s(fs[6]), .co(fc[6]));
    PaynPopcountFA u_fa7 (.a(fc[0]), .b(fc[1]), .ci(fc[2]), .s(fs[7]), .co(fc[7]));
    PaynPopcountFA u_fa8 (.a(fc[3]), .b(fc[4]), .ci(fc[5]), .s(fs[8]), .co(fc[8]));
    PaynPopcountFA u_fa9 (.a(fs[7]), .b(fs[8]), .ci(fc[6]), .s(fs[9]), .co(fc[9]));
    PaynPopcountFA u_fa10 (.a(fc[7]), .b(fc[8]), .ci(fc[9]), .s(fs[10]), .co(fc[10]));

    assign s0a = fs[5];
    assign s0b = fs[6];
    assign s1 = fs[9];
    assign s2 = fs[10];
    assign s3 = fc[10];
endmodule

// M = 8 counterpart: four full adders leave the count in four redundant bits,
//
//     count = s0a + s0b + 2*s1 + 4*s2,
//
// whose weights sum to exactly M = 8, so inverting all four gives 8 - count.
module PaynPopcount8Csa (
    input  logic [7:0] bits_in,
    output logic s0a, s0b, s1, s2
);
    logic [3:0] fs, fc;

    PaynPopcountFA u_fa0 (.a(bits_in[0]), .b(bits_in[1]), .ci(bits_in[2]), .s(fs[0]), .co(fc[0]));
    PaynPopcountFA u_fa1 (.a(bits_in[3]), .b(bits_in[4]), .ci(bits_in[5]), .s(fs[1]), .co(fc[1]));
    PaynPopcountFA u_fa2 (.a(fs[0]), .b(fs[1]), .ci(bits_in[6]), .s(fs[2]), .co(fc[2]));
    PaynPopcountFA u_fa3 (.a(fc[0]), .b(fc[1]), .ci(fc[2]), .s(fs[3]), .co(fc[3]));

    assign s0a = fs[2];
    assign s0b = bits_in[7];
    assign s1 = fs[3];
    assign s2 = fc[3];
endmodule

// Exact signed segmented accumulator, carry-save lane interface.
//
// Difference from `signed_segmented_popcount`: each lane hands its count to the
// cross-K heap in the counter's five redundant bits instead of a binary 5-bit
// count followed by a two's-complement negate.  For negative flag n,
//
//     n ? -count : count  =  sum_j (bit_j ^ n) * weight_j  -  16*n,
//
// so a lane costs five XORs, and one product-independent correction
// -M * countones(negative lanes) enters the heap once per tile.  The signs are
// held for a whole stochastic block, so the correction does not toggle inside
// a block.  Pending carry/borrow, the shared HIGH_W adder, canonical acc_out
// and the drain are unchanged; drained values are bit-identical.
module InnerTileSignedSegmentedCsa #(
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
    localparam int SUM_W = LOW_W + 2;
    localparam int HIGH_W = OWIDTH - LOW_W;
    localparam int RADIX = 1 << LOW_W;
    localparam int NEG_W = $clog2(K + 1);
    localparam int M_LOG2 = $clog2(M);
    // Per lane: one multi-bit row ({s3,s2,s1,s0a} for M=16, {s2,s1,s0a} for
    // M=8) and one 1-bit row {s0b}.
    localparam int N_HEAP = 2*K + 2;

    initial begin
        assert (M == 16 || M == 8)
            else $fatal(1, "the carry-save lane interface is built for M=16 or M=8 (got %0d)", M);
        assert (K > 0 && LOW_W > 0)
            else $fatal(1, "K and LOW_W must be positive");
        assert (OWIDTH > LOW_W)
            else $fatal(1, "OWIDTH (%0d) must exceed LOW_W (%0d)", OWIDTH, LOW_W);
        assert (RADIX >= K*M)
            else $fatal(1, "2**LOW_W (%0d) must be at least K*M (%0d)",
                        RADIX, K*M);
    end

    //---------------------------------------------------------------- lanes --
    logic [N_HEAP*SUM_W-1:0] heap_inputs;
    logic [K-1:0] negative_lanes;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic negate;

        assign products = a_bits[i] & w_bits[i];
        assign negate = a_signs[i] ^ w_signs[i];
        assign negative_lanes[i] = negate;
        if (M == 16) begin : g_m16
            logic s0a, s0b, s1, s2, s3;
            PaynPopcount16Csa u_popcount (
                .bits_in(products), .s0a, .s0b, .s1, .s2, .s3
            );
            assign heap_inputs[(2*i)*SUM_W +: SUM_W] =
                SUM_W'({s3, s2, s1, s0a} ^ {4{negate}});
            assign heap_inputs[(2*i+1)*SUM_W +: SUM_W] =
                SUM_W'(s0b ^ negate);
        end else begin : g_m8
            logic s0a, s0b, s1, s2;
            PaynPopcount8Csa u_popcount (
                .bits_in(products), .s0a, .s0b, .s1, .s2
            );
            assign heap_inputs[(2*i)*SUM_W +: SUM_W] =
                SUM_W'({s2, s1, s0a} ^ {3{negate}});
            assign heap_inputs[(2*i+1)*SUM_W +: SUM_W] =
                SUM_W'(s0b ^ negate);
        end
    end

    // -M per negative lane, applied once.  Stable for a whole block.
    logic [NEG_W-1:0] negative_count;
    assign negative_count = NEG_W'($countones(negative_lanes));
    assign heap_inputs[(2*K)*SUM_W +: SUM_W] =
        SUM_W'(-$signed({1'b0, negative_count, {M_LOG2{1'b0}}}));

    logic [LOW_W-1:0]  acc_low;
    logic [HIGH_W-1:0] acc_high;
    logic pending_carry;
    logic pending_borrow;

    assign heap_inputs[(2*K+1)*SUM_W +: SUM_W] = SUM_W'($unsigned(acc_low));

    logic [SUM_W-1:0] heap_row0;
    logic [SUM_W-1:0] heap_row1;
    logic signed [SUM_W-1:0] low_sum;
    logic next_carry;
    logic next_borrow;

    DW02_tree #(
        .num_inputs(N_HEAP),
        .input_width(SUM_W),
        .verif_en(1)
    ) u_heap (
        .INPUT(heap_inputs),
        .OUT0(heap_row0),
        .OUT1(heap_row1)
    );

    // Same range argument as the cleaned design: low_sum spans
    // [-K*M, 2**(LOW_W+1)-1], so negative is exactly one borrow and bit LOW_W
    // of a non-negative sum is exactly one carry.
    assign low_sum = $signed(heap_row0) + $signed(heap_row1);
    assign next_borrow = low_sum[SUM_W-1];
    assign next_carry  = !low_sum[SUM_W-1] && low_sum[LOW_W];

    //-------------------------------------------------- upper segment (+-1) --
    logic [HIGH_W-1:0] high_next;
    assign high_next =
        acc_high + {HIGH_W{pending_borrow}} + HIGH_W'(pending_carry);

    assign acc_out = $signed({high_next, acc_low});

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
            if (pending_carry || pending_borrow)
                acc_high <= high_next;

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

`ifndef SYNTHESIS
    always_ff @(posedge clk)
        assert (!(pending_carry === 1'b1 && pending_borrow === 1'b1))
            else $fatal(1, "pending_carry and pending_borrow both set");
`endif
endmodule

`endif
