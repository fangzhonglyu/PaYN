`timescale 1ns/1ps

`include "common/clk_util.sv"

// Golden-vector bench for the C-BSG RG array
// (payn_array_signed_segmented_csa_cbsg_rg): plays one case written by
// sweeps/cbsg/cbsg_ref.py --emit (or sweeps/cbsg/rg/gen_cases.py) and compares
// every drain bit-exactly with acc_exp.mem.
//
//   +CASE=<dir>            case directory (cfg.mem, a_mag.mem, ...); without it
//                          the run is a compile check and exits at once
//   +FULL_CYCLES           run 8 cycles per block instead of ceil(max L / 16)
//   +STALL=<pct>           insert rng_en = 0 stall edges at random (mac_en follows)
//   +JUNK                  random operands / lengths / acc_in_west on edges
//                          where they must be ignored, random slice_start
//                          without block_start, random block_start without rng_en
//   +SEED=<n>              $urandom seed for STALL / JUNK
//   +MAX_PRINT=<n>         mismatch lines to print (default 8)
//   +NO_PEEK               drain-only comparison: skip the per-block tile and
//                          phase reads (blk_total = phase_total = 0)
// Negative controls (the sequencer, not the DUT, goes wrong):
//   +NEG_NO_CALL_RESET     slice_start withheld on call-start blocks (except block 0)
//   +NEG_NO_SLICE_RESET    slice_start only on call starts (cbsg_ref fault no_slice_reset)
//   +NEG_FREE_PHASE        slice_start only on block 0 (cbsg_ref fault no_phase_reset)
//   +NEG_SHORT_BLOCK       one cycle fewer than ceil(max L / 16) (when that is > 1)
// Every slice of a golden case ends with a drain, so with the default
// DRAIN_PHASE_RESET = 1 the three phase controls are blind (the drain arms the
// phase reset); build with +define+CBSG_RG_DRAIN_RESET=0 to make slice_start
// the only reset and see them fail.
// DUT mutations are compile-time: +define+CBSG_RG_FAULT_HOOKS+CBSG_RG_FAULT=<n>
// (see the top header; without the HOOKS define a FAULT != 0 build stops at
// time 0); +define+CBSG_RG_IDX_W=<n> sets the W index width.
//
// Gate level: +define+GL_SIM (the flow's GL builds) instantiates the netlist
// without parameter overrides, annotates SDF_FILE unless NO_SDF, and compiles
// no hierarchical reads, so it is always a drain-only (+NO_PEEK) run.
//
// The DUT derives the mask phase itself (slice_start, drain arm); phase.mem is
// only compared against the DUT's phase register.  Besides the drains, the
// bench peeks every tile accumulator after each block's last MAC (acc_blk.mem)
// and the phase register after each block start (phase.mem).  The verdict line
//   CBSGRG_RESULT ... drain_bad=<n> drain_total=<n> blk_bad=... phase_bad=...
// is parsed by sweeps/cbsg/rg/run_rtl_checks.sh.
//
// Schedule (see the top header): block b's C generation edges are consecutive
// (except STALL edges), loads and block_start on its first; MAC two edges
// after each generation edge; after a slice's last block, N_W shift edges
// start on the edge after its last MAC, and the next block's generation
// resumes N_W slots later so its first MAC follows the last shift.

`ifndef GL_SIM
`ifndef CBSG_RG_EXTERNAL_RTL
`include "payn/variants/signed_segmented_csa_cbsg_rg/payn_array_signed_segmented_csa_cbsg_rg.sv"
`endif
`endif

`ifndef CBSG_RG_FAULT
`define CBSG_RG_FAULT 0
`endif
`ifndef CBSG_RG_IDX_W
`define CBSG_RG_IDX_W 8
`endif
`ifndef CBSG_RG_DRAIN_RESET
`define CBSG_RG_DRAIN_RESET 1
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
    localparam int LOW_W = 9;
    localparam int LEN_W = 8;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic block_start = 1'b0, slice_start = 1'b0;
    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*LEN_W-1:0]   row_len_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    ClkUtils #(.TIMEOUT(1_000_000_000)) clk_utils (.clk, .reset, .timeout);

`ifdef GL_SIM
    // Netlist: no parameters, no internal names.
    payn_array_signed_segmented_csa_cbsg_rg dut (.*);
    localparam bit CAN_PEEK = 1'b0;
    initial begin
