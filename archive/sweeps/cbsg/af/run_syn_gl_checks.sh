#!/bin/bash
# Post-synthesis gate-level checks for TSMC22/PAYN_SC_CSA_CBSG_AF (designs/payn/variants/signed_segmented_csa_cbsg_af)
# on the synthesized netlist of RUN (default cbsg_af_20261005).  Recipe as sweeps/run_csa_bp_syn_gl_checks.sh.
#
# Every functional run plays the same case list with the same plusargs on the RTL (a fresh RTL compile of the bench,
# build_rtl) and on the netlist; the bench compares every drain bit-exactly with the golden acc_exp.mem, and the GL
# RESULT line must equal the RTL one (cases, calls, blocks, drains, edges, drained values, drains wrong, stalls,
# stray loads).  Under GL_SIM the bench compares drains only (no hierarchical peeks, no contract count).
# (unit) netlist, NO_SDF, unit delay, ARM_UD_MODEL + ARM_EN_X_SQUASH, timing checks off: functional proof that the
#        netlist implements the RTL (clock gating, multibit banking, register merging, reset mapping).
#        Subset: plain / per-row L / extremes / chunked / per-head / call sequences / every L 1..32 / 2048-column
#        slice / chunk_d 8 / one-cycle blocks / 60 tiny calls; all 43 cases chained without slice_start (the phase
#        restart comes from the drains alone), and the same with stalls, junk buses, gaps, exact mac_en, loose drains,
#        all 8 cycles and a DUT reset between cases; three negative controls that must FAIL with exactly the RTL's
#        drain count (block one cycle short, next slice one edge early, stalls without the mac_en kill).
# (sdf)  the same bench with the synthesis SDF in its ideal-clock view (max corner, +neg_tchk +sdfverbose, timing
#        checks ON, full library models, no X squash) on a smaller subset (no DUT reset between cases: one reset per
#        run).  The ideal-clock view (sweeps/cbsg/af/sdf_ideal_clock.py) zeroes only the CK->ECK IOPATHs of the
#        clock-gating cells, i.e. the clock model DC timed with: the raw synthesis SDF gives the unbuffered shared
#        gated clocks (u_peripheral/clk_gate_a_signs_q_reg_0_, clk_gate_w_binary_q_reg_0_,
#        u_pe/u_array_core/clk_gate_acc_low_reg_0_) 3.3-3.8 ns, longer than the 2.5 ns period, so no gated pulse
#        survives (pre-CTS artifact, also in the PAYN_SC_CSA baseline's synthesis SDF; sweeps/cbsg/af/gl_sdf_ladder.sh
#        shows the raw-SDF failure).  Each log is qualified by sweeps/validate_routed_gl.py (SDF annotation complete,
#        no post-reset timing violation); its only accepted rejection is SDFCOM_CFTC when every instance is the
#        async-reset removal check $hold(posedge CK, negedge R) of a DFFRPQ* flop (DC writes the removal check as
#        HOLD, the cell model has $recrem).
# Reset settle: the sdf runs (GL and their RTL references alike) wait SDF_SETTLE=2 idle edges after the reset before
#        the first load (+RESET_SETTLE, compiled-in default +define+CBSG_RESET_SETTLE), as power_payn_array.sv does:
#        the operand registers' asynchronous reset reaches them through DC's buffer tree 1.45-1.73 ns after the port
#        (SDF), so a load on the first edge after reset straddles their reset release (gl_sdf_ladder.sh, settle 0).
#        The unit runs keep the RTL suite's tightest schedule (UNIT_SETTLE=0: the load on the first edge).
# (power) smoke run of the GL power bench designs/payn/power/power_payn_array_cbsg_af.sv with the ideal-clock SDF and
#        the APR phase's VCS flags (+neg_tchk +sdfverbose, max corner), SC_BATCHES=$PWR_BATCHES, uniform and ladder
#        workloads: bench PASS, drain recomputed by sweeps/cbsg/af/check_power_trace.py, trace identical to an RTL
#        run of the same workload, validate_routed_gl.py, validate_sc_power_saif.py, then PrimeTime PX on the
#        synthesized netlist with that SAIF (sweeps/cbsg/af/pt_syn_power_smoke.tcl: apr/scripts/power.tcl without
#        SPEF) and a check that every net's activity comes from the SAIF or the pinless-net policy.
#
#   bash sweeps/cbsg/af/run_syn_gl_checks.sh                 # RUN=cbsg_af_20261005, PARTS="unit sdf power"
#   PARTS=unit bash sweeps/cbsg/af/run_syn_gl_checks.sh
# Outputs: build/cbsg/af/gl/<RUN>/ (summary syn_gl_checks_summary.log; per run <mode>/<label>/{sim.log,rtl.log}).
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
TARGET=TSMC22/PAYN_SC_CSA_CBSG_AF
RUN=${RUN:-cbsg_af_20261005}
TOP=payn_array_signed_segmented_csa_cbsg_af
SYN=syn/build/$TARGET/$RUN
OUT=build/cbsg/af/gl/$RUN
GOLD=build/cbsg/golden
EXTRA=build/cbsg/af/golden_extra
RV=build/cbsg/af/golden_rv
TB=designs/payn/tb/test_payn_array_cbsg_af.sv
PWR=designs/payn/power/power_payn_array_cbsg_af.sv
PARTS=${PARTS:-"unit sdf power"}
MAX_JOBS=${MAX_JOBS:-12}
PWR_BATCHES=${PWR_BATCHES:-32}
LICWAIT_MIN=${LICWAIT_MIN:-60}
VCS_GL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
VCS_RTL="vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -licwait $LICWAIT_MIN -debug_access+pp \$(VCS_ARGS) +incdir+\$(DESIGNS_DIR) -assert svaext"
UNITDEF="+define+ARM_UD_MODEL+define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
SDFDEF="+neg_tchk +sdfverbose"
UNIT_SETTLE=${UNIT_SETTLE:-0}
SDF_SETTLE=${SDF_SETTLE:-2}
[[ -s "$SYN/$TOP.syn.v" && -s "$SYN/$TOP.syn.sdf" ]] || { echo "missing netlist/SDF in $SYN" >&2; exit 2; }
for d in "$GOLD" "$EXTRA" "$RV"; do
    [[ -d "$d" ]] || { echo "missing $d (run sweeps/cbsg/af/run_rtl_checks.sh ref first)" >&2; exit 2; }
