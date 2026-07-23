`ifndef PAYN_WDBI_COUNTCORRECT_INNER_PE
`define PAYN_WDBI_COUNTCORRECT_INNER_PE

`include "payn/variants/wdbi/common/dbi_word_encode_next.sv"
`include "payn/variants/wdbi/countcorrect/inner_tile_wdbi_countcorrect.sv"

module InnerPEWDBICountCorrect #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int OWIDTH = 16
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic [M-1:0] a_bits_in  [N_H][K],
    input  logic         a_signs_in [N_H][K],
    input  logic [M-1:0] w_bits_in  [N_W][K],
    input  logic         w_signs_in [N_W][K],
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,
    output logic [M-1:0] a_bits_out  [N_H][K],
    output logic         a_signs_out [N_H][K],
    output logic [M-1:0] w_bits_out  [N_W][K],
    output logic         w_signs_out [N_W][K],
    output logic load_a_sign_out,
    output logic load_w_sign_out,
    input  logic signed [OWIDTH-1:0] acc_in_west  [N_H],
    output logic signed [OWIDTH-1:0] acc_out_east [N_H]
);
    localparam int LANE_W = $clog2(M + 1);

    logic [M-1:0] a_bits_pipe [N_H][K];
    logic [LANE_W-1:0] a_count [N_H][K];
    logic         a_signs_pipe [N_H][K];
    logic [M-1:0] w_encoded_pipe [N_W][K];
    logic         w_keep_pipe [N_W][K];
    logic [M-1:0] w_encoded_next [N_W][K];
    logic         w_keep_next [N_W][K];
    logic         w_dbi_valid_q;
    logic         w_signs_pipe [N_W][K];
    logic load_a_sign_q, load_w_sign_q;

    initial begin
        assert (K > 0) else $error("K must be positive");
        assert (M > 0) else $error("M must be positive");
        assert (N_H > 0) else $error("N_H must be positive");
        assert (N_W > 0) else $error("N_W must be positive");
    end

    for (genvar h = 0; h < N_H; h++) begin : g_a_count_h
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign a_count[h][d] = LANE_W'($countones(a_bits_pipe[h][d]));
        end
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_dbi_v
        for (genvar d = 0; d < K; d++) begin : g_depth
            DBIWordEncodeNext #(.M(M)) u_encoder (
                .raw_word(w_bits_in[v][d]),
                .previous_encoded_word(w_encoded_pipe[v][d]),
                .previous_keep(w_keep_pipe[v][d]),
                .previous_valid(w_dbi_valid_q),
                .encoded_word(w_encoded_next[v][d]),
                .keep(w_keep_next[v][d])
            );
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            load_a_sign_q <= 1'b0;
            load_w_sign_q <= 1'b0;
        end else begin
            load_a_sign_q <= load_a_sign_in;
            load_w_sign_q <= load_w_sign_in;
        end
    end

    always_ff @(posedge clk) begin
        for (int h = 0; h < N_H; h++) begin
            for (int d = 0; d < K; d++) begin
                a_bits_pipe[h][d] <= a_bits_in[h][d];
                if (load_a_sign_q)
                    a_signs_pipe[h][d] <= a_signs_in[h][d];
            end
        end
        for (int v = 0; v < N_W; v++) begin
            for (int d = 0; d < K; d++) begin
                if (load_w_sign_q)
                    w_signs_pipe[v][d] <= w_signs_in[v][d];
            end
        end
    end

    always_ff @(posedge clk) begin
        // Keep the wide encoded bank truly resetless/unconditional so clock
        // gating does not infer a reset-controlled enable over every data bit.
        for (int v = 0; v < N_W; v++)
            for (int d = 0; d < K; d++)
                w_encoded_pipe[v][d] <= w_encoded_next[v][d];

        if (reset) begin
            w_dbi_valid_q <= 1'b0;
            for (int v = 0; v < N_W; v++)
                for (int d = 0; d < K; d++)
                    w_keep_pipe[v][d] <= 1'b1;
        end else begin
            w_dbi_valid_q <= 1'b1;
            for (int v = 0; v < N_W; v++) begin
                for (int d = 0; d < K; d++)
                    w_keep_pipe[v][d] <= w_keep_next[v][d];
            end
        end
    end

    assign load_a_sign_out = load_a_sign_q;
    assign load_w_sign_out = load_w_sign_q;

    for (genvar h = 0; h < N_H; h++) begin : g_row
        logic signed [OWIDTH-1:0] acc_chain [N_W:0];

        for (genvar d = 0; d < K; d++) begin : g_a_output
            assign a_bits_out[h][d] = a_bits_pipe[h][d];
            assign a_signs_out[h][d] = a_signs_pipe[h][d];
        end

        assign acc_chain[0] = acc_in_west[h];
        assign acc_out_east[h] = acc_chain[N_W];

        for (genvar v = 0; v < N_W; v++) begin : g_col
            InnerTileWDBICountCorrect #(
                .K(K), .M(M), .OWIDTH(OWIDTH), .LANE_W(LANE_W)
            ) u_inner (
                .clk,
                .reset,
                .a_signs(a_signs_pipe[h]),
                .a_bits(a_bits_pipe[h]),
                .a_count(a_count[h]),
                .w_signs(w_signs_pipe[v]),
                .w_bits_encoded(w_encoded_pipe[v]),
                .w_keep(w_keep_pipe[v]),
                .shift_in,
                .mac_en,
                .acc_in(acc_chain[v]),
                .acc_out(acc_chain[v+1])
            );
        end
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_output
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign w_bits_out[v][d] =
                w_encoded_pipe[v][d] ~^ {M{w_keep_pipe[v][d]}};
            assign w_signs_out[v][d] = w_signs_pipe[v][d];
        end
    end
