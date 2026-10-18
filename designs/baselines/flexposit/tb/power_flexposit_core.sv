`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power + output-checking bench for the FlexPosit core (designs/baselines/flexposit).
//
// Runs FP_TILES output-stationary GEMM tiles back to back through flexposit_core at one operating point
// (precision P, es) and checks every FP16 output lane against the bit-exact model's golden values
// (tools/gen_stim.py -> expect.mem).  The SAIF window opens before the first tile starts and closes after the
// last tile's readout: it holds the decode fill, the K products, the drain of the systolic skew and the
// row-by-row FP16 readout of every tile, so the energy is charged per useful MAC with all of that included.
//
// Operand buffering is outside the DUT, as in the BOS mesh: the bench instantiates the upstream input FIFOs of
// the FlexPosit top `mm` (rtl/act_fifo.v per row, rtl/fifo.v per column, unchanged) and preloads every tile
// before the window, so no FIFO ever runs dry.  The upstream global stall therefore never fires; the bench
// computes it exactly as rtl/mm_efficient.v does and fails if it ever would (the DUT's stall pin is tied low).
//
// Timing.  Every DUT input is launched at the NEGEDGE (control from the procedural code, FIFO outputs through a
// negedge register), so the routed gate DUT captures it at the next posedge with half a period of setup and the
// same cycle alignment as the upstream RTL, where the FIFO's registered dout feeds the array combinationally.
// Every DUT output is sampled at the POSEDGE (the value of the cycle that just ended): the FP16 lanes leave the
// stage register through the combinational FP16 converter and may settle late in the cycle.
//
// Stimulus header: `include "flexposit_stim.svh" (generated; pass +incdir+<dir>), which defines FP_N, FP_K,
// FP_P, FP_ES, FP_TILES, FP_WARMUP, FP_USEFUL_MACS and the absolute .mem paths.  The FP_WARMUP tiles run before
// the window (outputs still checked) so the resetless beat-FIFO storage holds data, not X, when the window opens.

`include "flexposit_stim.svh"

`ifndef GL_SIM
`include "baselines/flexposit/flexposit_core.sv"
`endif
`include "baselines/flexposit/rtl/fifo.v"
`include "baselines/flexposit/rtl/act_fifo.v"

`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif
// Idle cycles between one tile's `done` and the next tile's start (active low, as the upstream controller needs).
`ifndef FP_TILE_GAP
`define FP_TILE_GAP 2
`endif

module Top;
    localparam int N     = `FP_N;
    localparam int K     = `FP_K;
    localparam int P     = `FP_P;
    localparam int ES    = `FP_ES;
    localparam int W     = `FP_WARMUP;           // warm-up tiles, run and checked before the window
    localparam int T     = W + `FP_TILES;        // every tile the bench runs
    localparam int GAP   = `FP_TILE_GAP;
    localparam int LGN   = (N > 1) ? $clog2(N) : 1;
    localparam real PERIOD = `ASTRAEA_CLK_PERIOD_NS;
    localparam int ACT_DEPTH = T * K;
    localparam int W_DEPTH   = T * K * P;
    localparam int TILE_BOUND = (K + N) * P + 2 * N + 64;
    localparam int TIMEOUT_CYCLES = W_DEPTH + T * (TILE_BOUND + GAP) + 512;
    localparam longint USEFUL_MACS = `FP_USEFUL_MACS;   // the measured tiles (inside the window) only

    logic clk, reset, timeout;
    ClkUtils #(.TIMEOUT(TIMEOUT_CYCLES)) clk_utils (.clk, .reset, .timeout);
    // DUT reset (active low).  Gate level: ClkUtils' reset pulse, so the cell models see a real post-initialization
    // reset edge.  RTL: additionally held low from time 0 until that pulse, because the RTL's own non-synthesis
    // assertions read X state while rst is high, and VCS -xprop=tmerge fires them.
`ifdef GL_SIM
    wire rst_n = ~reset;
