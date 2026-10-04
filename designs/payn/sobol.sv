`ifndef ASTRAEA_SC_SOBOL
`define ASTRAEA_SC_SOBOL

`timescale 1ns/1ps

// M samples per cycle of one Gray-code Sobol sequence, matching the
// scmp_kernels emulator's per-column RNG words:
//
//   x[0] = 0,  x[t+1] = x[t] ^ V[lsz(t)]          (V: DIRECTION_SET table)
//
// random_values[lane*WIDTH +: WIDTH] is sample c*M + lane of cycle c. Sobol is
// linear in the Gray-coded index, and for M = 2**LM
//   gray(c*M + m) = (gray(c) << LM) ^ ((c & 1) << (LM-1)) ^ gray(m),
// so
//   x[c*M + m] = H(c) ^ LANE(m)
//   LANE(m)    = XOR_{j<LM} gray(m)[j] * V[j]                 (constant)
//   H(c+1)     = H(c) ^ V[LM + lsz(c)] ^ V[LM-1],  H(0) = 0
// -- one WIDTH-bit register plus M constant XORs.
//
// DIRECTION_SET 0: identity (the emulator's "q" seed, operand A).
// DIRECTION_SET 1: [128,64,32,16,72,4,82,255] (its "k" seed, operand W).
//
// The first `enable` after reset outputs cycle 0. `restart` (synchronous)
// returns to sample 0: with `enable` high it emits cycle 0 on that same clock
// (no bubble between back-to-back K-blocks); alone it rewinds so the next
// `enable` emits cycle 0.
module sobol_bank #(
    parameter int WIDTH = 8,
    parameter int M = 16,
    parameter int DIRECTION_SET = 0
) (
    input logic clk,
    input logic reset,
    input logic enable,
    input logic restart,
    output logic [M*WIDTH-1:0] random_values
);
    localparam int LM = (M > 1) ? $clog2(M) : 1;

    initial begin
        assert (M >= 2 && (1 << LM) == M && LM < WIDTH)
            else $error("sobol_bank needs M a power of two, 2 <= M < 2**WIDTH");
        assert (DIRECTION_SET inside {0, 1})
            else $error("DIRECTION_SET must be 0 (q) or 1 (k)");
        if (DIRECTION_SET == 1)
            assert (WIDTH inside {7, 8})
                else $error("DIRECTION_SET=1 requires WIDTH=7 or WIDTH=8");
    end

    function automatic logic [WIDTH-1:0] dv(input int j);
        logic [7:0] k_table [8];
        begin
            k_table = '{8'h80, 8'h40, 8'h20, 8'h10, 8'h48, 8'h04, 8'h52, 8'hff};
            dv = '0;
            if (j >= 0 && j < WIDTH) begin
                if (DIRECTION_SET == 0) dv[WIDTH-1-j] = 1'b1;
                else                    dv = WIDTH'(k_table[j] >> (8 - WIDTH));
            end
        end
    endfunction

    function automatic logic [WIDTH-1:0] lane_offset(input int lane);
        int gray;
        begin
            gray = lane ^ (lane >> 1);
            lane_offset = '0;
            for (int j = 0; j < LM; j++)
                if ((gray >> j) & 1) lane_offset ^= dv(j);
        end
    endfunction

    logic [WIDTH-1:0] high;       // H(c)
    logic [WIDTH-1:0] cycle;      // c
    logic [WIDTH-1:0] cur_high;
    logic [WIDTH-1:0] cur_cycle;
    logic [WIDTH-1:0] high_step;

    assign cur_high = restart ? '0 : high;
    assign cur_cycle = restart ? '0 : cycle;

    always_comb begin
        int unsigned lsz;
        lsz = WIDTH;
        for (int i = WIDTH - 1; i >= 0; i--)
            if (!cur_cycle[i]) lsz = i;
        high_step = dv(LM + lsz) ^ dv(LM - 1);
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            high <= '0;
            cycle <= '0;
            random_values <= '0;
        end else if (enable) begin
            for (int lane = 0; lane < M; lane++)
                random_values[lane*WIDTH +: WIDTH] <= cur_high ^ lane_offset(lane);
            high <= cur_high ^ high_step;
            cycle <= cur_cycle + 1'b1;
        end else if (restart) begin
            high <= '0;
            cycle <= '0;
        end
    end
endmodule

`endif
