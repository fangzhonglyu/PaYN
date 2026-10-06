`timescale 1ns/1ps

// Functional test of a genuine 2-D outer PE grid.
//
// This is intentionally different from test_inner_pe.sv: each of the six
// instantiated InnerPEs contains its own N_H x N_W tile array.  Time-varying
// A slices move east and W slices move south.  The edge driver applies the
// row/column skew required for equal-index slices to meet at every PE.
//
// The self-checking reference is independent of the RTL pipeline.  It computes
// every global output from the unskewed source slices, then drains the complete
// P_COLS*N_W-wide accumulator row through all PE-column boundaries.

`include "payn/variants/signed_segmented/inner_pe_grid_signed_segmented.sv"

module Top;
    localparam int P_ROWS = 2;
    localparam int P_COLS = 3;
    localparam int K = 2;
    localparam int M = 4;
    localparam int N_H = 2;
    localparam int N_W = 2;
    localparam int OWIDTH = 16;
    localparam int LOW_W = 9;
    localparam int SLICES = 600;
    localparam int GLOBAL_H = P_ROWS * N_H;
    localparam int GLOBAL_W = P_COLS * N_W;
    localparam int RUN_CYCLES = SLICES + P_ROWS + P_COLS - 1;
    localparam int RADIX = 1 << LOW_W;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic mac_en = 1'b0;
    logic shift_in = 1'b0;

    logic [M-1:0] a_bits_in  [P_ROWS][N_H][K];
    logic         a_signs_in [P_ROWS][N_H][K];
    logic [M-1:0] w_bits_in  [P_COLS][N_W][K];
    logic         w_signs_in [P_COLS][N_W][K];
    logic         load_a_sign_in [P_ROWS];
    logic         load_w_sign_in [P_COLS];

    logic [M-1:0] a_bits_out  [P_ROWS][N_H][K];
    logic         a_signs_out [P_ROWS][N_H][K];
    logic [M-1:0] w_bits_out  [P_COLS][N_W][K];
    logic         w_signs_out [P_COLS][N_W][K];
    logic         load_a_sign_out [P_ROWS];
    logic         load_w_sign_out [P_COLS];

    logic signed [OWIDTH-1:0] acc_in_west  [P_ROWS][N_H];
    logic signed [OWIDTH-1:0] acc_out_east [P_ROWS][N_H];
    integer signed expected [GLOBAL_H][GLOBAL_W];

    always #1.25 clk = ~clk;

    InnerPESignedSegmentedGrid #(
        .P_ROWS(P_ROWS),
        .P_COLS(P_COLS),
        .K(K),
        .M(M),
        .N_H(N_H),
        .N_W(N_W),
        .OWIDTH(OWIDTH),
        .LOW_W(LOW_W)
    ) dut (.*);

    function automatic logic a_stream_bit(
        input int slice,
        input int global_row,
        input int depth,
        input int lane
    );
        int code;
        if (slice < 0 || slice >= SLICES) begin
            a_stream_bit = 1'b0;
        end else begin
            code = slice*3 + global_row*5 + depth*7 + lane*11;
            a_stream_bit = ((code % 17) < 9);
        end
    endfunction

    function automatic logic w_stream_bit(
        input int slice,
        input int global_col,
        input int depth,
        input int lane
    );
        int code;
        if (slice < 0 || slice >= SLICES) begin
            w_stream_bit = 1'b0;
        end else begin
            code = slice*5 + global_col*7 + depth*3 + lane*13;
            w_stream_bit = ((code % 19) < 10);
        end
    endfunction

    // The depth-dependent term is shared between A and W.  Consequently all K
    // lanes at a given global output have sign (global_row XOR global_col).
    // Even-parity outputs force carries; odd-parity outputs force borrows.
    function automatic logic a_negative(
        input int global_row,
        input int depth
    );
        a_negative = (global_row + depth) & 1;
    endfunction

    function automatic logic w_negative(
        input int global_col,
        input int depth
    );
        w_negative = (global_col + depth) & 1;
    endfunction

    task automatic drive_edges(input int cycle);
        int global_row;
        int global_col;
        int slice;

        for (int r = 0; r < P_ROWS; r++) begin
            slice = cycle - r;
            for (int h = 0; h < N_H; h++) begin
                global_row = r*N_H + h;
                for (int d = 0; d < K; d++) begin
                    a_signs_in[r][h][d] = a_negative(global_row, d);
                    for (int lane = 0; lane < M; lane++)
                        a_bits_in[r][h][d][lane] =
                            a_stream_bit(slice, global_row, d, lane);
                end
            end
        end

        for (int c = 0; c < P_COLS; c++) begin
            slice = cycle - c;
            for (int v = 0; v < N_W; v++) begin
                global_col = c*N_W + v;
                for (int d = 0; d < K; d++) begin
                    w_signs_in[c][v][d] = w_negative(global_col, d);
                    for (int lane = 0; lane < M; lane++)
                        w_bits_in[c][v][d][lane] =
                            w_stream_bit(slice, global_col, d, lane);
                end
            end
        end
    endtask

    task automatic build_reference;
        logic negative;
        bit saw_carry;
        bit saw_borrow;

        saw_carry = 1'b0;
        saw_borrow = 1'b0;
        for (int h = 0; h < GLOBAL_H; h++) begin
            for (int v = 0; v < GLOBAL_W; v++) begin
                expected[h][v] = 0;
                for (int t = 0; t < SLICES; t++) begin
                    for (int d = 0; d < K; d++) begin
                        negative = a_negative(h, d) ^ w_negative(v, d);
                        for (int lane = 0; lane < M; lane++) begin
                            if (a_stream_bit(t, h, d, lane) &&
                                w_stream_bit(t, v, d, lane))
                                expected[h][v] += negative ? -1 : 1;
                        end
                    end
                end
                saw_carry |= (expected[h][v] >= RADIX);
                saw_borrow |= (expected[h][v] <= -RADIX);
            end
        end

        assert (saw_carry && saw_borrow)
            else $fatal(1,
                "stimulus must exercise both segmented carry and borrow");
    endtask

    task automatic check_east_tail(input int global_col);
        int global_row;
        for (int r = 0; r < P_ROWS; r++) begin
            for (int h = 0; h < N_H; h++) begin
                global_row = r*N_H + h;
                assert (acc_out_east[r][h] ===
                        OWIDTH'(expected[global_row][global_col]))
                    else $fatal(1,
                        "drain mismatch row=%0d col=%0d expected=%0d got=%0d",
                        global_row, global_col,
                        expected[global_row][global_col],
                        $signed(acc_out_east[r][h]));
            end
        end
    endtask

    task automatic check_no_unknown(input int cycle);
        for (int r = 0; r < P_ROWS; r++)
            for (int h = 0; h < N_H; h++)
                assert (!$isunknown(acc_out_east[r][h]))
                    else $fatal(1,
                        "X reached accumulator drain rail at cycle=%0d row=%0d",
                        cycle, r*N_H + h);
    endtask

    initial begin
        build_reference();
        drive_edges(-P_ROWS-P_COLS);
        for (int r = 0; r < P_ROWS; r++) begin
            load_a_sign_in[r] = 1'b0;
            for (int h = 0; h < N_H; h++)
                acc_in_west[r][h] = '0;
        end
        for (int c = 0; c < P_COLS; c++)
            load_w_sign_in[c] = 1'b0;

        // Reset every tile accumulator while zero stream slices fill the
        // resetless A/W operand pipelines.
        @(negedge clk);
        reset = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Signs are block-static.  Launch one load wave on every west/top edge
        // and wait until it has crossed the complete outer PE grid.
        for (int r = 0; r < P_ROWS; r++)
            load_a_sign_in[r] = 1'b1;
        for (int c = 0; c < P_COLS; c++)
            load_w_sign_in[c] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        for (int r = 0; r < P_ROWS; r++)
            load_a_sign_in[r] = 1'b0;
        for (int c = 0; c < P_COLS; c++)
            load_w_sign_in[c] = 1'b0;
        repeat (P_ROWS + P_COLS + 1) begin
            @(posedge clk);
            @(negedge clk);
        end

        // A row-block r is delayed r cycles at the west edge; W column-block c
        // is delayed c cycles at the top edge.  PE (r,c) therefore receives
        // matching source slice t from both directions.
        mac_en = 1'b1;
        for (int cycle = 0; cycle < RUN_CYCLES; cycle++) begin
            drive_edges(cycle);
            @(posedge clk);
            #0.05;
            check_no_unknown(cycle);
            @(negedge clk);
        end
        mac_en = 1'b0;
        drive_edges(RUN_CYCLES);

        // Sample before each shift edge, then shift the complete concatenated
        // row by one tile.  This explicitly checks PE-column drain crossings.
        shift_in = 1'b1;
        for (int step = 0; step < GLOBAL_W; step++) begin
            check_east_tail(GLOBAL_W - 1 - step);
            @(posedge clk);
            #0.05;
            @(negedge clk);
        end
        shift_in = 1'b0;

        for (int r = 0; r < P_ROWS; r++)
            for (int h = 0; h < N_H; h++)
                assert (acc_out_east[r][h] === '0)
                    else $fatal(1,
                        "zero-fill failed at outer row=%0d inner row=%0d",
                        r, h);

        $display(
            "PASS: %0dx%0d InnerPE systolic grid (%0dx%0d global outputs), time-skewed streams and cross-PE drain are exact",
            P_ROWS, P_COLS, GLOBAL_H, GLOBAL_W
        );
        $finish;
    end
endmodule
