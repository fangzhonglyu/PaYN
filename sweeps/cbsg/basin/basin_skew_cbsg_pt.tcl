# C-BSG copy of sweeps/pinned_pass2/basin_skew_pt.tcl (shared, unchanged): read-only operand-skew metric of a
# routed single-PE layout for the basin QoR gate.  Same timing setup (sweeps/pt_tsmc22_libraries.tcl, routed
# apr.v, syn.sdc, routed SPEF, update_timing -full, ideal clocks; pin arrival = max(max_rise_arrival,
# max_fall_arrival)) and the same product-AND discovery (an AND2 tile leaf cell whose inputs trace back through
# BUF/INV/DLY cells to the operand sources).
#
# MODE=and  the shared metric, verbatim: both product-AND inputs must root at pipe flops (a_bits_pipe and
#           w_bits_pipe).  Used for AF (whose tiles and pipes are the CSA's) only to dry-run on a netlist; the
#           campaign gates AF with the shared script itself.  Output columns as the shared script.
# MODE=rg   RG: the tile's W bits are not pipe-flop outputs but the outputs of per-tile comparators
#           w_local[k][m] = w_bits_pipe[v][k] > w_thr[h][k][m] (u_array_core, one per tile x lane x position),
#           where w_thr is the per-row W index generator's output (j register + in-cycle prefix of the A bits ->
#           Gray -> XOR map -> mask), about 1 ns of logic after the clock.  The shared skew w_arr - a_arr at the
#           product AND therefore carries that generator depth (identical in every basin) and its absolute
#           50 ps threshold is meaningless.  What the CSA metric measures is the mismatch of the two BROADCAST
#           networks where a row operand meets a column operand: both CSA operands leave flops on the same edge,
#           so w_arr - a_arr = (W column-broadcast network delay) - (A row-broadcast network delay) up to clock
#           skew, and a collapsed basin (tile rows packed into blobs, column broadcasts spread) drives it from
#           ~20 to ~145 ps.  In RG the row operand that meets the column operand is w_thr (row broadcast from
#           the generator of row h, lane k) and the column operand is the W magnitude (w_bits_pipe[v][k],
#           column broadcast); they meet at the tile's comparator.  The closest equivalent is therefore the
#           same difference of broadcast-network delays, measured at the comparator inputs:
#             skew_cmp = mean over the comparator's W-magnitude sink pins of (arr(sink) - arr(w_bits_pipe Q))
#                      - mean over its threshold sink pins of (arr(sink) - arr(generator output pin)),
#           network delay = from the broadcast driver's output (the last non-BUF/INV/DLY cell) to the sink pin,
#           so the generator's own depth cancels exactly as the common launch edge cancels in the CSA metric.
#           Two structural differences from the CSA networks remain and are handled by the gate
#           (basin_gate_cbsg.py --mode rg), not hidden: (1) the W-magnitude broadcast carries DLY2 hold padding
#           (1-2 cells per path in the synthesized netlist, none on the threshold side), which is not
#           distribution -- its delay is accumulated per path (dly columns) and the *_nodly columns subtract it;
#           (2) a W-magnitude bit fans out to 128-256 comparator inputs (8 tiles x 16 positions) through an INV
#           tree, a threshold bit to ~10 (8 tiles), so even a perfect layout has W slower than threshold.  The
#           gate therefore measures the routed skew against the same metric on the run's own synthesized
#           netlist (SPEF=none, zero wire load: the logic's floor) and limits the placement-induced increment.
#           Synthesized RG netlist cbsg_rg_20261005 (build/cbsg/rg/basin_dryrun/): 8,192 product ANDs, each
#           through its own comparator (8-11 cells, 66,761 in all), 10-14 W-magnitude and 8-13 threshold sinks;
#           W network 101 ps of which 52 ps DLY padding, threshold network 7.6 ps, floor skew 41.9 ps.
#           Comparator cone: the non-buffer, non-sequential u_array_core cells in the combinational fanout of
#           the w_bits_pipe flops (outside the tiles) -- in the synthesized RG netlist these are exactly the
#           per-tile cells (CGENI/AOI22/OAI22/OAI211/... ~8 per comparator; the column-shared cells on the W
#           side are only INV/DLY/BUF, part of the broadcast network).  Each product AND's W input roots at its
#           comparator's output cell; a backward walk inside the cone from there collects the cone's boundary
#           input pins, classed by their root: a w_bits_pipe flop -> W-magnitude sink, anything else (generator
#           gates; flops other than w_bits_pipe) -> threshold sink.  The product AND's own a_arr / w_arr are
#           also written (information only: w_arr includes the generator depth).
# Env: RUN_DIR, TOP, OUT (tsv), MODE (and|rg); optional NETLIST, SDC, SPEF (default the routed run's files;
# SPEF=none skips parasitics, for a dry run on a synthesized netlist).
set RUN_DIR $env(RUN_DIR)
set DESIGN_NAME $env(TOP)
set MODE $env(MODE)
if {$MODE ne "and" && $MODE ne "rg"} { puts "Error: MODE must be and|rg"; exit 1 }
set cbsg_basin_dir [file dirname [file normalize [info script]]]
source [file join [file dirname [file dirname $cbsg_basin_dir]] pt_tsmc22_libraries.tcl]
set NETLIST [expr {[info exists env(NETLIST)] && $env(NETLIST) ne "" ? $env(NETLIST) : "$RUN_DIR/outputs/${DESIGN_NAME}.apr.v"}]
set SDC [expr {[info exists env(SDC)] && $env(SDC) ne "" ? $env(SDC) : "$RUN_DIR/${DESIGN_NAME}.syn.sdc"}]
set SPEF [expr {[info exists env(SPEF)] && $env(SPEF) ne "" ? $env(SPEF) : "$RUN_DIR/outputs/${DESIGN_NAME}.spef"}]
read_verilog $NETLIST
current_design $DESIGN_NAME
link_design
read_sdc $SDC
if {$SPEF ne "none"} { read_parasitics -format SPEF $SPEF }
update_timing -full
puts "BASIN_SKEW_INPUTS mode=$MODE netlist=$NETLIST sdc=$SDC spef=$SPEF"

