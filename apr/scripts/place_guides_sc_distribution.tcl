# Soft row/column bands for the SC operand distribution registers.
foreach name {SC_NH SC_NW} {
    if {![info exists env($name)] || $env($name) < 1} {
        puts "ERROR: $name must be a positive integer"
        exit 1
    }
}
set n_h $env(SC_NH)
set n_w $env(SC_NW)
set prefix u_pe/u_array_core
if {[info exists env(SC_DIST_HIER_PREFIX)]} {
    set prefix $env(SC_DIST_HIER_PREFIX)
}
set name_separator /
if {[info exists env(SC_DIST_NAME_SEPARATOR)]} {
    set name_separator $env(SC_DIST_NAME_SEPARATOR)
}
set band_fraction 0.55
set edge_margin 0.03
set density 0.72
if {[info exists env(SC_DIST_GUIDE_BAND)]} {
    set band_fraction $env(SC_DIST_GUIDE_BAND)
}
if {[info exists env(SC_DIST_GUIDE_MARGIN)]} {
    set edge_margin $env(SC_DIST_GUIDE_MARGIN)
}
if {[info exists env(SC_DIST_GUIDE_DENSITY)]} {
    set density $env(SC_DIST_GUIDE_DENSITY)
}
if {$band_fraction <= 0.0 || $band_fraction > 1.0} {
    puts "ERROR: SC_DIST_GUIDE_BAND must be in (0.0, 1.0]"
    exit 1
}
if {$edge_margin < 0.0 || $edge_margin >= 0.45} {
    puts "ERROR: SC_DIST_GUIDE_MARGIN must be in \[0.0, 0.45)"
    exit 1
}
if {$density <= 0.0 || $density > 1.0} {
    puts "ERROR: SC_DIST_GUIDE_DENSITY must be in (0.0, 1.0]"
    exit 1
}

proc matching_names {patterns} {
    set objects {}
    foreach pattern $patterns {
        set collection [get_cells -quiet $pattern]
        if {[sizeof_collection $collection] > 0} {
            set objects [concat $objects [get_object_name $collection]]
        }
    }
    return [lsort -unique $objects]
}

set fp [dbFPlanBox [dbHeadFPlan]]
set llx [dbDBUToMicrons [lindex $fp 0]]
set lly [dbDBUToMicrons [lindex $fp 1]]
set urx [dbDBUToMicrons [lindex $fp 2]]
set ury [dbDBUToMicrons [lindex $fp 3]]
set tile_w [expr {($urx-$llx)/double($n_w)}]
set tile_h [expr {($ury-$lly)/double($n_h)}]
set a_total 0
set w_total 0
set w_keep_total 0

# A operands broadcast horizontally.  RTL row zero is at the top of the core,
# matching the tile-guide convention.
for {set h 0} {$h < $n_h} {incr h} {
    set y_center [expr {$lly+($n_h-$h-0.5)*$tile_h}]
    set y_half [expr {0.5*$band_fraction*$tile_h}]
    set box [format "%.3f %.3f %.3f %.3f" \
        [expr {$llx+$edge_margin*$tile_w}] [expr {$y_center-$y_half}] \
        [expr {$urx-$edge_margin*$tile_w}] [expr {$y_center+$y_half}]]
    set source_patterns [list \
        "${prefix}${name_separator}a_bits_pipe_reg_${h}__*" \
        "${prefix}${name_separator}a_signs_pipe_reg_${h}__*"]
    set sources [matching_names $source_patterns]
    if {[llength $sources] == 0} {
        puts "ERROR: no A pipeline cells found for row $h"
        exit 2
    }
    set group "SC_A_ROW_${h}"
    createInstGroup $group -guide $box -density $density
    foreach object $sources { addInstToInstGroup $group $object }
    incr a_total [llength $sources]
}

# W operands broadcast vertically.
for {set v 0} {$v < $n_w} {incr v} {
    set x_center [expr {$llx+($v+0.5)*$tile_w}]
    set x_half [expr {0.5*$band_fraction*$tile_w}]
    set box [format "%.3f %.3f %.3f %.3f" \
        [expr {$x_center-$x_half}] [expr {$lly+$edge_margin*$tile_h}] \
        [expr {$x_center+$x_half}] [expr {$ury-$edge_margin*$tile_h}]]
    set source_patterns [list \
        "${prefix}${name_separator}w_bits_pipe_reg_${v}__*" \
        "${prefix}${name_separator}w_encoded_pipe_reg_${v}__*" \
        "${prefix}${name_separator}w_signs_pipe_reg_${v}__*"]
    set keep_patterns [list \
        "${prefix}${name_separator}w_keep_pipe_reg_${v}__*"]
    set sources [matching_names $source_patterns]
    set keepers [matching_names $keep_patterns]
    if {[llength $sources] == 0} {
        puts "ERROR: no W pipeline cells found for column $v"
        exit 2
    }
    set objects [concat $sources $keepers]
    set group "SC_W_COL_${v}"
    createInstGroup $group -guide $box -density $density
    foreach object $objects { addInstToInstGroup $group $object }
    incr w_total [llength $sources]
    incr w_keep_total [llength $keepers]
}

puts "SC_DISTRIBUTION_GUIDES: nh=$n_h nw=$n_w band=$band_fraction density=$density a_cells=$a_total w_cells=$w_total w_keep=$w_keep_total"
