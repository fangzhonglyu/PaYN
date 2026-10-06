`timescale 1ns/1ps

// Unit checks of the AF edge blocks against brute-force definitions (no
// closed form, no lane split):
//   (1) CbsgAfKaEncoder, exhaustively: every lane k (8 instances) x phase p x
//       L = 1..128 x b = 0..128 (1,056,768 cases) against
//       kA = #{t < L : ((bitrev8(gray(t)) ^ mask) >> 1) < b},
//       mask = bitrev8((8p + k) mod 64);
//   (2) CbsgAfStreamGen: the registered W words of every cycle of every phase
//       against ((x_k(16c + m) ^ {3'b0, bitrev3(p), 2'b0}) >> 1), x_k the
//       "k"-seed Gray-code Sobol word by index; phase sequencing with
//       slice_start; the IDLE park after 8 cycles; rng_en freezing; restart;
//       the structural slice restart (phase 0 on the first block_start after
//       reset or after a shift_in edge, the drain tail on B+1 ignored).
// Prints UNITS PASS / UNITS FAIL with counts.

`include "payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_stream_gen.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_peripheral.sv"

module TbCbsgAfUnits;
    function automatic int bitrev8(input int x);
        int r = 0;
        for (int i = 0; i < 8; i++)
            if ((x >> i) & 1) r |= 1 << (7 - i);
        return r;
    endfunction

    function automatic int ka_brute(input int b, input int len, input int d);
        int mask = bitrev8(d % 64);
        int n = 0;
        for (int t = 0; t < len; t++) begin
            int g = t ^ (t >> 1);
            if (((bitrev8(g) ^ mask) >> 1) < b) n++;
        end
        return n;
    endfunction

    function automatic int sobol_k(input int idx);
        int dv [8] = '{8'h80, 8'h40, 8'h20, 8'h10, 8'h48, 8'h04, 8'h52, 8'hff};
        int g = idx ^ (idx >> 1);
        int x = 0;
        for (int b = 0; b < 8; b++)
            if ((g >> b) & 1) x ^= dv[b];
        return x;
    endfunction

    //------------------------------------------------------- (1) encoder --
    logic [7:0] enc_b, enc_len;
    logic [2:0] enc_phase;
    logic [7:0] enc_ka [8];

    for (genvar k = 0; k < 8; k++) begin : g_enc
        CbsgAfKaEncoder #(.LANE(k)) u_ka (
            .b(enc_b), .len(enc_len), .phase(enc_phase), .ka(enc_ka[k])
        );
    end

    //---------------------------------------------------- (2) stream gen --
    logic clk = 1'b0, reset = 1'b1;
    logic rng_en = 1'b0, block_start = 1'b0, slice_start = 1'b0, shift_in = 1'b0;
    logic [3:0] cyc;
    logic [2:0] phase;
    logic [16*7-1:0] w_words;

    always #1.25 clk = ~clk;

    CbsgAfStreamGen #(.M(16), .WIDTH(8)) u_rng (
        .clk, .reset, .rng_en, .block_start, .slice_start, .shift_in, .cyc, .phase, .w_words
    );

    int enc_checks = 0, enc_bad = 0;
    int gen_checks = 0, gen_bad = 0;

    task automatic check_words(input int c, input int p, input string what);
        gen_checks++;
        if (cyc !== 4'(c) || phase !== 3'(p)) begin
            gen_bad++;
            if (gen_bad < 10)
                $display("[UNIT-FAIL] %s: cyc=%0d phase=%0d, expected %0d / %0d", what, cyc, phase, c, p);
        end
        if (c < 8)
            for (int m = 0; m < 16; m++) begin
                int pb = ((p & 1) << 2) | (((p >> 1) & 1) << 1) | ((p >> 2) & 1);
                int exp_w = ((sobol_k(16*c + m) ^ (pb << 2)) >> 1) & 8'h7f;
                gen_checks++;
                if (w_words[m*7 +: 7] !== 7'(exp_w)) begin
                    gen_bad++;
                    if (gen_bad < 10)
                        $display("[UNIT-FAIL] %s: c=%0d p=%0d m=%0d word %h expected %h",
                                 what, c, p, m, w_words[m*7 +: 7], exp_w);
                end
            end
    endtask

    task automatic tick();
        @(posedge clk);
        #0.5;
    endtask

    // One edge with the given strobes (launched at the negedge), then check
    // the phase the edge loaded when it was a block_start.
    task automatic edge_with(input bit bs, input bit ss, input bit sh, input int exp_p, input string what);
        @(negedge clk);
        block_start = bs;
        slice_start = ss;
        shift_in = sh;
        tick();
        block_start = 1'b0;
        slice_start = 1'b0;
        shift_in = 1'b0;
        if (bs) check_words(0, exp_p, what);
    endtask

    initial begin
        int p;

        // (1) exhaustive encoder
        for (int ph = 0; ph < 8; ph++)
            for (int len = 1; len <= 128; len++)
                for (int b = 0; b <= 128; b++) begin
                    enc_b = 8'(b);
                    enc_len = 8'(len);
                    enc_phase = 3'(ph);
                    #1;
                    for (int k = 0; k < 8; k++) begin
                        automatic int exp_ka = ka_brute(b, len, 8*ph + k);
                        enc_checks++;
                        if (enc_ka[k] !== 8'(exp_ka)) begin
                            enc_bad++;
                            if (enc_bad < 10)
                                $display("[UNIT-FAIL] kA lane %0d phase %0d L %0d b %0d: %0d, expected %0d",
                                         k, ph, len, b, enc_ka[k], exp_ka);
                        end
                    end
                end
        $display("encoder: %0d cases, %0d mismatches", enc_checks, enc_bad);

        // (2) stream generator
        @(negedge clk);
        reset = 1'b0;
        tick();
        gen_checks++;
        if (cyc !== 4'd8) begin
            gen_bad++;
            $display("[UNIT-FAIL] counter not IDLE after reset (cyc=%0d)", cyc);
        end
        // 20 blocks of 8 cycles: slice starts at blocks 0, 3, 11 (phase reset),
        // otherwise phase + 1 (wraps past 7).
        p = 0;
        for (int blk = 0; blk < 20; blk++) begin
            automatic bit ss = (blk == 0 || blk == 3 || blk == 11);
            p = ss ? 0 : (p + 1) % 8;
            @(negedge clk);
            block_start = 1'b1;
            slice_start = ss;
            rng_en = (blk % 2);               // don't-care on the restart edge
            tick();
            block_start = 1'b0;
            slice_start = 1'b0;
            rng_en = 1'b1;
            check_words(0, p, "restart");
            for (int c = 1; c < 8; c++) begin
                if (blk == 5 && c == 4) begin  // a frozen edge: nothing moves
                    rng_en = 1'b0;
                    tick();
                    check_words(c - 1, p, "frozen");
                    rng_en = 1'b1;
                end
                tick();
                check_words(c, p, "advance");
            end
        end
        // IDLE park: one more advance reaches 8, then it stays.
        tick();
        check_words(8, p, "idle");
        repeat (5) tick();
        check_words(8, p, "idle-hold");
        // Short block then restart mid-stream, with and without slice_start.
        @(negedge clk);
        block_start = 1'b1;
        tick();
        block_start = 1'b0;
        p = (p + 1) % 8;
        check_words(0, p, "restart-from-idle");
        tick();
        tick();
        check_words(2, p, "short");
        @(negedge clk);
        block_start = 1'b1;
        slice_start = 1'b1;
        tick();
        block_start = 1'b0;
        slice_start = 1'b0;
        check_words(0, 0, "restart-mid");
        // Structural slice restart (slice_start low from here on).
        edge_with(1, 0, 0, 1, "no-drain +1");
        edge_with(0, 0, 0, 0, "");
        edge_with(1, 0, 0, 2, "no-drain +1 again");
        // A drain of 8 shift edges, then a block: phase 0; the next block +1.
        edge_with(0, 0, 0, 0, "");
        edge_with(0, 0, 0, 0, "");
        for (int s = 0; s < 8; s++) edge_with(0, 0, 1, 0, "");
        edge_with(1, 0, 0, 0, "after drain");
        edge_with(0, 0, 0, 0, "");
        edge_with(1, 0, 0, 1, "second block after drain");
        // Tightest overlap: S1..S6, block_start on S7, S8 on B+1 (the tail is
        // ignored), next block +1.
        edge_with(0, 0, 0, 0, "");
        edge_with(0, 0, 0, 0, "");
        for (int s = 0; s < 6; s++) edge_with(0, 0, 1, 0, "");
        edge_with(1, 0, 1, 0, "block on S7");
        edge_with(0, 0, 1, 0, "");
        edge_with(0, 0, 0, 0, "");
        edge_with(1, 0, 0, 1, "S8 tail ignored");
        // N_W = 2 overlap: the drain's first shift edge is the block_start edge.
        edge_with(0, 0, 0, 0, "");
        edge_with(1, 0, 1, 0, "shift on B");
        edge_with(0, 0, 1, 0, "");
        edge_with(1, 0, 0, 1, "B+1 tail ignored");
        // A shift on B+2 counts (window Bprev+2 .. B).
        edge_with(0, 0, 0, 0, "");
        edge_with(0, 0, 1, 0, "");
        edge_with(1, 0, 0, 0, "shift on Bprev+2");
        // Back-to-back blocks with no shift keep counting.
        edge_with(1, 0, 0, 1, "back-to-back +1");
        edge_with(1, 0, 0, 2, "back-to-back +1 again");
        // Asynchronous reset mid-block.
        tick();
        #0.2 reset = 1'b1;
        #0.2;
        gen_checks++;
        if (cyc !== 4'd8 || phase !== 3'd0) begin
            gen_bad++;
            $display("[UNIT-FAIL] async reset: cyc=%0d phase=%0d", cyc, phase);
        end
        // After reset a slice restart is pending: the first block runs at
        // phase 0 without slice_start, the next at 1.
        @(negedge clk);
        reset = 1'b0;
        edge_with(0, 0, 0, 0, "");
        edge_with(1, 0, 0, 0, "first block after reset");
        edge_with(1, 0, 0, 1, "second block after reset");
        $display("stream gen: %0d checks, %0d mismatches", gen_checks, gen_bad);

        if (enc_bad == 0 && gen_bad == 0 && enc_checks == 8*128*129*8)
            $display("UNITS PASS: encoder %0d cases, stream gen %0d checks", enc_checks, gen_checks);
        else
            $display("UNITS FAIL: encoder %0d/%0d bad, stream gen %0d/%0d bad",
                     enc_bad, enc_checks, gen_bad, gen_checks);
        $finish;
    end
endmodule
