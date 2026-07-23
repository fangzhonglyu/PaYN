`timescale 1ns/1ps

`include "payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv"

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int OWIDTH = 24;
    localparam int N_BURST = 4096;
    localparam int N_RANDOM = 8192;
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
    logic acc_valid_7;
    logic acc_valid_8;
    logic acc_valid_9;
    logic acc_valid_11;

    longint unsigned model;
    integer signed signed_delta;
    integer unsigned hits;
    integer unsigned q_nonzero_random;
    integer unsigned debt_retire_random;
    integer signed q_min_random;
    integer signed q_max_random;
    logic profile_random = 1'b0;

    always #1.25 clk = ~clk;

    InnerTileSignedSegmentedCSA #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(7)
    ) dut_7 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in,
        .acc_out(acc_out_7), .acc_out_valid(acc_valid_7)
    );
    InnerTileSignedSegmentedCSA #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(8)
    ) dut_8 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in,
        .acc_out(acc_out_8), .acc_out_valid(acc_valid_8)
    );
    InnerTileSignedSegmentedCSA #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(9)
    ) dut_9 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in,
        .acc_out(acc_out_9), .acc_out_valid(acc_valid_9)
    );
    InnerTileSignedSegmentedCSA #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(11)
    ) dut_11 (
        .clk, .reset, .a_signs, .a_bits, .w_signs, .w_bits,
        .shift_in, .mac_en, .acc_in,
        .acc_out(acc_out_11), .acc_out_valid(acc_valid_11)
    );

    task automatic check_state(input string phase);
        #0.01;
        if ($unsigned(acc_out_7) !== model[OWIDTH-1:0])
            $display(
                "DEBUG %s H=%h D=%h S=%h C=%h upper=%h neg=%h q=%h rows=%h/%h residues=%h/%h",
                phase, dut_7.acc_high, dut_7.high_debt,
                dut_7.acc_sum, dut_7.acc_carry,
                dut_7.heap_upper_sum, dut_7.negative_count,
                dut_7.high_delta, dut_7.heap_row0, dut_7.heap_row1,
                dut_7.lane_residues[0], dut_7.lane_residues[1]
            );
        assert (acc_valid_7 && acc_valid_8 && acc_valid_9 && acc_valid_11)
            else $fatal(1, "%s canonical output is not valid", phase);
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

    task automatic active_mac_edge;
        mac_en = 1'b1;
        model = (model + signed_delta) & ACC_MASK;
        #0.01;
        if (profile_random) begin
            if ($signed(dut_9.high_delta) != 0)
                q_nonzero_random++;
            if (dut_9.retire_debt_positive || dut_9.retire_debt_negative)
                debt_retire_random++;
            if ($signed(dut_9.high_delta) < q_min_random)
                q_min_random = $signed(dut_9.high_delta);
            if ($signed(dut_9.high_delta) > q_max_random)
                q_max_random = $signed(dut_9.high_delta);
        end
        @(posedge clk);
        #0.01;
        assert (!acc_valid_7 && !acc_valid_8 &&
                !acc_valid_9 && !acc_valid_11)
            else $fatal(1, "canonicalizer unexpectedly active during MAC");
        assert ((acc_out_7 === '0) && (acc_out_8 === '0) &&
                (acc_out_9 === '0) && (acc_out_11 === '0))
            else $fatal(1, "invalid MAC-time output is not isolated");
        @(negedge clk);
    endtask

    task automatic observe_without_clock(input string phase);
        // This is the architectural normalization boundary: the redundant
        // state is unchanged and becomes canonical combinationally.  There is
        // deliberately no idle/flush clock before the check.
        mac_en = 1'b0;
        check_state(phase);
    endtask

    initial begin
        model = 0;
        q_nonzero_random = 0;
        debt_retire_random = 0;
        q_min_random = 999;
        q_max_random = -999;
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

        // A canonical shift load maps directly into one carry-save row.
        acc_in = $signed(24'h8a_5c_31);
        shift_in = 1'b1;
        model = $unsigned(acc_in);
        @(posedge clk);
        check_state("initial shift load");
        @(negedge clk);
        shift_in = 1'b0;

        // Long uninterrupted runs demonstrate that no block length or periodic
        // normalization is hidden in the recurrence.
        set_extreme(1'b0);
        repeat (N_BURST)
            active_mac_edge();
        observe_without_clock("long positive burst");

        set_extreme(1'b1);
        repeat (2*N_BURST)
            active_mac_edge();
        observe_without_clock("long negative burst");

        // Random bipolar activity with a combinational observation after every
        // update stresses changes in the redundant row carry.
        profile_random = 1'b1;
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
            active_mac_edge();
            observe_without_clock("random MAC");
        end
        profile_random = 1'b0;

        // Back-to-back row shifting must emit the current exact value and load
        // the west value on the same edge, with no normalize bubble.
        acc_in = $signed(24'h37_c4_a9);
        shift_in = 1'b1;
        model = $unsigned(acc_in);
        @(posedge clk);
        check_state("back-to-back shift load");
        @(negedge clk);

        acc_in = $signed(24'hf1_20_03);
        model = $unsigned(acc_in);
        @(posedge clk);
        check_state("second shift load");
        @(negedge clk);
        shift_in = 1'b0;

        $display(
            "PASS: recurrent CSA exact for LOW_W={7,8,9,11}; %0d-cycle bursts and %0d random MACs require no flush clock",
            N_BURST, N_RANDOM
        );
        $display(
            "PROFILE: LOW_W=9 high correction nonzero %0d/%0d, debt retired %0d/%0d, q range [%0d,%0d]",
            q_nonzero_random, N_RANDOM, debt_retire_random, N_RANDOM,
            q_min_random, q_max_random
        );
        $finish;
    end
endmodule
