`timescale 1ns/1ps

// SC-mode isolation lockstep for the bit-plane (BP) INT top.
//
// The accepted carry-save top (payn_array_signed_segmented_csa, "ref_u") and
// the BP top (payn_array_signed_segmented_csa_bp, "dut") run side by side on
// identical SC stimulus with int_mode = 0.  Every clock, 4-state (!==), the
// bench compares acc_out_east, every tile's architectural state (acc_low,
// acc_high, pending carry/borrow), the peripheral stream and sign outputs, and
// the re-exported rails.  BP-only state must stay at its reset value in SC
// mode: ring_q, the combiner registers, int_out / int_out_valid.  (Post-review
// RTL: the combiner's 192-bit input register has no reset term and loads on
// reset edges, so after this bench's one-edge reset it may hold the X
// pre-reset column; it must then hold still and never reach int_out.)
//
// Stimulus: a canonical array block (test_payn_array.sv order), a streaming
// block run (power_payn_array.sv order), then random SC control and data every
// cycle (rng_en, loads, sign loads, mac_en, shift_in, acc_in_west).
//
// Plusargs (all opt-in):
//   +JUNK_RAW    a_raw_in / w_raw_in random at every negedge and 0.4 ns after
//                every posedge
//   +JUNK_PREC   int_prec random, same times
//   +X_RAW       a_raw_in / w_raw_in / int_prec held at X after reset
//   +JUNK_RING   ring_in random, same times (gated by int_mode in the
//                post-review RTL: ring_q must stay 0)
//   +XINIT       every input, int_mode included, X before and through the
//                single reset edge
//   +MODESWITCH  after the first SC session the dut runs an INT session
//                (int_mode = 1, raw planes, ring laps, drains), then a full
//                drain, int_mode = 0 and a second SC session, without reset;
//                tile comparison is suspended during the INT session only.
//                The INT session follows the post-review contract: zero-load
//                of both magnitude banks on entry, INT loads carry zero
//                magnitudes, shift_in on ring-lap edges
//   +NEG_MODE_PULSE  negative control: int_mode = 1 for one random-phase
//                cycle (with +JUNK_RAW the raw planes then reach the tiles);
//                must be reported as a failure
//   +SEED=<n>    stimulus seed (default 1)
//   +RAND_CYCLES=<n>  random SC cycles per session (default 4000)
// Ends with "PASS: BP SC lockstep" or "[LOCKSTEP-FAIL] ..." and $fatal.
//
//   make sim TOP=Top TB=designs/payn/tb/test_payn_array_bp_sc_lockstep.sv USE_DW=1 \
//     SIM_SRCS="<csa top> <bp top>" VCS_ARGS="+define+PAYN_SEG_LOW_W=9 ..."
// (sweeps/int_mode/bp/run_bp_sc_isolation_review.sh runs the whole matrix.)

`ifndef SC_K
`define SC_K 8
`endif
`ifndef SC_M
`define SC_M 16
`endif
`ifndef SC_NH
`define SC_NH 8
`endif
`ifndef SC_NW
`define SC_NW 8
`endif
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_T
`define SC_T 128
`endif
`ifndef PAYN_SEG_LOW_W
`define PAYN_SEG_LOW_W 9
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int WIDTH = 8;
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int LOW_W = `PAYN_SEG_LOW_W;
    localparam int HIGH_W = OWIDTH - LOW_W;
    localparam int T = `SC_T;
    localparam int MAC_CYCLES = T / M;

    logic clk = 1'b0;
    always #1.25 clk = ~clk;

    // Shared SC stimulus.
    logic reset, rng_en, load_a, load_w, load_a_sign, load_w_sign, mac_en, shift_in;
    logic [N_H*K*WIDTH-1:0] a_binary_in;
    logic [N_H*K-1:0]       a_signs_in;
    logic [N_W*K*WIDTH-1:0] w_binary_in;
    logic [N_W*K-1:0]       w_signs_in;
    logic [N_H*OWIDTH-1:0]  acc_in_west;
    // BP-only inputs.
    logic int_mode, int_prec, ring_in;
    logic [N_H*K*M-1:0] a_raw_in;
    logic [N_W*K*M-1:0] w_raw_in;

    logic [N_H*OWIDTH-1:0] acc_out_east_ref, acc_out_east_dut;
    logic [63:0] int_out;
    logic int_out_valid;

    payn_array_signed_segmented_csa #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) ref_u (
        .clk, .reset, .rng_en, .load_a, .load_w, .load_a_sign, .load_w_sign,
        .mac_en, .shift_in, .a_binary_in, .a_signs_in, .w_binary_in,
        .w_signs_in, .acc_in_west, .acc_out_east(acc_out_east_ref)
    );

    payn_array_signed_segmented_csa_bp #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (
        .clk, .reset, .rng_en, .load_a, .load_w, .load_a_sign, .load_w_sign,
        .mac_en, .shift_in, .a_binary_in, .a_signs_in, .w_binary_in,
        .w_signs_in, .acc_in_west, .acc_out_east(acc_out_east_dut),
        .int_mode, .int_prec, .ring_in, .a_raw_in, .w_raw_in,
        .int_out, .int_out_valid
    );

    //------------------------------------------------- per-clock comparison --
    logic [N_H*N_W-1:0] tile_diff;
    for (genvar h = 0; h < N_H; h++) begin : g_cmp_row
        for (genvar v = 0; v < N_W; v++) begin : g_cmp_col
            assign tile_diff[h*N_W + v] =
                (ref_u.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_low !==
                 dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_low) ||
                (ref_u.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_high !==
                 dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_high) ||
                (ref_u.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_carry !==
                 dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_carry) ||
                (ref_u.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_borrow !==
                 dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_borrow);
        end
    end

    bit cmp_on = 1'b0;        // SC equivalence checks armed
    bit bp_idle_on = 1'b0;    // BP-only state must hold still
    bit junk_on = 1'b0;       // SC-session junk drivers armed
    bit opt_junk_raw, opt_junk_prec, opt_x_raw, opt_junk_ring, opt_xinit, opt_modeswitch;
    bit opt_neg_pulse;
    longint n_raw_x = 0, n_raw_change = 0, n_prec_change = 0;
    logic [N_H*K*M-1:0] a_raw_prev;
    logic int_prec_prev;
    int seed, rand_cycles;
    longint n_cmp = 0, n_fail = 0, n_east_fail = 0, n_tile_fail = 0;
    longint n_periph_fail = 0, n_rail_fail = 0, n_bp_fail = 0, n_x_east = 0;
    longint n_ring_hi = 0, n_drain_cycles = 0, n_mac_cycles = 0;
    logic [N_H*OWIDTH-1:0] east_q_hold;
    logic [63:0] int_out_hold;

    task automatic fail(input string what);
        n_fail++;
        if (n_fail <= 20)
            $display("[LOCKSTEP-FAIL] t=%0t %s", $time, what);
    endtask

    // Sample 0.2 ns after each posedge: flops have updated, inputs (changed at
    // the negedge or at posedge + 0.4) are still the ones the edge used.
    always begin
        @(posedge clk);
        #0.2;
        if (cmp_on) begin
            n_cmp++;
            if ($isunknown(a_raw_in) || $isunknown(w_raw_in)) n_raw_x++;
            if (a_raw_in !== a_raw_prev) n_raw_change++;
            if (int_prec !== int_prec_prev) n_prec_change++;
            a_raw_prev = a_raw_in;
            int_prec_prev = int_prec;
            if (shift_in) n_drain_cycles++;
            if (mac_en) n_mac_cycles++;
            if (acc_out_east_ref !== acc_out_east_dut) begin
                n_east_fail++;
                fail($sformatf("acc_out_east ref=%h dut=%h", acc_out_east_ref, acc_out_east_dut));
            end
            if (|tile_diff) begin
                n_tile_fail++;
                fail($sformatf("tile state differs, tile_diff=%h", tile_diff));
            end
            if (ref_u.a_bits !== dut.a_bits || ref_u.w_bits !== dut.w_bits ||
                ref_u.a_signs !== dut.a_signs || ref_u.w_signs !== dut.w_signs) begin
                n_periph_fail++;
                fail("peripheral a_bits/w_bits/signs differ");
            end
            if (ref_u.a_bits_out_nc !== dut.a_bits_out_nc ||
                ref_u.w_bits_out_nc !== dut.w_bits_out_nc ||
                ref_u.a_signs_out_nc !== dut.a_signs_out_nc ||
                ref_u.w_signs_out_nc !== dut.w_signs_out_nc ||
                ref_u.load_a_sign_out_nc !== dut.load_a_sign_out_nc ||
                ref_u.load_w_sign_out_nc !== dut.load_w_sign_out_nc) begin
                n_rail_fail++;
                fail("re-exported rails differ");
            end
            if ($isunknown(acc_out_east_dut)) begin
                n_x_east++;
                fail($sformatf("dut acc_out_east has X: %h", acc_out_east_dut));
            end
        end
        if (bp_idle_on) begin
            if (dut.u_pe.ring_q === 1'b1) n_ring_hi++;
            if (dut.u_pe.ring_q !== 1'b0) begin
                n_bp_fail++;
                fail($sformatf("ring_q = %b in SC mode", dut.u_pe.ring_q));
            end
            if (int_out_valid !== 1'b0 || dut.u_combiner.capture_q !== 1'b0) begin
                n_bp_fail++;
                fail($sformatf("combiner fired in SC mode: valid=%b capture_q=%b",
                               int_out_valid, dut.u_combiner.capture_q));
            end
            if (dut.u_combiner.east_q !== east_q_hold || int_out !== int_out_hold ||
                $isunknown(dut.u_combiner.prec_q)) begin
                n_bp_fail++;
                fail("combiner registers moved or went X in SC mode");
            end
        end
    end

    //------------------------------------------------------- junk drivers --
    task automatic drive_junk();
        if (!junk_on) return;
        if (opt_x_raw) begin
            a_raw_in = 'x;
            w_raw_in = 'x;
            int_prec = 1'bx;
        end else begin
            if (opt_junk_raw) begin
                for (int i = 0; i < N_H*K*M; i++) a_raw_in[i] = $urandom & 1;
                for (int i = 0; i < N_W*K*M; i++) w_raw_in[i] = $urandom & 1;
            end
            if (opt_junk_prec) int_prec = $urandom & 1;
        end
        if (opt_junk_ring) ring_in = $urandom & 1;
    endtask

    always @(negedge clk) drive_junk();
    always begin
        @(posedge clk);
        #0.4;
        drive_junk();
    end

    //---------------------------------------------------------- stimulus --
    task automatic sc_idle();
        rng_en = 1'b0; load_a = 1'b0; load_w = 1'b0;
        load_a_sign = 1'b0; load_w_sign = 1'b0;
        mac_en = 1'b0; shift_in = 1'b0;
    endtask

    task automatic randomize_operands();
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
            w_signs_in[i] = $urandom & 1;
        end
    endtask

    task automatic drain(input bit zero_west);
        acc_in_west = '0;
        if (!zero_west)
            for (int i = 0; i < N_H*OWIDTH; i++) acc_in_west[i] = $urandom & 1;
        shift_in = 1'b1;
        repeat (N_W) @(negedge clk);
        shift_in = 1'b0;
        acc_in_west = '0;
    endtask

    // test_payn_array.sv order: load, sign load, warmup + T MAC cycles, drain.
    task automatic canonical_block();
        randomize_operands();
        load_a = 1'b1; load_w = 1'b1;
        @(negedge clk);
        load_a = 1'b0; load_w = 1'b0;
        load_a_sign = 1'b1; load_w_sign = 1'b1;
        @(negedge clk);
        @(negedge clk);
        load_a_sign = 1'b0; load_w_sign = 1'b0;
        rng_en = 1'b1;
        for (int c = 0; c < 2 + T; c++) begin
            mac_en = (c >= 2);
            @(negedge clk);
        end
        mac_en = 1'b0; rng_en = 1'b0;
        @(negedge clk);
        drain(1'b1);
    endtask

    // power_payn_array.sv order: batches issued two cycles before each block end.
    task automatic streaming_blocks(input int n_batches);
        randomize_operands();
        rng_en = 1'b1;
        load_a = 1'b1; load_w = 1'b1; load_a_sign = 1'b1; load_w_sign = 1'b1;
        @(negedge clk);
        load_a = 1'b0; load_w = 1'b0; load_a_sign = 1'b0; load_w_sign = 1'b0;
        mac_en = 1'b1;
        for (int c = 0, nb = 1; c < n_batches * MAC_CYCLES; c++) begin
            load_a = 1'b0; load_w = 1'b0; load_a_sign = 1'b0; load_w_sign = 1'b0;
            if (((c + 2) % MAC_CYCLES) == 0 && nb < n_batches) begin
                randomize_operands();
                nb++;
                load_a = 1'b1; load_w = 1'b1; load_a_sign = 1'b1; load_w_sign = 1'b1;
            end
            @(negedge clk);
        end
        sc_idle();
        drain(1'b1);
    endtask

    // Random SC control and data every cycle; shift_in also with random west data.
    task automatic random_sc(input int n);
        for (int c = 0; c < n; c++) begin
            rng_en = ($urandom % 100) < 85;
            mac_en = ($urandom % 100) < 70;
            shift_in = ($urandom % 100) < 12;
            load_a = ($urandom % 100) < 15;
            load_w = ($urandom % 100) < 15;
            load_a_sign = ($urandom % 100) < 15;
            load_w_sign = ($urandom % 100) < 15;
            if (($urandom % 4) == 0) randomize_operands();
            for (int i = 0; i < N_H*OWIDTH; i++) acc_in_west[i] = $urandom & 1;
            int_mode = (opt_neg_pulse && c == n/2);
            @(negedge clk);
        end
        sc_idle();
        acc_in_west = '0;
        @(negedge clk);
        drain(1'b1);
    endtask

    task automatic sc_session();
        canonical_block();
        streaming_blocks(16);
        random_sc(rand_cycles);
        canonical_block();
    endtask

    // INT-mode activity on the dut (not checked for INT correctness here; the
    // ref top sees the same SC-port values).  Ends with a full zero drain.
    task automatic int_session();
        int_mode = 1'b1;
        int_prec = $urandom & 1;
        // Post-review contract: magnitude banks zero-loaded on INT entry.
        a_binary_in = '0; w_binary_in = '0;
        load_a = 1'b1; load_w = 1'b1;
        @(negedge clk);
        load_a = 1'b0; load_w = 1'b0;
        for (int blk = 0; blk < 3; blk++) begin
            if (($urandom % 2) == 0) begin
                randomize_operands();
                a_binary_in = '0; w_binary_in = '0;   // INT loads carry signs only
                load_a_sign = 1'b1; load_w_sign = 1'b1; load_a = 1'b1; load_w = 1'b1;
            end
            for (int pass = 0; pass < 4; pass++) begin
                for (int c = 0; c < 6; c++) begin
                    load_a = 1'b0; load_w = 1'b0;
                    if (c == 1) begin load_a_sign = 1'b0; load_w_sign = 1'b0; end
                    mac_en = 1'b1;
                    for (int i = 0; i < N_H*K*M; i++) a_raw_in[i] = $urandom & 1;
                    for (int i = 0; i < N_W*K*M; i++) w_raw_in[i] = $urandom & 1;
                    @(negedge clk);
                end
                mac_en = 1'b0;
                a_raw_in = '0; w_raw_in = '0;
                if (pass != 3) begin
                    // ring_q lags ring_in by one edge; shift_in on the N_W lap edges.
                    ring_in = 1'b1;
                    @(negedge clk);
                    shift_in = 1'b1;
                    repeat (N_W - 1) @(negedge clk);
                    ring_in = 1'b0;
                    @(negedge clk);
                    shift_in = 1'b0;
                end
            end
            @(negedge clk);
            drain(1'b1);
            repeat (3) @(negedge clk);
        end
        // Leave INT mode: everything drained to zero, raw lines left non-zero
        // on purpose, int_prec left as is.
        for (int i = 0; i < N_H*K*M; i++) a_raw_in[i] = $urandom & 1;
        for (int i = 0; i < N_W*K*M; i++) w_raw_in[i] = $urandom & 1;
        @(negedge clk);
        int_mode = 1'b0;
        @(negedge clk);
    endtask

    initial begin
        opt_junk_raw = $test$plusargs("JUNK_RAW");
        opt_junk_prec = $test$plusargs("JUNK_PREC");
        opt_x_raw = $test$plusargs("X_RAW");
        opt_junk_ring = $test$plusargs("JUNK_RING");
        opt_xinit = $test$plusargs("XINIT");
        opt_modeswitch = $test$plusargs("MODESWITCH");
        opt_neg_pulse = $test$plusargs("NEG_MODE_PULSE");
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("RAND_CYCLES=%d", rand_cycles)) rand_cycles = 4000;
        void'($urandom(seed));
        $display("[CFG] K=%0d M=%0d N_H=%0d N_W=%0d LOW_W=%0d T=%0d seed=%0d junk_raw=%0b junk_prec=%0b x_raw=%0b junk_ring=%0b xinit=%0b modeswitch=%0b",
                 K, M, N_H, N_W, LOW_W, T, seed, opt_junk_raw, opt_junk_prec,
                 opt_x_raw, opt_junk_ring, opt_xinit, opt_modeswitch);

        // ---- power-on: everything X (+XINIT) or 0, then a single reset edge --
        if (opt_xinit) begin
            {rng_en, load_a, load_w, load_a_sign, load_w_sign, mac_en, shift_in} = 'x;
            a_binary_in = 'x; a_signs_in = 'x; w_binary_in = 'x; w_signs_in = 'x;
            acc_in_west = 'x;
            int_mode = 1'bx; int_prec = 1'bx; ring_in = 1'bx;
            a_raw_in = 'x; w_raw_in = 'x;
            reset = 1'bx;
        end else begin
            sc_idle();
            a_binary_in = '0; a_signs_in = '0; w_binary_in = '0; w_signs_in = '0;
            acc_in_west = '0;
            int_mode = 1'b0; int_prec = 1'b0; ring_in = 1'b0;
            a_raw_in = '0; w_raw_in = '0;
            reset = 1'b0;
        end
        @(negedge clk);
        @(negedge clk);
        reset = 1'b1;
        @(posedge clk);
        #0.2;
        // One reset edge, inputs possibly X: the BP-only registers must be known 0.
        if (dut.u_pe.ring_q !== 1'b0) fail($sformatf("ring_q=%b after reset edge", dut.u_pe.ring_q));
        if (dut.u_combiner.prec_q !== 1'b0 ||
            dut.u_combiner.capture_q !== 1'b0 || int_out !== '0 || int_out_valid !== 1'b0)
            fail($sformatf("combiner not reset: east_q=%h prec_q=%b capture_q=%b out=%h valid=%b",
                           dut.u_combiner.east_q, dut.u_combiner.prec_q,
                           dut.u_combiner.capture_q, int_out, int_out_valid));
        if ($isunknown(acc_out_east_dut) || $isunknown(acc_out_east_ref))
            fail($sformatf("acc_out_east X after reset edge: ref=%h dut=%h",
                           acc_out_east_ref, acc_out_east_dut));
        if (|tile_diff) fail("tile state differs after reset edge");
        @(negedge clk);
        reset = 1'b0;
        sc_idle();
        a_binary_in = '0; a_signs_in = '0; w_binary_in = '0; w_signs_in = '0;
        acc_in_west = '0;
        int_mode = 1'b0; int_prec = 1'b0; ring_in = 1'b0;
        a_raw_in = '0; w_raw_in = '0;
        east_q_hold = dut.u_combiner.east_q;
        int_out_hold = int_out;
        cmp_on = 1'b1; bp_idle_on = 1'b1; junk_on = 1'b1;
        $display("[INFO] reset done at t=%0t; BP registers ring_q=%b east_q=%0h prec_q=%b capture_q=%b out=%0h valid=%b",
                 $time, dut.u_pe.ring_q, dut.u_combiner.east_q, dut.u_combiner.prec_q,
                 dut.u_combiner.capture_q, int_out, int_out_valid);

        sc_session();

        if (opt_modeswitch) begin
            junk_on = 1'b0; cmp_on = 1'b0; bp_idle_on = 1'b0;
            ring_in = 1'b0;
            int_session();
            // Fully drained, int_mode = 0 for one edge: the two tops must agree
            // again (tiles zero, pipes refilled from the comparators).
            #0.2;
            if (|tile_diff) fail("tile state differs after the INT session's drain");
            east_q_hold = dut.u_combiner.east_q;
            int_out_hold = int_out;
            $display("[INFO] INT session done at t=%0t; combiner holds out=%h (valid=%b)",
                     $time, int_out, int_out_valid);
            @(negedge clk);
            cmp_on = 1'b1; bp_idle_on = 1'b1; junk_on = 1'b1;
            sc_session();
        end

        cmp_on = 1'b0; bp_idle_on = 1'b0; junk_on = 1'b0;
        $display("[STATS] compared %0d clocks (%0d mac_en, %0d shift_in); failures: total %0d, east %0d, tile %0d, periph %0d, rail %0d, bp_idle %0d, dut_east_X %0d; ring_q high %0d clocks; raw X %0d clocks, a_raw changed %0d clocks, int_prec changed %0d clocks",
                 n_cmp, n_mac_cycles, n_drain_cycles, n_fail, n_east_fail, n_tile_fail,
                 n_periph_fail, n_rail_fail, n_bp_fail, n_x_east, n_ring_hi,
                 n_raw_x, n_raw_change, n_prec_change);
        if (n_fail != 0)
            $fatal(1, "[LOCKSTEP-FAIL] %0d failing checks", n_fail);
        $display("PASS: BP SC lockstep");
        $finish;
    end
endmodule
