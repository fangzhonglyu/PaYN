# Routed PT-PX power of the C-BSG AF array (or, for comparison, the CSA baseline) split by functional class:
# the block classes of sweeps/cbsg/af/dc_af_probe.tcl (area), applied to the routed netlist in PrimeTime.
#
# Why a separate pass: u_peripheral is flat in both netlists apart from AF's 64 kA encoders, so the hierarchical
# power report cannot separate the A edge (registers, encoders, thermometer / CSA A comparators) from the W edge
# (registers, W comparators).  This script reproduces the route's PT run exactly (same libraries, netlist, SDC,
# SPEF, SAIF, pinless-net policy, as ASTRAEA apr/scripts/power.tcl), checks that the total equals the route's
# power.rpt, then sums PT's per-cell power attributes over each class.  Nothing in the route directory is written:
# run it with cwd = an output directory (sweeps/cbsg/af/run_pt_power_classes.sh does).
#
# env: ROUTE_DIR (APR run dir), TOP, SAIF_FILE, KIND (af|csa), REF_TOTAL_W (the route power.rpt Total Power, W),
#      TSMC22_* as for make power_apr.
# Leaf-cell classes inside u_peripheral (priority order, first match wins; as dc_af_probe.tcl plus clk_buf):
#   ka_enc      AF: leaf cells inside the 64 CbsgAfKaEncoder instances (*u_ka)
#   a_regs      sequential cells / clock gates named a_* or clk_gate_a_* (A magnitude, sign, AF per-row L)
#   w_regs      sequential cells / clock gates named w_* or clk_gate_w_*
#   clk_buf     clock-tree buffers/inverters that Innovus CTS placed in u_peripheral (routed netlist only)
#   ka_in_buf   AF: combinational cells outside the encoders in the fan-in of encoder inputs
#   a_logic     combinational cells in the fan-in of u_peripheral/a_bits*: AF thermometer; CSA 1,024 A comparators
#   w_logic     combinational cells in the fan-in of u_peripheral/w_bits*: the 1,024 W comparators (+ buffering)
#   p_other     the rest (reset buffers, tie cells, ...)
# AF u_rng: rng_words (fan-in of w_words incl. the word registers), clk_buf, rng_ctrl (counter, phase, slice restart).
# A cell's power is PT's cell attribute: internal + leakage + switching of the nets its outputs drive, so the
# switching power of nets driven by input ports belongs to no cell (reported as port_nets).
# Output lines: PWR_TOTAL, PWR_HIER <cell> int sw leak tot, PWR_CLASS <scope> <class> <cells> int sw leak tot,
# PWR_CHECK ..., PWR_INFO ...  (watts; the last PWR_CLASS field is the cells' area, um2)

set DESIGN_NAME $env(TOP)
set R $env(ROUTE_DIR)
set kind $env(KIND)
set power_enable_analysis "true"
set power_analysis_mode   "averaged"
set power_model_preference "ccs"

# ---- library setup: ASTRAEA apr/scripts/power.tcl, TSMC22 branch ----
set KIT_PATH /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4
set cell_tier sc7mcpp140z
if {[info exists env(TSMC22_CELL_TIER)] && $env(TSMC22_CELL_TIER) ne ""} { set cell_tier $env(TSMC22_CELL_TIER) }
if {$cell_tier ne "sc7mcpp140z"} { puts "ERROR: only sc7mcpp140z is supported here"; exit 1 }
set lib_release r3p0
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
    if {![file exists $base_file]} { puts "ERROR: TSMC22 .db not found: $base_file"; exit 1 }
    lappend lib_search ${base_lib}/db
    lappend link_library $base_file
}
if {[info exists env(TSMC22_HPK)] && $env(TSMC22_HPK) == 1} {
    foreach flavor $hpk_flavors {
        set hpk_lib ${KIT_PATH}/sc7mcpp140z_hpk_${flavor}/r3p0
        set hpk_file ${hpk_lib}/db/sc7mcpp140z_cln22ul_hpk_${flavor}_tt_typical_max_0p80v_25c.db
        if {![file exists $hpk_file]} { puts "ERROR: TSMC22 HPK .db not found: $hpk_file"; exit 1 }
        lappend lib_search ${hpk_lib}/db
        lappend link_library $hpk_file
    }
}
set search_path [concat $lib_search $search_path]

