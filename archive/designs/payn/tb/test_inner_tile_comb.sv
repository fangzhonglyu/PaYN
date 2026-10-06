`timescale 1ns/1ps

`include "payn/inner_tile.sv"

module Top;
    localparam int K = 6;
    localparam int M = 16;
    localparam int OWIDTH = 24;

    logic clk = 1'b0;
    logic reset;
    logic [K-1:0] a_signs;
    logic [K*M-1:0] a_bits;
    logic [K-1:0] w_signs;
    logic [K*M-1:0] w_bits;
    logic signed [OWIDTH-1:0] acc_in;
    logic signed [OWIDTH-1:0] comb_acc_out;

    logic         a_signs_array [K];
    logic [M-1:0] a_bits_array  [K];
    logic         w_signs_array [K];
    logic [M-1:0] w_bits_array  [K];
    logic mac_en;
    logic shift_in;
    logic signed [OWIDTH-1:0] shift_acc_in;
    logic signed [OWIDTH-1:0] tile_acc_out;

    always #0.5 clk = ~clk;

    for (genvar i = 0; i < K; i++) begin : g_arrays
        assign a_signs_array[i] = a_signs[i];
        assign a_bits_array[i] = a_bits[i*M +: M];
        assign w_signs_array[i] = w_signs[i];
        assign w_bits_array[i] = w_bits[i*M +: M];
    end

    payn_inner_tile_comb u_comb (
        .clk,
        .reset,
        .a_signs,
        .a_bits,
        .w_signs,
        .w_bits,
        .acc_in,
        .acc_out(comb_acc_out)
    );

    InnerTile #(
        .K(K),
        .M(M),
        .OWIDTH(OWIDTH)
    ) u_tile (
        .clk,
        .reset,
        .a_signs(a_signs_array),
        .a_bits(a_bits_array),
        .w_signs(w_signs_array),
        .w_bits(w_bits_array),
        .shift_in,
        .mac_en,
        .acc_in(shift_acc_in),
        .acc_out(tile_acc_out)
    );

    function automatic logic signed [OWIDTH-1:0] reference_next(
        input logic signed [OWIDTH-1:0] ref_acc
    );
        integer signed total;
        integer hits;
        begin
            total = $signed(ref_acc);
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
        logic signed [OWIDTH-1:0] expected_comb;
        logic signed [OWIDTH-1:0] expected_tile;

        reset = 1'b1;
        mac_en = 1'b0;
        shift_in = 1'b0;
        shift_acc_in = '0;
        a_signs = '0;
        a_bits = '0;
        w_signs = '0;
        w_bits = '0;
        acc_in = '0;

        repeat (2) @(posedge clk);
        #0.01;
        reset = 1'b0;
        mac_en = 1'b1;

        for (int test_id = 0; test_id < 1000; test_id++) begin
            @(negedge clk);
            randomize_inputs();
            #0.01;

            expected_comb = reference_next(acc_in);
            if (comb_acc_out !== expected_comb)
                $fatal(1, "comb mismatch test=%0d got=%0d expected=%0d",
                    test_id, $signed(comb_acc_out), $signed(expected_comb));

            expected_tile = reference_next(tile_acc_out);
            @(posedge clk);
            #0.01;
            if (tile_acc_out !== expected_tile)
                $fatal(1, "registered mismatch test=%0d got=%0d expected=%0d",
                    test_id, $signed(tile_acc_out), $signed(expected_tile));
        end

        // Exercise the priority controls after the arithmetic regression.
        @(negedge clk);
        mac_en = 1'b0;
        shift_in = 1'b1;
        shift_acc_in = -24'sd123456;
        @(posedge clk);
        #0.01;
        if (tile_acc_out !== shift_acc_in)
            $fatal(1, "shift priority mismatch");

        reset = 1'b1;
        @(posedge clk);
        #0.01;
        if (tile_acc_out !== '0)
            $fatal(1, "reset priority mismatch");

        $display("PASS: combinational tile matches signed-popcount reference (1000 vectors)");
        $finish;
    end
endmodule
