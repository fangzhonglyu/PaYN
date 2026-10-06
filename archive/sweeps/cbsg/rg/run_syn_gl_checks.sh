#!/bin/bash
# Post-synthesis gate-level checks for TSMC22/PAYN_SC_CSA_CBSG_RG (designs/payn/variants/signed_segmented_csa_cbsg_rg)
# on the synthesized netlist of RUN (default cbsg_rg_20261005).  Same recipe as sweeps/run_csa_bp_syn_gl_checks.sh.
#
# (unit) Bit-exact golden bench designs/payn/tb/test_payn_array_cbsg_rg.sv on the netlist, NO_SDF, unit delay,
#        ARM_UD_MODEL + ARM_EN_X_SQUASH, timing checks off (functional: proves the netlist implements the RTL --
#        clock gating, multibit banking, reset mapping).  +define+GL_SIM: drain-only comparison (no peeks).
#        Every run's drain mismatch count must equal sweeps/cbsg/rg/predict_faults.py --no-peek for that run's
#        sequencer policy, AND equal the RTL run of the same case in build/cbsg/rg/runs/ (drain_bad, drain_total,
#        edges).  Subset: plain / per-row L / extreme / chunked / per-head / call sequences / 2048-column slice /
#        every L 1..128 / FULL_CYCLES / STALL+JUNK; a blind control (NEG_FREE_PHASE on calls_mix: the netlist's
#        drain-armed phase reset must hide it, 0 mismatches) and two negative controls (NEG_SHORT_BLOCK) that must
#        fail with exactly the predicted (and RTL) count.
# (sdf)  The same cases with the synthesis SDF in its ideal-clock view (max corner, +neg_tchk +sdfverbose, timing
#        checks ON, full library models, no X squash).  The ideal-clock view (sweeps/cbsg/rg/sdf_ideal_clock.py)
#        zeroes only the CK->ECK IOPATHs of the clock-gating cells, i.e. the clock model DC timed with: the raw
#        synthesis SDF gives the unbuffered shared gated clocks (e.g. clk_gate_acc_low_reg_0_ -> 320 acc_low clock
#        pins) 2.8-3.8 ns, longer than the period, so no gated pulse survives (pre-CTS artifact, identical in the
#        PAYN_SC_CSA baseline's synthesis SDF; sweeps/cbsg/rg/gl_x_ladder.sh shows the raw-SDF failure).  The view
#        is served to `make sim` through SYN_DIR=<view> (netlist symlinked, SDF rewritten).  Each log is qualified
#        by sweeps/validate_routed_gl.py; its only accepted rejection is SDFCOM_CFTC when every instance is the
#        async-reset removal check $hold(posedge CK, negedge R) of a DFFRPQ* flop (DC's SDF vs the cell model).
# (power) Smoke run of the GL power bench designs/payn/power/power_payn_array_cbsg_rg.sv on the netlist with the
#        ideal-clock SDF and the APR phase's VCS flags (+neg_tchk +sdfverbose, max corner), short SC_BATCHES:
#        bench PASS, drain recomputed by sweeps/cbsg/rg/check_power_trace.py, trace identical to an RTL run of the
#        same workload, validate_routed_gl.py, validate_sc_power_saif.py, then PrimeTime PX on the synthesized
#        netlist with that SAIF (sweeps/cbsg/rg/pt_syn_power_smoke.tcl: apr/scripts/power.tcl without SPEF) and
#        a check that every net's activity is annotated from the SAIF or the pinless-net policy.
#
#   bash sweeps/cbsg/rg/run_syn_gl_checks.sh                    # RUN=cbsg_rg_20261005, PARTS="unit sdf power"
#   PARTS=unit bash sweeps/cbsg/rg/run_syn_gl_checks.sh
# Outputs: build/cbsg/rg/gl/<RUN>/ (summary syn_gl_checks_summary.log).
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export NTFY_CHNL= PYTHONDONTWRITEBYTECODE=1 SNPSLMD_QUEUE=true
unset NETLIST_FILE SDC_FILE SDF_FILE VCS_ARGS
TARGET=TSMC22/PAYN_SC_CSA_CBSG_RG
RUN=${RUN:-cbsg_rg_20261005}
TOP=payn_array_signed_segmented_csa_cbsg_rg
SYN=syn/build/$TARGET/$RUN
OUT=build/cbsg/rg/gl/$RUN
RTLRUNS=build/cbsg/rg/runs
GOLD=build/cbsg/golden
XG=build/cbsg/rg/golden_extra
TB=designs/payn/tb/test_payn_array_cbsg_rg.sv
PWR=designs/payn/power/power_payn_array_cbsg_rg.sv
PARTS=${PARTS:-"unit sdf power"}
MAX_JOBS=${MAX_JOBS:-8}
PWR_BATCHES=${PWR_BATCHES:-24}
LICWAIT_MIN=${LICWAIT_MIN:-60}
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
VCS_RTL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN -debug_access+pp \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
UNITDEF="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
SDFDEF="+neg_tchk +sdfverbose"
[[ -s "$SYN/$TOP.syn.v" && -s "$SYN/$TOP.syn.sdf" ]] || { echo "missing netlist/SDF in $SYN" >&2; exit 2; }
mkdir -p "$OUT"
SUMMARY=$OUT/syn_gl_checks_summary.log
IDEAL=$OUT/idealclk_view            # SYN_DIR for the SDF builds: $IDEAL/$TARGET/$RUN/{netlist -> run, ideal-clock SDF}

