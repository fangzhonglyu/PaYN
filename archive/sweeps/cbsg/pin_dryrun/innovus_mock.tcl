# Dry run of an SC PRE_PLACE_SCRIPT (fixed grid-matched pins + distribution guides) in plain tclsh, without
# Innovus: the Innovus/dbGet calls those scripts make are mocked on a database built from the synthesized
# netlist (netlist_mockdb.py), and the script is sourced inside a proc with `global env SCRIPT_DIR`, exactly as
# ASTRAEA apr.tcl source_optional_user_script does.  What it proves: the Tcl logic runs to completion on the
# real port list and instance names (every port planned once, shape parameters derived, band geometry legal,
# every guide glob matches the real pipe-register names); what it cannot prove: Innovus's own legality checks
# (editPin track snapping on the real track grid, checkPinAssignment, GigaPlace), which the APR stage audits.
#
#   tclsh innovus_mock.tcl MOCKDB.tcl PRE_PLACE_SCRIPT.tcl OUT_DIR
# Env as in APR: SC_NH, SC_NW, SC_DIST_HIER_PREFIX (+ optional SC_PIN_* / SC_DIST_GUIDE_* knobs).
# Writes OUT_DIR/{sc_pin_plan.tsv,sc_pin_plan.checkPin.rpt,guides.tsv,dryrun_summary.txt}; prints
# PIN_DRYRUN: PASS|FAIL ... as its last line and exits non-zero on FAIL.

lassign $argv mock_db pre_place out_dir
source $mock_db
file mkdir $out_dir
cd $out_dir

set MOCK_DBU 2000
array set MOCK_LAYER_DIR {M1 Vertical M2 Horizontal M3 Vertical M4 Horizontal M5 Vertical M6 Horizontal M7 Vertical M8 Horizontal}
array set MOCK_CELL_SET {}
foreach c $MOCK_CELLS { set MOCK_CELL_SET($c) 1 }
array set MOCK_TERM_SET {}
foreach t $MOCK_TERMS { set MOCK_TERM_SET($t) 1 }
array set PIN {}
array set GROUP_BOX {}
array set GROUP_MEMBERS {}
array set CELL_GROUP {}
array set PIN_SLOT {}
set MOCK_ERRORS {}

proc mock_err {msg} { global MOCK_ERRORS; lappend MOCK_ERRORS $msg; puts "MOCK_ERROR: $msg" }

proc dbHeadFPlan {} { return fplan0 }
proc dbFPlanBox {fp} {
    global MOCK_DIE_UM MOCK_DBU
    set out {}
    foreach v $MOCK_DIE_UM { lappend out [expr {round($v * $MOCK_DBU)}] }
    return $out
}
proc dbDBUToMicrons {v} { global MOCK_DBU; return [expr {double($v) / $MOCK_DBU}] }
proc dbGet {args} {
    global MOCK_TERMS MOCK_LAYER_DIR PIN
    set p 0
    if {[lindex $args 0] eq "-p"} { set p 1; set args [lrange $args 1 end] }
    set e [lindex $args 0]
    if {$e eq "top.terms"} {
        set out {}
        foreach t $MOCK_TERMS { lappend out "term:$t" }
        return $out
    }
    if {$e eq "head.layers.name" && $p} {
        set l [lindex $args 1]
        if {[info exists MOCK_LAYER_DIR($l)]} { return "layer:$l" }
        return 0x0
    }
    if {[regexp {^layer:(\S+)\.direction$} $e -> l]} { return [list $MOCK_LAYER_DIR($l)] }
    if {[regexp {^term:([^.]+)\.(name|pStatus|pt|layer\.name)$} $e -> t attr]} {
        switch -- $attr {
            name       { return [list $t] }
            pStatus    { return [list [expr {[info exists PIN($t,status)] ? $PIN($t,status) : "unplaced"}]] }
            pt         { if {[info exists PIN($t,x)]} { return [list [list $PIN($t,x) $PIN($t,y)]] }
                         return [list [list 0.0 0.0]] }
            layer.name { return [list [expr {[info exists PIN($t,layer)] ? $PIN($t,layer) : ""}]] }
        }
    }
    error "mock dbGet: unsupported query: $args"
}
proc get_cells {args} {
    global MOCK_CELLS
    set out {}
    foreach a $args {
        if {$a eq "-quiet"} { continue }
        if {[string index $a 0] eq "-"} { error "mock get_cells: unsupported option $a" }
        set out [concat $out [lsearch -all -inline -glob $MOCK_CELLS $a]]
    }
    return $out
}
proc sizeof_collection {c} { return [llength $c] }
proc get_object_name {c} { return $c }
proc createInstGroup {name args} {
    global GROUP_BOX GROUP_MEMBERS
    if {[info exists GROUP_BOX($name)]} { mock_err "createInstGroup: $name exists" }
    set i [lsearch -exact $args -guide]
    if {$i < 0} { mock_err "createInstGroup $name without -guide" ; return }
    set GROUP_BOX($name) [lindex $args [expr {$i + 1}]]
    set GROUP_MEMBERS($name) {}
}
proc addInstToInstGroup {group obj} {
    global GROUP_BOX GROUP_MEMBERS CELL_GROUP MOCK_CELL_SET
    if {![info exists GROUP_BOX($group)]} { mock_err "addInstToInstGroup: no group $group"; return }
    if {![info exists MOCK_CELL_SET($obj)]} { mock_err "addInstToInstGroup: no instance $obj"; return }
    if {[info exists CELL_GROUP($obj)]} { mock_err "addInstToInstGroup: $obj already in $CELL_GROUP($obj)"; return }
    set CELL_GROUP($obj) $group
    lappend GROUP_MEMBERS($group) $obj
}
proc setPinAssignMode {args} {}
proc editPin {args} {
    global PIN MOCK_DIE_UM MOCK_TERM_SET PIN_SLOT
    array set o {-snap ""}
    foreach {k v} $args { set o($k) $v }
    set t $o(-pin)
    if {![info exists MOCK_TERM_SET($t)]} { mock_err "editPin: no term $t"; return }
    lassign $o(-assign) x y
    lassign $MOCK_DIE_UM llx lly urx ury
    set track 0.1
    switch -- $o(-side) {
        Right  { set x $urx; set y [expr {round($y / $track) * $track}]; set c $y }
        Left   { set x $llx; set y [expr {round($y / $track) * $track}]; set c $y }
        Top    { set y $ury; set x [expr {round($x / $track) * $track}]; set c $x }
        Bottom { set y $lly; set x [expr {round($x / $track) * $track}]; set c $x }
        default { mock_err "editPin $t: bad side $o(-side)"; return }
    }
    set key "$o(-side),$o(-layer),[format %.3f $c]"
    if {[info exists PIN_SLOT($key)]} { mock_err "editPin: $t and $PIN_SLOT($key) on the same track slot $key" }
    set PIN_SLOT($key) $t
    set PIN($t,x) [format %.4f $x]
    set PIN($t,y) [format %.4f $y]
    set PIN($t,layer) $o(-layer)
    set PIN($t,side) $o(-side)
    set PIN($t,status) [expr {$o(-fixedPin) == 1 ? "fixed" : "placed"}]
}
proc checkPinAssignment {args} {
    set i [lsearch -exact $args -outFile]
    set f [open [lindex $args [expr {$i + 1}]] w]
    puts $f "mock checkPinAssignment: Innovus legality not checked in a dry run"
    close $f
}

