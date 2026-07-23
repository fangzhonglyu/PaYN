`ifndef PAYN_WDBI_WORD_ENCODE_NEXT
`define PAYN_WDBI_WORD_ENCODE_NEXT

// One combinational step of transition-aware bus inversion.  State is kept by
// the enclosing operand pipe so its physical registers remain visible to the
// placement flow.  keep=1 transmits raw_word; keep=0 transmits its complement.
module DBIWordEncodeNext #(
    parameter int M = 16
) (
    input  logic [M-1:0] raw_word,
    input  logic [M-1:0] previous_encoded_word,
    input  logic         previous_keep,
    input  logic         previous_valid,
    output logic [M-1:0] encoded_word,
    output logic         keep
);
    localparam int DIST_W = $clog2(M + 1);

    logic [DIST_W-1:0] normal_distance;
    logic [DIST_W-1:0] inverted_distance;

    initial begin
        assert (M > 0) else $error("M must be positive");
    end

    always_comb begin
        normal_distance = DIST_W'(
            $countones(raw_word ^ previous_encoded_word));
        inverted_distance = DIST_W'(M) - normal_distance;

        // The first valid word is sent normally because the resetless encoded
        // data registers have no meaningful predecessor.  On equal distances,
        // retain the previous polarity to avoid an unnecessary keep transition.
        if (!previous_valid)
            keep = 1'b1;
        else if (normal_distance < inverted_distance)
            keep = 1'b1;
        else if (inverted_distance < normal_distance)
            keep = 1'b0;
        else
            keep = previous_keep;

        encoded_word = raw_word ~^ {M{keep}};
    end
endmodule

`endif
