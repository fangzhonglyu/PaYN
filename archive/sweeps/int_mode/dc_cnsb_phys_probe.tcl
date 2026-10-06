# Synthesize the CNSB physical probes (sweeps/int_mode/cnsb_phys_probe.sv) with
# the CSA flow's library and options: TSMC22 sc7mcpp140z base+HPK svt_c30 TT
# 0.80 V, 2.5 ns, 5% clock uncertainty, compile_ultra -gate_clock, multibit.
# Run from a scratch build dir:  TOPS="..." ACC_IN_DELAY=1.10 dc_shell -f <this>
set REPO /home/barrylyu/repos/PaYN
set KIT_PATH /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
set base_lib ${KIT_PATH}/sc7mcpp140z_base_svt_c30/r3p0
set hpk_lib  ${KIT_PATH}/sc7mcpp140z_hpk_svt_c30/r3p0
set_app_var search_path ". ${REPO}/designs ${base_lib}/db ${hpk_lib}/db $search_path"
set_app_var target_library [list \
    ${base_lib}/db/sc7mcpp140z_cln22ul_base_svt_c30_tt_typical_max_0p80v_25c.db \
    ${hpk_lib}/db/sc7mcpp140z_cln22ul_hpk_svt_c30_tt_typical_max_0p80v_25c.db]
set_app_var synthetic_library dw_foundation.sldb
set_app_var link_library "* $target_library $synthetic_library"
set_app_var hdlin_infer_multibit default_all
set_app_var compile_clock_gating_through_hierarchy true
set_app_var power_cg_derive_related_clock true
set_host_options -max_cores 4
suppress_message UID-401

set PERIOD 2.5
set ACC_IN_DELAY $env(ACC_IN_DELAY)
foreach top $env(TOPS) {
    remove_design -all
    analyze -format sverilog ${REPO}/sweeps/int_mode/cnsb_phys_probe.sv
    elaborate $top
    current_design $top
    link
    uniquify
    create_clock [get_ports clk] -name clk -period $PERIOD
    set_clock_uncertainty [expr {$PERIOD * 0.05}] [get_clocks clk]
    set_driving_cell -lib_cell INV_X2M_A7PP140ZTS_C30 [remove_from_collection [all_inputs] [get_ports clk]]
    set_input_delay 1.25 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
    if {[sizeof_collection [get_ports -quiet acc_out_east*]] > 0} {
        set_input_delay $ACC_IN_DELAY -clock clk [get_ports acc_out_east*]
    }
    set_output_delay 0.05 -clock clk [all_outputs]
    set_max_fanout 16 [current_design]
    set_multibit_options -stage rtl -mode non_timing_driven
    set_clock_gating_style -minimum_bitwidth 1 -positive_edge_logic integrated -control_point before
    compile_ultra -no_autoungroup -gate_clock
    redirect ${top}.area.rpt   { report_area -hierarchy -nosplit }
    redirect ${top}.ref.rpt    { report_reference -nosplit -hierarchy }
    redirect ${top}.timing.rpt { report_timing -max_paths 5 -nworst 1 -nosplit -significant_digits 3 }
    redirect ${top}.cg.rpt     { report_clock_gating -nosplit }
    redirect -variable _ar { report_area -nosplit }
    regexp {Total cell area:\s+([0-9.]+)} $_ar -> ta
    set wp [get_timing_paths -max_paths 1]
    puts [format "PROBE %-28s area=%9.3f worst_slack=%7.3f  %s -> %s" $top $ta \
        [get_attribute $wp slack] [get_object_name [get_attribute $wp startpoint]] \
        [get_object_name [get_attribute $wp endpoint]]]
    write -format verilog -hierarchy -output ${top}.syn.v
}
exit