done
mkdir -p "$OUT"
SUMMARY=$OUT/syn_gl_checks_summary.log
IDEAL=$OUT/idealclk_view            # SYN_DIR for the SDF builds: $IDEAL/$TARGET/$RUN/{netlist -> run, ideal-clock SDF}

# label  cases  plusargs(comma list or -)  expect(pass|fail)
UNIT_CASES=$(cat <<'EOF'
plain_u128                plain_u128      -                     pass
plain_u97                 plain_u97       -                     pass
plain_ladder              plain_ladder    -                     pass
plain_extreme             plain_extreme   -                     pass
chunked_rung              chunked_rung    -                     pass
chunked_100               chunked_100     -                     pass
chunked_tail5             chunked_tail5   -                     pass
perhead_64                perhead_64      -                     pass
calls_prot                calls_prot      -                     pass
calls_av257               calls_av257     -                     pass
af_calls_mixed            af_calls_mixed  -                     pass
af_calls_odd              af_calls_odd    -                     pass
af_uL_001_032             af_uL_001_032   -                     pass
af_lad_chunk_0            af_lad_chunk_0  -                     pass
af_perhead                af_perhead      -                     pass
af_extreme_max            af_extreme_max  -                     pass
af_av2048                 af_av2048       -                     pass
rv_tiny_calls             rv_tiny_calls   -                     pass
rv_cd8                    rv_cd8          -                     pass
rv_c1_chain               rv_c1_chain     -                     pass
rv_plain_randL            rv_plain_randL  -                     pass
chain_all_no_ss           @all            NO_SLICE_START        pass
chain_all_no_ss_combo_s10 @all            NO_SLICE_START,STALL,JUNK_BUS,MID_RESET,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,SEED=10 pass
neg_short_u97             plain_u97       NEG_SHORT_BLOCK       fail
neg_next_early_rung       chunked_rung    NEG_NEXT_EARLY        fail
neg_stall_nomac           plain_u97,calls_prot NEG_STALL_NOMAC,SEED=3 fail
EOF
)
SDF_CASES=$(cat <<'EOF'
plain_u128                plain_u128      -                     pass
plain_ladder              plain_ladder    -                     pass
chunked_rung              chunked_rung    -                     pass
calls_av257               calls_av257     -                     pass
af_calls_mixed            af_calls_mixed  -                     pass
rv_tiny_calls             rv_tiny_calls   -                     pass
chain_golden_combo_s10    @golden         NO_SLICE_START,STALL,JUNK_BUS,GAPS,RNG_GAP_LOW,MAC_EXACT,LOOSE_DRAIN,FULL_CYCLES,SEED=10 pass
chain_all_no_ss           @all            NO_SLICE_START        pass
neg_short_u97             plain_u97       NEG_SHORT_BLOCK       fail
neg_next_early_rung       chunked_rung    NEG_NEXT_EARLY        fail
EOF
)

