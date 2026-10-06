`timescale 1ns/1ps

`include "common/clk_util.sv"

// [CBSG-AF-IPD COPY] of designs/payn/power/power_payn_array_bp_int.sv (sha256 in
// designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/README.md) for the
// C-BSG AF + IPD array payn_array_signed_segmented_csa_cbsg_af_ipd in INT mode.
// Changes (marked [AF-IPD]):
//  * DUT: the AF-IPD top (PAYN_ARRAY_DUT names the netlist top for GL); the
//    BPE_DUT_SR / BPE_DUT_IPD options are dropped;
//  * defaults BPE_LAP_LEN = 1 (the in-place lap; 2, 4 and 8 multiply by
//    2^g here and are wrong) and BPE_LAP_RING_ONLY = 1 (shift_in on drain
//    edges only, laps on ring_q alone: the contract the routed BP INT energy
//    campaign used); check with sweeps/cbsg/af_ipd/check_bp_power_trace.py
//    --lap-len 1 --lap-ring-only;
//  * the AF-only inputs held quiet in INT mode: block_start = slice_start = 0
//    (contract), a_len_in = 0, rng_en = 0 (as before), magnitudes 0;
//  * in RTL the AF contract count ([CBSG-AF-CONTRACT]) must stay 0.
// The original header (its BPE_LAP_LEN / BPE_DUT_* notes describe the BP
// bench):
//
// Bit-plane (BP) INT energy bench for payn_array_signed_segmented_csa_bp,
// driving the REAL INT ports per the sequencer contract in the top's header.
// No forces.  It is the measured counterpart of the emulation bench
// designs/payn/power/power_payn_array_int_bitplane.sv (which forced the raw
// planes onto the unchanged CSA array's PE inputs and closed the ring in the
// bench): same mapping, schedule, operands and SAIF windows, so the two sets of
// numbers compare point for point.  The port driving is that of the functional
// bench designs/payn/tb/test_payn_array_bp.sv, without its JUNK / negative
// controls.
//
// Mapping (one PE): row h carries activation plane p = h % BA of activation
// row i = ig*ROWS_PE + h / BA; column v carries output column j = jg*8 + v.
// Lane k / position m of data cycle b carries reduction element
// x = 128*b + 16*k + m.  Weight planes go in time, MSB pass first: in pass q,
// w_raw_in[v][k][m] = bit q of W[x, j].  INT8: BA = BW = 8; W4A8: BA = 8,
// BW = 4; INT4: BA = BW = 4 (two activation rows per block, int_prec = 1).
//
// Contract, as driven here (every input launched at the negedge before the
// capturing posedge P_e, i.e. at the route's 1.25 ns SDC input delay):
//  * SC side quiet for the whole run: rng_en = 0 (Sobol banks frozen at their
//    reset state), a_binary_in = w_binary_in = 0 on every edge (so every INT
//    load carries zero magnitudes and the comparators stay silent),
//    acc_in_west = 0 (lap edges take the ring value, drain edges take 0).
//  * INT entry: the run leaves reset in SC mode and raises int_mode at the
//    negedge before P_{MODE_AT} (default 1; -1 = high through reset; 3 is the
//    latest legal edge).  int_mode is registered, so the first raw plane
//    (captured at P_E0, E0 = 4) needs it high at P_{E0-1}.  The zero-load on
//    INT entry is the pass-0 sign load at P_{E0-1}: load_a and load_w both
//    fire there, after the rise, with zero magnitudes.  int_mode never changes
//    afterwards, so the two-edge MAC guard never fires in the window.
//  * Signs through the existing two-edge path: a_signs_in = (h % BA == BA-1),
//    loaded once; w_signs_in = all ones for the weight-MSB pass, else zero,
//    with load_w + load_w_sign at P_e for a pass whose first raw plane is
//    captured at P_{e+1}.
//  * Ring lap: ring_in high one edge ahead of each of the N_W lap edges (the
//    PE registers it as ring_q), shift_in high on the lap edges (the
//    csa_bp_20261003b contract, still legal on the single-PE top because the
//    tile shift is shift_in | ring_q).  With BPE_LAP_RING_ONLY = 1 (plusarg
//    +LAP_RING_ONLY=1) shift_in is high on drain edges only and ring_q alone
//    shifts the tiles on lap edges: the per-PE lap-enable contract of
//    csa_bp_20261004_lap (on csa_bp_20261003b that mode fails by design).
//    Drain: shift_in with ring_q low.  Zero raw planes (bubbles) during laps
//    and drains.  mac_en = 1 from P_{E0+1}.  int_prec = (BA == 4), static.
//
// Schedule (edge P_e = e-th posedge after the post-reset settle).  Inside a
// block, pass pi (q = BW-1-pi) occupies PASS_LEN = NB + 8 edges: u = 0..NB-1
// capture data, u = NB..NB+7 capture bubbles.  Shift edges are u = NB+1..NB+7
// and u = 0 of the following pass: a ring lap if pi < BW-1, else the drain,
// which overlaps the next block's first pass.  The combiner (u_combiner)
// captures on drain edges and emits int_out / int_out_valid two edges later.
//
// SAIF windows (identical to the emulation bench).  Interval
// I_e = (P_e + 1 ps, P_{e+1} + 1 ps] holds the response to edge P_e and
// exactly one clock period.  It is classed DATA if u < NB, else RING (pi <
// BW-1) or DRAIN (pi = BW-1); e runs over [E0, E_END), E_END = final drain
// edge.  Collection is paused/resumed exactly at the 1 ps marks, so duration
// and clock toggle count stay exact (the SAIF period check holds):
//   BPE_SAIF_MODE 0: data + ring intervals (drain paused, SC methodology)
//   BPE_SAIF_MODE 1: data intervals only (peak)
//   BPE_SAIF_MODE 2: everything, drain included
// The classing is by interval count, not by cause: I_{u=0} holds the 8th lap /
// drain shift and is DATA, I_{u=NB} holds the pass's last MAC and is RING or
// DRAIN.  The combiner's input register loads in drain intervals, but its
// output register loads two edges later, so for the last two to three drained
// columns of a block (u = NB+6.. and u = 0) the out-register update falls in
// the next block's first DATA intervals; modes 0 and 1 include that, as they
// include the 8th drain shift.
//
// Checks: the bench fails on X on the drain rail or the combiner outputs from
// E0 on, and on any int_out_valid edge that is not exactly two edges after a
// drain edge ([TIMING-FAIL]); in RTL the top's [BP-CONTRACT] check fails on a
// MAC that consumes live comparator bits.  Every drained column ("D blk t
// tile_h0..tile_h7", column v = 7 - t) and every combiner word ("C blk t lo
// hi") goes to bpt_trace.txt in the format of the functional bench, and is
// checked against numpy int64 by sweeps/int_mode/bp/check_bp_power_trace.py
// (which runs sweeps/int_mode/bp/check_bp_trace.py unchanged and checks the
// window counts in bpe_saif.txt against the schedule).
//
// Configuration: compile-time defines BPE_BA, BPE_BW, BPE_L, BPE_MROWS,
// BPE_NCOLS, BPE_SAIF_MODE, BPE_MODE_AT, BPE_LAP_RING_ONLY (what the routed
// driver uses, since make sim passes no runtime arguments), each overridable
// at run time by the plusarg of the same name without the prefix (+BA=4
// +SAIF_MODE=2 +LAP_RING_ONLY=1 ...).  The trace header carries lap_ring_only
// in field 12 (the functional bench's position); the PASS line gains
// " lap_ring_only=1" only in that mode, so default runs print what they always
// printed.
// Operands: bpt_a.hex (A row-major, MROWS x L) and bpt_w.hex (W column-major,
// W[x, j] at j*L + x), one two's-complement byte per line, in the run
// directory (sweeps/int_mode/gen_bitplane_workload.py writes them as
// intb_*.hex; the drivers copy them).  RTL needs DesignWare (USE_DW=1) and is
// instantiated with LOW_W = 9 like the route.
//
// Opt-in extensions (sweeps/int_mode/bp/sr/run_int_energy_prelayout_ab.sh);
// none of them is active by default, and a default run prints, writes and
// drives exactly what it did before they existed:
//  * BPE_LAP_LEN (plusarg +LAP_LEN), default 8 = N_W (the BP ring): the
//    lap length g of the sub-ring / in-place-doubling tops.  A non-final pass
//    takes PASS_LEN = NB + g edges (ring_in on g consecutive edges, one ahead
//    of the g lap edges = the last g-1 edges of the pass and u = 0 of the
//    next), the final pass LAST_LEN = NB + 8 (the drain), so a block is
//    BLK_LEN = BW*NB + g*(BW-1) + 8 edges (the schedule of
//    designs/payn/tb/test_payn_array_bp_ipd.sv at +LAP_LEN=g).  With g = 8,
//    PASS_LEN = LAST_LEN = NB + 8: the default schedule edge for edge.  For
//    g != 8 the PASS line gains " lap_len=<g>" and bpe_saif.txt a
//    "BPELAP g PASS_LEN LAST_LEN BLK_LEN" line.
//  * BPE_DUT_SR (with PAYN_LAP_G=<g>) / BPE_DUT_IPD: RTL against the
//    sub-ring top payn_array_signed_segmented_csa_bp_sr or the in-place top
//    payn_array_signed_segmented_csa_bp_ipd (same ports); GL runs name the
//    netlist top with PAYN_ARRAY_DUT as before.
//  * BPE_SAIF_MODE 3 / 4: the windows of modes 1 / 0 classed by CAUSE
//    instead of by interval count.  Interval I_e is a MAC interval if edge
//    P_e is neither a shift edge nor E0 (the first capture, which has no MAC),
//    a LAP interval if P_e is a ring-lap shift, a DRAIN interval if it is a
//    drain shift; e runs over (E0, E_END).  Mode 3 collects MAC intervals,
//    mode 4 MAC + LAP intervals.  The class counts and the segment counts
//    equal those of modes 1 / 0 (blocks*BW*NB MAC, blocks*(BW-1)*g LAP; one
//    MAC interval per pass moves from the pass's first slot u = 0, the lap
//    or drain shift that closes the previous pass, to its last MAC u = NB),
//    so every lap edge's response is in the LAP class whatever g is.
//    Modes 0-2 are unchanged.

