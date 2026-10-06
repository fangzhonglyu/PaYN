`timescale 1ns/1ps

`include "payn/sobol.sv"

module Top;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic enable = 1'b0;
    logic [7:0] random_value;
    logic [31:0] bank_values;

    always #1.25 clk = ~clk;

    sobol_generator #(
        .WIDTH(8),
        .DIRECTION_SET(0),
        .DIGITAL_SHIFT(8'h00)
    ) dut (
        .clk,
        .reset,
        .enable,
        .random_value
    );

    sobol_bank #(
        .WIDTH(8),
        .M(4),
        .DIRECTION_SET(1),
        .DIGITAL_SHIFT_BASE(8'h17),
        .DIGITAL_SHIFT_STRIDE(8'h53)
    ) bank (
        .clk,
        .reset,
        .enable,
        .random_values(bank_values)
    );

    task automatic step_and_check(input logic [7:0] expected);
        @(posedge clk);
        #0.1;
        assert (random_value === expected)
            else $fatal(1, "expected Sobol value %02h, got %02h",
                        expected, random_value);
    endtask

    initial begin
        #0.1;
        assert (random_value === 8'h00)
            else $fatal(1, "asynchronous reset did not initialize sequence");

        @(negedge clk);
        reset = 1'b0;
        enable = 1'b1;
        step_and_check(8'h80);
        step_and_check(8'hc0);
        step_and_check(8'h40);
        step_and_check(8'h60);

        @(negedge clk);
        enable = 1'b0;
        repeat (2) begin
            @(posedge clk);
            #0.1;
            assert (random_value === 8'h60)
                else $fatal(1, "disabled Sobol generator advanced");
        end

        assert (bank_values[7:0] != bank_values[15:8] &&
                bank_values[7:0] != bank_values[23:16] &&
                bank_values[7:0] != bank_values[31:24])
            else $fatal(1, "bank digital shifts are not distinct");

        reset = 1'b1;
        #0.1;
        reset = 1'b0;
        enable = 1'b1;
        repeat (256) @(posedge clk);
        #0.1;
        assert (random_value === 8'h01)
            else $fatal(1, "Sobol all-ones count did not repeat the final sample");
        step_and_check(8'h81);

        $display("PASS: Sobol sequence, hold, bank shifts, and legacy wrap");
        $finish;
    end
endmodule
