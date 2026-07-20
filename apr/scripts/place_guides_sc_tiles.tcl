# One soft placement guide per output-stationary accumulator tile.
foreach name {SC_NH SC_NW} {
    if {![info exists env($name)] || $env($name) < 1} {
        puts "ERROR: $name must be a positive integer"
        exit 1
    }
}
set n_h $env(SC_NH)
set n_w $env(SC_NW)
set hierarchy_style canonical
if {[info exists env(SC_TILE_HIER_STYLE)]} {
    set hierarchy_style $env(SC_TILE_HIER_STYLE)
}
set hierarchy_prefix u_core
if {[info exists env(SC_TILE_HIER_PREFIX)]} {
    set hierarchy_prefix $env(SC_TILE_HIER_PREFIX)
}
if {$hierarchy_style ni {canonical manual}} {
    puts "ERROR: SC_TILE_HIER_STYLE must be canonical or manual"
    exit 1
}
set margin 0.05
set density 0.76
if {[info exists env(SC_TILE_GUIDE_MARGIN)]} {
    set margin $env(SC_TILE_GUIDE_MARGIN)
}
if {[info exists env(SC_TILE_GUIDE_DENSITY)]} {
    set density $env(SC_TILE_GUIDE_DENSITY)
}
if {$margin < 0.0 || $margin >= 0.45} {
    puts "ERROR: SC_TILE_GUIDE_MARGIN must be in \[0.0, 0.45)"
    exit 1
}
if {$density <= 0.0 || $density > 1.0} {
    puts "ERROR: SC_TILE_GUIDE_DENSITY must be in (0.0, 1.0]"
    exit 1
}

set fp [dbFPlanBox [dbHeadFPlan]]
set llx [dbDBUToMicrons [lindex $fp 0]]
set lly [dbDBUToMicrons [lindex $fp 1]]
set urx [dbDBUToMicrons [lindex $fp 2]]
set ury [dbDBUToMicrons [lindex $fp 3]]
set tile_w [expr {($urx-$llx)/double($n_w)}]
set tile_h [expr {($ury-$lly)/double($n_h)}]
set added 0
for {set h 0} {$h < $n_h} {incr h} {
    for {set v 0} {$v < $n_w} {incr v} {
        set x1 [expr {$llx+$v*$tile_w+$margin*$tile_w}]
        set x2 [expr {$llx+($v+1)*$tile_w-$margin*$tile_w}]
        set y1 [expr {$lly+($n_h-1-$h)*$tile_h+$margin*$tile_h}]
        set y2 [expr {$lly+($n_h-$h)*$tile_h-$margin*$tile_h}]
        set box [format "%.3f %.3f %.3f %.3f" $x1 $y1 $x2 $y2]
        set group "SC_TILE_H${h}_V${v}"
        if {[catch {createInstGroup $group -guide $box -density $density} msg]} {
            puts "ERROR: create $group failed: $msg"
            exit 1
        }
        if {$hierarchy_style eq "manual"} {
            set inst "${hierarchy_prefix}/g_row_${h}__g_col_${v}__u_inner"
        } else {
            set inst "${hierarchy_prefix}/g_inner_h_${h}__g_inner_v_${v}__u_inner"
        }
        set objects [get_object_name [get_cells -quiet $inst]]
        if {[llength $objects] != 1} {
            puts "ERROR: expected one retained tile at $inst, found [llength $objects]"
            exit 1
        }
        if {[catch {addInstToInstGroup $group [lindex $objects 0]} msg]} {
            puts "ERROR: add $inst failed: $msg"
            exit 1
        }
        incr added
    }
}
puts "SC_TILE_GUIDES: style=$hierarchy_style prefix=$hierarchy_prefix nh=$n_h nw=$n_w margin=$margin density=$density added=$added"
