# Worst synthesized paths through the sub-ring lap additions (LAP_G = $env(LAP_G);
# head mux at every LAP_G-th tile), plus the CSA / BP paths they touch, for any
# BP netlist, so the SR runs, the IPD run and the csa_bp_20261004_lap run can be
# probed by the SAME script.  Adapted from sweeps/int_mode/bp/ipd/dc_bp_ipd_new_paths.tcl.
# Run by sweeps/int_mode/bp/sr/report_bp_sr_new_paths.sh from its own output
# directory after sourcing the run's TARGET_DEF; reads the written netlist and
# SDC from BP_RUN_DIR and never writes into the synthesis run.
#
# SR-specific probes:
#   * combinational loops (report_timing -loops, check_timing);
#   * the head path: tail tile (3, 4+LAP_G-1) registers -> <<1 -> head mux ->
#     head tile (3,4) acc registers (LAP_G = 1: the IPD self path);
#   * ring_q -> tile clock-gate enable / acc_low (head-mux selects).
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

set lap_g [expr {[info exists env(LAP_G)] ? $env(LAP_G) : 1}]
set tail_v [expr {4 + $lap_g - 1}]
if {$tail_v > 7} { set tail_v 7 }
set tile00 [seq_cells "${core}/g_row_3__g_col_${tail_v}__u_inner/*"]
set tile00_acc [seq_cells "${core}/g_row_3__g_col_4__u_inner/acc_*_reg*"]
puts "BP_INFO LAP_G=$lap_g: tail tile (3,$tail_v) sequential cells: [sizeof_collection $tile00], head tile (3,4) acc regs: [sizeof_collection $tile00_acc]"
bp_path "head path: tail tile (3,$tail_v) registers -> <<1 -> head mux -> head tile (3,4) acc regs" \
    [clk_pins $tile00] [data_pins $tile00_acc]
bp_path "chain path, one tile: tile (3,3) registers -> tile (3,4) acc regs (west neighbour, drain)" \
    [clk_pins [seq_cells "${core}/g_row_3__g_col_3__u_inner/*"]] [data_pins $tile00_acc]
bp_path "BP ring return (col-7 tile -> <<1 -> col-0 tile); SR: only when LAP_G = 8" \
    [clk_pins [seq_cells "${core}/g_row_*__g_col_7__u_inner/*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_0__u_inner/acc_*_reg*"]]
bp_path "ring_q -> anywhere (ring mux / head-mux selects / combiner capture)" \
    [clk_pins [seq_cells "u_pe/ring_q_reg*"]] ""
bp_path "shift_in port -> anywhere (CSA route worst path: tile clock-gate enable)" [get_ports shift_in] ""
set tile_cg_en [get_pins -hier * -filter "full_name=~${core}/*clk_gate_acc_high_reg*/EN"]
puts "BP_INFO tile acc_high clock-gate EN pins: [sizeof_collection $tile_cg_en]"
bp_path_thru "shift_in port -> tile acc_high clock-gate enable" [get_ports shift_in] $tile_cg_en
bp_path_thru "ring_q -> tile acc_high clock-gate enable" [clk_pins [seq_cells "u_pe/ring_q_reg*"]] $tile_cg_en
bp_path "ring_q -> tile acc_low register (shift mux / head-mux select)" [clk_pins [seq_cells "u_pe/ring_q_reg*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_low_reg*"]]
bp_path "ring_q -> tile acc_high register" [clk_pins [seq_cells "u_pe/ring_q_reg*"]] \
    [data_pins [seq_cells "${core}/g_row_*__g_col_*__u_inner/acc_high_reg*"]]
bp_path "any tile register -> any tile acc register (head, chain and MAC paths)" \
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
