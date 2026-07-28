`timescale 1ns/1ps

`include "common/clk_util.sv"
`include "baselines/binary_os/binary_os_asym.sv"

// Self-checking functional test for the asymmetric binary output-stationary array.
//
// The golden model is the true asymmetric product computed with plain integer
// arithmetic in the testbench:
//
//   C[h][v] = sum_t (qa[h][t] - za) * (qw[t][v] - zw[v])
//
// The DUT never forms centred operands: its PEs multiply the raw quantized
// values and the drain-path corrector removes the zero-point terms using the
// on-array row activation sums plus the off-array centred weight sums.  Getting
// a bit-exact match therefore exercises the whole identity, not just transport.
//
// Nonzero zero points on both operands, and a per-column weight zero point, so a
// correction that dropped either term or used the wrong column would fail.
module Top;
    localparam int IWIDTH  = 8;
    localparam int N_H     = 8;
    localparam int N_W     = 8;
    localparam int OWIDTH  = 24;
    localparam int DEPTH_W = 10;
    localparam int SUMA_WIDTH = IWIDTH + DEPTH_W;
    localparam int WSUM_WIDTH = IWIDTH + 1 + DEPTH_W;
    localparam int K_DEPTH = 24;
    localparam int BLOCKS  = 4;
    localparam int STREAM_CYCLES = K_DEPTH + N_H + N_W - 1;
    localparam int FLUSH_CYCLES  = (N_H > N_W ? N_H : N_W) + 1;

    logic clk, reset, timeout;
    logic mac_en = 1'b0, shift_in = 1'b0;
    logic sum_en = 1'b0, sum_load = 1'b0, corr_en = 1'b0;

    logic [N_H*IWIDTH-1:0] a_in = '0;
    logic [N_W*IWIDTH-1:0] w_in = '0;
    logic [N_H*OWIDTH-1:0] acc_in_west = '0;
    logic [N_H*OWIDTH-1:0] ofm;

    logic signed [IWIDTH-1:0] ifm_zp = '0;
    logic signed [IWIDTH-1:0] wght_zp = '0;
    logic signed [WSUM_WIDTH-1:0] centered_wsum = '0;

    ClkUtils #(.TIMEOUT(BLOCKS*(STREAM_CYCLES + FLUSH_CYCLES + N_W + 8) + 512))
        clk_utils (.clk, .reset, .timeout);

    binary_os_array_asym #(
        .IWIDTH(IWIDTH), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .DEPTH_W(DEPTH_W)
    ) dut (.*);

    int a_mat [N_H][K_DEPTH];
    int w_mat [K_DEPTH][N_W];
    int za;
    int zw [N_W];
    int cwsum [N_W];          // sum_t (qw - zw[v]), the off-array precompute
    int golden [N_H][N_W];
    logic signed [OWIDTH-1:0] got [N_H][N_W];

    int errors = 0;

    function automatic logic signed [IWIDTH-1:0] rand_operand();
        rand_operand = IWIDTH'($urandom);
    endfunction

    task automatic drive_cycle(input int c);
        int t;
        for (int h = 0; h < N_H; h++) begin
            t = c - h;
            a_in[h*IWIDTH +: IWIDTH] =
                (t >= 0 && t < K_DEPTH) ? a_mat[h][t][IWIDTH-1:0] : {IWIDTH{1'b0}};
        end
        for (int v = 0; v < N_W; v++) begin
            t = c - v;
            w_in[v*IWIDTH +: IWIDTH] =
                (t >= 0 && t < K_DEPTH) ? w_mat[t][v][IWIDTH-1:0] : {IWIDTH{1'b0}};
        end
    endtask

    // Drain step s emits column N_W-1-s on every row rail, so the host presents
    // that column's zero point and centred weight sum for the step.
    task automatic drain_matrix();
        int v;
        corr_en = 1'b1;
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            v = N_W-1-s;
            wght_zp = zw[v][IWIDTH-1:0];
            centered_wsum = cwsum[v][WSUM_WIDTH-1:0];
            #0.01;                      // let the combinational corrector settle
            for (int h = 0; h < N_H; h++)
                got[h][v] = $signed(ofm[h*OWIDTH +: OWIDTH]);
            @(posedge clk);
            @(negedge clk);
        end
        shift_in = 1'b0;
        corr_en = 1'b0;
    endtask

    task automatic check_matrix(input int block);
        logic signed [OWIDTH-1:0] want;
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) begin
                want = OWIDTH'(golden[h][v]);
                if (got[h][v] !== want) begin
                    $display("[FAIL] block=%0d out[%0d][%0d] got=%0d want=%0d",
                             block, h, v, got[h][v], want);
                    errors++;
                end
            end
    endtask

    initial begin
        clk_utils.set_clock(2.5);
        clk_utils.do_reset();
        @(negedge clk);

        for (int block = 0; block < BLOCKS; block++) begin
            za = $signed(rand_operand());
            ifm_zp = za[IWIDTH-1:0];
            for (int v = 0; v < N_W; v++) zw[v] = $signed(rand_operand());

            for (int h = 0; h < N_H; h++)
                for (int t = 0; t < K_DEPTH; t++)
                    a_mat[h][t] = $signed(rand_operand());
            for (int t = 0; t < K_DEPTH; t++)
                for (int v = 0; v < N_W; v++)
                    w_mat[t][v] = $signed(rand_operand());

            // Off-array precompute, exactly as a weight-preparation pass would.
            for (int v = 0; v < N_W; v++) begin
                cwsum[v] = 0;
                for (int t = 0; t < K_DEPTH; t++) cwsum[v] += w_mat[t][v] - zw[v];
            end

            for (int h = 0; h < N_H; h++)
                for (int v = 0; v < N_W; v++) begin
                    golden[h][v] = 0;
                    for (int t = 0; t < K_DEPTH; t++)
                        golden[h][v] += (a_mat[h][t] - za) * (w_mat[t][v] - zw[v]);
                end

            // Flush the resetless hop registers.
            mac_en = 1'b0; sum_en = 1'b0; sum_load = 1'b0;
            a_in = '0; w_in = '0;
            for (int t = 0; t < FLUSH_CYCLES; t++) begin
                @(posedge clk);
                @(negedge clk);
            end

            // The row sums must cover exactly the K_DEPTH real slices.  Zero
            // padding contributes nothing to either the products or the sums, so
            // sum_en can stay high for the whole skewed stream, and the first
            // cycle LOADS so no prior state survives (row h's pre-real cycles
            // carry padding zeros, so a single global load is correct despite
            // the skew).
            mac_en = 1'b1; sum_en = 1'b1;
            for (int c = 0; c < STREAM_CYCLES; c++) begin
                sum_load = (c == 0);
                drive_cycle(c);
                @(posedge clk);
                @(negedge clk);
            end
            mac_en = 1'b0; sum_en = 1'b0; sum_load = 1'b0;
            a_in = '0; w_in = '0;

            drain_matrix();
            check_matrix(block);
        end

        if (errors != 0)
            $fatal(1, "FAIL: %0d mismatches in %0d asymmetric blocks", errors, BLOCKS);
        $display("PASS: binary OS asym array matched golden asymmetric matmul, %0d blocks of %0dx%0d, depth %0d",
                 BLOCKS, N_H, N_W, K_DEPTH);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
