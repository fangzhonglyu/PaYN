`timescale 1ns/1ps

`include "common/clk_util.sv"
`include "baselines/binary_os/binary_os_array.sv"

// Self-checking functional test for the binary output-stationary systolic array.
//
// Each block streams K_DEPTH signed INT8 slices through the mesh with the
// conventional systolic skew -- A slice t enters row h at cycle t+h, W slice t
// enters column v at cycle t+v, so both reach PE (h,v) at cycle t+h+v+1 -- then
// drains the N_H x N_W accumulator matrix east and compares it against an
// independent golden matmul computed in the testbench (plain integer
// arithmetic, no structural mirror of the DUT).
//
// Outside the valid slice window the edges are zero-padded, so every PE sees
// exactly K_DEPTH productive MACs however it is skewed, and the fill/ramp cycles
// contribute nothing.  Blocks run back-to-back to prove the drain leaves the
// array clean: the west rail shifts zeros in, so the next block starts from a
// zeroed matrix without a reset.
//
// Also covered: mac_en=0 holds the accumulator, and acc_in_west is a real
// architectural input (a nonzero west value shifts into the row).
module Top;
    localparam int IWIDTH  = 8;
    localparam int N_H     = 8;
    localparam int N_W     = 8;
    localparam int OWIDTH  = 24;
    localparam int K_DEPTH = 24;          // reduction depth
    localparam int BLOCKS  = 4;
    // Cycles the skewed stream needs: slice t reaches PE (h,v) at t+h+v+1, so
    // the last productive MAC edge is K_DEPTH-1 + (N_H-1) + (N_W-1) + 1.
    localparam int STREAM_CYCLES = K_DEPTH + N_H + N_W - 1;
    // Zeros driven long enough to flush the resetless hop registers.
    localparam int FLUSH_CYCLES  = (N_H > N_W ? N_H : N_W) + 1;

    logic clk, reset, timeout;
    logic mac_en = 1'b0, shift_in = 1'b0;

    logic [N_H*IWIDTH-1:0] a_in = '0;
    logic [N_W*IWIDTH-1:0] w_in = '0;
    logic [N_H*OWIDTH-1:0] acc_in_west = '0;
    logic [N_H*OWIDTH-1:0] acc_out_east;

    ClkUtils #(.TIMEOUT(BLOCKS*(STREAM_CYCLES + FLUSH_CYCLES + N_W + 8) + 512))
        clk_utils (.clk, .reset, .timeout);

    binary_os_array #(
        .IWIDTH(IWIDTH), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) dut (.*);

    // Golden operands and result, held as unbounded integers and only truncated
    // to OWIDTH at the comparison.
    int a_mat [N_H][K_DEPTH];
    int w_mat [K_DEPTH][N_W];
    int golden [N_H][N_W];
    logic signed [OWIDTH-1:0] got [N_H][N_W];

    int errors = 0;

    function automatic logic signed [IWIDTH-1:0] rand_operand();
        rand_operand = IWIDTH'($urandom);
    endfunction

    // Drive edge cycle c with the systolic skew; zero-pad outside the window.
    task automatic drive_cycle(input int c);
        int t;
        for (int h = 0; h < N_H; h++) begin
            t = c - h;
            a_in[h*IWIDTH +: IWIDTH] =
                (t >= 0 && t < K_DEPTH) ? a_mat[h][t][IWIDTH-1:0]
                                        : {IWIDTH{1'b0}};
        end
        for (int v = 0; v < N_W; v++) begin
            t = c - v;
            w_in[v*IWIDTH +: IWIDTH] =
                (t >= 0 && t < K_DEPTH) ? w_mat[t][v][IWIDTH-1:0]
                                        : {IWIDTH{1'b0}};
        end
    endtask

    task automatic drive_zeros();
        a_in = '0;
        w_in = '0;
    endtask

    task automatic drain_matrix();
        // Sample at the negedge *before* each shift edge: acc_out_east then
        // holds the settled value of the east-most PE, and every following edge
        // advances the row by one column.
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            for (int h = 0; h < N_H; h++)
                got[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(posedge clk);
            @(negedge clk);
        end
        shift_in = 1'b0;
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
            for (int h = 0; h < N_H; h++)
                for (int t = 0; t < K_DEPTH; t++)
                    a_mat[h][t] = $signed(rand_operand());
            for (int t = 0; t < K_DEPTH; t++)
                for (int v = 0; v < N_W; v++)
                    w_mat[t][v] = $signed(rand_operand());
            for (int h = 0; h < N_H; h++)
                for (int v = 0; v < N_W; v++) begin
                    golden[h][v] = 0;
                    for (int t = 0; t < K_DEPTH; t++)
                        golden[h][v] += a_mat[h][t] * w_mat[t][v];
                end

            // Flush the resetless hop registers with zeros before enabling MAC.
            mac_en = 1'b0;
            drive_zeros();
            for (int t = 0; t < FLUSH_CYCLES; t++) begin
                @(posedge clk);
                @(negedge clk);
            end

            // Skewed stream.  Zero padding makes the fill and ramp-out edges
            // contribute nothing, so mac_en can stay high throughout.
            mac_en = 1'b1;
            for (int c = 0; c < STREAM_CYCLES; c++) begin
                drive_cycle(c);
                @(posedge clk);
                @(negedge clk);
            end
            mac_en = 1'b0;
            drive_zeros();

            // The accumulator must hold while mac_en is low, even though fresh
            // operands keep arriving on the hop.
            for (int idle = 0; idle < 3; idle++) begin
                for (int h = 0; h < N_H; h++)
                    a_in[h*IWIDTH +: IWIDTH] = rand_operand();
                for (int v = 0; v < N_W; v++)
                    w_in[v*IWIDTH +: IWIDTH] = rand_operand();
                @(posedge clk);
                @(negedge clk);
            end

            drain_matrix();
            check_matrix(block);
        end

        // acc_in_west is architectural: after a full drain the matrix is zero,
        // so shifting a marker in from the west must reappear N_W cycles later.
        for (int h = 0; h < N_H; h++)
            acc_in_west[h*OWIDTH +: OWIDTH] = OWIDTH'(-(h + 1));
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            @(posedge clk);
            @(negedge clk);
        end
        for (int h = 0; h < N_H; h++)
            if ($signed(acc_out_east[h*OWIDTH +: OWIDTH]) !== OWIDTH'(-(h + 1))) begin
                $display("[FAIL] west shift-in row=%0d got=%0d want=%0d", h,
                         $signed(acc_out_east[h*OWIDTH +: OWIDTH]), -(h + 1));
                errors++;
            end
        shift_in = 1'b0;

        if (errors != 0)
            $fatal(1, "FAIL: %0d mismatches in %0d blocks of %0d x %0d depth %0d",
                   errors, BLOCKS, N_H, N_W, K_DEPTH);
        $display("PASS: binary OS systolic array matched golden matmul, %0d blocks of %0dx%0d, depth %0d",
                 BLOCKS, N_H, N_W, K_DEPTH);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
