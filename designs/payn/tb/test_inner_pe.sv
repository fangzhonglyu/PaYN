`timescale 1ns/1ps

`include "payn/inner_pe.sv"

`ifndef SC_TEST_K
`define SC_TEST_K 2
`endif
`ifndef SC_TEST_M
`define SC_TEST_M 4
`endif
`ifndef SC_TEST_NH
`define SC_TEST_NH 2
`endif
`ifndef SC_TEST_NW
`define SC_TEST_NW 3
`endif
`ifndef SC_TEST_OWIDTH
`define SC_TEST_OWIDTH 12
`endif
`ifndef SC_TEST_CORE
`define SC_TEST_CORE InnerPEFlat
`endif

module Top;
    localparam int K = `SC_TEST_K;
    localparam int M = `SC_TEST_M;
    localparam int N_H = `SC_TEST_NH;
    localparam int N_W = `SC_TEST_NW;
    localparam int OWIDTH = `SC_TEST_OWIDTH;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic mac_en = 1'b0, shift_in = 1'b0;
    logic load_a_sign_in = 1'b0, load_w_sign_in = 1'b0;
    logic [N_H*K*M-1:0] a_bits_in = '0, a_bits_out;
    logic [N_H*K-1:0] a_signs_in = '0, a_signs_out;
    logic [N_W*K*M-1:0] w_bits_in = '0, w_bits_out;
    logic [N_W*K-1:0] w_signs_in = '0, w_signs_out;
    logic load_a_sign_out, load_w_sign_out;
    logic [N_H*OWIDTH-1:0] acc_in_west = '0, acc_out_east;
    integer signed expected [N_H][N_W];

    always #1.25 clk = ~clk;

    `SC_TEST_CORE #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) dut (.*);

    function automatic integer signed contribution(input int h, input int v);
        integer signed value;
        value = 0;
        for (int d = 0; d < K; d++) begin
            for (int lane = 0; lane < M; lane++) begin
                if (a_bits_in[(h*K + d)*M + lane] &&
                    w_bits_in[(v*K + d)*M + lane]) begin
                    value += (a_signs_in[h*K + d] ^
                              w_signs_in[v*K + d]) ? -1 : 1;
                end
            end
        end
        return value;
    endfunction

    task automatic check_row_outputs(input int column);
        for (int h = 0; h < N_H; h++) begin
            assert ($signed(acc_out_east[h*OWIDTH +: OWIDTH]) ===
                    expected[h][column])
                else $fatal(1,
                    "row %0d column %0d expected %0d, got %0d",
                    h, column, expected[h][column],
                    $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
        end
    endtask

    initial begin
        @(negedge clk);
        reset = 1'b1;
        mac_en = 1'b1;
        shift_in = 1'b1;
        @(posedge clk);
        #0.1;
        assert (acc_out_east === '0)
            else $fatal(1, "synchronous reset did not clear row tails");

        @(negedge clk);
        reset = 1'b0;
        mac_en = 1'b0;
        shift_in = 1'b0;

        a_bits_in = '1;
        w_bits_in = '1;
        a_signs_in = '0;
        w_signs_in = '0;
        a_signs_in[1*K + 0] = 1'b1;
        w_signs_in[1*K + 0] = 1'b1;
        w_signs_in[1*K + 1] = 1'b1;
        w_signs_in[2*K + 1] = 1'b1;

        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++)
                expected[h][v] = contribution(h, v);

        load_a_sign_in = 1'b1;
        load_w_sign_in = 1'b1;
        @(negedge clk);
        load_a_sign_in = 1'b0;
        load_w_sign_in = 1'b0;
        @(negedge clk);

        @(posedge clk);
        #0.05;
        mac_en = 1'b1;
        @(posedge clk);
        #0.05;
        mac_en = 1'b0;

        @(negedge clk);
        shift_in = 1'b1;
        for (int step = 0; step < N_W; step++) begin
            @(posedge clk);
            check_row_outputs(N_W - 1 - step);
            @(negedge clk);
        end
        shift_in = 1'b0;
        #0.1;
        assert (acc_out_east === '0)
            else $fatal(1, "zero fill did not clear row chains");

        $display(
            "PASS: synchronous manual PE MAC and row-serial drain K=%0d M=%0d N=%0dx%0d OWIDTH=%0d",
            K, M, N_H, N_W, OWIDTH
        );
        $finish;
    end
endmodule
