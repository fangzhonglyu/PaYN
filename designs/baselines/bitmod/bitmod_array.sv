// Migrated verbatim from the bitmod repo (module bodies unchanged).
// Raptor_Lake_HX: 4x4 grid of tiles = 1024 PEs, 1024 MAC/cycle at INT8 (src/main.sv)
// Provenance: bitmod @ 5cb051c, src/{main,pe}.sv -- see README.md.
`ifndef BITMOD_ARRAY_SV
`define BITMOD_ARRAY_SV
`include "baselines/bitmod/bitmod_tile.sv"
`include "baselines/bitmod/bitmod_ctrl.sv"
// contract: on startup, must send a dummy fin group to zero tile obufs / pe accums
module Raptor_Lake_HX (
    output  logic[3:0]                  o_drain_vld,    // tile_col
    output  logic[3:0][7:0][28:0]       o_drain_dat,    // tile_col, pe_col

    input   logic                       clk,
    input   logic                       arstn,
    input   logic[1:0]                  mode,

    input   logic                       i_vld,
    output  logic                       i_rdy,

    input   logic[3:0][7:0][3:0][15:0]  i_a,            // tile_row, pe_row, activation_row
    input   logic[3:0][7:0][3:0][7:0]   i_w,            // tile_col, pe_col, weight_col

    input   logic                       i_grp_vld,
    input   logic                       i_grp_fin,
    output  logic                       i_grp_rdy,
    input   logic[3:0][7:0][7:0]        i_grp_w_scale,  // tile_col, pe_col
    input   logic[3:0][7:0][2:0]        i_grp_w_special_value_id,
    input   logic[31:0]                 i_grp_w_elem_count_m1 // elem_count - 1

);
    typedef struct packed {
        logic[7:0][28:0]        row;
    } drain_pkt_t;

    // controller outputs
    logic vld_cout;
    logic vld_first_elem_cout;
    logic vld_first_group_cout;
    logic fin_cout;
    logic last_cout;
    logic[3:0]      [7:0][3:0][15:0]a_cout;
    logic     [3:0] [7:0][3:0][3:0] w_sem_cout;
    logic           [2:0]           w_bsig_cout;
    logic     [3:0] [7:0][7:0]      w_scale_cout;

    vert_tr_pkt_t[3:0] vert_tr_cout;
    vert_gr_pkt_t[3:0] vert_gr_cout;
    hori_er_pkt_t[3:0] hori_er_cout;

    for (genvar i = 0; i < 4; ++i) begin
        assign vert_tr_cout[i] = '{
            fin     : fin_cout,
            last    : last_cout,
            w_sem   : w_sem_cout[i],
            w_bsig  : w_bsig_cout

        };

        assign vert_gr_cout[i] = '{
            w_scale : w_scale_cout[i]

        };

        assign hori_er_cout[i] = '{
            a       : a_cout[i]

        };

    end

    controller big_brain (
        .clk                        (clk),
        .arstn                      (arstn),
        .mode                       (mode),

        .i_vld                      (i_vld),
        .i_rdy                      (i_rdy),
        .o_vld                      (vld_cout),
        .o_vld_first_elem           (vld_first_elem_cout),
        .o_vld_first_group          (vld_first_group_cout),
        .o_fin                      (fin_cout),
        .o_last                     (last_cout),

        .i_a                        (i_a),
        .i_w                        (i_w),

        .i_grp_vld                  (i_grp_vld),
        .i_grp_fin                  (i_grp_fin),
        .i_grp_rdy                  (i_grp_rdy),
        .i_grp_w_scale              (i_grp_w_scale),
        .i_grp_w_special_value_id   (i_grp_w_special_value_id),
        .i_grp_w_elem_count_m1      (i_grp_w_elem_count_m1),

        .o_a                        (a_cout),
        .o_w_sem                    (w_sem_cout),
        .o_w_bsig                   (w_bsig_cout),
        .o_w_scale                  (w_scale_cout)

    );

    logic[3:0] vld_skewed;
    logic[3:0] vld_first_elem_skewed;
    logic[3:0] vld_first_group_skewed;

    vert_tr_pkt_t[3:0] vert_tr_skewed;
    vert_gr_pkt_t[3:0] vert_gr_skewed;
    hori_er_pkt_t[3:0] hori_er_skewed;

    skew skew (
        .clk                (clk),
        .arstn              (arstn),

        .i_vld              (vld_cout),
        .i_vld_first_elem   (vld_first_elem_cout),
        .i_vld_first_group  (vld_first_group_cout),
        .i_vert_tr          (vert_tr_cout),
        .i_vert_gr          (vert_gr_cout),
        .i_hori_er          (hori_er_cout),

        .o_vld              (vld_skewed),
        .o_vld_first_elem   (vld_first_elem_skewed),
        .o_vld_first_group  (vld_first_group_skewed),

        .o_vert_tr          (vert_tr_skewed),
        .o_vert_gr          (vert_gr_skewed),
        .o_hori_er          (hori_er_skewed)
    );

    // per-tile state
    logic[4:0][3:0]         vld;
    logic[4:0][3:0]         vld_first_elem;
    logic[4:0][3:0]         vld_first_group;
    vert_tr_pkt_t[4:0][3:0] vertp_tr;
    vert_gr_pkt_t[4:0][3:0] vertp_gr;
    hori_er_pkt_t[3:0][4:0] horip_er;
    logic[4:0][3:0]         drain_vld_ahead1;
    drain_pkt_t[4:0][3:0]   drain;
    logic[3:0]              drain_vld;

    assign vld[0]               = vld_skewed;
    assign vld_first_elem[0]    = vld_first_elem_skewed;
    assign vld_first_group[0]   = vld_first_group_skewed;
    assign vertp_tr[0]          = vert_tr_skewed;
    assign vertp_gr[0]          = vert_gr_skewed;

    assign horip_er[0][0]       = hori_er_skewed[0];
    assign horip_er[1][0]       = hori_er_skewed[1];
    assign horip_er[2][0]       = hori_er_skewed[2];
    assign horip_er[3][0]       = hori_er_skewed[3];

    assign drain_vld_ahead1[0]  = '0;
    assign o_drain_vld          = drain_vld;
    for (genvar c = 0; c < 4; ++c) begin
        assign drain[0][c].row  = 'x;
        assign o_drain_dat[c]   = drain[4][c];
    end

    for (genvar r = 0; r < 4; ++r) begin : tile_row
        for (genvar c = 0; c < 4; ++c) begin : tile_col
            tile t (
                .clk                (clk),
                .arstn              (arstn),

                .i_drain_vld_ahead1 (drain_vld_ahead1   [r][c]),
                .i_drain_row        (drain              [r][c].row),
                .o_drain_vld_ahead1 (drain_vld_ahead1   [r+1][c]),
                .o_drain_row        (drain              [r+1][c].row),

                .i_vld              (vld            [r][c]),
                .i_vld_first_elem   (vld_first_elem [r][c]),
                .i_vld_first_group  (vld_first_group[r][c]),
                .i_fin              (vertp_tr       [r][c].fin),
                .i_last             (vertp_tr       [r][c].last),
                .i_a                (horip_er       [r][c].a),
                .i_w_sem            (vertp_tr       [r][c].w_sem),
                .i_w_bsig           (vertp_tr       [r][c].w_bsig),
                .i_w_scale          (vertp_gr       [r][c].w_scale),

                .o_vld              (vld            [r+1][c]),
                .o_vld_first_elem   (vld_first_elem [r+1][c]),
                .o_vld_first_group  (vld_first_group[r+1][c]),
                .o_fin              (vertp_tr       [r+1][c].fin),
                .o_last             (vertp_tr       [r+1][c].last),
                .o_a                (horip_er       [r][c+1].a),
                .o_w_sem            (vertp_tr       [r+1][c].w_sem),
                .o_w_bsig           (vertp_tr       [r+1][c].w_bsig),
                .o_w_scale          (vertp_gr       [r+1][c].w_scale)

            );

        end
    end

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn)
            drain_vld <= '0;
        else
            drain_vld <= drain_vld_ahead1[4]; // slow by 1 cycle to sync with data

    end

endmodule
`endif
