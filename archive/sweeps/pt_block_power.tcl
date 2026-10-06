# Block-level routed power at full precision: core PE vs peripheral vs Sobol.
# The stock power_hier.rpt carries 3 significant digits, which cannot resolve a
# ~1% core delta.  Run from an APR dir with TOP and SAIF_FILE set.
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
set NL   "outputs/${DESIGN_NAME}.apr.v"
set SDC  "${DESIGN_NAME}.syn.sdc"
set SPEF "outputs/${DESIGN_NAME}.spef"
set OUT  [expr {[info exists env(OUT)] && $env(OUT) ne "" ? $env(OUT) : "reports/block_power.rpt"}]

set power_enable_analysis  "true"
set power_analysis_mode    "averaged"
set power_model_preference "ccs"
set report_default_significant_digits 8
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
read_verilog $NL
current_design $DESIGN_NAME
link_design
read_sdc $SDC
if {[file exists $SPEF]} { read_parasitics -format SPEF $SPEF }
update_timing -full
reset_switching_activity
read_saif $SAIF_FILE -strip_path $SAIF_STRIP_PATH
update_power

# Cells with no power contribution return an empty attribute rather than 0,
# which would abort the sum.  Coerce.
proc pget {obj attr} {
    set v [get_attribute -quiet $obj $attr]
    if {$v eq "" || ![string is double -strict $v]} { return 0.0 }
    return $v
}

proc blk {name} {
    set c [get_cells -quiet -hierarchical -filter \
        "is_hierarchical==false && full_name=~\"${name}/*\""]
    if {[sizeof_collection $c] == 0} { return [list 0 0.0 0.0 0.0 0.0] }
    set i 0.0; set s 0.0; set l 0.0
    foreach_in_collection x $c {
        set i [expr {$i + [pget $x internal_power]}]
        set s [expr {$s + [pget $x switching_power]}]
        set l [expr {$l + [pget $x leakage_power]}]
    }
    return [list [sizeof_collection $c] $i $s $l [expr {$i+$s+$l}]]
}

set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME"
puts $fh [format "%-16s %8s %14s %14s %14s %14s" block cells internal_mW switch_mW leak_mW total_mW]
set grand 0.0
foreach b {u_pe u_peripheral u_a_rng u_w_rng} {
    set r [blk $b]
    set grand [expr {$grand + [lindex $r 4]}]
    puts $fh [format "%-16s %8d %14.6f %14.6f %14.6f %14.6f" $b [lindex $r 0] \
        [expr {[lindex $r 1]*1000}] [expr {[lindex $r 2]*1000}] \
        [expr {[lindex $r 3]*1000}] [expr {[lindex $r 4]*1000}]]
}
# Whole design, so the leftover (top-level glue + clock tree above the blocks)
# is visible rather than silently dropped.
# Includes physical-only cells (DIODE_*, POSROTFE_* fillers) that carry no
# power attributes at all, hence pget rather than a bare get_attribute.
set all [get_cells -quiet -hierarchical -filter {is_hierarchical==false}]
set ti 0.0; set ts 0.0; set tl 0.0
foreach_in_collection x $all {
    set ti [expr {$ti + [pget $x internal_power]}]
    set ts [expr {$ts + [pget $x switching_power]}]
    set tl [expr {$tl + [pget $x leakage_power]}]
}
set tt [expr {$ti+$ts+$tl}]
puts $fh [format "%-16s %8d %14.6f %14.6f %14.6f %14.6f" TOTAL [sizeof_collection $all] \
    [expr {$ti*1000}] [expr {$ts*1000}] [expr {$tl*1000}] [expr {$tt*1000}]]
puts $fh [format "%-16s %8s %14s %14s %14s %14.6f" "glue(residual)" "" "" "" "" \
    [expr {($tt-$grand)*1000}]]
close $fh
puts "wrote $OUT"
exit
