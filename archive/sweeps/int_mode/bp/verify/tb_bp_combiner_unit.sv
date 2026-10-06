`timescale 1ns/1ps

// Unit test of PaynBpCombiner (designs/payn/variants/signed_segmented_csa_bp/
// bp_combiner.sv) with ARBITRARY 24-bit tile values, not only values a GEMM
// can reach: every row independently uniform, or pinned to -2^23 / 2^23-1 /
// -1 / 0, so the 32-bit range claim is tested at its worst case
// (|sum_h 2^h T(h)| <= 255 * 2^23 < 2^31).  Captures arrive in random bursts
// (back-to-back, gaps), int_prec toggles randomly every edge (the word must use
// the value sampled with the capture), acc_east toggles on non-capture edges,
// and reset is asserted at random, including on capture edges and inside the
// 2-edge latency.  Reference: exact longint sum, no modular arithmetic; a
// word is correct only if it equals the TRUE sum as signed 32-bit.
// Inputs launched at the negedge, outputs sampled at the negedge (race-free).

`include "payn/variants/signed_segmented_csa_bp/bp_combiner.sv"

module TbBpCombinerUnit;
    localparam int N_H = 8, OWIDTH = 24, OUT_W = 32, G = N_H / 2;
    localparam int N_CYC = 200000;

    logic clk = 1'b0;
    always #1.25 clk = ~clk;

    logic reset = 1'b1, capture = 1'b0, int_prec = 1'b0;
    logic [N_H*OWIDTH-1:0] acc_east = '0;
    logic [2*OUT_W-1:0] out;
    logic out_valid;

    PaynBpCombiner #(.N_H(N_H), .OWIDTH(OWIDTH), .OUT_W(OUT_W)) dut (.*);

    // Expected words in flight: stage 0 = captured on the last edge, stage 1 = emitted next.
    longint exp_lo [2], exp_hi [2];
    bit     exp_v  [2];
    longint lo, hi, t;
    int errors = 0, n_words = 0, n_extreme = 0, mode;

    function automatic longint tile(input logic [N_H*OWIDTH-1:0] v, input int h);
        return longint'($signed(v[h*OWIDTH +: OWIDTH]));
    endfunction

    initial begin
        exp_v = '{0, 0};
        for (int n = 0; n < N_CYC; n++) begin
            @(negedge clk);
            // ---- check the state after the previous edge
            if (n > 2) begin
                if ($isunknown(out_valid) || out_valid !== exp_v[1]) begin
                    errors++;
                    if (errors < 10) $display("[ERR] n=%0d out_valid=%b expected %0b", n, out_valid, exp_v[1]);
                end else if (exp_v[1]) begin
                    n_words++;
                    if ($signed(out[OUT_W-1:0]) != exp_lo[1] || $signed(out[2*OUT_W-1:OUT_W]) != exp_hi[1]) begin
                        errors++;
                        if (errors < 10)
                            $display("[ERR] n=%0d out lo=%0d hi=%0d expected lo=%0d hi=%0d", n,
                                     $signed(out[OUT_W-1:0]), $signed(out[2*OUT_W-1:OUT_W]), exp_lo[1], exp_hi[1]);
                    end
                end
            end
            // ---- launch the next edge's inputs
            reset = (n < 3) || ($urandom % 97 == 0);
            capture = ($urandom % 3 != 0);
            int_prec = $urandom;
            mode = $urandom % 8;
            for (int h = 0; h < N_H; h++) begin
                case (mode)
                    0: acc_east[h*OWIDTH +: OWIDTH] = 24'h800000;                 // all -2^23
                    1: acc_east[h*OWIDTH +: OWIDTH] = 24'h7fffff;                 // all 2^23-1
                    2: acc_east[h*OWIDTH +: OWIDTH] = ($urandom & 1) ? 24'h800000 : 24'h7fffff;
                    3: acc_east[h*OWIDTH +: OWIDTH] = ($urandom & 1) ? 24'hffffff : 24'h000000;
                    4: acc_east[h*OWIDTH +: OWIDTH] = (h < G) ? 24'h800000 : 24'h7fffff;
                    default: acc_east[h*OWIDTH +: OWIDTH] = $urandom;
                endcase
            end
            if (mode < 5) n_extreme++;
            // ---- reference for this edge
            lo = 0; hi = 0;
            for (int h = 0; h < N_H; h++) begin
                t = tile(acc_east, h);
                if (int_prec) begin
                    if (h < G) lo += t <<< h; else hi += t <<< (h - G);
                end else
                    lo += t <<< h;
            end
            if (lo > 64'sd2147483647 || lo < -64'sd2147483648) $fatal(1, "reference exceeds int32 (lo=%0d)", lo);
            if (reset) begin
                exp_v[1] = 0; exp_v[0] = 0;
            end else begin
                exp_v[1] = exp_v[0]; exp_lo[1] = exp_lo[0]; exp_hi[1] = exp_hi[0];
                exp_v[0] = capture;
                if (capture) begin exp_lo[0] = lo; exp_hi[0] = hi; end
            end
        end
        if (errors == 0 && n_words > N_CYC / 3)
            $display("[PASS] combiner unit: %0d words exact (true int64 sums, %0d extreme-pattern edges), valid exact on %0d edges",
                     n_words, n_extreme, N_CYC);
        else
            $display("[FAIL] combiner unit: %0d errors, %0d words", errors, n_words);
        $finish;
    end
endmodule
