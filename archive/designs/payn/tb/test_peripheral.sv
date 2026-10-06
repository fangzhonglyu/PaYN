`timescale 1ns/1ps

`include "payn/pe_peripheral.sv"

module Top;
    localparam int K = 2;
    localparam int M = 2;
    localparam int N_H = 2;
    localparam int N_W = 2;
    localparam int WIDTH = 4;
    localparam int LEVELS = 1 << WIDTH;
    localparam int K_STRIDE = ((LEVELS * 79 / 128) | 1);
    localparam int M_STRIDE = ((LEVELS * 49 / 128) | 1);
    localparam int W_SALT = 1 << (WIDTH - 1);

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic load_a = 1'b0;
    logic load_w = 1'b0;
    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0] a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0] w_signs_in = '0;
    logic [M*WIDTH-1:0] a_random_values = '0;
    logic [M*WIDTH-1:0] w_random_values = '0;
    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0] a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0] w_signs;

    logic [N_H*K*WIDTH-1:0] expected_a_binary;
    logic [N_W*K*WIDTH-1:0] expected_w_binary;
    logic [N_H*K-1:0] expected_a_signs;
    logic [N_W*K-1:0] expected_w_signs;

    always #1.25 clk = ~clk;

    sc_pe_peripheral #(
        .K(K),
        .M(M),
        .N_H(N_H),
        .N_W(N_W),
        .WIDTH(WIDTH),
        .SCRAMBLE_ENABLE(1'b1)
    ) dut (.*);

    task automatic check_outputs;
        logic [N_H*K*M-1:0] expected_a_bits;
        logic [N_W*K*M-1:0] expected_w_bits;
        logic [WIDTH-1:0] boundary;
        logic [WIDTH-1:0] random_value;
        logic [WIDTH-1:0] mask;

        expected_a_bits = '0;
        expected_w_bits = '0;

        for (int row = 0; row < N_H; row++) begin
            for (int depth = 0; depth < K; depth++) begin
                boundary = expected_a_binary[(row*K + depth)*WIDTH +: WIDTH];
                for (int lane = 0; lane < M; lane++) begin
                    mask = WIDTH'((depth*K_STRIDE + lane*M_STRIDE) &
                                  (LEVELS - 1));
                    random_value =
                        a_random_values[lane*WIDTH +: WIDTH] ^ mask;
                    expected_a_bits[(row*K + depth)*M + lane] =
                        boundary > random_value;
                end
            end
        end

        for (int col = 0; col < N_W; col++) begin
            for (int depth = 0; depth < K; depth++) begin
                boundary = expected_w_binary[(col*K + depth)*WIDTH +: WIDTH];
                for (int lane = 0; lane < M; lane++) begin
                    mask = WIDTH'((depth*K_STRIDE + lane*M_STRIDE + W_SALT) &
                                  (LEVELS - 1));
                    random_value =
                        w_random_values[lane*WIDTH +: WIDTH] ^ mask;
                    expected_w_bits[(col*K + depth)*M + lane] =
                        boundary > random_value;
                end
            end
        end

        #0.1;
        assert (a_bits === expected_a_bits)
            else $fatal(1, "A comparator mismatch: expected %h, got %h",
                        expected_a_bits, a_bits);
        assert (w_bits === expected_w_bits)
            else $fatal(1, "W comparator mismatch: expected %h, got %h",
                        expected_w_bits, w_bits);
        assert (a_signs === expected_a_signs)
            else $fatal(1, "A sign register mismatch");
        assert (w_signs === expected_w_signs)
            else $fatal(1, "W sign register mismatch");
    endtask

    initial begin
        #0.1;
        expected_a_binary = '0;
        expected_w_binary = '0;
        expected_a_signs = '0;
        expected_w_signs = '0;
        check_outputs();

        @(negedge clk);
        reset = 1'b0;
        a_random_values[0 +: WIDTH] = 4'h1;
        a_random_values[WIDTH +: WIDTH] = 4'h7;
        w_random_values[0 +: WIDTH] = 4'h3;
        w_random_values[WIDTH +: WIDTH] = 4'hc;
        for (int index = 0; index < N_H*K; index++)
            a_binary_in[index*WIDTH +: WIDTH] = WIDTH'(index*3 + 2);
        for (int index = 0; index < N_W*K; index++)
            w_binary_in[index*WIDTH +: WIDTH] = WIDTH'(index*2 + 5);
        a_signs_in = 4'b1010;
        w_signs_in = 4'b0110;
        load_a = 1'b1;
        load_w = 1'b1;

        @(posedge clk);
        expected_a_binary = a_binary_in;
        expected_w_binary = w_binary_in;
        expected_a_signs = a_signs_in;
        expected_w_signs = w_signs_in;
        check_outputs();

        @(negedge clk);
        load_a = 1'b0;
        load_w = 1'b0;
        a_binary_in = '0;
        w_binary_in = '0;
        a_signs_in = '0;
        w_signs_in = '0;
        check_outputs();

        a_random_values = 8'h2e;
        w_random_values = 8'h94;
        check_outputs();

        @(negedge clk);
        for (int index = 0; index < N_H*K; index++)
            a_binary_in[index*WIDTH +: WIDTH] = WIDTH'(15 - index);
        a_signs_in = 4'b0101;
        load_a = 1'b1;
        @(posedge clk);
        expected_a_binary = a_binary_in;
        expected_a_signs = a_signs_in;
        check_outputs();

        $display("PASS: peripheral registers, independent loads, scrambling, and comparators");
        $finish;
    end
endmodule
