# Routed PrimeTime-PX power grouped by leaf reference family for PaYN compute
# tiles. Run from an APR run directory with TOP and SAIF_FILE set.
set DESIGN_NAME $env(TOP)
set SAIF_FILE $env(SAIF_FILE)
set OUT [expr {[info exists env(OUT)] && $env(OUT) ne "" ? \
    $env(OUT) : "reports/sc_cell_family_power.rpt"}]

set power_enable_analysis true
set power_analysis_mode averaged
set power_model_preference ccs
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
read_verilog outputs/${DESIGN_NAME}.apr.v
current_design $DESIGN_NAME
link_design
read_sdc ${DESIGN_NAME}.syn.sdc
read_parasitics -format SPEF outputs/${DESIGN_NAME}.spef
update_timing -full
reset_switching_activity
read_saif $SAIF_FILE -strip_path Top/dut
update_power

array set count {}
array set internal {}
array set switching {}
array set leakage {}
array set output_pins {}
array set output_toggles {}
array set output_gt_one {}
array set output_max {}
array set output_excess {}
set clock_period [get_attribute [get_clocks clk] period]
set tile_cells [get_cells -quiet -hierarchical -filter \
    {is_hierarchical == false && is_sequential == false && full_name =~ *u_inner*}]

foreach_in_collection cell $tile_cells {
    set ref [get_attribute $cell ref_name]
    if {![regexp {^([^_]+)_X} $ref -> family]} {
        set family OTHER
    }
    if {![info exists count($family)]} {
        set count($family) 0
        set internal($family) 0.0
        set switching($family) 0.0
        set leakage($family) 0.0
        set output_pins($family) 0
        set output_toggles($family) 0.0
        set output_gt_one($family) 0
        set output_max($family) 0.0
        set output_excess($family) 0.0
    }
    incr count($family)
    set internal($family) [expr {$internal($family) + [get_attribute $cell internal_power]}]
    set switching($family) [expr {$switching($family) + [get_attribute $cell switching_power]}]
    set leakage($family) [expr {$leakage($family) + [get_attribute $cell leakage_power]}]
    foreach_in_collection pin [get_pins -quiet -of_objects $cell -filter {direction == out}] {
        set transitions [expr {$clock_period * [get_attribute $pin toggle_rate]}]
        incr output_pins($family)
        set output_toggles($family) [expr {$output_toggles($family) + $transitions}]
        if {$transitions > 1.0} {
            incr output_gt_one($family)
            set output_excess($family) \
                [expr {$output_excess($family) + $transitions - 1.0}]
        }
        if {$transitions > $output_max($family)} { set output_max($family) $transitions }
    }
}

set rows {}
foreach family [array names count] {
    set total [expr {$internal($family) + $switching($family) + $leakage($family)}]
    lappend rows [list $total $family]
}
set rows [lsort -real -decreasing -index 0 $rows]

catch {file mkdir [file dirname $OUT]}
set fh [open $OUT w]
puts $fh "family,count,internal_mW,switching_mW,leakage_mW,total_mW,output_pins,avg_output_transitions_per_cycle,pct_output_pins_gt_one,min_glitch_fraction_of_output_transitions,max_output_transitions_per_cycle"
set sum_i 0.0
set sum_s 0.0
set sum_l 0.0
foreach row $rows {
    lassign $row total family
    set sum_i [expr {$sum_i + $internal($family)}]
    set sum_s [expr {$sum_s + $switching($family)}]
    set sum_l [expr {$sum_l + $leakage($family)}]
    set average [expr {$output_pins($family) ? \
        $output_toggles($family)/$output_pins($family) : 0.0}]
    set pct_gt_one [expr {$output_pins($family) ? \
        100.0*$output_gt_one($family)/$output_pins($family) : 0.0}]
    set min_glitch_fraction [expr {$output_toggles($family) > 0.0 ? \
        100.0*$output_excess($family)/$output_toggles($family) : 0.0}]
    puts $fh [format "%s,%d,%.9f,%.9f,%.9f,%.9f,%d,%.6f,%.3f,%.3f,%.6f" \
        $family $count($family) \
        [expr {1000.0*$internal($family)}] \
        [expr {1000.0*$switching($family)}] \
        [expr {1000.0*$leakage($family)}] \
        [expr {1000.0*$total}] $output_pins($family) $average \
        $pct_gt_one $min_glitch_fraction $output_max($family)]
}
puts $fh [format "TOTAL,%d,%.9f,%.9f,%.9f,%.9f,,,," \
    [sizeof_collection $tile_cells] [expr {1000.0*$sum_i}] \
    [expr {1000.0*$sum_s}] [expr {1000.0*$sum_l}] \
    [expr {1000.0*($sum_i+$sum_s+$sum_l)}]]
close $fh
puts "SC_CELL_FAMILY_POWER_DONE $DESIGN_NAME"
exit
