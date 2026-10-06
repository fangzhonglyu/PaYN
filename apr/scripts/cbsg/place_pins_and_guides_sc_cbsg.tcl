# C-BSG copy of apr/scripts/place_pins_and_guides_sc.tcl (that file is shared
# and stays unchanged) for the two C-BSG tops of the carry-save array:
#   payn_array_signed_segmented_csa_cbsg_af  (TSMC22/PAYN_SC_CSA_CBSG_AF)
#   payn_array_signed_segmented_csa_cbsg_rg  (TSMC22/PAYN_SC_CSA_CBSG_RG)
# Both keep every CSA port and add a per-row stream-length bus (AF a_len_in,
# RG row_len_in, N_H x 8 bits) and two scalars (block_start, slice_start).
# The shared script would put the 64 length bits on the SOUTH edge (east half,
# with an "unrecognised pin" warning), far from the row each one serves.
# Differences from the shared script (everything else is byte-for-byte the
# same plan and the same audit):
#   * the per-row length bus <len>[h*LW +: LW] is an EAST pin group of row h,
#     placed in the middle of the row band right before that row's
#     acc_out_east block (the length is row data, like a_signs_in; it feeds
#     the row's kA encoders (AF) or the row's t < L gate of the A comparators
#     (RG), both in u_peripheral at the east edge);
#   * block_start and slice_start join the SOUTH control list after shift_in;
#   * any other unrecognised port is an ERROR (fail closed), not a warning:
#     the C-BSG port list is known, so a stray port means a wrong netlist;
#   * the distribution guides are the SHARED apr/scripts/
#     place_guides_sc_distribution.tcl, sourced from the parent directory (the
#     guide globs a_bits_pipe_reg_<h>__* / a_signs_pipe_reg_<h>__* and
#     w_bits_pipe_reg_<v>__* / w_signs_pipe_reg_<v>__* match both C-BSG
#     netlists: AF 544 A + 544 W cells as the CSA; RG 544 A + 288 W cells, the
#     RG w_bits_pipe holding the 8-bit W magnitudes in 2-bit multibit flops);
#   * the SC_PIN_PLACEMENT line appends "len_bus=<name> LEN_W=<bits>".
# Dry run without Innovus: sweeps/cbsg/pin_dryrun/run_pin_dryrun.sh.
#
# Original header of the shared script follows.
#
# PRE_PLACE_SCRIPT: SC distribution guides plus FIXED top-level IO pins that
# follow the N_H x N_W tile grid.
#
# 1. Sources place_guides_sc_distribution.tcl unchanged (same env knobs:
#    SC_NH, SC_NW, SC_DIST_HIER_PREFIX, SC_DIST_GUIDE_BAND/MARGIN/DENSITY).
# 2. Places every top-level pin with editPin -fixedPin before place_opt_design,
#    so GigaPlace sees fixed pins instead of 3,661 (BP) / 1,545 (CSA) float
#    pins.  apr.tcl later calls plain assignIoPins and legalizePin; neither
#    moves a Fixed pin without -moveFixedPin, so the plan survives to the DEF.
#
# Pin plan (row 0 at the top and column 0 at the west, the guide convention;
# band centres are the A-row / W-column guide band centres on the floorplan box):
#   EAST  row h : per depth k = 0..K-1: a_binary_in[(hK+k)WIDTH +: WIDTH],
#                 a_signs_in[hK+k], a_raw_in[(hK+k)M +: M] (BP only); the
#                 row's acc_out_east[h*OW +: OW] block sits in the middle of the
#                 band (between depth K/2-1 and K/2).  Index runs top->bottom.
#   NORTH col v : per depth k: w_binary_in, w_signs_in[vK+k], w_raw_in (BP).
#                 Index runs west->east.
#   WEST  row h : acc_in_west[h*OW +: OW].
#   SOUTH       : scalar control (clk, reset, rng_en, load_*, mac_en, shift_in,
#                 int_mode, int_prec, ring_in, ...) centred; int_out[*] and
#                 int_out_valid on the east half.  Any port not recognised
#                 above is appended to the south list and reported.
# Shape parameters come from the port widths: K = |a_signs_in|/N_H,
# WIDTH = |a_binary_in|/(N_H K), M = |a_raw_in|/(N_H K), OW = |acc_in_west|/N_H,
# with N_H/N_W from SC_NH/SC_NW cross-checked against the g_row_*__g_col_*
# tile instances.  The W side must agree (|w_signs_in| = N_W K, ...).
#
# Layers follow what assignIoPins uses for 96 % of its pins in the accepted
# routes: the 0.1 um-pitch layers, horizontal M2/M4/M6 on east/west edges and
# vertical M3/M5 on north/south edges.  Pin width/depth are left to editPin
# (layer minimum width, depth from minimum area, as assignIoPins produces) and
# every pin snaps to a routing track.  Consecutive pins rotate through the
# layers; the script refuses a plan whose same-layer pitch is below
# SC_PIN_MIN_PITCH_TRACKS tracks.
#
# Knobs (all optional): SC_PIN_SPAN (fraction of the tile pitch each band
# uses, default 0.90), SC_PIN_LAYERS_H ("M2 M4 M6"), SC_PIN_LAYERS_V
# ("M3 M5"), SC_PIN_TRACK_UM (0.1), SC_PIN_MIN_PITCH_TRACKS (2),
# SC_PIN_SOUTH_CTRL_STEP_UM (1.0), SC_PIN_PLAN_FILE (sc_pin_plan.tsv).
# Outputs: the plan file (requested and resulting location, layer, status per
# pin) in the run directory and one SC_PIN_PLACEMENT summary line in apr.log.

