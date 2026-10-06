`timescale 1ns/1ps

`include "common/clk_util.sv"

// [ABIT COPY] of designs/payn/tb/test_pe_grid_cbsg_af_ipd.sv (sha256 4aaaac77...9382 at copy time, 2026-10-06),
// run on the same copied grid wrapper InnerPESignedSegmentedCsaBpIpdGridAfIpd
// (designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/inner_pe_grid_signed_segmented_csa_cbsg_af_ipd.sv,
// unchanged), with the ALL-BITS-IN-TIME schedule of doc/cbsg_handoff.md section 5 in place of the bit-plane
// schedule.  Kept from the original: the edge drive at the negedge before each capturing posedge, the per-PE lap
// wave (ring_in[r] with row r's skew, one edge ahead; the grid moves it one PE east per edge, so PE (r,c) laps at
// offset r+c), the global shift_in for the final drain only (8*P_C edges, acc_in_west = 0), the lap-run monitor
// (R records), the drain read (D records) and the reset rule (zero planes before the first MAC).  Like the
// original this bench drives the PE inputs directly (no AF edge, no INT bypass, no combiner: the grid wrapper has
// none); it is evidence for the IPD lap wave and the schedule on a grid, not for per-row/column AF edges.
//
// Mapping: output block blk = ig*NJG + jg; PE (r,c), tile (h,v) holds C[i, j] with
// i = (ig*P_R + r)*8 + h, j = (jg*P_C + c)*8 + v.  One pass per bit pair (p, q): PE row r's A bus carries bit p of
// its eight activation rows, PE column c's W bus bit q of its eight weight columns, chunk u = reduction elements
// 128u + 16k + m.  Passes grouped by level p + q, MSB level first (A bit ascending in a level), contiguous inside a
// level; between levels one bubble slice and one 1-edge lap.  Pass sign (p == BA-1) XOR (q == BW-1) on the W
// sign wave (load_w_sign_in[c] one edge ahead of column c's pass start); A signs 0, loaded once.
//
// Schedule ("virtual edge" = PE (0,0) time; PE row r sees it r edges late, column c c edges late).  A block's slots
// are those of the single-PE abit bench (+MODE=abit of test_payn_array_cbsg_af_ipd.sv): data slots, a bubble before
// every level step (the lap on the next level's first capture), one final bubble; the drain starts DS = S =
// P_R+P_C-2 edges after the single-PE drain point (the far PE's last MAC is S edges late) and lasts 8*P_C edges,
// the last drain edge being the next block's first capture.  Block period
//     BLK_LEN = BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + 8*P_C.
//
// Options: +BA +BW (2..8) +L (worst case L*2^(BA+BW-2) < 2^23 unless +ABIT_RANGE_DATA, for workloads whose
// actual GEMM fits, which the checker verifies) +MROWS +NCOLS (multiples of P_R*8 / P_C*8) +JUNK (random acc_in_west on every
// non-drain edge, random sign words on every edge where no PE latches them).  Negative controls (must FAIL):
//   +NEG_RING_NO_ROW_SKEW  ring_in[r] with row 0's timing: rows r > 0 lap r edges early
//   +NEG_RING_NO_COL_SKEW  every PE (r,c) takes the row's west ring_in directly (forced): columns c > 0 lap early
//   +NEG_ABIT_NO_BUBBLE    no bubble before a lap (each lap on a PE's last MAC of the level)
//   +NEG_DRAIN_EARLY       DS = S - 1 (the drain starts on the far PE's last MAC)
//   +NEG_BLOCK_OVERLAP     BLK_LEN one short (the next block's first MAC lands on the last drain edge)
//   +NEG_ABIT_NO_LAP=n     no lap before level n;  +NEG_ABIT_EXTRA_LAP=n  extra bubble + lap inside level n
//   +NEG_ABIT_SIGN=1       pass sign (q == BW-1) only;  +NEG_ABIT_ORDER=1  levels LSB first
// Trace abit_grid_trace.txt: header ABITGCFG, the virtual schedule (P/K/L/M records as the single-PE trace), the
// real drain edges (X e blk t), every drained column "D blk r t e tile_h0..tile_h7" (PE column P_C-1-t/8, tile
// column 7-t%8) and every PE's lap runs "R r c e_first len".  Checker:
// sweeps/cbsg/af_ipd/abit/check_abit_grid_trace.py.  Shape: +define+BPG_PR= +define+BPG_PC=.  RTL needs
// DesignWare (USE_DW=1).

