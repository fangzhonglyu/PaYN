# Functional per-component POWER decomposition of a uSystolic binary/bit-serial
# array (BP/BS). SAIF-annotated; classifies every leaf cell by hierarchy (each PE
# = U_ireg / U_wreg / U_mul / U_acc). Flop buckets INCLUDE clock pins; clock_dist
# is the clock-tree cells only. Reconciles to Total. cwd = run dir.
# Env: TOP, SAIF_FILE. Optional NL/SDC/SPEF/OUT (SPEF="" for synth zero-wireload).
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
set SC_LIB [expr {[info exists env(SC_LIB)] ? $env(SC_LIB) : "/afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/sc7mcpp140z_base_svt_c30/r3p0"}]
set LIB_FILE "${SC_LIB}/db/sc7mcpp140z_cln22ul_base_svt_c30_tt_typical_max_0p80v_25c.db"
set search_path  [concat [list . ${SC_LIB}/db] $search_path]
set link_library [list "*" $LIB_FILE]
read_verilog $NL
current_design $DESIGN_NAME
link_design
read_sdc $SDC
if {$SPEF ne "" && [file exists $SPEF]} { read_parasitics -format SPEF $SPEF }
update_timing -full
reset_switching_activity
read_saif $SAIF_FILE -strip_path $SAIF_STRIP_PATH
update_power

set leaves [get_cells -hierarchical -filter {is_hierarchical==false}]
set names  [get_attribute -quiet $leaves full_name]
set ip     [get_attribute -quiet $leaves internal_power]
set sp     [get_attribute -quiet $leaves switching_power]
set lp     [get_attribute -quiet $leaves leakage_power]
set isseq  [get_attribute -quiet $leaves is_sequential]

array set B {}
foreach k {bin_ireg bin_wreg bin_acc_reg bin_mul bin_acc_add bin_ctrl bin_asym_sum bin_asym_corr clock_dist glue_other} { set B($k) 0.0 }
set tot 0.0
foreach nm $names i $ip s $sp l $lp sq $isseq {
    if {$i eq ""} {set i 0.0}; if {$s eq ""} {set s 0.0}; if {$l eq ""} {set l 0.0}
    set p [expr {$i + $s + $l}]
    set tot [expr {$tot + $p}]
    set seq [expr {$sq eq "true" || $sq == 1}]
    if {[string match *U_asym_sum* $nm]} { set B(bin_asym_sum) [expr {$B(bin_asym_sum)+$p}]
    } elseif {[string match *U_asym_corr* $nm]} { set B(bin_asym_corr) [expr {$B(bin_asym_corr)+$p}]
    } elseif {[string match *clk_gate* $nm] || [string match *CTS_* $nm] || [string match *clk_clone* $nm]} {
        set B(clock_dist) [expr {$B(clock_dist)+$p}]
    } elseif {[string match *U_ireg* $nm]} { set B(bin_ireg) [expr {$B(bin_ireg)+$p}]
    } elseif {[string match *U_wreg* $nm]} { set B(bin_wreg) [expr {$B(bin_wreg)+$p}]
    } elseif {[string match *U_mul* $nm]}  { set B(bin_mul)  [expr {$B(bin_mul)+$p}]
    } elseif {[string match *U_acc* $nm]} {
        if {$seq} { set B(bin_acc_reg) [expr {$B(bin_acc_reg)+$p}]
        } else    { set B(bin_acc_add) [expr {$B(bin_acc_add)+$p}] }
    } elseif {$seq} { set B(bin_ctrl) [expr {$B(bin_ctrl)+$p}]
    } else { set B(glue_other) [expr {$B(glue_other)+$p}] }
}
set sum 0.0
foreach k {bin_ireg bin_wreg bin_acc_reg bin_mul bin_acc_add bin_ctrl bin_asym_sum bin_asym_corr clock_dist glue_other} { set sum [expr {$sum+$B($k)}] }
proc mw {x} { return [format "%.4f" [expr {$x*1000.0}]] }
catch { file mkdir [file dirname $OUT] }
set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME  TOTAL [mw $tot]"
foreach k {bin_ireg bin_wreg bin_acc_reg bin_mul bin_acc_add bin_ctrl bin_asym_sum bin_asym_corr clock_dist glue_other} {
    puts $fh "[format %-14s $k] [mw $B($k)]"
}
puts $fh "check_sum [mw $sum]   TOTAL [mw $tot]"
close $fh
puts "BIN_POWER_DONE $DESIGN_NAME total [mw $tot] mW"
exit
