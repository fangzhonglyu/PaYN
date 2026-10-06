`timescale 1ns/1ps
// PE-level random bench for the sub-ring BP PE
// (designs/payn/variants/signed_segmented_csa_bp_sr/inner_pe_signed_segmented_csa_bp_sr.sv),
// generalized from the IPD review bench (sweeps/int_mode/bp/ipd/review/tb_ipd_pe_review.sv)
// to any sub-ring length LAP_G (+define+PAYN_LAP_G=<g>, default 2).
//
// One random stimulus stream drives
//   dut     InnerPESignedSegmentedCsaBpSrFlat #(LAP_G) (RTL)
//   ref_csa InnerPESignedSegmentedCsaFlat              (RTL, accepted CSA PE; no ring port)
//   dut_gl  a synthesized SR PE (only with +define+REVIEW_GL and +define+REVIEW_GL_MODULE=<name>),
//           compared in lock step with dut.
//
// Phase A (ring_in = 0, SC transparency): every cycle, every output and every
//   tile's canonical acc_out of dut must equal ref_csa's.  Random reset,
//   shift_in, mac_en, sign loads, acc_in_west biased to range extremes.
// Phase B (ring_in random): every tile's canonical acc_out must equal a
//   behavioural model kept in this bench, exact mod 2^24, edge by edge:
//     reset            -> 0
//     ring_q           -> head tile (v % LAP_G == 0): 2 * tail value (tile v+LAP_G-1)
//                         other tiles: west neighbour's value (tile v-1)
//                         (MAC on that edge dropped; shift_in ignored)
//     shift_in         -> west value    (acc_in_west for column 0)
//     mac_en           -> v + sum_k (+-) popcount(a & w)  (from the PE's pipes)
//   ring_q must be reset ? 0 : ring_in.  ring_in runs are exactly LAP_G edges
//   (a contract lap), or 1 .. 2*LAP_G edges (any run length: the model is per
//   edge), forced right after max-magnitude MACs (pending carry / borrow at the
//   lap edge), back to back, with shift_in and with mac_en high, reset on a lap
//   edge, and tile values at the 24-bit range limits (doubling across the sign
//   bit).  A full LAP_G-edge lap must leave every tile = 2 * its pre-lap value;
//   the bench counts those laps and checks them against the pre-lap snapshot.
// Coverage counters are printed at the end; the run fails if any is zero.
//
// Mutant control: +define+REVIEW_DUT_G=<g'> builds the DUT with LAP_G = g' != the model's; must FAIL.
// Plusargs: +NA=<phase A cycles> +NB=<phase B cycles> +ntb_random_seed=<n> +SEED=<n>
`ifndef PAYN_LAP_G
`define PAYN_LAP_G 2
`endif
`ifdef REVIEW_GL
`ifndef REVIEW_GL_MODULE
`define REVIEW_GL_MODULE InnerPESignedSegmentedCsaBpSrFlat_K8_M16_N_H8_N_W8_OWIDTH24_LOW_W9_LAP_G2
`endif
`endif
`include "payn/variants/signed_segmented_csa_bp_sr/inner_pe_signed_segmented_csa_bp_sr.sv"
`include "payn/variants/signed_segmented_csa/inner_pe_signed_segmented_csa.sv"

module TbSrPeReview;
    localparam int K = 8, M = 16, NH = 8, NW = 8, OW = 24, LW = 9, G = `PAYN_LAP_G;
`ifdef REVIEW_DUT_G
    localparam int DUT_G = `REVIEW_DUT_G;   // mutant control: DUT sub-ring length != model's
