`ifndef PAYN_SIGNED_SEGMENTED_CSA_SR_INNER_PE_CORE
`define PAYN_SIGNED_SEGMENTED_CSA_SR_INNER_PE_CORE

`include "payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv"

// Sub-ring (SR) copy of the carry-save PE core
// (../signed_segmented_csa/inner_pe_signed_segmented_csa.sv,
// InnerPESignedSegmentedCsa).  Everything is that core, line for line, except
// the accumulator input of every LAP_G-th tile.  Each tile row's N_W tiles are
// split into N_W/LAP_G sub-rings of LAP_G consecutive tiles; the head tile of a
// sub-ring (v % LAP_G == 0) gets a 2:1 mux, the other tiles keep the plain west
// chain:
//
//     head tile (h, v), v % LAP_G == 0:
//         acc_in = lap ? acc_out(h, v+LAP_G-1) << 1     (its sub-ring's TAIL, doubled)
//                      : acc_chain[h][v]                (west neighbour, as in the CSA core)
//     other tiles:
//         acc_in = acc_chain[h][v]                      (west neighbour, unchanged)
//
// A weight-pass lap is LAP_G consecutive edges with lap high (and the tile
// shift high: the PE wrapper drives shift = shift_in | lap).  Each edge
// rotates every sub-ring one tile east and doubles the value that wraps from
// tail to head, so after LAP_G edges every value is back in its own tile and
// doubled exactly once.
//
//     LAP_G = 1      every tile is its own sub-ring: in-place doubling (IPD,
//                    InnerPESignedSegmentedCsaIpd, 1-edge laps, 64 muxes/PE)
//     LAP_G = N_W    one sub-ring per row: the BP ring of
//                    csa_bp_20261004_lap (N_W-edge laps; there the mux sits at
//                    the PE west input, here in front of tile 0, same function)
//     LAP_G = 2, 4   2- / 4-edge laps with N_W/LAP_G muxes per row
//
// INT mode is defined for N_H = N_W = 8 with LAP_G in {1, 2, 4, 8}.  Other
// shapes only need to elaborate (SC drop-in, lap = 0): if LAP_G does not divide
// N_W the last sub-ring is shorter, which is irrelevant with lap = 0.
//
// Exactness.  acc_out is the tile's canonical {high_next, acc_low}, i.e. the
// pending carry/borrow is already folded into high_next, and a shift loads
// acc_in and clears both pending flags (unchanged tile).  The first lap edge
// therefore moves every canonical value exactly; the later edges move values
// that have no pending flags.  The wrap doubles mod 2^OWIDTH, as a BP ring lap
// does.  The MAC on a lap edge is dropped (shift priority), as on the BP ring.
//
// No combinational loop: acc_out = {acc_high + pending adjust, acc_low} is a
// function of the tile's registers only, and acc_in only reaches register D
// inputs.  The head path is tail register -> <<1 -> mux -> head register, a
// one-cycle register-to-register path across LAP_G-1 tiles.
//
// With lap = 0 this is InnerPESignedSegmentedCsa exactly, so SC mode is
// unchanged.  The instance names (g_row, g_col, u_inner, a_bits_pipe,
// w_bits_pipe) are the CSA core's, so the APR distribution guides
// (u_pe/u_array_core/a_bits_pipe_reg_*) still apply.
module InnerPESignedSegmentedCsaSr #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 11,
    parameter int LAP_G = 2
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic lap,
    input  logic [M-1:0] a_bits_in  [N_H][K],
    input  logic         a_signs_in [N_H][K],
    input  logic [M-1:0] w_bits_in  [N_W][K],
    input  logic         w_signs_in [N_W][K],
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,
    output logic [M-1:0] a_bits_out  [N_H][K],
    output logic         a_signs_out [N_H][K],
    output logic [M-1:0] w_bits_out  [N_W][K],
    output logic         w_signs_out [N_W][K],
    output logic load_a_sign_out,
    output logic load_w_sign_out,
    input  logic signed [OWIDTH-1:0] acc_in_west  [N_H],
    output logic signed [OWIDTH-1:0] acc_out_east [N_H]
);
    logic [M-1:0] a_bits_pipe  [N_H][K];
    logic         a_signs_pipe [N_H][K];
    logic [M-1:0] w_bits_pipe  [N_W][K];
    logic         w_signs_pipe [N_W][K];
    logic load_a_sign_q, load_w_sign_q;

    initial begin
        assert (K > 0 && M > 0 && N_H > 0 && N_W > 0)
            else $fatal(1, "K, M, N_H and N_W must be positive");
        assert (LAP_G >= 1 && LAP_G <= N_W)
            else $fatal(1, "LAP_G=%0d must be in 1..N_W=%0d", LAP_G, N_W);
    end

    // The load wave is registered once so the sign pipes latch on the same clock
    // the corresponding bits arrive.
    always_ff @(posedge clk) begin
        if (reset) begin
            load_a_sign_q <= 1'b0;
            load_w_sign_q <= 1'b0;
        end else begin
            load_a_sign_q <= load_a_sign_in;
            load_w_sign_q <= load_w_sign_in;
        end
    end

    // Bits stream every cycle; signs are held for a whole operand, so their
    // banks carry an enable and synthesis clock-gates them separately.
    always_ff @(posedge clk) begin
        for (int h = 0; h < N_H; h++)
            for (int d = 0; d < K; d++)
                a_bits_pipe[h][d] <= a_bits_in[h][d];
        for (int v = 0; v < N_W; v++)
            for (int d = 0; d < K; d++)
                w_bits_pipe[v][d] <= w_bits_in[v][d];
    end

    // Sign pipes reset, as in the CSA core (the carry-save tile XORs the sign
    // into the counter bits, so an unknown sign is not masked by a zero count).
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

    assign load_a_sign_out = load_a_sign_q;
    assign load_w_sign_out = load_w_sign_q;

    for (genvar h = 0; h < N_H; h++) begin : g_row
        logic signed [OWIDTH-1:0] acc_chain [N_W:0];

        for (genvar d = 0; d < K; d++) begin : g_a_output
            assign a_bits_out[h][d] = a_bits_pipe[h][d];
            assign a_signs_out[h][d] = a_signs_pipe[h][d];
        end

        assign acc_chain[0] = acc_in_west[h];
        assign acc_out_east[h] = acc_chain[N_W];

        for (genvar v = 0; v < N_W; v++) begin : g_col
            // Sub-ring head: on a lap edge it loads its sub-ring's tail value
            // shifted left by one; every other tile (and the head off a lap
            // edge) loads the west chain.
            logic signed [OWIDTH-1:0] tile_acc_in;
            if (v % LAP_G == 0) begin : g_head
                // tail = last tile of this sub-ring (shorter last sub-ring
                // when LAP_G does not divide N_W; see the header)
                localparam int TAIL_OUT = (v + LAP_G < N_W) ? v + LAP_G : N_W;
                assign tile_acc_in = lap ? {acc_chain[TAIL_OUT][OWIDTH-2:0], 1'b0} : acc_chain[v];
            end else begin : g_body
                assign tile_acc_in = acc_chain[v];
            end

            InnerTileSignedSegmentedCsa #(
                .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(LOW_W)
            ) u_inner (
                .clk,
                .reset,
                .a_signs(a_signs_pipe[h]),
                .a_bits(a_bits_pipe[h]),
                .w_signs(w_signs_pipe[v]),
                .w_bits(w_bits_pipe[v]),
                .shift_in,
                .mac_en,
                .acc_in(tile_acc_in),
                .acc_out(acc_chain[v+1])
            );
        end
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_output
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign w_bits_out[v][d] = w_bits_pipe[v][d];
            assign w_signs_out[v][d] = w_signs_pipe[v][d];
        end
    end
endmodule

`endif
