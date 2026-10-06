#!/bin/bash
# AF pinned pass 2 with a DRC fix: the recipe of sweeps/cbsg/run_cbsg_pinned_pass2.sh's do_apr (same modules,
# exports, guides, bootstrap SAIF, workload power opt, PRE_REPORT_SCRIPT) under a new run name, with ONE fix option
# applied, then the driver's do_qualify (run_popcount_apr.sh's check_apr 'final' extracted at run time; if only
# residual geometry/antenna markers remain, the targeted repair sweeps/repair_popcount_apr.sh, then check_apr again).
# Written 2026-10-05: the campaign's pinned route cbsg_af_20261005_distguide_spp_pins fails the final DRC check
# because NanoRoute's auto-stop skipped search-and-repair in the strong reroute after the flow's second (no-DRC-check)
# filler pass (68,476 markers > 62,713 routable nets; every other route in the repo stayed below 1.0 and iterated).
# Root cause and the fix ladder: build/power_char/cbsg_20261005/af/pinned_fix/README.txt.
#
#   bash sweeps/cbsg/af/run_af_pinned_fix.sh FIX OUT_DIR
#   FIX = lensouth   fix option (a): apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_lensouth.tcl (the per-row
#                    length bus on the SOUTH out group, where the shared pin script puts it; east edge = CSA's 768)
#   FIX = csadie     fix option (b): apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_csadie.tcl (the CSA pinned route's
#                    die and core boxes, fixed, then the lensouth plan: every edge's pin pitch equals the CSA's)
#   FIX = postfill   fix option (c): apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_postfill.tcl (the campaign's pin plan
#                    unchanged; the flow's PRE_REPORT_SCRIPT hook pointed at apr/scripts/cbsg/postfill_search_repair.tcl,
#                    which reruns the flow's strong reroute with -drouteAutoStop false if >= 1000 markers remain)
#   Run name: cbsg_af_20261005_distguide_spp_pins_<FIX>.  Stages (PASS markers in OUT_DIR, RETRY_FAILED=1 resumes):
#   apr      make apr + pin-plan / guide / fixed-pin checks (the driver's do_apr checks)
#   qualify  check_apr final (+ targeted repair of residual markers only) -> OUT_DIR/qualification.json
# The measurement stages then run with sweeps/cbsg/af/run_af_route_measure.sh RUN OUT_DIR/measure LABEL --pin-plan.
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 FIX OUT_DIR" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
FIX=$1; OUTD=$2
RETRY_FAILED=${RETRY_FAILED:-0}
case "$FIX" in
    lensouth) PIN_SCRIPT=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_lensouth.tcl; LEN_TAG="len_edge=south_out ";;
    csadie)   PIN_SCRIPT=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_csadie.tcl; LEN_TAG="len_edge=south_out ";;
    postfill) PIN_SCRIPT=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_postfill.tcl; LEN_TAG="";;
    *) echo "Unknown FIX $FIX" >&2; exit 2;;
esac
mkdir -p "$OUTD"; OUTD=$(readlink -f "$OUTD")
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
# ---- identical to sweeps/cbsg/run_cbsg_pinned_pass2.sh ----
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export CORE_UTIL=0.70 CORE_ASPECT=1.000 PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05
export CLOCK_UNCERTAINTY=0.125 SC_DISTRIBUTION_GUIDES=1 SC_PLACE_GUIDES=0 SC_NH=8 SC_NW=8
export APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0
unset NETLIST_FILE SDC_FILE SDF_FILE PRE_PLACE_SCRIPT POST_LOAD_SCRIPT
unset APR_ACTIVITY_FILE APR_ACTIVITY_SCOPE APR_POWER_ANALYSIS_VIEW
unset APR_WORKLOAD_POWER_OPT APR_LEAKAGE_TO_DYNAMIC_RATIO APR_DETAIL_WIRE_LENGTH_OPT_EFFORT
unset SC_DIST_HIER_PREFIX SC_TILE_HIER_PREFIX NO_SDF VCS_ARGS
export SC_DISTRIBUTION_GUIDES=0 PRE_PLACE_SCRIPT=$PIN_SCRIPT SC_DIST_HIER_PREFIX=u_pe/u_array_core
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY
unset POST_SCRIPT APR_RESUME_FINAL SKIP_FILLER FORCE_STRONG_FINAL_DRC SKIP_FINAL_HOLD_OPT FORCE_FINAL_HOLD_OPT
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
source "$REPO/sweeps/cbsg/cbsg_campaign_lib.sh"
arm=af
cbsg_arm_config af
bootrun=${synrun}_distguide
run=${bootrun}_spp_pins_${FIX}
syndir="$REPO/syn/build/$target/$synrun"
bootdir="$REPO/apr/build/$target/$bootrun"
boot_saif="$bootdir/activity/dut.saif"
finaldir="$REPO/apr/build/$target/$run"
exec 9>"$OUTD/worker.lock"
flock -n 9 || { echo "Another worker owns $OUTD" >&2; exit 2; }
guide_line=$(awk '/^SC_DISTRIBUTION_GUIDES:/{print; exit}' "$bootdir/apr.log")
[[ -n "$guide_line" ]]
# The campaign route's inputs (bootstrap SAIF, synthesis) must be the ones used here.
grep -Fxq "bootstrap_saif=$boot_saif sha256=$(sha256sum "$boot_saif" | cut -d' ' -f1)" \
    "$REPO/build/power_char/cbsg_20261005/af/pinned/inputs.txt"
