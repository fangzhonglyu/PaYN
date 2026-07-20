// Cycle-accurate RTL preflight for the binary-parallel power workload.
//
// This bench deliberately matches power_array_8.sv's parameters, reset,
// weight-load sequence, flush, streaming interval, and clear cadence.  The
// reference below is a flat state model of the array pipelines; it does not
// inspect DUT hierarchy.

`include "common/clk_util.sv"
`include "common/defines.sv"
`include "baselines/binary_parallel/array_8.sv"

`timescale 1ns/1ps

`ifndef BP_INPUT_BITS
`define BP_INPUT_BITS 8
`endif

module Top;
    localparam int STIM_CYCLES    = 4096;
    localparam int READOUT_PERIOD = 64;
    localparam int HEIGHT         = 8;
    localparam int WIDTH          = 8;
    localparam int IWIDTH         = 8;
    localparam int INPUT_BITS     = `BP_INPUT_BITS;
    localparam int OWIDTH         = 24;
    localparam int FLUSH_CYCLES   = HEIGHT + WIDTH + 2;

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(STIM_CYCLES + 1024)) clk_utils (
        .clk(clk), .reset(reset), .timeout(timeout)
    );
    wire rst_n = ~reset;

    logic [HEIGHT-1:0] en_i, clr_i;
    logic [WIDTH-1:0]  en_w, clr_w, en_o, clr_o;
    logic [HEIGHT*IWIDTH-1:0] ifm_flat;
    logic [WIDTH*IWIDTH-1:0]  wght_flat;
    logic [WIDTH*OWIDTH-1:0]  ofm_flat;

    logic signed [IWIDTH-1:0] ifm [HEIGHT-1:0];
    logic signed [IWIDTH-1:0] wght [WIDTH-1:0];
    logic signed [OWIDTH-1:0] ofm [WIDTH-1:0];

    genvar gh, gw;
    generate
        for (gh = 0; gh < HEIGHT; gh++)
            assign ifm[gh] = ifm_flat[gh*IWIDTH +: IWIDTH];
        for (gw = 0; gw < WIDTH; gw++) begin
            assign wght[gw] = wght_flat[gw*IWIDTH +: IWIDTH];
            assign ofm_flat[gw*OWIDTH +: OWIDTH] = ofm[gw];
        end
    endgenerate

    array_8 #(
        .HEIGHT(HEIGHT), .WIDTH(WIDTH),
        .IWIDTH(IWIDTH), .OWIDTH(OWIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .en_i(en_i), .clr_i(clr_i),
        .en_w(en_w), .clr_w(clr_w),
        .en_o(en_o), .clr_o(clr_o),
        .ifm(ifm), .wght(wght), .ofm(ofm)
    );

    // Reference state at each PE output.  Control state intentionally has no
    // reset, matching pe_border/pe_inner; the workload flush must make it known.
    logic ref_en_i  [HEIGHT-1:0][WIDTH-1:0];
    logic ref_clr_i [HEIGHT-1:0][WIDTH-1:0];
    logic ref_en_w  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_w [WIDTH-1:0][HEIGHT-1:0];
    logic ref_en_o  [WIDTH-1:0][HEIGHT-1:0];
    logic ref_clr_o [WIDTH-1:0][HEIGHT-1:0];
    logic signed [IWIDTH-1:0] ref_ifm [HEIGHT-1:0][WIDTH-1:0];
    logic signed [IWIDTH-1:0] ref_wght [WIDTH-1:0][HEIGHT-1:0];
    logic signed [OWIDTH-1:0] ref_ofm [WIDTH-1:0][HEIGHT-1:0];
    bit check_enable = 1'b0;
    int checked_cycles = 0;

    function automatic logic [HEIGHT*IWIDTH-1:0] random_ifm_vector();
        logic [HEIGHT*IWIDTH-1:0] raw;
        logic signed [INPUT_BITS-1:0] narrow;
        logic signed [IWIDTH-1:0] extended;
        begin
            raw = {$urandom, $urandom};
            for (int lane = 0; lane < HEIGHT; lane++) begin
                narrow = raw[lane*IWIDTH +: INPUT_BITS];