`else
    localparam int DUT_G = G;
`endif
    localparam logic [OW-1:0] MASK = '1;

    logic clk = 1'b0;
    always #1.25 clk = ~clk;

    logic reset = 1'b1, mac_en = 1'b0, shift_in = 1'b0, ring_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0;
    logic [NH*K*M-1:0] a_bits = '0;
    logic [NH*K-1:0]   a_signs = '0;
    logic [NW*K*M-1:0] w_bits = '0;
    logic [NW*K-1:0]   w_signs = '0;
    logic [NH*OW-1:0]  acc_west = '0;

    // outputs
    logic [NH*K*M-1:0] d_abo, r_abo, g_abo;
    logic [NH*K-1:0]   d_aso, r_aso, g_aso;
    logic [NW*K*M-1:0] d_wbo, r_wbo, g_wbo;
    logic [NW*K-1:0]   d_wso, r_wso, g_wso;
    logic d_lao, r_lao, g_lao, d_lwo, r_lwo, g_lwo, d_ring, g_ring;
    logic [NH*OW-1:0]  d_east, r_east, g_east;

    InnerPESignedSegmentedCsaBpSrFlat #(.K(K), .M(M), .N_H(NH), .N_W(NW), .OWIDTH(OW), .LOW_W(LW), .LAP_G(DUT_G)) dut (
        .clk, .reset, .mac_en, .shift_in, .ring_in,
        .a_bits_in(a_bits), .a_signs_in(a_signs), .w_bits_in(w_bits), .w_signs_in(w_signs),
        .load_a_sign_in(load_a), .load_w_sign_in(load_w),
        .a_bits_out(d_abo), .a_signs_out(d_aso), .w_bits_out(d_wbo), .w_signs_out(d_wso),
        .load_a_sign_out(d_lao), .load_w_sign_out(d_lwo), .ring_out(d_ring),
        .acc_in_west(acc_west), .acc_out_east(d_east));

    InnerPESignedSegmentedCsaFlat #(.K(K), .M(M), .N_H(NH), .N_W(NW), .OWIDTH(OW), .LOW_W(LW)) ref_csa (
        .clk, .reset, .mac_en, .shift_in,
        .a_bits_in(a_bits), .a_signs_in(a_signs), .w_bits_in(w_bits), .w_signs_in(w_signs),
        .load_a_sign_in(load_a), .load_w_sign_in(load_w),
        .a_bits_out(r_abo), .a_signs_out(r_aso), .w_bits_out(r_wbo), .w_signs_out(r_wso),
        .load_a_sign_out(r_lao), .load_w_sign_out(r_lwo),
        .acc_in_west(acc_west), .acc_out_east(r_east));

`ifdef REVIEW_GL
    `REVIEW_GL_MODULE dut_gl (
        .clk, .reset, .mac_en, .shift_in, .ring_in,
        .a_bits_in(a_bits), .a_signs_in(a_signs), .w_bits_in(w_bits), .w_signs_in(w_signs),
        .load_a_sign_in(load_a), .load_w_sign_in(load_w),
        .a_bits_out(g_abo), .a_signs_out(g_aso), .w_bits_out(g_wbo), .w_signs_out(g_wso),
        .load_a_sign_out(g_lao), .load_w_sign_out(g_lwo), .ring_out(g_ring),
        .acc_in_west(acc_west), .acc_out_east(g_east));
