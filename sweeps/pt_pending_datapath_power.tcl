# Routed power/activity drilldown for the pending-bit signed segmented PaYN
# tile. Reloads the accepted APR netlist/SPEF/SAIF, then reports:
#   * low-, high-, and pending-state register power;
#   * the combinational cones updating low/pending state, retiring high state,
#     and producing the canonical high output (cones may overlap);
#   * inner-tile combinational power grouped by mapped cell family.
#
# Run from an APR directory with TOP and SAIF_FILE set. NL, SDC, SPEF, and OUT
# have the same optional overrides as pt_pe_components.tcl.
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
set NL   [expr {[info exists env(NL)]   && $env(NL)   ne "" ? $env(NL)   : "outputs/${DESIGN_NAME}.apr.v"}]
set SDC  [expr {[info exists env(SDC)]  && $env(SDC)  ne "" ? $env(SDC)  : "${DESIGN_NAME}.syn.sdc"}]
set SPEF [expr {[info exists env(SPEF)] ? $env(SPEF) : "outputs/${DESIGN_NAME}.spef"}]
set OUT  [expr {[info exists env(OUT)]  && $env(OUT)  ne "" ? $env(OUT)  : "reports/pending_datapath_power.rpt"}]

set power_enable_analysis  "true"
set power_analysis_mode    "averaged"
set power_model_preference "ccs"
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
read_verilog $NL
current_design $DESIGN_NAME
link_design
read_sdc $SDC
if {$SPEF ne "" && [file exists $SPEF]} {
    read_parasitics -format SPEF $SPEF
}
update_timing -full
reset_switching_activity
read_saif $SAIF_FILE -strip_path $SAIF_STRIP_PATH
update_power

proc numeric_power_attribute {cell attribute} {
    if {[catch {set value [get_attribute $cell $attribute]}]} {
        return 0.0
    }
    if {$value eq ""} {
        return 0.0
    }
    return $value
}

proc collection_power {cells} {
    set pi 0.0
    set ps 0.0
    set pl 0.0
    foreach_in_collection cell $cells {
        set pi [expr {$pi + [numeric_power_attribute $cell internal_power]}]
        set ps [expr {$ps + [numeric_power_attribute $cell switching_power]}]
        set pl [expr {$pl + [numeric_power_attribute $cell leakage_power]}]
    }
    return [list $pi $ps $pl [expr {$pi + $ps + $pl}]]
}

proc mw_row {label cells} {
    set p [collection_power $cells]
    return [format "%-24s cells %6d  internal %9.6f  switching %9.6f  leakage %9.6f  total %9.6f" \
        $label [sizeof_collection $cells] \
        [expr {[lindex $p 0] * 1000.0}] \
        [expr {[lindex $p 1] * 1000.0}] \
        [expr {[lindex $p 2] * 1000.0}] \
        [expr {[lindex $p 3] * 1000.0}]]
}

proc combinational_fanin {pins} {
    if {[sizeof_collection $pins] == 0} {
        return [get_cells -quiet __no_such_pending_cell__]
    }
    return [filter_collection \
        [all_fanin -flat -only_cells -to $pins] \
        {is_hierarchical==false && is_sequential==false}]
}

set tile_leaves [get_cells -quiet -hierarchical \
    -filter {is_hierarchical==false && full_name=~"*u_inner/*"}]
set tile_comb [filter_collection $tile_leaves {is_sequential==false}]

set low_regs [get_cells -quiet -hierarchical \
    -filter {is_hierarchical==false && is_sequential==true &&
             full_name=~"*u_inner/*acc_low_reg*"}]
set high_regs [get_cells -quiet -hierarchical \
    -filter {is_hierarchical==false && is_sequential==true &&
             full_name=~"*u_inner/*acc_high_reg*" &&
             full_name!~"*clk_gate_acc_high_reg*"}]
set pending_regs [get_cells -quiet -hierarchical \
    -filter {is_hierarchical==false && is_sequential==true &&
             full_name=~"*u_inner/*pending_*_reg*"}]
set high_gate_leaves [get_cells -quiet -hierarchical \
    -filter {is_hierarchical==false &&
             full_name=~"*u_inner/*clk_gate_acc_high_reg*"}]

set low_d [get_pins -quiet -hierarchical \
    -filter {full_name=~"*u_inner/*acc_low_reg*/D*"}]
set pending_d [get_pins -quiet -hierarchical \
    -filter {full_name=~"*u_inner/*pending_*_reg*/D*"}]
set high_d [get_pins -quiet -hierarchical \
    -filter {full_name=~"*u_inner/*acc_high_reg*/D*"}]
set tile_high_out [get_pins -quiet -hierarchical \
    -filter {full_name=~"*u_inner/acc_out*" && pin_direction==out}]

set hot_update_cone [combinational_fanin \
    [add_to_collection $low_d $pending_d]]
set high_retire_cone [combinational_fanin $high_d]
set visible_output_cone [combinational_fanin $tile_high_out]

array set fam_count {}
array set fam_int {}
array set fam_switch {}
array set fam_leak {}
foreach_in_collection cell $tile_comb {
    set ref [get_attribute $cell ref_name]
    if {![info exists fam_count($ref)]} {
        set fam_count($ref) 0
        set fam_int($ref) 0.0
        set fam_switch($ref) 0.0
        set fam_leak($ref) 0.0
    }
    incr fam_count($ref)
    set fam_int($ref) [expr {$fam_int($ref) +
        [numeric_power_attribute $cell internal_power]}]
    set fam_switch($ref) [expr {$fam_switch($ref) +
        [numeric_power_attribute $cell switching_power]}]
    set fam_leak($ref) [expr {$fam_leak($ref) +
        [numeric_power_attribute $cell leakage_power]}]
}

set family_rows {}
foreach ref [array names fam_count] {
    set total [expr {$fam_int($ref) + $fam_switch($ref) + $fam_leak($ref)}]
    lappend family_rows [list $total $ref]
}
set family_rows [lsort -real -decreasing -index 0 $family_rows]

catch { file mkdir [file dirname $OUT] }
set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME"
puts $fh ""
puts $fh "STATE"
puts $fh [mw_row "acc_low registers" $low_regs]
puts $fh [mw_row "acc_high registers" $high_regs]
puts $fh [mw_row "pending registers" $pending_regs]
puts $fh [mw_row "acc_high clock gate" $high_gate_leaves]
puts $fh ""
puts $fh "COMBINATIONAL CONES (overlap is intentional)"
puts $fh [mw_row "all tile combinational" $tile_comb]
puts $fh [mw_row "low+pending update" $hot_update_cone]
puts $fh [mw_row "high retire update" $high_retire_cone]
puts $fh [mw_row "canonical output" $visible_output_cone]
puts $fh ""
puts $fh "TOP INNER-TILE COMBINATIONAL CELL FAMILIES"
puts $fh [format "%-42s %8s %12s %12s %12s %12s" \
    "reference" "cells" "internal_mW" "switch_mW" "leak_mW" "total_mW"]
set shown 0
foreach row $family_rows {
    if {$shown >= 30} { break }
    set ref [lindex $row 1]
    puts $fh [format "%-42s %8d %12.6f %12.6f %12.6f %12.6f" \
        $ref $fam_count($ref) \
        [expr {$fam_int($ref) * 1000.0}] \
        [expr {$fam_switch($ref) * 1000.0}] \
        [expr {$fam_leak($ref) * 1000.0}] \
        [expr {[lindex $row 0] * 1000.0}]]
    incr shown
}
close $fh
puts "PENDING_DATAPATH_POWER_DONE $OUT"
exit
