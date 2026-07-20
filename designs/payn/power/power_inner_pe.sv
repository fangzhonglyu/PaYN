`timescale 1ns/1ps

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
// Bank/peripheral config mirrors payn_array exactly (A: identity DVs 0x17/0x53;
// W: decorrelated DVs 0x9d/0x2b; salts 0 / 2^(WIDTH-1)) so the drain is bit-exact
// against sc_kernel.py -- checked post-hoc by cosim_array.py on array_rtl.txt.
// All inputs launched at the NEGEDGE (insertion-independent); timing checks ON.
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
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_T
`define SC_T 128
`endif
`ifndef SC_WARMUP
`define SC_WARMUP 2
`endif
// Cycles to skip at the start of the productive phase before opening the SAIF
// window (startup transient on the resetless bit-pipes); the drain is still
// output-X-checked over the whole productive phase. See power_payn_array.sv.
`ifndef SC_SETTLE
`define SC_SETTLE 8
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
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int T = `SC_T;
    localparam int WARMUP = `SC_WARMUP;
    localparam int SETTLE = `SC_SETTLE;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    logic clk = 1'b0;
    logic reset = 1'b0;
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

    always #(PERIOD/2.0) clk = ~clk;

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

    initial begin
        seed_state = `SC_SEED;
        void'($urandom(seed_state));
        for (int i = 0; i < N*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            w_signs_in[i] = $urandom & 1;
        end

        // reset (async for peripheral + Sobol, sync for InnerPE)
        @(negedge clk);
        reset = 1'b1;
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // latch operands into the peripheral (control launched at the NEGEDGE:
        // full half-cycle setup, clears the clock-tree insertion by construction)
        @(posedge clk); @(negedge clk); load_a = 1'b1; load_w = 1'b1;
        @(posedge clk); @(negedge clk); load_a = 1'b0; load_w = 1'b0;
        @(posedge clk); @(negedge clk); load_a_sign = 1'b1; load_w_sign = 1'b1;
        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk); load_a_sign = 1'b0; load_w_sign = 1'b0;

        // ---- SAIF window: WARMUP + T productive stochastic-MAC cycles ----
        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        rng_en = 1'b1;
        for (int c = 0; c < WARMUP + T; c++) begin
            if (c == WARMUP)          monitor_x = 1'b1;
            if (c == WARMUP + SETTLE) $toggle_start;
            mac_en = (c >= WARMUP);
            @(posedge clk); @(negedge clk);
        end
        mac_en = 1'b0;
        rng_en = 1'b0;
        @(negedge clk);
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain (outside SAIF window) + dump trace for cosim check ----
        acc_in_west = '0;
        @(negedge clk);
        shift_in = 1'b1;
        for (int s = 0; s < N; s++) begin
            @(posedge clk);
            for (int h = 0; h < N; h++)
                drain[h][N-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(negedge clk);
        end
        shift_in = 1'b0;

        trace_file = $fopen("array_rtl.txt", "w");
        assert (trace_file != 0) else $fatal(1, "cannot open array_rtl.txt");
        $fwrite(trace_file, "CFG %0d %0d %0d %0d %0d %0d %0d\n", K, M, N, N, WIDTH, OWIDTH, T);
        $fwrite(trace_file, "AMAG");
        for (int i = 0; i < N*K; i++) $fwrite(trace_file, " %0d", a_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nASIGN");
        for (int i = 0; i < N*K; i++) $fwrite(trace_file, " %0d", a_signs_in[i]);
        $fwrite(trace_file, "\nWMAG");
        for (int i = 0; i < N*K; i++) $fwrite(trace_file, " %0d", w_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nWSIGN");
        for (int i = 0; i < N*K; i++) $fwrite(trace_file, " %0d", w_signs_in[i]);
        $fwrite(trace_file, "\nDRAIN");
        for (int h = 0; h < N; h++)
            for (int v = 0; v < N; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display("PASS: InnerPE PE-level power SAIF captured; drain dumped (K=%0d M=%0d N=%0dx%0d T=%0d) -> cosim_array.py",
                 K, M, N, N, T);
        $finish;
    end
endmodule
