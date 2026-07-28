// Migrated verbatim from the bitmod repo (module bodies unchanged).
// pe_scratch_common / pe_scratch / pe_scratch_with_control (src/pe.sv)
// Provenance: bitmod @ 5cb051c, src/{main,pe}.sv -- see README.md.
`ifndef BITMOD_PE_SV
`define BITMOD_PE_SV
`include "baselines/bitmod/bitmod_defs.svh"
module pe_scratch_common #(
    parameter   int COL_LEN = 8,
    parameter   int ROW_LEN = 8
) (
    input   logic                   clk,
    input   logic                   arstn,
    input   logic                   gclk_s1_scale,
    output  logic                   gclk_s3,
    output  logic                   gclk_s4_0,
    output  logic                   gclk_s4_1,
    output  logic                   gclk_o,

    input   logic                   i_vld,
    input   logic                   i_vld_first_group,
    input   logic                   i_fin,
    input   logic                   i_last,
    input   logic[2:0]              i_w_bsig,
    input   logic[COL_LEN-1:0][7:0] i_w_scale,

    output  logic                   s1_vld,
    output  logic[4:0]              s1_bsig_1hot,

    output  logic                   s2_vld, s2_last,

    output  logic                   s4_load,
    output  logic[COL_LEN-1:0]      s4_scale_bit,

    output  logic                   o_vld_ahead1,
    output  logic                   o_fin_ahead1

);
    logic                   s1_vld_first_group;
    logic                   s1_fin, s1_last;
    logic[COL_LEN-1:0][7:0] s1_scale;

    logic                   s2_fin;
    logic[COL_LEN-1:0][7:0] s2_scale;

    logic                   s4_vld;
    logic                   s4_fin;
    logic[7:0]              s4_cycle_1hot;

    logic gclk_s2_scale;

    tech_icg cg_s2_scale(.clk(clk), .en(s1_vld_first_group),.gclk(gclk_s2_scale));
    tech_icg cg_s3      (.clk(clk), .en(s2_vld), .gclk(gclk_s3));
    tech_icg cg_s4_0    (.clk(clk), .en(s2_vld & s2_last),  .gclk(gclk_s4_0));
    tech_icg cg_s4_1    (.clk(clk), .en((s2_vld & s2_last) | (s4_vld & ~s4_cycle_1hot[0])), .gclk(gclk_s4_1));
    tech_icg cg_o       (.clk(clk), .en(s4_vld & s4_cycle_1hot[0]), .gclk(gclk_o));

    always_ff @(posedge clk or negedge arstn) begin
        if (~arstn) begin
            s1_vld      <= 1'b0;
            s2_vld      <= 1'b0;
            s4_vld      <= 1'b0;
            o_vld_ahead1<= 1'b0;

            s1_vld_first_group <= 1'b0;

        end else begin
            s1_vld      <= i_vld;
            s2_vld      <= s1_vld;
            s4_vld      <= (s2_vld & s2_last) | (s4_vld & ~s4_cycle_1hot[0]);
            o_vld_ahead1<= s4_vld & s4_cycle_1hot[1];

            s1_vld_first_group <= i_vld_first_group;

        end

    end

    always_ff @(posedge clk) begin
        s1_fin  <= i_fin;
        s1_last <= i_last;

        // count -> 1hot decoding
        s1_bsig_1hot[0] <= ~|i_w_bsig;                  // 0
        s1_bsig_1hot[1] <=  i_w_bsig[0];                // 1
        s1_bsig_1hot[2] <= ~i_w_bsig[2] &  i_w_bsig[1]; // 2
        s1_bsig_1hot[3] <=  i_w_bsig[2] & ~i_w_bsig[1]; // 4
        s1_bsig_1hot[4] <=  i_w_bsig[2] &  i_w_bsig[1]; // 6

        s2_fin  <= s1_fin;
        s2_last <= s1_last;

        o_fin_ahead1 <= s4_fin;

    end

    always_ff @(posedge gclk_s1_scale) begin
        s1_scale <= i_w_scale;
    end

    always_ff @(posedge gclk_s2_scale) begin
        s2_scale <= s1_scale;
    end

    logic[COL_LEN-1:0][6:0] s4_scale_low7, s4_scale_low7_n;
    logic[COL_LEN-1:0]      s4_scale_bit_n;
    for (genvar c = 0; c < COL_LEN; ++c) begin
        assign s4_scale_low7_n[c]   = s2_scale[c][6:0];
        assign s4_scale_bit_n[c]    = s4_load ? s2_scale[c][7] : |(s4_cycle_1hot[7:1] & s4_scale_low7[c]);
    end

    always_ff @(posedge gclk_s4_0) begin
        s4_scale_low7   <= s4_scale_low7_n;
        s4_fin          <= s2_fin;
    end

    always_ff @(posedge gclk_s4_1 or negedge arstn) begin
        if (~arstn)
            s4_cycle_1hot <= 8'h01; // idle/park state
        else
            s4_cycle_1hot <= {s4_cycle_1hot[0], s4_cycle_1hot[7:1]}; // rotr 1
    end

    assign s4_load = s4_cycle_1hot[0];
    always_ff @(posedge gclk_s4_1) begin
        s4_scale_bit<= s4_scale_bit_n;
    end

endmodule

// contract A: w_scale != 0 (this would be incredibly stupid and make no sense for practical use)
module pe_scratch (
    input   logic           clk,
    input   logic           gclk_s3,
    input   logic           gclk_s4_0,
    input   logic           gclk_s4_1,
    input   logic           gclk_o,

    input   logic[3:0][15:0]a,
    input   logic[3:0][3:0] w_sem, // sign:1, exponent:2, mantissa:1

    input   logic           s1_vld,
    input   logic[4:0]      s1_bsig_1hot,

    input   logic           s2_vld, s2_last,

    input   logic           s4_load,
    input   logic           s4_scale_bit,

    output  logic[5:0]      o_exp,
    output  logic[22:0]     o_man // 2c

);
    logic[5:0]  exp_max;
    logic[3:0]  sum0_lo, sum1_lo;   // {carry_out, sum[2:0]}
    logic[12:0] sum0_hi, sum1_hi;
    // >> s1 registers
    logic       s1_dir;
`ifdef PE_ROUND_LOWER
    logic[4:0]  s1_mag;
