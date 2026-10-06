`ifndef PAYN_BP_HYBRID_COMBINER
`define PAYN_BP_HYBRID_COMBINER

`timescale 1ns/1ps

// PROPOSED east-edge combine for the BP-hybrid schedule H(TA,TW) on the
// unchanged csa_bp_20261004_lap PE (sweeps/int_mode/bp/model_lap_schedules.py,
// designs/payn/tb/test_pe_grid_bp_hybrid.sv).  NOT part of any synthesized or
// routed design: the single-PE hybrid bench (designs/payn/tb/
// test_payn_array_bp_hybrid.sv) instantiates it as a sidecar on the top's
// acc_out_east port to check that the combine is right; its area in the model
// is a cell-count placeholder until it is synthesized.
//
// In H, tile row h holds activation row il = h / GA and activation-bit group
// g = h % GA (bits g*TA .. g*TA+TA-1, TA*GA = BA).  After the drain each column
// gives, per activation row,
//
//     out[il] = sum_{g < GA} 2^(g*TA) * T(il*GA + g),     il < 8/GA
//
// GA = 8 (TA = 1) is the as-built INT8 combine (sum_h 2^h T(h)); GA = 4 with
// TA = 1 is the as-built INT4 one (two 4-plane halves); GA = 4 / TA = 2, GA = 2
// (TA = 4 for INT8 H(4,8), TA = 2 for INT4 H(2,4)) and GA = 1 (TA = BA: tile =
// full product, W4A8 H(8,4), INT4 H(4,4), INT8 H(8,8)) are new.  One 3-level
// tree with selectable level shifts serves all of them:
//
//     l1[p] = T(2p)  + T(2p+1) << TA          (GA >= 2; TA in {1,2,4})
//     l2[q] = l1[2q] + l1[2q+1] << 2*TA       (GA >= 4; TA in {1,2})
//     l3    = l2[0]  + l2[1]    << 4          (GA = 8;  TA = 1)
//
// and out word il takes T(il), l1[il], l2[il] or l3 for GA = 1, 2, 4, 8.  A
// schedule with TW < BW (weight-bit groups across columns, e.g. INT8 H(4,4))
// additionally needs the column Horner R <- (R << TW) + out[il] over its GW
// drained columns (as T2 does); not included here.
//
// Range: every word is exact mod 2^OUT_W; with OUT_W = 32 every true output of
// a tile set the 24-bit tiles allow fits (|T| < 2^23, shifts <= 7).
// Timing as PaynBpCombiner: capture samples the column (and the config) on the
// drain edge, out / out_valid appear two edges later.
module PaynBpHybridCombiner #(
    parameter int N_H = 8,
    parameter int OWIDTH = 24,
    parameter int OUT_W = 32
) (
    input  logic clk,
    input  logic reset,
    input  logic capture,
    input  logic [1:0] ga_log2,              // GA = 1 << ga_log2  (tile rows per activation row)
    input  logic [1:0] ta_log2,              // TA = 1 << ta_log2  (activation bits in time)
    input  logic [N_H*OWIDTH-1:0] acc_east,
    output logic [N_H*OUT_W-1:0] out,        // word il = out[il*OUT_W +: OUT_W], il < 8/GA, others 0
    output logic out_valid
);
    initial begin
        assert (N_H == 8) else $fatal(1, "PaynBpHybridCombiner is defined for N_H = 8 (got %0d)", N_H);
        assert (OUT_W >= OWIDTH + 7) else $fatal(1, "OUT_W (%0d) must hold a tile shifted by 7", OUT_W);
    end

    logic [N_H*OWIDTH-1:0] east_q;
    logic [1:0] ga_q, ta_q;
    logic capture_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            capture_q <= 1'b0;
            ga_q <= '0;
            ta_q <= '0;
        end else begin
            capture_q <= capture;
            if (capture) begin
                ga_q <= ga_log2;
                ta_q <= ta_log2;
            end
        end
    end

    always_ff @(posedge clk)
        if (capture || reset)
            east_q <= acc_east;

    logic [OUT_W-1:0] t [N_H];
    logic [OUT_W-1:0] l1 [4];
    logic [OUT_W-1:0] l2 [2];
    logic [OUT_W-1:0] l3;
    logic [N_H*OUT_W-1:0] out_next;

    for (genvar h = 0; h < N_H; h++) begin : g_ext
        assign t[h] = {{(OUT_W-OWIDTH){east_q[h*OWIDTH + OWIDTH-1]}}, east_q[h*OWIDTH +: OWIDTH]};
    end

    always_comb begin
        for (int p = 0; p < 4; p++)
            case (ta_q)
                2'd0:    l1[p] = t[2*p] + (t[2*p+1] << 1);
                2'd1:    l1[p] = t[2*p] + (t[2*p+1] << 2);
                default: l1[p] = t[2*p] + (t[2*p+1] << 4);
            endcase
        for (int q = 0; q < 2; q++)
            l2[q] = l1[2*q] + ((ta_q == 2'd0) ? (l1[2*q+1] << 2) : (l1[2*q+1] << 4));
        l3 = l2[0] + (l2[1] << 4);
        out_next = '0;
        case (ga_q)
            2'd0: for (int h = 0; h < 8; h++) out_next[h*OUT_W +: OUT_W] = t[h];
            2'd1: for (int p = 0; p < 4; p++) out_next[p*OUT_W +: OUT_W] = l1[p];
            2'd2: for (int q = 0; q < 2; q++) out_next[q*OUT_W +: OUT_W] = l2[q];
            default: out_next[0 +: OUT_W] = l3;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            out <= '0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= capture_q;
            if (capture_q)
                out <= out_next;
        end
    end
endmodule

`endif
