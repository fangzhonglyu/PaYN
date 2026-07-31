`timescale 1ns/1ps

`include "common/clk_util.sv"

// Padded-T variant of power_payn_array.sv: allows SC_T that is NOT a multiple
// of M.  A length-T block executes in MAC_CYCLES = ceil(T/M) clocks; the last
// slice of every block carries only T%M real samples and the top
// PAD_LANES = MAC_CYCLES*M - T lanes of each operand unit are forced to zero
// at the u_pe boundary.  This models a mask-after-compare implementation: the
// peripheral and both Sobol banks run full width every clock (as they would in
// real padded hardware) while the compute array sees literal zeros in the pad
// slots.  For T % M == 0 the bench is behaviorally identical to
// power_payn_array.sv.  The reference model (cosim_streaming.py) masks the
// same lanes, so the post-hoc drain check is bit-exact and also validates the
// mask phase: masking the wrong slice mismatches the drain.
//
// Everything below this paragraph other than MAC_CYCLES/PAD_LANES, the
// pad_mask_en schedule, and the force/release generate blocks is a verbatim
// copy of power_payn_array.sv.
//
// A length-T stochastic block takes MAC_CYCLES clocks.  One binary
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
    localparam logic [WIDTH-1:0] LOGICAL_MAG_MASK =
        {WIDTH{1'b1}} >> (WIDTH - MAG_WIDTH);
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int T = `SC_T;
    // ceil(T/M): a block with a partial final slice still costs a full clock.
    localparam int MAC_CYCLES = (T + M - 1) / M;
    // Dead lanes in the final slice of every block; 0 restores the exact
    // behavior of power_payn_array.sv.
    localparam int PAD_LANES = MAC_CYCLES*M - T;
    localparam int N_BATCHES = `SC_BATCHES;
    localparam int TOTAL_MAC_CYCLES = N_BATCHES * MAC_CYCLES;
    localparam bit RNG_FULL_PERIOD_WRAP = `SC_RNG_FULL_PERIOD_WRAP;
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

`ifdef PAYN_XTRACE
    // Debug only: dump the whole DUT so an X transition can be traced to its
    // source net.  Never defined in normal power runs.
    //   PAYN_XTRACE        : dump from t=0 (startup X; the $fatal ends the run)
    //   +PAYN_XTRACE_DRAIN : hold the dump off until just before the drain, so
    //                        the ~7.7 ms window stays a tractable file size
    initial begin
        $dumpfile("xtrace.vcd");
        $dumpvars(0, dut);
`ifdef PAYN_XTRACE_DRAIN
        $dumpoff;
`endif
    end
`endif

    `PAYN_ARRAY_DUT #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH)
`ifdef PAYN_BLOCK_FINALIZE
        , .BLOCK_T(MAC_CYCLES)
`endif
    ) dut (.*);

    // ---------------------------------------------------------- T padding --
    // While pad_mask_en is high, the top PAD_LANES lanes of every operand
    // unit are forced to zero at the u_pe boundary (the flattened
    // InnerPE*Flat ports, identical in RTL and gate netlists).
    //
    // Timing, chosen so each pad net makes exactly one entry and one exit
    // transition per block (what a mask-after-compare gate whose mask beats
    // the comparator would do):
    //  * ENTRY at the pad interval's NEGEDGE.  In GL the compare path
    //    delivers the new slice near the END of the cycle, so at the negedge
    //    the boundary still holds the previous (already captured) value; the
    //    force truncates it to 0 once.  Capture races are impossible: the
    //    gated/routed clock reaches the pipe flops ~1 ns after the launch
    //    edge, long before the negedge.  (Do NOT move the entry to the
    //    launch posedge: the force would beat the delayed clock to the flop
    //    D pins and corrupt the PREVIOUS slice's capture.)
    //  * EXIT delayed to 0.1 ns before the next launch edge, after the next
    //    slice's live value has settled at the boundary, so the net makes a
    //    single 0 -> live transition.  A first version released at the next
    //    negedge instead; exposing the stale pre-pad value mid-cycle added
    //    an extra transition per pad lane per block on the operand-broadcast
    //    nets and measurably inflated power (T'=120 came out 1.2% ABOVE
    //    T=128; results_maskA_negedge.csv preserves that run).
    localparam real PAD_RELEASE_DLY = PERIOD/2.0 - 0.1;
    bit pad_mask_en = 1'b0;

    // PAYN_TPAD_MASK_W_ONLY: a product bit dies when EITHER operand bit is
    // zero, so masking only the W side is functionally identical (bit-exact
    // same drain, reference unchanged) but pays the boundary-net toggle tax
    // on half as many nets.  A real padded design should do this.
    if (PAD_LANES > 0) begin : g_tpad
`ifndef PAYN_TPAD_MASK_W_ONLY
        for (genvar u = 0; u < N_H*K; u++) begin : g_a
            always @(pad_mask_en)
                if (pad_mask_en)
                    force dut.u_pe.a_bits_in[u*M + M - 1 -: PAD_LANES] = '0;
                else begin
                    #(PAD_RELEASE_DLY);
                    release dut.u_pe.a_bits_in[u*M + M - 1 -: PAD_LANES];
                end
        end
`endif
        for (genvar u = 0; u < N_W*K; u++) begin : g_w
            always @(pad_mask_en)
                if (pad_mask_en)
                    force dut.u_pe.w_bits_in[u*M + M - 1 -: PAD_LANES] = '0;
                else begin
                    #(PAD_RELEASE_DLY);
                    release dut.u_pe.w_bits_in[u*M + M - 1 -: PAD_LANES];
                end
        end
    end

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

        assert (T > 0 && M > 0)
            else $fatal(1, "SC_T=%0d and SC_M=%0d must be positive", T, M);
        if (PAD_LANES > 0)
            $display("[INFO] padded T: T=%0d executes as %0d slices of M=%0d with %0d dead lanes in the final slice",
                     T, MAC_CYCLES, M, PAD_LANES);
        assert (MAG_WIDTH > 0 && MAG_WIDTH <= WIDTH)
            else $fatal(1, "SC_MAG_WIDTH=%0d must be in [1, SC_WIDTH=%0d]",
                        MAG_WIDTH, WIDTH);
        assert (MAC_CYCLES >= 1)
            else $fatal(1, "streaming bench requires T/M >= 1");
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
        $fwrite(trace_file,
                "STREAMCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, WIDTH, OWIDTH, T, N_BATCHES,
                RNG_FULL_PERIOD_WRAP);

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
        // At MAC_CYCLES=1 every slice is a final slice, including batch 0's
        // first slice which rides the boundary bus during this pre-window
        // clock -- mask it here; the loop below cannot reach it.
        pad_mask_en = (PAD_LANES > 0) && (MAC_CYCLES == 1);
        // At MAC_CYCLES=1 every window clock is a block boundary, so the
        // operand feed has to run two batches ahead of the accumulator instead
        // of one.  Issue batch 1 in this second pre-window clock; the window
        // then opens already owing batch 2.  For MAC_CYCLES >= 2 this branch is
        // not taken and the prologue is unchanged.
        if (MAC_CYCLES < 2 && N_BATCHES > 1) begin
            randomize_batch();
            write_batch(1);
        end else begin
            load_a = 1'b0;
            load_w = 1'b0;
            load_a_sign = 1'b0;
            load_w_sign = 1'b0;
        end
        @(posedge clk);
        // Assert mac_en here, immediately after this posedge, rather than at the
        // negedge below.  It gates acc_low's clock; the SDC constrains it with
        // `set_input_delay 0.05`, so STA verified ~a full period of propagation,
        // while a negedge launch grants only half.  On wide arrays it then reaches
        // the shared acc_low ICG ~46 ps before the edge against a 55 ps setup,
        // the notifier drives ENCLK to X, and the X lands in the accumulator.
        // The first accumulating edge is unchanged -- this only buys setup margin.
        mac_en = 1'b1;
        @(negedge clk);
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;

        // ---- SAIF window: many contiguous T/M-cycle stochastic blocks ----
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        // RTL runs feed SYN_SAIF_FILE (workload-driven synthesis). Without the
        // "sv" argument VCS skips SystemVerilog-typed nets and the SAIF comes
        // out empty; it also needs -lca on the VCS command line.
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        monitor_x = 1'b1;
        // mac_en was asserted one half-cycle earlier (see above) for setup margin.
        $toggle_start;
        // MAC_CYCLES=1 opened the window with batch 1 already issued.
        next_batch = (MAC_CYCLES < 2 && N_BATCHES > 1) ? 2 : 1;

        for (int cycle = 0; cycle < TOTAL_MAC_CYCLES; cycle++) begin
            // The boundary bus carries a block's FINAL slice during exactly
            // the cycles where the next batch is issued (load captures at
            // the closing edge; the new block's first slice appears the next
            // cycle with no bubble).  Same modulus, without the
            // next_batch < N_BATCHES qualifier: the last block has no
            // successor to load but still has a final slice to mask.  This
            // body runs in the negedge half-cycle -- the mask ENTRY point;
            // see the timing note at the g_tpad generate block.
            pad_mask_en = (PAD_LANES > 0) && (((cycle + 2) % MAC_CYCLES) == 0);
            load_a = 1'b0;
            load_w = 1'b0;
            load_a_sign = 1'b0;
            load_w_sign = 1'b0;

            // The peripheral adds one stage and the InnerPE adds one bit/sign
            // stage.  Issuing the next batch two cycles before the current
            // block ends makes the accumulator see exactly MAC_CYCLES slices
            // from each batch with no bubble.
            // Equivalent to (cycle % MAC_CYCLES) == MAC_CYCLES - 2 whenever
            // MAC_CYCLES >= 2, but also well-defined at MAC_CYCLES = 1, where
            // it fires every clock.
            if (((cycle + 2) % MAC_CYCLES) == 0 &&
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
        pad_mask_en = 1'b0;
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

`ifdef PAYN_XTRACE_DRAIN
        $dumpon;   // arm the dump for the drain only
`endif
        // ---- drain outside SAIF; append the observed matrix to the trace ----
        // Align to a posedge, then assert shift_in immediately after it.  shift_in
        // gates acc_high; the SDC constrains it with `set_input_delay 0.05`, so STA
        // verified ~a full period to cross the array.  Asserting at the negedge (as
        // the plain `shift_in = 1` here used to) grants only half, and on wide
        // arrays it reaches the far tiles' ICG enable inside the setup window --
        // the notifier then drives ENCLK to X and corrupts the drained value.
        // Traced at N=12: clk_gate_acc_high X at t=7704737, ~26 ps after the edge.
        // The alignment edge itself has mac_en=0 and shift_in=0, so it shifts
        // nothing and additionally retires any pending carry/borrow.
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
