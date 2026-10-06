# PT-PX power (and area) split of the C-BSG RG array into its functional blocks, on a routed run (or, with
# SPEF=none, on the synthesized netlist).  Read-only on the run directory; writes into cwd.
#
# The power setup is ASTRAEA's apr/scripts/power.tcl verbatim (library block, read order, update_timing -full,
# read_saif -strip_path, pinless-net zeroing, update_power), so the total must equal that run's power.rpt
# (sweeps/cbsg/rg/power_split.py checks it).  The split itself is sweeps/cbsg/rg/dc_rg_area_cones.tcl's cone
# dump, repeated in PT on the analysed netlist with each cell's power next to its area:
#   CELL <name> <ref> <area> <seq> <total_W> <internal_W> <switching_W> <leakage_W>
#                                    every leaf cell local to u_pe/u_array_core (not inside a tile)
#   HIER <name> <ref> <area> <total_W> <ncells>   hierarchical children of the core (64 tiles, clock-gate wrappers)
#   WCONE <h> <v> <cells...>         core-local fan-in cone of tile (h, v)'s w_bits pins (comparators + generator)
#   JCONE <h> <cells...>             core-local fan-in cone of row h's j registers' data pins (prefix -> j)
#   TCONE <cells...>                 core-local fan-in cone of every other tile input (operand/control distribution)
#   PCELL <name> <ref> <area> <seq> <total_W>     every leaf cell under u_peripheral (the A edge)
#   TOPH <name> <area> <total_W> <ncells>         every first-level child of the top, plus top-local leaf cells
#   TOTAL <total_W> <internal_W> <switching_W> <leakage_W>
# Env: TOP, NETLIST, SDC, SPEF (path or 'none'), SAIF_FILE, SAIF_STRIP_PATH (default Top/dut), TSMC22_* as the
# flow sets them, ZERO_PINLESS_NET_ACTIVITY.  Output: rg_power_split.txt and pt_reports/ in cwd.
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
if {[info exists env(SAIF_STRIP_PATH)] && $env(SAIF_STRIP_PATH) ne ""} { set SAIF_STRIP_PATH $env(SAIF_STRIP_PATH) }

set power_enable_analysis        "true"
set power_analysis_mode          "averaged"
set power_model_preference       "ccs"

# Library setup: verbatim from ASTRAEA apr/scripts/power.tcl (TSMC22 branch).
    set KIT_PATH /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
    set cell_tier sc7mcpp140z
    if {[info exists env(TSMC22_CELL_TIER)] && $env(TSMC22_CELL_TIER) ne ""} {
        set cell_tier $env(TSMC22_CELL_TIER)
    }
    switch -- $cell_tier {
        sc7mcpp140z   { set lib_release r3p0 }
        sc6p5mcpp140z { set lib_release r4p0 }
        default {
            puts "ERROR: unsupported TSMC22_CELL_TIER: $cell_tier"
            exit 1
        }
    }
    set lib_flavors [list svt_c30]
    if {[info exists env(TSMC22_LIB_FLAVORS)] && $env(TSMC22_LIB_FLAVORS) ne ""} {
        set lib_flavors [regexp -all -inline {\S+} $env(TSMC22_LIB_FLAVORS)]
    }
    set hpk_flavors $lib_flavors
    if {[info exists env(TSMC22_HPK_FLAVORS)] && $env(TSMC22_HPK_FLAVORS) ne ""} {
        set hpk_flavors [regexp -all -inline {\S+} $env(TSMC22_HPK_FLAVORS)]
    }
    set lib_search [list .]
    set link_library [list "*"]
    foreach flavor $lib_flavors {
        set base_lib ${KIT_PATH}/${cell_tier}_base_${flavor}/${lib_release}
        set base_file ${base_lib}/db/${cell_tier}_cln22ul_base_${flavor}_tt_typical_max_0p80v_25c.db
        if {![file exists $base_file]} {
            puts "ERROR: TSMC22 .db not found: $base_file"
            exit 1
        }
        lappend lib_search ${base_lib}/db
        lappend link_library $base_file
    }
    if {[info exists env(TSMC22_HPK)] && $env(TSMC22_HPK) == 1} {
        if {$cell_tier ne "sc7mcpp140z"} {
            puts "ERROR: TSMC22 HPK is only physically compatible with sc7mcpp140z"
            exit 1
        }
        foreach flavor $hpk_flavors {
            set hpk_lib ${KIT_PATH}/sc7mcpp140z_hpk_${flavor}/r3p0
            set hpk_file ${hpk_lib}/db/sc7mcpp140z_cln22ul_hpk_${flavor}_tt_typical_max_0p80v_25c.db
            if {![file exists $hpk_file]} {
                puts "ERROR: TSMC22 HPK .db not found: $hpk_file"
                exit 1
            }
            lappend lib_search ${hpk_lib}/db
            lappend link_library $hpk_file
        }
    }
    set search_path [concat $lib_search $search_path]

