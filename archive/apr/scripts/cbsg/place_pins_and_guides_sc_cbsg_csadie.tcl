# PRE_PLACE_SCRIPT for the AF pinned-route DRC fix option (b), written 2026-10-05
# (build/power_char/cbsg_20261005/af/pinned_fix/README.txt): the CSA pinned
# route's die (fixed die), then the "lensouth" pin plan, so that every edge's
# pin pitch equals the CSA baseline's (east 96 pins per row, north 72 per
# column, west 24 per row on the same 270.06 x 268.52 um die).
#
# 1. apr.tcl's run_floorplan sized the die from CORE_UTIL=0.70 (AF: 259.14 x
#    258.72) and built the M2 follow-pin rails (sroute).  Here the rails are
#    deleted, the floorplan is re-specified with the CSA pinned route's exact
#    boxes (apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins: die
#    {0 0 270.06 268.52}, core {10.08 10.0 259.98 258.5}, the boxes its own
#    floorPlan -r 1 0.70 10 10 10 10 -adjustToSite produced) by floorPlan -b
#    ... -noSnapToGrid (the core box is on the row/site grid as in the CSA;
#    without -noSnapToGrid, -b/-s/-d all snap the die top to 268.50, tested on
#    the AF floorplan checkpoint 2026-10-05), and the flow's
#    own power steps are repeated (connect_std_cells_to_power, sroute).  Cells
#    are still unplaced at this point.  Fail closed unless the resulting boxes
#    equal the CSA's exactly.
# 2. Sources place_pins_and_guides_sc_cbsg_lensouth.tcl unchanged (guides and
#    fixed pins on the new floorplan).
# Knob: SC_FIXED_DIE_BOXES (12 numbers: die, io, core), default the CSA's.
set sc_fd_dir [file dirname [file normalize [info script]]]
set sc_fd_boxes {0 0 270.06 268.52 0 0 270.06 268.52 10.08 10.0 259.98 258.5}
if {[info exists env(SC_FIXED_DIE_BOXES)] && $env(SC_FIXED_DIE_BOXES) ne ""} { set sc_fd_boxes $env(SC_FIXED_DIE_BOXES) }
if {[llength $sc_fd_boxes] != 12} { puts "ERROR: SC_FIXED_DIE: need 12 numbers, got '$sc_fd_boxes'"; exit 2 }
proc sc_fd_box {} {
    set fp [dbFPlanBox [dbHeadFPlan]]
    set die {}
    foreach v $fp { lappend die [format %.3f [dbDBUToMicrons $v]] }
    set core {}
    foreach v [lindex [dbGet top.fPlan.coreBox] 0] { lappend core [format %.3f $v] }
    return [list $die $core]
}
puts "SC_FIXED_DIE: before die/core = [sc_fd_box] rows=[llength [dbGet top.fPlan.rows]]"
editDelete -type Special
floorPlan -b $sc_fd_boxes -noSnapToGrid
connect_std_cells_to_power
sroute
lassign [sc_fd_box] sc_fd_die sc_fd_core
set sc_fd_want_die {}; foreach v [lrange $sc_fd_boxes 0 3] { lappend sc_fd_want_die [format %.3f $v] }
set sc_fd_want_core {}; foreach v [lrange $sc_fd_boxes 8 11] { lappend sc_fd_want_core [format %.3f $v] }
if {$sc_fd_die ne $sc_fd_want_die || $sc_fd_core ne $sc_fd_want_core} {
    puts "ERROR: SC_FIXED_DIE: got die $sc_fd_die core $sc_fd_core, wanted die $sc_fd_want_die core $sc_fd_want_core"
    exit 2
}
set sc_fd_sw [dbGet top.nets.sWires]
set sc_fd_nsw [expr {$sc_fd_sw eq "0x0" ? 0 : [llength $sc_fd_sw]}]
if {$sc_fd_nsw == 0} { puts "ERROR: SC_FIXED_DIE: sroute created no follow-pin wires"; exit 2 }
puts "SC_FIXED_DIE: die=$sc_fd_die core=$sc_fd_core rows=[llength [dbGet top.fPlan.rows]] special_wires=$sc_fd_nsw"
source [file join $sc_fd_dir place_pins_and_guides_sc_cbsg_lensouth.tcl]
