`timescale 1ns/1ps

// Full int8 matmul on payn_array in STREAM_MODE=1 (unary temporal A,
// sample-ordered Sobol W), checked against emulator golden accumulators.
//
// C = A @ B.T with A (N_H x D) and B (N_W x D) int8 from $readmemh files in the
// t9_sc_matmul format. D is processed as D/K K-blocks; each block restarts the
// RNG streams at t = 0 and sets d_base = kb*K so the W column masks match the
// emulator's bitrev(d mod 64). Operand encoding (host-side quantization):
//   bA = round(|qA| * 128 / 127)        (emulator comparator threshold)
//   kA = round(bA * L / 128)            (A's thermometer length; the A operand)
//   bB = round(|qB| * 128 / 127)        (W operand, vs. 7-bit Sobol thresholds)
//
// Plusargs: +CASE=<dir with a.mem, b.mem>  +EXPECT=<out_L*.mem>  +L=<length>
//           +ACC_OUT=<file>  (optional: dump the drained acc)
//
// Needs the DesignWare sim library (InnerTile instantiates DW02_tree).

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
`ifndef SC_D
`define SC_D 128
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int D = `SC_D;
    localparam int WIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int WARMUP = 2;
    localparam int GRID = 128;
    localparam int Q_MAX = 127;
    localparam int N_BLOCKS = D / K;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic rng_en = 1'b0, rng_restart = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0;
    logic load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic [15:0] d_base = '0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    logic [7:0]  a_mem [N_H*D];
    logic [7:0]  b_mem [N_W*D];
    logic [31:0] expect_mem [N_H*N_W];
    integer signed drain [N_H][N_W];

    always #1.25 clk = ~clk;

    payn_array #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH),
        .STREAM_MODE(1), .RNG_SHIFT(1)
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
        string case_dir, expect_file, acc_file;
        int L, cycles, errors, fd;

        if (!$value$plusargs("CASE=%s", case_dir)) $fatal(1, "missing +CASE=");
        if (!$value$plusargs("EXPECT=%s", expect_file)) $fatal(1, "missing +EXPECT=");
        if (!$value$plusargs("L=%d", L)) $fatal(1, "missing +L=");
        if (L < 1 || L > GRID) $fatal(1, "L=%0d out of range 1..%0d", L, GRID);
        $readmemh({case_dir, "/a.mem"}, a_mem);
        $readmemh({case_dir, "/b.mem"}, b_mem);
        $readmemh(expect_file, expect_mem);
        cycles = (L + M - 1) / M;

        @(negedge clk);
        reset = 1'b1;
        tick();
        reset = 1'b0;

        for (int kb = 0; kb < N_BLOCKS; kb++) begin
            for (int h = 0; h < N_H; h++)
                for (int k = 0; k < K; k++) begin
                    logic [7:0] q;
                    q = a_mem[h*D + kb*K + k];
                    a_binary_in[(h*K + k)*WIDTH +: WIDTH] =
                        WIDTH'((threshold(q) * L + GRID / 2) / GRID);
                    a_signs_in[h*K + k] = q[7];
                end
            for (int v = 0; v < N_W; v++)
                for (int k = 0; k < K; k++) begin
                    logic [7:0] q;
                    q = b_mem[v*D + kb*K + k];
                    w_binary_in[(v*K + k)*WIDTH +: WIDTH] = WIDTH'(threshold(q));
                    w_signs_in[v*K + k] = q[7];
                end
            d_base = 16'(kb * K);

            // Restart both streams at t = 0 and latch this block's operands.
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

        // Row-serial drain (same protocol as test_payn_array.sv).
        acc_in_west = '0;
        @(negedge clk);
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            @(posedge clk);
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(negedge clk);
        end
        shift_in = 1'b0;

        errors = 0;
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++)
                if (drain[h][v] !== $signed(expect_mem[h*N_W + v])) begin
                    if (errors < 8)
                        $display("MISMATCH acc[%0d][%0d]: rtl=%0d expected=%0d",
                                 h, v, drain[h][v], $signed(expect_mem[h*N_W + v]));
                    errors++;
                end

        if ($value$plusargs("ACC_OUT=%s", acc_file)) begin
            fd = $fopen(acc_file, "w");
            for (int h = 0; h < N_H; h++) begin
                for (int v = 0; v < N_W; v++)
                    $fwrite(fd, "%08x%s", drain[h][v], v == N_W-1 ? "\n" : " ");
            end
            $fclose(fd);
        end

        if (errors == 0)
            $display("PASS: L=%0d all %0d accumulators match %s", L, N_H*N_W, expect_file);
        else
            $display("FAIL: L=%0d %0d of %0d accumulators differ", L, errors, N_H*N_W);
        $finish;
    end
endmodule
