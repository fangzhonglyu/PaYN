`ifndef PAYN_SIGNED_SEGMENTED_CSA_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_CSA_INNER_TILE

// A width-growing 3:2 compressor.  Keeping the carry-out bit makes the
// relation unsigned(out_sum)+unsigned(out_carry)=a+b+c exact, rather than only
// modulo 2**W as with a fixed-width carry-save primitive.
module PaynCSA3Exact #(
    parameter int W = 1
) (
    input  logic [W-1:0] a,
    input  logic [W-1:0] b,
    input  logic [W-1:0] c,
    output logic [W:0] sum,
    output logic [W:0] carry
);
    logic [W-1:0] majority;

    assign sum = {1'b0, a ^ b ^ c};
    assign majority = (a & b) | (a & c) | (b & c);
    assign carry = {majority, 1'b0};
endmodule

// Exact recurrent carry-save low accumulator for one PaYN inner tile.
//
// The low radix digit is retained as two unsigned LOW_W-bit carry-save rows:
//
//     mathematical accumulator =
//         (acc_high + high_debt) * R + acc_sum + acc_carry
//     R = 2**LOW_W
//
// A signed lane term is inserted into the heap modulo R.  A nonzero negative
// term therefore contributes one explicit -R correction.  The heap is wide
// enough that its unsigned sum cannot overflow; every row bit above LOW_W is
// folded into a small signed high_debt digit.  When that digit wraps, an exact
// multiple of its radix is retired into acc_high.  This maintains the invariant
// for an arbitrary number of MAC cycles without resolving acc_sum + acc_carry
// or frequently toggling the wide high bank.
//
// The redundant digit is converted to canonical two's complement only while
// shift_in is asserted or mac_en is deasserted.  acc_out_valid states this
// contract explicitly.  During an uninterrupted MAC run the canonicalizer is
// operand-isolated and acc_out is zero; no normalization clock is required
// before drain, because deasserting mac_en makes the exact value visible
// combinationally.
module InnerTileSignedSegmentedCSA #(
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
    output logic signed [OWIDTH-1:0] acc_out,
    output logic acc_out_valid
);
    localparam int LANE_W = $clog2(M + 1);
    localparam int TERM_W = LANE_W + 1;
    localparam int HIGH_W = OWIDTH - LOW_W;
    localparam int RADIX = 1 << LOW_W;

    // This first experiment targets the active K=8 design point.  Ten inputs
    // (eight lane residues and two state rows) reduce to two exact rows in five
    // width-growing 3:2 stages.  Fixed-width DW02_tree outputs are deliberately
    // not used: they preserve the sum only modulo their output width, so their
    // final two rows can differ from the unsigned input sum by one full modulus
    // unless a carry-propagate overflow test is added.
    localparam int HEAP_GUARD_W = 5;
    localparam int HEAP_W = LOW_W + HEAP_GUARD_W;
    localparam int COUNT_W = $clog2(K + 1);
    localparam int HIGH_DELTA_W =
        ((HEAP_GUARD_W > COUNT_W) ? HEAP_GUARD_W : COUNT_W) + 2;
    localparam int DEBT_W = $clog2(K + 1);
    localparam int DEBT_RADIX = 1 << DEBT_W;
    localparam int DEBT_MIN = -(1 << (DEBT_W - 1));
    localparam int DEBT_MAX = (1 << (DEBT_W - 1)) - 1;
    localparam int DEBT_SUM_W = HIGH_DELTA_W + 1;

    initial begin
        assert (K > 0) else $error("K must be positive");
        assert (K == 8)
            else $error("this balanced experimental CSA tree requires K=8");
        assert (M > 0) else $error("M must be positive");
        assert (LOW_W > 0) else $error("LOW_W must be positive");
        assert (OWIDTH > LOW_W)
            else $error("OWIDTH must exceed LOW_W");
        assert (RADIX >= K*M)
            else $error("2**LOW_W must be at least K*M");
        assert (DEBT_RADIX >= 2*K)
            else $error("high-debt digit is too narrow for one-cycle correction");
    end

    logic [LOW_W-1:0] lane_residues [K];
    logic [K-1:0] lane_negative_nonzero;
    logic [K-1:0] lane_positive_radix;
    logic [COUNT_W-1:0] negative_count;
    logic [COUNT_W-1:0] positive_radix_count;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic [LANE_W-1:0] hit_count;
        logic signed [TERM_W-1:0] hit_magnitude;
        logic signed [TERM_W-1:0] signed_term;
        logic negate;

        assign products = a_bits[i] & w_bits[i];
        assign hit_count = LANE_W'($countones(products));
        assign hit_magnitude = $signed({1'b0, hit_count});
        assign negate = a_signs[i] ^ w_signs[i];
        assign signed_term = negate ? -hit_magnitude : hit_magnitude;

        // LOW_W' truncation is the term modulo R.  Negative zero needs no
        // correction; a true negative term satisfies term=residue-R.
        assign lane_residues[i] = LOW_W'($signed(signed_term));
        assign lane_negative_nonzero[i] = negate && (|hit_count);

        // RADIX >= K*M makes +R possible only in the K=1 corner.  Preserve
        // exact parameterized behavior there: +R has a zero residue and +R
        // high correction.
        if (RADIX <= M) begin : g_positive_radix
            assign lane_positive_radix[i] =
                !negate && (hit_count == LANE_W'(RADIX));
        end else begin : g_no_positive_radix
            assign lane_positive_radix[i] = 1'b0;
        end
    end

    assign negative_count =
        COUNT_W'($countones(lane_negative_nonzero));
    assign positive_radix_count =
        COUNT_W'($countones(lane_positive_radix));

    logic [LOW_W-1:0] acc_sum;
    logic [LOW_W-1:0] acc_carry;
    logic signed [HIGH_W-1:0] acc_high;
    logic signed [DEBT_W-1:0] high_debt;

    // Balanced exact reduction of {lane_residues[0:7], acc_sum, acc_carry}.
    // Every stage grows by one bit; hence no compressor can discard a carry.
    logic [LOW_W:0] s10, s11, s12, s13, s14, s15, s16;
    logic [LOW_W+1:0] s20, s21, s22, s23, s24;
    logic [LOW_W+2:0] s30, s31, s32, s33;
    logic [LOW_W+3:0] s40, s41, s42;
    logic [HEAP_W-1:0] heap_row0;
    logic [HEAP_W-1:0] heap_row1;
    logic [HEAP_GUARD_W:0] heap_upper_sum;

    PaynCSA3Exact #(.W(LOW_W)) u_csa10 (
        .a(lane_residues[0]), .b(lane_residues[1]),
        .c(lane_residues[2]), .sum(s10), .carry(s11)
    );
    PaynCSA3Exact #(.W(LOW_W)) u_csa11 (
        .a(lane_residues[3]), .b(lane_residues[4]),
        .c(lane_residues[5]), .sum(s12), .carry(s13)
    );
    PaynCSA3Exact #(.W(LOW_W)) u_csa12 (
        .a(lane_residues[6]), .b(lane_residues[7]),
        .c(acc_sum), .sum(s14), .carry(s15)
    );
    assign s16 = {1'b0, acc_carry};

    PaynCSA3Exact #(.W(LOW_W+1)) u_csa20 (
        .a(s10), .b(s11), .c(s12), .sum(s20), .carry(s21)
    );
    PaynCSA3Exact #(.W(LOW_W+1)) u_csa21 (
        .a(s13), .b(s14), .c(s15), .sum(s22), .carry(s23)
    );
    assign s24 = {1'b0, s16};

    PaynCSA3Exact #(.W(LOW_W+2)) u_csa30 (
        .a(s20), .b(s21), .c(s22), .sum(s30), .carry(s31)
    );
    assign s32 = {1'b0, s23};
    assign s33 = {1'b0, s24};

    PaynCSA3Exact #(.W(LOW_W+3)) u_csa40 (
        .a(s30), .b(s31), .c(s32), .sum(s40), .carry(s41)
    );
    assign s42 = {1'b0, s33};

    PaynCSA3Exact #(.W(LOW_W+4)) u_csa50 (
        .a(s40), .b(s41), .c(s42),
        .sum(heap_row0), .carry(heap_row1)
    );

    assign heap_upper_sum =
        {1'b0, heap_row0[HEAP_W-1:LOW_W]} +
        {1'b0, heap_row1[HEAP_W-1:LOW_W]};

    // If U is the unsigned heap total, then
    //
    //   U = new_sum + new_carry + heap_upper_sum*R
    //
    // and each genuinely negative lane added one artificial R to U.  Remove
    // those offsets (and handle the parameterized +R corner) in the small
    // signed high correction, not with a LOW_W-bit carry-propagate adder.
    logic signed [HIGH_DELTA_W-1:0] high_delta;

    assign high_delta =
        $signed(HIGH_DELTA_W'($unsigned(heap_upper_sum))) +
        $signed(HIGH_DELTA_W'($unsigned(positive_radix_count))) -
        $signed(HIGH_DELTA_W'($unsigned(negative_count)));

    // The carry-save representation can move a hidden radix carry between its
    // rows even when the canonical high digit is unchanged.  Absorb those
    // small +/- corrections in a four-bit signed digit (for K=8).  Crossing
    // its boundary retires +/-16 into acc_high, preserving
    // acc_high+high_debt while keeping the wide bank mostly idle.
    logic signed [DEBT_SUM_W-1:0] debt_total;
    logic signed [DEBT_W-1:0] next_high_debt;
    logic retire_debt_positive;
    logic retire_debt_negative;

    assign debt_total =
        $signed(DEBT_SUM_W'($signed(high_debt))) +
        $signed(DEBT_SUM_W'($signed(high_delta)));
    assign next_high_debt = DEBT_W'($signed(debt_total));
    assign retire_debt_positive =
        debt_total > $signed(DEBT_SUM_W'(DEBT_MAX));
    assign retire_debt_negative =
        debt_total < $signed(DEBT_SUM_W'(DEBT_MIN));

    // Canonicalize only at an architectural observation boundary.  In normal
    // array use mac_en is low before and throughout row-serial drain, so this
    // requires no extra cycle.  Operand isolation prevents the LOW_W-bit CPA
    // from switching during the repeated MAC workload.
    logic canonicalize;
    logic [LOW_W:0] canonical_low_sum;
    logic signed [HIGH_W-1:0] canonical_high;
    logic signed [HIGH_W-1:0] canonical_debt;

    assign acc_out_valid = shift_in || !mac_en;
    assign canonicalize = acc_out_valid;
    assign canonical_low_sum =
        {1'b0, acc_sum & {LOW_W{canonicalize}}} +
        {1'b0, acc_carry & {LOW_W{canonicalize}}};
    assign canonical_debt =
        HIGH_W'($signed(high_debt)) & {HIGH_W{canonicalize}};
    assign canonical_high =
        $signed(acc_high & {HIGH_W{canonicalize}}) +
        canonical_debt +
        HIGH_W'($unsigned(canonical_low_sum[LOW_W]));
    assign acc_out =
        canonicalize
            ? $signed({canonical_high, canonical_low_sum[LOW_W-1:0]})
            : '0;

    always_ff @(posedge clk) begin
        if (reset) begin
            acc_sum <= '0;
            acc_carry <= '0;
            acc_high <= '0;
            high_debt <= '0;
        end else if (shift_in) begin
            // acc_in is canonical.  Loading it into one row reestablishes the
            // redundant invariant without a flush or bubble.
            acc_sum <= acc_in[LOW_W-1:0];
            acc_carry <= '0;
            acc_high <= $signed(acc_in[OWIDTH-1:LOW_W]);
            high_debt <= '0;
        end else if (mac_en) begin
            acc_sum <= heap_row0[LOW_W-1:0];
            acc_carry <= heap_row1[LOW_W-1:0];
            high_debt <= next_high_debt;
            if (retire_debt_positive)
                acc_high <= acc_high + HIGH_W'(DEBT_RADIX);
            else if (retire_debt_negative)
                acc_high <= acc_high - HIGH_W'(DEBT_RADIX);
        end
    end
endmodule

`endif
