`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power + output-checking bench for the binary output-stationary array.
//
// Captures dut.saif over a streaming-MAC window AND checks the east drain rail
// against a reference model with faithful pipeline timing every scored cycle.
// All stimulus is launched at the NEGEDGE (full half-cycle setup, stable across
// the posedge -> posedge+insertion capture window) so the zero-delay reference
// and the routed gate DUT sample the same value regardless of clock insertion:
// no launch tuning, timing checks stay ON.
//
// Methodology matches designs/payn/power/power_payn_array.sv so the numbers are
// directly comparable: fresh operands every cycle, and the accumulator drain is
// taken AFTER $toggle_stop so the measured window is pure MAC work.  Set
// BOS_DRAIN_PERIOD=<k> to instead fold a full N_W-cycle drain into the window
// after every k MAC cycles; the PASS line then reports the MAC/drain split so
// energy can be charged per useful MAC.
//
// The final drain is compared against the reference matrix in full, so all
// N_H*N_W accumulators are checked, not just the east column.

`ifndef GL_SIM
`include "baselines/binary_os/binary_os_array.sv"
`endif

`ifndef BOS_GL_DUT
`define BOS_GL_DUT binary_os_array
`endif

`ifndef BOS_IWIDTH
`define BOS_IWIDTH 8
`endif
`ifndef BOS_NH
`define BOS_NH 8
`endif
`ifndef BOS_NW
`define BOS_NW 8
`endif
`ifndef BOS_OWIDTH
`define BOS_OWIDTH 24
`endif
// Cycles inside the SAIF window (MAC + any in-window drain).
`ifndef STIM_CYCLES_N
`define STIM_CYCLES_N 4096
`endif
// 0 = no in-window drain (PaYN methodology).  k > 0 = drain every k MAC cycles.
`ifndef BOS_DRAIN_PERIOD
`define BOS_DRAIN_PERIOD 0
`endif
`ifndef BOS_SEED
`define BOS_SEED 32'hDEAD_BEEF
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int IWIDTH       = `BOS_IWIDTH;
    localparam int N_H          = `BOS_NH;
    localparam int N_W          = `BOS_NW;
    localparam int OWIDTH       = `BOS_OWIDTH;
    localparam int STIM_CYCLES  = `STIM_CYCLES_N;
    localparam int DRAIN_PERIOD = `BOS_DRAIN_PERIOD;
    localparam real PERIOD      = `ASTRAEA_CLK_PERIOD_NS;

    logic clk, reset, timeout;
    logic mac_en = 1'b0, shift_in = 1'b0;

    logic [N_H*IWIDTH-1:0] a_in = '0;
    logic [N_W*IWIDTH-1:0] w_in = '0;
    logic [N_H*OWIDTH-1:0] acc_in_west = '0;
    logic [N_H*OWIDTH-1:0] acc_out_east;

    bit monitor_x = 1'b0;
    bit check_enable = 1'b0;
    int checked_cycles = 0;
    int mac_cycles = 0;
    int drain_cycles = 0;
    int seed_state;

    ClkUtils #(.TIMEOUT(STIM_CYCLES + 2048)) clk_utils (.clk, .reset, .timeout);

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] OS drain rail entered X during SAIF: %h", acc_out_east);

`ifdef GL_SIM
    `BOS_GL_DUT dut (
        .clk(clk), .reset(reset), .mac_en(mac_en), .shift_in(shift_in),
        .a_in(a_in), .w_in(w_in),
        .acc_in_west(acc_in_west), .acc_out_east(acc_out_east)
    );
    initial begin
`ifndef NO_SDF
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
`endif
    end
