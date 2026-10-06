#!/bin/bash
# GL + PT-PX + functional power split of one RG route for one workload, without touching the route directory.
#   bash sweeps/cbsg/rg/run_rg_route_power.sh RUN uniform|rowmix|rowgrouped [REUSE_SIM_DIR]
#   RETRY_FAILED=1 ...                                   (retry a failed stage)
# RUN is a run under apr/build/TSMC22/PAYN_SC_CSA_CBSG_RG.  Written for the 2026-10-05 campaign, where the
# headline pinned route (and the floating final) missed setup at 2.5 ns by 23-30 ps and therefore got no GL/PT:
# this measures INDICATIVE power on a route whose timing is clean (the bootstrap route), with the campaign's own
# checks, and records the route's qualification state next to every number (result.csv 'route_status').
# Stages (PASS markers, attempt logs, as the campaign drivers):
#   sim    sweeps/cbsg/cbsg_campaign_lib.sh cbsg_gl_sim: full-timing max-SDF GL with the RG power bench, bench
#          PASS for the full workload, trace header, bit-exact drain (sweeps/cbsg/rg/check_power_trace.py vs the
#          kernel and the RG model), SAIF validation, routed-SDF clock audit (raw routed SDF, no ideal-clock
#          view).  With REUSE_SIM_DIR (an already audited sim of this route and workload, e.g. the bootstrap
#          campaign's gl_bootstrap), sim and audit are not rerun; that directory is used read-only.
#   audit  cbsg_gl_audit: strict sweeps/validate_routed_gl.py; approvals only after a strict failure
#          (RG_GL_VALIDATOR_ARGS + a rationale file in the output directory citing every flag)
#   power  make power_apr on a PT-only view apr/build/TSMC22/PAYN_SC_CSA_CBSG_RG/<RUN>_pt_<workload>
#          (symlinks to the route's netlist, SPEF, SDC) + sweeps/validate_pt_power_coverage.py
#   split  sweeps/cbsg/rg/run_power_split.sh on the same inputs (W generators / per-tile comparators / tiles /
#          A edge ...; its cell-sum total must equal the power stage's)
#   result result.csv: power, pJ per kernel MAC = P * window * 2.5 ns / (blocks * 512), nJ per block
# Outputs: build/power_char/<campaign>/rg/indicative/<RUN>/<workload>/.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
CAMPAIGN=${CAMPAIGN:-cbsg_20261005}
RETRY_FAILED=${RETRY_FAILED:-0}
[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 RUN uniform|rowmix|rowgrouped [REUSE_SIM_DIR]" >&2; exit 2; }
RUN=$1; WL=$2; REUSE=${3:-}
[[ "$RUN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "invalid RUN" >&2; exit 2; }
case "$WL" in uniform|rowmix|rowgrouped) ;; *) echo "workload must be uniform, rowmix or rowgrouped" >&2; exit 2;; esac
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
# ---- identical to sweeps/cbsg/run_cbsg_apr.sh (itself = sweeps/run_popcount_apr.sh) ----
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
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
export SNPSLMD_QUEUE=true PYTHONDONTWRITEBYTECODE=1
source "$REPO/sweeps/cbsg/cbsg_campaign_lib.sh"

arm=rg
case "$WL" in rowgrouped) RG_LADDER=rowgrouped cbsg_arm_config rg;; *) RG_LADDER=rowmix cbsg_arm_config rg;; esac
wlkind=ladder; [[ "$WL" == uniform ]] && wlkind=uniform
route=$REPO/apr/build/$target/$RUN
for f in "outputs/$top.apr.v" "outputs/$top.spef" "outputs/$top.apr.sdf" "$top.syn.sdc" reports/setup.rpt reports/hold.rpt; do
    [[ -s "$route/$f" ]] || { echo "missing $route/$f" >&2; exit 2; }
