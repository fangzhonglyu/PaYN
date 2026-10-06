#!/bin/bash
# BOS baseline (designs/baselines/binary_os): the native signed INT8 / INT6 / INT4 output-stationary 8x8 arrays
# (targets TSMC22/BOS_ARRAY, BOS_ARRAY_INT6, BOS_ARRAY_INT4; 24-bit accumulators, 64 MAC/cycle, 400 MHz), from RTL
# to routed PrimeTime power, with the same tools and gates as the PaYN flow.
#   bash flow/bos.sh CAMPAIGN [8] [6] [4]          # default widths 8 6 4
#   DRY_RUN=1 bash flow/bos.sh CAMPAIGN 6 4        # the plan, with each stage's state
#   RETRY_FAILED=1 bash flow/bos.sh CAMPAIGN 6     # redo a failed stage (its output moved aside)
# Per width, stages (PASS marker + log each, in build/flow/bos/<CAMPAIGN>/int<W>/; resume only from markers):
#   rtl       test_binary_os_array.sv on RTL: independent golden matmul, signed extremes, hold, drain priority,
#             both accumulator wrap directions
#   workload  power_binary_os_array.sv on RTL, 4,096 MAC cycles, outputs checked; qualify.py saif-binary
#   synth     make synth (RUN_NAME <CAMPAIGN>_int<W>) with that SAIF as the synthesis activity; setup met, native
#             port widths (a_in / w_in 8 x W bits, 192-bit accumulator ports)
#   syn-func  the RTL test on the synthesized cells, unit delay
#   apr       make apr (CORE_UTIL 0.75, APR power and multibit optimization, uncertainty 0.125 ns); qualify.py
#             routed-apr (report-file rules: no geometry / antenna / connectivity / placement violation, timing met)
#   sim       full-timing max-SDF GL of the route with the power bench (+neg_tchk +sdfverbose, no drain in the
#             window); qualify.py routed-gl strict and saif-binary
#   power     make power_apr (PT-PX, routed SPEF) on the route with that SAIF; qualify.py pt-coverage; result.csv
#             (power, pJ/MAC = P x 2.5 ns / 64, area, slacks, coverage)
# Results: build/flow/bos/<CAMPAIGN>/results.csv; synthesis and routes syn/build/<target>/<CAMPAIGN>_int<W>,
# apr/build/<target>/<CAMPAIGN>_int<W>.  An existing run directory is never replaced (choose a new CAMPAIGN).
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
CAMPAIGN=${1:?usage: bash flow/bos.sh CAMPAIGN [8] [6] [4]}
shift
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "CAMPAIGN must match [A-Za-z0-9_]+" >&2; exit 2; }
WIDTHS=("$@"); ((${#WIDTHS[@]})) || WIDTHS=(8 6 4)
DRY_RUN=${DRY_RUN:-0}
RETRY_FAILED=${RETRY_FAILED:-0}
for w in "${WIDTHS[@]}"; do [[ "$w" =~ ^(8|6|4)$ ]] || { echo "unsupported width $w" >&2; exit 2; }; done
source "$REPO/flow/env.sh"
# BOS synthesis / APR knobs (the PaYN APR block of env.sh minus guides, plus the BOS route's optimizations).
export MULTIBIT_INFER=1 CLOCK_GATE=1 MINPOWER=0 FLATTEN=0 SYN_AREA_HIGH_EFFORT=0 MAX_FANOUT=16
export CORE_UTIL=0.75 APR_OPT_POWER=1 APR_MULTIBIT_FLOP_OPT=1 APR_LEAN_OPT=0
export PRE_REPORT_SCRIPT=apr/scripts/check_final_placement.tcl
unset SC_PLACE_GUIDES SC_NH SC_NW SYN_SAIF_FILE SYN_SAIF_INSTANCE MULTICYCLE_INPUT_PORTS MULTICYCLE_INPUT_CYCLES
unset CLOCK_GATE_MAX_FANOUT DISABLE_POSTROUTE_SWAPVIA
TEST=designs/baselines/binary_os/tb/test_binary_os_array.sv
POWER_TB=designs/baselines/binary_os/power/power_binary_os_array.sv
WORKLOAD_PASS='PASS: binary OS power SAIF captured + output-checked; 4096 cycles (4096 MAC, 0 drain), 262144 useful MAC'
OUT="$REPO/build/flow/bos/$CAMPAIGN"
QUALIFY=(python3 "$REPO/flow/qualify.py")

stage() {   # name artifact description command...
    local name=$1 artifact=$2 what=$3 marker attempt=1 log
    shift 3
    marker="$work/$name.status"
    if [[ "$DRY_RUN" == 1 ]]; then
        local state=pending
        [[ ! -f "$marker" ]] || state=$(cat "$marker")
        [[ -f "$marker" || ! -e "$artifact" ]] || state="output exists without a marker"
        echo "[INT$width] stage $name: $state"
        echo "    output   $artifact"
        echo "    $what"
        return 0
    fi
    if [[ -f "$marker" ]]; then
        [[ "$(cat "$marker")" == PASS && -e "$artifact" ]] || { echo "[INT$width] invalid completed stage $name" >&2; return 1; }
        echo "[INT$width] reuse completed $name"
        return 0
    fi
    while [[ -e "$work/$name.attempt_$attempt.log" ]]; do attempt=$((attempt + 1)); done
    if [[ -e "$artifact" || "$attempt" -gt 1 ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "[INT$width] unfinished $name preserved; inspect, then RETRY_FAILED=1" >&2; return 1; }
        [[ ! -e "$artifact" ]] || mv "$artifact" "$artifact.failed_$(date +%Y%m%d_%H%M%S)_$BASHPID"
    fi
    log="$work/$name.attempt_$attempt.log"
    echo "[INT$width] $name started $(date -Is); $log"
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[INT$width] $name passed $(date -Is)"
}

do_rtl() {
    mkdir -p "$work/rtl"
    make sim GL= TARGET= TOP=Top TB="$TEST" BUILD_DIR="$work/rtl" VCS_ARGS="$defs" "VCS=$FLOW_VCS" NTFY_CHNL= \
        > "$work/rtl/simulation.log" 2>&1 || true
    grep -q "PASS: binary OS INT$width array matched golden matmul" "$work/rtl/simulation.log"
}

do_workload() {
    mkdir -p "$work/workload"
    make sim GL= TARGET= TOP=Top TB="$POWER_TB" BUILD_DIR="$work/workload" \
        VCS_ARGS="$defs +define+STIM_CYCLES_N=4096 -debug_access+pp" "VCS=$FLOW_VCS" NTFY_CHNL= \
        > "$work/workload/simulation.log" 2>&1 || true
    grep -qF "$WORKLOAD_PASS" "$work/workload/simulation.log"
    [[ -s "$work/workload/$POWER_TB/dut.saif" ]]
    "${QUALIFY[@]}" saif-binary "$work/workload/$POWER_TB/dut.saif"
}

do_synth() {
    [[ ! -e "$syn" ]] || { echo "refusing existing synthesis $syn"; return 1; }
    RUN_NAME="$run" SYN_SAIF_FILE="$work/workload/$POWER_TB/dut.saif" SYN_SAIF_INSTANCE=Top/dut \
        make synth TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    [[ -s "$syn/$top.syn.v" && -s "$syn/area.rpt" && -s "$syn/timing.rpt" ]]
    python3 - "$syn" "$top" "$width" <<'PY'
import re, sys
from pathlib import Path
syn, top, width = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
slacks = [float(x) for x in re.findall(r"slack \((?:MET|VIOLATED)\)\s+([-+0-9.]+)", (syn / "timing.rpt").read_text())]
assert slacks and min(slacks) >= 0, f"synthesis setup slack {slacks and min(slacks)}"
body = re.search(r"\bmodule\s+" + re.escape(top) + r"\s*\(.*?endmodule", (syn / f"{top}.syn.v").read_text(), re.S)[0]
for name, bits in (("a_in", 8 * width), ("w_in", 8 * width), ("acc_in_west", 192), ("acc_out_east", 192)):
    d = re.search(r"\b(?:input|output)\s+\[(\d+):(\d+)\]\s+" + name + r"\s*;", body)
    assert d and abs(int(d[1]) - int(d[2])) + 1 == bits, f"unexpected native port width: {name}"
area = re.search(r"Total cell area:\s*([0-9.]+)", (syn / "area.rpt").read_text())[1]
print(f"synthesis {syn.name}: {area} um2, setup slack {min(slacks):+.3f} ns, native INT{width} ports")
PY
}

do_syn_func() {
    mkdir -p "$work/syn_func"
    make sim GL=syn TARGET="$target" RUN="$run" TB="$TEST" BUILD_DIR="$work/syn_func" NO_SDF=1 \
        RTL_PREFLIGHT_CMD=true VCS_ARGS="$defs +define+ARM_UD_MODEL +notimingcheck" "VCS=$FLOW_VCS" NTFY_CHNL= \
        ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$work/syn_func/simulation.log" 2>&1 || true
    grep -q "PASS: binary OS INT$width array matched golden matmul" "$work/syn_func/simulation.log"
}

do_apr() {
    local rc=0
    [[ ! -e "$route" ]] || { echo "refusing existing route $route"; return 1; }
    SYNTH_RUN="$run" RUN_NAME="$run" make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" || rc=$?
    echo "make apr returned $rc (the routed-apr qualification decides)"
    "${QUALIFY[@]}" routed-apr "$route" "$top" --json "$work/qualification.json"
}

do_sim() {
    mkdir -p "$work/gl"
    make sim GL=apr TARGET="$target" RUN="$run" TB="$POWER_TB" BUILD_DIR="$work/gl" SDF_CORNER=max NO_SDF= \
        RTL_PREFLIGHT_CMD=true "VCS=$FLOW_VCS" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
        VCS_ARGS="$defs +define+STIM_CYCLES_N=4096 +define+BOS_DRAIN_PERIOD=0 +neg_tchk +sdfverbose" \
        > "$work/gl/simulation.log" 2>&1 || true
    grep -qF "$WORKLOAD_PASS" "$work/gl/simulation.log"
    "${QUALIFY[@]}" routed-gl "$work/gl/simulation.log" --expected-pass "$WORKLOAD_PASS" \
        --json "$work/gl/timing_qualification.json"
    "${QUALIFY[@]}" saif-binary "$work/gl/$POWER_TB/dut.saif" --expected-period-ns 2.5 | tee "$work/gl/saif_validation.log"
}

do_power() {
    mkdir -p "$work/power/prior_apr_reports"
    cp -p "$route"/reports/*.rpt "$work/power/prior_apr_reports/"
    make power_apr TARGET="$target" RUN="$run" SAIF="$work/gl/$POWER_TB/dut.saif" SAIF_STRIP_PATH=Top/dut \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    grep -q 'Report : Averaged Power' "$route/reports/power.rpt"
    "${QUALIFY[@]}" pt-coverage "$route/reports" --power-log "$route/power_apr.log" \
        --json "$work/power/power_coverage.json"
    cmp -s "$work/gl/$POWER_TB/dut.saif" "$route/activity/dut.saif"
    cp -p "$route/reports/power.rpt" "$route/power_apr.log" "$work/power/"
    python3 - "$work" "$width" "$target" "$run" <<'PY'
import csv, json, re, sys
from pathlib import Path
work, width, target, run = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
q = json.loads((work / "qualification.json").read_text())
c = json.loads((work / "power/power_coverage.json").read_text())
g = json.loads((work / "gl/timing_qualification.json").read_text())
assert q["status"] == c["status"] == g["status"] == "PASS"
power = float(re.search(r"Total Power\s*=\s*([0-9.eE+-]+)", (work / "power/power.rpt").read_text())[1]) * 1e3
row = dict(IWIDTH=width, N_H=8, N_W=8, OWIDTH=24, period_ns=2.5, mac_cycles=4096, drain_cycles=0, GMAC_s=25.6,
           target=target, run=run, power_mW=power, pJ_MAC=power * 2.5 / 64, **q,
           **{k: v for k, v in c.items() if k != "status"}, sdf_errors=sum(g["sdf_errors"]),
           post_reset_timing_violations=g["post_reset_timing_violations"])
with (work / "result.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(row)); w.writeheader(); w.writerow(row)
print(json.dumps(row, indent=2))
PY
}

run_width() (
    width=$1
    target=TSMC22/BOS_ARRAY_INT$width top=binary_os_array_int$width
    if [[ "$width" == 8 ]]; then target=TSMC22/BOS_ARRAY top=binary_os_array; fi
    run=${CAMPAIGN}_int$width
    work="$OUT/int$width" syn="$REPO/syn/build/$target/$run" route="$REPO/apr/build/$target/$run"
    defs="+define+BOS_IWIDTH=$width +define+BOS_GL_DUT=$top +define+BOS_NH=8 +define+BOS_NW=8 +define+BOS_OWIDTH=24"
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[INT$width] target $target, top $top, synthesis $syn, route $route"
    else
        mkdir -p "$work"
        exec 9>"$work/worker.lock"; flock -n 9 || { echo "[INT$width] another worker owns $work" >&2; exit 2; }
    fi
    stage rtl "$work/rtl" "make sim TB=$TEST VCS_ARGS='$defs' (RTL golden matmul)" do_rtl
    stage workload "$work/workload" "make sim TB=$POWER_TB VCS_ARGS='$defs +define+STIM_CYCLES_N=4096'; qualify.py saif-binary" do_workload
    stage synth "$syn" "RUN_NAME=$run SYN_SAIF_FILE=<workload SAIF> make synth TARGET=$target" do_synth
    stage syn-func "$work/syn_func" "make sim GL=syn TB=$TEST NO_SDF=1 (unit delay)" do_syn_func
    stage apr "$route" "SYNTH_RUN=$run RUN_NAME=$run make apr TARGET=$target (CORE_UTIL=$CORE_UTIL APR_OPT_POWER=$APR_OPT_POWER APR_MULTIBIT_FLOP_OPT=$APR_MULTIBIT_FLOP_OPT); qualify.py routed-apr" do_apr
    stage sim "$work/gl" "make sim GL=apr TB=$POWER_TB SDF_CORNER=max (+neg_tchk +sdfverbose); qualify.py routed-gl, saif-binary" do_sim
    stage power "$work/result.csv" "make power_apr TARGET=$target RUN=$run; qualify.py pt-coverage; result.csv" do_power
)

[[ "$DRY_RUN" == 1 ]] && echo "DRY RUN: BOS campaign $CAMPAIGN, widths ${WIDTHS[*]}, out $OUT (ASTRAEA_FLOW=$ASTRAEA_FLOW)"
pids=()
for w in "${WIDTHS[@]}"; do
    if [[ "$DRY_RUN" == 1 ]]; then run_width "$w"; else run_width "$w" & pids+=("$!"); fi
done
status=0
for p in "${pids[@]}"; do wait "$p" || status=1; done
if [[ "$DRY_RUN" == 0 && "$status" == 0 ]]; then
    python3 - "$OUT" "${WIDTHS[@]}" <<'PY'
import csv, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = [next(csv.DictReader((out / f"int{w}" / "result.csv").open())) for w in sys.argv[2:]]
with (out / "results.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
print(out / "results.csv")
PY
fi
exit "$status"
