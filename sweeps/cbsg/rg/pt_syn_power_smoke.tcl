# PrimeTime PX smoke check of the C-BSG RG GL power bench on the SYNTHESIZED netlist: ASTRAEA's
# apr/scripts/power.tcl (the APR phase's `make power_apr`) with the synthesis netlist and SDC in place of the
# routed netlist, and no SPEF (none exists before APR).  It proves the GL SAIF (instance Top/dut) annotates
# the netlist the APR phase will start from; the power number itself is a zero-wire-load figure, not a result.
# Run by sweeps/cbsg/rg/run_syn_gl_checks.sh with cwd = the output directory after sourcing the run's
# TARGET_DEF.  Env: TOP, TECH (=TSMC22), RG_SYN_DIR (synthesis run), SAIF_FILE, SAIF_STRIP_PATH.

set DESIGN_NAME $env(TOP)
set TECH        $env(TECH)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
if {[info exists env(SAIF_STRIP_PATH)] && $env(SAIF_STRIP_PATH) ne ""} {
    set SAIF_STRIP_PATH $env(SAIF_STRIP_PATH)
}
if {$TECH ne "TSMC22"} { puts "ERROR: TSMC22 only"; exit 1 }

proc write_saif_header_report {saif_file out_file} {
    set timescale "UNKNOWN"
    set duration  "UNKNOWN"
    set fh [open $saif_file r]
    for {set i 0} {$i < 200 && [gets $fh line] >= 0} {incr i} {
        if {[regexp {\(TIMESCALE[ \t]+(.+)\)} $line -> val]} {
            set timescale $val
        }
        if {[regexp {\(DURATION[ \t]+([0-9.]+)\)} $line -> val]} {
            set duration $val
        }
        if {$timescale ne "UNKNOWN" && $duration ne "UNKNOWN"} {
            break
        }
    }
    close $fh

    set duration_ns "UNKNOWN"
    if {$duration ne "UNKNOWN" &&
        [regexp {^([0-9.eE+-]+)[ 	]+(fs|ps|ns|us|ms|s)$} $timescale -> scale unit]} {
        switch -- $unit {
            fs { set unit_ns 1.0e-6 }
            ps { set unit_ns 1.0e-3 }
            ns { set unit_ns 1.0 }
            us { set unit_ns 1.0e3 }
            ms { set unit_ns 1.0e6 }
            s  { set unit_ns 1.0e9 }
        }
        set duration_ns [expr {$duration * $scale * $unit_ns}]
    }

    set target_period "UNKNOWN"
    if {[info exists ::env(PERIOD)]} {
        set target_period "$::env(PERIOD) ns"
    }

    set out [open $out_file w]
    puts $out "SAIF_FILE      $saif_file"
    puts $out "SAIF_TIMESCALE $timescale"
    puts $out "SAIF_DURATION_RAW $duration time-units"
    puts $out "SAIF_DURATION_NS  $duration_ns ns"
    puts $out "TARGET_PERIOD  $target_period"
    close $out

    puts "SAIF header: timescale=$timescale duration_ns=$duration_ns target_period=$target_period"
}

set power_enable_analysis        "true"
set power_analysis_mode          "averaged"
set power_model_preference       "ccs"

# Library setup: verbatim from apr/scripts/power.tcl (TSMC22 branch).
# TSMC 22ULL selectable threshold/channel-length flavors, TT @ 0.80V / 25C.
    set KIT_PATH /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
    set cell_tier sc7mcpp140z
    if {[info exists env(TSMC22_CELL_TIER)] && $env(TSMC22_CELL_TIER) ne ""} {
        set cell_tier $env(TSMC22_CELL_TIER)
    }
    switch -- $cell_tier {
        sc7mcpp140z   { set lib_release r3p0 }
        sc6p5mcpp140z { set lib_release r4p0 }
        default {
            puts "ERROR: unsupported TSMC22_CELL_TIER: $cell_tier"
            exit 1
        }
    }
    set lib_flavors [list svt_c30]
    if {[info exists env(TSMC22_LIB_FLAVORS)] && $env(TSMC22_LIB_FLAVORS) ne ""} {
        set lib_flavors [regexp -all -inline {\S+} $env(TSMC22_LIB_FLAVORS)]
    }
    set hpk_flavors $lib_flavors
    if {[info exists env(TSMC22_HPK_FLAVORS)] && $env(TSMC22_HPK_FLAVORS) ne ""} {
        set hpk_flavors [regexp -all -inline {\S+} $env(TSMC22_HPK_FLAVORS)]
    }
    set lib_search [list .]
    set link_library [list "*"]
    foreach flavor $lib_flavors {
        set base_lib ${KIT_PATH}/${cell_tier}_base_${flavor}/${lib_release}
        set base_file ${base_lib}/db/${cell_tier}_cln22ul_base_${flavor}_tt_typical_max_0p80v_25c.db
        if {![file exists $base_file]} {
            puts "ERROR: TSMC22 .db not found: $base_file"
            exit 1
        }
        lappend lib_search ${base_lib}/db
        lappend link_library $base_file
    }
    if {[info exists env(TSMC22_HPK)] && $env(TSMC22_HPK) == 1} {
        if {$cell_tier ne "sc7mcpp140z"} {
            puts "ERROR: TSMC22 HPK is only physically compatible with sc7mcpp140z"
            exit 1
        }
        foreach flavor $hpk_flavors {
            set hpk_lib ${KIT_PATH}/sc7mcpp140z_hpk_${flavor}/r3p0
            set hpk_file ${hpk_lib}/db/sc7mcpp140z_cln22ul_hpk_${flavor}_tt_typical_max_0p80v_25c.db
            if {![file exists $hpk_file]} {
                puts "ERROR: TSMC22 HPK .db not found: $hpk_file"
                exit 1
            }
            lappend lib_search ${hpk_lib}/db
            lappend link_library $hpk_file
        }
    }
    set search_path [concat $lib_search $search_path]

