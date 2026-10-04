`timescale 1ns/1ps

`include "common/clk_util.sv"

// Bit-plane INT energy bench for the routed CSA single-PE array
// (payn_array_signed_segmented_csa), emulating the BP-HW-ring INT mode of
// sweeps/int_mode/model_bitplane_throughput.py on UNCHANGED hardware.
//
// What is emulated, and how:
//  * Comparator bypass.  The proposed INT mode ORs raw operand bits into the
//    comparator outputs.  The routed netlist has no such OR, so the raw bits
//    are forced onto the u_pe input nets (dut.u_pe.a_bits_in / w_bits_in, the
//    peripheral -> PE boundary that power_payn_array_tpad.sv also forces).
//    The peripheral is idle: rng_en = 0 (Sobol frozen) and the held binary
//    magnitudes stay 0, so every comparator output is a constant 0 and the
//    forced value is exactly what "0 | raw" would deliver.
//  * Mapping (one PE, HW mode): row h carries activation plane p = h % BA of
//    activation row i = ig*ROWS_PE + h / BA; column v carries output column
//    j = jg*8 + v.  Lane k / position m of a cycle carries reduction element
//    kk = 128*b + 16*k + m.  Weight planes go in time, one pass per plane,
//    MSB pass first: in pass q, w_bits[v][k][m] = bit q of W[kk, j].
//  * Signs (two's complement, MSB plane negative) go through the EXISTING sign
//    path: a_signs_in[h*K+k] = (h % BA == BA-1), loaded once; w_signs_in =
//    all ones for the weight MSB pass, zeros otherwise, loaded with load_w /
//    load_w_sign one cycle before each pass's first raw bits (the peripheral
//    register plus the PE sign pipe is two edges, the raw path one edge).
//    a_binary_in / w_binary_in stay 0, so those loads keep the magnitudes 0.
//  * Per-PE drain ring.  Between weight passes every tile value is doubled by
//    one lap around the PE's own drain chain: 8 shift_in cycles with
//    acc_in_west = acc_out_east << 1 (per row).  The bench closes this loop
//    through the top-level ports with a transport delay of INTB_RING_DLY_NS
//    standing in for the return wire, so glitches on acc_out_east propagate
//    like they would on a real ring.  ring_en (the ring mux select) changes
//    at negedges, like a registered ring_q would, never racing a capture
//    edge.  The ring mux cells themselves are not in the netlist.
//  * Zero bubbles: during each 8-cycle lap the data mover sends zero raw
//    bits (shift_in has priority over MAC, so they are never accumulated).
//  * Drain: after the last pass, 8 shift_in cycles with acc_in_west = 0
//    deliver tile (h, 7-t) on acc_out_east at drain edge t and clear the
//    tiles for the next block.  Every block's drained 64 values are written
//    to intb_trace.txt and checked post hoc against a numpy reference by
//    sweeps/int_mode/check_bitplane_drain.py.
//
// Schedule (edge P_e = e-th posedge after the post-reset settle; E0 = first
// data capture).  Inside a block, pass pi (q = BW-1-pi) occupies PASS_LEN =
// NB + 8 edges: offsets u = 0..NB-1 capture data (kk-block b = u) into the bit
// pipes, u = NB..NB+7 capture zero bubbles.  Shift edges are u = NB+1..NB+7
// and u = 0 of the following pass (ring lap if pi < BW-1, else drain).
// Interval I_e = (P_e + 1 ps, P_{e+1} + 1 ps] is classed DATA if u < NB, else
// RING or DRAIN.  SAIF collection is paused/resumed exactly at those 1 ps
// marks (verified: duration and clock toggle count stay exact):
//   INTB_SAIF_MODE 0: data + ring intervals (drain paused; SC methodology
//                     excludes the drain)
//   INTB_SAIF_MODE 1: data intervals only (peak)
//   INTB_SAIF_MODE 2: everything, drain included
// Each active interval contains exactly one clock period, so the SAIF period
// check (2*duration/clock TC) stays exact.
//
// Input timing: every DUT input (forced raw bits, signs, loads, shift_in,
// mac_en, ring select) is launched at the negedge, i.e. at the route's SDC
// input delay of 1.25 ns.  Unlike power_payn_array.sv, shift_in and mac_en are
// NOT launched just after the posedge: a falling shift_in launched there races
// the ICG-gated acc_high clock in some tiles (see the loop comment).
//
// Operands come from intb_a.hex / intb_w.hex in the run directory
// (sweeps/int_mode/gen_bitplane_workload.py).  RTL needs DesignWare
// (USE_DW=1); RTL instantiates the CSA RTL with LOW_W=9 like the route.