set sc_pin_script_dir [file dirname [file normalize [info script]]]
# The shared guide script one level up (apr/scripts/), unchanged.
source [file join [file dirname $sc_pin_script_dir] place_guides_sc_distribution.tcl]

proc sc_pin_env {name default} {
    global env
    if {[info exists env($name)] && $env($name) ne ""} { return $env($name) }
    return $default
}

proc sc_pin_fail {msg} {
    puts "ERROR: SC_PIN_PLACEMENT: $msg"
    exit 2
}

set sc_pin_nh $env(SC_NH)
set sc_pin_nw $env(SC_NW)
set sc_pin_span [sc_pin_env SC_PIN_SPAN 0.90]
set sc_pin_layers_h [sc_pin_env SC_PIN_LAYERS_H "M2 M4 M6"]
set sc_pin_layers_v [sc_pin_env SC_PIN_LAYERS_V "M3 M5"]
set sc_pin_track [sc_pin_env SC_PIN_TRACK_UM 0.1]
set sc_pin_min_tracks [sc_pin_env SC_PIN_MIN_PITCH_TRACKS 2]
set sc_pin_ctrl_step [sc_pin_env SC_PIN_SOUTH_CTRL_STEP_UM 1.0]
set sc_pin_plan_file [sc_pin_env SC_PIN_PLAN_FILE sc_pin_plan.tsv]
if {$sc_pin_span <= 0.0 || $sc_pin_span > 1.0} { sc_pin_fail "SC_PIN_SPAN must be in (0, 1]" }

# Layer sanity: the requested layers must exist with the expected direction.
foreach {sc_pin_layers sc_pin_dir} [list $sc_pin_layers_h Horizontal $sc_pin_layers_v Vertical] {
    if {[llength $sc_pin_layers] < 1} { sc_pin_fail "empty pin layer list" }
    foreach sc_pin_layer $sc_pin_layers {
        set sc_pin_lp [dbGet -p head.layers.name $sc_pin_layer]
        if {$sc_pin_lp eq "0x0" || [llength $sc_pin_lp] != 1} { sc_pin_fail "unknown layer $sc_pin_layer" }
        set sc_pin_ldir [lindex [dbGet $sc_pin_lp.direction] 0]
        if {[string tolower $sc_pin_ldir] ne [string tolower $sc_pin_dir]} {
            sc_pin_fail "layer $sc_pin_layer is $sc_pin_ldir, expected $sc_pin_dir"
        }
    }
}

