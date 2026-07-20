// Cycle-accurate functional golden for the bit-serial (BS) systolic array.
//
// Flat state model of the BS pipeline, driven with the same weight-load /
// flush / streaming-MAC cadence as power_array_8.sv. The reference faithfully
// reproduces each PE's ireg (ifm east), wreg (wght south), free-running mul
// index (mod 2^IDEPTH), bit-serial shift-add accumulator, and the north-flowing
// ofm chain, then checks ofm[w] == ref_ofm[w][0] every scored cycle. It does not
// inspect DUT hierarchy.

`include "common/clk_util.sv"
`include "common/defines.sv"
`include "baselines/binary_serial/array_8.sv"

`timescale 1ns/1ps

module Top;
    localparam int IWIDTH         = 8;
    localparam int IDEPTH         = 3;
    localparam int OWIDTH         = 24;
    localparam int HEIGHT         = 8;
    localparam int WIDTH          = 8;
    localparam int STIM_CYCLES    = 2048;
    localparam int READOUT_PERIOD = 64 * IWIDTH;
    localparam int FLUSH_CYCLES   = (HEIGHT + WIDTH + 2) * IWIDTH;

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(STIM_CYCLES + 2048)) clk_utils (
        .clk(clk), .reset(reset), .timeout(timeout)
    );
    wire rst_n = ~reset;

    logic [HEIGHT-1:0] en_i, clr_i, mac_done;
    logic [WIDTH-1:0]  en_w, clr_w, en_o, clr_o;
    logic signed [IWIDTH-1:0] ifm  [HEIGHT-1:0];
    logic signed [IWIDTH-1:0] wght [WIDTH-1:0];
    logic signed [OWIDTH-1:0] ofm  [WIDTH-1:0];

    array_8 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH),
        .IWIDTH(IWIDTH), .IDEPTH(IDEPTH), .OWIDTH(OWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i), .mac_done(mac_done),
        .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm), .wght(wght), .ofm(ofm)
    );

    // -------- flat reference state --------
    // Control forwarding is resetless (matches pe en_clr block); flush makes it known.
    logic ref_en_i  [HEIGHT-1:0][WIDTH-1:0];
    logic ref_clr_i [HEIGHT-1:0][WIDTH-1:0];
    logic ref_macd  [HEIGHT-1:0][WIDTH-1:0];   // mac_done_d
    logic ref_en_w  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_w [WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_o  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_o [WIDTH-1:0][HEIGHT-1:0];
    logic signed [IWIDTH-1:0] ref_ifm  [HEIGHT-1:0][WIDTH-1:0];
    logic signed [IWIDTH-1:0] ref_wght [WIDTH-1:0][HEIGHT-1:0];
    logic        [IDEPTH-1:0] ref_idx  [HEIGHT-1:0][WIDTH-1:0];  // mul o_idx (free-running)
    logic signed [OWIDTH-1:0] ref_ofm  [WIDTH-1:0][HEIGHT-1:0];

    bit check_enable = 1'b0;
    int checked_cycles = 0;

    // Resetless control/index forwarding (one-cycle skew per PE).
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

    // Datapath: ireg (east), wreg (south), free-running index, bit-serial
    // shift-add accumulator with north chain. Reads old (pre-edge) state, so it
    // mirrors the DUT's nonblocking register semantics.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin
                    ref_ifm[h][w] <= '0;
                    ref_idx[h][w] <= '0;
                end
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    ref_wght[w][h] <= '0;
                    ref_ofm[w][h]  <= '0;
                end
        end else begin
            // ifm east + free-running mul index
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++) begin
                    logic cur_clr_i, cur_en_i;
                    logic signed [IWIDTH-1:0] in_ifm;
                    cur_clr_i = (w == 0) ? clr_i[h] : ref_clr_i[h][w-1];
                    cur_en_i  = (w == 0) ? en_i[h]  : ref_en_i[h][w-1];
                    in_ifm    = (w == 0) ? ifm[h]   : ref_ifm[h][w-1];
                    if (cur_clr_i)      ref_ifm[h][w] <= '0;
                    else if (cur_en_i)  ref_ifm[h][w] <= in_ifm;
                    // mul_border free-runs (o_idx+1); mul_inner copies the
                    // propagated west index (o_idx <= i_idx), so column w's
                    // index is skewed w cycles to track the eastward ifm.
                    ref_idx[h][w] <= (w == 0) ? (ref_idx[h][w] + 1'b1)
                                              : ref_idx[h][w-1];
                end
            // wght south + ofm north (bit-serial shift-add)
            for (int w = 0; w < WIDTH; w++)
                for (int h = 0; h < HEIGHT; h++) begin
                    logic cur_clr_w, cur_en_w, cur_clr_o, cur_en_o, cur_macd, sel_bit;
                    logic signed [IWIDTH-1:0] in_wght;
                    logic signed [OWIDTH-1:0] sum_i, prod_ext;
                    cur_clr_w = (h == 0) ? clr_w[w] : ref_clr_w[w][h-1];
                    cur_en_w  = (h == 0) ? en_w[w]  : ref_en_w[w][h-1];
                    in_wght   = (h == 0) ? wght[w]  : ref_wght[w][h-1];
                    if (cur_clr_w)      ref_wght[w][h] <= '0;
                    else if (cur_en_w)  ref_wght[w][h] <= in_wght;

                    cur_clr_o = (h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1];
                    cur_en_o  = (h == HEIGHT-1) ? en_o[w]  : ref_en_o[w][h+1];
                    cur_macd  = ref_macd[h][w];
                    sum_i     = (h == HEIGHT-1) ? '0 : ref_ofm[w][h+1];
                    sel_bit   = ref_ifm[h][w][ref_idx[h][w]];
                    prod_ext  = sel_bit ? OWIDTH'(ref_wght[w][h]) : '0;   // signed sext
                    if (cur_clr_o)
                        ref_ofm[w][h] <= '0;
                    else if (cur_en_o)
                        ref_ofm[w][h] <= (cur_macd ? sum_i    : prod_ext)
                                       + (cur_macd ? ref_ofm[w][h] : (ref_ofm[w][h] << 1));
                end
        end
    end

    // Compare after posedge NBA settles, before the next stimulus change.
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

    // Bit-serial MAC cadence: en_i + fresh ifm on phase 0, mac_done on phase 7.
    task automatic drive_phase(input int t, input bit refresh_ifm);
        int phase;
        phase = t % IWIDTH;
        @(negedge clk);
        if (phase == 0) begin
            if (refresh_ifm)
                for (int h = 0; h < HEIGHT; h++) ifm[h] = $urandom;
            en_i = '1;
        end else begin
            en_i = '0;
        end
        mac_done = (phase == (IWIDTH-1)) ? '1 : '0;
    endtask

    initial begin
        en_i = '0; clr_i = '0; mac_done = '0;
        en_w = '0; clr_w = '0; en_o = '0; clr_o = '0;
        for (int h = 0; h < HEIGHT; h++) ifm[h]  = '0;
        for (int w = 0; w < WIDTH;  w++) wght[w] = '0;

        clk_utils.set_clock(2.5);
        clk_utils.do_reset();

        // Phase 1: load stationary weights.
        en_w = '1;
        for (int t = 0; t < HEIGHT; t++) begin
            @(negedge clk);
            for (int w = 0; w < WIDTH; w++) wght[w] = $urandom;
        end
        @(negedge clk);
        en_w = '0;

        // Flush every resetless control/index wavefront (clear, then a clean pass).
        en_o = '1; clr_i = '1; clr_o = '1;
        for (int t = 0; t < FLUSH_CYCLES; t++) drive_phase(t, 1'b1);
        clr_i = '0; clr_o = '0;
        for (int t = 0; t < FLUSH_CYCLES; t++) drive_phase(t, 1'b1);

        @(posedge clk);
        @(negedge clk);
        #0.01;
        for (int w = 0; w < WIDTH; w++) begin
            if ($isunknown(ofm[w]))
                $fatal(1, "[FUNC-FAIL] DUT ofm[%0d] unknown before scored workload", w);
            if ($isunknown(ref_ofm[w][0]))
                $fatal(1, "[FUNC-FAIL] reference ofm[%0d] unknown before scored workload", w);
        end
        check_enable = 1'b1;

        // Phase 2: scored streaming MACs with periodic drain.
        for (int t = 0; t < STIM_CYCLES; t++) begin
            drive_phase(t, 1'b1);
            clr_o = ((t % READOUT_PERIOD) == (READOUT_PERIOD-1)) ? '1 : '0;
        end
        @(negedge clk);
        check_enable = 1'b0;

        if (checked_cycles < STIM_CYCLES)
            $fatal(1, "[FUNC-FAIL] checked only %0d of %0d cycles", checked_cycles, STIM_CYCLES);
        $display("PASS: bit-serial BS array matched reference for %0d cycles", checked_cycles);
        $finish;
    end
endmodule
