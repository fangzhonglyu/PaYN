`timescale 1ns/1ps

`include "common/clk_util.sv"

// SC power + output-checking bench for payn_array (A-first C-BSG streams, one
// PE).  Shape from +define+PAYN_M=8 (K16/M8, default) or 16 (K8/M16), K =
// 128/M lanes; SC_NH x SC_NW tiles (default 8 x 8).
//
// One plain call of SC_BATCHES blocks (D = K * SC_BATCHES reduction columns)
// runs back to back inside the SAIF window: every block loads new A/W
// magnitudes, signs and row lengths with block_start on the load edge, runs
// C = ceil(max L / M) cycles, and the next block loads at B+C (no bubble).
// The accumulator drain comes after $toggle_stop (headline power excludes the
// drain).  Inputs are launched at the NEGEDGE, mac_en right after a posedge
// (a full period of setup for the acc_low clock gate).
//
// Operand activity: |q| uniform in 0..127 and a random sign per element, new
// every block, loads inside the window.  The C-BSG field is the kernel
// boundary b = round(|q| * 128/127) = |q| + [|q| >= 64].
//
// INT side: the INT ports are tied off (int_mode = 0, raw planes, int_prec
// and ring_in 0) and checked to stay silent (int_out and int_out_valid 0, and
// in RTL ring_q 0) from the first reset edge on ([INT-FAIL]).  With
// +define+SC_INT_JUNK the raw planes, int_prec and ring_in instead take random
// values on every edge (own xorshift generator, so the operand stream and the
// trace are unchanged); SC must not change.
//
// Workloads (one define):
//   default    uniform L = SC_UNIFORM_L (default 128, 1..128) on every row of
//              every block: every block ceil(L / M) cycles (2,048 window edges
//              at 256 blocks and L = 128 at K8/M16, 4,096 at K16/M8).  The
//              operand draws do not depend on L, so every uniform-L run sees the
//              same magnitudes and signs (energy vs stream length T = L)
//   SC_LADDER  per-row L drawn uniformly from the 14B target-48 ladder
//              [128, 96, 64, 48, 44, 42, 38] per (row, 128-column chunk), as a
//              chunk_d = 128 rung table; a chunk's blocks run ceil(max L / M)
//              cycles.  The chunks are not drained separately (the drain stays
//              outside the window), so the drained value is the sum of the
//              per-chunk partials; chunks of 128/K blocks start at phase 0, so
//              the slice-local masks are exact without a slice_start per
//              chunk.
//
// The issued blocks and the drain are written to
// sc_trace.txt:
//   CBSGAFSTREAM K M NH NW OWIDTH NB CB WL      CB = blocks per chunk, WL = workload (0 uniform, 1 ladder)
//   LADDER v ...
//   BLOCK i cycles slice_start, then lines AMAG / ASIGN / ALEN / WMAG / WSIGN
//   WINDOW edges
//   DRAIN acc[0][0] ... acc[NH-1][NW-1]
// designs/payn/model/sc_trace.py recomputes the drain (kernel and A-first
// model) and asserts a bit-exact match.  In RTL the [SC-CONTRACT] count must
// stay 0.  Last line PASS: PaYN SC power bench ...
//
// Drain register (+define+PAYN_DRAIN=1): the post-window drain is the
// read-out instead: drain_in for one edge, then dr_out after each of the two
// read edges (tile rows 0-3, then 4-7; at the negedge, or with
// DRAIN_SAMPLE_LATE_PS that many ps before the next edge), dr_out_valid high
// on both; the DRAIN line is the same.  dr_in_east is held at 0 (one PE).
//
// Defines: PAYN_M, PAYN_DRAIN (0), PAYN_LAP_FOLD (0; SC mode never laps), SC_NH, SC_NW, SC_OWIDTH (24), SC_BATCHES (256), SC_SEED,
// SC_UNIFORM_L (128), SC_LADDER, SC_INT_JUNK, SC_DRAIN_SAMPLE_LATE_PS (0; or the
// plusarg +DRAIN_SAMPLE_LATE_PS=n, for routed netlists, see the drain below),
// ASTRAEA_CLK_PERIOD_NS.  Needs DesignWare for the RTL
// tile heap (VCS -y $SYNOPSYS/dw/sim_ver).  GL runs: +define+GL_SIM,
// +define+PAYN_DUT=<netlist top> if it is not payn_array, SDF_FILE / NO_SDF.

