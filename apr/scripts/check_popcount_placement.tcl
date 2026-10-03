# Read-only final placement audit. Called from PRE_REPORT_SCRIPT after DRC
# repair and before SDF/netlist/SPEF export; detailed output remains in apr.log.
puts "POP_COUNT_FINAL_PLACEMENT_CHECK_BEGIN"
file mkdir reports
checkPlace reports/placement_final.rpt
puts "POP_COUNT_FINAL_PLACEMENT_CHECK_END"
