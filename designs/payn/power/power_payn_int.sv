`timescale 1ns/1ps

`include "common/clk_util.sv"

// INT energy bench for payn_array, driving the real INT ports per the
// sequencer contract in the top's header, with the two INT schedules on one
// bench: +MODE=bp (bit-plane, default) or +MODE=abit (all bits in time).  No
// forces.  Shape from +define+PAYN_M=8 (K16/M8, default) or 16 (K8/M16), K =
// 128/M; 8 x 8 tiles, LOW_W = 9 like the route.  Lane k / position m of data
// cycle u carries reduction element x = 128*u + M*k + m, so NB = L/128 data
// cycles per pass whichever the shape.
//
// Common contract, as driven here (every input launched at the negedge before
// the capturing posedge P_e, i.e. at the route's half-period SDC input delay):
//  * SC side quiet for the whole run: rng_en = 0, a_binary_in = w_binary_in =
//    0 on every edge (every INT load carries zero magnitudes, so the SC streams
//    stay silent), a_len_in = 0, block_start = slice_start = 0, acc_in_west = 0
//    (lap edges take the doubled tile, drain edges take 0).
//  * INT entry: the run leaves reset in SC mode and raises int_mode at the
//    negedge before P_{MODE_AT} (default 1; -1 = high through reset; 3 is the
//    latest legal edge).  int_mode is registered, so the first raw plane
//    (captured at P_E0, E0 = 4) needs it high at P_{E0-1}.  The zero-load on
//    INT entry is the first pass's sign load at P_{E0-1}: load_a and load_w
//    both fire there, after the rise, with zero magnitudes.  int_mode never
//    changes afterwards, so the two-edge MAC guard never fires in the window.
//  * Signs through the existing two-edge path: load_w + load_w_sign at P_e for
//    a pass whose first raw plane is captured at P_{e+1}.
//  * Laps: ring_in high one edge ahead of each 1-edge lap (ring_q); every tile
//    doubles in place, the MAC on the lap edge is dropped, so a bubble plane
//    is captured on the edge before it.  Drain: shift_in with ring_q low and
//    acc_in_west = 0, N_W edges, the last being the next block's first
//    capture.  mac_en = 1 from P_{E0+1}.
//  * Checks: X on the drain rail or the combiner outputs from E0 on
//    ([X-FAIL]); int_out_valid exactly two edges after each drain edge and
//    never otherwise ([TIMING-FAIL]); in RTL the top's [INT-CONTRACT] check
//    (a MAC consuming live SC stream bits) and a zero [SC-CONTRACT] count.
//
// SAIF windows.  Interval I_e = (P_e + 1 ps, P_{e+1} + 1 ps] holds the
// response to edge P_e and exactly one clock period; e runs over [E0, E_END),
// E_END = the final drain edge.  Collection is paused/resumed exactly at the
// 1 ps marks, so duration and clock toggle count stay exact (the SAIF period
// check holds).  SAIF_MODE 0 = data + lap intervals (drain paused: headline
// numbers are drain-excluded), 1 = data only (peak), 2 = everything, drain
// included; bp also has 3 / 4 (below).  The SAIF covers Top.dut (dut.saif).
//
// --------------------------------------------------------------- +MODE=bp --
// Bit-plane schedule (A bits in space).  Row h carries activation plane
// p = h % BA of activation row i = ig*ROWS_PE + h / BA (ROWS_PE = 8/BA);
// column v carries output column j = jg*8 + v.  Weight planes go in time, MSB
// pass first: in pass pi (q = BW-1-pi), w_raw_in[v][k][m] = bit q of W[x, j].
// INT8: BA = BW = 8; W4A8: BA = 8, BW = 4; INT4: BA = BW = 4 (two activation
// rows per block, int_prec = 1).  a_signs_in = (h % BA == BA-1), loaded once;
// w_signs_in = all ones in the weight-MSB pass, else zero.  int_prec = (BA ==
// 4), static.
// Schedule (edge P_e = e-th posedge after the post-reset settle).  A non-final
// pass takes PASS_LEN = NB + 1 edges (NB data captures, then one bubble whose
// successor u = 0 of the next pass is the lap edge), the final pass LAST_LEN =
// NB + 8 (data, then the drain on u = NB+1 .. NB+7 and u = 0 of the next
// block), so a block is BLK_LEN = BW*NB + (BW-1) + 8 edges.  The combiner
// (u_combiner) captures on drain edges and emits int_out / int_out_valid two
// edges later.  With LAP_RING_ONLY = 1 (default) shift_in is high on drain
// edges only and ring_q alone shifts the tiles on lap edges (the per-PE lap
// contract the grid needs); LAP_RING_ONLY = 0 also raises shift_in on lap
// edges (legal on one PE: tile shift = shift_in | ring_q).
// Window classes: I_e is DATA if u < NB, else RING (pi < BW-1) or DRAIN
// (pi = BW-1).  The classing is by interval count, not by cause: I_{u=0} holds
// the lap / last drain shift and is DATA, I_{u=NB} holds the pass's last MAC
// and is RING or DRAIN.  The combiner's input register loads in drain
// intervals, its output register two edges later, so for the last drained
// columns of a block the out-register update falls in the next block's first
// DATA intervals (modes 0 and 1 include that, as they include the last drain
// shift).  SAIF_MODE 3 / 4: the windows of modes 1 / 0 classed by CAUSE:
// I_e is a MAC interval if P_e is neither a shift edge nor E0 (the first
// capture, no MAC), a LAP interval if P_e is a ring-lap shift, a DRAIN
// interval if it is a drain shift; e runs over (E0, E_END).  Mode 3 collects
// MAC intervals, mode 4 MAC + LAP; their counts equal those of modes 1 / 0.
// Trace bpt_trace.txt, the functional bench's records: header
//   BPTCFG BA BW L MROWS NCOLS NBLK NB int_prec 0 0 0 LAP_RING_ONLY 0 MODE_AT
// every drained column "D blk t tile_h0..tile_h7" (column v = 7 - t) and every
// combiner word "C blk t lo hi".  Window record bpe_saif.txt:
//   BPECFG BA BW L MROWS NCOLS NBLK NB SAIF_MODE MODE_AT E0 E_END N_EDGES
//   SAIFWIN active data ring drain segments
//   BPELAP 1 PASS_LEN LAST_LEN BLK_LEN
// Checker: designs/payn/model/int_trace.py bp-power (--lap-ring-only when
// LAP_RING_ONLY = 1).  Last line PASS: PaYN bit-plane INT power bench ...
//
// ------------------------------------------------------------- +MODE=abit --
// All-bits-in-time schedule: every tile holds one output.  Block blk =
// ig*NJG + jg: tile row h = activation row ig*8 + h, column v = weight column
// jg*8 + v.  One pass per bit pair (p, q): a_raw_in row h carries bit p of
// A[ig*8 + h, x], w_raw_in column v bit q of W[x, jg*8 + v].  Passes grouped
// by level p + q, MSB level first (A bit ascending inside a level), contiguous
// inside a level; between levels one bubble capture and one 1-edge lap; pass
// sign (p == BA-1) XOR (q == BW-1) on the W side (load_w + load_w_sign one
// edge ahead of the pass, zero magnitudes); A signs 0, loaded once with the
// zero-load.  After the last level one bubble (the last MAC), then the drain:
// shift_in on 8 edges with acc_in_west = 0, the 8th being the next block's
// first capture; the 8 raw rows are read from acc_out_east (the combiner still
// captures and its words are recorded, but this schedule does not use them).
// Block period BA*BW*NB + (BA+BW-2) + 8 edges; int_prec = 0.  BA, BW 2..8;
// worst case L * 2^(BA+BW-2) must fit the signed 24-bit tile.
// Window classes (by interval count): I_e is DATA if P_e captures a data chunk
// (lap edges included: a lap edge is also the next level's first capture),
// LAP if P_e captures the bubble before a lap (its interval holds the level's
// last MAC), DRAIN if P_e is the block's final bubble (the last MAC) or one of
// the first 7 drain edges (the 8th is the next block's first capture, DATA).
// Per block: BA*BW*NB DATA, BA+BW-2 LAP, 8 DRAIN intervals.
// Trace abit_trace.txt, the functional bench's records: header
//   ABITCFG BA BW L MROWS NCOLS NBLK NB E0 E_END BLK_LEN D0 FORMULA NLEV 0 MODE_AT -1 -1 0 0 0 0 0 0
// (the negative-control fields at their defaults), the schedule records
// written at the negedge before each edge ("P e blk j p q sign" first capture
// of pass j, "K e blk j u" raw-plane capture, "L e" lap edge, "X e blk t"
// drain step, "M e" first MAC edge), every drained column with its edge
// "D blk t e tile_h0..tile_h7" (column v = 7 - t) and every combiner word
// "C blk t lo hi".  Window record abit_saif.txt:
//   ABITSAIF BA BW L MROWS NCOLS NBLK NB SAIF_MODE MODE_AT E0 E_END N_EDGES BLK_LEN D0
//   SAIFWIN active data lap drain segments
// Checker: designs/payn/model/int_trace.py abit-power.  Last line PASS: PaYN
// abit INT power bench ...
//
// Configuration: compile-time defines (make sim passes no runtime arguments),
// each overridable at run time by the plusarg of the same name without the
// INT_ prefix:
//   INT_ABIT        selects +MODE=abit by default (else bp)
//   INT_BA, INT_BW  default 8
//   INT_L           default 1024 (bp) / 384 (abit)
//   INT_MROWS       default 1 (bp) / 8 (abit); INT_NCOLS default 8
//   INT_SAIF_MODE   default 0;  INT_MODE_AT default 1
//   INT_LAP_RING_ONLY  (bp) default 1
//   INT_LOW_W (9), INT_MAX_EDGES (200000), INT_RANGE_DATA (abit: skip the
//   worst-case tile range check for workloads whose actual GEMM fits; also
//   +ABIT_RANGE_DATA), INT_VCD (debug only: dumps the top
//   ports and the PE to int_debug.vcd; never in measured runs)
// Operands: bpt_a.hex (A row-major, MROWS x L) and bpt_w.hex (W column-major,
// W[x, j] at j*L + x), one two's-complement byte per line, in the run
// directory (designs/payn/model/int_workload.py).  Needs DesignWare for the
// RTL tile heap (VCS -y $SYNOPSYS/dw/sim_ver).  GL runs: +define+GL_SIM,
// +define+PAYN_DUT=<netlist top> if it is not payn_array, SDF_FILE / NO_SDF.

