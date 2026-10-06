# Worst synthesized paths through the in-place-doubling (IPD) additions, plus
# the CSA / BP paths they touch, for either BP netlist, so the IPD run and the
# csa_bp_20261004_lap run are probed by the SAME script (like-for-like table).
# Adapted from sweeps/int_mode/bp/dc_bp_new_paths.tcl (unchanged).  Run by
# sweeps/int_mode/bp/ipd/report_bp_ipd_new_paths.sh from its own output
# directory after sourcing the run's TARGET_DEF; reads the written netlist and
# SDC from BP_RUN_DIR and never writes into the synthesis run.
#
# IPD-specific probes:
#   * combinational loops: report_timing -loops and check_timing (the self
#     path acc_out -> <<1 -> mux -> acc_in must end at a register D pin);
#   * the self-doubling path: tile (h,v) registers -> <<1 -> AO22 -> the same
#     tile's acc_low / acc_high registers (one tile, then all tiles);
#   * ring_q -> tile clock-gate enable and ring_q -> tile acc_low (the
#     doubling-mux select now fans out to 64 x 24 mux bits).
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
    if {[sizeof_collection $from] == 0 && $from ne ""} { puts "BP_INFO empty startpoint set"; return }
    if {$from ne "" && $to ne ""} {
        report_timing -nosplit -from $from -to $to -max_paths 1
    } elseif {$from ne ""} {
        report_timing -nosplit -from $from -max_paths 1
    } else {
        report_timing -nosplit -to $to -max_paths 1
    }
}
proc bp_path_thru {label from thru} {
    puts "BP_PATH $label"
    if {[sizeof_collection $from] == 0 || [sizeof_collection $thru] == 0} { puts "BP_INFO empty set"; return }
    report_timing -nosplit -from $from -through $thru -max_paths 1
}

puts "BP_PATH combinational loops (report_timing -loops)"
report_timing -loops -max_paths 20
puts "BP_PATH check_timing (loops, unconstrained endpoints)"
check_timing
puts "BP_INFO end of loop checks"

set tile00 [seq_cells "${core}/g_row_3__g_col_4__u_inner/*"]
set tile00_acc [seq_cells "${core}/g_row_3__g_col_4__u_inner/acc_*_reg*"]
puts "BP_INFO tile (3,4) sequential cells: [sizeof_collection $tile00], acc regs: [sizeof_collection $tile00_acc]"
bp_path "self path, one tile: tile (3,4) registers -> <<1 -> doubling mux -> tile (3,4) acc regs" \
    [clk_pins $tile00] [data_pins $tile00_acc]
bp_path "chain path, one tile: tile (3,3) registers -> tile (3,4) acc regs (west neighbour, drain)" \
    [clk_pins [seq_cells "${core}/g_row_3__g_col_3__u_inner/*"]] [data_pins $tile00_acc]
bp_path "BP ring return (east tile -> <<1 -> ring mux -> west tile); IPD: west tile from its own value only" \
    [clk_pins [seq_cells "${core}/g_row_*__g_col_7__u_inner/*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_0__u_inner/acc_*_reg*"]]
bp_path "ring_q -> anywhere (ring mux / doubling-mux selects / combiner capture)" \
    [clk_pins [seq_cells "u_pe/ring_q_reg*"]] ""
bp_path "shift_in port -> anywhere (CSA route worst path: tile clock-gate enable)" [get_ports shift_in] ""
set tile_cg_en [get_pins -hier * -filter "full_name=~${core}/*clk_gate_acc_high_reg*/EN"]
puts "BP_INFO tile acc_high clock-gate EN pins: [sizeof_collection $tile_cg_en]"
bp_path_thru "shift_in port -> tile acc_high clock-gate enable" [get_ports shift_in] $tile_cg_en
bp_path_thru "ring_q -> tile acc_high clock-gate enable" [clk_pins [seq_cells "u_pe/ring_q_reg*"]] $tile_cg_en
bp_path "ring_q -> tile acc_low register (shift mux / doubling mux select)" [clk_pins [seq_cells "u_pe/ring_q_reg*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_low_reg*"]]
bp_path "ring_q -> tile acc_high register" [clk_pins [seq_cells "u_pe/ring_q_reg*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_high_reg*"]]
bp_path "any tile register -> any tile acc register (self, chain and MAC paths)" \
    [clk_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_*_reg*"]]
bp_path "mac_en port -> anywhere (through the mode guard)" [get_ports mac_en] ""
bp_path "int_mode port -> anywhere (guard XNOR, ring gate, capture, mode register)" [get_ports int_mode] ""
bp_path "ring_in port -> anywhere" [get_ports ring_in] ""
bp_path "east column (col-7 tile registers) -> combiner input register" \
    [clk_pins [seq_cells "${core}/g_row_*__g_col_7__u_inner/*"]] \
    [data_pins [seq_cells "u_combiner/east_q_reg*"]]
bp_path "reset port -> anywhere" [get_ports reset] ""
bp_path "register -> register (whole design)" [all_registers -clock_pins] [all_registers -data_pins]
exit
