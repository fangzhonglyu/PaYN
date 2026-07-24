`timescale 1ns/1ps

`include "payn/variants/signed_segmented_block_retired/inner_tile_signed_segmented_block_retired.sv"

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int OWIDTH = 24;
    localparam int T_MAIN = 128;
    localparam int T_HALF = 64;
    localparam int T_QUARTER = 32;
    localparam int MAIN_CYCLES = T_MAIN / M;
    localparam int HALF_CYCLES = T_HALF / M;
    localparam int QUARTER_CYCLES = T_QUARTER / M;
    localparam int N_TILES = 3;
    localparam int N_RANDOM_BLOCKS = 4000;
    localparam longint unsigned ACC_MASK =
        (64'h1 << OWIDTH) - 1;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic shift_in = 1'b0;
    logic mac_en = 1'b0;
    logic a_signs [K];
    logic [M-1:0] a_bits [K];
    logic w_signs [K];
    logic [M-1:0] w_bits [K];
    logic signed [OWIDTH-1:0] acc_in = '0;

    integer phase_main = 0;
    integer phase_half = 0;
    integer phase_quarter = 0;
    logic block_last_main;
    logic block_last_half;
    logic block_last_quarter;

    assign block_last_main = (phase_main == MAIN_CYCLES - 1);
    assign block_last_half = (phase_half == HALF_CYCLES - 1);
    assign block_last_quarter =
        (phase_quarter == QUARTER_CYCLES - 1);

    logic signed [OWIDTH-1:0] acc_chain [N_TILES:0];
    logic signed [OWIDTH-1:0] acc_out_half;
    logic signed [OWIDTH-1:0] acc_out_quarter;

    assign acc_chain[0] = acc_in;

    for (genvar tile = 0; tile < N_TILES; tile++) begin : g_chain
        InnerTileSignedSegmentedBlockRetired #(
            .K(K), .M(M), .T(T_MAIN), .OWIDTH(OWIDTH)
        ) dut (
            .clk,
            .reset,
            .a_signs,
            .a_bits,
            .w_signs,
            .w_bits,
            .block_last(block_last_main),
            .shift_in,
            .mac_en,
            .acc_in(acc_chain[tile]),
            .acc_out(acc_chain[tile+1])
        );
    end

    // The same independent signed reference also checks the generalized
    // multi-quotient case: at T=32 a cycle can cross four radix boundaries.
    InnerTileSignedSegmentedBlockRetired #(
        .K(K), .M(M), .T(T_HALF), .OWIDTH(OWIDTH)
    ) dut_half (
        .clk,
        .reset,
        .a_signs,
        .a_bits,
        .w_signs,
        .w_bits,
        .block_last(block_last_half),
        .shift_in,
        .mac_en,
        .acc_in,
        .acc_out(acc_out_half)
    );

    InnerTileSignedSegmentedBlockRetired #(
        .K(K), .M(M), .T(T_QUARTER), .OWIDTH(OWIDTH)
    ) dut_quarter (
        .clk,
        .reset,
        .a_signs,
        .a_bits,
        .w_signs,
        .w_bits,
        .block_last(block_last_quarter),
        .shift_in,
        .mac_en,
        .acc_in,
        .acc_out(acc_out_quarter)
    );

    longint unsigned model [N_TILES];
    integer signed signed_delta;
    integer unsigned hits;
    integer unsigned seed;

    always #1.25 clk = ~clk;

    task automatic check_chain(input string phase);
        #0.01;
        for (int tile = 0; tile < N_TILES; tile++) begin
            assert ($unsigned(acc_chain[tile+1])
                    === model[tile][OWIDTH-1:0])
                else $fatal(
                    1,
                    "%s tile=%0d got=%h expected=%h",
                    phase,
                    tile,
                    acc_chain[tile+1],
                    model[tile][OWIDTH-1:0]
                );
        end
    endtask

    task automatic check_half(input string phase);
        #0.01;
        assert ($unsigned(acc_out_half) === model[0][OWIDTH-1:0])
            else $fatal(
                1,
                "%s T=64 got=%h expected=%h",
                phase,
                acc_out_half,
                model[0][OWIDTH-1:0]
            );
    endtask

    task automatic check_quarter(input string phase);
        #0.01;
        assert ($unsigned(acc_out_quarter)
                === model[0][OWIDTH-1:0])
            else $fatal(
                1,
                "%s T=32 got=%h expected=%h",
                phase,
                acc_out_quarter,
                model[0][OWIDTH-1:0]
            );
    endtask

    task automatic clear_operands;
        signed_delta = 0;
        for (int lane = 0; lane < K; lane++) begin
            a_bits[lane] = '0;
            w_bits[lane] = '0;
            a_signs[lane] = 1'b0;
            w_signs[lane] = 1'b0;
        end
    endtask

    task automatic set_sign_pattern(input integer mode);
        for (int lane = 0; lane < K; lane++) begin
            case (mode)
                0: begin
                    a_signs[lane] = 1'b0;
                    w_signs[lane] = 1'b0;
                end
                1: begin
                    a_signs[lane] = 1'b1;
                    w_signs[lane] = 1'b0;
                end
                2: begin
                    a_signs[lane] = (lane >= K/2);
                    w_signs[lane] = 1'b0;
                end
                default: begin
                    a_signs[lane] = $urandom & 1;
                    w_signs[lane] = $urandom & 1;
                end
            endcase
        end
    endtask

    task automatic set_full_hits;
        signed_delta = 0;
        for (int lane = 0; lane < K; lane++) begin
            a_bits[lane] = '1;
            w_bits[lane] = '1;
            signed_delta +=
                (a_signs[lane] ^ w_signs[lane]) ? -M : M;
        end
    endtask

    task automatic set_no_hits;
        signed_delta = 0;
        for (int lane = 0; lane < K; lane++) begin
            a_bits[lane] = '0;
            w_bits[lane] = '1;
        end
    endtask

    task automatic set_random_bits;
        signed_delta = 0;
        for (int lane = 0; lane < K; lane++) begin
            a_bits[lane] = $urandom;
            w_bits[lane] = $urandom;
            hits = $countones(a_bits[lane] & w_bits[lane]);
            if (a_signs[lane] ^ w_signs[lane])
                signed_delta -= hits;
            else
                signed_delta += hits;
        end
    endtask

    task automatic idle_cycle;
        mac_en = 1'b0;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic mac_cycle(input string phase);
        logic was_last_main;
        logic was_last_half;
        logic was_last_quarter;

        was_last_main = block_last_main;
        was_last_half = block_last_half;
        was_last_quarter = block_last_quarter;
        mac_en = 1'b1;
        for (int tile = 0; tile < N_TILES; tile++)
            model[tile] =
                (model[tile] + signed_delta) & ACC_MASK;

        @(posedge clk);
        if (was_last_main)
            check_chain(phase);
        if (was_last_half)
            check_half(phase);
        if (was_last_quarter)
            check_quarter(phase);

        @(negedge clk);
        // Move the testbench phase only after the sampling edge.  Updating it
        // in the posedge active region would race the DUT's block_last input.
        phase_main =
            was_last_main ? 0 : phase_main + 1;
        phase_half =
            was_last_half ? 0 : phase_half + 1;
        phase_quarter =
            was_last_quarter ? 0 : phase_quarter + 1;
    endtask

    task automatic shift_and_check(
        input logic signed [OWIDTH-1:0] value,
        input string phase
    );
        mac_en = 1'b0;
        shift_in = 1'b1;
        acc_in = value;
        for (int tile = N_TILES-1; tile > 0; tile--)
            model[tile] = model[tile-1];
        model[0] = $unsigned(value);

        @(posedge clk);
        check_chain(phase);
        check_half(phase);
        check_quarter(phase);
        @(negedge clk);
        phase_main = 0;
        phase_half = 0;
        phase_quarter = 0;
        shift_in = 1'b0;
    endtask

    task automatic run_fixed_block(
        input integer sign_mode,
        input integer bit_mode,
        input string phase
    );
        set_sign_pattern(sign_mode);
        for (int cycle = 0; cycle < MAIN_CYCLES; cycle++) begin
            if (bit_mode == 0)
                set_full_hits();
            else
                set_no_hits();
            mac_cycle(phase);
        end
    endtask

    initial begin
        seed = 32'h5eed_1288;
        void'($urandom(seed));
        for (int tile = 0; tile < N_TILES; tile++)
            model[tile] = 0;
        clear_operands();

        @(negedge clk);
        reset = 1'b1;
        @(posedge clk);
        check_chain("reset");
        check_half("reset");
        check_quarter("reset");
        @(negedge clk);
        reset = 1'b0;

        // Seed three distinct accumulator states through the actual serial
        // shift chain.  Later drain checks can therefore detect ordering bugs.
        shift_and_check($signed(24'h80_01_00), "chain seed 0");
        shift_and_check($signed(24'h7f_ff_00), "chain seed 1");
        shift_and_check($signed(24'hff_ff_00), "chain seed 2");

        run_fixed_block(0, 0, "all-positive full-hit block");
        run_fixed_block(1, 0, "all-negative full-hit block");
        run_fixed_block(1, 1, "negative zero-hit bias cancellation");
        run_fixed_block(2, 0, "mixed-sign exact cancellation");

        // Exercise repeated modulo wrap in both directions.
        for (int block = 0; block < 64; block++)
            run_fixed_block(0, 0, "positive wrap blocks");
        for (int block = 0; block < 64; block++)
            run_fixed_block(1, 0, "negative wrap blocks");

        // Signs are reselected only at T=128 boundaries; magnitudes change
        // every cycle.  Random idle gaps prove that block phase counts enabled
        // MACs rather than clocks.
        for (int block = 0; block < N_RANDOM_BLOCKS; block++) begin
            set_sign_pattern(3);
            for (int cycle = 0; cycle < MAIN_CYCLES; cycle++) begin
                if ($urandom_range(0, 15) == 0)
                    idle_cycle();
                set_random_bits();
                mac_cycle("random bipolar blocks");
            end
        end

        // The final random block was retired by its own last MAC; there is no
        // following load/finalize pulse.  Drain it immediately and check the
        // row-serial ordering over two consecutive shifts.
        shift_and_check($signed(24'h12_34_56), "first drain shift");
        shift_and_check($signed(24'ha5_5a_c3), "second drain shift");

        $display(
            "PASS: block-retired tile exact for T={32,64,128}; %0d random T=128 blocks plus extremes, idle gaps, wrap, and serial drain",
            N_RANDOM_BLOCKS
        );
        $finish;
    end
endmodule