# label case_dir plusargs expect policy cycles rtl_label
UNIT_CASES=$(cat <<EOF
plain_u128            $GOLD/plain_u128     -                     pass  slice exact g_plain_u128
plain_ladder          $GOLD/plain_ladder   -                     pass  slice exact g_plain_ladder
plain_extreme         $GOLD/plain_extreme  -                     pass  slice exact g_plain_extreme
chunked_100           $GOLD/chunked_100    -                     pass  slice exact g_chunked_100
chunked_rung          $GOLD/chunked_rung   -                     pass  slice exact g_chunked_rung
perhead_64            $GOLD/perhead_64     -                     pass  slice exact g_perhead_64
calls_prot            $GOLD/calls_prot     -                     pass  slice exact g_calls_prot
calls_av257           $GOLD/calls_av257    -                     pass  slice exact g_calls_av257
calls_mix             $XG/calls_mix        -                     pass  slice exact x_calls_mix
extreme_mix           $XG/extreme_mix      -                     pass  slice exact x_extreme_mix
range_2048            $XG/range_2048       -                     pass  slice exact x_range_2048
allL_plain            $XG/allL_plain       -                     pass  slice exact x_allL_plain
full_calls_av257      $GOLD/calls_av257    FULL_CYCLES           pass  slice full  full_calls_av257
sj_calls_av257        $GOLD/calls_av257    STALL=20,JUNK,SEED=12 pass  slice exact stalljunk_calls_av257
drblind_free_calls_mix $XG/calls_mix       NEG_FREE_PHASE        blind free  exact drblind_free_calls_mix
neg_short_calls_mix   $XG/calls_mix        NEG_SHORT_BLOCK       fail  slice short neg_short_calls_mix
neg_short_plain_u97   $GOLD/plain_u97      NEG_SHORT_BLOCK       fail  slice short nopeek_short_plain_u97
EOF
)
SDF_CASES="$UNIT_CASES"

prep_ideal() {
    local d="$IDEAL/$TARGET/$RUN"
    rm -rf "$IDEAL"; mkdir -p "$d"
    ln -s "$REPO/$SYN/$TOP.syn.v" "$d/$TOP.syn.v"
    python3 sweeps/cbsg/rg/sdf_ideal_clock.py "$SYN/$TOP.syn.sdf" "$d/$TOP.syn.sdf" --report "$IDEAL/idealclk_report.txt"
}

qualify_sdf() {   # log json -> 0 if validate_routed_gl passed, or failed only on DFFRPQ* removal-check SDFCOM_CFTC
    python3 - "$1" "$2" <<'PY2'
import json, re, sys
log = open(sys.argv[1], errors="replace").read()
d = json.load(open(sys.argv[2]))
reasons = [r for r in d["rejection_reasons"] if r != "unapproved SDF warnings: SDFCOM_CFTC"]
blocks = re.findall(r"Warning-\[SDFCOM_CFTC\](.*?)(?=\n\s*\n|\Z)", log, re.S)
bad = [b for b in blocks if not (re.search(r"module: DFFRPQ\w+", b)
                                 and re.search(r"\$hold\(posedge CK[^,]*,\s*negedge R", " ".join(b.split())))]
if bad:
    reasons.append(f"{len(bad)} SDFCOM_CFTC not of the async-reset removal kind")
print("timing violations %d (post-reset %d), SDF errors %s, SDF warnings %s, %d SDFCOM_CFTC all DFFRPQ removal checks%s"
      % (d["timing_violation_reports"], d["post_reset_timing_violations"], d["sdf_errors"],
         d["sdf_warning_categories"] or "{}", len(blocks), "; REJECT: " + "; ".join(reasons) if reasons else ""))
sys.exit(1 if reasons else 0)
PY2
}

