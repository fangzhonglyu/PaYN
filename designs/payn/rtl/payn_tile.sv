`ifndef PAYN_TILE_SV
`define PAYN_TILE_SV

// One output-stationary accumulator tile: K lanes of M stochastic products
// (M = 16 or 8), a carry-save lane interface and a segmented accumulator.

// Full adder; a+b+ci = s + 2*co.
module PaynFA (
    input  logic a, b, ci,
    output logic s, co
);
    assign {co, s} = {1'b0, a} + {1'b0, b} + {1'b0, ci};
endmodule

// 16-input population count left in carry-save form: 11 full adders and no
// half-adder ripple.  The count sits in five redundant bits,
//
//     count = s0a + s0b + 2*s1 + 4*s2 + 8*s3,
//
// whose weights sum to exactly 16, so inverting all five gives 16 - count.
// That is what makes the tile's sign handling free of adders.
module PaynCount16 (
    input  logic [15:0] bits_in,
    output logic s0a, s0b, s1, s2, s3
);
    logic [10:0] fs, fc;

    for (genvar i = 0; i < 5; i++) begin : g_first
        PaynFA u_fa (
            .a(bits_in[3*i]), .b(bits_in[3*i+1]), .ci(bits_in[3*i+2]),
            .s(fs[i]), .co(fc[i])
        );
    end
    PaynFA u_fa5 (.a(fs[0]), .b(fs[1]), .ci(fs[2]), .s(fs[5]), .co(fc[5]));
    PaynFA u_fa6 (.a(fs[3]), .b(fs[4]), .ci(bits_in[15]), .s(fs[6]), .co(fc[6]));
    PaynFA u_fa7 (.a(fc[0]), .b(fc[1]), .ci(fc[2]), .s(fs[7]), .co(fc[7]));
    PaynFA u_fa8 (.a(fc[3]), .b(fc[4]), .ci(fc[5]), .s(fs[8]), .co(fc[8]));
    PaynFA u_fa9 (.a(fs[7]), .b(fs[8]), .ci(fc[6]), .s(fs[9]), .co(fc[9]));
    PaynFA u_fa10 (.a(fc[7]), .b(fc[8]), .ci(fc[9]), .s(fs[10]), .co(fc[10]));

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
// whose weights sum to exactly 8, so inverting all four gives 8 - count.
module PaynCount8 (
    input  logic [7:0] bits_in,
    output logic s0a, s0b, s1, s2
);
    logic [3:0] fs, fc;

    PaynFA u_fa0 (.a(bits_in[0]), .b(bits_in[1]), .ci(bits_in[2]), .s(fs[0]), .co(fc[0]));
    PaynFA u_fa1 (.a(bits_in[3]), .b(bits_in[4]), .ci(bits_in[5]), .s(fs[1]), .co(fc[1]));
    PaynFA u_fa2 (.a(fs[0]), .b(fs[1]), .ci(bits_in[6]), .s(fs[2]), .co(fc[2]));
    PaynFA u_fa3 (.a(fc[0]), .b(fc[1]), .ci(fc[2]), .s(fs[3]), .co(fc[3]));

    assign s0a = fs[2];
    assign s0b = bits_in[7];
    assign s1 = fs[3];
    assign s2 = fc[3];
endmodule

// Exact signed segmented accumulator.
//
// Lanes.  Lane i counts a_bits[i] & w_bits[i] and hands the count to a
// cross-lane heap in the counter's redundant bits (five at M = 16, four at
// M = 8, weights summing to M).  For the lane's negative flag
// n = a_sign ^ w_sign,
//
//     n ? -count : count  =  sum_j (bit_j ^ n) * weight_j  -  M*n,
//
// so a lane costs one XOR per counter bit, and one product-independent correction
// -M * countones(negative lanes) enters the heap once per tile.  Signs are
// held for a whole block, so the correction does not toggle inside a block.
//
// Accumulator.  acc_low (LOW_W bits) takes the heap sum every MAC edge; the
// carry or borrow out of it is held one edge in pending_carry/pending_borrow
// and folded into acc_high (HIGH_W bits, +-1 adder) on the next edge.
// acc_out = {high_next, acc_low} is the canonical value with the pending bit
// already folded in.  A shift edge loads acc_in and clears both pending bits;
// shift has priority over mac_en.
//
// Fold (FOLD = 1, the INT lap fold).  An edge with fold and mac_en is a MAC
// edge that doubles the canonical value first,
//
//     acc  <-  2 * acc_out + S        (mod 2^OWIDTH, S = this edge's heap sum)
//
// with no new adder: the heap takes {acc_low[LOW_W-2:0], 0} in place of
// acc_low, so low_sum = 2*(acc_low mod 2^(LOW_W-1)) + S stays inside
// [-K*M, 2**(LOW_W+1)-1] (one carry or borrow at most, pending bits as on any
// MAC edge), and acc_high loads {high_next[HIGH_W-2:0], acc_low[LOW_W-1]},
// i.e. 2*high_next plus the bit that leaves the low segment (high_next has
// the previous edge's pending bit folded in).  Shift keeps priority; a fold
// needs mac_en (the PE checks both, [FOLD-CONTRACT]).  With FOLD = 0 the fold
// input is ignored.
module PaynTile #(
    parameter int K = 16,
    parameter int M = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9,
    parameter int FOLD = 0
) (
    input  logic clk,
    input  logic reset,
    input  logic         a_signs [K],
    input  logic [M-1:0] a_bits  [K],
    input  logic         w_signs [K],
    input  logic [M-1:0] w_bits  [K],
    input  logic shift_in,
    input  logic mac_en,
    input  logic fold,
    input  logic signed [OWIDTH-1:0] acc_in,
    output logic signed [OWIDTH-1:0] acc_out
);
    localparam int SUM_W = LOW_W + 2;
    localparam int HIGH_W = OWIDTH - LOW_W;
    localparam int RADIX = 1 << LOW_W;
    localparam int NEG_W = $clog2(K + 1);
    localparam int M_LOG2 = $clog2(M);
    // Per lane: one multi-bit row ({s3,s2,s1,s0a} at M = 16, {s2,s1,s0a} at
    // M = 8) and one 1-bit row {s0b}; plus the sign correction and acc_low.
    localparam int N_HEAP = 2*K + 2;

    initial begin
        assert (M == 16 || M == 8)
            else $fatal(1, "PaynTile is built for M=16 or M=8 (got %0d)", M);
        assert (K > 0 && LOW_W > 0)
            else $fatal(1, "K and LOW_W must be positive");
        assert (OWIDTH > LOW_W)
            else $fatal(1, "OWIDTH (%0d) must exceed LOW_W (%0d)", OWIDTH, LOW_W);
        assert (RADIX >= K*M)
            else $fatal(1, "2**LOW_W (%0d) must be at least K*M (%0d)", RADIX, K*M);
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
            PaynCount16 u_popcount (
                .bits_in(products), .s0a, .s0b, .s1, .s2, .s3
            );
            assign heap_inputs[(2*i)*SUM_W +: SUM_W] =
                SUM_W'({s3, s2, s1, s0a} ^ {4{negate}});
            assign heap_inputs[(2*i+1)*SUM_W +: SUM_W] =
                SUM_W'(s0b ^ negate);
        end else begin : g_m8
            logic s0a, s0b, s1, s2;
            PaynCount8 u_popcount (
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

    // The heap's accumulator row: acc_low, doubled on a fold edge.
    logic do_fold;
    logic [LOW_W-1:0] acc_low_row;
    assign do_fold = (FOLD == 1) && fold;
    assign acc_low_row = do_fold ? {acc_low[LOW_W-2:0], 1'b0} : acc_low;
    assign heap_inputs[(2*K+1)*SUM_W +: SUM_W] = SUM_W'($unsigned(acc_low_row));

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

    // low_sum spans [-K*M, 2**(LOW_W+1)-1] (a fold edge: [-K*M, 2**LOW_W-2+K*M]):
    // a negative sum is exactly one borrow, and bit LOW_W of a non-negative sum
    // is exactly one carry.
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
            if (do_fold)
                acc_high <= {high_next[HIGH_W-2:0], acc_low[LOW_W-1]};
            else if (pending_carry || pending_borrow)
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
