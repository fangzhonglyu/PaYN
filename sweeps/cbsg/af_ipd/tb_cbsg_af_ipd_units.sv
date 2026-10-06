`timescale 1ns/1ps

// Unit bench of the C-BSG AF + IPD variant (signed_segmented_csa_cbsg_af_ipd).
// Parts (1) and (2) are sweeps/cbsg/af/tb_cbsg_af_units.sv with the module
// names renamed to the copies (sweeps/cbsg/af_ipd/rename_af_ipd.pl), run
// unchanged on the copies; parts (3) and (4) are new:
//   (3) INT silence: CbsgAfKaEncoderAfIpd with b = 0 gives kA = 0 for every
//       L = 0..255 (garbage L included), phase and lane; CbsgAfPeripheralAfIpd
//       loaded with zero magnitudes (random signs, random L 0..255) gives
//       sc_a_bits = sc_w_bits = 0 for every cyc 0..15, phase 0..7 and random W
//       words, and in INT select a_bits / w_bits equal the raw planes exactly;
//       (3c) CbsgAfKaEncoderAfIpd with L = 0 gives kA = 0 for every b 0..255,
//       phase and lane (the 64-AND2 A-side gate point quoted in the
//       peripheral header; counted separately as "L=0 gate point");
//   (4) SC transparency of the copy: CbsgAfPeripheralAfIpd against the original
//       CbsgAfPeripheral (../signed_segmented_csa_cbsg_af) on random loads
//       (magnitudes 0..255, L 0..255), cyc, phase and W words with random raw
//       planes: with int_mode = 0 every output bit and kA are equal; with
//       int_mode = 1 a_bits / w_bits = original | raw.
// Below: the original bench's description (parts 1-2).
//
// Unit checks of the AF edge blocks against brute-force definitions (no
// closed form, no lane split):
//   (1) CbsgAfKaEncoderAfIpd, exhaustively: every lane k (8 instances) x phase p x
//       L = 1..128 x b = 0..128 (1,056,768 cases) against
//       kA = #{t < L : ((bitrev8(gray(t)) ^ mask) >> 1) < b},
//       mask = bitrev8((8p + k) mod 64);
//   (2) CbsgAfStreamGenAfIpd: the registered W words of every cycle of every phase
//       against ((x_k(16c + m) ^ {3'b0, bitrev3(p), 2'b0}) >> 1), x_k the
//       "k"-seed Gray-code Sobol word by index; phase sequencing with
//       slice_start; the IDLE park after 8 cycles; rng_en freezing; restart;
//       the structural slice restart (phase 0 on the first block_start after
//       reset or after a shift_in edge, the drain tail on B+1 ignored).
// Prints UNITS PASS / UNITS FAIL with counts.

`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/cbsg_af_ipd_stream_gen.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/cbsg_af_ipd_peripheral.sv"
`include "payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_peripheral.sv"

module TbCbsgAfIpdUnits;
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
        CbsgAfKaEncoderAfIpd #(.LANE(k)) u_ka (
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

    CbsgAfStreamGenAfIpd #(.M(16), .WIDTH(8)) u_rng (
        .clk, .reset, .rng_en, .block_start, .slice_start, .shift_in, .cyc, .phase, .w_words
    );

    int enc_checks = 0, enc_bad = 0;
    int gen_checks = 0, gen_bad = 0;

    //------------------------------ (3)/(4) peripheral: copy vs original --
    localparam int PK = 8, PM = 16, PNH = 8, PNW = 8, PWD = 8;
    logic pclk = 1'b0, prst = 1'b1, p_load_a = 1'b0, p_load_w = 1'b0;
    logic [PNH*PK*PWD-1:0] p_a_bin = '0;
    logic [PNH*PK-1:0]     p_a_sgn = '0;
    logic [PNH*PWD-1:0]    p_a_len = '0;
    logic [PNW*PK*PWD-1:0] p_w_bin = '0;
    logic [PNW*PK-1:0]     p_w_sgn = '0;
    logic [3:0] p_cyc = '0;
    logic [2:0] p_phase = '0;
    logic [PM*7-1:0] p_words = '0;
    logic p_int = 1'b0;
    logic [PNH*PK*PM-1:0] p_a_raw = '0;
    logic [PNW*PK*PM-1:0] p_w_raw = '0;
    logic [PNH*PK*PM-1:0] n_a_bits, o_a_bits;
    logic [PNW*PK*PM-1:0] n_w_bits, o_w_bits;
    logic [PNH*PK-1:0] n_a_sgn, o_a_sgn;
    logic [PNW*PK-1:0] n_w_sgn, o_w_sgn;

    CbsgAfPeripheralAfIpd #(.K(PK), .M(PM), .N_H(PNH), .N_W(PNW), .WIDTH(PWD)) u_per_new (
        .clk(pclk), .reset(prst), .load_a(p_load_a), .load_w(p_load_w),
        .a_binary_in(p_a_bin), .a_signs_in(p_a_sgn), .a_len_in(p_a_len),
        .w_binary_in(p_w_bin), .w_signs_in(p_w_sgn),
        .cyc(p_cyc), .phase(p_phase), .w_words(p_words),
        .int_mode(p_int), .a_raw_in(p_a_raw), .w_raw_in(p_w_raw),
        .a_bits(n_a_bits), .a_signs(n_a_sgn), .w_bits(n_w_bits), .w_signs(n_w_sgn)
    );
    CbsgAfPeripheral #(.K(PK), .M(PM), .N_H(PNH), .N_W(PNW), .WIDTH(PWD)) u_per_orig (
        .clk(pclk), .reset(prst), .load_a(p_load_a), .load_w(p_load_w),
        .a_binary_in(p_a_bin), .a_signs_in(p_a_sgn), .a_len_in(p_a_len),
        .w_binary_in(p_w_bin), .w_signs_in(p_w_sgn),
        .cyc(p_cyc), .phase(p_phase), .w_words(p_words),
        .a_bits(o_a_bits), .a_signs(o_a_sgn), .w_bits(o_w_bits), .w_signs(o_w_sgn)
    );

    int sil_checks = 0, sil_bad = 0;      // (3)
    int lz_checks = 0, lz_bad = 0;        // (3c)
    int eq_checks = 0, eq_bad = 0;        // (4)

    task automatic p_load(input bit zero_mag);
        for (int i = 0; i < PNH*PK; i++) begin
            p_a_bin[i*PWD +: PWD] = zero_mag ? 8'd0 : (($urandom & 3) ? 8'($urandom_range(0, 128)) : 8'($urandom));
            p_a_sgn[i] = $urandom & 1;
        end
        for (int h = 0; h < PNH; h++) p_a_len[h*PWD +: PWD] = 8'($urandom);
        for (int i = 0; i < PNW*PK; i++) begin
            p_w_bin[i*PWD +: PWD] = zero_mag ? 8'd0 : (($urandom & 3) ? 8'($urandom_range(0, 128)) : 8'($urandom));
            p_w_sgn[i] = $urandom & 1;
        end
        p_load_a = 1'b1;
        p_load_w = 1'b1;
        #1 pclk = 1'b1;
        #1 pclk = 1'b0;
        p_load_a = 1'b0;
        p_load_w = 1'b0;
    endtask

    task automatic p_random_view();
        for (int n = 0; n < PM*7; n++) p_words[n] = $urandom & 1;
        for (int n = 0; n < PNH*PK*PM; n++) p_a_raw[n] = $urandom & 1;
        for (int n = 0; n < PNW*PK*PM; n++) p_w_raw[n] = $urandom & 1;
    endtask

    task automatic p_check_eq(input string what);
        #1;
        eq_checks++;
        if (p_int == 1'b0) begin
            if (n_a_bits !== o_a_bits || n_w_bits !== o_w_bits || n_a_sgn !== o_a_sgn || n_w_sgn !== o_w_sgn ||
                u_per_new.ka_flat !== u_per_orig.ka_flat) begin
                eq_bad++;
                if (eq_bad < 10) $display("[UNIT-FAIL] %s: copy differs from the original peripheral in SC select", what);
            end
        end else begin
            if (n_a_bits !== (o_a_bits | p_a_raw) || n_w_bits !== (o_w_bits | p_w_raw) ||
                n_a_sgn !== o_a_sgn || n_w_sgn !== o_w_sgn) begin
                eq_bad++;
                if (eq_bad < 10) $display("[UNIT-FAIL] %s: INT select is not original | raw", what);
            end
        end
    endtask

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

        // (3a) encoder, b = 0: kA = 0 for every L 0..255 (garbage L included).
        enc_b = 8'd0;
        for (int ph = 0; ph < 8; ph++)
            for (int len = 0; len < 256; len++) begin
                enc_len = 8'(len);
                enc_phase = 3'(ph);
                #1;
                for (int k = 0; k < 8; k++) begin
                    sil_checks++;
                    if (enc_ka[k] !== 8'd0) begin
                        sil_bad++;
                        if (sil_bad < 10) $display("[UNIT-FAIL] b=0 lane %0d phase %0d L %0d: kA %0d", k, ph, len, enc_ka[k]);
                    end
                end
            end
        // (3b) peripheral with zero magnitudes: silent AF streams, raw passes.
        #1 prst = 1'b0;
        for (int it = 0; it < 64; it++) begin
            p_load(1'b1);
            for (int c = 0; c < 16; c++)
                for (int ph = 0; ph < 8; ph++) begin
                    p_cyc = 4'(c);
                    p_phase = 3'(ph);
                    p_random_view();
                    p_int = 1'b0;
                    #1;
                    sil_checks++;
                    if (u_per_new.sc_a_bits !== '0 || u_per_new.sc_w_bits !== '0 || n_a_bits !== '0 ||
                        n_w_bits !== '0 || u_per_new.ka_flat !== '0) begin
                        sil_bad++;
                        if (sil_bad < 10) $display("[UNIT-FAIL] zero magnitudes, cyc %0d phase %0d: AF streams not silent", c, ph);
                    end
                    p_int = 1'b1;
                    #1;
                    sil_checks++;
                    if (n_a_bits !== p_a_raw || n_w_bits !== p_w_raw) begin
                        sil_bad++;
                        if (sil_bad < 10) $display("[UNIT-FAIL] zero magnitudes, cyc %0d phase %0d: INT bits are not the raw planes", c, ph);
                    end
                end
        end
        $display("INT silence: %0d checks, %0d mismatches", sil_checks, sil_bad);

        // (3c) encoder, L = 0: kA = 0 for every b 0..255 (the A-side gate point
        // of the peripheral header: gating the per-row L buses silences A).
        for (int ph = 0; ph < 8; ph++)
            for (int b = 0; b < 256; b++) begin
                enc_b = 8'(b);
                enc_len = 8'd0;
                enc_phase = 3'(ph);
                #1;
                for (int k = 0; k < 8; k++) begin
                    lz_checks++;
                    if (enc_ka[k] !== 8'd0) begin
                        lz_bad++;
                        if (lz_bad < 10) $display("[UNIT-FAIL] L=0 lane %0d phase %0d b %0d: kA %0d", k, ph, b, enc_ka[k]);
                    end
                end
            end
        $display("L=0 gate point: %0d checks, %0d mismatches", lz_checks, lz_bad);

        // (4) copy vs original, random loads and views, both selects.
        for (int it = 0; it < 4000; it++) begin
            p_load(1'b0);
            for (int v = 0; v < 4; v++) begin
                p_cyc = 4'($urandom);
                p_phase = 3'($urandom);
                p_random_view();
                p_int = 1'b0;
                p_check_eq("random");
                p_int = 1'b1;
                p_check_eq("random");
            end
        end
        // Asynchronous reset of both.
        #1 prst = 1'b1;
        #1 prst = 1'b0;
        p_int = 1'b0;
        p_check_eq("after reset");
        $display("peripheral copy vs original: %0d checks, %0d mismatches", eq_checks, eq_bad);

        if (enc_bad == 0 && gen_bad == 0 && enc_checks == 8*128*129*8 && sil_bad == 0 && eq_bad == 0 &&
            sil_checks == 8*256*8 + 64*16*8*2 && eq_checks == 4000*4*2 + 1 &&
            lz_bad == 0 && lz_checks == 8*256*8)
            $display("UNITS PASS: encoder %0d cases, stream gen %0d checks, INT silence %0d checks, peripheral copy vs original %0d checks, L=0 gate point %0d checks",
                     enc_checks, gen_checks, sil_checks, eq_checks, lz_checks);
        else
            $display("UNITS FAIL: encoder %0d/%0d bad, stream gen %0d/%0d bad, INT silence %0d/%0d bad, copy vs original %0d/%0d bad, L=0 gate point %0d/%0d bad",
                     enc_bad, enc_checks, gen_bad, gen_checks, sil_bad, sil_checks, eq_bad, eq_checks, lz_bad, lz_checks);
        $finish;
    end
endmodule
