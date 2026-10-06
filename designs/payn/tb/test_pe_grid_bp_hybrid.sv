`timescale 1ns/1ps

`include "common/clk_util.sv"

// BP-hybrid INT bench for a P_R x P_C grid of the UNCHANGED carry-save BP PE
// (InnerPESignedSegmentedCsaBpGrid, csa_bp_20261004_lap RTL).  Written for the
// adversarial schedule review of the "execute through the reduction, then
// shift" study: it tests whether putting ACTIVATION bits (partly) in time as
// well as weight bits gives more outputs per PE per drain, and so amortises
// the drain + skew + laps over more MACs, with no tile, PE or grid change.
// Edge-drive conventions as test_pe_grid_bp_space.sv (not changed).
//
// Mapping.  TA activation bits and TW weight bits in TIME per tile, so
// GA = BA/TA activation-bit groups and GW = BW/TW weight-bit groups in SPACE:
//   tile row h     activation row i = (ig*P_R + r)*ROWS_PE + h / GA,
//                  group g = h % GA (activation bits g*TA .. g*TA+TA-1),
//                  ROWS_PE = 8/GA
//   tile column v  output column j = (jg*P_C + c)*CPE + v / GW,
//                  group s = v % GW (weight bits s*TW .. s*TW+TW-1), CPE = 8/GW
//   pass (ta, q)   tile row (i,g) carries activation bit g*TA + ta, tile
//                  column (j,s) carries weight bit s*TW + q; TA*TW passes.
// Horner over the time bits: level k = ta + q, k = TA+TW-2 first; the passes of
// one level run back to back, and one 8-edge per-PE ring lap (the existing
// ring, ring_in[r] one edge ahead with row r's A skew) doubles every tile
// between levels: TA+TW-2 laps.  The sign words are reloaded on every pass
// (sign waves skewed like the operands): a_signs row h = (g*TA + ta == BA-1),
// w_signs column v = (s*TW + q == BW-1), all lanes.  So each drained tile is
//     T((i,g),(j,s)) = sum_x Afield_g[i,x] * Wfield_s[x,j]
// (field = those bits, signed iff it holds the MSB), and the east-edge combine
// is out(i,j) = sum_g sum_s 2^(g*TA + s*TW) T.
// TA = 1, TW = BW is the as-built T1 mapping (one activation row of BA planes,
// 8 output columns); TA = TW = 1 is T2 S = BW.
// Block period (virtual edges; NB = L/128):
//     BLK_LEN = TA*TW*NB + 8*(TA+TW-2) + (P_R+P_C-2) + 8*P_C
//
// Plusargs: +BA=<4|8> +BW=<4|8> +TA=<1|2|4|8, divides BA> +TW=<1|2|4|8,
//   divides BW> +L=<multiple of 128> +MROWS=<multiple of P_R*ROWS_PE>
//   +NCOLS=<multiple of P_C*CPE>  +JUNK (random acc_in_west on every non-drain
//   edge, random sign words on every edge where no PE latches them).
//   Negative controls (must FAIL with tile / output mismatches):
//   +NEG_ASIGN_HELD   activation sign word held as in T1 (top group negative in
//                     every pass) instead of reloaded per pass (needs TA > 1)
//   +NEG_DRAIN_EARLY  drain starts on the far PE's last MAC (DS = Sk - 1)
//   +NEG_BLOCK_OVERLAP BLK_LEN - 1 (>= 2 blocks)
//   +NEG_GAP_SHORT    every lap starts on the PE's last MAC of the level
//
// Trace bpg_trace.txt: header BPHGCFG, "D blk r t e tile_h0..h7" per drain
// read, "R r c e_first len" per PE ring_q run.  Checker:
// sweeps/int_mode/bp/hybrid/check_bp_hybrid_trace.py.  Operands bpt_a.hex /
// bpt_w.hex (sweeps/int_mode/bp/space/gen_bp_space_workload.py).
// Shape: +define+BPG_PR=, +define+BPG_PC=.  RTL needs DesignWare.

