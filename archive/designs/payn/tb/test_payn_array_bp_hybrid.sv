`timescale 1ns/1ps

`include "common/clk_util.sv"

// BP-hybrid H(TA,TW) INT bench for the UNCHANGED single-PE BP top
// payn_array_signed_segmented_csa_bp (csa_bp_20261004_lap RTL).  Written in the
// fix stage of the BP lap-schedule study to run the hybrid through the real top
// (peripheral raw-bit bypass, top-level sign path with per-pass reloads of BOTH
// sign words, int_mode guard, ring) and to check a proposed east-edge combine
// (designs/payn/variants/signed_segmented_csa_bp_hyb/bp_hybrid_combiner.sv,
// instantiated here as a sidecar on acc_out_east; it is not in the top).
// Edge-drive conventions as test_payn_array_bp_space.sv (not changed).
//
// Mapping (one PE; GA = BA/TA activation-bit groups on tile rows, GW = BW/TW
// weight-bit groups on tile columns; ROWS_PE = 8/GA, CPE = 8/GW):
//   tile row h     activation row i = ig*ROWS_PE + h / GA, group g = h % GA
//   tile column v  output column  j = jg*CPE + v / GW,     group s = v % GW
//   pass (ta, q)   row (i,g) carries activation bit g*TA + ta, column (j,s)
//                  carries weight bit s*TW + q; TA*TW passes, grouped by Horner
//                  level k = ta + q (k = TA+TW-2 first, ta high first); one
//                  8-edge ring lap between levels (TA+TW-2 laps).
//   lane k, position m of data edge b: reduction element x = 128*b + 16*k + m.
// Sign words, loaded through the top's load_a / load_w + load_X_sign (zero
// magnitudes) on the edge before each pass's first capture: a_signs row h =
// (g*TA + ta == BA-1), w_signs column v = (s*TW + q == BW-1), all lanes.
// Each drained tile is T((i,g),(j,s)) = sum_x Afield_g[i,x] * Wfield_s[x,j],
// and out(i,j) = sum_g sum_s 2^(g*TA + s*TW) T.  TA = 1, TW = BW is the
// as-built T1 mapping and schedule; TA = TW = 1 is T2 S = BW.
//
// Schedule (E0 = first data capture, block base B = E0 + blk*BLK_LEN):
//   data captured on B + pass_off[p] + 0..NB-1 (MAC one edge later);
//   lap after level lv: ring_q high on B + lev_end[lv] + LO + 1 .. + 8;
//   drain: shift_in (acc_in_west = 0) on D0 .. D0+7, D0 = B + ACTIVE + 1 + DS,
//          the last drain edge being the next block's first capture, so
//   BLK_LEN = TA*TW*NB + 8*(TA+TW-2) + 8.
// The top's combiner (PaynBpCombiner) captures on the drain edges and gives,
// per column, sum_h 2^h T(h) (int_prec = 0) or the two 4-plane halves
// (int_prec = 1); that is the H output only at the T1 corner.  The sidecar
// PaynBpHybridCombiner (ga_log2 = log2 GA, ta_log2 = log2 TA) captures on the
// same edges and gives out[il] = sum_g 2^(g*TA) T(il*GA + g); the checker adds
// the column Horner for TW < BW.
//
// Plusargs: +BA=<4|8> +BW=<4|8> +TA=<1|2|4|8, divides BA> +TW=<1|2|4|8,
//   divides BW> +L=<multiple of 128> +MROWS=<multiple of ROWS_PE>
//   +NCOLS=<multiple of CPE>
//   +JUNK  as test_payn_array_bp_space.sv (Sobol running, random binary words
//          off the load edges, extra load_a / load_w with random sign words and
//          load_X_sign low, random acc_in_west off drains, random int_prec off
//          capture edges).
//   Negative controls (must FAIL in the checker with tile / output mismatches):
//   +NEG_ASIGN_HELD    a sign word loaded once (T1's) and held (needs TA > 1)
//   +NEG_GAP_SHORT     every lap one edge early (drops the level's last MAC)
//   +NEG_DRAIN_EARLY   drain starts on the last MAC edge
//   +NEG_BLOCK_OVERLAP BLK_LEN - 1 (needs >= 2 blocks)
//
// Trace (bph_trace.txt): header BPHTCFG; "D blk t tile_h0..h7" per drain read
// (pre-edge acc_out_east, column v = 7 - t), "E blk t e", "C blk t lo hi" per
// top combiner word, "Y blk t w0..w7" per sidecar word, "R e_first len" ring_q
// runs.  Checker: sweeps/int_mode/bp/hybrid/check_bp_hybrid_top_trace.py.
// Operands bpt_a.hex / bpt_w.hex (sweeps/int_mode/bp/space/gen_bp_space_workload.py).
// RTL needs DesignWare.

