# Worst synthesized paths of the C-BSG RG array (payn_array_signed_segmented_csa_cbsg_rg), with the
# single-cycle PE path in front: a_bits_pipe -> prefix -> Gray -> k-direction XOR map -> mask -> 8-bit
# compare -> CSA counter / heap / adder -> acc_low.  Run by sweeps/cbsg/rg/report_rg_paths.sh from
# build/cbsg/rg/syn_paths/<run>/ after sourcing the run's TARGET_DEF; reads the written netlist and SDC
# from RG_RUN_DIR (never writes into the synthesis run).
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
read_verilog -netlist $env(RG_RUN_DIR)/$env(TOP).syn.v
current_design $env(TOP)
link
read_sdc $env(RG_RUN_DIR)/$env(TOP).syn.sdc
set core u_pe/u_array_core

proc seq_cells {pattern} {
    return [get_cells -hier * -filter "full_name=~${pattern} && is_sequential==true"]
}
proc clk_pins {cells} { return [get_pins -of_objects $cells -filter "name==CK"] }
proc data_pins {cells} {
    return [get_pins -of_objects $cells -filter "pin_direction==in && name!=CK && name!=SE && name!=SI"]
}
proc rg_path {label from to} {
    puts "RG_PATH $label"
    if {[sizeof_collection $from] == 0 && $from ne ""} { puts "RG_INFO no startpoints"; return }
    if {[sizeof_collection $to] == 0 && $to ne ""} { puts "RG_INFO no endpoints"; return }
    if {$from ne "" && $to ne ""} {
        report_timing -nosplit -from $from -to $to -max_paths 1 -input_pins
    } elseif {$from ne ""} {
        report_timing -nosplit -from $from -max_paths 1 -input_pins
    } else {
        report_timing -nosplit -to $to -max_paths 1 -input_pins
    }
}

set a_pipe   [seq_cells "${core}/a_bits_pipe_reg*"]
set w_pipe   [seq_cells "${core}/w_bits_pipe_reg*"]
set j_regs   [seq_cells "${core}/g_gen_row_*j_reg*"]
set ctl_pipe [seq_cells "${core}/*_pipe_reg*"]
set acc_low  [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_low_reg*"]
set tile_all [seq_cells "${core}/g_row_*__g_col_*__u_inner/*"]
puts "RG_INFO a_bits_pipe flops: [sizeof_collection $a_pipe], w_bits_pipe flops: [sizeof_collection $w_pipe],\
 j flops: [sizeof_collection $j_regs], tile acc_low flops: [sizeof_collection $acc_low],\
 all registers: [sizeof_collection [all_registers]]"

rg_path "a_bits_pipe -> W index generator -> W compare -> CSA tile -> acc_low (the new single-cycle path)" \
    [clk_pins $a_pipe] [data_pins $acc_low]
rg_path "a_bits_pipe -> W index generator -> j register (generator feedback)" [clk_pins $a_pipe] [data_pins $j_regs]
rg_path "j register -> prefix -> W compare -> CSA tile -> acc_low" [clk_pins $j_regs] [data_pins $acc_low]
rg_path "w_bits_pipe (W magnitude) -> W compare -> CSA tile -> acc_low" [clk_pins $w_pipe] [data_pins $acc_low]
rg_path "PE pipes (first/valid/phase/sign) -> anywhere" [clk_pins $ctl_pipe] ""
rg_path "edge: q bank / phase / operand registers -> A compare -> a_bits_pipe" \
    [clk_pins [add_to_collection [seq_cells "u_a_rng/*"] [seq_cells "u_peripheral/*"]]] [data_pins $a_pipe]
rg_path "top control (phase_q, first_q, valid_q, shift_q, phase_rst_pend_q) -> anywhere" \
    [clk_pins [seq_cells "*_q_reg*"]] ""
rg_path "shift_in port -> anywhere (tile clock-gate enable)" [get_ports shift_in] ""
rg_path "mac_en port -> anywhere" [get_ports mac_en] ""
rg_path "reset port -> anywhere" [get_ports reset] ""
rg_path "any input port -> anywhere" [all_inputs] ""
rg_path "tile register -> tile register (accumulator loop, baseline-like)" [clk_pins $tile_all] [data_pins $tile_all]
rg_path "register -> register (whole design)" [all_registers -clock_pins] [all_registers -data_pins]
puts "RG_PATH worst path overall"
report_timing -nosplit -max_paths 1 -input_pins
exit
