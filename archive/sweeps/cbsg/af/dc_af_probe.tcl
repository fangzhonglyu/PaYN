# Post-synthesis area classes and timing probes for the C-BSG AF array
# (payn_array_signed_segmented_csa_cbsg_af) and, for comparison, the accepted
# CSA baseline (payn_array_signed_segmented_csa).  Run by
# sweeps/cbsg/af/run_syn_reports.sh from build/cbsg/af/syn/<target>_<run>/ after
# sourcing the run's TARGET_DEF; reads the written netlist and SDC from
# PROBE_RUN_DIR, so nothing is written into a synthesis run directory.
#
# Area: every leaf cell of u_peripheral (and of the AF stream generator u_rng)
# is put in exactly one class, and the class sums are printed as
#   AREA_CLASS <class> <cells> <area_um2>
# Classes (priority order, first match wins):
#   ka_enc      AF only: leaf cells inside the 64 CbsgAfKaEncoder instances (*u_ka)
#   a_regs      sequential cells / clock gates named a_* or clk_gate_a_* (A magnitude,
#               sign and, in AF, per-row L registers)
#   w_regs      sequential cells / clock gates named w_* or clk_gate_w_*
#   ka_in_buf   AF only: combinational cells outside the encoders in the fanin of the
#               encoders' input pins (register-output buffering into the encoders)
#   a_logic     combinational cells in the fanin of u_peripheral/a_bits*:
#               AF thermometer decode (+ cyc buffering); CSA the 1,024 A comparators
#   w_logic     combinational cells in the fanin of u_peripheral/w_bits*: the 1,024
#               W comparators (+ threshold buffering)
#   p_other     anything else in u_peripheral (listed)
# AF u_rng classes: rng_words (fanin of the w_words outputs, incl. the 112 word
# registers), rng_ctrl (rest: counter, phase, slice restart).
#
# Timing: PROBE_PATH <label> followed by report_timing -max_paths 1.
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
read_verilog -netlist $env(PROBE_RUN_DIR)/$env(TOP).syn.v
current_design $env(TOP)
link
read_sdc $env(PROBE_RUN_DIR)/$env(TOP).syn.sdc
set kind $env(PROBE_KIND)
set core u_pe/u_array_core

proc sum_area {cells} {
    set a 0.0
    foreach_in_collection c $cells { set a [expr {$a + [get_attribute $c area]}] }
    return $a
}
proc emit {label cells} {
    puts [format "AREA_CLASS %s %d %.4f" $label [sizeof_collection $cells] [sum_area $cells]]
}
proc leaf {pattern} {
    return [get_cells -hier * -filter "full_name=~${pattern} && is_hierarchical==false"]
}
proc cone_to {pins} {
    return [filter_collection [all_fanin -to $pins -flat -only_cells] "is_hierarchical==false"]
}

#------------------------------------------------------------------ area --
set p_all [leaf "u_peripheral/*"]
puts "AREA_TOTAL u_peripheral [sizeof_collection $p_all] [sum_area $p_all]"
set rest $p_all

if {$kind eq "af"} {
    set enc [leaf "u_peripheral/*u_ka/*"]
    set rest [remove_from_collection $rest $enc]
    emit ka_enc $enc
    puts "AREA_INFO ka_enc instances [sizeof_collection [get_cells -hier * -filter {full_name=~u_peripheral/*u_ka && is_hierarchical==true}]]"
}

set seq [filter_collection $rest "is_sequential==true"]
set a_seq [filter_collection $seq "full_name=~u_peripheral/a_* || full_name=~u_peripheral/clk_gate_a_*"]
set w_seq [filter_collection $seq "full_name=~u_peripheral/w_* || full_name=~u_peripheral/clk_gate_w_*"]
# Clock-gate wrappers are hierarchical (SNPS_CLOCK_GATE_HIGH_*): their leaf latch cell sits
# below the clk_gate_* instance, so match it by the wrapper prefix too.
set a_seq [add_to_collection $a_seq [filter_collection $rest "full_name=~u_peripheral/clk_gate_a_*"] -unique]
set w_seq [add_to_collection $w_seq [filter_collection $rest "full_name=~u_peripheral/clk_gate_w_*"] -unique]
set rest [remove_from_collection $rest $a_seq]
set rest [remove_from_collection $rest $w_seq]
emit a_regs $a_seq
emit w_regs $w_seq
foreach r {a_binary_q a_signs_q a_len_q w_binary_q w_signs_q} {
    set c [filter_collection $seq "full_name=~u_peripheral/${r}_reg*"]
    puts [format "AREA_REG %s %d %.4f" $r [sizeof_collection $c] [sum_area $c]]
}

if {$kind eq "af"} {
    set enc_in [get_pins -hier * -filter "full_name=~u_peripheral/*u_ka/* && pin_direction==in"]
    set kin [remove_from_collection [cone_to $enc_in] $enc]
    set kin [filter_collection $kin "full_name=~u_peripheral/* && is_sequential==false"]
    set kin [remove_from_collection $kin $a_seq]
    set kin [remove_from_collection $kin $w_seq]
    set rest [remove_from_collection $rest $kin]
    emit ka_in_buf $kin
}

