`timescale 1ns/1ps

`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"

module Top;
    localparam int K = 4;
    localparam int M = 4;
    localparam int N_H = 2;
    localparam int N_W = 2;
    localparam int WIDTH = 8;
    localparam int CYCLES = 260;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic enable = 1'b0;
    logic load_a = 1'b0;
    logic load_w = 1'b0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0] a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0] w_signs_in = '0;
    logic [M*WIDTH-1:0] a_random_values;
    logic [M*WIDTH-1:0] w_random_values;
    logic [N_H*K*M-1:0] a_bits;
    logic [N_H*K-1:0] a_signs;
    logic [N_W*K*M-1:0] w_bits;
    logic [N_W*K-1:0] w_signs;

    integer trace_file;

    always #1.25 clk = ~clk;

    sobol_bank #(
        .WIDTH(WIDTH),
        .M(M),
        .DIRECTION_SET(0),
        .DIGITAL_SHIFT_BASE(8'h17),
        .DIGITAL_SHIFT_STRIDE(8'h53)
    ) u_a_rng (
        .clk,
        .reset,
        .enable,
        .random_values(a_random_values)
    );

    sobol_bank #(
        .WIDTH(WIDTH),
        .M(M),
        .DIRECTION_SET(1),
        .DIGITAL_SHIFT_BASE(8'h9d),
        .DIGITAL_SHIFT_STRIDE(8'h2b)
    ) u_w_rng (
        .clk,
        .reset,
        .enable,
        .random_values(w_random_values)
    );

    sc_pe_peripheral #(
        .K(K),
        .M(M),
        .N_H(N_H),
        .N_W(N_W),
        .WIDTH(WIDTH)
    ) u_peripheral (.*);

    initial begin
        for (int index = 0; index < N_H*K; index++) begin
            a_binary_in[index*WIDTH +: WIDTH] = WIDTH'(index*29 + 7);
            a_signs_in[index] = ((index % 3) == 1);
        end
        for (int index = 0; index < N_W*K; index++) begin
            w_binary_in[index*WIDTH +: WIDTH] = WIDTH'(index*43 + 11);
            w_signs_in[index] = ((index % 4) >= 2);
        end

        trace_file = $fopen("peripheral_v1_rtl.csv", "w");
        assert (trace_file != 0) else $fatal(1, "cannot open RTL trace");
        $fwrite(trace_file,
                "cycle,a_rng,w_rng,a_bits,w_bits,a_signs,w_signs\n");

        repeat (2) @(negedge clk);
        reset = 1'b0;
        enable = 1'b1;
        load_a = 1'b1;
        load_w = 1'b1;

        for (int cycle = 0; cycle < CYCLES; cycle++) begin
            @(posedge clk);
            #0.1;
            $fwrite(trace_file, "%0d,%h,%h,%h,%h,%h,%h\n",
                    cycle, a_random_values, w_random_values,
                    a_bits, w_bits, a_signs, w_signs);
            load_a = 1'b0;
            load_w = 1'b0;
        end

        $fclose(trace_file);
        $display("PASS: wrote %0d-cycle peripheral trace", CYCLES);
        $finish;
    end
endmodule