`ifndef GL_SIM
`include "payn/rtl/payn_array.sv"
`endif

`ifndef PAYN_M
`define PAYN_M 8                      // positions per lane: 8 (K16/M8) or 16 (K8/M16)
`endif
`ifndef PAYN_DUT
`define PAYN_DUT payn_array           // netlist top name (GL_SIM)
`endif
`ifndef INT_BA
`define INT_BA 8
`endif
`ifndef INT_BW
`define INT_BW 8
`endif
`ifndef INT_L
`define INT_L -1                      // -1: the schedule's default
`endif
`ifndef INT_MROWS
`define INT_MROWS -1                  // -1: the schedule's default
`endif
`ifndef INT_NCOLS
`define INT_NCOLS 8
`endif
`ifndef INT_SAIF_MODE
`define INT_SAIF_MODE 0
`endif
`ifndef INT_MODE_AT
`define INT_MODE_AT 1
`endif
`ifndef INT_LAP_RING_ONLY
`define INT_LAP_RING_ONLY 1
`endif
`ifndef INT_LOW_W
`define INT_LOW_W 9
`endif
`ifndef INT_MAX_EDGES
`define INT_MAX_EDGES 200000
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int M = `PAYN_M;
    localparam int K = 128 / M;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = 24;
    localparam int LOW_W = `INT_LOW_W;
    localparam int E0 = 4;                      // first data capture edge
    localparam int LAP_LEN = 1;                 // the in-place lap
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    // Configuration (defines, overridable by plusargs) and derived schedule.
`ifdef INT_ABIT
    string sched = "abit";
`else
    string sched = "bp";