# ---------------------------------------------------------------- ports --
array unset sc_pin_bits
array unset sc_pin_scalar
array unset sc_pin_ptr
foreach sc_pin_t [dbGet top.terms] {
    set sc_pin_name [lindex [dbGet $sc_pin_t.name] 0]
    set sc_pin_ptr($sc_pin_name) $sc_pin_t
    if {[regexp {^(.+)\[(\d+)\]$} $sc_pin_name -> sc_pin_base sc_pin_idx]} {
        lappend sc_pin_bits($sc_pin_base) $sc_pin_idx
    } else {
        set sc_pin_scalar($sc_pin_name) 1
    }
}
set sc_pin_width_of [dict create]
foreach sc_pin_base [array names sc_pin_bits] {
    set sc_pin_sorted [lsort -integer -unique $sc_pin_bits($sc_pin_base)]
    set sc_pin_w [llength $sc_pin_sorted]
    if {[lindex $sc_pin_sorted 0] != 0 || [lindex $sc_pin_sorted end] != $sc_pin_w - 1 ||
        $sc_pin_w != [llength $sc_pin_bits($sc_pin_base)]} {
        sc_pin_fail "bus $sc_pin_base is not a contiguous \[w-1:0\] range"
    }
    dict set sc_pin_width_of $sc_pin_base $sc_pin_w
}
foreach sc_pin_req {a_binary_in a_signs_in w_binary_in w_signs_in acc_in_west acc_out_east} {
    if {![dict exists $sc_pin_width_of $sc_pin_req]} { sc_pin_fail "required bus $sc_pin_req not found" }
}
set sc_pin_has_raw [expr {[dict exists $sc_pin_width_of a_raw_in] || [dict exists $sc_pin_width_of w_raw_in]}]
if {$sc_pin_has_raw && !([dict exists $sc_pin_width_of a_raw_in] && [dict exists $sc_pin_width_of w_raw_in])} {
    sc_pin_fail "a_raw_in and w_raw_in must both exist or both be absent"
}

proc sc_pin_div {num den what} {
    if {$den <= 0 || $num % $den != 0} { sc_pin_fail "$what: $num is not a multiple of $den" }
    return [expr {$num / $den}]
}
set sc_pin_k  [sc_pin_div [dict get $sc_pin_width_of a_signs_in] $sc_pin_nh "K from a_signs_in"]
set sc_pin_bw [sc_pin_div [dict get $sc_pin_width_of a_binary_in] [expr {$sc_pin_nh*$sc_pin_k}] "WIDTH from a_binary_in"]
set sc_pin_ow [sc_pin_div [dict get $sc_pin_width_of acc_in_west] $sc_pin_nh "OWIDTH from acc_in_west"]
set sc_pin_m 0
if {$sc_pin_has_raw} {
    set sc_pin_m [sc_pin_div [dict get $sc_pin_width_of a_raw_in] [expr {$sc_pin_nh*$sc_pin_k}] "M from a_raw_in"]
}
foreach {sc_pin_bus sc_pin_expect} [list \
        w_signs_in [expr {$sc_pin_nw*$sc_pin_k}] \
        w_binary_in [expr {$sc_pin_nw*$sc_pin_k*$sc_pin_bw}] \
        acc_out_east [expr {$sc_pin_nh*$sc_pin_ow}]] {
    if {[dict get $sc_pin_width_of $sc_pin_bus] != $sc_pin_expect} {
        sc_pin_fail "$sc_pin_bus width [dict get $sc_pin_width_of $sc_pin_bus] != $sc_pin_expect"
    }
}
if {$sc_pin_has_raw && [dict get $sc_pin_width_of w_raw_in] != $sc_pin_nw*$sc_pin_k*$sc_pin_m} {
    sc_pin_fail "w_raw_in width [dict get $sc_pin_width_of w_raw_in] != N_W*K*M"
}
# C-BSG: exactly one per-row stream-length bus (AF a_len_in, RG row_len_in).
set sc_pin_len_bus ""
foreach sc_pin_cand {a_len_in row_len_in} {
    if {[dict exists $sc_pin_width_of $sc_pin_cand]} {
        if {$sc_pin_len_bus ne ""} { sc_pin_fail "both $sc_pin_len_bus and $sc_pin_cand exist" }
        set sc_pin_len_bus $sc_pin_cand
    }
}
if {$sc_pin_len_bus eq ""} { sc_pin_fail "no per-row length bus (a_len_in or row_len_in): not a C-BSG top" }
set sc_pin_lw [sc_pin_div [dict get $sc_pin_width_of $sc_pin_len_bus] $sc_pin_nh "LEN_W from $sc_pin_len_bus"]

