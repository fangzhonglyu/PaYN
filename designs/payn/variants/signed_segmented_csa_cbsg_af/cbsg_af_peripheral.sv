`ifndef PAYN_CBSG_AF_PERIPHERAL
`define PAYN_CBSG_AF_PERIPHERAL

`timescale 1ns/1ps

// Closed-form C-BSG A count for one element, no Sobol stream:
//
//     kA = #{t < L : ((Xq(t) ^ mask) >> 1) < b}
//
// with Xq the identity-direction ("q") Gray-code Sobol word and
// mask = {bitrev3(k), bitrev3(p), 2'b00}.  [0, L) splits into aligned dyadic
// blocks, largest first.  Set bit j of L is a block of 2^j samples starting
// at s0 = (the bits of L above j); across it the top j bits of the word take
// every value and the low part is the constant
//     c_j = ((bitrev8(gray(s0)) ^ mask) mod 2^(8-j)) >> 1          (s = 7-j bits)
// so the block contributes (b >> s) + [(b mod 2^s) > c_j].  One s-bit compare
// per bit of L and an adder of at most eight terms; no subtractor, no clamp.
// kA <= L <= 128.  Port of cbsg_ref.ka_closed (exhaustive check in
// sweeps/cbsg/ka_closed_form.py: 1,056,768 (L, mask, b) cases).
//
// LANE (k) is a parameter, so the lane mask bits are constants per instance.
module CbsgAfKaEncoder #(
    parameter int LANE = 0
) (
    input  logic [7:0] b,         // magnitude 0..128
    input  logic [7:0] len,       // row stream length L, 1..128
    input  logic [2:0] phase,     // block phase p
    output logic [7:0] ka
);
    localparam logic [2:0] LANE_BITS = {LANE[0], LANE[1], LANE[2]};

    initial begin
        assert (LANE >= 0 && LANE < 8)
            else $fatal(1, "CbsgAfKaEncoder LANE must be 0..7 (got %0d)", LANE);
    end

    logic [7:0] mask;
    assign mask = {LANE_BITS, phase[0], phase[1], phase[2], 2'b00};

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

// A-first (AF) C-BSG edge peripheral for one PE: binary operands in, packed
// stochastic streams out, with the outputs and packing of sc_pe_peripheral
// (a_bits[(h*K+k)*M + m], w_bits[(v*K+k)*M + m], signs), so the CSA PE core
// is untouched.
//
//   A, per element (h, k): kA = CbsgAfKaEncoder(b, L_h, mask(k, p)) and the
//     thermometer a_bit[m] = (16*cyc + m) < kA, built as one 4-bit compare per
//     element shared by the 16 positions plus a constant low-nibble decode:
//         bit[m] = (cyc < kA[7:4]) | ((cyc == kA[7:4]) & (m < kA[3:0])).
//     No A Sobol bank and no A comparators.
//   W, per (v, k, m): w_bit = b_w > ((x_k(16*cyc + m) ^ mask) >> 1), i.e.
//     b_w > (w_words[m] ^ {bitrev3(k), 4'b0}); the stream generator already
//     folded the phase bits into the lane words.
//
// Registers (asynchronous reset like sc_pe_peripheral, load enables so the A
// and W banks clock-gate separately): A magnitudes, A signs and the per-row
// stream length L on load_a; W magnitudes and W signs on load_w.  Magnitudes
// are 8 bits, 0..128 (b = round(|q| * 128/127)); L is 1..128.
module CbsgAfPeripheral #(
    parameter int K = 8,
    parameter int M = 16,
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

    input logic [3:0] cyc,
    input logic [2:0] phase,
    input logic [M*(WIDTH-1)-1:0] w_words,

    output logic [N_H*K*M-1:0] a_bits,
    output logic [N_H*K-1:0] a_signs,
    output logic [N_W*K*M-1:0] w_bits,
    output logic [N_W*K-1:0] w_signs
);
    localparam int TW = WIDTH - 1;

    initial begin
        assert (K == 8 && M == 16 && WIDTH == 8)
            else $fatal(1, "CbsgAfPeripheral is built for the C-BSG block: K=8 lanes, M=16, WIDTH=8 (got K=%0d M=%0d WIDTH=%0d)",
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

    // kA of every A element, (h*K + k)*8 +: 8.  Kept as one named vector: the
    // functional bench's NEG_KA_EQ_B control forces it to min(b, L).
    logic [N_H*K*WIDTH-1:0] ka_flat;

    for (genvar row = 0; row < N_H; row++) begin : g_a_row
        for (genvar depth = 0; depth < K; depth++) begin : g_a_depth
            logic [WIDTH-1:0] ka;
            logic ka_hi_gt;
            logic ka_hi_eq;

            CbsgAfKaEncoder #(.LANE(depth)) u_ka (
                .b(a_binary_q[(row*K + depth)*WIDTH +: WIDTH]),
                .len(a_len_q[row*WIDTH +: WIDTH]),
                .phase,
                .ka(ka_flat[(row*K + depth)*WIDTH +: WIDTH])
            );

            assign ka = ka_flat[(row*K + depth)*WIDTH +: WIDTH];
            assign ka_hi_gt = cyc < ka[7:4];
            assign ka_hi_eq = cyc == ka[7:4];

            for (genvar lane = 0; lane < M; lane++) begin : g_a_lane
                assign a_bits[(row*K + depth)*M + lane] =
                    ka_hi_gt || (ka_hi_eq && (4'(lane) < ka[3:0]));
            end
        end
    end

    for (genvar col = 0; col < N_W; col++) begin : g_w_col
        for (genvar depth = 0; depth < K; depth++) begin : g_w_depth
            // bitrev3(k) in mask bits [7:5], i.e. threshold bits [6:4].
            localparam logic [TW-1:0] LANE_MASK = TW'(
                ((depth & 1) << 6) | (((depth >> 1) & 1) << 5) |
                (((depth >> 2) & 1) << 4));

            for (genvar lane = 0; lane < M; lane++) begin : g_w_lane
                logic [TW-1:0] threshold;

                assign threshold = w_words[lane*TW +: TW] ^ LANE_MASK;
                assign w_bits[(col*K + depth)*M + lane] =
                    w_binary_q[(col*K + depth)*WIDTH +: WIDTH] >
                    {1'b0, threshold};
            end
        end
    end
endmodule

`endif
