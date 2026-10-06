`ifndef PAYN_CNSB_PHYS_PROBE
`define PAYN_CNSB_PHYS_PROBE

`timescale 1ns/1ps

// Synthesis probes for the CNSB / spatial-Booth INT-mode review (physical and
// timing lens).  Nothing here is part of the accepted design; the accepted
// payn/sobol.sv is only included, never edited.
//
//  * cnsb_sobol_pair_base   : the two accepted Sobol banks, as in the CSA top.
//  * cnsb_sobol_pair_preset : the same banks with a synchronous INT preset to
//                             the searched comparator constants (PRESETS
//                             "r4rows" in model_red_team_novel.py).  The
//                             preset sits on the random_value D side.
//  * cnsb_east_combiner_*   : one PE row's INT8 east-edge combiner on the
//                             drain stream, s_i = T0 + 4T1 + 16T2 + 64T3 and a
//                             one-step Horner out = 16*H + s, with and without
//                             an input register on acc_out_east.

`include "payn/sobol.sv"

module sobol_generator_int_preset #(
    parameter int WIDTH = 8,
    parameter int DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT = '0,
    parameter logic [WIDTH-1:0] PRESET = '0,
    parameter logic FULL_PERIOD_WRAP = 1'b0
) (
    input  logic clk,
    input  logic reset,
    input  logic enable,
    input  logic preset,
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
                direction_vector = WIDTH'(decorrelated_vector);
            end
        end
    endfunction

    always_comb begin
        selected_direction = '0;
        direction_found = 1'b0;
        for (int index = 0; index < WIDTH; index++) begin
            if (!direction_found && !count[index]) begin
                selected_direction = direction_vector(index);
                direction_found = 1'b1;
            end
        end
        if (FULL_PERIOD_WRAP && !direction_found)
            selected_direction = direction_vector(WIDTH - 1);
    end

    // INT preset: random_value only.  count is left alone so the SC sequence
    // position is not disturbed beyond what the global reset restores.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            count <= '0;
            random_value <= DIGITAL_SHIFT;
        end else begin
            if (enable)
                count <= count + 1'b1;
            if (preset)
                random_value <= PRESET;
            else if (enable)
                random_value <= random_value ^ selected_direction;
        end
    end
endmodule

module sobol_bank_int_preset #(
    parameter int WIDTH = 8,
    parameter int M = 16,
    parameter int DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT_BASE = 'h17,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT_STRIDE = 'h53,
    parameter logic [M*WIDTH-1:0] PRESET_VALUES = '0,
    parameter logic FULL_PERIOD_WRAP = 1'b0
) (
    input  logic clk,
    input  logic reset,
    input  logic enable,
    input  logic preset,
    output logic [M*WIDTH-1:0] random_values
);
    for (genvar lane = 0; lane < M; lane++) begin : g_lane
        localparam logic [WIDTH-1:0] LANE_SHIFT =
            DIGITAL_SHIFT_BASE ^ WIDTH'(DIGITAL_SHIFT_STRIDE * lane);
        sobol_generator_int_preset #(
            .WIDTH(WIDTH), .DIRECTION_SET(DIRECTION_SET),
            .DIGITAL_SHIFT(LANE_SHIFT),
            .PRESET(PRESET_VALUES[lane*WIDTH +: WIDTH]),
            .FULL_PERIOD_WRAP(FULL_PERIOD_WRAP)
        ) u_generator (
            .clk, .reset, .enable, .preset,
            .random_value(random_values[lane*WIDTH +: WIDTH])
        );
    end
endmodule

module cnsb_sobol_pair_base (
    input  logic clk,
    input  logic reset,
    input  logic rng_en,
    output logic [127:0] a_random_values,
    output logic [127:0] w_random_values
);
    sobol_bank #(.WIDTH(8), .M(16), .DIRECTION_SET(0),
        .DIGITAL_SHIFT_BASE(8'h17), .DIGITAL_SHIFT_STRIDE(8'h53)
    ) u_a_rng (.clk, .reset, .enable(rng_en), .random_values(a_random_values));
    sobol_bank #(.WIDTH(8), .M(16), .DIRECTION_SET(1),
        .DIGITAL_SHIFT_BASE(8'h9d), .DIGITAL_SHIFT_STRIDE(8'h2b)
    ) u_w_rng (.clk, .reset, .enable(rng_en), .random_values(w_random_values));
