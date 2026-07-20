`ifndef _bp_asym_activation_sum_v2_
`define _bp_asym_activation_sum_v2_

// Activation-sum pipeline that mirrors array_8's wavefront. Partial products
// move upward one row per cycle, so the corresponding qx terms must do the same
// before the shared result is delayed across output columns.
module bp_asym_activation_sum_v2 #(
    parameter int HEIGHT = 8,
    parameter int WIDTH = 8,
    parameter int IWIDTH = 8,
    parameter int SUM_WIDTH = IWIDTH + $clog2(HEIGHT)
) (
    input logic clk,
    input logic sum_en,
    input logic signed [IWIDTH-1:0] ifm [HEIGHT-1:0],
    output logic signed [SUM_WIDTH-1:0] sum_x [WIDTH-1:0]
);
    logic signed [SUM_WIDTH-1:0] row_pipe [HEIGHT-1:0];
    logic signed [SUM_WIDTH-1:0] col_pipe [WIDTH-1:0];

    integer h;
    integer w;
    // Resetless by design. HEIGHT+WIDTH valid input cycles flush all state.
    always_ff @(posedge clk) begin : P_WAVEFRONT
        if (sum_en) begin
            row_pipe[HEIGHT-1] <=
                {{(SUM_WIDTH-IWIDTH){ifm[HEIGHT-1][IWIDTH-1]}}, ifm[HEIGHT-1]};
            for (h = HEIGHT-2; h >= 0; h = h - 1)
                row_pipe[h] <=
                    {{(SUM_WIDTH-IWIDTH){ifm[h][IWIDTH-1]}}, ifm[h]} + row_pipe[h+1];

            // This first register accounts for array_8's input-register to
            // accumulator-register boundary at column zero.
            col_pipe[0] <= row_pipe[0];
            for (w = 1; w < WIDTH; w = w + 1)
                col_pipe[w] <= col_pipe[w-1];
        end
    end

    genvar c;
    generate
        for (c = 0; c < WIDTH; c++) begin : G_SUM_OUT
            assign sum_x[c] = col_pipe[c];
        end
    endgenerate
endmodule

`endif
