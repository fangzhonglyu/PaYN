`timescale 1ns/1ps

`include "common/clk_util.sv"

// PE-level power + output-checking bench for the InnerPE tile grid (the SC PE).
//
// The M=16 stochastic bit-pairs per operand are generated the SAME way the array
// does it in hardware: real sobol_bank x2 + sc_pe_peripheral are instantiated
// here as STIMULUS GENERATORS (outside the SAIF toggle region), fed real binary
// operands, and their comparator outputs drive the InnerPE. So the PE sees
// hardware-faithful streams -- each operand's 16 bits are `operand > sobol[m]`
// across 16 different RNGs -- NOT uniform-random bits. Only the InnerPE DUT is in
// the toggle region, so the SAIF measures the compute core alone.
//
// One binary magnitude/sign batch is held for T/M cycles while Sobol advances
// every cycle.  The measured workload runs many batches back-to-back, and its
// array_streaming_rtl.txt trace is checked post-hoc by cosim_streaming.py.
// Bank/peripheral config mirrors payn_array exactly (A: identity DVs 0x17/0x53;
// W: decorrelated DVs 0x9d/0x2b; salts 0 / 2^(WIDTH-1)).  All inputs launch at
// the NEGEDGE (insertion-independent); timing checks remain ON.
//
// Needs DesignWare for the InnerTile heap: make sim ... USE_DW=1

`include "payn/sobol.sv"
`include "payn/pe_peripheral.sv"
`ifndef GL_SIM
`include "payn/inner_pe.sv"
`endif

`ifndef SC_K
`define SC_K 6
`endif
`ifndef SC_M
`define SC_M 16
`endif
`ifndef SC_N
`define SC_N 9
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
`ifndef SC_DUT
`define SC_DUT sc_inner_pe_manual_k6m16n9_ow24
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N = `SC_N;              // N_H = N_W = N for the square PE
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

    logic [N*K*WIDTH-1:0] a_binary_in = '0;
    logic [N*K-1:0]       a_signs_in = '0;
    logic [N*K*WIDTH-1:0] w_binary_in = '0;
    logic [N*K-1:0]       w_signs_in = '0;

    // peripheral-generated stochastic streams (stimulus into the DUT)
    logic [M*WIDTH-1:0]   a_random_values, w_random_values;
    logic [N*K*M-1:0]     a_bits;
    logic [N*K-1:0]       a_signs;
    logic [N*K*M-1:0]     w_bits;
    logic [N*K-1:0]       w_signs;

    // systolic passthrough outputs are unused for a single PE
    logic [N*K*M-1:0] a_bits_out_nc, w_bits_out_nc;
    logic [N*K-1:0]   a_signs_out_nc, w_signs_out_nc;
    logic load_a_sign_out_nc, load_w_sign_out_nc;

    logic [N*OWIDTH-1:0] acc_in_west = '0;
    logic [N*OWIDTH-1:0] acc_out_east;

    integer signed drain [N][N];
    integer trace_file;
    int seed_state;
    bit monitor_x = 1'b0;

    ClkUtils #(.TIMEOUT(TOTAL_MAC_CYCLES + N + 256)) clk_utils (
        .clk, .reset, .timeout
    );

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] InnerPE drain rail entered X during SAIF: %h", acc_out_east);

    // ---- stimulus generators (NOT in the toggle region) ---------------------
    // Real Sobol banks + peripheral, wired exactly as payn_array does, so the
    // DUT sees the same 16-RNG comparator streams it does in the full array.
    sobol_bank #(
        .WIDTH(WIDTH), .M(M), .DIRECTION_SET(0),
        .DIGITAL_SHIFT_BASE(8'h17), .DIGITAL_SHIFT_STRIDE(8'h53)
    ) u_a_rng (
        .clk, .reset, .enable(rng_en), .random_values(a_random_values)
    );
    sobol_bank #(
        .WIDTH(WIDTH), .M(M), .DIRECTION_SET(1),
        .DIGITAL_SHIFT_BASE(8'h9d), .DIGITAL_SHIFT_STRIDE(8'h2b)
    ) u_w_rng (
        .clk, .reset, .enable(rng_en), .random_values(w_random_values)
    );
    sc_pe_peripheral #(
        .K(K), .M(M), .N_H(N), .N_W(N), .WIDTH(WIDTH),
        .A_SCRAMBLE_SALT(0), .W_SCRAMBLE_SALT(1 << (WIDTH - 1))
    ) u_periph (
        .clk, .reset, .load_a, .load_w,
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in,
        .a_random_values, .w_random_values,
        .a_bits, .a_signs, .w_bits, .w_signs
    );

    // ---- DUT: the InnerPE compute core (the only toggle-region instance) -----
    `SC_DUT dut (
        .clk, .reset, .mac_en, .shift_in,
        .a_bits_in(a_bits),   .a_signs_in(a_signs),
        .w_bits_in(w_bits),   .w_signs_in(w_signs),
        .load_a_sign_in(load_a_sign), .load_w_sign_in(load_w_sign),
        .a_bits_out(a_bits_out_nc),   .a_signs_out(a_signs_out_nc),
        .w_bits_out(w_bits_out_nc),   .w_signs_out(w_signs_out_nc),
        .load_a_sign_out(load_a_sign_out_nc),
        .load_w_sign_out(load_w_sign_out_nc),
        .acc_in_west, .acc_out_east
    );

`ifdef GL_SIM
    initial begin
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
    end
`endif

    task automatic randomize_batch;
        for (int i = 0; i < N*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] =
                (WIDTH'($urandom) & LOGICAL_MAG_MASK) << MAG_SHIFT;
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] =
                (WIDTH'($urandom) & LOGICAL_MAG_MASK) << MAG_SHIFT;
            w_signs_in[i] = $urandom & 1;
        end
    endtask

    task automatic write_batch(input int batch);
        $fwrite(trace_file, "BATCH %0d\nAMAG", batch);
        for (int i = 0; i < N*K; i++)
            $fwrite(trace_file, " %0d", a_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nASIGN");
        for (int i = 0; i < N*K; i++)
            $fwrite(trace_file, " %0d", a_signs_in[i]);
        $fwrite(trace_file, "\nWMAG");
        for (int i = 0; i < N*K; i++)
            $fwrite(trace_file, " %0d", w_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nWSIGN");
        for (int i = 0; i < N*K; i++)
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

        seed_state = `SC_SEED;
        void'($urandom(seed_state));

        // Reset is asynchronous for the peripheral/Sobol generators and
        // synchronous for the InnerPE. The common utility holds it across two
        // active clock edges for reliable routed gate-level initialization.
        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        trace_file = $fopen("array_streaming_rtl.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open array_streaming_rtl.txt");
        $fwrite(trace_file, "STREAMCFG %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N, N, WIDTH, OWIDTH, T, N_BATCHES);

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
        #1ps;
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain (outside SAIF window) + dump trace for cosim check ----
        acc_in_west = '0;
        shift_in = 1'b1;
        for (int s = 0; s < N; s++) begin
            @(posedge clk);
            for (int h = 0; h < N; h++)
                drain[h][N-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(negedge clk);
        end
        shift_in = 1'b0;

        $fwrite(trace_file, "DRAIN");
        for (int h = 0; h < N; h++)
            for (int v = 0; v < N; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display("PASS: streaming InnerPE SAIF captured; %0d batches x %0d cycles, drain dumped -> cosim_streaming.py",
                 N_BATCHES, MAC_CYCLES);
        $finish;
    end
endmodule
