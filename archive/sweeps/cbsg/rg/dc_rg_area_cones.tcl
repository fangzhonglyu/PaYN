# Cone dump for the C-BSG RG area breakdown (sweeps/cbsg/rg/area_breakdown.py).  Reads the written netlist of a
# synthesis run (never writes into it) and, for the PE core u_pe/u_array_core, lists
#   CELL <name> <ref> <area> <seq>      every leaf cell local to the core (not inside a tile)
#   WCONE <h> <v> <cells...>            the core-local fan-in cone of tile (h, v)'s w_bits pins (128 = K*M):
#                                       the W comparators of that tile plus everything they read
#                                       combinationally (W index generator of row h, operand buffers)
#   JCONE <h> <cells...>                the core-local fan-in cone of row h's j register data pins
#                                       (generator feedback: prefix[M] -> j)
#   TCONE <cells...>                    the core-local fan-in cone of every other tile input pin (a_bits, signs,
#                                       mac_en, shift_in, reset, acc_in): operand / control distribution
# all_fanin stops at timing startpoints (register clock pins, ports), so cones end at the pipe registers.
# Env (from the run's TARGET_DEF plus): ASTRAEA_FLOW, TOP, RG_RUN_DIR.  Output: rg_area_cones.txt in cwd.
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
read_verilog -netlist $env(RG_RUN_DIR)/$env(TOP).syn.v
current_design $env(TOP)
link
set core u_pe/u_array_core
set NH 8
set NW 8
set plen [expr {[string length $core] + 1}]
set fh [open rg_area_cones.txt w]

# Leaf cells directly in the core (tiles and clock-gate wrappers are hierarchical and reported by report_area).
set local [get_cells ${core}/* -filter "is_hierarchical==false"]
puts "RG_AREA local leaf cells in $core: [sizeof_collection $local]"
foreach_in_collection c $local {
    set seq [get_attribute $c is_sequential]
    puts $fh "CELL [string range [get_object_name $c] $plen end] [get_attribute $c ref_name] [get_attribute $c area] [expr {$seq eq "true" ? 1 : 0}]"
}
# Hierarchical children of the core that are not tiles (clock-gate wrappers), with their total area.
foreach_in_collection c [get_cells ${core}/* -filter "is_hierarchical==true"] {
    set n [get_object_name $c]
    if {[string match "*__u_inner" $n]} { continue }
    set a 0.0
    foreach_in_collection l [get_cells -hier -filter "full_name=~${n}/* && is_hierarchical==false"] {
        set a [expr {$a + [get_attribute $l area]}]
    }
    puts $fh "HIER [string range $n $plen end] [get_attribute $c ref_name] $a"
}

proc local_names {cells core plen} {
    set out {}
    foreach_in_collection c $cells {
        set n [get_object_name $c]
        # keep core-local leaf cells only (drop tile-internal and out-of-core cells)
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
        set cone [all_fanin -to $pins -flat -only_cells]
        set names [local_names $cone $core $plen]
        puts $fh "WCONE $h $v [join $names { }]"
        puts "RG_AREA wcone $h $v: [sizeof_collection $pins] pins, [llength $names] core-local cells"
    }
    set jregs [get_cells ${core}/g_gen_row_${h}__g_gen_lane_*j_reg* -filter "is_sequential==true"]
    set jpins [get_pins -of_objects $jregs -filter "pin_direction==in && name!=CK"]
    set names [local_names [all_fanin -to $jpins -flat -only_cells] $core $plen]
    puts $fh "JCONE $h [join $names { }]"
    puts "RG_AREA jcone $h: [sizeof_collection $jregs] j registers, [sizeof_collection $jpins] pins, [llength $names] cells"
}

set tpins [get_pins ${core}/g_row_*__g_col_*__u_inner/* -filter "pin_direction==in && name!~w_bits* && name!=clk"]
set names [local_names [all_fanin -to $tpins -flat -only_cells] $core $plen]
puts $fh "TCONE [join $names { }]"
puts "RG_AREA tcone: [sizeof_collection $tpins] pins, [llength $names] cells"
close $fh
puts "RG_AREA_DONE"
exit
