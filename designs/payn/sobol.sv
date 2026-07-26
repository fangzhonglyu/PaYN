`ifndef ASTRAEA_SC_SOBOL
`define ASTRAEA_SC_SOBOL

`timescale 1ns/1ps

// One digitally shifted Sobol sequence. DIRECTION_SET=0 is the identity
// direction table. DIRECTION_SET=1 is the decorrelated 8-bit table previously
// used for the weight stream.
module sobol_generator #(
    parameter int WIDTH = 8,
    parameter int DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT = '0,
    parameter logic FULL_PERIOD_WRAP = 1'b0
) (
    input logic clk,
    input logic reset,
    input logic enable,
    output logic [WIDTH-1:0] random_value
);
    logic [WIDTH-1:0] count;
    logic [WIDTH-1:0] selected_direction;
    logic direction_found;

    function automatic logic [WIDTH-1:0] direction_vector(input int index);
        logic [7:0] decorrelated_vector;
        begin
            decorrelated_vector = '0;
            if (DIRECTION_SET == 0) begin
                direction_vector = '0;
                direction_vector[WIDTH-1-index] = 1'b1;
            end else begin
                case (index)
                    0: decorrelated_vector = 8'h80;
                    1: decorrelated_vector = 8'h40;
                    2: decorrelated_vector = 8'h20;
                    3: decorrelated_vector = 8'h10;
                    4: decorrelated_vector = 8'h48;
                    5: decorrelated_vector = 8'h04;
                    6: decorrelated_vector = 8'h52;
                    7: decorrelated_vector = 8'hff;
                    default: decorrelated_vector = '0;
                endcase
                if (WIDTH == 8)
                    direction_vector = WIDTH'(decorrelated_vector);
                else
                    direction_vector =
                        WIDTH'(decorrelated_vector >> (8 - WIDTH));
            end
        end
    endfunction

    initial begin
        assert (WIDTH > 0) else $error("WIDTH must be positive");
        assert (DIRECTION_SET inside {0, 1})
            else $error("DIRECTION_SET must be 0 or 1");
        if (DIRECTION_SET == 1)
            assert (WIDTH inside {7, 8})
                else $error("DIRECTION_SET=1 requires WIDTH=7 or WIDTH=8");
    end

    // Select the direction vector indexed by the least-significant zero in
    // the current sample index.
    always_comb begin
        selected_direction = '0;
        direction_found = 1'b0;
        for (int index = 0; index < WIDTH; index++) begin
            if (!direction_found && !count[index]) begin
                selected_direction = direction_vector(index);
                direction_found = 1'b1;
            end
        end
        // The legacy generator deliberately holds its final value when count
        // is all ones.  A native WIDTH-bit full-period stream instead returns
        // to DIGITAL_SHIFT on that last update, so all 2**WIDTH thresholds
        // appear exactly once.  Keep the corrected behavior opt-in so existing
        // checkpoints and their bit-exact traces are unchanged.
        if (FULL_PERIOD_WRAP && !direction_found)
            selected_direction = direction_vector(WIDTH - 1);
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            count <= '0;
            random_value <= DIGITAL_SHIFT;
        end else if (enable) begin
            // Preserve the established SC sequence: an all-ones count selects
            // no direction vector, so the final sample repeats before wrap.
            count <= count + 1'b1;
            random_value <= random_value ^ selected_direction;
        end
    end
endmodule

// M parallel Sobol sequences with distinct digital shifts and one shared
// direction table. random_values[lane*WIDTH +: WIDTH] is lane's value.
module sobol_bank #(
    parameter int WIDTH = 8,
    parameter int M = 16,
    parameter int DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT_BASE = 'h17,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT_STRIDE = 'h53,
    parameter logic FULL_PERIOD_WRAP = 1'b0
) (
    input logic clk,
    input logic reset,
    input logic enable,
    output logic [M*WIDTH-1:0] random_values
);
    initial begin
        assert (M > 0) else $error("M must be positive");
    end

    for (genvar lane = 0; lane < M; lane++) begin : g_lane
        localparam logic [WIDTH-1:0] LANE_SHIFT =
            DIGITAL_SHIFT_BASE ^ WIDTH'(DIGITAL_SHIFT_STRIDE * lane);

        sobol_generator #(
            .WIDTH(WIDTH),
            .DIRECTION_SET(DIRECTION_SET),
            .DIGITAL_SHIFT(LANE_SHIFT),
            .FULL_PERIOD_WRAP(FULL_PERIOD_WRAP)
        ) u_generator (
            .clk,
            .reset,
            .enable,
            .random_value(random_values[lane*WIDTH +: WIDTH])
        );
    end
endmodule

`endif