resolve() {   # comma list of case names / @golden / @extra / @rv / @all -> comma list of absolute dirs
    local out=() x d xs
    IFS=, read -ra xs <<< "$1"
    for x in "${xs[@]}"; do
        case "$x" in
            @golden) for d in "$GOLD"/*/; do out+=("$REPO/${d%/}"); done ;;
            @extra)  for d in "$EXTRA"/*/; do out+=("$REPO/${d%/}"); done ;;
            @rv)     for d in "$RV"/*/; do out+=("$REPO/${d%/}"); done ;;
            @all)    for d in "$GOLD"/*/ "$EXTRA"/*/ "$RV"/*/; do out+=("$REPO/${d%/}"); done ;;
            *) if [[ -d "$GOLD/$x" ]]; then out+=("$REPO/$GOLD/$x");
               elif [[ -d "$EXTRA/$x" ]]; then out+=("$REPO/$EXTRA/$x");
               elif [[ -d "$RV/$x" ]]; then out+=("$REPO/$RV/$x");
               else echo "unknown case $x" >&2; return 1; fi ;;
        esac
    done
    (IFS=,; echo "${out[*]}")
}

prep_ideal() {
    local d="$IDEAL/$TARGET/$RUN"
    rm -rf "$IDEAL"; mkdir -p "$d"
    ln -s "$REPO/$SYN/$TOP.syn.v" "$d/$TOP.syn.v"
    python3 sweeps/cbsg/af/sdf_ideal_clock.py "$SYN/$TOP.syn.sdf" "$d/$TOP.syn.sdf" --report "$IDEAL/idealclk_report.txt"
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

# RESULT line -> "cases calls blocks drains edges drain_values drain_bad stalls stray"
res_fields() {
    grep -m1 '^RESULT' "$1" | sed -E 's/^RESULT cases=([0-9]+) calls=([0-9]+) blocks=([0-9]+) drains=([0-9]+) edges=([0-9]+) \| drain values ([0-9]+) bad ([0-9]+) .*stalls ([0-9]+) stray loads ([0-9]+).*/\1 \2 \3 \4 \5 \6 \7 \8 \9/'
}

compile_bench() {   # mode builddir -> simv for TB (rtl | unit | sdf); the compile run plays plain_u128
    local mode=$1 b=$2
    rm -rf "$b"; mkdir -p "$b/$TB"
    echo "$REPO/$GOLD/plain_u128" > "$b/$TB/cbsg_cases.txt"
    case "$mode" in
        rtl)  make sim TOP=Top TB="$TB" BUILD_DIR="$REPO/$b" GL= TARGET= RTL_PREFLIGHT_CMD= USE_DW=1 \
                  "VCS=$VCS_RTL" > "$b/compile.log" 2>&1 ;;
        unit) make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$b" NO_SDF=1 \
                  RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="$UNITDEF +define+CBSG_RESET_SETTLE=$UNIT_SETTLE" > "$b/compile.log" 2>&1 ;;
        sdf)  make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$TB" BUILD_DIR="$REPO/$b" SDF_CORNER=max NO_SDF= \
                  SYN_DIR="$REPO/$IDEAL" RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="$SDFDEF +define+CBSG_RESET_SETTLE=$SDF_SETTLE" \
                  > "$b/compile.log" 2>&1 ;;
    esac
    grep -q '^PASS: CBSG AF bench' "$b/compile.log"
}

