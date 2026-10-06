`ifndef WO_RING_VERIFY_BLOCKS
`define WO_RING_VERIFY_BLOCKS

`timescale 1ns/1ps

// Area-verification RTL for the WO-ring INT mode (design key weight_outer_horner).
// None of this is in the routed design. Each module is one of the INT-only blocks
// the WO-ring proposal needs, written to be synthesized on its own so its cell
// area can replace the hand cell counts in design_round1.json.
//
//   WoRingPeDelta    per PE: x4 drain-ring mux on acc_chain[0] + ring_q flop +
//                    shift_in OR (the only PE-level change the proposal makes)
//   WoFeederA        per A edge half (64 lanes): radix-4 Booth digit select by
//                    pass p, |d| -> per-lane 8-bit comparator code, digit sign,
//                    and the SC/INT source mux in front of a_binary_in/a_signs_in
//   WoFeederW        per W edge half (64 lanes): radix-16 Booth digit select
//                    (q from the pass in FH, q = v&1 in HYS), |d| -> per-lane
//                    9-entry code table, digit sign, and the SC/INT source mux
//   WoCollectorRow   per global row at the east edge: HYS pair combine
//                    X1<<4 + X0 (24-bit hold + 28-bit add), SC bypass
//
// Code tables are the ones model_weight_outer_horner.py derives from its
// PRESET_A / PRESET_W (printed at the top of model_weight_outer_horner.log).
// tb_wo_ring_blocks.sv checks the feeders exhaustively against a dump that
// check_wo_feeder.py compares with the model's own booth_digits + CODE tables.

module WoRingPeDelta #(
    parameter int N_H = 8,
    parameter int OWIDTH = 24
) (
    input  logic clk,
    input  logic reset,
    input  logic ring_in,
    input  logic shift_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,    // from the west PE (SC drain)
    input  logic [N_H*OWIDTH-1:0] acc_out_east,   // tile column N_W-1 canonical acc_out
    output logic [N_H*OWIDTH-1:0] acc_chain0,     // into tile column 0 acc_in
    output logic shift_eff,                       // tile shift_in
    output logic ring_out                         // re-exported east
);
    logic ring_q;
    always_ff @(posedge clk) begin
        if (reset) ring_q <= 1'b0;
        else       ring_q <= ring_in;
    end
    assign ring_out  = ring_q;
    assign shift_eff = shift_in | ring_q;
    for (genvar h = 0; h < N_H; h++) begin : g_row
        logic [OWIDTH-1:0] e;
        assign e = acc_out_east[h*OWIDTH +: OWIDTH];
        assign acc_chain0[h*OWIDTH +: OWIDTH] =
            ring_q ? {e[OWIDTH-3:0], 2'b00} : acc_in_west[h*OWIDTH +: OWIDTH];
    end
endmodule

module WoFeederA #(
    parameter int N_H = 8,
    parameter int K = 8
) (
    input  logic int_mode,
    input  logic [1:0] p,                       // radix-4 digit index of this pass
    input  logic [N_H*K*8-1:0] din,             // SC magnitude, or INT raw byte
    input  logic [N_H*K-1:0]   sin,             // SC sign
    output logic [N_H*K*8-1:0] code_out,        // -> a_binary_in
    output logic [N_H*K-1:0]   sign_out         // -> a_signs_in
);
    localparam logic [7:0] CA1 [8] = '{8'd73, 8'd111, 8'd143, 8'd124, 8'd132, 8'd96, 8'd75, 8'd137};
    localparam logic [7:0] CA2 [8] = '{8'd245, 8'd234, 8'd214, 8'd250, 8'd255, 8'd234, 8'd253, 8'd248};
    for (genvar h = 0; h < N_H; h++) begin : g_h
        for (genvar k = 0; k < K; k++) begin : g_k
            localparam int L = h*K + k;
            logic [7:0] a;
            logic [8:0] ax;
            logic [2:0] win;
            logic one, two, neg;
            logic [7:0] code;
            assign a  = din[L*8 +: 8];
            assign ax = {a, 1'b0};                       // ax[i+1] = a[i], a[-1] = 0
            always_comb begin
                case (p)
                    2'd0: win = ax[2:0];
                    2'd1: win = ax[4:2];
                    2'd2: win = ax[6:4];
                    default: win = ax[8:6];
                endcase
            end
            // d = -2*win[2] + win[1] + win[0]
            assign one  = win[1] ^ win[0];
            assign two  = (win[2] ^ win[1]) & ~(win[1] ^ win[0]);
            assign neg  = win[2] & ~(win[1] & win[0]);
            assign code = ({8{one}} & CA1[k % 8]) | ({8{two}} & CA2[k % 8]);
            assign code_out[L*8 +: 8] = int_mode ? code : a;
            assign sign_out[L]        = int_mode ? neg  : sin[L];
        end
    end
endmodule

module WoFeederW #(
    parameter int N_W = 8,
    parameter int K = 8
) (
    input  logic int_mode,
    input  logic hys,                           // 1: column v carries digit v&1
    input  logic q,                             // FH: radix-16 digit index of this pass
    input  logic [N_W*K*8-1:0] din,             // SC magnitude, or INT raw byte
    input  logic [N_W*K-1:0]   sin,
    output logic [N_W*K*8-1:0] code_out,        // -> w_binary_in
    output logic [N_W*K-1:0]   sign_out         // -> w_signs_in
);
    localparam logic [7:0] CW [8][9] = '{
        '{8'd0, 8'd35, 8'd53, 8'd61, 8'd115, 8'd144, 8'd150, 8'd195, 8'd240},
        '{8'd0, 8'd15, 8'd20, 8'd35, 8'd55, 8'd83, 8'd100, 8'd178, 8'd220},
        '{8'd0, 8'd85, 8'd108, 8'd123, 8'd170, 8'd180, 8'd196, 8'd233, 8'd248},
        '{8'd0, 8'd17, 8'd26, 8'd34, 8'd93, 8'd99, 8'd126, 8'd213, 8'd246},
        '{8'd0, 8'd4, 8'd23, 8'd71, 8'd138, 8'd171, 8'd185, 8'd223, 8'd254},
        '{8'd0, 8'd41, 8'd64, 8'd139, 8'd152, 8'd165, 8'd179, 8'd206, 8'd232},
        '{8'd0, 8'd53, 8'd64, 8'd76, 8'd85, 8'd126, 8'd199, 8'd217, 8'd255},
        '{8'd0, 8'd81, 8'd102, 8'd144, 8'd160, 8'd214, 8'd231, 8'd237, 8'd252}};
    for (genvar v = 0; v < N_W; v++) begin : g_v
        for (genvar k = 0; k < K; k++) begin : g_k
            localparam int L = v*K + k;
            logic [7:0] w;
            logic [8:0] wx;
            logic qe;
            logic [4:0] win;
            logic signed [5:0] d;
            logic [3:0] mag;
            logic neg;
            logic [7:0] code;
            assign w   = din[L*8 +: 8];
            assign wx  = {w, 1'b0};
            assign qe  = hys ? 1'(v & 1) : q;
            assign win = qe ? wx[8:4] : wx[4:0];        // {b3,b2,b1,b0,b-1}
            assign d   = -6'sd8 * $signed({5'b0, win[4]}) + 6'sd4 * $signed({5'b0, win[3]})
                       + 6'sd2 * $signed({5'b0, win[2]}) + $signed({5'b0, win[1]})
                       + $signed({5'b0, win[0]});
            assign neg = d < 0;
            assign mag = neg ? 4'(-d) : 4'(d);
            always_comb begin
                code = '0;
                for (int c = 0; c < 9; c++)
                    if (mag == 4'(c)) code = CW[k % 8][c];
            end
            assign code_out[L*8 +: 8] = int_mode ? code : w;
            assign sign_out[L]        = int_mode ? neg  : sin[L];
        end
    end
endmodule

module WoCollectorRow #(
    parameter int OWIDTH = 24
) (
    input  logic clk,
    input  logic int_mode,
    input  logic phase,                          // 0: X_{j,1} arrives, 1: X_{j,0}
    input  logic signed [OWIDTH-1:0] acc_east,
    output logic signed [OWIDTH+3:0] out
);
    logic signed [OWIDTH-1:0] hold;
    always_ff @(posedge clk)
        if (int_mode && !phase) hold <= acc_east;
    assign out = int_mode ? (($signed({{4{hold[OWIDTH-1]}}, hold}) <<< 4) + acc_east)
                          : (OWIDTH+4)'(acc_east);
endmodule

`endif
