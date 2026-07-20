`timescale 1ns/1ps

// End-to-end bit-exact cosim driver for the integrated PaYN SC array.
// Generates random binary operands for one spatial tile, runs payn_array through
// reset -> load -> T stochastic MAC cycles -> row-serial drain, and dumps the
// operands + drained accumulator matrix to array_rtl.txt. cosim_array.py then
// recomputes the expected drain with sc_kernel.matmul and checks bit-for-bit.
//
// Needs the DesignWare sim library (InnerTile instantiates DW02_tree):
//   make sim TB=designs/payn/tb/test_payn_array.sv USE_DW=1

`include "payn/payn_array.sv"

`ifndef SC_K
`define SC_K 4
`endif
`ifndef SC_M
`define SC_M 4
`endif
`ifndef SC_NH
`define SC_NH 2
`endif
`ifndef SC_NW
`define SC_NW 2
`endif
`ifndef SC_WIDTH
`define SC_WIDTH 8
`endif
`ifndef SC_OWIDTH
`define SC_OWIDTH 16
`endif
`ifndef SC_T
`define SC_T 32
`endif
`ifndef SC_WARMUP
`define SC_WARMUP 2
`endif
`ifndef SC_SEED
`define SC_SEED 32'hDEAD_BEEF
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int WIDTH = `SC_WIDTH;
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int T = `SC_T;
    localparam int WARMUP = `SC_WARMUP;

    logic clk = 1'b0;
    logic reset = 1'b0;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0;
    logic load_a_sign = 1'b0, load_w_sign = 1'b0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    integer signed drain [N_H][N_W];
    integer trace_file;
    int seed_state;

    always #1.25 clk = ~clk;

    payn_array #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH)
    ) dut (.*);

    initial begin
        seed_state = `SC_SEED;
        void'($urandom(seed_state));   // seed the stream once, deterministically
        // Random operands: WIDTH-bit magnitudes, 1-bit signs.
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            w_signs_in[i] = $urandom & 1;
        end

        // ---- reset (clears InnerPE accumulators; parks Sobol at its seed) ----
        @(negedge clk);
        reset = 1'b1; rng_en = 1'b0; mac_en = 1'b0; shift_in = 1'b0;
        load_a = 1'b0; load_w = 1'b0; load_a_sign = 1'b0; load_w_sign = 1'b0;
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // ---- latch binary operands into the peripheral -----------------------
        load_a = 1'b1; load_w = 1'b1;
        @(negedge clk);            // posedge latched a_binary_q / w_binary_q
        load_a = 1'b0; load_w = 1'b0;

        // ---- load signs into the InnerPE pipe (gated by registered load wave) -
        load_a_sign = 1'b1; load_w_sign = 1'b1;
        @(negedge clk);            // load_*_sign_q <= 1
        @(negedge clk);            // *_signs_pipe loads while load_*_sign_q high
        load_a_sign = 1'b0; load_w_sign = 1'b0;

        // ---- productive window: rng advances every cycle; MAC thr[0..T-1] ----
        rng_en = 1'b1;
        for (int c = 0; c < WARMUP + T; c++) begin
            mac_en = (c >= WARMUP);
            @(posedge clk);
            @(negedge clk);
        end
        mac_en = 1'b0;
        rng_en = 1'b0;

        // ---- row-serial drain (mirrors test_inner_pe.sv), zero-fill west -----
        acc_in_west = '0;
        @(negedge clk);
        shift_in = 1'b1;
        // Read acc_out_east in the Active region right after the edge (the
        // pre-shift value), exactly as test_inner_pe.sv does its drain check.
        for (int s = 0; s < N_W; s++) begin
            @(posedge clk);
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] =
                    $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(negedge clk);
        end
        shift_in = 1'b0;

        // ---- dump operands + drain for the Python oracle --------------------
        trace_file = $fopen("array_rtl.txt", "w");
        assert (trace_file != 0) else $fatal(1, "cannot open array_rtl.txt");
        $fwrite(trace_file, "CFG %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, WIDTH, OWIDTH, T);
        $fwrite(trace_file, "AMAG");
        for (int i = 0; i < N_H*K; i++)
            $fwrite(trace_file, " %0d", a_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nASIGN");
        for (int i = 0; i < N_H*K; i++)
            $fwrite(trace_file, " %0d", a_signs_in[i]);
        $fwrite(trace_file, "\nWMAG");
        for (int i = 0; i < N_W*K; i++)
            $fwrite(trace_file, " %0d", w_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nWSIGN");
        for (int i = 0; i < N_W*K; i++)
            $fwrite(trace_file, " %0d", w_signs_in[i]);
        $fwrite(trace_file, "\nDRAIN");
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++)
                $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display("PASS: wrote array_rtl.txt (K=%0d M=%0d N=%0dx%0d T=%0d)",
                 K, M, N_H, N_W, T);
        $finish;
    end
endmodule