`ifndef NO_SDF
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
`endif
    end
`else
    payn_array_signed_segmented_csa_cbsg_rg #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH),
        .LOW_W(LOW_W), .LEN_W(LEN_W), .IDX_W(`CBSG_RG_IDX_W),
        .DRAIN_PHASE_RESET(`CBSG_RG_DRAIN_RESET), .FAULT(`CBSG_RG_FAULT)
    ) dut (.*);
    localparam bit CAN_PEEK = 1'b1;
`endif

    // Non-destructive views of the tile accumulators (canonical acc_out) and
    // of the phase register, for the per-block checks (RTL only).
    logic signed [OWIDTH-1:0] peek [N_H][N_W];
    logic [2:0] peek_phase;
`ifdef GL_SIM
    assign peek = '{default: '0};
    assign peek_phase = '0;
`else
    for (genvar h = 0; h < N_H; h++) begin : g_peek_row
        for (genvar v = 0; v < N_W; v++) begin : g_peek_col
            assign peek[h][v] = dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_out;
        end
    end
    assign peek_phase = dut.phase_q;
`endif

    //------------------------------------------------------------ golden --
    typedef logic [31:0] word_t;
    word_t cfg[$], a_mag[$], a_sgn[$], w_mag[$], w_sgn[$], row_len[$];
    word_t slice_st[$], call_st[$], phase_exp[$], cycles_exp[$], drain_flag[$];
    word_t acc_blk[$], acc_exp[$];

    function automatic void read_mem(input string path, ref word_t q[$]);
        int fd;
        string line;
        word_t v;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "[CBSG-RG] cannot open %s", path);
        q.delete();
        while (!$feof(fd)) begin
            if ($fgets(line, fd) == 0) break;
            if (line.len() >= 2 && line.substr(0, 1) == "//") continue;
            if ($sscanf(line, "%h", v) == 1) q.push_back(v);
        end
        $fclose(fd);
    endfunction

    //---------------------------------------------------------- schedule --
    bit s_gen[$], s_bs[$], s_ss[$], s_mac[$], s_shift[$];
    int s_load[$], s_rdrain[$], s_rcol[$], s_peek[$], s_phase[$];

    function automatic void grow(input int n);
        while (s_gen.size() <= n) begin
            s_gen.push_back(1'b0); s_bs.push_back(1'b0); s_ss.push_back(1'b0);
            s_mac.push_back(1'b0); s_shift.push_back(1'b0);
            s_load.push_back(-1); s_rdrain.push_back(-1); s_rcol.push_back(-1);
            s_peek.push_back(-1); s_phase.push_back(-1);
        end
    endfunction

    task automatic apply_block(input int b);
        for (int h = 0; h < N_H; h++) begin
            for (int k = 0; k < K; k++) begin
                a_binary_in[(h*K + k)*WIDTH +: WIDTH] = a_mag[b*64 + h*8 + k][WIDTH-1:0];
                a_signs_in[h*K + k] = a_sgn[b*64 + h*8 + k][0];
            end
            row_len_in[h*LEN_W +: LEN_W] = row_len[b*8 + h][LEN_W-1:0];
        end
        for (int v = 0; v < N_W; v++)
            for (int k = 0; k < K; k++) begin
                w_binary_in[(v*K + k)*WIDTH +: WIDTH] = w_mag[b*64 + k*8 + v][WIDTH-1:0];
                w_signs_in[v*K + k] = w_sgn[b*64 + k*8 + v][0];
            end
    endtask

    task automatic junk_operands();
        for (int i = 0; i < N_H*K*WIDTH; i += 32) a_binary_in[i +: 32] = $urandom;
        for (int i = 0; i < N_W*K*WIDTH; i += 32) w_binary_in[i +: 32] = $urandom;
        for (int i = 0; i < N_H*LEN_W; i += 32) row_len_in[i +: 32] = $urandom;
        a_signs_in = {$urandom, $urandom};
        w_signs_in = {$urandom, $urandom};
    endtask

    string case_dir, case_name;
    int nb, nd, ncalls, max_print, stall_pct, seed;
    bit full_cycles, junk, no_peek, neg_no_call_reset, neg_no_slice_reset, neg_free_phase, neg_short;
    int drain_bad = 0, drain_total = 0, blk_bad = 0, blk_total = 0, phase_bad = 0, phase_total = 0;
    int printed = 0, drains_done = 0;
    logic signed [31:0] drain_val [N_H][N_W];

    function automatic logic signed [31:0] s32(input word_t w);
        return $signed(w);
    endfunction

    initial begin
        int E, d, n_edges, slash;

        if (!$value$plusargs("CASE=%s", case_dir)) begin
            #1ps;   // let the DUT's time-0 parameter checks run first
            $display("CBSGRG compile-only run (no +CASE); FAULT=%0d IDX_W=%0d DRAIN_RESET=%0d GL_SIM=%0d",
                     `CBSG_RG_FAULT, `CBSG_RG_IDX_W, `CBSG_RG_DRAIN_RESET, !CAN_PEEK);
            $finish;
        end
        case_name = case_dir;
        for (int i = case_dir.len() - 1; i >= 0; i--)
            if (case_dir[i] == "/") begin
                case_name = case_dir.substr(i + 1, case_dir.len() - 1);
                break;
            end
        if (!$value$plusargs("MAX_PRINT=%d", max_print)) max_print = 8;
        if (!$value$plusargs("STALL=%d", stall_pct)) stall_pct = 0;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        full_cycles = $test$plusargs("FULL_CYCLES");
        junk = $test$plusargs("JUNK");
        no_peek = $test$plusargs("NO_PEEK") || !CAN_PEEK;
        neg_no_call_reset = $test$plusargs("NEG_NO_CALL_RESET");
        neg_no_slice_reset = $test$plusargs("NEG_NO_SLICE_RESET");
        neg_free_phase = $test$plusargs("NEG_FREE_PHASE");
        neg_short = $test$plusargs("NEG_SHORT_BLOCK");
        void'($urandom(seed));

        read_mem({case_dir, "/cfg.mem"}, cfg);
        nb = cfg[0];
        nd = cfg[1];
        ncalls = (cfg.size() > 6) ? int'(cfg[6]) : 1;
        assert (cfg[2] == N_H && cfg[3] == N_W && cfg[4] == K && cfg[5] == M)
            else $fatal(1, "[CBSG-RG] case shape %0dx%0d K%0d M%0d, bench is %0dx%0d K%0d M%0d",
                        cfg[2], cfg[3], cfg[4], cfg[5], N_H, N_W, K, M);
        read_mem({case_dir, "/a_mag.mem"}, a_mag);
        read_mem({case_dir, "/a_sgn.mem"}, a_sgn);
        read_mem({case_dir, "/w_mag.mem"}, w_mag);
        read_mem({case_dir, "/w_sgn.mem"}, w_sgn);
        read_mem({case_dir, "/row_len.mem"}, row_len);
        read_mem({case_dir, "/slice_start.mem"}, slice_st);
        read_mem({case_dir, "/call_start.mem"}, call_st);
        read_mem({case_dir, "/phase.mem"}, phase_exp);
        read_mem({case_dir, "/cycles.mem"}, cycles_exp);
        read_mem({case_dir, "/drain.mem"}, drain_flag);
        read_mem({case_dir, "/acc_blk.mem"}, acc_blk);
        read_mem({case_dir, "/acc_exp.mem"}, acc_exp);
        assert (a_mag.size() == nb*64 && a_sgn.size() == nb*64 && w_mag.size() == nb*64 &&
                w_sgn.size() == nb*64 && row_len.size() == nb*8 && slice_st.size() == nb &&
                call_st.size() == nb && phase_exp.size() == nb && cycles_exp.size() == nb &&
                drain_flag.size() == nb && acc_blk.size() == nb*64 && acc_exp.size() == nd*64)
            else $fatal(1, "[CBSG-RG] %s: .mem sizes do not match cfg.mem (%0d blocks, %0d drains)",
                        case_dir, nb, nd);

        // ---- build the edge schedule ----
        E = 0;
        d = 0;
        for (int b = 0; b < nb; b++) begin
            int C, Lmax;
            bit ss;
            Lmax = 0;
            for (int h = 0; h < N_H; h++) begin
                assert (row_len[b*8 + h] >= 1 && row_len[b*8 + h] <= 128)
                    else $fatal(1, "[CBSG-RG] block %0d row %0d: L = %0d outside 1..128", b, h, row_len[b*8 + h]);
                if (row_len[b*8 + h] > Lmax) Lmax = row_len[b*8 + h];
            end
            C = (Lmax + 15) / 16;
            assert (C == cycles_exp[b])
                else $fatal(1, "[CBSG-RG] block %0d: ceil(max L / 16) = %0d but cycles.mem says %0d",
                            b, C, cycles_exp[b]);
            if (full_cycles) C = 8;
            else if (neg_short && C > 1) C = C - 1;
            ss = slice_st[b][0];
            if (neg_no_call_reset && call_st[b][0] && b > 0) ss = 1'b0;
            if (neg_no_slice_reset) ss = call_st[b][0];
            if (neg_free_phase) ss = (b == 0);
            for (int c = 0; c < C; c++) begin
                if (stall_pct > 0)
                    while (($urandom % 100) < stall_pct) E++;
                grow(E + 2);
                s_gen[E] = 1'b1;
                if (c == 0) begin
                    s_bs[E] = 1'b1;
                    s_ss[E] = ss;
                    s_load[E] = b;
                    s_phase[E] = b;
                end
                s_mac[E + 2] = 1'b1;
                E++;
            end
            // last generation edge E-1, last MAC edge E+1
            grow(E + 1);
            s_peek[E + 1] = b;
            if (drain_flag[b][0]) begin
                grow(E + 1 + N_W);
                for (int s = 0; s < N_W; s++) begin
                    s_shift[E + 2 + s] = 1'b1;
                    s_rdrain[E + 2 + s] = d;
                    s_rcol[E + 2 + s] = N_W - 1 - s;
                end
                E += N_W;
                d++;
            end
        end
        assert (d == nd) else $fatal(1, "[CBSG-RG] drain.mem has %0d drains, cfg says %0d", d, nd);
        n_edges = s_gen.size();
        foreach (s_mac[e]) assert (!(s_mac[e] && s_shift[e])) else $fatal(1, "schedule: MAC on a shift edge %0d", e);

        $display("[CBSG-RG] case %s: %0d blocks, %0d drains, %0d calls, %0d edges; FAULT=%0d IDX_W=%0d DRAIN_RESET=%0d%s%s%s%s%s%s%s%s",
                 case_name, nb, nd, ncalls, n_edges, `CBSG_RG_FAULT, `CBSG_RG_IDX_W, `CBSG_RG_DRAIN_RESET,
                 full_cycles ? " FULL_CYCLES" : "", junk ? " JUNK" : "", no_peek ? " NO_PEEK" : "",
                 neg_no_call_reset ? " NEG_NO_CALL_RESET" : "", neg_no_slice_reset ? " NEG_NO_SLICE_RESET" : "",
                 neg_free_phase ? " NEG_FREE_PHASE" : "", neg_short ? " NEG_SHORT_BLOCK" : "",
                 stall_pct > 0 ? $sformatf(" STALL=%0d", stall_pct) : "");

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        // ---- play it: inputs at the negedge before each edge ----
        for (int e = 0; e < n_edges; e++) begin
            rng_en = s_gen[e];
            block_start = s_bs[e];
            slice_start = s_ss[e];
            mac_en = s_mac[e];
            shift_in = s_shift[e];
            acc_in_west = '0;
            if (s_load[e] >= 0) begin
                apply_block(s_load[e]);
                {load_a, load_w, load_a_sign, load_w_sign} = 4'b1111;
            end else begin
                {load_a, load_w, load_a_sign, load_w_sign} = 4'b0000;
                if (junk) junk_operands();
            end
            if (junk) begin
                if (!s_bs[e]) slice_start = $urandom & 1;
                if (!s_gen[e]) block_start = $urandom & 1;
                if (!s_shift[e]) for (int i = 0; i < N_H*OWIDTH; i += 32) acc_in_west[i +: 32] = $urandom;
            end
            if (s_rdrain[e] >= 0) begin
                for (int h = 0; h < N_H; h++)
                    drain_val[h][s_rcol[e]] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
                if (s_rcol[e] == 0) begin
                    int di;
                    di = s_rdrain[e];
                    for (int h = 0; h < N_H; h++)
                        for (int v = 0; v < N_W; v++) begin
                            drain_total++;
                            if (drain_val[h][v] !== s32(acc_exp[di*64 + h*8 + v])) begin
                                drain_bad++;
                                if (printed < max_print) begin
                                    printed++;
                                    $display("[CBSG-RG] DRAIN MISMATCH drain %0d row %0d col %0d: got %0d expected %0d",
                                             di, h, v, drain_val[h][v], s32(acc_exp[di*64 + h*8 + v]));
                                end
                            end
                        end
                    drains_done++;
                end
            end
            @(posedge clk);
            @(negedge clk);
            if (s_peek[e] >= 0 && !no_peek) begin
                int b;
                b = s_peek[e];
                for (int h = 0; h < N_H; h++)
                    for (int v = 0; v < N_W; v++) begin
                        logic signed [31:0] got;
                        got = peek[h][v];
                        blk_total++;
                        if (got !== s32(acc_blk[b*64 + h*8 + v])) begin
                            blk_bad++;
                            if (printed < max_print) begin
                                printed++;
                                $display("[CBSG-RG] BLOCK MISMATCH block %0d row %0d col %0d: tile %0d expected %0d",
                                         b, h, v, got, s32(acc_blk[b*64 + h*8 + v]));
                            end
                        end
                    end
            end
            if (s_phase[e] >= 0 && !no_peek) begin
                phase_total++;
                if (peek_phase !== phase_exp[s_phase[e]][2:0]) begin
                    phase_bad++;
                    if (printed < max_print) begin
                        printed++;
                        $display("[CBSG-RG] PHASE MISMATCH block %0d: DUT phase %0d expected %0d",
                                 s_phase[e], peek_phase, phase_exp[s_phase[e]]);
                    end
                end
            end
        end
        {rng_en, block_start, slice_start, mac_en, shift_in} = '0;
        {load_a, load_w, load_a_sign, load_w_sign} = '0;
        repeat (2) @(negedge clk);

        assert (drains_done == nd) else $fatal(1, "[CBSG-RG] compared %0d of %0d drains", drains_done, nd);
        $display("CBSGRG_RESULT case=%s drain_bad=%0d drain_total=%0d blk_bad=%0d blk_total=%0d phase_bad=%0d phase_total=%0d edges=%0d blocks=%0d drains=%0d calls=%0d",
                 case_name, drain_bad, drain_total, blk_bad, blk_total, phase_bad, phase_total,
                 n_edges, nb, nd, ncalls);
        if (drain_bad == 0 && blk_bad == 0 && phase_bad == 0)
            $display("PASS: CBSG-RG bench %s: %0d drains x 64 accumulators bit-exact, %0d block checks, %0d phase checks",
                     case_name, nd, nb, phase_total);
        else
            $display("FAIL: CBSG-RG bench %s: %0d/%0d drain, %0d/%0d block, %0d/%0d phase mismatches",
                     case_name, drain_bad, drain_total, blk_bad, blk_total, phase_bad, phase_total);
        $finish;
    end
endmodule
