`ifndef BINARY_OS_ARRAY_NATIVE
`define BINARY_OS_ARRAY_NATIVE

`include "baselines/binary_os/binary_os_array.sv"

// Native signed narrow-operand OS arrays. The fixed port widths and IWIDTH
// bindings narrow the multiplier and both operand-hop registers. Accumulators
// and drain rails retain OWIDTH bits; the default mesh remains 8 x 8.

module binary_os_array_int6 #(
    parameter int N_H = `BOS_NH,
    parameter int N_W = `BOS_NW,
    parameter int OWIDTH = `BOS_OWIDTH
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic [N_H*6-1:0] a_in,
    input  logic [N_W*6-1:0] w_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic [N_H*6-1:0] a_out_nc;
    logic [N_W*6-1:0] w_out_nc;

    BinaryOSArrayFlat #(
        .IWIDTH(6), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) u_array (
        .clk, .reset, .mac_en, .shift_in,
        .a_in, .w_in, .a_out(a_out_nc), .w_out(w_out_nc),
        .acc_in_west, .acc_out_east
    );
endmodule

module binary_os_array_int4 #(
    parameter int N_H = `BOS_NH,
    parameter int N_W = `BOS_NW,
    parameter int OWIDTH = `BOS_OWIDTH
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic [N_H*4-1:0] a_in,
    input  logic [N_W*4-1:0] w_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic [N_H*4-1:0] a_out_nc;
    logic [N_W*4-1:0] w_out_nc;

    BinaryOSArrayFlat #(
        .IWIDTH(4), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) u_array (
        .clk, .reset, .mac_en, .shift_in,
        .a_in, .w_in, .a_out(a_out_nc), .w_out(w_out_nc),
        .acc_in_west, .acc_out_east
    );
endmodule

`endif // BINARY_OS_ARRAY_NATIVE
