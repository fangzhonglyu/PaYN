`ifndef PAYN_WDBI_BITDECODE_INNER_TILE
`define PAYN_WDBI_BITDECODE_INNER_TILE

// Reference W-DBI receiver.  The encoded W lanes are recovered bit-for-bit
// immediately before partial-product generation.  The separate numeric sign
// path is unchanged.
module InnerTileWDBIBitDecode #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int OWIDTH = 16
) (
    input  logic clk,
    input  logic reset,
    input  logic         a_signs [K],
    input  logic [M-1:0] a_bits  [K],
    input  logic         w_signs [K],
    input  logic [M-1:0] w_bits_encoded [K],
    input  logic         w_keep [K],
    input  logic shift_in,
    input  logic mac_en,
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
        logic [M-1:0] decoded_w;
        logic [M-1:0] products;
        logic [LANE_W-1:0] hit_count;
        logic signed [TERM_W-1:0] hit_mag;
        logic negate;

        assign decoded_w = w_bits_encoded[i] ~^ {M{w_keep[i]}};
        assign products = a_bits[i] & decoded_w;
        assign hit_count = LANE_W'($countones(products));
        assign hit_mag = $signed({1'b0, hit_count});
        assign negate = a_signs[i] ^ w_signs[i];
        assign lane_terms[i] = negate ? -hit_mag : hit_mag;
        assign heap_inputs[i*OWIDTH +: OWIDTH] =
            OWIDTH'($signed(lane_terms[i]));
    end

    logic [OWIDTH-1:0] heap_row0, heap_row1, acc_next;

    assign heap_inputs[K*OWIDTH +: OWIDTH] = acc_out;
    DW02_tree #(
        .num_inputs(K + 1),
        .input_width(OWIDTH),
        .verif_en(1)
    ) u_heap (
        .INPUT(heap_inputs),
        .OUT0(heap_row0),
        .OUT1(heap_row1)
    );

    assign acc_next = heap_row0 + heap_row1;

    always_ff @(posedge clk) begin
        if (reset)          acc_out <= '0;
        else if (shift_in)  acc_out <= acc_in;
        else if (mac_en)    acc_out <= acc_next;
    end
endmodule

`endif
