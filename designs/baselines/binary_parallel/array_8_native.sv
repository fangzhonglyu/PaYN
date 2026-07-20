`ifndef _array_8_native_
`define _array_8_native_

// Native narrow-datapath binary-parallel arrays: thin wrappers that fix
// array_8's IWIDTH parameter to 7 or 6, so synth/PnR/power target genuinely
// narrower INT7/INT6 hardware (not just narrowed 8-bit stimulus).

`include "baselines/binary_parallel/array_8.sv"

module array_8_int7 #(
    parameter HEIGHT = 8,
    parameter WIDTH  = 8,
    parameter OWIDTH = 24
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [HEIGHT-1:0] en_i, clr_i,
    input  logic [WIDTH-1:0]  en_w, clr_w, en_o, clr_o,
    input  logic signed [6:0] ifm  [HEIGHT-1:0],
    input  logic signed [6:0] wght [WIDTH-1:0],
    output logic signed [OWIDTH-1:0] ofm [WIDTH-1:0]
);
    array_8 #(.HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(7), .OWIDTH(OWIDTH)) u (
        .clk, .rst_n, .en_i, .clr_i, .en_w, .clr_w, .en_o, .clr_o, .ifm, .wght, .ofm);
endmodule

module array_8_int6 #(
    parameter HEIGHT = 8,
    parameter WIDTH  = 8,
    parameter OWIDTH = 24
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [HEIGHT-1:0] en_i, clr_i,
    input  logic [WIDTH-1:0]  en_w, clr_w, en_o, clr_o,
    input  logic signed [5:0] ifm  [HEIGHT-1:0],
    input  logic signed [5:0] wght [WIDTH-1:0],
    output logic signed [OWIDTH-1:0] ofm [WIDTH-1:0]
);
    array_8 #(.HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(6), .OWIDTH(OWIDTH)) u (
        .clk, .rst_n, .en_i, .clr_i, .en_w, .clr_w, .en_o, .clr_o, .ifm, .wght, .ofm);
endmodule

`endif