foreach f [list $env(NETLIST) $env(SDC) $SAIF_FILE] {
    if {![file exists $f]} { puts "ERROR: required input not found: $f"; exit 1 }
}
read_verilog $env(NETLIST)
current_design $DESIGN_NAME
link_design
read_sdc $env(SDC)
if {$env(SPEF) ne "none"} { read_parasitics -format SPEF $env(SPEF) }
update_timing -full
check_power
reset_switching_activity
read_saif $SAIF_FILE -strip_path $SAIF_STRIP_PATH
if {[info exists env(ZERO_PINLESS_NET_ACTIVITY)] && $env(ZERO_PINLESS_NET_ACTIVITY) == 1} {
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
update_power
file mkdir pt_reports
report_power -significant_digits 6 -nosplit       > pt_reports/power.rpt
report_power -significant_digits 6 -hier -nosplit > pt_reports/power_hier.rpt
report_switching_activity -list_not_annotated     > pt_reports/saif_coverage.rpt

proc pw {c attr} {
    set v [get_attribute -quiet $c $attr]
    if {$v eq ""} { return 0.0 }
    return $v
}
proc leaf_sum {pattern} {
    set a 0.0; set p 0.0; set n 0
    foreach_in_collection l [get_cells -quiet -hier -filter "full_name=~${pattern} && is_hierarchical==false"] {
        set a [expr {$a + [get_attribute $l area]}]
        set p [expr {$p + [pw $l total_power]}]
        incr n
    }
    return [list $a $p $n]
}

set core u_pe/u_array_core
set NH 8
set NW 8
set plen [expr {[string length $core] + 1}]
set fh [open rg_power_split.txt w]
set tot 0.0; set tint 0.0; set tsw 0.0; set tlk 0.0
foreach_in_collection c [get_cells -hier -filter "is_hierarchical==false"] {
    set tot  [expr {$tot  + [pw $c total_power]}]
    set tint [expr {$tint + [pw $c internal_power]}]
    set tsw  [expr {$tsw  + [pw $c switching_power]}]
    set tlk  [expr {$tlk  + [pw $c leakage_power]}]
}
puts $fh "TOTAL $tot $tint $tsw $tlk"

set local [get_cells ${core}/* -filter "is_hierarchical==false"]
puts "RG_SPLIT local leaf cells in $core: [sizeof_collection $local]"
foreach_in_collection c $local {
    set seq [get_attribute $c is_sequential]
    puts $fh "CELL [string range [get_object_name $c] $plen end] [get_attribute $c ref_name] [get_attribute $c area] [expr {$seq eq "true" ? 1 : 0}] [pw $c total_power] [pw $c internal_power] [pw $c switching_power] [pw $c leakage_power]"
}
foreach_in_collection c [get_cells ${core}/* -filter "is_hierarchical==true"] {
    set n [get_object_name $c]
    lassign [leaf_sum "${n}/*"] a p k
    puts $fh "HIER [string range $n $plen end] [get_attribute $c ref_name] $a $p $k"
}
foreach_in_collection c [get_cells u_peripheral/* -filter "is_hierarchical==false"] {
    set seq [get_attribute $c is_sequential]
    puts $fh "PCELL [string range [get_object_name $c] 13 end] [get_attribute $c ref_name] [get_attribute $c area] [expr {$seq eq "true" ? 1 : 0}] [pw $c total_power]"
}
foreach_in_collection c [get_cells u_peripheral/* -filter "is_hierarchical==true"] {
    set n [get_object_name $c]
    lassign [leaf_sum "${n}/*"] a p k
    puts $fh "PHIER [string range $n 13 end] $a $p $k"
}
foreach_in_collection c [get_cells * -filter "is_hierarchical==true"] {
    set n [get_object_name $c]
    lassign [leaf_sum "${n}/*"] a p k
    puts $fh "TOPH $n $a $p $k"
}
set a 0.0; set p 0.0; set k 0
foreach_in_collection l [get_cells * -filter "is_hierarchical==false"] {
    set a [expr {$a + [get_attribute $l area]}]; set p [expr {$p + [pw $l total_power]}]; incr k
}
puts $fh "TOPH __top_local__ $a $p $k"

proc local_names {cells core plen} {
    set out {}
    foreach_in_collection c $cells {
        set n [get_object_name $c]
        if {[string first "${core}/" $n] != 0} { continue }
        set r [string range $n $plen end]
        if {[string first "/" $r] >= 0} { continue }
        lappend out $r
    }
    return $out
}
for {set h 0} {$h < $NH} {incr h} {
    for {set v 0} {$v < $NW} {incr v} {
        set pins [get_pins ${core}/g_row_${h}__g_col_${v}__u_inner/w_bits*]
        set names [local_names [all_fanin -to $pins -flat -only_cells] $core $plen]
        puts $fh "WCONE $h $v [join $names { }]"
        puts "RG_SPLIT wcone $h $v: [sizeof_collection $pins] pins, [llength $names] core-local cells"
    }
    set jregs [get_cells ${core}/g_gen_row_${h}__g_gen_lane_*j_reg* -filter "is_sequential==true"]
    set jpins [get_pins -of_objects $jregs -filter "direction==in && is_clock_pin==false"]
    set names [local_names [all_fanin -to $jpins -flat -only_cells] $core $plen]
    puts $fh "JCONE $h [join $names { }]"
    puts "RG_SPLIT jcone $h: [sizeof_collection $jregs] j registers, [sizeof_collection $jpins] pins, [llength $names] cells"
}
set tpins [get_pins ${core}/g_row_*__g_col_*__u_inner/* -filter "direction==in && full_name!~*/w_bits* && full_name!~*/clk"]
set names [local_names [all_fanin -to $tpins -flat -only_cells] $core $plen]
puts $fh "TCONE [join $names { }]"
puts "RG_SPLIT tcone: [sizeof_collection $tpins] pins, [llength $names] cells"
close $fh
puts "RG_SPLIT_DONE"
exit
