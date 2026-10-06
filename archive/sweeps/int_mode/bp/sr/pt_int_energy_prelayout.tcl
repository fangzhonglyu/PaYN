# Pre-layout PT-PX for the INT energy A/B of the lap-length variants
# (sweeps/int_mode/bp/sr/run_int_energy_prelayout_ab.sh).
#
# The routed flow's script (ASTRAEA apr/scripts/power.tcl, used by
# run_bp_int_energy.sh through `make power_apr`) with the synthesized netlist
# and SDC instead of the APR outputs and NO parasitics: cell internal power,
# pin-load switching and leakage only, no wire capacitance and no clock tree
# (the clock is ideal in the synthesized netlist).  Same libraries (base + HPK
# SVT, tt 0.80 V 25 C via sweeps/pt_tsmc22_libraries.tcl, which builds the
# same list as power.tcl's TSMC22 branch), same averaged/CCS settings, same
# SAIF strip path, same ZERO_PINLESS_NET_ACTIVITY policy and the same report
# files, so sweeps/int_mode/bp/bp_int_energy_row.py parses them unchanged.
# Absolute numbers are NOT comparable with the routed ones; deltas between
# netlists under the same stimulus are what this is for.
#
# Extra: reports/block_power.csv, a cell-based split of the design into
#   tiles_seq / tiles_comb   u_pe/u_array_core/*u_inner* (the 64 tiles,
#                            their clock gates included)
#   core_other_seq / _comb   u_pe/u_array_core outside the tiles (bit and sign
#                            pipes, the sub-ring head muxes / IPD muxes and
#                            their select trees)
#   pe_other                 u_pe outside the core (ring_q, BP west mux)
#   u_peripheral u_combiner u_a_rng u_w_rng top_other
#
# Run with cwd = the point's power directory.  Env: TOP, NL, SDC, SAIF_FILE,
# optional SAIF_STRIP_PATH (default Top/dut), ZERO_PINLESS_NET_ACTIVITY.
set power_enable_analysis        "true"
set power_analysis_mode          "averaged"
set power_model_preference       "ccs"
source [file join [file dirname [file normalize [info script]]] .. .. .. pt_tsmc22_libraries.tcl]

set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
if {[info exists env(SAIF_STRIP_PATH)] && $env(SAIF_STRIP_PATH) ne ""} {
    set SAIF_STRIP_PATH $env(SAIF_STRIP_PATH)
}
foreach f [list $env(NL) $env(SDC) $SAIF_FILE] {
    if {![file exists $f]} { puts "ERROR: required input not found: $f"; exit 1 }
}
puts "PRELAYOUT_INPUTS netlist=$env(NL) sdc=$env(SDC) saif=$SAIF_FILE strip=$SAIF_STRIP_PATH"
puts "PRELAYOUT_LIBS [join $link_library { }]"

read_verilog $env(NL)
current_design $DESIGN_NAME
link_design
read_sdc $env(SDC)
set period [get_attribute [get_clocks clk] period]
if {abs(double($period) - 2.5) > 1.0e-6} { puts "ERROR: unexpected clock period $period"; exit 1 }

update_timing -full
check_power

reset_switching_activity
read_saif $SAIF_FILE -strip_path $SAIF_STRIP_PATH

if {[info exists env(ZERO_PINLESS_NET_ACTIVITY)] &&
    $env(ZERO_PINLESS_NET_ACTIVITY) == 1} {
    set pinless_count 0
    foreach_in_collection net [get_nets -hierarchical *] {
        if {[sizeof_collection [get_pins -quiet -of_objects $net]] == 0 &&
            [sizeof_collection [get_ports -quiet -of_objects $net]] == 0} {
            set_switching_activity -static_probability 0.0 -toggle_rate 0.0 $net
            incr pinless_count
        }
    }
    puts "Forced $pinless_count pinless net(s) to static-zero activity"
}

file mkdir reports
report_switching_activity -list_not_annotated > reports/saif_coverage.rpt

update_power

report_power -significant_digits 6 -nosplit              > reports/power.rpt
report_power -significant_digits 6 -hier -nosplit        > reports/power_hier.rpt
report_power -significant_digits 6 -cell_power -nosplit  > reports/cell_power.rpt
report_analysis_coverage                       > reports/analysis_coverage.rpt
report_units                                   > reports/units.rpt

proc pvalue {cell attribute} {
    set value [get_attribute -quiet $cell $attribute]
    if {$value eq "" || ![string is double -strict $value]} { return 0.0 }
    return $value
}
set blocks {tiles_seq tiles_comb core_other_seq core_other_comb pe_other u_peripheral u_combiner u_a_rng u_w_rng top_other}
foreach b $blocks {
    set count($b) 0; set internal($b) 0.0; set switching($b) 0.0; set leakage($b) 0.0
}
foreach_in_collection cell [get_cells -hierarchical -filter {is_hierarchical==false}] {
    set name [get_object_name $cell]
    set seq [get_attribute -quiet $cell is_sequential]
    set sfx [expr {($seq eq "true" || $seq eq "1") ? "seq" : "comb"}]
    if {[string match "u_pe/u_array_core/*u_inner*" $name]} {
        set b tiles_$sfx
    } elseif {[string match "u_pe/u_array_core/*" $name]} {
        set b core_other_$sfx
    } elseif {[string match "u_pe/*" $name]} {
        set b pe_other
    } else {
        set b top_other
        foreach cand {u_peripheral u_combiner u_a_rng u_w_rng} {
            if {[string match "${cand}/*" $name]} { set b $cand; break }
        }
    }
    incr count($b)
    set internal($b) [expr {$internal($b) + [pvalue $cell internal_power]}]
    set switching($b) [expr {$switching($b) + [pvalue $cell switching_power]}]
    set leakage($b) [expr {$leakage($b) + [pvalue $cell leakage_power]}]
}
set out [open reports/block_power.csv w]
puts $out "block,cells,internal_mW,switching_mW,leakage_mW,total_mW"
foreach b $blocks {
    puts $out [format "%s,%d,%.9f,%.9f,%.9f,%.9f" $b $count($b) \
        [expr {1000*$internal($b)}] [expr {1000*$switching($b)}] [expr {1000*$leakage($b)}] \
        [expr {1000*($internal($b)+$switching($b)+$leakage($b))}]]
}
close $out
puts "INT_PRELAYOUT_POWER_DONE $DESIGN_NAME"
exit