`else
    binary_os_array #(
        .IWIDTH(IWIDTH), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH)
    ) dut (.*);
`endif

    // -------- reference model: per-PE operand hops + stationary accumulator ----
    // Mirrors the mesh exactly: A hops west->east one PE per cycle, W hops
    // north->south one PE per cycle, and each PE multiplies only its own
    // registers.  No broadcast anywhere.
    logic signed [IWIDTH-1:0] ref_a [N_H][N_W];
    logic signed [IWIDTH-1:0] ref_w [N_H][N_W];
    logic signed [OWIDTH-1:0] ref_acc [N_H][N_W];

    always @(posedge clk) begin
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) begin
                ref_a[h][v] <= (v == 0) ? $signed(a_in[h*IWIDTH +: IWIDTH])
                                        : ref_a[h][v-1];
                ref_w[h][v] <= (h == 0) ? $signed(w_in[v*IWIDTH +: IWIDTH])
                                        : ref_w[h-1][v];
            end

        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) begin
                if (reset)
                    ref_acc[h][v] <= '0;
                else if (shift_in)
                    ref_acc[h][v] <= (v == 0)
                        ? $signed(acc_in_west[h*OWIDTH +: OWIDTH])
                        : ref_acc[h][v-1];
                else if (mac_en)
                    ref_acc[h][v] <=
                        ref_acc[h][v] + OWIDTH'(ref_a[h][v] * ref_w[h][v]);
            end
    end

    always @(negedge clk) begin
        if (check_enable) begin
            for (int h = 0; h < N_H; h++)
                if (acc_out_east[h*OWIDTH +: OWIDTH] !== ref_acc[h][N_W-1])
                    $fatal(1, "[FUNC-FAIL] SAIF cycle=%0d row=%0d got=%h expected=%h",
                           checked_cycles, h,
                           acc_out_east[h*OWIDTH +: OWIDTH], ref_acc[h][N_W-1]);
            checked_cycles++;
        end
    end

    task automatic randomize_operands();
        for (int h = 0; h < N_H; h++) a_in[h*IWIDTH +: IWIDTH] = IWIDTH'($urandom);
        for (int v = 0; v < N_W; v++) w_in[v*IWIDTH +: IWIDTH] = IWIDTH'($urandom);
    endtask

    logic signed [OWIDTH-1:0] want [N_H][N_W];
    logic signed [OWIDTH-1:0] got  [N_H][N_W];
    bit is_drain;
    int drain_errors = 0;

    initial begin
        assert (DRAIN_PERIOD >= 0)
            else $fatal(1, "BOS_DRAIN_PERIOD must be non-negative");
        assert (STIM_CYCLES > 0)
            else $fatal(1, "STIM_CYCLES_N must be positive");

        seed_state = `BOS_SEED;
        void'($urandom(seed_state));

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        // Let routed reset trees satisfy recovery, then flush the resetless
        // per-PE hop registers.  A needs N_W hops and W needs N_H hops to reach
        // the far corner, so neither the DUT nor the reference carries X into
        // the window.
        repeat (2) @(negedge clk);
        for (int t = 0; t < ((N_H > N_W) ? N_H : N_W) + 1; t++) begin
            randomize_operands();
            @(posedge clk);
            @(negedge clk);
        end
        #0.01;
        if ($isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] OS drain rail unknown before SAIF");
        monitor_x = 1'b1;
        check_enable = 1'b1;

        // ---- SAIF window ----------------------------------------------------
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        // RTL runs feed SYN_SAIF_FILE (workload-driven synthesis). Without the
        // "sv" argument VCS skips SystemVerilog-typed nets and the SAIF comes
        // out empty; it also needs -lca on the VCS command line.
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        $toggle_start;

        for (int cycle = 0; cycle < STIM_CYCLES; cycle++) begin
            is_drain = (DRAIN_PERIOD > 0) &&
                       ((cycle % (DRAIN_PERIOD + N_W)) >= DRAIN_PERIOD);
            mac_en   = !is_drain;
            shift_in =  is_drain;
            randomize_operands();
            @(posedge clk);
            @(negedge clk);
            if (is_drain) drain_cycles++; else mac_cycles++;
        end
        #0.01;

        mac_en = 1'b0;
        shift_in = 1'b0;
        $toggle_stop;
        check_enable = 1'b0;
        monitor_x = 1'b0;

        if (checked_cycles < STIM_CYCLES)
            $fatal(1, "[FUNC-FAIL] checked only %0d of %0d SAIF cycles",
                   checked_cycles, STIM_CYCLES);
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain outside SAIF; check the whole accumulator matrix ---------
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) want[h][v] = ref_acc[h][v];

        acc_in_west = '0;
        shift_in = 1'b1;
        for (int s = 0; s < N_W; s++) begin
            for (int h = 0; h < N_H; h++)
                got[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(posedge clk);
            @(negedge clk);
        end
        shift_in = 1'b0;

        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++)
                if (got[h][v] !== want[h][v]) begin
                    $display("[FUNC-FAIL] drain[%0d][%0d] got=%0d expected=%0d",
                             h, v, got[h][v], want[h][v]);
                    drain_errors++;
                end
        if (drain_errors != 0)
            $fatal(1, "[FUNC-FAIL] %0d drained accumulators mismatched", drain_errors);

        $display("PASS: binary OS power SAIF captured + output-checked; %0d cycles (%0d MAC, %0d drain), %0d useful MAC",
                 checked_cycles, mac_cycles, drain_cycles, mac_cycles * N_H * N_W);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
