`timescale 1ns/1ps

`include "common/clk_util.sv"

// Functional bench for the C-BSG AF + IPD array
// (payn_array_signed_segmented_csa_cbsg_af_ipd): SC mode (the AF C-BSG edge,
// bit-exact with the scmp_kernels integer accumulator), INT mode (bit-plane
// INT8 / W4A8 / INT4 with 1-edge in-place laps) and SC <-> INT switching on
// one DUT.  One compile serves every mode (+MODE=sc|int|switch).
//
// Sources: the SC part is designs/payn/tb/test_payn_array_cbsg_af.sv (the AF
// golden-suite bench), the INT part is designs/payn/tb/test_payn_array_bp_ipd.sv
// (the IPD single-PE bench); README.md of the variant lists their sha256.
// Differences to those benches are marked [AF-IPD].
//
// ------------------------------------------------------------ +MODE=sc --
// The AF bench: plays golden cases written by sweeps/cbsg/cbsg_ref.py --emit,
// sweeps/cbsg/af/emit_af_cases.py or sweeps/cbsg/af/review/emit_review_cases.py,
// one 8 x 8 PE per case, and compares every drain bit-exactly against
// acc_exp.mem; after every block the tile accumulators (acc_blk.mem), after
// every load edge the encoder outputs (ka.mem) and the phase register
// (phase.mem).  +CASES=d1,d2,.. play back to back without reset.  Schedule
// and every AF plusarg are the AF bench's (see there):
//   +SEED=n +FULL_CYCLES +GAPS +RNG_GAP_LOW +MAC_EXACT +LOOSE_DRAIN +STALL
//   +RNG_LOW_END +JUNK_BUS +MID_RESET +RESET_SETTLE=n +NO_CALL_SS +NO_SLICE_SS
//   +NO_SLICE_START +KILL_DRAIN_RESET; negative controls +NEG_STALL_NOMAC
//   +NEG_STRAY_LOAD +JUNK_SS +NEG_LANE_REV +NEG_KA_EQ_B +NEG_ROW_LEN_MAX
//   +NEG_LEN_128 +NEG_SHORT_BLOCK +NEG_DRAIN_EARLY +NEG_NEXT_EARLY.
// [AF-IPD] additions:
//   +INT_JUNK      random a_raw_in, w_raw_in, int_prec and ring_in on every
//                  edge while int_mode is low (own xorshift generator, so the
//                  bench's $urandom stream and therefore the schedule are those
//                  of a run without it); SC must not change
//   +SC_TRACE=f    write every drained accumulator (D), per-block tile
//                  accumulator (B) and load-edge phase + kA (K) to f.  The
//                  runner compiles this bench also against the AF top
//                  (+define+CAI_DUT_AF) and requires byte-identical traces
//   lockstep       compiled with +define+CAI_LOCKSTEP, an AF top instance
//                  (ref_af) runs on the same SC inputs; every negedge the bench
//                  compares acc_out_east, the stream bits before and after the
//                  PE bit pipes, signs, cyc / phase / W words, every kA and every
//                  tile accumulator, and requires ring_q = 0, int_out_valid = 0
//                  and int_out = 0 ([LOCKSTEP] tag); contract counts must be
//                  equal.  The NEG_KA_EQ_B / KILL_DRAIN_RESET forces apply to
//                  both tops, so lockstep holds in every SC run
//   +RNG_LOW_IDLE  rng_en low on every edge outside a running block (between
//                  blocks, in drains, in case tails), so the AF counter holds at
//                  the last block's cycle count instead of stepping to IDLE
//                  (legal: that cycle is past every row's L, so A is silent);
//                  in +MODE=switch the counter then reaches the next SC block
//                  after an INT segment still below IDLE
//   +NEG_SHORT_LAST=n  the last block of every case runs n cycles short (at
//                  least 1).  With +RNG_LOW_IDLE in +MODE=switch, the cut is
//                  flagged ("cuts a block") only at the first SC block_start
//                  after the INT segment that follows the case
//   +DRAIN_SAMPLE_LATE_PS=n  [AF-IPD, route step] read acc_out_east n ps before
//                  the shift edge that consumes it (the SDC output-delay point:
//                  OUTPUT_DELAY = 0.05 ns -> n = 50) instead of at the negedge
//                  before it.  Absent (the default): the negedge, as the AF bench,
//                  so every RTL / post-synthesis run is unchanged.  In RTL both
//                  points read the same value (nothing changes between them).
//                  Why: on the routed AF-IPD netlist the drain rail settles up to
//                  1.45 ns (PT) after the edge, past the 1.25 ns negedge but well
//                  inside the SDC budget (slack +1.00 ns); see the variant
//                  README, "Route and power".
//   The case tail is deterministic: a case ends on the negedge right after its
//   last drain shift edge (the AF bench could end one edge later, depending on
//   thread order), so the next case's first block may load on the edge after
//   the drain.
// Result tags: [CHECK] [BLOCK] [KA] [PHASE] [CONTRACT] as the AF bench, plus
// [LOCKSTEP].  Last line PASS: / FAIL: CBSG AF-IPD bench.
//
// ----------------------------------------------------------- +MODE=int --
// The IPD single-PE bench (1-edge laps, +LAP_LEN, default 1) on the real INT
// ports: +BA +BW +L +MROWS +NCOLS +MODE_AT +JUNK +NEG_NO_RING +NEG_PREC
// +LAP_RING_ONLY +NEG_RING_STRAY +NEG_MAG +LAP_LEN +NEG_NO_BUBBLE
// +NEG_RING_STRAY_MID, operands bpt_a.hex / bpt_w.hex in the run directory
// (sweeps/cbsg/af_ipd/gen_bp_workload.py), trace bpt_trace.txt (format of the
// IPD bench, 15-field BPTCFG header) checked by sweeps/cbsg/af_ipd/check_bp_trace.py,
// schedule bpt_sched.txt.  The schedule (E0 = 4 etc.) is the IPD bench's, so
// the traces must equal the IPD top's (run by the runner on the original IPD
// bench).  [AF-IPD] the AF-only inputs in INT mode: block_start = slice_start =
// 0 (contract), rng_en = 0 and a_len_in = 0 by default; under +JUNK rng_en and
// a_len_in are random on every edge (load edges included) as well, on top of
// the IPD bench's junk.  Magnitudes are driven 0 on every edge (the IPD bench
// left them at their reset value 0).  The JUNK extra loads (random sign
// words, load_X_sign low) come only on edges where int_mode is high: before
// int_mode rises the edge is an SC edge, where a load without block_start
// breaks the AF contract.  Additions:
//   +PARK_CYC0     one SC block_start (no loads) at edge 1 while int_mode is
//                  still low (needs MODE_AT >= 2), then rng_en = 0: the AF counter
//                  sits at cycle 0 for the whole INT run, so the A thermometer is
//                  live for any kA > 0 (after reset it parks in IDLE, where A is 0
//                  whatever kA is); with zero magnitudes the run must PASS
//   +NEG_MAG_A     (with +PARK_CYC0) A loads carry random magnitudes 1..128 and
//                  L = 128: the thermometer fires, [BP-CONTRACT] must stop the run
//   +NEG_MAG_W     W loads carry random magnitudes 1..128: [BP-CONTRACT]
//   +INT_LEN_DC=v  a_len_in = v on every row in INT mode (a don't-care there;
//                  default 0; JUNK overrides with random values).  With v > 128
//                  after a short SC block it is the review case for the
//                  [CBSG-AF-CONTRACT] cut-block check (it must read the L of the
//                  last SC load, not a_len_q, which INT A loads also load)
//   +JUNK_SCSTROBE random block_start / slice_start in INT mode: the INT
//                  result stays exact (they reach only the AF block clock) but
//                  the [CBSG-AF-CONTRACT] count must be > 0
// The drained columns and combiner words are read by one posedge monitor
// that knows every scheduled drain edge (absolute), so the timing check
// ([TIMING-FAIL]: int_out_valid exactly two edges after each drain edge, and
// never otherwise) covers every edge after reset in every mode.
//
// -------------------------------------------------------- +MODE=switch --
// +SWITCH=sc:<case dir>,int:<int dir>,...  SC golden cases and INT blocks on
// one DUT with no reset.  An INT dir holds bpt_a.hex, bpt_w.hex and bpt_cfg.txt
// ("BA BW L MROWS NCOLS MODE_AT JUNK LAP_RING_ONLY", MODE_AT 0..3); the bench
// writes bpt_trace.txt / bpt_sched.txt there.  Tightest transitions by
// default (+SW_GAP=n adds n idle edges at every switch):
//   SC -> INT: the SC case ends on the negedge after its last drain edge
//     D_last; the INT segment's edge 0 is D_last+1 and E0 = MODE_AT + 1
//     (MODE_AT = 0: int_mode high from D_last+1, zero-load on D_last+1,
//     first raw capture D_last+2);
//   INT -> SC: int_mode stays high through the INT segment's last drain edge
//     E_END and falls for E_END+1, where the next SC case's first block loads.
// +INT_JUNK applies to the SC segments.  Negative controls (must FAIL):
//   +NEG_SW_EARLY_INT     int_mode high on the SC drain's last edge before an
//                         INT segment: the combiner captures an SC column
//                         ([TIMING-FAIL])
//   +NEG_SW_LATE_DROP     int_mode falls one edge late after an INT segment: the
//                         SC block_start lands in INT mode and the guard drops
//                         its first MAC (CHECK + CONTRACT)
//   +NEG_SW_NO_ZERO_LOAD  INT segments do not zero the magnitudes after SC: the
//                         AF streams stay live ([BP-CONTRACT])
//   +NEG_SW_INT_DROP_EARLY int_mode falls on the INT segment's last drain edge:
//                         its last column is never combined (bench count FAIL)
//   +NEG_SW_NO_RELOAD     the first SC block after INT loads A but not W (W holds
//                         the INT zero magnitudes): CHECK + CONTRACT
//
// Needs DesignWare for the CSA tile heap: make sim ... USE_DW=1 (or the
// runner's -y $SYNOPSYS/dw/sim_ver).

