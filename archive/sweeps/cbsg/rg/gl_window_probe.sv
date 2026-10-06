`timescale 1ns/1ps
// Debug helper (2026-10-05, cbsg_rg_20261005b bootstrap GL audit): a second top that dumps the whole
// gate-level DUT Top.dut of the RG power bench to window_probe.vcd for the window
// [PROBE_T0_NS, PROBE_T0_NS + PROBE_LEN_NS], to trace one timing-check violation back through the netlist.
`ifndef PROBE_T0_NS
`define PROBE_T0_NS 339.0
`endif
`ifndef PROBE_LEN_NS
`define PROBE_LEN_NS 3.6
`endif
module GlWindowProbe;
    initial begin
        $dumpfile("window_probe.vcd");
        #(`PROBE_T0_NS);
        $dumpvars(0, Top.dut);
        #(`PROBE_LEN_NS);
        $dumpoff;
        $dumpflush;
    end
endmodule
