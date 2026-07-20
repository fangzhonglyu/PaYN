`include "common/clk_util.sv"
`include "common/defines.sv"
`ifndef GL_SIM
`include "baselines/binary_parallel/array_8_asym_corr_v2.sv"
`endif

`timescale 1ns/1ps

module Top;
    localparam int STIM_CYCLES = 4096;
    localparam int READOUT_PERIOD = 64;
    localparam int HEIGHT = 8;
    localparam int WIDTH = 8;
    localparam int IWIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int WSUM_WIDTH = 12;
    localparam int FLUSH_CYCLES = HEIGHT + WIDTH + 2;

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(STIM_CYCLES + 2048)) clk_utils (
        .clk(clk), .reset(reset), .timeout(timeout)
    );
    wire rst_n = ~reset;
    logic [HEIGHT-1:0] en_i, clr_i;
    logic [WIDTH-1:0] en_w, clr_w, en_o, clr_o;
    logic sum_en, corr_en;
    logic [HEIGHT*IWIDTH-1:0] ifm_flat;
    logic [WIDTH*IWIDTH-1:0] wght_flat;
    logic [IWIDTH-1:0] ifm_zp;
    logic [WIDTH*IWIDTH-1:0] wght_zp_flat;
    logic [WIDTH*WSUM_WIDTH-1:0] centered_wsum_flat;
    logic [WIDTH*OWIDTH-1:0] ofm_flat;
    bit monitor_arch_x = 1'b0;

    always @(ofm_flat) begin
        if (monitor_arch_x && $isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] asym BP v2 output entered X during SAIF: %h", ofm_flat);
    end

`ifdef GL_SIM
    array_8_asym_corr_v2 dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o), .sum_en(sum_en), .corr_en(corr_en),
        .ifm(ifm_flat), .wght(wght_flat), .ifm_zp(ifm_zp),
        .wght_zp(wght_zp_flat), .centered_wsum(centered_wsum_flat), .ofm(ofm_flat)
    );
    initial begin
`ifdef SDF_FILE
        $sdf_annotate(`SDF_FILE, dut);
`endif
    end
`else
    logic signed [IWIDTH-1:0] ifm_unp [HEIGHT-1:0];
    logic signed [IWIDTH-1:0] wght_unp [WIDTH-1:0];
    logic signed [IWIDTH-1:0] wght_zp_unp [WIDTH-1:0];
    logic signed [WSUM_WIDTH-1:0] centered_wsum_unp [WIDTH-1:0];
    logic signed [OWIDTH-1:0] ofm_unp [WIDTH-1:0];
    genvar gh, gw;
    generate
        for (gh = 0; gh < HEIGHT; gh++)
            assign ifm_unp[gh] = ifm_flat[gh*IWIDTH +: IWIDTH];
        for (gw = 0; gw < WIDTH; gw++) begin
            assign wght_unp[gw] = wght_flat[gw*IWIDTH +: IWIDTH];
            assign wght_zp_unp[gw] = wght_zp_flat[gw*IWIDTH +: IWIDTH];
            assign centered_wsum_unp[gw] = centered_wsum_flat[gw*WSUM_WIDTH +: WSUM_WIDTH];
            assign ofm_flat[gw*OWIDTH +: OWIDTH] = ofm_unp[gw];
        end
    endgenerate
    array_8_asym_corr_v2 dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o), .sum_en(sum_en), .corr_en(corr_en),
        .ifm(ifm_unp), .wght(wght_unp), .ifm_zp(ifm_zp),
        .wght_zp(wght_zp_unp), .centered_wsum(centered_wsum_unp), .ofm(ofm_unp)
    );
`endif

    initial begin
        en_i = '0; clr_i = '0; en_w = '0; clr_w = '0;
        en_o = '0; clr_o = '0; sum_en = 0; corr_en = 0;
        ifm_flat = '0; wght_flat = '0; ifm_zp = -8'sd5;
        for (int j = 0; j < WIDTH; j++) begin
            wght_zp_flat[j*IWIDTH +: IWIDTH] = j - 4;
            centered_wsum_flat[j*WSUM_WIDTH +: WSUM_WIDTH] = j*97 - 300;
        end
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif
        clk_utils.set_clock(`ASTRAEA_CLK_PERIOD_NS);
        clk_utils.do_reset();
        en_w = '1;
        for (int t = 0; t < HEIGHT; t++) begin
            @(negedge clk); wght_flat = {$urandom, $urandom};
        end
        @(negedge clk); en_w = '0;
        en_i = '1; clr_i = '1;
        en_o = '1; clr_o = '1;
        sum_en = 1;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin
            @(negedge clk); ifm_flat = {$urandom, $urandom};
        end
        clr_i = '0;
        clr_o = '0;
        corr_en = 1;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin
            @(negedge clk); ifm_flat = {$urandom, $urandom};
        end
        @(posedge clk);
        @(negedge clk);
        if ($isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] asymmetric BP output is unknown before SAIF: %h", ofm_flat);
        monitor_arch_x = 1'b1;
        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        $toggle_start;
        for (int t = 0; t < STIM_CYCLES; t++) begin
            @(negedge clk);
            if ($isunknown(ofm_flat))
                $fatal(1, "[X-FAIL] asymmetric BP output unknown in SAIF cycle %0d: %h", t, ofm_flat);
            ifm_flat = {$urandom, $urandom};
            clr_o = ((t % READOUT_PERIOD) == (READOUT_PERIOD-1)) ? '1 : '0;
        end
        @(negedge clk);
        if ($isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] asymmetric BP output unknown at end of SAIF: %h", ofm_flat);
        $toggle_stop;
        monitor_arch_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");
        $display("[INFO] wavefront asymmetric binary SAIF: %0d cycles at %0f ns",
                 STIM_CYCLES, `ASTRAEA_CLK_PERIOD_NS);
        $finish;
    end
endmodule