`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/inner_pe_grid_signed_segmented_csa_cbsg_af_ipd.sv"
`define BPG_GRID_MODULE InnerPESignedSegmentedCsaBpIpdGridAfIpd

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
`define BPG_MAX_EDGES 400000
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
    localparam int S = P_R + P_C - 2;           // skew of the far PE
    localparam int E0 = 4;                      // first capture, PE (0,0)
    localparam real PERIOD = 2.5;
    localparam int AB = N_H*K*M, AS = N_H*K, WB = N_W*K*M, WS = N_W*K, AW = N_H*OWIDTH;
    localparam int ZERO_EDGES_BEFORE_MAC = 10;  // as the original bench

    int BA = 8, BW = 8, L = 128, MROWS = 0, NCOLS = 0;
    bit junk = 1'b0, neg_row = 1'b0, neg_col = 1'b0, neg_no_bubble = 1'b0, neg_drain_early = 1'b0, neg_overlap = 1'b0;
    int neg_no_lap = -1, neg_extra_lap = -1, neg_sign = 0, neg_order = 0;
    bit cfg_done = 1'b0;
    int NB, NIG, NJG, NBLK, NLEV, NP, D0, DS, BLK_NOM, BLK_LEN, FORMULA, E_END, N_EDGES;
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

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]
    integer trace_file;
    int n_drain = 0;

    // Passes and the per-virtual-edge schedule.
    int lev_k [$];
    int pp [$], pq [$], ps [$], pn [$];
    int cap_blk [], cap_pass [], cap_u [], start_pass [], drn_blk [], drn_t [];
    bit lap_v [];
    int NV;

    ClkUtils #(.TIMEOUT(`BPG_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

    `BPG_GRID_MODULE #(
        .P_ROWS(P_R), .P_COLS(P_C), .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (.*);

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] abit grid bench exceeded %0d cycles", `BPG_MAX_EDGES);

    for (genvar r = 0; r < P_R; r++) begin : g_force_r
        for (genvar c = 0; c < P_C; c++) begin : g_force_c
            initial begin
                wait (cfg_done);
                if (neg_col)
                    force dut.g_pe_row[r].g_pe_col[c].u_pe.ring_in = ring_in[r] & int_mode;
            end

            // Lap-run monitor: ring_q as used on each edge (pre-edge value).
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
    task automatic build_schedule();
        int sl_kind [$], sl_pass [$], sl_u [$];
        bit sl_lap [$];
        bit lap_next, first;
        int base, e;
        NLEV = BA + BW - 1;
        NP = BA * BW;
        lev_k.delete();
        for (int n = 0; n < NLEV; n++) lev_k.push_back(NLEV - 1 - n);
        if (neg_order == 1) lev_k.reverse();
        for (int n = 0; n < NLEV; n++)
            for (int p = 0; p < BA; p++) begin
                int q;
                q = lev_k[n] - p;
                if (q < 0 || q >= BW) continue;
                pp.push_back(p); pq.push_back(q); pn.push_back(n);
                ps.push_back(neg_sign == 1 ? (q == BW - 1) : ((p == BA - 1) ^ (q == BW - 1)));
            end
        lap_next = 1'b0;
        for (int j = 0; j < NP; j++) begin
            first = (j == 0) || (pn[j] != pn[j-1]);
            if (first && j > 0) begin
                if (!neg_no_bubble) begin
                    sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);
                end
                lap_next = (pn[j] != neg_no_lap);
            end
            if (!first && pn[j] == neg_extra_lap && pn[j-1] == neg_extra_lap && (j < 2 || pn[j-2] != neg_extra_lap)) begin
                if (!neg_no_bubble) begin
                    sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);
                end
                lap_next = 1'b1;
            end
            for (int u = 0; u < NB; u++) begin
                sl_kind.push_back(0); sl_pass.push_back(j); sl_u.push_back(u); sl_lap.push_back(lap_next && u == 0);
            end
            lap_next = 1'b0;
        end
        sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);   // last MAC
        D0 = sl_kind.size();
        DS = neg_drain_early ? S - 1 : S;
        BLK_NOM = D0 + DS + 8*P_C - 1;           // last drain edge = next block's first capture
        BLK_LEN = BLK_NOM - (neg_overlap ? 1 : 0);
        FORMULA = BA*BW*NB + (BA + BW - 2) + S + 8*P_C;
        E_END = E0 + (NBLK - 1)*BLK_LEN + BLK_NOM;
        N_EDGES = E_END + 2;
        NV = E_END + P_R + P_C + 8;
        cap_blk = new[NV]; cap_pass = new[NV]; cap_u = new[NV]; start_pass = new[NV];
        drn_blk = new[NV]; drn_t = new[NV]; lap_v = new[NV];
        for (int i = 0; i < NV; i++) begin
            cap_blk[i] = -1; cap_pass[i] = -1; cap_u[i] = -1; start_pass[i] = -1;
            drn_blk[i] = -1; drn_t[i] = -1; lap_v[i] = 1'b0;
        end
        for (int b = 0; b < NBLK; b++) begin
            base = E0 + b*BLK_LEN;
            for (int s = 0; s < D0; s++) begin
                e = base + s;
                if (sl_lap[s]) lap_v[e] = 1'b1;
                if (sl_kind[s] == 0) begin
                    cap_blk[e] = b; cap_pass[e] = sl_pass[s]; cap_u[e] = sl_u[s];
                    if (sl_u[s] == 0) start_pass[e] = sl_pass[s];
                end
            end
            for (int t = 0; t < 8*P_C; t++) begin
                e = base + D0 + DS + t;
                if (drn_blk[e] >= 0) $fatal(1, "two drains on edge %0d", e);
                drn_blk[e] = b; drn_t[e] = t;
            end
        end
    endtask

    function automatic bit in_v(input int v);
        return v >= 0 && v < NV;
    endfunction

    // Sign word in force at virtual edge v (the latest pass start <= v).
    int sign_now [];
    task automatic build_sign_now();
        int s;
        sign_now = new[NV];
        s = 0;
        for (int v = 0; v < NV; v++) begin
            if (start_pass[v] >= 0) s = ps[start_pass[v]];
            sign_now[v] = s;
        end
    endtask

    // ----------------------------------------------------------- drivers --
    task automatic drive(input int e);
        int v, blk, j, u, ig, jg, p, q, x;
        for (int r = 0; r < P_R; r++) begin
            logic [AB-1:0] a_next;
            a_next = '0;
            v = e - r;
            if (in_v(v) && cap_blk[v] >= 0) begin
                blk = cap_blk[v]; j = cap_pass[v]; u = cap_u[v];
                ig = blk / NJG; p = pp[j];
                for (int h = 0; h < N_H; h++)
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[((ig*P_R + r)*N_H + h)*L + x][p];
                        end
            end
            a_bits_in[r*AB +: AB] = a_next;
            load_a_sign_in[r] = (e + 1 - r == E0);
            a_signs_in[r*AS +: AS] = (junk && e - r != E0) ? AS'({$urandom, $urandom}) : '0;
        end
        for (int c = 0; c < P_C; c++) begin
            logic [WB-1:0] w_next;
            w_next = '0;
            v = e - c;
            if (in_v(v) && cap_blk[v] >= 0) begin
                blk = cap_blk[v]; j = cap_pass[v]; u = cap_u[v];
                jg = blk % NJG; q = pq[j];
                for (int vv = 0; vv < N_W; vv++)
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            w_next[(vv*K + k)*M + m] = w_mem[((jg*P_C + c)*N_W + vv)*L + x][q];
                        end
            end
            w_bits_in[c*WB +: WB] = w_next;
            load_w_sign_in[c] = in_v(e + 1 - c) && start_pass[e + 1 - c] >= 0;
            if (junk && !(in_v(v) && start_pass[v] >= 0))
                w_signs_in[c*WS +: WS] = WS'({$urandom, $urandom});
            else
                w_signs_in[c*WS +: WS] = (in_v(v) && sign_now[v]) ? '1 : '0;
        end
        for (int r = 0; r < P_R; r++)
            ring_in[r] = neg_row ? (in_v(e + 1) && lap_v[e + 1]) : (in_v(e + 1 - r) && lap_v[e + 1 - r]);
        shift_in = in_v(e) && drn_blk[e] >= 0;
        if (shift_in)
            acc_in_west = '0;
        else if (junk)
            for (int n = 0; n < P_R*AW; n++) acc_in_west[n] = $urandom & 1;
        mac_en = (e > E0);
    endtask

    task automatic log_schedule(input int e);
        if (!in_v(e)) return;
        if (e == E0 + 1) $fwrite(trace_file, "M %0d\n", e);
        if (start_pass[e] >= 0)
            $fwrite(trace_file, "P %0d %0d %0d %0d %0d %0d\n", e, cap_blk[e], start_pass[e],
                    pp[start_pass[e]], pq[start_pass[e]], ps[start_pass[e]]);
        if (cap_blk[e] >= 0) $fwrite(trace_file, "K %0d %0d %0d %0d\n", e, cap_blk[e], cap_pass[e], cap_u[e]);
        if (lap_v[e]) $fwrite(trace_file, "L %0d\n", e);
        if (drn_blk[e] >= 0) $fwrite(trace_file, "X %0d %0d %0d\n", e, drn_blk[e], drn_t[e]);
    endtask

    // Pre-edge acc_out_east of every PE row on a drain edge.
    task automatic read_drain(input int e);
        if (!(in_v(e) && drn_blk[e] >= 0)) return;
        for (int r = 0; r < P_R; r++) begin
            if ($isunknown(acc_out_east[r*AW +: AW]))
                $fatal(1, "[X-FAIL] drained column X: block %0d row %0d step %0d", drn_blk[e], r, drn_t[e]);
            $fwrite(trace_file, "D %0d %0d %0d %0d", drn_blk[e], r, drn_t[e], e);
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
        trace_file = 0;
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        junk = $test$plusargs("JUNK");
        neg_row = $test$plusargs("NEG_RING_NO_ROW_SKEW");
        neg_col = $test$plusargs("NEG_RING_NO_COL_SKEW");
        neg_no_bubble = $test$plusargs("NEG_ABIT_NO_BUBBLE");
        neg_drain_early = $test$plusargs("NEG_DRAIN_EARLY");
        neg_overlap = $test$plusargs("NEG_BLOCK_OVERLAP");
        void'($value$plusargs("NEG_ABIT_NO_LAP=%d", neg_no_lap));
        void'($value$plusargs("NEG_ABIT_EXTRA_LAP=%d", neg_extra_lap));
        void'($value$plusargs("NEG_ABIT_SIGN=%d", neg_sign));
        void'($value$plusargs("NEG_ABIT_ORDER=%d", neg_order));
        if (ZERO_EDGES_BEFORE_MAC < ((P_R < P_C) ? P_R : P_C))
            $fatal(1, "grid %0dx%0d needs %0d zero-plane edges before the first MAC", P_R, P_C, (P_R < P_C) ? P_R : P_C);
        if (BA < 2 || BA > 8 || BW < 2 || BW > 8) $fatal(1, "BA, BW must be 2..8");
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        NB = L / (K*M);
        if (MROWS <= 0) MROWS = P_R*N_H;
        if (NCOLS <= 0) NCOLS = P_C*N_W;
        if (MROWS % (P_R*N_H) != 0 || NCOLS % (P_C*N_W) != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", P_R*N_H, P_C*N_W);
        if (longint'(L) * (longint'(1) << (BA + BW - 2)) > (longint'(1) << (OWIDTH-1)) - 1 &&
            !$test$plusargs("ABIT_RANGE_DATA"))
            $fatal(1, "L=%0d at BA=%0d BW=%0d can overflow the %0d-bit tile (+ABIT_RANGE_DATA: data-dependent range)",
                   L, BA, BW, OWIDTH);
        NIG = MROWS / (P_R*N_H);
        NJG = NCOLS / (P_C*N_W);
        NBLK = NIG * NJG;
        build_schedule();
        build_sign_now();
        if (N_EDGES + 16 > `BPG_MAX_EDGES) $fatal(1, "schedule exceeds BPG_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("abit_grid_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open abit_grid_trace.txt");
        $fwrite(trace_file, "ABITGCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, NB, E0, E_END, BLK_LEN, D0, DS, FORMULA, NLEV,
                junk, neg_row, neg_col, neg_no_bubble, neg_drain_early, neg_overlap, neg_no_lap, neg_extra_lap,
                neg_sign, neg_order);
        cfg_done = 1'b1;

        for (int e = 0; e < N_EDGES; e++) begin
            cur_e = e;
            drive(e);
            log_schedule(e);
            @(posedge clk);                      // P_e
            read_drain(e);
            @(negedge clk);
        end
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = '0;
        cur_e = N_EDGES;
        @(posedge clk);                          // flush open lap runs
        @(negedge clk);

        if (n_drain != NBLK*P_R*8*P_C)
            $fatal(1, "drained %0d columns, expected %0d", n_drain, NBLK*P_R*8*P_C);
        $fclose(trace_file);
        trace_file = 0;
        $display("PASS: ABIT grid bench P=%0dx%0d BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d block_len=%0d formula=%0d edges=%0d junk=%0d",
                 P_R, P_C, BA, BW, L, MROWS, NCOLS, NBLK, BLK_LEN, FORMULA, N_EDGES, junk);
        $finish;
    end
endmodule
