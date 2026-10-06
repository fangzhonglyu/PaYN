# PRE_PLACE_SCRIPT for the AF pinned-route DRC fix option (c), written 2026-10-05
# (build/power_char/cbsg_20261005/af/pinned_fix/README.txt):
#   1. points the flow's PRE_REPORT_SCRIPT hook (read by apr.tcl's run_final via source_optional_user_script at
#      call time) at apr/scripts/cbsg/postfill_search_repair.tcl for THIS run only; that step sources the target's
#      own PRE_REPORT_SCRIPT (apr/scripts/check_popcount_placement.tcl, saved here) when it is done;
#   2. sources the campaign's pin/guide script apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl unchanged, so the
#      placement and route up to the fillers are the campaign pinned route's (deterministic: its replicate
#      cbsg_af_20261005_distguide_spp_pins_rep2 reproduced it exactly).
# The target file sets PRE_REPORT_SCRIPT unconditionally, so it cannot be overridden from the caller's environment;
# this run-time override is the hook path that leaves the target, apr.tcl and every shared script unchanged.
set cbsg_pf_dir [file dirname [file normalize [info script]]]
set ::cbsg_postfill_next_hook ""
if {[info exists ::env(PRE_REPORT_SCRIPT)]} { set ::cbsg_postfill_next_hook $::env(PRE_REPORT_SCRIPT) }
set ::env(PRE_REPORT_SCRIPT) [file join $cbsg_pf_dir postfill_search_repair.tcl]
puts "CBSG_POSTFILL_HOOK: PRE_REPORT_SCRIPT=$::env(PRE_REPORT_SCRIPT) next_hook=$::cbsg_postfill_next_hook"
source [file join $cbsg_pf_dir place_pins_and_guides_sc_cbsg.tcl]
