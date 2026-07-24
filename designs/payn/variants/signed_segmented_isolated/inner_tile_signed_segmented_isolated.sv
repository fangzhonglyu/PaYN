`ifndef PAYN_SIGNED_SEGMENTED_ISOLATED_INNER_TILE
`define PAYN_SIGNED_SEGMENTED_ISOLATED_INNER_TILE

// Keep the clamp as a small, explicit physical boundary.  Without a preserved
// instance, whole-PE optimization can prove it logically redundant because the
// receiving tile selects acc_in only while enable is already high.
module AccChainIsolationSignedSegmented #(
    parameter int WIDTH = 24
) (
    input  logic signed [WIDTH-1:0] data_in,
    input  logic                    enable,
    output wire signed [WIDTH-1:0]  data_out
);
    assign data_out = data_in & {WIDTH{enable}};
endmodule

// Exact signed segmented accumulator with a drain-only chain output.
//
// The accumulator state and pending carry/borrow recurrence are identical to
// InnerTileSignedSegmented.  During normal MAC operation, acc_out is clamped
// locally to zero because the east neighbor does not consume acc_in.  When
// shift_in is asserted, the canonical accumulator is exposed before the clock
// edge so the existing row-serial shift protocol is preserved.
module InnerTileSignedSegmentedIsolated #(
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
    assign next_borrow = low_sum[SUM_W-1];
    assign next_carry =
        !low_sum[SUM_W-1] && low_sum[LOW_W];

    // Include the pipelined boundary event in the canonical high segment.
    logic [HIGH_W-1:0] visible_high;
    always_comb begin
        visible_high = acc_high;
        if (pending_carry)
            visible_high = acc_high + HIGH_W'(1);
        else if (pending_borrow)
            visible_high = acc_high - HIGH_W'(1);
    end

    logic signed [OWIDTH-1:0] canonical_acc;
    assign canonical_acc = $signed({visible_high, acc_low});

    // Source-side isolation: the long east-west chain is quiet throughout
    // compute, then becomes transparent for the complete drain interval.
    // Only this small boundary instance is protected from optimization; the
    // accumulator and the enclosing tile remain free to flatten and optimize.
    (* dont_touch = "true", keep_hierarchy = "yes" *)
    AccChainIsolationSignedSegmented #(
        .WIDTH(OWIDTH)
    ) u_acc_chain_isolation (
        .data_in(canonical_acc),
        .enable(shift_in),
        .data_out(acc_out)
    );

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