done
work=$REPO/build/power_char/$CAMPAIGN/rg/indicative/$RUN/$WL      # cbsg_gl_audit reads $work's rationale file
mkdir -p "$work"
exec 9>"$work/worker.lock"
flock -n 9 || { echo "another worker owns $work" >&2; exit 2; }
if [[ -n "$REUSE" ]]; then
    REUSE=$(cd "$REUSE" && pwd); sim=$REUSE
    [[ -f "$sim/timing_qualification.json" && -f "$sim/trace_check.json" && -f "$sim/sdf_clock_audit.json" ]]
    python3 - "$sim" "$route" "$WL" <<'PY'
import json,sys
sim,route,wl=sys.argv[1:]
q=json.load(open(f'{sim}/timing_qualification.json')); t=json.load(open(f'{sim}/trace_check.json'))
a=json.load(open(f'{sim}/sdf_clock_audit.json'))
assert q['status']=='PASS' and not t['errors'] and a['status']=='PASS', (q['status'], t['errors'], a['status'])
want={'uniform':'uniform_L128','rowmix':'ladder_rowmix','rowgrouped':'ladder_rowgrouped'}[wl]
assert t['workload']==want, (t['workload'], want)
log=open(f'{sim}/simulation.log',errors='replace').read()
assert f'{route}/outputs/' in log, 'reused sim did not simulate this route'
print(f'reusing audited sim {sim}: {t["workload"]}, {t["blocks"]} blocks, drain bit-exact, timing audit PASS')
PY
    echo "$sim" > "$work/reused_sim.txt"
else
    sim=$work/gl
fi

