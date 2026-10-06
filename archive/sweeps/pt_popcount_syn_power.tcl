# Workload-annotated pre-layout power for the matched popcount experiment.
# No SPEF or CTS: cell internal power, pin-load switching, and leakage only.
set power_enable_analysis true
set power_analysis_mode averaged
set power_model_preference ccs
set report_default_significant_digits 9
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
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
report_power -significant_digits 9 -hier -nosplit > power_hier.rpt
report_switching_activity -list_not_annotated > saif_coverage.rpt

proc pvalue {cell attribute} {
    set value [get_attribute -quiet $cell $attribute]
    if {$value eq "" || ![string is double -strict $value]} { return 0.0 }
    return $value
}

array set count {}
array set internal {}
array set switching {}
array set leakage {}
foreach block {u_pe u_peripheral u_a_rng u_w_rng top_other tile_combinational counter} {
    set count($block) 0
    set internal($block) 0.0
    set switching($block) 0.0
    set leakage($block) 0.0
}
foreach_in_collection cell [get_cells -hierarchical -filter {is_hierarchical==false}] {
    set name [get_object_name $cell]
    set block top_other
    foreach candidate {u_pe u_peripheral u_a_rng u_w_rng} {
        if {[string match "${candidate}/*" $name]} { set block $candidate; break }
    }
    set buckets [list $block]
    set seq [get_attribute $cell is_sequential]
    if {[string match *u_inner* $name] && !($seq eq "true" || $seq eq "1")} {
        lappend buckets tile_combinational
    }
    if {[string match *u_popcount* $name]} { lappend buckets counter }
    foreach bucket $buckets {
        incr count($bucket)
        set internal($bucket) [expr {$internal($bucket) + [pvalue $cell internal_power]}]
        set switching($bucket) [expr {$switching($bucket) + [pvalue $cell switching_power]}]
        set leakage($bucket) [expr {$leakage($bucket) + [pvalue $cell leakage_power]}]
    }
}
set output [open block_power.csv w]
puts $output "block,cells,internal_mW,switching_mW,leakage_mW,total_mW"
foreach block {u_pe u_peripheral u_a_rng u_w_rng top_other tile_combinational counter} {
    puts $output [format "%s,%d,%.9f,%.9f,%.9f,%.9f" $block $count($block) \
        [expr {1000*$internal($block)}] [expr {1000*$switching($block)}] \
        [expr {1000*$leakage($block)}] \
        [expr {1000*($internal($block)+$switching($block)+$leakage($block))}]]
}
close $output
puts "POPCOUNT_SYN_POWER_DONE $env(TOP)"
exit