`ifndef GL_SIM
`include "payn/rtl/payn_array.sv"
`endif

`ifndef PAYN_M
`define PAYN_M 8                      // positions per lane: 8 (K16/M8) or 16 (K8/M16)
`endif
`ifndef PAYN_DRAIN
`define PAYN_DRAIN 0                  // drain: 0 in-tile chain, 1 drain register (payn_array.sv)
`endif
`ifndef PAYN_DUT
`define PAYN_DUT payn_array           // netlist top name (GL_SIM)
`endif
`ifndef SC_NH
`define SC_NH 8
`endif
`ifndef SC_NW
`define SC_NW 8
`endif
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_BATCHES
`define SC_BATCHES 256
`endif
`ifndef SC_DRAIN_SAMPLE_LATE_PS
`define SC_DRAIN_SAMPLE_LATE_PS 0
`endif
`ifndef SC_UNIFORM_L
`define SC_UNIFORM_L 128
`endif
`ifndef SC_SEED
`define SC_SEED 32'hDEAD_BEEF
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int M = `PAYN_M;
    localparam int K = 128 / M;
    localparam int CYCLES = 128 / M;                 // cycles per 128-sample block
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int WIDTH = 8;
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int N_BLOCKS = `SC_BATCHES;
    localparam int CHUNK_BLOCKS = 128 / K;           // 128 columns per rung chunk
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
`ifdef SC_LADDER
    localparam int WORKLOAD = 1;
    localparam string WORKLOAD_NAME = "ladder";
`else
    localparam int WORKLOAD = 0;
    localparam string WORKLOAD_NAME = "uniform L=";
`endif
    localparam int UNIFORM_L = `SC_UNIFORM_L;
    initial assert (UNIFORM_L >= 1 && UNIFORM_L <= 128) else $fatal(1, "SC_UNIFORM_L must lie in 1..128");
    localparam int N_LADDER = 7;
    localparam int LADDER [N_LADDER] = '{128, 96, 64, 48, 44, 42, 38};

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
    // INT ports: SC mode, tied off (or junk, SC_INT_JUNK).
    logic int_mode = 1'b0, int_prec = 1'b0, ring_in = 1'b0;
    logic [N_H*K*M-1:0] a_raw_in = '0;
    logic [N_W*K*M-1:0] w_raw_in = '0;
    logic [63:0] int_out;
    // Drain register ports (DRAIN = 1 builds; unused and 0 with the in-tile chain).
    localparam int DRAIN = `PAYN_DRAIN;
    localparam int DRW = (N_H / 2) * N_W * OWIDTH;
    logic drain_in = 1'b0;
    logic [DRW-1:0] dr_out;
    logic dr_out_valid;
    logic [DRW-1:0] dr_in_east = '0;           // one PE: no east neighbour
    logic dr_in_east_valid = 1'b0;
    logic int_out_valid;
    bit int_reset_seen = 1'b0;

    always @(posedge clk) begin
        if (reset === 1'b1)
            int_reset_seen <= 1'b1;
        else if (int_reset_seen && (int_out_valid !== 1'b0 || int_out !== '0
`ifndef GL_SIM
                                    || dut.u_pe.ring_q !== 1'b0
`endif
                                    ))
            $fatal(1, "[INT-FAIL] INT side moved or went X in SC mode (valid=%b out=%h)",
                   int_out_valid, int_out);
    end
`ifdef SC_INT_JUNK
    int unsigned jx = 32'h2545_F491;
    function automatic int unsigned jrand();
        jx ^= jx << 13;
        jx ^= jx >> 17;
        jx ^= jx << 5;
        return jx;
    endfunction
    always @(negedge clk) begin
        for (int i = 0; i < N_H*K*M; i += 32) a_raw_in[i +: 32] = jrand();
        for (int i = 0; i < N_W*K*M; i += 32) w_raw_in[i +: 32] = jrand();
        int_prec = jrand() & 1;
        ring_in = jrand() & 1;
    end
