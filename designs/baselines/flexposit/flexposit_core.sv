`ifndef FLEXPOSIT_CORE_SV
`define FLEXPOSIT_CORE_SV
`timescale 1ns/1ps

// FlexPosit core (designs/baselines/flexposit): the N x N bit-serial Posit x FP8 output-stationary array of
// FlexPosit (Gao et al., MICRO 2026; github.com/hplp/FlexPosit, commit e42a219) behind flat packed ports.
//
// The DUT is the RTL module `systolic` unchanged: per-column SerialPosit decoders with their beat FIFOs, the N x N
// PE mesh (pe_pipe + bit-serial shift-add multiplier + block-floating accumulator per PE), the cycle generator
// (the paper's GPCU), and the per-column readout (row mux, normalize, power-of-two rescale, FP16).  The input
// FIFOs of the upstream top `mm` (fifo.v, act_fifo.v) are operand buffers, not compute, and stay in the bench:
// the same boundary as the BOS mesh, whose operands also arrive at the array edge.
//
// This wrapper only flattens the unpacked array ports of `systolic` so the netlist ports are plain vectors.
//
//   act_in[i*8 +: 8]        FP8 E4M3 activation of row i (from that row's activation FIFO)
//   act_valid_in[i]         that activation is fresh (act_fifo act_out_valid)
//   w_in[j]                 serialized SerialPosit weight bit of column j (from that column's 1-bit FIFO)
//   col_scale[j*5 +: 5]     signed power-of-two exponent of output column j
//   out_data[j*16 +: 16]    FP16 lane j of the row named by out_row, valid with out_valid
//   active_row[i]           FIFO read demand of row i
//   active_column[j]        FIFO read demand of column j = 1..N-1.  Column 0's demand is `active` itself
//                           (systolic_efficient.v: active_column[0] = active), so it is not a port: a port-to-port
//                           feedthrough leaves an SDF INTERCONNECT between two top-level ports that the routed-GL
//                           audit rejects (SDFCOM_SWC / SDFCOM_OMBPWOI).  The bench drives column 0 from `active`.
//
// rst_n is the active-low asynchronous reset of `systolic` (its port `rst`).

`include "baselines/flexposit/rtl/fp8_pe_mac_stream.v"
`include "baselines/flexposit/rtl/posit_decode_and_queue.v"
`include "baselines/flexposit/rtl/bfp_normalize.v"
`include "baselines/flexposit/rtl/bfp_pow2_rescale.v"
`include "baselines/flexposit/rtl/bfp_to_fp16.v"
`include "baselines/flexposit/rtl/systolic_efficient.v"

`ifndef FLEXPOSIT_N
`define FLEXPOSIT_N 8
`endif

module flexposit_core #(
    parameter integer N       = `FLEXPOSIT_N,
    parameter integer K_WIDTH = 16
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    stall,
    input  logic                    active,
    input  logic [K_WIDTH-1:0]      k_reg,
    input  logic [3:0]              precision,
    input  logic [1:0]              posit_es,
    input  logic [N*5-1:0]          col_scale,
    input  logic [N*8-1:0]          act_in,
    input  logic [N-1:0]            act_valid_in,
    input  logic [N-1:0]            w_in,
    input  logic                    out_ready,
    output logic                    done,
    output logic                    compute_done,
    output logic                    out_valid,
    output logic [$clog2(N)-1:0]    out_row,
    output logic [N*16-1:0]         out_data,
    output logic [N-1:0]            active_row,
    output logic [N-1:1]            active_column
);
    wire signed [4:0] col_scale_u [N-1:0];
    wire        [7:0] act_in_u    [N-1:0];
    wire              w_in_u      [N-1:0];

    wire        [N-1:0] active_column_all;
    assign active_column = active_column_all[N-1:1];

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_unpack
            assign col_scale_u[g] = col_scale[g*5 +: 5];
            assign act_in_u[g]    = act_in[g*8 +: 8];
            assign w_in_u[g]      = w_in[g];
        end
    endgenerate

    systolic #(
        .N       (N),
        .K_WIDTH (K_WIDTH)
    ) u_systolic (
        .clk              (clk),
        .rst              (rst_n),
        .stall            (stall),
        .active           (active),
        .k_reg_in         (k_reg),
        .precision        (precision),
        .posit_es         (posit_es),
        .col_scale        (col_scale_u),
        .act_in           (act_in_u),
        .act_valid_in     (act_valid_in),
        .w_in             (w_in_u),
        .done             (done),
        .compute_done_out (compute_done),
        .out_valid        (out_valid),
        .out_ready        (out_ready),
        .out_row          (out_row),
        .out_data         (out_data),
        .active_row       (active_row),
        .active_column    (active_column_all)
    );
endmodule

`endif
