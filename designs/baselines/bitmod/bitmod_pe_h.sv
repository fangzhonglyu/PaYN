`ifndef BITMOD_PE_H_SV
`define BITMOD_PE_H_SV
`include "baselines/bitmod/bitmod_defs.svh"
// Analysis copy of pe_scratch (bitmod_pe.sv) with one submodule per function, so synthesis, APR and PrimeTime
// report area and power by block.  Every expression and register is copied verbatim from pe_scratch; only module
// boundaries are new (pe_scratch itself is untouched).  No port duplicates another: a netlist output that aliases
// another net is written as an `assign`, which the routed-SDF audit rejects, so bmh_pairadd reads the negation
// carry-ins as bit 14 of the XORed buses (equal to the sign by construction) instead of as separate ports.
// Equivalence: tb/eq_pe_scratch_h.sv drives pe_scratch and
// pe_scratch_h with identical random inputs and compares every pipeline register and output every cycle.
//
//   u_lanes    4 lanes: FP16 activation decode, weight-term decode, exponent add, gated significand ("products")
//   u_align    pairwise exponent compare, exp_max, the two alignment shifters, sign XOR; s1_exp_max / s1_dir / s1_mag
//   u_pairadd  the two pair adders (with the negation carry-ins); s1_sum0 / s1_sum1
//   u_merge    pair merge (y = big + small >>> s1_mag) and the 1-hot bsig shifter; s2_sum / s2_exp_max
//   u_acc      beat accumulator: s2/s3 look-ahead, swap + align + add, overflow; s2_dir / s2_mag, s3_man / s3_exp
//   u_norm     end-of-group normalizer (leading-one detect); s4_man / s4_exp
//   u_scale    group-scale bit-serial multiply; s4_acc, o_exp / o_man

module bmh_lanes (
    input   logic[3:0][15:0]a,
    input   logic[3:0][3:0] w_sem,
    output  logic[3:0][5:0] exp,
    output  logic[3:0]      sign,
    output  logic[3:0][13:0]mul,
    output  logic[3:0]      nz
);
    logic[3:0]      a_sign;
    logic[3:0][4:0] a_exp;
    logic[3:0][10:0]a_man;

    logic[3:0]      w_sign;
    logic[3:0][1:0] w_exp;
    logic[3:0]      w_man;

    for (genvar i = 0; i < 4; ++i) begin
        assign a_sign[i]= a[i][15];
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
endmodule

module bmh_align (
    input   logic           clk,
    input   logic[3:0][5:0] exp,
    input   logic[3:0]      sign,
    input   logic[3:0][13:0]mul,
    input   logic[3:0]      nz,
    output  logic[14:0]     mul_xor_nshf0, mul_xor_nshf1,
    output  logic[14:0]     mul_xor_shf0, mul_xor_shf1,
    output  logic[5:0]      s1_exp_max,
    output  logic           s1_dir,
`ifdef PE_ROUND_LOWER
    output  logic[4:0]      s1_mag
`else
    output  logic[3:0]      s1_mag
`endif
);
    logic[5:0]  exp_max;
    logic[6:0]  sub, sub0, sub1;
    logic[6:0]  rsub, rsub0, rsub1;
    logic[5:0]  mag, mag0, mag1;
    logic[5:0]  exp_max0, exp_max1;
    logic       nshf0_sign, nshf1_sign, shf0_sign, shf1_sign;
    assign sub0 = {1'b0, exp[0]}    - {1'b0, exp[1]};
    assign sub1 = {1'b0, exp[2]}    - {1'b0, exp[3]};
    assign sub  = {1'b0, exp_max0}  - {1'b0, exp_max1};
    assign rsub0= {1'b0, exp[1]}    - {1'b0, exp[0]};
    assign rsub1= {1'b0, exp[3]}    - {1'b0, exp[2]};
    assign rsub = {1'b0, exp_max1}  - {1'b0, exp_max0};
    wire dir0   = sub0[6];
    wire dir1   = sub1[6];
    wire dir    = sub[6];
    wire zdir0  = nz[1] & (~nz[0] | sub0[6]);
    wire zdir1  = nz[3] & (~nz[2] | sub1[6]);
    wire zdir   = (nz[2] | nz[3]) & (~(nz[0] | nz[1]) | sub[6]);

    assign mag0 = dir0 ? rsub0[5:0] : sub0[5:0];
    assign mag1 = dir1 ? rsub1[5:0] : sub1[5:0];
    assign mag  = dir  ? rsub [5:0] : sub [5:0];
    assign exp_max0 = zdir0 ? exp[1]    : exp[0];
    assign exp_max1 = zdir1 ? exp[3]    : exp[2];
    assign exp_max  = zdir  ? exp_max1  : exp_max0;

    logic[13:0] nshf0, nshf1, shf0, shf1;
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

    always_ff @(posedge clk) begin
        s1_exp_max  <= exp_max & {6{|nz}};
        s1_dir      <= zdir;
