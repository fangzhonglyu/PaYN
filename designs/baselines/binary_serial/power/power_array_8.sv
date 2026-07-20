// Power + output-checking bench for the bit-serial (BS) systolic array.
//
// Captures dut.saif over a steady-state streaming-MAC window AND checks the
// drained ofm against a faithful flat reference every scored cycle (so the SAIF
// is only trusted when the array is functionally correct and X-free). Inputs are
// launched at the NEGEDGE (full half-cycle setup, insertion-independent) for gate-level
// timing-checks-on runs; the reference is posedge-clocked and outputs are
// sampled on the negedge.

`include "common/clk_util.sv"
`include "common/defines.sv"
`ifndef GL_SIM
`include "baselines/binary_serial/array_8.sv"
`endif

`timescale 1ns/1ps

`ifndef STIM_CYCLES_N
`define STIM_CYCLES_N 4096
`endif

module Top;
    localparam int IWIDTH         = 8;
    localparam int IDEPTH         = 3;
    localparam int OWIDTH         = 24;
    localparam int HEIGHT         = 8;
    localparam int WIDTH          = 8;
    localparam int STIM_CYCLES    = `STIM_CYCLES_N;
    localparam int READOUT_PERIOD = 64 * IWIDTH;
    localparam int FLUSH_CYCLES   = (HEIGHT + WIDTH + 2) * IWIDTH;

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(STIM_CYCLES + 2048)) clk_utils (
        .clk(clk), .reset(reset), .timeout(timeout)
    );
    wire rst_n = ~reset;

    logic [HEIGHT-1:0]        en_i, clr_i, mac_done;
    logic [WIDTH-1:0]         en_w, clr_w, en_o, clr_o;
    logic [HEIGHT*IWIDTH-1:0] ifm_flat;
    logic [WIDTH*IWIDTH-1:0]  wght_flat;
    logic [WIDTH*OWIDTH-1:0]  ofm_flat;

    bit monitor_x = 1'b0;
    always @(ofm_flat)
        if (monitor_x && $isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] BS output entered X during SAIF: %h", ofm_flat);

`ifdef GL_SIM
    array_8 dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .mac_done(mac_done),
        .en_w(en_w), .clr_w(clr_w), .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm_flat), .wght(wght_flat), .ofm(ofm_flat)
    );
    initial begin
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
    end
`else
    logic signed [IWIDTH-1:0] ifm_unp  [HEIGHT-1:0];
    logic signed [IWIDTH-1:0] wght_unp [WIDTH-1:0];
    logic signed [OWIDTH-1:0] ofm_unp  [WIDTH-1:0];
    genvar gh, gw;
    generate
        for (gh = 0; gh < HEIGHT; gh++) assign ifm_unp[gh]  = ifm_flat[gh*IWIDTH +: IWIDTH];
        for (gw = 0; gw < WIDTH;  gw++) assign wght_unp[gw] = wght_flat[gw*IWIDTH +: IWIDTH];
        for (gw = 0; gw < WIDTH;  gw++) assign ofm_flat[gw*OWIDTH +: OWIDTH] = ofm_unp[gw];
    endgenerate
    array_8 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(IWIDTH), .IDEPTH(IDEPTH), .OWIDTH(OWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .mac_done(mac_done),
        .en_w(en_w), .clr_w(clr_w), .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm_unp), .wght(wght_unp), .ofm(ofm_unp)
    );