`endif

    // taps
    logic [OW-1:0] d_tile [NH][NW];
    logic [OW-1:0] r_tile [NH][NW];
    logic d_pc [NH][NW];
    logic d_pb [NH][NW];
    for (genvar h = 0; h < NH; h++) begin : g_tap
        for (genvar v = 0; v < NW; v++) begin : g_tap_v
            assign d_tile[h][v] = dut.u_array_core.g_row[h].acc_chain[v+1];
            assign r_tile[h][v] = ref_csa.u_array_core.g_row[h].acc_chain[v+1];
            assign d_pc[h][v] = dut.u_array_core.g_row[h].g_col[v].u_inner.pending_carry;
            assign d_pb[h][v] = dut.u_array_core.g_row[h].g_col[v].u_inner.pending_borrow;
        end
    end

    // model
    logic [OW-1:0] m [NH][NW];
    logic rq_m = 1'b0;
    int unsigned errors = 0, cyc = 0, NA = 40000, NB = 160000, seed = 1;
    bit phase_b = 0;
    // coverage
    longint unsigned c_lap_edges = 0, c_tile_laps = 0, c_lap_pc = 0, c_lap_pb = 0, c_lap_ovf = 0,
                     c_lap_shift = 0, c_lap_mac = 0, c_lap_double = 0, c_reset_on_lap = 0,
                     c_ring_during_reset = 0, c_lap_maxneg = 0, c_lap_minpos = 0, c_a_shifts = 0,
                     c_a_pc = 0, c_a_pb = 0, c_gl_cmp = 0;
    bit prev_lap = 0;
    // Full-lap check: a run of exactly G consecutive lap edges (no reset inside)
    // must leave every tile at 2 * its value before the run.
    logic [OW-1:0] snap [NH][NW];
    int run_len = 0;
    bit run_reset = 0;
    longint unsigned c_full_laps = 0, c_full_lap_checked_tiles = 0;

    function automatic int contrib(int h, int v);
        int s = 0;
        for (int k = 0; k < K; k++) begin
            int pc = $countones(dut.u_array_core.a_bits_pipe[h][k] & dut.u_array_core.w_bits_pipe[v][k]);
            s += (dut.u_array_core.a_signs_pipe[h][k] ^ dut.u_array_core.w_signs_pipe[v][k]) ? -pc : pc;
        end
        return s;
    endfunction

    always @(posedge clk) begin : model_update
        logic [OW-1:0] nm [NH][NW];
        bit lap;
        lap = (rq_m === 1'b1) && !reset;
        if (lap) begin
            c_lap_edges++;
            if (shift_in) c_lap_shift++;
            if (mac_en) c_lap_mac++;
            if (prev_lap) c_lap_double++;
        end
        if (reset && rq_m) c_reset_on_lap++;
        if (reset && ring_in) c_ring_during_reset++;
        for (int h = 0; h < NH; h++)
            for (int v = 0; v < NW; v++) begin
                if (reset) nm[h][v] = '0;
                else if (rq_m || shift_in) begin
                    if (rq_m) begin
                        c_tile_laps++;
                        if (d_pc[h][v] === 1'b1) c_lap_pc++;
                        if (d_pb[h][v] === 1'b1) c_lap_pb++;
                        if (v % G == 0) begin
                            // head: the sub-ring's tail value, doubled
                            nm[h][v] = {m[h][v+G-1][OW-2:0], 1'b0};
                            if (m[h][v+G-1][OW-1] != m[h][v+G-1][OW-2]) c_lap_ovf++;
                            if (m[h][v+G-1] == 24'h800000) c_lap_maxneg++;
                            if (m[h][v+G-1] == 24'h400000 || m[h][v+G-1] == 24'h7fffff) c_lap_minpos++;
                        end else
                            nm[h][v] = m[h][v-1];
                    end else begin
                        nm[h][v] = (v == 0) ? acc_west[h*OW +: OW] : m[h][v-1];
                        if (!phase_b) begin
                            c_a_shifts++;
                            if (d_pc[h][v] === 1'b1) c_a_pc++;
                            if (d_pb[h][v] === 1'b1) c_a_pb++;
                        end
                    end
                end else if (mac_en)
                    nm[h][v] = OW'(int'(m[h][v]) + contrib(h, v));
                else
                    nm[h][v] = m[h][v];
            end
        // run bookkeeping (lap = this edge is a lap edge; the value after the
        // last lap edge of a run is nm)
        if (lap) begin
            if (run_len == 0) begin snap = m; run_reset = 0; end
            run_len++;
        end
        if (reset) run_reset = 1;
        if (!lap && run_len > 0) run_len = 0;
        m = nm;
        prev_lap = lap;
        rq_m = reset ? 1'b0 : ring_in;
        // a run that ends now (next edge is not a lap edge) with exactly G edges
        if (run_len == G && !(rq_m === 1'b1) && !run_reset) begin
            c_full_laps++;
            for (int h = 0; h < NH; h++)
                for (int v = 0; v < NW; v++) begin
                    c_full_lap_checked_tiles++;
                    if (m[h][v] !== {snap[h][v][OW-2:0], 1'b0}) begin
                        errors++;
                        if (errors < 20)
                            $display("[FULL-LAP-MISMATCH] cyc %0d tile (%0d,%0d): after %0d-edge lap %h, 2*before %h",
                                     cyc, h, v, G, m[h][v], {snap[h][v][OW-2:0], 1'b0});
                    end
                end
        end
    end

    // stimulus
    function automatic logic [OW-1:0] pick_west();
        int r = $urandom_range(0, 15);
        logic [OW-1:0] x = OW'($urandom);
        case (r)
            0: return 24'h7fffff;
            1: return 24'h800000;
            2: return 24'hffffff;
            3: return 24'h400000;
            4: return 24'h3fffff;
            5: return 24'hc00000;
            6: return 24'hbfffff;
            7: return {x[OW-1:LW], LW'($urandom_range(500, 511))};   // carry soon
            8: return {x[OW-1:LW], LW'($urandom_range(0, 10))};      // borrow soon
            9: return {2'b01, {(OW-LW-2){1'b1}}, LW'($urandom_range(400, 511))}; // just below +2^22 boundary
            10: return {2'b10, {(OW-LW-2){1'b0}}, LW'($urandom_range(0, 100))};  // just above -2^23
            11: return '0;
            default: return x;
        endcase
    endfunction

    task automatic drive_operands(int mode);
        // mode 0 random, 1 all ones (|contrib| = 128 per tile), 2 zeros, 3 sparse
        for (int i = 0; i < NH*K*M; i++)
            a_bits[i] = (mode == 1) ? 1'b1 : (mode == 2) ? 1'b0 : (mode == 3) ? ($urandom_range(0, 7) == 0) : ($urandom & 1);
        for (int i = 0; i < NW*K*M; i++)
            w_bits[i] = (mode == 1) ? 1'b1 : (mode == 2) ? 1'b0 : (mode == 3) ? ($urandom_range(0, 7) == 0) : ($urandom & 1);
    endtask

    int sign_mode = 0;
    task automatic drive_signs();
        // all positive, all negative, or random products
        sign_mode = $urandom_range(0, 2);
        for (int i = 0; i < NH*K; i++) a_signs[i] = (sign_mode == 2) ? ($urandom & 1) : 1'b0;
        for (int i = 0; i < NW*K; i++) w_signs[i] = (sign_mode == 2) ? ($urandom & 1) : (sign_mode == 1);
    endtask

    bit ring_prev = 0;
    int ring_run = 0;
    always @(negedge clk) begin : stim
        int r;
        if (cyc < 4) begin
            reset <= 1'b1;
        end else begin
            r = $urandom_range(0, 999);
            // reset: rare, and deliberately on lap edges in phase B
            // (rq_m is ring_q now, so the coming edge is a lap edge when it is high)
            reset <= (r < 3) || (phase_b && rq_m == 1'b1 && $urandom_range(0, 19) == 0);
            mac_en <= ($urandom_range(0, 9) < 7);
            shift_in <= phase_b ? ($urandom_range(0, 99) < 8) : ($urandom_range(0, 99) < 15);
            if (phase_b) begin
                if (ring_run > 0) begin
                    ring_in <= 1'b1; ring_run--;
                end else if ($urandom_range(0, 99) < 14) begin
                    // a contract lap (exactly G edges) most of the time, otherwise any run length
                    ring_in <= 1'b1;
                    ring_run = ($urandom_range(0, 3) != 0) ? G - 1 : $urandom_range(0, 2 * G - 1);
                end else
                    ring_in <= 1'b0;
            end else
                ring_in <= 1'b0;
            load_a <= ($urandom_range(0, 9) < 3);
            load_w <= ($urandom_range(0, 9) < 3);
            for (int h = 0; h < NH; h++) acc_west[h*OW +: OW] <= pick_west();
            drive_operands($urandom_range(0, 9) < 4 ? 1 : $urandom_range(0, 3));
            if ($urandom_range(0, 3) == 0) drive_signs();
        end
        ring_prev = ring_in;
    end

    // checks at negedge (before the stimulus block changes inputs, same timestep is fine:
    // inputs change via NBA)
    always @(negedge clk) begin : check
        if (cyc > 6) begin
            for (int h = 0; h < NH; h++)
                for (int v = 0; v < NW; v++) begin
                    if (d_tile[h][v] !== m[h][v]) begin
                        errors++;
                        if (errors < 20)
                            $display("[MODEL-MISMATCH] cyc %0d phase %s tile (%0d,%0d): dut %h model %h",
                                     cyc, phase_b ? "B" : "A", h, v, d_tile[h][v], m[h][v]);
                    end
                    if (!phase_b && d_tile[h][v] !== r_tile[h][v]) begin
                        errors++;
                        if (errors < 20)
                            $display("[CSA-MISMATCH] cyc %0d tile (%0d,%0d): sr %h csa %h", cyc, h, v,
                                     d_tile[h][v], r_tile[h][v]);
                    end
                end
            if (dut.ring_q !== rq_m) begin
                errors++;
                if (errors < 20) $display("[RINGQ-MISMATCH] cyc %0d dut %b model %b", cyc, dut.ring_q, rq_m);
            end
            if (!phase_b && {d_abo, d_aso, d_wbo, d_wso, d_lao, d_lwo, d_east} !==
                            {r_abo, r_aso, r_wbo, r_wso, r_lao, r_lwo, r_east}) begin
                errors++;
                if (errors < 20) $display("[CSA-OUT-MISMATCH] cyc %0d", cyc);
            end
`ifdef REVIEW_GL
            // The single-PE top leaves the systolic re-export rails (a/w bits and
            // signs out, load waves out) unconnected, so synthesis drops them and
            // the netlist PE leaves those ports undriven: compare the accumulator
            // outputs and the ring wave only.
            c_gl_cmp++;
            if ({g_ring, g_east} !== {d_ring, d_east}) begin
                errors++;
                if (errors < 20) $display("[GL-MISMATCH] cyc %0d phase %s east gl %h rtl %h", cyc,
                                          phase_b ? "B" : "A", g_east, d_east);
            end
