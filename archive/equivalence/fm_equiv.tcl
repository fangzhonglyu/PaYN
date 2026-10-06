# RTL-to-RTL equivalence of one archived module (reference) against its cleaned
# designs/payn/rtl counterpart (implementation), at the synthesized point
# K8/M16/N8x8/LOW_W9 (grid: 2x2 of PEs), the only shape the old RTL had.
# Env: DESIGNS (include root), DW_ROOT (DC install), REF_SV, REF_TOP, IMPL_SV,
# IMPL_TOP, IMPL_PARAMS (set_top -parameter for the implementation, may be empty).
set_app_var hdlin_dwroot $env(DW_ROOT)
set_app_var synopsys_auto_setup true
set designs $env(DESIGNS)

read_sverilog -r -work_library WORK \
    -vcs "+incdir+$designs +define+SYNTHESIS +define+PAYN_K=8 +define+PAYN_M=16 +define+PAYN_NH=8 +define+PAYN_NW=8 +define+PAYN_SEG_LOW_W=9" \
    $env(REF_SV)
set_top r:/WORK/$env(REF_TOP)

read_sverilog -i -work_library WORK \
    -vcs "+incdir+$designs +define+SYNTHESIS +define+PAYN_M=16 +define+PAYN_NH=8 +define+PAYN_NW=8 +define+PAYN_LOW_W=9" \
    $env(IMPL_SV)
if {$env(IMPL_PARAMS) ne ""} {
    set_top i:/WORK/$env(IMPL_TOP) -parameter $env(IMPL_PARAMS)
} else {
    set_top i:/WORK/$env(IMPL_TOP)
}

match
report_unmatched_points
set ok [verify]
report_status
report_failing_points
puts "EQUIVALENCE_RESULT $env(IMPL_TOP) [expr {$ok ? "SUCCEEDED" : "FAILED"}]"
exit
