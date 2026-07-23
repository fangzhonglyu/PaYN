// Power + end-to-end output-checking bench for the asymmetric binary-parallel
// systolic array.  The golden model pipelines centered (q-z) values through a
// flat array model and therefore does not reuse the DUT's correction equation.

`include "common/clk_util.sv"
`include "common/defines.sv"
`ifndef GL_SIM
`include "baselines/binary_parallel/array_8_asym_corr_v2.sv"
`endif

`timescale 1ns/1ps

`ifndef STIM_CYCLES_N
`define STIM_CYCLES_N 4096
`endif

module Top;
    localparam int STIM_CYCLES    = `STIM_CYCLES_N;
    localparam int READOUT_PERIOD = 64;
    localparam int HEIGHT         = 8;
    localparam int WIDTH          = 8;
    localparam int IWIDTH         = 8;
    localparam int CWIDTH         = IWIDTH + 1;
    localparam int OWIDTH         = 24;
    localparam int WSUM_WIDTH     = IWIDTH + $clog2(HEIGHT) + 1;
    localparam int FLUSH_CYCLES   = HEIGHT + WIDTH + 2;
`ifdef ASTRAEA_CLK_PERIOD_NS
    localparam realtime CLK_PERIOD_NS = `ASTRAEA_CLK_PERIOD_NS;
`else
    localparam realtime CLK_PERIOD_NS = 2.5;
`endif
    // The correction is combinational after the raw accumulator registers.
    // Sample at 90% of the cycle so routed logic has its full-cycle budget.
    localparam realtime CHECK_DELAY_NS = 0.4 * CLK_PERIOD_NS;

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(STIM_CYCLES + 2048)) clk_utils (
        .clk(clk), .reset(reset), .timeout(timeout)
    );
    wire rst_n = ~reset;

    logic [HEIGHT-1:0] en_i, clr_i;
    logic [WIDTH-1:0] en_w, clr_w, en_o, clr_o;
    logic sum_en, corr_en, correction_active;
    logic [HEIGHT*IWIDTH-1:0] ifm_flat;
    logic [WIDTH*IWIDTH-1:0] wght_flat;
    logic signed [IWIDTH-1:0] ifm_zp;
    logic [WIDTH*IWIDTH-1:0] wght_zp_flat;
    logic [WIDTH*WSUM_WIDTH-1:0] centered_wsum_flat;
    logic [WIDTH*OWIDTH-1:0] ofm_flat;
    bit monitor_x = 1'b0;

    function automatic logic [HEIGHT*IWIDTH-1:0] random_ifm_vector();
        random_ifm_vector = {$urandom, $urandom};
    endfunction

    function automatic logic [WIDTH*IWIDTH-1:0] random_wght_vector();
        random_wght_vector = {$urandom, $urandom};
    endfunction

    always @(ofm_flat)
        if (monitor_x && $isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] asymmetric BP output entered X during SAIF: %h", ofm_flat);

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
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
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
    array_8_asym_corr_v2 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(IWIDTH), .OWIDTH(OWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o), .sum_en(sum_en), .corr_en(corr_en),
        .ifm(ifm_unp), .wght(wght_unp), .ifm_zp(ifm_zp),
        .wght_zp(wght_zp_unp), .centered_wsum(centered_wsum_unp), .ofm(ofm_unp)
    );