`ifdef BP_ALL_POSITIVE
                narrow[INPUT_BITS-1] = 1'b0;
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
                narrow[INPUT_BITS-1] = 1'b0;
`endif
                extended = narrow;
                random_wght_vector[lane*IWIDTH +: IWIDTH] = extended;
            end
        end
    endfunction

    function automatic logic signed [OWIDTH-1:0] product_ext(
        input logic signed [IWIDTH-1:0] a,
        input logic signed [IWIDTH-1:0] b
    );
        logic signed [2*IWIDTH-1:0] product;
        begin
            product = a * b;
            product_ext = {{(OWIDTH-2*IWIDTH){product[2*IWIDTH-1]}}, product};
        end
    endfunction

    // The RTL forwards all enables and clears through resetless flops.
    always @(posedge clk) begin
        for (int h = 0; h < HEIGHT; h++) begin
            for (int w = 0; w < WIDTH; w++) begin
                ref_en_i[h][w] <= (w == 0) ? en_i[h] : ref_en_i[h][w-1];
                ref_clr_i[h][w] <= (w == 0) ? clr_i[h] : ref_clr_i[h][w-1];
            end
        end
        for (int w = 0; w < WIDTH; w++) begin
            for (int h = 0; h < HEIGHT; h++) begin
                ref_en_w[w][h] <= (h == 0) ? en_w[w] : ref_en_w[w][h-1];
                ref_clr_w[w][h] <= (h == 0) ? clr_w[w] : ref_clr_w[w][h-1];
                ref_en_o[w][h] <= (h == HEIGHT-1) ? en_o[w] : ref_en_o[w][h+1];
                ref_clr_o[w][h] <= (h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1];
            end
        end
    end

    // Datapath reference uses the old pipeline state on every active edge,
    // matching the DUT's nonblocking register updates.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int h = 0; h < HEIGHT; h++)
                for (int w = 0; w < WIDTH; w++)
                    ref_ifm[h][w] <= '0;
            for (int w = 0; w < WIDTH; w++) begin
                for (int h = 0; h < HEIGHT; h++) begin
                    ref_wght[w][h] <= '0;
                    ref_ofm[w][h] <= '0;
                end
            end
        end else begin
            for (int h = 0; h < HEIGHT; h++) begin
                for (int w = 0; w < WIDTH; w++) begin
                    if ((w == 0) ? clr_i[h] : ref_clr_i[h][w-1])
                        ref_ifm[h][w] <= '0;
                    else if ((w == 0) ? en_i[h] : ref_en_i[h][w-1])
                        ref_ifm[h][w] <= (w == 0) ? ifm[h] : ref_ifm[h][w-1];
                end
            end

            for (int w = 0; w < WIDTH; w++) begin
                for (int h = 0; h < HEIGHT; h++) begin
                    if ((h == 0) ? clr_w[w] : ref_clr_w[w][h-1])
                        ref_wght[w][h] <= '0;
                    else if ((h == 0) ? en_w[w] : ref_en_w[w][h-1])
                        ref_wght[w][h] <= (h == 0) ? wght[w] : ref_wght[w][h-1];

                    if ((h == HEIGHT-1) ? clr_o[w] : ref_clr_o[w][h+1])
                        ref_ofm[w][h] <= '0;
                    else if ((h == HEIGHT-1) ? en_o[w] : ref_en_o[w][h+1])
                        ref_ofm[w][h] <= product_ext(ref_ifm[h][w], ref_wght[w][h])
                            + ((h == HEIGHT-1) ? '0 : ref_ofm[w][h+1]);
                end
            end
        end
    end

    // Compare after the posedge NBA updates and before the next stimulus change.
    always @(negedge clk) begin
        if (check_enable) begin
            for (int w = 0; w < WIDTH; w++) begin
                if (ofm[w] !== ref_ofm[w][0]) begin
                    $fatal(1,
                        "[FUNC-FAIL] cycle=%0d column=%0d got=%0d (%h) expected=%0d (%h)",
                        checked_cycles, w, $signed(ofm[w]), ofm[w],
                        $signed(ref_ofm[w][0]), ref_ofm[w][0]);
                end
            end
            checked_cycles++;
        end
    end

    initial begin
        if (INPUT_BITS < 1 || INPUT_BITS > IWIDTH)
            $fatal(1, "BP_INPUT_BITS=%0d must be in [1,%0d]", INPUT_BITS, IWIDTH);
        en_i = '0; clr_i = '0;
        en_w = '0; clr_w = '0;
        en_o = '0; clr_o = '0;
        ifm_flat = '0; wght_flat = '0;

        clk_utils.set_clock(2.5);
        clk_utils.do_reset();

        en_w = '1;
        for (int unsigned t = 0; t < HEIGHT; t++) begin
            @(negedge clk);
            wght_flat = random_wght_vector();
        end
        @(negedge clk);
        en_w = '0;

        en_i = '1; clr_i = '1;
        en_o = '1; clr_o = '1;
        for (int unsigned t = 0; t < FLUSH_CYCLES; t++) begin
            @(negedge clk);
            ifm_flat = random_ifm_vector();
        end
        clr_i = '0;
        clr_o = '0;
        for (int unsigned t = 0; t < FLUSH_CYCLES; t++) begin
            @(negedge clk);
            ifm_flat = random_ifm_vector();
        end

        @(posedge clk);
        @(negedge clk);
        #0.01;
        if ($isunknown(ofm_flat))
            $fatal(1, "[FUNC-FAIL] unknown state before scored workload");
        for (int w = 0; w < WIDTH; w++)
            if ($isunknown(ref_ofm[w][0]))
                $fatal(1, "[FUNC-FAIL] reference output %0d unknown before workload", w);
        check_enable = 1'b1;

        for (int unsigned t = 0; t < STIM_CYCLES; t++) begin
            @(negedge clk);
            #0.01;
            ifm_flat = random_ifm_vector();
            clr_o = ((t % READOUT_PERIOD) == (READOUT_PERIOD-1)) ? '1 : '0;
        end
        @(negedge clk);
        #0.01;
        check_enable = 1'b0;

        if (checked_cycles < STIM_CYCLES)
            $fatal(1, "[FUNC-FAIL] checked only %0d workload cycles", checked_cycles);
        $display("PASS: signed int%0d BP8 RTL power workload matched for %0d cycles",
                 INPUT_BITS, checked_cycles);
        $finish;
    end
endmodule
