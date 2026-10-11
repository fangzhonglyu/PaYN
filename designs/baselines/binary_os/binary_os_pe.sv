`ifndef BINARY_OS_PE
`define BINARY_OS_PE

// One output-stationary binary PE: a signed IWIDTH-bit multiply-accumulate with a
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
//
// INT4X2 (a build-time choice, IWIDTH = 8 only; default 0 is the plain signed
// multiplier above).  With INT4X2 = 1 the multiplier is four nibble products,
// a = 16*aH + aL and w = 16*wH + wL (aH, wH signed):
//
//     a*w = 256*(aH*wH) + 16*(aH*wL + aL*wH) + aL*wL
//
// int4 = 0 (INT8): aL, wL are unsigned and the sum is the signed 8 x 8 product.
// int4 = 1 (two INT4 MACs): every nibble is a signed INT4 value, the aH*wH and
// aL*wL quadrants are gated off, and the two cross products, which already
// share weight 16, are the pair:
//
//     product = 16 * (aH*wL + aL*wH)
//
// Two multiplier builds (DUAL_BOOTH):
//
// 1 (default), Booth radix-4, like DC's choice for the plain a*w.  The weight
// is recoded into four digits d_k in {-2..2} from bits (w[2k+1], w[2k],
// w[2k-1]); d0 + 4*d1 is the signed low nibble in either mode, and digit 2's
// low bit w[3] (the carry into the high nibble) is gated off in INT4, so
// d2 + 4*d3 is the signed high nibble there.  Rows 0-1 multiply mA = a (INT8)
// or {aH, 0000} = 16*aH (INT4); rows 2-3 multiply mB = a or sext(aL).  So
//     INT8: a*s(wL) + 16*a*(s(wH) + w3) = a*w
//     INT4: 16*aH*s(wL) + 16*aL*s(wH)
// Each row is sel = 0 / m / 2m by the digit's magnitude, inverted when the
// digit is negative with its +1 in a shared correction row; the four rows, the
// correction and the accumulator go through one DW02_tree and one adder.
//
// 0, an AND-array partial-product matrix: bit a_i*w_j at weight 2^(i+j), gated
// off in INT4 when i and j sit in the same nibble half, negative when exactly
// one of i, j is a sign bit (bit 7 always, bit 3 in INT4); negative bits enter
// Baugh-Wooley style, complemented, with a per-mode constant row, all through
// one DW02_tree.  Lower energy than Booth (fewer glitches), larger.
//
// Single-PE synthesis with the flow's settings: Booth dual 224 um2, AND-array
// dual 247, DC's Booth INT8 PE 213 (an explicit Booth INT8 PE: 220).
//
// This is the sum-together subword-parallel layout of the precision-scalable
// MAC literature: one accumulator, no mux inside the MAC tree, so INT4 runs at
// twice the INT8 MAC rate on the same 8-bit operand hops.  Two conventions
// carry the cost instead of hardware: an A lane's high nibble pairs with the W
// lane's low nibble (A packs {a1, a0}, W packs {w0, w1}), and the accumulator
// holds 16x the INT4 dot product (exact; the output scale absorbs it).  With
// INT4X2 = 0 the int4 input is ignored.
module BinaryOSPE #(
    parameter int IWIDTH = 8,
    parameter int OWIDTH = 24,
    parameter int INT4X2 = 0,
    parameter int DUAL_BOOTH = 1    // INT4X2 = 1 only: 1 Booth radix-4, 0 AND array
) (
    input  logic clk,
    input  logic reset,
    input  logic shift_in,
    input  logic mac_en,
    input  logic int4,

    input  logic signed [IWIDTH-1:0] a_in,    // from west
    output logic signed [IWIDTH-1:0] a_out,   // to east
    input  logic signed [IWIDTH-1:0] w_in,    // from north
    output logic signed [IWIDTH-1:0] w_out,   // to south

    input  logic signed [OWIDTH-1:0] acc_in,  // from west
    output logic signed [OWIDTH-1:0] acc_out
);
    localparam int PROD_W = 2*IWIDTH;

    // Keep the synchronous reset at the accumulator's D pins.  Without this DC
    // may fold it into the MAC logic as an n & ~n cancellation (it does in the
    // INT4X2 netlist), which silicon resolves but 4-state gate simulation does
    // not: the ARM flops power up X, the reset edges latch it and the
    // accumulator feedback holds it.  No functional change.
    // synopsys sync_set_reset "reset"

    initial begin
        assert (IWIDTH > 1) else $error("IWIDTH must exceed the sign bit");
        assert (OWIDTH >= PROD_W)
            else $error("OWIDTH must hold a full IWIDTH x IWIDTH product");
        assert (INT4X2 == 0 || (INT4X2 == 1 && IWIDTH == 8))
            else $error("INT4X2 must be 0 or 1 (1 needs IWIDTH = 8)");
        assert (DUAL_BOOTH == 0 || DUAL_BOOTH == 1)
            else $error("DUAL_BOOTH must be 0 or 1");
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

    if (INT4X2 == 0) begin : g_mul
        assign product = a_reg * w_reg;
        assign acc_next = acc_out + OWIDTH'(product);
    end else if (DUAL_BOOTH == 1) begin : g_mul_int4x2_booth
        logic signed [7:0] mult_a, mult_b;        // rows 0-1, rows 2-3
        logic [8:0] w_ext;                        // {w, w[-1] = 0}
        logic [6*OWIDTH-1:0] rows;
        logic [OWIDTH-1:0] sum0, sum1;

        assign mult_a = int4 ? {a_reg[7:4], 4'b0} : a_reg;
        assign mult_b = int4 ? {{4{a_reg[3]}}, a_reg[3:0]} : a_reg;
        assign w_ext = {w_reg, 1'b0};

        for (genvar k = 0; k < 4; k++) begin : g_booth
            logic b0, b1, b2, neg, one, two;
            logic signed [8:0] m, sel;
            assign b2 = w_ext[2*k+2];
            assign b1 = w_ext[2*k+1];
            assign b0 = (k == 2) ? (w_ext[2*k] & !int4) : w_ext[2*k];
            assign neg = b2;
            assign one = b1 ^ b0;
            assign two = (b2 & !b1 & !b0) | (!b2 & b1 & b0);
            assign m = (k < 2) ? 9'(mult_a) : 9'(mult_b);
            assign sel = one ? m : two ? (m <<< 1) : 9'sd0;
            assign rows[k*OWIDTH +: OWIDTH] = OWIDTH'($signed(neg ? ~sel : sel) <<< (2*k));
        end
        // The +1 of every inverted row (an inverted 0 row, ~0 + 1 = 0, stays exact).
        assign rows[4*OWIDTH +: OWIDTH] = OWIDTH'({g_booth[3].neg, 1'b0, g_booth[2].neg, 1'b0,
                                                   g_booth[1].neg, 1'b0, g_booth[0].neg});
        assign rows[5*OWIDTH +: OWIDTH] = acc_out;

        DW02_tree #(
            .num_inputs(6),
            .input_width(OWIDTH),
            .verif_en(1)
        ) u_tree (
            .INPUT(rows),
            .OUT0(sum0),
            .OUT1(sum1)
        );
        assign product = '0;    // the rows go straight into the tree
        assign acc_next = sum0 + sum1;
    end else begin : g_mul_int4x2
        // Sum of the negative bits' weights per mode, as the constant row.
        function automatic logic [OWIDTH-1:0] correction(input logic m4);
            logic [OWIDTH-1:0] c;
            c = '0;
            for (int i = 0; i < 8; i++)
                for (int j = 0; j < 8; j++)
                    if ((!m4 || ((i >= 4) != (j >= 4))) &&
                        (((i == 7) || (m4 && i == 3)) != ((j == 7) || (m4 && j == 3))))
                        c = c - (OWIDTH'(1) << (i + j));
            correction = c;
        endfunction
        localparam logic [OWIDTH-1:0] CORR_INT8 = correction(1'b0);
        localparam logic [OWIDTH-1:0] CORR_INT4 = correction(1'b1);

        logic [10*OWIDTH-1:0] rows;
        logic [OWIDTH-1:0] sum0, sum1;

        for (genvar i = 0; i < 8; i++) begin : g_pp_row
            logic [7:0] pp;
            for (genvar j = 0; j < 8; j++) begin : g_pp
                localparam bit CROSS = (i >= 4) != (j >= 4);
                localparam bit NEG_INT8 = (i == 7) != (j == 7);
                localparam bit NEG_INT4 = CROSS && (((i == 7) || (i == 3)) != ((j == 7) || (j == 3)));
                logic on, neg;
                assign on = CROSS || !int4;
                assign neg = int4 ? NEG_INT4 : NEG_INT8;
                assign pp[j] = (a_reg[i] & w_reg[j] & on) ^ neg;
            end
            assign rows[i*OWIDTH +: OWIDTH] = OWIDTH'({8'b0, pp} << i);
        end
        assign rows[8*OWIDTH +: OWIDTH] = int4 ? CORR_INT4 : CORR_INT8;
        assign rows[9*OWIDTH +: OWIDTH] = acc_out;

        DW02_tree #(
            .num_inputs(10),
            .input_width(OWIDTH),
            .verif_en(1)
        ) u_tree (
            .INPUT(rows),
            .OUT0(sum0),
            .OUT1(sum1)
        );
        assign product = '0;    // the products go straight into the tree
        assign acc_next = sum0 + sum1;
    end

    always_ff @(posedge clk) begin
        if (reset)          acc_out <= '0;
        else if (shift_in)  acc_out <= acc_in;
        else if (mac_en)    acc_out <= acc_next;
    end
endmodule

`endif // BINARY_OS_PE
