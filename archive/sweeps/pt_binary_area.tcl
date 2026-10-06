# Functional per-component CELL-AREA decomposition of a uSystolic binary/bit-serial
# array (BP/BS). Classifies every leaf cell by HIERARCHY (each PE = U_ireg input
# reg + U_wreg weight reg + U_mul multiplier + U_acc adder+psum), since all flops
# share generic names. Netlist-only (no SAIF/power). cwd = run dir. Env: TOP.
#   NL  = netlist (default outputs/${TOP}.apr.v; synth: ${TOP}.syn.v)
#   OUT = report path (default reports/pe_area_components.rpt)
set DESIGN_NAME $env(TOP)
set NL  [expr {[info exists env(NL)]  && $env(NL)  ne "" ? $env(NL)  : "outputs/${DESIGN_NAME}.apr.v"}]
set OUT [expr {[info exists env(OUT)] && $env(OUT) ne "" ? $env(OUT) : "reports/pe_area_components.rpt"}]
set SC_LIB /afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4/sc7mcpp140z_base_svt_c30/r3p0
set LIB_FILE "${SC_LIB}/db/sc7mcpp140z_cln22ul_base_svt_c30_tt_typical_max_0p80v_25c.db"
set search_path  [concat [list . ${SC_LIB}/db] $search_path]
set link_library [list "*" $LIB_FILE]
read_verilog $NL
current_design $DESIGN_NAME
link_design

set leaves [get_cells -hierarchical -filter {is_hierarchical==false}]
set names  [get_attribute -quiet $leaves full_name]
set areas  [get_attribute -quiet $leaves area]
set isseq  [get_attribute -quiet $leaves is_sequential]

array set A {}
foreach k {bin_ireg bin_wreg bin_acc_reg bin_mul bin_acc_add bin_ctrl bin_asym_sum bin_asym_corr clock glue} { set A($k) 0.0 }
set ncell 0; set tot 0.0
foreach nm $names ar $areas sq $isseq {
    if {$ar eq ""} { set ar 0.0 }
    incr ncell; set tot [expr {$tot + $ar}]
    set seq [expr {$sq eq "true" || $sq == 1}]
    if {[string match *U_asym_sum* $nm]} { set A(bin_asym_sum) [expr {$A(bin_asym_sum)+$ar}]
    } elseif {[string match *U_asym_corr* $nm]} { set A(bin_asym_corr) [expr {$A(bin_asym_corr)+$ar}]
    } elseif {[string match *clk_gate* $nm] || [string match *CTS_* $nm] || [string match *clk_clone* $nm]} {
        set A(clock) [expr {$A(clock)+$ar}]
    } elseif {[string match *U_ireg* $nm]} { set A(bin_ireg) [expr {$A(bin_ireg)+$ar}]
    } elseif {[string match *U_wreg* $nm]} { set A(bin_wreg) [expr {$A(bin_wreg)+$ar}]
    } elseif {[string match *U_mul* $nm]}  { set A(bin_mul)  [expr {$A(bin_mul)+$ar}]
    } elseif {[string match *U_acc* $nm]} {
        if {$seq} { set A(bin_acc_reg) [expr {$A(bin_acc_reg)+$ar}]
        } else    { set A(bin_acc_add) [expr {$A(bin_acc_add)+$ar}] }
    } elseif {$seq} { set A(bin_ctrl) [expr {$A(bin_ctrl)+$ar}]
    } else { set A(glue) [expr {$A(glue)+$ar}] }
}
set sum 0.0
foreach k {bin_ireg bin_wreg bin_acc_reg bin_mul bin_acc_add bin_ctrl bin_asym_sum bin_asym_corr clock glue} { set sum [expr {$sum+$A($k)}] }

catch { file mkdir [file dirname $OUT] }
set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME  ncell $ncell  total_cell_area_um2 [format %.2f $tot]"
foreach k {bin_ireg bin_wreg bin_acc_reg bin_mul bin_acc_add bin_ctrl bin_asym_sum bin_asym_corr clock glue} {
    puts $fh "[format %-16s ${k}_area] [format %.2f $A($k)]"
}
puts $fh "check_sum [format %.2f $sum]  (should = total_cell_area)"
close $fh
puts "BIN_AREA_DONE $DESIGN_NAME  ireg [format %.0f $A(bin_ireg)] wreg [format %.0f $A(bin_wreg)] acc_reg [format %.0f $A(bin_acc_reg)] mul [format %.0f $A(bin_mul)] add [format %.0f $A(bin_acc_add)] clk [format %.0f $A(clock)] glue [format %.0f $A(glue)]"
exit
