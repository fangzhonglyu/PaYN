`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power + output-checking bench for payn_array (C-BSG).
//
// A length-T stochastic block takes MAC_CYCLES = T/M clocks. Every batch is one
// K-block: rng_restart is asserted with its loads, so its streams start at
// sample 0 (gapless -- the restart edge emits cycle 0), and d_base = batch*K
// selects its column masks (latched with the operands). The measured workload
// runs many blocks back-to-back so operand reload activity is inside the SAIF
// window. Operands are the emulator's thresholds: a logical magnitude m
// (uniform 0..127, random sign) maps to b = round(m * 128 / 127).
//
// After the run the accumulator is drained and all batches plus the drain go to
// array_streaming_rtl.txt; cosim_streaming.py checks it bit-for-bit against the
// emulator's C-BSG definition (run_power_array.sh). Inputs are launched at the
// NEGEDGE (full half-cycle setup, insertion-independent).
//
// Needs DesignWare for the RTL InnerTile heap: make sim ... USE_DW=1

`ifndef GL_SIM
`ifndef PAYN_ARRAY_EXTERNAL_RTL
`include "payn/payn_array.sv"
`endif
`endif

`ifndef PAYN_ARRAY_DUT
`define PAYN_ARRAY_DUT payn_array
`endif

`ifndef SC_K
`define SC_K 8
`endif
`ifndef SC_M
`define SC_M 16
`endif
`ifndef SC_NH
`define SC_NH 8
`endif
`ifndef SC_NW
`define SC_NW 8
`endif
`ifndef SC_WIDTH
`define SC_WIDTH 8
`endif
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_T
`define SC_T 128
`endif
`ifndef SC_BATCHES
`define SC_BATCHES 384
`endif
`ifndef SC_SEED
`define SC_SEED 32'hDEAD_BEEF
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int WIDTH = `SC_WIDTH;
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int T = `SC_T;
    localparam int MAC_CYCLES = T / M;
    localparam int N_BATCHES = `SC_BATCHES;
    localparam int TOTAL_MAC_CYCLES = N_BATCHES * MAC_CYCLES;
    localparam int GRID = 128;
    localparam int Q_MAX = 127;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic rng_restart = 1'b0;
    logic [15:0] d_base = '0;
    logic [7:0] stream_len = 8'(T);
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    integer signed drain [N_H][N_W];
    integer trace_file;
    int seed_state;
    bit monitor_x = 1'b0;

    ClkUtils #(.TIMEOUT(TOTAL_MAC_CYCLES + N_W + 256)) clk_utils (
        .clk, .reset, .timeout
    );

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] SC drain rail entered X during SAIF: %h", acc_out_east);

    `PAYN_ARRAY_DUT #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH)
    ) dut (.*);

`ifdef GL_SIM
    initial begin
`ifndef NO_SDF
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
`endif
    end
`endif

    // round(m * 128 / 127) for a logical magnitude m in 0..127.
    function automatic int threshold(input int m);
        return (m * GRID * 2 + Q_MAX) / (2 * Q_MAX);
    endfunction

    task automatic randomize_batch(input int batch);
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = WIDTH'(threshold($urandom & 7'h7f));
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = WIDTH'(threshold($urandom & 7'h7f));
            w_signs_in[i] = $urandom & 1;
        end
        d_base = 16'(batch * K);
    endtask

    task automatic write_batch(input int batch);
        $fwrite(trace_file, "BATCH %0d %0d\nAMAG", batch, d_base);
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
        $fwrite(trace_file, "\n");
    endtask

    task automatic issue_batch(input int batch);
        randomize_batch(batch);
        write_batch(batch);
        rng_restart = 1'b1;
        load_a = 1'b1;
        load_w = 1'b1;
        load_a_sign = 1'b1;
        load_w_sign = 1'b1;
    endtask

    task automatic idle_controls;
        rng_restart = 1'b0;
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
    endtask

    initial begin
        int next_batch;

        assert (T > 0 && M > 0 && (T % M) == 0 && T <= GRID)
            else $fatal(1, "SC_T=%0d must be a multiple of M=%0d and <= %0d", T, M, GRID);
        assert (MAC_CYCLES >= 2)
            else $fatal(1, "streaming bench requires T/M >= 2");
        assert (N_BATCHES > 0)
            else $fatal(1, "SC_BATCHES must be positive");

        seed_state = `SC_SEED;
        void'($urandom(seed_state));

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        // Let routed reset trees settle for two complete clocks before loading
        // operands (outside the SAIF window).
        repeat (2) @(negedge clk);

        trace_file = $fopen("array_streaming_rtl.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open array_streaming_rtl.txt");
        $fwrite(trace_file, "STREAMCFG %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, WIDTH, OWIDTH, T, N_BATCHES);

        // Batch zero: restart + load on the same edge, then fill the pipe.
        issue_batch(0);
        rng_en = 1'b1;
        @(posedge clk);
        @(negedge clk);
        idle_controls();
        @(posedge clk);
        // Assert mac_en right after this posedge rather than at the negedge: it
        // gates the accumulator clock and the SDC gives it a full period, while
        // a negedge launch would grant only half. The first accumulating edge is
        // unchanged -- this only buys setup margin.
        mac_en = 1'b1;
        @(negedge clk);

        // ---- SAIF window: back-to-back T/M-cycle K-blocks ----
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        // RTL runs feed SYN_SAIF_FILE; "sv" is needed for SV-typed nets (and
        // VCS needs -lca).
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        monitor_x = 1'b1;
        $toggle_start;
        next_batch = 1;

        for (int cycle = 0; cycle < TOTAL_MAC_CYCLES; cycle++) begin
            idle_controls();
            // Issue the next block two cycles before this one ends (peripheral
            // + InnerPE stages) so the accumulator sees exactly MAC_CYCLES
            // slices per block with no bubble.
            if (((cycle + 2) % MAC_CYCLES) == 0 && next_batch < N_BATCHES) begin
                issue_batch(next_batch);
                next_batch++;
            end
            @(posedge clk);
            @(negedge clk);
        end

        assert (next_batch == N_BATCHES)
            else $fatal(1, "issued %0d of %0d streaming batches", next_batch, N_BATCHES);
        mac_en = 1'b0;
        rng_en = 1'b0;
        idle_controls();

        #1ps;
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain outside SAIF ----
        // shift_in is asserted right after a posedge for the same setup-margin
        // reason as mac_en; the alignment edge has mac_en=0 and shifts nothing.
        acc_in_west = '0;
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            @(posedge clk);
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(negedge clk);
        end
        shift_in = 1'b0;

        $fwrite(trace_file, "DRAIN");
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display("PASS: streaming SC SAIF captured; %0d batches x %0d cycles, drain dumped -> cosim_streaming.py",
                 N_BATCHES, MAC_CYCLES);
        $finish;
    end
endmodule
