# Array-level per-component power decomposition of the PaYN SC array.
# Derived from pt_pe_components.tcl, extended from PE scope to the full array
# so the RNG / converter front end appears as its own component -- the
# low-corner K/M/N rays are precisely about how those fixed costs amortize.
# Emits reports/array_components.rpt (parsed by sweeps/plot_low_corner_components.py).
# cwd = APR run dir. Env: TOP, SAIF_FILE. TSMC22.
#
# Decomposition: ONE walk over every leaf cell, each counted exactly once
# (internal + switching + leakage cell attributes), so no bucket can double
# count -- hierarchy report_power totals are NOT used, because CCOpt places
# CTS buffers inside the Sobol/peripheral hierarchies and summing hierarchy
# totals alongside a clock bucket counts those twice (that error surfaced as
# negative glue on the M-heavy shapes).
#   clock_dist   : any *CTS_* buffer or *clk_gate* cell, wherever it lives
#                  (= the BOS convention: clock tree is CTS + ICG cells)
#   rng_total    : remaining leaves under u_a_rng / u_w_rng (Sobol banks)
#   periph_total : remaining leaves under u_peripheral (operand regs + cmp)
#   acc_reg      : sequential leaves inside *u_inner (accumulator state)
#   popcount     : combinational leaves inside *u_inner (tile compute cone)
#   in_bit/in_sign/w_bit/w_sign : operand pipe flops (by name)
#   load_ctrl/other : remaining sequential leaves
#   glue_other   : every remaining combinational leaf, plus the (small)
#                  gap between the leaf sum and report_power's Total
# Flop buckets include each flop's clock-pin internal power (it is part of
# the cell's internal_power attribute).
set DESIGN_NAME $env(TOP)
set SAIF_FILE   $env(SAIF_FILE)
set SAIF_STRIP_PATH "Top/dut"
set NL   [expr {[info exists env(NL)]   && $env(NL)   ne "" ? $env(NL)   : "outputs/${DESIGN_NAME}.apr.v"}]
set SDC  [expr {[info exists env(SDC)]  && $env(SDC)  ne "" ? $env(SDC)  : "${DESIGN_NAME}.syn.sdc"}]
set SPEF [expr {[info exists env(SPEF)] ? $env(SPEF) : "outputs/${DESIGN_NAME}.spef"}]
set OUT  [expr {[info exists env(OUT)]  && $env(OUT)  ne "" ? $env(OUT)  : "reports/array_components.rpt"}]
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

set comb 0.0; set reg 0.0; set clk 0.0; set tot 0.0
redirect -variable grp { report_power -significant_digits 6 -nosplit }
foreach l [split $grp "\n"] {
    if {[regexp {^\s*combinational\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> d]} { set comb $d }
    if {[regexp {^\s*register\s+(\S+)\s+\S+\s+\S+\s+(\S+)} $l -> a d]} { set reg $d }
    if {[regexp {^\s*clock_network\s+\S+\s+\S+\s+\S+\s+(\S+)} $l -> d]} { set clk $d }
    if {[regexp {Total Power\s*=\s*(\S+)} $l -> t]} { set tot $t }
}

# single walk over every physical leaf, each counted exactly once
array set B {}
foreach k {clock rng periph acc popcount in_bits w_bits in_sign w_sign \
           drain load other glue} { set B($k) 0.0 }
set nseq 0
set leaf_sum 0.0
set leaves [get_cells -hierarchical -filter {is_hierarchical==false}]
set nleaves [sizeof_collection $leaves]
proc pattr {c a} {
    set v [get_attribute -quiet $c $a]
    return [expr {$v eq "" ? 0.0 : $v}]
}
# clock and glue are split by scope: *_pe = leaf lives under u_pe/, *_fe =
# under the RNG/converter front end (u_a_rng, u_w_rng, u_peripheral), *_top =
# everything else.  The front end's own ICGs/CTS ride with clock_fe so a
# sharing analysis can amortize them together with the RNG.
foreach k {clock_pe clock_fe clock_top glue_pe glue_ext other_ext \
           rng_a rng_w} { set B($k) 0.0 }
set pe_total 0.0
foreach_in_collection c $leaves {
    set nm [get_object_name $c]
    set p [expr {[pattr $c internal_power] + [pattr $c switching_power] \
               + [pattr $c leakage_power]}]
    set leaf_sum [expr {$leaf_sum + $p}]
    set seq [expr {[get_attribute $c is_sequential] eq "true"}]
    if {$seq} { incr nseq }
    set in_pe [string match *u_pe/* $nm]
    set in_fe [expr {[string match *u_a_rng/* $nm] || [string match *u_w_rng/* $nm] \
                  || [string match *u_peripheral/* $nm]}]
    if {$in_pe} { set pe_total [expr {$pe_total + $p}] }
    if {[string match *CTS_* $nm] || [string match *clk_gate* $nm]} {
        set bucket [expr {$in_pe ? "clock_pe" : ($in_fe ? "clock_fe" : "clock_top")}]
    } elseif {[string match *u_a_rng/* $nm]} { set bucket rng_a
    } elseif {[string match *u_w_rng/* $nm]} { set bucket rng_w
    } elseif {[string match *u_peripheral/* $nm]} { set bucket periph
    } elseif {[string match *u_inner*/* $nm]} {
        set bucket [expr {$seq ? "acc" : "popcount"}]
    } elseif {!$seq} { set bucket [expr {$in_pe ? "glue_pe" : "glue_ext"}]
    } elseif {[string match *a_bits_pipe_reg* $nm]}  { set bucket in_bits
    } elseif {[string match *w_bits_pipe_reg* $nm]}  { set bucket w_bits
    } elseif {[string match *w_encoded_pipe_reg* $nm]} { set bucket w_bits
    } elseif {[string match *w_keep_pipe_reg* $nm]}  { set bucket w_bits
    } elseif {[string match *a_signs_pipe_reg* $nm]} { set bucket in_sign
    } elseif {[string match *w_signs_pipe_reg* $nm]} { set bucket w_sign
    } elseif {[string match *drain_reg_reg* $nm]}    { set bucket drain
    } elseif {[string match *load_* $nm] && [string match *_q_reg* $nm]} { set bucket load
    } elseif {!$in_pe} { set bucket other_ext
    } else { set bucket other }
    set B($bucket) [expr {$B($bucket) + $p}]
}
set B(rng)   [expr {$B(rng_a) + $B(rng_w)}]
set B(clock) [expr {$B(clock_pe) + $B(clock_fe) + $B(clock_top)}]
set B(glue)  [expr {$B(glue_pe) + $B(glue_ext)}]
set ntiles [sizeof_collection \
    [get_cells -quiet -hierarchical -filter {is_hierarchical==true} *u_inner]]
