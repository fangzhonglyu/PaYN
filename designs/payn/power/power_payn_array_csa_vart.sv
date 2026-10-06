`timescale 1ns/1ps

`include "common/clk_util.sv"

// Variable-length copy of power_payn_array.sv for the carry-save array
// (payn_array_signed_segmented_csa): block b holds its magnitude/sign batch for
// c_b clocks instead of a fixed MAC_CYCLES = T/M.  Everything else -- reset
// settle, NEGEDGE input launch, mac_en right after a posedge, the two-clock
// load lead (batch b+1 issued two clocks before block b ends), the SAIF window
// over every MAC clock, X monitor, drain after $toggle_stop -- is the original
// bench's code path for MAC_CYCLES >= 2.
//
// Stimulus (per-block cycle counts and every operand) comes from a file, so a
// run can replay another bench's exact operands:
//   csa_vart_stim.txt in the simulation directory (the runner copies it there),
//   written by sweeps/cbsg/tsweep/make_csa_vart_stim.py:
//     CSAVARTSTIM <N_BLOCKS> <N_H> <N_W> <K> <MAG_WIDTH>
//     then one line per block: c  aq[N_H*K]  as[N_H*K]  wq[N_W*K]  ws[N_W*K]
//   aq/wq are the logical MAG_WIDTH-bit magnitudes |q|; the bench sends
//   |q| << (WIDTH-MAG_WIDTH) exactly as power_payn_array.sv does (m << 1).
// Used for the CSA "ladder-equivalent" run: the A-first C-BSG ladder run's
// operands, each block held for c_b = ceil(max row L / 16) clocks (the CSA
// cannot give rows different lengths).
//
// Trace array_streaming_csa_vart_rtl.txt (STREAMCFGV header, BATCH b c_b per
// block, WINDOW, DRAIN) is checked bit-exact by
// sweeps/cbsg/tsweep/cosim_streaming_vart.py (cosim_streaming.py with
// per-block cycle counts).
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
`define SC_K 6
`endif
`ifndef SC_M
`define SC_M 16
`endif
`ifndef SC_NH
`define SC_NH 9
`endif
`ifndef SC_NW
`define SC_NW 9
`endif
`ifndef SC_WIDTH
`define SC_WIDTH 8
`endif
`ifndef SC_MAG_WIDTH
`define SC_MAG_WIDTH 7
`endif
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_BATCHES
`define SC_BATCHES 256
`endif
// Upper bound on any c_b (sizes the ClkUtils timeout only).
`ifndef SC_VART_MAX_CYCLES
`define SC_VART_MAX_CYCLES 8
`endif
`ifndef SC_RNG_FULL_PERIOD_WRAP
`define SC_RNG_FULL_PERIOD_WRAP 0
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
    localparam int MAG_WIDTH = `SC_MAG_WIDTH;
    localparam int MAG_SHIFT = WIDTH - MAG_WIDTH;
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int N_BATCHES = `SC_BATCHES;
    localparam int MAX_CYCLES = `SC_VART_MAX_CYCLES;
    localparam bit RNG_FULL_PERIOD_WRAP = `SC_RNG_FULL_PERIOD_WRAP;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    // Stimulus, read once at time zero.
    int blk_cycles [N_BATCHES];
    int a_q [N_BATCHES][N_H*K];
    int a_s [N_BATCHES][N_H*K];
    int w_q [N_BATCHES][N_W*K];
    int w_s [N_BATCHES][N_W*K];
    int total_cycles;

    integer signed drain [N_H][N_W];
    integer trace_file;
    bit monitor_x = 1'b0;

    ClkUtils #(.TIMEOUT(N_BATCHES * MAX_CYCLES + N_W + 256)) clk_utils (
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

    task automatic read_stimulus;
        int fd, n, nb, nh, nw, kk, mw, v;
        string tag;
        fd = $fopen("csa_vart_stim.txt", "r");
        assert (fd != 0) else $fatal(1, "cannot open csa_vart_stim.txt");
        n = $fscanf(fd, "%s %d %d %d %d %d", tag, nb, nh, nw, kk, mw);
        assert (n == 6 && tag == "CSAVARTSTIM")
            else $fatal(1, "stimulus header: read %0d fields, tag '%s'", n, tag);
        assert (nb == N_BATCHES && nh == N_H && nw == N_W && kk == K && mw == MAG_WIDTH)
            else $fatal(1, "stimulus shape %0d blocks %0dx%0d K%0d mag%0d != bench %0d blocks %0dx%0d K%0d mag%0d",
                        nb, nh, nw, kk, mw, N_BATCHES, N_H, N_W, K, MAG_WIDTH);
        total_cycles = 0;
        for (int b = 0; b < N_BATCHES; b++) begin
            n = $fscanf(fd, "%d", blk_cycles[b]);
            assert (n == 1) else $fatal(1, "stimulus block %0d: missing cycle count", b);
            // c_b >= 2 is the original bench's MAC_CYCLES >= 2 schedule (batch
            // b+1 issued two clocks before block b ends, never before it starts).
            assert (blk_cycles[b] >= 2 && blk_cycles[b] <= MAX_CYCLES)
                else $fatal(1, "stimulus block %0d: c=%0d outside [2, %0d]", b, blk_cycles[b], MAX_CYCLES);
            total_cycles += blk_cycles[b];
            for (int i = 0; i < N_H*K; i++) begin
                n = $fscanf(fd, "%d", a_q[b][i]);
                assert (n == 1 && a_q[b][i] >= 0 && a_q[b][i] < (1 << MAG_WIDTH))
                    else $fatal(1, "stimulus block %0d aq[%0d]", b, i);
            end
            for (int i = 0; i < N_H*K; i++) begin
                n = $fscanf(fd, "%d", a_s[b][i]);
                assert (n == 1 && (a_s[b][i] == 0 || a_s[b][i] == 1))
                    else $fatal(1, "stimulus block %0d as[%0d]", b, i);
            end
            for (int i = 0; i < N_W*K; i++) begin
                n = $fscanf(fd, "%d", w_q[b][i]);
                assert (n == 1 && w_q[b][i] >= 0 && w_q[b][i] < (1 << MAG_WIDTH))
                    else $fatal(1, "stimulus block %0d wq[%0d]", b, i);
            end
            for (int i = 0; i < N_W*K; i++) begin
                n = $fscanf(fd, "%d", w_s[b][i]);
                assert (n == 1 && (w_s[b][i] == 0 || w_s[b][i] == 1))
                    else $fatal(1, "stimulus block %0d ws[%0d]", b, i);
            end
        end
        n = $fscanf(fd, "%d", v);
        assert (n != 1) else $fatal(1, "stimulus has trailing values after %0d blocks", N_BATCHES);
        $fclose(fd);
    endtask

    // power_payn_array.sv's randomize_batch, with the batch's values taken
    // from the stimulus instead of $urandom.
    task automatic drive_batch(input int b);
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = WIDTH'(a_q[b][i]) << MAG_SHIFT;
            a_signs_in[i] = a_s[b][i][0];
        end
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = WIDTH'(w_q[b][i]) << MAG_SHIFT;
            w_signs_in[i] = w_s[b][i][0];
        end
    endtask

    task automatic write_batch(input int batch);
        $fwrite(trace_file, "BATCH %0d %0d\nAMAG", batch, blk_cycles[batch]);
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

    initial begin
        int next_batch, next_load, window_clocks;

        assert (M > 0 && MAG_WIDTH > 0 && MAG_WIDTH <= WIDTH)
            else $fatal(1, "bad M=%0d / SC_MAG_WIDTH=%0d / SC_WIDTH=%0d", M, MAG_WIDTH, WIDTH);
        assert (N_BATCHES > 1)
            else $fatal(1, "SC_BATCHES must be at least 2");

        read_stimulus();

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        // Let routed reset trees settle for two complete clocks before loading
        // operands (outside the SAIF window), as power_payn_array.sv does.
        repeat (2) @(negedge clk);

        trace_file = $fopen("array_streaming_csa_vart_rtl.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open array_streaming_csa_vart_rtl.txt");
        $fwrite(trace_file, "STREAMCFGV %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, WIDTH, OWIDTH, N_BATCHES, RNG_FULL_PERIOD_WRAP);

        // Launch batch zero and fill the peripheral/InnerPE input pipeline;
        // its first slice reaches the accumulator two clocks after this load
        // edge (power_payn_array.sv, MAC_CYCLES >= 2 branch).
        drive_batch(0);
        write_batch(0);
        rng_en = 1'b1;
        load_a = 1'b1;
        load_w = 1'b1;
        load_a_sign = 1'b1;
        load_w_sign = 1'b1;
        @(posedge clk);
        @(negedge clk);
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        @(posedge clk);
        // mac_en right after this posedge (a full period of setup for the
        // acc_low clock gate), as in power_payn_array.sv.
        mac_en = 1'b1;
        @(negedge clk);
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;

        // ---- SAIF window: every MAC clock of every block ----
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        monitor_x = 1'b1;
        $toggle_start;
        next_batch = 1;
        // Block b starts at window clock S_b = c_0 + ... + c_{b-1}; batch b is
        // issued at S_b - 2 (power_payn_array.sv: (cycle + 2) % MAC_CYCLES == 0).
        next_load = blk_cycles[0] - 2;
        window_clocks = 0;

        for (int cycle = 0; cycle < total_cycles; cycle++) begin
            load_a = 1'b0;
            load_w = 1'b0;
            load_a_sign = 1'b0;
            load_w_sign = 1'b0;
            if (cycle == next_load && next_batch < N_BATCHES) begin
                drive_batch(next_batch);
                write_batch(next_batch);
                next_load += blk_cycles[next_batch];
                next_batch++;
                load_a = 1'b1;
                load_w = 1'b1;
                load_a_sign = 1'b1;
                load_w_sign = 1'b1;
            end

            @(posedge clk);
            @(negedge clk);
            window_clocks++;
        end

        assert (next_batch == N_BATCHES && window_clocks == total_cycles)
            else $fatal(1, "issued %0d of %0d batches, %0d window clocks for %0d block cycles",
                        next_batch, N_BATCHES, window_clocks, total_cycles);
        mac_en = 1'b0;
        rng_en = 1'b0;
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;

        #1ps;
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain outside SAIF (power_payn_array.sv, unchanged) ----
        acc_in_west = '0;
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            @(posedge clk);
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(negedge clk);
        end
        shift_in = 1'b0;

        $fwrite(trace_file, "WINDOW %0d\n", window_clocks);
        $fwrite(trace_file, "DRAIN");
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display("PASS: streaming SC vart SAIF captured; %0d batches, %0d window clocks, drain dumped -> cosim_streaming_vart.py",
                 N_BATCHES, window_clocks);
        $finish;
    end
endmodule