`ifndef GL_SIM
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/payn_array_signed_segmented_csa_cbsg_af_ipd.sv"
`endif

`ifndef PAYN_ARRAY_DUT
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa_cbsg_af_ipd
`endif
`ifndef BPE_LAP_LEN
`define BPE_LAP_LEN 1
`endif
`ifndef BPE_BA
`define BPE_BA 8
`endif
`ifndef BPE_BW
`define BPE_BW 8
`endif
`ifndef BPE_L
`define BPE_L 1024
`endif
`ifndef BPE_MROWS
`define BPE_MROWS 1
`endif
`ifndef BPE_NCOLS
`define BPE_NCOLS 8
`endif
`ifndef BPE_SAIF_MODE
`define BPE_SAIF_MODE 0
`endif
`ifndef BPE_MODE_AT
`define BPE_MODE_AT 1
`endif
`ifndef BPE_LAP_RING_ONLY
`define BPE_LAP_RING_ONLY 1
`endif
`ifndef BPE_LOW_W
`define BPE_LOW_W 9
`endif
`ifndef BPE_MAX_EDGES
`define BPE_MAX_EDGES 200000
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
    localparam int LOW_W = `BPE_LOW_W;
    localparam int E0 = 4;                      // first data capture edge
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;

    // Configuration (defines, overridable by plusargs) and derived schedule.
    int BA = `BPE_BA, BW = `BPE_BW, L = `BPE_L;
    int MROWS = `BPE_MROWS, NCOLS = `BPE_NCOLS;
    int SAIF_MODE = `BPE_SAIF_MODE, MODE_AT = `BPE_MODE_AT;
    int LAP_RING_ONLY = `BPE_LAP_RING_ONLY;
    int LAP_LEN = `BPE_LAP_LEN;
    int NB, ROWS_PE, NIG, NJG, NBLK, PASS_LEN, LAST_LEN, BLK_LEN;
    int E_DATA_END, E_END, N_EDGES;
    logic [N_H*K-1:0] a_sign_word;

    logic clk, reset, timeout;

    // SC-side inputs: never driven away from zero (INT contract).
    logic rng_en = 1'b0;
    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    // [AF-IPD] AF-only inputs, quiet in INT mode.
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
    int n_active = 0, n_data = 0, n_ring = 0, n_drain_iv = 0, n_segments = 0;

    ClkUtils #(.TIMEOUT(`BPE_MAX_EDGES)) clk_utils (.clk, .reset, .timeout);

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

