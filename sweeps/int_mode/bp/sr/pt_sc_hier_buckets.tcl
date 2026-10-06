# Leaf-cell power buckets for the SC PaYN array tops (CSA, BP lap, SR, IPD).
# Source AFTER update_power in a PT-PX session (pre-layout or routed).  Writes
# hier_buckets.csv in the cwd: one row per bucket with cell count and internal /
# switching / leakage / total mW summed over leaf cells (full precision, unlike
# report_power -hier, which prints 3 digits).
#   tiles_seq / tiles_comb   u_pe/u_array_core/g_row_*__g_col_*__u_inner/*
#   core_seq / core_comb     other u_pe/u_array_core/* (a/w bit pipes, select tree,
#                            SR head muxes, IPD per-tile doubling AO22s)
#   pe_wrapper               u_pe/* outside u_array_core (BP west mux / ring)
#   sc_periph                u_peripheral/u_sc/*  (CSA: all of u_peripheral/*)
#   bp_bypass                u_peripheral/* outside u_sc
#   combiner, sobol          u_combiner/*, u_a_rng/* + u_w_rng/*
#   top                      remaining top-level cells
# Non-sequential CTS_* cells (routed clock-tree buffers) go to <bucket>_cts
# instead of <bucket>, so tree buffers inserted inside a hierarchy are visible.
# Net switching power is booked to the driving cell (PT convention).
proc _sc_pval {cell attribute} {
    set value [get_attribute -quiet $cell $attribute]
    if {$value eq "" || ![string is double -strict $value]} { return 0.0 }
    return $value
}
set _sc_buckets {tiles_seq tiles_comb core_seq core_comb pe_wrapper sc_periph bp_bypass combiner sobol top}
foreach _b $_sc_buckets { lappend _sc_buckets ${_b}_cts }
foreach _b $_sc_buckets {
    set _sc_n($_b) 0; set _sc_i($_b) 0.0; set _sc_s($_b) 0.0; set _sc_l($_b) 0.0
}
set _sc_has_usc [expr {[sizeof_collection [get_cells -quiet u_peripheral/u_sc]] > 0}]
foreach_in_collection _c [get_cells -hierarchical -filter {is_hierarchical==false}] {
    set _n [get_object_name $_c]
    set _seq [get_attribute -quiet $_c is_sequential]
    set _isseq [expr {$_seq eq "true" || $_seq eq "1"}]
    set _leaf [lindex [split $_n /] end]
    if {[regexp {^u_pe/u_array_core/g_row_\d+__g_col_\d+__u_inner/} $_n]} {
        set _b [expr {$_isseq ? "tiles_seq" : "tiles_comb"}]
    } elseif {[string match u_pe/u_array_core/* $_n]} {
        set _b [expr {$_isseq ? "core_seq" : "core_comb"}]
    } elseif {[string match u_pe/* $_n]} {
        set _b pe_wrapper
    } elseif {[string match u_peripheral/* $_n]} {
        if {!$_sc_has_usc || [string match u_peripheral/u_sc/* $_n]} { set _b sc_periph } else { set _b bp_bypass }
    } elseif {[string match u_combiner/* $_n]} {
        set _b combiner
    } elseif {[string match u_a_rng/* $_n] || [string match u_w_rng/* $_n]} {
        set _b sobol
    } else {
        set _b top
    }
    if {!$_isseq && [string match CTS_* $_leaf]} { set _b ${_b}_cts }
    incr _sc_n($_b)
    set _sc_i($_b) [expr {$_sc_i($_b) + [_sc_pval $_c internal_power]}]
    set _sc_s($_b) [expr {$_sc_s($_b) + [_sc_pval $_c switching_power]}]
    set _sc_l($_b) [expr {$_sc_l($_b) + [_sc_pval $_c leakage_power]}]
}
set _fh [open hier_buckets.csv w]
puts $_fh "bucket,cells,internal_mW,switching_mW,leakage_mW,total_mW"
foreach _b $_sc_buckets {
    puts $_fh [format "%s,%d,%.9f,%.9f,%.9f,%.9f" $_b $_sc_n($_b) [expr {1000*$_sc_i($_b)}] \
        [expr {1000*$_sc_s($_b)}] [expr {1000*$_sc_l($_b)}] \
        [expr {1000*($_sc_i($_b)+$_sc_s($_b)+$_sc_l($_b))}]]
}
close $_fh
redirect -variable _sc_tot { report_power -significant_digits 9 -nosplit }
regexp {Total Power\s*=\s*(\S+)} $_sc_tot -> _sc_total
puts [format "SC_HIER_BUCKETS_DONE total_mW=%.9f" [expr {1000*$_sc_total}]]
