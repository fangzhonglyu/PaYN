# Routed PT-PX power of payn_array split by functional class, read only on the route (run by flow/measure.py in a
# point's classes/ directory).  The PT setup is the measurement's (flow/tcl/pt_libraries.tcl, routed netlist, SDC,
# SPEF, the point's SAIF stripped at Top/dut, the pinless-net policy); the total must reproduce the point's
# power.rpt.  Classes, in priority order (every leaf cell in exactly one):
#   u_peripheral  ka_enc (kA encoders), a_regs, w_regs, clk_buf (CTS), ka_in_buf (encoder input buffering),
#                 byp_a / byp_w (combinational cells in the fanout of a_raw_in / w_raw_in: the INT bypass, merged by
#                 DC into the thermometer's and the W comparators' last gates), sel_a / sel_w / sel_both (the other
#                 cells in the fanout of int_mode: bypass select buffering), a_logic (thermometers), w_logic
#                 (W comparators), p_other
#   u_rng         rng_words, clk_buf, rng_ctrl (block clock)
#   u_pe          tiles, clk_buf (CTS), dr_seq (drain-register flops and their clock gate, g_dr*: PAYN_DRAIN = 1
#                 netlists, empty otherwise), dr_mux (the other core cells in the fanin of dr_seq's data and enable
#                 pins: the drain register's 3:1 mux and load enable), core_seq (bit/sign pipes, core clock gates),
#                 dbl_mux (cells in the fanin of the tile acc_in pins and the fanout of a tile acc_out pin: the
#                 per-tile doubling muxes), dbl_sel (the other cells in the fanin of acc_in: the lap select tree),
#                 core_glue, pe_local (ring_q flop, shift_in | ring_q; drain_q / drain_q2)
#   u_combiner    clk_buf, logic (absent in PAYN_DRAIN = 1 netlists: synthesis removes it)
#   top           clk_buf, glue (int_mode_q, MAC guard, ring and capture gates)
# Output lines: PWR_TOTAL, PWR_HIER, PWR_CLASS <scope> <class> <cells> int sw leak tot area, PWR_CHECK, PWR_INFO,
# PWR_OTHER.  Env: ROUTE_DIR, TOP, SAIF_FILE, REF_TOTAL_W (empty: no total check), TSMC22_*.

set DESIGN_NAME $env(TOP)
set R $env(ROUTE_DIR)
set power_enable_analysis "true"
set power_analysis_mode   "averaged"
set power_model_preference "ccs"
source [file join [file dirname [file normalize [info script]]] pt_libraries.tcl]

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

# Cells without power attributes (e.g. tie cells) count as zero (PWR_INFO no_power_attr_cells).
proc attr0 {c a} {
    set v [get_attribute -quiet $c $a]
    if {$v eq ""} { return 0.0 }
    return $v
}
proc psum {cells} {
    set i 0.0; set s 0.0; set l 0.0; set t 0.0; set a 0.0
    if {$cells eq "" || [sizeof_collection $cells] == 0} { return [list $i $s $l $t $a] }
    foreach_in_collection c $cells {
        set i [expr {$i + [attr0 $c internal_power]}]
        set s [expr {$s + [attr0 $c switching_power]}]
        set l [expr {$l + [attr0 $c leakage_power]}]
        set t [expr {$t + [attr0 $c total_power]}]
        set a [expr {$a + [attr0 $c area]}]
    }
    return [list $i $s $l $t $a]
}
proc ncells {cells} { if {$cells eq ""} { return 0 }; return [sizeof_collection $cells] }
proc emit {scope label cells} {
    lassign [psum $cells] i s l t a
    puts [format "PWR_CLASS %s %s %d %.9e %.9e %.9e %.9e %.4f" $scope $label [ncells $cells] $i $s $l $t $a]
}
proc hier {name} {
    set c [get_cells -quiet $name]
    if {[sizeof_collection $c] == 0} { return }
    puts [format "PWR_HIER %s %.9e %.9e %.9e %.9e" $name [get_attribute $c internal_power] \
        [get_attribute $c switching_power] [get_attribute $c leakage_power] [get_attribute $c total_power]]
}
proc leaf {pattern} { return [get_cells -hier * -quiet -filter "full_name=~${pattern} && is_hierarchical==false"] }
proc cone_to {pins} {
    if {$pins eq "" || [sizeof_collection $pins] == 0} { return "" }
    return [filter_collection [all_fanin -to $pins -flat -only_cells] "is_hierarchical==false"]
}
proc cone_from {pins} {
    if {$pins eq "" || [sizeof_collection $pins] == 0} { return "" }
    return [filter_collection [all_fanout -from $pins -flat -only_cells] "is_hierarchical==false"]
}
proc within {a b} {
    if {$a eq "" || $b eq "" || [sizeof_collection $a] == 0 || [sizeof_collection $b] == 0} { return "" }
    return [remove_from_collection $a [remove_from_collection $a $b]]
}
proc minus {a b} {
    if {$a eq "" || [sizeof_collection $a] == 0} { return "" }
    if {$b eq "" || [sizeof_collection $b] == 0} { return $a }
    return [remove_from_collection $a $b]
}
proc comb {cells} {
    if {$cells eq "" || [sizeof_collection $cells] == 0} { return "" }
    return [filter_collection $cells "is_sequential==false"]
}
proc named {cells prefixes} {
    set out ""
    foreach p $prefixes { set out [add_to_collection $out [filter_collection $cells "full_name=~*/${p}*"] -unique] }
    return $out
}

