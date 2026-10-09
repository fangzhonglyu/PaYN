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
// Lap fold (FOLD, a build-time choice; default 0 is the lap above).  With
// FOLD = 1 lap drives every tile's fold input instead (PaynTile): the lap edge
// keeps its MAC and loads 2 * value + this edge's sum, so the schedule needs
// no bubble before it; the tile acc_in has no lap leg and PaynPe does not
// raise the tile shift on lap edges.  Checked in simulation ([FOLD-CONTRACT],
// fatal): a fold on a shift edge (the shift wins and the doubling is lost)
// and a fold without mac_en (a fold edge adds its sample).
//
// Drain (DRAIN, a build-time choice):
//   0  in-tile chain (default): the accumulators themselves are the drain,
//      west -> east, 8 values per edge on acc_out_east; dr_west is 0.
//   1  drain register (DR): one register of N_H/2 x N_W values.  A half is
//      the tile rows 0..N_H/2-1 (half 0) or N_H/2..N_H-1 (half 1); DR value
//      n = (h mod N_H/2)*N_W + v.  On an edge with rd_half0 (rd_half1) the DR
//      loads that half's canonical acc_out and those tiles shift-load 0 (the
//      clear; shift has priority over the MAC); on every other edge the DR
//      loads dr_east, the east neighbour's DR, when that is valid, so items
//      move one PE west per edge.  dr_west_valid marks a loaded item.  The
//      tiles have no chain: acc_in = lap ? acc << 1 : 0 (FOLD = 1: 0),
//      acc_out_east is 0.
//      Checked in simulation ([DR-CONTRACT], fatal): a read edge while an
//      item arrives from the east (it would be lost), both halves on one edge,
//      a read on a lap edge.
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
    parameter int LOW_W = 9,
    parameter int DRAIN = 0,
    parameter int FOLD = 0,
    parameter int DRN = (N_H / 2) * N_W           // values per DR (derived)
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic lap,
    input  logic rd_half0,
    input  logic rd_half1,
    input  logic signed [OWIDTH-1:0] dr_east [DRN],
    input  logic dr_east_valid,
    output logic signed [OWIDTH-1:0] dr_west [DRN],
    output logic dr_west_valid,
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
        assert (DRAIN == 0 || (DRAIN == 1 && N_H % 2 == 0 && DRN == (N_H / 2) * N_W))
            else $fatal(1, "DRAIN must be 0 or 1 (1 needs an even N_H and DRN = N_H/2*N_W)");
        assert (FOLD == 0 || FOLD == 1)
            else $fatal(1, "FOLD must be 0 or 1");
    end

    // Canonical tile values, for the DR's half select.
    logic signed [OWIDTH-1:0] tile_out [N_H][N_W];

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
        logic row_shift;

        for (genvar d = 0; d < K; d++) begin : g_a_output
            assign a_bits_out[h][d] = a_bits_pipe[h][d];
            assign a_signs_out[h][d] = a_signs_pipe[h][d];
        end

        assign acc_chain[0] = acc_in_west[h];
        assign acc_out_east[h] = (DRAIN == 1) ? '0 : acc_chain[N_W];
        assign row_shift = shift_in | ((DRAIN == 1) && ((h < N_H / 2) ? rd_half0 : rd_half1));

        for (genvar v = 0; v < N_W; v++) begin : g_col
            logic signed [OWIDTH-1:0] tile_acc_in;
            assign tile_acc_in = (FOLD == 0 && lap) ? {acc_chain[v+1][OWIDTH-2:0], 1'b0} :
                                 (DRAIN == 1) ? '0 : acc_chain[v];
            assign tile_out[h][v] = acc_chain[v+1];

            PaynTile #(
                .K(K), .M(M), .OWIDTH(OWIDTH), .LOW_W(LOW_W), .FOLD(FOLD)
            ) u_inner (
                .clk,
                .reset,
                .a_signs(a_signs_pipe[h]),
                .a_bits(a_bits_pipe[h]),
                .w_signs(w_signs_pipe[v]),
                .w_bits(w_bits_pipe[v]),
                .shift_in(row_shift),
                .mac_en,
                .fold(lap),
                .acc_in(tile_acc_in),
                .acc_out(acc_chain[v+1])
            );
        end
    end

    //------------------------------------------------- drain register --
    if (DRAIN == 1) begin : g_dr
        logic signed [OWIDTH-1:0] dr_q [DRN];
        logic dr_valid_q;
        logic dr_load;

        assign dr_load = rd_half0 | rd_half1 | dr_east_valid;

        always_ff @(posedge clk) begin
            if (reset)
                dr_valid_q <= 1'b0;
            else
                dr_valid_q <= dr_load;
        end

        // No reset: the data is read only with dr_valid_q.
        always_ff @(posedge clk) begin
            if (dr_load)
                for (int n = 0; n < DRN; n++)
                    dr_q[n] <= rd_half0 ? tile_out[n / N_W][n % N_W] :
                               rd_half1 ? tile_out[N_H / 2 + n / N_W][n % N_W] : dr_east[n];
        end

        assign dr_west = dr_q;
        assign dr_west_valid = dr_valid_q;

