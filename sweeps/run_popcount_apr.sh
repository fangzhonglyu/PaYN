#!/bin/bash
# Matched K8/M16/N8, T128 two-pass routed popcount experiment through ASTRAEA.
#   bash sweeps/run_popcount_apr.sh inferred techmap   # parallel independent arms
#   bash sweeps/run_popcount_apr.sh control           # optional fresh control
#   RETRY_FAILED=1 bash sweeps/run_popcount_apr.sh inferred
#   CAMPAIGN=pc16_20261002 bash sweeps/run_popcount_apr.sh csa
#       carry-save lane interface; synthesis run CSA_SYNTH_RUN (csa_20261002)
# Stages resume only from explicit PASS markers. A failed stage is preserved;
# RETRY_FAILED=1 moves its unfinished outputs aside before starting a new attempt.
# The archived clean baseline used neither optPower recovery nor APR multibit
# rebanking. HPK multibit inference was already enabled in the input synthesis.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
CAMPAIGN=${CAMPAIGN:-pc16_20260930}
OUT=${OUT:-build/power_char/popcount_apr_${CAMPAIGN#pc16_}}
RETRY_FAILED=${RETRY_FAILED:-0}
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid CAMPAIGN' >&2; exit 2; }
[[ "$RETRY_FAILED" == 0 || "$RETRY_FAILED" == 1 ]] || { echo 'RETRY_FAILED must be 0 or 1' >&2; exit 2; }
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
[[ -f "$ASTRAEA_FLOW/Makefile" ]] || { echo 'ASTRAEA Makefile missing' >&2; exit 2; }
ARMS=("$@")
((${#ARMS[@]})) || ARMS=(inferred techmap)
declare -A SEEN=()
for arm in "${ARMS[@]}"; do
    case "$arm" in control|inferred|techmap|csa) ;; *) echo "Unknown arm: $arm" >&2; exit 2;; esac
    [[ ! -v SEEN[$arm] ]] || { echo "Repeated arm: $arm" >&2; exit 2; }
    SEEN[$arm]=1
done
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
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
TB=designs/payn/power/power_payn_array.sv
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'

# Each stage uses a new log. Success markers are never inferred from output
# existence: Innovus and PT can leave partial files after failed invocations.
stage() {
    local name=$1 artifact=$2
    shift 2
    local marker="$work/$name.status" attempt=1 log
    if [[ -f "$marker" ]]; then
        [[ "$(cat "$marker")" == PASS && -e "$artifact" ]] || {
            echo "[$arm] Invalid completed stage: $name" >&2; return 1;
        }
        echo "[$arm] reuse completed $name"
        return
    fi
    while [[ -e "$work/$name.attempt_$attempt.log" ]]; do attempt=$((attempt+1)); done
    if [[ -e "$artifact" || "$attempt" -gt 1 ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || {
            echo "[$arm] Unfinished $name preserved; inspect logs then use RETRY_FAILED=1 to retry" >&2
            return 1
        }
        if [[ -e "$artifact" ]]; then
            mv "$artifact" "${artifact}.failed_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
        fi
    fi
    log="$work/$name.attempt_$attempt.log"
    echo "[$arm] $name started; $log"
    # Called outside any conditional so errexit remains active in each action.
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[$arm] $name passed"
}

check_apr() {
    local path=$1 qualification=${2:-final}
    python3 - "$path" "$top" "$qualification" <<'PY'
import json,re,sys
from pathlib import Path
p,top=Path(sys.argv[1]),sys.argv[2]
qualification=sys.argv[3]
for suffix in ('apr.v','apr.sdf','spef'):
    f=p/'outputs'/f'{top}.{suffix}'
    assert f.is_file() and f.stat().st_size, f'Missing APR output {f}'
log=(p/'apr.log').read_text(errors='replace')
assert ('Innovus script finished' in log or 'POP_COUNT_CHECKPOINT_REPAIR_COMPLETE' in log), 'Missing APR or checkpoint-repair completion'
# A summary-script rejection is tolerable for a bootstrap seed only after
# proving that Innovus itself ended normally and reported no EDA errors.
assert '--- Ending "Innovus"' in log, 'Missing normal Innovus termination'
error_counts=re.findall(r'Message Summary:\s*\d+ warning\(s\),\s*(\d+) error\(s\)',log)
assert error_counts and all(int(n)==0 for n in error_counts), 'Innovus reported errors or lacks error summary'
assert not re.search(r'\*\*\s*ERROR:|(?m:^\s*(?:ERROR|Error):)',log), 'Innovus error diagnostic present'
for filename in (f'{top}.syn.sdc','reports/area.rpt'):
    f=p/filename
    assert f.is_file() and f.stat().st_size, f'Missing APR input/report {f}'
# Qualify the final occurrences only: earlier optimization passes may have DRCs.
drc=re.findall(r'Verification Complete\s*:\s*(\d+) Viols\.',log)
antenna=re.findall(r'Verification Complete:\s*(\d+) Violations',log)
connect=re.findall(r'\*+ Start: VERIFY CONNECTIVITY \*+(.*?)\*+ End: VERIFY CONNECTIVITY \*+',log,re.S)
assert len(drc)>=2 and antenna and connect, 'Missing final physical checks'
if qualification=='final':
    assert int(drc[-2])==0, f'Final geometry DRC {drc[-2]}'
assert int(drc[-1])==0 and 'Found no problems or warnings.' in connect[-1], 'Final connectivity failed'
if qualification=='final':
    assert int(antenna[-1])==0, f'Final antenna violations {antenna[-1]}'
slacks={}
for kind in ('setup','hold'):
    report=(p/'reports'/f'{kind}.rpt').read_text()
    m=re.search(r'Slack Time\s*([-+0-9.]+)',report)
    assert m, f'Missing {kind} slack'
    slacks[kind+'_wns_ns']=float(m[1])
    assert float(m[1])>=0, f'{kind} violation {m[1]}'
# Historical bootstrap routes can contain placement overlaps; they only seed
# activity for the independent second APR. Final results must be legal.
placement=list(re.finditer(r'Begin checking placement.*?Finished checkPlace[^\n]*',log,re.S))
assert placement, 'Missing placement check'
last_placement=placement[-1]
overlap_match=re.search(r'Overlapping with other instance:\s*(\d+)',last_placement[0])
overlaps=int(overlap_match[1]) if overlap_match else 0
late_overlap='NRDB-2082' in log[last_placement.end():]
if qualification=='final':
    assert overlaps==0 and not late_overlap, f'Final placement overlaps: instances={overlaps}, later_router_warning={late_overlap}'
summary=dict(slacks,geometry_drc=int(drc[-2]),connectivity_violations=0,antenna_violations=int(antenna[-1]),
             placement_overlapping_instances=overlaps,placement_late_overlap_warning=late_overlap,
             qualification=qualification)
(p/'reports'/'popcount_qualification.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
PY
}

do_apr() {
    local run=$1 pass=$2 path="$REPO/apr/build/$target/$1" make_status=0
    if [[ "$pass" == bootstrap ]]; then
        # summarize_run rejects residual seed geometry/antenna violations even
        # when Innovus finished correctly. Capture that status, then require
        # full tool completion, zero EDA errors, required outputs, and valid
        # connectivity/setup/hold through check_apr before accepting the seed.
        APR_WORKLOAD_POWER_OPT=0 SYNTH_RUN="$synrun" RUN_NAME="$run" \
            make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
            || make_status=$?
    else
        PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl \
        APR_WORKLOAD_POWER_OPT=1 APR_ACTIVITY_FILE="$boot_saif" APR_ACTIVITY_SCOPE=Top/dut \
        APR_LEAKAGE_TO_DYNAMIC_RATIO=0.0 APR_DETAIL_WIRE_LENGTH_OPT_EFFORT=high \
        SYNTH_RUN="$synrun" RUN_NAME="$run" \
            make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
        grep -q 'Enabling workload-aware dynamic-power optimization' "$path/apr.log"
        grep -q 'leakageToDynamicRatio=0.0 detail_wirelength_effort=high' "$path/apr.log"
    fi
    check_apr "$path" "$pass"
    if [[ "$make_status" -ne 0 ]]; then
        echo "Bootstrap make apr returned $make_status; completed Innovus output passed the activity-seed qualifier. Physical diagnostics remain recorded."
    fi
}

do_sim() {
    local run=$1 simdir=$2 route="$REPO/apr/build/$target/$1"
    mkdir -p "$simdir"
    make sim GL=apr TARGET="$target" RUN="$run" TB="$TB" BUILD_DIR="$simdir" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true VCS_ARGS="$glargs" "VCS=$VCS_CMD" \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$simdir/simulation.log" 2>&1
    grep -q 'PASS: streaming SC SAIF captured; 384 batches x 8 cycles' "$simdir/simulation.log"
    grep -q 'sdf corner = max' "$simdir/simulation.log"
    grep -Fq '[INFO] $sdf_annotate(' "$simdir/simulation.log"
    # Full library timing models plus verbose annotation let the validator
    # distinguish reset-startup checks from real workload violations and
    # reject missing SDF timing arcs instead of trusting functional PASS.
    # GL_VALIDATOR_ARGS is opt-in and recorded beside the run, e.g.
    # "--approve-negative-iopath-clamp-ps 10" after investigating SDFCOM_NDI.
    [[ -z "${GL_VALIDATOR_ARGS:-}" ]] || \
        printf 'GL_VALIDATOR_ARGS=%s (%s)\n' "$GL_VALIDATOR_ARGS" "$(date -Is)" >> "$work/gl_validator_args.txt"
    # shellcheck disable=SC2086
    python3 sweeps/validate_routed_gl.py "$simdir/simulation.log" ${GL_VALIDATOR_ARGS:-} \
        --json "$simdir/timing_qualification.json" > "$simdir/timing_validation.log" 2>&1
    local trace="$simdir/$TB/array_streaming_rtl.txt" saif="$simdir/$TB/dut.saif"
    [[ -s "$trace" && -s "$saif" ]]
    [[ "$(head -n 1 "$trace")" == 'STREAMCFG 8 16 8 8 8 24 128 384 0' ]]
    python3 designs/payn/cosim/cosim_streaming.py "$trace" > "$simdir/cosim.log" 2>&1
    grep -q '\[PASS\]' "$simdir/cosim.log"
    python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 \
        > "$simdir/saif_validation.log" 2>&1
    mkdir -p "$route/activity"
    [[ ! -e "$route/activity/dut.saif" ]] || \
        cp -p "$route/activity/dut.saif" "$simdir/previous_route_activity.saif"
    cp "$saif" "$route/activity/dut.saif"
    cat "$simdir/cosim.log" "$simdir/saif_validation.log"
}

do_power() {
    local saved="$work/power_result"
    mkdir -p "$saved/prior_reports"
    # PT overwrites Innovus power reports. Preserve those, or prior failed PT
    # reports, before each attempt; no earlier log is silently discarded.
    cp -p "$finaldir"/reports/*.rpt "$saved/prior_reports/"
    [[ ! -f "$finaldir/power_apr.log" ]] || cp -p "$finaldir/power_apr.log" "$saved/prior_power_apr.log"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_sc_power_saif.py" \
        make power_apr TARGET="$target" RUN="$finalrun" \
        SAIF="$finaldir/activity/dut.saif" SAIF_STRIP_PATH=Top/dut \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    [[ -s "$finaldir/reports/power.rpt" && -s "$finaldir/reports/saif_coverage.rpt" \
        && -s "$finaldir/reports/parasitics_coverage.rpt" ]]
    grep -q 'Report : Averaged Power' "$finaldir/reports/power.rpt"
    python3 sweeps/validate_pt_power_coverage.py "$finaldir/reports" \
        --power-log "$finaldir/power_apr.log" --json "$finaldir/reports/power_coverage.json"
    cp -p "$finaldir/power_apr.log" "$saved/"
    cp -p "$finaldir"/reports/*.rpt "$saved/"
    python3 - "$arm" "$target" "$finalrun" "$finaldir" "$top" "$work" <<'PY'
import csv,json,re,sys
from pathlib import Path
arm,target,run,dirname,top,work=sys.argv[1:]
p=Path(dirname); report=(p/'reports'/'power.rpt').read_text()
m=re.search(r'Total Power\s*=\s*([0-9.eE+-]+)',report)
assert m, 'Missing PT total power'
power=float(m[1]); assert power>0
area=None
for line in (p/'reports'/'area.rpt').read_text().splitlines():
    fields=line.split()
    if fields and fields[0]==top: area=float(fields[2]); break
assert area is not None
q=json.loads((p/'reports'/'popcount_qualification.json').read_text())
row=dict(arm=arm,target=target,run=run,K=8,M=16,N=8,T=128,area_um2=area,
         power_mW=power*1000,pJ_MAC=power*1000*2.5/64,**q,status='PASS')
with (Path(work)/'result.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=row);w.writeheader();w.writerow(row)
print(json.dumps(row,indent=2))
PY
}

run_arm() (
    local arm=$1 target top synrun bootrun finalrun syndir bootdir finaldir
    local work="$OUT/$arm" boot_sim final_sim boot_saif glargs current_stage=initialization
    case "$arm" in
        control) target=TSMC22/PAYN_SC_SIGNED_SEGMENTED_CLEAN; top=payn_array_signed_segmented_clean;;
        inferred|techmap) target=TSMC22/PAYN_SC_POPCOUNT_${arm^^}; top=payn_array_signed_segmented_popcount;;
        csa) target=TSMC22/PAYN_SC_CSA; top=payn_array_signed_segmented_csa;;
    esac
    mkdir -p "$work"
    exec 9>"$work/worker.lock"
    flock -n 9 || { echo "[$arm] Another worker owns this run" >&2; exit 2; }
    trap 'rc=$?; printf "FAILED stage=%s exit=%s time=%s\n" "$current_stage" "$rc" "$(date -Is)" >> "$work/failures.log"; exit "$rc"' ERR
    synrun=${CAMPAIGN}_${arm}
    # The carry-save arm was synthesized (and RTL-verified) outside the
    # popcount campaign, under the same knobs; route that exact netlist.
    [[ "$arm" != csa ]] || synrun=${CSA_SYNTH_RUN:-csa_20261002}
    bootrun=${synrun}_distguide
    finalrun=${bootrun}_spp_fixed
    syndir="$REPO/syn/build/$target/$synrun"
    bootdir="$REPO/apr/build/$target/$bootrun"
    finaldir="$REPO/apr/build/$target/$finalrun"
    boot_sim="$work/gl_bootstrap"; final_sim="$work/gl_final"
    boot_saif="$bootdir/activity/dut.saif"
    glargs="+define+PAYN_ARRAY_DUT=$top+define+SC_K=8+define+SC_M=16+define+SC_NH=8+define+SC_NW=8+define+SC_OWIDTH=24+define+SC_T=128+define+SC_BATCHES=384 +neg_tchk +sdfverbose"
    [[ -s "$syndir/$top.syn.v" && -s "$syndir/$top.syn.sdc" ]]
    python3 - "$syndir/$top.syn.sdc" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
delays=re.findall(r'^set_input_delay\b[^\n]*?\s([0-9]+(?:\.[0-9]+)?)\s+\[get_ports',s,re.M)
assert delays and all(float(x)==1.25 for x in delays), f'Unexpected input delays {delays}'
PY
    # Record a readable contract. Direct comparison avoids accepting stale
    # markers under changed settings; campaign names identify immutable inputs.
    local manifest
    manifest=$(printf 'target=%s\ntop=%s\nsynthesis=%s\nflow=%s\nK=8 M=16 NH=8 NW=8 OWIDTH=24 LOW_W=9 T=128 batches=384 period=2.5 input_delay=1.25 uncertainty=0.125 core_util=0.70 HPK=1 guides=1 APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0\n' "$target" "$top" "$syndir" "$ASTRAEA_FLOW")
    if [[ -e "$work/inputs.txt" ]]; then
        [[ "$(cat "$work/inputs.txt")" == "$manifest" ]]
    else
        printf '%s\n' "$manifest" > "$work/inputs.txt"
    fi
    current_stage=bootstrap_apr
    stage "$current_stage" "$bootdir" do_apr "$bootrun" bootstrap
    current_stage=bootstrap_sim
    stage "$current_stage" "$boot_sim" do_sim "$bootrun" "$boot_sim"
    current_stage=final_apr
    stage "$current_stage" "$finaldir" do_apr "$finalrun" final
    current_stage=final_sim
    stage "$current_stage" "$final_sim" do_sim "$finalrun" "$final_sim"
    current_stage=power
    stage "$current_stage" "$work/power_result" do_power
    echo "[$arm] complete: $work/result.csv"
)

mkdir -p "$OUT"
pids=()
for arm in "${ARMS[@]}"; do run_arm "$arm" & pids+=("$!"); done
status=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then :; else
        echo "[${ARMS[$i]}] Failed; inspect $OUT/${ARMS[$i]}/failures.log and stage logs" >&2
        status=1
    fi
done
exit "$status"