grep -Fq "synthesis=$syndir netlist sha256=$(sha256sum "$syndir/$top.syn.v" | cut -d' ' -f1)" \
    "$REPO/build/power_char/cbsg_20261005/af/pinned/inputs.txt"
manifest=$(printf 'fix=%s\nrun=%s\nderived_from=apr/build/%s/%s_spp_pins (campaign pinned route; only the fix differs)\nsynthesis=%s netlist sha256=%s\nbootstrap_saif=%s sha256=%s\npre_place_script=%s sha256=%s\nguide_script sha256=%s\nflow=%s apr.tcl sha256=%s\nguides=%s\n' \
    "$FIX" "$run" "$target" "$bootrun" "$syndir" "$(sha256sum "$syndir/$top.syn.v" | cut -d' ' -f1)" \
    "$boot_saif" "$(sha256sum "$boot_saif" | cut -d' ' -f1)" "$PIN_SCRIPT" "$(sha256sum "$REPO/$PIN_SCRIPT" | cut -d' ' -f1)" \
    "$(sha256sum "$REPO/apr/scripts/place_guides_sc_distribution.tcl" | cut -d' ' -f1)" \
    "$ASTRAEA_FLOW" "$(sha256sum "$ASTRAEA_FLOW/apr/scripts/apr.tcl" | cut -d' ' -f1)" "$guide_line")
if [[ -e "$OUTD/inputs.txt" ]]; then
    [[ "$(cat "$OUTD/inputs.txt")" == "$manifest" ]] || { echo "inputs changed; see $OUTD/inputs.txt" >&2; exit 2; }
else
    printf '%s\n' "$manifest" > "$OUTD/inputs.txt"
fi

