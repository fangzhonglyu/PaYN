`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power bench for the bitmod 8x8 PE tile (migrated baseline).
//
// The tile is the throughput match for the other baselines: 64 PEs, each
// retiring 4 K-lane products over (MODE+1) beats, so at INT8 it is 64 useful
// MAC/cycle at 400 MHz -- identical to BP_ARRAY, BOS_ARRAY and PAYN_SC.
//
// Methodology follows designs/baselines/binary_os/power/power_binary_os_array.sv:
//   * stimulus launched at the NEGEDGE so routed clock insertion cannot race it
//   * the accumulator drain is taken OUTSIDE the SAIF window (drain-excluded
//     energy, matching the accepted headline numbers).  Set
//     +define+BITMOD_DRAIN_IN_WINDOW to fold the 8 drain beats back in.
//   * X on the drain rail during the window is fatal
//
// Two deliberate divergences from the other benches, both documented in
// doc/results.md because they affect how the row may be read:
//
//   1. The DUT is the tile only.  Operand decode (booth term generation, group
//      scale distribution, skew) lives in `controller`, which this bench
//      instantiates OUTSIDE the toggle region as the stimulus source -- exactly
//      as bitmod's own tb_tile_power does.  The tile number therefore excludes
//      operand decode, the way an array-only number would.  BITMOD_ARRAY
//      (Raptor_Lake_HX) is the whole-design point that includes it.
//   2. The power workload uses full-range random operands and is NOT
//      output-checked in-window.  The tile accumulates in a 23b-mantissa /6b-exp
//      float format whose reference model only closes for the restricted
//      +-1.0-activation / 3-bit-weight encoding, which is a much lower-activity
//      workload and would not be a fair power stimulus.  This bench asserts
//      X-freedom on the drain rail plus a defined, non-all-zero drained
//      accumulator matrix, which is weaker than the cycle-by-cycle golden
//      comparison the other benches do.  Golden checking instead runs as the
//      target's RTL_PREFLIGHT_CMD, designs/baselines/bitmod/tb/test_bitmod_tile.sv,
//      which must pass before any gate-level power run.
//
// Startup obeys the design's documented contract: a dummy `fin` group is issued
// first to zero the tile output buffers and PE accumulators, so the resetless
// accumulate flops are flushed by real traffic before the window opens.

`ifndef GL_SIM
`include "baselines/bitmod/bitmod_tile.sv"
`endif
// The controller is the stimulus generator in both RTL and GL runs: under
// GL_SIM the netlist supplies `tile` only, so this must stay outside the guard.
`include "baselines/bitmod/bitmod_ctrl.sv"

`ifndef BITMOD_GL_DUT
`define BITMOD_GL_DUT tile
`endif

