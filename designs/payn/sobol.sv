`ifndef ASTRAEA_SC_SOBOL
`define ASTRAEA_SC_SOBOL

`timescale 1ns/1ps

// One digitally shifted Sobol sequence. DIRECTION_SET=0 is the identity
// direction table. DIRECTION_SET=1 is the decorrelated 8-bit table previously
// used for the weight stream.
module sobol_generator #(
    parameter int WIDTH = 8,
    parameter int DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT = '0,
    parameter logic FULL_PERIOD_WRAP = 1'b0
) (
    input logic clk,
    input logic reset,
    input logic enable,
    output logic [WIDTH-1:0] random_value
);
    logic [WIDTH-1:0] count;
    logic [WIDTH-1:0] selected_direction;
    logic direction_found;

    function automatic logic [WIDTH-1:0] direction_vector(input int index);
        logic [7:0] decorrelated_vector;
        begin
            decorrelated_vector = '0;
            if (DIRECTION_SET == 0) begin
                direction_vector = '0;
                direction_vector[WIDTH-1-index] = 1'b1;
            end else begin
                case (index)
                    0: decorrelated_vector = 8'h80;
                    1: decorrelated_vector = 8'h40;
                    2: decorrelated_vector = 8'h20;
                    3: decorrelated_vector = 8'h10;
                    4: decorrelated_vector = 8'h48;
                    5: decorrelated_vector = 8'h04;
                    6: decorrelated_vector = 8'h52;
                    7: decorrelated_vector = 8'hff;
                    default: decorrelated_vector = '0;
                endcase
                if (WIDTH == 8)
                    direction_vector = WIDTH'(decorrelated_vector);
                else
                    direction_vector =
                        WIDTH'(decorrelated_vector >> (8 - WIDTH));
            end
        end
    endfunction

    initial begin
        assert (WIDTH > 0) else $error("WIDTH must be positive");
        assert (DIRECTION_SET inside {0, 1})
            else $error("DIRECTION_SET must be 0 or 1");
        if (DIRECTION_SET == 1)
            assert (WIDTH inside {7, 8})
                else $error("DIRECTION_SET=1 requires WIDTH=7 or WIDTH=8");
    end

    // Select the direction vector indexed by the least-significant zero in
    // the current sample index.
    always_comb begin
        selected_direction = '0;
        direction_found = 1'b0;
        for (int index = 0; index < WIDTH; index++) begin
            if (!direction_found && !count[index]) begin
                selected_direction = direction_vector(index);
                direction_found = 1'b1;
            end
        end
        // The legacy generator deliberately holds its final value when count
        // is all ones.  A native WIDTH-bit full-period stream instead returns
        // to DIGITAL_SHIFT on that last update, so all 2**WIDTH thresholds
        // appear exactly once.  Keep the corrected behavior opt-in so existing
        // checkpoints and their bit-exact traces are unchanged.
        if (FULL_PERIOD_WRAP && !direction_found)
            selected_direction = direction_vector(WIDTH - 1);
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            count <= '0;
            random_value <= DIGITAL_SHIFT;
        end else if (enable) begin
            // Preserve the established SC sequence: an all-ones count selects
            // no direction vector, so the final sample repeats before wrap.
            count <= count + 1'b1;
            random_value <= random_value ^ selected_direction;
        end
    end
endmodule

// M parallel threshold lanes. MODE selects how the lanes are generated:
//
//   MODE=0 (legacy): M Sobol sequences with distinct digital shifts and one
//     shared direction table. random_values[lane*WIDTH +: WIDTH] is lane's
//     value. `restart` is ignored.
//
//   MODE=1 (sample-ordered Sobol): the M lanes of cycle c are samples
//     c*M .. c*M+M-1 of ONE Gray-code Sobol sequence (x[0] = 0,
//     x[t+1] = x[t] ^ V[lsz(t)]), i.e. the emulator's per-column RNG word
//     sequence delivered M samples per clock. Sobol is linear in the
//     Gray-coded index, and gray(c*M + m) = (gray(c) << LM) ^ ((c & 1) << (LM-1))
//     ^ gray(m) for M = 2**LM, so
//         x[c*M + m] = H(c) ^ LANE(m)
//         LANE(m)    = XOR_{j<LM} gray(m)[j] * V[j]              (constant)
//         H(c+1)     = H(c) ^ V[LM + lsz(c)] ^ V[LM-1],  H(0) = 0
//     One WIDTH-bit register plus M constant XORs, the same shape as MODE=0.
//
//   MODE=2 (unary temporal): lane m of cycle c is the sample index c*M + m,
//     saturating at 2**WIDTH-1. Compared as `operand > threshold`, an operand
//     k gives a thermometer stream whose first k samples are 1.
//
// MODE 1 and 2: the first `enable` after reset outputs cycle 0. `restart`
// (synchronous) returns the bank to sample 0 so every K-block's streams start
// at t = 0, as in the emulator: with `enable` high it emits cycle 0 on that
// same clock (no bubble between back-to-back blocks); alone it rewinds so the
// next `enable` emits cycle 0.
module sobol_bank #(
    parameter int WIDTH = 8,
    parameter int M = 16,
    parameter int DIRECTION_SET = 0,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT_BASE = 'h17,
    parameter logic [WIDTH-1:0] DIGITAL_SHIFT_STRIDE = 'h53,
    parameter logic FULL_PERIOD_WRAP = 1'b0,
    parameter int MODE = 0
) (
    input logic clk,
    input logic reset,
    input logic enable,
    input logic restart = 1'b0,
    output logic [M*WIDTH-1:0] random_values
);
    localparam int LM = (M > 1) ? $clog2(M) : 1;

    initial begin
        assert (M > 0) else $error("M must be positive");
        assert (MODE inside {0, 1, 2}) else $error("MODE must be 0, 1 or 2");
        if (MODE == 1) begin
            assert (M >= 2 && (1 << LM) == M && LM < WIDTH)
                else $error("MODE=1 needs M a power of two, 2 <= M < 2**WIDTH");
            assert (DIRECTION_SET inside {0, 1, 2})
                else $error("MODE=1 DIRECTION_SET must be 0, 1 or 2");
        end
    end

    // Direction vector j of the Gray-code Sobol sequence (MODE=1).
    // 0: identity (van der Corput), 1: the decorrelated table of
    // sobol_generator (scmp "k" seed), 2: standard Sobol dimension 2.
    function automatic logic [WIDTH-1:0] dv(input int j);
        logic [7:0] k_table [8];
        int unsigned m_i;
        begin
            k_table = '{8'h80, 8'h40, 8'h20, 8'h10, 8'h48, 8'h04, 8'h52, 8'hff};
            dv = '0;
            if (j >= 0 && j < WIDTH) begin
                case (DIRECTION_SET)
                    0: dv[WIDTH-1-j] = 1'b1;
                    1: dv = WIDTH'(k_table[j] >> (8 - WIDTH));
                    default: begin
                        m_i = 1;
                        for (int i = 1; i <= j; i++) m_i = m_i ^ (m_i << 1);
                        dv = WIDTH'(m_i << (WIDTH - 1 - j));
                    end
                endcase
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

    if (MODE == 0) begin : g_legacy
        for (genvar lane = 0; lane < M; lane++) begin : g_lane
            localparam logic [WIDTH-1:0] LANE_SHIFT =
                DIGITAL_SHIFT_BASE ^ WIDTH'(DIGITAL_SHIFT_STRIDE * lane);

            sobol_generator #(
                .WIDTH(WIDTH),
                .DIRECTION_SET(DIRECTION_SET),
                .DIGITAL_SHIFT(LANE_SHIFT),
                .FULL_PERIOD_WRAP(FULL_PERIOD_WRAP)
            ) u_generator (
                .clk,
                .reset,
                .enable,
                .random_value(random_values[lane*WIDTH +: WIDTH])
            );
        end
    end else if (MODE == 1) begin : g_sample_ordered
        logic [WIDTH-1:0] high;       // H(c)
        logic [WIDTH-1:0] cycle;      // c
        logic [WIDTH-1:0] high_step;

        // restart selects cycle 0 as the current state, so a restart on an
        // enable cycle emits cycle 0 with no bubble between K-blocks.
        logic [WIDTH-1:0] cur_high;
        logic [WIDTH-1:0] cur_cycle;
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
    end else begin : g_unary_temporal
        logic [WIDTH:0] base;         // c*M, saturating
        logic [WIDTH:0] cur_base;
        assign cur_base = restart ? '0 : base;

        always_ff @(posedge clk or posedge reset) begin
            if (reset) begin
                base <= '0;
                random_values <= '0;
            end else if (enable) begin
                for (int lane = 0; lane < M; lane++) begin
                    logic [WIDTH+1:0] sample;
                    sample = (WIDTH+2)'(cur_base) + (WIDTH+2)'(lane);
                    random_values[lane*WIDTH +: WIDTH] <=
                        sample >= (1 << WIDTH) ? {WIDTH{1'b1}} : WIDTH'(sample);
                end
                base <= (cur_base < (WIDTH+1)'(1 << WIDTH))
                        ? cur_base + (WIDTH+1)'(M) : cur_base;
            end else if (restart) begin
                base <= '0;
            end
        end
    end
endmodule

`endif
