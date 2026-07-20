// Power + output-checking bench for the unary-temporal (UT) stochastic array.
//
// Captures dut.saif over the temporal streaming window AND checks ofm against a
// faithful flat reference (temporal down-counter border + real sobol8 weight
// stream) every scored cycle. All inputs are launched at the NEGEDGE (full
// half-cycle setup, insertion-independent) so the zero-delay golden and the
// tree-delayed gate DUT sample the same value; timing checks stay ON.

`include "common/clk_util.sv"
`include "common/defines.sv"
`ifndef GL_SIM
`include "baselines/unary_temporal/array_8.sv"
`endif
`include "baselines/unary_temporal/sobol8.sv"

`timescale 1ns/1ps

`ifndef RATE_LEN_N
`define RATE_LEN_N 256
`endif

module Top;
    localparam int RATE_LEN = `RATE_LEN_N;
    localparam int N_MACS   = 16;
    localparam int HEIGHT   = 8;
    localparam int WIDTH    = 8;
    localparam int IWIDTH   = 8;
    localparam int OWIDTH   = 16;
    localparam int WARMUP   = WIDTH + 2;

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(N_MACS*RATE_LEN + 2048)) clk_utils (
        .clk(clk), .reset(reset), .timeout(timeout)
    );
    wire rst_n = ~reset;

    logic [HEIGHT-1:0]           en_i, clr_i, mac_done;
    logic [WIDTH-1:0]            en_w, clr_w, en_o, clr_o;
    logic [HEIGHT*IWIDTH-1:0]    ifm_flat;
    logic [WIDTH-1:0]            wght_sign_flat;
    logic [WIDTH*(IWIDTH-1)-1:0] wght_abs_flat;
    logic [WIDTH*OWIDTH-1:0]     ofm_flat;

    bit monitor_x = 1'b0;
    always @(ofm_flat)
        if (monitor_x && $isunknown(ofm_flat))
            $fatal(1, "[X-FAIL] UT output entered X during SAIF: %h", ofm_flat);

`ifdef GL_SIM
    array_8 dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .mac_done(mac_done),
        .en_w(en_w), .clr_w(clr_w), .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm_flat), .wght_sign(wght_sign_flat), .wght_abs(wght_abs_flat), .ofm(ofm_flat)
    );
    initial begin
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
    end
