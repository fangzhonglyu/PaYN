`timescale 1ns/1ps
`include "payn/variants/stratified_sng/strat_lane_count.sv"

// StratLaneCount against the expanded 16-lane AND + popcount, all masks,
// exhaustive over alpha/beta/fine_a/fine_w (2^12 inputs per mask pair).
module Top;
    logic [1:0] alpha, beta;
    logic [3:0] fine_a, fine_w;
    logic [4:0] c [4][4];
    for (genvar sa = 0; sa < 4; sa++) begin : g_sa
        for (genvar sw = 0; sw < 4; sw++) begin : g_sw
            StratLaneCount #(.SM_A(2'(sa)), .SM_W(2'(sw))) u (
                .alpha, .beta, .fine_a, .fine_w, .count(c[sa][sw]));
        end
    end
    function automatic int expanded(int sa, int sw);
        int n = 0, i, j;
        bit ab, wb;
        for (int m = 0; m < 16; m++) begin
            i = (m >> 2) ^ sa;  j = (m & 3) ^ sw;
            ab = (i < alpha) || (i == alpha && fine_a[m & 3]);
            wb = (j < beta)  || (j == beta  && fine_w[m >> 2]);
            n += ab & wb;
        end
        return n;
    endfunction
    initial begin
        int errors = 0;
        for (int v = 0; v < 4096; v++) begin
            {alpha, beta, fine_a, fine_w} = 12'(v);
            #1;
            for (int sa = 0; sa < 4; sa++)
                for (int sw = 0; sw < 4; sw++)
                    if (c[sa][sw] !== 5'(expanded(sa, sw))) errors++;
        end
        if (errors) $fatal(1, "[FAIL] %0d mismatches", errors);
        $display("[PASS] StratLaneCount equals expanded 16-lane AND+popcount: 4096 inputs x 16 mask pairs");
        $finish;
    end
endmodule
