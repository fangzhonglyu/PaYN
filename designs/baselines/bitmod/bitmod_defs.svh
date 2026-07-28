`ifndef DEFS_SVH
`define DEFS_SVH

`timescale 1ns/1ps

`define TILE_SHARED_CTL

`define MAX(a, b) ((a) > (b) ? (a) : (b))
`define MIN(a, b) ((a) > (b) ? (b) : (a))
// `define CLOCK_PERIOD 25.0
// `define CLOCK_PERIOD 10.0
// `define CLOCK_PERIOD 5.0
`define CLOCK_PERIOD 2.5
// `define CLOCK_PERIOD 1.0
// `define PE_ROUND_LOWER

`define is_pow2(x) (((x) > 0) && (((x) & ((x) - 1)) == 0))

typedef enum logic [1:0] {
    S_DUMMY =2'b00, // dummy 1-term format used for testing purposes
    S_F4_F3 =2'b01,
    S_I6    =2'b10,
    S_I8    =2'b11
} term_gen_mode_t;

// typedef struct packed {
//     logic       sign;
//     logic[1:0]  exp;
//     logic       man;
//     logic[2:0]  bsig;
// } term_t;

localparam logic[0:7][3:0] booth_lut = '{
    4'b0000, // 000
    4'b0001, // 001
    4'b0001, // 010
    4'b0011, // 011
    4'b1011, // 100
    4'b1001, // 101
    4'b1001, // 110
    4'b0000  // 111
};

// localparam logic[0:7][5:0] special_value_lut = '{
//     6'b0_0011_0, // 3
//     6'b1_0011_0, // -3
//     6'b0_0110_0, // 6
//     6'b1_0110_0, // -6

//     6'b0_0101_0, // 5
//     6'b1_0101_0, // -5
//     6'b0_1000_0, // 8
//     6'b1_1000_0  // -8
// };

// special_value_id = {sign:1, is_fp4:1, is_ea:1}
// index into lut = {is_fp4:1, is_ea:1}
localparam logic[0:3][3:0] special_value_lut = '{ // magnitude only
    4'b0011,// 3
    4'b0110,// 6

    4'b0101,// 5
    4'b1000 // 8
};

typedef struct packed {
    logic               fin;    // direction-agnostic
    logic               last;   // direction-agnostic
    logic[7:0][3:0][3:0]w_sem;
    logic[2:0]          w_bsig;

} vert_tr_pkt_t; // tr = term-rate duty cycle

typedef struct packed {
    logic[7:0][7:0]     w_scale;

} vert_gr_pkt_t; // gr = group-rate duty cycle

typedef struct packed {
    logic[7:0][3:0][15:0]   a;

} hori_er_pkt_t; // er = elem-rate duty cycle

// Integrated clock gate wrapper. All hand-rolled gating goes through this so a
// single define swaps the discrete latch+AND for the library ICG:
//   +define+TECH_ICG                    → PREICG_X2B_A7PP140ZTS_C30 (default)
//   +define+TECH_ICG_CELL=PREICG_X4B_A7PP140ZTS_C30  → override drive
// ARM sc7mcpp140z pinout: ECK (gated clk out), CK, E (enable, sampled while CK
// low), SE (scan/test enable — tied 0; set_dft_signal it if scan is added
// later so ATPG can force clocks). PREICG is the posedge variant; PREICGN is
// for inverted clocks and is not used here. A real ICG has lower internal
// power than latch+AND2, is min-pulse safe, and is visible to CCopt for gate
// merging/cloning; a discrete AND in the clock path is not.
// Fallback is bit-identical to the original latch+AND.
module tech_icg (
    input   logic clk,
    input   logic en,
    output  logic gclk
);
// `ifdef TECH_ICG
`ifdef TECH_ICG_CELL
// `ifndef TECH_ICG_CELL
// `define TECH_ICG_CELL PREICG_X2B_A7PP140ZTS_C30
// `endif
    `TECH_ICG_CELL u_icg (
        .ECK    (gclk),
        .CK     (clk),
        .E      (en),
        .SE     (1'b0)
    );
`else
    logic en_latched;

    always_latch begin
        if (~clk)
            en_latched = en;
    end

    assign gclk = clk & en_latched;
`endif
endmodule

// clock-gated data (and so it will NOT be asynchronously reset or have a vld signal) register
module cg_dreg #(
    parameter int WIDTH
) (
    input   logic               clk,
    input   logic               en,
    input   logic   [WIDTH-1:0] din,
    output  logic   [WIDTH-1:0] dout
);
    logic clk_gated;

    tech_icg u_cg (
        .clk    (clk),
        .en     (en),
        .gclk   (clk_gated)
    );

    always_ff @(posedge clk_gated) begin
        dout <= din;
    end
endmodule

module cg_rf #(
    parameter int COUNT,
    parameter int WIDTH
) (
    input   logic   clk,

    input   logic   [$clog2(COUNT)-1:0] ridx,
    output  logic   [WIDTH-1:0]         rdat,

    input   logic                       wen,
    input   logic   [$clog2(COUNT)-1:0] widx,
    input   logic   [WIDTH-1:0]         wdat
);
    logic[COUNT-1:0][WIDTH-1:0] rf;

    for (genvar i = 0; i < COUNT; ++i) begin : row
        logic row_clk;

        tech_icg u_cg (
            .clk    (clk),
            .en     (wen & (widx == i[$clog2(COUNT)-1:0])),
            .gclk   (row_clk)
        );

        always_ff @(posedge row_clk) begin
            rf[i] <= wdat;
        end
    end

    assign rdat = rf[ridx];

    initial
        assert(`is_pow2(COUNT)) else $fatal;
endmodule

`endif/*DEFS_SVH*/