`ifndef SYNTHESIS
        always_ff @(posedge clk) begin
            if (reset !== 1'b1) begin
                if ((rd_half0 === 1'b1 || rd_half1 === 1'b1) && dr_east_valid === 1'b1)
                    $fatal(1, "[DR-CONTRACT] %m: read edge while an item arrives from the east (it would be lost)");
                if (rd_half0 === 1'b1 && rd_half1 === 1'b1)
                    $fatal(1, "[DR-CONTRACT] %m: both halves read on one edge (drain wave longer than one edge)");
                if (lap === 1'b1 && (rd_half0 === 1'b1 || rd_half1 === 1'b1))
                    $fatal(1, "[DR-CONTRACT] %m: read edge on a lap edge");
            end
        end
`endif
    end else begin : g_no_dr
        for (genvar n = 0; n < DRN; n++) begin : g_zero
            assign dr_west[n] = '0;
        end
        assign dr_west_valid = 1'b0;
    end

`ifndef SYNTHESIS
    if (FOLD == 1) begin : g_fold_ck
        always_ff @(posedge clk) begin
            if (reset !== 1'b1 && lap === 1'b1) begin
                if (shift_in === 1'b1)
                    $fatal(1, "[FOLD-CONTRACT] %m: fold on a shift edge (the shift wins; the doubling is lost)");
                if (mac_en !== 1'b1)
                    $fatal(1, "[FOLD-CONTRACT] %m: fold on an edge without mac_en (a fold edge doubles and adds that edge's sample)");
            end
        end
    end
`endif

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
//     tile shift    = shift_in | ring_q       (FOLD = 1: shift_in)
//     tile acc_in   = ring_q ? own << 1 : west          (in the core; FOLD = 1:
//                                                       west, ring_q folds)
//
// ring_in high at edge P makes P+1 a lap edge that doubles every tile (FOLD =
// 1: a fold edge, doubling and adding that edge's MAC); k consecutive ring_in
// edges multiply by 2^k.  ring_out = ring_q re-exports the
// lap wave to the next PE east (PaynPeGrid), so every PE laps one edge after
// its west neighbour, in step with its A skew.  With ring_in = 0 the PE is a
// plain SC PE.  The core keeps the instance name u_array_core (APR guides).
//
// Drain wave (DRAIN = 1), built like the ring:
//
//     drain_q  <= drain_in,  drain_q2 <= drain_q     (reset to 0)
//     drain_q high: half-0 read edge;  drain_q2 high: half-1 read edge
//
// drain_in high at edge P makes P+1 the half-0 and P+2 the half-1 read edge;
// drain_out = drain_q re-exports the wave east one edge later (the A skew).
// dr_east_in / dr_east_valid_in come from the east neighbour's DR (zero at the
// east edge of a grid), dr_west_out / dr_west_valid_out go to the west
// neighbour or the array's west edge.  With DRAIN = 0 the drain wave inputs
// are ignored and the DR outputs are 0.
module PaynPe #(
    parameter int K = 16,
    parameter int M = 8,
    parameter int N_H = 8,
    parameter int N_W = 8,
    parameter int OWIDTH = 24,
    parameter int LOW_W = 9,
    parameter int DRAIN = 0,
    parameter int FOLD = 0,
    parameter int DRW = (N_H / 2) * N_W * OWIDTH  // DR bits (derived)
) (
    input  logic clk,
    input  logic reset,
    input  logic mac_en,
    input  logic shift_in,
    input  logic ring_in,
    input  logic drain_in,
    output logic drain_out,
    input  logic [DRW-1:0] dr_east_in,
    input  logic dr_east_valid_in,
    output logic [DRW-1:0] dr_west_out,
    output logic dr_west_valid_out,
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
    localparam int DRN = (N_H / 2) * N_W;
    logic signed [OWIDTH-1:0] dr_east_array [DRN];
    logic signed [OWIDTH-1:0] dr_west_array [DRN];

    logic ring_q;
    logic core_shift;
    logic rd_half0, rd_half1;

    always_ff @(posedge clk) begin
        if (reset)
            ring_q <= 1'b0;
        else
            ring_q <= ring_in;
    end

    assign ring_out = ring_q;
    assign core_shift = shift_in | ((FOLD == 0) & ring_q);

    if (DRAIN == 1) begin : g_drain
        logic drain_q, drain_q2;
        always_ff @(posedge clk) begin
            if (reset) begin
                drain_q <= 1'b0;
                drain_q2 <= 1'b0;
            end else begin
                drain_q <= drain_in;
                drain_q2 <= drain_q;
            end
        end
        assign rd_half0 = drain_q;
        assign rd_half1 = drain_q2;
        assign drain_out = drain_q;
    end else begin : g_no_drain
        assign rd_half0 = 1'b0;
        assign rd_half1 = 1'b0;
        assign drain_out = 1'b0;
    end

    for (genvar n = 0; n < DRN; n++) begin : g_dr_ports
        assign dr_east_array[n] = $signed(dr_east_in[n*OWIDTH +: OWIDTH]);
        assign dr_west_out[n*OWIDTH +: OWIDTH] = dr_west_array[n];
    end

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
        .OWIDTH(OWIDTH), .LOW_W(LOW_W), .DRAIN(DRAIN), .FOLD(FOLD)
    ) u_array_core (
        .clk,
        .reset,
        .mac_en,
        .shift_in(core_shift),
        .lap(ring_q),
        .rd_half0,
        .rd_half1,
        .dr_east(dr_east_array),
        .dr_east_valid(dr_east_valid_in),
        .dr_west(dr_west_array),
        .dr_west_valid(dr_west_valid_out),
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
