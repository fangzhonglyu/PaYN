#!/bin/bash
# Dry run (plain tclsh, no Innovus, no license) of the APR pre-placement Tcl on a C-BSG synthesized netlist:
# fixed grid-matched pins (apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl, which sources the shared
# apr/scripts/place_guides_sc_distribution.tcl) and/or the guides alone (the bootstrap / floating-final
# PRE_PLACE_SCRIPT).  The Innovus calls are mocked (sweeps/cbsg/pin_dryrun/innovus_mock.tcl) on the real port
# list and instance names (sweeps/cbsg/pin_dryrun/netlist_mockdb.py); the floorplan box is estimated from the
# synthesized area with apr.tcl's floorPlan -r 1 0.70 10 10 10 10.
#
#   bash sweeps/cbsg/pin_dryrun/run_pin_dryrun.sh af|rg [pins|guides|shared_pins] [OUT_DIR]
#     pins         apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl (pinned pass 2)        [default]
#     guides       apr/scripts/place_guides_sc_distribution.tcl (bootstrap and floating final)
#     shared_pins  apr/scripts/place_pins_and_guides_sc.tcl (the shared CSA pin script, for comparison only)
# Env: AF_SYNTH_RUN / RG_SYNTH_RUN (default cbsg_af_20261005 / cbsg_rg_20261005).
# Output: OUT_DIR (default build/cbsg/<arm>/pin_dryrun/<mode>) with dryrun.log, dryrun_summary.txt,
# sc_pin_plan.tsv, guides.tsv; the last log line is PIN_DRYRUN: PASS|FAIL.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
arm=${1:?usage: run_pin_dryrun.sh af|rg [pins|guides|shared_pins] [OUT_DIR]}
mode=${2:-pins}
case "$arm" in
    af) target=TSMC22/PAYN_SC_CSA_CBSG_AF; top=payn_array_signed_segmented_csa_cbsg_af; synrun=${AF_SYNTH_RUN:-cbsg_af_20261005};;
    rg) target=TSMC22/PAYN_SC_CSA_CBSG_RG; top=payn_array_signed_segmented_csa_cbsg_rg; synrun=${RG_SYNTH_RUN:-cbsg_rg_20261005};;
    *) echo "unknown arm $arm" >&2; exit 2;;
esac
case "$mode" in
    pins) script=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl;;
    guides) script=apr/scripts/place_guides_sc_distribution.tcl;;
    shared_pins) script=apr/scripts/place_pins_and_guides_sc.tcl;;
    *) echo "unknown mode $mode" >&2; exit 2;;
esac
out=${3:-$REPO/build/cbsg/$arm/pin_dryrun/$mode}
[[ "$out" == /* ]] || out="$REPO/$out"
syndir="$REPO/syn/build/$target/$synrun"
[[ -s "$syndir/$top.syn.v" && -s "$syndir/area.rpt" ]] || { echo "missing $syndir/$top.syn.v or area.rpt" >&2; exit 2; }
rm -rf "$out"; mkdir -p "$out"
python3 sweeps/cbsg/pin_dryrun/netlist_mockdb.py "$syndir" "$top" "$out/mockdb.tcl" --util "${CORE_UTIL:-0.70}" | tee "$out/dryrun.log"
# The env the pinned pass 2 exports for the APR run (SC_DIST_HIER_PREFIX as the target would).
export SC_NH=8 SC_NW=8 SC_DIST_HIER_PREFIX=u_pe/u_array_core
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY
rc=0
MOCK_EXPECT_PINS=1; [[ "$mode" != guides ]] || MOCK_EXPECT_PINS=0
export MOCK_EXPECT_PINS
tclsh sweeps/cbsg/pin_dryrun/innovus_mock.tcl "$out/mockdb.tcl" "$REPO/$script" "$out" >> "$out/dryrun.log" 2>&1 || rc=$?
rm -f "$out/mockdb.tcl"      # regenerated on every run; the netlist is the record
grep -E '^(SC_DISTRIBUTION_GUIDES|SC_PIN_PLACEMENT|WARNING|ERROR|MOCK_ERROR|PIN_DRYRUN)' "$out/dryrun.log" | cut -c1-900
exit "$rc"
