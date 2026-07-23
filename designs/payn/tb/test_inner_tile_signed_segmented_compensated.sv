`timescale 1ns/1ps

`include "payn/variants/signed_segmented_compensated/inner_tile_signed_segmented_compensated.sv"

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int OWIDTH = 24;
    localparam int N_RANDOM = 20000;
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

    longint unsigned model;
    integer signed signed_delta;
    integer unsigned hits;

    always #1.25 clk = ~clk;

    InnerTileSignedSegmentedCompensated #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(7)
    ) dut_7 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_7)
    );
    InnerTileSignedSegmentedCompensated #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(8)
    ) dut_8 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_8)
    );
    InnerTileSignedSegmentedCompensated #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(9)
    ) dut_9 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_9)
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
    endtask

    task automatic clear_operands;
        signed_delta = 0;
        for (int i = 0; i < K; i++) begin
            a_bits[i] = '0;
            w_bits[i] = '0;
            a_signs[i] = 1'b0;
            w_signs[i] = 1'b0;
        end
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

    task automatic set_negative_no_hits;
        // This is the compensated heap's largest internal cancellation:
        // sum(b_i)=K*M and correction=-K*M, while true delta is zero.
        signed_delta = 0;
        for (int i = 0; i < K; i++) begin
            a_bits[i] = '0;
            w_bits[i] = '1;
            a_signs[i] = 1'b1;
            w_signs[i] = 1'b0;
        end
    endtask

    task automatic set_mixed_cancellation;
        // Four +16 and four -16 lanes must cancel exactly.
        signed_delta = 0;
        for (int i = 0; i < K; i++) begin
            a_bits[i] = '1;
            w_bits[i] = '1;
            a_signs[i] = (i >= K/2);
            w_signs[i] = 1'b0;
            signed_delta += (i >= K/2) ? -M : M;
        end
    endtask

    task automatic random_operands;
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
    endtask

    task automatic mac_and_check(input string phase);
        model = (model + signed_delta) & ACC_MASK;
        mac_en = 1'b1;
        @(posedge clk);
        check_state(phase);
        @(negedge clk);
    endtask

    task automatic shift_and_check(
        input logic signed [OWIDTH-1:0] value,
        input string phase
    );
        mac_en = 1'b0;
        acc_in = value;
        shift_in = 1'b1;
        model = $unsigned(value);
        @(posedge clk);
        check_state(phase);
        @(negedge clk);
        shift_in = 1'b0;
    endtask

    initial begin
        model = 0;
        clear_operands();

        @(negedge clk);
        reset = 1'b1;
        @(posedge clk);
        check_state("reset");
        @(negedge clk);
        reset = 1'b0;

        // Low residues for widths 7, 8, and 9 are all at their maximum.
        shift_and_check($signed(24'h00_01_ff), "initial boundary shift");
        set_extreme(1'b0);
        mac_and_check("maximum positive boundary");

        // Overwrite a pending carry immediately.  The pre-shift acc_out was
        // already canonical, and shift must discard all local pending state.
        shift_and_check($signed(24'h8a_5c_00), "shift over pending carry");
        set_extreme(1'b1);
        mac_and_check("maximum negative boundary");

        // Retire a pending borrow on an idle edge without changing acc_out.
        mac_en = 1'b0;
        @(posedge clk);
        check_state("idle borrow retirement");
        @(negedge clk);

        set_negative_no_hits();
        mac_and_check("maximum bias/correction cancellation");
        set_mixed_cancellation();
        mac_and_check("mixed positive/negative cancellation");

        // Long runs exercise repeated carries, repeated borrows, and complete
        // OWIDTH modulo wrap, not merely one stochastic block.
        shift_and_check($signed(24'h7f_ff_f0), "positive wrap setup");
        set_extreme(1'b0);
        for (int cycle = 0; cycle < 1024; cycle++)
            mac_and_check("long positive run");

        shift_and_check($signed(24'h80_00_10), "negative wrap setup");
        set_extreme(1'b1);
        for (int cycle = 0; cycle < 1024; cycle++)
            mac_and_check("long negative run");

        for (int cycle = 0; cycle < N_RANDOM; cycle++) begin
            random_operands();
            mac_and_check("random MAC");
        end

        mac_en = 1'b0;
        @(posedge clk);
        check_state("final pending retirement");

        $display(
            "PASS: compensated signed segmented tile exact for LOW_W={7,8,9} over %0d random and 2048 extreme MACs",
            N_RANDOM
        );
        $finish;
    end
endmodule
