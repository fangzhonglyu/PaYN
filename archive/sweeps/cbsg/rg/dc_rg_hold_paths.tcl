# Why the C-BSG RG netlist carries ~3,259 DLY2 cells (the CSA baseline has none): min-delay (hold) view of a
# synthesis run's written netlist + SDC.  DC fixes hold (ASTRAEA synth.tcl: set_fix_hold [all_clocks]) against an
# ideal clock.  Reports the worst hold paths overall and the min/max paths through sample DLY2 cells of the PE
# core.  Run from build/cbsg/rg/syn_paths/hold_<run>/ after sourcing the run's TARGET_DEF; env RG_RUN_DIR.
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
read_verilog -netlist $env(RG_RUN_DIR)/$env(TOP).syn.v
current_design $env(TOP)
link
read_sdc $env(RG_RUN_DIR)/$env(TOP).syn.sdc
set dly [get_cells -hier * -filter "ref_name=~DLY*"]
puts "RG_HOLD DLY cells: [sizeof_collection $dly], area [expr {[sizeof_collection $dly] * [get_attribute [index_collection $dly 0] area]}]"
puts "RG_HOLD worst hold paths overall"
report_timing -nosplit -delay_type min -max_paths 3
set core_dly [get_cells u_pe/u_array_core/* -filter "ref_name=~DLY*"]
set i 0
foreach_in_collection c $core_dly {
    if {$i % 700 == 0} {
        puts "RG_HOLD through [get_object_name $c] (min)"
        report_timing -nosplit -delay_type min -through [get_pins -of_objects $c -filter "pin_direction==out"] -max_paths 1
        puts "RG_HOLD through [get_object_name $c] (max)"
        report_timing -nosplit -delay_type max -through [get_pins -of_objects $c -filter "pin_direction==out"] -max_paths 1
    }
    incr i
}
exit