# Cross-check N_H/N_W against the tile instances when the hierarchy exists.
set sc_pin_tile_rows -1
set sc_pin_tile_cols -1
set sc_pin_tiles [get_cells -quiet ${prefix}${name_separator}g_row_*__g_col_*__u_inner]
set sc_pin_tile_names {}
if {[sizeof_collection $sc_pin_tiles] > 0} { set sc_pin_tile_names [get_object_name $sc_pin_tiles] }
foreach sc_pin_tile $sc_pin_tile_names {
    if {[regexp {g_row_(\d+)__g_col_(\d+)__u_inner$} $sc_pin_tile -> sc_pin_r sc_pin_c]} {
        if {$sc_pin_r > $sc_pin_tile_rows} { set sc_pin_tile_rows $sc_pin_r }
        if {$sc_pin_c > $sc_pin_tile_cols} { set sc_pin_tile_cols $sc_pin_c }
    }
}
if {$sc_pin_tile_rows >= 0} {
    if {$sc_pin_tile_rows + 1 != $sc_pin_nh || $sc_pin_tile_cols + 1 != $sc_pin_nw} {
        sc_pin_fail "tile instances give [expr {$sc_pin_tile_rows+1}]x[expr {$sc_pin_tile_cols+1}], SC_NH x SC_NW = ${sc_pin_nh}x${sc_pin_nw}"
    }
} else {
    puts "WARNING: SC_PIN_PLACEMENT: no ${prefix}${name_separator}g_row_*__g_col_*__u_inner cells; N_H/N_W taken from SC_NH/SC_NW only"
}

# ------------------------------------------------------------ pin lists --
array unset sc_pin_used
proc sc_pin_take {name} {
    upvar 1 sc_pin_ptr ptr sc_pin_used used
    if {![info exists ptr($name)]} { sc_pin_fail "pin $name does not exist" }
    if {[info exists used($name)]} { sc_pin_fail "pin $name assigned twice" }
    set used($name) 1
    return $name
}

