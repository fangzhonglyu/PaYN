`timescale 1ns/1ps

// Int8 matmul C = A @ B.T on payn_array (C-BSG), checked bit-exact against the
// scmp_kernels emulator's C-BSG accumulators (emu_golden.py, or the t9 vectors).
//
// A is N x D, B is M x D (int8, $readmemh files in the t9_sc_matmul format).
// Any N, M, D up to the MAX_* bounds: the N x M output is tiled onto the
// N_H x N_W array, and D is processed as ceil(D/K) K-blocks. Partial tiles and
// the last K-block are zero-padded; a zero operand contributes exactly 0 in
// both the hardware and the emulator. Each spatial tile starts from reset;
// each K-block restarts the streams at t = 0 and sets d_base = kb*K. Both
// operands are the emulator's comparator thresholds b = round(|q| * 128 / 127).
//
// Plusargs: +CASE=<dir with a.mem, b.mem>  +EXPECT=<out_L*.mem>  +L=<length>
//           +N=<rows of A> +M=<rows of B> +D=<columns>   (default 8, 8, 128)
//
// Array shape via defines SC_K / SC_M / SC_NH / SC_NW. Needs DesignWare.

`include "payn/payn_array.sv"

`ifndef SC_K
`define SC_K 8
`endif
`ifndef SC_M
`define SC_M 16
`endif
`ifndef SC_NH
`define SC_NH 8
`endif
`ifndef SC_NW
`define SC_NW 8
`endif
`ifndef SC_MAX_N
`define SC_MAX_N 64
`endif
`ifndef SC_MAX_MB
`define SC_MAX_MB 64
`endif
`ifndef SC_MAX_D
`define SC_MAX_D 512
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int MAX_N = `SC_MAX_N;
    localparam int MAX_MB = `SC_MAX_MB;
    localparam int MAX_D = `SC_MAX_D;
    localparam int WIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int WARMUP = 2;
    localparam int GRID = 128;
    localparam int Q_MAX = 127;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic rng_en = 1'b0, rng_restart = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0;
    logic load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic [15:0] d_base = '0;
    logic [7:0] stream_len = 8'd128;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    logic [7:0]  a_mem [MAX_N*MAX_D];
    logic [7:0]  b_mem [MAX_MB*MAX_D];
    logic [31:0] expect_mem [MAX_N*MAX_MB];
    integer signed result [MAX_N][MAX_MB];

    always #1.25 clk = ~clk;

    payn_array #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH)
    ) dut (.*);

    // round(|q| * 128 / 127): |q| for |q| <= 63, |q| + 1 for |q| >= 64.
    function automatic int threshold(input logic [7:0] q);
        int mag;
        mag = $signed(q) < 0 ? -$signed(q) : $signed(q);
        return (mag * GRID * 2 + Q_MAX) / (2 * Q_MAX);
    endfunction

    task automatic tick();
        @(posedge clk);
        @(negedge clk);
    endtask

    initial begin
        string case_dir, expect_file;
        int L, N, MB, D, cycles, errors, n_rt, n_ct, n_kb;

        if (!$value$plusargs("CASE=%s", case_dir)) $fatal(1, "missing +CASE=");
        if (!$value$plusargs("EXPECT=%s", expect_file)) $fatal(1, "missing +EXPECT=");
        if (!$value$plusargs("L=%d", L)) $fatal(1, "missing +L=");
        if (!$value$plusargs("N=%d", N)) N = 8;
        if (!$value$plusargs("M=%d", MB)) MB = 8;
        if (!$value$plusargs("D=%d", D)) D = 128;
        if (L < 1 || L > GRID) $fatal(1, "L=%0d out of range 1..%0d", L, GRID);
        if (N < 1 || N > MAX_N || MB < 1 || MB > MAX_MB || D < 1 || D > MAX_D)
            $fatal(1, "shape %0dx%0dx%0d exceeds MAX %0dx%0dx%0d",
                   N, MB, D, MAX_N, MAX_MB, MAX_D);
        $readmemh({case_dir, "/a.mem"}, a_mem, 0, N*D - 1);
        $readmemh({case_dir, "/b.mem"}, b_mem, 0, MB*D - 1);
        $readmemh(expect_file, expect_mem, 0, N*MB - 1);
        stream_len = 8'(L);
        cycles = (L + M - 1) / M;
        n_rt = (N + N_H - 1) / N_H;
        n_ct = (MB + N_W - 1) / N_W;
        n_kb = (D + K - 1) / K;

        for (int rt = 0; rt < n_rt; rt++) begin
            for (int ct = 0; ct < n_ct; ct++) begin
                // Fresh accumulators for this spatial tile.
                @(negedge clk);
                reset = 1'b1;
                tick();
                reset = 1'b0;

                for (int kb = 0; kb < n_kb; kb++) begin
                    for (int h = 0; h < N_H; h++)
                        for (int k = 0; k < K; k++) begin
                            int row, col;
                            logic [7:0] q;
                            row = rt*N_H + h;
                            col = kb*K + k;
                            q = (row < N && col < D) ? a_mem[row*D + col] : 8'h00;
                            a_binary_in[(h*K + k)*WIDTH +: WIDTH] = WIDTH'(threshold(q));
                            a_signs_in[h*K + k] = q[7];
                        end
                    for (int v = 0; v < N_W; v++)
                        for (int k = 0; k < K; k++) begin
                            int row, col;
                            logic [7:0] q;
                            row = ct*N_W + v;
                            col = kb*K + k;
                            q = (row < MB && col < D) ? b_mem[row*D + col] : 8'h00;
                            w_binary_in[(v*K + k)*WIDTH +: WIDTH] = WIDTH'(threshold(q));
                            w_signs_in[v*K + k] = q[7];
                        end
                    d_base = 16'(kb * K);

                    // Restart the streams at t = 0 and latch this block's operands.
                    rng_restart = 1'b1; load_a = 1'b1; load_w = 1'b1;
                    tick();
                    rng_restart = 1'b0; load_a = 1'b0; load_w = 1'b0;
                    load_a_sign = 1'b1; load_w_sign = 1'b1;
                    tick();
                    tick();
                    load_a_sign = 1'b0; load_w_sign = 1'b0;

                    // Productive window: MAC cycle j consumes stream cycle j.
                    rng_en = 1'b1;
                    for (int c = 0; c < WARMUP + cycles; c++) begin
                        mac_en = (c >= WARMUP);
                        tick();
                    end
                    mac_en = 1'b0;
                    rng_en = 1'b0;
                end

                // Row-serial drain.
                acc_in_west = '0;
                @(negedge clk);
                shift_in = 1'b1;
                for (int s = 0; s < N_W; s++) begin
                    @(posedge clk);
                    for (int h = 0; h < N_H; h++) begin
                        int row, col;
                        row = rt*N_H + h;
                        col = ct*N_W + (N_W - 1 - s);
                        if (row < N && col < MB)
                            result[row][col] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
                    end
                    @(negedge clk);
                end
                shift_in = 1'b0;
            end
        end

        errors = 0;
        for (int n = 0; n < N; n++)
            for (int m = 0; m < MB; m++)
                if (result[n][m] !== $signed(expect_mem[n*MB + m])) begin
                    if (errors < 8)
                        $display("MISMATCH acc[%0d][%0d]: rtl=%0d expected=%0d",
                                 n, m, result[n][m], $signed(expect_mem[n*MB + m]));
                    errors++;
                end

        if (errors == 0)
            $display("PASS: %0dx%0dx%0d L=%0d array K%0d/M%0d/%0dx%0d: all %0d accumulators match",
                     N, MB, D, L, K, M, N_H, N_W, N*MB);
        else
            $display("FAIL: %0dx%0dx%0d L=%0d array K%0d/M%0d/%0dx%0d: %0d of %0d differ",
                     N, MB, D, L, K, M, N_H, N_W, errors, N*MB);
        $finish;
    end
endmodule
