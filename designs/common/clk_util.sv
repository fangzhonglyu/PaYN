// Barry Lyu, 06/06/2025
// Adapted from BRGTC6 Testing Infra by Parker Schless

`ifndef ASTRAEA_CLK_UTILS
`define ASTRAEA_CLK_UTILS

`timescale 1ns/1ps

`include "common/defines.sv"

//========================================================================
// Clock Utilities
//========================================================================

module ClkUtils #(
  parameter TIMEOUT = 10000
) (
  output logic clk,
  output logic reset,
  output logic timeout
);

initial reset  = 0;

//----------------------------------------------------------------------
// Clock controller
//----------------------------------------------------------------------
real clk_period = 10.0;

logic clk_rst;
initial clk_rst = 0;

logic clk_ack;
initial clk_ack = 0;

initial clk = 1'b1;

always begin
  if (!clk_rst) begin
    clk <= ~clk;
    clk_ack <= 0;
    #(clk_period/2);
  end
  else begin
    clk <= 1'b0;
    clk_ack <= 1;
    #1;
  end
end

//----------------------------------------------------------------------
// Cycle counter + timeout check
//----------------------------------------------------------------------
int cycles = 0;
initial timeout = 0;

always @(posedge clk) begin
  if (reset)
    cycles <= 0;
  else
    cycles <= cycles + 1;

  if (cycles > TIMEOUT) begin
    $write($sformatf("\n\n%sTIMEOUT @ %0dns%s", `RED, $time, `RESET));
    timeout <= 1;
  end
end

//----------------------------------------------------------------------
// Set clock
//----------------------------------------------------------------------
task set_clock ( real new_clk_period );
  clk_rst = 1;
  while(!clk_ack) #1;
  clk_period = new_clk_period;
  clk_rst = 0;
endtask

//----------------------------------------------------------------------
// do_reset
//----------------------------------------------------------------------
task do_reset();
  // Avoid asserting reset on the clock generator's time-zero transition;
  // gate-level UDP models need a real post-initialization reset edge.
  @(posedge clk);
  @(negedge clk);
  reset = 1;
  repeat (2) @(negedge clk);
  reset = 0;
  `INFO_MSG;
  $display("Performed reset at time %0t", $time);
endtask

endmodule

`endif