`else
    logic[3:0]  s1_mag;
`endif
    logic[5:0]  s1_exp_max;
    logic[15:0] s1_sum0, s1_sum1;
    // << s1 registers

    // >> s2 registers
    logic       s2_dir;
    logic[4:0]  s2_mag;

    logic[5:0]  s2_exp_max;
    logic[22:0] s2_sum;
    // << s2 registers

    logic[5:0]  s3_exp_n;
    logic[22:0] s3_man_n;
    logic       s3_zero;
    // >> s3 registers
    logic[5:0]  s3_exp;
    logic[22:0] s3_man;
    // << s3 registers

    logic[22:0] s4_acc_n;
    // >> s3 registers
    logic[14:0] s4_man;
    logic[5:0]  s4_exp;
    logic[22:0] s4_acc;
    // << s3 registers

    logic[3:0]      a_sign;
    logic[3:0][4:0] a_exp;
    logic[3:0][10:0]a_man;

    logic[3:0]      w_sign;
    logic[3:0][1:0] w_exp;
    logic[3:0]      w_man;
    logic[3:0]      nz;

    logic[3:0][5:0] exp;
    logic[3:0]      sign;
    logic[3:0][13:0]mul;

    for (genvar i = 0; i < 4; ++i) begin
        assign a_sign[i]= a[i][15];
        // assign a_exp[i] = a[i][14:10] != 0 ? a[i][14:10] : 5'd1;
        wire a_normal   = |a[i][14:10];
        assign a_exp[i] = {a[i][14:11], a[i][10] | ~a_normal};
        assign a_man[i] = {a_normal, a[i][9:0]}; // prepended with implicit leading bit (1'b0 iff subnormal)

        assign w_sign[i]= w_sem[i][3];
        assign w_exp[i] = w_sem[i][2:1];
        assign w_man[i] = w_sem[i][0];
        assign nz[i]    = w_man[i]; // "non-zero" weight mantissa

        assign exp[i]   = a_exp[i] + w_exp[i];
        assign sign[i]  = (a_sign[i] ^ w_sign[i]) & w_man[i]; // NOTE(ejs): w_man is gating only (not functional)
        assign mul[i]   = {(a_man[i] & {11{w_man[i]}}), 3'b0};
    end

    logic[6:0]  sub, sub0, sub1;
    logic[6:0]  rsub, rsub0, rsub1;
    logic[5:0]  mag, mag0, mag1;
    logic[5:0]  exp_max0, exp_max1;
    assign sub0 = {1'b0, exp[0]}    - {1'b0, exp[1]};
    assign sub1 = {1'b0, exp[2]}    - {1'b0, exp[3]};
    assign sub  = {1'b0, exp_max0}  - {1'b0, exp_max1};
    assign rsub0= {1'b0, exp[1]}    - {1'b0, exp[0]};
    assign rsub1= {1'b0, exp[3]}    - {1'b0, exp[2]};
    assign rsub = {1'b0, exp_max1}  - {1'b0, exp_max0};
    wire dir0   = sub0[6];
    wire dir1   = sub1[6];
    wire dir    = sub[6];
    /* zdir* := zero-aware direction (to prevent zero-mantissa terms with non-zero
    exponent from winning exp_max, which could shift-annihilate a real term with a smaller exponent)
    TODO(ejs): explain why nz[i] := w_man[i] is sufficient to nearly completely approximate
    nz := w_man[i] & |a_man[i], rendering the later (mostly) unnecessary */
    wire zdir0  = nz[1] & (~nz[0] | sub0[6]);
    wire zdir1  = nz[3] & (~nz[2] | sub1[6]);
    wire zdir   = (nz[2] | nz[3]) & (~(nz[0] | nz[1]) | sub[6]);

    /* Q: Why can we use dir* for mag selection?
    correctness proof: dir* selects the sub/rsub corresponding to the absolute difference
    - both nz       -> don't care
    - one nz, one z -> z is routed into non-shifted path by zdir*
    - both nz       -> abs difference as usual
    benefit: earlier-settling mag reduces glitches into >> barrels
    */
    assign mag0 = dir0 ? rsub0[5:0] : sub0[5:0];
    assign mag1 = dir1 ? rsub1[5:0] : sub1[5:0];
    assign mag  = dir  ? rsub [5:0] : sub [5:0];
    assign exp_max0 = zdir0 ? exp[1]    : exp[0];
    assign exp_max1 = zdir1 ? exp[3]    : exp[2];
    assign exp_max  = zdir  ? exp_max1  : exp_max0;

    logic[13:0] nshf0, nshf1, shf0, shf1;
    logic       nshf0_sign, nshf1_sign, shf0_sign, shf1_sign;
    logic[14:0] mul_xor_nshf0, mul_xor_nshf1;
    logic[14:0] mul_xor_shf0, mul_xor_shf1;
    assign nshf0= zdir0 ? mul[1] : mul[0];
    assign nshf1= zdir1 ? mul[3] : mul[2];
    assign shf0 =(zdir0 ? mul[0] : mul[1]) >> mag0;
    assign shf1 =(zdir1 ? mul[2] : mul[3]) >> mag1;
    assign nshf0_sign   = zdir0 ? sign[1] : sign[0];
    assign nshf1_sign   = zdir1 ? sign[3] : sign[2];
    assign shf0_sign    = zdir0 ? sign[0] : sign[1];
    assign shf1_sign    = zdir1 ? sign[2] : sign[3];
    assign mul_xor_nshf0= {1'b0, nshf0} ^ {15{nshf0_sign}};
    assign mul_xor_nshf1= {1'b0, nshf1} ^ {15{nshf1_sign}};
    assign mul_xor_shf0 = {1'b0, shf0}  ^ {15{shf0_sign}};
    assign mul_xor_shf1 = {1'b0, shf1}  ^ {15{shf1_sign}};

    assign sum0_lo  = {1'b0, mul_xor_shf0[2:0]} + shf0_sign;
    assign sum1_lo  = {1'b0, mul_xor_shf1[2:0]} + shf1_sign;
    assign sum0_hi  = 13'($signed(mul_xor_nshf0[14:3])) + 13'($signed(mul_xor_shf0[14:3])) + nshf0_sign + sum0_lo[3];
    assign sum1_hi  = 13'($signed(mul_xor_nshf1[14:3])) + 13'($signed(mul_xor_shf1[14:3])) + nshf1_sign + sum1_lo[3];

    // ==== direction and mag lookahead
    logic ovf;
    // NOTE(ejs): simplified (s2_vld & ~s2_last & ~s3_zero & ovf) -> (s2_vld & ~s2_last & ovf) because ovf (twop 2 bits differ) guarantees ~s3_zero
    wire[5:0]   exp_s2_s3   =((s2_vld & ~s2_dir) ? s2_exp_max : s3_exp) + 6'({4'b0, s2_vld & ~s2_last & ovf});
    wire[6:0]   sub_s1_s23  = {1'b0, s1_exp_max}- {1'b0, exp_s2_s3};
    wire[6:0]   sub_s23_s1  = {1'b0, exp_s2_s3} - {1'b0, s1_exp_max};
    wire        dir_s1_s23  = sub_s1_s23[6];
    wire[5:0]   mag_s1_s23  = dir_s1_s23 ? sub_s23_s1[5:0] : sub_s1_s23[5:0];
    wire[5:0]   s2_mag_n    = (s2_vld & s2_last) ? s1_exp_max: mag_s1_s23; 

    // lazily normalize to 23 bits on overflow
`ifdef PE_ROUND_LOWER
    wire[5:0]   s3_exp_n_raw= s2_dir ? s3_exp : s2_exp_max;
    wire[23:0]  s3_addend   = 24'($signed({(s2_dir ? s2_sum : s3_man), 1'b0})) >>> s2_mag;
    wire[23:0]  s3_man_n_raw= // sum with 1 overflow bit
        24'($signed(s2_dir ? s3_man : s2_sum))
    +   24'($signed(s3_addend[23:1]))
    +   24'(s3_addend[0]);
`else
    wire[5:0]   s3_exp_n_raw =  s2_dir ? s3_exp : s2_exp_max;
    wire[23:0]  s3_man_n_raw = // sum with 1 overflow bit
        24'($signed(            s2_dir ? s3_man : s2_sum))
    +   24'($signed(23'($signed(s2_dir ? s2_sum : s3_man)) >>> s2_mag));
`endif


    assign ovf      = s3_man_n_raw[23] ^ s3_man_n_raw[22];
    assign s3_exp_n = s3_zero ? '0 : s3_exp_n_raw + {5'b0, ovf};
    assign s3_man_n = ovf ? s3_man_n_raw[23:1] : s3_man_n_raw[22:0]; // shfr 1
    assign s3_zero  = ~|s3_man_n_raw;

    logic[5:0]  s3_norm_exp;
    logic[23:0] s3_norm_man;
    assign s3_norm_exp = s3_exp_n_raw & { 6{(s2_vld & s2_last)}}; // data-gate operands to normalizer
    // assign s3_norm_exp = s3_exp_n_raw & { 6{(s2_vld & s2_last & ~s3_zero)}}; // data-gate operands to normalizer
    assign s3_norm_man = s3_man_n_raw & {24{(s2_vld & s2_last)}};

    logic[3:0] shamt;
    logic[13:0]s4_man_data;
    always_comb begin
        unique casez (s3_norm_man[22:14] ^ {9{s3_norm_man[23]}})
        9'b1????????: begin shamt = 9; s4_man_data = s3_norm_man[22:9]; end
        9'b01???????: begin shamt = 8; s4_man_data = s3_norm_man[21:8]; end
        9'b001??????: begin shamt = 7; s4_man_data = s3_norm_man[20:7]; end
        9'b0001?????: begin shamt = 6; s4_man_data = s3_norm_man[19:6]; end
        9'b00001????: begin shamt = 5; s4_man_data = s3_norm_man[18:5]; end
        9'b000001???: begin shamt = 4; s4_man_data = s3_norm_man[17:4]; end
        9'b0000001??: begin shamt = 3; s4_man_data = s3_norm_man[16:3]; end
        9'b00000001?: begin shamt = 2; s4_man_data = s3_norm_man[15:2]; end
        9'b000000001: begin shamt = 1; s4_man_data = s3_norm_man[14:1]; end
        9'b000000000: begin shamt = 0; s4_man_data = s3_norm_man[13:0]; end
        default:      begin shamt ='x; s4_man_data = 'x; end
        endcase
    end

    logic[5:0]  s4_exp_n;
    logic[14:0] s4_man_n;
    assign s4_exp_n = s3_zero ? '0 : s3_norm_exp + shamt;
    // assign s4_exp_n = s3_norm_exp + shamt;
    assign s4_man_n = {s3_norm_man[23], s4_man_data};

    assign s4_acc_n = 23'($signed(s4_man & {15{s4_scale_bit}})) + 23'($signed(s4_acc << 1));

`ifdef PE_ROUND_LOWER
    wire[16:0] s2_addend = 17'($signed({(s1_dir ? s1_sum0 : s1_sum1), 1'b0})) >>> s1_mag;
    wire[16:0] y =
        17'($signed(s1_dir ? s1_sum1 : s1_sum0))
    +   17'($signed(s2_addend[16:1]))
    +   17'(s2_addend[0]);