stage() {
    local name=$1 artifact=$2 marker attempt=1 log
    shift 2
    marker="$OUTD/$name.status"
    if [[ -f "$marker" ]]; then
        [[ "$(cat "$marker")" == PASS && -e "$artifact" ]] || { echo "Invalid completed stage: $name" >&2; return 1; }
        echo "[$FIX] reuse completed $name"; return
    fi
    while [[ -e "$OUTD/$name.attempt_$attempt.log" ]]; do attempt=$((attempt+1)); done
    if [[ -e "$artifact" || "$attempt" -gt 1 ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "[$FIX] Unfinished $name preserved; inspect, then RETRY_FAILED=1" >&2; return 1; }
        [[ ! -e "$artifact" ]] || mv "$artifact" "${artifact}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    fi
    log="$OUTD/$name.attempt_$attempt.log"
    echo "[$FIX] $name started $(date -Is); $log"
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[$FIX] $name passed $(date -Is)"
}

check_apr() {   # route_dir bootstrap|final
    python3 - "$REPO/sweeps/run_popcount_apr.sh" "$1" "$top" "$2" <<'PY'
from pathlib import Path
import re,subprocess,sys
runner,path,top,qualification=sys.argv[1:]
blocks=re.findall(r"<<'PY'\n(.*?)\nPY",Path(runner).read_text(),re.S)
assert blocks and 'popcount_qualification.json' in blocks[0]
subprocess.run([sys.executable,'-c',blocks[0],path,top,qualification],check=True)
PY
}

do_apr() {
    local make_status=0 log="$finaldir/apr.log"
    PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl \
    APR_WORKLOAD_POWER_OPT=1 APR_ACTIVITY_FILE="$boot_saif" APR_ACTIVITY_SCOPE=Top/dut \
    APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
    SYNTH_RUN="$synrun" RUN_NAME="$run" \
        make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" || make_status=$?
    grep -q 'Enabling workload-aware dynamic-power optimization' "$log"
    grep -q 'leakageToDynamicRatio=0.0 detail_wirelength_effort=high' "$log"
    grep -Fq "INFO: activity_file=$boot_saif scope='Top/dut'" "$log"
    grep -Fq "Running PRE_PLACE_SCRIPT script: $REPO/$PIN_SCRIPT" "$log"
    grep -Fq "$guide_line" "$log"
    if grep -q '^ERROR: SC_PIN_PLACEMENT' "$log"; then echo 'pin script error' >&2; return 1; fi
    if grep -q '^WARNING: SC_PIN_PLACEMENT' "$log"; then echo 'pin script warning' >&2; return 1; fi
    grep -Eq "^SC_PIN_PLACEMENT: fixed=1611 .* ${LEN_TAG}len_bus=a_len_in LEN_W=8\$" "$log"
    if [[ "$FIX" == csadie ]]; then
        # (Innovus may prefix a puts line with its prompt, 'innovus 1> '.)
        grep -Eq '^(innovus [0-9]+> )?SC_FIXED_DIE: die=0.000 0.000 270.060 268.520 core=10.080 10.000 259.980 258.500 ' "$log"
        grep -Eq 'Design Boundary: \(0\.0000, 0\.0000\) \(270\.0600, 268\.5200\)' "$log"
        if grep -q '^ERROR: SC_FIXED_DIE' "$log"; then echo 'fixed-die error' >&2; return 1; fi
    fi
    if [[ "$FIX" == postfill ]]; then
        grep -Fq "CBSG_POSTFILL_HOOK: PRE_REPORT_SCRIPT=$REPO/apr/scripts/cbsg/postfill_search_repair.tcl next_hook=apr/scripts/check_popcount_placement.tcl" "$log"
        grep -q 'CBSG_POSTFILL_DRC_REPAIR_END' "$log"
        grep -q 'POP_COUNT_FINAL_PLACEMENT_CHECK_END' "$log"
        grep -E 'CBSG_POSTFILL_DRC_REPAIR: ' "$log"
    fi
    grep -Eq '#fixedPin=1611, #floatPin=0\b' "$log"
    if grep -Eq '#floatPin=[1-9]' "$log"; then echo 'GigaPlace saw floating pins' >&2; return 1; fi
    grep -Eq 'Illegally Assigned Pins\s*:\s*0' "$log"
    cp -p "$finaldir/sc_pin_plan.tsv" "$finaldir/sc_pin_plan.checkPin.rpt" "$OUTD/"
    grep -E '^SC_PIN_PLACEMENT|^SC_DISTRIBUTION_GUIDES|#fixedPin=' "$log"
    # The post-filler DRC trace: second-pass fillers, markers, strong-reroute iterations vs routable nets.
    python3 "$REPO/sweeps/cbsg/af/filler_drc_trace.py" "$log" --json "$OUTD/filler_drc_trace.json" || true
    echo "make apr status=$make_status (qualification is decided by the qualify stage)"
    grep -q 'Innovus script finished' "$log"
}

do_qualify() {
    local repaired=0
    if check_apr "$finaldir" final; then
        echo "First completed route passes the strict final qualification."
    else
        echo "Strict final qualification failed; checking whether only residual DRC/antenna markers remain."
        check_apr "$finaldir" bootstrap
        python3 - "$finaldir/reports/popcount_qualification.json" <<'PY'
import json,sys
q=json.load(open(sys.argv[1]))
assert q['placement_overlapping_instances']==0 and not q['placement_late_overlap_warning'], f'placement overlaps: {q}'
assert q['geometry_drc']>0 or q['antenna_violations']>0, f'no residual markers to repair: {q}'
# The targeted repair handles a handful of local markers (the CSA baseline: 1 + 1), not a filler-wide failure.
assert q['geometry_drc']<1000, f"{q['geometry_drc']} geometry markers (verify_drc limit reached): not a residual-marker case"
print('Residual markers only (connectivity clean, timing met, placement legal):', json.dumps(q))
PY
        cbsg_repair_accepts "$target"
        cp -p "$finaldir/$top.geom.rpt" "$OUTD/first_route_geom.rpt"
        cp -p "$finaldir/$top.antenna.rpt" "$OUTD/first_route_antenna.rpt"
        REPAIR_MODE=targeted bash sweeps/repair_popcount_apr.sh "$target" "$run" "$run"
        check_apr "$finaldir" final
        repaired=1
    fi
    python3 - "$finaldir" "$OUTD" "$repaired" <<'PY'
import json,sys,datetime
from pathlib import Path
route,work,repaired=Path(sys.argv[1]),Path(sys.argv[2]),int(sys.argv[3])
q=json.loads((route/'reports'/'popcount_qualification.json').read_text())
assert q['qualification']=='final'
q['targeted_repair']=bool(repaired)
if repaired:
    q['repair_plan']=json.loads((route/'repair_plan.json').read_text())
    q['original_route_archive']=[str(p) for p in sorted(route.glob('before_legalization_*'))]
q['utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
(work/'qualification.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps(q))
PY
}

[[ ! -e "$finaldir" || -f "$OUTD/apr.status" || "$RETRY_FAILED" == 1 ]] || { echo "Refusing existing $finaldir" >&2; exit 2; }
stage apr "$finaldir" do_apr
stage qualify "$OUTD/qualification.json" do_qualify
echo "[$FIX] qualified route: $finaldir"
