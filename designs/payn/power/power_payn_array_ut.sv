`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power + output-checking bench for payn_array in STREAM_MODE=1 (unary
// temporal A, sample-ordered Sobol W). Same structure and timing conventions as
// power_payn_array.sv; only the stream semantics differ:
//
//   * every batch is one K-block: rng_restart is asserted with its load, so its
//     streams start at sample 0 (gapless: the restart edge emits cycle 0), and
//     d_base = batch*K selects its column masks (latched with the operands);
//   * operands are the emulator's: a logical magnitude m (uniform 0..127, the
//     same distribution as power_payn_array.sv) maps to the threshold
//     b = round(m*128/127); W gets b, A gets its thermometer length
//     kA = round(b*T/128).
//
// After the run the accumulator is drained and all batches plus the drain go to
// array_streaming_ut_rtl.txt; cosim_streaming_ut.py checks it bit-for-bit
// against an emulator-defined reference (run_power_array_ut.sh).
//
// A paths: SC_A_ENCODER=0 feeds the host-side UT kA. SC_A_ENCODER=1 feeds bA to
// the on-chip encoder one batch ahead (its count overlaps the previous batch,
// so the MAC stream stays gapless); its scheme is fixed when the design is
// built (payn_array A_CBSG / PAYN_A_CBSG). SC_CBSG must match it (0 = UT,
// 1 = C-BSG): it only labels the trace for cosim_streaming_ut.py.
//
// +define+SC_GATED: DUT is payn_array_gated_cbsg with STREAMS=1 (gated W on
// the emulator's streams; PAYN_ARRAY_DUT=payn_array_gated_cbsg,
// PAYN_GATED_STREAMS=1). It takes bA for the current batch; the trace is
// labelled C-BSG so the checker counts A's ones from the emulator stream.
//
// RTL runs need +define+PAYN_STREAM_MODE=1 (and +define+PAYN_A_ENCODER=1 plus
// +define+PAYN_A_CBSG=<0|1> for the encoder); the gate-level netlist is
// synthesized with them. Needs DesignWare: USE_DW=1.

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
`ifndef SC_A_ENCODER
`define SC_A_ENCODER 0
`endif
`ifndef SC_CBSG
`define SC_CBSG 0
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
    localparam int A_ENCODER = `SC_A_ENCODER;
`ifdef SC_GATED
    localparam int GATED = 1;
`else
    localparam int GATED = 0;
`endif

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

    // All batches are drawn up front: with the encoder, A is presented one
    // batch ahead of W.
    logic [N_H*K*WIDTH-1:0] a_bat [N_BATCHES];
    logic [N_H*K-1:0]       as_bat [N_BATCHES];
    logic [N_W*K*WIDTH-1:0] w_bat [N_BATCHES];
    logic [N_W*K-1:0]       ws_bat [N_BATCHES];

    task automatic draw_batches;
        for (int bt = 0; bt < N_BATCHES; bt++) begin
            for (int i = 0; i < N_H*K; i++) begin
                int b;
                b = threshold($urandom & 7'h7f);
                // Encoder takes bA; host-side UT feeds kA = round(bA*T/128).
                a_bat[bt][i*WIDTH +: WIDTH] =
                    (A_ENCODER || GATED) ? WIDTH'(b) : WIDTH'((b * T + GRID / 2) / GRID);
                as_bat[bt][i] = $urandom & 1;
            end
            for (int i = 0; i < N_W*K; i++) begin
                w_bat[bt][i*WIDTH +: WIDTH] = WIDTH'(threshold($urandom & 7'h7f));
                ws_bat[bt][i] = $urandom & 1;
            end
        end
    endtask

    // Present batch bt's A (and its d_base) on the A inputs; zeros past the end.
    task automatic present_a(input int bt);
        a_binary_in = (bt < N_BATCHES) ? a_bat[bt] : '0;
        a_signs_in = (bt < N_BATCHES) ? as_bat[bt] : '0;
        d_base = 16'(bt * K);
    endtask

    task automatic write_batch(input int bt);
        $fwrite(trace_file, "BATCH %0d %0d\nAMAG", bt, bt * K);
        for (int i = 0; i < N_H*K; i++)
            $fwrite(trace_file, " %0d", a_bat[bt][i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nASIGN");
        for (int i = 0; i < N_H*K; i++)
            $fwrite(trace_file, " %0d", as_bat[bt][i]);
        $fwrite(trace_file, "\nWMAG");
        for (int i = 0; i < N_W*K; i++)
            $fwrite(trace_file, " %0d", w_bat[bt][i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nWSIGN");
        for (int i = 0; i < N_W*K; i++)
            $fwrite(trace_file, " %0d", ws_bat[bt][i]);
        $fwrite(trace_file, "\n");
    endtask

    // Load batch bt into the peripheral (with the encoder, its kA comes out of
    // the encoder while batch bt+1's A goes in).
    task automatic issue_batch(input int bt);
        write_batch(bt);
        present_a(A_ENCODER ? bt + 1 : bt);
        w_binary_in = w_bat[bt];
        w_signs_in = ws_bat[bt];
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
            else $fatal(1, "UT streaming bench requires T/M >= 2");
        assert (N_BATCHES > 0)
            else $fatal(1, "SC_BATCHES must be positive");

        seed_state = `SC_SEED;
        void'($urandom(seed_state));

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("array_streaming_ut_rtl.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open array_streaming_ut_rtl.txt");
        $fwrite(trace_file, "STREAMCFG_UT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, WIDTH, OWIDTH, T, N_BATCHES,
                (A_ENCODER || GATED) ? 1 : 0, GATED ? 1 : `SC_CBSG);
        draw_batches();

        if (A_ENCODER) begin
            // Pre-load batch 0's A into the encoder and let it count (outside
            // the SAIF window): load with rng_en starts the count gaplessly.
            present_a(0);
            load_a = 1'b1;
            rng_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            load_a = 1'b0;
            repeat (MAC_CYCLES - 1) begin
                @(posedge clk);
                @(negedge clk);
            end
        end

        // Batch zero: restart + load on the same edge, then fill the pipe.
        issue_batch(0);
        rng_en = 1'b1;
        @(posedge clk);
        @(negedge clk);
        idle_controls();
        @(posedge clk);
        // mac_en right after this posedge for setup margin (see power_payn_array.sv).
        mac_en = 1'b1;
        @(negedge clk);

        // ---- SAIF window: back-to-back T/M-cycle K-blocks ----
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
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

        // ---- drain outside SAIF (same protocol as power_payn_array.sv) ----
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

        $display("PASS: UT streaming SC SAIF captured; %0d batches x %0d cycles, drain dumped -> cosim_streaming_ut.py",
                 N_BATCHES, MAC_CYCLES);
        $finish;
    end
endmodule
