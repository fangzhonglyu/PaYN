# GTECH-only DC elaboration of the RG top (no target library, no AFS) for one FAULT value, with or without
# +define CBSG_RG_FAULT_HOOKS; writes the elaborated netlist so sweeps/cbsg/rg/run_rtl_checks.sh can show that
# without the hooks define every FAULT value elaborates to the same netlist as FAULT = 0 (the synthesis view
# ignores FAULT), and that with the define the hooks do change it (positive control).
#   env: RG_REPO, RG_FAULT, RG_HOOKS (0/1)
set repo $::env(RG_REPO)
set_app_var search_path [list . $repo/designs $::env(SYNOPSYS)/libraries/syn $::env(SYNOPSYS)/dw/sim_ver]
set_app_var target_library ""
set_app_var synthetic_library dw_foundation.sldb
set_app_var link_library [list * dw_foundation.sldb]
define_design_lib WORK -path ./WORK
set defs {SYNTHESIS PAYN_K=8 PAYN_M=16 PAYN_NH=8 PAYN_NW=8 PAYN_SEG_LOW_W=9}
if {$::env(RG_HOOKS)} { lappend defs CBSG_RG_FAULT_HOOKS }
set ok [analyze -format sverilog -define $defs \
    $repo/designs/payn/variants/signed_segmented_csa_cbsg_rg/payn_array_signed_segmented_csa_cbsg_rg.sv]
puts "ANALYZE_RESULT $ok"
set ok [elaborate payn_array_signed_segmented_csa_cbsg_rg -parameters "FAULT=$::env(RG_FAULT)"]
puts "ELABORATE_RESULT $ok"
current_design [get_designs payn_array_signed_segmented_csa_cbsg_rg*]
link
puts "REG_COUNT [sizeof_collection [all_registers]]"
puts "CELL_COUNT [sizeof_collection [get_cells -hier *]]"
write -hierarchy -format verilog -output elab.v
exit
