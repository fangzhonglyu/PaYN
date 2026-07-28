`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power + output-checking bench for the asymmetric binary output-stationary array.
//
// Unlike the plain BOS bench, the drain is taken INSIDE the SAIF window.  It has
// to be: the correction hardware only runs on drain cycles, so a drain-excluded
// window would measure the row-sum accumulators and nothing else.  The workload
// is therefore a repeating block of BOS_DRAIN_PERIOD MAC cycles followed by a
// full N_W-cycle corrected drain, and the PASS line reports the split so energy
// can be charged per useful MAC.
//
// Every drained value is checked against a reference that models the complete
// asymmetric identity with faithful pipeline timing, so the correction is
// verified on the routed netlist, not just in RTL.  All stimulus is launched at
// the NEGEDGE so the zero-delay reference and the routed gate DUT sample the
// same value regardless of clock insertion.

`ifndef GL_SIM
`include "baselines/binary_os/binary_os_asym.sv"
`endif

`ifndef BOS_GL_DUT
`define BOS_GL_DUT binary_os_array_asym
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
`ifndef BOS_DEPTH_W
`define BOS_DEPTH_W 10
`endif
`ifndef STIM_CYCLES_N
`define STIM_CYCLES_N 4096
`endif
// MAC cycles between drains.  Must be > 0 here: the correction only toggles on
// drain cycles, so there is no meaningful drain-free measurement.
`ifndef BOS_DRAIN_PERIOD
`define BOS_DRAIN_PERIOD 64
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
    localparam int DEPTH_W      = `BOS_DEPTH_W;
    localparam int SUMA_WIDTH   = IWIDTH + DEPTH_W;
    localparam int WSUM_WIDTH   = IWIDTH + 1 + DEPTH_W;
    localparam int STIM_CYCLES  = `STIM_CYCLES_N;
    localparam int DRAIN_PERIOD = `BOS_DRAIN_PERIOD;
    localparam int FLUSH_CYCLES = N_H + N_W + 2;   // BP/BS convention
    localparam real PERIOD      = `ASTRAEA_CLK_PERIOD_NS;

    logic clk, reset, timeout;
    logic mac_en = 1'b0, shift_in = 1'b0;
    logic sum_en = 1'b0, sum_load = 1'b0, corr_en = 1'b0;

    logic [N_H*IWIDTH-1:0] a_in = '0;
    logic [N_W*IWIDTH-1:0] w_in = '0;
    logic [N_H*OWIDTH-1:0] acc_in_west = '0;
    logic [N_H*OWIDTH-1:0] ofm;

    logic signed [IWIDTH-1:0] ifm_zp = '0;
    logic signed [IWIDTH-1:0] wght_zp = '0;
    logic signed [WSUM_WIDTH-1:0] centered_wsum = '0;

    bit monitor_x = 1'b0;
    bit check_enable = 1'b0;
    int checked_cycles = 0;
    int mac_cycles = 0;
    int drain_cycles = 0;
    int seed_state;

    ClkUtils #(.TIMEOUT(STIM_CYCLES + 2048)) clk_utils (.clk, .reset, .timeout);

    always @(ofm)
        if (monitor_x && $isunknown(ofm))
            $fatal(1, "[X-FAIL] OS asym output entered X during SAIF: %h", ofm);

`ifdef GL_SIM
    `BOS_GL_DUT dut (
        .clk(clk), .reset(reset), .mac_en(mac_en), .shift_in(shift_in),
        .sum_en(sum_en), .sum_load(sum_load), .corr_en(corr_en),
        .a_in(a_in), .w_in(w_in), .acc_in_west(acc_in_west),
        .ifm_zp(ifm_zp), .wght_zp(wght_zp), .centered_wsum(centered_wsum),
        .ofm(ofm)
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
    binary_os_array_asym #(
        .IWIDTH(IWIDTH), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .DEPTH_W(DEPTH_W)
    ) dut (.*);
