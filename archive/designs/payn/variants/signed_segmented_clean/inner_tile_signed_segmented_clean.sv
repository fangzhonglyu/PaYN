`ifndef PAYN_SIGNED_SEGMENTED_CLEAN_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_CLEAN_INNER_TILE

// Exact signed segmented accumulator for one PaYN inner tile.
//
// The true signed K-lane contribution is added only to a LOW_W-bit residue.  A
// carry/borrow across the 2**LOW_W boundary is encoded as a one-cycle pending
// event and retired into the upper accumulator on the following clock.
//
// Difference from `signed_segmented`: the retire and the externally visible high
// segment share ONE adder instead of an independent +1 chain, an independent -1
// chain and two 3-way select banks.  Adding an all-ones addend is -1, the
// carry-in is +1, and neither is +0, so the three cases fall out of a single
// HIGH_W ripple whose output feeds both `acc_out` and the `acc_high` D input.
// The state encoding, port list and observable behaviour are unchanged.
module InnerTileSignedSegmentedClean #(
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

    // A violated bound silently corrupts every accumulation rather than failing
    // visibly, so these are fatal at elaboration.
    initial begin
        assert (K > 0 && M > 0 && LOW_W > 0)
            else $fatal(1, "K, M and LOW_W must be positive");
        assert (OWIDTH > LOW_W)
            else $fatal(1, "OWIDTH (%0d) must exceed LOW_W (%0d)", OWIDTH, LOW_W);
        // One cycle contributes at most +-K*M, so a residue in [0, RADIX-1]
        // can cross the boundary at most once, in one direction.
        assert (RADIX >= K*M)
            else $fatal(1, "2**LOW_W (%0d) must be at least K*M (%0d)",
                        RADIX, K*M);
    end

    //---------------------------------------------------------------- lanes --
    logic [(K+1)*SUM_W-1:0] heap_inputs;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic [LANE_W-1:0] hit_count;
        logic signed [TERM_W-1:0] hit_magnitude;
        logic signed [TERM_W-1:0] lane_term;
        logic negate;

        assign products = a_bits[i] & w_bits[i];
        assign hit_count = LANE_W'($countones(products));
        assign hit_magnitude = $signed({1'b0, hit_count});
        assign negate = a_signs[i] ^ w_signs[i];
        assign lane_term = negate ? -hit_magnitude : hit_magnitude;
        assign heap_inputs[i*SUM_W +: SUM_W] = SUM_W'($signed(lane_term));
    end

    logic [LOW_W-1:0]  acc_low;
    logic [HIGH_W-1:0] acc_high;
    logic pending_carry;
    logic pending_borrow;

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
    // low_sum spans [-K*M, 2**(LOW_W+1)-1].  Negative is exactly one borrow;
    // non-negative with bit LOW_W set is exactly one carry.  Never both.
    assign next_borrow = low_sum[SUM_W-1];
    assign next_carry  = !low_sum[SUM_W-1] && low_sum[LOW_W];

    //-------------------------------------------------- upper segment (+-1) --
    // The one shared adder.  Its result is the retired value AND the visible
    // high segment, so including the not-yet-retired event in `acc_out` costs
    // nothing: the drain relies on that, because shift_in may assert on the
    // clock immediately after the last MAC with an event still outstanding.
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
            // Retire the previous cycle's event.  The conditional assignment
            // permits a clock gate on the comparatively wide upper bank.
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
    // The shared adder folds both-set to a hold, which would silently drop an
    // event.  next_carry/next_borrow make that unreachable; check it anyway.
    // Case-compare so the pre-reset X state is not itself a failure.
    always_ff @(posedge clk)
        assert (!(pending_carry === 1'b1 && pending_borrow === 1'b1))
            else $fatal(1, "pending_carry and pending_borrow both set");
`endif
endmodule

`endif
