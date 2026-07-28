// Migrated verbatim from the bitmod repo (module bodies unchanged).
// skid / fixed6_from_float4 / controller / skew: operand decode + skew (src/main.sv)
// Provenance: bitmod @ 5cb051c, src/{main,pe}.sv -- see README.md.
`ifndef BITMOD_CTRL_SV
`define BITMOD_CTRL_SV
`include "baselines/bitmod/bitmod_defs.svh"
module skid #(
    parameter logic EN_CLOCK_GATE   = 1'b0,
    parameter int   WIDTH           = 1024
) (
    input   logic   clk,
    input   logic   arstn,

    input   logic   i_vld,
    output  logic   i_rdy,
    input   logic   [WIDTH-1:0] i_dat,

    output  logic   o_vld,
    input   logic   o_rdy,
    output  logic   [WIDTH-1:0] o_dat

);
    typedef enum logic {
        PIPE = 1'b0,
        SKID = 1'b1
    } SKID_STATUS;

    logic   s, s_n;
    logic   vld, vld_n, rdy, rdy_n;
    logic   [WIDTH-1:0] dat, dat_n, tmp, tmp_n;

    assign  o_vld = vld;
    assign  o_dat = dat;
    assign  i_rdy = rdy;

    always_comb begin
        vld_n = vld;
        rdy_n = rdy;
        dat_n = dat;
        tmp_n = tmp;
        s_n   = s;

        case (s)
        PIPE: begin
            if (~vld | o_rdy) begin
                vld_n = i_vld;
                dat_n = i_dat;
                rdy_n = 1'b1;

            end else begin
                tmp_n = i_dat;
                rdy_n = 1'b0;
                s_n   = SKID;

            end

        end

        SKID: begin
            if (o_rdy) begin
                dat_n = tmp;
                s_n   = PIPE;
                rdy_n = 1'b1;

            end

        end

        endcase
    end

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            s   <= PIPE;
            vld <= 1'b0;
            rdy <= 1'b1;

        end else begin
            s   <= s_n;
            vld <= vld_n;
            rdy <= rdy_n;

        end

    end

    logic dat_en;
    logic tmp_en;
    assign dat_en = (s == PIPE & (~vld | o_rdy)) | (s == SKID & o_rdy);
    assign tmp_en = (s == PIPE) & vld & ~o_rdy;

if (EN_CLOCK_GATE) begin
    cg_dreg #(.WIDTH(WIDTH)) cg_dat (
        .clk  (clk),
        .en   (dat_en),
        .din  (dat_n),
        .dout (dat)
    );
    cg_dreg #(.WIDTH(WIDTH)) cg_tmp (
        .clk  (clk),
        .en   (tmp_en),
        .din  (tmp_n),
        .dout (tmp)
    );
end else begin
    always_ff @(posedge clk) begin
        dat <= dat_n;
        tmp <= tmp_n;
        // NOTE: dat, tmp are not reset-initialized

    end

end

endmodule
module fixed6_from_float4 (
    input   logic[3:0]  float4, // sign:1, exp:2, man:1
    output  logic[5:0]  fixed6  // sign:1, integer:4, float:1
);
    logic s, e1, e0, m;
    assign s = float4[3];
    assign e1= float4[2];
    assign e0= float4[1];
    assign m = float4[0];

    // assign fixed6[5] = s;
    // assign fixed6[4] = 1'b0;
    // assign fixed6[3] = e1 & e0;
    // assign fixed6[2] = (e1 & e0 & m) | (e1 & ~e0);
    // assign fixed6[1] = (e1 & ~e0 & m)| (~e1 & e0);
    // assign fixed6[0] = (~e1& e0 & m) | (~e1 & ~e0 & m);

    assign fixed6[5] = s;
    assign fixed6[4] = 1'b0;
    assign fixed6[3] = e1 & e0;
    assign fixed6[2] = (e1 & e0 & m) | (e1 & ~e0);
    assign fixed6[1] = (e1 & ~e0 & m)| (~e1 & e0);
    assign fixed6[0] = ~e1 & m;
endmodule

module controller #(
    parameter   TILE_WIDTH  = 4,
    localparam  PE_WIDTH    = 8*TILE_WIDTH,
    localparam  LANE_WIDTH  = 4*PE_WIDTH
) (
    input   logic                       clk,
    input   logic                       arstn,
    input   logic[1:0]                  mode,

    input   logic                       i_vld,
    output  logic                       i_rdy,
    output  logic                       o_vld,
    output  logic                       o_vld_first_elem,
    output  logic                       o_vld_first_group,
    output  logic                       o_last,
    output  logic                       o_fin,

    input   logic[LANE_WIDTH-1:0][15:0] i_a,
    input   logic[LANE_WIDTH-1:0][7:0]  i_w,

    input   logic                       i_grp_vld,
    output  logic                       i_grp_rdy,
    input   logic                       i_grp_fin,
    input   logic[PE_WIDTH-1:0][7:0]    i_grp_w_scale,
    input   logic[PE_WIDTH-1:0][2:0]    i_grp_w_special_value_id,
    input   logic[31:0]                 i_grp_w_elem_count_m1, // elem_count - 1

    output  logic[LANE_WIDTH-1:0][15:0] o_a,
    output  logic[LANE_WIDTH-1:0][3:0]  o_w_sem,
    output  logic[2:0]                  o_w_bsig,
    output  logic[PE_WIDTH-1:0][7:0]    o_w_scale

);
    typedef struct packed {
        logic                       fin;
        logic[PE_WIDTH-1:0][7:0]    scale;
        logic[PE_WIDTH-1:0][2:0]    special_value_id;
        logic[31:0]                 elem_count_m1;
    } group_md_t;

    logic work_vld, work_rdy;
    group_md_t i_grp_md, work_grp_md;
    assign i_grp_md = '{
        fin             : i_grp_fin,
        scale           : i_grp_w_scale,
        special_value_id: i_grp_w_special_value_id,
        elem_count_m1   : i_grp_w_elem_count_m1
    };

    skid #(.EN_CLOCK_GATE(1'b1), .WIDTH($bits(group_md_t))) work_fifo (
        .clk     (clk),
        .arstn   (arstn),

        .i_vld   (i_grp_vld),
        .i_rdy   (i_grp_rdy),
        .i_dat   (i_grp_md),

        .o_vld   (work_vld),
        .o_rdy   (work_rdy),
        .o_dat   (work_grp_md)

    );

    logic       step;
    logic       o_last_n;
    logic[4:0]  cycles_since_last_last;
    logic       last_last_was_fin;
    logic       safe_to_emit_last;
    logic[3:0]  cycle_1hot;
    logic[31:0] elem;
    logic[LANE_WIDTH-1:0][3:0]  o_w_sem_n;
    logic[PE_WIDTH-1:0][5:0]    fixed6_specials;
    for (genvar i = 0; i < PE_WIDTH; ++i) begin
        logic[2:0] special_id;
        assign special_id = work_grp_md.special_value_id[i];
        assign fixed6_specials[i] = {special_id[2], special_value_lut[special_id[1:0]], 1'b0};

    end

    logic       last_cycle;
    logic       f3f4_en;
    logic[3:0]  cycle_1hot_i6i8;
    assign f3f4_en          = mode == S_F4_F3;
    assign last_cycle       = cycle_1hot[mode];
    assign cycle_1hot_i6i8  = cycle_1hot & ~{4{f3f4_en}};

    for (genvar i = 0; i < LANE_WIDTH; ++i) begin : lane
        // 1. integer w_sem_n
        logic[2:0] idx;
        logic[3:0] int_w_sem_n;
        assign idx[2] =
            (cycle_1hot_i6i8[0] & i_w[i][1])
        |   (cycle_1hot_i6i8[1] & i_w[i][3])
        |   (cycle_1hot_i6i8[2] & i_w[i][5])
        |   (cycle_1hot_i6i8[3] & i_w[i][7]);
        assign idx[1] =
            (cycle_1hot_i6i8[0] & i_w[i][0])
        |   (cycle_1hot_i6i8[1] & i_w[i][2])
        |   (cycle_1hot_i6i8[2] & i_w[i][4])
        |   (cycle_1hot_i6i8[3] & i_w[i][6]);
        assign idx[0] =
            (cycle_1hot_i6i8[1] & i_w[i][1])
        |   (cycle_1hot_i6i8[2] & i_w[i][3])
        |   (cycle_1hot_i6i8[3] & i_w[i][5]);
        assign int_w_sem_n = booth_lut[idx];

        // 2. fixed point w_sem_n
        wire[3:0] i_w_f3f4 = i_w[i][3:0] & {4{f3f4_en}};

        logic[5:0] fixed6, fixed6_normal;
        fixed6_from_float4 cv (
            .float4 (i_w_f3f4),
            .fixed6 (fixed6_normal)
        );
        assign fixed6 = (i_w_f3f4 == 4'b1000) // == -0
            ? fixed6_specials[i / 4]
            : fixed6_normal;

        logic[3:0]  n0, n1;
        logic[1:0]  fexp0, fexp1, fexp;
        logic       fman;
        assign n0 = fixed6[3:0];
        assign n1 = {
            fixed6[4],
            fixed6[3] & (|fixed6[2:0]),
            fixed6[2] & (|fixed6[1:0]),
            fixed6[1] &   fixed6[0]
        };

        always_comb begin
            unique casez (n0)
            4'b???1:fexp0= 2'd0;
            4'b??10:fexp0= 2'd1;
            4'b?100:fexp0= 2'd2;
            4'b1000:fexp0= 2'd3;
            4'b0000:fexp0= 2'd0;
            default:fexp0= 'x;
            endcase
        end

        always_comb begin
            unique casez (n1)
            4'b???1:fexp1= 2'd0;
            4'b??10:fexp1= 2'd1;
            4'b?100:fexp1= 2'd2;
            4'b1000:fexp1= 2'd3;
            4'b0000:fexp1= 2'd0;
            default:fexp1= 'x;
            endcase
        end

        assign fexp = cycle_1hot[0] ? fexp0 : fexp1;
        assign fman = cycle_1hot[0] ? |n0   : |n1;
        assign o_w_sem_n[i] = f3f4_en ? {fixed6[5], fexp, fman} : int_w_sem_n;

    end


    localparam  THRESHOLD_NON_FIN_LAST  = 3'd7; // 8 beats (to avoid clobbering prior); slowest stage in pe is dequant / column accumumulation (both 8 cycles)
    localparam  THRESHOLD_FIN_LAST      = 5'd31;// drain critical path is bottom tile: drain self, then 3 north neighbors
    assign safe_to_emit_last = cycles_since_last_last >= (last_last_was_fin ? THRESHOLD_FIN_LAST : THRESHOLD_NON_FIN_LAST);
    assign o_last_n = last_cycle    & elem == work_grp_md.elem_count_m1;
    assign work_rdy = i_vld         & work_vld  &   o_last_n & safe_to_emit_last;
    assign i_rdy    = last_cycle    & work_vld  & (~o_last_n | safe_to_emit_last);
    assign step     = i_vld         & work_vld  & (~o_last_n | safe_to_emit_last);

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            last_last_was_fin       <= 1'b0;
            cycles_since_last_last  <= '1;

        end else begin
            if          (step & o_last_n) begin
                last_last_was_fin       <= work_grp_md.fin;
                cycles_since_last_last  <= '0;
            end else if (~&cycles_since_last_last) begin
                cycles_since_last_last  <= cycles_since_last_last + 1'b1;
            end

        end
    end

    // vld tracking start term of elem/group duty cycles respectively (for clock-gating)
    logic o_vld_first_elem_n;
    logic o_vld_first_group_n;
    assign o_vld_first_elem_n   = step & cycle_1hot[0];
    assign o_vld_first_group_n  = step & cycle_1hot[0] & (elem == 0);

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            o_vld               <= 1'b0;
            o_vld_first_elem    <= 1'b0;
            o_vld_first_group   <= 1'b0;

            cycle_1hot          <= 4'b0001;
            elem                <= '0;

        end else  begin
            o_vld               <= step;
            o_vld_first_elem    <= o_vld_first_elem_n;
            o_vld_first_group   <= o_vld_first_group_n;

            if (step) begin
                cycle_1hot      <= last_cycle ? 4'b0001 : {cycle_1hot[2:0], 1'b0};
                if (last_cycle)
                    elem<= elem == work_grp_md.elem_count_m1 ? '0 : elem + 1'b1;
            end

        end
    end

    always_ff @(posedge clk) begin
        o_last      <= o_last_n;
        o_fin       <= work_grp_md.fin;

        o_w_sem     <= o_w_sem_n;
        // int: {cycle, 1'b0}, fp4: {1'b0, cycle}
        // cycle_1hot[3:2] never set in fp4, so bit 2 needs no mode gating.
        o_w_bsig[2] <=             cycle_1hot[2] | cycle_1hot[3];
        o_w_bsig[1] <= ~f3f4_en & (cycle_1hot[1] | cycle_1hot[3]);
        o_w_bsig[0] <=  f3f4_en &  cycle_1hot[1];

    end

    cg_dreg #(.WIDTH($bits(o_a))) cg_o_a (
        .clk    (clk),
        .en     (o_vld_first_elem_n),
        .din    (i_a), // should this be masked by o_vld_first_elem_n
        .dout   (o_a)
    );

    cg_dreg #(.WIDTH($bits(o_w_scale))) cg_o_w_scale (
        .clk    (clk),
        .en     (o_vld_first_group_n),
        .din    (work_grp_md.scale), // should this be masked by o_vld_first_elem_n
        .dout   (o_w_scale)
    );

endmodule

module skew (
    input   logic               clk,
    input   logic               arstn,

    input   logic               i_vld,
    input   logic               i_vld_first_elem,
    input   logic               i_vld_first_group,
    input   vert_tr_pkt_t[3:0]  i_vert_tr,
    input   vert_gr_pkt_t[3:0]  i_vert_gr,
    input   hori_er_pkt_t[3:0]  i_hori_er,

    output  logic[3:0]          o_vld,
    output  logic[3:0]          o_vld_first_elem,
    output  logic[3:0]          o_vld_first_group,

    output  vert_tr_pkt_t[3:0]  o_vert_tr,
    output  vert_gr_pkt_t[3:0]  o_vert_gr,
    output  hori_er_pkt_t[3:0]  o_hori_er

);
    // latency skew belts
    logic       vld1, vld_first_elem1, vld_first_group1;
    logic[1:0]  vld2, vld_first_elem2, vld_first_group2;
    logic[2:0]  vld3, vld_first_elem3, vld_first_group3;

    vert_tr_pkt_t       vert_tr1;
    vert_tr_pkt_t[1:0]  vert_tr2;
    vert_tr_pkt_t[2:0]  vert_tr3;

    vert_gr_pkt_t       vert_gr1;
    vert_gr_pkt_t[1:0]  vert_gr2;
    vert_gr_pkt_t[2:0]  vert_gr3;

    hori_er_pkt_t       hori_er1;
    hori_er_pkt_t[1:0]  hori_er2;
    hori_er_pkt_t[2:0]  hori_er3;

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            vld1               <= '0;
            vld2               <= '0;
            vld3               <= '0;
            vld_first_elem1    <= '0;
            vld_first_elem2    <= '0;
            vld_first_elem3    <= '0;
            vld_first_group1   <= '0;
            vld_first_group2   <= '0;
            vld_first_group3   <= '0;

        end else begin
            vld1               <= i_vld;
            vld2               <= {i_vld, vld2[1]};
            vld3               <= {i_vld, vld3[2:1]};
            vld_first_elem1    <= i_vld_first_elem;
            vld_first_elem2    <= {i_vld_first_elem, vld_first_elem2[1]};
            vld_first_elem3    <= {i_vld_first_elem, vld_first_elem3[2:1]};
            vld_first_group1   <= i_vld_first_group;
            vld_first_group2   <= {i_vld_first_group, vld_first_group2[1]};
            vld_first_group3   <= {i_vld_first_group, vld_first_group3[2:1]};

        end
    end

    always_ff @(posedge clk) begin
        vert_tr1   <= i_vert_tr[1];
        vert_tr2   <= {i_vert_tr[2], vert_tr2[1]};
        vert_tr3   <= {i_vert_tr[3], vert_tr3[2:1]};

    end

    cg_dreg #(.WIDTH(3*$bits(i_vert_gr[0]))) cg_vert_gr0 (
        .clk    (clk),
        .en     (i_vld_first_group),
        .din    ({i_vert_gr[1], i_vert_gr[2],   i_vert_gr[3]}),
        .dout   ({  vert_gr1,     vert_gr2[1],    vert_gr3[2]})
    );

    cg_dreg #(.WIDTH(2*$bits(i_vert_gr[0]))) cg_vert_gr1 (
        .clk    (clk),
        .en     (vld_first_group3[2]),
        .din    ({vert_gr2[1], vert_gr3[2]}),
        .dout   ({vert_gr2[0], vert_gr3[1]})
    );

    cg_dreg #(.WIDTH(  $bits(i_vert_gr[0]))) cg_vert_gr2 (
        .clk    (clk),
        .en     (vld_first_group3[1]),
        .din    (vert_gr3[1]),
        .dout   (vert_gr3[0])
    );

    cg_dreg #(.WIDTH(3*$bits(i_hori_er[0]))) cg_hori_er0 (
        .clk    (clk),
        .en     (i_vld_first_elem),
        .din    ({i_hori_er[1], i_hori_er[2],   i_hori_er[3]}),
        .dout   ({  hori_er1,     hori_er2[1],    hori_er3[2]})
    );

    cg_dreg #(.WIDTH(2*$bits(i_hori_er[0]))) cg_hori_er1 (
        .clk    (clk),
        .en     (vld_first_elem3[2]),
        .din    ({hori_er2[1], hori_er3[2]}),
        .dout   ({hori_er2[0], hori_er3[1]})
    );

    cg_dreg #(.WIDTH(  $bits(i_hori_er[0]))) cg_hori_er2 (
        .clk    (clk),
        .en     (vld_first_elem3[1]),
        .din    (hori_er3[1]),
        .dout   (hori_er3[0])
    );

    assign o_vld            = {vld3[0],             vld2[0],            vld1,               i_vld};
    assign o_vld_first_elem = {vld_first_elem3[0],  vld_first_elem2[0], vld_first_elem1,    i_vld_first_elem};
    assign o_vld_first_group= {vld_first_group3[0], vld_first_group2[0],vld_first_group1,   i_vld_first_group};

    assign o_vert_tr = {vert_tr3[0], vert_tr2[0], vert_tr1, i_vert_tr[0]};
    assign o_vert_gr = {vert_gr3[0], vert_gr2[0], vert_gr1, i_vert_gr[0]};
    assign o_hori_er = {hori_er3[0], hori_er2[0], hori_er1, i_hori_er[0]};

endmodule
`endif
