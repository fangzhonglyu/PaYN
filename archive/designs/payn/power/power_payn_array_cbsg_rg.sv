`timescale 1ns/1ps

`include "common/clk_util.sv"

// Streaming power + output-checking bench for the C-BSG RG array
// (payn_array_signed_segmented_csa_cbsg_rg), modeled on power_payn_array.sv.
//
// Workload, matched to the baseline bench's operand activity: every block
// draws fresh uniform 7-bit magnitudes |q| = 0..127 and random signs for all
// 64 A and 64 W elements; the hardware operand is the kernel boundary
// b = round(|q| * 128/127) = |q| + [|q| >= 64].  Blocks run back to back, so
// every block's loads (except block 0's, which fills the pipeline) fall
// inside the SAIF window.  Three stream-length workloads:
//   default         L = 128 on every row: 8 cycles per block (T = 128).  This
//                   matches the baseline bench and is the headline workload.
//   CBSG_WL_LADDER  "ladder_rowmix": rung-table WORST case, per-row L mixed
//                   inside a tile.  L is drawn uniformly from the 14B
//                   target-48 ladder [128, 96, 64, 48, 44, 42, 38]
//                   independently for every (row, chunk); a chunk is
//                   CBSG_CHUNK_BLOCKS blocks (default 16 = 128 columns, the
//                   deployed chunk_d).  A block runs ceil(max_row L / 16)
//                   cycles, so most blocks run the full 8 cycles while short
//                   rows idle -- not a typical deployed case.
//   CBSG_WL_LADDER_GROUPED  "ladder_rowgrouped": one L per chunk shared by all
//                   N_H rows of the tile, drawn from the same ladder, as under
//                   scmp_llm row-split dispatch (rows of one rung share a
//                   tile): ceil(L / 16) cycles per block.
// slice_start is raised on the first block of every chunk.  The accumulators
// are NOT drained between chunks inside the window (headline numbers exclude
// the drain): the single drain after the window holds the sum of the per-chunk
// partials, which sweeps/cbsg/rg/check_power_trace.py recomputes bit-exactly
// with cbsg_ref.py (kernel_acc_chunked summed over chunks, and hw_rg_acc).
//
// Inputs launch at the NEGEDGE (the target's INPUT_DELAY = 1.25 ns), except
// mac_en, which (as in power_payn_array.sv) rises right after the posedge
// before the first accumulating edge.  The drain is read 0.05 ns (the target's
// OUTPUT_DELAY) before each shift edge; see the drain block.  The trace
// cbsg_rg_streaming_rtl.txt lists every block (L, |q|, b, signs, cycles), the
// window length and the drain.
//
// Energy per MAC: P * (window clocks) * period / (blocks * N_H * N_W * K);
// the window clocks are the MAC edges, sum over blocks of ceil(max L / 16).

`ifndef GL_SIM
`ifndef CBSG_RG_EXTERNAL_RTL
`include "payn/variants/signed_segmented_csa_cbsg_rg/payn_array_signed_segmented_csa_cbsg_rg.sv"
`endif
`endif

`ifndef PAYN_ARRAY_DUT
`define PAYN_ARRAY_DUT payn_array_signed_segmented_csa_cbsg_rg
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
`ifndef SC_OWIDTH
`define SC_OWIDTH 24
`endif
`ifndef SC_BATCHES
`define SC_BATCHES 384
`endif
`ifndef SC_SEED
`define SC_SEED 32'hDEAD_BEEF
`endif
`ifndef CBSG_CHUNK_BLOCKS
`define CBSG_CHUNK_BLOCKS 16
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int K = `SC_K;
    localparam int M = `SC_M;
    localparam int N_H = `SC_NH;
    localparam int N_W = `SC_NW;
    localparam int WIDTH = 8;
    localparam int LEN_W = 8;
    localparam int OWIDTH = `SC_OWIDTH;
    localparam int N_BLOCKS = `SC_BATCHES;
    localparam int CHUNK_BLOCKS = `CBSG_CHUNK_BLOCKS;
`ifdef CBSG_WL_LADDER_GROUPED
    localparam int WORKLOAD = 2;
`elsif CBSG_WL_LADDER
    localparam int WORKLOAD = 1;
`else
    localparam int WORKLOAD = 0;