set sc_pin_east [dict create]
set sc_pin_north [dict create]
set sc_pin_west [dict create]
for {set h 0} {$h < $sc_pin_nh} {incr h} {
    set row_pins {}
    for {set k 0} {$k < $sc_pin_k} {incr k} {
        if {$k == $sc_pin_k / 2} {
            # C-BSG: the row's stream length, then its acc_out_east block.
            for {set i 0} {$i < $sc_pin_lw} {incr i} {
                lappend row_pins [sc_pin_take "$sc_pin_len_bus\[[expr {$h*$sc_pin_lw+$i}]\]"]
            }
            for {set i 0} {$i < $sc_pin_ow} {incr i} {
                lappend row_pins [sc_pin_take "acc_out_east\[[expr {$h*$sc_pin_ow+$i}]\]"]
            }
        }
        set g [expr {$h*$sc_pin_k+$k}]
        for {set b 0} {$b < $sc_pin_bw} {incr b} {
            lappend row_pins [sc_pin_take "a_binary_in\[[expr {$g*$sc_pin_bw+$b}]\]"]
        }
        lappend row_pins [sc_pin_take "a_signs_in\[$g\]"]
        for {set m 0} {$m < $sc_pin_m} {incr m} {
            lappend row_pins [sc_pin_take "a_raw_in\[[expr {$g*$sc_pin_m+$m}]\]"]
        }
    }
    dict set sc_pin_east $h $row_pins
    set west_pins {}
    for {set i 0} {$i < $sc_pin_ow} {incr i} {
        lappend west_pins [sc_pin_take "acc_in_west\[[expr {$h*$sc_pin_ow+$i}]\]"]
    }
    dict set sc_pin_west $h $west_pins
}
for {set v 0} {$v < $sc_pin_nw} {incr v} {
    set col_pins {}
    for {set k 0} {$k < $sc_pin_k} {incr k} {
        set g [expr {$v*$sc_pin_k+$k}]
        for {set b 0} {$b < $sc_pin_bw} {incr b} {
            lappend col_pins [sc_pin_take "w_binary_in\[[expr {$g*$sc_pin_bw+$b}]\]"]
        }
        lappend col_pins [sc_pin_take "w_signs_in\[$g\]"]
        for {set m 0} {$m < $sc_pin_m} {incr m} {
            lappend col_pins [sc_pin_take "w_raw_in\[[expr {$g*$sc_pin_m+$m}]\]"]
        }
    }
    dict set sc_pin_north $v $col_pins
}
# South: known scalar control first (in a fixed order), then other scalars,
# then int_out / int_out_valid, then any unrecognised bus bits.
set sc_pin_ctrl_order {clk reset rng_en load_a load_w load_a_sign load_w_sign mac_en shift_in block_start slice_start int_mode int_prec ring_in}
set sc_pin_south_ctrl {}
set sc_pin_south_out {}
set sc_pin_unknown {}
foreach sc_pin_name $sc_pin_ctrl_order {
    if {[info exists sc_pin_scalar($sc_pin_name)]} { lappend sc_pin_south_ctrl [sc_pin_take $sc_pin_name] }
}
foreach sc_pin_name [lsort [array names sc_pin_scalar]] {
    if {[info exists sc_pin_used($sc_pin_name)] || $sc_pin_name eq "int_out_valid"} { continue }
    lappend sc_pin_south_ctrl [sc_pin_take $sc_pin_name]
    lappend sc_pin_unknown $sc_pin_name
}
if {[dict exists $sc_pin_width_of int_out]} {
    for {set i 0} {$i < [dict get $sc_pin_width_of int_out]} {incr i} {
        lappend sc_pin_south_out [sc_pin_take "int_out\[$i\]"]
    }
}
if {[info exists sc_pin_scalar(int_out_valid)]} { lappend sc_pin_south_out [sc_pin_take int_out_valid] }
foreach sc_pin_base [lsort [dict keys $sc_pin_width_of]] {
    for {set i 0} {$i < [dict get $sc_pin_width_of $sc_pin_base]} {incr i} {
        set sc_pin_name "$sc_pin_base\[$i\]"
        if {![info exists sc_pin_used($sc_pin_name)]} {
            lappend sc_pin_south_out [sc_pin_take $sc_pin_name]
            lappend sc_pin_unknown $sc_pin_name
        }
    }
}
if {[llength $sc_pin_unknown] > 0} {
    # C-BSG: fail closed (the shared script only warns).
    sc_pin_fail "[llength $sc_pin_unknown] unrecognised pin(s): [lrange $sc_pin_unknown 0 9]"
}
if {[array size sc_pin_used] != [array size sc_pin_ptr]} {
    sc_pin_fail "planned [array size sc_pin_used] of [array size sc_pin_ptr] pins"
}

# ------------------------------------------------------------ geometry --
set sc_pin_fp [dbFPlanBox [dbHeadFPlan]]
set sc_pin_llx [dbDBUToMicrons [lindex $sc_pin_fp 0]]
set sc_pin_lly [dbDBUToMicrons [lindex $sc_pin_fp 1]]
set sc_pin_urx [dbDBUToMicrons [lindex $sc_pin_fp 2]]
set sc_pin_ury [dbDBUToMicrons [lindex $sc_pin_fp 3]]
set sc_pin_tile_w [expr {($sc_pin_urx-$sc_pin_llx)/double($sc_pin_nw)}]
set sc_pin_tile_h [expr {($sc_pin_ury-$sc_pin_lly)/double($sc_pin_nh)}]
set sc_pin_plan {}
set sc_pin_min_pitch 1e9
set sc_pin_corner_keep 1.0

