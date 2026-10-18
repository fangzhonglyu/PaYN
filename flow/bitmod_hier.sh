#!/bin/bash
# BitMoD area / power breakdown: the bitmod 8x8 tile with pe_scratch_h PEs (target TSMC22/BITMOD_TILE_H; the same PE
# logic split into one submodule per function) from RTL to routed PrimeTime power in each datatype mode, with the
# tools, knobs and gates of flow/bos.sh and flow/flexposit.sh.
#   bash flow/bitmod_hier.sh CAMPAIGN [MODE ...]     # default modes 3 (i8 x f16) 2 (i6 x f16) 1 (f4 x f16)
#   DRY_RUN=1 bash flow/bitmod_hier.sh CAMPAIGN     # the plan, with each stage's state
#   RETRY_FAILED=1 bash flow/bitmod_hier.sh CAMPAIGN
# Stages (PASS marker + log each, in build/flow/bitmod_hier/<CAMPAIGN>/; resume only from markers):
#   gen         regenerate bitmod_tile_h.sv from bitmod_tile.sv; the module body must differ from `tile` in exactly the
#               module name and the PE instance type
#   eq          tb/eq_pe_scratch_h.sv, two seeds x 200,000 random cycles: every pipeline register and output of
#               pe_scratch_h equals pe_scratch's, X-exact, every cycle
#   rtl         the golden test (tb/test_bitmod_tile.sv, the target's preflight) on the original tile, mode 3 (its
#               reference closes only for the integer term path; see do_rtl)
#   synth-flat  make synth TARGET=TSMC22/BITMOD_TILE at 2.5 ns (RUN_NAME <CAMPAIGN>_flat): reference area of the
#               unmodified tile with today's flow, to measure what the new boundaries cost
#   synth-area  make synth TARGET=TSMC22/BITMOD_TILE_H at 2.5 ns (RUN_NAME <CAMPAIGN>_p25): the area breakdown
#   synth       make synth TARGET=TSMC22/BITMOD_TILE_H at SYN_PERIOD (default 2.25 ns; RUN_NAME <CAMPAIGN>): the netlist
#               routed for power.  The earlier BITMOD_TILE routes missed 2.5 ns by up to 27 ps and their gate-level
#               runs went X on setup violations in stage 1, so the power route is over-constrained; it is simulated and
#               measured at 400 MHz.  Setup must be met.
#   apr         make apr (CORE_UTIL 0.70 as the BITMOD_TILE target, APR power and multibit optimization, uncertainty
#               0.125 ns; the clock is the synthesis SDC's); log: clock uncertainty line; outputs written
#   qualify     qualify.py routed-apr; on failure up to two targeted make apr_repair runs (in place; placement overlaps via
#               flow/apr_overlap_repair.sh, the same repair planned from the checkPlace reports), each planned from
#               the current markers, re-qualifying after each.  If the only rejection left is timing against the
#               over-constrained SYN_PERIOD clock, the route is qualified at its 2.5 ns operating clock with ASTRAEA's
#               rules unchanged: report files as routed, slacks from the same Innovus reports regenerated from the
#               final database with only the clock period re-timed (flow/tcl/innovus_opclock_reports.tcl, which must
#               first reproduce the route's own reports).  A PrimeTime STA at 2.5 ns (flow/tcl/pt_sta_opclock.tcl) is
#               recorded beside it, not gating: Innovus's register-to-register slacks are optimistic by the clock
#               insertion delay (CCOpt's -max-only source latency read under OCV), for every ASTRAEA route alike
#   rtl-m<M>    the power bench on RTL with the ORIGINAL tile in mode M: the reference drained matrix (DRAIN lines)
#   sim-m<M>    the power bench on the routed tile_h netlist, max SDF, +neg_tchk +sdfverbose: PASS, the DRAIN lines
#               identical to rtl-m<M>, qualify.py gl-audit (strict first; the -2 ps clamp approval only after a strict
#               failure and only with $work's rationale file),
#               saif-binary
#   power-m<M>  make power_apr (PT-PX, routed SPEF); pt-coverage; result_m<M>.csv (power, pJ/MAC = P x window x 2.5 ns
#               / useful MAC; the window holds every MAC cycle and closes at the first drain beat, as for BOS)
# Results: build/flow/bitmod_hier/<CAMPAIGN>/results.csv; synthesis syn/build/TSMC22/BITMOD_TILE_H/<run>,
# route apr/build/TSMC22/BITMOD_TILE_H/<CAMPAIGN>.  Breakdown report: python3 flow/bitmod_hier_report.py <CAMPAIGN>.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
CAMPAIGN=${1:?usage: bash flow/bitmod_hier.sh CAMPAIGN [MODE ...]}
shift
[[ "$CAMPAIGN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "CAMPAIGN must match [A-Za-z0-9_]+" >&2; exit 2; }
MODES=("$@"); ((${#MODES[@]})) || MODES=(3 2 1)
for m in "${MODES[@]}"; do [[ "$m" =~ ^[123]$ ]] || { echo "unsupported mode $m" >&2; exit 2; }; done
DRY_RUN=${DRY_RUN:-0}
RETRY_FAILED=${RETRY_FAILED:-0}
SYN_PERIOD=${SYN_PERIOD:-2.25}
source "$REPO/flow/env.sh"
export MULTIBIT_INFER=1 CLOCK_GATE=1 MINPOWER=0 FLATTEN=0 SYN_AREA_HIGH_EFFORT=0 MAX_FANOUT=16
export CORE_UTIL=0.70 APR_OPT_POWER=1 APR_MULTIBIT_FLOP_OPT=1 APR_LEAN_OPT=0
export PRE_REPORT_SCRIPT=apr/scripts/check_final_placement.tcl
unset SC_PLACE_GUIDES SC_NH SC_NW SYN_SAIF_FILE SYN_SAIF_INSTANCE MULTICYCLE_INPUT_PORTS MULTICYCLE_INPUT_CYCLES
unset CLOCK_GATE_MAX_FANOUT DISABLE_POSTROUTE_SWAPVIA

BM=designs/baselines/bitmod
EQ_TB=$BM/tb/eq_pe_scratch_h.sv
GOLD_TB=$BM/tb/test_bitmod_tile.sv
POWER_TB=$BM/power/power_bitmod_tile.sv
target=TSMC22/BITMOD_TILE_H top=tile_h run=$CAMPAIGN label=BITMOD_H
work="$REPO/build/flow/bitmod_hier/$CAMPAIGN"
syn="$REPO/syn/build/$target/$run" route="$REPO/apr/build/$target/$run"
syn_area="$REPO/syn/build/$target/${CAMPAIGN}_p25" syn_flat="$REPO/syn/build/TSMC22/BITMOD_TILE/${CAMPAIGN}_flat"
QUALIFY=(python3 "$REPO/flow/qualify.py")

stage() {   # name artifact description command...   (flow/bos.sh's stage runner)
    local name=$1 artifact=$2 what=$3 marker attempt=1 log
    shift 3
    marker="$work/$name.status"
    if [[ "$DRY_RUN" == 1 ]]; then
        local state=pending
        [[ ! -f "$marker" ]] || state=$(cat "$marker")
        [[ -f "$marker" || ! -e "$artifact" ]] || state="output exists without a marker"
        echo "[$label] stage $name: $state"
        echo "    output   $artifact"
        echo "    $what"
        return 0
    fi
    if [[ -f "$marker" ]]; then
        [[ "$(cat "$marker")" == PASS && -e "$artifact" ]] || { echo "[$label] invalid completed stage $name" >&2; return 1; }
        echo "[$label] reuse completed $name"
        return 0
    fi
    while [[ -e "$work/$name.attempt_$attempt.log" ]]; do attempt=$((attempt + 1)); done
    if [[ -e "$artifact" || "$attempt" -gt 1 ]]; then
        [[ "$RETRY_FAILED" == 1 ]] || { echo "[$label] unfinished $name preserved; inspect, then RETRY_FAILED=1" >&2; return 1; }
        [[ ! -e "$artifact" ]] || mv "$artifact" "$artifact.failed_$(date +%Y%m%d_%H%M%S)_$BASHPID"
    fi
    log="$work/$name.attempt_$attempt.log"
    echo "[$label] $name started $(date -Is); $log"
    "$@" > "$log" 2>&1
    printf 'PASS\n' > "$marker"
    echo "[$label] $name passed $(date -Is)"
}

sim_run() {   # dir tb pass_regex make-args...: one bench run, grep its PASS line
    local dir=$1 tb=$2 pass=$3
    shift 3
    mkdir -p "$dir"
    make sim TOP=Top TB="$tb" BUILD_DIR="$dir" "VCS=$FLOW_VCS" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" "$@" \
        > "$dir/simulation.log" 2>&1 || true
    grep -m1 -E "$pass" "$dir/simulation.log"
}

do_gen() {
    mkdir -p "$work"
    python3 - "$REPO/$BM" <<'PY'
from pathlib import Path
import sys
bm = Path(sys.argv[1])
src = (bm / "bitmod_tile.sv").read_text().splitlines(keepends=True)
start = next(i for i, l in enumerate(src) if l.startswith("module tile #("))
end = next(i for i in range(start, len(src)) if src[i].startswith("endmodule"))
body = "".join(src[start:end + 1])
assert body.count("module tile #(") == 1 and body.count("            pe_scratch pe (") == 1
new = body.replace("module tile #(", "module tile_h #(", 1).replace("            pe_scratch pe (", "            pe_scratch_h pe (", 1)
out = bm / "bitmod_tile_h.sv"
text = out.read_text()
hdr = text[: text.index("module tile_h #(")]
out.write_text(hdr + new + "`endif\n")
diff = [(a, b) for a, b in zip(body.splitlines(), new.splitlines()) if a != b]
assert len(diff) == 2, diff
print("tile_h regenerated; differs from tile in:", diff)
PY
    printf 'ok\n' > "$work/gen.txt"
}

do_eq() {
    local seed
    for seed in 1592505725 195936478; do
        sim_run "$work/eq/$seed" "$EQ_TB" '^PASS: pe_scratch_h equivalent' GL= TARGET= VCS_ARGS="+define+EQ_SEED=$seed"
    done
}

do_rtl() {
    # Mode 3 only: the golden test's reference (upstream check_en: +-1.0 activations, 3-bit integer weights, integer
    # group scales) closes only for the integer term path, so it also "fails" the unmodified tile in f4 mode
    # (checked 2026-10-16: 64/64 mismatches on BITMOD_TILE's own tile).  The other modes are covered by
    # eq_pe_scratch_h.sv (random terms, bsig and stage controls) and by each mode's gate-level == RTL drain check.
    sim_run "$work/rtl/m3" "$GOLD_TB" '^PASS: bitmod tile output-checked' GL= TARGET= VCS_ARGS="+define+BITMOD_MODE=3"
}

syn_check() {   # dir top require_met
    python3 - "$1" "$2" "$3" <<'PY'
import re, sys
from pathlib import Path
syn, top, need = Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
slacks = [float(x) for x in re.findall(r"slack \((?:MET|VIOLATED)\)\s+([-+0-9.]+)", (syn / "timing.rpt").read_text())]
area = re.search(r"Total cell area:\s*([0-9.]+)", (syn / "area.rpt").read_text())[1]
print(f"synthesis {syn.name}: {area} um2, worst setup slack {min(slacks):+.3f} ns")
assert slacks and (min(slacks) >= 0 or not need), f"setup slack {min(slacks)}"
PY
}

do_synth_flat() {
    [[ ! -e "$syn_flat" ]] || { echo "refusing existing synthesis $syn_flat"; return 1; }
    RUN_NAME="${CAMPAIGN}_flat" PERIOD=2.5 RTL_PREFLIGHT_CMD=true make synth TARGET=TSMC22/BITMOD_TILE NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    syn_check "$syn_flat" tile 0
}

do_synth_area() {
    [[ ! -e "$syn_area" ]] || { echo "refusing existing synthesis $syn_area"; return 1; }
    RUN_NAME="${CAMPAIGN}_p25" PERIOD=2.5 make synth TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    syn_check "$syn_area" "$top" 0
}

do_synth() {
    [[ ! -e "$syn" ]] || { echo "refusing existing synthesis $syn"; return 1; }
    RUN_NAME="$run" PERIOD="$SYN_PERIOD" make synth TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    grep -q "create_clock.*-period $SYN_PERIOD\|period $SYN_PERIOD" "$syn/$top.syn.sdc" || { echo "SDC period is not $SYN_PERIOD"; return 1; }
    syn_check "$syn" "$top" 1
}

do_apr() {
    local rc=0
    [[ ! -e "$route" ]] || { echo "refusing existing route $route"; return 1; }
    SYNTH_RUN="$run" RUN_NAME="$run" make apr TARGET="$target" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" || rc=$?
    echo "make apr returned $rc (the routed-apr qualification decides)"
    local unc="INFO: APR clock uncertainty $CLOCK_UNCERTAINTY ns, setup and hold"
    grep -qF "$unc" "$route/apr.log" || { echo "apr.log lacks the clock uncertainty line: $unc"; return 1; }
    [[ -s "$route/outputs/$top.apr.v" && -s "$route/outputs/$top.apr.sdf" && -s "$route/outputs/$top.spef" ]]
}

do_qualify() {   # up to two targeted repairs, each planned from the route's current markers
    local i
    for i in 1 2; do
        "${QUALIFY[@]}" routed-apr "$route" "$top" --json "$work/qualification.json" && return 0
        python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["reason"]; sys.exit(0 if r.startswith(("setup timing violation","hold timing violation")) else 1)' \
            "$work/qualification.json" && break
        if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["reason"] == "placement violations" else 1)' \
                "$work/qualification.json"; then
            # make apr_repair plans overlaps from apr.log's NRDB-2082 messages, which can miss the last checkPlace's
            echo "routed-apr failed; overlap repair $i (flow/apr_overlap_repair.sh: make apr_repair planned from the checkPlace reports)"
            bash "$REPO/flow/apr_overlap_repair.sh" "$target" "$run" || true
        else
            echo "routed-apr failed; targeted repair $i (make apr_repair, in place, prior state kept in the route's before_repair_*/)"
            make apr_repair TARGET="$target" RUN="$run" NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" || true
        fi
    done
    "${QUALIFY[@]}" routed-apr "$route" "$top" --json "$work/qualification.json" && return 0
    # The only rejection left may be timing against the over-constrained synthesis clock (SYN_PERIOD).  The route is
    # used at 400 MHz, so qualify it there with ASTRAEA's rules unchanged (apr_qualify.audit_route_reports:
    # completion, outputs, geometry, antenna, connectivity, placement, area, and route_slacks: the first "Slack Time"
    # of the setup/hold reports), the timing reports regenerated by Innovus from the final database at 2.5 ns.
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["reason"]; sys.exit(0 if r.startswith(("setup timing violation","hold timing violation")) else 1)' \
        "$work/qualification.json" || return 1
    mv "$work/qualification.json" "$work/qualification_at_syn_clock.json"
    rm -rf "$work/innovus_opclock"; mkdir -p "$work/innovus_opclock"
    (cd "$work/innovus_opclock" && RUN_DIR="$route" TOP="$top" OP_PERIOD=2.5 OUT_DIR="$work/innovus_opclock" \
        innovus -batch -no_gui -files "$REPO/flow/tcl/innovus_opclock_reports.tcl" > innovus_opclock.log 2>&1)
    grep -q '^INNOVUS_OPCLOCK_DONE' "$work/innovus_opclock/innovus_opclock.log" || return 1
    # Recorded, not gating: PrimeTime at 2.5 ns (synthesis SDC re-timed, so without CCOpt's source latency).
    rm -rf "$work/sta_opclock"; mkdir -p "$work/sta_opclock"
    (cd "$work/sta_opclock" && RUN_DIR="$route" TOP="$top" OP_PERIOD=2.5 OP_UNCERTAINTY="$CLOCK_UNCERTAINTY" \
        OUT_DIR="$work/sta_opclock" pt_shell -f "$REPO/flow/tcl/pt_sta_opclock.tcl" > "$work/sta_opclock/pt.log" 2>&1)
    python3 - "$ASTRAEA_FLOW/apr/scripts/apr_qualify.py" "$route" "$top" "$work" "$SYN_PERIOD" <<'PY'
import importlib.util, json, re, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("aq", sys.argv[1]); aq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aq)
route, top, work, syn_period = Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]), float(sys.argv[5])
inv = work / "innovus_opclock"
# The restored session must time the route exactly as its own final reports do (compared as text: route_slacks
# itself rejects the negative slack at the synthesis clock).
restored_check = {}
for kind in ("setup", "hold"):
    own = re.search(r"Slack Time\s*([-+0-9.]+)", (route / "reports" / f"{kind}.rpt").read_text())[1]
    again = re.search(r"Slack Time\s*([-+0-9.]+)", (inv / "restored/reports" / f"{kind}.rpt").read_text())[1]
    assert own == again, f"restored {kind} slack {again} differs from the route's own {own}"
    restored_check[kind] = float(own)
period = re.search(r"clock period now ([0-9.]+) ns", (inv / "innovus_opclock.log").read_text())
assert period and float(period[1]) == 2.5, "Innovus clock not re-timed to 2.5 ns"
op = aq.route_slacks(inv / "opclock")      # ASTRAEA's own rule on the re-timed reports; raises on a violation
aq.route_slacks = lambda _route: dict(op)
result = aq.audit_route_reports(route, top)
setup_rpt = (inv / "opclock/reports/setup.rpt").read_text()
checks = re.findall(r"^Path \d+: \w+ (.+?) with Pin.*?Slack Time\s*([-+0-9.]+)", setup_rpt, re.M | re.S)
worst_real = min(float(s) for kind, s in checks if "Latch Borrowed" not in kind)
log = (work / "sta_opclock/pt.log").read_text()
m = re.search(r"OPCLOCK_STA period=([0-9.]+) uncertainty=([0-9.]+) setup_wns=([-+0-9.eE]+) hold_wns=([-+0-9.eE]+)", log)
assert m and not re.search(r"^Error:", log, re.M), "PrimeTime STA at the operating clock did not complete"
syn = json.loads((work / "qualification_at_syn_clock.json").read_text())
result.update(qualification="reports; timing from Innovus reports regenerated at the 2.5 ns operating clock "
                            "(innovus_opclock_reports.tcl), ASTRAEA's slack rule",
              op_period_ns=2.5, syn_period_ns=syn_period, timing_at_syn_clock=syn["reason"],
              restored_slacks_at_syn_clock_ns=restored_check,
              op_worst_setup_excluding_latch_borrow_ns=worst_real,
              primetime_at_op_clock=dict(uncertainty_ns=float(m[2]), setup_wns_ns=float(m[3]),
                                         hold_wns_ns=float(m[4]), gating=False))
(work / "qualification.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
PY
}

PASS_RE='^PASS: bitmod tile power SAIF captured'

do_rtl_mode() {   # M
    local m=$1 d="$work/rtl_m$1"
    sim_run "$d" "$POWER_TB" "$PASS_RE" GL= TARGET= VCS_ARGS="+define+BITMOD_MODE=$m -debug_access+pp" > "$d.pass"
    grep '^DRAIN ' "$d/simulation.log" > "$d.drains"
    [[ $(wc -l < "$d.drains") == 64 ]]
}

do_sim_mode() {   # M
    local m=$1 gl="$work/gl_m$1" pass
    pass=$(sim_run "$gl" "$POWER_TB" "$PASS_RE" GL=apr TARGET="$target" RUN="$run" SDF_CORNER=max NO_SDF= \
        RTL_PREFLIGHT_CMD=true VCS_ARGS="+define+BITMOD_MODE=$m +define+BITMOD_GL_DUT=$top +neg_tchk +sdfverbose")
    printf '%s\n' "$pass" > "$gl/expected_pass.txt"
    grep '^DRAIN ' "$gl/simulation.log" > "$gl/drains"
    cmp "$gl/drains" "$work/rtl_m$m.drains" && echo "gate-level drained matrix == RTL (64 accumulators)"
    # Strict first; the clamp approval applies only after a strict failure and only if $work's rationale cites it
    # (bm_20261016b: one -2 ps extracted value on a drain-row output-port wire; every outcome in gl_validator_args.txt).
    "${QUALIFY[@]}" gl-audit "$gl" --work "$work" --approve-negative-iopath-clamp-ps=2
    python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["status"] == "PASS"' "$gl/timing_qualification.json"
    "${QUALIFY[@]}" saif-binary "$gl/$POWER_TB/dut.saif" --expected-period-ns 2.5 | tee "$gl/saif_validation.log"
}

do_power_mode() {   # M
    local m=$1 gl="$work/gl_m$1" pw="$work/power_m$1" res="$work/result_m$1.csv"
    mkdir -p "$pw/prior_apr_reports"
    cp -p "$route"/reports/*.rpt "$pw/prior_apr_reports/"
    make power_apr TARGET="$target" RUN="$run" SAIF="$gl/$POWER_TB/dut.saif" SAIF_STRIP_PATH=Top/dut \
        NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW"
    grep -q 'Report : Averaged Power' "$route/reports/power.rpt"
    "${QUALIFY[@]}" pt-coverage "$route/reports" --power-log "$route/power_apr.log" --json "$pw/power_coverage.json"
    cmp -s "$gl/$POWER_TB/dut.saif" "$route/activity/dut.saif"
    cp -p "$route/reports/power.rpt" "$route/reports/power_hier.rpt" "$route/reports/cell_power.rpt" "$route/power_apr.log" "$pw/"
    python3 - "$work" "$m" "$target" "$run" "$gl" "$pw" "$res" <<'PY'
import csv, json, re, sys
from pathlib import Path
work, m, target, run, gl, pw, res = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5]), Path(sys.argv[6]), Path(sys.argv[7])
q = json.loads((work / "qualification.json").read_text())
c = json.loads((pw / "power_coverage.json").read_text())
g = json.loads((gl / "timing_qualification.json").read_text())
assert q["status"] == c["status"] == g["status"] == "PASS"
line = (gl / "expected_pass.txt").read_text()
x = re.search(r"mode=(\d+) beats=(\d+), (\d+) MAC cycles in window \((\d+) total\), (\d+) useful MAC", line)
assert x and int(x[1]) == m, line
window, useful, beats = int(x[3]), int(x[5]), int(x[2])
power = float(re.search(r"Total Power\s*=\s*([0-9.eE+-]+)", (pw / "power.rpt").read_text())[1]) * 1e3
mode = {3: "i8 x f16", 2: "i6 x f16", 1: "f4 x f16"}[m]
row = dict(design="bitmod tile_h", mode=mode, beats=beats, period_ns=2.5, window_cycles=window, useful_mac=useful,
           mac_per_cycle=256 / beats, power_mW=power, pJ_MAC=power * window * 2.5 / useful, target=target, run=run,
           **{k: v for k, v in q.items() if k not in ("route", "top")},
           **{k: v for k, v in c.items() if k != "status"}, sdf_errors=sum(g["sdf_errors"]),
           post_reset_timing_violations=g["post_reset_timing_violations"])
with res.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(row)); w.writeheader(); w.writerow(row)
print(json.dumps(row, indent=2))
PY
}

if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY RUN: BitMoD breakdown campaign $CAMPAIGN, modes ${MODES[*]}, SYN_PERIOD $SYN_PERIOD, out $work"
else
    mkdir -p "$work"
    exec 9>"$work/worker.lock"; flock -n 9 || { echo "[$label] another worker owns $work" >&2; exit 2; }
fi
stage gen "$work/gen.txt" "regenerate bitmod_tile_h.sv from bitmod_tile.sv (2-line difference)" do_gen
stage eq "$work/eq" "eq_pe_scratch_h.sv, 2 seeds x 200k cycles, every register and output X-exact" do_eq
stage rtl "$work/rtl" "golden test_bitmod_tile.sv on the original tile, mode 3" do_rtl
stage synth-flat "$syn_flat" "make synth TARGET=TSMC22/BITMOD_TILE PERIOD=2.5 (reference area)" do_synth_flat
stage synth-area "$syn_area" "make synth TARGET=$target PERIOD=2.5 (area breakdown)" do_synth_area
stage synth "$syn" "make synth TARGET=$target PERIOD=$SYN_PERIOD (power route netlist); setup met" do_synth
stage apr "$route" "SYNTH_RUN=$run make apr TARGET=$target (CORE_UTIL=$CORE_UTIL)" do_apr
stage qualify "$work/qualification.json" "qualify.py routed-apr; one make apr_repair if needed" do_qualify
for m in "${MODES[@]}"; do
    stage "rtl-m$m" "$work/rtl_m$m.drains" "power bench on RTL (original tile), mode $m: reference DRAIN lines" do_rtl_mode "$m"
    stage "sim-m$m" "$work/gl_m$m" "power bench on the routed tile_h, mode $m, max SDF; DRAIN == RTL; gl-audit; saif-binary" do_sim_mode "$m"
    stage "power-m$m" "$work/result_m$m.csv" "make power_apr (mode $m SAIF); pt-coverage; result_m$m.csv" do_power_mode "$m"
done
if [[ "$DRY_RUN" == 0 ]]; then
    python3 - "$work" <<'PY'
import csv, sys
from pathlib import Path
out = Path(sys.argv[1])
rows = [next(csv.DictReader(p.open())) for p in sorted(out.glob("result_m*.csv"), reverse=True)]
if rows:
    with (out / "results.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    print(out / "results.csv")
PY
fi
