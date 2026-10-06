# DC synthesis of one WO-ring verification block (env TOP), same library,
# clock and compile style as the routed CSA run (syn/targets/TSMC22/PAYN_SC_CSA):
# A7PP140Z SVT C30 base + HPK, 2.5 ns, INPUT_DELAY 1.25, OUTPUT_DELAY 0.05,
# max fanout 16, multibit inference, compile_ultra -no_autoungroup -gate_clock.
set TOP $env(TOP)
set KIT /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
set base_db $KIT/sc7mcpp140z_base_svt_c30/r3p0/db/sc7mcpp140z_cln22ul_base_svt_c30_tt_typical_max_0p80v_25c.db
set hpk_db  $KIT/sc7mcpp140z_hpk_svt_c30/r3p0/db/sc7mcpp140z_cln22ul_hpk_svt_c30_tt_typical_max_0p80v_25c.db
set_app_var search_path ". $env(SRC_DIR) $search_path"
set_app_var target_library [list $base_db $hpk_db]
set_app_var synthetic_library dw_foundation.sldb
set_app_var link_library "* $target_library $synthetic_library"
set_app_var hdlin_infer_multibit default_all
set_host_options -max_cores 4

analyze -format sverilog $env(SRC_DIR)/wo_ring_blocks.sv
elaborate $TOP
current_design $TOP
link
set_multibit_options -stage rtl -mode non_timing_driven

if {[sizeof_collection [get_ports -quiet clk]] > 0} {
    create_clock [get_ports clk] -name clk -period 2.5
} else {
    create_clock -name clk -period 2.5
}
set_max_fanout 16 [current_design]
set_driving_cell -lib_cell INV_X2M_A7PP140ZTS_C30 [all_inputs]
set_input_delay 1.25 -clock clk [all_inputs]
if {[sizeof_collection [get_ports -quiet clk]] > 0} { remove_input_delay -clock clk [get_ports clk] }
set_output_delay 0.05 -clock clk [all_outputs]
set_switching_activity -static_probability 0.5 -toggle_rate 0.25 -base_clock clk [all_inputs]
set_clock_gating_style -minimum_bitwidth 1 -positive_edge_logic integrated -control_point before
compile_ultra -no_autoungroup -gate_clock

report_area -nosplit > $TOP.area.rpt
report_reference -nosplit > $TOP.ref.rpt
report_timing -max_paths 3 > $TOP.timing.rpt
report_qor > $TOP.qor.rpt
write -format verilog -hierarchy -output $TOP.syn.v
exit
