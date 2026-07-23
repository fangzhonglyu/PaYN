`timescale 1ns/1ps

`include "payn/variants/biased_segmented/inner_tile_biased_segmented.sv"

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int OWIDTH = 24;
    localparam int BLOCK_T = 8;
    localparam int N_BLOCKS = 6;
    localparam longint unsigned ACC_MASK = (64'h1 << OWIDTH) - 1;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic shift_in = 1'b0;
    logic mac_en = 1'b0;
    logic block_finalize = 1'b0;
    logic a_signs [K];
    logic [M-1:0] a_bits [K];
    logic w_signs [K];
    logic [M-1:0] w_bits [K];
    logic signed [OWIDTH-1:0] acc_in = '0;
    logic signed [OWIDTH-1:0] acc_out;

    longint unsigned biased_model;
    longint unsigned canonical_model;
    integer unsigned biased_delta;
    integer signed signed_delta;
    integer unsigned negative_count;
    integer unsigned hits;

    always #1.25 clk = ~clk;

    InnerTileBiasedSegmented #(
        .K(K), .M(M), .OWIDTH(OWIDTH), .BLOCK_T(BLOCK_T)
    ) dut (.*);

    task automatic check_state(input string phase);
        #0.01;
        assert ($unsigned(acc_out) === biased_model[OWIDTH-1:0])
            else $fatal(1,
                "%s mismatch: got=%h expected=%h canonical=%h",
                phase, acc_out, biased_model[OWIDTH-1:0],
                canonical_model[OWIDTH-1:0]);
    endtask

    initial begin
        biased_model = 0;
        canonical_model = 0;
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

        for (int block = 0; block < N_BLOCKS; block++) begin
            negative_count = 0;
            for (int i = 0; i < K; i++) begin
                a_signs[i] = $urandom & 1;
                w_signs[i] = $urandom & 1;
                negative_count += a_signs[i] ^ w_signs[i];
            end

            for (int cycle = 0; cycle < BLOCK_T; cycle++) begin
                @(negedge clk);
                biased_delta = 0;
                signed_delta = 0;
                for (int i = 0; i < K; i++) begin
                    a_bits[i] = $urandom;
                    w_bits[i] = $urandom;
                    hits = $countones(a_bits[i] & w_bits[i]);
                    if (a_signs[i] ^ w_signs[i]) begin
                        biased_delta += M - hits;
                        signed_delta -= hits;
                    end else begin
                        biased_delta += hits;
                        signed_delta += hits;
                    end
                end
                biased_model = (biased_model + biased_delta) & ACC_MASK;
                canonical_model =
                    (canonical_model + signed_delta) & ACC_MASK;
                mac_en = 1'b1;
                @(posedge clk);
                check_state("biased MAC");
            end

            @(negedge clk);
            mac_en = 1'b0;
            block_finalize = 1'b1;
            biased_model =
                (biased_model - BLOCK_T*M*negative_count) & ACC_MASK;
            @(posedge clk);
            check_state("block finalize");
            assert (biased_model == canonical_model)
                else $fatal(1,
                    "block %0d correction mismatch: biased=%h canonical=%h",
                    block, biased_model, canonical_model);
            @(negedge clk);
            block_finalize = 1'b0;
        end

        // The segmented registers must retain the baseline row-serial shift
        // semantics after the resident value has been canonicalized.
        acc_in = $signed(24'h8a_5c_31);
        shift_in = 1'b1;
        @(posedge clk);
        biased_model = $unsigned(acc_in);
        check_state("shift");
        @(negedge clk);
        shift_in = 1'b0;

        $display("PASS: biased segmented tile is exact across %0d blocks", N_BLOCKS);
        $finish;
    end
endmodule
