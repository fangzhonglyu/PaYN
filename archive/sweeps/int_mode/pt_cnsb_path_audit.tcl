# Read-only PrimeTime path audit of the accepted routed CSA single-PE layout,
# for the CNSB / spatial-Booth INT-mode review (physical/timing lens).
# Loads outputs/*.apr.v + SPEF + the synthesis SDC of the accepted run and
# reports the paths INT mode would exercise differently from SC.  Writes only
# into the current working directory (a separate view dir), never into the
# accepted APR checkpoint.
#
#   cd build/int_mode_audit/cnsb_pt_paths && \
#     RUN_DIR=<accepted run> pt_shell -file sweeps/int_mode/pt_cnsb_path_audit.tcl

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
set timing_report_unconstrained_paths false
update_timing -full

proc worst {label args} {
    set p [eval get_timing_paths -max_paths 1 -nworst 1 $args]
    if {[sizeof_collection $p] == 0} {
        puts [format "AUDIT %-44s no path" $label]
        return
    }
    set sp [get_object_name [get_attribute $p startpoint]]
    set ep [get_object_name [get_attribute $p endpoint]]
    set sl [get_attribute $p slack]
    set ar [get_attribute $p arrival]
    puts [format "AUDIT %-44s slack=%7.3f arrival=%6.3f  %s -> %s" $label $sl $ar $sp $ep]
}

set rv_a   [get_cells -hier -filter "full_name=~u_a_rng/*random_value_reg*"]
set rv_w   [get_cells -hier -filter "full_name=~u_w_rng/*random_value_reg*"]
set cnt    [get_cells -hier -filter "full_name=~u_*_rng/*count_reg*"]
set icg_rng [get_cells -hier -filter "full_name=~u_*_rng/*clk_gate* && is_hierarchical==false"]
set abq    [get_cells -hier -filter "full_name=~u_peripheral/a_binary_q_reg*"]
set wbq    [get_cells -hier -filter "full_name=~u_peripheral/w_binary_q_reg*"]
set asq    [get_cells -hier -filter "full_name=~u_peripheral/a_signs_q_reg*"]
set wsq    [get_cells -hier -filter "full_name=~u_peripheral/w_signs_q_reg*"]
set abp    [get_cells -hier -filter "full_name=~u_pe/u_array_core/a_bits_pipe_reg*"]
set wbp    [get_cells -hier -filter "full_name=~u_pe/u_array_core/w_bits_pipe_reg*"]
set asp    [get_cells -hier -filter "full_name=~u_pe/u_array_core/a_signs_pipe_reg*"]
set wsp    [get_cells -hier -filter "full_name=~u_pe/u_array_core/w_signs_pipe_reg*"]
set accl   [get_cells -hier -filter "full_name=~u_pe/u_array_core/*u_inner/acc_low_reg*"]
set acch   [get_cells -hier -filter "full_name=~u_pe/u_array_core/*u_inner/acc_high_reg*"]
set pend   [get_cells -hier -filter "full_name=~u_pe/u_array_core/*u_inner/pending_*_reg*"]
set lwave  [get_cells -hier -filter "full_name=~u_pe/u_array_core/load_*_sign_q_reg*"]

foreach {n c} [list rv_a $rv_a rv_w $rv_w count $cnt icg_rng $icg_rng a_binary_q $abq \
        w_binary_q $wbq a_signs_q $asq w_signs_q $wsq a_bits_pipe $abp w_bits_pipe $wbp \
        a_signs_pipe $asp w_signs_pipe $wsp acc_low $accl acc_high $acch pending $pend \
        load_wave $lwave] {
    puts [format "AUDIT_COUNT %-14s %d cells" $n [sizeof_collection $c]]
}
foreach_in_collection c $icg_rng {
    puts "AUDIT_ICG [get_object_name $c] [get_attribute $c ref_name]"
}