kv() { grep -o "$1=[0-9]*" <<< "$2" | head -1 | cut -d= -f2; }

compile_gl() {   # mode tb builddir -> make sim GL=syn; the compile-time run has no +CASE / is the bench itself
    local mode=$1 tb=$2 b=$3 extra=${4:-} defs
    rm -rf "$b"; mkdir -p "$b"
    if [[ "$mode" == unit ]]; then
        make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$tb" BUILD_DIR="$REPO/$b" NO_SDF=1 \
            RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="$extra $UNITDEF" > "$b/compile.log" 2>&1
    else
        make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$tb" BUILD_DIR="$REPO/$b" SDF_CORNER=max NO_SDF= \
            SYN_DIR="$REPO/$IDEAL" RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="$extra $SDFDEF" > "$b/compile.log" 2>&1
    fi
}

run_case() {   # mode label case_dir plusargs expect policy cycles rtl_label
    local mode=$1 label=$2 cdir=$3 plus=$4 expect=$5 pol=$6 cyc=$7 rtl=$8
    local dir="$OUT/$mode/$label" args=() res pred rres ok=1 f x val=""
    rm -rf "$dir"; mkdir -p "$dir"
    if [[ "$plus" != - ]]; then IFS=, read -ra f <<< "$plus"; for x in "${f[@]}"; do args+=("+$x"); done; fi
    local t0=$SECONDS
    (cd "$dir" && "$REPO/$OUT/build_$mode/$TB/simv" +vcs+lic+wait +CASE="$REPO/$cdir" "${args[@]}" > sim.log 2>&1)
    local dt=$((SECONDS - t0))
    python3 sweeps/cbsg/rg/predict_faults.py "$cdir" --policy "$pol" --fault none --cycles "$cyc" \
        --idx-w 8 --drain-reset 1 --no-peek > "$dir/predict.log" 2>&1
    res=$(grep '^CBSGRG_RESULT' "$dir/sim.log")
    pred=$(grep '^PREDICT' "$dir/predict.log")
    rres=$(grep '^CBSGRG_RESULT' "$RTLRUNS/$rtl/sim.log" 2>/dev/null)
    if [[ -z "$res" || -z "$pred" || -z "$rres" ]]; then
        echo "$mode $label: FAIL (missing result / prediction / RTL run $rtl; see $dir)"; return 1
    fi
    grep -q 'GL_SIM=1\|NO_PEEK' "$dir/sim.log" || ok=0
    for x in drain_bad drain_total; do
        [[ "$(kv "$x" "$res")" == "$(kv "$x" "$pred")" ]] || ok=0
        [[ "$(kv "$x" "$res")" == "$(kv "$x" "$rres")" ]] || ok=0
    done
    [[ "$(kv edges "$res")" == "$(kv edges "$rres")" ]] || ok=0
    [[ "$(kv blk_total "$res")" == 0 && "$(kv phase_total "$res")" == 0 ]] || ok=0
    local db; db=$(kv drain_bad "$res")
    case "$expect" in
        pass)  (( db == 0 )) && grep -q '^PASS: CBSG-RG bench' "$dir/sim.log" || ok=0 ;;
        fail)  (( db > 0 )) || ok=0 ;;
        blind) (( db == 0 )) || ok=0 ;;
    esac
    if grep -qE 'Error-\[|\$fatal|FATAL' "$dir/sim.log"; then ok=0; fi
    if [[ "$mode" == sdf ]]; then
        # Qualify the timing view: the compile log carries the command line and corner, the run log the
        # annotation and timing checks of this run.
        cat "$OUT/build_sdf/compile.log" "$dir/sim.log" > "$dir/validation_input.log"
        local ep=(--expected-pass "PASS: CBSG-RG bench")
        [[ "$expect" != fail ]] || ep=(--expected-pass "CBSGRG_RESULT case=")   # a failing control prints no PASS
        python3 sweeps/validate_routed_gl.py "$dir/validation_input.log" "${ep[@]}" \
            --json "$dir/timing_qualification.json" > "$dir/timing_validation.log" 2>&1
        if val="; $(qualify_sdf "$dir/validation_input.log" "$dir/timing_qualification.json")"; then :; else ok=0; fi
    fi
    local tag=PASS; (( ok )) || tag=FAIL
    echo "$mode $label: $tag [$expect] ${plus} drains $db/$(kv drain_total "$res") bad (predicted $(kv drain_bad "$pred"), RTL $(kv drain_bad "$rres")/$(kv drain_total "$rres")); $(kv edges "$res") edges, ${dt}s$val"
    (( ok ))
}