run_case() {   # mode label cases plusargs expect
    local mode=$1 label=$2 cases=$3 plus=$4 expect=$5
    local dir="$OUT/$mode/$label" args=() f x list gl rtl ok=1 val="" t0 dt
    rm -rf "$dir"; mkdir -p "$dir"
    if [[ "$plus" != - ]]; then IFS=, read -ra f <<< "$plus"; for x in "${f[@]}"; do args+=("+$x"); done; fi
    if [[ "$mode" == sdf ]]; then args+=("+RESET_SETTLE=$SDF_SETTLE"); else args+=("+RESET_SETTLE=$UNIT_SETTLE"); fi
    list=$(resolve "$cases") || { echo "$mode $label: FAIL (cannot resolve $cases)"; return 1; }
    t0=$SECONDS
    (cd "$dir" && "$REPO/$OUT/build_$mode/$TB/simv" +vcs+lic+wait "+CASES=$list" "${args[@]}" > sim.log 2>&1)
    dt=$((SECONDS - t0))
    (cd "$dir" && "$REPO/$OUT/build_rtl/$TB/simv" +vcs+lic+wait "+CASES=$list" "${args[@]}" > rtl.log 2>&1)
    gl=$(res_fields "$dir/sim.log"); rtl=$(res_fields "$dir/rtl.log")
    if [[ -z "$gl" || -z "$rtl" || "$gl" == RESULT* || "$rtl" == RESULT* ]]; then
        echo "$mode $label: FAIL (missing RESULT; see $dir)"; return 1
    fi
    [[ "$gl" == "$rtl" ]] || ok=0
    read -r _ _ _ _ edges dvals dbad stalls stray <<< "$gl"
    case "$expect" in
        pass) grep -q '^PASS: CBSG AF bench' "$dir/sim.log" && grep -q '^PASS: CBSG AF bench' "$dir/rtl.log" \
                  && (( dbad == 0 )) || ok=0 ;;
        fail) grep -q '^FAIL: CBSG AF bench' "$dir/sim.log" && grep -q '^FAIL: CBSG AF bench' "$dir/rtl.log" \
                  && grep -q '^\[CHECK\] [0-9]' "$dir/sim.log" && (( dbad > 0 )) || ok=0 ;;
    esac
    if grep -qE 'Error-\[|\[TIMEOUT\]|\$fatal|Fatal:' "$dir/sim.log"; then ok=0; fi
    if [[ "$mode" == sdf ]]; then
        # The compile log up to its own (plain_u128) run carries the command line and corner; the run log
        # carries this run's annotation, reset and timing checks.
        { sed '/Running gate-level simulation/q' "$OUT/build_sdf/compile.log"; cat "$dir/sim.log"; } \
            > "$dir/validation_input.log"
        local ep=(--expected-pass "PASS: CBSG AF bench")
        [[ "$expect" != fail ]] || ep=(--expected-pass "RESULT cases=")   # a failing control prints no PASS
        python3 sweeps/validate_routed_gl.py "$dir/validation_input.log" "${ep[@]}" \
            --json "$dir/timing_qualification.json" > "$dir/timing_validation.log" 2>&1
        if val=$(qualify_sdf "$dir/validation_input.log" "$dir/timing_qualification.json"); then
            val="; timing view OK: $val"
        else
            val="; timing view FAIL: $val"; ok=0
        fi
    fi
    local tag=PASS; (( ok )) || tag=FAIL
    echo "$mode $label: $tag [$expect] ${plus} | drains $dbad/$dvals wrong, $edges edges, stalls $stalls, stray $stray | GL == RTL: $([[ "$gl" == "$rtl" ]] && echo yes || echo "NO (GL $gl / RTL $rtl)") | ${dt}s$val"
    (( ok ))
}