`else
    logic signed [IWIDTH-1:0] ifm_unp       [HEIGHT-1:0];
    logic                     wght_sign_unp [WIDTH-1:0];
    logic        [IWIDTH-2:0] wght_abs_unp  [WIDTH-1:0];
    logic signed [OWIDTH-1:0] ofm_unp       [WIDTH-1:0];
    genvar gh, gw;
    generate
        for (gh = 0; gh < HEIGHT; gh++) assign ifm_unp[gh] = ifm_flat[gh*IWIDTH +: IWIDTH];
        for (gw = 0; gw < WIDTH;  gw++) begin
            assign wght_sign_unp[gw] = wght_sign_flat[gw];
            assign wght_abs_unp[gw]  = wght_abs_flat[gw*(IWIDTH-1) +: (IWIDTH-1)];
            assign ofm_flat[gw*OWIDTH +: OWIDTH] = ofm_unp[gw];
        end
    endgenerate
    array_8 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(IWIDTH), .OWIDTH(OWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .mac_done(mac_done),
        .en_w(en_w), .clr_w(clr_w), .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm_unp), .wght_sign(wght_sign_unp), .wght_abs(wght_abs_unp), .ofm(ofm_unp)
    );
`endif

    logic signed [IWIDTH-1:0] ifm_in       [HEIGHT-1:0];
    logic                     wght_sign_in [WIDTH-1:0];
    logic        [IWIDTH-2:0] wght_abs_in  [WIDTH-1:0];
    always_comb for (int h = 0; h < HEIGHT; h++) ifm_in[h] = ifm_flat[h*IWIDTH +: IWIDTH];
    always_comb for (int w = 0; w < WIDTH;  w++) begin
        wght_sign_in[w] = wght_sign_flat[w];
        wght_abs_in[w]  = wght_abs_flat[w*(IWIDTH-1) +: (IWIDTH-1)];
    end

    // -------- faithful flat reference (see tb/test_array_8.sv) --------
    logic signed [IWIDTH-1:0] ref_ifm      [HEIGHT-1:0];
    logic        [IWIDTH-2:0] ref_ifm_abs  [HEIGHT-1:0];
    logic                     ref_ifm_sign [HEIGHT-1:0];
    logic        [IWIDTH-2:0] ref_cnt      [HEIGHT-1:0];
    logic        [IWIDTH-1:0] ref_randW_all[HEIGHT-1:0];
    logic                     ref_bitI     [HEIGHT-1:0];
    logic                     ref_ibit  [HEIGHT-1:0][WIDTH-1:0];
    logic                     ref_isign [HEIGHT-1:0][WIDTH-1:0];
    logic        [IWIDTH-2:0] ref_randW [HEIGHT-1:0][WIDTH-1:0];
    logic                     ref_wsign [WIDTH-1:0][HEIGHT-1:0];
    logic        [IWIDTH-2:0] ref_wabs  [WIDTH-1:0][HEIGHT-1:0];
    logic                     ref_macd  [HEIGHT-1:0][WIDTH-1:0];
    logic signed [OWIDTH-1:0] ref_ofm   [WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_i [HEIGHT-1:0][WIDTH-1:0];
    logic ref_clr_i[HEIGHT-1:0][WIDTH-1:0];
    logic ref_en_w [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_w[WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_o [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_o[WIDTH-1:0][HEIGHT-1:0];

    bit check_enable = 1'b0;
    int checked_cycles = 0;

    always_comb begin
        for (int h = 0; h < HEIGHT; h++) begin
            logic signed [IWIDTH-1:0] neg;
            neg = -ref_ifm[h];
            ref_ifm_sign[h] = ref_ifm[h][IWIDTH-1];
            ref_ifm_abs[h]  = ref_ifm[h][IWIDTH-1] ? neg[IWIDTH-2:0] : ref_ifm[h][IWIDTH-2:0];
            ref_bitI[h]     = (ref_cnt[h] != 0);
        end
    end

    genvar grh;
    generate
        for (grh = 0; grh < HEIGHT; grh++) begin : g_rng
            sobol8 U_W (.clk(clk), .rst_n(rst_n), .enable(ref_bitI[grh]), .sobolSeq(ref_randW_all[grh]));
        end
    endgenerate

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
            for (int h = 0; h < HEIGHT; h++) begin ref_ifm[h] <= '0; ref_cnt[h] <= '0; end
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin
                    ref_ibit[h][w] <= 1'b0; ref_isign[h][w] <= 1'b0; ref_randW[h][w] <= '0;
                end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    ref_wsign[w][h] <= 1'b0; ref_wabs[w][h] <= '0; ref_ofm[w][h] <= '0;
                end
        end else begin
            for (int h = 0; h < HEIGHT; h++) begin
                if (clr_i[h])     ref_ifm[h] <= '0;
                else if (en_i[h]) ref_ifm[h] <= ifm_in[h];
                if (ref_en_i[h][0])                       ref_cnt[h] <= ref_ifm_abs[h];
                else if (ref_clr_i[h][0] || !ref_bitI[h]) ref_cnt[h] <= '0;
                else                                      ref_cnt[h] <= ref_cnt[h] - 1'b1;
            end
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 1; w < WIDTH; w++) begin
                    logic cur_clr_i, cur_en_i, ibit_in, isign_in;
                    logic [IWIDTH-2:0] randw_in;
                    cur_clr_i = ref_clr_i[h][w-1];
                    cur_en_i  = ref_en_i[h][w-1];
                    ibit_in   = (w == 1) ? ref_bitI[h]     : ref_ibit[h][w-1];
                    isign_in  = (w == 1) ? ref_ifm_sign[h] : ref_isign[h][w-1];
                    randw_in  = (w == 1) ? ref_randW_all[h][IWIDTH-1:1] : ref_randW[h][w-1];
                    if (cur_clr_i) begin ref_ibit[h][w] <= 1'b0; ref_isign[h][w] <= 1'b0; end
                    else if (cur_en_i) begin ref_ibit[h][w] <= ibit_in; ref_isign[h][w] <= isign_in; end
                    ref_randW[h][w] <= randw_in;
                end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    logic cur_clr_w, cur_en_w, cur_clr_o, cur_en_o, cur_macd;
                    logic l_ibit, l_isign, l_wsign, bitW, o_bit, neg, in_wsign;
                    logic [IWIDTH-2:0] l_randW, l_wabs, in_wabs;
                    logic signed [OWIDTH-1:0] sum_i, prod_val;
                    cur_clr_w = (h == 0) ? clr_w[w] : ref_clr_w[w][h-1];
                    cur_en_w  = (h == 0) ? en_w[w]  : ref_en_w[w][h-1];
                    in_wsign  = (h == 0) ? wght_sign_in[w] : ref_wsign[w][h-1];
                    in_wabs   = (h == 0) ? wght_abs_in[w]  : ref_wabs[w][h-1];
                    if (cur_clr_w) begin ref_wsign[w][h] <= 1'b0; ref_wabs[w][h] <= '0; end
                    else if (cur_en_w) begin ref_wsign[w][h] <= in_wsign; ref_wabs[w][h] <= in_wabs; end

                    l_ibit  = (w == 0) ? ref_bitI[h]                  : ref_ibit[h][w];
                    l_isign = (w == 0) ? ref_ifm_sign[h]              : ref_isign[h][w];
                    l_randW = (w == 0) ? ref_randW_all[h][IWIDTH-1:1] : ref_randW[h][w];
                    l_wabs  = ref_wabs[w][h];
                    l_wsign = ref_wsign[w][h];
                    bitW    = l_wabs > l_randW;
                    o_bit   = l_ibit & bitW;
                    neg     = l_isign ^ l_wsign;
                    prod_val = o_bit ? (neg ? -16'sd1 : 16'sd1) : 16'sd0;

                    cur_clr_o = (h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1];
                    cur_en_o  = (h == HEIGHT-1) ? en_o[w]  : ref_en_o[w][h+1];
                    cur_macd  = ref_macd[h][w];
                    sum_i     = (h == HEIGHT-1) ? '0 : ref_ofm[w][h+1];
                    if (cur_clr_o)      ref_ofm[w][h] <= '0;
                    else if (cur_en_o)  ref_ofm[w][h] <= (cur_macd ? sum_i : prod_val) + ref_ofm[w][h];
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
        en_i = '0; clr_i = '0; mac_done = '0;
        en_w = '0; clr_w = '0; en_o = '0; clr_o = '0;
        ifm_flat = '0; wght_sign_flat = '0; wght_abs_flat = '0;

        clk_utils.set_clock(`ifdef ASTRAEA_CLK_PERIOD_NS `ASTRAEA_CLK_PERIOD_NS `else 2.5 `endif);
        clk_utils.do_reset();

        // Phase 1: weight load. All stimulus launched at the NEGEDGE (full
        // half-cycle setup) so every input is stable across the posedge ->
        // posedge+insertion capture window; golden and DUT sample the same value,
        // insertion-independent (see header).
        @(posedge clk); @(negedge clk); en_w = '1;
        for (int t = 0; t < HEIGHT; t++) begin
            @(posedge clk); @(negedge clk);
            wght_sign_flat = $urandom;
            wght_abs_flat  = {$urandom, $urandom};
        end
        @(posedge clk); @(negedge clk); en_w = '0;

        // Phase 2: temporal streaming SAIF window (1-cycle en_i pulse per window).
        $set_gate_level_monitoring("rtl_on");
        $set_toggle_region(dut);
        $toggle_start;
        @(posedge clk); @(negedge clk); en_o = '1; clr_o = '0;

        for (int m = 0; m < N_MACS; m++) begin
            @(posedge clk); @(negedge clk);
            ifm_flat = {$urandom, $urandom};
            en_i = '1; mac_done = '0;
            @(posedge clk); @(negedge clk); en_i = '0;
            if (m == 0) begin
                for (int t = 2; t < WARMUP; t++) @(posedge clk);
                @(negedge clk); #0.01;
                if ($isunknown(ofm_flat)) $fatal(1, "[X-FAIL] UT output unknown before SAIF check");
                for (int w = 0; w < WIDTH; w++)
                    if ($isunknown(ref_ofm[w][0])) $fatal(1, "[FUNC-FAIL] reference unknown before SAIF");
                monitor_x = 1'b1; check_enable = 1'b1;
                for (int t = WARMUP; t < RATE_LEN-1; t++) @(posedge clk);
            end else begin
                for (int t = 2; t < RATE_LEN-1; t++) @(posedge clk);
            end
            @(posedge clk); @(negedge clk); mac_done = '1;
        end
        @(posedge clk); @(negedge clk); mac_done = '0;
        @(negedge clk); #0.01;   // deterministic window close vs the negedge
                                 // scoring block (xprop-safe ordering)
        $toggle_stop;
        check_enable = 1'b0; monitor_x = 1'b0;

        if (checked_cycles < 1) $fatal(1, "[FUNC-FAIL] no SAIF cycles scored");
        $toggle_report("dut.saif", 1.0e-9, "Top.dut");
        $display("PASS: UT power SAIF captured + output-checked for %0d cycles", checked_cycles);
        $finish;
    end
endmodule