`ifndef GL_SIM
`include "payn/variants/signed_segmented_csa/payn_array_signed_segmented_csa.sv"
`endif

`ifndef PAYN_ARRAY_DUT
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa
`endif
`ifndef INTB_BA
`define INTB_BA 8
`endif
`ifndef INTB_BW
`define INTB_BW 8
`endif
`ifndef INTB_L
`define INTB_L 1024
`endif
`ifndef INTB_MROWS
`define INTB_MROWS 1
`endif
`ifndef INTB_NCOLS
`define INTB_NCOLS 8
`endif
`ifndef INTB_SAIF_MODE
`define INTB_SAIF_MODE 0
`endif
`ifndef INTB_RING_DLY_NS
`define INTB_RING_DLY_NS 0.15
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
    localparam int BA = `INTB_BA;
    localparam int BW = `INTB_BW;
    localparam int L = `INTB_L;
    localparam int MROWS = `INTB_MROWS;
    localparam int NCOLS = `INTB_NCOLS;
    localparam int NB = L / (K*M);              // data cycles per pass
    localparam int ROWS_PE = N_H / BA;          // activation rows per block
    localparam int NIG = MROWS / ROWS_PE;
    localparam int NJG = NCOLS / N_W;
    localparam int NBLK = NIG * NJG;
    localparam int PASS_LEN = NB + N_W;         // data + one 8-shift lap
    localparam int BLK_LEN = BW * PASS_LEN;
    localparam int E0 = 4;                      // first data capture edge
    localparam int E_DATA_END = E0 + NBLK*BLK_LEN;
    localparam int E_END = E_DATA_END;          // final drain edge
    localparam int N_EDGES = E_END + 1;
    localparam int SAIF_MODE = `INTB_SAIF_MODE;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
    localparam real RING_DLY = `INTB_RING_DLY_NS;

    logic clk, reset, timeout;
    logic rng_en = 1'b0, mac_en = 1'b0, shift_in = 1'b0;
    logic load_a = 1'b0, load_w = 1'b0, load_a_sign = 1'b0, load_w_sign = 1'b0;

    logic [N_H*K*WIDTH-1:0] a_binary_in = '0;
    logic [N_H*K-1:0]       a_signs_in = '0;
    logic [N_W*K*WIDTH-1:0] w_binary_in = '0;
    logic [N_W*K-1:0]       w_signs_in = '0;
    logic [N_H*OWIDTH-1:0]  acc_in_west = '0;
    logic [N_H*OWIDTH-1:0]  acc_out_east;

    // Raw bit-plane operands forced onto the PE input nets.
    logic [N_H*K*M-1:0] a_raw = '0;
    logic [N_W*K*M-1:0] w_raw = '0;
    bit ring_en = 1'b0;

    logic [7:0] a_mem [MROWS*L];
    logic [7:0] w_mem [NCOLS*L];      // w_mem[j*L + kk] = W[kk, j]
    integer signed drain [NBLK][N_H][N_W];

    integer trace_file;
    bit monitor_x = 1'b0;
    bit collecting = 1'b0;
    int n_active = 0, n_data = 0, n_ring = 0, n_drain = 0, n_segments = 0;

    ClkUtils #(.TIMEOUT(N_EDGES + 256)) clk_utils (.clk, .reset, .timeout);

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drain rail entered X during SAIF: %h", acc_out_east);

`ifdef GL_SIM
    `PAYN_ARRAY_DUT dut (.*);
`else
    `PAYN_ARRAY_DUT #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH),
        .LOW_W(9)
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

`ifdef INTB_VCD
    // Debug only (never in measured runs): dump the top ports and the whole
    // PE array core for a short schedule.
    initial begin
        $dumpfile("intb_debug.vcd");
        $dumpvars(1, Top);
        $dumpvars(0, dut.u_pe);
    end
`endif

    // Comparator-bypass emulation: the PE input nets follow a_raw / w_raw.
    initial begin
        force dut.u_pe.a_bits_in = a_raw;
        force dut.u_pe.w_bits_in = w_raw;
    end

    // Per-PE ring emulation: west input = own east output << 1 while ring_en.
    // Nonblocking intra-assignment delay = transport delay (no glitch filter).
    always @(acc_out_east or ring_en) begin : ring_loop
        logic [N_H*OWIDTH-1:0] nxt;
        for (int h = 0; h < N_H; h++)
