`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power + output-checking bench for the integrated SC array (payn_array).
//
// A length-T stochastic block takes MAC_CYCLES=T/M clocks.  One binary
// magnitude/sign batch is held for those clocks while Sobol advances every
// clock, producing a new M-bit parallel stochastic slice each cycle.  The
// measured workload runs many blocks back-to-back so magnitude/sign reload
// activity is represented instead of being hidden outside the SAIF window.
//
// After the long run, the accumulator matrix is drained and all issued batches
// plus the drain are written to array_streaming_rtl.txt.  The bit-exact check is
// post-hoc: designs/payn/cosim/cosim_streaming.py recomputes every cycle and
// asserts a bit-for-bit match (run via designs/payn/cosim/run_power_array.sh).
// Inputs are launched at the NEGEDGE (full half-cycle setup,
// insertion-independent) so routed clock insertion cannot race the launch.
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
// Numeric workload precision: the bipolar operand is a MAG_WIDTH-bit unsigned
// magnitude plus a separate sign bit.  The existing hardware comparator and
// Sobol threshold remain WIDTH=8, so encode a logical magnitude m as
// m << (WIDTH-MAG_WIDTH).  For the default 7-to-8-bit case this maps 0..127 to
// even thresholds 0..254 and preserves P(bit=1)=m/128.
`ifndef SC_MAG_WIDTH
`define SC_MAG_WIDTH 7
`endif
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_T
`define SC_T 128
`endif
`ifndef SC_BATCHES
`define SC_BATCHES 256
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
    localparam int MAG_WIDTH = `SC_MAG_WIDTH;
    localparam int MAG_SHIFT = WIDTH - MAG_WIDTH;
    localparam logic [WIDTH-1:0] LOGICAL_MAG_MASK =
        {WIDTH{1'b1}} >> (WIDTH - MAG_WIDTH);
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int T = `SC_T;
    localparam int MAC_CYCLES = T / M;
    localparam int N_BATCHES = `SC_BATCHES;
    localparam int TOTAL_MAC_CYCLES = N_BATCHES * MAC_CYCLES;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;
`ifdef PAYN_BLOCK_FINALIZE
    logic block_finalize = 1'b0;
`endif

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
`ifdef PAYN_BLOCK_FINALIZE
        , .BLOCK_T(MAC_CYCLES)
`endif
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

    task automatic randomize_batch;
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] =
                (WIDTH'($urandom) & LOGICAL_MAG_MASK) << MAG_SHIFT;
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] =
                (WIDTH'($urandom) & LOGICAL_MAG_MASK) << MAG_SHIFT;
            w_signs_in[i] = $urandom & 1;
        end
    endtask

    task automatic write_batch(input int batch);
        $fwrite(trace_file, "BATCH %0d\nAMAG", batch);
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
        int next_batch;

        assert (T > 0 && M > 0 && (T % M) == 0)
            else $fatal(1, "SC_T=%0d must be a positive multiple of M=%0d", T, M);
        assert (MAG_WIDTH > 0 && MAG_WIDTH <= WIDTH)
            else $fatal(1, "SC_MAG_WIDTH=%0d must be in [1, SC_WIDTH=%0d]",
                        MAG_WIDTH, WIDTH);
        assert (MAC_CYCLES >= 2)
            else $fatal(1, "streaming bench requires T/M >= 2 for the two-cycle input pipeline");
        assert (N_BATCHES > 0)
            else $fatal(1, "SC_BATCHES must be positive");
`ifdef PAYN_BLOCK_FINALIZE
        assert (N_BATCHES == 1)
            else $fatal(1, "PAYN_BLOCK_FINALIZE currently requires SC_BATCHES=1");
`endif

        seed_state = `SC_SEED;
        void'($urandom(seed_state));

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        // Let routed reset trees settle for two complete clocks before loading
        // operands.  This is outside the SAIF window and avoids recovery
        // notifiers caused by reset insertion delay in older checkpoints.
        repeat (2) @(negedge clk);

        trace_file = $fopen("array_streaming_rtl.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open array_streaming_rtl.txt");
        $fwrite(trace_file, "STREAMCFG %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, WIDTH, OWIDTH, T, N_BATCHES);

        // Launch batch zero and fill the peripheral/InnerPE input pipeline.
        // With nonblocking clocked stages, its first generated slice reaches
        // the accumulator two clocks after this load edge.
        randomize_batch();
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
        @(negedge clk);

        // ---- SAIF window: many contiguous T/M-cycle stochastic blocks ----
        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        monitor_x = 1'b1;
        mac_en = 1'b1;
        $toggle_start;
        next_batch = 1;

        for (int cycle = 0; cycle < TOTAL_MAC_CYCLES; cycle++) begin
            load_a = 1'b0;
            load_w = 1'b0;
            load_a_sign = 1'b0;
            load_w_sign = 1'b0;

            // The peripheral adds one stage and the InnerPE adds one bit/sign
            // stage.  Issuing the next batch two cycles before the current
            // block ends makes the accumulator see exactly MAC_CYCLES slices
            // from each batch with no bubble.
            if ((cycle % MAC_CYCLES) == (MAC_CYCLES - 2) &&
                next_batch < N_BATCHES) begin
                randomize_batch();
                write_batch(next_batch);
                next_batch++;
                load_a = 1'b1;
                load_w = 1'b1;
                load_a_sign = 1'b1;
                load_w_sign = 1'b1;
            end

            @(posedge clk);
            @(negedge clk);
        end

        assert (next_batch == N_BATCHES)
            else $fatal(1, "issued %0d of %0d streaming batches",
                        next_batch, N_BATCHES);
        mac_en = 1'b0;
        rng_en = 1'b0;
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
`ifdef PAYN_BLOCK_FINALIZE
        block_finalize = 1'b1;
        @(posedge clk);
        @(negedge clk);
        block_finalize = 1'b0;
`endif

        #1ps;
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain outside SAIF; append the observed matrix to the trace ----
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
