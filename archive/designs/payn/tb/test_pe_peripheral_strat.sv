`timescale 1ns/1ps
`include "payn/variants/stratified_sng/pe_peripheral_strat.sv"

// Checks the shared-compare decomposition of ScPePeripheralStrat against a
// direct 8-bit comparison with the threshold assembled exactly as
// sweeps/sng_accuracy_compare.py strat_thresholds() builds it, and checks that
// every (k) maps its M lanes onto distinct coarse cells.
module Top;
    localparam int K = 8, M = 16, N_H = 2, N_W = 2, WIDTH = 8, G_A = 2, G_W = 2;
    localparam int LB = 4, GA = M >> G_A, GW = M >> G_W;
    localparam int FA = WIDTH - G_A, FW = WIDTH - G_W;
    localparam int LEVELS = 1 << WIDTH;

    logic clk = 0, reset = 1, load_a = 0, load_w = 0;
    logic [N_H*K*WIDTH-1:0] a_binary_in;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [GA*WIDTH-1:0]    a_random_values;
    logic [GW*WIDTH-1:0]    w_random_values;
    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0]   a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0]   w_signs;

    ScPePeripheralStrat #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
                          .G_A(G_A), .G_W(G_W)) dut (.*);

    always #5 clk = ~clk;

    function automatic int owen(input int d, input int g, input int salt);
        int ks = ((LEVELS * 79 / 128) | 1), ms = ((LEVELS * 49 / 128) | 1);
        return (d*ks + g*ms + salt) & (LEVELS - 1);
    endfunction

    function automatic int thr_a(input int d, input int m);
        int g = m & (GA - 1);
        int s = ((m >> (LB - G_A)) ^ (owen(d, 0, 0) >> FA)) & ((1 << G_A) - 1);
        int r = a_random_values[g*WIDTH +: WIDTH];
        return (s << FA) | (((r ^ owen(d, g, 0)) >> G_A) & ((1 << FA) - 1));
    endfunction

    function automatic int thr_w(input int d, input int m);
        int g = m >> G_W;
        int s = ((m & ((1 << G_W) - 1)) ^ (owen(d, 0, 128) >> FW)) & ((1 << G_W) - 1);
        int r = w_random_values[g*WIDTH +: WIDTH];
        return (s << FW) | (((r ^ owen(d, g, 128)) >> G_W) & ((1 << FW) - 1));
    endfunction

    int errors = 0;
    initial begin
        bit [M-1:0] seen;
        int sa, sw, cell;
        bit exp;
        // Coarse cells must be a bijection for every k.
        for (int d = 0; d < K; d++) begin
            seen = '0;
            for (int m = 0; m < M; m++) begin
                sa = ((m >> (LB - G_A)) ^ (owen(d, 0, 0) >> FA)) & 3;
                sw = ((m & 3) ^ (owen(d, 0, 128) >> FW)) & 3;
                cell = sa * 4 + sw;
                assert (!seen[cell]) else $fatal(1, "k=%0d double-books cell %0d", d, cell);
                seen[cell] = 1'b1;
            end
        end

        repeat (2) @(negedge clk);
        reset = 0;
        for (int trial = 0; trial < 20000; trial++) begin
            @(negedge clk);
            for (int i = 0; i < N_H*K; i++) a_binary_in[i*WIDTH +: WIDTH] = $urandom;
            for (int i = 0; i < N_W*K; i++) w_binary_in[i*WIDTH +: WIDTH] = $urandom;
            for (int g = 0; g < GA; g++) a_random_values[g*WIDTH +: WIDTH] = $urandom;
            for (int g = 0; g < GW; g++) w_random_values[g*WIDTH +: WIDTH] = $urandom;
            load_a = 1; load_w = 1;
            @(posedge clk); #1;
            load_a = 0; load_w = 0;
            for (int row = 0; row < N_H; row++)
                for (int d = 0; d < K; d++)
                    for (int m = 0; m < M; m++) begin
                        exp = a_binary_in[(row*K + d)*WIDTH +: WIDTH] > thr_a(d, m);
                        if (a_bits[(row*K + d)*M + m] !== exp) errors++;
                    end
            for (int col = 0; col < N_W; col++)
                for (int d = 0; d < K; d++)
                    for (int m = 0; m < M; m++) begin
                        exp = w_binary_in[(col*K + d)*WIDTH +: WIDTH] > thr_w(d, m);
                        if (w_bits[(col*K + d)*M + m] !== exp) errors++;
                    end
        end
        if (errors) $fatal(1, "[FAIL] %0d lane-bit mismatches", errors);
        $display("[PASS] stratified peripheral: 20000 random trials, all lane bits equal direct 8-bit compares; all K lane->cell maps bijective");
        $finish;
    end
endmodule
