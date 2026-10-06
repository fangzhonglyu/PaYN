`ifndef PAYN_PE_SV
`define PAYN_PE_SV

`include "payn/rtl/payn_tile.sv"

// PE core: an N_H x N_W grid of tiles behind registered operand pipes.
//
//   A bits / signs of row h      reach every tile of row h
//   W bits / signs of column v   reach every tile of column v
//   accumulators                 chain west -> east along each row (drain)
//
// In-place doubling (the INT lap).  Each tile's accumulator input is
//
//     lap ? (own acc_out) << 1 : west neighbour's acc_out
//
// so one edge with lap high (and the tile shift high; PaynPe drives
// shift_in = shift_port | lap) doubles every tile in place.  acc_out is the
// tile's canonical value with the pending carry/borrow folded in, and a shift
// clears both pending bits, so a lap edge loads exactly 2 * value mod
// 2^OWIDTH.  The MAC on a lap edge is dropped (shift has priority).  The self
// path is register -> <<1 -> mux -> the same register; there is no
// combinational loop.  With lap = 0 the core is a plain output-stationary
// grid with a west -> east drain chain.
//
// The operand bit pipes have no reset (they stream every edge); the sign pipes
// reset, because the tile XORs the sign into the counter bits and an unknown
// sign is not masked by a zero count.  The instance names (g_row, g_col,
// u_inner, a_bits_pipe, w_bits_pipe) are what the APR distribution guides and
// the PrimeTime power classes match on.
module PaynPeCore #(
    parameter int K = 16,
    parameter int M = 8,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9
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

    // The load wave is registered once so the sign pipes latch on the same
    // edge the corresponding bits arrive.
    always_ff @(posedge clk) begin
        if (reset) begin
            load_a_sign_q <= 1'b0;
            load_w_sign_q <= 1'b0;
        end else begin
            load_a_sign_q <= load_a_sign_in;
            load_w_sign_q <= load_w_sign_in;
        end
    end

    // Bits stream every edge; signs are held for a whole operand, so their
    // banks carry an enable and synthesis clock-gates them separately.
    always_ff @(posedge clk) begin
        for (int h = 0; h < N_H; h++)
            for (int d = 0; d < K; d++)
                a_bits_pipe[h][d] <= a_bits_in[h][d];
        for (int v = 0; v < N_W; v++)
            for (int d = 0; d < K; d++)
                w_bits_pipe[v][d] <= w_bits_in[v][d];
    end

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
            logic signed [OWIDTH-1:0] tile_acc_in;
            assign tile_acc_in = lap ? {acc_chain[v+1][OWIDTH-2:0], 1'b0} : acc_chain[v];

            PaynTile #(
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

// PE with packed ports and the registered lap enable.
//
//     ring_q       <= ring_in                 (reset to 0)
//     tile shift    = shift_in | ring_q
//     tile acc_in   = ring_q ? own << 1 : west          (in the core)
//
// ring_in high at edge P makes P+1 a lap edge that doubles every tile; k
// consecutive ring_in edges multiply by 2^k.  ring_out = ring_q re-exports the
// lap wave to the next PE east (PaynPeGrid), so every PE laps one edge after
// its west neighbour, in step with its A skew.  With ring_in = 0 the PE is a
// plain SC PE.  The core keeps the instance name u_array_core (APR guides).
module PaynPe #(
    parameter int K = 16,
    parameter int M = 8,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic ring_in,
    input  logic [N_H*K*M-1:0] a_bits_in,
    input  logic [N_H*K-1:0]   a_signs_in,
    input  logic [N_W*K*M-1:0] w_bits_in,
    input  logic [N_W*K-1:0]   w_signs_in,
    input  logic load_a_sign_in,
    input  logic load_w_sign_in,
    output logic [N_H*K*M-1:0] a_bits_out,
    output logic [N_H*K-1:0]   a_signs_out,
    output logic [N_W*K*M-1:0] w_bits_out,
    output logic [N_W*K-1:0]   w_signs_out,
    output logic load_a_sign_out,
    output logic load_w_sign_out,
    output logic ring_out,
    input  logic [N_H*OWIDTH-1:0] acc_in_west,
    output logic [N_H*OWIDTH-1:0] acc_out_east
);
    logic [M-1:0] a_bits_in_array   [N_H][K];
    logic         a_signs_in_array  [N_H][K];
    logic [M-1:0] w_bits_in_array   [N_W][K];
    logic         w_signs_in_array  [N_W][K];
    logic [M-1:0] a_bits_out_array  [N_H][K];
    logic         a_signs_out_array [N_H][K];
    logic [M-1:0] w_bits_out_array  [N_W][K];
    logic         w_signs_out_array [N_W][K];
    logic signed [OWIDTH-1:0] acc_in_west_array  [N_H];
    logic signed [OWIDTH-1:0] acc_out_east_array [N_H];

    logic ring_q;
    logic core_shift;

    always_ff @(posedge clk) begin
        if (reset)
            ring_q <= 1'b0;
        else
            ring_q <= ring_in;
    end

    assign ring_out = ring_q;
    assign core_shift = shift_in | ring_q;

    for (genvar h = 0; h < N_H; h++) begin : g_a_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign a_bits_in_array[h][d] = a_bits_in[(h*K + d)*M +: M];
            assign a_signs_in_array[h][d] = a_signs_in[h*K + d];
            assign a_bits_out[(h*K + d)*M +: M] = a_bits_out_array[h][d];
            assign a_signs_out[h*K + d] = a_signs_out_array[h][d];
        end
        assign acc_in_west_array[h] = $signed(acc_in_west[h*OWIDTH +: OWIDTH]);
        assign acc_out_east[h*OWIDTH +: OWIDTH] = acc_out_east_array[h];
    end

    for (genvar v = 0; v < N_W; v++) begin : g_w_ports
        for (genvar d = 0; d < K; d++) begin : g_depth
            assign w_bits_in_array[v][d] = w_bits_in[(v*K + d)*M +: M];
            assign w_signs_in_array[v][d] = w_signs_in[v*K + d];
            assign w_bits_out[(v*K + d)*M +: M] = w_bits_out_array[v][d];
            assign w_signs_out[v*K + d] = w_signs_out_array[v][d];
        end
    end

    PaynPeCore #(
        .K(K), .M(M), .N_H(N_H), .N_W(N_W),
        .OWIDTH(OWIDTH), .LOW_W(LOW_W)
    ) u_array_core (
        .clk,
        .reset,
        .mac_en,
        .shift_in(core_shift),
        .lap(ring_q),
        .a_bits_in(a_bits_in_array),
        .a_signs_in(a_signs_in_array),
        .w_bits_in(w_bits_in_array),
        .w_signs_in(w_signs_in_array),
        .load_a_sign_in,
        .load_w_sign_in,
        .a_bits_out(a_bits_out_array),
        .a_signs_out(a_signs_out_array),
        .w_bits_out(w_bits_out_array),
        .w_signs_out(w_signs_out_array),
        .load_a_sign_out,
        .load_w_sign_out,
        .acc_in_west(acc_in_west_array),
        .acc_out_east(acc_out_east_array)
    );
endmodule

`endif
