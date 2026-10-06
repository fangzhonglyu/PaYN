# Debug helper (2026-10-05): worst setup paths of a routed RG run timed by PT from the route's SDF (MODE=sdf: the
# delays VCS GL simulates) or from its SPEF (MODE=spef: PT's own delay calculation), both with propagated clocks and
# NO clock uncertainty (the GL view).  Read-only on the run.  Env: RUN_DIR TOP MODE LIBS NPATHS
source $env(LIBS)
set R $env(RUN_DIR); set T $env(TOP)
read_verilog $R/outputs/$T.apr.v
current_design $T
link_design
read_sdc $R/$T.syn.sdc
set_propagated_clock [all_clocks]
if {$env(MODE) eq "sdf"} { read_sdf -analysis_type single $R/outputs/$T.apr.sdf } else { read_parasitics -format SPEF $R/outputs/$T.spef }
update_timing -full
report_timing -max_paths $env(NPATHS) -nworst 1 -nosplit -significant_digits 3 -path_type summary
report_timing -delay_type min -max_paths 10 -nworst 1 -nosplit -significant_digits 3 -path_type summary
puts PT_SDF_SPEF_DONE
exit
