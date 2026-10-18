# Sign-off STA of a routed run at its OPERATING clock, for routes synthesized and routed against a tighter clock
# (flow/bitmod_hier.sh: over-constrained for margin, simulated and measured at 400 MHz).
#   env: RUN_DIR (the route), TOP, OP_PERIOD (ns), OP_UNCERTAINTY (ns, setup and hold), OUT_DIR
# Reads the routed netlist and SPEF and the synthesis SDC with only its create_clock re-timed to OP_PERIOD
# (I/O delays in the SDC are absolute and stay), adds the implementation clock uncertainty (as ASTRAEA's APR does)
# and propagated clocks, and reports the worst setup and hold path.
set RUN_DIR $env(RUN_DIR)
set DESIGN_NAME $env(TOP)
set OP_PERIOD $env(OP_PERIOD)
set UNC $env(OP_UNCERTAINTY)
set OUT_DIR $env(OUT_DIR)
source [file join [file dirname [file normalize [info script]]] pt_libraries.tcl]

set fin [open $RUN_DIR/${DESIGN_NAME}.syn.sdc r]
set sdc [read $fin]
close $fin
set n [regsub -all -line {^create_clock \[get_ports clk\]\s+-period\s+\S+\s+-waveform\s+\{\S+\s+\S+\}} $sdc \
       "create_clock \[get_ports clk\] -period $OP_PERIOD -waveform \{0 [expr {$OP_PERIOD / 2.0}]\}" sdc]
if {$n != 1} { puts "ERROR: expected exactly one create_clock on port clk in the SDC, re-timed $n"; exit 1 }
set op_sdc $OUT_DIR/${DESIGN_NAME}.opclock.sdc
set fout [open $op_sdc w]
puts $fout $sdc
close $fout

read_verilog $RUN_DIR/outputs/${DESIGN_NAME}.apr.v
current_design $DESIGN_NAME
link_design
read_sdc $op_sdc
set_clock_uncertainty -setup $UNC [all_clocks]
set_clock_uncertainty -hold $UNC [all_clocks]
set_propagated_clock [all_clocks]
read_parasitics -format SPEF $RUN_DIR/outputs/${DESIGN_NAME}.spef
update_timing -full
report_annotated_parasitics > $OUT_DIR/parasitics.rpt
report_timing -delay_type max -max_paths 5 -nosplit > $OUT_DIR/setup_opclock.rpt
report_timing -delay_type min -max_paths 5 -nosplit > $OUT_DIR/hold_opclock.rpt
set s [get_attribute [get_timing_paths -delay_type max -max_paths 1] slack]
set h [get_attribute [get_timing_paths -delay_type min -max_paths 1] slack]
puts "OPCLOCK_STA period=$OP_PERIOD uncertainty=$UNC setup_wns=$s hold_wns=$h"
exit