endmodule

module InnerPEWDBICountCorrectFlat #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int OWIDTH = 16
) (
    input logic clk,
    input logic reset,
    input logic mac_en,
    input logic shift_in,
    input logic [N_H*K*M-1:0] a_bits_in,
    input logic [N_H*K-1:0] a_signs_in,
    input logic [N_W*K*M-1:0] w_bits_in,
    input logic [N_W*K-1:0] w_signs_in,
    input logic load_a_sign_in,
    input logic load_w_sign_in,
    output logic [N_H*K*M-1:0] a_bits_out,
    output logic [N_H*K-1:0] a_signs_out,
    output logic [N_W*K*M-1:0] w_bits_out,
    output logic [N_W*K-1:0] w_signs_out,
    output logic load_a_sign_out,
    output logic load_w_sign_out,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic [M-1:0] a_bits_in_array [N_H][K];
    logic         a_signs_in_array [N_H][K];
    logic [M-1:0] w_bits_in_array [N_W][K];
    logic         w_signs_in_array [N_W][K];
    logic [M-1:0] a_bits_out_array [N_H][K];
    logic         a_signs_out_array [N_H][K];
    logic [M-1:0] w_bits_out_array [N_W][K];
    logic         w_signs_out_array [N_W][K];
    logic signed [OWIDTH-1:0] acc_in_west_array [N_H];
    logic signed [OWIDTH-1:0] acc_out_east_array [N_H];

    for (genvar h = 0; h < N_H; h++) begin : g_a_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign a_bits_in_array[h][d] =
                a_bits_in[(h*K + d)*M +: M];
            assign a_signs_in_array[h][d] = a_signs_in[h*K + d];
            assign a_bits_out[(h*K + d)*M +: M] =
                a_bits_out_array[h][d];
            assign a_signs_out[h*K + d] = a_signs_out_array[h][d];
        end
        assign acc_in_west_array[h] =
            $signed(acc_in_west[h*OWIDTH +: OWIDTH]);
        assign acc_out_east[h*OWIDTH +: OWIDTH] = acc_out_east_array[h];
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign w_bits_in_array[v][d] =
                w_bits_in[(v*K + d)*M +: M];
            assign w_signs_in_array[v][d] = w_signs_in[v*K + d];
            assign w_bits_out[(v*K + d)*M +: M] =
                w_bits_out_array[v][d];
            assign w_signs_out[v*K + d] = w_signs_out_array[v][d];
        end
    end

    InnerPEWDBICountCorrect #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) u_array_core (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .a_bits_in(a_bits_in_array),
        .a_signs_in(a_signs_in_array),
        .w_bits_in(w_bits_in_array),
        .w_signs_in(w_signs_in_array),
        .load_a_sign_in,
        .load_w_sign_in,
        .a_bits_out(a_bits_out_array),
        .a_signs_out(a_signs_out_array),
        .w_bits_out(w_bits_out_array),
        .w_signs_out(w_signs_out_array),
        .load_a_sign_out,
        .load_w_sign_out,
        .acc_in_west(acc_in_west_array),
        .acc_out_east(acc_out_east_array)
    );
endmodule

`endif
