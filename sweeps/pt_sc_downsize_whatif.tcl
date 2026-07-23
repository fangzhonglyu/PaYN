# In-memory routed what-if: resize selected PaYN tile logic from X1/X0P7 to
# smaller function-equivalent cells, then report timing and PrimeTime-PX power.
# The APR netlist and files are not modified.
set DESIGN_NAME $env(TOP)
set SAIF_FILE $env(SAIF_FILE)
set OUT [expr {[info exists env(OUT)] && $env(OUT) ne "" ? \
    $env(OUT) : "reports/sc_downsize_whatif.rpt"}]

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
suppress_message NED-045

proc total_power {} {
    redirect -variable report {report_power -significant_digits 9 -nosplit}
    foreach line [split $report "\n"] {
        if {[regexp {Total Power\s*=\s*(\S+)} $line -> value]} {
            return $value
        }
    }
    error "Total Power not found"
}

proc cell_power {cells attribute} {
    set result 0.0
    foreach_in_collection cell $cells {
        set result [expr {$result + [get_attribute $cell $attribute]}]
    }
    return $result
}

proc measure {label fh} {
    update_timing -full
    update_power
    set worst [get_timing_paths -delay_type max -max_paths 1]
    set wns [get_attribute $worst slack]
    set tile [get_cells -quiet -hierarchical -filter \
        {is_hierarchical == false && is_sequential == false && full_name =~ *u_inner*}]
    set candidates [filter_collection $tile \
        {ref_name =~ AND2_* || ref_name =~ AND4_* || \
         ref_name =~ AO21_* || ref_name =~ AO22_* || \
         ref_name =~ AOI21_* || ref_name =~ AOI22_* || \
         ref_name =~ INV_* || ref_name =~ BUF_* || \
         ref_name =~ XNOR3_*}]
    set ci [cell_power $candidates internal_power]
    set cs [cell_power $candidates switching_power]
    set cl [cell_power $candidates leakage_power]
    redirect -file reports/sc_downsize_${label}_constraints.rpt {
        report_constraint -all_violators -nosplit \
            -max_transition -max_capacitance
    }
    puts $fh [format "%s,%.9f,%.9f,%d,%.9f,%.9f,%.9f,%.9f" \
        $label $wns [expr {1000.0*[total_power]}] \
        [sizeof_collection $candidates] [expr {1000.0*$ci}] \
        [expr {1000.0*$cs}] [expr {1000.0*$cl}] \
        [expr {1000.0*($ci+$cs+$cl)}]]
}

proc resize_family {family from_sizes to_size} {
    set suffix A7PP140ZTS_C30
    set target [get_lib_cells -quiet */${family}_${to_size}M_${suffix}]
    if {[sizeof_collection $target] != 1} {
        error "Missing or ambiguous target ${family}_${to_size}M_${suffix}"
    }
    set cells [get_cells -quiet -hierarchical -filter \
        "is_hierarchical == false && full_name =~ *u_inner* && ref_name =~ ${family}_*M_${suffix}"]
    set selected [remove_from_collection $cells $cells]
    foreach from_size $from_sizes {
        set source [filter_collection $cells \
            "ref_name == ${family}_${from_size}M_${suffix}"]
        set selected [add_to_collection $selected $source]
    }
    if {[sizeof_collection $selected] > 0} {
        size_cell $selected [get_object_name $target]
    }
    puts "RESIZED $family [join $from_sizes +]->$to_size count=[sizeof_collection $selected]"
}

catch {file mkdir [file dirname $OUT]}
set fh [open $OUT w]
puts $fh "scenario,setup_wns_ns,total_power_mW,candidate_count,candidate_internal_mW,candidate_switching_mW,candidate_leakage_mW,candidate_total_mW"
measure baseline $fh

foreach family {AND2 AND4 AO21 AO22 AOI21 AOI22 INV BUF XNOR3} {
    resize_family $family {X1} X0P7
}
measure x0p7 $fh

foreach family {AND2 AND4 AO21 AO22 AOI21 AOI22 INV BUF XNOR3} {
    resize_family $family {X1 X0P7} X0P5
}
measure x0p5 $fh

close $fh
puts "SC_DOWNSIZE_WHATIF_DONE $DESIGN_NAME"
exit
