# DC synthesizability preflight for the C-BSG AF + IPD top (not a synthesis run): analyze +
# elaborate payn_array_signed_segmented_csa_cbsg_af_ipd with the target's SYN_DEFINES, link,
# check_design; no latches allowed; prints the edge-triggered register count.  The same check is
# run on the AF top and the IPD top for the register delta (CAI_ELAB lines).
# Run by sweeps/cbsg/af_ipd/run_dc_elab.sh from build/cbsg/af_ipd/dc_elab after sourcing the syn target.
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
set_app_var hdlin_infer_multibit default_none

proc elab_one {tag src top} {
    remove_design -all
    analyze -format sverilog -define $::env(SYN_DEFINES) $src
    if {![elaborate $top]} { puts "CAI_ELAB FAIL $tag elaborate"; return 0 }
    current_design $top
    if {![link]} { puts "CAI_ELAB FAIL $tag link"; return 0 }
    redirect -file check_design_$tag.rpt { check_design }
    set latches [sizeof_collection [all_registers -level_sensitive]]
    set regs [sizeof_collection [all_registers -edge_triggered]]
    puts "CAI_ELAB $tag latches $latches registers $regs"
    if {$latches != 0} { puts "CAI_ELAB FAIL $tag latches"; return 0 }
    return 1
}
set ok [elab_one afipd ${SRC_SV} $DESIGN_NAME]
set ok_af [elab_one af payn/variants/signed_segmented_csa_cbsg_af/payn_array_signed_segmented_csa_cbsg_af.sv payn_array_signed_segmented_csa_cbsg_af]
set ok_ipd [elab_one ipd payn/variants/signed_segmented_csa_bp_ipd/payn_array_signed_segmented_csa_bp_ipd.sv payn_array_signed_segmented_csa_bp_ipd]
# PASS needs all three: the register delta in the README is AF-IPD minus AF (and IPD for reference),
# so a failed reference elaboration must fail the preflight too.
if {$ok && $ok_af && $ok_ipd} { puts "CAI_ELAB PASS" } else { puts "CAI_ELAB FAIL (afipd $ok af $ok_af ipd $ok_ipd)" }
exit 0
