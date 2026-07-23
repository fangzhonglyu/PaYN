# Routed-net capacitance and switching-power summary for the SC operand pipes.
#
# Run from an APR run directory after a power-annotated gate-level simulation:
#   TOP=payn_array SAIF_FILE=/abs/path/dut.saif \
#     pt_shell -file /abs/path/sweeps/pt_sc_net_loads.tcl
#
# The A/W rows describe the nets directly driven by the operand-pipe flops.
# The all_nets row is also reported because MAX_FANOUT may insert buffer trees;
# their branch capacitance is not part of the original flop-Q net anymore.
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set OUT [expr {[info exists env(OUT)] && $env(OUT) ne "" ? \
    $env(OUT) : "reports/sc_net_loads.rpt"}]

set power_enable_analysis  "true"
set power_analysis_mode    "averaged"
set power_model_preference "ccs"
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

proc percentile {values fraction} {
    if {[llength $values] == 0} { return 0.0 }
    set sorted [lsort -real $values]
    set index [expr {int(ceil($fraction * [llength $sorted])) - 1}]
    if {$index < 0} { set index 0 }
    return [lindex $sorted $index]
}

# Return: reported-net count, total cap (pF), average/p95/max cap (fF), and
# total net switching power (mW).  PrimeTime's report units are pF and W.
proc summarize_net_power {nets leaf_mode} {
    if {$leaf_mode} {
        redirect -variable report_text {
            report_power -net_power -leaf -include_boundary_nets \
                -nworst 1000000 -sort_by total_net_load \
                -significant_digits 8 -nosplit
        }
    } else {
        redirect -variable report_text {
            report_power -net_power -nworst 1000000 \
                -sort_by total_net_load -significant_digits 8 \
                -nosplit $nets
        }
    }

    set count 0
    set cap_sum 0.0
    set switching_sum 0.0
    set cap_values {}
    foreach line [split $report_text "\n"] {
        set fields [regexp -all -inline {\S+} [string trim $line]]
        if {[llength $fields] != 7} { continue }
        set cap [lindex $fields 2]
        set switching [lindex $fields 5]
        if {![string is double -strict $cap] ||
            ![string is double -strict $switching]} { continue }
        incr count
        set cap_sum [expr {$cap_sum + $cap}]
        set switching_sum [expr {$switching_sum + $switching}]
        lappend cap_values $cap
    }
    set average [expr {$count ? 1000.0 * $cap_sum / $count : 0.0}]
    set p95 [expr {1000.0 * [percentile $cap_values 0.95]}]
    set maximum [expr {1000.0 * [percentile $cap_values 1.0]}]
    return [list $count $cap_sum $average $p95 $maximum \
        [expr {1000.0 * $switching_sum}]]
}

proc summarize_fanout {nets} {
    set count 0
    set total 0
    set maximum 0
    foreach_in_collection net $nets {
        set sinks [get_pins -quiet -of_objects $net -filter {direction == in}]
        set fanout [sizeof_collection $sinks]
        incr count
        incr total $fanout
        if {$fanout > $maximum} { set maximum $fanout }
    }
    set average [expr {$count ? double($total) / $count : 0.0}]
    return [list $average $maximum]
}

set a_pipe [get_cells -quiet -hierarchical -filter {is_sequential == true} \
    *a_bits_pipe_reg*]
set w_pipe [get_cells -quiet -hierarchical -filter {is_sequential == true} \
    *w_bits_pipe_reg*]
set w_encoded_pipe [get_cells -quiet -hierarchical \
    -filter {is_sequential == true} *w_encoded_pipe_reg*]
set w_pipe [add_to_collection $w_pipe $w_encoded_pipe]
set a_nets [get_nets -quiet -of_objects \
    [get_pins -quiet -of_objects $a_pipe -filter {direction == out}]]
set w_nets [get_nets -quiet -of_objects \
    [get_pins -quiet -of_objects $w_pipe -filter {direction == out}]]

if {[sizeof_collection $a_nets] == 0 || [sizeof_collection $w_nets] == 0} {
    puts stderr "ERROR: operand-pipe nets were not found"
    exit 2
}

set all_summary [summarize_net_power "" 1]
set a_summary [summarize_net_power $a_nets 0]
set w_summary [summarize_net_power $w_nets 0]
set a_fanout [summarize_fanout $a_nets]
set w_fanout [summarize_fanout $w_nets]

catch {file mkdir [file dirname $OUT]}
set fh [open $OUT w]
puts $fh "scope,count,cap_total_pF,cap_avg_fF,cap_p95_fF,cap_max_fF,switching_mW,fanout_avg,fanout_max"
puts $fh [format "all_nets,%d,%.8f,%.6f,%.6f,%.6f,%.8f,," \
    {*}$all_summary]
puts $fh [format "a_pipe_root,%d,%.8f,%.6f,%.6f,%.6f,%.8f,%.4f,%d" \
    {*}$a_summary {*}$a_fanout]
puts $fh [format "w_pipe_root,%d,%.8f,%.6f,%.6f,%.6f,%.8f,%.4f,%d" \
    {*}$w_summary {*}$w_fanout]
puts $fh "CSVROW,$DESIGN_NAME,[join $all_summary ,],[join $a_summary ,],[join $a_fanout ,],[join $w_summary ,],[join $w_fanout ,]"
close $fh
puts "SC_NET_LOADS_DONE $DESIGN_NAME"
exit