run_mode() {   # mode cases
    local mode=$1 cases=$2 status=0 label c plus expect
    compile_bench "$mode" "$OUT/build_$mode" || { echo "$mode: bench compile FAILED ($OUT/build_$mode/compile.log)"; return 1; }
    if [[ "$mode" == sdf ]]; then
        grep -q 'sdf corner = max' "$OUT/build_sdf/compile.log" && grep -Fq '[INFO] $sdf_annotate(' "$OUT/build_sdf/compile.log" \
            || { echo "sdf: no SDF annotation in the compile run ($OUT/build_sdf/compile.log)"; return 1; }
    fi
    echo "$mode: compiled $(grep -o 'netlist = .*' "$OUT/build_$mode/compile.log" | head -1 | sed "s#$REPO/##")"
    : > "$OUT/${mode}_runs.log"
    while read -r label c plus expect; do
        [[ -n "$label" ]] || continue
        run_case "$mode" "$label" "$c" "$plus" "$expect" >> "$OUT/${mode}_runs.log" &
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
     cd "$pt" && AF_SYN_DIR="$REPO/$SYN" SAIF_FILE="$REPO/$sd/$PWR/dut.saif" SAIF_STRIP_PATH=Top/dut \
        pt_shell -file "$REPO/sweeps/cbsg/af/pt_syn_power_smoke.tcl" > power_pt.log 2>&1) || true
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
print(f"PT activity coverage OK ({'; '.join(out)}); total power {float(m[1])*1e3:.3f} mW (synthesis netlist, no SPEF, smoke only)")
PY
}

