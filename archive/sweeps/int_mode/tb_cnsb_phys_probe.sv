`timescale 1ns/1ps

// RTL checks for the CNSB physical/timing review (new file; nothing accepted
// is edited).
//   1. Sobol preset probe: with int_preset=0 the preset banks are bit-identical
//      to the accepted banks; one int_preset cycle with rng_en=0 loads the
//      searched constants, rng_en=0 then holds them; reset restores SC.
//   2. East combiner probe (input-registered): out = 16*s(q=1) + s(q=0) with
//      s = T0 + 4T1 + 16T2 + 64T3 per group.
//   3. INT-mode X hazard on the accepted CSA single-PE array: with
//      load_a/load_w/load_*_sign held high (INT schedule), zero codes, and one
//      undriven (X) sign cycle on the port, the accumulators go X; the same X
//      while the loads are low (SC schedule) is harmless.

`include "payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv"
`include "../sweeps/int_mode/cnsb_phys_probe.sv"

module Top;
    localparam int K = 8, M = 16, NH = 8, NW = 8, WIDTH = 8, OW = 24;
    logic clk = 1'b0;
    always #1.25 clk = ~clk;

    // ------------------------------------------------------------ 1. Sobol --
    logic reset = 1'b0, rng_en = 1'b0, int_preset = 1'b0;
    logic [127:0] a_base, w_base, a_pre, w_pre;
    cnsb_sobol_pair_base u_base (.clk, .reset, .rng_en,
        .a_random_values(a_base), .w_random_values(w_base));
    cnsb_sobol_pair_preset u_pre (.clk, .reset, .rng_en, .int_preset,
        .a_random_values(a_pre), .w_random_values(w_pre));
    localparam logic [127:0] PROW = {
        8'd139, 8'd155, 8'd207, 8'd250, 8'd40, 8'd148, 8'd44, 8'd253,
        8'd93, 8'd142, 8'd27, 8'd159, 8'd173, 8'd109, 8'd112, 8'd184};
    localparam logic [127:0] PCOL = {
        8'd37, 8'd75, 8'd91, 8'd96, 8'd181, 8'd190, 8'd95, 8'd146,
        8'd9, 8'd152, 8'd147, 8'd229, 8'd246, 8'd204, 8'd203, 8'd243};

    // --------------------------------------------------------- 2. combiner --
    logic c_reset = 1'b0, drain_en = 1'b0, q_hi = 1'b0;
    logic [8*OW-1:0] east = '0;
    logic [71:0] cout;
    logic cvalid;
    cnsb_east_combiner #(.IN_REG(1'b1)) u_comb (.clk, .reset(c_reset), .drain_en,
        .q_hi, .acc_out_east(east), .out(cout), .out_valid(cvalid));

    // ------------------------------------------------------- 3. CSA array --
    logic a_reset = 1'b0, a_rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic [NH*K*WIDTH-1:0] a_binary_in = '0;
    logic [NW*K*WIDTH-1:0] w_binary_in = '0;
    logic [NH*K-1:0] a_signs_in = '0;
    logic [NW*K-1:0] w_signs_in = '0;
    logic [NH*OW-1:0] acc_in_west = '0;
    logic [NH*OW-1:0] acc_out_east;
    payn_array_signed_segmented_csa #(.K(K), .M(M), .N_H(NH), .N_W(NW),
        .OWIDTH(OW), .LOW_W(9)) u_arr (.clk, .reset(a_reset), .rng_en(a_rng_en),
        .load_a, .load_w, .load_a_sign, .load_w_sign, .mac_en, .shift_in,
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in, .acc_in_west,
        .acc_out_east);

    function automatic int unsigned count_x_tiles();
        int unsigned n = 0;
        for (int h = 0; h < NH; h++)
            if ($isunknown(acc_out_east[h*OW +: OW])) n++;
        return n;
    endfunction

    // Drain one full PE row set (8 shifts) and count X values seen at the tail.
    task automatic drain_count_x(output int unsigned nx);
        nx = 0;
        shift_in = 1'b1;
        for (int s = 0; s < NW; s++) begin
            nx += count_x_tiles();
            @(posedge clk); #0.05; @(negedge clk);
        end
        shift_in = 1'b0;
    endtask

    int errors = 0;
    initial begin
        int unsigned nx;
        longint signed tv [8];
        longint signed s_hi [2], s_lo [2], exp_out;

        // ---- 1. Sobol ----
        @(negedge clk); reset = 1'b1; repeat (2) @(negedge clk); reset = 1'b0;
        rng_en = 1'b1;
        for (int c = 0; c < 300; c++) begin
            @(posedge clk); #0.05;
            if (a_pre !== a_base || w_pre !== w_base) begin
                errors++; $display("FAIL sobol SC mismatch at cycle %0d", c);
            end
            @(negedge clk);
        end
        rng_en = 1'b0; int_preset = 1'b1;
        @(posedge clk); #0.05;
        if (a_pre !== PROW || w_pre !== PCOL) begin
            errors++; $display("FAIL preset not loaded in one cycle with rng_en=0");
        end
        @(negedge clk); int_preset = 1'b0;
        repeat (50) begin
            @(posedge clk); #0.05;
            if (a_pre !== PROW || w_pre !== PCOL) begin
                errors++; $display("FAIL preset not held with rng_en=0");
            end
            @(negedge clk);
        end
        reset = 1'b1; @(negedge clk); reset = 1'b0; rng_en = 1'b1;
        for (int c = 0; c < 300; c++) begin
            @(posedge clk); #0.05;
            if (a_pre !== a_base || w_pre !== w_base) begin
                errors++; $display("FAIL sobol SC mismatch after reset at cycle %0d", c);
            end
            @(negedge clk);
        end
        rng_en = 1'b0;
        $display("CHECK1 Sobol preset probe done, errors=%0d", errors);

        // ---- 2. combiner ----
        c_reset = 1'b1; @(negedge clk); c_reset = 1'b0;
        for (int trial = 0; trial < 200; trial++) begin
            // q=1 step
            for (int h = 0; h < 8; h++) begin
                tv[h] = longint'($signed($urandom)) % 4000000;
                if (trial < 2) tv[h] = (trial == 0) ? -(1 << 23) : (1 << 23) - 1;
                east[h*OW +: OW] = OW'(tv[h]);
            end
            for (int i = 0; i < 2; i++)
                s_hi[i] = tv[4*i] + 4*tv[4*i+1] + 16*tv[4*i+2] + 64*tv[4*i+3];
            drain_en = 1'b1; q_hi = 1'b1;
            @(posedge clk); @(negedge clk);
            for (int h = 0; h < 8; h++) begin
                tv[h] = longint'($signed($urandom)) % 4000000;
                if (trial < 2) tv[h] = (trial == 0) ? -(1 << 23) : (1 << 23) - 1;
                east[h*OW +: OW] = OW'(tv[h]);
            end
            for (int i = 0; i < 2; i++)
                s_lo[i] = tv[4*i] + 4*tv[4*i+1] + 16*tv[4*i+2] + 64*tv[4*i+3];
            q_hi = 1'b0;
            @(posedge clk); @(negedge clk);
            drain_en = 1'b0;
            @(posedge clk); @(negedge clk);   // input register adds one stage
            @(posedge clk); #0.05;
            for (int i = 0; i < 2; i++) begin
                exp_out = 16*s_hi[i] + s_lo[i];
                if ($signed(cout[i*36 +: 36]) !== 36'(exp_out)) begin
                    errors++;
                    $display("FAIL combiner trial %0d grp %0d exp %0d got %0d",
                             trial, i, exp_out, $signed(cout[i*36 +: 36]));
                end
            end
            @(negedge clk);
        end
        $display("CHECK2 combiner probe done, errors=%0d", errors);

        // ---- 3. X hazard on the real CSA array ----
        @(negedge clk); a_reset = 1'b1; repeat (3) @(negedge clk); a_reset = 1'b0;
        // (a) INT schedule, all-defined zero padding: accumulators stay known 0
        load_a = 1'b1; load_w = 1'b1; load_a_sign = 1'b1; load_w_sign = 1'b1;
        a_signs_in = '1; w_signs_in = '0;          // negative lanes, zero counts
        repeat (4) @(negedge clk);
        mac_en = 1'b1;
        repeat (20) @(negedge clk);
        mac_en = 1'b0;
        drain_count_x(nx);
        $display("CHECK3a INT schedule, defined zero padding: X values drained = %0d", nx);
        if (nx != 0) errors++;
        // (b) INT schedule, one undriven sign cycle on the A port, zero codes
        mac_en = 1'b1;
        repeat (5) @(negedge clk);
        a_signs_in = 'x;
        @(negedge clk);
        a_signs_in = '0;
        repeat (10) @(negedge clk);
        mac_en = 1'b0;
        drain_count_x(nx);
        $display("CHECK3b INT schedule, one X sign cycle (zero codes): X values drained = %0d (expect >0: hazard)", nx);
        if (nx == 0) errors++;
        // (c) SC schedule: loads low, same X on the bus is never captured
        @(negedge clk); a_reset = 1'b1; repeat (3) @(negedge clk); a_reset = 1'b0;
        a_signs_in = '0;
        load_a = 1'b1; load_w = 1'b1; load_a_sign = 1'b1; load_w_sign = 1'b1;
        @(negedge clk);
        load_a = 1'b0; load_w = 1'b0; load_a_sign = 1'b0; load_w_sign = 1'b0;
        repeat (3) @(negedge clk);
        mac_en = 1'b1;
        repeat (5) @(negedge clk);
        a_signs_in = 'x;
        @(negedge clk);
        a_signs_in = '0;
        repeat (10) @(negedge clk);
        mac_en = 1'b0;
        drain_count_x(nx);
        $display("CHECK3c SC schedule, same X sign cycle with loads low: X values drained = %0d", nx);
        if (nx != 0) errors++;

        if (errors == 0) $display("PASS: cnsb physical probes");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
