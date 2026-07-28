# Functional per-component POWER decomposition of the binary output-stationary
# array (BOS).  SAIF-annotated; classifies every leaf cell by RTL signal name,
# the way pt_pe_components.tcl does for the SC PE, and reconciles to Total.
# cwd = run dir.  Env: TOP, SAIF_FILE.  Optional NL/SDC/SPEF/OUT (SPEF="" for
# synth zero-wireload).
#
# Bucket keys are deliberately the uSystolic binary keys so sweeps/pe_taxonomy.py
# and the existing plots consume this report unchanged:
#   bin_ireg     a_pipe   : activation hop registers
#   bin_wreg     w_pipe   : weight hop registers
#   bin_acc_reg  acc_out  : stationary accumulators (also the drain shift chain)
#   bin_mul               : the whole combinational cone inside the tiles --
#                           multiplier AND accumulate adder.  Unlike BP/BS, the
#                           PaYN-style tile is one module, so DC optimizes
#                           product and add jointly and no instance-name split
#                           exists.  bin_acc_add is therefore always 0 here and
#                           the taxonomy's merged "compute" segment is the
#                           meaningful comparison (SC popcount+heap+CPA cone).
#   bin_ctrl              : unclassified flops (should be ~0; guards name drift)
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
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

set tot 0.0
redirect -variable grp { report_power -significant_digits 6 -nosplit }
foreach l [split $grp "\n"] {
    if {[regexp {Total Power\s*=\s*(\S+)} $l -> t]} { set tot $t }
}

set leaves [get_cells -hierarchical -filter {is_hierarchical==false}]
set names  [get_attribute -quiet $leaves full_name]
set ip     [get_attribute -quiet $leaves internal_power]
set sp     [get_attribute -quiet $leaves switching_power]
set lp     [get_attribute -quiet $leaves leakage_power]
set isseq  [get_attribute -quiet $leaves is_sequential]

set KEYS {bin_ireg bin_wreg bin_acc_reg bin_mul bin_acc_add bin_ctrl clock_dist glue_other}
array set B {}
foreach k $KEYS { set B($k) 0.0 }
set sum_leaf 0.0
foreach nm $names i $ip s $sp l $lp sq $isseq {
    if {$i eq ""} {set i 0.0}; if {$s eq ""} {set s 0.0}; if {$l eq ""} {set l 0.0}
    set p [expr {$i + $s + $l}]
    set sum_leaf [expr {$sum_leaf + $p}]
    set seq [expr {$sq eq "true" || $sq == 1}]
    if {[string match *clk_gate* $nm] || [string match *CTS_* $nm] || \
        [string match *clk_clone* $nm]} {
        set B(clock_dist) [expr {$B(clock_dist)+$p}]
    } elseif {[string match *acc_out_reg* $nm]} {
        set B(bin_acc_reg) [expr {$B(bin_acc_reg)+$p}]
    } elseif {[string match *a_pipe_reg* $nm] || [string match *a_reg* $nm]} {
        # a_pipe_reg: array-boundary broadcast variant.  a_reg: per-PE hop
        # register in the systolic mesh.  Accumulators are matched first so
        # neither pattern can steal them.
        set B(bin_ireg) [expr {$B(bin_ireg)+$p}]
    } elseif {[string match *w_pipe_reg* $nm] || [string match *w_reg* $nm]} {
        set B(bin_wreg) [expr {$B(bin_wreg)+$p}]
    } elseif {$seq} {
        set B(bin_ctrl) [expr {$B(bin_ctrl)+$p}]
    } elseif {[string match *g_col_* $nm]} {
        # Match the per-PE generate label rather than the instance name: it is
        # stable across the BinaryOSTile -> BinaryOSPE rename, so this script
        # buckets both pre- and post-rename netlists identically.
        set B(bin_mul) [expr {$B(bin_mul)+$p}]
    } else {
        set B(glue_other) [expr {$B(glue_other)+$p}]
    }
}
set sum 0.0
foreach k $KEYS { set sum [expr {$sum+$B($k)}] }

proc mw {x} { return [format "%.4f" [expr {$x*1000.0}]] }
catch { file mkdir [file dirname $OUT] }
set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME  TOTAL [mw $tot]"
foreach k $KEYS { puts $fh "[format %-14s $k] [mw $B($k)]" }
puts $fh "check_sum [mw $sum]   TOTAL [mw $tot]"
set row "CSVROW,$DESIGN_NAME,[mw $tot]"
foreach k $KEYS { set row "$row,[mw $B($k)]" }
puts $fh "# CSVROW,design,total_mW,[join $KEYS ,]"
puts $fh $row
close $fh
puts "BOS_POWER_DONE $DESIGN_NAME total [mw $tot] mW (leaf sum [mw $sum_leaf] mW)"
exit