`endif
    bit abit;
    int BA = `INT_BA, BW = `INT_BW, L = `INT_L;
    int MROWS = `INT_MROWS, NCOLS = `INT_NCOLS;
    int SAIF_MODE = `INT_SAIF_MODE, MODE_AT = `INT_MODE_AT;
    int LAP_RING_ONLY = `INT_LAP_RING_ONLY;
    int NB, NIG, NJG, NBLK, BLK_LEN, E_END, N_EDGES;

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

    integer trace_file, saif_file;
    bit monitor_x = 1'b0;
    bit collecting = 1'b0;
    int n_drain = 0, n_comb = 0;
    int n_active = 0, n_segments = 0;
    int n_class [3] = '{0, 0, 0};     // data, ring / lap, drain intervals

    ClkUtils #(.TIMEOUT(`INT_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

`ifdef GL_SIM
    `PAYN_DUT dut (.*);
`else
    payn_array #(
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

`ifdef INT_VCD
    // Debug only (never in measured runs): top ports and the whole PE.
    initial begin
        $dumpfile("int_debug.vcd");
        $dumpvars(1, Top);
        $dumpvars(0, dut.u_pe);
    end
`endif

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] PaYN INT power bench exceeded %0d cycles", `INT_MAX_EDGES);

    // Architectural outputs must stay known from the first data edge on.
    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drain rail entered X: %h", acc_out_east);
    always @(int_out or int_out_valid)
        if (monitor_x && ($isunknown(int_out) || $isunknown(int_out_valid)))
            $fatal(1, "[X-FAIL] combiner output entered X: valid=%b out=%h", int_out_valid, int_out);

    //====================================================== bit-plane ==
    int ROWS_PE, PASS_LEN, LAST_LEN, E_DATA_END;
    logic [N_H*K-1:0] a_sign_word;

    function automatic void bp_decode(input int e, output int blk, output int pi, output int u);
        int r;
        r = e - E0;
        blk = r / BLK_LEN;
        r = r % BLK_LEN;
        pi = r / PASS_LEN;
        if (pi > BW - 1) pi = BW - 1;           // the final pass is LAST_LEN long
        u = r - pi*PASS_LEN;
    endfunction

    // The tile array shifts at P_e (ring lap or drain).  u = 0 closes the
    // previous pass's lap (pi >= 1) or the previous block's drain (pi = 0); a
    // non-final pass laps on its last LAP_LEN-1 edges, the final pass drains
    // on u >= NB+1.
    function automatic bit bp_core_shift_at(input int e);
        int blk, pi, u;
        if (e <= E0 || e > E_END) return 1'b0;
        bp_decode(e, blk, pi, u);
        if (u == 0) return 1'b1;
        if (pi < BW - 1) return u >= PASS_LEN - LAP_LEN + 1;
        return u >= NB + 1;
    endfunction

    // The shift at P_e is a ring-lap shift.
    function automatic bit bp_ring_at(input int e);
        int blk, pi, u;
        if (!bp_core_shift_at(e)) return 1'b0;
        bp_decode(e, blk, pi, u);
        if (u == 0) return pi >= 1;     // closes the lap after pass pi-1
        return pi < BW - 1;
    endfunction

    function automatic bit bp_drain_at(input int e);
        return bp_core_shift_at(e) && !bp_ring_at(e);
    endfunction

    // Drain edge P_e -> (block, step t); step t delivers column v = 7 - t.
    function automatic void bp_drain_slot(input int e, output int bd, output int t);
        int blk, pi, u;
        bp_decode(e, blk, pi, u);
        if (u == 0) begin
            bd = blk - 1;
            t = N_W - 1;
        end else begin
            bd = blk;
            t = u - NB - 1;
        end
    endfunction

    // 0 = data, 1 = ring lap, 2 = drain, for interval I_e (e >= E0).
    function automatic int bp_interval_class(input int e);
        int blk, pi, u;
        bp_decode(e, blk, pi, u);
        if (u < NB) return 0;
        return (pi < BW - 1) ? 1 : 2;
    endfunction

    // Modes 3 / 4: the class of interval I_e by the edge that causes it;
    // -1 outside (E0, E_END), 0 = MAC (P_e does not shift), 1 = ring-lap
    // shift, 2 = drain shift.
    function automatic int bp_cause_class(input int e);
        if (e <= E0 || e >= E_END) return -1;
        if (!bp_core_shift_at(e)) return 0;
        return bp_ring_at(e) ? 1 : 2;
    endfunction

    function automatic bit bp_interval_active(input int e);
        int c;
        if (SAIF_MODE >= 3) begin
            c = bp_cause_class(e);
            return (c == 0) || (SAIF_MODE == 4 && c == 1);
        end
        if (e < E0 || e >= E_END) return 1'b0;
        c = bp_interval_class(e);
        case (SAIF_MODE)
            0: return c != 2;
            1: return c == 0;
            default: return 1'b1;
        endcase
    endfunction

    // Raw planes captured into the bit pipes at P_e, assembled in temporaries
    // and applied in one assignment (one event per input bus per cycle).
    task automatic bp_set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, pi, u, ig, jg, q, i, p, j, x;
        a_next = '0;
        w_next = '0;
        if (e >= E0 && e < E_DATA_END) begin
            bp_decode(e, blk, pi, u);
            if (u < NB) begin
                ig = blk / NJG;
                jg = blk % NJG;
                q = BW - 1 - pi;
                for (int h = 0; h < N_H; h++) begin
                    i = ig*ROWS_PE + h / BA;
                    p = h % BA;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[i*L + x][p];
                        end
                end
                for (int v = 0; v < N_W; v++) begin
                    j = jg*N_W + v;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            x = u*K*M + k*M + m;
                            w_next[(v*K + k)*M + m] = w_mem[j*L + x][q];
                        end
                end
            end
        end
        a_raw_in = a_next;
        w_raw_in = w_next;
    endtask

    // Sign loads captured by the peripheral at P_e, so the PE sign pipes take
    // them at P_{e+1}, the pass's first raw-plane capture edge.  The first one
    // (P_{E0-1}) loads both sides: the zero-load on INT entry.
    task automatic bp_set_signs(input int e);
        int blk, pi, u;
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
        if (e + 1 >= E0 && e + 1 < E_DATA_END) begin
            bp_decode(e + 1, blk, pi, u);
            if (u == 0) begin
                w_signs_in = (pi == 0) ? '1 : '0;
                load_w = 1'b1;
                load_w_sign = 1'b1;
                if (e + 1 == E0) begin
                    a_signs_in = a_sign_word;
                    load_a = 1'b1;
                    load_a_sign = 1'b1;
                end
            end
        end
    endtask

    task automatic bp_config();
        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (!(SAIF_MODE >= 0 && SAIF_MODE <= 4)) $fatal(1, "SAIF_MODE must be 0, 1, 2, 3 or 4 (got %0d)", SAIF_MODE);
        if (!(LAP_RING_ONLY == 0 || LAP_RING_ONLY == 1)) $fatal(1, "LAP_RING_ONLY must be 0 or 1 (got %0d)", LAP_RING_ONLY);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        NB = L / (K*M);
        ROWS_PE = N_H / BA;
        if (MROWS < ROWS_PE || MROWS % ROWS_PE != 0 || NCOLS < N_W || NCOLS % N_W != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", ROWS_PE, N_W);
        // |tile value| <= 2^(BW-1) * L must fit the OWIDTH-bit accumulator.
        if ((longint'(1) << (BW-1)) * L >= (longint'(1) << (OWIDTH-1)))
            $fatal(1, "L=%0d can overflow the %0d-bit accumulator", L, OWIDTH);
        NIG = MROWS / ROWS_PE;
        NJG = NCOLS / N_W;
        NBLK = NIG * NJG;
        PASS_LEN = NB + LAP_LEN;                // data + the 1-edge lap
        LAST_LEN = NB + N_W;                    // data + the 8-shift drain
        BLK_LEN = (BW - 1) * PASS_LEN + LAST_LEN;
        E_DATA_END = E0 + NBLK*BLK_LEN;
        E_END = E_DATA_END;                     // final drain edge
        N_EDGES = E_END + 3;                    // + combiner latency
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);
        int_prec = (BA == 4);
    endtask

    //=========================================================== abit ==
    int NLEV, NP, D0, NV;
    int pp [$], pq [$], ps [$], pn [$];
    int cap_blk [], cap_pass [], cap_u [], start_pass [], drn_blk [], drn_t [], cls [];
    bit lap_e [];

    task automatic abit_schedule();
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

    function automatic bit abit_drain_at(input int e);
        return e >= 0 && e < NV && drn_blk[e] >= 0;
    endfunction

    function automatic bit abit_lap_at(input int e);
        return e >= 0 && e < NV && lap_e[e];
    endfunction

    function automatic bit abit_interval_active(input int e);
        if (e < E0 || e >= E_END) return 1'b0;
        case (SAIF_MODE)
            0: return cls[e] != 2;
            1: return cls[e] == 0;
            default: return 1'b1;
        endcase
    endfunction

    // Raw planes captured at P_e, assembled in temporaries and applied in one
    // assignment (one event per input bus per cycle).
    task automatic abit_set_raw(input int e);
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

    // W sign loads at P_e for a pass whose first raw plane is captured at
    // P_{e+1}; the first one (P_{E0-1}) loads both sides with zero magnitudes
    // and A sign 0.
    task automatic abit_set_signs(input int e);
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

    task automatic abit_log_schedule(input int e);
        if (e == E0 + 1) $fwrite(trace_file, "M %0d\n", e);
        if (e >= NV) return;
        if (start_pass[e] >= 0)
            $fwrite(trace_file, "P %0d %0d %0d %0d %0d %0d\n", e, cap_blk[e], start_pass[e],
                    pp[start_pass[e]], pq[start_pass[e]], ps[start_pass[e]]);
        if (cap_blk[e] >= 0) $fwrite(trace_file, "K %0d %0d %0d %0d\n", e, cap_blk[e], cap_pass[e], cap_u[e]);
        if (lap_e[e]) $fwrite(trace_file, "L %0d\n", e);
        if (drn_blk[e] >= 0) $fwrite(trace_file, "X %0d %0d %0d\n", e, drn_blk[e], drn_t[e]);
    endtask