proc is_buf {ref} { return [regexp {^(BUF|INV|DLY)} $ref] }
array set root_of {}
# Root of the net driving a pin, following BUF/INV/DLY cells: {cell_name driver_pin_name ref_name dly_ns} or "".
# dly_ns is the delay of the DLY* (hold-padding) cells on that path, max(rise, fall) arrival differences, cached
# per net (the path from a net back to its root is unique); MODE=rg subtracts it, MODE=and ignores it.
proc trace_root {pin} {
    global root_of
    set p $pin
    set visited {}
    set dl {}
    set tail ""
    for {set hop 0} {$hop < 16} {incr hop} {
        set net [get_nets -quiet -of_objects $p]
        if {[sizeof_collection $net] != 1} { break }
        set key [get_object_name $net]
        if {[info exists root_of($key)]} { set tail $root_of($key); break }
        set drv [get_pins -quiet -leaf -of_objects $net -filter "direction==out"]
        if {[sizeof_collection $drv] != 1} { break }
        set cell [get_cells -of_objects $drv]
        set ref [get_attribute $cell ref_name]
        if {[is_buf $ref]} {
            set ip [get_pins -of_objects $cell -filter "direction==in"]
            if {[sizeof_collection $ip] != 1} { break }
            lappend visited $key
            set d 0.0
            if {[regexp {^DLY} $ref]} {
                set ao [arr $drv]; set ai [arr $ip]
                if {$ao ne "" && $ai ne ""} { set d [expr {$ao - $ai}] }
            }
            lappend dl $d
            set p $ip
            continue
        }
        # The net driven by the root itself: no padding between it and the root.
        set tail [list [get_object_name $cell] [get_object_name $drv] $ref 0.0]
        set root_of($key) $tail
        break
    }
    if {$tail eq ""} {
        foreach k $visited { set root_of($k) "" }
        return ""
    }
    # Walk back from the root side: dly(N_i) = sum of padding between N_i and the root.
    set acc [lindex $tail 3]
    for {set i [expr {[llength $visited] - 1}]} {$i >= 0} {incr i -1} {
        set acc [expr {$acc + [lindex $dl $i]}]
        set root_of([lindex $visited $i]) [lreplace $tail 3 3 $acc]
    }
    if {[llength $visited] > 0} { return $root_of([lindex $visited 0]) }
    return $tail
}
proc kind_of {cellname} {
    if {[regexp {/a_bits_pipe_reg} $cellname]} { return A }
    if {[regexp {/w_bits_pipe_reg} $cellname]} { return W }
    return ""
}
proc arr {pin} {
    set r [get_attribute -quiet $pin max_rise_arrival]
    set f [get_attribute -quiet $pin max_fall_arrival]
    if {$r eq "" || $f eq ""} { return "" }
    return [expr {max($r, $f)}]
}
array set arr_of_pin {}
proc arr_name {pinname} {
    global arr_of_pin
    if {![info exists arr_of_pin($pinname)]} { set arr_of_pin($pinname) [arr [get_pins $pinname]] }
    return $arr_of_pin($pinname)
}

