# Follow-up to pt_cnsb_path_audit.tcl: Sobol data-pin (D/D0/D1) setup/hold only,
# ICG-enable paths inside the Sobol, and random_value Q fanout.  Read-only.
set RUN_DIR $env(RUN_DIR)
set TOP payn_array_signed_segmented_csa
set KIT_PATH /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
set base_lib ${KIT_PATH}/sc7mcpp140z_base_svt_c30/r3p0/db
set hpk_lib  ${KIT_PATH}/sc7mcpp140z_hpk_svt_c30/r3p0/db
set search_path [list . $base_lib $hpk_lib]
set link_library [list "*" \
    ${base_lib}/sc7mcpp140z_cln22ul_base_svt_c30_tt_typical_max_0p80v_25c.db \
    ${hpk_lib}/sc7mcpp140z_cln22ul_hpk_svt_c30_tt_typical_max_0p80v_25c.db]
read_verilog ${RUN_DIR}/outputs/${TOP}.apr.v
current_design $TOP
link_design
read_sdc ${RUN_DIR}/${TOP}.syn.sdc
read_parasitics -format SPEF ${RUN_DIR}/outputs/${TOP}.spef
update_timing -full
proc worst {label args} {
    set p [eval get_timing_paths -max_paths 1 -nworst 1 $args]
    if {[sizeof_collection $p] == 0} { puts [format "AUDIT %-44s no path" $label]; return }
    puts [format "AUDIT %-44s slack=%7.3f arrival=%6.3f  %s -> %s" $label \
        [get_attribute $p slack] [get_attribute $p arrival] \
        [get_object_name [get_attribute $p startpoint]] [get_object_name [get_attribute $p endpoint]]]
}
foreach bank {a w} {
    set rv [get_cells -hier -filter "full_name=~u_${bank}_rng/*random_value_reg* && is_hierarchical==false"]
    set dp [get_pins -of $rv -filter "lib_pin_name=~D*"]
    set ep [get_pins -hier -filter "full_name=~u_${bank}_rng/*clk_gate*/latch/E"]
    puts "AUDIT_COUNT ${bank} random_value leaf cells=[sizeof_collection $rv] data pins=[sizeof_collection $dp] icg E pins=[sizeof_collection $ep]"
    worst "Sobol ${bank} random_value data D (setup)" -delay_type max -to $dp
    worst "Sobol ${bank} random_value data D (hold)"  -delay_type min -to $dp
    worst "Sobol ${bank} per-gen ICG E (setup)"        -delay_type max -to $ep
    worst "Sobol ${bank} per-gen ICG E (hold)"         -delay_type min -to $ep
    report_timing -delay_type max -to $dp -max_paths 1 -nosplit -input_pins -significant_digits 3
    set mx 0; set tot 0; set n 0
    foreach_in_collection q [get_pins -of $rv -filter "direction==out"] {
        set net [get_nets -of $q]
        set fo [sizeof_collection [get_pins -leaf -of $net -filter "direction==in"]]
        incr tot $fo; incr n; if {$fo > $mx} {set mx $fo}
    }
    puts "AUDIT_FANOUT ${bank} random_value Q pins=$n direct leaf loads total=$tot max=$mx"
}
set top_icg [get_cells -hier -filter "full_name=~*clk_gate_count_reg_7_/latch && full_name!~u_*_rng/*"]
foreach_in_collection c $top_icg { puts "AUDIT_TOPICG [get_object_name $c] [get_attribute $c ref_name]" }
worst "top Sobol ICG E (setup)" -delay_type max -to [get_pins -of $top_icg -filter "lib_pin_name==E"]
exit
