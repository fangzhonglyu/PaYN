`ifndef PAYN_SIGNED_SEGMENTED_CSA_CBSG_RG_INNER_PE
`define PAYN_SIGNED_SEGMENTED_CSA_CBSG_RG_INNER_PE

// The accepted carry-save tile, unchanged (same file as signed_segmented_csa).
`include "payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv"

// N_H x N_W carry-save tiles with the C-BSG W generator inside the PE (design
// RG of sweeps/cbsg: the literal per-row generator).
//
// A arrives as gated stochastic bits (16 samples per lane per cycle, sample
// t = 16c + m), W as raw magnitudes.  Both are registered once at the array
// boundary and broadcast: tiles in row h read a_bits_pipe[h], tiles in
// column v read w_bits_pipe[v].  w_bits_pipe keeps the W pipe's name so the
// APR distribution guides (u_pe/u_array_core/w_bits_pipe_reg_*) still apply;
// here it holds the 8-bit W magnitude b_W (0..128) instead of 16 stream bits.
//
// W index generator, one per (row h, lane k), shared by the row's N_W tiles:
//
//   j        number of A ones of (h, k) in earlier cycles of this block
//            (IDX_W-bit register, cleared by the block's first cycle);
//   idx[m]   = j + #(A ones at positions < m)     (16-deep prefix);
//   x[m]     = XOR_b gray(idx[m])[b] * V_k[b]      (Gray-code Sobol word, k seed
//                                                  80 40 20 10 48 04 52 ff);
//   thr[m]   = (x[m] ^ mask_k) >> 1,  mask_k = { bitrev3(k), bitrev3(p), 2'b00 }.
//
// With this prefix the i-th A one of (h, k) in the block meets W sample i, but
// that order is neither observable nor required: a tile only sees the lane
// popcount of (a & w), so a cycle with n A ones depends only on the index set
// {j, ..., j+n-1} it hands out, and any in-cycle assignment of those indices
// to the n A positions gives the same sum.  What matters, and what the goldens
// pin, is that a block's kA A ones of (h, k) receive exactly the indices
// 0..kA-1.  Each tile compares w_bit[k][m] = b_W(v, k) > thr[h][k][m] and ANDs
// it with the A bit in the unchanged CSA tile, so a product counts
// #{i < kA : rB(d, i) < b_W}, the kernel's cum[d, kA, b_W].  j <= 128 always (at most 128 samples per
// block, and A is gated by t < L <= 128), so IDX_W = 8 holds the exact count;
// IDX_W = 7 also works (the wrap at 128 only affects lanes with no A one) and
// soren's 9 is wider than needed.
//
// first_in / valid_in / phase_in come from the top aligned with a_bits_in and
// are registered here next to the bit pipes: first = cycle 0 of a block,
// valid = the generators advanced (rng_en), phase = block phase p.  j advances
// only on valid cycles, so stall cycles are harmless.  The block-start clear
// of j is registered into each generator's j (j loads 0 while first_in is 1),
// so no shared first flag sits in front of the prefix chain (run
// cbsg_rg_20261005b; the first routes had first_pipe's fan-out tree on the
// critical path).  This needs first_in -> valid_in, which the top guarantees.
//
// FAULT (verification only; live only with +define+CBSG_RG_FAULT_HOOKS, else
// ignored): 1 = lane mask bits k instead of bitrev3(k); 2 = W index = t (no
// C-BSG gating; needs IDX_W = 8); 5 = j not cleared at block start; 6 = mask
// phase taken unregistered from phase_in (one cycle early).
module InnerPESignedSegmentedCsaCbsgRg #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9,
    parameter int WIDTH = 8,
    parameter int IDX_W = 8,
    parameter int FAULT = 0
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic [M-1:0]     a_bits_in  [N_H][K],
    input  logic             a_signs_in [N_H][K],
    input  logic [WIDTH-1:0] w_mag_in   [N_W][K],
    input  logic             w_signs_in [N_W][K],
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,
    input  logic [2:0] phase_in,
    input  logic first_in,
    input  logic valid_in,
    input  logic signed [OWIDTH-1:0] acc_in_west  [N_H],
    output logic signed [OWIDTH-1:0] acc_out_east [N_H]
);
`ifdef CBSG_RG_FAULT_HOOKS
    localparam int F = FAULT;
