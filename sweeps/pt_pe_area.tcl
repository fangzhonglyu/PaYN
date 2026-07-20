# Functional per-component CELL-AREA decomposition of an SC-GEMM PE.
# Only needs the netlist (+ .db for cell areas) — no SPEF/SAIF/power. Classifies
# every leaf cell by instance name and sums standard-cell area per bucket.
# cwd = the run dir. Env: TOP (design name). Optional:
#   NL  = netlist path relative to cwd (default outputs/${TOP}.apr.v; for synth
#         pass e.g. ${TOP}.syn.v)
#   OUT = output report path (default reports/pe_area_components.rpt)
# Parsed by sweeps/plot_pe_components.py (APR) / sweeps/plot_synth_vs_apr.py (synth).
set DESIGN_NAME $env(TOP)
set NL  [expr {[info exists env(NL)]  && $env(NL)  ne "" ? $env(NL)  : "outputs/${DESIGN_NAME}.apr.v"}]
set OUT [expr {[info exists env(OUT)] && $env(OUT) ne "" ? $env(OUT) : "reports/pe_area_components.rpt"}]
source [file join [file dirname [file normalize [info script]]] pt_tsmc22_libraries.tcl]
read_verilog $NL
current_design $DESIGN_NAME
link_design

set leaves [get_cells -hierarchical -filter {is_hierarchical==false}]
set names  [get_attribute -quiet $leaves full_name]
set areas  [get_attribute -quiet $leaves area]
set isseq  [get_attribute -quiet $leaves is_sequential]

array set A {}
foreach k {in_bit w_bit in_sign w_sign acc drain load other_reg popcount clock glue} { set A($k) 0.0 }
set ncell 0; set tot 0.0
foreach nm $names ar $areas sq $isseq {
    if {$ar eq ""} { set ar 0.0 }
    incr ncell; set tot [expr {$tot + $ar}]
    if {[string match *clk_gate* $nm] || [string match *CTS_* $nm] || [string match *clk_clone* $nm]} {
        set A(clock) [expr {$A(clock)+$ar}]
    } elseif {$sq eq "true" || $sq == 1} {
        if {[string match *in_bits_pipe_reg* $nm]}   { set A(in_bit)  [expr {$A(in_bit)+$ar}]
        } elseif {[string match *w_bits_pipe_reg* $nm]}  { set A(w_bit)  [expr {$A(w_bit)+$ar}]
        } elseif {[string match *in_signs_pipe_reg* $nm]} { set A(in_sign) [expr {$A(in_sign)+$ar}]
        } elseif {[string match *w_signs_pipe_reg* $nm]}  { set A(w_sign) [expr {$A(w_sign)+$ar}]
        } elseif {[string match *drain_reg_reg* $nm]}     { set A(drain) [expr {$A(drain)+$ar}]
        } elseif {[string match *acc_reg* $nm]}           { set A(acc)   [expr {$A(acc)+$ar}]
        } elseif {[string match *load_*pipe_q* $nm]}      { set A(load)  [expr {$A(load)+$ar}]
        } else { set A(other_reg) [expr {$A(other_reg)+$ar}] }
    } elseif {[string match *u_inner* $nm]} {
        set A(popcount) [expr {$A(popcount)+$ar}]
    } else {
        set A(glue) [expr {$A(glue)+$ar}]
    }
}
set sum 0.0
foreach k {in_bit w_bit in_sign w_sign acc drain load other_reg popcount clock glue} { set sum [expr {$sum+$A($k)}] }

catch { file mkdir [file dirname $OUT] }
set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME  ncell $ncell  total_cell_area_um2 [format %.2f $tot]"
foreach k {in_bit w_bit in_sign w_sign acc drain load other_reg popcount clock glue} {
    puts $fh "[format %-14s ${k}_area] [format %.2f $A($k)]"
}
puts $fh "check_sum [format %.2f $sum]  (should = total_cell_area)"
puts $fh "CSVROW,$DESIGN_NAME,[format %.2f $A(in_bit)],[format %.2f $A(w_bit)],[format %.2f $A(in_sign)],[format %.2f $A(w_sign)],[format %.2f $A(acc)],[format %.2f $A(drain)],[format %.2f $A(load)],[format %.2f $A(other_reg)],[format %.2f $A(popcount)],[format %.2f $A(clock)],[format %.2f $A(glue)],[format %.2f $tot]"
close $fh
puts "PE_AREA_DONE $DESIGN_NAME (ncell $ncell)"
exit
