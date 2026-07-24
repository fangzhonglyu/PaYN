`timescale 1ns/1ps

`include "payn/variants/signed_segmented/inner_pe_signed_segmented.sv"
`include "payn/variants/signed_segmented_isolated/inner_pe_signed_segmented_isolated.sv"

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 2;
    localparam int N_W = 4;
    localparam int OWIDTH = 24;
    localparam int LOW_W = 9;
    localparam int N_RANDOM = 4096;
    localparam int N_ROUNDS = 16;
    localparam int ROUND_MACS = 128;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic mac_en = 1'b0;
    logic shift_in = 1'b0;
    logic load_a_sign_in = 1'b0;
    logic load_w_sign_in = 1'b0;

    logic [M-1:0] a_bits_in  [N_H][K];
    logic         a_signs_in [N_H][K];
    logic [M-1:0] w_bits_in  [N_W][K];
    logic         w_signs_in [N_W][K];
    logic signed [OWIDTH-1:0] acc_in_west [N_H];

    logic [M-1:0] ref_a_bits_out [N_H][K];
    logic         ref_a_signs_out [N_H][K];
    logic [M-1:0] ref_w_bits_out [N_W][K];
    logic         ref_w_signs_out [N_W][K];
    logic ref_load_a_sign_out;
    logic ref_load_w_sign_out;
    logic signed [OWIDTH-1:0] ref_acc_out_east [N_H];

    logic [M-1:0] iso_a_bits_out [N_H][K];
    logic         iso_a_signs_out [N_H][K];
    logic [M-1:0] iso_w_bits_out [N_W][K];
    logic         iso_w_signs_out [N_W][K];
    logic iso_load_a_sign_out;
    logic iso_load_w_sign_out;
    logic signed [OWIDTH-1:0] iso_acc_out_east [N_H];

    logic signed [OWIDTH-1:0] ref_tile_value [N_H][N_W];
    logic signed [OWIDTH-1:0] iso_tile_value [N_H][N_W];
    logic signed [OWIDTH-1:0] iso_chain_link [N_H][N_W];

    always #1.25 clk = ~clk;

    InnerPESignedSegmented #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut_reference (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .a_bits_in,
        .a_signs_in,
        .w_bits_in,
        .w_signs_in,
        .load_a_sign_in,
        .load_w_sign_in,
        .a_bits_out(ref_a_bits_out),
        .a_signs_out(ref_a_signs_out),
        .w_bits_out(ref_w_bits_out),
        .w_signs_out(ref_w_signs_out),
        .load_a_sign_out(ref_load_a_sign_out),
        .load_w_sign_out(ref_load_w_sign_out),
        .acc_in_west,
        .acc_out_east(ref_acc_out_east)
    );

    InnerPESignedSegmentedIsolated #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut_isolated (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .a_bits_in,
        .a_signs_in,
        .w_bits_in,
        .w_signs_in,
        .load_a_sign_in,
        .load_w_sign_in,
        .a_bits_out(iso_a_bits_out),
        .a_signs_out(iso_a_signs_out),
        .w_bits_out(iso_w_bits_out),
        .w_signs_out(iso_w_signs_out),
        .load_a_sign_out(iso_load_a_sign_out),
        .load_w_sign_out(iso_load_w_sign_out),
        .acc_in_west,
        .acc_out_east(iso_acc_out_east)
    );

    for (genvar h = 0; h < N_H; h++) begin : g_observe_row
        for (genvar v = 0; v < N_W; v++) begin : g_observe_col
            assign ref_tile_value[h][v] =
                dut_reference.g_row[h].g_col[v].u_inner.acc_out;
            assign iso_tile_value[h][v] =
                dut_isolated.g_row[h].g_col[v].u_inner.canonical_acc;
            assign iso_chain_link[h][v] =
                dut_isolated.g_row[h].acc_chain[v+1];
        end
    end

    task automatic clear_inputs;
        for (int h = 0; h < N_H; h++) begin
            acc_in_west[h] = '0;
            for (int d = 0; d < K; d++) begin
                a_bits_in[h][d] = '0;
                a_signs_in[h][d] = 1'b0;
            end
        end
        for (int v = 0; v < N_W; v++) begin
            for (int d = 0; d < K; d++) begin
                w_bits_in[v][d] = '0;
                w_signs_in[v][d] = 1'b0;
            end
        end
    endtask

    task automatic set_extreme(input logic negative);
        for (int h = 0; h < N_H; h++) begin
            for (int d = 0; d < K; d++) begin
                a_bits_in[h][d] = '1;
                a_signs_in[h][d] = negative;
            end
        end
        for (int v = 0; v < N_W; v++) begin
            for (int d = 0; d < K; d++) begin
                w_bits_in[v][d] = '1;
                w_signs_in[v][d] = 1'b0;
            end
        end
    endtask

    task automatic randomize_inputs;
        for (int h = 0; h < N_H; h++) begin
            for (int d = 0; d < K; d++) begin
                a_bits_in[h][d] = $urandom;
                a_signs_in[h][d] = $urandom & 1;
            end
        end
        for (int v = 0; v < N_W; v++) begin
            for (int d = 0; d < K; d++) begin
                w_bits_in[v][d] = $urandom;
                w_signs_in[v][d] = $urandom & 1;
            end
        end
    endtask

    task automatic check_state_match(input string phase);
        for (int h = 0; h < N_H; h++) begin
            for (int v = 0; v < N_W; v++) begin
                assert (iso_tile_value[h][v] === ref_tile_value[h][v])
                    else $fatal(
                        1,
                        "%s tile[%0d][%0d] canonical mismatch iso=%h ref=%h",
                        phase, h, v,
                        iso_tile_value[h][v], ref_tile_value[h][v]
                    );
            end
        end
    endtask

    task automatic check_compute_isolation(input string phase);
        #0.01;
        assert (!shift_in)
            else $fatal(1, "%s compute check while shift_in is active", phase);
        check_state_match(phase);
        for (int h = 0; h < N_H; h++) begin
            assert (iso_acc_out_east[h] === '0)
                else $fatal(
                    1, "%s east output[%0d] toggled during compute: %h",
                    phase, h, iso_acc_out_east[h]
                );
            for (int v = 0; v < N_W; v++) begin
                assert (iso_chain_link[h][v] === '0)
                    else $fatal(
                        1, "%s chain[%0d][%0d] not isolated: %h",
                        phase, h, v, iso_chain_link[h][v]
                    );
            end
        end
    endtask

    task automatic check_shift_transparency(input string phase);
        #0.01;
        assert (shift_in)
            else $fatal(1, "%s shift check while shift_in is inactive", phase);
        check_state_match(phase);
        for (int h = 0; h < N_H; h++) begin
            assert (iso_acc_out_east[h] === ref_acc_out_east[h])
                else $fatal(
                    1, "%s east output[%0d] iso=%h ref=%h",
                    phase, h, iso_acc_out_east[h], ref_acc_out_east[h]
                );
            for (int v = 0; v < N_W; v++) begin
                assert (iso_chain_link[h][v] === ref_tile_value[h][v])
                    else $fatal(
                        1, "%s transparent chain[%0d][%0d] iso=%h ref=%h",
                        phase, h, v,
                        iso_chain_link[h][v], ref_tile_value[h][v]
                    );
            end
        end
    endtask

    task automatic compute_edge(input string phase);
        mac_en = 1'b1;
        @(posedge clk);
        check_compute_isolation(phase);
        @(negedge clk);
    endtask

    task automatic drain_row(input int round);
        mac_en = 1'b0;
        shift_in = 1'b1;

        // The first observation occurs without a flush clock.  It exercises
        // exposing a canonical value while a carry or borrow may be pending.
        check_shift_transparency($sformatf("round %0d pre-drain", round));

        for (int step = 0; step < N_W + 2; step++) begin
            for (int h = 0; h < N_H; h++)
                acc_in_west[h] =
                    OWIDTH'($urandom ^ (round << 8) ^ (step << 3) ^ h);

            #0.01;
            check_shift_transparency(
                $sformatf("round %0d shift %0d before edge", round, step)
            );
            @(posedge clk);
            check_shift_transparency(
                $sformatf("round %0d shift %0d after edge", round, step)
            );
            @(negedge clk);
        end

        shift_in = 1'b0;
        for (int h = 0; h < N_H; h++)
            acc_in_west[h] = '0;
        check_compute_isolation($sformatf("round %0d post-drain", round));
    endtask

    initial begin
        clear_inputs();

        @(negedge clk);
        reset = 1'b1;
        @(posedge clk);
        check_compute_isolation("reset");
        @(negedge clk);
        reset = 1'b0;

        // Initialize both stages of the delayed sign-load protocol before any
        // MAC can consume the unreset sign pipeline registers.
        load_a_sign_in = 1'b1;
        load_w_sign_in = 1'b1;
        repeat (3) begin
            @(posedge clk);
            check_compute_isolation("sign-pipeline warmup");
            @(negedge clk);
        end

        // Long monotonic bursts repeatedly create and retire boundary events.
        set_extreme(1'b0);
        repeat (1024)
            compute_edge("long positive compute");

        set_extreme(1'b1);
        repeat (2048)
            compute_edge("long negative compute");

        // Random bipolar activity checks that the clamp does not perturb the
        // accepted pending-event state recurrence.
        for (int cycle = 0; cycle < N_RANDOM; cycle++) begin
            randomize_inputs();
            compute_edge("random bipolar compute");
        end
        drain_row(0);

        // Repeated compute/drain transitions validate the actual row protocol,
        // including accumulation from values shifted in during a prior drain.
        for (int round = 1; round <= N_ROUNDS; round++) begin
            for (int cycle = 0; cycle < ROUND_MACS; cycle++) begin
                randomize_inputs();
                compute_edge("repeated compute/drain");
            end
            drain_row(round);
        end

        $display(
            "PASS: source-isolated K%0d/M%0d %0dx%0d PE matches accepted state over %0d MACs and %0d drain rounds; all internal chains are zero during compute",
            K, M, N_H, N_W,
            1024 + 2048 + N_RANDOM + N_ROUNDS*ROUND_MACS,
            N_ROUNDS + 1
        );
        $finish;
    end
endmodule
