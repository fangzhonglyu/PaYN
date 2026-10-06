`ifndef PAYN_CBSG_RG_EDGE
`define PAYN_CBSG_RG_EDGE

`timescale 1ns/1ps

// West/south edge of the C-BSG RG (per-row generator) array.
//
//   cbsg_rg_sobol_q_bank  the A sample-ordered Sobol "q" bank, reduced to its
//                         state: the H(c) word and the cycle index c.
//   cbsg_rg_edge_state    one A row's copy of the generation state: a q bank
//                         and a copy of the block phase p; cbsg_rg_edge_state_rep
//                         (the top's u_a_rng) holds one copy per row.
//   cbsg_rg_edge          operand registers (A magnitude, A sign, per-row L,
//                         W magnitude, W sign) and the A comparators with the
//                         per-row length gate.  W magnitudes leave raw: the W
//                         stream is generated inside the PE (C-BSG pairing).
//
// Sample order (scmp_kernels rng.py, soren_PaYN sobol.sv): position m of cycle
// c carries sample t = 16c + m of one Gray-code Sobol sequence,
//
//     x[16c + m] = H(c) ^ LANE(m),   LANE(m) = XOR_{j<4} gray(m)[j] * V[j],
//     H(0) = 0,  H(c+1) = H(c) ^ V[4 + lsz(c)] ^ V[3],
//
// with V the q (identity) direction numbers 80 40 20 10 08 04 02 01.  LANE(m)
// is a constant per position, so the bank holds only H (8 flops) and c (4);
// the 16 sample words are H with constant inversions, folded into the
// comparators.  Every block restarts at t = 0 (H = 0, c = 0).
//
// A bit (row h, lane k, position m):
//
//     a = [ b_A(h,k) > ((x[t] ^ mask_k) >> 1) ]  &  [ t < L_h ]
//     mask_k = { bitrev3(k), bitrev3(p), 2'b00 }     (= bitrev8(d mod 64), d = 8p + k)
//
// p is the 3-bit block phase (the top's phase_q; each row reads its own copy).
// c saturates at 8, so a block run
// past 8 cycles generates t >= 128 >= L_h, i.e. zeros.
//
// FAULT (verification only; live only with +define+CBSG_RG_FAULT_HOOKS, else
// ignored): 1 = lane mask bits k instead of bitrev3(k); 3 = no length gate.

module cbsg_rg_sobol_q_bank #(
    parameter int WIDTH = 8
) (
    input  logic clk,
    input  logic reset,
    input  logic enable,             // rng_en: emit the next cycle on this edge
    input  logic restart,            // block_start: with enable, emit cycle 0
    output logic [WIDTH-1:0] high,   // H(c) of the cycle now on the edge
    output logic [3:0] cycle         // c of the cycle now on the edge, 0..8
);
    initial begin
        assert (WIDTH == 8)
            else $fatal(1, "cbsg_rg_sobol_q_bank: the C-BSG grid needs WIDTH = 8 (got %0d)", WIDTH);
    end

    function automatic logic [WIDTH-1:0] dv(input int j);   // q seed: identity
        dv = '0;
        if (j >= 0 && j < WIDTH) dv[WIDTH-1-j] = 1'b1;
    endfunction

    // H(c+1) = H(c) ^ V[4 + lsz(c)] ^ V[3]; lsz = index of the lowest zero bit.
    logic [WIDTH-1:0] step;
    always_comb begin
        unique case (cycle[2:0])
            3'd0, 3'd2, 3'd4, 3'd6: step = dv(4) ^ dv(3);
            3'd1, 3'd5:             step = dv(5) ^ dv(3);
            3'd3:                   step = dv(6) ^ dv(3);
            default:                step = dv(7) ^ dv(3);
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            high <= '0;
            cycle <= '0;
        end else if (enable) begin
            if (restart) begin
                high <= '0;
                cycle <= '0;
            end else if (cycle != 4'd8) begin
                high <= high ^ step;
                cycle <= cycle + 4'd1;
            end
        end
    end
endmodule

// One row's copy of the A-edge generation state: the q bank (H(c), c) and the
// block phase p, with the comparator word x = H(c) ^ {000, bitrev3(p), 00}.
// Every copy sees the same controls and so holds the same values as the top's
// phase_q and a single bank; the copies only split the broadcast.  Run
// cbsg_rg_20261005b had ONE bank and one phase register feeding all 1,024 A
// comparators: its routed max-corner GL failed setup at an a_bits_pipe flop
// through that net's 6-stage fan-out tree (2.0 ns), so each row now has its
// own copy (cbsg_rg_edge_state_rep), placed next to that row's 128
// comparators.  The copies sit in separate instances so that synthesis keeps
// them apart (no register merging across the hierarchy).
module cbsg_rg_edge_state #(
    parameter int WIDTH = 8
) (
    input  logic clk,
    input  logic reset,
    input  logic enable,             // rng_en
    input  logic restart,            // block_start
    input  logic slice_open,         // top: the block starting on this edge opens a slice
    output logic [WIDTH-1:0] word,   // H(c) ^ {000, bitrev3(p), 00} of the cycle now on the edge
    output logic [3:0] cycle         // c of the cycle now on the edge, 0..8
);
    logic [WIDTH-1:0] high;
    logic [2:0] phase;

    cbsg_rg_sobol_q_bank #(.WIDTH(WIDTH)) u_bank (
        .clk, .reset, .enable, .restart, .high, .cycle
    );

    // Same update as the top's phase_q (asynchronous reset to 0).
    always_ff @(posedge clk or posedge reset) begin
        if (reset)                   phase <= '0;
        else if (enable && restart)  phase <= slice_open ? 3'd0 : phase + 3'd1;
    end

    assign word = high ^ {3'b000, phase[0], phase[1], phase[2], 2'b00};
endmodule

// N_COPY copies of cbsg_rg_edge_state (one per A row), instance u_a_rng of the top.
module cbsg_rg_edge_state_rep #(
    parameter int WIDTH = 8,
    parameter int N_COPY = 8
) (
    input  logic clk,
    input  logic reset,
    input  logic enable,
    input  logic restart,
    input  logic slice_open,
    output logic [N_COPY*WIDTH-1:0] word,
    output logic [N_COPY*4-1:0]     cycle
);
    for (genvar i = 0; i < N_COPY; i++) begin : g_copy
        cbsg_rg_edge_state #(.WIDTH(WIDTH)) u_copy (
            .clk, .reset, .enable, .restart, .slice_open,
            .word(word[i*WIDTH +: WIDTH]), .cycle(cycle[i*4 +: 4])
        );
    end
endmodule

module cbsg_rg_edge #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int WIDTH = 8,
    parameter int LEN_W = 8,
    parameter int FAULT = 0
) (
    input  logic clk,
    input  logic reset,
    input  logic load_a,
    input  logic load_w,

    input  logic [N_H*K*WIDTH-1:0] a_binary_in,
    input  logic [N_H*K-1:0]       a_signs_in,
    input  logic [N_H*LEN_W-1:0]   row_len_in,
    input  logic [N_W*K*WIDTH-1:0] w_binary_in,
    input  logic [N_W*K-1:0]       w_signs_in,

    // Row h's copy of the generation state (u_a_rng = cbsg_rg_edge_state_rep):
    input  logic [N_H*WIDTH-1:0] a_word_row,   // H(c) ^ {000, bitrev3(p), 00}
    input  logic [N_H*4-1:0]     a_cycle_row,  // c

    output logic [N_H*K*M-1:0]     a_bits,
    output logic [N_H*K-1:0]       a_signs,
    output logic [N_W*K*WIDTH-1:0] w_mags,
    output logic [N_W*K-1:0]       w_signs
);
    localparam int LM = 4;
`ifdef CBSG_RG_FAULT_HOOKS
    localparam int F = FAULT;
