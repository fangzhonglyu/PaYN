# Post-synthesis area classes and timing probes for the C-BSG AF array with bit-plane INT mode and in-place
# doubling (payn_array_signed_segmented_csa_cbsg_af_ipd), written so that the SAME script also classes the
# reference netlists: AF (payn_array_signed_segmented_csa_cbsg_af), IPD (payn_array_signed_segmented_csa_bp_ipd)
# and CSA (payn_array_signed_segmented_csa).  Adapted from sweeps/cbsg/af/dc_af_probe.tcl (area classes, AF
# timing probes) and sweeps/int_mode/bp/ipd/dc_bp_ipd_new_paths.tcl (lap / ring / combiner probes); both are
# unchanged.  Run by sweeps/cbsg/af_ipd/run_syn_reports.sh from build/cbsg/af_ipd/syn/<target>_<run>/ after
# sourcing the run's TARGET_DEF; reads the written netlist and SDC from PROBE_RUN_DIR and never writes into a
# synthesis run directory.
#
# Area: every leaf cell of the design is put in exactly one class (first match wins), printed as
#   AREA_CLASS <class> <cells> <area_um2>   and   AREA_REFS <class> <ref>:<count> ... (cell mix)
# u_peripheral (every netlist; leaf cells at any depth below it):
#   ka_enc      leaf cells inside the 64 kA encoders (*u_ka)                               AF, AF-IPD
#   a_regs      sequential cells / clock-gate latches of a_binary_q, a_signs_q, a_len_q, clk_gate_a_*
#   w_regs      the same for w_binary_q, w_signs_q, clk_gate_w_*
#   ka_in_buf   combinational cells outside the encoders in the fanin of encoder input pins AF, AF-IPD
#   byp_a       combinational cells in the fanout of the a_raw_in pins (INT bypass gates)  IPD, AF-IPD
#   byp_w       combinational cells in the fanout of the w_raw_in pins                     IPD, AF-IPD
#   sel_a/sel_w/sel_both  remaining combinational cells in the fanout of the int_mode pin (bypass select
#               buffering), by which bit cone (a_bits / w_bits / both) they feed            IPD, AF-IPD
#   a_logic     remaining combinational cells in the fanin of a_bits: AF thermometer decode, CSA/IPD the
#               1,024 A comparators
#   w_logic     remaining combinational cells in the fanin of w_bits: the 1,024 W comparators
#   p_other     anything else in u_peripheral (listed, AREA_OTHER)
# u_pe:
#   tiles       leaf cells inside the 64 u_inner tiles
#   core_seq    core-local sequential cells: bit/sign pipes, load_*_sign_q, core clock gates (incl. the
#               shared tile acc clock gate DC places at core level)
#   dbl_mux     core-local combinational cells in the fanin of the tile acc_in pins AND in the fanout of a
#               tile acc_out pin: the per-tile doubling muxes (acc_in = lap ? own << 1 : west)       IPD, AF-IPD
#   dbl_sel     the other core-local combinational cells in the fanin of the tile acc_in pins: the lap
#               select tree (ring_q / lap buffering)                                              IPD, AF-IPD
#   core_glue   the other core-local combinational cells
#   pe_local    leaf cells of u_pe outside u_array_core (IPD wrapper: ring_q flop, shift_in | ring_q OR2)
# rest:
#   rng         AF / AF-IPD u_rng (AF block clock: counter, phase, slice restart, lane words); CSA / IPD
#               u_a_rng + u_w_rng (rng_a, rng_w)
#   combiner    u_combiner (IPD, AF-IPD)
#   top_glue    top-level leaf cells (AF-IPD / IPD: int_mode_q, int_mode_q2, MAC guard, ring gate,
#               combiner capture gate; listed, AREA_TOP)
#
# Timing: PROBE_PATH <label> followed by report_timing -max_paths 1 (labels are the same in every netlist;
# a probe whose objects do not exist prints PROBE_NA).
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
read_verilog -netlist $env(PROBE_RUN_DIR)/$env(TOP).syn.v
current_design $env(TOP)
link
read_sdc $env(PROBE_RUN_DIR)/$env(TOP).syn.sdc
set kind $env(PROBE_KIND)
set core u_pe/u_array_core
puts "PROBE_KIND $kind $env(TOP) $env(PROBE_RUN_DIR)"

