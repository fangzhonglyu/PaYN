#!/bin/bash
# Route the verified native BOS builds and measure full-timing extracted power.
# Usage: bash sweeps/run_bos_precision_apr.sh [6] [4]
# Each width runs independently. Only explicit PASS markers permit resumption.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
SYN_CAMPAIGN=${SYN_CAMPAIGN:-bos_precision_20261001}
CAMPAIGN=${CAMPAIGN:-bos_precision_20261002}
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ && "$SYN_CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || exit 2
OUT="$REPO/build/bos_precision/$CAMPAIGN"
WIDTHS=("$@"); ((${#WIDTHS[@]})) || WIDTHS=(6 4)
declare -A SEEN=()
for width in "${WIDTHS[@]}"; do
    case "$width" in 6|4) ;; *) echo "Unsupported width $width" >&2; exit 2;; esac
    [[ ! -v SEEN[$width] ]] || exit 2; SEEN[$width]=1
done
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1 NTFY_CHNL= ZERO_PINLESS_NET_ACTIVITY=1
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export PERIOD=2.5 INPUT_DELAY=1.25 OUTPUT_DELAY=0.05 CLOCK_UNCERTAINTY=0.125
export CORE_UTIL=0.75 CORE_ASPECT=1.000 APR_OPT_POWER=1 APR_MULTIBIT_FLOP_OPT=1 APR_LEAN_OPT=0
export PRE_REPORT_SCRIPT=apr/scripts/check_final_placement.tcl
unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS
unset APR_ACTIVITY_FILE APR_ACTIVITY_SCOPE APR_POWER_ANALYSIS_VIEW APR_WORKLOAD_POWER_OPT
unset APR_LEAKAGE_TO_DYNAMIC_RATIO APR_DETAIL_WIRE_LENGTH_OPT_EFFORT
unset SC_DISTRIBUTION_GUIDES SC_PLACE_GUIDES SC_NH SC_NW SC_DIST_HIER_PREFIX SC_TILE_HIER_PREFIX PRE_PLACE_SCRIPT
unset APR_RESUME_FINAL DISABLE_POSTROUTE_SWAPVIA SKIP_FILLER SKIP_FINAL_HOLD_OPT FORCE_FINAL_HOLD_OPT FORCE_STRONG_FINAL_DRC
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'
TB=designs/baselines/binary_os/power/power_binary_os_array.sv
EXPECTED_PASS='PASS: binary OS power SAIF captured + output-checked; 4096 cycles (4096 MAC, 0 drain), 262144 useful MAC'
mkdir -p "$OUT"
stage() {
    local name=$1 artifact=$2; shift 2
    if [[ -f "$work/$name.status" ]]; then
        [[ "$(cat "$work/$name.status")" == PASS && -s "$artifact" ]] || return 1
        echo "[INT$width] reuse $name"; return
    fi
    [[ ! -e "$work/$name.log" && ! -e "$artifact" ]] || { echo "[INT$width] Preserve unfinished $name; inspect and repair before resuming" >&2; return 1; }
    echo "[INT$width] $name started"
    "$@" > "$work/$name.log" 2>&1
    printf 'PASS\n' > "$work/$name.status"
    echo "[INT$width] $name passed"
}
route_design() {
    local rc=0
    [[ ! -e "$route" ]] || { echo "Refusing existing route $route"; return 1; }
    SYNTH_RUN="$synrun" RUN_NAME="$run" make apr TARGET="$target" NTFY_CHNL= || rc=$?
    python3 sweeps/validate_routed_apr.py "$route" "$top" --json "$route/reports/qualification.json"
    if [[ "$rc" != 0 ]]; then echo "make apr returned $rc; independent complete-output qualification passed"; fi
}
simulate() {
    mkdir "$work/gl_final"
    make sim GL=apr TARGET="$target" RUN="$run" TB="$TB" BUILD_DIR="$work/gl_final" \
        SDF_CORNER=max NO_SDF= RTL_PREFLIGHT_CMD=true "VCS=$VCS_CMD" \
        VCS_ARGS="+define+BOS_IWIDTH=$width+define+BOS_GL_DUT=$top+define+BOS_NH=8+define+BOS_NW=8+define+BOS_OWIDTH=24+define+STIM_CYCLES_N=4096+define+BOS_DRAIN_PERIOD=0 +neg_tchk +sdfverbose" \
        NTFY_CHNL= > "$work/gl_final/simulation.log" 2>&1
    python3 sweeps/validate_routed_gl.py "$work/gl_final/simulation.log" --expected-pass "$EXPECTED_PASS" \
        --json "$work/gl_final/timing_qualification.json" > "$work/gl_final/timing_validation.log"
    python3 sweeps/validate_power_saif.py "$work/gl_final/$TB/dut.saif" --expected-period-ns 2.5 > "$work/gl_final/saif_validation.log"
    mkdir -p "$route/activity"
    cp "$work/gl_final/$TB/dut.saif" "$route/activity/dut.saif"
}
measure_power() {
    mkdir "$work/prior_apr_reports"
    cp -p "$route"/reports/*.rpt "$work/prior_apr_reports/"
    POWER_SAIF_VALIDATOR="$REPO/sweeps/validate_power_saif.py" \
        make power_apr TARGET="$target" RUN="$run" SAIF="$route/activity/dut.saif" SAIF_STRIP_PATH=Top/dut NTFY_CHNL=
    python3 sweeps/validate_pt_power_coverage.py "$route/reports" --power-log "$route/power_apr.log" --json "$route/reports/power_coverage.json"
    python3 - "$route" "$width" "$target" "$run" "$work" <<'REPORT'
import csv,json,re,sys
from pathlib import Path
route,width,target,run,work=Path(sys.argv[1]),int(sys.argv[2]),sys.argv[3],sys.argv[4],Path(sys.argv[5])
q=json.loads((route/'reports/qualification.json').read_text())
c=json.loads((route/'reports/power_coverage.json').read_text())
assert q['status']==c['status']=='PASS'
s=(route/'reports/power.rpt').read_text()
m=re.search(r'Total Power\s*=\s*([0-9.eE+-]+)',s);assert m
power=float(m[1])*1000
row=dict(IWIDTH=width,N_H=8,N_W=8,OWIDTH=24,period_ns=2.5,voltage_V=0.8,mac_cycles=4096,drain_cycles=0,GMAC_s=25.6,target=target,run=run,power_mW=power,pJ_MAC=power*2.5/64,**q)
with (work/'result.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=row);w.writeheader();w.writerow(row)
print(json.dumps(row,indent=2))
REPORT
}
run_width() (
    width=$1;target=TSMC22/BOS_ARRAY_INT$width;top=binary_os_array_int$width
    synrun=${SYN_CAMPAIGN}_int$width;run=${CAMPAIGN}_int$width
    work="$OUT/int$width";route="$REPO/apr/build/$target/$run"
    mkdir -p "$work"
    exec 9>"$work/worker.lock";flock -n 9 || exit 2
    current=inputs
    trap 'rc=$?; printf "FAIL stage=%s exit=%s\n" "$current" "$rc" >> "$work/failures.log"; exit "$rc"' ERR
    [[ "$(cat "$REPO/build/bos_precision/$SYN_CAMPAIGN/int$width/status")" == PASS ]]
    [[ -s "$REPO/syn/build/$target/$synrun/$top.syn.v" ]]
    manifest=$(printf 'target=%s\nsynthesis=%s\nrun=%s\n8x8 OW24 period2.5 input1.25 uncertainty0.125 util0.75 HPK1 APR_MULTIBIT1 APR_OPT_POWER1\n' "$target" "$synrun" "$run")
    if [[ -e "$work/inputs.txt" ]]; then
        [[ "$(cat "$work/inputs.txt")" == "$manifest" ]] || { echo 'Run settings changed; choose a new CAMPAIGN' >&2; exit 2; }
    else
        printf '%s\n' "$manifest" > "$work/inputs.txt"
    fi
    current=apr;stage "$current" "$route/reports/qualification.json" route_design
    current=simulation;stage "$current" "$route/activity/dut.saif" simulate
    current=power;stage "$current" "$work/result.csv" measure_power
    echo "[INT$width] complete: $work/result.csv"
)
pids=()
for width in "${WIDTHS[@]}"; do run_width "$width" & pids+=("$!"); done
status=0
for pid in "${pids[@]}"; do if wait "$pid"; then :; else status=1; fi; done
[[ "$status" == 0 ]] || exit "$status"
python3 sweeps/report_bos_precision_apr.py --campaign "$CAMPAIGN" --widths "${WIDTHS[@]}"
