`ifndef _array_8_asym_corr_v2_
`define _array_8_asym_corr_v2_

`include "baselines/binary_parallel/array_8.sv"
`include "baselines/binary_parallel/asym_activation_sum_v2.sv"
`include "baselines/binary_parallel/asym_column_correction_v1.sv"

module array_8_asym_corr_v2 #(
    parameter int HEIGHT = 8,
    parameter int WIDTH = 8,
    parameter int IWIDTH = 8,
    parameter int OWIDTH = 24,
    parameter int SUMX_WIDTH = IWIDTH + $clog2(HEIGHT),
    parameter int WSUM_WIDTH = IWIDTH + $clog2(HEIGHT) + 1
) (
    input logic clk,
    input logic rst_n,
    input logic [HEIGHT-1:0] en_i,
    input logic [HEIGHT-1:0] clr_i,
    input logic [WIDTH-1:0] en_w,
    input logic [WIDTH-1:0] clr_w,
    input logic [WIDTH-1:0] en_o,
    input logic [WIDTH-1:0] clr_o,
    input logic sum_en,
    input logic corr_en,
    input logic signed [IWIDTH-1:0] ifm [HEIGHT-1:0],
    input logic signed [IWIDTH-1:0] wght [WIDTH-1:0],
    input logic signed [IWIDTH-1:0] ifm_zp,
    input logic signed [IWIDTH-1:0] wght_zp [WIDTH-1:0],
    input logic signed [WSUM_WIDTH-1:0] centered_wsum [WIDTH-1:0],
    output logic signed [OWIDTH-1:0] ofm [WIDTH-1:0]
);
    logic signed [OWIDTH-1:0] raw_ofm [WIDTH-1:0];
    logic signed [SUMX_WIDTH-1:0] sum_x [WIDTH-1:0];

    array_8 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(IWIDTH), .OWIDTH(OWIDTH)
    ) U_array (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o), .ifm(ifm), .wght(wght), .ofm(raw_ofm)
    );

    bp_asym_activation_sum_v2 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(IWIDTH), .SUM_WIDTH(SUMX_WIDTH)
    ) U_asym_sum (
        .clk(clk), .sum_en(sum_en), .ifm(ifm), .sum_x(sum_x)
    );

    genvar w;
    generate
        for (w = 0; w < WIDTH; w++) begin : G_ASYM_COL
            bp_asym_column_correction_v1 #(
                .IWIDTH(IWIDTH), .SUMX_WIDTH(SUMX_WIDTH),
                .WSUM_WIDTH(WSUM_WIDTH), .OWIDTH(OWIDTH)
            ) U_asym_corr (
                .corr_en(corr_en), .raw_sum(raw_ofm[w]),
                .ifm_zp(ifm_zp), .wght_zp(wght_zp[w]),
                .sum_x(sum_x[w]), .centered_wsum(centered_wsum[w]),
                .corrected_sum(ofm[w])
            );
        end
    endgenerate
endmodule

`endif
