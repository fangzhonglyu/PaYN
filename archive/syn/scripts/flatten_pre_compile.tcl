# Dissolve all RTL hierarchy BEFORE compile_ultra, so DC optimizes the design as
# one flat netlist and may share/restructure logic across tile boundaries.
#
# Sourced via POST_LOAD_SCRIPT, which ASTRAEA's synth.tcl runs right after
# link/current_design and before create_clock, uniquify and compile_ultra.  That
# ordering is the whole point: the flow's own FLATTEN=1 knob runs
# `ungroup -all -flatten` AFTER compile_ultra, which strips hierarchy from an
# already-optimized netlist and therefore cannot change QoR.  This can.
#
# Consequences to be aware of before using a flattened run for anything:
#   * per-tile rows disappear from area.rpt (there are no tile modules left);
#   * PT/SAIF scripts that match `*u_inner/*` or `u_pe/*` must instead match the
#     flattened leaf-name prefixes DC synthesizes (u_pe_u_array_core_...);
#   * apr/scripts/place_guides_sc_distribution.tcl selects tiles by hierarchical
#     instance name, so the accepted spp_fixed distribution guides will select
#     nothing -- a flattened APR run is NOT recipe-comparable to the accepted
#     0.70984 point unless those patterns are adapted too.
puts "Pre-compile flatten: ungroup -all -flatten (cross-boundary optimization ENABLED)"
ungroup -all -flatten
puts "Pre-compile flatten: [sizeof_collection [get_cells -quiet -hierarchical -filter {is_hierarchical==true}]] hierarchical instance(s) remain"
