# Start from ROC_flow's characterized GF22 synthesis subset, then remove the
# cells for which its physical sensitive-region database has no entry.  This
# prevents layout strikes from being silently assigned zero collected charge.
source ${SCRIPT_DIR}/GF22_limit_cell.tcl

set roc_uncharacterized_cells [get_lib_cells {
    */UDBSLT20_AO21B_0P75
    */UDBSLT20_AO21_0P75
    */UDBSLT20_AOAI211_0P75
    */UDBSLT20_EO3_0P75
    */UDBSLT20_MAJI3B_0P75
    */UDBSLT20_MAJI3_1
    */UDBSLT20_NR4_0P75
    */UDBSLT20_OA21B_0P75
    */UDBSLT20_OAOI211_0P75
}]
set_dont_use $roc_uncharacterized_cells
puts "ROC sensitive-region exclusions: [get_object_name $roc_uncharacterized_cells]"
