# ASTRAEA POST_LOAD_SCRIPT: preserve only the deliberately instantiated A7
# counter adders. The signed reduction, products, and accumulator remain free
# to optimize. This hook runs before ASTRAEA's own link command.
link

set pc_fa [get_cells -quiet -hierarchical -filter \
    {full_name =~ *u_popcount* && ref_name == ADDF_X1M_A7PP140ZTS_C30}]
set pc_ha [get_cells -quiet -hierarchical -filter \
    {full_name =~ *u_popcount* && ref_name == ADDH_X1M_A7PP140ZTS_C30}]
set pc_nfa [sizeof_collection $pc_fa]
set pc_nha [sizeof_collection $pc_ha]
set pc_lanes $env(PAYN_POPCOUNT_EXPECTED_LANES)
# Generate blocks can prefix the instance with a dot before change_names.
# Match the stable u_popcount token, then require the exact library reference.
if {$pc_nfa != 11 * $pc_lanes || $pc_nha != 4 * $pc_lanes} {
    puts "ERROR: popcount cell preservation expected [expr {11 * $pc_lanes}] FA / [expr {4 * $pc_lanes}] HA; found $pc_nfa FA / $pc_nha HA"
    exit 1
}
set_dont_touch $pc_fa true
set_dont_touch $pc_ha true

# Prevent boundary optimization from replacing a preserved counter output
# with copied logic in its parent while leaving other design boundaries alone.
set pc_wrappers [get_cells -quiet -hierarchical -filter \
    {ref_name =~ PaynUnsignedPopcount* || ref_name =~ PaynPopcount16*}]
set_boundary_optimization $pc_wrappers false
set_ungroup $pc_wrappers false

set pc_report [open popcount_preservation.rpt w]
puts $pc_report "Expected counter lanes: $pc_lanes"
puts $pc_report "Preserved full adders: $pc_nfa"
puts $pc_report "Preserved half adders: $pc_nha"
puts $pc_report "Counter hierarchy instances: [sizeof_collection $pc_wrappers]"
puts $pc_report "Cells: ADDF_X1M_A7PP140ZTS_C30 / ADDH_X1M_A7PP140ZTS_C30"
close $pc_report
puts "Popcount preservation: $pc_nfa full adders and $pc_nha half adders in $pc_lanes lanes"
