// [CBSG-AF-IPD COPY] of designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_core_signed_segmented_csa_ipd.sv (sha256 in README.md / copied_from.sha256), module names suffixed AfIpd.
// [CBSG-AF-IPD COPY] Rename only: sweeps/cbsg/af_ipd/check_copies.sh shows no other difference.
`ifndef PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_IPD_INNER_PE_CORE
`define PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_IPD_INNER_PE_CORE

`include "payn/variants/signed_segmented_csa/inner_tile_signed_segmented_csa.sv"

// In-place-doubling (IPD) copy of the carry-save PE core
// (../signed_segmented_csa/inner_pe_signed_segmented_csa.sv,
// InnerPESignedSegmentedCsa).  Everything is that core, line for line, except
// the accumulator input of each tile:
//
//     tile (h, v) acc_in = lap ? acc_out(h, v) << 1     (its OWN value, doubled)
//                              : acc_chain[h][v]        (west neighbour, as in the CSA core)
//
// so one edge with lap high (and the tile shift high: the PE wrapper drives
// shift_in = shift_in_port | lap) doubles every tile in place.  The BP ring
// (8 lap edges around the PE's own drain chain, a <<1 mux at the PE west
// input and 192 ring return wires from the east column) is gone.
//
// Exactness.  acc_out is the tile's canonical {high_next, acc_low}, i.e. the
// pending carry/borrow is already folded into high_next, and a shift loads
// acc_in and clears both pending flags (unchanged tile).  So the lap edge
// loads exactly 2 * value mod 2^OWIDTH and leaves no pending, as a drain shift
// or the BP ring lap does.  The MAC on a lap edge is dropped (shift priority),
// exactly as on the BP ring's lap edges.
//
// No combinational loop: acc_out = {acc_high + pending adjust, acc_low} is a
// function of the tile's registers only, and acc_in only reaches register D
// inputs (the tile loads it on shift).  The self path is register -> <<1 ->
// mux -> the same tile's register, a one-cycle register-to-register path.
//
// With lap = 0 this is InnerPESignedSegmentedCsa exactly (acc_in = west
// neighbour), so SC mode is unchanged.  The instance names (g_row, g_col,
// u_inner, a_bits_pipe, w_bits_pipe) are the CSA core's, so the APR
// distribution guides (u_pe/u_array_core/a_bits_pipe_reg_*) still apply.
module InnerPESignedSegmentedCsaIpdAfIpd #(
    parameter int K = 8,
    parameter int M = 16,
    parameter int N_H = 9,
    parameter int N_W = 9,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 11
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
            // In-place doubling: on a lap edge the tile reloads its own
            // canonical value shifted left by one; otherwise the west chain.
            logic signed [OWIDTH-1:0] tile_acc_in;
            assign tile_acc_in = lap ? {acc_chain[v+1][OWIDTH-2:0], 1'b0} : acc_chain[v];

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