# Spread pins over [center-span/2, center+span/2] along one edge, rotating
# through the layers.  dir=+1 runs low->high coordinate, -1 high->low.
proc sc_pin_spread {pins edge group center span dir layers} {
    upvar 1 sc_pin_plan plan sc_pin_min_pitch min_pitch
    upvar 1 sc_pin_llx llx sc_pin_lly lly sc_pin_urx urx sc_pin_ury ury
    upvar 1 sc_pin_track track sc_pin_min_tracks min_tracks sc_pin_corner_keep keep
    set n [llength $pins]
    if {$n == 0} { return }
    set nl [llength $layers]
    set step [expr {$span/double($n)}]
    if {$n > $nl} {
        set pitch [expr {$step*$nl}]
        if {$pitch < $min_pitch} { set min_pitch $pitch }
        if {$pitch < $min_tracks*$track} {
            sc_pin_fail "$edge group $group: same-layer pitch [format %.3f $pitch] um < $min_tracks tracks ($n pins, $nl layers, span [format %.2f $span] um)"
        }
    }
    if {$edge eq "E" || $edge eq "W"} { set lo $lly; set hi $ury } else { set lo $llx; set hi $urx }
    for {set i 0} {$i < $n} {incr i} {
        set c [expr {$center + $dir*($span*(($i+0.5)/double($n) - 0.5))}]
        if {$c < $lo + $keep || $c > $hi - $keep} {
            sc_pin_fail "$edge group $group pin [lindex $pins $i] at [format %.3f $c] is within $keep um of a corner"
        }
        switch -- $edge {
            E { set x $urx; set y $c; set side Right }
            W { set x $llx; set y $c; set side Left }
            N { set x $c; set y $ury; set side Top }
            S { set x $c; set y $lly; set side Bottom }
        }
        lappend plan [list [lindex $pins $i] $edge $group [lindex $layers [expr {$i % $nl}]] $x $y $side]
    }
}

for {set h 0} {$h < $sc_pin_nh} {incr h} {
    set yc [expr {$sc_pin_lly+($sc_pin_nh-$h-0.5)*$sc_pin_tile_h}]
    sc_pin_spread [dict get $sc_pin_east $h] E $h $yc [expr {$sc_pin_span*$sc_pin_tile_h}] -1 $sc_pin_layers_h
    sc_pin_spread [dict get $sc_pin_west $h] W $h $yc [expr {$sc_pin_span*$sc_pin_tile_h}] -1 $sc_pin_layers_h
}
for {set v 0} {$v < $sc_pin_nw} {incr v} {
    set xc [expr {$sc_pin_llx+($v+0.5)*$sc_pin_tile_w}]
    sc_pin_spread [dict get $sc_pin_north $v] N $v $xc [expr {$sc_pin_span*$sc_pin_tile_w}] 1 $sc_pin_layers_v
}
set sc_pin_die_w [expr {$sc_pin_urx-$sc_pin_llx}]
set sc_pin_nctrl [llength $sc_pin_south_ctrl]
sc_pin_spread $sc_pin_south_ctrl S ctrl [expr {$sc_pin_llx+0.5*$sc_pin_die_w}] \
    [expr {$sc_pin_nctrl*$sc_pin_ctrl_step}] 1 $sc_pin_layers_v
if {[llength $sc_pin_south_out] > 0} {
    sc_pin_spread $sc_pin_south_out S out [expr {$sc_pin_llx+0.775*$sc_pin_die_w}] \
        [expr {0.35*$sc_pin_die_w}] 1 $sc_pin_layers_v
}

