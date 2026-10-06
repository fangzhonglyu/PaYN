# Post-fill search-and-repair for the C-BSG AF pinned route, fix option (c), written 2026-10-05
# (build/power_char/cbsg_20261005/af/pinned_fix/README.txt).  Reached through the flow's PRE_REPORT_SCRIPT hook
# (apr.tcl run_final: after the two-pass addFiller, the local detailRoute, the strong reroute and the
# final_pre_gds save; before the final verify_drc / connectivity / antenna checks, timing reports and exports), set
# at run time by apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_postfill.tcl, so it applies only to runs that use
# that pre-place script.  The target's own PRE_REPORT_SCRIPT (apr/scripts/check_popcount_placement.tcl, the
# read-only placement audit) is sourced unchanged at the end.
#
# Why: the flow's second addFiller pass ("without DRC checking") overlaps existing M1 routing; its strong reroute
# (editDeleteViolations + globalDetailRoute) repairs that only if NanoRoute runs search-and-repair, which its
# auto-stop (setNanoRouteMode -drouteAutoStop, default true above 20 nm) skips when the violation count is too high.
# On the AF pinned route the count after the initial detail pass was 68,476 for 62,713 routable nets and no
# iteration ran (69,437 markers left); on every other route in the repo it stayed <= 0.99 per routable net and the
# iterations closed it.
#
# What: if the flow's repair left a wholesale failure (verify_drc reaches the flow's own 1000-marker limit), run the
# flow's strong reroute again, unchanged, with -drouteAutoStop false for that one command, then restore the mode.
# Fewer markers (residual ones) are left to the campaign's targeted repair (sweeps/repair_popcount_apr.sh), as
# for the CSA baseline.  Nothing else (timing optimization, fillers, placement) is touched.
puts "CBSG_POSTFILL_DRC_REPAIR_BEGIN"
clearDrc
verify_drc
set cbsg_pf_m [dbGet top.markers]
set cbsg_pf_before [expr {$cbsg_pf_m eq "0x0" ? 0 : [llength $cbsg_pf_m]}]
if {$cbsg_pf_before >= 1000} {
    set cbsg_pf_prev [getNanoRouteMode -drouteAutoStop -quiet]
    puts "CBSG_POSTFILL_DRC_REPAIR: markers_before=$cbsg_pf_before (verify_drc limit) drouteAutoStop=$cbsg_pf_prev -> false for one strong reroute"
    setNanoRouteMode -drouteAutoStop false
    editDeleteViolations
    globalDetailRoute
    setNanoRouteMode -drouteAutoStop $cbsg_pf_prev
    connect_std_cells_to_power
    clearDrc
    verify_drc
    set cbsg_pf_m [dbGet top.markers]
    set cbsg_pf_after [expr {$cbsg_pf_m eq "0x0" ? 0 : [llength $cbsg_pf_m]}]
    puts "CBSG_POSTFILL_DRC_REPAIR: ran=1 markers_before=$cbsg_pf_before markers_after=$cbsg_pf_after drouteAutoStop_restored=[getNanoRouteMode -drouteAutoStop -quiet]"
} else {
    puts "CBSG_POSTFILL_DRC_REPAIR: ran=0 markers_before=$cbsg_pf_before (below the 1000-marker wholesale-failure trigger)"
}
puts "CBSG_POSTFILL_DRC_REPAIR_END"
# The target's PRE_REPORT_SCRIPT, unchanged.
if {[info exists ::cbsg_postfill_next_hook] && $::cbsg_postfill_next_hook ne ""} {
    set cbsg_pf_next $::cbsg_postfill_next_hook
    if {[file pathtype $cbsg_pf_next] ne "absolute"} { set cbsg_pf_next [file join $::env(DESIGN_ROOT) $cbsg_pf_next] }
    puts "CBSG_POSTFILL_DRC_REPAIR: sourcing the target's PRE_REPORT_SCRIPT $cbsg_pf_next"
    source $cbsg_pf_next
}
