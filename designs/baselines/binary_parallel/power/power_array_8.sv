// Power + output-checking bench for the binary-parallel (BP) systolic array.
//
// Captures dut.saif over the streaming-MAC window AND checks ofm against a flat
// reference (independent integer products, faithful pipeline timing) every scored
// cycle. All inputs are launched at the NEGEDGE (full half-cycle setup, stable
// across the posedge -> posedge+insertion capture window) so the zero-delay
// golden and the tree-delayed gate DUT sample the same value, independent of the
// clock insertion -- no launch tuning, timing checks stay ON. BP_INPUT_BITS
// selects the signed input regime (see run_bp_regimes.sh).

`include "common/clk_util.sv"
`include "common/defines.sv"
`ifndef GL_SIM
`include "baselines/binary_parallel/array_8.sv"
`endif

`timescale 1ns/1ps

`ifndef BP_IWIDTH
`define BP_IWIDTH 8
`endif
`ifndef BP_INPUT_BITS
`define BP_INPUT_BITS `BP_IWIDTH
`endif
// GL DUT module: array_8 by default; native narrow targets flatten to a
// differently-named top (array_8_int7/array_8_int6) -> override for GL power.
`ifndef BP_GL_DUT
`define BP_GL_DUT array_8
`endif

`ifndef STIM_CYCLES_N
`define STIM_CYCLES_N 4096
`endif

module Top;
    localparam int STIM_CYCLES    = `STIM_CYCLES_N;
    localparam int READOUT_PERIOD = 64;
    localparam int HEIGHT         = 8;
    localparam int WIDTH          = 8;
    localparam int IWIDTH         = `BP_IWIDTH;   // native datapath width (8/7/6)
    localparam int INPUT_BITS     = `BP_INPUT_BITS;
    localparam int OWIDTH         = 24;
    localparam int FLUSH_CYCLES   = HEIGHT + WIDTH + 2;

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(STIM_CYCLES + 2048)) clk_utils (
        .clk(clk), .reset(reset), .timeout(timeout)
    );
    wire rst_n = ~reset;

    logic [HEIGHT-1:0]        en_i, clr_i;
    logic [WIDTH-1:0]         en_w, clr_w, en_o, clr_o;
    logic [HEIGHT*IWIDTH-1:0] ifm_flat;
    logic [WIDTH*IWIDTH-1:0]  wght_flat;
    logic [WIDTH*OWIDTH-1:0]  ofm_flat;
    bit monitor_x = 1'b0;

    function automatic logic [HEIGHT*IWIDTH-1:0] random_ifm_vector();
        logic [HEIGHT*IWIDTH-1:0] raw;
        logic signed [INPUT_BITS-1:0] narrow;
        logic signed [IWIDTH-1:0] extended;
        begin
            raw = {$urandom, $urandom};
            for (int lane = 0; lane < HEIGHT; lane++) begin
                narrow = raw[lane*IWIDTH +: INPUT_BITS];
`ifdef BP_ALL_POSITIVE
                narrow[INPUT_BITS-1] = 1'b0;   // all-positive INT<INPUT_BITS>
`endif
                extended = narrow;
                random_ifm_vector[lane*IWIDTH +: IWIDTH] = extended;
            end
        end
    endfunction

    function automatic logic [WIDTH*IWIDTH-1:0] random_wght_vector();
        logic [WIDTH*IWIDTH-1:0] raw;
        logic signed [INPUT_BITS-1:0] narrow;
        logic signed [IWIDTH-1:0] extended;
        begin
            raw = {$urandom, $urandom};
            for (int lane = 0; lane < WIDTH; lane++) begin
                narrow = raw[lane*IWIDTH +: INPUT_BITS];
`ifdef BP_ALL_POSITIVE
                narrow[INPUT_BITS-1] = 1'b0;   // all-positive INT<INPUT_BITS>
`endif
                extended = narrow;
                random_wght_vector[lane*IWIDTH +: IWIDTH] = extended;
            end
        end
    endfunction

    always @(ofm_flat)
        if (monitor_x && $isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] BP output entered X during SAIF: %h", ofm_flat);

`ifdef GL_SIM
    `BP_GL_DUT dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o),
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
    array_8 #(.HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(IWIDTH), .OWIDTH(OWIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm_unp), .wght(wght_unp), .ofm(ofm_unp)
    );
