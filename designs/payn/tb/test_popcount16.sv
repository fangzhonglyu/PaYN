`timescale 1ns/1ps
`include "payn/variants/signed_segmented_popcount/popcount16.sv"

module Top;
    logic [15:0] bits_in;
    logic [4:0] count, wrapped_count;
    logic [3:0] count8;
    logic count1;

    PaynPopcount16 u_dut (.bits_in(bits_in), .count(count));
    PaynUnsignedPopcount #(.M(16)) u_wrapper (.bits_in(bits_in), .count(wrapped_count));
    PaynUnsignedPopcount #(.M(8)) u_generic8 (.bits_in(bits_in[7:0]), .count(count8));
    PaynUnsignedPopcount #(.M(1)) u_generic1 (.bits_in(bits_in[0]), .count(count1));

    initial begin
        for (int pattern = 0; pattern < 65536; pattern++) begin
            bits_in = 16'(pattern);
            #1;
            assert (count === 5'($countones(bits_in)))
                else $fatal(1, "pattern=%h count=%0d expected=%0d", bits_in, count, $countones(bits_in));
            assert (wrapped_count === count)
                else $fatal(1, "M16 wrapper differs at pattern=%h", bits_in);
            assert (count8 === 4'($countones(bits_in[7:0])))
                else $fatal(1, "M8 fallback differs at pattern=%h", bits_in);
            assert (count1 === bits_in[0])
                else $fatal(1, "M1 fallback differs at pattern=%h", bits_in);
        end
        $display("[PASS] 11FA/4HA popcount: all 65536 inputs; M16 wrapper and M8/M1 fallbacks match");
        $finish;
    end
endmodule