`else
    localparam int F = 0;
`endif

    initial begin
        assert (K == 8 && M == 16 && WIDTH == 8)
            else $fatal(1, "C-BSG RG PE needs K=8, M=16, WIDTH=8");
        assert (IDX_W >= 7 && IDX_W <= 9)
            else $fatal(1, "IDX_W must be 7..9 (got %0d)", IDX_W);
        assert (F != 2 || IDX_W == 8)
            else $fatal(1, "FAULT=2 needs IDX_W=8");
        assert (N_H > 0 && N_W > 0) else $fatal(1, "N_H and N_W must be positive");
    end

    // k seed direction numbers V_k[b] (scmp_kernels rng.py, seed [1,1,1,1,9,1,41,255]).
    function automatic logic [7:0] dv_k(input int b);
        case (b)
            0: dv_k = 8'h80;
            1: dv_k = 8'h40;
            2: dv_k = 8'h20;
            3: dv_k = 8'h10;
            4: dv_k = 8'h48;
            5: dv_k = 8'h04;
            6: dv_k = 8'h52;
            7: dv_k = 8'hff;
            default: dv_k = 8'h00;
        endcase
    endfunction
    localparam int GRAY_BITS = (IDX_W < 8) ? IDX_W : 8;   // gray(idx) bit 8 is 0 for idx < 256

    function automatic logic [2:0] bitrev3(input logic [2:0] v);
        bitrev3 = {v[0], v[1], v[2]};
    endfunction

    //------------------------------------------------------ operand pipes --
    logic [M-1:0]     a_bits_pipe  [N_H][K];
    logic             a_signs_pipe [N_H][K];
    logic [WIDTH-1:0] w_bits_pipe  [N_W][K];   // W magnitudes (name kept for the APR guides)
    logic             w_signs_pipe [N_W][K];
    logic load_a_sign_q, load_w_sign_q;
    logic [2:0] phase_pipe;
    logic first_pipe, valid_pipe;

    always_ff @(posedge clk) begin
        if (reset) begin
            load_a_sign_q <= 1'b0;
            load_w_sign_q <= 1'b0;
            phase_pipe <= '0;
            first_pipe <= 1'b0;
            valid_pipe <= 1'b0;
        end else begin
            load_a_sign_q <= load_a_sign_in;
            load_w_sign_q <= load_w_sign_in;
            phase_pipe <= phase_in;
            first_pipe <= first_in;
            valid_pipe <= valid_in;
        end
    end

    // Bits and magnitudes advance every cycle (resetless, as in the CSA PE).
    always_ff @(posedge clk) begin
        for (int h = 0; h < N_H; h++)
            for (int d = 0; d < K; d++)
                a_bits_pipe[h][d] <= a_bits_in[h][d];
        for (int v = 0; v < N_W; v++)
            for (int d = 0; d < K; d++)
                w_bits_pipe[v][d] <= w_mag_in[v][d];
    end

    // Sign pipes load on the registered load wave; reset as in the CSA PE (the
    // carry-save tile XORs the sign into the counter bits).
    always_ff @(posedge clk) begin
        if (reset) begin
            a_signs_pipe <= '{default: '0};
            w_signs_pipe <= '{default: '0};
        end else begin
            for (int h = 0; h < N_H; h++)
                for (int d = 0; d < K; d++)
                    if (load_a_sign_q)
                        a_signs_pipe[h][d] <= a_signs_in[h][d];
            for (int v = 0; v < N_W; v++)
                for (int d = 0; d < K; d++)
                    if (load_w_sign_q)
                        w_signs_pipe[v][d] <= w_signs_in[v][d];
        end
    end

    //------------------------------------------------ mask phase (shared) --
    logic [2:0] mask_phase_rev;
    if (F == 6) begin : g_fault_phase_early
        assign mask_phase_rev = bitrev3(phase_in);
    end else begin : g_phase
        assign mask_phase_rev = bitrev3(phase_pipe);
    end

    // FAULT 2 only: the sample index t of the cycle now in the pipes.
    logic [3:0] t_cycle, cur_t_cycle;
    if (F == 2) begin : g_fault_t_counter
        assign cur_t_cycle = first_pipe ? 4'd0 : t_cycle;
        always_ff @(posedge clk) begin
            if (reset)           t_cycle <= '0;
            else if (valid_pipe) t_cycle <= cur_t_cycle + 4'd1;
        end
    end else begin : g_no_t_counter
        assign t_cycle = '0;
        assign cur_t_cycle = '0;
    end

    //--------------------------------------- W index generator per (h, k) --
    logic [WIDTH-2:0] w_thr [N_H][K][M];

    for (genvar h = 0; h < N_H; h++) begin : g_gen_row
        for (genvar k = 0; k < K; k++) begin : g_gen_lane
            localparam logic [2:0] LANE_BITS = (F == 1) ? 3'(k) : bitrev3(3'(k));
            logic [IDX_W-1:0] j, cur_j;
            logic [IDX_W-1:0] prefix [M+1];
            logic [WIDTH-1:0] mask;

            assign mask = {LANE_BITS, mask_phase_rev, 2'b00};
            // The block's first cycle starts from j = 0.  The clear is taken
            // into j's own next-state (j loads 0 on the edge that brings the
            // block's first cycle into the pipes, while first_in is 1), not
            // applied as cur_j = first_pipe ? 0 : j after the register: that
            // AND put first_pipe's 512-load buffer tree in front of the
            // prefix chain on the PE's critical path (cbsg_rg_20261005 routes:
            // first_pipe -> fan-out buffers -> j-clear AND -> prefix -> Gray ->
            // compare -> tile, -0.03 ns).  Each generator's j register is its
            // own registered copy of the clear, so nothing on the path fans
            // out beyond one generator.  Same values cycle for cycle: first_in
            // implies valid_in (the top derives first_q = rng_en & block_start
            // and valid_q = rng_en on the same edge; asserted below), so
            // cur_j(t) = first_pipe(t) ? 0 : j_old(t) equals j_new(t).
            assign cur_j = j;

            assign prefix[0] = cur_j;
            for (genvar m = 0; m < M; m++) begin : g_pos
                logic [IDX_W-1:0] idx, gray;
                logic [WIDTH-1:0] x;

                assign prefix[m+1] = prefix[m] + IDX_W'(a_bits_pipe[h][k][m]);
                if (F == 2) begin : g_fault_idx_t
                    assign idx = IDX_W'({cur_t_cycle, 4'(m)});
                end else begin : g_idx
                    assign idx = prefix[m];
                end
                assign gray = idx ^ (idx >> 1);

                always_comb begin
                    x = '0;
                    for (int b = 0; b < GRAY_BITS; b++)
                        if (gray[b]) x ^= dv_k(b);
                end

                logic [WIDTH-1:0] xm;
                assign xm = x ^ mask;
                assign w_thr[h][k][m] = xm[WIDTH-1:1];           // (x ^ mask) >> 1
            end

            if (F == 5) begin : g_fault_no_restart
                // FAULT 5: j is never cleared at a block start.
                always_ff @(posedge clk) begin
                    if (reset)           j <= '0;
                    else if (valid_pipe) j <= prefix[M];
                end
            end else begin : g_restart
                always_ff @(posedge clk) begin
                    if (reset)           j <= '0;
                    else if (first_in)   j <= '0;          // next cycle is a block's cycle 0
                    else if (valid_pipe) j <= prefix[M];
                end
            end
        end
    end

