`timescale 1ns/1ps

`include "common/clk_util.sv"

// Functional check for the bitmod tile against an independent integer reference.
//
// This is the golden-value counterpart to power/power_bitmod_tile.sv, which runs
// full-range random operands and can only assert X-freedom.  Ported from
// upstream's check_en path (bitmod tb_matmul.sv:334-369, 480-492).
//
// The reference only closes for the restricted encoding upstream uses:
//   * activations are +-1.0 in fp16   -> a_f16 = (bit << 15) | 16'h3C00
//   * weights are 3-bit magnitudes    -> w in [0, 7]
//   * group scales are small integers -> scale in [1, 3]
// so every product is exactly representable and the accumulation is an integer
// sum.  That makes it a correctness stimulus, NOT a power stimulus -- its
// activity is far below a real workload's, which is why the power bench does not
// use it.
//
// The DUT's accumulator is a 23-bit signed mantissa with a 6-bit exponent biased
// by 28, so the decoded value is mantissa * 2^(exp - 28).
//
// Wire this as RTL_PREFLIGHT_CMD on syn/targets/TSMC22/BITMOD_TILE so a
// functional regression blocks gate-level power measurement.

`include "baselines/bitmod/bitmod_tile.sv"
`include "baselines/bitmod/bitmod_ctrl.sv"

`ifndef BITMOD_COL_LEN
`define BITMOD_COL_LEN 8
`endif
`ifndef BITMOD_MODE
`define BITMOD_MODE 3
`endif
`ifndef BITMOD_GROUP_ELEMS
`define BITMOD_GROUP_ELEMS 32
`endif
`ifndef BITMOD_GROUPS
`define BITMOD_GROUPS 8
`endif
`ifndef BITMOD_SEED
`define BITMOD_SEED 32'h1234_5678
`endif
`ifndef ASTRAEA_CLK_PERIOD_NS
`define ASTRAEA_CLK_PERIOD_NS 2.5
`endif

