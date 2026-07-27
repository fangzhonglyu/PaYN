`timescale 1ns/1ps

// End-to-end binary-matrix test for a multi-PE PaYN fabric.
//
// Unlike test_systolic_pe_grid.sv, this bench does not invent stochastic input
// bits. It loads signed binary matrices, generates their streams with the RTL
// Sobol banks and comparator peripheral, applies the outer-grid systolic skew,
// and drains the complete result matrix. cosim_systolic_matmul.py compares the
// drain bit-for-bit with the independent Python PaYN matmul model.

`include "common/clk_util.sv"
`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"
`include "payn/variants/signed_segmented/inner_pe_grid_signed_segmented.sv"

module Top;
    localparam int P_ROWS = 8;
    localparam int P_COLS = 8;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int GLOBAL_H = P_ROWS * N_H;
    localparam int GLOBAL_W = P_COLS * N_W;
    localparam int WIDTH = 8;
    localparam int MAG_WIDTH = 7;
    localparam int MAG_SHIFT = WIDTH - MAG_WIDTH;
    localparam int OWIDTH = 24;
    localparam int LOW_W = 9;
    // Production operating point: 8 cycles x 16 lanes = T=128.
    localparam int STREAM_LENGTH = 128;
    localparam int MAC_CYCLES = STREAM_LENGTH / M;
    localparam int A_BLOCK_W = N_H*K*M;
    localparam int W_BLOCK_W = N_W*K*M;
    localparam int FLUSH_CYCLES = P_ROWS + P_COLS;

    logic clk;
    logic reset;
    logic timeout;
    logic rng_en = 1'b0;
    logic source_valid = 1'b0;
    logic mac_en = 1'b0;
    logic shift_in = 1'b0;
    logic load_a = 1'b0;
    logic load_w = 1'b0;

    logic [GLOBAL_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [GLOBAL_H*K-1:0]       a_signs_binary = '0;
    logic [GLOBAL_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [GLOBAL_W*K-1:0]       w_signs_binary = '0;

    logic [M*WIDTH-1:0] a_random_values;
    logic [M*WIDTH-1:0] w_random_values;
    logic [GLOBAL_H*K*M-1:0] a_bits_all;
    logic [GLOBAL_H*K-1:0]   a_signs_all;
    logic [GLOBAL_W*K*M-1:0] w_bits_all;
    logic [GLOBAL_W*K-1:0]   w_signs_all;

    logic [A_BLOCK_W-1:0] a_skew_bits [P_ROWS][P_ROWS];
    logic                  a_skew_valid [P_ROWS][P_ROWS];
    logic [W_BLOCK_W-1:0] w_skew_bits [P_COLS][P_COLS];
    logic                  w_skew_valid [P_COLS][P_COLS];

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

    integer signed drain [GLOBAL_H][GLOBAL_W];
    integer trace_file;

    ClkUtils #(.TIMEOUT(MAC_CYCLES + FLUSH_CYCLES + GLOBAL_W + 128)) clk_utils (
        .clk,
        .reset,
        .timeout
    );

    sobol_bank #(
        .WIDTH(WIDTH),
        .M(M),
        .DIRECTION_SET(0),
        .DIGITAL_SHIFT_BASE(8'h17),
        .DIGITAL_SHIFT_STRIDE(8'h53)
    ) u_a_rng (
        .clk,
        .reset,
        .enable(rng_en),
        .random_values(a_random_values)
    );

    sobol_bank #(
        .WIDTH(WIDTH),
        .M(M),
        .DIRECTION_SET(1),
        .DIGITAL_SHIFT_BASE(8'h9d),
        .DIGITAL_SHIFT_STRIDE(8'h2b)
    ) u_w_rng (
        .clk,
        .reset,
        .enable(rng_en),
        .random_values(w_random_values)
    );

    sc_pe_peripheral #(
        .K(K),
        .M(M),
        .N_H(GLOBAL_H),
        .N_W(GLOBAL_W),
        .WIDTH(WIDTH)
    ) u_peripheral (
        .clk,
        .reset,
        .load_a,
        .load_w,
        .a_binary_in,
        .a_signs_in(a_signs_binary),
        .w_binary_in,
        .w_signs_in(w_signs_binary),
        .a_random_values,
        .w_random_values,
        .a_bits(a_bits_all),
        .a_signs(a_signs_all),
        .w_bits(w_bits_all),
        .w_signs(w_signs_all)
    );

    // One common register plus r/c extra stages implements the source skew.
    // Row-block r therefore reaches the west edge r cycles after row-block 0;
    // column-block c reaches the top edge c cycles after column-block 0.
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int r = 0; r < P_ROWS; r++) begin
                for (int stage = 0; stage < P_ROWS; stage++) begin
                    a_skew_bits[r][stage] <= '0;
                    a_skew_valid[r][stage] <= 1'b0;
                end
            end
            for (int c = 0; c < P_COLS; c++) begin
                for (int stage = 0; stage < P_COLS; stage++) begin
                    w_skew_bits[c][stage] <= '0;
                    w_skew_valid[c][stage] <= 1'b0;
                end
            end
        end else begin
            for (int r = 0; r < P_ROWS; r++) begin
                a_skew_bits[r][0] <=
                    a_bits_all[r*A_BLOCK_W +: A_BLOCK_W];
                a_skew_valid[r][0] <= source_valid;
                for (int stage = 1; stage < P_ROWS; stage++) begin
                    a_skew_bits[r][stage] <= a_skew_bits[r][stage-1];
                    a_skew_valid[r][stage] <= a_skew_valid[r][stage-1];
                end
            end
            for (int c = 0; c < P_COLS; c++) begin
                w_skew_bits[c][0] <=
                    w_bits_all[c*W_BLOCK_W +: W_BLOCK_W];
                w_skew_valid[c][0] <= source_valid;
                for (int stage = 1; stage < P_COLS; stage++) begin
                    w_skew_bits[c][stage] <= w_skew_bits[c][stage-1];
                    w_skew_valid[c][stage] <= w_skew_valid[c][stage-1];
                end
            end
        end
    end

    for (genvar r = 0; r < P_ROWS; r++) begin : g_a_edge
        for (genvar h = 0; h < N_H; h++) begin : g_row
            for (genvar d = 0; d < K; d++) begin : g_depth
                assign a_bits_in[r][h][d] =
                    a_skew_valid[r][r]
                        ? a_skew_bits[r][r][(h*K+d)*M +: M]
                        : '0;
                assign a_signs_in[r][h][d] =
                    a_signs_all[((r*N_H+h)*K)+d];
            end
        end
    end

    for (genvar c = 0; c < P_COLS; c++) begin : g_w_edge
        for (genvar v = 0; v < N_W; v++) begin : g_col
            for (genvar d = 0; d < K; d++) begin : g_depth
                assign w_bits_in[c][v][d] =
                    w_skew_valid[c][c]
                        ? w_skew_bits[c][c][(v*K+d)*M +: M]
                        : '0;
                assign w_signs_in[c][v][d] =
                    w_signs_all[((c*N_W+v)*K)+d];
            end
        end
    end

    InnerPESignedSegmentedGrid #(
        .P_ROWS(P_ROWS),
        .P_COLS(P_COLS),
        .K(K),
        .M(M),
        .N_H(N_H),
        .N_W(N_W),
        .OWIDTH(OWIDTH),
        .LOW_W(LOW_W)
    ) dut (
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
        .a_bits_out,
        .a_signs_out,
        .w_bits_out,
        .w_signs_out,
        .load_a_sign_out,
        .load_w_sign_out,
        .acc_in_west,
        .acc_out_east
    );

    function automatic int a_logical_magnitude(
        input int global_row,
        input int depth
    );
        a_logical_magnitude =
            8 + ((global_row*31 + depth*47 + 19) % 120);
    endfunction

    function automatic int w_logical_magnitude(
        input int global_col,
        input int depth
    );
        w_logical_magnitude =
            9 + ((global_col*23 + depth*41 + 11) % 118);
    endfunction

    function automatic logic a_negative(
        input int global_row,
        input int depth
    );
        a_negative = ((global_row + 2*depth) % 3) == 1;
    endfunction

    function automatic logic w_negative(
        input int global_col,
        input int depth
    );
        w_negative = ((2*global_col + depth) % 4) == 2;
    endfunction

    task automatic load_binary_matrices;
        int index;
        for (int h = 0; h < GLOBAL_H; h++) begin
            for (int d = 0; d < K; d++) begin
                index = h*K + d;
                a_binary_in[index*WIDTH +: WIDTH] =
                    WIDTH'(a_logical_magnitude(h, d) << MAG_SHIFT);
                a_signs_binary[index] = a_negative(h, d);
            end
        end
        for (int v = 0; v < GLOBAL_W; v++) begin
            for (int d = 0; d < K; d++) begin
                index = v*K + d;
                w_binary_in[index*WIDTH +: WIDTH] =
                    WIDTH'(w_logical_magnitude(v, d) << MAG_SHIFT);
                w_signs_binary[index] = w_negative(v, d);
            end
        end
    endtask

    initial begin
        clk_utils.set_clock(2.5);
        load_binary_matrices();
        for (int r = 0; r < P_ROWS; r++) begin
            load_a_sign_in[r] = 1'b0;
            for (int h = 0; h < N_H; h++)
                acc_in_west[r][h] = '0;
        end
        for (int c = 0; c < P_COLS; c++)
            load_w_sign_in[c] = 1'b0;

        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        // Latch the binary matrices into the actual converter peripheral.
        load_a = 1'b1;
        load_w = 1'b1;
        @(posedge clk);
        @(negedge clk);
        load_a = 1'b0;
        load_w = 1'b0;

        // Preload the block-static signs through every outer PE.
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

        // Advance once while invalid so the first accepted source slice uses
        // Sobol step zero, matching RNGBank.step() in sc_kernel.py.
        rng_en = 1'b1;
        source_valid = 1'b0;
        mac_en = 1'b1;
        @(posedge clk);
        @(negedge clk);

        source_valid = 1'b1;
        for (int t = 0; t < MAC_CYCLES; t++) begin
            @(posedge clk);
            @(negedge clk);
        end
        source_valid = 1'b0;
        rng_en = 1'b0;

        // Zero-gated invalid slices flush the skew and PE pipelines without
        // altering the arithmetic result.
        repeat (FLUSH_CYCLES) begin
            @(posedge clk);
            @(negedge clk);
        end
        mac_en = 1'b0;

        // Drain the P_COLS*N_W-wide global rows through all outer PE columns.
        shift_in = 1'b1;
        for (int step = 0; step < GLOBAL_W; step++) begin
            for (int r = 0; r < P_ROWS; r++) begin
                for (int h = 0; h < N_H; h++) begin
                    drain[r*N_H+h][GLOBAL_W-1-step] =
                        $signed(acc_out_east[r][h]);
                end
            end
            @(posedge clk);
            #0.05;
            @(negedge clk);
        end
        shift_in = 1'b0;

        trace_file = $fopen("systolic_matmul_rtl.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open systolic_matmul_rtl.txt");
        $fwrite(trace_file, "CFG %0d %0d %0d %0d %0d %0d %0d 0\n",
                K, M, GLOBAL_H, GLOBAL_W, WIDTH, OWIDTH, MAC_CYCLES);
        $fwrite(trace_file, "AMAG");
        for (int i = 0; i < GLOBAL_H*K; i++)
            $fwrite(trace_file, " %0d",
                    a_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nASIGN");
        for (int i = 0; i < GLOBAL_H*K; i++)
            $fwrite(trace_file, " %0d", a_signs_binary[i]);
        $fwrite(trace_file, "\nWMAG");
        for (int i = 0; i < GLOBAL_W*K; i++)
            $fwrite(trace_file, " %0d",
                    w_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nWSIGN");
        for (int i = 0; i < GLOBAL_W*K; i++)
            $fwrite(trace_file, " %0d", w_signs_binary[i]);
        $fwrite(trace_file, "\nDRAIN");
        for (int h = 0; h < GLOBAL_H; h++)
            for (int v = 0; v < GLOBAL_W; v++)
                $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display(
            "PASS: wrote binary-to-SC %0dx%0d-PE matmul trace (%0dx%0d outputs)",
            P_ROWS, P_COLS, GLOBAL_H, GLOBAL_W
        );
        $finish;
    end
endmodule