`endif
    localparam int N_LADDER = 7;
    localparam int LADDER [N_LADDER] = '{128, 96, 64, 48, 44, 42, 38};
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
    // Drain sampling point: OUTPUT_DELAY of the PAYN_SC_CSA* targets (0.05 ns)
    // before the shift edge, the latest acc_out_east settles under STA.
    localparam real OUT_SAMPLE_NS = 0.05;
    string wl_name;
    initial wl_name = (WORKLOAD == 2) ? "ladder_rowgrouped" :
                      (WORKLOAD == 1) ? "ladder_rowmix" : "uniform_L128";

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

    // Pre-drawn workload (the draw order is fixed by SC_SEED).
    int unsigned aq   [N_BLOCKS][N_H*K];
    int unsigned wq   [N_BLOCKS][N_W*K];
    bit          asg  [N_BLOCKS][N_H*K];
    bit          wsg  [N_BLOCKS][N_W*K];
    int unsigned lrow [N_BLOCKS][N_H];
    int          cyc  [N_BLOCKS];
    int          gen_start [N_BLOCKS];
    int          total_gen;

    integer signed drain [N_H][N_W];
    integer trace_file;
    int seed_state;
    bit monitor_x = 1'b0;

    ClkUtils #(.TIMEOUT(N_BLOCKS*8 + 4*N_W + 256)) clk_utils (.clk, .reset, .timeout);

    always @(acc_out_east)
        if (monitor_x && $isunknown(acc_out_east))
            $fatal(1, "[X-FAIL] drain rail entered X during SAIF: %h", acc_out_east);

    `PAYN_ARRAY_DUT #(
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

    function automatic int unsigned boundary(input int unsigned q);
        return q + (q >= 64 ? 1 : 0);          // round(q * 128 / 127), q = 0..127
    endfunction

    task automatic draw_workload();
        total_gen = 0;
        for (int b = 0; b < N_BLOCKS; b++) begin
            int lmax;
            if (b % CHUNK_BLOCKS == 0) begin
                int lg;
                // Drawn only for the grouped workload, so the other two keep
                // their random sequence (and operands) unchanged.
                lg = (WORKLOAD == 2) ? LADDER[$urandom % N_LADDER] : 0;
                for (int h = 0; h < N_H; h++)
                    lrow[b][h] = (WORKLOAD == 1) ? LADDER[$urandom % N_LADDER] :
                                 (WORKLOAD == 2) ? lg : 128;
            end else begin
                for (int h = 0; h < N_H; h++) lrow[b][h] = lrow[b-1][h];
            end
            for (int i = 0; i < N_H*K; i++) begin
                aq[b][i] = $urandom & 127;
                asg[b][i] = $urandom & 1;
            end
            for (int i = 0; i < N_W*K; i++) begin
                wq[b][i] = $urandom & 127;
                wsg[b][i] = $urandom & 1;
            end
            lmax = 0;
            for (int h = 0; h < N_H; h++) if (lrow[b][h] > lmax) lmax = lrow[b][h];
            cyc[b] = (lmax + M - 1) / M;
            gen_start[b] = total_gen;
            total_gen += cyc[b];
        end
    endtask

    task automatic apply_block(input int b);
        for (int i = 0; i < N_H*K; i++) begin
            a_binary_in[i*WIDTH +: WIDTH] = WIDTH'(boundary(aq[b][i]));
            a_signs_in[i] = asg[b][i];
        end
        for (int h = 0; h < N_H; h++) row_len_in[h*LEN_W +: LEN_W] = LEN_W'(lrow[b][h]);
        for (int i = 0; i < N_W*K; i++) begin
            w_binary_in[i*WIDTH +: WIDTH] = WIDTH'(boundary(wq[b][i]));
            w_signs_in[i] = wsg[b][i];
        end
    endtask

    task automatic write_trace_blocks();
        $fwrite(trace_file, "CBSGRG_STREAMCFG %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                K, M, N_H, N_W, OWIDTH, N_BLOCKS, WORKLOAD, CHUNK_BLOCKS, `SC_SEED);
        $fwrite(trace_file, "LADDER");
        for (int i = 0; i < N_LADDER; i++) $fwrite(trace_file, " %0d", LADDER[i]);
        $fwrite(trace_file, "\n");
        for (int b = 0; b < N_BLOCKS; b++) begin
            $fwrite(trace_file, "BLOCK %0d %0d %0d %0d\nL", b, cyc[b], (b % CHUNK_BLOCKS) == 0, gen_start[b]);
            for (int h = 0; h < N_H; h++) $fwrite(trace_file, " %0d", lrow[b][h]);
            $fwrite(trace_file, "\nAQ");
            for (int i = 0; i < N_H*K; i++) $fwrite(trace_file, " %0d", aq[b][i]);
            $fwrite(trace_file, "\nAMAG");
            for (int i = 0; i < N_H*K; i++) $fwrite(trace_file, " %0d", boundary(aq[b][i]));
            $fwrite(trace_file, "\nASIGN");
            for (int i = 0; i < N_H*K; i++) $fwrite(trace_file, " %0d", asg[b][i]);
            $fwrite(trace_file, "\nWQ");
            for (int i = 0; i < N_W*K; i++) $fwrite(trace_file, " %0d", wq[b][i]);
            $fwrite(trace_file, "\nWMAG");
            for (int i = 0; i < N_W*K; i++) $fwrite(trace_file, " %0d", boundary(wq[b][i]));
            $fwrite(trace_file, "\nWSIGN");
            for (int i = 0; i < N_W*K; i++) $fwrite(trace_file, " %0d", wsg[b][i]);
            $fwrite(trace_file, "\n");
        end
    endtask

    // Generation controls for edge e: block b's cycles occupy edges
    // gen_start[b] .. gen_start[b] + cyc[b] - 1; loads and block_start on the first.
    int next_blk = 0;
    task automatic drive_gen(input int e);
        {load_a, load_w, load_a_sign, load_w_sign} = 4'b0000;
        block_start = 1'b0;
        slice_start = 1'b0;
        rng_en = (e < total_gen);
        if (next_blk < N_BLOCKS && e == gen_start[next_blk]) begin
            apply_block(next_blk);
            {load_a, load_w, load_a_sign, load_w_sign} = 4'b1111;
            block_start = 1'b1;
            slice_start = (next_blk % CHUNK_BLOCKS) == 0;
            next_blk++;
        end
    endtask

    initial begin
        assert (K == 8 && M == 16) else $fatal(1, "C-BSG needs K = 8, M = 16");
        assert (N_BLOCKS > 0 && N_BLOCKS * K * 128 < (1 << (OWIDTH - 1)))
            else $fatal(1, "SC_BATCHES=%0d: |acc| <= 128 * 8 * blocks must stay below 2^%0d",
                        N_BLOCKS, OWIDTH - 1);
        assert (CHUNK_BLOCKS > 0) else $fatal(1, "CBSG_CHUNK_BLOCKS must be positive");

        seed_state = `SC_SEED;
        void'($urandom(seed_state));
        draw_workload();
        assert (total_gen >= 2) else $fatal(1, "workload shorter than the 2-edge pipeline fill");

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);

        trace_file = $fopen("cbsg_rg_streaming_rtl.txt", "w");
        assert (trace_file != 0) else $fatal(1, "cannot open cbsg_rg_streaming_rtl.txt");
        write_trace_blocks();

        // ---- prologue: generation edges 0 and 1 fill the 2-edge pipeline ----
        drive_gen(0);
        @(posedge clk);
        @(negedge clk);
        drive_gen(1);
        @(posedge clk);
        // As in power_payn_array.sv: mac_en rises right after this posedge for
        // setup margin on its ICG enable; the first accumulating edge is edge 2.
        mac_en = 1'b1;
        @(negedge clk);

        // ---- SAIF window: MAC edges 2 .. total_gen + 1 ----
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        monitor_x = 1'b1;
        $toggle_start;
        for (int e = 2; e <= total_gen + 1; e++) begin
            drive_gen(e);
            @(posedge clk);
            @(negedge clk);
        end
        assert (next_blk == N_BLOCKS) else $fatal(1, "issued %0d of %0d blocks", next_blk, N_BLOCKS);
        mac_en = 1'b0;
        rng_en = 1'b0;
        {load_a, load_w, load_a_sign, load_w_sign} = 4'b0000;
        #1ps;
        $toggle_stop;
        monitor_x = 1'b0;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- drain outside the SAIF window: read column N_W-1-s before shift edge s ----
        // Launch and sample points follow the target's SDC, so a GL/SDF run sees
        // exactly the timing STA signed off:
        //   * shift_in rises at the negedge.  PAYN_SC_CSA_CBSG_RG (like
        //     PAYN_SC_CSA) sets INPUT_DELAY = 1.25 ns on every input, shift_in
        //     included, so STA checks setup and hold for an input arriving at
        //     the negedge.  A launch right after the posedge would be 1.25 ns
        //     earlier than STA's hold assumption at the flops shift_in feeds
        //     directly (the top's shift_q).  power_payn_array.sv also raises
        //     shift_in at the negedge before its first shift edge; its
        //     "align to a posedge" comment refers to an SDC with
        //     set_input_delay 0.05.
        //   * acc_out_east is sampled OUT_SAMPLE_NS before each shift edge, not at
        //     the negedge: STA (OUTPUT_DELAY = 0.05 ns) only guarantees the
        //     output settled by then, not half a period after the edge.
        // The first shift edge follows the last MAC edge directly, as in the
        // sequencer contract.
        acc_in_west = '0;
        for (int s = 0; s < N_W; s++) begin
            shift_in = 1'b1;
            #(PERIOD / 2.0 - OUT_SAMPLE_NS - (s == 0 ? 0.001 : 0.0));   // s = 0 starts 1 ps late
            for (int h = 0; h < N_H; h++)
                drain[h][N_W-1-s] = $signed(acc_out_east[h*OWIDTH +: OWIDTH]);
            @(posedge clk);
            @(negedge clk);
        end
        shift_in = 1'b0;

        $fwrite(trace_file, "WINDOW %0d %0d\n", total_gen, N_BLOCKS);
        $fwrite(trace_file, "DRAIN");
        for (int h = 0; h < N_H; h++)
            for (int v = 0; v < N_W; v++) $fwrite(trace_file, " %0d", drain[h][v]);
        $fwrite(trace_file, "\n");
        $fclose(trace_file);

        $display("PASS: CBSG-RG streaming SAIF captured; workload %s, %0d blocks, %0d window clocks (%0d MACs), drain dumped -> check_power_trace.py",
                 wl_name, N_BLOCKS, total_gen, N_BLOCKS*N_H*N_W*K);
        $finish;
    end
endmodule
