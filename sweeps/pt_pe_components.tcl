# Functional per-component power decomposition of an SC-GEMM PE (SCArch-specific).
# Reload an APR run + SAIF, classify every flop by its RTL signal name and the
# inner-tile compute logic into architectural buckets, and reconcile to Total.
# Emits reports/pe_components.rpt (parsed by sweeps/plot_pe_components.py).
# cwd = APR run dir. Env: TOP, SAIF_FILE. TSMC22.
#
# Buckets (flop buckets INCLUDE each flop's clock-pin internal power):
#   in_bit_reg / w_bit_reg : input & weight stochastic bit pipes (toggle/cycle)
#   in_sign_reg / w_sign_reg : sign pipes (stationary per K-tile)
#   acc_reg     : output-stationary accumulators (inside inner tiles)
#   drain_reg   : drain / output shift registers
#   load_ctrl_reg : systolic load-pulse flops
#   other_reg   : any unclassified flop (should be ~0; guards naming drift)
#   popcount_logic : combinational compute in the N_H*N_W inner tiles
#   clock_dist  : clock tree buffers + gates (clock_network - register clock pins)
#   glue_other  : remaining combinational (= combinational_group - popcount)
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
# Netlist/SDC/SPEF/OUT overridable so this runs on APR (default) OR synth (.syn.v,
# no SPEF -> pass SPEF="" for zero-wireload). Same classification either way.
set NL   [expr {[info exists env(NL)]   && $env(NL)   ne "" ? $env(NL)   : "outputs/${DESIGN_NAME}.apr.v"}]
set SDC  [expr {[info exists env(SDC)]  && $env(SDC)  ne "" ? $env(SDC)  : "${DESIGN_NAME}.syn.sdc"}]
set SPEF [expr {[info exists env(SPEF)] ? $env(SPEF) : "outputs/${DESIGN_NAME}.spef"}]
set OUT  [expr {[info exists env(OUT)]  && $env(OUT)  ne "" ? $env(OUT)  : "reports/pe_components.rpt"}]
set power_enable_analysis  "true"
set power_analysis_mode    "averaged"
set power_model_preference "ccs"
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
read_verilog $NL
current_design $DESIGN_NAME
link_design
read_sdc $SDC
if {$SPEF ne "" && [file exists $SPEF]} { read_parasitics -format SPEF $SPEF }
update_timing -full
reset_switching_activity
read_saif $SAIF_FILE -strip_path $SAIF_STRIP_PATH
update_power