`endif

    integer signed drain [N_H][N_W];
    integer trace_file;
    int seed_state;
    bit monitor_x = 1'b0;
    int row_len [N_H];

    ClkUtils #(.TIMEOUT(N_BLOCKS * CYCLES + N_W + 256)) clk_utils (
        .clk, .reset, .timeout
    );

    always @(posedge timeout) $fatal(1, "[TIMEOUT] PaYN SC power bench");

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drain rail entered X during SAIF: %h", acc_out_east);

`ifdef GL_SIM
    `PAYN_DUT dut (.*);
`else
    payn_array #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH), .DRAIN(DRAIN)
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

    // b = round(|q| * 128/127) for |q| in 0..127.
    function automatic logic [WIDTH-1:0] boundary(input int q);
        return WIDTH'(q + ((q >= 64) ? 1 : 0));
    endfunction

    // Draw block b's operands (and, at a chunk start, its row lengths), drive
    // them with the load/restart strobes, append it to the trace, and return
    // its cycle count.
    task automatic issue_block(input int b, output int cycles);
        int max_len;
        if (b % CHUNK_BLOCKS == 0)
            for (int h = 0; h < N_H; h++)
                row_len[h] = (WORKLOAD == 1) ? LADDER[$urandom % N_LADDER] : UNIFORM_L;
        max_len = 0;
        for (int h = 0; h < N_H; h++) begin
            a_len_in[h*WIDTH +: WIDTH] = WIDTH'(row_len[h]);
            if (row_len[h] > max_len) max_len = row_len[h];
        end
        cycles = (max_len + M - 1) / M;
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = boundary($urandom & 127);
            a_signs_in[i] = $urandom & 1;
        end
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = boundary($urandom & 127);
            w_signs_in[i] = $urandom & 1;
        end
        load_a = 1'b1;
        load_w = 1'b1;
        load_a_sign = 1'b1;
        load_w_sign = 1'b1;
        block_start = 1'b1;
        slice_start = (b == 0);
        $fwrite(trace_file, "BLOCK %0d %0d %0d\nAMAG", b, cycles, b == 0);
        for (int i = 0; i < N_H*K; i++)
            $fwrite(trace_file, " %0d", a_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nASIGN");
        for (int i = 0; i < N_H*K; i++)
            $fwrite(trace_file, " %0d", a_signs_in[i]);
        $fwrite(trace_file, "\nALEN");
        for (int h = 0; h < N_H; h++)
            $fwrite(trace_file, " %0d", row_len[h]);
        $fwrite(trace_file, "\nWMAG");
        for (int i = 0; i < N_W*K; i++)
            $fwrite(trace_file, " %0d", w_binary_in[i*WIDTH +: WIDTH]);
        $fwrite(trace_file, "\nWSIGN");
        for (int i = 0; i < N_W*K; i++)
            $fwrite(trace_file, " %0d", w_signs_in[i]);
        $fwrite(trace_file, "\n");
    endtask

    task automatic idle_strobes();
        load_a = 1'b0;
        load_w = 1'b0;
        load_a_sign = 1'b0;
        load_w_sign = 1'b0;
        block_start = 1'b0;
        slice_start = 1'b0;
    endtask

    function automatic int dut_contract();
`ifndef GL_SIM
        return dut.contract_errors;
`else
        return 0;
`endif
    endfunction

    int drain_sample_late_ps = `SC_DRAIN_SAMPLE_LATE_PS;   // or +DRAIN_SAMPLE_LATE_PS

    initial begin
        int next_b, cycles, window_edges, total_cycles;
        int unsigned edge_idx, next_load, last_mac;

        void'($value$plusargs("DRAIN_SAMPLE_LATE_PS=%d", drain_sample_late_ps));

        assert (((K == 16 && M == 8) || (K == 8 && M == 16)) && WIDTH == 8)
            else $fatal(1, "PaYN SC power bench needs K16/M8 or K8/M16, WIDTH=8 (got K=%0d M=%0d)", K, M);
        assert (N_BLOCKS > 0)
            else $fatal(1, "SC_BATCHES must be positive");

        seed_state = `SC_SEED;
        void'($urandom(seed_state));

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        // Let routed reset trees settle for two complete clocks before loading
        // operands (outside the SAIF window).
        repeat (2) @(negedge clk);

        trace_file = $fopen("sc_trace.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open sc_trace.txt");
        $fwrite(trace_file, "CBSGAFSTREAM %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, OWIDTH, N_BLOCKS, CHUNK_BLOCKS, WORKLOAD);
        $fwrite(trace_file, "LADDER");
        if (WORKLOAD == 1)
            for (int i = 0; i < N_LADDER; i++) $fwrite(trace_file, " %0d", LADDER[i]);
        else
            $fwrite(trace_file, " %0d", UNIFORM_L);
        $fwrite(trace_file, "\n");

        // Block 0 loads at edge B0 (edge_idx counts from it); its first MAC is
        // B0+2, where the window opens.
        rng_en = 1'b1;
        issue_block(0, cycles);
        total_cycles = cycles;
        next_load = cycles;                 // relative to B0
        last_mac = cycles + 1;
        next_b = 1;
        @(posedge clk);                     // B0
        @(negedge clk);
        idle_strobes();
        if (next_load == 1 && next_b < N_BLOCKS) begin  // only for a 1-cycle block (L <= M)
            issue_block(next_b, cycles);
            total_cycles += cycles;
            last_mac = next_load + cycles + 1;
            next_load += cycles;
            next_b++;
        end
        @(posedge clk);                     // B0+1
        // mac_en right after this posedge: a full period of setup for the
        // acc_low clock gate.
        mac_en = 1'b1;
        @(negedge clk);
        idle_strobes();

        // ---- SAIF window: every MAC edge of every block ----
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        monitor_x = 1'b1;
        $toggle_start;

        window_edges = 0;
        for (edge_idx = 2; edge_idx <= last_mac; edge_idx++) begin
            idle_strobes();
            if (next_b < N_BLOCKS && edge_idx == next_load) begin
                issue_block(next_b, cycles);
                total_cycles += cycles;
                last_mac = next_load + cycles + 1;
                next_load += cycles;
                next_b++;
            end
            @(posedge clk);
            @(negedge clk);
            window_edges++;
        end

        assert (next_b == N_BLOCKS && window_edges == total_cycles)
            else $fatal(1, "issued %0d of %0d blocks, %0d window edges for %0d block cycles",
                        next_b, N_BLOCKS, window_edges, total_cycles);
        mac_en = 1'b0;
        rng_en = 1'b0;
        idle_strobes();

        #1ps;
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain outside SAIF: sample before each shift edge ----
        // +DRAIN_SAMPLE_LATE_PS=n reads acc_out_east n ps before the shift
        // edge (the SDC output-delay point, n = 50 for OUTPUT_DELAY 0.05 ns)
        // instead of at the negedge: a routed drain rail settles up to ~1.45 ns
        // after the edge.  The drain is outside the window, so the SAIF and the
        // energy do not depend on it.
        if (DRAIN == 1) begin
            // Read-out: drain_in on the next edge P, half 0 loaded into dr_out
            // on P+1, half 1 on P+2.  mac_en is low, so neither half moves.
            drain_in = 1'b1;
            @(posedge clk);
            @(negedge clk);
            drain_in = 1'b0;
            for (int hf = 0; hf < 2; hf++) begin
                @(posedge clk);
                @(negedge clk);
                if (drain_sample_late_ps > 0) #(PERIOD / 2.0 - drain_sample_late_ps / 1000.0);
                if (dr_out_valid !== 1'b1)
                    $fatal(1, "[X-FAIL] dr_out_valid %b after read edge %0d", dr_out_valid, hf);
                for (int h = 0; h < N_H / 2; h++)
                    for (int v = 0; v < N_W; v++)
                        drain[hf*(N_H/2) + h][v] = $signed(dr_out[(h*N_W + v)*OWIDTH +: OWIDTH]);
            end
        end else begin
        acc_in_west = '0;
        for (int s = 0; s < N_W; s++) begin
            if (drain_sample_late_ps > 0) begin
                shift_in = 1'b1;
                #(PERIOD / 2.0 - drain_sample_late_ps / 1000.0);
            end
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            shift_in = 1'b1;
            @(posedge clk);
            @(negedge clk);
        end
        shift_in = 1'b0;
        end

        $fwrite(trace_file, "WINDOW %0d\n", window_edges);
        $fwrite(trace_file, "DRAIN");
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        if (dut_contract() != 0)
            $fatal(1, "[CONTRACT] %0d [SC-CONTRACT] errors in the power bench schedule", dut_contract());
        if (WORKLOAD == 1)
            $display("PASS: PaYN SC power bench; workload %0s, %0d blocks, %0d window edges, drain dumped (check with sc_trace.py)",
                     WORKLOAD_NAME, N_BLOCKS, window_edges);
        else
            $display("PASS: PaYN SC power bench; workload %0s%0d, %0d blocks, %0d window edges, drain dumped (check with sc_trace.py)",
                     WORKLOAD_NAME, UNIFORM_L, N_BLOCKS, window_edges);
        $finish;
    end
endmodule