set NETLIST "$env(RG_SYN_DIR)/${DESIGN_NAME}.syn.v"
set SDC     "$env(RG_SYN_DIR)/${DESIGN_NAME}.syn.sdc"
foreach f [list $NETLIST $SDC $SAIF_FILE] {
    if {![file exists $f]} { puts "ERROR: required input not found: $f"; exit 1 }
}

read_verilog $NETLIST
current_design $DESIGN_NAME
link_design
read_sdc $SDC
update_timing -full
check_power

reset_switching_activity
read_saif $SAIF_FILE -strip_path $SAIF_STRIP_PATH

if {[info exists env(ZERO_PINLESS_NET_ACTIVITY)] &&
    $env(ZERO_PINLESS_NET_ACTIVITY) == 1} {
    set pinless_count 0
    foreach_in_collection net [get_nets -hierarchical *] {
        if {[sizeof_collection [get_pins -quiet -of_objects $net]] == 0 &&
            [sizeof_collection [get_ports -quiet -of_objects $net]] == 0} {
            set_switching_activity -static_probability 0.0 -toggle_rate 0.0 $net
            incr pinless_count
        }
    }
    puts "Forced $pinless_count pinless net(s) to static-zero activity"
}

file mkdir reports
write_saif_header_report $SAIF_FILE reports/saif_header.rpt
report_switching_activity -list_not_annotated > reports/saif_coverage.rpt

update_power

report_power -significant_digits 6 -nosplit              > reports/power.rpt
report_power -significant_digits 6 -hier -nosplit        > reports/power_hier.rpt
report_analysis_coverage                       > reports/analysis_coverage.rpt
report_units                                   > reports/units.rpt

# --- Clock-pin split -----------------------------------------------------------
# PrimeTime's power groups fold every flop's clock-pin internal power into the
# clock_network group (see the "i" attribute in power.rpt), so raw "register"
# understates true sequential power and raw "clock_network" overstates clock
# distribution. Recover the split: a cell-based sum over sequential cells INCLUDES
# each flop's clock-pin internal power, whereas the register power GROUP excludes
# it, so their difference is the register clock-pin internal power. Reattributing
# it gives sequential_true = register_group + reg_clkpin and clock_dist =
# clock_network - reg_clkpin (both reconcile to Total). Consumed by
# sweeps/plot_updated_breakdowns.py (parses the reg_clkpin_int line).
set _comb 0.0; set _reg 0.0; set _regint 0.0; set _clk 0.0; set _tot 0.0
redirect -variable _grp { report_power -significant_digits 6 -nosplit }
foreach _l [split $_grp "\n"] {
    if {[regexp {^\s*combinational\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)} $_l -> _a _b _c _d]} { set _comb $_d }
    if {[regexp {^\s*register\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)} $_l -> _a _b _c _d]} { set _regint $_a; set _reg $_d }
    if {[regexp {^\s*clock_network\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)} $_l -> _a _b _c _d]} { set _clk $_d }
    if {[regexp {Total Power\s*=\s*(\S+)} $_l -> _t]} { set _tot $_t }
}
set _seqint 0.0; set _nseq 0
foreach_in_collection _c [all_registers -cells] {
    set _seqint [expr {$_seqint + [get_attribute $_c internal_power]}]
    incr _nseq
}
set _clkpin  [expr {$_seqint - $_regint}]
set _seqtrue [expr {$_reg + $_clkpin}]
set _clkdist [expr {$_clk - $_clkpin}]
proc _mw {x} { return [format "%.4f" [expr {$x * 1000.0}]] }
set _fh [open reports/power_clock_split.rpt w]
puts $_fh "DESIGN            $DESIGN_NAME"
puts $_fh "num_seq_cells     $_nseq"
puts $_fh "--- group report totals (mW) ---"
puts $_fh "combinational     [_mw $_comb]"
puts $_fh "register_group    [_mw $_reg]   (internal [_mw $_regint], EXCLUDES clock pins)"
puts $_fh "clock_network     [_mw $_clk]   (tree cells + register clock pins)"
puts $_fh "TOTAL             [_mw $_tot]"
puts $_fh "--- clock-pin split ---"
puts $_fh "seq_cell_internal [_mw $_seqint]   (cell-based, INCLUDES clock pins)"
puts $_fh "reg_clkpin_int    [_mw $_clkpin]   (= seq_cell_internal - register_group_internal)"
puts $_fh "--- reattributed buckets (mW) ---"
puts $_fh "combinational     [_mw $_comb]"
puts $_fh "sequential_true   [_mw $_seqtrue]   (register_group + reg_clkpin)"
puts $_fh "clock_dist        [_mw $_clkdist]   (clock_network - reg_clkpin)"
puts $_fh "check_sum         [_mw [expr {$_comb + $_seqtrue + $_clkdist}]]   (should equal TOTAL)"
puts $_fh "CSVROW,$DESIGN_NAME,[_mw $_comb],[_mw $_reg],[_mw $_clk],[_mw $_tot],[_mw $_seqint],[_mw $_clkpin],[_mw $_seqtrue],[_mw $_clkdist]"
close $_fh

exit
