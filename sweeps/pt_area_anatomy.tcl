# Per-reference cell area of selected hierarchies in a routed PaYN netlist.
# cwd = APR run dir.  Env: TOP, OUT (report path).  Area only: no SDC/SPEF/SAIF.
set DESIGN_NAME $env(TOP)
set OUT $env(OUT)
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
set NL [expr {[info exists env(NL)] && $env(NL) ne "" ? $env(NL) : "outputs/${DESIGN_NAME}.apr.v"}]
read_verilog $NL
current_design $DESIGN_NAME
link_design

proc ref_table {fh label pattern} {
    set cells [get_cells -quiet -hierarchical -filter "is_hierarchical==false && full_name=~$pattern"]
    array set n {}; array set a {}
    set tot 0.0
    foreach_in_collection c $cells {
        set r [get_attribute $c ref_name]
        set ar [get_attribute [get_lib_cells -of_objects $c] area]
        if {![info exists n($r)]} { set n($r) 0; set a($r) 0.0 }
        incr n($r)
        set a($r) [expr {$a($r) + $ar}]
        set tot [expr {$tot + $ar}]
    }
    puts $fh "== $label  pattern=$pattern  cells=[sizeof_collection $cells]  area=[format %.3f $tot]"
    foreach r [lsort [array names n]] {
        puts $fh [format "  %-34s %6d %10.3f" $r $n($r) $a($r)]
    }
}

set fh [open $OUT w]
ref_table $fh tile00 u_pe/u_array_core/g_row_0__g_col_0__u_inner/*
ref_table $fh tile00_counters u_pe/u_array_core/g_row_0__g_col_0__u_inner/*u_popcount*/*
ref_table $fh pe_outside_tiles_bitpipes u_pe/u_array_core/*bits_pipe*
ref_table $fh pe_outside_tiles_signpipes u_pe/u_array_core/*signs_pipe*
ref_table $fh periph_all u_peripheral/*
ref_table $fh periph_binary_regs u_peripheral/*binary_q*
ref_table $fh a_rng u_a_rng/*
close $fh
puts "AREA_ANATOMY_DONE"
exit
