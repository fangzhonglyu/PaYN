`ifndef PAYN_EDGE_SV
`define PAYN_EDGE_SV

`timescale 1ns/1ps

// Closed-form C-BSG A count for one element, no Sobol stream:
//
//     kA = #{t < L : ((Xq(t) ^ mask) >> 1) < b}
//
// with Xq the identity-direction ("q") Gray-code Sobol word and
// mask = bitrev8(d mod 64) for column d = K*p + k (lane k of block p): the
// lane bits bitrev(k) in mask[7:8-log2K], the phase bits bitrev(p) below
// them, mask[1:0] = 0.  [0, L) splits into aligned dyadic
// blocks, largest first.  Set bit j of L is a block of 2^j samples starting
// at s0 = (the bits of L above j); across it the top j bits of the word take
// every value and the low part is the constant
//     c_j = ((bitrev8(gray(s0)) ^ mask) mod 2^(8-j)) >> 1          (s = 7-j bits)
// so the block contributes (b >> s) + [(b mod 2^s) > c_j].  One s-bit compare
// per bit of L and an adder of at most eight terms; no subtractor, no clamp.
// kA <= L <= 128.  Port of model/cbsg.py ka_closed (exhaustive over
// (L, mask, b) there and in tb/test_payn_units.sv).
//
// K (lanes per block, 8 or 16) and LANE (k) are parameters, so the lane mask
// bits are constants per instance.
module PaynKaEncoder #(
    parameter int K = 16,
    parameter int LANE = 0
) (
    input  logic [7:0] b,                          // magnitude 0..128
    input  logic [7:0] len,                        // row stream length L, 1..128
    input  logic [6 - $clog2(K) - 1:0] phase,      // block phase p
    output logic [7:0] ka
);
    localparam int LB = $clog2(K);                 // lane bits of d
    localparam int PB = 6 - LB;                    // phase bits of d

    // mask[7-i] = d[i]: lane bits first, then the phase.
    function automatic logic [7:0] lane_mask(input int lane);
        lane_mask = '0;
        for (int i = 0; i < LB; i++)
            lane_mask[7 - i] = (lane >> i) & 1;
    endfunction
    localparam logic [7:0] LANE_MASK = lane_mask(LANE);

    initial begin
        assert ((K == 8 || K == 16) && LANE >= 0 && LANE < K)
            else $fatal(1, "PaynKaEncoder needs K 8 or 16 and LANE 0..K-1 (got K=%0d LANE=%0d)", K, LANE);
    end

    logic [7:0] phase_mask;
    always_comb begin
        phase_mask = '0;
        for (int i = 0; i < PB; i++)
            phase_mask[7 - LB - i] = phase[i];
    end

    logic [7:0] mask;
    assign mask = LANE_MASK | phase_mask;

    logic [8:0] above;
    logic [7:0] s0;
    logic [7:0] gray_s0;
    logic [7:0] low;
    logic [6:0] c;
    logic [7:0] b_low;
    logic [7:0] sum;

    always_comb begin
        sum = '0;
        for (int j = 7; j >= 0; j--) begin
            above = 9'h1FE << j;                          // bits j+1..8
            s0 = len & above[7:0];                        // L's bits above j
            gray_s0 = s0 ^ (s0 >> 1);
            for (int i = 0; i < 8; i++)
                low[i] = gray_s0[7-i] ^ mask[i];          // bitrev8(gray) ^ mask
            low = low & ((9'h001 << (8 - j)) - 9'h001);   // mod 2^(8-j)
            c = 7'(low >> 1);
            b_low = b & ((8'h01 << (7 - j)) - 8'h01);     // b mod 2^s
            if (len[j])
                sum = sum + (b >> (7 - j)) + 8'(b_low > {1'b0, c});
        end
        ka = sum;
    end
endmodule

// Edge peripheral of one PE: binary operands in, packed stochastic streams
// out (a_bits[(h*K+k)*M + m], w_bits[(v*K+k)*M + m], signs).
//
// SC mode, A-first C-BSG, K lanes x M positions (K8/M16 or K16/M8),
// LM = log2(M):
//   A, per element (h, k): kA = PaynKaEncoder(b, L_h, mask(k, p)) and the
//     thermometer a_bit[m] = (M*cyc + m) < kA, built as one compare per
//     element shared by the M positions plus a constant low-bits decode:
//         bit[m] = (cyc < kA[7:LM]) | ((cyc == kA[7:LM]) & (m < kA[LM-1:0])).
//     No A Sobol bank and no A comparators.
//   W, per (v, k, m): w_bit = b_w > ((x(M*cyc + m) ^ mask) >> 1), i.e.
//     b_w > (w_words[m] ^ (lane bits of the mask >> 1)); PaynStreamGen already
//     folded the phase bits into the lane words.
//
// INT mode, raw-bit bypass after the SC stream logic, one AO21 per bit:
//
//     a_bits = sc_a_bits | (a_raw_in & int_mode)
//     w_bits = sc_w_bits | (w_raw_in & int_mode)
//
// int_mode is the top's registered mode bit, so the 2,048-pin select hangs
// off a flop.  With int_mode = 0 the raw lines reach nothing.  INT exactness
// needs sc_a_bits and sc_w_bits silent, which the INT contract gets from zero
// magnitudes instead of a gate: b = 0 makes every term of the kA encoder 0, so
// kA = 0 for every L, lane and phase and the thermometer is 0 for every cyc;
// b_w = 0 makes every W comparator 0 > threshold = 0.  The INT sign loads
// already exist and carry those zero magnitudes, so silence costs no
// hardware (a gate would cost ~512 AND2 on the W magnitudes).
//
// Registers (asynchronous reset, separate load enables so the A and W banks
// clock-gate separately): A magnitudes, A signs and the per-row stream length
// L on load_a; W magnitudes and W signs on load_w.  Magnitudes are 8 bits,
// 0..128 (b = round(|q| * 128/127)); L is 1..128.
module PaynEdge #(
    parameter int K = 16,
    parameter int M = 8,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int WIDTH = 8
) (
    input logic clk,
    input logic reset,
    input logic load_a,
    input logic load_w,

    input logic [N_H*K*WIDTH-1:0] a_binary_in,
    input logic [N_H*K-1:0] a_signs_in,
    input logic [N_H*WIDTH-1:0] a_len_in,
    input logic [N_W*K*WIDTH-1:0] w_binary_in,
    input logic [N_W*K-1:0] w_signs_in,

    input logic [$clog2(128/M + 1)-1:0] cyc,
    input logic [6 - $clog2(K) - 1:0] phase,
    input logic [M*(WIDTH-1)-1:0] w_words,

    // INT mode: registered mode bit and raw bit-plane operands, same packing
    // as a_bits / w_bits.
    input logic int_mode,
    input logic [N_H*K*M-1:0] a_raw_in,
    input logic [N_W*K*M-1:0] w_raw_in,

    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0] a_signs,
    output logic [N_W*K*M-1:0] w_bits,
    output logic [N_W*K-1:0] w_signs
);
    localparam int TW = WIDTH - 1;
    localparam int LM = $clog2(M);
    localparam int LB = $clog2(K);

    // Lane bits of the mask in the 7-bit threshold: d[i] = lane[i] sits in
    // mask bit 7-i, i.e. threshold bit 6-i.
    function automatic logic [TW-1:0] lane_threshold_mask(input int lane);
        lane_threshold_mask = '0;
        for (int i = 0; i < LB; i++)
            lane_threshold_mask[6 - i] = (lane >> i) & 1;
    endfunction

    initial begin
        assert (((K == 8 && M == 16) || (K == 16 && M == 8)) && WIDTH == 8)
            else $fatal(1, "PaynEdge is built for the C-BSG block: K8/M16 or K16/M8, WIDTH=8 (got K=%0d M=%0d WIDTH=%0d)",
                        K, M, WIDTH);
        assert (N_H > 0 && N_W > 0)
            else $fatal(1, "N_H and N_W must be positive");
    end

    logic [N_H*K*WIDTH-1:0] a_binary_q;
    logic [N_H*K-1:0] a_signs_q;
    logic [N_H*WIDTH-1:0] a_len_q;
    logic [N_W*K*WIDTH-1:0] w_binary_q;
    logic [N_W*K-1:0] w_signs_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            a_binary_q <= '0;
            a_signs_q <= '0;
            a_len_q <= '0;
        end else if (load_a) begin
            a_binary_q <= a_binary_in;
            a_signs_q <= a_signs_in;
            a_len_q <= a_len_in;
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            w_binary_q <= '0;
            w_signs_q <= '0;
        end else if (load_w) begin
            w_binary_q <= w_binary_in;
            w_signs_q <= w_signs_in;
        end
    end

    assign a_signs = a_signs_q;
    assign w_signs = w_signs_q;

    // SC stream bits before the INT bypass (the top's INT contract check reads
    // them by these names).
    logic [N_H*K*M-1:0] sc_a_bits;
    logic [N_W*K*M-1:0] sc_w_bits;

    assign a_bits = sc_a_bits | (a_raw_in & {(N_H*K*M){int_mode}});
    assign w_bits = sc_w_bits | (w_raw_in & {(N_W*K*M){int_mode}});

    // kA of every A element, (h*K + k)*8 +: 8.  Kept as one named vector: the
    // functional bench's NEG_KA_EQ_B control forces it to min(b, L).
    logic [N_H*K*WIDTH-1:0] ka_flat;

    for (genvar row = 0; row < N_H; row++) begin : g_a_row
        for (genvar depth = 0; depth < K; depth++) begin : g_a_depth
            logic [WIDTH-1:0] ka;
            logic ka_hi_gt;
            logic ka_hi_eq;

            PaynKaEncoder #(.K(K), .LANE(depth)) u_ka (
                .b(a_binary_q[(row*K + depth)*WIDTH +: WIDTH]),
                .len(a_len_q[row*WIDTH +: WIDTH]),
                .phase,
                .ka(ka_flat[(row*K + depth)*WIDTH +: WIDTH])
            );

            assign ka = ka_flat[(row*K + depth)*WIDTH +: WIDTH];
            assign ka_hi_gt = cyc < ka[7:LM];
            assign ka_hi_eq = cyc == ka[7:LM];

            for (genvar lane = 0; lane < M; lane++) begin : g_a_lane
                assign sc_a_bits[(row*K + depth)*M + lane] =
                    ka_hi_gt || (ka_hi_eq && (LM'(lane) < ka[LM-1:0]));
            end
        end
    end

    for (genvar col = 0; col < N_W; col++) begin : g_w_col
        for (genvar depth = 0; depth < K; depth++) begin : g_w_depth
            localparam logic [TW-1:0] LANE_MASK = lane_threshold_mask(depth);

            for (genvar lane = 0; lane < M; lane++) begin : g_w_lane
                logic [TW-1:0] threshold;

                assign threshold = w_words[lane*TW +: TW] ^ LANE_MASK;
                assign sc_w_bits[(col*K + depth)*M + lane] =
                    w_binary_q[(col*K + depth)*WIDTH +: WIDTH] >
                    {1'b0, threshold};
            end
        end
    end
endmodule

`endif