stage() {   # name artifact cmd...   (the campaign drivers' stage semantics)
    local name=$1 artifact=$2 marker attempt=1 log; shift 2
    marker="$work/$name.status"
    if [[ -f "$marker" ]]; then
        [[ "$(cat "$marker")" == PASS && -e "$artifact" ]] || { echo "invalid completed stage $name" >&2; return 1; }
        echo "[rg $RUN $WL] reuse completed $name"; return
    fi
    while [[ -e "$work/$name.attempt_$attempt.log" ]]; do attempt=$((attempt+1)); done
    if [[ -e "$artifact" || "$attempt" -gt 1 ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "unfinished $name preserved; RETRY_FAILED=1 to retry" >&2; return 1; }
        [[ ! -e "$artifact" ]] || mv "$artifact" "${artifact}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    fi
    log="$work/$name.attempt_$attempt.log"
    echo "[rg $RUN $WL] $name started $(date -Is); $log"
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[rg $RUN $WL] $name passed $(date -Is)"
}

view=$REPO/apr/build/$target/${RUN}_pt_$WL
do_power() {
    local saved="$work/power_result" f saif="$sim/$TB/dut.saif"
    [[ ! -e "$view" ]] || mv "$view" "${view}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    mkdir -p "$view/outputs" "$saved"
    ln -s "$route/outputs/$top.apr.v" "$view/outputs/$top.apr.v"
    ln -s "$route/outputs/$top.spef" "$view/outputs/$top.spef"
    ln -s "$route/$top.syn.sdc" "$view/$top.syn.sdc"
    {
        echo "PT-only view of $route for the RG $WL workload (SAIF $saif), written by sweeps/cbsg/rg/run_rg_route_power.sh;"
        echo "the route's own reports and activity file are untouched."
        for f in "outputs/$top.apr.v" "outputs/$top.spef" "$top.syn.sdc"; do
            echo "$(sha256sum "$route/$f" | cut -d' ' -f1)  $f"
        done
    } > "$view/VIEW_OF.txt"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="${RUN}_pt_$WL" \
        SAIF="$saif" SAIF_STRIP_PATH=Top/dut NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    [[ -s "$view/reports/power.rpt" && -s "$view/reports/saif_coverage.rpt" && -s "$view/reports/parasitics_coverage.rpt" ]]
    grep -q 'Report : Averaged Power' "$view/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$view/reports" \
        --power-log "$view/power_apr.log" --json "$view/reports/power_coverage.json"
    cmp -s "$saif" "$view/activity/dut.saif"
    cp -p "$view/power_apr.log" "$view/reports/power_coverage.json" "$view/VIEW_OF.txt" "$saved/"
    cp -p "$view"/reports/*.rpt "$saved/"
}

do_split() {
    local window blocks
    read -r window blocks < <(python3 -c 'import json,sys; t=json.load(open(sys.argv[1])); print(t.get("window_edges",t.get("window_clocks")), t["blocks"])' "$sim/trace_check.json")
    bash sweeps/cbsg/rg/run_power_split.sh "$work/split" "$route/outputs/$top.apr.v" "$route/$top.syn.sdc" \
        "$route/outputs/$top.spef" "$sim/$TB/dut.saif" "$work/power_result/power.rpt" "$window" "$blocks" "${RUN}_$WL"
}

do_result() {
    python3 - "$work" "$sim" "$route" "$RUN" "$top" "$rng_insts" <<'PY'
import csv,json,re,sys
from pathlib import Path
work,sim,route,run,top,rng=sys.argv[1:]; work,sim,route=Path(work),Path(sim),Path(route); rng=rng.split()
report=(work/'power_result'/'power.rpt').read_text()
def total(name):
    m=re.search(name+r'\s*=\s*([0-9.eE+-]+)',report); assert m,name; return float(m[1])*1e3
hier={}
for line in (work/'power_result'/'cell_power.rpt').read_text().splitlines():
    m=re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\(.*\)\s+h\s*$',line)
    if m and m[1] not in hier: hier[m[1]]=float(m[5])*1e3
t=json.loads((sim/'timing_qualification.json').read_text()); assert t['status']=='PASS'
c=json.loads((sim/'trace_check.json').read_text()); assert not c['errors']
s=json.loads((work/'split'/'power_split.json').read_text())
area=None
for line in (route/'reports'/'area.rpt').read_text().splitlines():
    f=line.split()
    if f and f[0]==top: area=float(f[2]); break
slack={}
for k in ('setup','hold'):
    slack[k]=float(re.search(r'Slack Time\s*([-+0-9.]+)',(route/'reports'/f'{k}.rpt').read_text())[1])
qf=route/'reports'/'popcount_qualification.json'
q=json.loads(qf.read_text()) if qf.exists() else {}
status=('qualified final' if q.get('qualification')=='final' else
        f"NOT final-qualified ({q.get('qualification','unqualified')}: geometry_drc={q.get('geometry_drc')}, "
        f"antenna={q.get('antenna_violations')}, overlaps={q.get('placement_overlapping_instances')})")
window=c.get('window_edges',c.get('window_clocks')); blocks=c['blocks']; p=total('Total Power')
e=p*1e-3*window*2.5e-9
row=dict(arm='rg',run=run,route_status=status,setup_wns_ns=slack['setup'],hold_wns_ns=slack['hold'],area_um2=area,
         workload=c['workload'],blocks=blocks,window_clocks=window,kernel_macs=blocks*512,
         mean_cycles_per_block=window/blocks,power_mW=p,internal_mW=total('Cell Internal Power'),
         switching_mW=total('Net Switching Power'),leakage_mW=total('Cell Leakage Power'),
         pJ_MAC=e/(blocks*512)*1e12,nJ_block=e/blocks*1e9,u_pe_mW=hier['u_pe'],u_peripheral_mW=hier['u_peripheral'],
         sobol_mW=sum(hier[k] for k in rng),tiles_mW=s['tiles_mW'],w_generators_mW=s['w_generators_mW'],
         w_comparators_mW=s['w_comparators_mW'],gl_strict=json.loads((sim/'timing_qualification_strict.json').read_text())['status'],
         gl_approved_ndi_clamps=len(t['approved_negative_iopath_clamps']),
         gl_approved_iwsba=len(t['approved_annotated_interconnects']),drain_bit_exact=not c['errors'],status='PASS')
with (work/'result.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(row)); w.writeheader(); w.writerow(row)
print(json.dumps(row,indent=2))
PY
}

if [[ -z "$REUSE" ]]; then
    stage sim "$sim" cbsg_gl_sim "$RUN" "$sim" "$wlkind"
    stage audit "$sim/timing_qualification.json" cbsg_gl_audit "$sim"
fi
stage power "$work/power_result" do_power
stage split "$work/split/power_split.json" do_split
stage result "$work/result.csv" do_result
echo "[rg $RUN $WL] complete: $work/result.csv"
