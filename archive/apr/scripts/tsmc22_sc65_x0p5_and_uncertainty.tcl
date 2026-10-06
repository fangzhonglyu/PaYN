# Preserve the SCArch-proven X0P5 full-adder/product mapping through APR, then
# restore PaYN's clock uncertainty for timing-check-clean routed simulation.
source [file join $SCRIPT_DIR tsmc22_sc65_addf_and2_x0p5_only_v2.tcl]
source [file join [file dirname [file normalize [info script]]] set_clock_uncertainty.tcl]
