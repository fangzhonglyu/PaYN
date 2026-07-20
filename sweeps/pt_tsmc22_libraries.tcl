# Build PrimeTime link/search libraries from the target's TSMC22 flavor env.
# Defaults preserve the original base-SVT + HPK-SVT reporting setup.
set TSMC22_KIT /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
set tsmc22_cell_tier sc7mcpp140z
if {[info exists env(TSMC22_CELL_TIER)] && $env(TSMC22_CELL_TIER) ne ""} {
    set tsmc22_cell_tier $env(TSMC22_CELL_TIER)
}
switch -- $tsmc22_cell_tier {
    sc7mcpp140z   { set tsmc22_lib_release r3p0 }
    sc6p5mcpp140z { set tsmc22_lib_release r4p0 }
    default { error "Unsupported TSMC22 component-report cell tier: $tsmc22_cell_tier" }
}
set tsmc22_base_flavors [list svt_c30]
if {[info exists env(TSMC22_LIB_FLAVORS)] && $env(TSMC22_LIB_FLAVORS) ne ""} {
    set tsmc22_base_flavors [regexp -all -inline {\S+} $env(TSMC22_LIB_FLAVORS)]
}
set tsmc22_hpk_flavors $tsmc22_base_flavors
if {[info exists env(TSMC22_HPK_FLAVORS)] && $env(TSMC22_HPK_FLAVORS) ne ""} {
    set tsmc22_hpk_flavors [regexp -all -inline {\S+} $env(TSMC22_HPK_FLAVORS)]
}
set tsmc22_hpk_enabled 1
if {[info exists env(TSMC22_HPK)]} {
    set tsmc22_hpk_enabled $env(TSMC22_HPK)
}

set tsmc22_db_files [list]
set tsmc22_db_dirs [list .]
foreach flavor $tsmc22_base_flavors {
    set root ${TSMC22_KIT}/${tsmc22_cell_tier}_base_${flavor}/${tsmc22_lib_release}
    lappend tsmc22_db_dirs ${root}/db
    lappend tsmc22_db_files \
        ${root}/db/${tsmc22_cell_tier}_cln22ul_base_${flavor}_tt_typical_max_0p80v_25c.db
}
if {$tsmc22_hpk_enabled == 1} {
    if {$tsmc22_cell_tier ne "sc7mcpp140z"} {
        error "TSMC22 HPK component reporting is only valid with sc7mcpp140z"
    }
    foreach flavor $tsmc22_hpk_flavors {
        set root ${TSMC22_KIT}/sc7mcpp140z_hpk_${flavor}/r3p0
        lappend tsmc22_db_dirs ${root}/db
        lappend tsmc22_db_files \
            ${root}/db/sc7mcpp140z_cln22ul_hpk_${flavor}_tt_typical_max_0p80v_25c.db
    }
}
foreach db $tsmc22_db_files {
    if {![file exists $db]} {
        error "Missing TSMC22 component-report library: $db"
    }
}
set search_path [concat $tsmc22_db_dirs $search_path]
set link_library [concat [list "*"] $tsmc22_db_files]
