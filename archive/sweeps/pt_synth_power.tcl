# SAIF-annotated power on the SYNTHESIS netlist (no SPEF -> zero-wireload nets),
# using the SAME dut.saif as the APR power run. This isolates the parasitic +
# clock-tree cost that APR adds: same switching activity, no interconnect.
# (The DC synth pwr.rpt uses DEFAULT activity and is unreliable for SC; this
# replaces it for the synth-vs-APR comparison.)
# cwd = synth run dir. Env: TOP, SAIF_FILE. TSMC22.
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set power_enable_analysis  "true"
set power_analysis_mode    "averaged"
set power_model_preference "ccs"
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
read_verilog "${DESIGN_NAME}.syn.v"
current_design $DESIGN_NAME
link_design
read_sdc "${DESIGN_NAME}.syn.sdc"
update_timing -full

set clock_periods [get_attribute [get_clocks *] period]
if {[llength $clock_periods] == 0} {
    error "No clock period found after reading ${DESIGN_NAME}.syn.sdc"
}
set target_period_ns [lindex $clock_periods 0]
if {[info exists env(EXPECTED_PERIOD_NS)] &&
    abs(double($target_period_ns) - double($env(EXPECTED_PERIOD_NS))) > 1.0e-6} {
    error "Synth clock period ${target_period_ns} ns does not match accepted SAIF period $env(EXPECTED_PERIOD_NS) ns"
}
reset_switching_activity
read_saif $SAIF_FILE -strip_path "Top/dut"
update_power

set comb 0.0; set reg 0.0; set clk 0.0; set tot 0.0
redirect -variable grp { report_power -nosplit }
foreach l [split $grp "\n"] {
    if {[regexp {^\s*combinational\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> d]} { set comb $d }
    if {[regexp {^\s*register\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> d]} { set reg $d }
    if {[regexp {^\s*clock_network\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> d]} { set clk $d }
    if {[regexp {Total Power\s*=\s*(\S+)} $l -> t]} { set tot $t }
}
set netpct ""
redirect -variable cov { report_switching_activity -list_not_annotated }
foreach l [split $cov "\n"] {
    if {[regexp {Nets\s+\d+\(([0-9.]+)%\)} $l -> p]} { set netpct $p }
}
proc mw {x} { return [format "%.4f" [expr {$x*1000.0}]] }
catch { file mkdir reports }
set fh [open reports/synth_saif_power.rpt w]
puts $fh "SAIF_FILE $SAIF_FILE"
puts $fh "TARGET_PERIOD_NS $target_period_ns"
puts $fh "$grp"
puts $fh "net_annotated_pct $netpct"
puts $fh "SYNTHPWR,$DESIGN_NAME,[mw $tot],[mw $comb],[mw $reg],[mw $clk],$netpct"
close $fh
puts "SYNTH_POWER_DONE $DESIGN_NAME  total [mw $tot] mW  net_annot ${netpct}%"
exit
