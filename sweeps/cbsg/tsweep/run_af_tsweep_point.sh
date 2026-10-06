#!/bin/bash
# One point of the AF stream-length sweep on the qualified pinned AF route, measured exactly as the headline
# (sweeps/cbsg/af/run_af_route_measure.sh: same environment, same campaign-library GL audit, same PT-PX path),
# read only on the route.  Stages (OUT_DIR = build/power_char/cbsg_20261005/tsweep/af/<tag>):
#   sim      full-timing max-SDF GL of the routed netlist with the L-sweep bench copy
#            designs/payn/power/power_payn_array_cbsg_af_vart.sv (+neg_tchk +sdfverbose, raw routed SDF):
#            bench PASS line, max-corner annotation, trace header + LADDER line, bit-exact drain
#            (sweeps/cbsg/tsweep/check_af_power_trace_vart.py: kernel == AF model == RTL), window =
#            384 * ceil(L/16) for uniform L, SAIF validation, routed-SDF clock audit
#   audit    sweeps/validate_routed_gl.py strict first (cbsg_gl_audit; no approvals are configured here, so a strict
#            failure stops the point)
#   power    PT-PX on a PT-only view apr/build/<target>/<RUN>_ptview_tsweep_<tag> (symlinks to the route's netlist,
#            SPEF, SDC) + sweeps/validate_pt_power_coverage.py
#   classes  per-class split (sweeps/cbsg/af/run_pt_power_classes.sh; must reproduce the PT total)
#   result   OUT_DIR/result.json
#
#   bash sweeps/cbsg/tsweep/run_af_tsweep_point.sh TAG        TAG = u<LLL> (uniform L, 1..128, e.g. u043) | ladder
# Environment: AF_TSWEEP_RUN (default the qualified pinned postfill route), AF_TSWEEP_OUT (output root).
set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 u<LLL>|ladder" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
TAG=$1
if [[ "$TAG" == ladder ]]; then
    WL=ladder; L=0
