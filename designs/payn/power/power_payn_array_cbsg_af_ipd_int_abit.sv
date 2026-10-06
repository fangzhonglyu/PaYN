`timescale 1ns/1ps

`include "common/clk_util.sv"

// [ABIT COPY] of designs/payn/power/power_payn_array_cbsg_af_ipd_int.sv (sha256 4a816718...b6cd at copy time,
// 2026-10-06; the AF-IPD INT energy bench, unchanged by this copy) for the ALL-BITS-IN-TIME INT schedule of
// doc/cbsg_handoff.md section 5 on the same top, payn_array_signed_segmented_csa_cbsg_af_ipd, with no RTL change.
// Kept from the original: the DUT and GL hooks (PAYN_ARRAY_DUT, SDF_FILE), the clock and reset, the INT entry
// (reset in SC mode, int_mode raised at the negedge before P_{MODE_AT}, default 1, first raw capture at P_E0, E0 = 4,
// the zero-load with the first pass's sign loads at P_{E0-1}), the SC side quiet for the whole run (rng_en = 0,
// a_binary_in = w_binary_in = 0, a_len_in = 0, block_start = slice_start = 0, acc_in_west = 0), every input launched
// at the negedge before the capturing posedge, shift_in on drain edges only (laps on ring_q alone, the
// lap_ring_only contract), the X monitors, the int_out_valid timing check ([TIMING-FAIL]: exactly two edges after
// each drain edge), the 1 ps SAIF window marks, the [CBSG-AF-CONTRACT] count check in RTL, and the operand files
// bpt_a.hex / bpt_w.hex.  Changed (the schedule and what is recorded):
//
// Mapping: every tile holds one output.  Block blk = ig*NJG + jg: tile row h = activation row ig*8 + h, column v =
// weight column jg*8 + v.  One pass per bit pair (p, q): a_raw_in row h carries bit p of A[ig*8 + h, x], w_raw_in
// column v bit q of W[x, jg*8 + v], lane k / position m of chunk u carrying x = 128u + 16k + m; NB = L/128 chunks
// per pass.  Passes grouped by level p + q, MSB level first (A bit ascending inside a level), contiguous inside a
// level; between levels one bubble capture and one 1-edge lap (ring_in one edge ahead); pass sign
// (p == BA-1) XOR (q == BW-1) on the W side (load_w + load_w_sign one edge ahead of the pass, zero magnitudes);
// A signs 0, loaded once with the zero-load.  After the last level one bubble (the last MAC), then the drain:
// shift_in on 8 edges with acc_in_west = 0, the 8th being the next block's first capture; the 8 raw rows are read
// from acc_out_east (the combiner still captures and its words are recorded, but this schedule does not use them).
// Block period BLK = BA*BW*NB + (BA+BW-2) + 8 edges; int_prec = 0.
//
// SAIF windows (the original's classing by interval count).  Interval I_e = (P_e + 1 ps, P_{e+1} + 1 ps] holds the
// response to edge P_e; e runs over [E0, E_END), E_END = the final drain edge.  I_e is DATA if P_e captures a data
// chunk (lap edges included: a lap edge is also the next level's first capture), LAP if P_e captures the bubble
// before a lap (its interval holds the level's last MAC), DRAIN if P_e is the block's final bubble (the last MAC)
// or one of the first 7 drain edges (the 8th is the next block's first capture, DATA).  Per block: BA*BW*NB DATA,
// BA+BW-2 LAP, 8 DRAIN intervals, as the original's BW*NB data, (BW-1) ring, 8 drain.
//   BPA_SAIF_MODE 0: data + lap (drain paused, the SC / INT methodology: headline numbers are drain-excluded)
//   BPA_SAIF_MODE 1: data only (peak)
//   BPA_SAIF_MODE 2: everything, drain included
//
// Trace abit_trace.txt, read by sweeps/cbsg/af_ipd/abit/check_abit_power_trace.py (which runs the functional
// checker's data / schedule / period / replay checks): the functional bench's records (ABITCFG header with the
// negative-control fields at their defaults, P / K / L / X / M schedule records, C combiner words) with the drain
// edge in each D record ("D blk t e tile_h0..tile_h7", column v = 7 - t).  Window record abit_saif.txt:
//   ABITSAIF BA BW L MROWS NCOLS NBLK NB SAIF_MODE MODE_AT E0 E_END N_EDGES BLK_LEN D0
//   SAIFWIN active data lap drain segments
//
// Configuration: compile-time defines BPA_BA, BPA_BW (2..8), BPA_L, BPA_MROWS, BPA_NCOLS (multiples of 8),
// BPA_SAIF_MODE, BPA_MODE_AT (make sim passes no runtime arguments), each overridable by the plusarg of the same
// name without the prefix.  Worst case L * 2^(BA+BW-2) must fit the signed 24-bit tile.  RTL needs DesignWare
// (USE_DW=1) and is instantiated with LOW_W = 9 like the route.