`include "payn/variants/signed_segmented_csa_bp/inner_pe_grid_signed_segmented_csa_bp.sv"

`ifndef BPG_PR
`define BPG_PR 2
`endif
`ifndef BPG_PC
`define BPG_PC 2
`endif
`ifndef BPG_LOW_W
`define BPG_LOW_W 9
`endif
`ifndef BPG_MAX_EDGES
`define BPG_MAX_EDGES 2000000
`endif

module Top;
    localparam int P_R = `BPG_PR;
    localparam int P_C = `BPG_PC;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int OWIDTH = 24;
    localparam int LOW_W = `BPG_LOW_W;
    localparam int SK = P_R + P_C - 2;
    localparam int E0 = 4;
    localparam real PERIOD = 2.5;
    localparam int AB = N_H*K*M, AS = N_H*K, WB = N_W*K*M, WS = N_W*K, AW = N_H*OWIDTH;
    localparam int ZERO_EDGES_BEFORE_MAC = 10;
    localparam int MAX_PASS = 64;

    localparam int MODE_PE = 0, MODE_NEG_ASIGN_HELD = 1, MODE_NEG_DRAIN_EARLY = 4,
                   MODE_NEG_BLOCK_OVERLAP = 5, MODE_NEG_GAP_SHORT = 6;

    int BA = 8, BW = 8, TA = 1, TW = 8, L = 128, MROWS = 0, NCOLS = 0;
    int mode = MODE_PE;
    bit junk = 1'b0;
    bit cfg_done = 1'b0;
    int GA, GW, ROWS_PE, CPE, NPASS, NLEV, NB, NIG, NJG, NBLK, GAP, LO, DS, ACTIVE, BLK_LEN, E_END, N_EDGES;
    int pass_ta [MAX_PASS];
    int pass_q  [MAX_PASS];
    int pass_off[MAX_PASS];
    int lev_end [MAX_PASS];
    int cur_e = -1000;

    logic clk, reset, timeout;
    logic mac_en = 1'b0, shift_in = 1'b0, int_mode = 1'b1;
    logic [P_R-1:0] ring_in = '0;
    logic [P_R*AB-1:0] a_bits_in = '0;
    logic [P_R*AS-1:0] a_signs_in = '0;
    logic [P_C*WB-1:0] w_bits_in = '0;
    logic [P_C*WS-1:0] w_signs_in = '0;
    logic [P_R-1:0] load_a_sign_in = '0;
    logic [P_C-1:0] load_w_sign_in = '0;
    logic [P_R*AB-1:0] a_bits_out;
    logic [P_R*AS-1:0] a_signs_out;
    logic [P_C*WB-1:0] w_bits_out;
    logic [P_C*WS-1:0] w_signs_out;
    logic [P_R-1:0] load_a_sign_out;
    logic [P_C-1:0] load_w_sign_out;
    logic [P_R-1:0] ring_out;
    logic [P_R*AW-1:0] acc_in_west = '0;
    logic [P_R*AW-1:0] acc_out_east;

    logic [7:0] a_mem [];
    logic [7:0] w_mem [];
    integer trace_file;
    int n_drain = 0;

    ClkUtils #(.TIMEOUT(`BPG_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

    InnerPESignedSegmentedCsaBpGrid #(
        .P_ROWS(P_R), .P_COLS(P_C), .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (.*);

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] BP hybrid grid bench exceeded %0d cycles", `BPG_MAX_EDGES);

    for (genvar r = 0; r < P_R; r++) begin : g_mon_r
        for (genvar c = 0; c < P_C; c++) begin : g_mon_c
            int run_start = -1, run_len = 0;
            always @(posedge clk) begin
                if (cfg_done && trace_file != 0) begin
                    if (dut.g_pe_row[r].g_pe_col[c].u_pe.ring_q === 1'b1) begin
                        if (run_len == 0) run_start = cur_e;
                        run_len++;
                    end else begin
                        if (dut.g_pe_row[r].g_pe_col[c].u_pe.ring_q !== 1'b0)
                            $fatal(1, "[X-FAIL] PE (%0d,%0d) ring_q X at edge %0d", r, c, cur_e);
                        if (run_len != 0) $fwrite(trace_file, "R %0d %0d %0d %0d\n", r, c, run_start, run_len);
                        run_len = 0;
                    end
                end
            end
        end
    end

    // ---------------------------------------------------------- schedule --
    function automatic bit decode(input int v, output int blk, output int u);
        if (v < E0 || v >= E0 + NBLK*BLK_LEN) return 1'b0;
        blk = (v - E0) / BLK_LEN;
        u = (v - E0) % BLK_LEN;
        return 1'b1;
    endfunction

    function automatic bit data_at(input int v, output int blk, output int n, output int b);
        int u;
        if (!decode(v, blk, u)) return 1'b0;
        for (int p = 0; p < NPASS; p++)
            if (u >= pass_off[p] && u < pass_off[p] + NB) begin
                n = p;
                b = u - pass_off[p];
                return 1'b1;
            end
        return 1'b0;
    endfunction

    function automatic bit lap_at(input int v);
        int blk, u;
        if (!decode(v, blk, u)) return 1'b0;
        if (u == 0) return 1'b0;
        for (int lv = 0; lv < NLEV - 1; lv++)
            if (u >= lev_end[lv] + LO + 1 && u <= lev_end[lv] + LO + 8) return 1'b1;
        return 1'b0;
    endfunction

    function automatic bit pass_first_at(input int v);
        int blk, n, b;
        if (!data_at(v, blk, n, b)) return 1'b0;
        return b == 0;
    endfunction

    function automatic int sign_pass(input int v);
        int blk, u, n;
        if (!decode(v, blk, u)) return 0;
        n = 0;
        for (int p = 0; p < NPASS; p++)
            if (pass_off[p] <= u) n = p;
        return n;
    endfunction

    function automatic logic [AS-1:0] a_word(input int n);
        logic [AS-1:0] wd;
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                wd[h*K + k] = (mode == MODE_NEG_ASIGN_HELD) ? ((h % GA) == GA - 1)
                                                           : ((h % GA)*TA + pass_ta[n] == BA - 1);
        return wd;
    endfunction

    function automatic logic [WS-1:0] w_word(input int n);
        logic [WS-1:0] wd;
        for (int v = 0; v < N_W; v++)
            for (int k = 0; k < K; k++)
                wd[v*K + k] = ((v % GW)*TW + pass_q[n] == BW - 1);
        return wd;
    endfunction

    function automatic bit drain_at(input int e, output int blk, output int t);
        int d0, bb;
        if (e <= E0) return 1'b0;
        bb = (e - E0) / BLK_LEN;
        for (int b = bb; b >= bb - 1 && b >= 0; b--) begin
            if (b >= NBLK) continue;
            d0 = E0 + b*BLK_LEN + ACTIVE + 1 + DS;
            if (e - d0 >= 0 && e - d0 < 8*P_C) begin
                blk = b;
                t = e - d0;
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    // ----------------------------------------------------------- drivers --
    task automatic drive(input int e);
        int blk, n, b, ig, jg, i, j, x, bit_i, t, dblk;
        bit drain;
        for (int r = 0; r < P_R; r++) begin
            logic [AB-1:0] a_next;
            a_next = '0;
            if (data_at(e - r, blk, n, b)) begin
                ig = blk / NJG;
                for (int h = 0; h < N_H; h++) begin
                    i = (ig*P_R + r)*ROWS_PE + h / GA;
                    bit_i = (h % GA)*TA + pass_ta[n];
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = b*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[i*L + x][bit_i];
                        end
                end
            end
            a_bits_in[r*AB +: AB] = a_next;
            load_a_sign_in[r] = pass_first_at(e + 1 - r);
            if (junk && !pass_first_at(e - r))
                a_signs_in[r*AS +: AS] = AS'({$urandom, $urandom});
            else
                a_signs_in[r*AS +: AS] = a_word(sign_pass(e - r));
        end
        for (int c = 0; c < P_C; c++) begin
            logic [WB-1:0] w_next;
            w_next = '0;
            if (data_at(e - c, blk, n, b)) begin
                jg = blk % NJG;
                for (int v = 0; v < N_W; v++) begin
                    j = (jg*P_C + c)*CPE + v / GW;
                    bit_i = (v % GW)*TW + pass_q[n];
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = b*K*M + k*M + m;
                            w_next[(v*K + k)*M + m] = w_mem[j*L + x][bit_i];
                        end
                end
            end
            w_bits_in[c*WB +: WB] = w_next;
            load_w_sign_in[c] = pass_first_at(e + 1 - c);
            if (junk && !pass_first_at(e - c))
                w_signs_in[c*WS +: WS] = WS'({$urandom, $urandom});
            else
                w_signs_in[c*WS +: WS] = w_word(sign_pass(e - c));
        end
        for (int r = 0; r < P_R; r++)
            ring_in[r] = lap_at(e + 1 - r);
        drain = drain_at(e, dblk, t);
        shift_in = drain;
        if (drain)
            acc_in_west = '0;
        else if (junk)
            for (int q = 0; q < P_R*AW; q++) acc_in_west[q] = $urandom & 1;
        mac_en = (e > E0);
    endtask

    task automatic read_drain(input int e);
        int blk, t;
        if (!drain_at(e, blk, t)) return;
        for (int r = 0; r < P_R; r++) begin
            if ($isunknown(acc_out_east[r*AW +: AW]))
                $fatal(1, "[X-FAIL] drained column X: block %0d row %0d step %0d", blk, r, t);
            $fwrite(trace_file, "D %0d %0d %0d %0d", blk, r, t, e);
            for (int h = 0; h < N_H; h++)
                $fwrite(trace_file, " %0d", $signed(acc_out_east[(r*N_H + h)*OWIDTH +: OWIDTH]));
            $fwrite(trace_file, "\n");
            n_drain++;
        end
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

    initial begin
        longint amax, wmax;
        int off, np;
        trace_file = 0;
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("TA=%d", TA));
        void'($value$plusargs("TW=%d", TW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        junk = $test$plusargs("JUNK");
        if ($test$plusargs("NEG_ASIGN_HELD")) mode = MODE_NEG_ASIGN_HELD;
        if ($test$plusargs("NEG_DRAIN_EARLY")) mode = MODE_NEG_DRAIN_EARLY;
        if ($test$plusargs("NEG_BLOCK_OVERLAP")) mode = MODE_NEG_BLOCK_OVERLAP;
        if ($test$plusargs("NEG_GAP_SHORT")) mode = MODE_NEG_GAP_SHORT;
        if (ZERO_EDGES_BEFORE_MAC < ((P_R < P_C) ? P_R : P_C))
            $fatal(1, "grid needs more zero-plane edges before the first MAC");
        if (!(BA == 8 || BA == 4) || !(BW == 8 || BW == 4)) $fatal(1, "BA/BW must be 4 or 8");
        if (TA < 1 || BA % TA != 0 || TW < 1 || BW % TW != 0) $fatal(1, "TA must divide BA and TW divide BW");
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        GA = BA / TA;
        GW = BW / TW;
        if (N_H % GA != 0 || N_W % GW != 0) $fatal(1, "GA must divide N_H and GW divide N_W");
        ROWS_PE = N_H / GA;
        CPE = N_W / GW;
        NPASS = TA * TW;
        NLEV = TA + TW - 1;
        NB = L / (K*M);
        if (mode == MODE_NEG_ASIGN_HELD && TA < 2) $fatal(1, "NEG_ASIGN_HELD needs TA >= 2");
        if (mode == MODE_NEG_GAP_SHORT && NLEV < 2) $fatal(1, "NEG_GAP_SHORT needs a lap");
        if (MROWS <= 0) MROWS = P_R*ROWS_PE;
        if (NCOLS <= 0) NCOLS = P_C*CPE;
        if (MROWS % (P_R*ROWS_PE) != 0 || NCOLS % (P_C*CPE) != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", P_R*ROWS_PE, P_C*CPE);
        amax = (GA > 1) ? ((longint'(1) << TA) - 1) : (longint'(1) << (TA-1));
        wmax = (GW > 1) ? ((longint'(1) << TW) - 1) : (longint'(1) << (TW-1));
        if (amax * wmax * L > (longint'(1) << (OWIDTH-1)) - 1)
            $fatal(1, "L=%0d can overflow the %0d-bit tile (field product max %0d)", L, OWIDTH, amax*wmax);
        NIG = MROWS / (P_R*ROWS_PE);
        NJG = NCOLS / (P_C*CPE);
        NBLK = NIG * NJG;
        if (mode == MODE_NEG_BLOCK_OVERLAP && NBLK < 2) $fatal(1, "NEG_BLOCK_OVERLAP needs two blocks");
        LO = (mode == MODE_NEG_GAP_SHORT) ? -1 : 0;
        GAP = 8 + LO;
        DS = (mode == MODE_NEG_DRAIN_EARLY) ? SK - 1 : SK;
        // Pass order: Horner level k = TA+TW-2 first; within a level, ta high first.
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
            if (lv < NLEV - 1) off += GAP;
        end
        if (np != NPASS) $fatal(1, "pass table built %0d passes, expected %0d", np, NPASS);
        ACTIVE = off;
        BLK_LEN = ACTIVE + DS + 8*P_C - ((mode == MODE_NEG_BLOCK_OVERLAP) ? 1 : 0);
        E_END = E0 + (NBLK-1)*BLK_LEN + ACTIVE + 1 + DS + 8*P_C - 1;
        N_EDGES = E_END + 2;
        if (N_EDGES + 16 > `BPG_MAX_EDGES) $fatal(1, "schedule exceeds BPG_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("bpg_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open bpg_trace.txt");
        $fwrite(trace_file, "BPHGCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                P_R, P_C, BA, BW, TA, TW, L, MROWS, NCOLS, NBLK, NB, NPASS, NLEV, GAP, LO, SK, DS,
                BLK_LEN, E0, mode, int'(junk));
        cfg_done = 1'b1;

        for (int e = 0; e < N_EDGES; e++) begin
            cur_e = e;
            drive(e);
            @(posedge clk);
            read_drain(e);
            @(negedge clk);
        end
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = '0;
        cur_e = N_EDGES;
        @(posedge clk);
        @(negedge clk);

        if (n_drain != NBLK*P_R*8*P_C)
            $fatal(1, "drained %0d columns, expected %0d", n_drain, NBLK*P_R*8*P_C);
        $fclose(trace_file);
        trace_file = 0;
        $display("PASS: BP hybrid grid bench P=%0dx%0d BA=%0d BW=%0d TA=%0d TW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d edges=%0d mode=%0d junk=%0d",
                 P_R, P_C, BA, BW, TA, TW, L, MROWS, NCOLS, NBLK, BLK_LEN, N_EDGES, mode, junk);
        $finish;
    end
endmodule
