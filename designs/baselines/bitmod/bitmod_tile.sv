// Migrated verbatim from the bitmod repo (module bodies unchanged).
// fpadd + tile: the 8x8 PE tile, 64 MAC/cycle at INT8 (src/main.sv)
// Provenance: bitmod @ 5cb051c, src/{main,pe}.sv -- see README.md.
`ifndef BITMOD_TILE_SV
`define BITMOD_TILE_SV
`include "baselines/bitmod/bitmod_defs.svh"
`include "baselines/bitmod/bitmod_pe.sv"
// NOTE: we use a special format where the mantissa is a signed 2c number
// TODO: actually convert it back to fp16...??
module fpadd #(
    parameter int MANW=23,
    parameter int EXPW=6

) (
    input   logic[MANW-1:0] a_man,
    input   logic[EXPW-1:0] a_exp,
    input   logic[MANW-1:0] b_man,
    input   logic[EXPW-1:0] b_exp,
    output  logic[MANW-1:0] sum_man,
    output  logic[EXPW-1:0] sum_exp
);
    logic dir;
    logic[EXPW:0]   sub, rsub;
    logic[EXPW-1:0] mag, exp;

    assign sub  = {1'b0, a_exp} - {1'b0, b_exp};
    assign rsub = {1'b0, b_exp} - {1'b0, a_exp};
    assign dir  = sub[EXPW];
    assign mag  = dir ? rsub[EXPW-1:0] : sub[EXPW-1:0];
    assign exp  = dir ? b_exp : a_exp;

    logic[MANW+3:0] sum_man_ext;
        // ext = {ovf:1, man:MANW, guard:3}
        // 1. guard bits for alignment
        // 2. 1 overflow bit to absorb sum overflow
    assign sum_man_ext =
        (MANW+4)'($signed(                  {dir ? b_man : a_man, 3'b0}))
    +   (MANW+4)'($signed((MANW+3)'($signed({dir ? a_man : b_man, 3'b0})) >>> mag));

    logic shift;
    assign shift = sum_man_ext[MANW+3] ^ sum_man_ext[MANW+3-1];

    assign sum_exp = |sum_man_ext[MANW+3:3] ? exp + shift : '0; // zero-canonicalize
    assign sum_man = MANW'($signed(sum_man_ext[MANW+3:3]) >>> shift);

endmodule


module tile #(
    parameter   int COL_LEN = 8,
    localparam  int ROW_LEN = 8
) (
    input   logic                           i_drain_vld_ahead1,
    input   logic[COL_LEN-1:0][28:0]        i_drain_row,
    output  logic                           o_drain_vld_ahead1,
    output  logic[COL_LEN-1:0][28:0]        o_drain_row,

    input   logic                           clk,
    input   logic                           arstn,

    input   logic                           i_vld,
    input   logic                           i_vld_first_elem,
    input   logic                           i_vld_first_group,
    input   logic                           i_fin,
    input   logic                           i_last,
    input   logic[ROW_LEN-1:0][3:0][15:0]   i_a,
    input   logic[COL_LEN-1:0][3:0][3:0]    i_w_sem, // sign:1, exponent:2, mantissa:1
    input   logic[2:0]                      i_w_bsig,
    input   logic[COL_LEN-1:0][7:0]         i_w_scale,

    output  logic                           o_vld,
    output  logic                           o_vld_first_elem,
    output  logic                           o_vld_first_group,
    output  logic                           o_fin,
    output  logic                           o_last,
    output  logic[ROW_LEN-1:0][3:0][15:0]   o_a,
    output  logic[COL_LEN-1:0][3:0][3:0]    o_w_sem, // sign:1, exponent:2, mantissa:1
    output  logic[2:0]                      o_w_bsig,
    output  logic[COL_LEN-1:0][7:0]         o_w_scale

);
    logic   gclk_i_vld_first_group;
    logic   gclk_s3;
    logic   gclk_s4_0;
    logic   gclk_s4_1;
    logic   gclk_o;

    logic[COL_LEN-1:0][28:0]                o_drain_row_n;
    logic                                   pe_vld_ahead1;
    logic                                   pe_fin_ahead1;
    logic[ROW_LEN-1:0][COL_LEN-1:0][22:0]   pe_dat_man;
    logic[ROW_LEN-1:0][COL_LEN-1:0][5:0]    pe_dat_exp;
    logic[COL_LEN-1:0][28:0]                rd_obuf;

    logic[$clog2(ROW_LEN)-1:0]              accum_row;
    logic[COL_LEN-1:0][5:0]                 accum_sum_exp;
    logic[COL_LEN-1:0][22:0]                accum_sum_man;


    logic                   s1_vld;
    logic[4:0]              s1_bsig_1hot;

    logic                   s2_vld, s2_last;

    logic                   s3_5_vld, s3_5_fin;
    logic[COL_LEN-1:0][7:0] s3_5_scale;

    logic                   s4_load;
    logic[COL_LEN-1:0]      s4_scale_bit;

    tech_icg cg_i_vld_first_group (.clk(clk), .en(i_vld_first_group), .gclk(gclk_i_vld_first_group));

    pe_scratch_common #(.COL_LEN(COL_LEN), .ROW_LEN(ROW_LEN)) common (
        .clk            (clk),
        .arstn          (arstn),
        .gclk_s1_scale  (gclk_i_vld_first_group),
        .gclk_s3        (gclk_s3),
        .gclk_s4_0      (gclk_s4_0),
        .gclk_s4_1      (gclk_s4_1),
        .gclk_o         (gclk_o),

        .i_vld          (i_vld),
        .i_vld_first_group  (i_vld_first_group),
        .i_fin          (i_fin),
        .i_last         (i_last),
        .i_w_bsig       (i_w_bsig),
        .i_w_scale      (i_w_scale),

        .s1_vld         (s1_vld),
        .s1_bsig_1hot   (s1_bsig_1hot),

        .s2_vld         (s2_vld),
        .s2_last        (s2_last),

        .s4_load        (s4_load),
        .s4_scale_bit   (s4_scale_bit),

        .o_vld_ahead1   (pe_vld_ahead1),
        .o_fin_ahead1   (pe_fin_ahead1)

    );

    for (genvar r = 0; r < ROW_LEN; ++r) begin : pe_row
        for (genvar c = 0; c < COL_LEN; ++c) begin : pe_col
            pe_scratch pe (
                .clk            (clk),
                .gclk_s3        (gclk_s3),
                .gclk_s4_0      (gclk_s4_0),
                .gclk_s4_1      (gclk_s4_1),
                .gclk_o         (gclk_o),

                .a              (i_a[r]),
                .w_sem          (i_w_sem[c]),

                .s1_vld         (s1_vld),
                .s1_bsig_1hot   (s1_bsig_1hot),

                .s2_vld         (s2_vld),
                .s2_last        (s2_last),

                .s4_load        (s4_load),
                .s4_scale_bit   (s4_scale_bit[c]),

                .o_exp          (pe_dat_exp[r][c]),
                .o_man          (pe_dat_man[r][c])
            );

        end

    end

    for (genvar c = 0; c < COL_LEN; ++c) begin
        fpadd #(.MANW(23), .EXPW(6)) accum (
            .a_man  (pe_dat_man[accum_row][c]),
            .a_exp  (pe_dat_exp[accum_row][c]),
            .b_man  (rd_obuf[c][22:0]),
            .b_exp  (rd_obuf[c][28:23]),
            .sum_man(accum_sum_man[c]),
            .sum_exp(accum_sum_exp[c])
        );

    end

    struct packed {
        logic store_en;
        logic forward_en;
        logic forward_else;
    } mode, mode_n;

    assign mode_n = '{
        store_en    :   pe_vld_ahead1 & ~pe_fin_ahead1,
        forward_en  :  (pe_vld_ahead1 &  pe_fin_ahead1) | (mode.forward_en & mode.forward_else),
        forward_else:   i_drain_vld_ahead1
    };

    always_ff @(posedge clk or negedge arstn) begin
        if          (~arstn) begin
            accum_row           <= '0;
            mode                <= '0;
            o_vld               <= 1'b0;
            o_vld_first_elem    <= 1'b0;
            o_vld_first_group   <= 1'b0;
            o_drain_vld_ahead1  <= 1'b0;

        end else begin
            if (mode.store_en | mode.forward_en)
                accum_row <= accum_row + 1'b1;

            if (~(mode.store_en | mode.forward_en) | accum_row == 3'd7)
                mode <= mode_n;

            if (~mode.forward_en | accum_row == 3'd7)
                o_drain_vld_ahead1  <= mode_n.forward_en;

            o_vld               <= i_vld;
            o_vld_first_elem    <= i_vld_first_elem;
            o_vld_first_group   <= i_vld_first_group;

        end
    end

    logic[COL_LEN-1:0][28:0] accum_sum_row;
    for (genvar c = 0; c < COL_LEN; ++c)
        assign accum_sum_row[c] = {accum_sum_exp[c], accum_sum_man[c]};

    cg_rf #(.COUNT(ROW_LEN), .WIDTH(COL_LEN*29)) cg_obuf (
        .clk    (clk),
        .ridx   (accum_row),
        .rdat   (rd_obuf),
        .wen    (mode.store_en | (mode.forward_en & ~mode.forward_else)),
        .widx   (accum_row),
        .wdat   (mode.store_en ? accum_sum_row : '0)
    );

    cg_dreg #(.WIDTH($bits(o_drain_row))) cg_o_drain_row (
        .clk    (clk),
        .en     (mode.forward_en),
        .din    (mode.forward_else ? i_drain_row : accum_sum_row),
        .dout   (o_drain_row)
    );

    always_ff @(posedge clk) begin
        o_fin       <= i_fin;
        o_last      <= i_last;
        o_w_sem     <= i_w_sem;
        o_w_bsig    <= i_w_bsig;

    end

    cg_dreg #(.WIDTH($bits(o_a))) cg_o_a (
        .clk    (clk),
        .en     (i_vld_first_elem),
        .din    (i_a),
        .dout   (o_a)
    );

    always_ff @(posedge gclk_i_vld_first_group) begin
        o_w_scale <= i_w_scale;
    end

endmodule
`endif
