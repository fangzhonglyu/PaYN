// [CBSG-AF-IPD COPY] of designs/payn/variants/signed_segmented_csa_bp/bp_combiner.sv (sha256 in README.md / copied_from.sha256), module names suffixed AfIpd.
// [CBSG-AF-IPD COPY] Rename only: sweeps/cbsg/af_ipd/check_copies.sh shows no other difference.
`ifndef PAYN_CBSG_AF_IPD_BP_COMBINER
`define PAYN_CBSG_AF_IPD_BP_COMBINER

`timescale 1ns/1ps

// East-edge plane combiner for bit-plane (BP) INT mode.
//
// Tile row h carries activation plane h, so after the last weight pass the
// drain delivers, per column, T(h) = sigma_h * sum_kk a_h[kk] * W[kk, j] on
// acc_east[h] (sigma = -1 for the MSB plane, applied by the tile's sign path).
// The output is the shift-add over rows:
//
//     int_prec = 0 (INT8, W4A8):  out[0] = sum_{h < N_H} 2^h T(h),   out[1] = 0
//     int_prec = 1 (INT4):        out[0] = sum_{h < G}   2^h     T(h)
//                                 out[1] = sum_{h >= G}  2^(h-G) T(h),  G = N_H/2
//
// Both precisions share the two half-trees: the INT8 sum is the low half plus
// the high half shifted by G.  The BP INT mapping is defined for N_H = 8 (8
// planes, or two 4-plane INT4 rows); other N_H elaborate, so the BP top stays
// an SC drop-in at any shape, but INT mode is not defined there.
//
// Range: arithmetic is mod 2^OUT_W.  Every row term fits (the check below),
// and every true output fits OUT_W = 32: |out| <= 2^(BA-1) * 2^(BW-1) * L
// <= 2^14 * L < 2^30 for any L the 24-bit tiles allow (INT8 L <= 65,535).
// Arbitrary 24-bit tiles can reach 255 * 2^23 < 2^31, which also fits.
//
// capture samples the east column on each drain edge, before it shifts, and
// int_prec with it, so each word uses the precision in force on its drain edge
// and the static mode input never sits on the adder carry chain.  The input
// register loads only on capture, so SC drains never toggle the tree.
// Latency: out / out_valid appear two edges after the capture edge.
//
// Reset: out, out_valid, capture_q and prec_q reset synchronously, so the
// outputs are known and silent in SC mode.  The 192-bit input register has no
// reset term (a gate per bit and 192 reset endpoints saved): it simply loads
// on reset edges too, and since the tiles clear on the first reset edge, any
// reset of two or more edges leaves it zero.  After a one-edge reset it may
// hold the pre-reset column, which is never observable: out only loads on
// capture_q, and every capture reloads the register first.
module PaynBpCombinerAfIpd #(
    parameter int N_H = 8,
    parameter int OWIDTH = 24,
    parameter int OUT_W = 32
) (
    input  logic clk,
    input  logic reset,
    input  logic capture,
    input  logic int_prec,
    input  logic [N_H*OWIDTH-1:0] acc_east,
    output logic [2*OUT_W-1:0] out,
    output logic out_valid
);
    localparam int G = N_H / 2;

    initial begin
        assert (N_H >= 2)
            else $fatal(1, "N_H (%0d) must be at least 2", N_H);
        assert (OUT_W >= OWIDTH + N_H - 1)
            else $fatal(1, "OUT_W (%0d) must hold a %0d-bit tile shifted by %0d",
                        OUT_W, OWIDTH, N_H - 1);
    end

    logic [N_H*OWIDTH-1:0] east_q;
    logic prec_q;
    logic capture_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            prec_q <= 1'b0;
            capture_q <= 1'b0;
        end else begin
            capture_q <= capture;
            if (capture)
                prec_q <= int_prec;
        end
    end

    always_ff @(posedge clk)
        if (capture || reset)
            east_q <= acc_east;

    // Two half-trees of sign-extended, row-weighted tile values.
    logic [OUT_W-1:0] tile_ext [N_H];
    logic [OUT_W-1:0] sum_lo, sum_hi;
    logic [OUT_W-1:0] out_lo_next, out_hi_next;

    for (genvar h = 0; h < N_H; h++) begin : g_extend
        assign tile_ext[h] = {{(OUT_W-OWIDTH){east_q[h*OWIDTH + OWIDTH-1]}},
                              east_q[h*OWIDTH +: OWIDTH]};
    end

    always_comb begin
        sum_lo = '0;
        sum_hi = '0;
        for (int h = 0; h < G; h++)
            sum_lo += tile_ext[h] << h;
        for (int h = G; h < N_H; h++)
            sum_hi += tile_ext[h] << (h - G);
    end

    assign out_lo_next = sum_lo + (prec_q ? '0 : (sum_hi << G));
    assign out_hi_next = prec_q ? sum_hi : '0;

    always_ff @(posedge clk) begin
        if (reset) begin
            out <= '0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= capture_q;
            if (capture_q)
                out <= {out_hi_next, out_lo_next};
        end
    end
endmodule

`endif