`ifdef INT_RANGE_DATA
    bit range_data = 1'b1;
`else
    bit range_data = 1'b0;
`endif
    task automatic abit_config();
        if (BA < 2 || BA > 8 || BW < 2 || BW > 8) $fatal(1, "BA, BW must be 2..8 (got %0d, %0d)", BA, BW);
        if (!(SAIF_MODE >= 0 && SAIF_MODE <= 2)) $fatal(1, "SAIF_MODE must be 0, 1 or 2 (got %0d)", SAIF_MODE);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        if (MROWS < N_H || MROWS % N_H != 0 || NCOLS < N_W || NCOLS % N_W != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", N_H, N_W);
        // Worst-case range of the tile; INT_RANGE_DATA / +ABIT_RANGE_DATA skip it for workloads whose actual GEMM
        // fits (the checker requires every drained tile value to fit and be exact).
        if (longint'(L) * (longint'(1) << (BA + BW - 2)) > (longint'(1) << (OWIDTH-1)) - 1 &&
            !(range_data || $test$plusargs("ABIT_RANGE_DATA")))
            $fatal(1, "L=%0d at BA=%0d BW=%0d can overflow the %0d-bit tile (INT_RANGE_DATA: data-dependent range)",
                   L, BA, BW, OWIDTH);
        NB = L / (K*M);
        NIG = MROWS / N_H;
        NJG = NCOLS / N_W;
        NBLK = NIG * NJG;
        abit_schedule();
        int_prec = 1'b0;
    endtask

    //===================================================== common tail ==
    function automatic bit drain_at(input int e);
        return abit ? abit_drain_at(e) : bp_drain_at(e);
    endfunction

    function automatic void drain_slot(input int e, output int bd, output int t);
        if (abit) begin
            bd = drn_blk[e];
            t = drn_t[e];
        end else begin
            bp_drain_slot(e, bd, t);
        end
    endfunction

    // Pre-edge acc_out_east on a drain edge (the abit record carries the edge).
    task automatic read_drain(input int e);
        int bd, t;
        if (!drain_at(e)) return;
        drain_slot(e, bd, t);
        if ($isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drained column X: block %0d step %0d", bd, t);
        if (abit)
            $fwrite(trace_file, "D %0d %0d %0d", bd, t, e);
        else
            $fwrite(trace_file, "D %0d %0d", bd, t);
        for (int h = 0; h < N_H; h++)
            $fwrite(trace_file, " %0d", $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
        $fwrite(trace_file, "\n");
        n_drain++;
    endtask

    // Pre-edge combiner output: valid exactly two edges after each drain edge.
    task automatic read_comb(input int e);
        int bd, t;
        bit expect_valid;
        if ($isunknown(int_out_valid))
            $fatal(1, "[X-FAIL] int_out_valid X at edge %0d", e);
        expect_valid = (e >= 2) && drain_at(e - 2);
        if (int_out_valid !== expect_valid)
            $fatal(1, "[TIMING-FAIL] int_out_valid=%0b at edge %0d, expected %0b",
                   int_out_valid, e, expect_valid);
        if (!int_out_valid) return;
        drain_slot(e - 2, bd, t);
        if ($isunknown(int_out))
            $fatal(1, "[X-FAIL] int_out X: block %0d step %0d", bd, t);
        $fwrite(trace_file, "C %0d %0d %0d %0d\n", bd, t,
                $signed(int_out[31:0]), $signed(int_out[63:32]));
        n_comb++;
    endtask

    // Window class of interval I_e when it is collected.
    function automatic int window_class(input int e);
        if (abit) return cls[e];
        return (SAIF_MODE >= 3) ? bp_cause_class(e) : bp_interval_class(e);
    endfunction

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

    function automatic int dut_contract();
`ifndef GL_SIM
        return dut.contract_errors;