set all_leaf [get_cells -hier * -filter "is_hierarchical==false"]
set nopwr {}
foreach_in_collection c $all_leaf {
    if {[get_attribute -quiet $c total_power] eq ""} { lappend nopwr "[get_attribute $c full_name]:[get_attribute $c ref_name]" }
}
puts "PWR_INFO no_power_attr_cells [llength $nopwr] [lrange $nopwr 0 9]"
lassign [psum $all_leaf] i s l t a
puts [format "PWR_CHECK leaf_sum %.9e port_nets_switching %.9e" $t [expr {$total - $t}]]
foreach h [list u_pe u_peripheral u_rng u_combiner] { hier $h }

set clk_net [filter_collection [all_fanout -clock_tree -flat -only_cells] "is_hierarchical==false"]
set clk_comb [filter_collection $clk_net "is_sequential==false && is_integrated_clock_gating_cell!=true"]
puts "PWR_INFO clock_network_leaf_cells [sizeof_collection $clk_net] clock_buffers [sizeof_collection $clk_comb]"

# ---- u_peripheral ----
set p_all [leaf "u_peripheral/*"]
puts "PWR_INFO u_peripheral_leaf_cells [sizeof_collection $p_all]"
set rest $p_all
set enc [leaf "u_peripheral/*u_ka/*"]
set rest [minus $rest $enc]
emit u_peripheral ka_enc $enc
puts "PWR_INFO ka_enc_instances [sizeof_collection [get_cells -hier * -filter {full_name=~u_peripheral/*u_ka && is_hierarchical==true}]]"
set a_seq [named $rest {a_binary_q a_signs_q a_len_q clk_gate_a_}]
set a_seq [filter_collection $a_seq "is_sequential==true || full_name=~*clk_gate_a_*"]
set w_seq [named $rest {w_binary_q w_signs_q clk_gate_w_}]
set w_seq [filter_collection $w_seq "is_sequential==true || full_name=~*clk_gate_w_*"]
set rest [minus $rest $a_seq]
set rest [minus $rest $w_seq]
emit u_peripheral a_regs $a_seq
emit u_peripheral w_regs $w_seq
set pclk [within $rest $clk_comb]
set rest [minus $rest $pclk]
emit u_peripheral clk_buf $pclk
set enc_in [get_pins -hier * -filter "full_name=~u_peripheral/*u_ka/* && pin_direction==in"]
set kin [within [comb [cone_to $enc_in]] $rest]
set rest [minus $rest $kin]
emit u_peripheral ka_in_buf $kin
set a_cone [filter_collection [cone_to [get_pins u_peripheral/a_bits*]] "full_name=~u_peripheral/*"]
set w_cone [filter_collection [cone_to [get_pins u_peripheral/w_bits*]] "full_name=~u_peripheral/*"]
set araw [get_pins -quiet u_peripheral/a_raw_in*]
set wraw [get_pins -quiet u_peripheral/w_raw_in*]
set imode [get_pins -quiet u_peripheral/int_mode]
puts "PWR_INFO a_raw_in_pins [ncells $araw] w_raw_in_pins [ncells $wraw] int_mode_pins [ncells $imode]"
set byp_a [within [comb [filter_collection [cone_from $araw] "full_name=~u_peripheral/*"]] $rest]
set rest [minus $rest $byp_a]
set byp_w [within [comb [filter_collection [cone_from $wraw] "full_name=~u_peripheral/*"]] $rest]
set rest [minus $rest $byp_w]
set sel [within [comb [filter_collection [cone_from $imode] "full_name=~u_peripheral/*"]] $rest]
set sel_a [minus [within $sel $a_cone] $w_cone]
set sel_w [minus [within $sel $w_cone] $a_cone]
set sel_both [minus [minus $sel $sel_a] $sel_w]
set rest [minus $rest $sel]
emit u_peripheral byp_a $byp_a
emit u_peripheral byp_w $byp_w
emit u_peripheral sel_a $sel_a
emit u_peripheral sel_w $sel_w
emit u_peripheral sel_both $sel_both
set a_logic [within $rest $a_cone]
set w_logic [within $rest $w_cone]
set both [within $a_logic $w_logic]
puts "PWR_INFO a_logic_w_logic_overlap_cells [ncells $both] (assigned to a_logic)"
set w_logic [minus $w_logic $both]
set rest [minus $rest $a_logic]
set rest [minus $rest $w_logic]
emit u_peripheral a_logic $a_logic
emit u_peripheral w_logic $w_logic
emit u_peripheral p_other $rest
set n 0
if {$rest ne "" && [sizeof_collection $rest] > 0} {
    foreach_in_collection c [sort_collection [filter_collection $rest "defined(total_power)"] total_power -descending] {
        if {[incr n] > 15} break
        puts [format "PWR_OTHER %s %s %.4e" [get_attribute $c full_name] [get_attribute $c ref_name] [attr0 $c total_power]]
    }
}
emit u_peripheral ALL $p_all