`ifdef INTB_NEG_NO_DOUBLE
            // Negative control: the lap returns the value without the x2.
            nxt[h*OWIDTH +: OWIDTH] =
                ring_en ? acc_out_east[h*OWIDTH +: OWIDTH] : '0;
`else
            nxt[h*OWIDTH +: OWIDTH] =
                ring_en ? {acc_out_east[h*OWIDTH +: OWIDTH-1], 1'b0} : '0;
`endif
        acc_in_west <= #(RING_DLY) nxt;
    end

    // ---------------------------------------------------------- schedule --
    function automatic void decode(input int e, output int blk, output int pi,
                                   output int u);
        int r;
        r = e - E0;
        blk = r / BLK_LEN;
        r = r % BLK_LEN;
        pi = r / PASS_LEN;
        u = r % PASS_LEN;
    endfunction

    // shift_in sampled at P_e.
    function automatic bit shift_at(input int e);
        int blk, pi, u;
        if (e <= E0 || e > E_END) return 1'b0;
        decode(e, blk, pi, u);
        return (u == 0) || (u >= NB + 1);
    endfunction

    // The shift at P_e is a ring-lap shift (not a drain shift).
    function automatic bit ring_at(input int e);
        int blk, pi, u;
        if (!shift_at(e)) return 1'b0;
        decode(e, blk, pi, u);
        if (u == 0) return pi >= 1;     // closes the lap after pass pi-1
        return pi < BW - 1;
    endfunction

    // 0 = data, 1 = ring lap, 2 = drain lap, for interval I_e.
    function automatic int interval_class(input int e);
        int blk, pi, u;
        decode(e, blk, pi, u);
        if (u < NB) return 0;
        return (pi < BW - 1) ? 1 : 2;
    endfunction

    function automatic bit interval_active(input int e);
        int c;
        if (e < E0 || e >= E_END) return 1'b0;
        c = interval_class(e);
        case (SAIF_MODE)
            0: return c != 2;
            1: return c == 0;
            default: return 1'b1;
        endcase
    endfunction

    // Raw planes captured into the bit pipes at P_e (launched at the negedge
    // before it).  Assembled in temporaries and applied in one assignment so
    // the forced nets see one event per cycle.
    task automatic set_raw(input int e);
        logic [N_H*K*M-1:0] a_next;
        logic [N_W*K*M-1:0] w_next;
        int blk, pi, u, ig, jg, q, i, p, j, kk;
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
                            kk = u*K*M + k*M + m;
                            a_next[(h*K + k)*M + m] = a_mem[i*L + kk][p];
                        end
                end
                for (int v = 0; v < N_W; v++) begin
                    j = jg*N_W + v;
                    for (int k = 0; k < K; k++)
                        for (int m = 0; m < M; m++) begin
                            kk = u*K*M + k*M + m;
                            w_next[(v*K + k)*M + m] = w_mem[j*L + kk][q];
                        end
                end
            end
        end
        a_raw = a_next;
        w_raw = w_next;
    endtask

    // Sign loads captured by the peripheral at P_e, so the PE sign pipes
    // take them at P_{e+1}, the pass's first data capture edge.
    task automatic set_signs(input int e);
        int blk, pi, u;
        load_a = 1'b0;
        load_a_sign = 1'b0;
        load_w = 1'b0;
        load_w_sign = 1'b0;
`ifdef INTB_NEG_LATE_SIGN
        // Negative control: signs launched one cycle late (raw-path timing),
        // so each pass's first MAC uses the previous pass's sign.
        if (e >= E0 && e < E_DATA_END) begin
            decode(e, blk, pi, u);
`else
        if (e + 1 >= E0 && e + 1 < E_DATA_END) begin
            decode(e + 1, blk, pi, u);
`endif
            if (u == 0) begin
                w_signs_in = (pi == 0) ? '1 : '0;
                load_w = 1'b1;
                load_w_sign = 1'b1;
                if (e + 1 == E0 || e == E0) begin
                    load_a = 1'b1;
                    load_a_sign = 1'b1;
                end
            end
        end
    endtask

    task automatic read_drain(input int e);
        int blk, pi, u, bd, t;
        if (!shift_at(e) || ring_at(e)) return;
        decode(e, blk, pi, u);
        if (u == 0) begin
            bd = blk - 1;
            t = N_W - 1;
        end else begin
            bd = blk;
            t = u - NB - 1;
        end
        for (int h = 0; h < N_H; h++) begin
            if ($isunknown(acc_out_east[h*OWIDTH +: OWIDTH]))
                $fatal(1, "[X-FAIL] drained value X: block %0d row %0d step %0d", bd, h, t);
            drain[bd][h][N_W-1-t] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
        end
    endtask

    initial begin
        assert (BA == 8 || BA == 4) else $fatal(1, "INTB_BA must be 4 or 8");
        assert (BW == 8 || BW == 4) else $fatal(1, "INTB_BW must be 4 or 8");
        assert (L % (K*M) == 0 && NB >= 1) else $fatal(1, "INTB_L must be a positive multiple of 128");
        assert (MROWS % ROWS_PE == 0 && NCOLS % N_W == 0 && NBLK >= 1)
            else $fatal(1, "MROWS must be a multiple of %0d and NCOLS of 8", ROWS_PE);
        // |tile value| <= 2^(BW-1) * L must fit the 24-bit accumulator.
        assert ((longint'(1) << (BW-1)) * L < (longint'(1) << (OWIDTH-1)))
            else $fatal(1, "L=%0d can overflow the %0d-bit accumulator", L, OWIDTH);

        $readmemh("intb_a.hex", a_mem);
        $readmemh("intb_w.hex", w_mem);
        foreach (a_mem[n]) if ($isunknown(a_mem[n])) $fatal(1, "intb_a.hex short/invalid at %0d", n);
        foreach (w_mem[n]) if ($isunknown(w_mem[n])) $fatal(1, "intb_w.hex short/invalid at %0d", n);
        for (int h = 0; h < N_H; h++)
            for (int k = 0; k < K; k++)
                a_signs_in[h*K + k] = (h % BA == BA - 1);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("intb_trace.txt", "w");
        assert (trace_file != 0) else $fatal(1, "cannot open intb_trace.txt");
        $fwrite(trace_file, "INTBCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                BA, BW, L, MROWS, NCOLS, NBLK, NB, SAIF_MODE, N_EDGES);

`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);

        // Each iteration starts at the negedge before P_e.  EVERY input,
        // including shift_in and mac_en, is launched here: the route's SDC
        // signs off all array inputs with set_input_delay 1.25 ns (half a
        // period), min and max.  Launching shift_in just after the root
        // posedge instead (as power_payn_array.sv does) violates that
        // assumption: a falling shift_in then reaches some tiles' drain-mux
        // selects before their ICG-gated acc_high clock and the last ring
        // shift captures high_next instead of acc_in (seen in GL as silent
        // corruption in five tiles plus setup-window reports in one).
        for (int e = 0; e < N_EDGES; e++) begin
            set_raw(e);
            set_signs(e);
            ring_en = ring_at(e);
            shift_in = shift_at(e);
            mac_en = (e > E0);                   // first MAC at P_{E0+1}
            @(posedge clk);                      // P_e
            read_drain(e);                       // pre-edge acc_out_east
            #(0.001);                            // P_e + 1 ps: SAIF window mark
            if (interval_active(e)) begin
                if (!collecting) begin
                    $toggle_start;
                    collecting = 1'b1;
                    n_segments++;
                end
                n_active++;
                case (interval_class(e))
                    0: n_data++;
                    1: n_ring++;
                    default: n_drain++;
                endcase
            end else if (collecting) begin
                $toggle_stop;
                collecting = 1'b0;
            end
            monitor_x = (e >= E0 && e < E_END);
            @(negedge clk);
        end
        assert (!collecting) else $fatal(1, "SAIF window still open after the schedule");
        monitor_x = 1'b0;
        mac_en = 1'b0;
        shift_in = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        $fwrite(trace_file, "SAIFWIN %0d %0d %0d %0d %0d\n",
                n_active, n_data, n_ring, n_drain, n_segments);
        for (int b = 0; b < NBLK; b++) begin
            $fwrite(trace_file, "DRAIN %0d", b);
            for (int h = 0; h < N_H; h++)
                for (int v = 0; v < N_W; v++)
                    $fwrite(trace_file, " %0d", drain[b][h][v]);
            $fwrite(trace_file, "\n");
        end
        $fclose(trace_file);
        $display("PASS: INT bit-plane SAIF captured; BA=%0d BW=%0d L=%0d blocks=%0d mode=%0d active=%0d",
                 BA, BW, L, NBLK, SAIF_MODE, n_active);
        $finish;
    end
endmodule