`else
        return 0;
`endif
    endfunction

    initial begin
        int c;
        assert ((K == 16 && M == 8) || (K == 8 && M == 16))
            else $fatal(1, "PaYN INT power bench needs K16/M8 or K8/M16 (got K=%0d M=%0d)", K, M);
        void'($value$plusargs("MODE=%s", sched));
        if (sched != "bp" && sched != "abit") $fatal(1, "[BENCH] unknown +MODE=%s (bp | abit)", sched);
        abit = (sched == "abit");
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        void'($value$plusargs("SAIF_MODE=%d", SAIF_MODE));
        void'($value$plusargs("MODE_AT=%d", MODE_AT));
        void'($value$plusargs("LAP_RING_ONLY=%d", LAP_RING_ONLY));
        if (abit && $test$plusargs("LAP_RING_ONLY"))
            $fatal(1, "[BENCH] +LAP_RING_ONLY is not an option of +MODE=abit (shift_in is on drain edges only)");
        if (L < 0) L = abit ? 384 : 1024;
        if (MROWS < 0) MROWS = abit ? 8 : 1;
        if (!(MODE_AT == -1 || (MODE_AT >= 0 && MODE_AT <= E0 - 1)))
            $fatal(1, "MODE_AT must be -1 or 0..%0d (got %0d)", E0 - 1, MODE_AT);
        if (abit) abit_config();
        else bp_config();
        if (N_EDGES + 16 > `INT_MAX_EDGES) $fatal(1, "schedule exceeds INT_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        int_mode = (MODE_AT < 0);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        if (abit) begin
            trace_file = $fopen("abit_trace.txt", "w");
            if (trace_file == 0) $fatal(1, "cannot open abit_trace.txt");
            // The functional bench's 23-field header; negative controls at their defaults, junk 0, park_cyc0 0.
            $fwrite(trace_file, "ABITCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d 0 %0d -1 -1 0 0 0 0 0 0\n",
                    BA, BW, L, MROWS, NCOLS, NBLK, NB, E0, E_END, BLK_LEN, D0,
                    BA*BW*NB + (BA + BW - 2) + N_W, NLEV, MODE_AT);
        end else begin
            trace_file = $fopen("bpt_trace.txt", "w");
            if (trace_file == 0) $fatal(1, "cannot open bpt_trace.txt");
            // The functional bench's header without JUNK / negative controls;
            // field 12 is lap_ring_only.
            $fwrite(trace_file, "BPTCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    BA, BW, L, MROWS, NCOLS, NBLK, NB, int_prec, 0, 0, 0, LAP_RING_ONLY, 0, MODE_AT);
        end

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
            if (abit) begin
                abit_set_raw(e);
                abit_set_signs(e);
                ring_in = abit_lap_at(e + 1);
                shift_in = abit_drain_at(e);
            end else begin
                bp_set_raw(e);
                bp_set_signs(e);
                ring_in = bp_ring_at(e + 1);
                shift_in = LAP_RING_ONLY ? bp_drain_at(e) : bp_core_shift_at(e);
            end
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            if (abit) abit_log_schedule(e);
            @(posedge clk);                      // P_e
            read_drain(e);                       // pre-edge acc_out_east
            read_comb(e);                        // pre-edge int_out
            #(0.001);                            // P_e + 1 ps: SAIF window mark
            if (abit ? abit_interval_active(e) : bp_interval_active(e)) begin
                if (!collecting) begin
                    $toggle_start;
                    collecting = 1'b1;
                    n_segments++;
                end
                n_active++;
                c = window_class(e);
                n_class[(c == 0 || c == 1) ? c : 2]++;
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

        if (abit) begin
            saif_file = $fopen("abit_saif.txt", "w");
            if (saif_file == 0) $fatal(1, "cannot open abit_saif.txt");
            $fwrite(saif_file, "ABITSAIF %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    BA, BW, L, MROWS, NCOLS, NBLK, NB, SAIF_MODE, MODE_AT, E0, E_END, N_EDGES, BLK_LEN, D0);
        end else begin
            saif_file = $fopen("bpe_saif.txt", "w");
            if (saif_file == 0) $fatal(1, "cannot open bpe_saif.txt");
            $fwrite(saif_file, "BPECFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    BA, BW, L, MROWS, NCOLS, NBLK, NB, SAIF_MODE, MODE_AT, E0, E_END, N_EDGES);
        end
        $fwrite(saif_file, "SAIFWIN %0d %0d %0d %0d %0d\n",
                n_active, n_class[0], n_class[1], n_class[2], n_segments);
        if (!abit)
            $fwrite(saif_file, "BPELAP %0d %0d %0d %0d\n", LAP_LEN, PASS_LEN, LAST_LEN, BLK_LEN);
        $fclose(saif_file);
        if (dut_contract() != 0)
            $fatal(1, "[CONTRACT] %0d [SC-CONTRACT] errors in the INT energy schedule", dut_contract());
        if (abit)
            $display("PASS: PaYN abit INT power bench; BA=%0d BW=%0d L=%0d blocks=%0d mode=%0d active=%0d drained=%0d combined=%0d block_len=%0d",
                     BA, BW, L, NBLK, SAIF_MODE, n_active, n_drain, n_comb, BLK_LEN);
        else
            $display("PASS: PaYN bit-plane INT power bench; BA=%0d BW=%0d L=%0d blocks=%0d mode=%0d active=%0d drained=%0d combined=%0d lap_ring_only=%0d",
                     BA, BW, L, NBLK, SAIF_MODE, n_active, n_drain, n_comb, LAP_RING_ONLY);
        $finish;
    end
endmodule
