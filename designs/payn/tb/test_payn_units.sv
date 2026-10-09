`timescale 1ns/1ps

// Unit bench of the PaYN edge blocks against brute-force references written
// here from the definitions (no closed form, no lane split).  Shape from
// +define+PAYN_M=8 (K16/M8, default) or 16 (K8/M16): K = 128/M lanes,
// PB = 6 - log2(K) phase bits, 128/M cycles per block.
//
// Definitions:
//   A word      bitrev8(gray(t)) (identity directions), column mask
//               mask = bitrev8(d mod 64) for column d = K*p + k (lane k of
//               block phase p);
//   kA          #{t < L : ((bitrev8(gray(t)) ^ mask) >> 1) < b};
//   A bit       sample t = M*cyc + m of element (h, k): [t < kA];
//   W stream    x(t) = XOR_j gray(t)[j] * dv[j], dv = [80 40 20 10 48 04 52 ff];
//               the stream generator's lane word m at cycle c of phase p is
//               (x(M*c + m) ^ phase bits) >> 1, phase bits = bitrev8((K*p) mod 64);
//   W bit       b_w > ((x ^ mask) >> 1), i.e. b_w > (word ^ (bitrev8(k) >> 1))
//               for lane k (the phase bits are already in the word);
//   INT bypass  bits = SC bits | (raw & int_mode).
//
// Parts:
//   (1) PaynKaEncoder, exhaustively: every lane k (K instances) x phase p x
//       L = 0..255 x b = 0..128 against kA (2^PB * 256 * 129 * K = 2,113,536
//       cases at either shape); and L = 0 for every b 0..255 (kA = 0).
//   (2) PaynStreamGen: the registered W words of every cycle of every phase
//       against the W stream; phase sequencing with slice_start; the IDLE
//       park after 128/M cycles; rng_en freezing; restart; the structural
//       slice restart (phase 0 on the first block_start after reset or after a
//       shift_in edge, the drain tail on B+1 ignored); the asynchronous reset.
//   (3) INT silence: (3a) PaynKaEncoder with b = 0 gives kA = 0 for every
//       L = 0..255 (garbage L included), phase and lane; (3b) PaynEdge loaded
//       with zero magnitudes (random signs, random L 0..255) gives silent SC
//       streams (sc_a_bits = sc_w_bits = 0, ka_flat = 0) for every cyc value,
//       every phase and random W words, and in INT select a_bits / w_bits
//       equal the raw planes exactly.
//   (4) PaynEdge against the reference on random loads (A magnitudes 0..128,
//       W magnitudes 0..255, random signs, L 0..255), random cyc, phase, W
//       words and raw planes: in SC select every A bit (thermometer of the
//       reference kA), every W bit, both sign banks and ka_flat; in INT select
//       a_bits / w_bits = reference | raw.  Then after an asynchronous reset.
//   (5) PaynTile with FOLD = 1 (the INT lap fold) against an integer model,
//       acc <- shift ? acc_in : fold ? 2*acc + S : mac ? acc + S : acc
//       (mod 2^24, S = sum over lanes of +-popcount(a & w)), on 200,000 random
//       edges: shift / fold+MAC / MAC / idle mixes, dense and sparse operands,
//       uniform and random signs, random shift values.  acc_out is checked
//       after every edge; folds that meet a pending carry / borrow (the
//       segmented accumulator's corner) are counted and must both occur.
//       Every build runs it (the instance sets FOLD = 1 itself).
// Last line PASS: / FAIL: PaYN units bench, with counts.

`include "payn/rtl/payn_stream_gen.sv"
`include "payn/rtl/payn_edge.sv"
`include "payn/rtl/payn_tile.sv"