# ---- RG comparator cone: combinational fanout of the W-magnitude pipe flops outside the tiles ----
array set CMP {}
if {$MODE eq "rg"} {
    set wq [get_pins -quiet -of_objects [get_cells -quiet u_pe/u_array_core/w_bits_pipe_reg*] -filter "direction==out"]
    if {[sizeof_collection $wq] == 0} { puts "Error: no u_pe/u_array_core/w_bits_pipe_reg* outputs"; exit 1 }
    set n_fo 0
    foreach_in_collection c [all_fanout -from $wq -flat -only_cells] {
        incr n_fo
        set name [get_object_name $c]
        if {[string match "*u_inner/*" $name]} { continue }      ;# tile cells (g_row_h__g_col_v__u_inner/...)
        if {![string match "u_pe/u_array_core/*" $name]} { continue }
        set ref [get_attribute $c ref_name]
        if {[is_buf $ref] || [regexp {^(DFF|SDFF|LAT|PREICG|ICG)} $ref]} { continue }
        if {[get_attribute -quiet $c is_sequential] eq "true"} { continue }
        set CMP($name) 1
    }
    puts "BASIN_CMP_CONE fanout_cells=$n_fo comparator_logic_cells=[array size CMP] w_pipe_outputs=[sizeof_collection $wq]"
}
array set cmp_done {}
# Boundary sinks of the comparator cone whose output cell is croot: list of {W|R|X sink_pin root_pin root_ref}.
proc cmp_sinks {croot} {
    global CMP
    set todo [list $croot]
    array set seen {}
    set out {}
    while {[llength $todo] > 0} {
        set c [lindex $todo end]
        set todo [lrange $todo 0 end-1]
        if {[info exists seen($c)]} { continue }
        set seen($c) 1
        foreach_in_collection p [get_pins -of_objects [get_cells $c] -filter "direction==in"] {
            set r [trace_root $p]
            if {$r eq ""} { lappend out [list X [get_object_name $p] "" "" 0.0]; continue }
            lassign $r rc rpin rref rdly
            if {[info exists CMP($rc)]} { lappend todo $rc; continue }
            if {[kind_of $rc] eq "W"} {
                lappend out [list W [get_object_name $p] $rpin $rref $rdly]
            } else {
                lappend out [list R [get_object_name $p] $rpin $rref $rdly]
            }
        }
    }
    return [list [array size seen] $out]
}