`endif
        end
        cyc++;
        if (cyc == NA) phase_b = 1;
        if (cyc == NA + NB) finish_run();
    end

    task automatic finish_run();
        bit cov_ok;
        $display("REVIEW coverage: phaseA_shift_tiles=%0d phaseA_shift_with_pending_carry=%0d phaseA_shift_with_pending_borrow=%0d",
                 c_a_shifts, c_a_pc, c_a_pb);
        $display("REVIEW coverage: lap_edges=%0d tile_laps=%0d with_pending_carry=%0d with_pending_borrow=%0d sign_overflow=%0d",
                 c_lap_edges, c_tile_laps, c_lap_pc, c_lap_pb, c_lap_ovf);
        $display("REVIEW coverage: LAP_G=%0d full_%0d_edge_laps_checked=%0d (tiles %0d)", G, G, c_full_laps, c_full_lap_checked_tiles);
        $display("REVIEW coverage: lap_with_shift_in=%0d lap_with_mac_en=%0d consecutive_laps=%0d reset_on_lap_edge=%0d ring_in_during_reset=%0d lap_of_0x800000=%0d lap_of_0x400000_or_0x7fffff=%0d gl_compares=%0d",
                 c_lap_shift, c_lap_mac, c_lap_double, c_reset_on_lap, c_ring_during_reset, c_lap_maxneg, c_lap_minpos, c_gl_cmp);
        cov_ok = c_lap_pc > 0 && c_lap_pb > 0 && c_lap_ovf > 0 && c_lap_shift > 0 && c_lap_mac > 0 &&
                 c_lap_double > 0 && c_reset_on_lap > 0 && c_ring_during_reset > 0 && c_a_pc > 0 && c_a_pb > 0 &&
                 c_lap_maxneg > 0 && c_full_laps > 0;
        if (errors == 0 && cov_ok)
            $display("REVIEW PASS: %0d cycles (A %0d, B %0d), 0 mismatches", NA + NB, NA, NB);
        else
            $display("REVIEW FAIL: errors=%0d coverage_ok=%0d", errors, cov_ok);
        $finish;
    endtask

    initial begin
        void'($value$plusargs("NA=%d", NA));
        void'($value$plusargs("NB=%d", NB));
        void'($value$plusargs("SEED=%d", seed));
        void'($urandom(seed));
        for (int h = 0; h < NH; h++) for (int v = 0; v < NW; v++) m[h][v] = '0;
    end
endmodule
