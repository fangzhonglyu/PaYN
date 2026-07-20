`ifndef _bp_asym_column_correction_v1_
`define _bp_asym_column_correction_v1_

// Exact signed asymmetric correction for one output column:
//   sum((qx-zx)*(qw-zw)) = raw - zw*sum(qx) - zx*sum(qw-zw)
// centered_wsum is precomputed when the stationary weights are prepared.
module bp_asym_column_correction_v1 #(
    parameter int IWIDTH = 8,
    parameter int SUMX_WIDTH = 11,
    parameter int WSUM_WIDTH = 12,
    parameter int OWIDTH = 24
) (
    input  logic corr_en,
    input  logic signed [OWIDTH-1:0] raw_sum,
    input  logic signed [IWIDTH-1:0] ifm_zp,
    input  logic signed [IWIDTH-1:0] wght_zp,
    input  logic signed [SUMX_WIDTH-1:0] sum_x,
    input  logic signed [WSUM_WIDTH-1:0] centered_wsum,
    output logic signed [OWIDTH-1:0] corrected_sum
);
    localparam int WPROD_WIDTH = IWIDTH + SUMX_WIDTH;
    localparam int XPROD_WIDTH = IWIDTH + WSUM_WIDTH;

    logic signed [OWIDTH-1:0] raw_active;
    logic signed [SUMX_WIDTH-1:0] sum_x_active;
    logic signed [WSUM_WIDTH-1:0] centered_wsum_active;
    logic signed [WPROD_WIDTH-1:0] w_correction;
    logic signed [XPROD_WIDTH-1:0] x_correction;
    logic signed [OWIDTH-1:0] w_correction_ext;
    logic signed [OWIDTH-1:0] x_correction_ext;

    // Operand isolation prevents the multipliers and subtractors from reacting
    // while the corresponding array output is invalid or intentionally idle.
    assign raw_active = corr_en ? raw_sum : '0;
    assign sum_x_active = corr_en ? sum_x : '0;
    assign centered_wsum_active = corr_en ? centered_wsum : '0;
    assign w_correction = wght_zp * sum_x_active;
    assign x_correction = ifm_zp * centered_wsum_active;
    assign w_correction_ext = {{(OWIDTH-WPROD_WIDTH){w_correction[WPROD_WIDTH-1]}},
                               w_correction};
    assign x_correction_ext = {{(OWIDTH-XPROD_WIDTH){x_correction[XPROD_WIDTH-1]}},
                               x_correction};
    assign corrected_sum = raw_active - w_correction_ext - x_correction_ext;
endmodule

`endif