module Top;
    localparam int  COL_LEN     = `BITMOD_COL_LEN;
    localparam int  ROW_LEN     = 8;
    localparam logic [1:0] MODE = 2'(`BITMOD_MODE);
    localparam int  BEATS       = `BITMOD_MODE + 1;

    localparam int  K_GROUP_COUNT          = `BITMOD_GROUPS;
    localparam int  K_PER_GROUP_ELEM_COUNT = `BITMOD_GROUP_ELEMS;
    localparam int  K_ELEM_COUNT = K_GROUP_COUNT * K_PER_GROUP_ELEM_COUNT;
    localparam int  K_LANE_COUNT = 4 * K_ELEM_COUNT;

    localparam int  LANE_ROWS = 4 * ROW_LEN;
    localparam int  LANE_COLS = 4 * COL_LEN;
    localparam real PERIOD    = `ASTRAEA_CLK_PERIOD_NS;

    logic clk, reset, timeout;
    logic arstn;
    assign arstn = ~reset;

    logic [1:0]                 mode;
    logic                       i_vld, i_rdy;
    logic [LANE_ROWS-1:0][15:0] i_a;
    logic [LANE_COLS-1:0][7:0]  i_w;
    logic                       i_grp_vld, i_grp_rdy, i_grp_fin;
    logic [COL_LEN-1:0][7:0]    i_grp_w_scale;
    logic [COL_LEN-1:0][2:0]    i_grp_w_special_value_id;
    logic [31:0]                i_grp_w_elem_count_m1;

    logic                       enc_vld, enc_fin, enc_last;
    logic                       enc_vld_first_elem, enc_vld_first_group;
    logic [LANE_ROWS-1:0][15:0] enc_a;
    logic [LANE_COLS-1:0][3:0]  enc_w_sem;
    logic [2:0]                 enc_w_bsig;
    logic [COL_LEN-1:0][7:0]    enc_w_scale;

    logic                     o_drain_vld_ahead1;
    logic [COL_LEN-1:0][28:0] o_drain_row;

    bit dummy_reset;
    int seed_state;

    ClkUtils #(.TIMEOUT(K_ELEM_COUNT * BEATS + 8192)) clk_utils (.clk, .reset, .timeout);

    controller #(.TILE_WIDTH(1)) enc (
        .clk (clk), .arstn (arstn), .mode (mode),
        .i_vld (i_vld), .i_rdy (i_rdy),
        .o_vld (enc_vld),
        .o_vld_first_elem (enc_vld_first_elem),
        .o_vld_first_group (enc_vld_first_group),
        .o_fin (enc_fin), .o_last (enc_last),
        .i_a (i_a), .i_w (i_w),
        .i_grp_vld (i_grp_vld), .i_grp_rdy (i_grp_rdy), .i_grp_fin (i_grp_fin),
        .i_grp_w_scale (i_grp_w_scale),
        .i_grp_w_special_value_id (i_grp_w_special_value_id),
        .i_grp_w_elem_count_m1 (i_grp_w_elem_count_m1),
        .o_a (enc_a), .o_w_sem (enc_w_sem),
        .o_w_bsig (enc_w_bsig), .o_w_scale (enc_w_scale)
    );

    logic                       enc_vld_d, enc_fin_d, enc_last_d;
    logic                       enc_vld_first_elem_d, enc_vld_first_group_d;
    logic [LANE_ROWS-1:0][15:0] enc_a_d;
    logic [LANE_COLS-1:0][3:0]  enc_w_sem_d;
    logic [2:0]                 enc_w_bsig_d;
    logic [COL_LEN-1:0][7:0]    enc_w_scale_d;

    // Same negedge relaunch as the power bench, so RTL and gate runs see the
    // identical stimulus timing.
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

    tile #(.COL_LEN(COL_LEN)) dut (
        .clk (clk), .arstn (arstn),
        .i_drain_vld_ahead1 (1'b0), .i_drain_row ('0),
        .o_drain_vld_ahead1 (o_drain_vld_ahead1), .o_drain_row (o_drain_row),
        .i_vld (enc_vld_d),
        .i_vld_first_elem (enc_vld_first_elem_d),
        .i_vld_first_group (enc_vld_first_group_d),
        .i_fin (enc_fin_d), .i_last (enc_last_d),
        .i_a (enc_a_d), .i_w_sem (enc_w_sem_d),
        .i_w_bsig (enc_w_bsig_d), .i_w_scale (enc_w_scale_d),
        .o_vld (), .o_fin (), .o_last (), .o_a (),
        .o_w_sem (), .o_w_bsig (), .o_w_scale ()
    );

    // ---- restricted-encoding operands + integer reference -------------------
    int a_bit  [ROW_LEN][K_LANE_COUNT];   // 0 -> +1.0, 1 -> -1.0
    int w_mag  [K_LANE_COUNT][COL_LEN];   // 3-bit magnitude
    int scale_i[K_GROUP_COUNT][COL_LEN];  // small integer group scale
    logic [ROW_LEN-1:0][15:0] a_f16 [K_LANE_COUNT];
    int expected [ROW_LEN][COL_LEN];
    logic [ROW_LEN-1:0][COL_LEN-1:0][28:0] actual;

    int elem_idx, group_idx, got_drain, drain_count;
    logic drain_vld;

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            elem_idx <= 0; group_idx <= 0; got_drain <= 0; drain_count <= 0;
            drain_vld <= 1'b0;
        end else begin
            drain_vld <= o_drain_vld_ahead1;
            if (~dummy_reset && (elem_idx  < K_ELEM_COUNT)  && i_vld     && i_rdy)
                elem_idx  <= elem_idx + 1;
            if (~dummy_reset && (group_idx < K_GROUP_COUNT) && i_grp_vld && i_grp_rdy)
                group_idx <= group_idx + 1;
            if (~dummy_reset && drain_vld) begin
                got_drain <= got_drain + COL_LEN;
                for (int pc = 0; pc < COL_LEN; ++pc)
                    actual[drain_count][pc] <= o_drain_row[pc];
                drain_count <= (drain_count + 1) & (ROW_LEN - 1);
            end
        end
    end

    task automatic issue_dummy_group();
        i_grp_vld = 1'b1; i_grp_fin = 1'b1; i_grp_w_elem_count_m1 = 32'd0;
        do @(posedge clk); while (i_grp_rdy !== 1'b1);
        @(negedge clk);
        i_grp_vld = 1'b0; i_grp_fin = 1'b0; i_grp_w_elem_count_m1 = '0;
        i_vld = 1'b1;
        do @(posedge clk); while (i_rdy !== 1'b1);
        @(negedge clk);
        i_vld = 1'b0;
        repeat (64) @(posedge clk);
        @(negedge clk);
    endtask

    int errors;
    real actual_real;

    initial begin
        seed_state = `BITMOD_SEED;
        void'($urandom(seed_state));

        for (int i = 0; i < ROW_LEN; ++i)
            for (int k = 0; k < K_LANE_COUNT; ++k) begin
                a_bit[i][k]   = $urandom & 1;
                a_f16[k][i]   = 16'((a_bit[i][k] << 15) | 16'h3C00);  // +-1.0
            end
        for (int j = 0; j < COL_LEN; ++j) begin
            for (int k = 0; k < K_LANE_COUNT; ++k) w_mag[k][j] = $urandom & 7;
            for (int g = 0; g < K_GROUP_COUNT; ++g) scale_i[g][j] = ($urandom % 3) + 1;
        end

        // Golden: every K lane of every group, sign from the activation bit.
        for (int i = 0; i < ROW_LEN; ++i)
            for (int j = 0; j < COL_LEN; ++j) begin
                automatic int k = 0;
                expected[i][j] = 0;
                for (int g = 0; g < K_GROUP_COUNT; ++g)
                    for (int c = 0; c < 4 * K_PER_GROUP_ELEM_COUNT; ++c) begin
                        expected[i][j] +=
                            (1 - 2*a_bit[i][k]) * w_mag[k][j] * scale_i[g][j];
                        ++k;
                    end
            end

        mode = 2'b00;
        i_vld = 1'b0; i_a = '0; i_w = '0;
        i_grp_vld = 1'b0; i_grp_fin = 1'b0;
        i_grp_w_scale = '0; i_grp_w_special_value_id = '0;
        i_grp_w_elem_count_m1 = '0;
        dummy_reset = 1'b1;

        clk_utils.set_clock(PERIOD);
        clk_utils.do_reset();
        repeat (2) @(negedge clk);
        repeat (2) issue_dummy_group();
        dummy_reset = 1'b0;

        mode = MODE;
        while (got_drain < ROW_LEN * COL_LEN) begin
            i_vld                 = elem_idx  < K_ELEM_COUNT;
            i_grp_vld             = group_idx < K_GROUP_COUNT;
            i_grp_fin             = group_idx == (K_GROUP_COUNT - 1);
            i_grp_w_elem_count_m1 = i_grp_vld ? K_PER_GROUP_ELEM_COUNT - 1 : '0;

            for (int p = 0; p < ROW_LEN; ++p)
                for (int l = 0; l < 4; ++l)
                    i_a[4*p+l] = a_f16[4*elem_idx+l][p];
            for (int p = 0; p < COL_LEN; ++p) begin
                for (int l = 0; l < 4; ++l)
                    i_w[4*p+l] = 8'(w_mag[4*elem_idx+l][p]);
                i_grp_w_scale[p] = 8'(scale_i[group_idx][p]);
            end

            @(posedge clk);
            @(negedge clk);
        end

        errors = 0;
        for (int i = 0; i < ROW_LEN; ++i)
            for (int j = 0; j < COL_LEN; ++j) begin
                if ($isunknown(actual[i][j])) begin
                    $display("[FUNC-FAIL] acc[%0d][%0d] is X: %h", i, j, actual[i][j]);
                    errors++;
                    continue;
                end
                // mantissa is a signed 2's-complement value scaled by 2^(exp-28)
                actual_real = $itor($signed(actual[i][j][22:0]))
                              * (2.0 ** ($itor(actual[i][j][28:23]) - 28.0));
                if (actual_real != $itor(expected[i][j])) begin
                    $display("[FUNC-FAIL] acc[%2d][%2d] expected=%0d actual=%f (%h)",
                             i, j, expected[i][j], actual_real, actual[i][j]);
                    errors++;
                end
            end

        if (errors != 0)
            $fatal(1, "[FUNC-FAIL] %0d of %0d accumulators mismatched",
                   errors, ROW_LEN * COL_LEN);

        $display("PASS: bitmod tile output-checked; mode=%0d, %0d groups x %0d elems, %0d K lanes, %0d/%0d accumulators exact",
                 MODE, K_GROUP_COUNT, K_PER_GROUP_ELEM_COUNT, K_LANE_COUNT,
                 ROW_LEN * COL_LEN, ROW_LEN * COL_LEN);
        $finish;
    end

    always @(posedge timeout) $fatal(1, "FAIL: simulation timeout");
endmodule
