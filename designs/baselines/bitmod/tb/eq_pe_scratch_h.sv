`timescale 1ns/1ps

`include "common/clk_util.sv"

// Equivalence bench: pe_scratch (bitmod_pe.sv, the migrated upstream PE) vs pe_scratch_h (bitmod_pe_h.sv, the same
// logic split into submodules for area / power breakdowns).  Both get identical random inputs every cycle --
// activations, weight terms, bsig (mostly one-hot, sometimes arbitrary), stage valids, last, scale bits and the four
// gated-clock enables through the design's own tech_icg -- and every pipeline register and both outputs are
// compared X-exactly (!==) every cycle.  Any difference is fatal.

`include "baselines/bitmod/bitmod_pe.sv"
`include "baselines/bitmod/bitmod_pe_h.sv"

`ifndef EQ_CYCLES
`define EQ_CYCLES 200000
`endif
`ifndef EQ_SEED
`define EQ_SEED 32'h5EED_B17D
`endif

module Top;
    localparam int CYCLES = `EQ_CYCLES;
    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(CYCLES + 1000)) clk_utils (.clk, .reset, .timeout);

    logic[3:0][15:0] a = '0;
    logic[3:0][3:0]  w_sem = '0;
    logic            s1_vld = 1'b0;
    logic[4:0]       s1_bsig_1hot = 5'b00001;
    logic            s2_vld = 1'b0, s2_last = 1'b0;
    logic            s4_load = 1'b1, s4_scale_bit = 1'b0;
    logic            en_s3 = 1'b0, en_s4_0 = 1'b0, en_s4_1 = 1'b0, en_o = 1'b0;
    logic            gclk_s3, gclk_s4_0, gclk_s4_1, gclk_o;

    tech_icg icg_s3   (.clk(clk), .en(en_s3),   .gclk(gclk_s3));
    tech_icg icg_s4_0 (.clk(clk), .en(en_s4_0), .gclk(gclk_s4_0));
    tech_icg icg_s4_1 (.clk(clk), .en(en_s4_1), .gclk(gclk_s4_1));
    tech_icg icg_o    (.clk(clk), .en(en_o),    .gclk(gclk_o));

    logic[5:0]  o_exp_r, o_exp_h;
    logic[22:0] o_man_r, o_man_h;

    pe_scratch ref_pe (
        .clk, .gclk_s3, .gclk_s4_0, .gclk_s4_1, .gclk_o, .a, .w_sem, .s1_vld, .s1_bsig_1hot,
        .s2_vld, .s2_last, .s4_load, .s4_scale_bit, .o_exp(o_exp_r), .o_man(o_man_r));
    pe_scratch_h hier_pe (
        .clk, .gclk_s3, .gclk_s4_0, .gclk_s4_1, .gclk_o, .a, .w_sem, .s1_vld, .s1_bsig_1hot,
        .s2_vld, .s2_last, .s4_load, .s4_scale_bit, .o_exp(o_exp_h), .o_man(o_man_h));

    int compares = 0, known_cycles = 0, cycle = 0;
    bit armed = 1'b0;

    `define EQ_CHECK(R, H) \
        compares++; \
        if ((R) !== (H)) $fatal(1, "[EQ-FAIL] cycle %0d: %s = %h but %s = %h", cycle, `"R`", (R), `"H`", (H));

    always @(negedge clk) if (armed) begin
        `EQ_CHECK(ref_pe.s1_exp_max, hier_pe.u_align.s1_exp_max)
        `EQ_CHECK(ref_pe.s1_dir,     hier_pe.u_align.s1_dir)
        `EQ_CHECK(ref_pe.s1_mag,     hier_pe.u_align.s1_mag)
        `EQ_CHECK(ref_pe.s1_sum0,    hier_pe.u_pairadd.s1_sum0)
        `EQ_CHECK(ref_pe.s1_sum1,    hier_pe.u_pairadd.s1_sum1)
        `EQ_CHECK(ref_pe.s2_exp_max, hier_pe.u_merge.s2_exp_max)
        `EQ_CHECK(ref_pe.s2_sum,     hier_pe.u_merge.s2_sum)
        `EQ_CHECK(ref_pe.s2_dir,     hier_pe.u_acc.s2_dir)
        `EQ_CHECK(ref_pe.s2_mag,     hier_pe.u_acc.s2_mag)
        `EQ_CHECK(ref_pe.s3_man,     hier_pe.u_acc.s3_man)
        `EQ_CHECK(ref_pe.s3_exp,     hier_pe.u_acc.s3_exp)
        `EQ_CHECK(ref_pe.s4_man,     hier_pe.u_norm.s4_man)
        `EQ_CHECK(ref_pe.s4_exp,     hier_pe.u_norm.s4_exp)
        `EQ_CHECK(ref_pe.s4_acc,     hier_pe.u_scale.s4_acc)
        `EQ_CHECK(o_exp_r,           o_exp_h)
        `EQ_CHECK(o_man_r,           o_man_h)
        if (!$isunknown({ref_pe.s3_man, ref_pe.s4_acc, o_man_r, o_exp_r})) known_cycles++;
    end

    initial begin
        void'($urandom(`EQ_SEED));
        clk_utils.set_clock(2.5);
        clk_utils.do_reset();
        armed = 1'b1;
        for (cycle = 0; cycle < CYCLES; cycle++) begin
            @(negedge clk);
            #0.01;
            for (int l = 0; l < 4; l++) begin
                a[l]     = 16'($urandom);
                w_sem[l] = 4'($urandom);
            end
            s1_vld       = 1'($urandom);
            s1_bsig_1hot = ($urandom_range(0, 9) < 8) ? (5'b00001 << $urandom_range(0, 4)) : 5'($urandom);
            s2_vld       = ($urandom_range(0, 3) != 0);
            s2_last      = ($urandom_range(0, 7) == 0);
            s4_load      = ($urandom_range(0, 7) == 0);
            s4_scale_bit = 1'($urandom);
            en_s3        = ($urandom_range(0, 3) != 0);
            en_s4_0      = ($urandom_range(0, 3) == 0);
            en_s4_1      = ($urandom_range(0, 1) == 0);
            en_o         = ($urandom_range(0, 3) == 0);
        end
        @(negedge clk);
        if (known_cycles < CYCLES / 2)
            $fatal(1, "[EQ-FAIL] only %0d of %0d cycles had known accumulator state; stimulus too weak", known_cycles, CYCLES);
        $display("PASS: pe_scratch_h equivalent to pe_scratch over %0d random cycles (%0d register/output comparisons, %0d cycles with fully known accumulator state)",
                 CYCLES, compares, known_cycles);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