`endif

    // -------- reference: mesh hops, stationary accumulator, full correction ----
    logic signed [IWIDTH-1:0] ref_a [N_H][N_W];
    logic signed [IWIDTH-1:0] ref_w [N_H][N_W];
    logic signed [OWIDTH-1:0] ref_acc [N_H][N_W];
    logic signed [SUMA_WIDTH-1:0] ref_sum_a [N_H];

    always @(posedge clk) begin
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) begin
                ref_a[h][v] <= (v == 0) ? $signed(a_in[h*IWIDTH +: IWIDTH])
                                        : ref_a[h][v-1];
                ref_w[h][v] <= (h == 0) ? $signed(w_in[v*IWIDTH +: IWIDTH])
                                        : ref_w[h-1][v];
            end

        for (int h = 0; h < N_H; h++) begin
            if (sum_load)
                ref_sum_a[h] <= SUMA_WIDTH'($signed(a_in[h*IWIDTH +: IWIDTH]));
            else if (sum_en)
                ref_sum_a[h] <= ref_sum_a[h]
                              + SUMA_WIDTH'($signed(a_in[h*IWIDTH +: IWIDTH]));
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

    function automatic logic signed [OWIDTH-1:0] ref_corrected(input int h);
        logic signed [IWIDTH+SUMA_WIDTH-1:0] wc;
        logic signed [IWIDTH+WSUM_WIDTH-1:0] xc;
        begin
            if (!corr_en) return -OWIDTH'(0);
            wc = wght_zp * ref_sum_a[h];
            xc = ifm_zp * centered_wsum;
            ref_corrected = ref_acc[h][N_W-1] - OWIDTH'(wc) - OWIDTH'(xc);
        end
    endfunction

    always @(negedge clk) begin
        if (check_enable && corr_en) begin
            for (int h = 0; h < N_H; h++)
                if ($signed(ofm[h*OWIDTH +: OWIDTH]) !== ref_corrected(h))
                    $fatal(1, "[FUNC-FAIL] SAIF cycle=%0d row=%0d got=%0d expected=%0d",
                           checked_cycles, h,
                           $signed(ofm[h*OWIDTH +: OWIDTH]), ref_corrected(h));
            checked_cycles++;
        end
    end

    task automatic randomize_operands();
        for (int h = 0; h < N_H; h++) a_in[h*IWIDTH +: IWIDTH] = IWIDTH'($urandom);
        for (int v = 0; v < N_W; v++) w_in[v*IWIDTH +: IWIDTH] = IWIDTH'($urandom);
    endtask

    int drain_step;

    initial begin
        assert (DRAIN_PERIOD > 0)
            else $fatal(1, "BOS_DRAIN_PERIOD must be positive: the correction only runs on drain cycles");
        assert (STIM_CYCLES > 0)
            else $fatal(1, "STIM_CYCLES_N must be positive");

        seed_state = `BOS_SEED;
        void'($urandom(seed_state));

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        ifm_zp = -8'sd5;

        // Flush resetless state: valid-input pass, then clean pass, following
        // designs/baselines/binary_{parallel,serial}/power/power_array_8.sv.
        // sum_load is held high so every row-sum register is overwritten from
        // its input each cycle, and shift_in walks zeros in from acc_in_west to
        // flush the accumulator chain.  All state is then a function of driven
        // inputs, which is the property BP's resetless pipeline has by
        // construction.
        repeat (2) @(negedge clk);
        sum_en = 1'b1; sum_load = 1'b1; shift_in = 1'b1;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin
            randomize_operands();
            @(posedge clk);
            @(negedge clk);
        end
        sum_en = 1'b0; sum_load = 1'b0; shift_in = 1'b0;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin
            randomize_operands();
            @(posedge clk);
            @(negedge clk);
        end
        #0.01;
        if ($isunknown(ofm)) $fatal(1, "[X-FAIL] OS asym output unknown before SAIF");
        monitor_x = 1'b1;
        check_enable = 1'b1;

        // ---- SAIF window: MAC blocks separated by corrected drains ----------
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
            drain_step = cycle % (DRAIN_PERIOD + N_W);
            if (drain_step < DRAIN_PERIOD) begin
                mac_en = 1'b1; shift_in = 1'b0; sum_en = 1'b1; corr_en = 1'b0;
                // First MAC cycle of a block loads rather than accumulates, so
                // each block's row sum starts clean without a clear signal.
                sum_load = (drain_step == 0);
            end else begin
                // Drain step s emits column N_W-1-s on every rail.  Fresh zero
                // points and centred weight sums each step so the correction
                // datapath toggles the way a real column sweep would.
                mac_en = 1'b0; shift_in = 1'b1; sum_en = 1'b0; corr_en = 1'b1;
                wght_zp = IWIDTH'($urandom);
                centered_wsum = WSUM_WIDTH'($urandom);
                sum_load = 1'b0;
            end
            randomize_operands();
            @(posedge clk);
            @(negedge clk);
            // Let the negedge checker read this cycle's zero point and centred
            // weight sum before the next iteration overwrites them.  Unlike the
            // plain BOS bench, the scored value here is combinational in those
            // two inputs, so a zero-delay handoff races: the reference would
            // read the next column's constants while the SDF-delayed DUT output
            // still reflects the current column's.
            #0.01;
            if (drain_step < DRAIN_PERIOD) mac_cycles++; else drain_cycles++;
        end

        mac_en = 1'b0; shift_in = 1'b0; sum_en = 1'b0; corr_en = 1'b0;
        $toggle_stop;
        check_enable = 1'b0;
        monitor_x = 1'b0;

        if (checked_cycles < drain_cycles - 1)
            $fatal(1, "[FUNC-FAIL] checked only %0d of %0d corrected drain cycles",
                   checked_cycles, drain_cycles);
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        $display("PASS: binary OS asym power SAIF captured + output-checked; %0d cycles (%0d MAC, %0d drain), %0d corrected outputs checked, %0d useful MAC",
                 mac_cycles + drain_cycles, mac_cycles, drain_cycles,
                 checked_cycles * N_H, mac_cycles * N_H * N_W);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