`else
    bit  reset_pulsed = 1'b0;
    always @(posedge reset) reset_pulsed = 1'b1;
    wire rst_n = ~reset && reset_pulsed;
`endif
    // The bench FIFOs leave reset only after the DUT's reset pulse: before it their read enables (DUT outputs)
    // are X and their underflow assertions would fire under -xprop=tmerge.
    bit  fifo_released = 1'b0;
    wire fifo_rst_n = rst_n && fifo_released;

    // ---------------- stimulus and golden values -------------------------------------------------------------
    logic [7:0]  act_mem   [T*N*K];
    logic [7:0]  w_mem     [T*N*K];
    logic [7:0]  scale_mem [T*N];
    logic [15:0] exp_mem   [T*N*N];

    // ---------------- bench-side operand buffers (upstream mm's FIFOs) ----------------------------------------
    logic             wr_en_act = 1'b0, wr_en_w = 1'b0;
    logic [7:0]       act_din [N];
    logic             w_din   [N];
    wire  [7:0]       act_dout [N];
    wire              w_dout   [N];
    wire  [N-1:0]     act_fifo_valid, act_fifo_empty, act_fifo_ready, act_fifo_underflow;
    wire  [N-1:0]     w_fifo_empty, w_fifo_ready, w_fifo_underflow;
    wire  [N-1:0]     active_row;
    wire  [N-1:1]     active_column;
    logic             active = 1'b0;
    // Column FIFO read demands: column 0's is `active` itself (the DUT exports columns 1..N-1, flexposit_core.sv).
    wire  [N-1:0]     col_demand = {active_column, active};

    genvar gi;
    generate
        for (gi = 0; gi < N; gi++) begin : g_buf
            act_fifo #(.WIDTH(8), .DEPTH(ACT_DEPTH)) u_act (
                .clk(clk), .rst(fifo_rst_n), .wr_en(wr_en_act), .rd_en(active_row[gi]), .precision(4'(P)),
                .din(act_din[gi]), .dout(act_dout[gi]), .wr_ready(act_fifo_ready[gi]), .full(),
                .empty(act_fifo_empty[gi]), .underflow(act_fifo_underflow[gi]),
                .act_out_valid(act_fifo_valid[gi]));
            fifo #(.WIDTH(1), .DEPTH(W_DEPTH)) u_w (
                .clk(clk), .rst(fifo_rst_n), .wr_en(wr_en_w), .rd_en(col_demand[gi]),
                .din(w_din[gi]), .dout(w_dout[gi]), .wr_ready(w_fifo_ready[gi]), .full(),
                .empty(w_fifo_empty[gi]), .underflow(w_fifo_underflow[gi]));
        end
    endgenerate

    // Negedge launch of the FIFO outputs into the DUT (same cycle alignment as the upstream direct connection).
    logic [N*8-1:0] dut_act_in    = '0;
    logic [N-1:0]   dut_act_valid = '0;
    logic [N-1:0]   dut_w_in      = '0;
    always @(negedge clk)
        for (int i = 0; i < N; i++) begin
            dut_act_in[i*8 +: 8] <= act_dout[i];
            dut_act_valid[i]     <= act_fifo_valid[i];
            dut_w_in[i]          <= w_dout[i];
        end

    // ---------------- DUT ------------------------------------------------------------------------------------
    logic [15:0]    k_reg = 16'(K);
    logic [3:0]     precision = 4'(P);
    logic [1:0]     posit_es = 2'(ES);
    logic [N*5-1:0] col_scale = '0;
    wire            done, compute_done, out_valid;
    wire  [LGN-1:0] out_row;
    wire  [N*16-1:0] out_data;

`ifdef GL_SIM
    flexposit_core dut (
`else
    flexposit_core #(.N(N)) dut (