proc sum_area {cells} {
    set a 0.0
    foreach_in_collection c $cells { set a [expr {$a + [get_attribute $c area]}] }
    return $a
}
proc refs {cells} {
    set h [dict create]
    foreach_in_collection c $cells { dict incr h [get_attribute $c ref_name] }
    set out {}
    foreach {k v} $h { lappend out [list $k $v] }
    set out [lsort -integer -decreasing -index 1 $out]
    set s ""
    foreach kv [lrange $out 0 11] { append s " [lindex $kv 0]:[lindex $kv 1]" }
    if {[llength $out] > 12} { append s " (+[expr {[llength $out] - 12}] more refs)" }
    return $s
}
proc emit {label cells} {
    puts [format "AREA_CLASS %s %d %.4f" $label [sizeof_collection $cells] [sum_area $cells]]
    puts "AREA_REFS $label[refs $cells]"
}
proc leaf {pattern} {
    return [get_cells -hier * -filter "full_name=~${pattern} && is_hierarchical==false"]
}
proc cone_to {pins} {
    if {[sizeof_collection $pins] == 0} { return "" }
    return [filter_collection [all_fanin -to $pins -flat -only_cells] "is_hierarchical==false"]
}
proc cone_from {pins} {
    if {[sizeof_collection $pins] == 0} { return "" }
    return [filter_collection [all_fanout -from $pins -flat -only_cells] "is_hierarchical==false"]
}
proc within {cells set} {
    # cells that are also in set
    if {[sizeof_collection $cells] == 0 || [sizeof_collection $set] == 0} { return "" }
    return [remove_from_collection $cells [remove_from_collection $cells $set]]
}
proc minus {cells set} {
    if {[sizeof_collection $cells] == 0} { return "" }
    if {[sizeof_collection $set] == 0} { return $cells }
    return [remove_from_collection $cells $set]
}
proc comb {cells} {
    if {[sizeof_collection $cells] == 0} { return "" }
    return [filter_collection $cells "is_sequential==false"]
}
proc named {cells prefixes} {
    # cells whose full name has a path component starting with one of prefixes
    set out ""
    foreach p $prefixes {
        set c [filter_collection $cells "full_name=~*/${p}*"]
        set out [add_to_collection $out $c -unique]
    }
    return $out
}

set all_leaf [get_cells -hier * -filter "is_hierarchical==false"]
puts "AREA_TOTAL design [sizeof_collection $all_leaf] [sum_area $all_leaf]"

#------------------------------------------------------- u_peripheral --
set p_all [leaf "u_peripheral/*"]
puts "AREA_TOTAL u_peripheral [sizeof_collection $p_all] [sum_area $p_all]"
set rest $p_all

set enc [leaf "u_peripheral/*u_ka/*"]
if {[sizeof_collection $enc] > 0} {
    set rest [minus $rest $enc]
    puts "AREA_INFO ka_enc instances [sizeof_collection [get_cells -hier * -filter {full_name=~u_peripheral/*u_ka && is_hierarchical==true}]]"
}
emit ka_enc $enc

# Sequential cells and clock-gate latches by register name (clock-gate wrappers are hierarchical, their latch
# leaf sits below clk_gate_*, so match any path component).
set a_seq [named $rest {a_binary_q a_signs_q a_len_q clk_gate_a_}]
set a_seq [filter_collection $a_seq "is_sequential==true || full_name=~*clk_gate_a_*"]
set w_seq [named $rest {w_binary_q w_signs_q clk_gate_w_}]
set w_seq [filter_collection $w_seq "is_sequential==true || full_name=~*clk_gate_w_*"]
set rest [minus $rest $a_seq]
set rest [minus $rest $w_seq]
emit a_regs $a_seq
emit w_regs $w_seq
set p_seq [filter_collection $p_all "is_sequential==true"]
foreach r {a_binary_q a_signs_q a_len_q w_binary_q w_signs_q} {
    set c [filter_collection $p_seq "full_name=~*/${r}_reg*"]
    puts [format "AREA_REG %s %d %.4f" $r [sizeof_collection $c] [sum_area $c]]
}

set kin ""
if {[sizeof_collection $enc] > 0} {
    set enc_in [get_pins -hier * -filter "full_name=~u_peripheral/*u_ka/* && pin_direction==in"]
    set kin [within [comb [cone_to $enc_in]] $rest]
    set rest [minus $rest $kin]
}
emit ka_in_buf $kin

set a_pins [get_pins u_peripheral/a_bits*]
set w_pins [get_pins u_peripheral/w_bits*]
puts "AREA_INFO a_bits pins [sizeof_collection $a_pins] w_bits pins [sizeof_collection $w_pins]"
set a_cone [filter_collection [cone_to $a_pins] "full_name=~u_peripheral/*"]
set w_cone [filter_collection [cone_to $w_pins] "full_name=~u_peripheral/*"]