`ifdef BPE_VCD
    // Debug only (never in measured runs): top ports and the whole PE.
    initial begin
        $dumpfile("bpe_debug.vcd");
        $dumpvars(1, Top);
        $dumpvars(0, dut.u_pe);
    end
`endif

    always @(posedge clk)
        if (timeout) $fatal(1, "[TIMEOUT] BP INT energy bench exceeded %0d cycles", `BPE_MAX_EDGES);

    // Architectural outputs must stay known from the first data edge on.
    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drain rail entered X: %h", acc_out_east);
    always @(int_out or int_out_valid)
        if (monitor_x && ($isunknown(int_out) || $isunknown(int_out_valid)))
            $fatal(1, "[X-FAIL] combiner output entered X: valid=%b out=%h", int_out_valid, int_out);

    // ---------------------------------------------------------- schedule --
    function automatic void decode(input int e, output int blk, output int pi,
                                   output int u);
        int r;
        r = e - E0;
        blk = r / BLK_LEN;
        r = r % BLK_LEN;
        pi = r / PASS_LEN;
        if (pi > BW - 1) pi = BW - 1;           // the final pass is LAST_LEN long
        u = r - pi*PASS_LEN;                    // (LAP_LEN = 8: r % PASS_LEN)
    endfunction

    // The tile array shifts at P_e (ring lap or drain).  u = 0 closes the
    // previous pass's lap (pi >= 1) or the previous block's drain (pi = 0); a
    // non-final pass laps on its last LAP_LEN-1 edges, the final pass drains
    // on u >= NB+1 (LAP_LEN = 8: every pass shifts on u >= NB+1).
    function automatic bit core_shift_at(input int e);
        int blk, pi, u;
        if (e <= E0 || e > E_END) return 1'b0;
        decode(e, blk, pi, u);
        if (u == 0) return 1'b1;
        if (pi < BW - 1) return u >= PASS_LEN - LAP_LEN + 1;
        return u >= NB + 1;
    endfunction

    // The shift at P_e is a ring-lap shift.
    function automatic bit ring_at(input int e);
        int blk, pi, u;
        if (!core_shift_at(e)) return 1'b0;
        decode(e, blk, pi, u);
        if (u == 0) return pi >= 1;     // closes the lap after pass pi-1
        return pi < BW - 1;
    endfunction

    function automatic bit drain_at(input int e);
        return core_shift_at(e) && !ring_at(e);
    endfunction

    // Drain edge P_e -> (block, step t); step t delivers column v = 7 - t.
    function automatic void drain_slot(input int e, output int bd, output int t);
        int blk, pi, u;
        decode(e, blk, pi, u);
        if (u == 0) begin
            bd = blk - 1;
            t = N_W - 1;
        end else begin
            bd = blk;
            t = u - NB - 1;
        end
    endfunction

    // 0 = data, 1 = ring lap, 2 = drain, for interval I_e (e >= E0).
    function automatic int interval_class(input int e);
        int blk, pi, u;
        decode(e, blk, pi, u);
        if (u < NB) return 0;
        return (pi < BW - 1) ? 1 : 2;
    endfunction

    // Modes 3 / 4: the class of interval I_e by the edge that causes it;
    // -1 outside (E0, E_END), 0 = MAC (P_e does not shift), 1 = ring-lap
    // shift, 2 = drain shift.
    function automatic int cause_class(input int e);
        if (e <= E0 || e >= E_END) return -1;
        if (!core_shift_at(e)) return 0;
        return ring_at(e) ? 1 : 2;
    endfunction

    function automatic bit interval_active(input int e);
        int c;
        if (SAIF_MODE >= 3) begin
            c = cause_class(e);
            return (c == 0) || (SAIF_MODE == 4 && c == 1);
        end
        if (e < E0 || e >= E_END) return 1'b0;
        c = interval_class(e);
        case (SAIF_MODE)
            0: return c != 2;
            1: return c == 0;
            default: return 1'b1;
        endcase
    endfunction

    // Raw planes captured into the bit pipes at P_e, assembled in temporaries
    // and applied in one assignment (one event per input bus per cycle).
    task automatic set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, pi, u, ig, jg, q, i, p, j, x;
        a_next = '0;
        w_next = '0;
        if (e >= E0 && e < E_DATA_END) begin
            decode(e, blk, pi, u);
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
    // (P_{E0-1}) loads both sides: the zero-load on INT entry.  Magnitude
    // inputs are zero on every edge.
    task automatic set_signs(input int e);
        int blk, pi, u;
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
        if (e + 1 >= E0 && e + 1 < E_DATA_END) begin
            decode(e + 1, blk, pi, u);
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

    // Pre-edge acc_out_east on a drain edge.
    task automatic read_drain(input int e);
        int bd, t;
        if (!drain_at(e)) return;
        drain_slot(e, bd, t);
        if ($isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drained column X: block %0d step %0d", bd, t);
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
        void'($value$plusargs("LAP_RING_ONLY=%d", LAP_RING_ONLY));
        void'($value$plusargs("LAP_LEN=%d", LAP_LEN));

        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (!(SAIF_MODE >= 0 && SAIF_MODE <= 4)) $fatal(1, "SAIF_MODE must be 0, 1, 2, 3 or 4 (got %0d)", SAIF_MODE);
        if (!(LAP_LEN == 1 || LAP_LEN == 2 || LAP_LEN == 4 || LAP_LEN == N_W))
            $fatal(1, "LAP_LEN must be 1, 2, 4 or %0d (got %0d)", N_W, LAP_LEN);
        if (!(LAP_RING_ONLY == 0 || LAP_RING_ONLY == 1)) $fatal(1, "LAP_RING_ONLY must be 0 or 1 (got %0d)", LAP_RING_ONLY);
        if (!(MODE_AT == -1 || (MODE_AT >= 0 && MODE_AT <= E0 - 1)))
            $fatal(1, "MODE_AT must be -1 or 0..%0d (got %0d)", E0 - 1, MODE_AT);
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
        PASS_LEN = NB + LAP_LEN;                // data + one LAP_LEN-shift lap
        LAST_LEN = NB + N_W;                    // data + the 8-shift drain
        BLK_LEN = (BW - 1) * PASS_LEN + LAST_LEN;   // LAP_LEN = 8: BW * PASS_LEN
        E_DATA_END = E0 + NBLK*BLK_LEN;
        E_END = E_DATA_END;                     // final drain edge
        N_EDGES = E_END + 3;                    // + combiner latency
        if (N_EDGES + 16 > `BPE_MAX_EDGES) $fatal(1, "schedule exceeds BPE_MAX_EDGES");

        read_hex("bpt_a.hex", MROWS*L, a_mem);
        read_hex("bpt_w.hex", NCOLS*L, w_mem);
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);
        int_mode = (MODE_AT < 0);
        int_prec = (BA == 4);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("bpt_trace.txt", "w");
        if (trace_file == 0) $fatal(1, "cannot open bpt_trace.txt");
        // check_bp_trace.py's 14-field header: no JUNK / negative controls;
        // field 12 is lap_ring_only.
        $fwrite(trace_file, "BPTCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, int_prec, 0, 0, 0, LAP_RING_ONLY, 0, MODE_AT);

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
            ring_in = ring_at(e + 1);
            shift_in = LAP_RING_ONLY ? drain_at(e) : core_shift_at(e);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
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
                case ((SAIF_MODE >= 3) ? cause_class(e) : interval_class(e))
                    0: n_data++;
                    1: n_ring++;
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

        saif_file = $fopen("bpe_saif.txt", "w");
        if (saif_file == 0) $fatal(1, "cannot open bpe_saif.txt");
        $fwrite(saif_file, "BPECFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, SAIF_MODE, MODE_AT, E0, E_END, N_EDGES);
        $fwrite(saif_file, "SAIFWIN %0d %0d %0d %0d %0d\n",
                n_active, n_data, n_ring, n_drain_iv, n_segments);
        if (LAP_LEN != N_W)
            $fwrite(saif_file, "BPELAP %0d %0d %0d %0d\n", LAP_LEN, PASS_LEN, LAST_LEN, BLK_LEN);
        $fclose(saif_file);
`ifndef GL_SIM
        if (dut.contract_errors != 0)
            $fatal(1, "[CONTRACT] %0d [CBSG-AF-CONTRACT] errors in the INT energy schedule", dut.contract_errors);
`endif
        $display("PASS: BP INT SAIF captured; BA=%0d BW=%0d L=%0d blocks=%0d mode=%0d active=%0d drained=%0d combined=%0d%s%s",
                 BA, BW, L, NBLK, SAIF_MODE, n_active, n_drain, n_comb,
                 LAP_RING_ONLY ? " lap_ring_only=1" : "",
                 (LAP_LEN != N_W) ? $sformatf(" lap_len=%0d", LAP_LEN) : "");
        $finish;
    end
endmodule
