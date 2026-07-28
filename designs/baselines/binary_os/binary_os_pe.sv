`ifndef BINARY_OS_PE
`define BINARY_OS_PE

// One output-stationary binary PE: a single INT8 multiply-accumulate with a
// stationary accumulator and its own operand pipeline registers.
//
// Everything the PE consumes is local.  A arrives from the west, is registered
// here, and is forwarded east; W arrives from the north, is registered here, and
// is forwarded south.  The multiplier reads only this PE's two registers, so no
// operand net is shared between PEs -- the array is a true systolic mesh, not a
// broadcast block.
//
// The accumulator is stationary: on every enabled cycle it absorbs the local
// signed product.  `shift_in` overrides the MAC path and loads the west
// neighbour's accumulator, which turns a PE row into the row-serial drain shift
// register.  That is the control contract of the PaYN `InnerTile` -- reset, then
// shift, then MAC -- with the K-lane stochastic popcount replaced by one binary
// multiplier.
//
// Exactly three registers live here: an IWIDTH A hop, an IWIDTH W hop, and the
// OWIDTH accumulator (8 + 8 + 24 = 40 flops at the default widths).  One PE is
// one MAC per cycle, which is what throughput-matches PaYN: an InnerTile carries
// K=8 spatial lanes but needs T/M=8 cycles to retire that K=8 dot product, so it
// too averages one MAC per cycle per accumulator.
//
// Because each operand takes one cycle per PE hop, the edge driver must apply
// the conventional systolic skew: A slice t enters row h at cycle t+h and W
// slice t enters column v at cycle t+v, so both reach PE (h,v) at cycle t+h+v+1.
module BinaryOSPE #(
    parameter int IWIDTH = 8,
    parameter int OWIDTH = 24
) (
    input  logic clk,
    input  logic reset,
    input  logic shift_in,
    input  logic mac_en,

    input  logic signed [IWIDTH-1:0] a_in,    // from west
    output logic signed [IWIDTH-1:0] a_out,   // to east
    input  logic signed [IWIDTH-1:0] w_in,    // from north
    output logic signed [IWIDTH-1:0] w_out,   // to south

    input  logic signed [OWIDTH-1:0] acc_in,  // from west
    output logic signed [OWIDTH-1:0] acc_out
);
    localparam int PROD_W = 2*IWIDTH;

    initial begin
        assert (IWIDTH > 1) else $error("IWIDTH must exceed the sign bit");
        assert (OWIDTH >= PROD_W)
            else $error("OWIDTH must hold a full IWIDTH x IWIDTH product");
    end

    // Local operand hop registers.  Unconditional, like the PaYN InnerPE
    // magnitude pipe: in an output-stationary array both operands are re-issued
    // every cycle, so there is nothing to hold and no enable to spend.
    logic signed [IWIDTH-1:0] a_reg;
    logic signed [IWIDTH-1:0] w_reg;

    always_ff @(posedge clk) begin
        a_reg <= a_in;
        w_reg <= w_in;
    end

    assign a_out = a_reg;
    assign w_out = w_reg;

    logic signed [PROD_W-1:0] product;
    logic signed [OWIDTH-1:0] acc_next;

    assign product  = a_reg * w_reg;
    assign acc_next = acc_out + OWIDTH'(product);

    always_ff @(posedge clk) begin
        if (reset)          acc_out <= '0;
        else if (shift_in)  acc_out <= acc_in;
        else if (mac_en)    acc_out <= acc_next;
    end
endmodule

`endif // BINARY_OS_PE
