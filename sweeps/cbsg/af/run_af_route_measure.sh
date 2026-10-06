#!/bin/bash
# The measurement stages of sweeps/cbsg/run_cbsg_pinned_pass2.sh for one AF route, run OUTSIDE the qualified
# campaign and read only on the route:
#   gate            basin QoR gate (sweeps/cbsg/basin/run_basin_gate_cbsg.sh -> the shared gate for AF)
#   uniform_sim     full-timing max-SDF GL, uniform L=128 power bench (cbsg_gl_sim: bench PASS, trace header,
#                   bit-exact drain, SAIF validation, routed-SDF clock audit)
#   uniform_audit   sweeps/validate_routed_gl.py strict first (cbsg_gl_audit; approvals only after a strict failure,
#                   opt-in AF_GL_VALIDATOR_ARGS, with OUT_DIR/gl_validator_args_rationale.txt)
#   uniform_power   PT-PX on a PT-only view apr/build/<target>/<RUN>_ptview_uniform (symlinks to the route's
#                   netlist, SPEF, SDC; make power_apr writes its SAIF snapshot and reports there) + coverage audit
#   ladder_sim / ladder_audit / ladder_power   the same with the CBSG_PWR_LADDER workload
#   classes_uniform / classes_ladder   per-class power and area (sweeps/cbsg/af/run_pt_power_classes.sh; must
#                   reproduce the PT total of that workload)
#   routed_func     the AF functional bench on the routed netlist, raw routed SDF, +RESET_SETTLE=2 and =0 (as the
#                   driver's do_routed_func)
#   result          OUT_DIR/result.json + result.csv for both workloads
# The route's activity file, reports and checkpoints are never written, and the GL / PT steps are the campaign
# library's functions unchanged (sweeps/cbsg/cbsg_campaign_lib.sh), with the drivers' environment.
#
#   bash sweeps/cbsg/af/run_af_route_measure.sh RUN OUT_DIR LABEL [--pin-plan PLAN] [--reuse-uniform SIMDIR POWERDIR]
#   --reuse-uniform  take the uniform GL (SIMDIR: cbsg_gl_sim output whose timing_qualification.json is PASS) and
#                    its PT reports (POWERDIR with power.rpt, cell_power.rpt, ...) from a campaign stage instead of
#                    rerunning them (the floating final of sweeps/cbsg/run_cbsg_apr.sh).
# Used 2026-10-05 for the AF pinned pass 2 route, which failed the strict final DRC qualification (results labeled
# UNQUALIFIED, provisional), and for the qualified floating-pin final (basin gate, ladder and class split added).
set -Eeuo pipefail
[[ $# -ge 3 ]] || { echo "Usage: $0 RUN OUT_DIR LABEL [--pin-plan PLAN] [--reuse-uniform SIMDIR POWERDIR]" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
RUN=$1; OUTD=$2; LABEL=$3; shift 3
PLAN=""; REUSE_SIM=""; REUSE_PWR=""
while (($#)); do
    case "$1" in
        --pin-plan) PLAN=$(readlink -f "$2"); shift 2;;
        --reuse-uniform) REUSE_SIM=$(readlink -f "$2"); REUSE_PWR=$(readlink -f "$3"); shift 3;;
        *) echo "unknown option $1" >&2; exit 2;;
    esac
done
[[ "$RUN" =~ ^[A-Za-z0-9_]+$ && "$LABEL" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid RUN or LABEL' >&2; exit 2; }
mkdir -p "$OUTD"; OUTD=$(readlink -f "$OUTD")
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
# ---- the drivers' environment (sweeps/cbsg/run_cbsg_pinned_pass2.sh) ----
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
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
source "$REPO/sweeps/cbsg/cbsg_campaign_lib.sh"

arm=af
cbsg_arm_config af
work=$OUTD                     # cbsg_gl_audit: rationale file and gl_validator_args.txt live here
finalrun=$RUN
finaldir="$REPO/apr/build/$target/$RUN"
[[ -s "$finaldir/outputs/$top.apr.v" && -s "$finaldir/outputs/$top.spef" && -s "$finaldir/outputs/$top.apr.sdf" ]] || {
    echo "route outputs missing in $finaldir" >&2; exit 2; }
exec 9>"$OUTD/worker.lock"
flock -n 9 || { echo "Another worker owns $OUTD" >&2; exit 2; }
{
    echo "label=$LABEL route=$finaldir top=$top"
    for f in "outputs/$top.apr.v" "outputs/$top.spef" "outputs/$top.apr.sdf" "$top.syn.sdc"; do
        echo "$(sha256sum "$finaldir/$f" | cut -d' ' -f1)  $f"
    done
    echo "bench=$TB sha256=$(sha256sum "$REPO/$TB" | cut -d' ' -f1) functional_bench=$ftb"
    echo "pin_plan=${PLAN:-none} reuse_uniform_sim=${REUSE_SIM:-none} reuse_uniform_power=${REUSE_PWR:-none}"
    echo "route qualification: $(cat "$finaldir/reports/popcount_qualification.json" 2>/dev/null | tr -d '\n ')"
} > "$OUTD/inputs.$(date +%Y%m%d_%H%M%S).txt"

stage() {
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

pt_reports_check() {   # run_dir
    [[ -s "$1/reports/power.rpt" && -s "$1/reports/saif_coverage.rpt" && -s "$1/reports/parasitics_coverage.rpt" ]]
    grep -q 'Report : Averaged Power' "$1/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$1/reports" \
        --power-log "$1/power_apr.log" --json "$1/reports/power_coverage.json"
}

do_gate() {
    local rc=0
    if [[ -n "$PLAN" ]]; then
        bash sweeps/cbsg/basin/run_basin_gate_cbsg.sh "$finaldir" "$top" "$OUTD/basin" "$LABEL" "$PLAN" || rc=$?
    else
        bash sweeps/cbsg/basin/run_basin_gate_cbsg.sh "$finaldir" "$top" "$OUTD/basin" "$LABEL" || rc=$?
    fi
    [[ "$rc" == 0 || "$rc" == 3 ]]
    python3 - "$OUTD/basin/basin_gate.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
pp=j.get('pin_proof',{})
print('basin', j['gate']['basin'], 'corr', round(j['corr_x_col'],3), 'skew_ps', round(j['abs_skew_mean_ps'],1),
      'pin_proof', pp.get('status','n/a'), 'fixed', pp.get('fixed_in_def','n/a'), 'mismatches', pp.get('mismatches','n/a'))
PY
}

# PT-PX on a PT-only view of the route (the driver's do_ladder_power, generalized).
do_pt_view() {   # name saif saved_dir
    local view="$REPO/apr/build/$target/${finalrun}_ptview_$1" saif=$2 saved=$3 f
    [[ ! -e "$view" ]] || mv "$view" "${view}.old_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    mkdir -p "$view/outputs" "$saved"
    ln -s "$finaldir/outputs/$top.apr.v" "$view/outputs/$top.apr.v"
    ln -s "$finaldir/outputs/$top.spef" "$view/outputs/$top.spef"
    ln -s "$finaldir/$top.syn.sdc" "$view/$top.syn.sdc"
    {
        echo "PT-only view of $finaldir ($1 workload, label $LABEL), written by sweeps/cbsg/af/run_af_route_measure.sh;"
        echo "the route's own reports and activity file are untouched."
        for f in "outputs/$top.apr.v" "outputs/$top.spef" "$top.syn.sdc"; do
            echo "$(sha256sum "$finaldir/$f" | cut -d' ' -f1)  $f"
        done
    } > "$view/VIEW_OF.txt"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="${finalrun}_ptview_$1" \
        SAIF="$saif" SAIF_STRIP_PATH=Top/dut NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    pt_reports_check "$view"
    cmp -s "$saif" "$view/activity/dut.saif"
    cp -p "$view/power_apr.log" "$view/reports/power_coverage.json" "$view/VIEW_OF.txt" "$saved/"
    cp -p "$view"/reports/*.rpt "$saved/"
}

do_classes() {   # simdir powerdir outdir
    bash sweeps/cbsg/af/run_pt_power_classes.sh "$finaldir" "$top" af "$1/$TB/dut.saif" "$2/power.rpt" "$3"
}

# The driver's do_routed_func (AF branch), with the uniform GL's clock audit as the ICG evidence.
do_routed_func() {   # uniform_simdir
    local d="$OUTD/routed_func" b="$OUTD/routed_func/build" cases c s runp
    local pass_pat="PASS: CBSG AF bench" settle_list="2 0" results="$OUTD/routed_func/runs.tsv"
    local defs="+neg_tchk +sdfverbose +define+CBSG_RESET_SETTLE=2"
    mkdir -p "$b/$ftb"
    echo "$CBSG_GOLDEN/plain_u128" > "$b/$ftb/cbsg_cases.txt"
    cases="plain_u128 chunked_rung calls_av257"
    for c in $cases; do [[ -d "$CBSG_GOLDEN/$c" ]] || { echo "missing golden case $CBSG_GOLDEN/$c" >&2; return 1; }; done
    make sim GL=apr TARGET="$target" RUN="$finalrun" TB="$ftb" BUILD_DIR="$b" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$defs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$b/compile.log" 2>&1
    [[ -x "$b/$ftb/simv" ]]
    grep -q 'sdf corner = max' "$b/compile.log"
    printf 'settle\tcase\tbench\taudit\tstatus\n' > "$results"
    for s in $settle_list; do
        for c in $cases; do
            runp="$d/settle${s}_$c"; mkdir -p "$runp"
            (cd "$runp" && "$b/$ftb/simv" +vcs+lic+wait "+CASES=$CBSG_GOLDEN/$c" "+RESET_SETTLE=$s" > run.log 2>&1) || true
            { sed '/Running gate-level simulation/q' "$b/compile.log"; cat "$runp/run.log"; } > "$runp/simulation.log"
            local bench=FAIL audit=FAIL
            if grep -q "^$pass_pat" "$runp/run.log" && ! grep -qE 'Error-\[|\$fatal|\[TIMEOUT\]' "$runp/run.log"; then bench=PASS; fi
            if cbsg_gl_audit "$runp" "$pass_pat" > "$runp/audit.log" 2>&1; then audit=PASS; fi
            local st=FAIL; [[ "$bench" == PASS && "$audit" == PASS ]] && st=PASS
            printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$c" "$bench" "$audit" "$st" >> "$results"
        done
    done
    cat "$results"
    python3 - "$results" "$1/sdf_clock_audit.json" "$d/summary.json" <<'PY'
import csv,json,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t'))
icg=json.load(open(sys.argv[2]))
ok=lambda s: all(r['status']=='PASS' for r in rows if r['settle']==s)
out=dict(arm='af', runs=rows, ideal_clock_view_needed=not (icg['status']=='PASS' and ok('2')),
         worst_icg_ck_eck_ns=icg['worst_icg_iopath_ns'], icg_cells=icg['icg_cells'],
         reset_settle_needed=(not ok('0')),
         note="settle 0 = first load on the first edge after reset (the RTL suite's tightest schedule)")
json.dump(out,open(sys.argv[3],'w'),indent=2)
print(json.dumps({k:v for k,v in out.items() if k!='runs'}))
assert ok('2'), 'routed functional runs failed at the standard 2-edge settle'
PY
}

do_result() {   # uniform_simdir uniform_powerdir
    python3 - "$LABEL" "$target" "$finalrun" "$finaldir" "$top" "$OUTD" "$1" "$2" <<'PY'
import csv,json,re,sys
from pathlib import Path
label,target,run,route,top,out,usim,upwr=sys.argv[1:]
route,out=Path(route),Path(out)
def totals(p):
    t=(Path(p)/'power.rpt').read_text()
    g=lambda n: float(re.search(n+r'\s*=\s*([0-9.eE+-]+)',t)[1])*1e3
    return dict(power_mW=g('Total Power'),internal_mW=g('Cell Internal Power'),switching_mW=g('Net Switching Power'),
                leakage_mW=g('Cell Leakage Power'))
def hier(p):
    h={}
    for line in (Path(p)/'cell_power.rpt').read_text().splitlines():
        m=re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\(.*\)\s+h\s*$',line)
        if m and m[1] not in h: h[m[1]]=float(m[5])*1e3
    return h
areas={}
for line in (route/'reports'/'area.rpt').read_text().splitlines():
    f=line.split()
    if not f: continue
    if f[0]==top: areas[top]=float(f[2])
    elif line.startswith(' ') and not line.startswith('  ') and len(f)>=4: areas[f[0]]=float(f[3])
q=json.loads((route/'reports'/'popcount_qualification.json').read_text())
b=json.loads((out/'basin'/'basin_gate.json').read_text())
rows=[]
for wl,sim,pwr,cls in (('uniform',Path(usim),Path(upwr),out/'classes_uniform'),
                       ('ladder',out/'gl_ladder',out/'ladder'/'power_result',out/'classes_ladder')):
    c=json.loads((sim/'trace_check.json').read_text())
    t=json.loads((sim/'timing_qualification.json').read_text())
    a=json.loads((sim/'sdf_clock_audit.json').read_text())
    k=json.loads((cls/'power_classes.json').read_text())
    window=c.get('window_edges',c.get('window_clocks')); blocks=c['blocks']
    tot=totals(pwr); h=hier(pwr); p=tot['power_mW']
    row=dict(label=label,target=target,run=run,workload=c['workload'],blocks=blocks,window_clocks=window,
             cycles_per_block=window/blocks,kernel_macs=blocks*512,mean_kA=c.get('mean_kA'),a_one_density=c.get('a_one_density'),
             drain_bit_exact=(not c['errors']),gl_strict=t['status'],gl_approvals_ndi=len(t['approved_negative_iopath_clamps']),
             gl_approvals_iwsba=len(t['approved_annotated_interconnects']),gl_post_reset_violations=t['post_reset_timing_violations'],
             gl_sdf_warnings=json.dumps(t['sdf_warning_categories'],sort_keys=True),worst_icg_ck_eck_ns=a['worst_icg_iopath_ns'],
             **tot,pJ_per_MAC=p*window*2.5/(blocks*512),pJ_per_block=p*window*2.5/blocks,
             nJ_total_window=p*window*2.5/1e3,
             u_pe_mW=h['u_pe'],u_peripheral_mW=h['u_peripheral'],u_rng_mW=h['u_rng'],
             **{f'cls_{kk}_mW':vv for kk,vv in k['rows_mW'].items()},
             area_um2=areas[top],u_pe_um2=areas['u_pe'],u_peripheral_um2=areas['u_peripheral'],u_rng_um2=areas['u_rng'],
             **{f'cls_{kk}_um2':vv for kk,vv in (k['rows_area_um2'] or {}).items()},
             setup_wns_ns=q['setup_wns_ns'],hold_wns_ns=q['hold_wns_ns'],geometry_drc=q['geometry_drc'],
             antenna_violations=q['antenna_violations'],connectivity_violations=q['connectivity_violations'],
             placement_overlapping_instances=q['placement_overlapping_instances'],route_qualification=q['qualification'],
             basin=b['gate']['basin'],corr_x_col=b['corr_x_col'],mean_abs_skew_ps=b['abs_skew_mean_ps'],
             p90_abs_skew_ps=b['abs_skew_p90_ps'],wire_mm=b['wire_mm'],pin_proof=b.get('pin_proof',{}).get('status','n/a'))
    rows.append(row)
json.dump(rows,open(out/'result.json','w'),indent=2)
with (out/'result.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
for r in rows:
    print(f"{r['label']} {r['workload']}: {r['power_mW']:.4f} mW, {r['pJ_per_MAC']:.4f} pJ/MAC, {r['pJ_per_block']:.2f} pJ/block, "
          f"{r['cycles_per_block']:.3f} cycles/block, drain bit-exact {r['drain_bit_exact']}, GL {r['gl_strict']}")
PY
}

if [[ -n "$REUSE_SIM" ]]; then
    usim=$REUSE_SIM; upwr=$REUSE_PWR
    python3 -c 'import json,sys; q=json.load(open(sys.argv[1])); assert q["status"]=="PASS", q["status"]' "$usim/timing_qualification.json"
    [[ -s "$upwr/power.rpt" && -s "$upwr/cell_power.rpt" ]]
    cmp -s "$usim/$TB/dut.saif" "$finaldir/activity/dut.saif" || { echo "reused uniform SAIF is not the route's activity file" >&2; exit 2; }
else
    usim="$OUTD/gl_final"; upwr="$OUTD/power_result"
fi
stage gate "$OUTD/basin/basin_gate.json" do_gate
if [[ -z "$REUSE_SIM" ]]; then
    stage uniform_sim "$OUTD/gl_final" cbsg_gl_sim "$finalrun" "$OUTD/gl_final" uniform
    stage uniform_audit "$OUTD/gl_final/timing_qualification.json" cbsg_gl_audit "$OUTD/gl_final"
    stage uniform_power "$OUTD/power_result" do_pt_view uniform "$OUTD/gl_final/$TB/dut.saif" "$OUTD/power_result"
fi
stage ladder_sim "$OUTD/gl_ladder" cbsg_gl_sim "$finalrun" "$OUTD/gl_ladder" ladder
stage ladder_audit "$OUTD/gl_ladder/timing_qualification.json" cbsg_gl_audit "$OUTD/gl_ladder"
stage ladder_power "$OUTD/ladder/power_result" do_pt_view ladder "$OUTD/gl_ladder/$TB/dut.saif" "$OUTD/ladder/power_result"
stage classes_uniform "$OUTD/classes_uniform/power_classes.json" do_classes "$usim" "$upwr" "$OUTD/classes_uniform"
stage classes_ladder "$OUTD/classes_ladder/power_classes.json" do_classes "$OUTD/gl_ladder" "$OUTD/ladder/power_result" "$OUTD/classes_ladder"
stage routed_func "$OUTD/routed_func/summary.json" do_routed_func "$usim"
stage result "$OUTD/result.json" do_result "$usim" "$upwr"
echo "[$LABEL] complete: $OUTD/result.csv"