// Tile shape as instantiated in Raptor_Lake_HX (4x4 grid of these).
`ifndef BITMOD_COL_LEN
`define BITMOD_COL_LEN 8
`endif
// Datatype mode: 1 = S_F4_F3, 2 = S_I6, 3 = S_I8.  Beats per element = MODE+1.
`ifndef BITMOD_MODE
`define BITMOD_MODE 3
`endif
// Weights per group along K.  bitmod's paper-recommended group size is 128
// K-elements = 32 tb elements x 4 lanes.
`ifndef BITMOD_GROUP_ELEMS
`define BITMOD_GROUP_ELEMS 32
`endif
// Cycles of MAC work inside the SAIF window.  Elements are derived from this so
// the window length matches the other baselines' STIM_CYCLES_N.
`ifndef STIM_CYCLES_N
`define STIM_CYCLES_N 4096
`endif
`ifndef BITMOD_SEED
`define BITMOD_SEED 32'hDEAD_BEEF
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int  COL_LEN      = `BITMOD_COL_LEN;
    localparam int  ROW_LEN      = 8;
    localparam logic [1:0] MODE  = 2'(`BITMOD_MODE);
    localparam int  BEATS        = `BITMOD_MODE + 1;
    localparam int  STIM_CYCLES  = `STIM_CYCLES_N;

    // Elements are consumed one per beat, BEATS beats per element.
    localparam int  K_PER_GROUP_ELEM_COUNT = `BITMOD_GROUP_ELEMS;
    localparam int  K_ELEM_COUNT_RAW       = STIM_CYCLES / BEATS;
    localparam int  K_GROUP_COUNT          =
        (K_ELEM_COUNT_RAW / K_PER_GROUP_ELEM_COUNT) > 0
            ? (K_ELEM_COUNT_RAW / K_PER_GROUP_ELEM_COUNT) : 1;
    localparam int  K_ELEM_COUNT = K_GROUP_COUNT * K_PER_GROUP_ELEM_COUNT;
    localparam int  K_LANE_COUNT = 4 * K_ELEM_COUNT;

    localparam int  LANE_ROWS = 4 * ROW_LEN;
    localparam int  LANE_COLS = 4 * COL_LEN;
    localparam real PERIOD    = `ASTRAEA_CLK_PERIOD_NS;

    // Useful work: every PE consumes all 4 lanes of every element.
    localparam int  MAC_TOTAL  = ROW_LEN * COL_LEN * K_LANE_COUNT;
    localparam int  MAC_CYCLES = K_ELEM_COUNT * BEATS;

    logic clk, reset, timeout;
    logic arstn;
    assign arstn = ~reset;

    logic [1:0] mode;

    // raw side (bench -> controller)
    logic                       i_vld, i_rdy;
    logic [LANE_ROWS-1:0][15:0] i_a;
    logic [LANE_COLS-1:0][7:0]  i_w;
    logic                       i_grp_vld, i_grp_rdy, i_grp_fin;
    logic [COL_LEN-1:0][7:0]    i_grp_w_scale;
    logic [COL_LEN-1:0][2:0]    i_grp_w_special_value_id;
    logic [31:0]                i_grp_w_elem_count_m1;

    // encoded side (controller -> tile)
    logic                       enc_vld, enc_fin, enc_last;
    logic                       enc_vld_first_elem, enc_vld_first_group;
    logic [LANE_ROWS-1:0][15:0] enc_a;
    logic [LANE_COLS-1:0][3:0]  enc_w_sem;
    logic [2:0]                 enc_w_bsig;
    logic [COL_LEN-1:0][7:0]    enc_w_scale;

    logic                    o_drain_vld_ahead1;
    logic [COL_LEN-1:0][28:0] o_drain_row;

    bit  monitor_x  = 1'b0;
    bit  saif_open  = 1'b0;
    bit  dummy_reset;
    int  window_cycles = 0;
    int  seed_state;

    ClkUtils #(.TIMEOUT(STIM_CYCLES + 4096)) clk_utils (.clk, .reset, .timeout);

    // ---- stimulus source: the design's own term generator, outside the SAIF --
    controller #(.TILE_WIDTH(1)) enc (
        .clk                        (clk),
        .arstn                      (arstn),
        .mode                       (mode),

        .i_vld                      (i_vld),
        .i_rdy                      (i_rdy),
        .o_vld                      (enc_vld),
        .o_vld_first_elem           (enc_vld_first_elem),
        .o_vld_first_group          (enc_vld_first_group),
        .o_fin                      (enc_fin),
        .o_last                     (enc_last),

        .i_a                        (i_a),
        .i_w                        (i_w),

        .i_grp_vld                  (i_grp_vld),
        .i_grp_rdy                  (i_grp_rdy),
        .i_grp_fin                  (i_grp_fin),
        .i_grp_w_scale              (i_grp_w_scale),
        .i_grp_w_special_value_id   (i_grp_w_special_value_id),
        .i_grp_w_elem_count_m1      (i_grp_w_elem_count_m1),

        .o_a                        (enc_a),
        .o_w_sem                    (enc_w_sem),
        .o_w_bsig                   (enc_w_bsig),
        .o_w_scale                  (enc_w_scale)
    );

    logic                       enc_vld_d, enc_fin_d, enc_last_d;
    logic                       enc_vld_first_elem_d, enc_vld_first_group_d;
    logic [LANE_ROWS-1:0][15:0] enc_a_d;
    logic [LANE_COLS-1:0][3:0]  enc_w_sem_d;
    logic [2:0]                 enc_w_bsig_d;
    logic [COL_LEN-1:0][7:0]    enc_w_scale_d;

    // NEGEDGE relaunch of the encoder outputs.
    //
    // The controller is clocked on the same posedge as the DUT, so its outputs
    // launch at the capture edge.  Upstream's bench covers that with a 50 ps
    // transport delay, which only survives if routed clock insertion is smaller
    // than 50 ps: at 2.5 ns this netlist produced ~98k $setup violations
    // (data 31 ps before CK against a 44 ps requirement), the notifiers injected
    // X, and the drained accumulators came back unknown.
    //
    // Re-registering on the negedge gives the DUT a full half cycle of setup
    // while delivering the same value at the same capture edge, so cycle
    // semantics are unchanged and the launch is insertion-independent.  This is
    // the methodology the other power benches already use.
    always @(negedge clk) begin
        enc_vld_d             <= enc_vld;
        enc_fin_d             <= enc_fin;
        enc_last_d            <= enc_last;
        enc_vld_first_elem_d  <= enc_vld_first_elem;
        enc_vld_first_group_d <= enc_vld_first_group;
        enc_a_d               <= enc_a;
        enc_w_sem_d           <= enc_w_sem;
        enc_w_bsig_d          <= enc_w_bsig;
        enc_w_scale_d         <= enc_w_scale;
    end

    always @(o_drain_row)
        if (monitor_x && $isunknown(o_drain_row))
            $fatal(1, "[X-FAIL] bitmod tile drain rail entered X during SAIF: %h",
                   o_drain_row);