set comb 0.0; set reg 0.0; set regint 0.0; set clk 0.0; set tot 0.0
redirect -variable grp { report_power -significant_digits 6 -nosplit }
foreach l [split $grp "\n"] {
    if {[regexp {^\s*combinational\s+(\S+)\s+\S+\s+\S+\s+(\S+)} $l -> a d]} { set comb $d }
    if {[regexp {^\s*register\s+(\S+)\s+\S+\s+\S+\s+(\S+)} $l -> a d]} { set regint $a; set reg $d }
    if {[regexp {^\s*clock_network\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> d]} { set clk $d }
    if {[regexp {Total Power\s*=\s*(\S+)} $l -> t]} { set tot $t }
}

array set B {}
array set BI {}
array set BS {}
array set BL {}
foreach k {in_bits w_bits in_sign w_sign drain acc load periph rng other} { set B($k) 0.0 }
foreach k {in_bits w_bits in_sign w_sign drain acc load periph rng other} {
    set BI($k) 0.0
    set BS($k) 0.0
    set BL($k) 0.0
}
# all_registers -cells can return the same physical multibit cell once per
# logical register bit. Iterate physical sequential leaves directly so HPK
# DFFQA2W cells are counted exactly once.
set seq_cells [get_cells -hierarchical -filter {is_hierarchical==false && is_sequential==true}]
set nseq [sizeof_collection $seq_cells]
foreach_in_collection c $seq_cells {
    set nm [get_object_name $c]
    set pi [get_attribute $c internal_power]
    set ps [get_attribute $c switching_power]
    set pl [get_attribute $c leakage_power]
    set p [expr {$pi + $ps + $pl}]
    if {[string match *clk_gate* $nm]} { set bucket other
    } elseif {[string match *a_bits_pipe_reg* $nm]} { set bucket in_bits
    } elseif {[string match *w_bits_pipe_reg* $nm]} { set bucket w_bits
    } elseif {[string match *w_encoded_pipe_reg* $nm]} { set bucket w_bits
    } elseif {[string match *w_keep_pipe_reg* $nm]} { set bucket w_bits
    } elseif {[string match *a_signs_pipe_reg* $nm]} { set bucket in_sign
    } elseif {[string match *w_signs_pipe_reg* $nm]} { set bucket w_sign
    } elseif {[string match *acc_out_reg* $nm]} { set bucket acc
    } elseif {[string match *drain_reg_reg* $nm]} { set bucket drain
    } elseif {[string match *a_binary_q_reg* $nm]} { set bucket periph
    } elseif {[string match *w_binary_q_reg* $nm]} { set bucket periph
    } elseif {[string match *a_signs_q_reg* $nm]} { set bucket periph
    } elseif {[string match *w_signs_q_reg* $nm]} { set bucket periph
    } elseif {[string match *random_value_reg* $nm]} { set bucket rng
    } elseif {[string match *count_reg* $nm]} { set bucket rng
    } elseif {[string match *load_* $nm] && [string match *_q_reg* $nm]} { set bucket load
    } else { set bucket other }
    set B($bucket) [expr {$B($bucket)+$p}]
    set BI($bucket) [expr {$BI($bucket)+$pi}]
    set BS($bucket) [expr {$BS($bucket)+$ps}]
    set BL($bucket) [expr {$BL($bucket)+$pl}]
}
set flops_total 0.0
foreach k {in_bits w_bits in_sign w_sign drain acc load periph rng other} { set flops_total [expr {$flops_total+$B($k)}] }

set tiles [get_cells -quiet -hierarchical -filter {is_hierarchical==true} *u_inner]
set ntiles [sizeof_collection $tiles]
set ninner_leaves 0
set inner_total 0.0
if {$ntiles > 0} {
    redirect -variable tr { report_power -significant_digits 6 -cell_power -nosplit $tiles }
    foreach l [split $tr "\n"] {
        if {[regexp {Totals \([0-9]+ cell[s]?\)\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> t]} { set inner_total $t }
    }
} else {
    # Flattened netlists retain the u_inner prefix in leaf instance names even
    # though the hierarchical cells no longer exist. Recover the same compute
    # cone from those leaves so acc flops can be removed below exactly as in a
    # hierarchical netlist.
    set inner_leaves [get_cells -quiet -hierarchical -filter {is_hierarchical==false} *u_inner*]
    set ninner_leaves [sizeof_collection $inner_leaves]
    if {$ninner_leaves > 0} {
        redirect -variable tr { report_power -significant_digits 6 -cell_power -nosplit $inner_leaves }
        foreach l [split $tr "\n"] {
            if {[regexp {Totals \([0-9]+ cell[s]?\)\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> t]} { set inner_total $t }
        }
    }
}
set popcount   [expr {$inner_total - $B(acc)}]
set reg_clkpin [expr {$flops_total - $reg}]
set clock_dist [expr {$clk - $reg_clkpin}]
set glue       [expr {$tot - $flops_total - $popcount - $clock_dist}]

proc mw {x} { return [format "%.6f" [expr {$x*1000.0}]] }
catch { file mkdir [file dirname $OUT] }
set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME  nseq $nseq  ntiles $ntiles  ninner_leaves $ninner_leaves"
puts $fh "group_mW comb [mw $comb] register [mw $reg] clock_network [mw $clk] TOTAL [mw $tot]"
puts $fh "in_bit_reg     [mw $B(in_bits)]"
puts $fh "w_bit_reg      [mw $B(w_bits)]"
puts $fh "in_sign_reg    [mw $B(in_sign)]"
puts $fh "w_sign_reg     [mw $B(w_sign)]"
puts $fh "acc_reg        [mw $B(acc)]"
puts $fh "drain_reg      [mw $B(drain)]"
puts $fh "load_ctrl_reg  [mw $B(load)]"
puts $fh "periph_reg     [mw $B(periph)]"
puts $fh "rng_reg        [mw $B(rng)]"
puts $fh "other_reg      [mw $B(other)]"
foreach k {in_bits w_bits in_sign w_sign drain acc load periph rng other} {
    puts $fh "${k}_detail_mW internal [mw $BI($k)] switching [mw $BS($k)] leakage [mw $BL($k)]"
}
puts $fh "popcount_logic [mw $popcount]"
puts $fh "clock_dist     [mw $clock_dist]"
puts $fh "glue_other     [mw $glue]"
puts $fh "check_flops    [mw $flops_total]   register+clkpin [mw [expr {$reg+$reg_clkpin}]]"
puts $fh "check_sum      [mw [expr {$flops_total+$popcount+$clock_dist+$glue}]]   TOTAL [mw $tot]"
puts $fh "CSVROW,$DESIGN_NAME,[mw $B(in_bits)],[mw $B(w_bits)],[mw $B(in_sign)],[mw $B(w_sign)],[mw $B(acc)],[mw $B(drain)],[mw $B(load)],[mw $B(periph)],[mw $B(rng)],[mw $B(other)],[mw $popcount],[mw $clock_dist],[mw $glue],[mw $tot]"
close $fh
puts "PE_COMPONENTS_DONE $DESIGN_NAME"
exit
