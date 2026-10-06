# Pre-layout PT-PX session identical to sweeps/pt_popcount_syn_power.tcl (same
# libraries, netlist, SDC, SAIF, no SPEF/CTS), but it only writes the leaf-cell
# hierarchy buckets (pt_sc_hier_buckets.tcl) plus a power.rpt whose total must
# equal the original run's.  Env: TOP NL SDC SAIF_FILE.  Writes into the cwd.
set power_enable_analysis true
set power_analysis_mode averaged
set power_model_preference ccs
set report_default_significant_digits 9
source [file join [file dirname [file normalize [info script]]] ../../../pt_tsmc22_libraries.tcl]
read_verilog $env(NL)
current_design $env(TOP)
link_design
read_sdc $env(SDC)
set period [get_attribute [get_clocks clk] period]
if {abs(double($period) - 2.5) > 1.0e-6} { error "Unexpected clock period $period" }
update_timing -full
reset_switching_activity
read_saif $env(SAIF_FILE) -strip_path Top/dut
update_power
report_power -significant_digits 9 -nosplit > power.rpt
source [file join [file dirname [file normalize [info script]]] pt_sc_hier_buckets.tcl]
exit