# net switching not attributed to a driving leaf (primary-input nets etc.)
set resid [expr {$tot - $leaf_sum}]
set B(glue) [expr {$B(glue) + $resid}]
set rng_total    $B(rng)
set periph_total $B(periph)
set popcount     $B(popcount)
set clock_dist   $B(clock)
set pipes        [expr {$B(in_bits) + $B(w_bits) + $B(in_sign) + $B(w_sign)}]
set glue         $B(glue)

proc mw {x} { return [format "%.6f" [expr {$x*1000.0}]] }
catch { file mkdir [file dirname $OUT] }
set fh [open $OUT w]
puts $fh "DESIGN $DESIGN_NAME  nseq $nseq  nleaves $nleaves  ntiles $ntiles  unattributed_mW [mw $resid]"
puts $fh "group_mW comb [mw $comb] register [mw $reg] clock_network [mw $clk] TOTAL [mw $tot]"
puts $fh "rng_total      [mw $rng_total]"
puts $fh "periph_total   [mw $periph_total]"
puts $fh "in_bit_reg     [mw $B(in_bits)]"
puts $fh "w_bit_reg      [mw $B(w_bits)]"
puts $fh "in_sign_reg    [mw $B(in_sign)]"
puts $fh "w_sign_reg     [mw $B(w_sign)]"
puts $fh "acc_reg        [mw $B(acc)]"
puts $fh "drain_reg      [mw $B(drain)]"
puts $fh "load_ctrl_reg  [mw $B(load)]"
puts $fh "other_reg      [mw $B(other)]"
puts $fh "popcount_logic [mw $popcount]"
puts $fh "clock_dist     [mw $clock_dist]"
puts $fh "clock_pe       [mw $B(clock_pe)]"
puts $fh "clock_fe       [mw $B(clock_fe)]"
puts $fh "clock_top      [mw $B(clock_top)]"
puts $fh "rng_a_total    [mw $B(rng_a)]"
puts $fh "rng_w_total    [mw $B(rng_w)]"
puts $fh "glue_other     [mw $glue]"
puts $fh "glue_pe        [mw $B(glue_pe)]"
puts $fh "other_ext_reg  [mw $B(other_ext)]"
puts $fh "pe_total       [mw $pe_total]"
puts $fh "check_sum      [mw [expr {$rng_total+$periph_total+$popcount+$B(acc)+$pipes+$B(drain)+$B(load)+$B(other)+$B(other_ext)+$clock_dist+$glue}]]   TOTAL [mw $tot]"
puts $fh "check_pe       [mw [expr {$popcount+$B(acc)+$pipes+$B(drain)+$B(load)+$B(other)+$B(clock_pe)+$B(glue_pe)}]]   PE_TOTAL [mw $pe_total]"
close $fh
puts "ARRAY_COMPONENTS_DONE $DESIGN_NAME"
exit