`ifndef GL_SIM
`ifdef CAI_DUT_AF
`include "payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv"
`else
`include "payn/variants/signed_segmented_csa_cbsg_af_ipd/payn_array_signed_segmented_csa_cbsg_af_ipd.sv"
`ifdef CAI_LOCKSTEP
`include "payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv"
`endif
`endif
`endif

`ifndef CAI_MAX_BLK
`define CAI_MAX_BLK 4096
`endif
`ifndef CAI_OWIDTH
`define CAI_OWIDTH 24
`endif
`ifndef CAI_LOW_W
`define CAI_LOW_W 9
`endif
`ifndef CAI_TIMEOUT
`define CAI_TIMEOUT 50000000
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif
`ifndef CAI_RESET_SETTLE
`define CAI_RESET_SETTLE 0            // default of +RESET_SETTLE
`endif

module Top;
    localparam int K = 8;
    localparam int M = 16;
    localparam int N_H = 8;
    localparam int N_W = 8;
    localparam int WIDTH = 8;
    localparam int OWIDTH = `CAI_OWIDTH;
    localparam int LOW_W = `CAI_LOW_W;
    localparam int MAX_BLK = `CAI_MAX_BLK;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
    localparam int MAX_PRINT = 8;
    localparam int MAX_SEG = 64;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;
    logic block_start = 1'b0, slice_start = 1'b0;
    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*WIDTH-1:0]   a_len_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;
    // INT ports (dangling when compiled against the AF top, +define+CAI_DUT_AF)
    logic int_mode = 1'b0, int_prec = 1'b0, ring_in = 1'b0;
    logic [N_H*K*M-1:0] a_raw_in = '0;
    logic [N_W*K*M-1:0] w_raw_in = '0;
    logic [63:0] int_out;
    logic int_out_valid;

    ClkUtils #(.TIMEOUT(`CAI_TIMEOUT)) clk_utils (.clk, .reset, .timeout);

    always @(posedge timeout) $fatal(1, "[TIMEOUT] CBSG AF-IPD bench");

`ifdef CAI_DUT_AF
    payn_array_signed_segmented_csa_cbsg_af #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) dut (.*);
`elsif GL_SIM
    payn_array_signed_segmented_csa_cbsg_af_ipd dut (.*);
`else
    payn_array_signed_segmented_csa_cbsg_af_ipd #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
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

    //------------------------------------------------------------ options --
    string bench_mode = "sc";
    bit opt_full, opt_gaps, opt_rng_gap_low, opt_mac_exact, opt_loose;
    bit opt_stall, opt_rng_low_end, opt_junk_bus, opt_mid_reset;
    bit opt_no_call_ss, opt_no_slice_ss, opt_no_slice_start, opt_kill_drain_reset;
    bit neg_lane_rev, neg_ka_eq_b, neg_row_len_max;
    bit neg_len_128, neg_short, neg_drain_early, neg_next_early;
    bit neg_stall_nomac, neg_stray_load, opt_junk_ss;
    bit opt_int_junk;                                   // [AF-IPD]
    bit neg_sw_early_int, neg_sw_late_drop, neg_sw_no_zero_load, neg_sw_int_drop_early, neg_sw_no_reload;
    int sw_gap = 0;
    bit opt_rng_low_idle;                               // [AF-IPD] review fix
    int neg_short_last = 0;                             // [AF-IPD] review fix
    int drain_sample_late_ps = 0;                       // [AF-IPD] route step: +DRAIN_SAMPLE_LATE_PS
    bit stall_edge [int unsigned];
    bit mac_kill [int unsigned];
    int total_stalls = 0, total_stray = 0;

    //------------------------------------------------------------- golden --
    logic [31:0] cfg_m   [8];
    logic [7:0]  a_mag_m [MAX_BLK*64];
    logic [3:0]  a_sgn_m [MAX_BLK*64];
    logic [7:0]  w_mag_m [MAX_BLK*64];
    logic [3:0]  w_sgn_m [MAX_BLK*64];
    logic [7:0]  len_m   [MAX_BLK*8];
    logic [3:0]  ss_m    [MAX_BLK];
    logic [3:0]  cs_m    [MAX_BLK];
    logic [3:0]  ph_m    [MAX_BLK];
    logic [3:0]  cy_m    [MAX_BLK];
    logic [3:0]  dr_m    [MAX_BLK];
    logic [7:0]  ka_m    [MAX_BLK*64];
    logic [31:0] accb_m  [MAX_BLK*64];
    logic [31:0] acce_m  [MAX_BLK*64];

    int n_blk, n_drn;

    task automatic load_case(input string dir);
        $readmemh({dir, "/cfg.mem"}, cfg_m, 0, 6);
        n_blk = int'(cfg_m[0]);
        n_drn = int'(cfg_m[1]);
        if (cfg_m[2] != N_H || cfg_m[3] != N_W || cfg_m[4] != K || cfg_m[5] != M)
            $fatal(1, "[BENCH] %s: shape %0d x %0d, %0d lanes x %0d positions; bench is %0d x %0d, %0d x %0d",
                   dir, cfg_m[2], cfg_m[3], cfg_m[4], cfg_m[5], N_H, N_W, K, M);
        if (n_blk < 1 || n_blk > MAX_BLK || n_drn < 1 || n_drn > n_blk)
            $fatal(1, "[BENCH] %s: %0d blocks / %0d drains (MAX_BLK %0d)", dir, n_blk, n_drn, MAX_BLK);
        $readmemh({dir, "/a_mag.mem"}, a_mag_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/a_sgn.mem"}, a_sgn_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/w_mag.mem"}, w_mag_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/w_sgn.mem"}, w_sgn_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/row_len.mem"}, len_m, 0, n_blk*8 - 1);
        $readmemh({dir, "/slice_start.mem"}, ss_m, 0, n_blk - 1);
        $readmemh({dir, "/call_start.mem"}, cs_m, 0, n_blk - 1);
        $readmemh({dir, "/phase.mem"}, ph_m, 0, n_blk - 1);
        $readmemh({dir, "/cycles.mem"}, cy_m, 0, n_blk - 1);
        $readmemh({dir, "/drain.mem"}, dr_m, 0, n_blk - 1);
        $readmemh({dir, "/ka.mem"}, ka_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/acc_blk.mem"}, accb_m, 0, n_blk*64 - 1);
        $readmemh({dir, "/acc_exp.mem"}, acce_m, 0, n_drn*64 - 1);
    endtask

    //----------------------------------------------------------- counters --
    int drain_vals = 0, drain_bad = 0;
    int blk_vals = 0, blk_bad = 0;
    int ka_vals = 0, ka_bad = 0;
    int ph_vals = 0, ph_bad = 0;
    int total_blocks = 0, total_drains = 0, total_calls = 0;
    string case_name;
    int case_idx = 0;
    integer sc_trace = 0;                 // [AF-IPD] +SC_TRACE file

    //------------------------------------------------------- edge counter --
    // edge_n = posedges so far; at a negedge the upcoming edge is edge_n + 1,
    // and in a posedge process (before the nonblocking update) the current
    // edge is edge_n + 1 as well.
    int unsigned edge_n = 0;
    always @(posedge clk) edge_n <= edge_n + 1;

    bit run_active = 1'b0;
    bit mac_edge [int unsigned];

    always @(negedge clk) begin
        if (run_active) begin
            if (opt_mac_exact)
                mac_en = mac_edge.exists(edge_n + 1);
            else
                mac_en = 1'b1;
        end
        if (mac_edge.exists(edge_n + 1))
            mac_edge.delete(edge_n + 1);
        if (mac_kill.exists(edge_n + 1)) begin
            if (run_active) mac_en = 1'b0;
            mac_kill.delete(edge_n + 1);
        end
    end

    //------------------------------------------------- [AF-IPD] INT junk --
    // Random INT inputs while int_mode is low (SC segments), from an own
    // xorshift32 so the bench's $urandom stream is untouched.
    bit sc_int_junk_on = 1'b0;
    int unsigned jx = 32'h2545_F491;
    function automatic int unsigned jrand();
        jx ^= jx << 13;
        jx ^= jx >> 17;
        jx ^= jx << 5;
        return jx;
    endfunction
    int unsigned junk_edges = 0;
    always @(negedge clk) begin
        if (sc_int_junk_on && int_mode === 1'b0) begin
            for (int i = 0; i < N_H*K*M; i += 32) a_raw_in[i +: 32] = jrand();
            for (int i = 0; i < N_W*K*M; i += 32) w_raw_in[i +: 32] = jrand();
            int_prec = jrand() & 1;
            ring_in = jrand() & 1;
            junk_edges++;
        end
    end

`ifndef GL_SIM
    //------------------------------------------- hierarchical observation --
    logic signed [OWIDTH-1:0] tile_acc [N_H][N_W];
    for (genvar h = 0; h < N_H; h++) begin : g_peek_row
        for (genvar v = 0; v < N_W; v++) begin : g_peek_col
            assign tile_acc[h][v] = dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_out;
        end
    end

    // NEG_KA_EQ_B: the naive encoder kA = min(b, L) in place of the closed form.
    logic [N_H*K*WIDTH-1:0] neg_ka;
    for (genvar h = 0; h < N_H; h++) begin : g_neg_row
        for (genvar k = 0; k < K; k++) begin : g_neg_lane
            logic [7:0] nb, nl;
            assign nb = dut.u_peripheral.a_binary_q[(h*K + k)*WIDTH +: WIDTH];
            assign nl = dut.u_peripheral.a_len_q[h*WIDTH +: WIDTH];
            assign neg_ka[(h*K + k)*WIDTH +: WIDTH] = (nb < nl) ? nb : nl;
        end
    end
    initial begin
        #0;
        if ($test$plusargs("NEG_KA_EQ_B"))
            force dut.u_peripheral.ka_flat = neg_ka;
        // Model of an edge without the structural slice restart: only
        // slice_start resets the phase.
        if ($test$plusargs("KILL_DRAIN_RESET"))
            force dut.u_rng.drain_seen = 1'b0;
    end