run_mode() {   # mode cases
    local mode=$1 cases=$2 status=0 b="$OUT/build_$1"
    local label cdir plus expect pol cyc rtl
    compile_gl "$mode" "$TB" "$b"
    if ! grep -q 'CBSGRG compile-only run (no +CASE).*GL_SIM=1' "$b/compile.log"; then
        echo "$mode: bench compile FAILED ($b/compile.log)"; return 1
    fi
    if [[ "$mode" == sdf ]]; then
        grep -q 'sdf corner = max' "$b/compile.log" && grep -Fq '[INFO] $sdf_annotate(' "$b/compile.log" \
            || { echo "sdf: no SDF annotation in the compile run ($b/compile.log)"; return 1; }
    fi
    echo "$mode: compiled $(grep -o 'netlist = .*' "$b/compile.log" | head -1 | sed "s#$REPO/##")"
    : > "$OUT/${mode}_runs.log"
    while read -r label cdir plus expect pol cyc rtl; do
        [[ -n "$label" ]] || continue
        run_case "$mode" "$label" "$cdir" "$plus" "$expect" "$pol" "$cyc" "$rtl" >> "$OUT/${mode}_runs.log" &
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
    done <<< "$cases"
    while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
    sort "$OUT/${mode}_runs.log"
    echo "$mode: $(grep -c ': PASS \[' "$OUT/${mode}_runs.log")/$(grep -c . <<< "$cases") runs PASS"
    return "$status"
}

#--------------------------------------------------------------- (power) --
pt_smoke() {   # wl simdir
    local wl=$1 sd=$2 pt="$2/pt"
    rm -rf "$pt"; mkdir -p "$pt"
    (set -a; . "$SYN/TARGET_DEF"; set +a
     cd "$pt" && RG_SYN_DIR="$REPO/$SYN" SAIF_FILE="$REPO/$sd/$PWR/dut.saif" SAIF_STRIP_PATH=Top/dut \
        pt_shell -file "$REPO/sweeps/cbsg/rg/pt_syn_power_smoke.tcl" > power_pt.log 2>&1) || true
    if grep -qE '^(Error:|ERROR:)' "$pt/power_pt.log" || [[ ! -s "$pt/reports/power.rpt" ]]; then
        echo "power $wl: PT FAIL ($pt/power_pt.log)"; return 1
    fi
    python3 - "$pt" <<'PY'
import re, sys
from pathlib import Path
pt = Path(sys.argv[1])
act = (pt / "reports/saif_coverage.rpt").read_text()
rows = re.findall(r'^[ \t]*Nets[ \t]+(?=\d)(.+)$', act, re.M)
log = (pt / "power_pt.log").read_text(errors="replace")
forced = re.findall(r'Forced\s+(\d+)\s+pinless net\(s\) to static-zero activity', log)
assert len(rows) == 2 and len(forced) == 1, "unrecognized PT activity report"
pinless = int(forced[0])
out = []
for kind, row in zip(("switching", "static_probability"), rows):
    counts = [int(x) for x in re.findall(r'(\d+)\([0-9.]+%\)', row)]
    total = int(re.search(r'\s(\d+)\s*$', row)[1])
    assert len(counts) == 10 and sum(counts) == total, f"bad {kind} row"
    # columns: file, SSA, SSA-force-annotated, SSA-force-implied, SCA, clock, default, propagated, implied, missing
    assert counts[6] == 0 and counts[9] == 0, f"{kind}: {counts[6]} default, {counts[9]} unannotated nets"
    assert counts[1] == pinless, f"{kind}: {counts[1]} static nets vs {pinless} pinless"
    out.append(f"{kind} {counts[0]} from SAIF + {counts[1]} pinless + {counts[5]} clock + {counts[7]} propagated of {total}")
pw = (pt / "reports/power.rpt").read_text()
m = re.search(r'Total Power\s*=\s*(\S+)', pw)
print(f"PT activity coverage OK ({'; '.join(out)}); total power {float(m[1])*1e3:.3f} mW (synthesis netlist, no SPEF)")
PY
}

