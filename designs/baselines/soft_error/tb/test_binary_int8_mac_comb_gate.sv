`timescale 1ns/1ps

`ifndef GL_SIM
`include "baselines/soft_error/binary_int8_mac_comb.sv"
`endif

module Top;
    logic clk = 1'b0;
    logic reset = 1'b0;
    logic signed [7:0] a;
    logic signed [7:0] b;
    logic signed [31:0] c;
    logic signed [31:0] y;

    binary_int8_mac_comb dut (.*);

`ifdef GL_SIM
    initial begin
`ifdef SDF_FILE
        $sdf_annotate(`SDF_FILE, dut);
`endif
    end
`endif

    initial begin
        logic signed [31:0] expected;

        a = '0;
        b = '0;
        c = '0;
        #2;
        for (int test_id = 0; test_id < 1000; test_id++) begin
            a = $urandom;
            b = $urandom;
            c = $urandom;
            expected = ($signed(a) * $signed(b)) + $signed(c);
            #2;
            if (y !== expected)
                $fatal(1, "mismatch test=%0d a=%0d b=%0d c=%0d y=%0d expected=%0d",
                    test_id, a, b, c, y, expected);
        end
        $display("PASS: binary INT8 combinational MAC matches reference (1000 vectors)");
        $finish;
    end
endmodule
