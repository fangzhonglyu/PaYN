`ifndef PAYN_INNER_TILE_COMB
`define PAYN_INNER_TILE_COMB

// Purely combinational arithmetic cone extracted from one PaYN InnerTile.
// One evaluation adds K signed stochastic-popcount lane contributions to the
// incoming output-stationary accumulator.  There are no inferred latches or
// registers in this module.
module InnerTileComb #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int OWIDTH = 16
) (
    input  logic         a_signs [K],
    input  logic [M-1:0] a_bits  [K],
    input  logic         w_signs [K],
    input  logic [M-1:0] w_bits  [K],
    input  logic signed [OWIDTH-1:0] acc_in,
    output logic signed [OWIDTH-1:0] acc_out
);
    localparam int LANE_W = $clog2(M + 1);
    localparam int TERM_W = LANE_W + 1;
    localparam int CONTRIB_W = $clog2(K*M + 1) + 1;

    initial begin
        assert (K > 0) else $error("K must be positive");
        assert (M > 0) else $error("M must be positive");
        assert (OWIDTH >= CONTRIB_W)
            else $error("OWIDTH is too small for one exact contribution");
    end

    logic signed [TERM_W-1:0] lane_terms [K];
    logic [(K+1)*OWIDTH-1:0] heap_inputs;

    for (genvar i = 0; i < K; i++) begin : g_lanes
        logic [M-1:0] products;
        logic [LANE_W-1:0] hit_count;
        logic signed [TERM_W-1:0] hit_mag;
        logic negate;

        assign products = a_bits[i] & w_bits[i];
        assign hit_count = LANE_W'($countones(products));
        assign hit_mag = $signed({1'b0, hit_count});
        assign negate = a_signs[i] ^ w_signs[i];
        assign lane_terms[i] = negate ? -hit_mag : hit_mag;
        assign heap_inputs[i*OWIDTH +: OWIDTH] =
            OWIDTH'($signed(lane_terms[i]));
    end

    assign heap_inputs[K*OWIDTH +: OWIDTH] = acc_in;

    logic [OWIDTH-1:0] heap_row0;
    logic [OWIDTH-1:0] heap_row1;

    DW02_tree #(
        .num_inputs(K + 1),
        .input_width(OWIDTH),
        .verif_en(1)
    ) u_heap (
        .INPUT(heap_inputs),
        .OUT0(heap_row0),
        .OUT1(heap_row1)
    );

    assign acc_out = heap_row0 + heap_row1;
endmodule

// Flat, fixed-shape physical-analysis top.  clk/reset are intentionally unused
// compatibility ports: ASTRAEA constrains clk during synthesis and ROC_flow
// recognizes both as non-data inputs.  The synthesized data cone is entirely
// combinational.
module payn_inner_tile_comb (
    input  logic clk,
    input  logic reset,
    input  logic [5:0]  a_signs,
    input  logic [95:0] a_bits,
    input  logic [5:0]  w_signs,
    input  logic [95:0] w_bits,
    input  logic signed [23:0] acc_in,
    output logic signed [23:0] acc_out
);
    localparam int K = 6;
    localparam int M = 16;
    localparam int OWIDTH = 24;

    logic         a_signs_array [K];
    logic [M-1:0] a_bits_array  [K];
    logic         w_signs_array [K];
    logic [M-1:0] w_bits_array  [K];

    for (genvar i = 0; i < K; i++) begin : g_flatten
        assign a_signs_array[i] = a_signs[i];
        assign a_bits_array[i] = a_bits[i*M +: M];
        assign w_signs_array[i] = w_signs[i];
        assign w_bits_array[i] = w_bits[i*M +: M];
    end

    InnerTileComb #(
        .K(K),
        .M(M),
        .OWIDTH(OWIDTH)
    ) u_comb (
        .a_signs(a_signs_array),
        .a_bits(a_bits_array),
        .w_signs(w_signs_array),
        .w_bits(w_bits_array),
        .acc_in,
        .acc_out
    );
endmodule

`endif // PAYN_INNER_TILE_COMB
