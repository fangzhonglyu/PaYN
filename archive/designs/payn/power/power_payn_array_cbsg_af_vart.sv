`timescale 1ns/1ps

`include "common/clk_util.sv"

// L-sweep copy of power_payn_array_cbsg_af.sv (sweeps/cbsg/tsweep/, 2026-10-05).
// The only change: the uniform workload's L is CBSG_PWR_UNIFORM_L (default 128,
// 1..128) instead of a fixed 128, written on the trace's LADDER line and in the
// PASS line.  The operand draws do not depend on L, so every uniform-L run sees
// the same A/W magnitudes and signs as the L=128 headline, and with L=128 (or
// CBSG_PWR_LADDER) the stimulus is identical to power_payn_array_cbsg_af.sv.
// Checker: sweeps/cbsg/tsweep/check_af_power_trace_vart.py.
//
// Power + output-checking bench for the C-BSG A-first array
// (payn_array_signed_segmented_csa_cbsg_af), modeled on power_payn_array.sv.
//
// One plain call of SC_BATCHES blocks (D = 8 * SC_BATCHES reduction columns)
// runs back to back inside the SAIF window: every block loads new A/W
// magnitudes, signs and row lengths with block_start on the load edge, runs
// C = ceil(max L / 16) cycles, and the next block loads at B+C (no bubble).
// The accumulator drain comes after $toggle_stop (headline power excludes the
// drain).  Inputs are launched at the NEGEDGE, mac_en right after a posedge,
// as in power_payn_array.sv.
//
// Operand activity matches power_payn_array.sv: |q| uniform in 0..127 and a
// random sign per element, new every block, loads inside the window.  The
// C-BSG field is the kernel boundary b = round(|q| * 128/127) = |q| + [|q| >= 64]
// (power_payn_array.sv sends |q| << 1 to its 8-bit comparator).
//
// Workloads (one define):
//   default            uniform L = CBSG_PWR_UNIFORM_L (default 128) on every row of every
//                      block: every block ceil(L / 16) cycles (8 at L = 128: 3,072 window
//                      edges at 384 blocks)
//   CBSG_PWR_LADDER    per-row L drawn uniformly from the 14B target-48 ladder
//                      [128, 96, 64, 48, 44, 42, 38] per (row, 128-column chunk), as a
//                      chunk_d = 128 rung table; a chunk's blocks run ceil(max L / 16)
//                      cycles (3..8).  The chunks are not drained separately (the drain
//                      stays outside the window), so the drained value is the sum of the
//                      per-chunk partials; chunks of 16 blocks start at phase 0, so the
//                      slice-local masks are exact without a slice_start per chunk.
//
// The issued blocks and the drain are written to array_streaming_cbsg_af_rtl.txt;
// sweeps/cbsg/tsweep/check_af_power_trace_vart.py recomputes the drain with cbsg_ref.py
// (kernel and AF model) and asserts a bit-exact match.
//
// Needs DesignWare for the RTL CSA tile heap: make sim ... USE_DW=1

`ifndef GL_SIM
`include "payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv"
`endif

`ifndef SC_K
`define SC_K 8
`endif
`ifndef SC_M
`define SC_M 16
`endif
`ifndef SC_NH
`define SC_NH 8
`endif
`ifndef SC_NW
`define SC_NW 8
`endif
`ifndef SC_WIDTH
`define SC_WIDTH 8
`endif
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_BATCHES
`define SC_BATCHES 256
`endif
`ifndef CBSG_PWR_UNIFORM_L
`define CBSG_PWR_UNIFORM_L 128
`endif
`ifndef SC_SEED
`define SC_SEED 32'hDEAD_BEEF
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int WIDTH = `SC_WIDTH;
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int N_BLOCKS = `SC_BATCHES;
    localparam int CHUNK_BLOCKS = 16;                // 128 columns per rung chunk
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
`ifdef CBSG_PWR_LADDER
    localparam int WORKLOAD = 1;
`else
    localparam int WORKLOAD = 0;
`endif
    localparam int UNIFORM_L = `CBSG_PWR_UNIFORM_L;
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

    integer signed drain [N_H][N_W];
    integer trace_file;
    int seed_state;
    bit monitor_x = 1'b0;
    int row_len [N_H];

    ClkUtils #(.TIMEOUT(N_BLOCKS * 8 + N_W + 256)) clk_utils (
        .clk, .reset, .timeout
    );

    always @(posedge timeout) $fatal(1, "[TIMEOUT] CBSG AF power bench");

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drain rail entered X during SAIF: %h", acc_out_east);

    payn_array_signed_segmented_csa_cbsg_af #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .WIDTH(WIDTH), .OWIDTH(OWIDTH)
    ) dut (.*);

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

    initial begin
        int next_b, cycles, window_edges, total_cycles;
        string workload_name;
        int unsigned edge_idx, next_load, last_mac;

        assert (K == 8 && M == 16 && WIDTH == 8)
            else $fatal(1, "C-BSG power bench needs K=8, M=16, WIDTH=8");
        assert (N_BLOCKS > 0)
            else $fatal(1, "SC_BATCHES must be positive");
        assert (UNIFORM_L >= 1 && UNIFORM_L <= 128)
            else $fatal(1, "CBSG_PWR_UNIFORM_L must lie in 1..128");
        workload_name = (WORKLOAD == 1) ? "ladder" : $sformatf("uniform L=%0d", UNIFORM_L);

        seed_state = `SC_SEED;
        void'($urandom(seed_state));

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        // Let routed reset trees settle for two complete clocks before loading
        // operands (outside the SAIF window), as power_payn_array.sv does.
        repeat (2) @(negedge clk);

        trace_file = $fopen("array_streaming_cbsg_af_rtl.txt", "w");
        assert (trace_file != 0)
            else $fatal(1, "cannot open array_streaming_cbsg_af_rtl.txt");
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
        if (next_load == 1 && next_b < N_BLOCKS) begin  // never at L >= 17
            issue_block(next_b, cycles);
            total_cycles += cycles;
            last_mac = next_load + cycles + 1;
            next_load += cycles;
            next_b++;
        end
        @(posedge clk);                     // B0+1
        // mac_en right after this posedge (power_payn_array.sv: a full period
        // of setup for the acc_low clock gate).
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
        acc_in_west = '0;
        for (int s = 0; s < N_W; s++) begin
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            shift_in = 1'b1;
            @(posedge clk);
            @(negedge clk);
        end
        shift_in = 1'b0;

        $fwrite(trace_file, "WINDOW %0d\n", window_edges);
        $fwrite(trace_file, "DRAIN");
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

`ifndef GL_SIM
        if (dut.contract_errors != 0)
            $fatal(1, "[CONTRACT] %0d [CBSG-AF-CONTRACT] errors in the power bench schedule", dut.contract_errors);
`endif
        $display("PASS: streaming C-BSG AF SAIF captured; workload %0s, %0d blocks, %0d window edges, drain dumped -> check_power_trace.py",
                 workload_name, N_BLOCKS, window_edges);
        $finish;
    end
endmodule
