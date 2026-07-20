`timescale 1ns/1ps
`include "baselines/binary_parallel/asym_activation_sum_v2.sv"
`include "baselines/binary_parallel/asym_column_correction_v1.sv"

module Top;
    localparam int HEIGHT = 8;
    localparam int WIDTH = 8;
    logic clk = 0;
    logic sum_en = 1;
    logic corr_en;
    logic signed [7:0] ifm [HEIGHT-1:0];
    logic signed [10:0] sum_x [WIDTH-1:0];
    logic signed [23:0] raw_sum, corrected_sum;
    logic signed [7:0] ifm_zp, wght_zp;
    logic signed [11:0] centered_wsum;
    integer history [0:HEIGHT-1][0:HEIGHT+WIDTH-1];

    always #1.25 clk = ~clk;

    bp_asym_activation_sum_v2 U_asym_sum (
        .clk(clk), .sum_en(sum_en), .ifm(ifm), .sum_x(sum_x)
    );
    bp_asym_column_correction_v1 U_asym_corr (
        .corr_en(corr_en), .raw_sum(raw_sum), .ifm_zp(ifm_zp),
        .wght_zp(wght_zp), .sum_x(sum_x[0]),
        .centered_wsum(centered_wsum), .corrected_sum(corrected_sum)
    );

    task automatic shift_expected;
        for (int h = 0; h < HEIGHT; h++) begin
            for (int d = HEIGHT+WIDTH-1; d > 0; d--)
                history[h][d] = history[h][d-1];
            history[h][0] = $signed(ifm[h]);
        end
    endtask

    initial begin
        corr_en = 0; raw_sum = 0; ifm_zp = 0; wght_zp = 0;
        centered_wsum = 0;
        for (int h = 0; h < HEIGHT; h++) begin
            ifm[h] = 0;
            for (int d = 0; d < HEIGHT+WIDTH; d++) history[h][d] = 0;
        end

        repeat (HEIGHT+WIDTH+1) begin
            @(posedge clk); shift_expected(); #0.1;
        end
        // Independent row sequences catch the incorrect sum-then-delay v1
        // topology, while every value remains in signed-int8 range.
        for (int sample = 1; sample <= 24; sample++) begin
            @(negedge clk);
            for (int h = 0; h < HEIGHT; h++) ifm[h] = sample + 9*h - 64;
            @(posedge clk); shift_expected(); #0.1;
            for (int w = 0; w < WIDTH; w++) begin
                integer expected;
                expected = 0;
                for (int h = 0; h < HEIGHT; h++)
                    expected += history[h][1+h+w];
                if ($signed(sum_x[w]) !== expected) begin
                    $error("wavefront col %0d: got %0d expected %0d",
                           w, $signed(sum_x[w]), expected);
                    $fatal;
                end
            end
        end

        @(negedge clk);
        for (int h = 0; h < HEIGHT; h++) ifm[h] = h - 4;
        repeat (HEIGHT+WIDTH+1) @(posedge clk);
        #0.1;
        raw_sum = 24'sd10000; ifm_zp = -8'sd5; wght_zp = 8'sd7;
        centered_wsum = -12'sd123; corr_en = 1; #0.1;
        if ($signed(sum_x[0]) !== -4 || $signed(corrected_sum) !== 9413)
            $fatal(1, "correction got sum=%0d result=%0d", sum_x[0], corrected_sum);
        corr_en = 0; #0.1;
        if (corrected_sum !== 0) $fatal(1, "operand isolation failed");
        $display("PASS: wavefront-aligned asymmetric correction v2");
        $finish;
    end
endmodule