power_one() {   # wl defines
    local wl=$1 defs="+define+SC_BATCHES=$PWR_BATCHES $2" sd="$OUT/power/$1" rd="$OUT/power/${1}_rtl" st=0 msg
    rm -rf "$sd" "$rd"; mkdir -p "$sd" "$rd"
    # RTL reference run of the same workload (same seed, same SC_BATCHES): the GL trace must be identical.
    make sim TOP=Top TB="$PWR" BUILD_DIR="$REPO/$rd" GL= TARGET= RTL_PREFLIGHT_CMD= USE_DW=1 \
        "VCS=$VCS_RTL" VCS_ARGS="$defs" > "$rd/sim.log" 2>&1
    grep -q '^PASS: streaming C-BSG AF' "$rd/sim.log" || { echo "power $wl: FAIL (RTL reference, $rd/sim.log)"; return 1; }
    make sim GL=syn TARGET="$TARGET" RUN="$RUN" TB="$PWR" BUILD_DIR="$REPO/$sd" SDF_CORNER=max NO_SDF= \
        SYN_DIR="$REPO/$IDEAL" RTL_PREFLIGHT_CMD=true "VCS=$VCS_GL" VCS_ARGS="$defs $SDFDEF" > "$sd/simulation.log" 2>&1
    local tr="$sd/$PWR/array_streaming_cbsg_af_rtl.txt" saif="$sd/$PWR/dut.saif"
    grep -q '^PASS: streaming C-BSG AF SAIF captured' "$sd/simulation.log" || { echo "power $wl: FAIL (GL bench, $sd/simulation.log)"; return 1; }
    grep -q 'sdf corner = max' "$sd/simulation.log" && grep -Fq '[INFO] $sdf_annotate(' "$sd/simulation.log" \
        || { echo "power $wl: FAIL (no max-corner SDF annotation)"; return 1; }
    python3 sweeps/cbsg/af/check_power_trace.py "$tr" --json "$sd/check.json" > "$sd/check.log" 2>&1 \
        || { echo "power $wl: FAIL drain check: $(tail -n 1 "$sd/check.log")"; st=1; }
    cmp -s "$tr" "$rd/$PWR/array_streaming_cbsg_af_rtl.txt" && msg="trace identical to RTL" \
        || { msg="trace DIFFERS from RTL"; st=1; }
    python3 sweeps/validate_routed_gl.py "$sd/simulation.log" --expected-pass "PASS: streaming C-BSG AF SAIF captured" \
        --json "$sd/timing_qualification.json" > "$sd/timing_validation.log" 2>&1
    local q
    if q=$(qualify_sdf "$sd/simulation.log" "$sd/timing_qualification.json"); then
        msg="$msg; timing view OK: $q"
    else
        msg="$msg; timing view FAIL: $q"; st=1
    fi
    if python3 sweeps/validate_sc_power_saif.py "$saif" --expected-period-ns 2.5 > "$sd/saif_validation.log" 2>&1; then
        msg="$msg; SAIF validator PASS ($(sed -E 's/^validated SC SAIF: //' "$sd/saif_validation.log" | cut -c1-160))"
    else
        msg="$msg; SAIF validator FAIL ($(tail -n 1 "$sd/saif_validation.log"))"; st=1
    fi
    echo "power $wl: $( ((st)) && echo FAIL || echo PASS) $(grep -o 'workload .*window edges' "$sd/simulation.log" | head -1); $(tail -n 1 "$sd/check.log"); $msg"
    pt_smoke "$wl" "$sd" > "$sd/pt_smoke.log" 2>&1 || st=1
    sed "s/^/power $wl: /" "$sd/pt_smoke.log"
    return "$st"
}

run_power() {
    local status=0 pids=()
    power_one uniform "" > "$OUT/power_uniform.log" 2>&1 & pids+=("$!")
    power_one ladder "+define+CBSG_PWR_LADDER" > "$OUT/power_ladder.log" 2>&1 & pids+=("$!")
    for p in "${pids[@]}"; do wait "$p" || status=1; done
    cat "$OUT/power_uniform.log" "$OUT/power_ladder.log"
    return "$status"
}

#----------------------------------------------------------------- driver --
status=0
: > "$SUMMARY"
echo "C-BSG AF post-synthesis GL checks $(date -Iseconds): $SYN (git $(git rev-parse --short HEAD), uncommitted tree)" >> "$SUMMARY"
if [[ " $PARTS " == *" sdf "* || " $PARTS " == *" power "* ]]; then
    prep_ideal >> "$SUMMARY" 2>&1 || { echo "ideal-clock SDF view FAILED" | tee -a "$SUMMARY"; exit 1; }
fi
if [[ " $PARTS " == *" unit "* || " $PARTS " == *" sdf "* ]]; then
    compile_bench rtl "$OUT/build_rtl" || { echo "RTL bench compile FAILED ($OUT/build_rtl/compile.log)" | tee -a "$SUMMARY"; exit 1; }
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
echo "C-BSG AF post-synthesis GL checks: $([[ $status == 0 ]] && echo PASS || echo FAIL)" >> "$SUMMARY"
cat "$SUMMARY"
exit "$status"
