# Run the normal SC row/column guide setup, then terminate after the standard
# placement and pre-CTS optimization sequence.  This is for placement-QoR
# screening only; a winning point still requires the normal full APR flow.
set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir place_guides_sc_distribution.tcl]
source [file join $script_dir stop_after_place.tcl]
