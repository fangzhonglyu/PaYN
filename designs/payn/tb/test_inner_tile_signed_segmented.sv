`timescale 1ns/1ps

`include "payn/variants/signed_segmented/inner_tile_signed_segmented.sv"

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int OWIDTH = 24;
    localparam int N_RANDOM = 4096;
    localparam longint unsigned ACC_MASK = (64'h1 << OWIDTH) - 1;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic shift_in = 1'b0;
    logic mac_en = 1'b0;
    logic a_signs [K];
    logic [M-1:0] a_bits [K];
    logic w_signs [K];
    logic [M-1:0] w_bits [K];
    logic signed [OWIDTH-1:0] acc_in = '0;
    logic signed [OWIDTH-1:0] acc_out_7;
    logic signed [OWIDTH-1:0] acc_out_8;
    logic signed [OWIDTH-1:0] acc_out_9;
    logic signed [OWIDTH-1:0] acc_out_11;

    longint unsigned model;
    integer signed signed_delta;
    integer unsigned hits;

    always #1.25 clk = ~clk;

    InnerTileSignedSegmented #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(7)
    ) dut_7 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_7)
    );
    InnerTileSignedSegmented #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(8)
    ) dut_8 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_8)
    );
    InnerTileSignedSegmented #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(9)
    ) dut_9 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_9)
    );
    InnerTileSignedSegmented #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(11)
    ) dut_11 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_11)
    );

    task automatic check_state(input string phase);
        #0.01;
        assert ($unsigned(acc_out_7) === model[OWIDTH-1:0])
            else $fatal(1, "%s LOW_W=7 got=%h expected=%h",
                        phase, acc_out_7, model[OWIDTH-1:0]);
        assert ($unsigned(acc_out_8) === model[OWIDTH-1:0])
            else $fatal(1, "%s LOW_W=8 got=%h expected=%h",
                        phase, acc_out_8, model[OWIDTH-1:0]);
        assert ($unsigned(acc_out_9) === model[OWIDTH-1:0])
            else $fatal(1, "%s LOW_W=9 got=%h expected=%h",
                        phase, acc_out_9, model[OWIDTH-1:0]);
        assert ($unsigned(acc_out_11) === model[OWIDTH-1:0])
            else $fatal(1, "%s LOW_W=11 got=%h expected=%h",
                        phase, acc_out_11, model[OWIDTH-1:0]);
    endtask

    task automatic set_extreme(input logic negative);
        signed_delta = 0;
        for (int i = 0; i < K; i++) begin
            a_bits[i] = '1;
            w_bits[i] = '1;
            a_signs[i] = negative;
            w_signs[i] = 1'b0;
            signed_delta += negative ? -M : M;
        end
    endtask

    task automatic mac_and_check(input string phase);
        model = (model + signed_delta) & ACC_MASK;
        mac_en = 1'b1;
        @(posedge clk);
        check_state(phase);
        @(negedge clk);
    endtask

    initial begin
        model = 0;
        for (int i = 0; i < K; i++) begin
            a_signs[i] = 1'b0;
            w_signs[i] = 1'b0;
            a_bits[i] = '0;
            w_bits[i] = '0;
        end

        @(negedge clk);
        reset = 1'b1;
        @(posedge clk);
        check_state("reset");
        @(negedge clk);
        reset = 1'b0;

        // All low banks are at their maximum residue.  The next +128 creates a
        // pending carry in every implementation.
        acc_in = $signed(24'h00_07_ff);
        shift_in = 1'b1;
        model = $unsigned(acc_in);
        @(posedge clk);
        check_state("initial shift");
        @(negedge clk);
        shift_in = 1'b0;

        set_extreme(1'b0);
        mac_and_check("positive boundary");

        // Shift immediately while the carry is still pending.  acc_out must
        // already be canonical, and the loaded state must discard local debt.
        mac_en = 1'b0;
        acc_in = $signed(24'h8a_5c_31);
        shift_in = 1'b1;
        model = $unsigned(acc_in);
        @(posedge clk);
        check_state("shift over pending carry");
        @(negedge clk);
        shift_in = 1'b0;

        set_extreme(1'b1);
        mac_and_check("negative boundary");

        // Retire a pending borrow on an idle edge without changing the visible
        // canonical value.
        mac_en = 1'b0;
        @(posedge clk);
        check_state("idle retirement");
        @(negedge clk);

        for (int cycle = 0; cycle < N_RANDOM; cycle++) begin
            signed_delta = 0;
            for (int i = 0; i < K; i++) begin
                a_bits[i] = $urandom;
                w_bits[i] = $urandom;
                a_signs[i] = $urandom & 1;
                w_signs[i] = $urandom & 1;
                hits = $countones(a_bits[i] & w_bits[i]);
                if (a_signs[i] ^ w_signs[i])
                    signed_delta -= hits;
                else
                    signed_delta += hits;
            end
            mac_and_check("random MAC");
        end

        mac_en = 1'b0;
        @(posedge clk);
        check_state("final retirement");

        $display(
            "PASS: signed segmented tile exact for LOW_W={7,8,9,11} over %0d random MACs",
            N_RANDOM
        );
        $finish;
    end
endmodule