`endif
        .clk(clk), .rst_n(rst_n), .stall(1'b0), .active(active), .k_reg(k_reg), .precision(precision),
        .posit_es(posit_es), .col_scale(col_scale), .act_in(dut_act_in), .act_valid_in(dut_act_valid),
        .w_in(dut_w_in), .out_ready(1'b1), .done(done), .compute_done(compute_done), .out_valid(out_valid),
        .out_row(out_row), .out_data(out_data), .active_row(active_row), .active_column(active_column));

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

    // ---------------- monitors (posedge: the value of the cycle that just ended) ------------------------------
    bit     armed = 1'b0;      // set after reset: before it the DUT state is X (and VCS -xprop=tmerge runs both
                               // branches of an if on X), so no monitor looks at the DUT
    bit     in_window = 1'b0;
    int     window_cycles = 0;
    int     tiles_done = 0;
    int     cur_tile = 0;
    int     rows_seen [T];
    int     lanes_checked = 0;
    int     lane_errors = 0;
    int     tile_start_cycle [T];
    int     tile_done_cycle  [T];
    int     cycle = 0;

    // The upstream stall expression (mm_efficient.v), with no streamer: it must never fire here.
    wire stall_mm = active && ((|(active_row & act_fifo_empty) & !wr_en_act) |
                               (|(col_demand & w_fifo_empty) & !wr_en_w));

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (in_window) window_cycles <= window_cycles + 1;
        if (armed && stall_mm)
            $fatal(1, "[FUNC-FAIL] the upstream stall would fire at cycle %0d (an operand FIFO ran dry)", cycle);
        if (in_window && $isunknown({done, compute_done, out_valid, active_row, active_column}))
            $fatal(1, "[X-FAIL] DUT control output unknown in the window at cycle %0d", cycle);
        if (in_window && $isunknown({active, col_scale, dut_act_in, dut_act_valid, dut_w_in}))
            $fatal(1, "[X-FAIL] DUT input unknown in the window at cycle %0d: act_in=%h act_valid=%b w_in=%b",
                   cycle, dut_act_in, dut_act_valid, dut_w_in);
        if (armed && out_valid) begin
            if ($isunknown({out_row, out_data}))
                $fatal(1, "[X-FAIL] FP16 output unknown at cycle %0d", cycle);
            if (cur_tile >= T) $fatal(1, "[FUNC-FAIL] output row after the last tile");
            for (int j = 0; j < N; j++) begin
                logic [15:0] got, want;
                got  = out_data[j*16 +: 16];
                want = exp_mem[(cur_tile*N + out_row)*N + j];
                if (got !== want) begin
                    lane_errors++;
                    if (lane_errors <= 20)
                        $display("[FUNC-FAIL] tile %0d row %0d lane %0d: got %h expected %h",
                                 cur_tile, out_row, j, got, want);
                end
                lanes_checked++;
            end
            if (out_row != LGN'(rows_seen[cur_tile]))
                $fatal(1, "[FUNC-FAIL] tile %0d: row %0d out of order (expected %0d)", cur_tile, out_row,
                       rows_seen[cur_tile]);
            rows_seen[cur_tile]++;
        end
        if (armed && done) begin
            if (rows_seen[cur_tile] != N)
                $fatal(1, "[FUNC-FAIL] tile %0d done after %0d of %0d rows", cur_tile, rows_seen[cur_tile], N);
            tile_done_cycle[cur_tile] = cycle;
            cur_tile++;
            tiles_done++;
        end
    end

    // ---------------- sequence -------------------------------------------------------------------------------
    // One tile: scales, then `active` for exactly K*P cycles (column 0's weight FIFO pops one bit per cycle while
    // active), then wait for the tile's `done` (all N rows read out), then the inter-tile gap.
    task automatic run_tile(input int t);
        for (int j = 0; j < N; j++) col_scale[j*5 +: 5] = scale_mem[t*N + j][4:0];
        @(negedge clk);
        tile_start_cycle[t] = cycle;
        active = 1'b1;                           // start_pulse latches P, es and the column scales
        repeat (K * P) @(negedge clk);
        active = 1'b0;
        while (tiles_done <= t) @(negedge clk);
        repeat (GAP) @(negedge clk);
    endtask

    task automatic load_operands();
        // Activations (one vector per cycle) and serialized weights (one bit per column per cycle, MSB first),
        // every tile in order, concurrently on the two write ports.
        fork
            begin
                for (int t = 0; t < T; t++)
                    for (int k = 0; k < K; k++) begin
                        for (int i = 0; i < N; i++) act_din[i] = act_mem[(t*N + i)*K + k];
                        wr_en_act = 1'b1;
                        @(negedge clk);
                    end
                wr_en_act = 1'b0;
            end
            begin
                for (int t = 0; t < T; t++)
                    for (int k = 0; k < K; k++)
                        for (int b = P - 1; b >= 0; b--) begin
                            for (int j = 0; j < N; j++) w_din[j] = w_mem[(t*N + j)*K + k][b];
                            wr_en_w = 1'b1;
                            @(negedge clk);
                        end
                wr_en_w = 1'b0;
            end
        join
    endtask

    initial begin
        $readmemh(`FP_ACT_MEM, act_mem);
        $readmemh(`FP_W_MEM, w_mem);
        $readmemh(`FP_SCALE_MEM, scale_mem);
        $readmemh(`FP_EXPECT_MEM, exp_mem);
        for (int i = 0; i < N; i++) begin act_din[i] = '0; w_din[i] = 1'b0; end
        for (int t = 0; t < T; t++) rows_seen[t] = 0;

        assert ($bits(dut.out_data) == N*16 && $bits(dut.act_in) == N*8 && $bits(dut.w_in) == N &&
                $bits(dut.active_column) == N-1)
            else $fatal(1, "DUT ports do not match FP_N=%0d", N);

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);
        if ($isunknown({done, compute_done, out_valid, active_row, active_column}))
            $fatal(1, "[X-FAIL] DUT control outputs unknown after reset");
        armed = 1'b1;
        fifo_released = 1'b1;
        repeat (2) @(negedge clk);

        load_operands();
        repeat (4) @(negedge clk);
        if ($isunknown({done, compute_done, out_valid, active_row, active_column}))
            $fatal(1, "[X-FAIL] DUT control outputs unknown before the window");

        // ---- warm-up tiles: write every entry of the resetless beat FIFOs before the window ----------------
        for (int t = 0; t < W; t++) run_tile(t);

        // ---- SAIF window ------------------------------------------------------------------------------------
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        $toggle_start;
        in_window = 1'b1;

        for (int t = W; t < T; t++) run_tile(t);
        @(negedge clk);

        in_window = 1'b0;
        $toggle_stop;
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        if (lane_errors != 0)
            $fatal(1, "[FUNC-FAIL] %0d of %0d FP16 lanes mismatched the bit-exact model", lane_errors, lanes_checked);
        if (lanes_checked != T*N*N)
            $fatal(1, "[FUNC-FAIL] checked %0d lanes, expected %0d", lanes_checked, T*N*N);
        for (int t = 0; t < T; t++)
            $display("INFO: tile %0d%s: start cycle %0d, done cycle %0d, %0d cycles", t, (t < W) ? " (warm-up)" : "",
                     tile_start_cycle[t], tile_done_cycle[t], tile_done_cycle[t] - tile_start_cycle[t]);
        $display("PASS: FlexPosit power SAIF captured + output-checked; P=%0d es=%0d N=%0d tiles=%0d K=%0d; %0d window cycles, %0d useful MAC, %0d FP16 lanes matched",
                 P, ES, N, T - W, K, window_cycles, USEFUL_MACS, lanes_checked);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