`ifdef PE_ROUND_LOWER
        s1_mag      <= mag >= 6'd16 ? 5'd16 : mag[4:0];
`else
        s1_mag      <= mag >= 6'd15 ? 5'd15 : mag[3:0];
`endif
    end
endmodule

module bmh_pairadd (
    input   logic           clk,
    input   logic[14:0]     mul_xor_nshf0, mul_xor_nshf1,
    input   logic[14:0]     mul_xor_shf0, mul_xor_shf1,
    output  logic[15:0]     s1_sum0, s1_sum1
);
    wire nshf0_sign = mul_xor_nshf0[14], nshf1_sign = mul_xor_nshf1[14];   // = 1'b0 ^ sign (bmh_align)
    wire shf0_sign  = mul_xor_shf0[14],  shf1_sign  = mul_xor_shf1[14];
    logic[3:0]  sum0_lo, sum1_lo;   // {carry_out, sum[2:0]}
    logic[12:0] sum0_hi, sum1_hi;
    assign sum0_lo  = {1'b0, mul_xor_shf0[2:0]} + shf0_sign;
    assign sum1_lo  = {1'b0, mul_xor_shf1[2:0]} + shf1_sign;
    assign sum0_hi  = 13'($signed(mul_xor_nshf0[14:3])) + 13'($signed(mul_xor_shf0[14:3])) + nshf0_sign + sum0_lo[3];
    assign sum1_hi  = 13'($signed(mul_xor_nshf1[14:3])) + 13'($signed(mul_xor_shf1[14:3])) + nshf1_sign + sum1_lo[3];

    always_ff @(posedge clk) begin
        s1_sum0     <= {sum0_hi, sum0_lo[2:0]};
        s1_sum1     <= {sum1_hi, sum1_lo[2:0]};
    end
endmodule

module bmh_merge (
    input   logic           clk,
    input   logic           s1_dir,
`ifdef PE_ROUND_LOWER
    input   logic[4:0]      s1_mag,
`else
    input   logic[3:0]      s1_mag,
`endif
    input   logic[15:0]     s1_sum0, s1_sum1,
    input   logic[4:0]      s1_bsig_1hot,
    input   logic[5:0]      s1_exp_max,
    output  logic[5:0]      s2_exp_max,
    output  logic[22:0]     s2_sum
);
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
        s2_exp_max  <= s1_exp_max;
        s2_sum      <= s2_sum_n;
    end
endmodule

module bmh_acc (
    input   logic           clk,
    input   logic           gclk_s3,
    input   logic           s2_vld, s2_last,
    input   logic[5:0]      s1_exp_max,
    input   logic[5:0]      s2_exp_max,
    input   logic[22:0]     s2_sum,
    output  logic[5:0]      s3_exp_n_raw,
    output  logic[23:0]     s3_man_n_raw,
    output  logic           s3_zero
);
    logic       s2_dir;
    logic[4:0]  s2_mag;
    logic[5:0]  s3_exp_n;
    logic[22:0] s3_man_n;
    logic[5:0]  s3_exp;
    logic[22:0] s3_man;

    // ==== direction and mag lookahead
    logic ovf;
    wire[5:0]   exp_s2_s3   =((s2_vld & ~s2_dir) ? s2_exp_max : s3_exp) + 6'({4'b0, s2_vld & ~s2_last & ovf});
    wire[6:0]   sub_s1_s23  = {1'b0, s1_exp_max}- {1'b0, exp_s2_s3};
    wire[6:0]   sub_s23_s1  = {1'b0, exp_s2_s3} - {1'b0, s1_exp_max};
    wire        dir_s1_s23  = sub_s1_s23[6];
    wire[5:0]   mag_s1_s23  = dir_s1_s23 ? sub_s23_s1[5:0] : sub_s1_s23[5:0];
    wire[5:0]   s2_mag_n    = (s2_vld & s2_last) ? s1_exp_max: mag_s1_s23;

    // lazily normalize to 23 bits on overflow
`ifdef PE_ROUND_LOWER
    assign      s3_exp_n_raw= s2_dir ? s3_exp : s2_exp_max;
    wire[23:0]  s3_addend   = 24'($signed({(s2_dir ? s2_sum : s3_man), 1'b0})) >>> s2_mag;
    assign      s3_man_n_raw= // sum with 1 overflow bit
        24'($signed(s2_dir ? s3_man : s2_sum))
    +   24'($signed(s3_addend[23:1]))
    +   24'(s3_addend[0]);
`else
    assign      s3_exp_n_raw =  s2_dir ? s3_exp : s2_exp_max;
    assign      s3_man_n_raw = // sum with 1 overflow bit
        24'($signed(            s2_dir ? s3_man : s2_sum))
    +   24'($signed(23'($signed(s2_dir ? s2_sum : s3_man)) >>> s2_mag));
