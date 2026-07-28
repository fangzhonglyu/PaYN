`ifndef BINARY_OS_ASYM
`define BINARY_OS_ASYM

`timescale 1ns/1ps

`include "baselines/binary_os/binary_os_array.sv"

`ifndef BOS_DEPTH_W
`define BOS_DEPTH_W 10
`endif

// Asymmetric (zero-point) correction for the binary output-stationary array.
//
// Same exact identity the BP variant uses, per output (h,v):
//
//   sum((qa-za)*(qw-zw)) = raw - zw*sum(qa) - za*sum(qw-zw)
//
//   raw            the plain array accumulator, sum of raw quantized products
//   sum(qa)        per-ROW activation sum, data-dependent -> accumulated on-array
//   sum(qw-zw)     per-COLUMN centered weight sum, a property of the weight
//                  matrix -> precomputed off-array exactly as in BP
//
// The output-stationary drain makes this cheaper than the BP arrangement.  BP
// produces all N_W columns in parallel and therefore replicates a full
// correction unit (two multipliers) per column: 2*N_W multipliers.  Here a drain
// step emits column v on every row rail at once, so the `za*sum(qw-zw)` term is
// a single scalar shared by all N_H rails and only `zw*sum(qa)` is per-rail:
// N_H + 1 multipliers.  At 8x8 that is 9 instead of 16.
//
// The host presents `wght_zp` and `centered_wsum` for the column currently being
// drained (step s emits column N_W-1-s), mirroring how BP presents per-column
// arrays to its parallel correctors.

// Per-row activation sum.  Unlike the BP version it does not have to chase a
// moving partial-sum wavefront, because in an output-stationary array the row
// sum is a scalar consumed once at drain time.
//
// Resetless by design, exactly like bp_asym_activation_sum_v2: the first slice
// of a block LOADS instead of accumulating, so one valid input cycle flushes all
// state.  BP can be resetless because its sum is a pipeline -- every register is
// fed from an input or a neighbour, so HEIGHT+WIDTH valid cycles overwrite
// everything.  A temporal accumulator cannot be flushed that way (X + known = X
// forever), so the load is what restores the same property here.  Without it the
// register would depend on a clear signal that the repo's flush idiom does not
// provide, and gate-level X would never wash out.
module BinaryOSActSum #(
    parameter int IWIDTH = 8,
    parameter int SUMA_WIDTH = 18
) (
    input  logic clk,
    input  logic sum_en,
    input  logic sum_load,
    input  logic signed [IWIDTH-1:0] a_in,
    output logic signed [SUMA_WIDTH-1:0] sum_a
);
    always_ff @(posedge clk) begin
        if (sum_load)     sum_a <= SUMA_WIDTH'(a_in);
        else if (sum_en)  sum_a <= sum_a + SUMA_WIDTH'(a_in);
    end
endmodule

// Correction for one drain rail.  `x_correction` is supplied already formed
// because it is shared across every rail; only the weight-zero-point product is
// local.  Operand isolation matches the BP corrector so the multiplier does not
// react while the drained value is invalid.
module BinaryOSAsymCorrect #(
    parameter int IWIDTH = 8,
    parameter int SUMA_WIDTH = 18,
    parameter int OWIDTH = 24
) (
    input  logic corr_en,
    input  logic signed [OWIDTH-1:0] raw_sum,
    input  logic signed [IWIDTH-1:0] wght_zp,
    input  logic signed [SUMA_WIDTH-1:0] sum_a,
    input  logic signed [OWIDTH-1:0] x_correction,
    output logic signed [OWIDTH-1:0] corrected_sum
);
    localparam int WPROD_WIDTH = IWIDTH + SUMA_WIDTH;

    logic signed [OWIDTH-1:0] raw_active;
    logic signed [IWIDTH-1:0] wght_zp_active;
    logic signed [SUMA_WIDTH-1:0] sum_a_active;
    logic signed [WPROD_WIDTH-1:0] w_correction;

    assign raw_active     = corr_en ? raw_sum : '0;
    assign wght_zp_active = corr_en ? wght_zp : '0;
    assign sum_a_active   = corr_en ? sum_a   : '0;
    assign w_correction   = wght_zp_active * sum_a_active;

    // The corrected value fits in OWIDTH by construction, so taking the low
    // OWIDTH bits of the wider product is exact (two's complement, mod 2**OWIDTH).
    assign corrected_sum = raw_active - OWIDTH'(w_correction) - x_correction;
endmodule

module binary_os_array_asym #(
    parameter int IWIDTH = `BOS_IWIDTH,
    parameter int N_H = `BOS_NH,
    parameter int N_W = `BOS_NW,
    parameter int OWIDTH = `BOS_OWIDTH,
    parameter int DEPTH_W = `BOS_DEPTH_W,
    parameter int SUMA_WIDTH = IWIDTH + DEPTH_W,
    parameter int WSUM_WIDTH = IWIDTH + 1 + DEPTH_W
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic sum_en,
    input  logic sum_load,
    input  logic corr_en,
    input  logic [N_H*IWIDTH-1:0] a_in,
    input  logic [N_W*IWIDTH-1:0] w_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    input  logic signed [IWIDTH-1:0] ifm_zp,
    input  logic signed [IWIDTH-1:0] wght_zp,        // column being drained
    input  logic signed [WSUM_WIDTH-1:0] centered_wsum,  // column being drained
    output logic [N_H*OWIDTH-1:0] ofm
);
    localparam int XPROD_WIDTH = IWIDTH + WSUM_WIDTH;

    logic [N_H*IWIDTH-1:0] a_out_nc;
    logic [N_W*IWIDTH-1:0] w_out_nc;
    logic [N_H*OWIDTH-1:0] raw_east;

    BinaryOSArrayFlat #(
        .IWIDTH(IWIDTH), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) u_array (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .a_in,
        .w_in,
        .a_out(a_out_nc),
        .w_out(w_out_nc),
        .acc_in_west,
        .acc_out_east(raw_east)
    );

    // Shared activation-zero-point term: identical on every rail at a given
    // drain step, so it is formed once instead of N_H times.
    // Both multiplicands must be named signed variables.  Inlining the
    // isolation ternary into the multiply would make the operand unsigned --
    // `'0` is unsigned, so `(corr_en ? ifm_zp : '0)` is an unsigned expression
    // and drags the whole multiply into unsigned context, silently corrupting
    // every negative centred weight sum.
    logic signed [IWIDTH-1:0] ifm_zp_active;
    logic signed [WSUM_WIDTH-1:0] centered_wsum_active;
    logic signed [XPROD_WIDTH-1:0] x_correction;
    logic signed [OWIDTH-1:0] x_correction_ow;

    assign ifm_zp_active = corr_en ? ifm_zp : '0;
    assign centered_wsum_active = corr_en ? centered_wsum : '0;
    assign x_correction = ifm_zp_active * centered_wsum_active;
    assign x_correction_ow = OWIDTH'(x_correction);

    for (genvar h = 0; h < N_H; h++) begin : g_rail
        logic signed [SUMA_WIDTH-1:0] sum_a;
        logic signed [OWIDTH-1:0] corrected;

        BinaryOSActSum #(
            .IWIDTH(IWIDTH), .SUMA_WIDTH(SUMA_WIDTH)
        ) u_asym_sum (
            .clk,
            .sum_en,
            .sum_load,
            .a_in($signed(a_in[h*IWIDTH +: IWIDTH])),
            .sum_a(sum_a)
        );

        BinaryOSAsymCorrect #(
            .IWIDTH(IWIDTH), .SUMA_WIDTH(SUMA_WIDTH), .OWIDTH(OWIDTH)
        ) u_asym_corr (
            .corr_en,
            .raw_sum($signed(raw_east[h*OWIDTH +: OWIDTH])),
            .wght_zp,
            .sum_a,
            .x_correction(x_correction_ow),
            .corrected_sum(corrected)
        );

        assign ofm[h*OWIDTH +: OWIDTH] = corrected;
    end
endmodule

`endif // BINARY_OS_ASYM
