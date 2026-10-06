# Net/cell power at the peripheral -> PE boundary and on the drain ports, for
# sizing what the bit-plane INT energy bench does not model (the bypass OR's
# second input and its raw-bit wire, the ring return wires).
#
# Read-only on the accepted route: every input is an absolute path, and all
# PT output goes to the current directory / $OUT.
#   TOP=payn_array_signed_segmented_csa ROUTE=/abs/route_dir SAIF_FILE=/abs/dut.saif \
#   OUT=/abs/out.csv pt_shell -file sweeps/int_mode/pt_bitplane_boundary_nets.tcl
# ROUTE must contain outputs/$TOP.apr.v, outputs/$TOP.spef and $TOP.syn.sdc.
set DESIGN_NAME $env(TOP)
set ROUTE       $env(ROUTE)
set SAIF_FILE   $env(SAIF_FILE)
set OUT         $env(OUT)

set power_enable_analysis  "true"
set power_analysis_mode    "averaged"
set power_model_preference "ccs"
source [file join [file dirname [file normalize [info script]]] .. pt_tsmc22_libraries.tcl]
read_verilog ${ROUTE}/outputs/${DESIGN_NAME}.apr.v
current_design $DESIGN_NAME
link_design
read_sdc ${ROUTE}/${DESIGN_NAME}.syn.sdc
read_parasitics -format SPEF ${ROUTE}/outputs/${DESIGN_NAME}.spef
update_timing -full
reset_switching_activity
read_saif $SAIF_FILE -strip_path Top/dut
update_power

# Sum net switching power (W) and total net load (pF) over a net collection.
proc net_sum {nets} {
    set n 0; set cap 0.0; set sw 0.0; set tr 0.0
    redirect -variable txt {
        report_power -net_power -nworst 1000000 -significant_digits 8 -nosplit $nets
    }
    foreach line [split $txt "\n"] {
        set f [regexp -all -inline {\S+} [string trim $line]]
        if {[llength $f] != 7} { continue }
        if {![string is double -strict [lindex $f 2]] ||
            ![string is double -strict [lindex $f 5]]} { continue }
        incr n
        set cap [expr {$cap + [lindex $f 2]}]
        set sw  [expr {$sw + [lindex $f 5]}]
        set tr  [expr {$tr + [lindex $f 4]}]
    }
    return [list $n $cap $sw $tr]
}

# Sum cell internal / total power (W) over a cell collection.
proc cell_sum {cells} {
    set n 0; set int 0.0; set tot 0.0
    foreach_in_collection c $cells {
        incr n
        set i [get_attribute -quiet $c internal_power]
        set t [get_attribute -quiet $c total_power]
        if {$i ne ""} { set int [expr {$int + $i}] }
        if {$t ne ""} { set tot [expr {$tot + $t}] }
    }
    return [list $n $int $tot]
}

set a_pins [get_pins -quiet u_pe/a_bits_in*]
set w_pins [get_pins -quiet u_pe/w_bits_in*]
set op_nets [get_nets -quiet -of_objects [add_to_collection $a_pins $w_pins]]
set op_drv_pins [get_pins -quiet -leaf -of_objects $op_nets -filter {direction == out}]
set op_drv_cells [get_cells -quiet -of_objects $op_drv_pins]
set accin_nets  [get_nets -quiet -of_objects [get_ports acc_in_west*]]
set accout_nets [get_nets -quiet -of_objects [get_ports acc_out_east*]]
set binin_nets  [get_nets -quiet -of_objects [get_ports {a_binary_in* w_binary_in*}]]
set signin_nets [get_nets -quiet -of_objects [get_ports {a_signs_in* w_signs_in*}]]

set fh [open $OUT w]
puts $fh "group,count,cap_total_pF,switching_mW,toggle_rate_sum,cells,cell_internal_mW,cell_total_mW"
foreach {name nets cells} [list operand_boundary $op_nets $op_drv_cells \
                                acc_in_west $accin_nets "" \
                                acc_out_east $accout_nets "" \
                                binary_in_ports $binin_nets "" \
                                sign_in_ports $signin_nets ""] {
    lassign [net_sum $nets] n cap sw tr
    if {$cells ne ""} { lassign [cell_sum $cells] nc ci ct } else { set nc 0; set ci 0.0; set ct 0.0 }
    puts $fh [format "%s,%d,%.6f,%.6f,%.6f,%d,%.6f,%.6f" $name $n $cap [expr {1e3*$sw}] $tr \
        $nc [expr {1e3*$ci}] [expr {1e3*$ct}]]
}
redirect -variable drv_refs { report_cell -nosplit $op_drv_cells }
set refs [dict create]
foreach line [split $drv_refs "\n"] {
    set f [regexp -all -inline {\S+} [string trim $line]]
    if {[llength $f] >= 2 && [string match "*_A7PP140ZTS_C30" [lindex $f 1]]} {
        dict incr refs [lindex $f 1]
    }
}
puts $fh "# operand-boundary driver cell types: $refs"
close $fh
puts "BOUNDARY_NETS_DONE"
exit