`endif

    // -------- faithful flat reference (see tb/test_array_8.sv) --------
    logic ref_en_i  [HEIGHT-1:0][WIDTH-1:0];
    logic ref_clr_i [HEIGHT-1:0][WIDTH-1:0];
    logic ref_macd  [HEIGHT-1:0][WIDTH-1:0];
    logic ref_en_w  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_w [WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_o  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_o [WIDTH-1:0][HEIGHT-1:0];
    logic signed [IWIDTH-1:0] ref_ifm  [HEIGHT-1:0][WIDTH-1:0];
    logic signed [IWIDTH-1:0] ref_wght [WIDTH-1:0][HEIGHT-1:0];
    logic        [IDEPTH-1:0] ref_idx  [HEIGHT-1:0][WIDTH-1:0];
    logic signed [OWIDTH-1:0] ref_ofm  [WIDTH-1:0][HEIGHT-1:0];

    logic signed [IWIDTH-1:0] ifm_in  [HEIGHT-1:0];
    logic signed [IWIDTH-1:0] wght_in [WIDTH-1:0];
    always_comb for (int h = 0; h < HEIGHT; h++) ifm_in[h]  = ifm_flat[h*IWIDTH +: IWIDTH];
    always_comb for (int w = 0; w < WIDTH;  w++) wght_in[w] = wght_flat[w*IWIDTH +: IWIDTH];

    bit check_enable = 1'b0;
    int checked_cycles = 0;

    always @(posedge clk) begin
        for (int h = 0; h < HEIGHT; h++)
            for (int w = 0; w < WIDTH; w++) begin
                ref_en_i[h][w]  <= (w == 0) ? en_i[h]     : ref_en_i[h][w-1];
                ref_clr_i[h][w] <= (w == 0) ? clr_i[h]    : ref_clr_i[h][w-1];
                ref_macd[h][w]  <= (w == 0) ? mac_done[h] : ref_macd[h][w-1];
            end
        for (int w = 0; w < WIDTH; w++)
            for (int h = 0; h < HEIGHT; h++) begin
                ref_en_w[w][h]  <= (h == 0) ? en_w[w] : ref_en_w[w][h-1];
                ref_clr_w[w][h] <= (h == 0) ? clr_w[w] : ref_clr_w[w][h-1];
                ref_en_o[w][h]  <= (h == HEIGHT-1) ? en_o[w] : ref_en_o[w][h+1];
                ref_clr_o[w][h] <= (h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1];
            end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin ref_ifm[h][w] <= '0; ref_idx[h][w] <= '0; end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin ref_wght[w][h] <= '0; ref_ofm[w][h] <= '0; end
        end else begin
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin
                    logic cur_clr_i, cur_en_i;
                    logic signed [IWIDTH-1:0] in_ifm;
                    cur_clr_i = (w == 0) ? clr_i[h] : ref_clr_i[h][w-1];
                    cur_en_i  = (w == 0) ? en_i[h]  : ref_en_i[h][w-1];
                    in_ifm    = (w == 0) ? ifm_in[h] : ref_ifm[h][w-1];
                    if (cur_clr_i)      ref_ifm[h][w] <= '0;
                    else if (cur_en_i)  ref_ifm[h][w] <= in_ifm;
                    ref_idx[h][w] <= (w == 0) ? (ref_idx[h][w] + 1'b1) : ref_idx[h][w-1];
                end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    logic cur_clr_w, cur_en_w, cur_clr_o, cur_en_o, cur_macd, sel_bit;
                    logic signed [IWIDTH-1:0] in_wght;
                    logic signed [OWIDTH-1:0] sum_i, prod_ext;
                    cur_clr_w = (h == 0) ? clr_w[w] : ref_clr_w[w][h-1];
                    cur_en_w  = (h == 0) ? en_w[w]  : ref_en_w[w][h-1];
                    in_wght   = (h == 0) ? wght_in[w] : ref_wght[w][h-1];
                    if (cur_clr_w)      ref_wght[w][h] <= '0;
                    else if (cur_en_w)  ref_wght[w][h] <= in_wght;

                    cur_clr_o = (h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1];
                    cur_en_o  = (h == HEIGHT-1) ? en_o[w]  : ref_en_o[w][h+1];
                    cur_macd  = ref_macd[h][w];
                    sum_i     = (h == HEIGHT-1) ? '0 : ref_ofm[w][h+1];
                    sel_bit   = ref_ifm[h][w][ref_idx[h][w]];
                    prod_ext  = sel_bit ? OWIDTH'(ref_wght[w][h]) : '0;
                    if (cur_clr_o)      ref_ofm[w][h] <= '0;
                    else if (cur_en_o)  ref_ofm[w][h] <= (cur_macd ? sum_i : prod_ext)
                                                       + (cur_macd ? ref_ofm[w][h] : (ref_ofm[w][h] << 1));
                end
        end
    end

    always @(negedge clk) begin
        if (check_enable) begin
            for (int w = 0; w < WIDTH; w++)
                if (ofm_flat[w*OWIDTH +: OWIDTH] !== ref_ofm[w][0])
                    $fatal(1, "[FUNC-FAIL] SAIF cycle=%0d column=%0d got=%h expected=%h",
                           checked_cycles, w, ofm_flat[w*OWIDTH +: OWIDTH], ref_ofm[w][0]);
            checked_cycles++;
        end
    end

    // Launch inputs at the NEGEDGE: a full half-cycle of setup so each input is
    // stable across the posedge -> posedge+insertion capture window, so the
    // zero-delay golden and the tree-delayed DUT sample the same value,
    // insertion-independent (see header).
    task automatic step_phase(input int t, input bit refresh_ifm);
        int phase;
        phase = t % IWIDTH;
        @(posedge clk); @(negedge clk);
        if (phase == 0) begin
            if (refresh_ifm) ifm_flat = {$urandom, $urandom};
            en_i = '1;
        end else begin
            en_i = '0;
        end
        mac_done = (phase == (IWIDTH-1)) ? '1 : '0;
    endtask

    initial begin
        en_i = '0; clr_i = '0; mac_done = '0;
        en_w = '0; clr_w = '0; en_o = '0; clr_o = '0;
        ifm_flat = '0; wght_flat = '0;

        clk_utils.set_clock(`ifdef ASTRAEA_CLK_PERIOD_NS `ASTRAEA_CLK_PERIOD_NS `else 2.5 `endif);
        clk_utils.do_reset();

        // Phase 1: weight load (not in SAIF window).
        @(posedge clk); @(negedge clk); en_w = '1;
        for (int t = 0; t < HEIGHT; t++) begin @(posedge clk); @(negedge clk); wght_flat = {$urandom, $urandom}; end
        @(posedge clk); @(negedge clk); en_w = '0;

        // Flush resetless control/index state (clear pass, then clean pass).
        en_o = '1; clr_i = '1; clr_o = '1;
        for (int t = 0; t < FLUSH_CYCLES; t++) step_phase(t, 1'b1);
        clr_i = '0; clr_o = '0;
        for (int t = 0; t < FLUSH_CYCLES; t++) step_phase(t, 1'b1);

        @(negedge clk); #0.01;
        if ($isunknown(ofm_flat)) $fatal(1, "[X-FAIL] BS output unknown before SAIF");
        for (int w = 0; w < WIDTH; w++)
            if ($isunknown(ref_ofm[w][0])) $fatal(1, "[FUNC-FAIL] reference unknown before SAIF");
        monitor_x = 1'b1;
        check_enable = 1'b1;

        // Phase 2: scored streaming-MAC SAIF window.
        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        $toggle_start;
        for (int t = 0; t < STIM_CYCLES; t++) begin
            step_phase(t, 1'b1);
            clr_o = ((t % READOUT_PERIOD) == (READOUT_PERIOD-1)) ? '1 : '0;
        end
        @(negedge clk); #0.01;   // count this last cycle before clearing
                                 // check_enable (deterministic ordering vs the
                                 // negedge scoring block; xprop exposed the race)
        $toggle_stop;
        check_enable = 1'b0;
        monitor_x = 1'b0;

        if (checked_cycles < STIM_CYCLES)
            $fatal(1, "[FUNC-FAIL] checked only %0d of %0d SAIF cycles", checked_cycles, STIM_CYCLES);
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");
        $display("PASS: BS power SAIF captured + output-checked for %0d cycles", checked_cycles);
        $finish;
    end
endmodule
