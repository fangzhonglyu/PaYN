# Worst synthesized paths through the bit-plane additions of
# payn_array_signed_segmented_csa_bp, plus the CSA paths they touch.  Run by
# sweeps/int_mode/bp/report_bp_new_paths.sh from <run>/bp_paths/ after sourcing
# the run's TARGET_DEF; reads the written netlist and SDC from BP_RUN_DIR.
source $env(ASTRAEA_FLOW)/syn/setups/dc_setup_TSMC22.tcl
read_verilog -netlist $env(BP_RUN_DIR)/$env(TOP).syn.v
current_design $env(TOP)
link
read_sdc $env(BP_RUN_DIR)/$env(TOP).syn.sdc
set core u_pe/u_array_core

proc seq_cells {pattern} {
    return [get_cells -hier * -filter "full_name=~${pattern} && is_sequential==true"]
}
proc clk_pins {cells} { return [get_pins -of_objects $cells -filter "name==CK"] }
proc data_pins {cells} {
    return [get_pins -of_objects $cells -filter "pin_direction==in && name!=CK && name!=SE && name!=SI"]
}
proc bp_path {label from to} {
    puts "BP_PATH $label"
    if {$from ne "" && $to ne ""} {
        report_timing -nosplit -from $from -to $to -max_paths 1
    } elseif {$from ne ""} {
        report_timing -nosplit -from $from -max_paths 1
    } else {
        report_timing -nosplit -to $to -max_paths 1
    }
}

bp_path "ring return (east tile -> <<1 -> ring mux -> west tile)" \
    [clk_pins [seq_cells "${core}/g_row_*__g_col_7__u_inner/*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_0__u_inner/*"]]
bp_path "ring_q -> ring mux / combiner capture" [clk_pins [seq_cells "u_pe/ring_q_reg*"]] ""
bp_path "shift_in port -> anywhere (CSA route worst path: tile clock-gate enable)" [get_ports shift_in] ""
bp_path "mac_en port -> anywhere (through the mode guard)" [get_ports mac_en] ""
bp_path "int_mode port -> anywhere (guard XNOR, ring gate, capture, mode register)" [get_ports int_mode] ""
bp_path "int_mode_q -> select tree -> bit pipes" [clk_pins [seq_cells "int_mode_q_reg*"]] ""
bp_path "comparator bypass (Sobol -> comparator -> AO21 -> A bit pipe)" \
    [clk_pins [seq_cells "u_a_rng/*"]] [data_pins [seq_cells "${core}/a_bits_pipe_reg*"]]
bp_path "comparator bypass (Sobol -> comparator -> AO21 -> W bit pipe)" \
    [clk_pins [seq_cells "u_w_rng/*"]] [data_pins [seq_cells "${core}/w_bits_pipe_reg*"]]
bp_path "raw input port -> bit pipe" [get_ports a_raw_in*] ""
bp_path "ring_in port -> anywhere" [get_ports ring_in] ""
bp_path "combiner tree (input register -> output register)" \
    [clk_pins [seq_cells "u_combiner/*"]] [data_pins [seq_cells "u_combiner/out_reg*"]]
bp_path "east column (col-7 tile registers) -> combiner input register" \
    [clk_pins [seq_cells "${core}/g_row_*__g_col_7__u_inner/*"]] \
    [data_pins [seq_cells "u_combiner/east_q_reg*"]]
bp_path "reset port -> combiner" [get_ports reset] [data_pins [seq_cells "u_combiner/*"]]
bp_path "register -> register (whole design)" [all_registers -clock_pins] [all_registers -data_pins]
exit
