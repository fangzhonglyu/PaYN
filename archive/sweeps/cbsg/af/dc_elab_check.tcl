# DC synthesizability preflight for the C-BSG AF top (not a synthesis run):
#   1. analyze + elaborate payn_array_signed_segmented_csa_cbsg_af with the target's SYN_DEFINES,
#      link, check_design (the behavioral kA encoder, stream generator and peripheral must elaborate
#      without latches or unresolved references);
#   2. a quick standalone compile_ultra of one CbsgAfKaEncoder (LANE 0) at the target clock as a
#      combinational block (input and output delay 0, max delay = PERIOD), for a first area and
#      depth figure of the encoder that appears 64 times per PE.
# Run by sweeps/cbsg/af/run_dc_elab.sh from build/cbsg/af/dc_elab after sourcing the syn target.
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
set_app_var hdlin_infer_multibit default_none

analyze -format sverilog -define $env(SYN_DEFINES) ${SRC_SV}
if {![elaborate $DESIGN_NAME]} { puts "CBSG_ELAB FAIL elaborate"; exit 1 }
current_design $DESIGN_NAME
if {![link]} { puts "CBSG_ELAB FAIL link"; exit 1 }
redirect -file check_design.rpt { check_design }
set latches [sizeof_collection [all_registers -level_sensitive]]
puts "CBSG_ELAB latches $latches"
puts "CBSG_ELAB registers [sizeof_collection [all_registers -edge_triggered]]"
if {$latches != 0} { puts "CBSG_ELAB FAIL latches"; exit 1 }

remove_design -all
analyze -format sverilog -define $env(SYN_DEFINES) ${SRC_SV}
elaborate CbsgAfKaEncoder -parameters "LANE=0"
current_design [get_designs CbsgAfKaEncoder*]
link
set_max_delay $PERIOD -from [all_inputs] -to [all_outputs]
compile_ultra -no_autoungroup
redirect -file ka_encoder_area.rpt { report_area }
redirect -file ka_encoder_timing.rpt { report_timing -nosplit }
set fh [open ka_encoder_area.rpt r]
set rpt [read $fh]
close $fh
set area n/a
regexp {Total cell area:\s+([0-9.]+)} $rpt -> area
puts "CBSG_ELAB ka_encoder_area_um2 $area cells [sizeof_collection [get_cells -hier * -filter is_hierarchical==false]]"
set p [get_timing_paths -max_paths 1]
puts "CBSG_ELAB ka_encoder_delay [get_attribute $p arrival]"
puts "CBSG_ELAB PASS"
exit 0
