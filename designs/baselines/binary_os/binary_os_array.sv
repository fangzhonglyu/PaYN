`ifndef BINARY_OS_ARRAY
`define BINARY_OS_ARRAY

`timescale 1ns/1ps

`include "baselines/binary_os/binary_os_pe.sv"

`ifndef BOS_IWIDTH
`define BOS_IWIDTH 8
`endif
`ifndef BOS_NH
`define BOS_NH 8
`endif
`ifndef BOS_NW
`define BOS_NW 8
`endif
`ifndef BOS_OWIDTH
`define BOS_OWIDTH 24
`endif
`ifndef BOS_DUAL_BOOTH
`define BOS_DUAL_BOOTH 1
`endif

// N_H x N_W output-stationary binary systolic array.
//
// A pure mesh: the only wires crossing a PE boundary are the west->east A hop,
// the north->south W hop, and the west->east accumulator drain chain.  No
// operand net is shared by more than two PEs, so there is no broadcast and no
// high-fanout operand bus.  A and W enter at the west and north edges and leave
// at the east and south edges, so arrays tile directly into a larger fabric.
//
// Operand skew is the caller's job (see BinaryOSPE): A slice t must enter row h
// at cycle t+h and W slice t must enter column v at cycle t+v.
//
// `mac_en` and `shift_in` are the one exception to "no broadcast", and they have
// to be: a row drains as a lockstep shift register, so every PE in the row must
// shift on the *same* cycle.  Pipelining the drain enable east would let PE v-1
// overwrite its accumulator one cycle before PE v reads it, destroying one value
// per hop.  These are single-bit control nets, not operand buses.
//
// Per cycle the array retires N_H*N_W signed IWIDTH MACs.  A drain costs N_W
// cycles and empties the array through N_H parallel OWIDTH rails, so a reduction
// of depth D runs at N_H*N_W*D/(D+N_W) useful MAC/cycle.
//
// INT4X2 = 1 (IWIDTH = 8) builds every PE with the dual INT8 / 2 x INT4
// multiplier (BinaryOSPE); `int4` selects the mode for the whole array and is a
// static control net like mac_en.  In INT4 mode each 8-bit lane carries two
// signed INT4 values, so the array retires 2*N_H*N_W MACs per cycle.
module BinaryOSArray #(
    parameter int IWIDTH = 8,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int INT4X2 = 0,
    parameter int DUAL_BOOTH = 1
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic int4,
    input  logic signed [IWIDTH-1:0] a_in  [N_H],
    input  logic signed [IWIDTH-1:0] w_in  [N_W],
    output logic signed [IWIDTH-1:0] a_out [N_H],
    output logic signed [IWIDTH-1:0] w_out [N_W],
    input  logic signed [OWIDTH-1:0] acc_in_west  [N_H],
    output logic signed [OWIDTH-1:0] acc_out_east [N_H]
);
    initial begin
        assert (N_H > 0) else $error("N_H must be positive");
        assert (N_W > 0) else $error("N_W must be positive");
    end

    // Mesh links.  a_link[h][v] feeds PE (h,v) from the west;
    // w_link[v][h] feeds PE (h,v) from the north.
    logic signed [IWIDTH-1:0] a_link [N_H][N_W+1];
    logic signed [IWIDTH-1:0] w_link [N_W][N_H+1];
    logic signed [OWIDTH-1:0] acc_link [N_H][N_W+1];

    for (genvar h = 0; h < N_H; h++) begin : g_row
        assign acc_link[h][0] = acc_in_west[h];
        assign acc_out_east[h] = acc_link[h][N_W];

        assign a_link[h][0] = a_in[h];
        assign a_out[h] = a_link[h][N_W];

        for (genvar v = 0; v < N_W; v++) begin : g_col
            BinaryOSPE #(
                .IWIDTH(IWIDTH),
                .OWIDTH(OWIDTH),
                .INT4X2(INT4X2),
                .DUAL_BOOTH(DUAL_BOOTH)
            ) u_pe (
                .clk,
                .reset,
                .shift_in,
                .mac_en,
                .int4,
                .a_in(a_link[h][v]),
                .a_out(a_link[h][v+1]),
                .w_in(w_link[v][h]),
                .w_out(w_link[v][h+1]),
                .acc_in(acc_link[h][v]),
                .acc_out(acc_link[h][v+1])
            );
        end
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_edge
        assign w_link[v][0] = w_in[v];
        assign w_out[v] = w_link[v][N_H];
    end
endmodule

// Flat-port wrapper for synthesis and gate-level benches, mirroring
// `InnerPESignedSegmentedFlat`.  Element 0 of every unpacked rail occupies the
// low bits of its bus.
module BinaryOSArrayFlat #(
    parameter int IWIDTH = 8,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int INT4X2 = 0,
    parameter int DUAL_BOOTH = 1
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic int4,
    input  logic [N_H*IWIDTH-1:0] a_in,
    input  logic [N_W*IWIDTH-1:0] w_in,
    output logic [N_H*IWIDTH-1:0] a_out,
    output logic [N_W*IWIDTH-1:0] w_out,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic signed [IWIDTH-1:0] a_in_array  [N_H];
    logic signed [IWIDTH-1:0] w_in_array  [N_W];
    logic signed [IWIDTH-1:0] a_out_array [N_H];
    logic signed [IWIDTH-1:0] w_out_array [N_W];
    logic signed [OWIDTH-1:0] acc_in_west_array  [N_H];
    logic signed [OWIDTH-1:0] acc_out_east_array [N_H];

    for (genvar h = 0; h < N_H; h++) begin : g_a_ports
        assign a_in_array[h] = $signed(a_in[h*IWIDTH +: IWIDTH]);
        assign a_out[h*IWIDTH +: IWIDTH] = a_out_array[h];
        assign acc_in_west_array[h] = $signed(acc_in_west[h*OWIDTH +: OWIDTH]);
        assign acc_out_east[h*OWIDTH +: OWIDTH] = acc_out_east_array[h];
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_ports
        assign w_in_array[v] = $signed(w_in[v*IWIDTH +: IWIDTH]);
        assign w_out[v*IWIDTH +: IWIDTH] = w_out_array[v];
    end

    BinaryOSArray #(
        .IWIDTH(IWIDTH), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .INT4X2(INT4X2), .DUAL_BOOTH(DUAL_BOOTH)
    ) u_array_core (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .int4,
        .a_in(a_in_array),
        .w_in(w_in_array),
        .a_out(a_out_array),
        .w_out(w_out_array),
        .acc_in_west(acc_in_west_array),
        .acc_out_east(acc_out_east_array)
    );
endmodule

// Synthesis top for the binary output-stationary array.
//
// The counterpart of `payn_array_signed_segmented` minus the stochastic front
// end: binary operands feed the PE mesh directly, so this top is the array and
// nothing else.
module binary_os_array #(
    parameter int IWIDTH = `BOS_IWIDTH,
    parameter int N_H = `BOS_NH,
    parameter int N_W = `BOS_NW,
    parameter int OWIDTH = `BOS_OWIDTH
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic [N_H*IWIDTH-1:0] a_in,
    input  logic [N_W*IWIDTH-1:0] w_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    // East/south forwarding rails are unused in the single-array top, exactly as
    // the PaYN array top leaves its operand pass-through unconnected.
    logic [N_H*IWIDTH-1:0] a_out_nc;
    logic [N_W*IWIDTH-1:0] w_out_nc;

    BinaryOSArrayFlat #(
        .IWIDTH(IWIDTH), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) u_array (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .int4(1'b0),
        .a_in,
        .w_in,
        .a_out(a_out_nc),
        .w_out(w_out_nc),
        .acc_in_west,
        .acc_out_east
    );
endmodule

// Synthesis top for the dual INT8 / INT4 binary output-stationary array: the
// binary_os_array mesh and ports with the INT4X2 PEs and one mode pin.
// int4_mode is registered here, so the PE-wide mode net hangs off one flop
// (reset to INT8); a mode change takes effect on the edge after the pin
// changes and is meant for an idle, drained array.  INT4 mode: each 8-bit lane
// carries two signed INT4 values (A {a1, a0}, W {w0, w1}: an A lane's high
// nibble pairs with the W lane's low nibble), 2 x N_H x N_W MACs per cycle, and
// the accumulators hold 16 x the INT4 dot product (BinaryOSPE).
module binary_os_array_int8_int4 #(
    parameter int N_H = `BOS_NH,
    parameter int N_W = `BOS_NW,
    parameter int OWIDTH = `BOS_OWIDTH,
    parameter int DUAL_BOOTH = `BOS_DUAL_BOOTH    // BinaryOSPE: 1 Booth radix-4 (default), 0 AND array
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic int4_mode,
    input  logic [N_H*8-1:0] a_in,
    input  logic [N_W*8-1:0] w_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic int4_q;
    logic [N_H*8-1:0] a_out_nc;
    logic [N_W*8-1:0] w_out_nc;

    always_ff @(posedge clk) begin
        if (reset) int4_q <= 1'b0;
        else       int4_q <= int4_mode;
    end

    BinaryOSArrayFlat #(
        .IWIDTH(8), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .INT4X2(1), .DUAL_BOOTH(DUAL_BOOTH)
    ) u_array (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .int4(int4_q),
        .a_in,
        .w_in,
        .a_out(a_out_nc),
        .w_out(w_out_nc),
        .acc_in_west,
        .acc_out_east
    );
endmodule

`endif // BINARY_OS_ARRAY
