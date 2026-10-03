# Read-only final placement check before timing/netlist/SPEF export.
puts "FINAL_PLACEMENT_CHECK_BEGIN"
file mkdir reports
checkPlace reports/placement_final.rpt
puts "FINAL_PLACEMENT_CHECK_END"
