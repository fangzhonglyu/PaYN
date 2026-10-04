`timescale 1ns/1ps
`include "wo_ring_blocks.sv"

// Exhaustive functional dump of the WO-ring feeders (and a directed check of the
// ring delta and collector). check_wo_feeder.py compares the dump with the
// model's booth_digits() and CODE_A/CODE_W.
module tb_wo_ring_blocks;
    localparam int NL = 64;
    logic int_mode, hys, q;
    logic [1:0] p;
    logic [NL*8-1:0] dA, dW, cA, cW;
    logic [NL-1:0] sA, sW, oA, oW;
    integer fd, b, pp, hh, qq, im, L;

    WoFeederA #(.N_H(8), .K(8)) u_a (.int_mode, .p, .din(dA), .sin(sA), .code_out(cA), .sign_out(oA));
    WoFeederW #(.N_W(8), .K(8)) u_w (.int_mode, .hys, .q, .din(dW), .sin(sW), .code_out(cW), .sign_out(oW));

    // ring delta + collector, directed
    logic clk = 0, reset = 1, ring_in = 0, shift_in = 0, shift_eff, ring_out;
    logic [8*24-1:0] west, east, chain0;
    WoRingPeDelta #(.N_H(8), .OWIDTH(24)) u_r (.clk, .reset, .ring_in, .shift_in,
        .acc_in_west(west), .acc_out_east(east), .acc_chain0(chain0), .shift_eff, .ring_out);
    logic phase;
    logic signed [23:0] acc_east;
    logic signed [27:0] cout;
    WoCollectorRow #(.OWIDTH(24)) u_c (.clk, .int_mode, .phase, .acc_east, .out(cout));

    initial begin
        fd = $fopen("feeder_dump.txt", "w");
        for (im = 0; im < 2; im++) begin
            int_mode = im[0];
            for (pp = 0; pp < 4; pp++) begin
                p = pp[1:0];
                for (b = 0; b < 256; b++) begin
                    for (L = 0; L < NL; L++) begin
                        dA[L*8 +: 8] = 8'((b + 37*L) & 255);
                        sA[L] = ((b + L) % 3) == 0;
                    end
                    #1;
                    for (L = 0; L < NL; L++)
                        $fwrite(fd, "A %0d %0d %0d %0d %0d %0d %0d\n", im, pp, L,
                                dA[L*8 +: 8], sA[L], cA[L*8 +: 8], oA[L]);
                end
            end
            for (hh = 0; hh < 2; hh++) begin
                for (qq = 0; qq < 2; qq++) begin
                    hys = hh[0]; q = qq[0];
                    for (b = 0; b < 256; b++) begin
                        for (L = 0; L < NL; L++) begin
                            dW[L*8 +: 8] = 8'((b + 53*L) & 255);
                            sW[L] = ((b + L) % 5) == 0;
                        end
                        #1;
                        for (L = 0; L < NL; L++)
                            $fwrite(fd, "W %0d %0d %0d %0d %0d %0d %0d %0d\n", im, hh, qq, L,
                                    dW[L*8 +: 8], sW[L], cW[L*8 +: 8], oW[L]);
                    end
                end
            end
        end
        $fclose(fd);

        // ring delta: ring_q follows ring_in by one clock; x4 wiring; west otherwise
        for (L = 0; L < 8; L++) begin
            west[L*24 +: 24] = 24'(32'h123456 * (L + 1));
            east[L*24 +: 24] = 24'(32'h0abcde * (L + 3));
        end
        #1 reset = 1; clk = 1; #1 clk = 0; reset = 0;
        ring_in = 1; #1;
        if (shift_eff !== 1'b0 || chain0 !== west) $fatal(1, "ring delta: idle path wrong");
        clk = 1; #1 clk = 0; #1;
        for (L = 0; L < 8; L++)
            if (chain0[L*24 +: 24] !== {east[L*24 +: 22], 2'b00}) $fatal(1, "ring delta: x4 path wrong");
        if (shift_eff !== 1'b1 || ring_out !== 1'b1) $fatal(1, "ring delta: shift_eff/ring_out wrong");

        // collector: X1 = -5, X0 = 7 -> -80 + 7 = -73 ; SC bypass sign-extends
        int_mode = 1; phase = 0; acc_east = -24'sd5; #1 clk = 1; #1 clk = 0;
        phase = 1; acc_east = 24'sd7; #1;
        if (cout !== -28'sd73) $fatal(1, "collector: got %0d", cout);
        int_mode = 0; acc_east = -24'sd1234567; #1;
        if (cout !== -28'sd1234567) $fatal(1, "collector bypass: got %0d", cout);
        $display("TB_DONE ring/collector directed checks passed; feeder dump written");
        $finish;
    end
endmodule