# ---- block clock ----
set g_all [leaf "u_rng/*"]
set g_words [within $g_all [cone_to [get_pins u_rng/w_words*]]]
set g_clk [minus [within $g_all $clk_comb] $g_words]
emit u_rng rng_words $g_words
emit u_rng clk_buf $g_clk
emit u_rng rng_ctrl [minus [minus $g_all $g_words] $g_clk]
emit u_rng ALL $g_all

# ---- PE ----
set core u_pe/u_array_core
set pe_all [leaf "u_pe/*"]
set core_all [leaf "${core}/*"]
set tiles [leaf "${core}/g_row_*__g_col_*__u_inner/*"]
emit u_pe tiles $tiles
set pe_rest [minus $pe_all $tiles]
set pe_clk [within $pe_rest $clk_comb]
emit u_pe clk_buf $pe_clk
set core_loc [minus [minus $core_all $tiles] $pe_clk]
set dr_seq ""
if {$core_loc ne "" && [sizeof_collection $core_loc] > 0} {
    set dr_seq [filter_collection $core_loc "full_name=~${core}/g_dr_* || full_name=~${core}/*clk_gate_g_dr_*"]
}
set core_loc [minus $core_loc $dr_seq]
set core_seq [filter_collection $core_loc "is_sequential==true || full_name=~*clk_gate_*"]
set core_comb [minus $core_loc $core_seq]
set dr_mux ""
if {$dr_seq ne "" && [sizeof_collection $dr_seq] > 0} {
    set dr_in [get_pins -quiet -of_objects $dr_seq -filter "direction==in && is_clock_pin==false"]
    set dr_mux [within [cone_to $dr_in] $core_comb]
    set core_comb [minus $core_comb $dr_mux]
}
puts "PWR_INFO drain_register_cells [ncells $dr_seq] seq [ncells $dr_mux] mux"
emit u_pe dr_seq $dr_seq
emit u_pe dr_mux $dr_mux
emit u_pe core_seq $core_seq
set acc_in_pins [get_pins -quiet "${core}/g_row_*__g_col_*__u_inner/acc_in*"]
set acc_out_pins [get_pins -quiet "${core}/g_row_*__g_col_*__u_inner/acc_out*"]
puts "PWR_INFO tile_acc_in_pins [ncells $acc_in_pins] acc_out_pins [ncells $acc_out_pins]"
set acc_in_cone [within [cone_to $acc_in_pins] $core_comb]
set dbl_mux [within $acc_in_cone [cone_from $acc_out_pins]]
set dbl_sel [minus $acc_in_cone $dbl_mux]
emit u_pe dbl_mux $dbl_mux
emit u_pe dbl_sel $dbl_sel
emit u_pe core_glue [minus [minus $core_comb $dbl_mux] $dbl_sel]
emit u_pe pe_local [minus [minus $pe_all $core_all] $pe_clk]
emit u_pe ALL $pe_all

# ---- combiner ----
set c_all [leaf "u_combiner/*"]
set c_clk [within $c_all $clk_comb]
emit u_combiner clk_buf $c_clk
emit u_combiner logic [minus $c_all $c_clk]
emit u_combiner ALL $c_all

# ---- top ----
set top_leaf [filter_collection $all_leaf "full_name!~u_pe/* && full_name!~u_peripheral/* && full_name!~u_rng/* && full_name!~u_combiner/*"]
set top_clk [within $top_leaf $clk_comb]
emit top clk_buf $top_clk
emit top glue [minus $top_leaf $top_clk]
emit top ALL_LEAF $all_leaf
emit top CLOCK_BUFFERS_ALL $clk_comb
exit