`ifdef CAI_LOCKSTEP
    //--------------------------------------------- [AF-IPD] AF lockstep --
    logic [N_H*OWIDTH-1:0] ref_acc_out_east;
    payn_array_signed_segmented_csa_cbsg_af #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) ref_af (
        .clk, .reset, .rng_en, .load_a, .load_w, .load_a_sign, .load_w_sign, .mac_en, .shift_in,
        .a_binary_in, .a_signs_in, .w_binary_in, .w_signs_in,
        .acc_in_west, .acc_out_east(ref_acc_out_east),
        .a_len_in, .block_start, .slice_start
    );
    logic [N_H*N_W*OWIDTH-1:0] ls_tiles_dut, ls_tiles_ref;
    logic [N_H*K*WIDTH-1:0] neg_ka_ref;
    for (genvar h = 0; h < N_H; h++) begin : g_ls_row
        for (genvar v = 0; v < N_W; v++) begin : g_ls_col
            assign ls_tiles_dut[(h*N_W + v)*OWIDTH +: OWIDTH] = dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_out;
            assign ls_tiles_ref[(h*N_W + v)*OWIDTH +: OWIDTH] = ref_af.u_pe.u_array_core.g_row[h].g_col[v].u_inner.acc_out;
        end
        for (genvar k = 0; k < K; k++) begin : g_ls_neg
            logic [7:0] nb, nl;
            assign nb = ref_af.u_peripheral.a_binary_q[(h*K + k)*WIDTH +: WIDTH];
            assign nl = ref_af.u_peripheral.a_len_q[h*WIDTH +: WIDTH];
            assign neg_ka_ref[(h*K + k)*WIDTH +: WIDTH] = (nb < nl) ? nb : nl;
        end
    end
    initial begin
        #0;
        if ($test$plusargs("NEG_KA_EQ_B"))
            force ref_af.u_peripheral.ka_flat = neg_ka_ref;
        if ($test$plusargs("KILL_DRAIN_RESET"))
            force ref_af.u_rng.drain_seen = 1'b0;
    end
    bit ls_on = 1'b0;
    int ls_edges = 0, ls_bad = 0;
    always @(negedge clk) begin
        if (ls_on) begin
            ls_edges++;
            if (acc_out_east !== ref_acc_out_east || ls_tiles_dut !== ls_tiles_ref ||
                dut.a_bits !== ref_af.a_bits || dut.w_bits !== ref_af.w_bits ||
                dut.a_signs !== ref_af.a_signs || dut.w_signs !== ref_af.w_signs ||
                dut.a_bits_out_nc !== ref_af.a_bits_out_nc || dut.w_bits_out_nc !== ref_af.w_bits_out_nc ||
                dut.a_signs_out_nc !== ref_af.a_signs_out_nc || dut.w_signs_out_nc !== ref_af.w_signs_out_nc ||
                dut.cyc !== ref_af.cyc || dut.phase !== ref_af.phase || dut.w_words !== ref_af.w_words ||
                dut.u_peripheral.ka_flat !== ref_af.u_peripheral.ka_flat ||
                dut.u_rng.slice_pending_q !== ref_af.u_rng.slice_pending_q ||
                dut.u_pe.ring_q !== 1'b0 || int_out_valid !== 1'b0 || int_out !== '0) begin
                ls_bad++;
                if (ls_bad <= MAX_PRINT)
                    $display("[LOCKSTEP] edge %0d: AF-IPD top differs from the AF top (acc_east %0b tiles %0b a_bits %0b w_bits %0b pipes %0b/%0b cyc %0d/%0d phase %0d/%0d ka %0b ring_q %b valid %b)",
                             edge_n, acc_out_east !== ref_acc_out_east, ls_tiles_dut !== ls_tiles_ref,
                             dut.a_bits !== ref_af.a_bits, dut.w_bits !== ref_af.w_bits,
                             dut.a_bits_out_nc !== ref_af.a_bits_out_nc, dut.w_bits_out_nc !== ref_af.w_bits_out_nc,
                             dut.cyc, ref_af.cyc, dut.phase, ref_af.phase,
                             dut.u_peripheral.ka_flat !== ref_af.u_peripheral.ka_flat, dut.u_pe.ring_q, int_out_valid);
            end
        end
    end
`endif
`endif

    //-------------------------------------------------------- block peeks --
    typedef struct { int unsigned at; int b; } peek_t;
    peek_t peek_q [$];

    task automatic check_block(input int b);
`ifndef GL_SIM
        if (sc_trace != 0) $fwrite(sc_trace, "B %0d %0d", case_idx, b);
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) begin
                logic signed [31:0] exp_v;
                exp_v = $signed(accb_m[b*64 + h*8 + v]);
                blk_vals++;
                if (sc_trace != 0) $fwrite(sc_trace, " %0d", tile_acc[h][v]);
                if (tile_acc[h][v] !== OWIDTH'(exp_v)) begin
                    blk_bad++;
                    if (blk_bad <= MAX_PRINT)
                        $display("[BLOCK] %s block %0d tile (%0d,%0d): %0d, expected %0d",
                                 case_name, b, h, v, tile_acc[h][v], exp_v);
                end
            end
        if (sc_trace != 0) $fwrite(sc_trace, "\n");
`endif
    endtask

    always @(negedge clk) begin
        while (peek_q.size() > 0 && peek_q[0].at <= edge_n) begin
            if (peek_q[0].at == edge_n)
                check_block(peek_q[0].b);
            void'(peek_q.pop_front());
        end
    end

    //------------------------------------------------------------- drains --
    typedef struct { int unsigned d0; int di; } drain_t;
    drain_t drain_q [$];
    bit drain_busy = 1'b0;
    int unsigned drain_last_edge = 0;     // [AF-IPD] last shift edge of the drain in flight / last drain
    bit early_int_arm = 1'b0;             // [AF-IPD] NEG_SW_EARLY_INT on the case's last drain

    initial begin
        drain_t dr;
        logic signed [OWIDTH-1:0] got [N_H][N_W];
        forever begin
            wait (drain_q.size() > 0);
            dr = drain_q.pop_front();
            drain_busy = 1'b1;
            drain_last_edge = dr.d0 + N_W - 1;
            while (edge_n + 1 < dr.d0) @(negedge clk);
            acc_in_west = '0;
            for (int s = 0; s < N_W; s++) begin
                if (drain_sample_late_ps == 0) begin
                    for (int h = 0; h < N_H; h++)
                        got[h][N_W-1-s] = acc_out_east[h*OWIDTH +: OWIDTH];
                end else begin
                    // [AF-IPD] route step: read drain_sample_late_ps before the shift edge
                    // (this negedge + PERIOD/2); done before the loop's next negedge.
                    fork
                        automatic int ss = s;
                        begin
                            #(PERIOD / 2.0 - drain_sample_late_ps / 1000.0);
                            for (int h = 0; h < N_H; h++)
                                got[h][N_W-1-ss] = acc_out_east[h*OWIDTH +: OWIDTH];
                        end
                    join_none
                end
                shift_in = 1'b1;
                if (s == N_W - 1 && early_int_arm && dr.di == n_drn - 1)
                    int_mode = 1'b1;              // NEG_SW_EARLY_INT: int_mode high on the last SC drain edge
                @(negedge clk);
            end
            shift_in = 1'b0;
            if (sc_trace != 0) $fwrite(sc_trace, "D %0d %0d", case_idx, dr.di);
            for (int h = 0; h < N_H; h++)
                for (int v = 0; v < N_W; v++) begin
                    logic signed [31:0] exp_v;
                    exp_v = $signed(acce_m[dr.di*64 + h*8 + v]);
                    drain_vals++;
                    if (sc_trace != 0) $fwrite(sc_trace, " %0d", got[h][v]);
                    if (got[h][v] !== OWIDTH'(exp_v)) begin
                        drain_bad++;
                        if (drain_bad <= MAX_PRINT)
                            $display("[CHECK] %s drain %0d (%0d,%0d): %0d, expected %0d",
                                     case_name, dr.di, h, v, got[h][v], exp_v);
                    end
                end
            if (sc_trace != 0) $fwrite(sc_trace, "\n");
            total_drains++;
            drain_busy = 1'b0;
        end
    end

    //---------------------------------------------------------- stimulus --
    int unsigned cur_end = 0;          // last advance edge (B+C) of the running block
    bit first_block_of_run = 1'b1;
    bit first_block_after_int = 1'b0;  // [AF-IPD] NEG_SW_NO_RELOAD

    task automatic idle_controls();
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        block_start = 1'b0;
        slice_start = 1'b0;
        if (edge_n + 1 <= cur_end)
            rng_en = !stall_edge.exists(edge_n + 1) && !(opt_rng_low_end && edge_n + 1 == cur_end);
        else if (opt_rng_low_idle)               // [AF-IPD] RNG_LOW_IDLE: the counter holds after the block
            rng_en = 1'b0;
        else if (!(opt_gaps && opt_rng_gap_low))
            rng_en = 1'b1;
        else
            rng_en = 1'($urandom & 1);
        if (opt_junk_ss) slice_start = 1'($urandom & 1);
        if (opt_junk_bus) begin
            for (int i = 0; i < N_H*K; i++) begin
                a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
                a_signs_in[i] = 1'($urandom);
            end
            for (int i = 0; i < N_W*K; i++) begin
                w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom);
                w_signs_in[i] = 1'($urandom);
            end
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'($urandom);
        end
        if (neg_stray_load && $urandom_range(0, 15) == 0) begin
            // A legal-valued load pair with no restart: only the operands change.
            total_stray++;
            if ($urandom & 1) begin
                for (int i = 0; i < N_H*K; i++) begin
                    a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(0, 128));
                    a_signs_in[i] = 1'($urandom);
                end
                for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'($urandom_range(1, 128));
                load_a = 1'b1;
                load_a_sign = 1'b1;
            end else begin
                for (int i = 0; i < N_W*K; i++) begin
                    w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(0, 128));
                    w_signs_in[i] = 1'($urandom);
                end
                load_w = 1'b1;
                load_w_sign = 1'b1;
            end
        end
    endtask

    task automatic drive_block(input int b);
        int max_len;
        bit ss;
        max_len = 0;
        for (int h = 0; h < N_H; h++)
            if (int'(len_m[b*8 + h]) > max_len) max_len = int'(len_m[b*8 + h]);
        for (int h = 0; h < N_H; h++) begin
            int len;
            len = int'(len_m[b*8 + h]);
            if (neg_row_len_max) len = max_len;
            if (neg_len_128) len = 128;
            a_len_in[h*WIDTH +: WIDTH] = WIDTH'(len);
            for (int k = 0; k < K; k++) begin
                int kk;
                kk = neg_lane_rev ? (K - 1 - k) : k;
                a_binary_in[(h*K + kk)*WIDTH +: WIDTH] = a_mag_m[b*64 + h*8 + k];
                a_signs_in[h*K + kk] = a_sgn_m[b*64 + h*8 + k][0];
            end
        end
        for (int k = 0; k < K; k++) begin
            int kk;
            kk = neg_lane_rev ? (K - 1 - k) : k;
            for (int v = 0; v < N_W; v++) begin
                w_binary_in[(v*K + kk)*WIDTH +: WIDTH] = w_mag_m[b*64 + k*8 + v];
                w_signs_in[v*K + kk] = w_sgn_m[b*64 + k*8 + v][0];
            end
        end
        ss = ss_m[b][0];
        if (opt_no_call_ss && cs_m[b][0] && !first_block_of_run) ss = 1'b0;
        if (opt_no_slice_ss) ss = cs_m[b][0];
        if (opt_no_slice_start) ss = 1'b0;
        slice_start = ss;
        block_start = 1'b1;
        load_a = 1'b1;
        load_w = 1'b1;
        load_a_sign = 1'b1;
        load_w_sign = 1'b1;
        if (neg_sw_no_reload && first_block_after_int) begin
            load_w = 1'b0;                       // NEG_SW_NO_RELOAD: W keeps the INT zero magnitudes
            load_w_sign = 1'b0;
        end
        first_block_after_int = 1'b0;
        if (opt_gaps) rng_en = 1'($urandom & 1);   // don't-care on the restart edge
        first_block_of_run = 1'b0;
    endtask

    task automatic check_load(input int b);
`ifndef GL_SIM
        ph_vals++;
        if (sc_trace != 0) $fwrite(sc_trace, "K %0d %0d %0d", case_idx, b, dut.phase);
        if (dut.phase !== 3'(ph_m[b])) begin
            ph_bad++;
            if (ph_bad <= MAX_PRINT)
                $display("[PHASE] %s block %0d: phase register %0d, expected %0d", case_name, b, dut.phase, ph_m[b]);
        end
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++) begin
                ka_vals++;
                if (sc_trace != 0) $fwrite(sc_trace, " %0d", dut.u_peripheral.ka_flat[(h*K + k)*WIDTH +: WIDTH]);
                if (dut.u_peripheral.ka_flat[(h*K + k)*WIDTH +: WIDTH] !== ka_m[b*64 + h*8 + k]) begin
                    ka_bad++;
                    if (ka_bad <= MAX_PRINT)
                        $display("[KA] %s block %0d row %0d lane %0d: %0d, expected %0d", case_name, b, h, k,
                                 dut.u_peripheral.ka_flat[(h*K + k)*WIDTH +: WIDTH], ka_m[b*64 + h*8 + k]);
                end
            end
        if (sc_trace != 0) $fwrite(sc_trace, "\n");
`endif
    endtask

    task automatic run_case(input string dir);
        int unsigned next_free, B, D0;
        int C, di, gap, ns, slots, nst;
        load_case(dir);
        case_name = dir;
        next_free = edge_n + 1;
        di = 0;
        for (int b = 0; b < n_blk; b++) begin
            C = int'(cy_m[b]);
            if (C < 1 || C > 8) $fatal(1, "[BENCH] %s block %0d: cycles %0d", dir, b, C);
            if (opt_full || neg_len_128) C = 8;
            if (neg_short && C > 1) C = C - 1;
            if (neg_short_last > 0 && b == n_blk - 1)   // [AF-IPD] NEG_SHORT_LAST
                C = (C > neg_short_last) ? C - neg_short_last : 1;
            gap = opt_gaps ? $urandom_range(0, 3) : 0;
            B = ((edge_n + 1 > next_free) ? edge_n + 1 : next_free) + gap;
            while (edge_n + 1 < B) begin
                idle_controls();
                @(negedge clk);
            end
            drive_block(b);
            // Stalls: ns of the C-1+ns edges B+1 .. B+C+ns-1 hold the counter;
            // each kills the MAC two edges later (the cycle's second copy).
            ns = (opt_stall || neg_stall_nomac) ? $urandom_range(0, 2) : 0;
            slots = C - 1 + ns;
            nst = ns;
            for (int i = 1; i <= slots; i++)
                if (nst > 0 && $urandom_range(1, slots - i + 1) <= nst) begin
                    stall_edge[B + i] = 1'b1;
                    if (!neg_stall_nomac) mac_kill[B + i + 2] = 1'b1;
                    nst--;
                    total_stalls++;
                end
            C = C + ns;                          // block span in edges from here on
            for (int unsigned e = B + 2; e <= B + C + 1; e++) mac_edge[e] = 1'b1;
            cur_end = B + C;
            peek_q.push_back('{B + C + 1, b});
            if (dr_m[b][0]) begin
                D0 = B + C + 2 + (opt_loose ? $urandom_range(0, 3) : 0);
                if (neg_drain_early) D0 = D0 - 1;
                drain_q.push_back('{D0, di});
                di++;
                next_free = D0 + N_W - 2 + (opt_loose ? $urandom_range(0, 3) : 0);
                if (neg_next_early) next_free = next_free - 1;
            end else begin
                next_free = B + C;
            end
            total_blocks++;
            if (cs_m[b][0]) total_calls++;
            @(negedge clk);                      // edge B has happened
            check_load(b);
            idle_controls();
        end
        if (di != n_drn) $fatal(1, "[BENCH] %s: %0d drains scheduled, %0d expected", dir, di, n_drn);
        // [AF-IPD] deterministic tail: end on the negedge after the last drain's
        // last shift edge (and after the last block peek).
        while (drain_q.size() > 0 || (drain_busy && drain_last_edge > edge_n) || peek_q.size() > 0) begin
            idle_controls();
            @(negedge clk);
        end
    endtask

    //======================================================== INT part ==
    // The IPD single-PE bench's schedule, as a segment that starts on the
    // current negedge (edge 0 = the next posedge).
    int E0 = 4;                                  // first data capture edge (relative)
    int BA = 8, BW = 8, L = 128, MROWS = 1, NCOLS = 8, MODE_AT = -1;
    bit junk = 1'b0, neg_no_ring = 1'b0, neg_prec = 1'b0;
    bit lap_ring_only = 1'b0, neg_ring_stray = 1'b0, neg_mag = 1'b0;
    int LAP_LEN = 1;
    bit neg_no_bubble = 1'b0, neg_ring_stray_mid = 1'b0;
    bit park_cyc0 = 1'b0, neg_mag_a = 1'b0, neg_mag_w = 1'b0, junk_scstrobe = 1'b0;   // [AF-IPD]
    int int_len_dc = -1;                         // [AF-IPD] review fix: +INT_LEN_DC
    logic [N_H*K-1:0] a_sign_word;
    int NB, ROWS_PE, NIG, NJG, NBLK, PASS_LEN, LAST_LEN, BLK_LEN;
    int E_DATA_END, E_END;

    logic [7:0] a_mem [];             // a_mem[i*L + x] = A[i, x]
    logic [7:0] w_mem [];             // w_mem[j*L + x] = W[x, j]

    // Per INT segment bookkeeping.
    int n_seg = 0;
    integer seg_trace [MAX_SEG];
    integer seg_sched [MAX_SEG];
    int seg_ndrain [MAX_SEG];
    int seg_ncomb [MAX_SEG];
    int seg_nblk [MAX_SEG];
    string seg_dir [MAX_SEG];
    int seg_base [MAX_SEG];

    // Drain / combiner monitor: scheduled drain edges (absolute) -> what they drain.
    typedef struct { int seg; int blk; int t; } cap_t;
    cap_t drain_expect [int unsigned];
    cap_t comb_expect [int unsigned];
    bit int_mon_on = 1'b0;
    int comb_unexpected = 0;

`ifndef CAI_DUT_AF
    always @(posedge clk) begin
        int unsigned a;
        cap_t c;
        a = edge_n + 1;
        if (drain_expect.exists(a)) begin
            c = drain_expect[a];
            drain_expect.delete(a);
            if (c.t == 0) $fwrite(seg_sched[c.seg], "DRAIN_START %0d %0d\n", c.blk, int'(a) - seg_base[c.seg]);
            if ($isunknown(acc_out_east))
                $fatal(1, "[X-FAIL] drained column X: segment %0d block %0d step %0d", c.seg, c.blk, c.t);
            $fwrite(seg_trace[c.seg], "D %0d %0d", c.blk, c.t);
            for (int h = 0; h < N_H; h++)
                $fwrite(seg_trace[c.seg], " %0d", $signed(acc_out_east[h*OWIDTH +: OWIDTH]));
            $fwrite(seg_trace[c.seg], "\n");
            seg_ndrain[c.seg]++;
            comb_expect[a] = c;
        end
        if (int_mon_on) begin
            if ($isunknown(int_out_valid))
                $fatal(1, "[X-FAIL] int_out_valid X at edge %0d", a);
            if (int_out_valid !== comb_expect.exists(a - 2))
                $fatal(1, "[TIMING-FAIL] int_out_valid=%0b at edge %0d, expected %0b",
                       int_out_valid, a, comb_expect.exists(a - 2));
            if (int_out_valid) begin
                c = comb_expect[a - 2];
                comb_expect.delete(a - 2);
                if ($isunknown(int_out))
                    $fatal(1, "[X-FAIL] int_out X: segment %0d block %0d step %0d", c.seg, c.blk, c.t);
                $fwrite(seg_trace[c.seg], "C %0d %0d %0d %0d\n", c.blk, c.t,
                        $signed(int_out[31:0]), $signed(int_out[63:32]));
                seg_ncomb[c.seg]++;
            end
        end
    end
`endif

`ifndef GL_SIM
`ifndef CAI_DUT_AF
    // Lap coverage (RTL only), as the IPD bench: lap edges (ring_q high) whose
    // tiles fold a pending carry / borrow into the doubled value.
    int cov_lap_edges = 0, cov_tile_laps = 0, cov_pending_carry = 0, cov_pending_borrow = 0;
    for (genvar h = 0; h < N_H; h++) begin : g_cov_r
        for (genvar v = 0; v < N_W; v++) begin : g_cov_c
            always @(posedge clk)
                if (!reset && dut.u_pe.ring_q === 1'b1) begin
                    cov_tile_laps++;
                    if (dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_carry === 1'b1)
                        cov_pending_carry++;
                    if (dut.u_pe.u_array_core.g_row[h].g_col[v].u_inner.pending_borrow === 1'b1)
                        cov_pending_borrow++;
                end
        end
    end
    always @(posedge clk)
        if (!reset && dut.u_pe.ring_q === 1'b1) cov_lap_edges++;
    // INT samples consumed with the AF streams silent (the [BP-CONTRACT] check
    // in the top stops the run otherwise): counted for the report.
    int int_mac_samples = 0;
    always @(posedge clk)
        if (!reset && dut.int_mode_q2 === 1'b1 && dut.mac_core === 1'b1) int_mac_samples++;
`endif
`endif

    function automatic void decode(input int e, output int blk, output int pi, output int u);
        int r;
        r = e - E0;
        blk = r / BLK_LEN;
        r = r % BLK_LEN;
        pi = r / PASS_LEN;
        if (pi > BW - 1) pi = BW - 1;           // the final pass is LAST_LEN long
        u = r - pi*PASS_LEN;
    endfunction

    // The tile array shifts at P_e (ring lap or drain).  u = 0 closes the
    // previous pass's lap (pi >= 1; none for LAP_LEN = 0) or the previous
    // block's drain (pi = 0); a non-final pass laps on its last LAP_LEN-1
    // edges, the final pass drains on u >= NB+1.
    function automatic bit core_shift_at(input int e);
        int blk, pi, u;
        if (e <= E0 || e > E_END) return 1'b0;
        decode(e, blk, pi, u);
        if (u == 0) return (pi == 0) || (LAP_LEN >= 1);
        if (pi < BW - 1) return (LAP_LEN >= 1) && (u >= PASS_LEN - LAP_LEN + 1);
        return u >= NB + 1;
    endfunction

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
        // [AF-IPD] junk loads only on INT edges: before int_mode rises (MODE_AT
        // >= 0) the edge is an SC edge, where a load without block_start is an
        // AF contract error.
        if (junk && int_mode) begin
            if (!load_a && ($urandom & 1)) begin
                load_a = 1'b1;
                a_signs_in = {$urandom, $urandom};
            end
            if (!load_w && ($urandom & 1)) begin
                load_w = 1'b1;
                w_signs_in = {$urandom, $urandom};
            end
        end
        if (neg_mag) begin
            load_a = 1'b1;
            load_w = 1'b1;
        end
    endtask

    // [AF-IPD] Magnitude lines: zero on every edge (the zero-load on INT
    // entry and every INT load); under JUNK random on the edges that do not
    // load that side; NEG_MAG random everywhere; NEG_MAG_A / NEG_MAG_W random
    // 1..128 on that side's loads; NEG_SW_NO_ZERO_LOAD leaves them as the SC
    // segment left them.
    task automatic set_binary();
        if (neg_sw_no_zero_load) return;
        if (neg_mag || (junk && !load_a))
            for (int n = 0; n < N_H*K*WIDTH; n++) a_binary_in[n] = $urandom & 1;
        else if (neg_mag_a && load_a)
            for (int i = 0; i < N_H*K; i++) a_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(1, 128));
        else
            a_binary_in = '0;
        if (neg_mag || (junk && !load_w))
            for (int n = 0; n < N_W*K*WIDTH; n++) w_binary_in[n] = $urandom & 1;
        else if (neg_mag_w && load_w)
            for (int i = 0; i < N_W*K; i++) w_binary_in[i*WIDTH +: WIDTH] = WIDTH'($urandom_range(1, 128));
        else
            w_binary_in = '0;
    endtask

    // [AF-IPD] AF-only inputs in INT mode.
    task automatic set_af_side(input int e);
        block_start = park_cyc0 && (e == 1);
        slice_start = 1'b0;
        if (junk_scstrobe && int_mode) begin
            block_start = $urandom & 1;
            slice_start = $urandom & 1;
        end
        if (park_cyc0)
            rng_en = 1'b0;
        else if (junk)
            rng_en = $urandom & 1;
        else
            rng_en = neg_mag;
        if (junk)
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'($urandom);
        else if (int_len_dc >= 0)
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = WIDTH'(int_len_dc);
        else
            a_len_in = '0;
        if (neg_mag_a && load_a)
            for (int h = 0; h < N_H; h++) a_len_in[h*WIDTH +: WIDTH] = 8'd128;
    endtask

    task automatic set_west_junk(input int e);
        if (drain_at(e))
            acc_in_west = '0;
        else
            for (int n = 0; n < N_H*OWIDTH; n++) acc_in_west[n] = $urandom & 1;
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

    // Derived schedule constants and range checks for the current INT config.
    task automatic int_config();
        if (LAP_LEN < 0 || LAP_LEN > 64) $fatal(1, "LAP_LEN=%0d out of range", LAP_LEN);
        if (neg_no_bubble && LAP_LEN < 1) $fatal(1, "NEG_NO_BUBBLE needs LAP_LEN >= 1");
        if (!(BA == 8 || BA == 4)) $fatal(1, "BA must be 4 or 8 (got %0d)", BA);
        if (!(BW == 8 || BW == 4)) $fatal(1, "BW must be 4 or 8 (got %0d)", BW);
        if (L < K*M || L % (K*M) != 0) $fatal(1, "L=%0d must be a positive multiple of %0d", L, K*M);
        if (park_cyc0 && !(MODE_AT >= 2 && MODE_AT <= E0 - 1))
            $fatal(1, "PARK_CYC0 needs MODE_AT 2..%0d (an SC block_start on edge 1)", E0 - 1);
        if (neg_mag_a && !park_cyc0) $fatal(1, "NEG_MAG_A needs PARK_CYC0 (after reset the AF counter parks in IDLE, where A is 0)");
        NB = L / (K*M);
        ROWS_PE = N_H / BA;
        if (MROWS < ROWS_PE || MROWS % ROWS_PE != 0 || NCOLS < N_W || NCOLS % N_W != 0)
            $fatal(1, "MROWS must be a multiple of %0d and NCOLS of %0d", ROWS_PE, N_W);
        if ((longint'(1) << (BW-1)) * L >= (longint'(1) << (OWIDTH-1)))
            $fatal(1, "L=%0d can overflow the %0d-bit accumulator", L, OWIDTH);
        NIG = MROWS / ROWS_PE;
        NJG = NCOLS / N_W;
        NBLK = NIG * NJG;
        PASS_LEN = NB + LAP_LEN - (neg_no_bubble ? 1 : 0);
        LAST_LEN = NB + N_W;
        BLK_LEN = (BW - 1) * PASS_LEN + LAST_LEN;
        if (neg_ring_stray_mid && BW < 2) $fatal(1, "NEG_RING_STRAY_MID needs BW >= 2");
        E_DATA_END = E0 + NBLK*BLK_LEN;
        E_END = E_DATA_END;                      // final drain edge
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_sign_word[h*K + k] = (h % BA == BA - 1);
    endtask

    // One INT segment, starting on the current negedge (edge 0 = next posedge),
    // ending on the negedge after edge E_END + tail.  int_mode is raised at
    // MODE_AT (or already high) and left high.
    task automatic run_int_segment(input string dir, input int tail);
        int seg;
        string pfx;
        if (n_seg >= MAX_SEG) $fatal(1, "more than %0d INT segments", MAX_SEG);
        seg = n_seg++;
        pfx = (dir == "") ? "" : {dir, "/"};
        seg_dir[seg] = dir;
        seg_nblk[seg] = NBLK;
        seg_ndrain[seg] = 0;
        seg_ncomb[seg] = 0;
        read_hex({pfx, "bpt_a.hex"}, MROWS*L, a_mem);
        read_hex({pfx, "bpt_w.hex"}, NCOLS*L, w_mem);
        seg_trace[seg] = $fopen({pfx, "bpt_trace.txt"}, "w");
        if (seg_trace[seg] == 0) $fatal(1, "cannot open %sbpt_trace.txt", pfx);
        seg_sched[seg] = $fopen({pfx, "bpt_sched.txt"}, "w");
        if (seg_sched[seg] == 0) $fatal(1, "cannot open %sbpt_sched.txt", pfx);
        $fwrite(seg_sched[seg], "SCHED lap_len=%0d pass_len=%0d last_len=%0d blk_len=%0d nb=%0d bw=%0d nblk=%0d formula=%0d\n",
                LAP_LEN, PASS_LEN, LAST_LEN, BLK_LEN, NB, BW, NBLK, BW*NB + LAP_LEN*(BW-1) + N_W);
        $fwrite(seg_trace[seg], "BPTCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, int_prec, junk, neg_no_ring, neg_prec,
                lap_ring_only, neg_mag, MODE_AT, neg_ring_stray);
        seg_base[seg] = int'(edge_n) + 1;
        for (int e = 0; e <= E_END + tail; e++) begin
            if (e == MODE_AT) int_mode = 1'b1;
            if (neg_sw_int_drop_early && e == E_END) int_mode = 1'b0;
            set_raw(e);
            set_signs(e);
            set_binary();
            set_af_side(e);
            if (junk) set_west_junk(e);
            ring_in = (!neg_no_ring && ring_at(e + 1)) || (neg_ring_stray && e + 1 == E0 + 1) ||
                      (neg_ring_stray_mid && e + 1 == E0 + PASS_LEN + NB/2 + 1);
            shift_in = lap_ring_only ? drain_at(e) : core_shift_at(e);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            if (drain_at(e)) begin
                cap_t c;
                c.seg = seg;
                drain_slot(e, c.blk, c.t);
                drain_expect[edge_n + 1] = c;
            end
            @(posedge clk);                      // P_e
            @(negedge clk);
        end
        // Leave the INT-side strobes idle for whatever comes next (the next
        // edge may be an SC block_start).
        shift_in = 1'b0;
        ring_in = 1'b0;
        a_raw_in = '0;
        w_raw_in = '0;
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        block_start = 1'b0;
        slice_start = 1'b0;
        acc_in_west = '0;
    endtask

    //=========================================================== main ==
    int seed, reset_settle;

    function automatic void split_list(input string arg, ref string out [$]);
        int start;
        start = 0;
        for (int i = 0; i <= arg.len(); i++)
            if (i == arg.len() || arg[i] == ",") begin
                if (i > start) out.push_back(arg.substr(start, i - 1));
                start = i + 1;
            end
    endfunction

    function automatic int dut_contract();
`ifndef GL_SIM
        return dut.contract_errors;
`else
        return 0;
`endif
    endfunction

    task automatic finish_sc_result(input int n_cases);
        int contract;
        string extra;
        contract = dut_contract();
        extra = "";
`ifdef CAI_LOCKSTEP
`ifndef GL_SIM
        extra = $sformatf(" | lockstep edges %0d bad %0d", ls_edges, ls_bad);
        if (ref_af.contract_errors != contract) begin
            ls_bad++;
            $display("[LOCKSTEP] contract counts differ: AF-IPD %0d, AF %0d", contract, ref_af.contract_errors);
        end
`endif
`endif
        $display("RESULT cases=%0d calls=%0d blocks=%0d drains=%0d edges=%0d | drain values %0d bad %0d | block values %0d bad %0d | kA values %0d bad %0d | phase checks %0d bad %0d | contract %0d | stalls %0d stray loads %0d%s",
                 n_cases, total_calls, total_blocks, total_drains, edge_n, drain_vals, drain_bad,
                 blk_vals, blk_bad, ka_vals, ka_bad, ph_vals, ph_bad, contract, total_stalls, total_stray, extra);
        if (opt_int_junk) $display("INT_JUNK edges %0d", junk_edges);
        if (drain_bad) $display("[CHECK] %0d of %0d drained accumulators wrong", drain_bad, drain_vals);
        if (blk_bad) $display("[BLOCK] %0d of %0d per-block accumulators wrong", blk_bad, blk_vals);
        if (ka_bad) $display("[KA] %0d of %0d encoder outputs wrong", ka_bad, ka_vals);
        if (ph_bad) $display("[PHASE] %0d of %0d phases wrong", ph_bad, ph_vals);
        if (contract) $display("[CONTRACT] %0d [CBSG-AF-CONTRACT] errors", contract);
`ifdef CAI_LOCKSTEP
`ifndef GL_SIM
        if (ls_bad) $display("[LOCKSTEP] %0d of %0d edges differ from the AF top", ls_bad, ls_edges);
`endif
`endif
    endtask

    initial begin
        string arg, dirs [$], items [$];
        int contract;
        bit ok;
        void'($value$plusargs("MODE=%s", bench_mode));
        opt_full = $test$plusargs("FULL_CYCLES");
        opt_gaps = $test$plusargs("GAPS");
        opt_rng_gap_low = $test$plusargs("RNG_GAP_LOW");
        opt_mac_exact = $test$plusargs("MAC_EXACT");
        opt_loose = $test$plusargs("LOOSE_DRAIN");
        opt_stall = $test$plusargs("STALL");
        opt_rng_low_end = $test$plusargs("RNG_LOW_END");
        opt_junk_bus = $test$plusargs("JUNK_BUS");
        opt_mid_reset = $test$plusargs("MID_RESET");
        opt_no_call_ss = $test$plusargs("NO_CALL_SS");
        opt_no_slice_ss = $test$plusargs("NO_SLICE_SS");
        opt_no_slice_start = $test$plusargs("NO_SLICE_START");
        opt_kill_drain_reset = $test$plusargs("KILL_DRAIN_RESET");
        neg_stall_nomac = $test$plusargs("NEG_STALL_NOMAC");
        neg_stray_load = $test$plusargs("NEG_STRAY_LOAD");
        opt_junk_ss = $test$plusargs("JUNK_SS");
        neg_lane_rev = $test$plusargs("NEG_LANE_REV");
        neg_ka_eq_b = $test$plusargs("NEG_KA_EQ_B");
        neg_row_len_max = $test$plusargs("NEG_ROW_LEN_MAX");
        neg_len_128 = $test$plusargs("NEG_LEN_128");
        neg_short = $test$plusargs("NEG_SHORT_BLOCK");
        neg_drain_early = $test$plusargs("NEG_DRAIN_EARLY");
        neg_next_early = $test$plusargs("NEG_NEXT_EARLY");
        opt_int_junk = $test$plusargs("INT_JUNK");
        neg_sw_early_int = $test$plusargs("NEG_SW_EARLY_INT");
        neg_sw_late_drop = $test$plusargs("NEG_SW_LATE_DROP");
        neg_sw_no_zero_load = $test$plusargs("NEG_SW_NO_ZERO_LOAD");
        neg_sw_int_drop_early = $test$plusargs("NEG_SW_INT_DROP_EARLY");
        neg_sw_no_reload = $test$plusargs("NEG_SW_NO_RELOAD");
        void'($value$plusargs("SW_GAP=%d", sw_gap));
        opt_rng_low_idle = $test$plusargs("RNG_LOW_IDLE");
        void'($value$plusargs("NEG_SHORT_LAST=%d", neg_short_last));
        void'($value$plusargs("DRAIN_SAMPLE_LATE_PS=%d", drain_sample_late_ps));   // [AF-IPD] route step
        if (drain_sample_late_ps < 0 || drain_sample_late_ps >= int'(PERIOD * 500.0))
            $fatal(1, "[BENCH] DRAIN_SAMPLE_LATE_PS=%0d out of 0..%0d", drain_sample_late_ps, int'(PERIOD * 500.0) - 1);
        void'($value$plusargs("INT_LEN_DC=%d", int_len_dc));
        if (int_len_dc > 255) $fatal(1, "[BENCH] INT_LEN_DC=%0d out of 0..255", int_len_dc);
        // INT options (+MODE=int; switch segments take theirs from bpt_cfg.txt)
        void'($value$plusargs("BA=%d", BA));
        void'($value$plusargs("BW=%d", BW));
        void'($value$plusargs("L=%d", L));
        void'($value$plusargs("MROWS=%d", MROWS));
        void'($value$plusargs("NCOLS=%d", NCOLS));
        void'($value$plusargs("MODE_AT=%d", MODE_AT));
        junk = $test$plusargs("JUNK");
        neg_no_ring = $test$plusargs("NEG_NO_RING");
        neg_prec = $test$plusargs("NEG_PREC");
        lap_ring_only = $test$plusargs("LAP_RING_ONLY");
        neg_ring_stray = $test$plusargs("NEG_RING_STRAY");
        neg_mag = $test$plusargs("NEG_MAG");
        void'($value$plusargs("LAP_LEN=%d", LAP_LEN));
        neg_no_bubble = $test$plusargs("NEG_NO_BUBBLE");
        neg_ring_stray_mid = $test$plusargs("NEG_RING_STRAY_MID");
        park_cyc0 = $test$plusargs("PARK_CYC0");
        neg_mag_a = $test$plusargs("NEG_MAG_A");
        neg_mag_w = $test$plusargs("NEG_MAG_W");
        junk_scstrobe = $test$plusargs("JUNK_SCSTROBE");
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("RESET_SETTLE=%d", reset_settle)) reset_settle = `CAI_RESET_SETTLE;
        if ($value$plusargs("SC_TRACE=%s", arg)) begin
            sc_trace = $fopen(arg, "w");
            if (sc_trace == 0) $fatal(1, "cannot open %s", arg);
        end

        if (bench_mode == "sc") begin
            //----------------------------------------------------- SC --
            void'($urandom(seed));
            if (!$value$plusargs("CASES=%s", arg) && !$value$plusargs("CASE=%s", arg)) begin
                // `make sim` runs simv without plusargs: take the list from
                // cbsg_cases.txt in the run directory (one comma-separated line).
                int fd;
                fd = $fopen("cbsg_cases.txt", "r");
                if (fd == 0 || $fgets(arg, fd) == 0)
                    $fatal(1, "[BENCH] give +CASES=dir1,dir2,... (or +CASE=dir, or a cbsg_cases.txt)");
                $fclose(fd);
                while (arg.len() > 0 && (arg[arg.len()-1] == "\n" || arg[arg.len()-1] == " "))
                    arg = arg.substr(0, arg.len() - 2);
            end
            split_list(arg, dirs);

            clk_utils.set_clock(PERIOD);
            clk_utils.do_reset();
            @(negedge clk);
            repeat (reset_settle) @(negedge clk);
            rng_en = 1'b1;
            run_active = 1'b1;
            sc_int_junk_on = opt_int_junk;
            int_mon_on = 1'b1;
`ifdef CAI_LOCKSTEP
`ifndef GL_SIM
            ls_on = 1'b1;
`endif
`endif

            foreach (dirs[i]) begin
                int db, dd, bb, kb, pb;
                db = drain_bad; dd = drain_vals; bb = blk_bad; kb = ka_bad; pb = ph_bad;
                case_idx = i;
                if (opt_mid_reset && i > 0) begin
                    run_active = 1'b0;
                    clk_utils.do_reset();
                    @(negedge clk);
                    repeat (reset_settle) @(negedge clk);
                    rng_en = 1'b1;
                    run_active = 1'b1;
                end
                run_case(dirs[i]);
                $display("CASE %s: %0d blocks, %0d drains; drain %0d/%0d bad, block %0d bad, kA %0d bad, phase %0d bad",
                         dirs[i], n_blk, n_drn, drain_bad - db, drain_vals - dd, blk_bad - bb, ka_bad - kb, ph_bad - pb);
            end
            repeat (4) @(negedge clk);
            finish_sc_result(dirs.size());
            contract = dut_contract();
            ok = drain_bad == 0 && blk_bad == 0 && ka_bad == 0 && ph_bad == 0 && contract == 0 && drain_vals > 0;
`ifdef CAI_LOCKSTEP
`ifndef GL_SIM
            ok = ok && ls_bad == 0 && ls_edges > 0;
`endif
`endif
            if (sc_trace != 0) $fclose(sc_trace);
            if (ok)
                $display("PASS: CBSG AF-IPD bench, %0d cases, %0d blocks, %0d drained accumulators bit-exact",
                         dirs.size(), total_blocks, drain_vals);
            else
                $display("FAIL: CBSG AF-IPD bench");
            $finish;
        end

`ifndef CAI_DUT_AF
        if (bench_mode == "int") begin
            //---------------------------------------------------- INT --
            int_config();
            int_mode = (MODE_AT < 0);
            int_prec = (BA == 4) ^ neg_prec;
            rng_en = park_cyc0 ? 1'b0 : (junk || neg_mag);

            clk_utils.set_clock(PERIOD);
            clk_utils.do_reset();
            repeat (2) @(negedge clk);
            int_mon_on = 1'b1;
            run_int_segment("", 2);
            mac_en = 1'b0;
            shift_in = 1'b0;
            ring_in = 1'b0;
            @(negedge clk);                      // monitor reads the last combiner word at E_END+2
            if (seg_ndrain[0] != NBLK*N_W || seg_ncomb[0] != NBLK*N_W)
                $fatal(1, "drained %0d columns and %0d combiner outputs, expected %0d each",
                       seg_ndrain[0], seg_ncomb[0], NBLK*N_W);
            $fclose(seg_trace[0]);
            $fclose(seg_sched[0]);
            contract = dut_contract();
`ifndef GL_SIM
            $display("LAP_COVERAGE lap_edges=%0d tile_laps=%0d with_pending_carry=%0d with_pending_borrow=%0d",
                     cov_lap_edges, cov_tile_laps, cov_pending_carry, cov_pending_borrow);
            $display("INT_SILENT_MAC_SAMPLES %0d", int_mac_samples);
`endif
            $display("PASS: BP INT bench BA=%0d BW=%0d L=%0d MROWS=%0d NCOLS=%0d blocks=%0d edges=%0d junk=%0d mode_at=%0d lap_ring_only=%0d lap_len=%0d block_len=%0d af_contract=%0d park_cyc0=%0d",
                     BA, BW, L, MROWS, NCOLS, NBLK, E_END + 3, junk, MODE_AT, lap_ring_only, LAP_LEN, BLK_LEN,
                     contract, park_cyc0);
            $finish;
        end

        if (bench_mode == "switch") begin
            //------------------------------------------------- switch --
            string prev;
            int n_sc, int_fd, code, cj, cl;
            void'($urandom(seed));
            if (!$value$plusargs("SWITCH=%s", arg)) $fatal(1, "[BENCH] +MODE=switch needs +SWITCH=sc:dir,int:dir,...");
            split_list(arg, items);
            clk_utils.set_clock(PERIOD);
            clk_utils.do_reset();
            @(negedge clk);
            rng_en = 1'b1;
            int_mon_on = 1'b1;
            prev = "";
            n_sc = 0;
            foreach (items[it]) begin
                string kind, dir;
                if (items[it].len() < 4 || items[it][2] != ":" && items[it][3] != ":")
                    $fatal(1, "[BENCH] bad +SWITCH item %s", items[it]);
                kind = items[it].substr(0, 1) == "sc" ? "sc" : "int";
                dir = (kind == "sc") ? items[it].substr(3, items[it].len() - 1)
                                     : items[it].substr(4, items[it].len() - 1);
                repeat (prev == "" ? 0 : sw_gap) begin
                    if (prev == "sc") idle_controls();
                    @(negedge clk);
                end
                if (kind == "sc") begin
                    if (prev == "int") begin
                        if (neg_sw_late_drop)
                            fork begin @(negedge clk); int_mode = 1'b0; end join_none
                        else
                            int_mode = 1'b0;
                        first_block_after_int = 1'b1;
                        rng_en = 1'b1;
                        mac_en = 1'b1;
                    end
                    run_active = 1'b1;
                    sc_int_junk_on = opt_int_junk;
                    early_int_arm = neg_sw_early_int && it + 1 < items.size() &&
                                    items[it + 1].substr(0, 2) == "int";
                    case_idx = n_sc++;
                    run_case(dir);
                    early_int_arm = 1'b0;
                    $display("SWITCH SC %s: %0d blocks, %0d drains, drain bad so far %0d, contract %0d",
                             dir, n_blk, n_drn, drain_bad, dut_contract());
                end else begin
                    run_active = 1'b0;
                    sc_int_junk_on = 1'b0;
                    int_fd = $fopen({dir, "/bpt_cfg.txt"}, "r");
                    if (int_fd == 0) $fatal(1, "cannot open %s/bpt_cfg.txt", dir);
                    code = $fscanf(int_fd, "%d %d %d %d %d %d %d %d", BA, BW, L, MROWS, NCOLS, MODE_AT, cj, cl);
                    $fclose(int_fd);
                    if (code != 8) $fatal(1, "%s/bpt_cfg.txt: need BA BW L MROWS NCOLS MODE_AT JUNK LAP_RING_ONLY", dir);
                    if (MODE_AT < 0 || MODE_AT > 3) $fatal(1, "%s: switch segments need MODE_AT 0..3", dir);
                    junk = cj;
                    lap_ring_only = cl;
                    E0 = MODE_AT + 1;
                    int_config();
                    int_prec = (BA == 4);
                    run_int_segment(dir, 0);
                    $display("SWITCH INT %s: BA=%0d BW=%0d L=%0d blocks=%0d block_len=%0d E0=%0d",
                             dir, BA, BW, L, NBLK, BLK_LEN, E0);
                end
                prev = kind;
            end
            if (prev == "int") begin
                mac_en = 1'b0;
                shift_in = 1'b0;
                ring_in = 1'b0;
                repeat (3) @(negedge clk);
                int_mode = 1'b0;
            end
            repeat (4) @(negedge clk);
            finish_sc_result(n_sc);
            contract = dut_contract();
            ok = drain_bad == 0 && blk_bad == 0 && ka_bad == 0 && ph_bad == 0 && contract == 0 && drain_vals > 0;
            for (int s = 0; s < n_seg; s++) begin
                $display("SEGMENT %0d %s: drained %0d combined %0d expected %0d",
                         s, seg_dir[s], seg_ndrain[s], seg_ncomb[s], seg_nblk[s]*N_W);
                if (seg_ndrain[s] != seg_nblk[s]*N_W || seg_ncomb[s] != seg_nblk[s]*N_W) begin
                    ok = 1'b0;
                    $display("[INTCOUNT] segment %0d (%s): drained %0d, combined %0d, expected %0d each",
                             s, seg_dir[s], seg_ndrain[s], seg_ncomb[s], seg_nblk[s]*N_W);
                end
                $fclose(seg_trace[s]);
                $fclose(seg_sched[s]);
            end
`ifndef GL_SIM
            $display("LAP_COVERAGE lap_edges=%0d tile_laps=%0d with_pending_carry=%0d with_pending_borrow=%0d",
                     cov_lap_edges, cov_tile_laps, cov_pending_carry, cov_pending_borrow);
`endif
            $display("SWITCH_RESULT sc_cases=%0d int_segments=%0d edges=%0d", n_sc, n_seg, edge_n);
            if (ok)
                $display("PASS: CBSG AF-IPD switch bench, %0d SC cases, %0d INT segments", n_sc, n_seg);
            else
                $display("FAIL: CBSG AF-IPD switch bench");
            $finish;
        end
`endif
        $fatal(1, "[BENCH] unknown +MODE=%s (sc | int | switch)", bench_mode);
    end
endmodule