`ifdef GL_SIM
    `BITMOD_GL_DUT dut (
        .clk                (clk),
        .arstn              (arstn),
        .i_drain_vld_ahead1 (1'b0),
        .i_drain_row        ('0),
        .o_drain_vld_ahead1 (o_drain_vld_ahead1),
        .o_drain_row        (o_drain_row),
        .i_vld              (enc_vld_d),
        .i_vld_first_elem   (enc_vld_first_elem_d),
        .i_vld_first_group  (enc_vld_first_group_d),
        .i_fin              (enc_fin_d),
        .i_last             (enc_last_d),
        .i_a                (enc_a_d),
        .i_w_sem            (enc_w_sem_d),
        .i_w_bsig           (enc_w_bsig_d),
        .i_w_scale          (enc_w_scale_d),
        .o_vld              (), .o_fin  (), .o_last (), .o_a (),
        .o_w_sem            (), .o_w_bsig (), .o_w_scale ()
    );
    initial begin
`ifndef NO_SDF
`ifdef SDF_FILE
        $display("[INFO] $sdf_annotate(`SDF_FILE, dut)");
        $sdf_annotate(`SDF_FILE, dut);
`endif
`endif
    end
`else
    tile #(.COL_LEN(COL_LEN)) dut (
        .clk                (clk),
        .arstn              (arstn),
        .i_drain_vld_ahead1 (1'b0),
        .i_drain_row        ('0),
        .o_drain_vld_ahead1 (o_drain_vld_ahead1),
        .o_drain_row        (o_drain_row),
        .i_vld              (enc_vld_d),
        .i_vld_first_elem   (enc_vld_first_elem_d),
        .i_vld_first_group  (enc_vld_first_group_d),
        .i_fin              (enc_fin_d),
        .i_last             (enc_last_d),
        .i_a                (enc_a_d),
        .i_w_sem            (enc_w_sem_d),
        .i_w_bsig           (enc_w_bsig_d),
        .i_w_scale          (enc_w_scale_d),
        .o_vld              (), .o_fin  (), .o_last (), .o_a (),
        .o_w_sem            (), .o_w_bsig (), .o_w_scale ()
    );
`endif

    // ---- operand storage ---------------------------------------------------
    logic [ROW_LEN-1:0][15:0]                    a_lane [K_LANE_COUNT];
    logic [COL_LEN-1:0][7:0]                     w_lane [K_LANE_COUNT];
    logic [COL_LEN-1:0][7:0]                     scale  [K_GROUP_COUNT];
    logic [ROW_LEN-1:0][COL_LEN-1:0][28:0]       actual;

    task automatic randomize_operands();
        for (int k = 0; k < K_LANE_COUNT; ++k) begin
            for (int p = 0; p < ROW_LEN; ++p) a_lane[k][p] = 16'($urandom);
            for (int p = 0; p < COL_LEN; ++p) w_lane[k][p] = 8'($urandom);
        end
        for (int g = 0; g < K_GROUP_COUNT; ++g)
            for (int p = 0; p < COL_LEN; ++p) scale[g][p] = 8'($urandom);
    endtask

    // ---- progress counters (mirror bitmod's tb_tile_power) ------------------
    int elem_idx, group_idx, got_drain, drain_count;
    logic drain_vld;

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            elem_idx    <= 0;
            group_idx   <= 0;
            got_drain   <= 0;
            drain_count <= 0;
            drain_vld   <= 1'b0;
        end else begin
            // vld leads the row data by one cycle, as the chip registers it
            drain_vld <= o_drain_vld_ahead1;

            if (~dummy_reset && (elem_idx  < K_ELEM_COUNT)  && i_vld     && i_rdy)
                elem_idx  <= elem_idx + 1;
            if (~dummy_reset && (group_idx < K_GROUP_COUNT) && i_grp_vld && i_grp_rdy)
                group_idx <= group_idx + 1;

            // single tile = forward_mine only: beats arrive in accum_row order
            if (~dummy_reset && drain_vld) begin
                got_drain <= got_drain + COL_LEN;
                for (int pc = 0; pc < COL_LEN; ++pc)
                    actual[drain_count][pc] <= o_drain_row[pc];
                drain_count <= (drain_count + 1) & (ROW_LEN - 1);
            end
        end
    end

    // One dummy `fin` group carrying a single element: the design's documented
    // startup contract for zeroing tile output buffers and PE accumulators.
    task automatic issue_dummy_group();
        i_grp_vld             = 1'b1;
        i_grp_fin             = 1'b1;
        i_grp_w_elem_count_m1 = 32'd0;
        // Sample ready AT the accepting edge, before it can fall as a result of
        // that same transaction.
        do @(posedge clk); while (i_grp_rdy !== 1'b1);
        @(negedge clk);
        i_grp_vld             = 1'b0;
        i_grp_fin             = 1'b0;
        i_grp_w_elem_count_m1 = '0;

        i_vld = 1'b1;
        do @(posedge clk); while (i_rdy !== 1'b1);
        @(negedge clk);
        i_vld = 1'b0;

        // Let the dummy fin transaction initialize and drain the tile.
        repeat (64) @(posedge clk);
        @(negedge clk);
    endtask

    // ---- main sequence ------------------------------------------------------
    int nonzero_drains;

    initial begin
        assert (MODE != 2'b00)
            else $fatal(1, "BITMOD_MODE=0 (S_DUMMY) is not a workload mode");
        assert (K_ELEM_COUNT > 0)
            else $fatal(1, "STIM_CYCLES_N too small for BEATS=%0d", BEATS);

        seed_state = `BITMOD_SEED;
        void'($urandom(seed_state));
        randomize_operands();

        mode                     = 2'b00;  // S_DUMMY
        i_vld                    = 1'b0;
        i_a                      = '0;
        i_w                      = '0;
        i_grp_vld                = 1'b0;
        i_grp_fin                = 1'b0;
        i_grp_w_scale            = '0;
        i_grp_w_special_value_id = '0;
        i_grp_w_elem_count_m1    = '0;
        dummy_reset              = 1'b1;

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();

        // Let routed reset trees satisfy recovery before the first transaction.
        repeat (2) @(negedge clk);

        // ---- startup contract: dummy fin groups flush the resetless state ----
        // Pass 1 zeroes the PE accumulators and the output-buffer RF, but the
        // drain output register captures that first (still-unknown) accumulator
        // read, so it ends the pass holding X.  Pass 2 drains the now-zeroed
        // buffer through it, leaving every resetless flop at a defined value
        // with real traffic only -- no forced/deposited nodes.
        repeat (2) issue_dummy_group();

        #0.01;
        if ($isunknown(o_drain_row))
            $fatal(1, "[X-FAIL] bitmod tile drain rail unknown before SAIF: %h",
                   o_drain_row);
        dummy_reset = 1'b0;
        monitor_x   = 1'b1;

        // ---- SAIF window ----------------------------------------------------
`ifdef GL_SIM
        $set_gate_level_monitoring("rtl_on");
`else
        // RTL runs feed SYN_SAIF_FILE.  Without the "sv" argument VCS skips
        // SystemVerilog-typed nets, and this design is entirely packed
        // `logic` arrays -- the SAIF would come out empty (header only).
        $set_gate_level_monitoring("rtl_on", "sv");
`endif
        $set_toggle_region(dut);
        $toggle_start;
        saif_open = 1'b1;

        mode = MODE;
        while (got_drain < ROW_LEN * COL_LEN) begin
            i_vld                 = elem_idx  < K_ELEM_COUNT;
            i_grp_vld             = group_idx < K_GROUP_COUNT;
            i_grp_fin             = group_idx == (K_GROUP_COUNT - 1);
            i_grp_w_elem_count_m1 = i_grp_vld ? K_PER_GROUP_ELEM_COUNT - 1 : '0;

            for (int p = 0; p < ROW_LEN; ++p)
                for (int l = 0; l < 4; ++l)
                    i_a[4*p+l] = a_lane[4*elem_idx+l][p];

            for (int p = 0; p < COL_LEN; ++p) begin
                for (int l = 0; l < 4; ++l)
                    i_w[4*p+l] = w_lane[4*elem_idx+l][p];
                i_grp_w_scale[p] = scale[group_idx][p];
            end

            @(posedge clk);
            @(negedge clk);
            if (saif_open) window_cycles++;

            // Close the window the moment the tile signals the first drain beat,
            // so drain activity is excluded from the measured energy.
`ifndef BITMOD_DRAIN_IN_WINDOW
            if (saif_open && o_drain_vld_ahead1) begin
                #0.01;
                $toggle_stop;
                saif_open = 1'b0;
                monitor_x = 1'b0;
            end
`endif
        end
        #0.01;

        if (saif_open) begin
            $toggle_stop;
            saif_open = 1'b0;
            monitor_x = 1'b0;
        end
        $toggle_report("dut.saif", 1.0e-12, "Top.dut");

        // ---- post-window sanity on the drained accumulators -----------------
        nonzero_drains = 0;
        for (int i = 0; i < ROW_LEN; ++i)
            for (int j = 0; j < COL_LEN; ++j) begin
                if ($isunknown(actual[i][j]))
                    $fatal(1, "[FUNC-FAIL] drained accumulator [%0d][%0d] is X: %h",
                           i, j, actual[i][j]);
                if (actual[i][j] !== '0) nonzero_drains++;
            end
        if (nonzero_drains == 0)
            $fatal(1, "[FUNC-FAIL] every drained accumulator is zero -- the tile did no work");

        $display("PASS: bitmod tile power SAIF captured; mode=%0d beats=%0d, %0d MAC cycles in window (%0d total), %0d useful MAC, %0d/%0d drains nonzero",
                 MODE, BEATS, window_cycles, MAC_CYCLES, MAC_TOTAL,
                 nonzero_drains, ROW_LEN * COL_LEN);
        $display("PASS: useful throughput = %0d MAC/cycle", MAC_TOTAL / MAC_CYCLES);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