read_verilog $R/outputs/${DESIGN_NAME}.apr.v
current_design $DESIGN_NAME
link_design
read_sdc $R/${DESIGN_NAME}.syn.sdc
read_parasitics -format SPEF $R/outputs/${DESIGN_NAME}.spef
update_timing -full
reset_switching_activity
read_saif $env(SAIF_FILE) -strip_path Top/dut
if {[info exists env(ZERO_PINLESS_NET_ACTIVITY)] && $env(ZERO_PINLESS_NET_ACTIVITY) == 1} {
    set pinless_count 0
    foreach_in_collection net [get_nets -hierarchical *] {
        if {[sizeof_collection [get_pins -quiet -of_objects $net]] == 0 &&
            [sizeof_collection [get_ports -quiet -of_objects $net]] == 0} {
            set_switching_activity -static_probability 0.0 -toggle_rate 0.0 $net
            incr pinless_count
        }
    }
    puts "PWR_INFO pinless_nets_forced_static $pinless_count"
}
update_power
redirect -variable rpt { report_power -significant_digits 6 -nosplit }
regexp {Total Power\s*=\s*(\S+)} $rpt -> total
regexp {Net Switching Power\s*=\s*(\S+)} $rpt -> total_sw
puts "PWR_TOTAL $total"
puts "PWR_TOTAL_SWITCHING $total_sw"
if {[info exists env(REF_TOTAL_W)] && $env(REF_TOTAL_W) ne ""} {
    set rel [expr {abs($total - $env(REF_TOTAL_W)) / $env(REF_TOTAL_W)}]
    puts [format "PWR_CHECK total_vs_route_power_rpt %s %s rel %.3g" $total $env(REF_TOTAL_W) $rel]
    if {$rel > 1e-5} { puts "ERROR: PT total $total differs from the route's power.rpt $env(REF_TOTAL_W)"; exit 1 }
}

# Cells without power attributes (cells PT has no power data for, e.g. tie cells) count as zero; they are
# counted in PWR_INFO no_power_attr_cells.
proc attr0 {c a} {
    set v [get_attribute -quiet $c $a]
    if {$v eq ""} { return 0.0 }
    return $v
}
proc psum {cells} {
    set i 0.0; set s 0.0; set l 0.0; set t 0.0; set a 0.0
    foreach_in_collection c $cells {
        set i [expr {$i + [attr0 $c internal_power]}]
        set s [expr {$s + [attr0 $c switching_power]}]
        set l [expr {$l + [attr0 $c leakage_power]}]
        set t [expr {$t + [attr0 $c total_power]}]
        set a [expr {$a + [attr0 $c area]}]
    }
    return [list $i $s $l $t $a]
}
proc emit {scope label cells} {
    lassign [psum $cells] i s l t a
    puts [format "PWR_CLASS %s %s %d %.9e %.9e %.9e %.9e %.4f" $scope $label [sizeof_collection $cells] $i $s $l $t $a]
}
proc hier {name} {
    set c [get_cells -quiet $name]
    if {[sizeof_collection $c] == 0} { return }
    puts [format "PWR_HIER %s %.9e %.9e %.9e %.9e" $name [get_attribute $c internal_power] \
        [get_attribute $c switching_power] [get_attribute $c leakage_power] [get_attribute $c total_power]]
}
proc leaf {pattern} { return [get_cells -hier * -quiet -filter "full_name=~${pattern} && is_hierarchical==false"] }
proc cone_to {pins} { return [filter_collection [all_fanin -to $pins -flat -only_cells] "is_hierarchical==false"] }
proc intersect {a b} { return [remove_from_collection $a [remove_from_collection $a $b]] }

set all_leaf [get_cells -hier * -filter "is_hierarchical==false"]
set nopwr {}
foreach_in_collection c $all_leaf {
    if {[get_attribute -quiet $c total_power] eq ""} { lappend nopwr "[get_attribute $c full_name]:[get_attribute $c ref_name]" }
}
puts "PWR_INFO no_power_attr_cells [llength $nopwr] [lrange $nopwr 0 9]"
lassign [psum $all_leaf] i s l t a
puts [format "PWR_CHECK leaf_sum %.9e port_nets_switching %.9e" $t [expr {$total - $t}]]
foreach h [list u_pe u_peripheral u_rng u_a_rng u_w_rng] { hier $h }

# Clock network cells (CTS buffers/inverters and clock gates), from the clock sources to the register clock pins.
set clk_net [filter_collection [all_fanout -clock_tree -flat -only_cells] "is_hierarchical==false"]
set clk_comb [filter_collection $clk_net "is_sequential==false && is_integrated_clock_gating_cell!=true"]
puts "PWR_INFO clock_network_leaf_cells [sizeof_collection $clk_net] clock_buffers [sizeof_collection $clk_comb]"

