# "rgtiles" variant of apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl (that
# file stays unchanged; every campaign pinned run hashes it), written
# 2026-10-05 for the RG pinned basin (build/power_char/cbsg_20261005/rg/
# cbsg_rg_20261005b/README.txt).  The RG pinned route of cbsg_rg_20261005
# landed with the tiles of each row packed 8.8 um apart (rows 45 um apart,
# corr(tile x, column) 0.81): each row's W index generators broadcast 896
# threshold bits to the row's 8 tiles, against 64 W-magnitude bits per column,
# so the placer clusters a row's tiles around its generators.  The distribution
# guides cover only the a/w pipe flops, not the tiles or the generators.
# This variant adds ONE thing: after the unchanged cbsg plan (shared
# distribution guides + every pin fixed on the 8x8 grid), one soft placement
# guide per tile, exactly the shared apr/scripts/place_guides_sc_tiles.tcl
# (sourced unchanged; grid cell (h, v) shrunk by its 5 % margin, density 0.76,
# row 0 at the top and column 0 at the west -- the same convention as the
# distribution guides and the pin plan), with the RG tile hierarchy
# u_pe/u_array_core/g_row_<h>__g_col_<v>__u_inner (SC_TILE_HIER_STYLE=manual).
# The comparators, generators and pipes stay unguided.  Knobs: those of the two
# sourced scripts (SC_TILE_GUIDE_MARGIN, SC_TILE_GUIDE_DENSITY, ...).
# Prints the cbsg SC_PIN_PLACEMENT line unchanged, then the SC_TILE_GUIDES line.
set sc_rgt_dir [file dirname [file normalize [info script]]]
source [file join $sc_rgt_dir place_pins_and_guides_sc_cbsg.tcl]
set env(SC_TILE_HIER_STYLE) manual
set env(SC_TILE_HIER_PREFIX) u_pe/u_array_core
source [file join [file dirname $sc_rgt_dir] place_guides_sc_tiles.tcl]
if {$added != $n_h * $n_w} {
    puts "ERROR: SC_TILE_GUIDES: added $added tile guides, expected [expr {$n_h * $n_w}]"
    exit 1
}
puts "SC_RGTILES_VARIANT: cbsg pin plan + distribution guides + $added soft tile guides"