`endif

    logic signed [IWIDTH-1:0] ifm_in [HEIGHT-1:0];
    logic signed [IWIDTH-1:0] wght_in [WIDTH-1:0];
    logic signed [IWIDTH-1:0] wght_zp_in [WIDTH-1:0];
    always_comb for (int h = 0; h < HEIGHT; h++)
        ifm_in[h] = ifm_flat[h*IWIDTH +: IWIDTH];
    always_comb for (int w = 0; w < WIDTH; w++) begin
        wght_in[w] = wght_flat[w*IWIDTH +: IWIDTH];
        wght_zp_in[w] = wght_zp_flat[w*IWIDTH +: IWIDTH];
    end

    // Independent flat reference.  It models a mathematically centered array:
    // every stored activation is qx-zx and every stored weight is qw-zw.
    logic ref_en_i  [HEIGHT-1:0][WIDTH-1:0];
    logic ref_clr_i [HEIGHT-1:0][WIDTH-1:0];
    logic ref_en_w  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_w [WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_o  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_o [WIDTH-1:0][HEIGHT-1:0];
    logic signed [CWIDTH-1:0] ref_ifm [HEIGHT-1:0][WIDTH-1:0];
    logic signed [CWIDTH-1:0] ref_wght [WIDTH-1:0][HEIGHT-1:0];
    logic signed [OWIDTH-1:0] ref_ofm [WIDTH-1:0][HEIGHT-1:0];
    bit check_enable = 1'b0;
    int checked_cycles = 0;

    function automatic logic signed [CWIDTH-1:0] centered_value(
        input logic signed [IWIDTH-1:0] q,
        input logic signed [IWIDTH-1:0] zp
    );
        logic signed [CWIDTH-1:0] q_ext, zp_ext;
        begin
            q_ext = {q[IWIDTH-1], q};
            zp_ext = {zp[IWIDTH-1], zp};
            centered_value = q_ext - zp_ext;
        end
    endfunction

    function automatic logic signed [OWIDTH-1:0] centered_product_ext(
        input logic signed [CWIDTH-1:0] a,
        input logic signed [CWIDTH-1:0] b
    );
        logic signed [2*CWIDTH-1:0] product;
        begin
            product = a * b;
            centered_product_ext = {{(OWIDTH-2*CWIDTH){product[2*CWIDTH-1]}}, product};
        end
    endfunction

    // The output-clear wavefront is synchronous across columns in this
    // workload.  corr_en is the output-valid qualifier: on a top-row clear it
    // disables the combinational correction so the architectural output is 0.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            corr_en <= 1'b0;
        else if (!correction_active)
            corr_en <= 1'b0;
        else
            corr_en <= !((HEIGHT == 1) ? clr_o[0] : ref_clr_o[0][1]);
    end

    always @(posedge clk) begin
        for (int h = 0; h < HEIGHT; h++)
            for (int w = 0; w < WIDTH; w++) begin
                ref_en_i[h][w] <= (w == 0) ? en_i[h] : ref_en_i[h][w-1];
                ref_clr_i[h][w] <= (w == 0) ? clr_i[h] : ref_clr_i[h][w-1];
            end
        for (int w = 0; w < WIDTH; w++)
            for (int h = 0; h < HEIGHT; h++) begin
                ref_en_w[w][h] <= (h == 0) ? en_w[w] : ref_en_w[w][h-1];
                ref_clr_w[w][h] <= (h == 0) ? clr_w[w] : ref_clr_w[w][h-1];
                ref_en_o[w][h] <= (h == HEIGHT-1) ? en_o[w] : ref_en_o[w][h+1];
                ref_clr_o[w][h] <= (h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1];
            end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) ref_ifm[h][w] <= '0;
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    ref_wght[w][h] <= '0;
                    ref_ofm[w][h] <= '0;
                end
        end else begin
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin
                    if ((w == 0) ? clr_i[h] : ref_clr_i[h][w-1])
                        ref_ifm[h][w] <= '0;
                    else if ((w == 0) ? en_i[h] : ref_en_i[h][w-1])
                        ref_ifm[h][w] <= (w == 0)
                            ? centered_value(ifm_in[h], ifm_zp) : ref_ifm[h][w-1];
                end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    if ((h == 0) ? clr_w[w] : ref_clr_w[w][h-1])
                        ref_wght[w][h] <= '0;
                    else if ((h == 0) ? en_w[w] : ref_en_w[w][h-1])
                        ref_wght[w][h] <= (h == 0)
                            ? centered_value(wght_in[w], wght_zp_in[w]) : ref_wght[w][h-1];

                    if ((h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1])
                        ref_ofm[w][h] <= '0;
                    else if ((h == HEIGHT-1) ? en_o[w] : ref_en_o[w][h+1])
                        ref_ofm[w][h] <= centered_product_ext(ref_ifm[h][w], ref_wght[w][h])
                            + ((h == HEIGHT-1) ? '0 : ref_ofm[w][h+1]);
                end
        end
    end

    always @(negedge clk) begin
        if (check_enable) begin
            #(CHECK_DELAY_NS);
            for (int w = 0; w < WIDTH; w++) begin
                if (ofm_flat[w*OWIDTH +: OWIDTH] !== ref_ofm[w][0])
                    $fatal(1,
                        "[FUNC-FAIL] SAIF cycle=%0d column=%0d corr_en=%b got=%0d (%h) expected=%0d (%h)",
                        checked_cycles, w, corr_en,
                        $signed(ofm_flat[w*OWIDTH +: OWIDTH]),
                        ofm_flat[w*OWIDTH +: OWIDTH],
                        $signed(ref_ofm[w][0]), ref_ofm[w][0]);
            end
            checked_cycles++;
        end
    end

    initial begin
        en_i = '0; clr_i = '0; en_w = '0; clr_w = '0;
        en_o = '0; clr_o = '0; sum_en = 1'b0; correction_active = 1'b0;
        ifm_flat = '0; wght_flat = '0; centered_wsum_flat = '0;
        ifm_zp = -8'sd5;
        for (int w = 0; w < WIDTH; w++)
            wght_zp_flat[w*IWIDTH +: IWIDTH] = w - 4;

        clk_utils.set_clock(CLK_PERIOD_NS);
        clk_utils.do_reset();

        // Drive eight weight-load cycles.  The centered sums supplied to the
        // DUT are then derived from the golden model's final stationary state,
        // exactly as software would precompute them.
        @(posedge clk); @(negedge clk); en_w = '1;
        for (int t = 0; t < HEIGHT; t++) begin
            wght_flat = random_wght_vector();
            @(posedge clk); @(negedge clk);
        end
        en_w = '0;

        // Flush the resetless activation/control/sum wavefront, then run a
        // clean valid pass before enabling checking and SAIF collection.
        en_i = '1; clr_i = '1; en_o = '1; clr_o = '1; sum_en = 1'b1;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin
            @(posedge clk); @(negedge clk); ifm_flat = random_ifm_vector();
        end
        // The weight-enable wavefront takes HEIGHT cycles to drain after en_w
        // is deasserted.  Compute the metadata only after the stationary array
        // has reached its final loaded state.
        for (int w = 0; w < WIDTH; w++) begin
            integer centered_sum;
            centered_sum = 0;
            for (int h = 0; h < HEIGHT; h++) centered_sum += $signed(ref_wght[w][h]);
            centered_wsum_flat[w*WSUM_WIDTH +: WSUM_WIDTH] = centered_sum;
        end
        clr_i = '0; clr_o = '0; correction_active = 1'b1;
        for (int t = 0; t < FLUSH_CYCLES; t++) begin
            @(posedge clk); @(negedge clk); ifm_flat = random_ifm_vector();
        end

        #(CHECK_DELAY_NS);
        if ($isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] asymmetric BP output unknown before SAIF: %h", ofm_flat);
        for (int w = 0; w < WIDTH; w++)
            if ($isunknown(ref_ofm[w][0]))
                $fatal(1, "[FUNC-FAIL] centered reference output %0d unknown before SAIF", w);
        monitor_x = 1'b1;
        check_enable = 1'b1;

        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        $toggle_start;
        for (int t = 0; t < STIM_CYCLES; t++) begin
            @(posedge clk); @(negedge clk);
            ifm_flat = random_ifm_vector();
            clr_o = ((t % READOUT_PERIOD) == (READOUT_PERIOD-1)) ? '1 : '0;
        end
        #(CHECK_DELAY_NS + 0.01);
        $toggle_stop;
        check_enable = 1'b0;
        monitor_x = 1'b0;

        if (checked_cycles < STIM_CYCLES)
            $fatal(1, "[FUNC-FAIL] checked only %0d of %0d SAIF cycles",
                   checked_cycles, STIM_CYCLES);
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");
        $display("PASS: asymmetric INT8 BP SAIF captured + end-to-end output-checked for %0d cycles",
                 checked_cycles);
        $finish;
    end
endmodule