# INT bypass: a_bits = sc_a_bits | (a_raw_in & int_mode), w_bits likewise.
set araw [get_pins -quiet u_peripheral/a_raw_in*]
set wraw [get_pins -quiet u_peripheral/w_raw_in*]
set imode [get_pins -quiet u_peripheral/int_mode]
puts "AREA_INFO a_raw_in pins [sizeof_collection $araw] w_raw_in pins [sizeof_collection $wraw] int_mode pins [sizeof_collection $imode]"
set byp_a [within [comb [filter_collection [cone_from $araw] "full_name=~u_peripheral/*"]] $rest]
set rest [minus $rest $byp_a]
set byp_w [within [comb [filter_collection [cone_from $wraw] "full_name=~u_peripheral/*"]] $rest]
set rest [minus $rest $byp_w]
set sel [within [comb [filter_collection [cone_from $imode] "full_name=~u_peripheral/*"]] $rest]
set sel_a [minus [within $sel $a_cone] $w_cone]
set sel_w [minus [within $sel $w_cone] $a_cone]
set sel_both [minus [minus $sel $sel_a] $sel_w]
set rest [minus $rest $sel]
emit byp_a $byp_a
emit byp_w $byp_w
emit sel_a $sel_a
emit sel_w $sel_w
emit sel_both $sel_both

set a_logic [within $rest $a_cone]
set w_logic [within $rest $w_cone]
set both [within $a_logic $w_logic]
puts "AREA_INFO a_logic/w_logic overlap cells [sizeof_collection $both]"
set w_logic [minus $w_logic $both]
set rest [minus $rest $a_logic]
set rest [minus $rest $w_logic]
emit a_logic $a_logic
emit w_logic $w_logic
emit p_other $rest
foreach_in_collection c $rest {
    puts "AREA_OTHER [get_attribute $c full_name] [get_attribute $c ref_name] [get_attribute $c area]"
}

#--------------------------------------------------------------- u_pe --
set pe_all [leaf "u_pe/*"]
set core_all [leaf "${core}/*"]
set tiles [leaf "${core}/*u_inner/*"]
puts "AREA_TOTAL u_pe [sizeof_collection $pe_all] [sum_area $pe_all]"
emit tiles $tiles
set core_loc [minus $core_all $tiles]
set core_seq [filter_collection $core_loc "is_sequential==true || full_name=~*clk_gate_*"]
set core_comb [minus $core_loc $core_seq]
emit core_seq $core_seq
set acc_in_pins [get_pins -quiet "${core}/g_row_*__g_col_*__u_inner/acc_in*"]
set acc_out_pins [get_pins -quiet "${core}/g_row_*__g_col_*__u_inner/acc_out*"]
puts "AREA_INFO tile acc_in pins [sizeof_collection $acc_in_pins] acc_out pins [sizeof_collection $acc_out_pins]"
set acc_in_cone [within [cone_to $acc_in_pins] $core_comb]
set dbl_mux [within $acc_in_cone [cone_from $acc_out_pins]]
set dbl_sel [minus $acc_in_cone $dbl_mux]
set core_glue [minus [minus $core_comb $dbl_mux] $dbl_sel]
emit dbl_mux $dbl_mux
emit dbl_sel $dbl_sel
emit core_glue $core_glue
foreach_in_collection c $core_glue {
    puts "AREA_CORE_GLUE [get_attribute $c full_name] [get_attribute $c ref_name] [get_attribute $c area]"
}
set pe_local [minus $pe_all $core_all]
emit pe_local $pe_local
foreach_in_collection c $pe_local {
    puts "AREA_PE_LOCAL [get_attribute $c full_name] [get_attribute $c ref_name] [get_attribute $c area]"
}
set seq_pipes [filter_collection $core_seq "full_name=~*_pipe_reg* && is_sequential==true"]
puts [format "AREA_REG bit_sign_pipes %d %.4f" [sizeof_collection $seq_pipes] [sum_area $seq_pipes]]