endmodule

module cnsb_sobol_pair_preset (
    input  logic clk,
    input  logic reset,
    input  logic rng_en,
    input  logic int_preset,
    output logic [127:0] a_random_values,
    output logic [127:0] w_random_values
);
    // PRESETS["r4rows"] from model_red_team_novel.py, lane 0 in the low byte.
    localparam logic [127:0] CNSB_PRESET_ROW = {
        8'd139, 8'd155, 8'd207, 8'd250, 8'd40, 8'd148, 8'd44, 8'd253,
        8'd93, 8'd142, 8'd27, 8'd159, 8'd173, 8'd109, 8'd112, 8'd184};
    localparam logic [127:0] CNSB_PRESET_COL = {
        8'd37, 8'd75, 8'd91, 8'd96, 8'd181, 8'd190, 8'd95, 8'd146,
        8'd9, 8'd152, 8'd147, 8'd229, 8'd246, 8'd204, 8'd203, 8'd243};
    sobol_bank_int_preset #(.WIDTH(8), .M(16), .DIRECTION_SET(0),
        .DIGITAL_SHIFT_BASE(8'h17), .DIGITAL_SHIFT_STRIDE(8'h53),
        .PRESET_VALUES(CNSB_PRESET_ROW)
    ) u_a_rng (.clk, .reset, .enable(rng_en), .preset(int_preset),
               .random_values(a_random_values));
    sobol_bank_int_preset #(.WIDTH(8), .M(16), .DIRECTION_SET(1),
        .DIGITAL_SHIFT_BASE(8'h9d), .DIGITAL_SHIFT_STRIDE(8'h2b),
        .PRESET_VALUES(CNSB_PRESET_COL)
    ) u_w_rng (.clk, .reset, .enable(rng_en), .preset(int_preset),
               .random_values(w_random_values));
endmodule

// One PE row of the 'r4rows' INT8 east combiner.  Tile row h = 4i+p carries
// radix-4 digit p of activation i; the drain delivers column v = 2j+q with
// q=1 first.  q_hi marks the q=1 drain step.
module cnsb_east_combiner #(
    parameter int OW = 24,
    parameter int SW = 32,
    parameter int CW = 36,
    parameter bit IN_REG = 1'b0
) (
    input  logic clk,
    input  logic reset,
    input  logic drain_en,
    input  logic q_hi,
    input  logic [8*OW-1:0] acc_out_east,
    output logic [2*CW-1:0] out,
    output logic out_valid
);
    logic [8*OW-1:0] east;
    logic en_d, q_d;

    if (IN_REG) begin : g_in_reg
        always_ff @(posedge clk) begin
            east <= acc_out_east;
            en_d <= reset ? 1'b0 : drain_en;
            q_d <= q_hi;
        end
    end else begin : g_no_in_reg
        assign east = acc_out_east;
        assign en_d = drain_en;
        assign q_d = q_hi;
    end

    logic signed [SW-1:0] s [2];
    logic signed [SW-1:0] h [2];

    for (genvar i = 0; i < 2; i++) begin : g_group
        always_comb begin
            s[i] = '0;
            for (int p = 0; p < 4; p++)
                s[i] += SW'($signed(east[(4*i+p)*OW +: OW])) <<< (2*p);
        end

        always_ff @(posedge clk) begin
            if (en_d && q_d)
                h[i] <= s[i];
            if (en_d && !q_d)
                out[i*CW +: CW] <= (CW'(h[i]) <<< 4) + CW'(s[i]);
        end
    end

    always_ff @(posedge clk)
        out_valid <= reset ? 1'b0 : (en_d && !q_d);
endmodule

module cnsb_east_combiner_noreg (
    input  logic clk, reset, drain_en, q_hi,
    input  logic [191:0] acc_out_east,
    output logic [71:0] out,
    output logic out_valid
);
    cnsb_east_combiner #(.IN_REG(1'b0)) u (.*);
endmodule

module cnsb_east_combiner_inreg (
    input  logic clk, reset, drain_en, q_hi,
    input  logic [191:0] acc_out_east,
    output logic [71:0] out,
    output logic out_valid
);
    cnsb_east_combiner #(.IN_REG(1'b1)) u (.*);
endmodule

`endif