`endif

    assign ovf      = s3_man_n_raw[23] ^ s3_man_n_raw[22];
    assign s3_exp_n = s3_zero ? '0 : s3_exp_n_raw + {5'b0, ovf};
    assign s3_man_n = ovf ? s3_man_n_raw[23:1] : s3_man_n_raw[22:0]; // shfr 1
    assign s3_zero  = ~|s3_man_n_raw;

    always_ff @(posedge clk) begin
        s2_dir      <= (s2_vld & (s2_last | s3_zero))   ? 1'b0      : dir_s1_s23;
        s2_mag      <= s2_mag_n >= 5'd23 ? 5'd23 : s2_mag_n[4:0];
    end

    // cg to prevent synth inferring recirculation muxes (save ~5uW vs. sd_vld guard under clk domain)
    always_ff @(posedge gclk_s3) begin
        s3_man <= s2_last ? '0 : s3_man_n;
        s3_exp <= s2_last ? '0 : s3_exp_n;
    end
endmodule

module bmh_norm (
    input   logic           gclk_s4_0,
    input   logic           s2_vld, s2_last,
    input   logic[5:0]      s3_exp_n_raw,
    input   logic[23:0]     s3_man_n_raw,
    input   logic           s3_zero,
    output  logic[14:0]     s4_man,
    output  logic[5:0]      s4_exp
);
    logic[5:0]  s3_norm_exp;
    logic[23:0] s3_norm_man;
    assign s3_norm_exp = s3_exp_n_raw & { 6{(s2_vld & s2_last)}}; // data-gate operands to normalizer
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
    assign s4_man_n = {s3_norm_man[23], s4_man_data};

    always_ff @(posedge gclk_s4_0) begin
        s4_man <= s4_man_n;
        s4_exp <= s4_exp_n;
    end
endmodule

module bmh_scale (
    input   logic           gclk_s4_1,
    input   logic           gclk_o,
    input   logic[14:0]     s4_man,
    input   logic[5:0]      s4_exp,
    input   logic           s4_load,
    input   logic           s4_scale_bit,
    output  logic[5:0]      o_exp,
    output  logic[22:0]     o_man // 2c
);
    logic[22:0] s4_acc_n;
    logic[22:0] s4_acc;
    assign s4_acc_n = 23'($signed(s4_man & {15{s4_scale_bit}})) + 23'($signed(s4_acc << 1));

    always_ff @(posedge gclk_s4_1) begin
        s4_acc <= s4_load ? '0 : s4_acc_n;
    end

    always_ff @(posedge gclk_o) begin
        o_exp <= s4_exp;// ...we can avoid zero-canonicalization assuming contract A
        o_man <= s4_acc_n;
    end
endmodule

// Same ports as pe_scratch.
module pe_scratch_h (
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
    logic[3:0][5:0] exp;
    logic[3:0]      sign;
    logic[3:0][13:0]mul;
    logic[3:0]      nz;
    logic[14:0]     mul_xor_nshf0, mul_xor_nshf1, mul_xor_shf0, mul_xor_shf1;
    logic[5:0]      s1_exp_max;
    logic           s1_dir;
`ifdef PE_ROUND_LOWER
    logic[4:0]      s1_mag;
`else
    logic[3:0]      s1_mag;
`endif
    logic[15:0]     s1_sum0, s1_sum1;
    logic[5:0]      s2_exp_max;
    logic[22:0]     s2_sum;
    logic[5:0]      s3_exp_n_raw;
    logic[23:0]     s3_man_n_raw;
    logic           s3_zero;
    logic[14:0]     s4_man;
    logic[5:0]      s4_exp;

    bmh_lanes   u_lanes   (.a, .w_sem, .exp, .sign, .mul, .nz);
    bmh_align   u_align   (.clk, .exp, .sign, .mul, .nz, .mul_xor_nshf0, .mul_xor_nshf1, .mul_xor_shf0, .mul_xor_shf1,
                           .s1_exp_max, .s1_dir, .s1_mag);
    bmh_pairadd u_pairadd (.clk, .mul_xor_nshf0, .mul_xor_nshf1, .mul_xor_shf0, .mul_xor_shf1, .s1_sum0, .s1_sum1);
    bmh_merge   u_merge   (.clk, .s1_dir, .s1_mag, .s1_sum0, .s1_sum1, .s1_bsig_1hot, .s1_exp_max, .s2_exp_max, .s2_sum);
    bmh_acc     u_acc     (.clk, .gclk_s3, .s2_vld, .s2_last, .s1_exp_max, .s2_exp_max, .s2_sum,
                           .s3_exp_n_raw, .s3_man_n_raw, .s3_zero);
    bmh_norm    u_norm    (.gclk_s4_0, .s2_vld, .s2_last, .s3_exp_n_raw, .s3_man_n_raw, .s3_zero, .s4_man, .s4_exp);
    bmh_scale   u_scale   (.gclk_s4_1, .gclk_o, .s4_man, .s4_exp, .s4_load, .s4_scale_bit, .o_exp, .o_man);
endmodule
`endif