#--------------------------------------------------------------- rest --
emit rng [leaf "u_rng/*"]
emit rng_a [leaf "u_a_rng/*"]
emit rng_w [leaf "u_w_rng/*"]
if {[sizeof_collection [leaf "u_rng/*"]] > 0} {
    set g_all [leaf "u_rng/*"]
    set g_words [within [cone_to [get_pins u_rng/w_words*]] $g_all]
    emit rng_words $g_words
    emit rng_ctrl [minus $g_all $g_words]
}
emit combiner [leaf "u_combiner/*"]
# top glue: top-level leaf cells plus leaf cells of top-level clock-gate wrappers (everything outside the
# named blocks)
set classed [add_to_collection $p_all $pe_all]
foreach h {u_rng/* u_a_rng/* u_w_rng/* u_combiner/*} { set classed [add_to_collection $classed [leaf $h]] }
set top_leaf [minus $all_leaf $classed]
emit top_glue $top_leaf
foreach_in_collection c $top_leaf {
    puts "AREA_TOP [get_attribute $c full_name] [get_attribute $c ref_name] [get_attribute $c area]"
}
set unclassed [minus $all_leaf [add_to_collection $classed $top_leaf]]
emit unclassed $unclassed

#---------------------------------------------------------------- timing --
proc seq_cells {pattern} {
    return [get_cells -quiet -hier * -filter "full_name=~${pattern} && is_sequential==true"]
}
proc clk_pins {cells} {
    if {[sizeof_collection $cells] == 0} { return "" }
    return [get_pins -of_objects $cells -filter "name==CK"]
}
proc data_pins {cells} {
    if {[sizeof_collection $cells] == 0} { return "" }
    return [get_pins -of_objects $cells -filter "pin_direction==in && name!=CK && name!=SE && name!=SI"]
}
# probe label ?-from X? ?-through Y? ?-to Z?  (empty collections -> PROBE_NA)
proc probe {label args} {
    puts "PROBE_PATH $label"
    set cmd [list report_timing -nosplit -max_paths 1 -input_pins]
    foreach {opt val} $args {
        if {$val eq "" || [sizeof_collection $val] == 0} { puts "PROBE_NA empty $opt"; return }
        lappend cmd $opt $val
    }
    eval $cmd
}

set a_pipe [data_pins [seq_cells "${core}/a_bits_pipe_reg*"]]
set w_pipe [data_pins [seq_cells "${core}/w_bits_pipe_reg*"]]
set tile_acc [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_*_reg*"]]
set tile_any_ck [clk_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/*"]]
set ringq_ck [clk_pins [seq_cells "u_pe/ring_q_reg*"]]
set encp [get_pins -quiet -hier * -filter "full_name=~u_peripheral/*u_ka/* && pin_direction==out"]
set tile_cg_en [get_pins -quiet -hier * -filter "full_name=~${core}/*clk_gate_acc_high_reg*/EN"]
puts "PROBE_INFO tile acc_high clock-gate EN pins [sizeof_collection $tile_cg_en]"

puts "PROBE_PATH combinational loops (report_timing -loops)"
report_timing -loops -max_paths 20
puts "PROBE_PATH check_timing"
check_timing
puts "PROBE_INFO end of loop checks"

probe "worst path (whole design)"
probe "register -> register (whole design)" -from [all_registers -clock_pins] -to [all_registers -data_pins]
probe "-> A bit pipe (any start)" -to $a_pipe
probe "-> W bit pipe (any start)" -to $w_pipe
# AF edge (AF, AF-IPD)
probe "A magnitude reg -> kA encoder -> thermometer -> A bit pipe" \
    -from [clk_pins [seq_cells "u_peripheral/a_binary_q_reg*"]] -through $encp -to $a_pipe
probe "row L reg -> kA encoder -> thermometer -> A bit pipe" \
    -from [clk_pins [seq_cells "u_peripheral/a_len_q_reg*"]] -through $encp -to $a_pipe
probe "phase reg -> kA encoder -> thermometer -> A bit pipe" \
    -from [clk_pins [seq_cells "u_rng/phase_q_reg*"]] -to $a_pipe
probe "cycle counter -> thermometer -> A bit pipe" \
    -from [clk_pins [seq_cells "u_rng/cyc_q_reg*"]] -to $a_pipe
probe "W lane words -> W comparator -> W bit pipe" \
    -from [clk_pins [seq_cells "u_rng/words_q_reg*"]] -to $w_pipe
probe "W magnitude reg -> W comparator -> W bit pipe" \
    -from [clk_pins [seq_cells "u_peripheral/w_binary_q_reg*"]] -to $w_pipe
probe "stream generator internal (counter/phase/slice -> words, phase)" \
    -from [clk_pins [seq_cells "u_rng/*"]] -to [data_pins [seq_cells "u_rng/*"]]
# CSA / IPD Sobol edge
probe "A Sobol bank -> A comparator -> A bit pipe" -from [clk_pins [seq_cells "u_a_rng/*"]] -to $a_pipe
probe "W Sobol bank -> W comparator -> W bit pipe" -from [clk_pins [seq_cells "u_w_rng/*"]] -to $w_pipe
# INT bypass (IPD, AF-IPD)
probe "int_mode_q -> bypass select -> A bit pipe" -from [clk_pins [seq_cells "int_mode_q_reg*"]] -to $a_pipe
probe "int_mode_q -> bypass select -> W bit pipe" -from [clk_pins [seq_cells "int_mode_q_reg*"]] -to $w_pipe
probe "a_raw_in port -> A bit pipe" -from [get_ports -quiet a_raw_in*] -to $a_pipe
probe "w_raw_in port -> W bit pipe" -from [get_ports -quiet w_raw_in*] -to $w_pipe
probe "int_mode_q2 -> MAC guard -> anywhere" -from [clk_pins [seq_cells "int_mode_q2_reg*"]]
# lap / doubling (IPD, AF-IPD)
set tile34 [seq_cells "${core}/g_row_3__g_col_4__u_inner/*"]
set tile34_acc [data_pins [seq_cells "${core}/g_row_3__g_col_4__u_inner/acc_*_reg*"]]
probe "self path, one tile: tile (3,4) registers -> <<1 -> doubling mux -> tile (3,4) acc regs" \
    -from [clk_pins $tile34] -to $tile34_acc
probe "chain path, one tile: tile (3,3) registers -> tile (3,4) acc regs (west neighbour, drain)" \
    -from [clk_pins [seq_cells "${core}/g_row_3__g_col_3__u_inner/*"]] -to $tile34_acc
probe "any tile register -> any tile acc register (self, chain and MAC paths)" -from $tile_any_ck -to $tile_acc
probe "ring_q -> anywhere (doubling-mux selects / tile shift / combiner capture)" -from $ringq_ck
probe "ring_q -> tile acc_high clock-gate enable" -from $ringq_ck -through $tile_cg_en
probe "ring_q -> tile acc_low register (doubling-mux select)" -from $ringq_ck \
    -to [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_low_reg*"]]
probe "ring_q -> tile acc_high register" -from $ringq_ck \
    -to [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_high_reg*"]]
probe "ring_q -> combiner (capture gate)" -from $ringq_ck -to [data_pins [seq_cells "u_combiner/*"]]
probe "east column (col-7 tile registers) -> combiner input register" \
    -from [clk_pins [seq_cells "${core}/g_row_*__g_col_7__u_inner/*"]] -to [data_pins [seq_cells "u_combiner/east_q_reg*"]]
probe "combiner internal (east_q -> out)" -from [clk_pins [seq_cells "u_combiner/*"]] -to [data_pins [seq_cells "u_combiner/*"]]
# ports
probe "shift_in port -> anywhere" -from [get_ports shift_in]
probe "shift_in port -> tile acc_high clock-gate enable" -from [get_ports shift_in] -through $tile_cg_en
probe "shift_in port -> stream generator (slice restart)" -from [get_ports shift_in] -to [data_pins [seq_cells "u_rng/*"]]
probe "shift_in port -> combiner (capture)" -from [get_ports shift_in] -to [data_pins [seq_cells "u_combiner/*"]]
probe "mac_en port -> anywhere (through the mode guard)" -from [get_ports mac_en]
probe "int_mode port -> anywhere (guard XNOR, ring gate, capture, mode register)" -from [get_ports -quiet int_mode]
probe "ring_in port -> anywhere" -from [get_ports -quiet ring_in]
probe "int_prec port -> anywhere" -from [get_ports -quiet int_prec]
probe "block_start port -> anywhere" -from [get_ports -quiet block_start]
probe "slice_start port -> anywhere" -from [get_ports -quiet slice_start]
probe "rng_en port -> anywhere" -from [get_ports rng_en]
probe "a_len_in port -> anywhere" -from [get_ports -quiet a_len_in*]
probe "load_a port -> anywhere" -from [get_ports load_a]
probe "reset port -> anywhere" -from [get_ports reset]
puts "PROBE_PATH top-10 endpoints (register -> register)"
report_timing -nosplit -max_paths 10 -nworst 1 -path_type end \
    -from [all_registers -clock_pins] -to [all_registers -data_pins]
puts "PROBE_PATH top-10 endpoints into the A bit pipe"
report_timing -nosplit -max_paths 10 -nworst 1 -path_type end -to $a_pipe
puts "PROBE_PATH top-10 endpoints (any start)"
report_timing -nosplit -max_paths 10 -nworst 1 -path_type end
exit