# ---- run the PRE_PLACE script the way apr.tcl does (inside a proc) ----
set SCRIPT_DIR [file dirname [file normalize $pre_place]]
proc run_pre_place {path} {
    global env SCRIPT_DIR
    puts "Running PRE_PLACE_SCRIPT script: $path"
    source $path
}
set rc [catch {run_pre_place [file normalize $pre_place]} msg]
if {$rc} { mock_err "PRE_PLACE script error: $msg" }

# ---- independent audit ----
set nh $env(SC_NH)
set nw $env(SC_NW)
lassign $MOCK_DIE_UM llx lly urx ury
set tile_w [expr {($urx - $llx) / double($nw)}]
set tile_h [expr {($ury - $lly) / double($nh)}]
set span [expr {[info exists env(SC_PIN_SPAN)] && $env(SC_PIN_SPAN) ne "" ? $env(SC_PIN_SPAN) : 0.90}]
set nfixed 0
array set side_count {Right 0 Left 0 Top 0 Bottom 0}
# MOCK_EXPECT_PINS=0: the script under test is the guide script alone (no pins to audit).
set expect_pins [expr {![info exists env(MOCK_EXPECT_PINS)] || $env(MOCK_EXPECT_PINS) ne "0"}]
set checked {}
set min_gap 1e9
if {$expect_pins} {
foreach t $MOCK_TERMS {
    if {![info exists PIN($t,status)] || $PIN($t,status) ne "fixed"} { mock_err "term $t not fixed"; continue }
    incr nfixed
    incr side_count($PIN($t,side))
}
# Row-band membership of every row-indexed EAST bus and column-band membership of every NORTH bus.
proc band_check {bus per side} {
    global PIN MOCK_TERMS llx lly urx ury tile_w tile_h span nh nw
    set n 0
    foreach t [lsearch -all -inline -glob $MOCK_TERMS "$bus\\\[*\\\]"] {
        regexp {\[(\d+)\]$} $t -> i
        set g [expr {$i / $per}]
        if {$PIN($t,side) ne $side} { mock_err "$t on $PIN($t,side), expected $side"; continue }
        if {$side eq "Right" || $side eq "Left"} {
            set c [expr {$lly + ($nh - $g - 0.5) * $tile_h}]
            set d [expr {abs($PIN($t,y) - $c)}]
            set half [expr {0.5 * $span * $tile_h + 0.05}]
        } else {
            set c [expr {$llx + ($g + 0.5) * $tile_w}]
            set d [expr {abs($PIN($t,x) - $c)}]
            set half [expr {0.5 * $span * $tile_w + 0.05}]
        }
        if {$d > $half} { mock_err "$t ([expr {$side eq "Top" ? "col" : "row"}] $g) is [format %.2f $d] um from its band centre (> [format %.2f $half])" }
        incr n
    }
    return $n
}
foreach {bus per side} [list a_binary_in 64 Right a_signs_in 8 Right acc_out_east 24 Right acc_in_west 24 Left \
                            w_binary_in 64 Top w_signs_in 8 Top a_len_in 8 Right row_len_in 8 Right] {
    if {[llength [lsearch -all -glob $MOCK_TERMS "$bus\\\[*\\\]"]] == 0} { continue }
    lappend checked "$bus=[band_check $bus $per $side]"
}
# Same-layer spacing on each edge after snapping (>= 2 tracks).
array set by_layer {}
foreach t $MOCK_TERMS {
    if {![info exists PIN($t,side)]} { continue }
    set c [expr {$PIN($t,side) in {Right Left} ? $PIN($t,y) : $PIN($t,x)}]
    lappend by_layer($PIN($t,side),$PIN($t,layer)) $c
}
foreach k [array names by_layer] {
    set s [lsort -real $by_layer($k)]
    for {set i 1} {$i < [llength $s]} {incr i} {
        set g [expr {[lindex $s $i] - [lindex $s [expr {$i - 1}]]}]
        if {$g < $min_gap} { set min_gap $g }
    }
}
if {$min_gap < 0.2 - 1e-6} { mock_err "same-layer pin gap [format %.3f $min_gap] um < 2 tracks" }
}
# Guides: every A/W pipe register of row/column i is in SC_A_ROW_i / SC_W_COL_i.
set prefix [expr {[info exists env(SC_DIST_HIER_PREFIX)] ? $env(SC_DIST_HIER_PREFIX) : "u_pe/u_array_core"}]
set gstats {}
foreach {kind stems grp} {A {a_bits_pipe a_signs_pipe} SC_A_ROW W {w_bits_pipe w_encoded_pipe w_signs_pipe w_keep_pipe} SC_W_COL} {
    set total 0
    set per {}
    for {set i 0} {$i < ($kind eq "A" ? $nh : $nw)} {incr i} {
        set g ${grp}_$i
        set n [expr {[info exists GROUP_MEMBERS($g)] ? [llength $GROUP_MEMBERS($g)] : 0}]
        lappend per $n
        incr total $n
        if {$n == 0} { mock_err "guide group $g empty or missing" }
    }
    set expect 0
    foreach stem $stems {
        foreach c [lsearch -all -inline -glob $MOCK_CELLS "$prefix/${stem}_reg_*"] {
            incr expect
            if {![regexp "^$prefix/${stem}_reg_(\\d+)__" $c -> idx]} { mock_err "unparsed register name $c"; continue }
            if {![info exists CELL_GROUP($c)] || $CELL_GROUP($c) ne "${grp}_$idx"} {
                mock_err "$c not in ${grp}_$idx"
            }
        }
    }
    if {$expect != $total} { mock_err "$kind guides hold $total cells, $expect $kind pipe registers exist" }
    lappend gstats "$kind=$total per=[join $per ,]"
}
# Registers in u_array_core that no guide covers (information: the shared guide script never covered them).
array set unguided {}
foreach c [lsearch -all -inline -glob $MOCK_CELLS "$prefix/*_reg*"] {
    if {[info exists CELL_GROUP($c)] || [string match "*clk_gate*" $c]} { continue }
    set stem [regsub -all {\d+} [lindex [split [string range $c [string length "$prefix/"] end] "/"] 0] "#"]
    regsub {_reg.*$} $stem "" stem
    incr unguided($stem)
}
set ug {}
foreach k [lsort [array names unguided]] { lappend ug "$k:$unguided($k)" }
set f [open guides.tsv w]
puts $f "group\tbox\tcells"
foreach g [lsort [array names GROUP_BOX]] { puts $f "$g\t$GROUP_BOX($g)\t[llength $GROUP_MEMBERS($g)]" }
close $f
set status [expr {[llength $MOCK_ERRORS] == 0 ? "PASS" : "FAIL"}]
set summary [format "PIN_DRYRUN: %s top=%s script=%s terms=%d fixed=%d E=%d N=%d W=%d S=%d die_um=%.2f(est) band_checks={%s} min_same_layer_gap_um=%s guides={%s} unguided_core_regs={%s} errors=%d" \
    $status $MOCK_TOP [file tail $pre_place] [llength $MOCK_TERMS] $nfixed $side_count(Right) $side_count(Top) \
    $side_count(Left) $side_count(Bottom) [expr {$urx - $llx}] [join $checked " "] [expr {$expect_pins ? [format %.3f $min_gap] : "n/a"}] [join $gstats "; "] \
    [join $ug " "] [llength $MOCK_ERRORS]]
set f [open dryrun_summary.txt w]
foreach e $MOCK_ERRORS { puts $f "MOCK_ERROR: $e" }
puts $f $summary
close $f
puts $summary
exit [expr {$status eq "PASS" ? 0 : 1}]