set ands [get_cells -quiet -hierarchical -filter "is_hierarchical==false && ref_name=~AND2* && full_name=~u_pe/u_array_core/g_row_*"]
set fo [open $env(OUT) w]
if {$MODE eq "and"} {
    puts $fo "tile_row\ttile_col\tcell\ta_pin\tw_pin\ta_arr\tw_arr\ta_slew\tw_slew"
} else {
    puts $fo "tile_row\ttile_col\tcell\ta_pin\tw_pin\ta_arr\tw_arr\ta_slew\tw_slew\tcmp_cell\tcmp_cells\tn_w\tn_r\tn_x\tw_net_mean\tr_net_mean\tw_net_max\tr_net_max\tw_sink_arr_mean\tr_sink_arr_mean\tr_flop_roots\tw_net_nodly_mean\tr_net_nodly_mean\tw_dly_mean\tr_dly_mean"
}
set n_and 0
set n_prod 0
set n_missing 0
set n_nocmp 0
foreach_in_collection c $ands {
    incr n_and
    set name [get_object_name $c]
    if {![regexp {g_row_(\d+)__g_col_(\d+)__u_inner/} $name -> h v]} { continue }
    set apin ""; set wpin ""; set wroot ""
    foreach_in_collection p [get_pins -of_objects $c -filter "direction==in"] {
        set r [trace_root $p]
        if {$r eq ""} { continue }
        set k [kind_of [lindex $r 0]]
        if {$k eq "A"} {
            set apin $p
        } elseif {$MODE eq "and" && $k eq "W"} {
            set wpin $p
        } elseif {$MODE eq "rg" && [info exists CMP([lindex $r 0])]} {
            set wpin $p; set wroot [lindex $r 0]
        }
    }
    if {$apin eq "" || $wpin eq ""} { if {$MODE eq "rg" && $apin ne ""} { incr n_nocmp }; continue }
    set aa [arr $apin]; set wa [arr $wpin]
    if {$aa eq "" || $wa eq ""} { incr n_missing; continue }
    set row [list $h $v $name [get_object_name $apin] [get_object_name $wpin] $aa $wa \
        [get_attribute -quiet $apin actual_transition_max] [get_attribute -quiet $wpin actual_transition_max]]
    if {$MODE eq "rg"} {
        lassign [cmp_sinks $wroot] ncells sinks
        set nw 0; set nr 0; set nx 0; set sw 0.0; set sr 0.0; set mw -1e9; set mr -1e9; set aw 0.0; set ar 0.0
        set dw 0.0; set dr 0.0
        set rflops 0; set bad 0
        foreach s $sinks {
            lassign $s kind spin rpin rref rdly
            if {$kind eq "X"} { incr nx; continue }
            set sa [arr_name $spin]; set ra [arr_name $rpin]
            if {$sa eq "" || $ra eq ""} { incr bad; continue }
            set d [expr {$sa - $ra}]
            if {$kind eq "W"} {
                incr nw; set sw [expr {$sw + $d}]; set aw [expr {$aw + $sa}]; set dw [expr {$dw + $rdly}]
                if {$d > $mw} { set mw $d }
            } else {
                incr nr; set sr [expr {$sr + $d}]; set ar [expr {$ar + $sa}]; set dr [expr {$dr + $rdly}]
                if {$d > $mr} { set mr $d }
                if {[regexp {^(DFF|SDFF)} $rref]} { incr rflops }
            }
        }
        if {$nw == 0 || $nr == 0 || $bad > 0} { incr n_missing; continue }
        lappend row $wroot $ncells $nw $nr $nx [expr {$sw / $nw}] [expr {$sr / $nr}] $mw $mr \
            [expr {$aw / $nw}] [expr {$ar / $nr}] $rflops \
            [expr {($sw - $dw) / $nw}] [expr {($sr - $dr) / $nr}] [expr {$dw / $nw}] [expr {$dr / $nr}]
    }
    puts $fo [join $row "\t"]
    incr n_prod
}
close $fo
puts "BASIN_SKEW_DONE mode=$MODE and2_cells=$n_and product_ands=$n_prod missing_arrival=$n_missing w_not_from_comparator=$n_nocmp"
exit