set a_pins [get_pins u_peripheral/a_bits*]
set w_pins [get_pins u_peripheral/w_bits*]
puts "AREA_INFO a_bits pins [sizeof_collection $a_pins] w_bits pins [sizeof_collection $w_pins]"
set a_cone [filter_collection [cone_to $a_pins] "full_name=~u_peripheral/*"]
set w_cone [filter_collection [cone_to $w_pins] "full_name=~u_peripheral/*"]
set a_logic [remove_from_collection $rest [remove_from_collection $rest $a_cone]]
set w_logic [remove_from_collection $rest [remove_from_collection $rest $w_cone]]
set both [remove_from_collection $a_logic [remove_from_collection $a_logic $w_logic]]
puts "AREA_INFO a_logic/w_logic overlap cells [sizeof_collection $both]"
set w_logic [remove_from_collection $w_logic $both]
set rest [remove_from_collection $rest $a_logic]
set rest [remove_from_collection $rest $w_logic]
emit a_logic $a_logic
emit w_logic $w_logic
emit p_other $rest
foreach_in_collection c $rest {
    puts "AREA_OTHER [get_attribute $c full_name] [get_attribute $c ref_name] [get_attribute $c area]"
}

if {$kind eq "af"} {
    set g_all [leaf "u_rng/*"]
    puts "AREA_TOTAL u_rng [sizeof_collection $g_all] [sum_area $g_all]"
    set words_pins [get_pins u_rng/w_words*]
    set g_words [filter_collection [cone_to $words_pins] "full_name=~u_rng/*"]
    set g_words [remove_from_collection $g_all [remove_from_collection $g_all $g_words]]
    emit rng_words $g_words
    emit rng_ctrl [remove_from_collection $g_all $g_words]
    set wq [filter_collection $g_all "full_name=~u_rng/words_q_reg* && is_sequential==true"]
    puts [format "AREA_REG words_q %d %.4f" [sizeof_collection $wq] [sum_area $wq]]
}
set top_leaf [get_cells * -filter "is_hierarchical==false"]
emit top_glue $top_leaf

#---------------------------------------------------------------- timing --
proc seq_cells {pattern} {
    return [get_cells -hier * -filter "full_name=~${pattern} && is_sequential==true"]
}
proc clk_pins {cells} { return [get_pins -of_objects $cells -filter "name==CK"] }
proc data_pins {cells} {
    return [get_pins -of_objects $cells -filter "pin_direction==in && name!=CK && name!=SE && name!=SI"]
}
proc probe {label args} {
    puts "PROBE_PATH $label"
    eval report_timing -nosplit -max_paths 1 -input_pins $args
}

set a_pipe [data_pins [seq_cells "${core}/a_bits_pipe_reg*"]]
set w_pipe [data_pins [seq_cells "${core}/w_bits_pipe_reg*"]]
probe "worst path (whole design)"
probe "register -> register (whole design)" -from [all_registers -clock_pins] -to [all_registers -data_pins]
probe "-> A bit pipe (any start)" -to $a_pipe
probe "-> W bit pipe (any start)" -to $w_pipe
if {$kind eq "af"} {
    set encp [get_pins -hier * -filter "full_name=~u_peripheral/*u_ka/* && pin_direction==out"]
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
    probe "block_start port -> anywhere" -from [get_ports block_start]
    probe "slice_start port -> anywhere" -from [get_ports slice_start]
    probe "shift_in port -> stream generator (slice restart)" \
        -from [get_ports shift_in] -to [data_pins [seq_cells "u_rng/*"]]
    probe "shift_in port -> anywhere" -from [get_ports shift_in]
    probe "rng_en port -> anywhere" -from [get_ports rng_en]
    probe "a_len_in port -> anywhere" -from [get_ports a_len_in*]
    probe "load_a port -> anywhere" -from [get_ports load_a]
    # Top 10 register-to-register endpoints (one path each) to see what is near-critical.
    puts "PROBE_PATH top-10 endpoints (register -> register)"
    report_timing -nosplit -max_paths 10 -nworst 1 -path_type end \
        -from [all_registers -clock_pins] -to [all_registers -data_pins]
    puts "PROBE_PATH top-10 endpoints into the A bit pipe"
    report_timing -nosplit -max_paths 10 -nworst 1 -path_type end -to $a_pipe
} else {
    probe "A Sobol bank -> A comparator -> A bit pipe" \
        -from [clk_pins [seq_cells "u_a_rng/*"]] -to $a_pipe
    probe "W Sobol bank -> W comparator -> W bit pipe" \
        -from [clk_pins [seq_cells "u_w_rng/*"]] -to $w_pipe
    puts "PROBE_PATH top-10 endpoints (register -> register)"
    report_timing -nosplit -max_paths 10 -nworst 1 -path_type end \
        -from [all_registers -clock_pins] -to [all_registers -data_pins]
}
exit