`ifndef SYNTHESIS
    // The j pre-clear above needs first_in -> valid_in (a block's first cycle
    // is always a valid cycle), which the top guarantees structurally.
    always_ff @(posedge clk) begin
        if (!reset && first_in === 1'b1 && valid_in !== 1'b1)
            $error("InnerPESignedSegmentedCsaCbsgRg: first_in without valid_in (the j pre-clear needs first -> valid)");
    end
`endif

    //------------------------------------------------------------- tiles --
    for (genvar h = 0; h < N_H; h++) begin : g_row
        logic signed [OWIDTH-1:0] acc_chain [N_W:0];

        assign acc_chain[0] = acc_in_west[h];
        assign acc_out_east[h] = acc_chain[N_W];

        for (genvar v = 0; v < N_W; v++) begin : g_col
            logic [M-1:0] w_local [K];

            for (genvar k = 0; k < K; k++) begin : g_w_lane
                for (genvar m = 0; m < M; m++) begin : g_cmp
                    assign w_local[k][m] = w_bits_pipe[v][k] > {1'b0, w_thr[h][k][m]};
                end
            end

            InnerTileSignedSegmentedCsa #(
                .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(LOW_W)
            ) u_inner (
                .clk,
                .reset,
                .a_signs(a_signs_pipe[h]),
                .a_bits(a_bits_pipe[h]),
                .w_signs(w_signs_pipe[v]),
                .w_bits(w_local),
                .shift_in,
                .mac_en,
                .acc_in(acc_chain[v]),
                .acc_out(acc_chain[v+1])
            );
        end
    end
