`timescale 1ns/1ps

`ifndef GL_SIM
`include "payn/inner_tile_comb.sv"
`endif

module Top;
    localparam int K = 6;
    localparam int M = 16;
    localparam int OWIDTH = 24;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic [K-1:0] a_signs;
    logic [K*M-1:0] a_bits;
    logic [K-1:0] w_signs;
    logic [K*M-1:0] w_bits;
    logic signed [OWIDTH-1:0] acc_in;
    logic signed [OWIDTH-1:0] acc_out;

    payn_inner_tile_comb dut (
        .clk,
        .reset,
        .a_signs,
        .a_bits,
        .w_signs,
        .w_bits,
        .acc_in,
        .acc_out
    );

`ifdef GL_SIM
    initial begin
`ifdef SDF_FILE
        $display("[INFO] annotating %s", `SDF_FILE);
        $sdf_annotate(`SDF_FILE, dut);
`endif
    end
`endif

    function automatic logic signed [OWIDTH-1:0] reference_next;
        integer signed total;
        integer hits;
        begin
            total = $signed(acc_in);
            for (int i = 0; i < K; i++) begin
                hits = $countones(a_bits[i*M +: M] & w_bits[i*M +: M]);
                total += (a_signs[i] ^ w_signs[i]) ? -hits : hits;
            end
            reference_next = OWIDTH'(total);
        end
    endfunction

    task automatic randomize_inputs;
        begin
            a_bits = {$urandom, $urandom, $urandom};
            w_bits = {$urandom, $urandom, $urandom};
            a_signs = $urandom;
            w_signs = $urandom;
            acc_in = {$urandom, $urandom};
        end
    endtask

    initial begin
        logic signed [OWIDTH-1:0] expected;

        a_signs = '0;
        a_bits = '0;
        w_signs = '0;
        w_bits = '0;
        acc_in = '0;
        #2;

        for (int test_id = 0; test_id < 1000; test_id++) begin
            randomize_inputs();
            expected = reference_next();
            #2;
            if (acc_out !== expected)
                $fatal(1, "mismatch test=%0d got=%0d expected=%0d",
                    test_id, $signed(acc_out), $signed(expected));
        end

        $display("PASS: combinational tile gate surface matches reference (1000 vectors)");
        $finish;
    end
endmodule
