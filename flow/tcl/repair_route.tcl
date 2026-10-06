# Targeted repair of a completed route's residual markers, from its own checkpoint (no synthesis, placement or CTS
# rerun).  Run by flow/route.py (qualify stage) in the route directory, with cwd holding:
#   repair_flow_procedures.tcl  the flow's apr.tcl procedures and setup (everything before its resume branch),
#                               written by the driver; in targeted mode its strong global reroute fallback raises
#   repair_targets.tcl          the plan: repair_mode (targeted | overlap), repair_checkpoint (final | route),
#                               repair_instances, repair_ant_pins {inst pin net}, repair_geometry {{nets} {box}}
# Targeted: open a 5 um filler window around each antenna sink and attach the library diode there; rip up only the
# diagnosed nets' regular wires in a 0.5 um halo of each geometry marker; then ECO route, refill and the flow's
# standard final checks and exports (run_final).  Overlap: ECO-legalize the overlapping instances from route.enc.
# Prints POP_COUNT_CHECKPOINT_REPAIR_COMPLETE at the end (the completion marker qualify.py routed-apr accepts).
source repair_flow_procedures.tcl
source repair_targets.tcl
restoreDesign "${top_level}.${repair_checkpoint}.enc.dat" $top_level
get_multithread_lic
file mkdir reports
checkPlace reports/placement_before_repair.rpt
configure_antenna_repair
configure_postroute_swapvia
proc exact_inst {name} {
    set pattern [string map [list "\\" "\\\\" {[} {\[} {]} {\]} {*} {\*} {?} {\?}] $name]
    set ptr [dbGet -p top.insts.name $pattern]
    if {$ptr eq "0x0" || [llength $ptr] != 1} { error "Cannot uniquely find instance $name" }
    return $ptr
}
setPlaceMode -place_detail_preserve_routing true
setPlaceMode -place_detail_remove_affected_routing true
setPlaceMode -place_hard_fence false
if {$repair_mode eq "overlap"} {
    set movable {}
    foreach name $repair_instances {
        set ptr [exact_inst $name]
        set status [dbGet ${ptr}.pStatus]
        puts "REPAIR_INSTANCE name=$name placement_status=$status"
        if {$status ne "fixed" && $status ne "cover"} { lappend movable $name }
    }
    if {[llength $movable] == 0} { error "All overlap instances are fixed" }
    refinePlace -eco true -inst $movable
} else {
    # Filler-complete density blocks automatic antenna-diode insertion: open only five-micron neighborhoods around
    # the reported sinks, attach the library diode explicitly, and keep every existing logical placement.
    foreach item $repair_ant_pins {
        lassign $item inst pin net
        set ptr [exact_inst $inst]
        set box [lindex [dbGet ${ptr}.box] 0]
        lassign $box x1 y1 x2 y2
        set halo 5.0
        set local_box [list [expr {$x1-$halo}] [expr {$y1-$halo}] [expr {$x2+$halo}] [expr {$y2+$halo}]]
        puts "REPAIR_ANTENNA net=$net sink=$inst/$pin filler_window=$local_box"
        deleteFiller -area $local_box
        attachDiode -diodeCell $ANTENNA_CELL -pin [list $inst $pin] -prefix POP_REPAIR_DIODE
    }
    if {[llength $repair_ant_pins] > 0} {
        set diode_ptrs [dbGet -p top.insts.name *POP_REPAIR_DIODE*]
        if {$diode_ptrs eq "0x0"} { error "attachDiode created no diode instances" }
        set diode_names [dbGet ${diode_ptrs}.name]
        if {[llength $diode_names] < [llength $repair_ant_pins]} { error "Not all requested antenna diodes were created" }
        refinePlace -eco true -inst $diode_names
    }
    # Rip up only the diagnosed nets' regular geometry inside each marker's neighborhood, so the ECO route places
    # the failed via differently instead of repeating an unchanged detailRoute pass.
    foreach item $repair_geometry {
        lassign $item nets box
        lassign $box x1 y1 x2 y2
        set halo 0.5
        set local_box [list [expr {$x1-$halo}] [expr {$y1-$halo}] [expr {$x2+$halo}] [expr {$y2+$halo}]]
        puts "REPAIR_GEOMETRY nets=$nets area=$local_box"
        editDelete -net $nets -area $local_box -type Regular
    }
}
checkPlace reports/placement_after_legalize.rpt
connect_std_cells_to_power
ecoRoute
connect_std_cells_to_power
saveDesign ${top_level}.repaired_route.enc
# Refill the opened gaps and run the flow's standard local checks and exports.  In targeted mode the procedures
# refuse the global-reroute fallback.
run_final
puts "POP_COUNT_CHECKPOINT_REPAIR_COMPLETE"
exit