`ifndef GL_SIM
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/payn_array_signed_segmented_csa_cbsg_af_ipd.sv"
`endif

`ifndef PAYN_ARRAY_DUT
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa_cbsg_af_ipd
`endif
`ifndef BPA_BA
`define BPA_BA 8
`endif
`ifndef BPA_BW
`define BPA_BW 8
`endif
`ifndef BPA_L
`define BPA_L 384
`endif
`ifndef BPA_MROWS
`define BPA_MROWS 8
`endif
`ifndef BPA_NCOLS
`define BPA_NCOLS 8
`endif
`ifndef BPA_SAIF_MODE
`define BPA_SAIF_MODE 0
`endif
`ifndef BPA_MODE_AT
`define BPA_MODE_AT 1
`endif
`ifndef BPA_LOW_W
`define BPA_LOW_W 9
`endif
`ifndef BPA_MAX_EDGES
`define BPA_MAX_EDGES 200000
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int LOW_W = `BPA_LOW_W;
    localparam int E0 = 4;                      // first data capture edge
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    int BA = `BPA_BA, BW = `BPA_BW, L = `BPA_L;
    int MROWS = `BPA_MROWS, NCOLS = `BPA_NCOLS;
    int SAIF_MODE = `BPA_SAIF_MODE, MODE_AT = `BPA_MODE_AT;
    int NB, NIG, NJG, NBLK, NLEV, NP, D0, BLK_LEN, E_END, N_EDGES, NV;

    logic clk, reset, timeout;

    // SC-side inputs: never driven away from zero (INT contract).
    logic rng_en = 1'b0;
    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*WIDTH-1:0]   a_len_in = '0;
    logic block_start = 1'b0, slice_start = 1'b0;

    logic mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    logic int_mode = 1'b0, int_prec = 1'b0, ring_in = 1'b0;
    logic [N_H*K*M-1:0] a_raw_in = '0;
    logic [N_W*K*M-1:0] w_raw_in = '0;
    logic [63:0] int_out;
    logic int_out_valid;

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]

    // Passes and the per-edge schedule.
    int pp [$], pq [$], ps [$], pn [$];
    int cap_blk [], cap_pass [], cap_u [], start_pass [], drn_blk [], drn_t [], cls [];
    bit lap_e [];

    integer trace_file, saif_file;
    bit monitor_x = 1'b0;
    bit collecting = 1'b0;
    int n_drain = 0, n_comb = 0;
    int n_active = 0, n_data = 0, n_lap = 0, n_drain_iv = 0, n_segments = 0;

    ClkUtils #(.TIMEOUT(`BPA_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

`ifdef GL_SIM
    `PAYN_ARRAY_DUT dut (.*);
`else
    `PAYN_ARRAY_DUT #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH),
        .LOW_W(LOW_W)
    ) dut (.*);
`endif

`ifdef GL_SIM
    initial begin
`ifndef NO_SDF
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
`endif
    end
