`ifndef PAYN_BINARY_INT8_MAC_COMB
`define PAYN_BINARY_INT8_MAC_COMB

// Combinational binary reference used by ROC_flow.  This is the same signed
// INT8 multiply-plus-32-bit-accumulator surface as ROC_flow's historical
// INT8_MAC_COMB target, rebuilt with the current characterized-cell subset.
module binary_int8_mac_comb (
    input  logic clk,
    input  logic reset,
    input  logic signed [7:0] a,
    input  logic signed [7:0] b,
    input  logic signed [31:0] c,
    output logic signed [31:0] y
);
    assign y = (a * b) + c;
endmodule

`endif // PAYN_BINARY_INT8_MAC_COMB