`include "payn/variants/signed_segmented_csa_bp/payn_array_signed_segmented_csa_bp.sv"
`include "payn/variants/signed_segmented_csa_bp_hyb/bp_hybrid_combiner.sv"

`ifndef BPH_LOW_W
`define BPH_LOW_W 9
`endif
`ifndef BPH_MAX_EDGES
`define BPH_MAX_EDGES 20000000
`endif

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int LOW_W = `BPH_LOW_W;
    localparam int E0 = 4;
    localparam real PERIOD = 2.5;
    localparam int MAX_PASS = 64;

    int BA = 8, BW = 8, TA = 1, TW = 8, L = 128, MROWS = 0, NCOLS = 0;
    bit junk = 1'b0, neg_asign_held = 1'b0, neg_gap_short = 1'b0, neg_drain_early = 1'b0;
    bit neg_block_overlap = 1'b0;
    int GA, GW, ROWS_PE, CPE, NPASS, NLEV, NB, NIG, NJG, NBLK, LO, DS, ACTIVE, BLK_LEN, E_END, N_EDGES;
    int pass_ta [MAX_PASS];
    int pass_q  [MAX_PASS];
    int pass_off[MAX_PASS];
    int lev_end [MAX_PASS];
    int cur_e = -1000;
    bit cfg_done = 1'b0;
    bit cap_hist [int];

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;
    logic int_mode = 1'b1, int_prec = 1'b0, ring_in = 1'b0;
    logic [N_H*K*M-1:0] a_raw_in = '0;
    logic [N_W*K*M-1:0] w_raw_in = '0;
    logic [63:0] int_out;
    logic int_out_valid;

    logic hyb_cap = 1'b0;
    logic [1:0] ga_log2 = '0, ta_log2 = '0;
    logic [N_H*32-1:0] hyb_out;
    logic hyb_valid;

    logic [7:0] a_mem [];
    logic [7:0] w_mem [];
    integer trace_file = 0;
    int n_drain = 0, n_comb = 0, n_cap = 0, n_hyb = 0;

    ClkUtils #(.TIMEOUT(`BPH_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

    payn_array_signed_segmented_csa_bp #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (.*);

    PaynBpHybridCombiner #(.N_H(N_H), .OWIDTH(OWIDTH), .OUT_W(32)) u_hyb (
        .clk, .reset, .capture(hyb_cap), .ga_log2, .ta_log2, .acc_east(acc_out_east),
        .out(hyb_out), .out_valid(hyb_valid));

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] BP hybrid top bench exceeded %0d cycles", `BPH_MAX_EDGES);

    int run_start = -1, run_len = 0;
    always @(posedge clk) begin
        if (cfg_done && trace_file != 0) begin
            if (dut.u_pe.ring_q === 1'b1) begin
                if (run_len == 0) run_start = cur_e;
                run_len++;
            end else begin
                if (dut.u_pe.ring_q !== 1'b0) $fatal(1, "[X-FAIL] ring_q X at edge %0d", cur_e);
                if (run_len != 0) $fwrite(trace_file, "R %0d %0d\n", run_start, run_len);
                run_len = 0;
            end
        end
    end

    // ---------------------------------------------------------- schedule --
    function automatic bit decode(input int e, output int blk, output int u);
        if (e < E0 || e >= E0 + NBLK*BLK_LEN) return 1'b0;
        blk = (e - E0) / BLK_LEN;
        u = (e - E0) % BLK_LEN;
        return 1'b1;
    endfunction

    function automatic bit data_at(input int e, output int blk, output int n, output int b);
        int u;
        if (!decode(e, blk, u)) return 1'b0;
        for (int p = 0; p < NPASS; p++)
            if (u >= pass_off[p] && u < pass_off[p] + NB) begin
                n = p;
                b = u - pass_off[p];
                return 1'b1;
            end
        return 1'b0;
    endfunction

    function automatic bit lap_at(input int e);
        int blk, u;
        if (!decode(e, blk, u)) return 1'b0;
        if (u == 0) return 1'b0;
        for (int lv = 0; lv < NLEV - 1; lv++)
            if (u >= lev_end[lv] + LO + 1 && u <= lev_end[lv] + LO + 8) return 1'b1;
        return 1'b0;
    endfunction

    function automatic bit drain_at(input int e, output int blk, output int t);
        int d0, bb;
        if (e <= E0) return 1'b0;
        bb = (e - E0) / BLK_LEN;
        for (int b = bb; b >= bb - 1 && b >= 0; b--) begin
            if (b >= NBLK) continue;
            d0 = E0 + b*BLK_LEN + ACTIVE + 1 + DS;
            if (e - d0 >= 0 && e - d0 < N_W) begin
                blk = b;
                t = e - d0;
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    function automatic logic [N_H*K-1:0] a_word(input int n);
        logic [N_H*K-1:0] wd;
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                wd[h*K + k] = neg_asign_held ? ((h % GA) == GA - 1) : ((h % GA)*TA + pass_ta[n] == BA - 1);
        return wd;
    endfunction

    function automatic logic [N_W*K-1:0] w_word(input int n);
        logic [N_W*K-1:0] wd;
        for (int v = 0; v < N_W; v++)
            for (int k = 0; k < K; k++)
                wd[v*K + k] = ((v % GW)*TW + pass_q[n] == BW - 1);
        return wd;
    endfunction

    task automatic set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, n, b, ig, jg, i, j, x, bi;
        a_next = '0;
        w_next = '0;
        if (data_at(e, blk, n, b)) begin
            ig = blk / NJG;
            jg = blk % NJG;
            for (int h = 0; h < N_H; h++) begin
                i = ig*ROWS_PE + h / GA;
                bi = (h % GA)*TA + pass_ta[n];
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = b*K*M + k*M + m;
                        a_next[(h*K + k)*M + m] = a_mem[i*L + x][bi];
                    end
            end
            for (int v = 0; v < N_W; v++) begin
                j = jg*CPE + v / GW;
                bi = (v % GW)*TW + pass_q[n];
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = b*K*M + k*M + m;
                        w_next[(v*K + k)*M + m] = w_mem[j*L + x][bi];
                    end
            end
        end
        a_raw_in = a_next;
        w_raw_in = w_next;
    endtask

    // Sign loads captured by the peripheral at P_e; the PE sign pipes take them
    // at P_{e+1}, the pass's first raw-plane capture edge.  Both words, every
    // pass (NEG_ASIGN_HELD: the a word only once, T1's word).
    task automatic set_signs(input int e);
        int blk, n, b;
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
        if (data_at(e + 1, blk, n, b) && b == 0) begin
            if (!neg_asign_held || e + 1 == E0) begin
                a_signs_in = a_word(n);
                load_a = 1'b1;
                load_a_sign = 1'b1;
            end
            w_signs_in = w_word(n);
            load_w = 1'b1;
            load_w_sign = 1'b1;
        end
        if (junk) begin
            if (!load_a && ($urandom & 1)) begin
                load_a = 1'b1;
                a_signs_in = {$urandom, $urandom};
            end
            if (!load_w && ($urandom & 1)) begin
                load_w = 1'b1;
                w_signs_in = {$urandom, $urandom};
            end
        end
    endtask

    task automatic set_binary();
        if (!junk) return;
        if (load_a) a_binary_in = '0;
        else for (int q = 0; q < N_H*K*WIDTH; q++) a_binary_in[q] = $urandom & 1;
        if (load_w) w_binary_in = '0;
        else for (int q = 0; q < N_W*K*WIDTH; q++) w_binary_in[q] = $urandom & 1;
    endtask

    task automatic read_drain(input int e);
        int bd, t;
        if (!drain_at(e, bd, t)) return;
        if ($isunknown(acc_out_east)) $fatal(1, "[X-FAIL] drained column X: block %0d step %0d", bd, t);
        $fwrite(trace_file, "D %0d %0d", bd, t);
        for (int h = 0; h < N_H; h++) $fwrite(trace_file, " %0d", $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
        $fwrite(trace_file, "\n");
        $fwrite(trace_file, "E %0d %0d %0d\n", bd, t, e);
        n_drain++;
    endtask

    task automatic read_comb(input int e);
        int bd, t;
        bit expect_valid;
        if ($isunknown(int_out_valid) || $isunknown(hyb_valid))
            $fatal(1, "[X-FAIL] combiner valid X at edge %0d", e);
        expect_valid = cap_hist.exists(e - 2);
        if (int_out_valid !== expect_valid || hyb_valid !== expect_valid)
            $fatal(1, "[TIMING-FAIL] int_out_valid=%0b hyb_valid=%0b at edge %0d, expected %0b",
                   int_out_valid, hyb_valid, e, expect_valid);
        if (!expect_valid) return;
        void'(drain_at(e - 2, bd, t));
        if ($isunknown(int_out) || $isunknown(hyb_out)) $fatal(1, "[X-FAIL] combiner word X: block %0d step %0d", bd, t);
        $fwrite(trace_file, "C %0d %0d %0d %0d\n", bd, t, $signed(int_out[31:0]), $signed(int_out[63:32]));
        $fwrite(trace_file, "Y %0d %0d", bd, t);
        for (int w = 0; w < N_H; w++) $fwrite(trace_file, " %0d", $signed(hyb_out[w*32 +: 32]));
        $fwrite(trace_file, "\n");
        n_comb++;
        n_hyb++;
    endtask

    task automatic read_hex(input string path, input int n, output logic [7:0] mem []);
        int fd, code;
        logic [7:0] v;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", path);
        mem = new[n];
        for (int idx = 0; idx < n; idx++) begin
            code = $fscanf(fd, "%h", v);
            if (code != 1 || $isunknown(v)) $fatal(1, "%s short/invalid at entry %0d", path, idx);
            mem[idx] = v;
        end
        code = $fscanf(fd, "%h", v);
        if (code == 1) $fatal(1, "%s has more than %0d entries", path, n);
        $fclose(fd);
    endtask

    function automatic int log2i(input int v);
        for (int k = 0; k < 4; k++) if ((1 << k) == v) return k;
        return -1;
    endfunction

    initial begin
        longint amax, wmax;
        int off, np, bd, t;
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("TA=%d", TA));
        void'($value$plusargs("TW=%d", TW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        junk = $test$plusargs("JUNK");
        neg_asign_held = $test$plusargs("NEG_ASIGN_HELD");
        neg_gap_short = $test$plusargs("NEG_GAP_SHORT");
        neg_drain_early = $test$plusargs("NEG_DRAIN_EARLY");
        neg_block_overlap = $test$plusargs("NEG_BLOCK_OVERLAP");
        if (!(BA == 8 || BA == 4) || !(BW == 8 || BW == 4)) $fatal(1, "BA/BW must be 4 or 8");
        if (TA < 1 || BA % TA != 0 || TW < 1 || BW % TW != 0 || log2i(TA) < 0 || log2i(TW) < 0)
            $fatal(1, "TA must divide BA and TW divide BW (powers of two)");
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        GA = BA / TA;
        GW = BW / TW;
        ROWS_PE = N_H / GA;
        CPE = N_W / GW;
        NPASS = TA * TW;
        NLEV = TA + TW - 1;
        NB = L / (K*M);
        if (neg_asign_held && TA < 2) $fatal(1, "NEG_ASIGN_HELD needs TA >= 2");
        if (neg_gap_short && NLEV < 2) $fatal(1, "NEG_GAP_SHORT needs a lap");
        if (MROWS <= 0) MROWS = ROWS_PE;
        if (NCOLS <= 0) NCOLS = CPE;
        if (MROWS % ROWS_PE != 0 || NCOLS % CPE != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", ROWS_PE, CPE);
        amax = (GA > 1) ? ((longint'(1) << TA) - 1) : (longint'(1) << (TA-1));
        wmax = (GW > 1) ? ((longint'(1) << TW) - 1) : (longint'(1) << (TW-1));
        if (amax * wmax * L > (longint'(1) << (OWIDTH-1)) - 1)
            $fatal(1, "L=%0d can overflow the %0d-bit tile (field product max %0d)", L, OWIDTH, amax*wmax);
        NIG = MROWS / ROWS_PE;
        NJG = NCOLS / CPE;
        NBLK = NIG * NJG;
        if (neg_block_overlap && NBLK < 2) $fatal(1, "NEG_BLOCK_OVERLAP needs two blocks");
        LO = neg_gap_short ? -1 : 0;
        DS = neg_drain_early ? -1 : 0;
        off = 0;
        np = 0;
        for (int lv = 0; lv < NLEV; lv++) begin
            int k;
            k = NLEV - 1 - lv;
            for (int ta = TA - 1; ta >= 0; ta--) begin
                if (k - ta < 0 || k - ta > TW - 1) continue;
                pass_ta[np] = ta;
                pass_q[np] = k - ta;
                pass_off[np] = off;
                off += NB;
                np++;
            end
            lev_end[lv] = off;
            if (lv < NLEV - 1) off += 8 + LO;
        end
        if (np != NPASS) $fatal(1, "pass table built %0d passes, expected %0d", np, NPASS);
        ACTIVE = off;
        BLK_LEN = ACTIVE + DS + 8 - (neg_block_overlap ? 1 : 0);
        E_END = E0 + (NBLK-1)*BLK_LEN + ACTIVE + 1 + DS + N_W - 1;
        N_EDGES = E_END + 3;
        if (N_EDGES + 16 > `BPH_MAX_EDGES) $fatal(1, "schedule exceeds BPH_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        int_mode = 1'b1;
        int_prec = (BA == 4);
        rng_en = junk;
        ga_log2 = log2i(GA);
        ta_log2 = log2i(TA);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("bph_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open bph_trace.txt");
        $fwrite(trace_file, "BPHTCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, TA, TW, L, MROWS, NCOLS, NBLK, NB, NPASS, NLEV, LO, DS, BLK_LEN, E0, int'(BA == 4),
                junk, neg_asign_held, neg_gap_short, neg_block_overlap);
        cfg_done = 1'b1;

        for (int e = 0; e < N_EDGES; e++) begin
            cur_e = e;
            set_raw(e);
            set_signs(e);
            set_binary();
            if (junk) begin
                if (drain_at(e, bd, t)) acc_in_west = '0;
                else for (int q = 0; q < N_H*OWIDTH; q++) acc_in_west[q] = $urandom & 1;
            end
            ring_in = lap_at(e + 1);
            shift_in = drain_at(e, bd, t);
            hyb_cap = shift_in && !lap_at(e);
            if (hyb_cap) begin
                cap_hist[e] = 1'b1;
                n_cap++;
            end
            int_prec = (junk && !cap_hist.exists(e)) ? ($urandom & 1) : (BA == 4);
            mac_en = (e > E0);
            @(posedge clk);
            read_drain(e);
            read_comb(e);
            @(negedge clk);
        end
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = 1'b0;
        hyb_cap = 1'b0;
        cur_e = N_EDGES;
        @(posedge clk);
        @(negedge clk);

        if (n_drain != NBLK*N_W || n_comb != n_cap || n_hyb != n_cap)
            $fatal(1, "read %0d drained columns, %0d / %0d combiner words, expected %0d and %0d",
                   n_drain, n_comb, n_hyb, NBLK*N_W, n_cap);
        $fclose(trace_file);
        trace_file = 0;
        $display("PASS: BP hybrid top bench BA=%0d BW=%0d TA=%0d TW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d edges=%0d junk=%0d",
                 BA, BW, TA, TW, L, MROWS, NCOLS, NBLK, BLK_LEN, N_EDGES, junk);
        $finish;
    end
endmodule