`else
    localparam int F = 0;
`endif

    initial begin
        assert (K == 8 && M == 16 && WIDTH == 8 && LEN_W == 8)
            else $fatal(1, "cbsg_rg_edge: the C-BSG mask split needs K=8, M=16, WIDTH=8, LEN_W=8");
        assert (N_H > 0 && N_W > 0) else $fatal(1, "N_H and N_W must be positive");
    end

    function automatic logic [2:0] bitrev3(input logic [2:0] v);
        bitrev3 = {v[0], v[1], v[2]};
    endfunction

    function automatic logic [WIDTH-1:0] lane_offset(input int lane);   // LANE(m), q seed
        int gray;
        lane_offset = '0;
        gray = lane ^ (lane >> 1);
        for (int j = 0; j < LM; j++)
            if ((gray >> j) & 1) lane_offset[WIDTH-1-j] = 1'b1;
    endfunction

    //------------------------------------------------------ operand registers --
    // Asynchronous reset, as in sc_pe_peripheral: no reset mux on held bits.
    logic [N_H*K*WIDTH-1:0] a_binary_q;
    logic [N_H*K-1:0]       a_signs_q;
    logic [N_H*LEN_W-1:0]   row_len_q;
    logic [N_W*K*WIDTH-1:0] w_binary_q;
    logic [N_W*K-1:0]       w_signs_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            a_binary_q <= '0;
            a_signs_q <= '0;
            row_len_q <= '0;
        end else if (load_a) begin
            a_binary_q <= a_binary_in;
            a_signs_q <= a_signs_in;
            row_len_q <= row_len_in;
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
    assign w_mags = w_binary_q;
    assign w_signs = w_signs_q;

    //------------------------------------------------------- A comparators --
    // Row h compares against its own copy of x = H ^ {000, bitrev3(p), 00}; the
    // lane and position bits are constants.
    logic [M-1:0] len_ok [N_H];

    for (genvar h = 0; h < N_H; h++) begin : g_len
        for (genvar m = 0; m < M; m++) begin : g_pos
            if (F == 3) begin : g_fault_no_gate
                assign len_ok[h][m] = 1'b1;
            end else begin : g_gate
                // t = 16c + m < L_h (c <= 8, so t <= 143 fits 8 bits)
                assign len_ok[h][m] =
                    {a_cycle_row[h*4 +: 4], 4'(m)} < row_len_q[h*LEN_W +: LEN_W];
            end
        end
    end

    for (genvar k = 0; k < K; k++) begin : g_lane
        localparam logic [2:0] LANE_BITS = (F == 1) ? 3'(k) : bitrev3(3'(k));
        for (genvar m = 0; m < M; m++) begin : g_pos
            localparam logic [WIDTH-1:0] CONST = lane_offset(m) ^ {LANE_BITS, 5'b0};
            for (genvar h = 0; h < N_H; h++) begin : g_row
                logic [WIDTH-1:0] x;
                logic [WIDTH-2:0] thr;
                assign x = a_word_row[h*WIDTH +: WIDTH] ^ CONST;
                assign thr = x[WIDTH-1:1];                      // (x ^ mask) >> 1
                assign a_bits[(h*K + k)*M + m] =
                    (a_binary_q[(h*K + k)*WIDTH +: WIDTH] > {1'b0, thr}) & len_ok[h][m];
            end
        end
    end
endmodule

`endif