# ---- u_peripheral ----
set p_all [leaf "u_peripheral/*"]
puts "PWR_INFO u_peripheral_leaf_cells [sizeof_collection $p_all]"
set rest $p_all
if {$kind eq "af"} {
    set enc [leaf "u_peripheral/*u_ka/*"]
    set rest [remove_from_collection $rest $enc]
    emit u_peripheral ka_enc $enc
    puts "PWR_INFO ka_enc_instances [sizeof_collection [get_cells -hier * -filter {full_name=~u_peripheral/*u_ka && is_hierarchical==true}]]"
} else {
    set enc ""
}
set seq [filter_collection $rest "is_sequential==true"]
set a_seq [filter_collection $seq "full_name=~u_peripheral/a_* || full_name=~u_peripheral/clk_gate_a_*"]
set w_seq [filter_collection $seq "full_name=~u_peripheral/w_* || full_name=~u_peripheral/clk_gate_w_*"]
set a_seq [add_to_collection $a_seq [filter_collection $rest "full_name=~u_peripheral/clk_gate_a_*"] -unique]
set w_seq [add_to_collection $w_seq [filter_collection $rest "full_name=~u_peripheral/clk_gate_w_*"] -unique]
set rest [remove_from_collection $rest $a_seq]
set rest [remove_from_collection $rest $w_seq]
emit u_peripheral a_regs $a_seq
emit u_peripheral w_regs $w_seq
set pclk [intersect $rest $clk_comb]
set rest [remove_from_collection $rest $pclk]
emit u_peripheral clk_buf $pclk
if {$kind eq "af"} {
    set enc_in [get_pins -hier * -filter "full_name=~u_peripheral/*u_ka/* && pin_direction==in"]
    set kin [intersect $rest [cone_to $enc_in]]
    set kin [filter_collection $kin "is_sequential==false"]
    set rest [remove_from_collection $rest $kin]
    emit u_peripheral ka_in_buf $kin
}
set a_cone [cone_to [get_pins u_peripheral/a_bits*]]
set w_cone [cone_to [get_pins u_peripheral/w_bits*]]
set a_logic [intersect $rest $a_cone]
set w_logic [intersect $rest $w_cone]
set both [intersect $a_logic $w_logic]
puts "PWR_INFO a_logic_w_logic_overlap_cells [sizeof_collection $both] (assigned to a_logic)"
set w_logic [remove_from_collection $w_logic $both]
set rest [remove_from_collection $rest $a_logic]
set rest [remove_from_collection $rest $w_logic]
emit u_peripheral a_logic $a_logic
emit u_peripheral w_logic $w_logic
emit u_peripheral p_other $rest
set n 0
foreach_in_collection c [sort_collection [filter_collection $rest "defined(total_power)"] total_power -descending] {
    if {[incr n] > 15} break
    puts [format "PWR_OTHER %s %s %.4e" [get_attribute $c full_name] [get_attribute $c ref_name] [attr0 $c total_power]]
}
emit u_peripheral ALL $p_all

# ---- stream generators ----
if {$kind eq "af"} {
    set g_all [leaf "u_rng/*"]
    set g_words [intersect $g_all [cone_to [get_pins u_rng/w_words*]]]
    set g_clk [remove_from_collection [intersect $g_all $clk_comb] $g_words]
    emit u_rng rng_words $g_words
    emit u_rng clk_buf $g_clk
    emit u_rng rng_ctrl [remove_from_collection [remove_from_collection $g_all $g_words] $g_clk]
    emit u_rng ALL $g_all
} else {
    emit u_a_rng ALL [leaf "u_a_rng/*"]
    emit u_w_rng ALL [leaf "u_w_rng/*"]
}

# ---- PE core and top ----
set tiles [leaf "u_pe/u_array_core/g_row_*__g_col_*__u_inner/*"]
set pe_all [leaf "u_pe/*"]
emit u_pe tiles $tiles
set pe_rest [remove_from_collection $pe_all $tiles]
set pe_clk [intersect $pe_rest $clk_comb]
emit u_pe clk_buf $pe_clk
emit u_pe pipes_glue [remove_from_collection $pe_rest $pe_clk]
emit u_pe ALL $pe_all
# Everything outside the named blocks: top-level leaf cells and leaf cells of top-level hierarchical wrappers
# (e.g. a top-level SNPS_CLOCK_GATE).
set top_leaf [filter_collection $all_leaf "full_name!~u_pe/* && full_name!~u_peripheral/* && full_name!~u_rng/* && full_name!~u_a_rng/* && full_name!~u_w_rng/*"]
set top_clk [intersect $top_leaf $clk_comb]
emit top clk_buf $top_clk
emit top glue [remove_from_collection $top_leaf $top_clk]
emit top ALL_LEAF $all_leaf
emit top CLOCK_BUFFERS_ALL $clk_comb
exit