`endif

    logic signed [IWIDTH-1:0] ifm_in  [HEIGHT-1:0];
    logic signed [IWIDTH-1:0] wght_in [WIDTH-1:0];
    always_comb for (int h = 0; h < HEIGHT; h++) ifm_in[h]  = ifm_flat[h*IWIDTH +: IWIDTH];
    always_comb for (int w = 0; w < WIDTH;  w++) wght_in[w] = wght_flat[w*IWIDTH +: IWIDTH];

    // -------- flat reference (see tb/test_array_8_power_workload.sv) --------
    logic ref_en_i  [HEIGHT-1:0][WIDTH-1:0];
    logic ref_clr_i [HEIGHT-1:0][WIDTH-1:0];
    logic ref_en_w  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_w [WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_o  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_o [WIDTH-1:0][HEIGHT-1:0];
    logic signed [IWIDTH-1:0] ref_ifm  [HEIGHT-1:0][WIDTH-1:0];
    logic signed [IWIDTH-1:0] ref_wght [WIDTH-1:0][HEIGHT-1:0];
    logic signed [OWIDTH-1:0] ref_ofm  [WIDTH-1:0][HEIGHT-1:0];
    bit check_enable = 1'b0;
    int checked_cycles = 0;

    function automatic logic signed [OWIDTH-1:0] product_ext(
        input logic signed [IWIDTH-1:0] a, input logic signed [IWIDTH-1:0] b);
        logic signed [2*IWIDTH-1:0] product;
        begin
            product = a * b;
            product_ext = {{(OWIDTH-2*IWIDTH){product[2*IWIDTH-1]}}, product};
        end
    endfunction

    always @(posedge clk) begin
        for (int h = 0; h < HEIGHT; h++)
            for (int w = 0; w < WIDTH; w++) begin
                ref_en_i[h][w]  <= (w == 0) ? en_i[h]  : ref_en_i[h][w-1];
                ref_clr_i[h][w] <= (w == 0) ? clr_i[h] : ref_clr_i[h][w-1];
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
                for (int w = 0; w < WIDTH; w++) ref_ifm[h][w] <= '0;
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin ref_wght[w][h] <= '0; ref_ofm[w][h] <= '0; end
        end else begin
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin
                    if ((w == 0) ? clr_i[h] : ref_clr_i[h][w-1]) ref_ifm[h][w] <= '0;
                    else if ((w == 0) ? en_i[h] : ref_en_i[h][w-1])
                        ref_ifm[h][w] <= (w == 0) ? ifm_in[h] : ref_ifm[h][w-1];
                end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    if ((h == 0) ? clr_w[w] : ref_clr_w[w][h-1]) ref_wght[w][h] <= '0;
                    else if ((h == 0) ? en_w[w] : ref_en_w[w][h-1])
                        ref_wght[w][h] <= (h == 0) ? wght_in[w] : ref_wght[w][h-1];
                    if ((h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1]) ref_ofm[w][h] <= '0;
                    else if ((h == HEIGHT-1) ? en_o[w] : ref_en_o[w][h+1])
                        ref_ofm[w][h] <= product_ext(ref_ifm[h][w], ref_wght[w][h])
                                       + ((h == HEIGHT-1) ? '0 : ref_ofm[w][h+1]);
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

    initial begin
        if (INPUT_BITS < 1 || INPUT_BITS > IWIDTH)
            $fatal(1, "BP_INPUT_BITS=%0d must be in [1,%0d]", INPUT_BITS, IWIDTH);
        en_i = '0; clr_i = '0; en_w = '0; clr_w = '0; en_o = '0; clr_o = '0;
        ifm_flat = '0; wght_flat = '0;

        clk_utils.set_clock(`ifdef ASTRAEA_CLK_PERIOD_NS `ASTRAEA_CLK_PERIOD_NS `else 2.5 `endif);
        clk_utils.do_reset();

        // Phase 1: weight load. All stimulus launched at the NEGEDGE (full
        // half-cycle setup) so every input is stable across the posedge ->
        // posedge+insertion capture window: golden and DUT sample the same value,
        // insertion-independent (see header).
        @(posedge clk); @(negedge clk); en_w = '1;
        for (int t = 0; t < HEIGHT; t++) begin @(posedge clk); @(negedge clk); wght_flat = random_wght_vector(); end
        @(posedge clk); @(negedge clk); en_w = '0;

        // Flush resetless control wavefront (clear pass, then a clean pass).
        en_i = '1; clr_i = '1; en_o = '1; clr_o = '1;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin @(posedge clk); @(negedge clk); ifm_flat = random_ifm_vector(); end
        clr_i = '0; clr_o = '0;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin @(posedge clk); @(negedge clk); ifm_flat = random_ifm_vector(); end

        @(negedge clk); #0.01;
        if ($isunknown(ofm_flat)) $fatal(1, "[X-FAIL] BP output unknown before SAIF");
        for (int w = 0; w < WIDTH; w++)
            if ($isunknown(ref_ofm[w][0])) $fatal(1, "[FUNC-FAIL] reference unknown before SAIF");
        monitor_x = 1'b1; check_enable = 1'b1;

        // Phase 2: scored streaming-MAC SAIF window.
        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        $toggle_start;
        for (int t = 0; t < STIM_CYCLES; t++) begin
            @(posedge clk); @(negedge clk);
            ifm_flat = random_ifm_vector();
            clr_o = ((t % READOUT_PERIOD) == (READOUT_PERIOD-1)) ? '1 : '0;
        end
        @(negedge clk); #0.01;   // let the negedge scoring block count this last
                                 // cycle before clearing check_enable (deterministic
                                 // ordering; xprop scheduling exposed the race)
        $toggle_stop;
        check_enable = 1'b0; monitor_x = 1'b0;

        if (checked_cycles < STIM_CYCLES)
            $fatal(1, "[FUNC-FAIL] checked only %0d of %0d SAIF cycles", checked_cycles, STIM_CYCLES);
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");
        $display("PASS: signed int%0d BP power SAIF captured + output-checked for %0d cycles",
                 INPUT_BITS, checked_cycles);
        $finish;
    end
endmodule
