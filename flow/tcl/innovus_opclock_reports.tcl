# Innovus timing of a finished route re-timed to its OPERATING clock (flow/bitmod_hier.sh: synthesized and routed
# against a tighter clock for margin, used at 400 MHz).  Run in a scratch directory, never in the route:
#   env: RUN_DIR (the route), TOP, OP_PERIOD (ns), OUT_DIR
# Restores <top>.final.enc.dat, writes the restored timing (must reproduce the route's own reports/setup.rpt and
# hold.rpt) and the restored constraints, then re-applies those same constraints with only the clock period and
# waveform changed (update_constraint_mode, latencies kept) and writes the reports again, in the exact form of
# ASTRAEA's apr.tcl final reports, under <OUT_DIR>/{restored,opclock}/reports/ so apr_qualify.route_slacks
# reads them unchanged.
set RUN_DIR $env(RUN_DIR)
set top $env(TOP)
set OP_PERIOD $env(OP_PERIOD)
set OUT_DIR $env(OUT_DIR)

restoreDesign $RUN_DIR/${top}.final.enc.dat $top
file mkdir $OUT_DIR/restored/reports $OUT_DIR/opclock/reports

set mode [all_constraint_modes -active]
if {[llength $mode] != 1} { puts "ERROR: expected one active constraint mode, got '$mode'"; exit 1 }

report_timing -late  -max_paths 999 > $OUT_DIR/restored/reports/setup.rpt
report_timing -early -max_paths 999 > $OUT_DIR/restored/reports/hold.rpt
write_sdc $OUT_DIR/restored/${top}.sdc

set fin [open $OUT_DIR/restored/${top}.sdc r]
set sdc [read $fin]
close $fin
set n [regsub -all -line {^(create_clock .*-period )\S+( .*-waveform )\{\S+ \S+\}(.*)$} $sdc \
       "\\1$OP_PERIOD\\2\{0 [expr {$OP_PERIOD / 2.0}]\}\\3" sdc]
if {$n != 1} { puts "ERROR: expected exactly one create_clock in the restored SDC, re-timed $n"; exit 1 }
set op_sdc $OUT_DIR/opclock/${top}.sdc
set fout [open $op_sdc w]
puts -nonewline $fout $sdc
close $fout

update_constraint_mode -name $mode -sdc_files $op_sdc
puts "INFO: clock period now [get_property [get_clocks] period] ns"

report_timing -late  -max_paths 999 > $OUT_DIR/opclock/reports/setup.rpt
report_timing -early -max_paths 999 > $OUT_DIR/opclock/reports/hold.rpt
puts "INNOVUS_OPCLOCK_DONE"
exit
