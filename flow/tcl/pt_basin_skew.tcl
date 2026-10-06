# Operand-arrival skew at the product AND2s of a routed single-PE layout, for the basin gate (qualify.py basin).
#
# A product AND is a tile leaf cell (u_pe/u_array_core/g_row_<h>__g_col_<v>__u_inner/...) whose reference is
# AND2* and whose two inputs trace back, through BUF/INV/DLY cells, to an a_bits_pipe flop and a w_bits_pipe flop.
# Both operands leave flops on the same edge, so w_arr - a_arr is the column-broadcast minus row-broadcast network
# delay: a collapsed placement basin (tile rows packed into blobs, column broadcasts spread) drives its mean |.|
# from ~20 ps to ~145 ps.  Timing: routed apr.v, syn.sdc, routed SPEF, update_timing -full, ideal clocks; per pin
# arrival = max(max_rise_arrival, max_fall_arrival).
# Env: RUN_DIR (route), TOP, OUT (tsv: tile_row tile_col cell a_pin w_pin a_arr w_arr a_slew w_slew, in ns).
set RUN_DIR $env(RUN_DIR)
set DESIGN_NAME $env(TOP)

# TSMC22 libraries, typical corner (default: base SVT c30 + HPK SVT c30).
source [file join [file dirname [file normalize [info script]]] pt_libraries.tcl]

read_verilog $RUN_DIR/outputs/${DESIGN_NAME}.apr.v
current_design $DESIGN_NAME
link_design
read_sdc $RUN_DIR/${DESIGN_NAME}.syn.sdc
read_parasitics -format SPEF $RUN_DIR/outputs/${DESIGN_NAME}.spef
update_timing -full

# A, W or "" for the pipe flop that ultimately drives this pin (cached per net).
array set root_of {}
proc root_kind {pin} {
    global root_of
    set p $pin
    for {set hop 0} {$hop < 12} {incr hop} {
        set net [get_nets -quiet -of_objects $p]
        if {[sizeof_collection $net] != 1} { return "" }
        set key [get_object_name $net]
        if {[info exists root_of($key)]} { return $root_of($key) }
        set drv [get_pins -quiet -leaf -of_objects $net -filter "direction==out"]
        if {[sizeof_collection $drv] != 1} { set root_of($key) ""; return "" }
        set cell [get_cells -of_objects $drv]
        if {[regexp {^(BUF|INV|DLY)} [get_attribute $cell ref_name]]} {
            set p [get_pins -of_objects $cell -filter "direction==in"]
            if {[sizeof_collection $p] != 1} { set root_of($key) ""; return "" }
            continue
        }
        set name [get_object_name $cell]
        set kind ""
        if {[regexp {/a_bits_pipe_reg} $name]} { set kind A }
        if {[regexp {/w_bits_pipe_reg} $name]} { set kind W }
        set root_of($key) $kind
        return $kind
    }
    return ""
}
proc arr {pin} {
    set r [get_attribute -quiet $pin max_rise_arrival]
    set f [get_attribute -quiet $pin max_fall_arrival]
    if {$r eq "" || $f eq ""} { return "" }
    return [expr {max($r, $f)}]
}

set ands [get_cells -quiet -hierarchical \
    -filter "is_hierarchical==false && ref_name=~AND2* && full_name=~u_pe/u_array_core/g_row_*"]
set fo [open $env(OUT) w]
puts $fo "tile_row\ttile_col\tcell\ta_pin\tw_pin\ta_arr\tw_arr\ta_slew\tw_slew"
set n_and 0
set n_prod 0
set n_missing 0
foreach_in_collection c $ands {
    incr n_and
    set name [get_object_name $c]
    if {![regexp {g_row_(\d+)__g_col_(\d+)__u_inner/} $name -> h v]} { continue }
    set apin ""; set wpin ""
    foreach_in_collection p [get_pins -of_objects $c -filter "direction==in"] {
        set k [root_kind $p]
        if {$k eq "A"} { set apin $p } elseif {$k eq "W"} { set wpin $p }
    }
    if {$apin eq "" || $wpin eq ""} { continue }
    set aa [arr $apin]; set wa [arr $wpin]
    if {$aa eq "" || $wa eq ""} { incr n_missing; continue }
    puts $fo [join [list $h $v $name [get_object_name $apin] [get_object_name $wpin] $aa $wa \
        [get_attribute -quiet $apin actual_transition_max] [get_attribute -quiet $wpin actual_transition_max]] "\t"]
    incr n_prod
}
close $fo
puts "BASIN_SKEW_DONE and2_cells=$n_and product_ands=$n_prod missing_arrival=$n_missing"
exit