puts "AUDIT ==== setup (max) ===="
worst "Sobol A random_value D-side (setup)"   -delay_type max -to $rv_a
worst "Sobol W random_value D-side (setup)"   -delay_type max -to $rv_w
worst "Sobol count D-side (setup)"            -delay_type max -to $cnt
worst "Sobol ICG enables (clock-gating setup)" -delay_type max -to [get_pins -of $icg_rng -filter "direction==in && lib_pin_name==E"]
worst "rng_en port -> anything"                -delay_type max -from [get_ports rng_en]
worst "Sobol W Q -> w_bits_pipe (SC worst)"    -delay_type max -from $rv_w -to $wbp
worst "Sobol A Q -> a_bits_pipe"               -delay_type max -from $rv_a -to $abp
worst "a_binary_q -> a_bits_pipe (INT/cycle)"  -delay_type max -from $abq -to $abp
worst "w_binary_q -> w_bits_pipe (INT/cycle)"  -delay_type max -from $wbq -to $wbp
worst "a_signs_q -> a_signs_pipe"              -delay_type max -from $asq -to $asp
worst "w_signs_q -> w_signs_pipe"              -delay_type max -from $wsq -to $wsp
worst "a_signs_pipe -> acc_low"                -delay_type max -from $asp -to $accl
worst "a_signs_pipe -> pending"                -delay_type max -from $asp -to $pend
worst "w_signs_pipe -> acc_low"                -delay_type max -from $wsp -to $accl
worst "a_bits_pipe -> acc_low"                 -delay_type max -from $abp -to $accl
worst "w_bits_pipe -> acc_low"                 -delay_type max -from $wbp -to $accl
worst "bits_pipe -> pending"                   -delay_type max -from $wbp -to $pend
worst "load_wave -> sign pipes"                -delay_type max -from $lwave
worst "a_binary_in port -> a_binary_q"         -delay_type max -from [get_ports a_binary_in*]
worst "w_binary_in port -> w_binary_q"         -delay_type max -from [get_ports w_binary_in*]
worst "a_signs_in port -> a_signs_q"           -delay_type max -from [get_ports a_signs_in*]
worst "load_a port -> anything"                -delay_type max -from [get_ports load_a]
worst "load_a_sign port -> anything"           -delay_type max -from [get_ports load_a_sign]
worst "mac_en port -> anything"                -delay_type max -from [get_ports mac_en]
worst "acc_in_west port -> anything"           -delay_type max -from [get_ports acc_in_west*]
worst "-> acc_out_east port"                   -delay_type max -to [get_ports acc_out_east*]
worst "acc_high -> acc_out_east port"          -delay_type max -from $acch -to [get_ports acc_out_east*]
worst "pending -> acc_out_east port"           -delay_type max -from $pend -to [get_ports acc_out_east*]

puts "AUDIT ==== hold (min) ===="
worst "Sobol A random_value D-side (hold)"     -delay_type min -to $rv_a
worst "Sobol W random_value D-side (hold)"     -delay_type min -to $rv_w
worst "acc_in_west port (hold)"                -delay_type min -from [get_ports acc_in_west*]
worst "a_binary_in port (hold)"                -delay_type min -from [get_ports a_binary_in*]

puts "AUDIT ==== detailed paths ===="
report_timing -delay_type max -to $rv_w -max_paths 1 -nosplit -input_pins -significant_digits 3
report_timing -delay_type max -to $rv_a -max_paths 1 -nosplit -input_pins -significant_digits 3
report_timing -delay_type max -from $acch -to [get_ports acc_out_east*] -max_paths 1 -nosplit -significant_digits 3
report_timing -delay_type max -from [get_ports acc_in_west*] -max_paths 1 -nosplit -significant_digits 3
report_timing -delay_type max -from $abq -to $abp -max_paths 1 -nosplit -significant_digits 3
report_timing -delay_type max -from $asp -to $accl -max_paths 1 -nosplit -significant_digits 3
report_timing -delay_type max -from [get_ports a_binary_in*] -max_paths 1 -nosplit -significant_digits 3
exit