# --------------------------------------------------------------- place --
set sc_pin_t0 [clock milliseconds]
setPinAssignMode -pinEditInBatch true
foreach sc_pin_rec $sc_pin_plan {
    lassign $sc_pin_rec sc_pin_name sc_pin_edge sc_pin_group sc_pin_layer sc_pin_x sc_pin_y sc_pin_side
    editPin -pin $sc_pin_name -side $sc_pin_side -layer $sc_pin_layer \
        -assign [list $sc_pin_x $sc_pin_y] -fixedPin 1 -snap TRACK
}
setPinAssignMode -pinEditInBatch false
set sc_pin_ms [expr {[clock milliseconds]-$sc_pin_t0}]

# --------------------------------------------------------------- audit --
set sc_pin_fo [open $sc_pin_plan_file w]
puts $sc_pin_fo "pin\tedge\tgroup\tlayer_req\tx_req\ty_req\tlayer\tx\ty\tstatus"
set sc_pin_bad 0
set sc_pin_max_shift 0.0
array unset sc_pin_edge_count
foreach sc_pin_rec $sc_pin_plan {
    lassign $sc_pin_rec sc_pin_name sc_pin_edge sc_pin_group sc_pin_layer sc_pin_x sc_pin_y sc_pin_side
    set sc_pin_t $sc_pin_ptr($sc_pin_name)
    # A single-object dbGet returns a one-element list.
    set sc_pin_status [lindex [dbGet $sc_pin_t.pStatus] 0]
    set sc_pin_pt [lindex [dbGet $sc_pin_t.pt] 0]
    set sc_pin_lname [lindex [dbGet $sc_pin_t.layer.name] 0]
    lassign $sc_pin_pt sc_pin_ax sc_pin_ay
    puts $sc_pin_fo [join [list $sc_pin_name $sc_pin_edge $sc_pin_group $sc_pin_layer \
        [format %.4f $sc_pin_x] [format %.4f $sc_pin_y] $sc_pin_lname $sc_pin_ax $sc_pin_ay $sc_pin_status] "\t"]
    incr sc_pin_edge_count($sc_pin_edge)
    set sc_pin_shift [expr {abs($sc_pin_ax-$sc_pin_x)+abs($sc_pin_ay-$sc_pin_y)}]
    if {$sc_pin_shift > $sc_pin_max_shift} { set sc_pin_max_shift $sc_pin_shift }
    if {$sc_pin_status ne "fixed" || $sc_pin_lname ne $sc_pin_layer || $sc_pin_shift > $sc_pin_track} {
        if {$sc_pin_bad < 10} {
            puts "ERROR: SC_PIN_PLACEMENT: $sc_pin_name requested $sc_pin_layer ($sc_pin_x, $sc_pin_y) fixed; got $sc_pin_lname ($sc_pin_ax, $sc_pin_ay) $sc_pin_status"
        }
        incr sc_pin_bad
    }
}
close $sc_pin_fo
if {$sc_pin_bad > 0} { sc_pin_fail "$sc_pin_bad pin(s) not at their fixed planned location; see $sc_pin_plan_file" }
checkPinAssignment -outFile sc_pin_plan.checkPin.rpt

puts [format "SC_PIN_PLACEMENT: fixed=%d east=%d north=%d west=%d south=%d nh=%d nw=%d K=%d WIDTH=%d M=%d OWIDTH=%d raw=%d span=%.2f layersH={%s} layersV={%s} min_same_layer_pitch_um=%.3f max_snap_um=%.3f edit_ms=%d plan=%s len_bus=%s LEN_W=%d" \
    [llength $sc_pin_plan] $sc_pin_edge_count(E) $sc_pin_edge_count(N) $sc_pin_edge_count(W) $sc_pin_edge_count(S) \
    $sc_pin_nh $sc_pin_nw $sc_pin_k $sc_pin_bw $sc_pin_m $sc_pin_ow $sc_pin_has_raw $sc_pin_span \
    $sc_pin_layers_h $sc_pin_layers_v $sc_pin_min_pitch $sc_pin_max_shift $sc_pin_ms [file normalize $sc_pin_plan_file] \
    $sc_pin_len_bus $sc_pin_lw]
