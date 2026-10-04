# Preflight of apr/scripts/place_pins_and_guides_sc.tcl on a copy of an arm's
# bootstrap floorplan checkpoint (same netlist and floorPlan as pass 2).
# Sources the pin script the way apr.tcl's source_optional_user_script does
# (inside a proc with env/SCRIPT_DIR global), then runs the exact post-placement
# pin commands of apr.tcl run_place (assignIoPins; legalizePin) and reports
# every pin whose status, layer or location changed.
# Env: PREFLIGHT_DB (floorplan .enc.dat), TOP, PIN_SCRIPT, SC_NH, SC_NW,
#      SC_DIST_HIER_PREFIX.
restoreDesign $env(PREFLIGHT_DB) $env(TOP)
setMultiCpuUsage -localCpu 8

proc run_pre_place {path} {
    global env SCRIPT_DIR
    puts "Running PRE_PLACE_SCRIPT script: $path"
    source $path
}
proc pin_snapshot {} {
    set result [dict create]
    foreach t [dbGet top.terms] {
        dict set result [lindex [dbGet $t.name] 0] [list [lindex [dbGet $t.pStatus] 0] \
            [lindex [dbGet $t.layer.name] 0] [lindex [dbGet $t.pt] 0]]
    }
    return $result
}

set t0 [clock milliseconds]
run_pre_place $env(PIN_SCRIPT)
puts "PREFLIGHT pin_script_ms=[expr {[clock milliseconds]-$t0}]"
set before [pin_snapshot]
set nfixed 0
dict for {name rec} $before { if {[lindex $rec 0] eq "fixed"} { incr nfixed } }
puts "PREFLIGHT pins=[dict size $before] fixed_after_script=$nfixed"

# apr.tcl run_place, lines after place_opt_design.
assignIoPins
legalizePin

set after [pin_snapshot]
set moved 0
dict for {name rec} $before {
    if {[dict get $after $name] ne $rec} {
        if {$moved < 20} { puts "PREFLIGHT MOVED $name before={$rec} after={[dict get $after $name]}" }
        incr moved
    }
}
puts "PREFLIGHT changed_by_assignIoPins_legalizePin=$moved"
checkPinAssignment -outFile preflight_after.checkPin.rpt
set dbgLefDefOutVersion 5.5
defOut -floorplan preflight_pins.def
puts "PREFLIGHT_DONE"
exit
