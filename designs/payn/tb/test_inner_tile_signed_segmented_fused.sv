`timescale 1ns/1ps

`include "payn/variants/signed_segmented_fused/inner_tile_signed_segmented_fused.sv"

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int OWIDTH = 24;
    localparam int N_RANDOM = 32768;
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
    logic signed [OWIDTH-1:0] acc_out_8;
    logic signed [OWIDTH-1:0] acc_out_9;

    longint unsigned model;
    integer signed signed_delta;
    integer unsigned hits;
    integer unsigned seed_state;

    always #1.25 clk = ~clk;

    InnerTileSignedSegmentedFused #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(8)
    ) dut_8 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_8)
    );

    InnerTileSignedSegmentedFused #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(9)
    ) dut_9 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in, .acc_out(acc_out_9)
    );

    task automatic check_state(input string phase, input integer cycle);
        #0.01;
        assert ($unsigned(acc_out_8) === model[OWIDTH-1:0])
            else $fatal(1,
                "%s cycle=%0d LOW_W=8 got=%h expected=%h",
                phase, cycle, acc_out_8, model[OWIDTH-1:0]);
        assert ($unsigned(acc_out_9) === model[OWIDTH-1:0])
            else $fatal(1,
                "%s cycle=%0d LOW_W=9 got=%h expected=%h",
                phase, cycle, acc_out_9, model[OWIDTH-1:0]);
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

    task automatic mac_and_check(
        input string phase,
        input integer cycle
    );
        model = (model + signed_delta) & ACC_MASK;
        mac_en = 1'b1;
        @(posedge clk);
        check_state(phase, cycle);
        @(negedge clk);
    endtask

    initial begin
        seed_state = 32'hf053_d123;
        void'($urandom(seed_state));
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
        check_state("reset", 0);
        @(negedge clk);
        reset = 1'b0;

        // Start one positive MAC below whole-word wrap and simultaneously
        // cross the low-segment boundary.
        acc_in = $signed(24'hff_fff0);
        shift_in = 1'b1;
        model = $unsigned(acc_in);
        @(posedge clk);
        check_state("near-overflow shift", 0);
        @(negedge clk);
        shift_in = 1'b0;

        set_extreme(1'b0);
        mac_and_check("whole-word positive wrap", 0);

        // Overwrite an unretired carry.  The loaded word must become visible
        // immediately, with no stale boundary event.
        mac_en = 1'b0;
        acc_in = $signed(24'h00_0010);
        shift_in = 1'b1;
        model = $unsigned(acc_in);
        @(posedge clk);
        check_state("shift over pending carry", 0);
        @(negedge clk);
        shift_in = 1'b0;

        set_extreme(1'b1);
        mac_and_check("whole-word negative wrap", 0);

        mac_en = 1'b0;
        @(posedge clk);
        check_state("idle borrow retirement", 0);
        @(negedge clk);

        // Sustained extremes cross thousands of LOW_W boundaries and exercise
        // arbitrary-duration high-segment carry/borrow retirement.
        set_extreme(1'b0);
        for (int cycle = 0; cycle < 2048; cycle++)
            mac_and_check("sustained positive", cycle);

        set_extreme(1'b1);
        for (int cycle = 0; cycle < 4096; cycle++)
            mac_and_check("sustained negative", cycle);

        // Random signs are deliberately changed every cycle.  Real workloads
        // hold signs for a block, but this stresses the compensated correction
        // path more aggressively.
        for (int cycle = 0; cycle < N_RANDOM; cycle++) begin
            signed_delta = 0;
            for (int i = 0; i < K; i++) begin
                a_bits[i] = M'($urandom);
                w_bits[i] = M'($urandom);
                a_signs[i] = $urandom & 1;
                w_signs[i] = $urandom & 1;
                hits = $countones(a_bits[i] & w_bits[i]);
                if (a_signs[i] ^ w_signs[i])
                    signed_delta -= hits;
                else
                    signed_delta += hits;
            end
            mac_and_check("random MAC", cycle);

            // Also exercise an idle retirement regularly.
            if ((cycle & 10'h3ff) == 10'h3ff) begin
                mac_en = 1'b0;
                @(posedge clk);
                check_state("periodic idle", cycle);
                @(negedge clk);
            end
        end

        mac_en = 1'b0;
        @(posedge clk);
        check_state("final retirement", N_RANDOM);

        $display(
            "PASS: fused compensated tile exact for LOW_W={8,9} over %0d random plus 6146 directed MACs",
            N_RANDOM
        );
        $finish;
    end
endmodule
