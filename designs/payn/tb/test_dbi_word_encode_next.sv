`timescale 1ns/1ps

`include "payn/variants/wdbi/common/dbi_word_encode_next.sv"

module Top;
    localparam int M = 8;

    logic [M-1:0] raw_word;
    logic [M-1:0] previous_encoded_word;
    logic previous_keep;
    logic previous_valid;
    logic [M-1:0] encoded_word;
    logic keep;

    DBIWordEncodeNext #(.M(M)) dut (.*);

    function automatic int distance(
        input logic [M-1:0] lhs,
        input logic [M-1:0] rhs
    );
        return $countones(lhs ^ rhs);
    endfunction

    task automatic check_case(
        input logic [M-1:0] raw,
        input logic [M-1:0] previous,
        input logic old_keep,
        input logic valid
    );
        int selected_distance;
        int alternate_distance;
        raw_word = raw;
        previous_encoded_word = previous;
        previous_keep = old_keep;
        previous_valid = valid;
        #1;
        assert ((encoded_word ~^ {M{keep}}) === raw_word)
            else $fatal(1, "DBI decode mismatch");
        if (!valid) begin
            assert (keep === 1'b1 && encoded_word === raw_word)
                else $fatal(1, "first word was not sent normally");
        end else begin
            selected_distance = distance(encoded_word, previous);
            alternate_distance = distance(~encoded_word, previous);
            assert (selected_distance <= alternate_distance)
                else $fatal(1, "DBI selected the higher-transition polarity");
            if (selected_distance == alternate_distance)
                assert (keep === old_keep)
                    else $fatal(1, "tie did not retain previous polarity");
        end
    endtask

    initial begin
        check_case(8'h5a, 8'h00, 1'b0, 1'b0);
        check_case(8'h03, 8'h00, 1'b1, 1'b1);
        check_case(8'hfe, 8'h00, 1'b1, 1'b1);
        check_case(8'h0f, 8'h00, 1'b1, 1'b1);
        check_case(8'h0f, 8'h00, 1'b0, 1'b1);
        $display("PASS: DBI word encoder polarity and decode checks");
        $finish;
    end
endmodule