`endif

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] abit INT energy bench exceeded %0d cycles", `BPA_MAX_EDGES);

    // Architectural outputs must stay known from the first data edge on.
    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drain rail entered X: %h", acc_out_east);
    always @(int_out or int_out_valid)
        if (monitor_x && ($isunknown(int_out) || $isunknown(int_out_valid)))
            $fatal(1, "[X-FAIL] combiner output entered X: valid=%b out=%h", int_out_valid, int_out);

    // ---------------------------------------------------------- schedule --
    task automatic build_schedule();
        int sl_kind [$], sl_pass [$], sl_u [$];  // 0 data, 1 lap bubble, 2 final bubble
        bit sl_lap [$];
        bit lap_next, first;
        int base, e;
        NLEV = BA + BW - 1;
        NP = BA * BW;
        for (int n = 0; n < NLEV; n++)
            for (int p = 0; p < BA; p++) begin
                int q;
                q = (NLEV - 1 - n) - p;
                if (q < 0 || q >= BW) continue;
                pp.push_back(p); pq.push_back(q); pn.push_back(n);
                ps.push_back((p == BA - 1) ^ (q == BW - 1));
            end
        lap_next = 1'b0;
        for (int j = 0; j < NP; j++) begin
            first = (j == 0) || (pn[j] != pn[j-1]);
            if (first && j > 0) begin
                sl_kind.push_back(1); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);
                lap_next = 1'b1;
            end
            for (int u = 0; u < NB; u++) begin
                sl_kind.push_back(0); sl_pass.push_back(j); sl_u.push_back(u); sl_lap.push_back(lap_next && u == 0);
            end
            lap_next = 1'b0;
        end
        sl_kind.push_back(2); sl_pass.push_back(-1); sl_u.push_back(-1); sl_lap.push_back(1'b0);
        D0 = sl_kind.size();
        BLK_LEN = D0 + N_W - 1;
        E_END = E0 + NBLK*BLK_LEN;               // final drain edge
        N_EDGES = E_END + 3;                     // + combiner latency
        NV = N_EDGES + 2;
        cap_blk = new[NV]; cap_pass = new[NV]; cap_u = new[NV]; start_pass = new[NV];
        drn_blk = new[NV]; drn_t = new[NV]; cls = new[NV]; lap_e = new[NV];
        for (int i = 0; i < NV; i++) begin
            cap_blk[i] = -1; cap_pass[i] = -1; cap_u[i] = -1; start_pass[i] = -1;
            drn_blk[i] = -1; drn_t[i] = -1; cls[i] = -1; lap_e[i] = 1'b0;
        end
        for (int b = 0; b < NBLK; b++) begin
            base = E0 + b*BLK_LEN;
            for (int s = 0; s < D0; s++) begin
                e = base + s;
                cls[e] = sl_kind[s];             // 0 data, 1 lap, 2 drain (final bubble)
                if (sl_lap[s]) lap_e[e] = 1'b1;
                if (sl_kind[s] == 0) begin
                    cap_blk[e] = b; cap_pass[e] = sl_pass[s]; cap_u[e] = sl_u[s];
                    if (sl_u[s] == 0) start_pass[e] = sl_pass[s];
                end
            end
            for (int t = 0; t < N_W; t++) begin
                e = base + D0 + t;
                drn_blk[e] = b; drn_t[e] = t;
                if (t < N_W - 1) cls[e] = 2;     // the 8th is the next block's first capture (DATA)
            end
        end
    endtask

    function automatic bit drain_at(input int e);
        return e >= 0 && e < NV && drn_blk[e] >= 0;
    endfunction

    function automatic bit lap_at(input int e);
        return e >= 0 && e < NV && lap_e[e];
    endfunction

    function automatic bit interval_active(input int e);
        if (e < E0 || e >= E_END) return 1'b0;
        case (SAIF_MODE)
            0: return cls[e] != 2;
            1: return cls[e] == 0;
            default: return 1'b1;
        endcase
    endfunction

    // Raw planes captured at P_e, assembled in temporaries and applied in one
    // assignment (one event per input bus per cycle).
    task automatic set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, j, u, ig, jg, p, q, x;
        a_next = '0;
        w_next = '0;
        if (e >= 0 && e < NV && cap_blk[e] >= 0) begin
            blk = cap_blk[e]; j = cap_pass[e]; u = cap_u[e];
            ig = blk / NJG; jg = blk % NJG;
            p = pp[j]; q = pq[j];
            for (int h = 0; h < N_H; h++)
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = u*K*M + k*M + m;
                        a_next[(h*K + k)*M + m] = a_mem[(ig*N_H + h)*L + x][p];
                    end
            for (int v = 0; v < N_W; v++)
                for (int k = 0; k < K; k++)
                    for (int m = 0; m < M; m++) begin
                        x = u*K*M + k*M + m;
                        w_next[(v*K + k)*M + m] = w_mem[(jg*N_W + v)*L + x][q];
                    end
        end
        a_raw_in = a_next;
        w_raw_in = w_next;
    endtask

    // W sign loads at P_e for a pass whose first raw plane is captured at P_{e+1};
    // the first one (P_{E0-1}) loads both sides with zero magnitudes and A sign 0.
    task automatic set_signs(input int e);
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
        if (e + 1 >= 0 && e + 1 < NV && start_pass[e + 1] >= 0) begin
            w_signs_in = ps[start_pass[e + 1]] ? '1 : '0;
            load_w = 1'b1;
            load_w_sign = 1'b1;
            if (e + 1 == E0) begin
                a_signs_in = '0;
                load_a = 1'b1;
                load_a_sign = 1'b1;
            end
        end
    endtask

    task automatic log_schedule(input int e);
        if (e == E0 + 1) $fwrite(trace_file, "M %0d\n", e);
        if (e >= NV) return;
        if (start_pass[e] >= 0)
            $fwrite(trace_file, "P %0d %0d %0d %0d %0d %0d\n", e, cap_blk[e], start_pass[e],
                    pp[start_pass[e]], pq[start_pass[e]], ps[start_pass[e]]);
        if (cap_blk[e] >= 0) $fwrite(trace_file, "K %0d %0d %0d %0d\n", e, cap_blk[e], cap_pass[e], cap_u[e]);
        if (lap_e[e]) $fwrite(trace_file, "L %0d\n", e);
        if (drn_blk[e] >= 0) $fwrite(trace_file, "X %0d %0d %0d\n", e, drn_blk[e], drn_t[e]);
    endtask

    // Pre-edge acc_out_east on a drain edge.
    task automatic read_drain(input int e);
        if (!drain_at(e)) return;
        if ($isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drained column X: block %0d step %0d", drn_blk[e], drn_t[e]);
        $fwrite(trace_file, "D %0d %0d %0d", drn_blk[e], drn_t[e], e);
        for (int h = 0; h < N_H; h++)
            $fwrite(trace_file, " %0d", $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
        $fwrite(trace_file, "\n");
        n_drain++;
    endtask

    // Pre-edge combiner output: valid exactly two edges after each drain edge.
    task automatic read_comb(input int e);
        bit expect_valid;
        if ($isunknown(int_out_valid))
            $fatal(1, "[X-FAIL] int_out_valid X at edge %0d", e);
        expect_valid = (e >= 2) && drain_at(e - 2);
        if (int_out_valid !== expect_valid)
            $fatal(1, "[TIMING-FAIL] int_out_valid=%0b at edge %0d, expected %0b",
                   int_out_valid, e, expect_valid);
        if (!int_out_valid) return;
        if ($isunknown(int_out))
            $fatal(1, "[X-FAIL] int_out X: block %0d step %0d", drn_blk[e - 2], drn_t[e - 2]);
        $fwrite(trace_file, "C %0d %0d %0d %0d\n", drn_blk[e - 2], drn_t[e - 2],
                $signed(int_out[31:0]), $signed(int_out[63:32]));
        n_comb++;
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
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        void'($value$plusargs("SAIF_MODE=%d", SAIF_MODE));
        void'($value$plusargs("MODE_AT=%d", MODE_AT));

        if (BA < 2 || BA > 8 || BW < 2 || BW > 8) $fatal(1, "BA, BW must be 2..8 (got %0d, %0d)", BA, BW);
        if (!(SAIF_MODE >= 0 && SAIF_MODE <= 2)) $fatal(1, "SAIF_MODE must be 0, 1 or 2 (got %0d)", SAIF_MODE);
        if (!(MODE_AT == -1 || (MODE_AT >= 0 && MODE_AT <= E0 - 1)))
            $fatal(1, "MODE_AT must be -1 or 0..%0d (got %0d)", E0 - 1, MODE_AT);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        if (MROWS < N_H || MROWS % N_H != 0 || NCOLS < N_W || NCOLS % N_W != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", N_H, N_W);
        if (longint'(L) * (longint'(1) << (BA + BW - 2)) > (longint'(1) << (OWIDTH-1)) - 1)
            $fatal(1, "L=%0d at BA=%0d BW=%0d can overflow the %0d-bit tile", L, BA, BW, OWIDTH);
        NB = L / (K*M);
        NIG = MROWS / N_H;
        NJG = NCOLS / N_W;
        NBLK = NIG * NJG;
        build_schedule();
        if (N_EDGES + 16 > `BPA_MAX_EDGES) $fatal(1, "schedule exceeds BPA_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        int_mode = (MODE_AT < 0);
        int_prec = 1'b0;

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("abit_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open abit_trace.txt");
        // The functional bench's 23-field header; negative controls at their defaults, junk 0, park_cyc0 0.
        $fwrite(trace_file, "ABITCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d 0 %0d -1 -1 0 0 0 0 0 0\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, E0, E_END, BLK_LEN, D0,
                BA*BW*NB + (BA + BW - 2) + N_W, NLEV, MODE_AT);

`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);

        // Each iteration starts at the negedge before P_e, where every input
        // is launched (the route's SDC input delay is half a period).
        for (int e = 0; e < N_EDGES; e++) begin
            if (e == MODE_AT) int_mode = 1'b1;
            set_raw(e);
            set_signs(e);
            ring_in = lap_at(e + 1);
            shift_in = drain_at(e);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            log_schedule(e);
            @(posedge clk);                      // P_e
            read_drain(e);                       // pre-edge acc_out_east
            read_comb(e);                        // pre-edge int_out
            #(0.001);                            // P_e + 1 ps: SAIF window mark
            if (interval_active(e)) begin
                if (!collecting) begin
                    $toggle_start;
                    collecting = 1'b1;
                    n_segments++;
                end
                n_active++;
                case (cls[e])
                    0: n_data++;
                    1: n_lap++;
                    default: n_drain_iv++;
                endcase
            end else if (collecting) begin
                $toggle_stop;
                collecting = 1'b0;
            end
            monitor_x = (e >= E0);
            @(negedge clk);
        end
        if (collecting) $fatal(1, "SAIF window still open after the schedule");
        monitor_x = 1'b0;
        mac_en = 1'b0;
        shift_in = 1'b0;
        ring_in = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        if (n_drain != NBLK*N_W || n_comb != NBLK*N_W)
            $fatal(1, "drained %0d columns and %0d combiner outputs, expected %0d each",
                   n_drain, n_comb, NBLK*N_W);
        $fclose(trace_file);

        saif_file = $fopen("abit_saif.txt", "w");
        if (saif_file == 0) $fatal(1, "cannot open abit_saif.txt");
        $fwrite(saif_file, "ABITSAIF %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, SAIF_MODE, MODE_AT, E0, E_END, N_EDGES, BLK_LEN, D0);
        $fwrite(saif_file, "SAIFWIN %0d %0d %0d %0d %0d\n",
                n_active, n_data, n_lap, n_drain_iv, n_segments);
        $fclose(saif_file);
`ifndef GL_SIM
        if (dut.contract_errors != 0)
            $fatal(1, "[CONTRACT] %0d [CBSG-AF-CONTRACT] errors in the abit INT energy schedule", dut.contract_errors);
`endif
        $display("PASS: ABIT INT SAIF captured; BA=%0d BW=%0d L=%0d blocks=%0d mode=%0d active=%0d drained=%0d combined=%0d block_len=%0d",
                 BA, BW, L, NBLK, SAIF_MODE, n_active, n_drain, n_comb, BLK_LEN);
        $finish;
    end
endmodule