`else
    wire[16:0] y =
        17'($signed(            s1_dir ? s1_sum1 : s1_sum0))
    +   17'($signed(16'($signed(s1_dir ? s1_sum0 : s1_sum1) >>> s1_mag)));
`endif

    // custom 1-hot shift decoder for bsig
    localparam int SH [5] = '{0, 1, 2, 4, 6};
    function automatic int nsign(input int b);   // legs whose source is y[16]
        nsign = 0;
        for (int k = 0; k < 5; ++k)
            if (b - SH[k] >= 16)
                ++nsign;
    endfunction

    wire g1 = ~(s1_bsig_1hot[2] | s1_bsig_1hot[3] | s1_bsig_1hot[4]);   // bsig <= 1
    wire g2 = ~(s1_bsig_1hot[3] | s1_bsig_1hot[4]);                     // bsig <= 2
    wire g4 = ~ s1_bsig_1hot[4];                                        // bsig <= 4
    logic[22:0] s2_sum_n; // = $signed(y) << bsig
    for (genvar b = 0; b < 23; ++b) begin : g_b
        localparam int P = nsign(b);
        if (P == 5) begin
            assign s2_sum_n[b] = y[16]; // b == 22

        end else begin
            wire ctl =
                (P == 0) ? 1'b0             :
                (P == 1) ? s1_bsig_1hot[0]  :
                (P == 2) ? g1               :
                (P == 3) ? g2               : g4;

            wire[4:0] leg;
            for (genvar k = 0; k < 5; ++k)
                if (b < SH[k] || b - SH[k] >= 16)
                    assign leg[k] = 1'b0;
                else
                    assign leg[k] = s1_bsig_1hot[k] & y[b - SH[k]];
            assign s2_sum_n[b] = (P == 0 ? 1'b0 : ctl & y[16]) | (|leg);

        end
    end

    always_ff @(posedge clk) begin
        s1_exp_max  <= exp_max & {6{|nz}};
        s1_sum0     <= {sum0_hi, sum0_lo[2:0]};
        s1_sum1     <= {sum1_hi, sum1_lo[2:0]};
        s1_dir      <= zdir;
`ifdef PE_ROUND_LOWER
        // s1_mag      <= |mag[5:4] ? 5'd16 : mag[4:0]; // s1_mag<= mag >= 5'd16 ? 5'd16 : mag[4:0];
        s1_mag      <= mag >= 6'd16 ? 5'd16 : mag[4:0];
        // s1_mag      <= mag[4:0] | {5{mag[5]}};  // 17-bit signed, >>>16..31 all identical
`else
        s1_mag      <= mag >= 6'd15 ? 5'd15 : mag[3:0];
        // s1_mag      <= mag[3:0] | {4{|mag[5:4]}}; // 16-bit signed, >>>15 is all-sign
`endif

        s2_dir      <= (s2_vld & (s2_last | s3_zero))   ? 1'b0      : dir_s1_s23;
        s2_mag      <= s2_mag_n >= 5'd23 ? 5'd23 : s2_mag_n[4:0];
        // s2_mag      <= s2_mag_n[4:0] | {5{s2_mag_n[5]}};  // 24-bit signed, >>>23..31 identical
        // s2_mag      <= (s2_vld & s2_last) ? '0 : (s2_mag_n >= 6'23 ? 5'd23 : s2_mag_n[4:0]);
        // s2_mag      <= (s2_vld & s2_last)               ? s1_exp_max: mag_s1_s23;
        s2_exp_max  <= s1_exp_max;
        s2_sum      <= s2_sum_n;
// `ifdef PE_ROUND_LOWER
//         s2_sum      <= 23'($signed(
//             17'($signed(s1_dir ? s1_sum1 : s1_sum0))
//         +   17'($signed(s2_addend[16:1]))
//         +   17'(s2_addend[0])
//         )) << s1_bsig;
// `else
//         s2_sum      <= 23'($signed(
//             17'($signed(            s1_dir ? s1_sum1 : s1_sum0))
//         +   17'($signed(16'($signed(s1_dir ? s1_sum0 : s1_sum1) >>> s1_mag)))
//         )) << s1_bsig;
// `endif

        // if (s2_vld) begin
        //     s3_man  <= s2_last ? '0 : s3_man_n;
        //     s3_exp  <= s2_last ? '0 : s3_exp_n;

        // end

    end

    // cg to prevent synth inferring recirculation muxes (save ~5uW vs. sd_vld guard under clk domain)
    always_ff @(posedge gclk_s3) begin
        s3_man <= s2_last ? '0 : s3_man_n;
        s3_exp <= s2_last ? '0 : s3_exp_n;
    end

    always_ff @(posedge gclk_s4_0) begin
        s4_man <= s4_man_n;
        s4_exp <= s4_exp_n;
    end

    always_ff @(posedge gclk_s4_1) begin
        s4_acc <= s4_load ? '0 : s4_acc_n;
    end

    always_ff @(posedge gclk_o) begin
        // o_exp <= |s4_acc_n ? s4_exp : '0;   // ...if contract A was not upheld (0 scale would zero the mantissa)
        o_exp <= s4_exp;// ...we can avoid zero-canonicalization assuming contract A
        o_man <= s4_acc_n;
    end

endmodule

// pe_scratch wrapper obeying interface of tb_pe_power
module pe_scratch_with_control (
    input   logic           clk,
    input   logic           arstn,

    input   logic           i_vld,
    input   logic           i_vld_first_group,
    input   logic           i_fin,
    input   logic           i_last,

    input   logic[3:0][15:0]a,
    input   logic[3:0][3:0] w_sem, // sign:1, exponent:2, mantissa:1
    input   logic[2:0]      w_bsig,
    input   logic[7:0]      w_scale,

    output  logic           o_vld_ahead1,
    output  logic           o_fin_ahead1,
    output  logic[5:0]      o_exp,
    output  logic[22:0]     o_man // 2c

);
    logic       gclk_i_vld_first_group;
    logic       gclk_s3;
    logic       gclk_s4_0;
    logic       gclk_s4_1;
    logic       gclk_o;

    logic       s1_vld;
    logic[4:0]  s1_bsig_1hot;

    logic       s2_vld, s2_last;

    logic       s4_load;
    logic       s4_scale_bit;

    tech_icg cg_i_vld_first_group (.clk(clk), .en(i_vld_first_group), .gclk(gclk_i_vld_first_group));

    /* We disable pe_scratch_common clock-gating for a fair comparison against
    other, older pe variants. Priority is to compare and optimize combinational power */
    pe_scratch_common #(.COL_LEN(1), .ROW_LEN(1)) common (
        .clk            (clk),
        .arstn          (arstn),
        .gclk_s1_scale  (gclk_i_vld_first_group),
        .gclk_s3        (gclk_s3),
        .gclk_s4_0      (gclk_s4_0),
        .gclk_s4_1      (gclk_s4_1),
        .gclk_o         (gclk_o),

        .i_vld          (i_vld),
        .i_vld_first_group(i_vld_first_group),
        .i_fin          (i_fin),
        .i_last         (i_last),
        .i_w_bsig       (w_bsig),
        .i_w_scale      (w_scale),

        .s1_vld         (s1_vld),
        .s1_bsig_1hot   (s1_bsig_1hot),

        .s2_vld         (s2_vld),
        .s2_last        (s2_last),

        .s4_load        (s4_load),
        .s4_scale_bit   (s4_scale_bit),

        .o_vld_ahead1   (o_vld_ahead1),
        .o_fin_ahead1   (o_fin_ahead1)

    );

    pe_scratch pe (
        .clk            (clk),
        .gclk_s3        (gclk_s3),
        .gclk_s4_0      (gclk_s4_0),
        .gclk_s4_1      (gclk_s4_1),
        .gclk_o         (gclk_o),

        .a              (a),
        .w_sem          (w_sem),

        .s1_vld         (s1_vld),
        .s1_bsig_1hot   (s1_bsig_1hot),

        .s2_vld         (s2_vld),
        .s2_last        (s2_last),

        .s4_load        (s4_load),
        .s4_scale_bit   (s4_scale_bit),

        .o_exp          (o_exp),
        .o_man          (o_man)
    );

endmodule
`endif
