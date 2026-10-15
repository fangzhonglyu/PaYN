# Post-fill search-and-repair, armed by payn_pre_place.tcl as the run's
# PRE_REPORT_SCRIPT (apr.tcl run_final: after the two-pass addFiller, the local
# detailRoute, the strong reroute and the final_pre_gds save; before the final
# verify_drc / connectivity / antenna checks, timing reports and exports).  The
# target's own PRE_REPORT_SCRIPT is sourced at the end.
#
# Why: the flow's second addFiller pass ("without DRC checking") overlaps
# existing M1 routing; its strong reroute (editDeleteViolations +
# globalDetailRoute) repairs that only if NanoRoute runs search-and-repair,
# which its auto-stop (setNanoRouteMode -drouteAutoStop, default true above
# 20 nm) skips when the violation count is too high (about one marker per
# routable net on the pinned PaYN route: 68,476 for 62,713 nets, 69,437 left).
#
# What: if verify_drc reaches the flow's 1000-marker limit (a wholesale
# failure), run the flow's strong reroute again, unchanged, with
# -drouteAutoStop false for that one command, then restore the mode.  Fewer
# markers are left to the targeted repair (flow/apr.sh repair).  Nothing else
# (timing optimization, fillers, placement) is touched.
puts "POSTFILL_DRC_REPAIR_BEGIN"
clearDrc
verify_drc
set pf_m [dbGet top.markers]
set pf_before [expr {$pf_m eq "0x0" ? 0 : [llength $pf_m]}]
if {$pf_before >= 1000} {
    set pf_prev [getNanoRouteMode -drouteAutoStop -quiet]
    puts "POSTFILL_DRC_REPAIR: markers_before=$pf_before (verify_drc limit) drouteAutoStop=$pf_prev -> false for one strong reroute"
    setNanoRouteMode -drouteAutoStop false
    editDeleteViolations
    globalDetailRoute
    setNanoRouteMode -drouteAutoStop $pf_prev
    connect_std_cells_to_power
    clearDrc
    verify_drc
    set pf_m [dbGet top.markers]
    set pf_after [expr {$pf_m eq "0x0" ? 0 : [llength $pf_m]}]
    puts "POSTFILL_DRC_REPAIR: ran=1 markers_before=$pf_before markers_after=$pf_after drouteAutoStop_restored=[getNanoRouteMode -drouteAutoStop -quiet]"
} else {
    puts "POSTFILL_DRC_REPAIR: ran=0 markers_before=$pf_before (below the 1000-marker wholesale-failure trigger)"
}
puts "POSTFILL_DRC_REPAIR_END"
# The target's PRE_REPORT_SCRIPT, unchanged.
if {[info exists ::payn_postfill_next_hook] && $::payn_postfill_next_hook ne ""} {
    set pf_next $::payn_postfill_next_hook
    if {[file pathtype $pf_next] ne "absolute"} { set pf_next [file join $::env(DESIGN_ROOT) $pf_next] }
    puts "POSTFILL_DRC_REPAIR: sourcing the target's PRE_REPORT_SCRIPT $pf_next"
    source $pf_next
}
