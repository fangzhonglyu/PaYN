`timescale 1ns/1ps

`include "common/clk_util.sv"

// Power bench for the full bitmod array (Raptor_Lake_HX), the whole-design point.
//
// Raptor_Lake_HX is a 4x4 grid of the 8x8 tiles measured by
// power/power_bitmod_tile.sv, plus the controller (booth term generation, group
// scale distribution) and the skew network -- 1024 PEs, 1024 useful MAC/cycle at
// INT8, 16x the throughput of the other baselines.  Because energy is reported
// per MAC, the row is still directly comparable to BP/BOS/PAYN_SC; only the
// absolute power and area are 16x larger.
//
// Unlike the tile bench, operand decode IS inside the DUT here, so this number
// carries the full cost of the datatype machinery.  Tile vs array is therefore
// the same split PaYN reports as SC_INNER_PE vs PAYN_SC.
//
// Methodology matches power/power_bitmod_tile.sv: negedge launch, resetless
// state flushed by two dummy `fin` groups (real traffic, nothing forced), drain
// taken outside the SAIF window, X on any drain rail during the window fatal.

`ifndef GL_SIM
`include "baselines/bitmod/bitmod_array.sv"
`endif

`ifndef BITMOD_GL_DUT
`define BITMOD_GL_DUT Raptor_Lake_HX
`endif

// Datatype mode: 1 = S_F4_F3, 2 = S_I6, 3 = S_I8.  Beats per element = MODE+1.
`ifndef BITMOD_MODE
`define BITMOD_MODE 3
`endif
`ifndef BITMOD_GROUP_ELEMS
`define BITMOD_GROUP_ELEMS 32
`endif
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
    localparam int  TILE_WIDTH   = 4;
    localparam int  PE_WIDTH     = 8 * TILE_WIDTH;   // 32 PE rows / cols
    localparam logic [1:0] MODE  = 2'(`BITMOD_MODE);
    localparam int  BEATS        = `BITMOD_MODE + 1;
    localparam int  STIM_CYCLES  = `STIM_CYCLES_N;

    localparam int  K_PER_GROUP_ELEM_COUNT = `BITMOD_GROUP_ELEMS;
    localparam int  K_ELEM_COUNT_RAW       = STIM_CYCLES / BEATS;
    localparam int  K_GROUP_COUNT          =
        (K_ELEM_COUNT_RAW / K_PER_GROUP_ELEM_COUNT) > 0
            ? (K_ELEM_COUNT_RAW / K_PER_GROUP_ELEM_COUNT) : 1;
    localparam int  K_ELEM_COUNT = K_GROUP_COUNT * K_PER_GROUP_ELEM_COUNT;
    localparam int  K_LANE_COUNT = 4 * K_ELEM_COUNT;

    localparam real PERIOD     = `ASTRAEA_CLK_PERIOD_NS;
    localparam int  MAC_TOTAL  = PE_WIDTH * PE_WIDTH * K_LANE_COUNT;
    localparam int  MAC_CYCLES = K_ELEM_COUNT * BEATS;

    logic clk, reset, timeout;
    logic arstn;
    assign arstn = ~reset;

    logic [1:0]                  mode;
    logic                        i_vld, i_rdy;
    logic [3:0][7:0][3:0][15:0]  i_a;
    logic [3:0][7:0][3:0][7:0]   i_w;
    logic                        i_grp_vld, i_grp_rdy, i_grp_fin;
    logic [3:0][7:0][7:0]        i_grp_w_scale;
    logic [3:0][7:0][2:0]        i_grp_w_special_value_id;
    logic [31:0]                 i_grp_w_elem_count_m1;

    logic [3:0]                  o_drain_vld;
    logic [3:0][7:0][28:0]       o_drain_dat;

    bit  monitor_x = 1'b0;
    bit  saif_open = 1'b0;
    bit  dummy_reset;
    int  window_cycles = 0;
    int  seed_state;

    ClkUtils #(.TIMEOUT(STIM_CYCLES + 8192)) clk_utils (.clk, .reset, .timeout);

    always @(o_drain_dat)
        if (monitor_x && $isunknown(o_drain_dat))
            $fatal(1, "[X-FAIL] bitmod array drain rail entered X during SAIF");