power_one() {   # wl defines
    local wl=$1 defs="+define+SC_BATCHES=$PWR_BATCHES $2" sd="$OUT/power/$1" rd="$OUT/power/${1}_rtl" st=0 msg
    rm -rf "$sd" "$rd"; mkdir -p "$sd" "$rd"
    # RTL reference run of the same workload (same seed, same SC_BATCHES): the GL trace must be identical.
    make sim TOP=Top TB="$PWR" BUILD_DIR="$REPO/$rd" GL= TARGET= RTL_PREFLIGHT_CMD= USE_DW=1 \
        "VCS=$VCS_RTL" VCS_ARGS="$defs" > "$rd/sim.log" 2>&1
    compile_gl sdf "$PWR" "$sd" "$defs"
    mv "$sd/compile.log" "$sd/simulation.log"
    local tr="$sd/$PWR/cbsg_rg_streaming_rtl.txt" saif="$sd/$PWR/dut.saif"
    grep -q '^PASS: CBSG-RG streaming SAIF captured' "$sd/simulation.log" || { echo "power $wl: FAIL (GL bench, $sd/simulation.log)"; return 1; }
    grep -q 'sdf corner = max' "$sd/simulation.log" && grep -Fq '[INFO] $sdf_annotate(' "$sd/simulation.log" \
        || { echo "power $wl: FAIL (no max-corner SDF annotation)"; return 1; }
    python3 sweeps/cbsg/rg/check_power_trace.py "$tr" --json "$sd/check.json" > "$sd/check.log" 2>&1 \
        || { echo "power $wl: FAIL drain check: $(tail -n 1 "$sd/check.log")"; st=1; }
    cmp -s "$tr" "$rd/$PWR/cbsg_rg_streaming_rtl.txt" && msg="trace identical to RTL" \
        || { msg="trace DIFFERS from RTL"; st=1; }
    python3 sweeps/validate_routed_gl.py "$sd/simulation.log" --expected-pass "PASS: CBSG-RG streaming SAIF captured" \
        --json "$sd/timing_qualification.json" > "$sd/timing_validation.log" 2>&1
    local q
    if q=$(qualify_sdf "$sd/simulation.log" "$sd/timing_qualification.json"); then msg="$msg; timing view OK: $q"
    else msg="$msg; timing view REJECTED: $q"; st=1; fi
    if python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 > "$sd/saif_validation.log" 2>&1; then
        msg="$msg; SAIF validator PASS"
    else
        msg="$msg; SAIF validator FAIL ($(tail -n 1 "$sd/saif_validation.log"))"; st=1
    fi
    echo "power $wl: $( ((st)) && echo FAIL || echo PASS) $(grep -o 'workload.*clocks ([0-9]* MACs)' "$sd/simulation.log"); $(tail -n 1 "$sd/check.log"); $msg"
    pt_smoke "$wl" "$sd" > "$sd/pt_smoke.log" 2>&1 || st=1
    sed "s/^/power $wl: /" "$sd/pt_smoke.log"
    return "$st"
}

run_power() {
    local status=0 pids=()
    power_one uniform_L128 "" > "$OUT/power_uniform_L128.log" 2>&1 & pids+=("$!")
    power_one ladder_rowgrouped "+define+CBSG_WL_LADDER_GROUPED" > "$OUT/power_ladder_rowgrouped.log" 2>&1 & pids+=("$!")
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    cat "$OUT/power_uniform_L128.log" "$OUT/power_ladder_rowgrouped.log"
    return "$status"
}

#----------------------------------------------------------------- driver --
status=0
: > "$SUMMARY"
echo "C-BSG RG post-synthesis GL checks $(date -Iseconds): $SYN (git $(git rev-parse --short HEAD), uncommitted tree)" >> "$SUMMARY"
if [[ " $PARTS " == *" sdf "* || " $PARTS " == *" power "* ]]; then
    prep_ideal >> "$SUMMARY" 2>&1 || { echo "ideal-clock SDF view FAILED" >> "$SUMMARY"; exit 1; }
fi
pids=()
if [[ " $PARTS " == *" unit "* ]]; then run_mode unit "$UNIT_CASES" > "$OUT/unit_summary.log" 2>&1 & pids+=("$!"); fi
if [[ " $PARTS " == *" sdf "* ]]; then run_mode sdf "$SDF_CASES" > "$OUT/sdf_summary.log" 2>&1 & pids+=("$!"); fi
if [[ " $PARTS " == *" power "* ]]; then run_power > "$OUT/power_summary.log" 2>&1 & pids+=("$!"); fi
for p in "${pids[@]}"; do wait "$p" || status=1; done
for m in unit sdf power; do
    [[ " $PARTS " == *" $m "* ]] || continue
    echo "== ($m)" >> "$SUMMARY"; cat "$OUT/${m}_summary.log" >> "$SUMMARY"
done
echo "C-BSG RG post-synthesis GL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)" >> "$SUMMARY"
cat "$SUMMARY"
exit "$status"
