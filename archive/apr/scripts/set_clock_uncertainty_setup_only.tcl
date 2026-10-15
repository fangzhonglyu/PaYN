# APR post-load: setup-only clock uncertainty.
#
# Variant of set_clock_uncertainty.tcl for designs that need extra SETUP margin
# to keep the routed-SDF gate sim X-free, but cannot afford the same margin on
# hold.  The shared script calls set_clock_uncertainty with no -setup/-hold, so
# the value applies to both checks: raising it to close setup simultaneously
# makes every hold check that much harder.  On BITMOD_TILE at 0.25 ns that
# traded a -0.000 ns setup / +0.013 ns hold route for +0.054 ns setup /
# -0.013 ns hold -- hold violations inject X just as readily as setup ones.
#
# Applying the margin to setup only lets APR close setup with real slack while
# hold keeps the tool's normal (small) uncertainty, which is what the default
# period*0.05 already provided successfully.
#
#   CLOCK_UNCERTAINTY        setup uncertainty (default period * 0.05)
#   CLOCK_UNCERTAINTY_HOLD   hold uncertainty  (default period * 0.05)
set _per [expr {[info exists ::env(PERIOD)] ? $::env(PERIOD) : 2.5}]
set _unc [expr {[info exists ::env(CLOCK_UNCERTAINTY)] ? $::env(CLOCK_UNCERTAINTY) : $_per * 0.05}]
set _unc_hold [expr {[info exists ::env(CLOCK_UNCERTAINTY_HOLD)] ?
                     $::env(CLOCK_UNCERTAINTY_HOLD) : $_per * 0.05}]

set _cm [all_constraint_modes -active]
set_interactive_constraint_modes $_cm
set_clock_uncertainty -setup $_unc      [all_clocks]
set_clock_uncertainty -hold  $_unc_hold [all_clocks]
set_interactive_constraint_modes {}
puts "APR: set_clock_uncertainty -setup $_unc -hold $_unc_hold ns (period $_per ns, mode $_cm)"
