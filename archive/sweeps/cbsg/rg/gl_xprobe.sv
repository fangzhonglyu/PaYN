`timescale 1ns/1ps
// Debug helper for sweeps/cbsg/rg/gl_x_ladder.sh: second top that dumps the gate-level DUT of
// designs/payn/tb/test_payn_array_cbsg_rg.sv (instance Top.dut) to xprobe.vcd for the first
// XPROBE_NS nanoseconds, for sweeps/cbsg/rg/vcd_first_x.py.
`ifndef XPROBE_NS
`define XPROBE_NS 80
`endif
module XProbe;
    initial begin
        $dumpfile("xprobe.vcd");
        $dumpvars(0, Top.dut);
        #(`XPROBE_NS);
        $dumpoff;
        $dumpflush;
    end
endmodule
