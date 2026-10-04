`timescale 1ns/1ps
`include "payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv"

// Exhaustive check of the M=8 carry-save counter: the four redundant bits must
// carry the exact count with weights 1,1,2,4, and inverting them under a
// negative sign must give 8 - count (the identity the -8*N heap row relies on).
module Top;
    logic [7:0] bits_in;
    logic s0a, s0b, s1, s2;
    int count, inverted;

    PaynPopcount8Csa u_dut (.bits_in, .s0a, .s0b, .s1, .s2);

    initial begin
        for (int pattern = 0; pattern < 256; pattern++) begin
            bits_in = 8'(pattern);
            #1;
            count = s0a + s0b + 2*s1 + 4*s2;
            inverted = !s0a + !s0b + 2*!s1 + 4*!s2;
            assert (count == $countones(bits_in))
                else $fatal(1, "pattern=%h count=%0d expected=%0d", bits_in, count, $countones(bits_in));
            assert (inverted == 8 - count)
                else $fatal(1, "pattern=%h inverted=%0d expected=%0d", bits_in, inverted, 8 - count);
        end
        $display("[PASS] 4FA M=8 carry-save counter: all 256 inputs; inverted bits give 8 - count");
        $finish;
    end
endmodule