`ifndef PAYN_M
`define PAYN_M 8                      // positions per lane: 8 (K16/M8) or 16 (K8/M16)
`endif

module Top;
    localparam int M = `PAYN_M;
    localparam int K = 128 / M;
    localparam int PB = 6 - $clog2(K);          // block phase bits
    localparam int NPH = 1 << PB;               // block phases
    localparam int CYCLES = 128 / M;            // cycles per block
    localparam int CW = $clog2(CYCLES + 1);     // cycle counter width
    localparam int NCYC = 1 << CW;              // every cycle counter value
    localparam int N_H = 8, N_W = 8, WIDTH = 8, TW = WIDTH - 1;

    initial begin
        assert ((K == 16 && M == 8) || (K == 8 && M == 16))
            else $fatal(1, "PaYN units bench needs K16/M8 or K8/M16 (got K=%0d M=%0d)", K, M);
    end

    //------------------------------------------------------- reference --
    function automatic int bitrev8(input int x);
        int r = 0;
        for (int i = 0; i < 8; i++)
            if ((x >> i) & 1) r |= 1 << (7 - i);
        return r;
    endfunction

    function automatic int gray(input int t);
        return t ^ (t >> 1);
    endfunction

    // Column mask of column d.
    function automatic int col_mask(input int d);
        return bitrev8(d % 64);
    endfunction

    // A threshold of sample t in column d: ((bitrev8(gray(t)) ^ mask) >> 1).
    function automatic int a_threshold(input int d, input int t);
        return (bitrev8(gray(t)) ^ col_mask(d)) >> 1;
    endfunction

    // kA reference: ka_ref[d][L][b] = #{t < L : a_threshold(d, t) < b},
    // counted sample by sample for every column d mod 64, L 0..255, b 0..128.
    byte unsigned ka_ref [64][256][129];

    task automatic build_ka_ref();
        int n;
        for (int d = 0; d < 64; d++)
            for (int b = 0; b <= 128; b++) begin
                n = 0;
                for (int len = 0; len < 256; len++) begin
                    ka_ref[d][len][b] = n;
                    if (a_threshold(d, len) < b) n++;
                end
            end
    endtask

    // W stream sample t: XOR of the direction numbers selected by gray(t).
    function automatic int w_sobol(input int t);
        int dv [8] = '{8'h80, 8'h40, 8'h20, 8'h10, 8'h48, 8'h04, 8'h52, 8'hff};
        int g = gray(t);
        int x = 0;
        for (int j = 0; j < 8; j++)
            if ((g >> j) & 1) x ^= dv[j];
        return x;
    endfunction

    // The phase's bits of the mask: bitrev8((K*p) mod 64).
    function automatic int phase_bits(input int p);
        return bitrev8((K*p) % 64);
    endfunction

    // Stream generator lane word m at cycle c of phase p.
    function automatic int w_word_ref(input int c, input int p, input int m);
        return ((w_sobol(M*c + m) ^ phase_bits(p)) >> 1) & 8'h7f;
    endfunction

    // W bit of lane k for magnitude b and lane word w.
    function automatic bit w_bit_ref(input int b, input int w, input int k);
        return b > ((w ^ (bitrev8(k) >> 1)) & 8'h7f);
    endfunction

    // The magnitude the INT contract loads (its streams must be silent): the
    // INT-silence part (3) predicts the edge from the reference at this b.
    localparam int SILENT_B = 0;

    //------------------------------------------------------- (1) encoder --
    logic [7:0] enc_b, enc_len;
    logic [PB-1:0] enc_phase;
    logic [7:0] enc_ka [K];

    for (genvar k = 0; k < K; k++) begin : g_enc
        PaynKaEncoder #(.K(K), .LANE(k)) u_ka (
            .b(enc_b), .len(enc_len), .phase(enc_phase), .ka(enc_ka[k])
        );
    end

    //---------------------------------------------------- (2) stream gen --
    logic clk = 1'b0, reset = 1'b1;
    logic rng_en = 1'b0, block_start = 1'b0, slice_start = 1'b0, shift_in = 1'b0;
    logic [CW-1:0] cyc;
    logic [PB-1:0] phase;
    logic [M*TW-1:0] w_words;

    always #1.25 clk = ~clk;

    PaynStreamGen #(.M(M), .WIDTH(WIDTH)) u_rng (
        .clk, .reset, .rng_en, .block_start, .slice_start, .shift_in, .cyc, .phase, .w_words
    );

    int enc_checks = 0, enc_bad = 0;
    int gen_checks = 0, gen_bad = 0;

    //--------------------------------------------------- (3)/(4) PaynEdge --
    logic pclk = 1'b0, prst = 1'b1, p_load_a = 1'b0, p_load_w = 1'b0;
    logic [N_H*K*WIDTH-1:0] p_a_bin = '0;
    logic [N_H*K-1:0]       p_a_sgn = '0;
    logic [N_H*WIDTH-1:0]   p_a_len = '0;
    logic [N_W*K*WIDTH-1:0] p_w_bin = '0;
    logic [N_W*K-1:0]       p_w_sgn = '0;
    logic [CW-1:0] p_cyc = '0;
    logic [PB-1:0] p_phase = '0;
    logic [M*TW-1:0] p_words = '0;
    logic p_int = 1'b0;
    logic [N_H*K*M-1:0] p_a_raw = '0;
    logic [N_W*K*M-1:0] p_w_raw = '0;
    logic [N_H*K*M-1:0] e_a_bits;
    logic [N_W*K*M-1:0] e_w_bits;
    logic [N_H*K-1:0] e_a_sgn;
    logic [N_W*K-1:0] e_w_sgn;

    PaynEdge #(.K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH)) u_edge (
        .clk(pclk), .reset(prst), .load_a(p_load_a), .load_w(p_load_w),
        .a_binary_in(p_a_bin), .a_signs_in(p_a_sgn), .a_len_in(p_a_len),
        .w_binary_in(p_w_bin), .w_signs_in(p_w_sgn),
        .cyc(p_cyc), .phase(p_phase), .w_words(p_words),
        .int_mode(p_int), .a_raw_in(p_a_raw), .w_raw_in(p_w_raw),
        .a_bits(e_a_bits), .a_signs(e_a_sgn), .w_bits(e_w_bits), .w_signs(e_w_sgn)
    );

    // Reference copy of the edge registers (loaded by p_load, cleared by reset).
    logic [N_H*K*WIDTH-1:0] r_a_bin = '0;
    logic [N_H*K-1:0]       r_a_sgn = '0;
    logic [N_H*WIDTH-1:0]   r_a_len = '0;
    logic [N_W*K*WIDTH-1:0] r_w_bin = '0;
    logic [N_W*K-1:0]       r_w_sgn = '0;

    int sil_checks = 0, sil_bad = 0;      // (3)
    int lz_checks = 0, lz_bad = 0;        // (1), L = 0
    int eq_checks = 0, eq_bad = 0;        // (4)

    // Expected SC stream bits and kA of the edge for the current registers,
    // cyc, phase and words; mag >= 0 replaces every magnitude by mag.
    task automatic edge_ref(input int mag, output logic [N_H*K*M-1:0] ea, output logic [N_W*K*M-1:0] ew,
                            output logic [N_H*K*WIDTH-1:0] eka);
        int kv, d, b;
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++) begin
                d = K*int'(p_phase) + k;
                b = (mag >= 0) ? mag : int'(r_a_bin[(h*K + k)*WIDTH +: WIDTH]);
                kv = ka_ref[d % 64][r_a_len[h*WIDTH +: WIDTH]][b];
                eka[(h*K + k)*WIDTH +: WIDTH] = WIDTH'(kv);
                for (int m = 0; m < M; m++)
                    ea[(h*K + k)*M + m] = (M*int'(p_cyc) + m) < kv;
            end
        for (int v = 0; v < N_W; v++)
            for (int k = 0; k < K; k++) begin
                b = (mag >= 0) ? mag : int'(r_w_bin[(v*K + k)*WIDTH +: WIDTH]);
                for (int m = 0; m < M; m++)
                    ew[(v*K + k)*M + m] = w_bit_ref(b, p_words[m*TW +: TW], k);
            end
    endtask

    task automatic p_load(input bit zero_mag);
        for (int i = 0; i < N_H*K; i++) begin
            p_a_bin[i*WIDTH +: WIDTH] = zero_mag ? 8'd0 : 8'($urandom_range(0, 128));
            p_a_sgn[i] = $urandom & 1;
        end
        for (int h = 0; h < N_H; h++) p_a_len[h*WIDTH +: WIDTH] = 8'($urandom);
        for (int i = 0; i < N_W*K; i++) begin
            p_w_bin[i*WIDTH +: WIDTH] = zero_mag ? 8'd0 : (($urandom & 3) ? 8'($urandom_range(0, 128)) : 8'($urandom));
            p_w_sgn[i] = $urandom & 1;
        end
        p_load_a = 1'b1;
        p_load_w = 1'b1;
        #1 pclk = 1'b1;
        r_a_bin = p_a_bin;
        r_a_sgn = p_a_sgn;
        r_a_len = p_a_len;
        r_w_bin = p_w_bin;
        r_w_sgn = p_w_sgn;
        #1 pclk = 1'b0;
        p_load_a = 1'b0;
        p_load_w = 1'b0;
    endtask

    task automatic p_random_view();
        for (int n = 0; n < M*TW; n++) p_words[n] = $urandom & 1;
        for (int n = 0; n < N_H*K*M; n++) p_a_raw[n] = $urandom & 1;
        for (int n = 0; n < N_W*K*M; n++) p_w_raw[n] = $urandom & 1;
    endtask

    task automatic p_check_eq(input string what);
        logic [N_H*K*M-1:0] ea;
        logic [N_W*K*M-1:0] ew;
        logic [N_H*K*WIDTH-1:0] eka;
        #1;
        edge_ref(-1, ea, ew, eka);
        eq_checks++;
        if (p_int == 1'b0) begin
            if (e_a_bits !== ea || e_w_bits !== ew || e_a_sgn !== r_a_sgn || e_w_sgn !== r_w_sgn ||
                u_edge.ka_flat !== eka) begin
                eq_bad++;
                if (eq_bad < 10) $display("[UNIT-FAIL] %s: edge differs from the reference in SC select (cyc %0d phase %0d)",
                                          what, p_cyc, p_phase);
            end
        end else begin
            if (e_a_bits !== (ea | p_a_raw) || e_w_bits !== (ew | p_w_raw) ||
                e_a_sgn !== r_a_sgn || e_w_sgn !== r_w_sgn) begin
                eq_bad++;
                if (eq_bad < 10) $display("[UNIT-FAIL] %s: INT select is not reference | raw (cyc %0d phase %0d)",
                                          what, p_cyc, p_phase);
            end
        end
    endtask

    task automatic check_words(input int c, input int p, input string what);
        gen_checks++;
        if (cyc !== CW'(c) || phase !== PB'(p)) begin
            gen_bad++;
            if (gen_bad < 10)
                $display("[UNIT-FAIL] %s: cyc=%0d phase=%0d, expected %0d / %0d", what, cyc, phase, c, p);
        end
        if (c < CYCLES)
            for (int m = 0; m < M; m++) begin
                int exp_w = w_word_ref(c, p, m);
                gen_checks++;
                if (w_words[m*TW +: TW] !== TW'(exp_w)) begin
                    gen_bad++;
                    if (gen_bad < 10)
                        $display("[UNIT-FAIL] %s: c=%0d p=%0d m=%0d word %h expected %h",
                                 what, c, p, m, w_words[m*TW +: TW], TW'(exp_w));
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

    //------------------------------------------------- (5) PaynTile fold --
    localparam int T_OW = 24, T_LW = 9, T_EDGES = 200000;
    logic tclk = 1'b0, trst = 1'b1;
    logic         t_a_sgn  [K];
    logic [M-1:0] t_a_bits [K];
    logic         t_w_sgn  [K];
    logic [M-1:0] t_w_bits [K];
    logic t_shift = 1'b0, t_mac = 1'b0, t_fold = 1'b0;
    logic signed [T_OW-1:0] t_acc_in = '0;
    logic signed [T_OW-1:0] t_acc_out;
    int tile_checks = 0, tile_bad = 0, tile_folds = 0, fold_pc = 0, fold_pb = 0;

    PaynTile #(.K(K), .M(M), .OWIDTH(T_OW), .LOW_W(T_LW), .FOLD(1)) u_tile (
        .clk(tclk), .reset(trst),
        .a_signs(t_a_sgn), .a_bits(t_a_bits), .w_signs(t_w_sgn), .w_bits(t_w_bits),
        .shift_in(t_shift), .mac_en(t_mac), .fold(t_fold), .acc_in(t_acc_in), .acc_out(t_acc_out)
    );

    function automatic longint wrap_ow(input longint x);
        x = x & ((longint'(1) << T_OW) - 1);
        return (x >= (longint'(1) << (T_OW - 1))) ? x - (longint'(1) << T_OW) : x;
    endfunction

    // Random operands for one edge: density 0 sparse / 1 random / 2 dense,
    // signs 0 all positive / 1 all negative products / 2 random.
    task automatic t_operands(output longint s);
        int dens, sg;
        dens = $urandom_range(0, 2);
        sg = $urandom_range(0, 2);
        s = 0;
        for (int i = 0; i < K; i++) begin
            t_a_bits[i] = (dens == 2) ? ~M'($urandom_range(0, 3)) : (dens == 1) ? M'($urandom) : M'($urandom) & M'($urandom) & M'($urandom);
            t_w_bits[i] = (dens == 2) ? '1 : M'($urandom);
            t_a_sgn[i] = (sg == 2) ? 1'($urandom) : 1'b0;
            t_w_sgn[i] = (sg == 2) ? 1'($urandom) : 1'(sg);
            s += ((t_a_sgn[i] ^ t_w_sgn[i]) ? -1 : 1) * $countones(t_a_bits[i] & t_w_bits[i]);
        end
    endtask

    task automatic tile_fold_test();
        longint ref_acc, s;
        int r;
        for (int i = 0; i < K; i++) begin
            t_a_bits[i] = '0; t_w_bits[i] = '0; t_a_sgn[i] = 1'b0; t_w_sgn[i] = 1'b0;
        end
        #1 tclk = 1'b1;
        #1 tclk = 1'b0;
        trst = 1'b0;
        ref_acc = 0;
        for (int e = 0; e < T_EDGES; e++) begin
            r = $urandom_range(0, 99);
            t_operands(s);
            t_shift = (r < 4);
            t_fold = (r >= 4 && r < 40);
            t_mac = (r >= 4 && r < 90);
            t_acc_in = T_OW'({$urandom, $urandom});
            if (t_fold) begin
                tile_folds++;
                fold_pc += (u_tile.pending_carry === 1'b1);
                fold_pb += (u_tile.pending_borrow === 1'b1);
            end
            if (t_shift) ref_acc = t_acc_in;
            else if (t_fold) ref_acc = wrap_ow(2 * ref_acc + s);
            else if (t_mac) ref_acc = wrap_ow(ref_acc + s);
            #1 tclk = 1'b1;
            #1 tclk = 1'b0;
            tile_checks++;
            if (t_acc_out !== T_OW'(ref_acc)) begin
                tile_bad++;
                if (tile_bad < 10)
                    $display("[UNIT-FAIL] tile edge %0d (shift %0b fold %0b mac %0b, S %0d): acc_out %0d, expected %0d",
                             e, t_shift, t_fold, t_mac, s, t_acc_out, ref_acc);
            end
        end
        $display("tile fold: %0d edges checked, %0d mismatches; %0d folds, %0d with a pending carry, %0d with a pending borrow",
                 tile_checks, tile_bad, tile_folds, fold_pc, fold_pb);
    endtask

    initial begin
        int p;
        bit ok;
        logic [N_H*K*M-1:0] ea;
        logic [N_W*K*M-1:0] ew;
        logic [N_H*K*WIDTH-1:0] eka;

        build_ka_ref();

        // (1) exhaustive encoder
        for (int ph = 0; ph < NPH; ph++)
            for (int len = 0; len < 256; len++)
                for (int b = 0; b <= 128; b++) begin
                    enc_b = 8'(b);
                    enc_len = 8'(len);
                    enc_phase = PB'(ph);
                    #1;
                    for (int k = 0; k < K; k++) begin
                        automatic int exp_ka = ka_ref[K*ph + k][len][b];
                        enc_checks++;
                        if (enc_ka[k] !== 8'(exp_ka)) begin
                            enc_bad++;
                            if (enc_bad < 10)
                                $display("[UNIT-FAIL] kA lane %0d phase %0d L %0d b %0d: %0d, expected %0d",
                                         k, ph, len, b, enc_ka[k], exp_ka);
                        end
                    end
                end
        // (1) L = 0: kA = 0 for every b 0..255 (the empty sample set).
        for (int ph = 0; ph < NPH; ph++)
            for (int b = 0; b < 256; b++) begin
                enc_b = 8'(b);
                enc_len = 8'd0;
                enc_phase = PB'(ph);
                #1;
                for (int k = 0; k < K; k++) begin
                    lz_checks++;
                    if (enc_ka[k] !== 8'd0) begin
                        lz_bad++;
                        if (lz_bad < 10) $display("[UNIT-FAIL] L=0 lane %0d phase %0d b %0d: kA %0d", k, ph, b, enc_ka[k]);
                    end
                end
            end
        $display("encoder: %0d cases, %0d mismatches; L=0: %0d checks, %0d mismatches",
                 enc_checks, enc_bad, lz_checks, lz_bad);

        // (2) stream generator
        @(negedge clk);
        reset = 1'b0;
        tick();
        gen_checks++;
        if (cyc !== CW'(CYCLES)) begin
            gen_bad++;
            $display("[UNIT-FAIL] counter not IDLE after reset (cyc=%0d)", cyc);
        end
        // 20 blocks of CYCLES cycles: slice starts at blocks 0, 3, 11 (phase
        // reset), otherwise phase + 1 (wraps past NPH-1).
        p = 0;
        for (int blk = 0; blk < 20; blk++) begin
            automatic bit ss = (blk == 0 || blk == 3 || blk == 11);
            p = ss ? 0 : (p + 1) % NPH;
            @(negedge clk);
            block_start = 1'b1;
            slice_start = ss;
            rng_en = (blk % 2);               // don't-care on the restart edge
            tick();
            block_start = 1'b0;
            slice_start = 1'b0;
            rng_en = 1'b1;
            check_words(0, p, "restart");
            for (int c = 1; c < CYCLES; c++) begin
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
        // IDLE park: one more advance reaches CYCLES, then it stays.
        tick();
        check_words(CYCLES, p, "idle");
        repeat (5) tick();
        check_words(CYCLES, p, "idle-hold");
        // Short block then restart mid-stream, with and without slice_start.
        @(negedge clk);
        block_start = 1'b1;
        tick();
        block_start = 1'b0;
        p = (p + 1) % NPH;
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
        if (cyc !== CW'(CYCLES) || phase !== '0) begin
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

        // (3a) encoder with b = 0: kA = 0 for every L 0..255 (the reference at
        // the silent magnitude, which must itself be 0).
        enc_b = 8'd0;
        for (int ph = 0; ph < NPH; ph++)
            for (int len = 0; len < 256; len++) begin
                enc_len = 8'(len);
                enc_phase = PB'(ph);
                #1;
                for (int k = 0; k < K; k++) begin
                    sil_checks++;
                    if (enc_ka[k] !== 8'(ka_ref[K*ph + k][len][SILENT_B]) || enc_ka[k] !== 8'd0) begin
                        sil_bad++;
                        if (sil_bad < 10) $display("[UNIT-FAIL] b=0 lane %0d phase %0d L %0d: kA %0d", k, ph, len, enc_ka[k]);
                    end
                end
            end
        // (3b) edge with zero magnitudes: silent SC streams, raw passes.
        #1 prst = 1'b0;
        for (int it = 0; it < 64; it++) begin
            p_load(1'b1);
            for (int c = 0; c < NCYC; c++)
                for (int ph = 0; ph < NPH; ph++) begin
                    p_cyc = CW'(c);
                    p_phase = PB'(ph);
                    p_random_view();
                    p_int = 1'b0;
                    #1;
                    edge_ref(SILENT_B, ea, ew, eka);
                    sil_checks++;
                    if (u_edge.sc_a_bits !== ea || u_edge.sc_w_bits !== ew || e_a_bits !== ea ||
                        e_w_bits !== ew || u_edge.ka_flat !== eka || ea !== '0 || ew !== '0 || eka !== '0) begin
                        sil_bad++;
                        if (sil_bad < 10) $display("[UNIT-FAIL] zero magnitudes, cyc %0d phase %0d: SC streams not silent", c, ph);
                    end
                    p_int = 1'b1;
                    #1;
                    sil_checks++;
                    if (e_a_bits !== (ea | p_a_raw) || e_w_bits !== (ew | p_w_raw) ||
                        e_a_bits !== p_a_raw || e_w_bits !== p_w_raw) begin
                        sil_bad++;
                        if (sil_bad < 10) $display("[UNIT-FAIL] zero magnitudes, cyc %0d phase %0d: INT bits are not the raw planes", c, ph);
                    end
                end
        end
        $display("INT silence: %0d checks, %0d mismatches", sil_checks, sil_bad);

        // (4) edge vs reference, random loads and views, both selects.
        for (int it = 0; it < 4000; it++) begin
            p_load(1'b0);
            for (int v = 0; v < 4; v++) begin
                p_cyc = CW'($urandom);
                p_phase = PB'($urandom);
                p_random_view();
                p_int = 1'b0;
                p_check_eq("random");
                p_int = 1'b1;
                p_check_eq("random");
            end
        end
        // Asynchronous reset: every register back to zero.
        #1 prst = 1'b1;
        r_a_bin = '0;
        r_a_sgn = '0;
        r_a_len = '0;
        r_w_bin = '0;
        r_w_sgn = '0;
        #1 prst = 1'b0;
        p_int = 1'b0;
        p_check_eq("after reset");
        $display("edge vs reference: %0d checks, %0d mismatches", eq_checks, eq_bad);

        // (5) PaynTile fold vs the integer model.
        tile_fold_test();

        ok = enc_bad == 0 && gen_bad == 0 && sil_bad == 0 && eq_bad == 0 && lz_bad == 0 &&
             enc_checks == NPH*256*129*K && lz_checks == NPH*256*K &&
             sil_checks == NPH*256*K + 64*NCYC*NPH*2 && eq_checks == 4000*4*2 + 1 &&
             tile_bad == 0 && tile_checks == T_EDGES && fold_pc > 0 && fold_pb > 0;
        if (ok)
            $display("PASS: PaYN units bench K=%0d M=%0d: encoder %0d cases, L=0 %0d checks, stream gen %0d checks, INT silence %0d checks, edge vs reference %0d checks, tile fold %0d edges (%0d folds, %0d / %0d with a pending carry / borrow)",
                     K, M, enc_checks, lz_checks, gen_checks, sil_checks, eq_checks, tile_checks, tile_folds, fold_pc, fold_pb);
        else
            $display("FAIL: PaYN units bench K=%0d M=%0d: encoder %0d/%0d bad, L=0 %0d/%0d bad, stream gen %0d/%0d bad, INT silence %0d/%0d bad, edge vs reference %0d/%0d bad, tile fold %0d/%0d bad (%0d / %0d folds with a pending carry / borrow)",
                     K, M, enc_bad, enc_checks, lz_bad, lz_checks, gen_bad, gen_checks, sil_bad, sil_checks, eq_bad, eq_checks, tile_bad, tile_checks, fold_pc, fold_pb);
        $finish;
    end
endmodule
