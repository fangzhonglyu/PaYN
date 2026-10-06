# Routed setup slack of the shift_in port on an existing BP route.
#
# The route's reports/setup.rpt lists only the worst path per endpoint
# (report_timing -late -max_paths 999), so on a route where reset dominates the
# tile endpoints it does not show shift_in at all.  This restores a COPY of the
# route's final database (the same Innovus timer and constraint mode that wrote
# setup.rpt) and reports the worst paths FROM shift_in, split into tile
# clock-gate enables and register D pins, plus the overall worst path as a
# calibration check against setup.rpt.
#
# Driver: sweeps/int_mode/bp/report_bp_routed_shift_in.sh
# Env: DB (copied .enc.dat), OUT_DIR (reports).
set top payn_array_signed_segmented_csa_bp
restoreDesign $env(DB) $top
setMultiCpuUsage -localCpu 8

report_timing -late -max_paths 1 > $env(OUT_DIR)/worst.rpt
report_timing -late -from [get_ports shift_in] -max_paths 10 > $env(OUT_DIR)/from_shift_in.rpt
report_timing -late -from [get_ports shift_in] \
    -to [get_pins {u_pe/u_array_core/*/clk_gate_*/latch/E u_pe/u_array_core/clk_gate_*/latch/E}] -max_paths 3 \
    > $env(OUT_DIR)/from_shift_in_to_clock_gate.rpt
report_timing -late -from [get_ports reset] -max_paths 1 > $env(OUT_DIR)/from_reset.rpt
report_timing -late -from [get_ports int_mode] -max_paths 1 > $env(OUT_DIR)/from_int_mode.rpt
# The per-PE lap enable's own path (csa_bp_20261004_lap: ring_q -> OR2 -> tile
# clock gates and shift-mux selects; on csa_bp_20261003b it only steered the
# west mux).  Guarded so a route without that flop still finishes.
if {[catch {report_timing -late -from [get_pins u_pe/ring_q_reg*/CK] -max_paths 3 > $env(OUT_DIR)/from_ring_q.rpt} msg]} {
    puts "RING_Q_REPORT_FAILED: $msg"
}
exit
