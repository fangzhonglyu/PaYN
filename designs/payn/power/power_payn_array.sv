`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power + output-checking bench for the integrated SC array (payn_array).
//
// Captures dut.saif over the T-cycle stochastic-MAC window, then drains the
// accumulator matrix and dumps operands + drain to array_rtl.txt. The bit-exact
// output check is post-hoc: designs/payn/cosim/cosim_array.py recomputes the
// drain with sc_kernel.py and asserts a bit-for-bit match (run via
// designs/payn/cosim/run_power_array.sh). All inputs are launched at the NEGEDGE
// (full half-cycle setup, insertion-independent) so the gate DUT and reference
// sample the same value; timing checks stay ON. Operands are held static in the
// window (only the Sobol RNG toggles).
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
// window, so the startup transient (resetless bit-pipes clearing their reset-X on
// internal nets) is not captured; the drain is still output-X-checked over the
// whole productive phase. 8 clears it for the 9x9 shape with TC margin to spare;
// scale up for larger arrays.
`ifndef SC_SETTLE
`define SC_SETTLE 8
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
    localparam int WARMUP = `SC_WARMUP;
    localparam int SETTLE = `SC_SETTLE;
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

    ClkUtils #(.TIMEOUT(WARMUP + T + N_W + 2048)) clk_utils (
        .clk, .reset, .timeout
    );

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] SC drain rail entered X during SAIF: %h", acc_out_east);

    `PAYN_ARRAY_DUT #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH)
`ifdef PAYN_BLOCK_FINALIZE
        , .BLOCK_T(T)
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

    initial begin
        seed_state = `SC_SEED;
        void'($urandom(seed_state));
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            w_signs_in[i] = $urandom & 1;
        end

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        // latch operands (control launched at the NEGEDGE: full half-cycle setup,
        // stable across the posedge -> posedge+insertion capture window, so it
        // clears the clock-tree insertion by construction -- no launch tuning)
        @(posedge clk); @(negedge clk); load_a = 1'b1; load_w = 1'b1;
        @(posedge clk); @(negedge clk); load_a = 1'b0; load_w = 1'b0;
        @(posedge clk); @(negedge clk); load_a_sign = 1'b1; load_w_sign = 1'b1;
        @(posedge clk); @(negedge clk);
        @(posedge clk); @(negedge clk); load_a_sign = 1'b0; load_w_sign = 1'b0;

        // ---- SAIF window: WARMUP + T productive stochastic-MAC cycles ----
        // monitor_x guards the drain output over the whole productive phase; the
        // SAIF window opens SETTLE cycles in, so the startup transient (resetless
        // bit-pipes clearing their reset-X on internal nets) is not captured --
        // steady-state power over the remaining productive cycles.
        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        rng_en = 1'b1;
        for (int c = 0; c < WARMUP + T; c++) begin
            if (c == WARMUP)          monitor_x = 1'b1;
            if (c == WARMUP + SETTLE) $toggle_start;
            mac_en = (c >= WARMUP);
            @(posedge clk);
`ifdef PAYN_BLOCK_FINALIZE
            if (c == WARMUP + T - 1) begin
                // Launch the correction immediately after the final MAC edge.
                // This preserves the last MAC capture and gives the distributed
                // finalize control plus upper-segment subtract a full cycle.
                // Launch after the routed clock insertion/hold window.  A
                // real controller flop on the same tree changes after its
                // local clock edge and clock-to-Q delay, not at the source
                // clock edge itself.
                #300ps;
                mac_en = 1'b0;
                rng_en = 1'b0;
                block_finalize = 1'b1;
            end
`endif
            @(negedge clk);
        end
        mac_en = 1'b0;
        rng_en = 1'b0;
`ifdef PAYN_BLOCK_FINALIZE
        // The existing post-MAC idle cycle captures the block correction, so
        // the SAIF includes its amortized cost without extending the window.
        block_finalize = 1'b1;
`endif
        @(negedge clk);
`ifdef PAYN_BLOCK_FINALIZE
        block_finalize = 1'b0;
`endif
        // Let the reporter observe the final control/clock events before
        // closing the window.  Without this separation, VCS can omit the
        // coincident final clock transition from the SAIF toggle count.
        #1ps;
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain (outside SAIF window) + dump trace for cosim check ----
        acc_in_west = '0;
        @(negedge clk);
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            @(posedge clk);
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(negedge clk);
        end
        shift_in = 1'b0;

        trace_file = $fopen("array_rtl.txt", "w");
        assert (trace_file != 0) else $fatal(1, "cannot open array_rtl.txt");
        $fwrite(trace_file, "CFG %0d %0d %0d %0d %0d %0d %0d\n", K, M, N_H, N_W, WIDTH, OWIDTH, T);
        $fwrite(trace_file, "AMAG");
        for (int i = 0; i < N_H*K; i++) $fwrite(trace_file, " %0d", a_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nASIGN");
        for (int i = 0; i < N_H*K; i++) $fwrite(trace_file, " %0d", a_signs_in[i]);
        $fwrite(trace_file, "\nWMAG");
        for (int i = 0; i < N_W*K; i++) $fwrite(trace_file, " %0d", w_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nWSIGN");
        for (int i = 0; i < N_W*K; i++) $fwrite(trace_file, " %0d", w_signs_in[i]);
        $fwrite(trace_file, "\nDRAIN");
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display("PASS: SC power SAIF captured; drain dumped (K=%0d M=%0d N=%0dx%0d T=%0d) -> cosim_array.py",
                 K, M, N_H, N_W, T);
        $finish;
    end
endmodule
