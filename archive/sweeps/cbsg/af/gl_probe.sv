`timescale 1ns/1ps
// Gate-level probe for the C-BSG AF functional bench (diagnosis helper for sweeps/cbsg/af/gl_divergence.sh):
// an extra top that samples the netlist's hierarchy ports (stream generator outputs, edge peripheral outputs,
// PE inputs, drain rail) at every negedge and writes them to gl_probe.txt, so two delay modes can be diffed
// edge by edge.  Compiled with `-top GlProbe` next to the bench's Top.
module GlProbe;
    integer fd, n = 0;
    initial fd = $fopen("gl_probe.txt", "w");
    always @(negedge Top.clk) begin
        n++;
        $fdisplay(fd, "%0d rst=%b bs=%b rng=%b mac=%b sh=%b cyc=%h ph=%h words=%h a_signs=%h w_signs=%h",
                  n, Top.reset, Top.block_start, Top.rng_en, Top.mac_en, Top.shift_in,
                  Top.dut.u_rng.cyc, Top.dut.u_rng.phase, Top.dut.u_rng.w_words,
                  Top.dut.u_peripheral.a_signs, Top.dut.u_peripheral.w_signs);
        $fdisplay(fd, "%0d a_bits=%h", n, Top.dut.u_peripheral.a_bits);
        $fdisplay(fd, "%0d w_bits=%h", n, Top.dut.u_peripheral.w_bits);
        $fdisplay(fd, "%0d acc=%h", n, Top.acc_out_east);
    end
endmodule
