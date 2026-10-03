`ifndef PAYN_SIGNED_SEGMENTED_POPCOUNT_COUNTER
`define PAYN_SIGNED_SEGMENTED_POPCOUNT_COUNTER

// One-bit compressor cells. Inferred mode permits ordinary synthesis mapping.
// The explicit-cell experiment is enabled only for technology synthesis so
// ordinary RTL simulation needs no foundry cell models.
module PaynPopcountFA (
    input  logic a, b, ci,
    output logic s, co
);
`ifdef PAYN_POPCOUNT_TECHMAP
`ifdef SYNTHESIS
    ADDF_X1M_A7PP140ZTS_C30 u_cell (
        .A(a), .B(b), .CI(ci), .S(s), .CO(co)
    );
`else
    assign {co, s} = {1'b0, a} + {1'b0, b} + {1'b0, ci};
`endif
`else
    assign {co, s} = {1'b0, a} + {1'b0, b} + {1'b0, ci};
`endif
endmodule

module PaynPopcountHA (
    input  logic a, b,
    output logic s, co
);
`ifdef PAYN_POPCOUNT_TECHMAP
`ifdef SYNTHESIS
    ADDH_X1M_A7PP140ZTS_C30 u_cell (
        .A(a), .B(b), .S(s), .CO(co)
    );
`else
    assign {co, s} = {1'b0, a} + {1'b0, b};
`endif
`else
    assign {co, s} = {1'b0, a} + {1'b0, b};
`endif
endmodule

// Exact 16-input population counter. Each compressor preserves bit weight:
// a+b+ci = s+2*co. Column 0 uses 7 FA + 1 HA, column 1 uses 3 FA + 1 HA,
// column 2 uses 1 FA + 1 HA, and column 3 uses 1 HA. Total: 11 FA + 4 HA.
module PaynPopcount16 (
    input  logic [15:0] bits_in,
    output logic [4:0] count
);
    logic [10:0] fs, fc;
    logic [2:0] hc;

    for (genvar i = 0; i < 5; i++) begin : g_first
        PaynPopcountFA u_fa (
            .a(bits_in[3*i]), .b(bits_in[3*i+1]), .ci(bits_in[3*i+2]),
            .s(fs[i]), .co(fc[i])
        );
    end
    PaynPopcountFA u_fa5 (.a(fs[0]), .b(fs[1]), .ci(fs[2]), .s(fs[5]), .co(fc[5]));
    PaynPopcountFA u_fa6 (.a(fs[3]), .b(fs[4]), .ci(bits_in[15]), .s(fs[6]), .co(fc[6]));
    PaynPopcountHA u_ha0 (.a(fs[5]), .b(fs[6]), .s(count[0]), .co(hc[0]));

    PaynPopcountFA u_fa7 (.a(fc[0]), .b(fc[1]), .ci(fc[2]), .s(fs[7]), .co(fc[7]));
    PaynPopcountFA u_fa8 (.a(fc[3]), .b(fc[4]), .ci(fc[5]), .s(fs[8]), .co(fc[8]));
    PaynPopcountFA u_fa9 (.a(fs[7]), .b(fs[8]), .ci(fc[6]), .s(fs[9]), .co(fc[9]));
    PaynPopcountHA u_ha1 (.a(fs[9]), .b(hc[0]), .s(count[1]), .co(hc[1]));

    PaynPopcountFA u_fa10 (.a(fc[7]), .b(fc[8]), .ci(fc[9]), .s(fs[10]), .co(fc[10]));
    PaynPopcountHA u_ha2 (.a(fs[10]), .b(hc[1]), .s(count[2]), .co(hc[2]));
    PaynPopcountHA u_ha3 (.a(fc[10]), .b(hc[2]), .s(count[3]), .co(count[4]));
endmodule

// Stable child name u_popcount at every lane; preserve its descendants for the
// technology-mapped experiment. Other M values retain the baseline behavior.
module PaynUnsignedPopcount #(
    parameter int M = 16
) (
    input  logic [M-1:0] bits_in,
    output logic [$clog2(M+1)-1:0] count
);
    if (M == 16) begin : g_m16
        PaynPopcount16 u_counter (.bits_in(bits_in), .count(count));
    end else begin : g_generic
        assign count = $clog2(M+1)'($countones(bits_in));
    end
endmodule

`endif