`ifdef GL_SIM
    `BITMOD_GL_DUT dut (
        .o_drain_vld              (o_drain_vld),
        .o_drain_dat              (o_drain_dat),
        .clk                      (clk),
        .arstn                    (arstn),
        .mode                     (mode),
        .i_vld                    (i_vld),
        .i_rdy                    (i_rdy),
        .i_a                      (i_a),
        .i_w                      (i_w),
        .i_grp_vld                (i_grp_vld),
        .i_grp_fin                (i_grp_fin),
        .i_grp_rdy                (i_grp_rdy),
        .i_grp_w_scale            (i_grp_w_scale),
        .i_grp_w_special_value_id (i_grp_w_special_value_id),
        .i_grp_w_elem_count_m1    (i_grp_w_elem_count_m1)
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
    Raptor_Lake_HX dut (.*);
`endif

    // ---- operand storage ---------------------------------------------------
    logic [PE_WIDTH-1:0][15:0] a_lane [K_LANE_COUNT];
    logic [PE_WIDTH-1:0][7:0]  w_lane [K_LANE_COUNT];
    logic [PE_WIDTH-1:0][7:0]  scale  [K_GROUP_COUNT];
    logic [PE_WIDTH-1:0][PE_WIDTH-1:0][28:0] actual;

    task automatic randomize_operands();
        for (int k = 0; k < K_LANE_COUNT; ++k)
            for (int p = 0; p < PE_WIDTH; ++p) begin
                a_lane[k][p] = 16'($urandom);
                w_lane[k][p] = 8'($urandom);
            end
        for (int g = 0; g < K_GROUP_COUNT; ++g)
            for (int p = 0; p < PE_WIDTH; ++p) scale[g][p] = 8'($urandom);
    endtask

    // ---- progress counters -------------------------------------------------
    int elem_idx, group_idx, got_drain;
    int drain_count [TILE_WIDTH];
    int drain_inc;

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            elem_idx  <= 0;
            group_idx <= 0;
            got_drain <= 0;
            for (int tc = 0; tc < TILE_WIDTH; ++tc) drain_count[tc] <= 0;
        end else begin
            if (~dummy_reset && (elem_idx  < K_ELEM_COUNT)  && i_vld     && i_rdy)
                elem_idx  <= elem_idx + 1;
            if (~dummy_reset && (group_idx < K_GROUP_COUNT) && i_grp_vld && i_grp_rdy)
                group_idx <= group_idx + 1;

            // All four tile columns can drain in the same cycle, so the beat
            // count has to accumulate across them before being committed once.
            drain_inc = 0;
            for (int tc = 0; tc < TILE_WIDTH; ++tc)
                if (~dummy_reset && o_drain_vld[tc]) begin
                    drain_inc += 8;
                    for (int pc = 0; pc < 8; ++pc)
                        actual[drain_count[tc]][8*tc+pc] <= o_drain_dat[tc][pc];
                    drain_count[tc] <= (drain_count[tc] + 1) & (PE_WIDTH - 1);
                end
            got_drain <= got_drain + drain_inc;
        end
    end

    // Two dummy `fin` groups flush the resetless accumulators, the tile output
    // buffers, and the drain output registers.  See power_bitmod_tile.sv.
    task automatic issue_dummy_group();
        i_grp_vld             = 1'b1;
        i_grp_fin             = 1'b1;
        i_grp_w_elem_count_m1 = 32'd0;
        do @(posedge clk); while (i_grp_rdy !== 1'b1);
        @(negedge clk);
        i_grp_vld             = 1'b0;
        i_grp_fin             = 1'b0;
        i_grp_w_elem_count_m1 = '0;

        i_vld = 1'b1;
        do @(posedge clk); while (i_rdy !== 1'b1);
        @(negedge clk);
        i_vld = 1'b0;

        repeat (128) @(posedge clk);
        @(negedge clk);
    endtask

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
        repeat (2) @(negedge clk);

        repeat (2) issue_dummy_group();

        #0.01;
        if ($isunknown(o_drain_dat))
            $fatal(1, "[X-FAIL] bitmod array drain rail unknown before SAIF");
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
        while (got_drain < PE_WIDTH * PE_WIDTH) begin
            i_vld                 = elem_idx  < K_ELEM_COUNT;
            i_grp_vld             = group_idx < K_GROUP_COUNT;
            i_grp_fin             = group_idx == (K_GROUP_COUNT - 1);
            i_grp_w_elem_count_m1 = i_grp_vld ? K_PER_GROUP_ELEM_COUNT - 1 : '0;

            for (int i = 0; i < TILE_WIDTH; ++i)
                for (int j = 0; j < 8; ++j) begin
                    automatic int p = 8*i + j;
                    for (int l = 0; l < 4; ++l) begin
                        i_a[i][j][l] = a_lane[4*elem_idx + l][p];
                        i_w[i][j][l] = w_lane[4*elem_idx + l][p];
                    end
                    i_grp_w_scale[i][j] = scale[group_idx][p];
                end

            @(posedge clk);
            @(negedge clk);
            if (saif_open) window_cycles++;

`ifndef BITMOD_DRAIN_IN_WINDOW
            if (saif_open && (o_drain_vld !== 4'b0)) begin
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

        nonzero_drains = 0;
        for (int i = 0; i < PE_WIDTH; ++i)
            for (int j = 0; j < PE_WIDTH; ++j) begin
                if ($isunknown(actual[i][j]))
                    $fatal(1, "[FUNC-FAIL] drained accumulator [%0d][%0d] is X: %h",
                           i, j, actual[i][j]);
                if (actual[i][j] !== '0) nonzero_drains++;
            end
        if (nonzero_drains == 0)
            $fatal(1, "[FUNC-FAIL] every drained accumulator is zero -- the array did no work");

        $display("PASS: bitmod array power SAIF captured; mode=%0d beats=%0d, %0d MAC cycles in window (%0d total), %0d useful MAC, %0d/%0d drains nonzero",
                 MODE, BEATS, window_cycles, MAC_CYCLES, MAC_TOTAL,
                 nonzero_drains, PE_WIDTH * PE_WIDTH);
        $display("PASS: useful throughput = %0d MAC/cycle", MAC_TOTAL / MAC_CYCLES);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