elif [[ "$TAG" =~ ^u([0-9]{3})$ ]]; then
    WL=uniform; L=$((10#${BASH_REMATCH[1]}))
    ((L >= 1 && L <= 128)) || { echo "L must lie in 1..128" >&2; exit 2; }
else
    echo "TAG must be u<LLL> or ladder" >&2; exit 2
fi
RUN=${AF_TSWEEP_RUN:-cbsg_af_20261005_distguide_spp_pins_postfill}
OUTROOT=${AF_TSWEEP_OUT:-$REPO/build/power_char/cbsg_20261005/tsweep/af}
OUTD="$OUTROOT/$TAG"; LABEL="af_tsweep_$TAG"
mkdir -p "$OUTD"; OUTD=$(readlink -f "$OUTD")
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
# ---- the drivers' environment (verbatim from sweeps/cbsg/af/run_af_route_measure.sh) ----
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export ZERO_PINLESS_NET_ACTIVITY=1
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export CORE_UTIL=0.70 CORE_ASPECT=1.000 PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05
export CLOCK_UNCERTAINTY=0.125 SC_PLACE_GUIDES=0 SC_NH=8 SC_NW=8
export APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0
unset NETLIST_FILE SDC_FILE SDF_FILE PRE_PLACE_SCRIPT POST_LOAD_SCRIPT
unset APR_ACTIVITY_FILE APR_ACTIVITY_SCOPE APR_POWER_ANALYSIS_VIEW
unset APR_WORKLOAD_POWER_OPT APR_LEAKAGE_TO_DYNAMIC_RATIO APR_DETAIL_WIRE_LENGTH_OPT_EFFORT
unset SC_DIST_HIER_PREFIX SC_TILE_HIER_PREFIX NO_SDF VCS_ARGS
unset AF_GL_VALIDATOR_ARGS GL_VALIDATOR_ARGS    # strict audit only
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
source "$REPO/sweeps/cbsg/cbsg_campaign_lib.sh"

arm=af
cbsg_arm_config af
TB=designs/payn/power/power_payn_array_cbsg_af_vart.sv          # the L-sweep bench copy
checker=sweeps/cbsg/tsweep/check_af_power_trace_vart.py         # its checker copy
work=$OUTD
finalrun=$RUN
finaldir="$REPO/apr/build/$target/$RUN"
[[ -s "$finaldir/outputs/$top.apr.v" && -s "$finaldir/outputs/$top.spef" && -s "$finaldir/outputs/$top.apr.sdf" ]] || {
    echo "route outputs missing in $finaldir" >&2; exit 2; }
exec 9>"$OUTD/worker.lock"
flock -n 9 || { echo "Another worker owns $OUTD" >&2; exit 2; }
{
    echo "label=$LABEL workload=$WL L=$L route=$finaldir top=$top"
    for f in "outputs/$top.apr.v" "outputs/$top.spef" "outputs/$top.apr.sdf" "$top.syn.sdc"; do
        echo "$(sha256sum "$finaldir/$f" | cut -d' ' -f1)  $f"
    done
    for f in "$TB" "$checker" sweeps/cbsg/cbsg_ref.py sweeps/cbsg/cbsg_campaign_lib.sh sweeps/cbsg/af/run_pt_power_classes.sh \
             sweeps/cbsg/af/pt_power_classes.tcl "${BASH_SOURCE[0]}"; do
        echo "$(sha256sum "$f" | cut -d' ' -f1)  $f"
    done
    echo "route qualification: $(tr -d '\n ' < "$finaldir/reports/popcount_qualification.json" 2>/dev/null)"
} > "$OUTD/inputs.$(date +%Y%m%d_%H%M%S).txt"

stage() {   # as sweeps/cbsg/af/run_af_route_measure.sh
    local name=$1 artifact=$2 marker attempt=1 log
    shift 2
    marker="$OUTD/$name.status"
    if [[ -f "$marker" && "$(cat "$marker")" == PASS && -e "$artifact" ]]; then echo "[$LABEL] reuse completed $name"; return; fi
    while [[ -e "$OUTD/$name.attempt_$attempt.log" ]]; do attempt=$((attempt+1)); done
    [[ ! -e "$artifact" ]] || mv "$artifact" "${artifact}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    log="$OUTD/$name.attempt_$attempt.log"
    echo "[$LABEL] $name started $(date -Is); $log"
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[$LABEL] $name passed $(date -Is)"
}

# cbsg_gl_sim (sweeps/cbsg/cbsg_campaign_lib.sh) with the workload generalized to uniform L.
do_sim() {   # simdir
    local simdir=$1 route="$finaldir" defs wlname wlnum re line window lad
    if [[ "$WL" == ladder ]]; then
        defs=" $ladder_def"; wlname=$ladder_name; wlnum=$ladder_wl
    else
        defs=" +define+CBSG_PWR_UNIFORM_L=$L"; wlname="uniform L=$L"; wlnum=0
    fi
    re=$(cbsg_pass_regex "$wlname")
    mkdir -p "$simdir"
    make sim GL=apr TARGET="$target" RUN="$finalrun" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs$defs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    line=$(grep -E "$re" "$simdir/simulation.log" | head -n 1 || true)
    [[ -n "$line" ]] || { echo "bench PASS line for workload '$wlname' missing in $simdir/simulation.log" >&2; return 1; }
    window=$(sed -E "s/$re/\\1/" <<< "$line")
    if [[ "$WL" == uniform && "$window" != $((CBSG_BATCHES * ((L + 15) / 16))) ]]; then
        echo "uniform L=$L ran $window window clocks, expected $((CBSG_BATCHES * ((L + 15) / 16)))" >&2; return 1
    fi
    printf '%s\n' "$line" > "$simdir/expected_pass.txt"
    grep -q 'sdf corner = max' "$simdir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$simdir/simulation.log"
    local trace="$simdir/$TB/$trace_name" saif="$simdir/$TB/dut.saif"
    [[ -s "$trace" && -s "$saif" ]]
    [[ "$(head -n 1 "$trace")" == "$(cbsg_header "$wlnum")" ]] || {
        echo "trace header '$(head -n 1 "$trace")' != '$(cbsg_header "$wlnum")'" >&2; return 1; }
    lad=$(sed -n 2p "$trace")
    if [[ "$WL" == uniform ]]; then
        [[ "$lad" == "LADDER $L" ]] || { echo "trace LADDER line '$lad' != 'LADDER $L'" >&2; return 1; }
    else
        [[ "$lad" == "LADDER 128 96 64 48 44 42 38" ]] || { echo "trace LADDER line '$lad'" >&2; return 1; }
    fi
    python3 "$checker" "$trace" --json "$simdir/trace_check.json" > "$simdir/trace_check.log" 2>&1
    grep -q '\[PASS\]' "$simdir/trace_check.log"
    python3 - "$simdir/trace_check.json" "$window" "$CBSG_BATCHES" "$WL" "$L" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); window,blocks=int(sys.argv[2]),int(sys.argv[3]); wl,L=sys.argv[4],int(sys.argv[5])
w=j.get('window_edges', j.get('window_clocks'))
assert w==window and j['blocks']==blocks and not j['errors'], (w, window, j['blocks'], j['errors'])
if wl=='uniform':
    assert j['workload']==f'uniform L={L}' and j['mean_L']==L, (j['workload'], j['mean_L'])
print(f"trace check: {j['workload']}, {j['blocks']} blocks, {w} window clocks, drain bit-exact")
PY
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 > "$simdir/saif_validation.log" 2>&1
    python3 sweeps/cbsg/routed_sdf_clock_audit.py "$route/outputs/$top.apr.sdf" --period-ns 2.5 \
        --sim-log "$simdir/simulation.log" --json "$simdir/sdf_clock_audit.json" > "$simdir/sdf_clock_audit.log" 2>&1
    cat "$simdir/trace_check.log" "$simdir/saif_validation.log" "$simdir/sdf_clock_audit.log"
}

pt_reports_check() {   # run_dir (as sweeps/cbsg/af/run_af_route_measure.sh)
    [[ -s "$1/reports/power.rpt" && -s "$1/reports/saif_coverage.rpt" && -s "$1/reports/parasitics_coverage.rpt" ]]
    grep -q 'Report : Averaged Power' "$1/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$1/reports" \
        --power-log "$1/power_apr.log" --json "$1/reports/power_coverage.json"
}

# PT-PX on a PT-only view of the route (do_pt_view of sweeps/cbsg/af/run_af_route_measure.sh, view tag tsweep_<tag>).
do_pt_view() {   # saif saved_dir
    local vname="${finalrun}_ptview_tsweep_$TAG"
    local view="$REPO/apr/build/$target/$vname" saif=$1 saved=$2 f
    [[ ! -e "$view" ]] || mv "$view" "${view}.old_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    mkdir -p "$view/outputs" "$saved"
    ln -s "$finaldir/outputs/$top.apr.v" "$view/outputs/$top.apr.v"
    ln -s "$finaldir/outputs/$top.spef" "$view/outputs/$top.spef"
    ln -s "$finaldir/$top.syn.sdc" "$view/$top.syn.sdc"
    {
        echo "PT-only view of $finaldir (AF L-sweep point $TAG, label $LABEL), written by sweeps/cbsg/tsweep/run_af_tsweep_point.sh;"
        echo "the route's own reports and activity file are untouched."
        for f in "outputs/$top.apr.v" "outputs/$top.spef" "$top.syn.sdc"; do
            echo "$(sha256sum "$finaldir/$f" | cut -d' ' -f1)  $f"
        done
    } > "$view/VIEW_OF.txt"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="$vname" \
        SAIF="$saif" SAIF_STRIP_PATH=Top/dut NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    pt_reports_check "$view"
    cmp -s "$saif" "$view/activity/dut.saif"
    cp -p "$view/power_apr.log" "$view/reports/power_coverage.json" "$view/VIEW_OF.txt" "$saved/"
    cp -p "$view"/reports/*.rpt "$saved/"
    echo "$view" > "$saved/VIEW_DIR.txt"
}

do_classes() {   # simdir powerdir outdir
    bash sweeps/cbsg/af/run_pt_power_classes.sh "$finaldir" "$top" af "$1/$TB/dut.saif" "$2/power.rpt" "$3"
}

do_result() {
    python3 - "$TAG" "$WL" "$L" "$finaldir" "$OUTD" "$TB" <<'PY'
import json,re,sys,hashlib
from pathlib import Path
tag,wl,L,route,out,tb=sys.argv[1:]
out=Path(out)
sim,pwr,cls=out/'gl',out/'power_result',out/'classes'
t=(pwr/'power.rpt').read_text()
g=lambda n: float(re.search(n+r'\s*=\s*([0-9.eE+-]+)',t)[1])*1e3
tot=dict(power_mW=g('Total Power'),internal_mW=g('Cell Internal Power'),switching_mW=g('Net Switching Power'),
         leakage_mW=g('Cell Leakage Power'))
c=json.loads((sim/'trace_check.json').read_text())
q=json.loads((sim/'timing_qualification.json').read_text())
a=json.loads((sim/'sdf_clock_audit.json').read_text())
k=json.loads((cls/'power_classes.json').read_text())
cov=json.loads((pwr/'power_coverage.json').read_text())
window=c['window_edges']; blocks=c['blocks']; p=tot['power_mW']
saif=sim/tb/'dut.saif'
row=dict(tag=tag,workload=c['workload'],L=(int(L) if wl=='uniform' else None),mean_L=c['mean_L'],blocks=blocks,
         window_clocks=window,cycles_per_block=window/blocks,kernel_macs=blocks*512,mean_kA=c['mean_kA'],
         a_one_density=c['a_one_density'],drain_bit_exact=(not c['errors'] and c['wrong']==0),
         drained_accumulators=c['accumulators'],
         gl_strict=json.loads((sim/'timing_qualification_strict.json').read_text())['status'],gl_status=q['status'],
         gl_approvals_ndi=len(q['approved_negative_iopath_clamps']),gl_approvals_iwsba=len(q['approved_annotated_interconnects']),
         gl_post_reset_violations=q['post_reset_timing_violations'],gl_sdf_warnings=q['sdf_warning_categories'],
         worst_icg_ck_eck_ns=a['worst_icg_iopath_ns'],sdf_clock_audit=a['status'],pt_coverage=cov['status'],
         **tot,pJ_per_MAC=p*window*2.5/(blocks*512),pJ_per_block=p*window*2.5/blocks,nJ_window=p*window*2.5/1e3,
         classes_mW=k['rows_mW'],
         saif_sha256=hashlib.sha256(saif.read_bytes()).hexdigest(),
         sim_dir=str(sim),power_dir=str(pwr),classes_dir=str(cls),
         pt_view=(pwr/'VIEW_DIR.txt').read_text().strip(),route=route)
(out/'result.json').write_text(json.dumps(row,indent=1)+'\n')
print(f"{tag}: {row['workload']}: {p:.4f} mW, {row['pJ_per_MAC']:.4f} pJ/MAC, {row['pJ_per_block']:.2f} pJ/block, "
      f"{window} clocks ({row['cycles_per_block']:.3f}/block), mean kA {row['mean_kA']:.2f}, drain bit-exact {row['drain_bit_exact']}, "
      f"GL strict {row['gl_strict']}")
PY
}

stage sim "$OUTD/gl" do_sim "$OUTD/gl"
stage audit "$OUTD/gl/timing_qualification.json" cbsg_gl_audit "$OUTD/gl"
stage power "$OUTD/power_result" do_pt_view "$OUTD/gl/$TB/dut.saif" "$OUTD/power_result"
stage classes "$OUTD/classes/power_classes.json" do_classes "$OUTD/gl" "$OUTD/power_result" "$OUTD/classes"
stage result "$OUTD/result.json" do_result
cat "$OUTD/result.attempt_"*.log | tail -n 1
echo "[$LABEL] complete: $OUTD/result.json"