endmodule

// Packed-port wrapper for synthesis (same reason as the CSA PE: DC flattens
// unpacked array ports inconsistently), keeping u_pe/u_array_core.
module InnerPESignedSegmentedCsaCbsgRgFlat #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9,
    parameter int WIDTH = 8,
    parameter int IDX_W = 8,
    parameter int FAULT = 0
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic [N_H*K*M-1:0]     a_bits_in,
    input  logic [N_H*K-1:0]       a_signs_in,
    input  logic [N_W*K*WIDTH-1:0] w_mag_in,
    input  logic [N_W*K-1:0]       w_signs_in,
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,
    input  logic [2:0] phase_in,
    input  logic first_in,
    input  logic valid_in,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic [M-1:0]     a_bits_in_array  [N_H][K];
    logic             a_signs_in_array [N_H][K];
    logic [WIDTH-1:0] w_mag_in_array   [N_W][K];
    logic             w_signs_in_array [N_W][K];
    logic signed [OWIDTH-1:0] acc_in_west_array  [N_H];
    logic signed [OWIDTH-1:0] acc_out_east_array [N_H];

    for (genvar h = 0; h < N_H; h++) begin : g_a_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign a_bits_in_array[h][d] = a_bits_in[(h*K + d)*M +: M];
            assign a_signs_in_array[h][d] = a_signs_in[h*K + d];
        end
        assign acc_in_west_array[h] = $signed(acc_in_west[h*OWIDTH +: OWIDTH]);
        assign acc_out_east[h*OWIDTH +: OWIDTH] = acc_out_east_array[h];
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign w_mag_in_array[v][d] = w_mag_in[(v*K + d)*WIDTH +: WIDTH];
            assign w_signs_in_array[v][d] = w_signs_in[v*K + d];
        end
    end

    InnerPESignedSegmentedCsaCbsgRg #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W), .OWIDTH(OWIDTH), .LOW_W(LOW_W),
        .WIDTH(WIDTH), .IDX_W(IDX_W), .FAULT(FAULT)
    ) u_array_core (
        .clk,
        .reset,
        .mac_en,
        .shift_in,
        .a_bits_in(a_bits_in_array),
        .a_signs_in(a_signs_in_array),
        .w_mag_in(w_mag_in_array),
        .w_signs_in(w_signs_in_array),
        .load_a_sign_in,
        .load_w_sign_in,
        .phase_in,
        .first_in,
        .valid_in,
        .acc_in_west(acc_in_west_array),
        .acc_out_east(acc_out_east_array)
    );
endmodule

`endif
