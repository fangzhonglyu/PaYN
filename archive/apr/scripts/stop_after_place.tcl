# Placement-QoR experiment hook.
#
# This script is sourced immediately before run_place by the ASTRAEA APR flow.
# Replace the next stage with a clean exit so the normal floorplan and
# place_opt_design sequence runs and saves <top>.place.enc, but the experiment
# does not spend time on CTS, detailed routing, antenna repair, or GDS export.
#
# The placer already prints estimated wire length, placement density, early
# global-route overflow, and normalized hotspot area into apr.log.
proc run_clock {} {
    puts "APR_STOP_AFTER_PLACE: placement checkpoint saved; skipping CTS and routing"
    exit 0
}
