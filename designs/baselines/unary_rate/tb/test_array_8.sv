// Cycle-accurate functional golden for the unary-rate (UR) stochastic array.
//
// Flat reference of the UR pipeline driven with power_array_8.sv's cadence
// (weight load, then N_MACS windows of RATE_LEN held-stable rate cycles with a
// mac_done pulse per window). To avoid re-deriving the Sobol LS-zero logic the
// reference instantiates the real sobol8 primitive (per row: randI free-running,
// randW enable-gated by bitI) and models the comparators, the eastward i_bit /
// randW / sign propagation, southward weights, and the +/-1 accumulator. Checks
// ofm[w] == ref_ofm[w][0] every scored cycle. It does not inspect DUT hierarchy.

`include "common/clk_util.sv"
`include "common/defines.sv"
`include "baselines/unary_rate/array_8.sv"
`include "baselines/unary_rate/sobol8.sv"

`timescale 1ns/1ps

module Top;
    localparam int RATE_LEN = 256;
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

    logic [HEIGHT-1:0] en_i, clr_i, mac_done;
    logic [WIDTH-1:0]  en_w, clr_w, en_o, clr_o;
    logic signed [IWIDTH-1:0] ifm       [HEIGHT-1:0];
    logic                     wght_sign [WIDTH-1:0];
    logic        [IWIDTH-2:0] wght_abs  [WIDTH-1:0];
    logic signed [OWIDTH-1:0] ofm       [WIDTH-1:0];

    array_8 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH), .IWIDTH(IWIDTH), .OWIDTH(OWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .mac_done(mac_done),
        .en_w(en_w), .clr_w(clr_w), .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm), .wght_sign(wght_sign), .wght_abs(wght_abs), .ofm(ofm)
    );

    // -------- reference state --------
    logic signed [IWIDTH-1:0] ref_ifm      [HEIGHT-1:0];   // ireg_border o_data
    logic        [IWIDTH-2:0] ref_ifm_abs  [HEIGHT-1:0];
    logic                     ref_ifm_sign [HEIGHT-1:0];
    logic        [IWIDTH-1:0] ref_randI    [HEIGHT-1:0];   // sobol8 (enable=1)
    logic        [IWIDTH-1:0] ref_randW_all[HEIGHT-1:0];   // sobol8 (enable=bitI)
    logic                     ref_bitI     [HEIGHT-1:0];

    // eastward propagation (inner cols 1..W-1); randW resetless self-fills
    logic                     ref_ibit  [HEIGHT-1:0][WIDTH-1:0];
    logic                     ref_isign [HEIGHT-1:0][WIDTH-1:0];
    logic        [IWIDTH-2:0] ref_randW [HEIGHT-1:0][WIDTH-1:0];
    // southward weights, eastward mac_done, north ofm chain
    logic                     ref_wsign [WIDTH-1:0][HEIGHT-1:0];
    logic        [IWIDTH-2:0] ref_wabs  [WIDTH-1:0][HEIGHT-1:0];
    logic                     ref_macd  [HEIGHT-1:0][WIDTH-1:0];
    logic signed [OWIDTH-1:0] ref_ofm   [WIDTH-1:0][HEIGHT-1:0];
    // control forwarding (resetless)
    logic ref_en_i [HEIGHT-1:0][WIDTH-1:0];
    logic ref_clr_i[HEIGHT-1:0][WIDTH-1:0];
    logic ref_en_w [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_w[WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_o [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_o[WIDTH-1:0][HEIGHT-1:0];

    bit check_enable = 1'b0;
    int checked_cycles = 0;

    // ireg_border sign/abs split + border comparator, per row.
    always_comb begin
        for (int h = 0; h < HEIGHT; h++) begin
            logic signed [IWIDTH-1:0] neg;
            neg = -ref_ifm[h];
            ref_ifm_sign[h] = ref_ifm[h][IWIDTH-1];
            ref_ifm_abs[h]  = ref_ifm[h][IWIDTH-1] ? neg[IWIDTH-2:0] : ref_ifm[h][IWIDTH-2:0];
            ref_bitI[h]     = ref_ifm_abs[h] > ref_randI[h][IWIDTH-1:1];
        end
    end

    // Reuse the real Sobol primitive for both streams (matches the DUT exactly).
    genvar gh;
    generate
        for (gh = 0; gh < HEIGHT; gh++) begin : g_rng
            sobol8 U_I (.clk(clk), .rst_n(rst_n), .enable(1'b1),        .sobolSeq(ref_randI[gh]));
            sobol8 U_W (.clk(clk), .rst_n(rst_n), .enable(ref_bitI[gh]), .sobolSeq(ref_randW_all[gh]));
        end
    endgenerate

    // Resetless control forwarding.
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

    // Datapath.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int h = 0; h < HEIGHT; h++) ref_ifm[h] <= '0;
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin
                    ref_ibit[h][w]  <= 1'b0;
                    ref_isign[h][w] <= 1'b0;
                    ref_randW[h][w] <= '0;
                end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    ref_wsign[w][h] <= 1'b0;
                    ref_wabs[w][h]  <= '0;
                    ref_ofm[w][h]   <= '0;
                end
        end else begin
            // ireg_border: registered ifm (col 0 input).
            for (int h = 0; h < HEIGHT; h++) begin
                if (clr_i[h])     ref_ifm[h] <= '0;
                else if (en_i[h]) ref_ifm[h] <= ifm[h];
            end
            // ireg_inner (east): i_bit + sign, gated by en_i/clr_i. randW (mul_inner,
            // ungated, resetless-self-fill). Border feeds w==1 with comb bitI/sign/randW.
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 1; w < WIDTH; w++) begin
                    logic cur_clr_i, cur_en_i, ibit_in, isign_in;
                    logic [IWIDTH-2:0] randw_in;
                    cur_clr_i = ref_clr_i[h][w-1];
                    cur_en_i  = ref_en_i[h][w-1];
                    ibit_in   = (w == 1) ? ref_bitI[h]     : ref_ibit[h][w-1];
                    isign_in  = (w == 1) ? ref_ifm_sign[h] : ref_isign[h][w-1];
                    randw_in  = (w == 1) ? ref_randW_all[h][IWIDTH-1:1] : ref_randW[h][w-1];
                    if (cur_clr_i) begin
                        ref_ibit[h][w]  <= 1'b0;
                        ref_isign[h][w] <= 1'b0;
                    end else if (cur_en_i) begin
                        ref_ibit[h][w]  <= ibit_in;
                        ref_isign[h][w] <= isign_in;
                    end
                    ref_randW[h][w] <= randw_in;   // mul_inner o_randW <= i_randW (always)
                end
            // wreg (south) + acc (north, +/-1 rate accumulate).
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    logic cur_clr_w, cur_en_w, cur_clr_o, cur_en_o, cur_macd;
                    logic l_ibit, l_isign, l_wsign, bitW, o_bit, neg;
                    logic [IWIDTH-2:0] l_randW, l_wabs, in_wabs;
                    logic in_wsign;
                    logic signed [OWIDTH-1:0] sum_i, prod_val;

                    cur_clr_w = (h == 0) ? clr_w[w] : ref_clr_w[w][h-1];
                    cur_en_w  = (h == 0) ? en_w[w]  : ref_en_w[w][h-1];
                    in_wsign  = (h == 0) ? wght_sign[w] : ref_wsign[w][h-1];
                    in_wabs   = (h == 0) ? wght_abs[w]  : ref_wabs[w][h-1];
                    if (cur_clr_w) begin
                        ref_wsign[w][h] <= 1'b0;
                        ref_wabs[w][h]  <= '0;
                    end else if (cur_en_w) begin
                        ref_wsign[w][h] <= in_wsign;
                        ref_wabs[w][h]  <= in_wabs;
                    end

                    // local (pre-edge) operands at PE[h][w]
                    l_ibit  = (w == 0) ? ref_bitI[h]                 : ref_ibit[h][w];
                    l_isign = (w == 0) ? ref_ifm_sign[h]             : ref_isign[h][w];
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
                    if (cur_clr_o)
                        ref_ofm[w][h] <= '0;
                    else if (cur_en_o)
                        ref_ofm[w][h] <= (cur_macd ? sum_i : prod_val) + ref_ofm[w][h];
                end
        end
    end

    always @(negedge clk) begin
        if (check_enable) begin
            for (int w = 0; w < WIDTH; w++)
                if (ofm[w] !== ref_ofm[w][0])
                    $fatal(1,
                        "[FUNC-FAIL] cycle=%0d column=%0d got=%0d (%h) expected=%0d (%h)",
                        checked_cycles, w, $signed(ofm[w]), ofm[w],
                        $signed(ref_ofm[w][0]), ref_ofm[w][0]);
            checked_cycles++;
        end
    end

    initial begin
        en_i = '0; clr_i = '0; mac_done = '0;
        en_w = '0; clr_w = '0; en_o = '0; clr_o = '0;
        for (int h = 0; h < HEIGHT; h++) ifm[h] = '0;
        for (int w = 0; w < WIDTH;  w++) begin wght_sign[w] = 1'b0; wght_abs[w] = '0; end

        clk_utils.set_clock(2.5);
        clk_utils.do_reset();

        // Phase 1: weight load.
        en_w = '1;
        for (int t = 0; t < HEIGHT; t++) begin
            @(negedge clk);
            for (int w = 0; w < WIDTH; w++) begin
                wght_sign[w] = $urandom & 1;
                wght_abs[w]  = $urandom;
            end
        end
        @(negedge clk);
        en_w = '0;

        // Phase 2: rate-coded streaming MACs.
        en_i = '1; clr_i = '0; en_o = '1; clr_o = '0;
        for (int m = 0; m < N_MACS; m++) begin
            @(negedge clk);
            for (int h = 0; h < HEIGHT; h++) ifm[h] = $urandom;
            mac_done = '0;
            if (m == 0) begin
                // warm up the resetless randW fill, then gate on X-freeness.
                for (int t = 1; t < WARMUP; t++) @(negedge clk);
                #0.01;
                for (int w = 0; w < WIDTH; w++)
                    if ($isunknown(ofm[w]) || $isunknown(ref_ofm[w][0]))
                        $fatal(1, "[FUNC-FAIL] unknown ofm[%0d] before scored window", w);
                check_enable = 1'b1;
                for (int t = WARMUP; t < RATE_LEN-1; t++) @(negedge clk);
            end else begin
                for (int t = 1; t < RATE_LEN-1; t++) @(negedge clk);
            end
            @(negedge clk);
            mac_done = '1;
        end
        @(negedge clk);
        mac_done = '0;
        @(negedge clk);
        check_enable = 1'b0;

        if (checked_cycles < 1)
            $fatal(1, "[FUNC-FAIL] no cycles scored");
        $display("PASS: unary-rate UR array matched reference for %0d cycles", checked_cycles);
        $finish;
    end
endmodule
