`ifndef ASTRAEA_SC_INNER_TILE
`define ASTRAEA_SC_INNER_TILE

`include "payn/inner_tile_comb.sv"

module InnerTile #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int OWIDTH = 16
) (
    input  logic clk,
    input  logic reset,

    // Pipeline Inputs
    input  logic         a_signs [K],
    input  logic [M-1:0] a_bits  [K],
    input  logic         w_signs [K],
    input  logic [M-1:0] w_bits  [K],

    input  logic shift_in,
    input  logic mac_en,
    input  logic signed [OWIDTH-1:0] acc_in,
    output logic signed [OWIDTH-1:0] acc_out
);

    logic signed [OWIDTH-1:0] acc_next;

    InnerTileComb #(
        .K(K),
        .M(M),
        .OWIDTH(OWIDTH)
    ) u_comb (
        .a_signs,
        .a_bits,
        .w_signs,
        .w_bits,
        .acc_in(acc_out),
        .acc_out(acc_next)
    );

    always_ff @(posedge clk) begin
        if (reset)          acc_out <= '0;
        else if (shift_in)  acc_out <= acc_in;
        else if (mac_en)    acc_out <= acc_next;
    end
    
endmodule

`endif // ASTRAEA_SC_INNER_TILE
