# PrimeTime link and search libraries for TSMC22, sourced by every flow PrimeTime script (the same choice as
# ASTRAEA's apr/scripts/power.tcl, TSMC22 branch): typical corner 0.80 V / 25 C, the base flavors of
# TSMC22_LIB_FLAVORS and, with TSMC22_HPK=1, the HPK flavors of TSMC22_HPK_FLAVORS (sc7mcpp140z only).
# Defaults (flow/env.sh): sc7mcpp140z, svt_c30, HPK svt_c30.
set tsmc22_kit /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
set tsmc22_cell_tier sc7mcpp140z
if {[info exists env(TSMC22_CELL_TIER)] && $env(TSMC22_CELL_TIER) ne ""} {
    set tsmc22_cell_tier $env(TSMC22_CELL_TIER)
}
switch -- $tsmc22_cell_tier {
    sc7mcpp140z   { set tsmc22_lib_release r3p0 }
    sc6p5mcpp140z { set tsmc22_lib_release r4p0 }
    default { puts "Error: unsupported TSMC22_CELL_TIER $tsmc22_cell_tier"; exit 1 }
}
set tsmc22_base_flavors [list svt_c30]
if {[info exists env(TSMC22_LIB_FLAVORS)] && $env(TSMC22_LIB_FLAVORS) ne ""} {
    set tsmc22_base_flavors [regexp -all -inline {\S+} $env(TSMC22_LIB_FLAVORS)]
}
set tsmc22_hpk_flavors $tsmc22_base_flavors
if {[info exists env(TSMC22_HPK_FLAVORS)] && $env(TSMC22_HPK_FLAVORS) ne ""} {
    set tsmc22_hpk_flavors [regexp -all -inline {\S+} $env(TSMC22_HPK_FLAVORS)]
}
set tsmc22_hpk 1
if {[info exists env(TSMC22_HPK)] && $env(TSMC22_HPK) ne ""} { set tsmc22_hpk $env(TSMC22_HPK) }

set tsmc22_db_dirs [list .]
set tsmc22_db_files [list]
foreach flavor $tsmc22_base_flavors {
    set root ${tsmc22_kit}/${tsmc22_cell_tier}_base_${flavor}/${tsmc22_lib_release}
    lappend tsmc22_db_dirs ${root}/db
    lappend tsmc22_db_files ${root}/db/${tsmc22_cell_tier}_cln22ul_base_${flavor}_tt_typical_max_0p80v_25c.db
}
if {$tsmc22_hpk == 1} {
    if {$tsmc22_cell_tier ne "sc7mcpp140z"} { puts "Error: TSMC22 HPK needs sc7mcpp140z"; exit 1 }
    foreach flavor $tsmc22_hpk_flavors {
        set root ${tsmc22_kit}/sc7mcpp140z_hpk_${flavor}/r3p0
        lappend tsmc22_db_dirs ${root}/db
        lappend tsmc22_db_files ${root}/db/sc7mcpp140z_cln22ul_hpk_${flavor}_tt_typical_max_0p80v_25c.db
    }
}
foreach db $tsmc22_db_files {
    if {![file exists $db]} { puts "Error: missing TSMC22 library $db"; exit 1 }
}
set search_path [concat $tsmc22_db_dirs $search_path]
set link_library [concat [list "*"] $tsmc22_db_files]
