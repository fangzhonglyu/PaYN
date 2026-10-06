# Debug helper (2026-10-05): compare the clock latency and one data path of a routed RG run under PT with the
# route's SPEF (MODE=spef) and with its SDF (MODE=sdf, what VCS GL simulates).  Read-only on the run.
# Env: RUN_DIR TOP MODE LIBS (Tcl with the power.tcl library block) FROM TO
source $env(LIBS)
set R $env(RUN_DIR); set T $env(TOP)
read_verilog $R/outputs/$T.apr.v
current_design $T
link_design
read_sdc $R/$T.syn.sdc
set_propagated_clock [all_clocks]
if {$env(MODE) eq "sdf"} {
    read_sdf -analysis_type single $R/outputs/$T.apr.sdf
} else {
    read_parasitics -format SPEF $R/outputs/$T.spef
}
source $env(EXTRA)
update_timing -full
report_clock_timing -type latency -to [get_pins [list $env(FROM_CK) $env(TO_CK)]] -nosplit
report_timing -from $env(FROM) -to $env(TO) -path_type full_clock_expanded -nosplit -input_pins -significant_digits 3
puts PT_CLOCK_PROBE_DONE
exit
