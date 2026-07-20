# APR post-load: restore clock uncertainty.
#
# The generated synthesis SDC omits clock uncertainty, so APR would otherwise
# close timing at ~zero margin. At zero margin, a few-ps modeling delta between
# STA and the routed-SDF gate sim (max-corner slew, timing-check notifier firing
# on the nearest clock edge) tips clock-gating ENABLE setup checks negative in
# simulation only -- injecting X into gated registers even though STA is clean.
#
# Restoring the synthesis-intended uncertainty (period * 0.05) forces APR to
# close every path -- including the clock-gating enable setups -- with positive
# margin, which keeps the timing-checks-ON gate-level power sim X-free. This
# mirrors the retained SC flow (apr_post_load.tcl set 0.125 ns at 2.5 ns).
set _per [expr {[info exists ::env(PERIOD)] ? $::env(PERIOD) : 2.5}]
set _unc [expr {[info exists ::env(CLOCK_UNCERTAINTY)] ? $::env(CLOCK_UNCERTAINTY) : $_per * 0.05}]
# MMMC: SDC edits require an interactively-enabled constraint mode (matches the
# retained SC apr_post_load.tcl idiom).
set _cm [all_constraint_modes -active]
set_interactive_constraint_modes $_cm
set_clock_uncertainty $_unc [all_clocks]
set_interactive_constraint_modes {}
puts "APR: set_clock_uncertainty $_unc ns (period $_per ns, mode $_cm)"
