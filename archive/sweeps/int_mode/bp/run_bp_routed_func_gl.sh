#!/bin/bash
# Routed full-timing functional GL of the BP INT bench
# (designs/payn/tb/test_payn_array_bp.sv, real INT ports, no forces) on a routed
# bit-plane netlist: max-corner SDF, full library timing models, +neg_tchk
# +sdfverbose, exactly as the routed SC / INT-energy GL runs.
#   ROUTE_RUN=csa_bp_20261004_lap_distguide_spp_pins \
#     GL_VALIDATOR_ARGS="..." bash sweeps/int_mode/bp/run_bp_routed_func_gl.sh
#
# Complements sweeps/int_mode/bp/run_bp_int_energy.sh (contract-clean power
# bench, SAIF + PT-PX) with the functional bench's adversarial cases on the
# routed layout: JUNK (Sobol running, random magnitudes / acc_in_west / extra
# sign loads that the bypass, sign path and ring mux must hide), the latest
# legal int_mode rise, both lap contracts (shift_in on lap edges, and
# LAP_RING_ONLY: laps on the per-PE ring_q alone), and the stray-ring negative
# control, which must FAIL the checker with a GL trace identical to RTL.
#
# Per case: the same operands (sweeps/int_mode/bp/gen_bp_workload.py) run on
# the RTL (USE_DW, LOW_W=9) and on the routed netlist; the GL run must print the
# bench's exact PASS line, pass sweeps/validate_routed_gl.py (strict, i.e. no
# approvals, unless GL_VALIDATOR_ARGS is given; whatever is used is recorded in
# each case's timing_qualification.json and in $OUT/validator_args.txt), give
# the expected check_bp_trace.py verdict, and produce a trace byte-identical to
# the RTL one.  One GL compile (make sim GL=apr, SDF_CORNER=max) serves every
# case; each case log is that compile's header (its "sdf corner = max" and
# command evidence, up to "Compilation finished.") followed by the case's own
# simv run, which performs its own $sdf_annotate and reset.
# Results: $OUT/summary.log (default OUT=build/rtl_preflight/csa_bp_routed_func_gl/$ROUTE_RUN).
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
ROUTE_RUN=${ROUTE_RUN:?set ROUTE_RUN to a routed TSMC22/PAYN_SC_CSA_BP run}
[[ "$ROUTE_RUN" =~ ^[A-Za-z0-9_]+$ ]] || { echo "bad ROUTE_RUN" >&2; exit 2; }
OUT=${OUT:-build/rtl_preflight/csa_bp_routed_func_gl/$ROUTE_RUN}
[[ "$OUT" == /* ]] || OUT="$REPO/$OUT"
MAX_JOBS=${MAX_JOBS:-8}
GL_VALIDATOR_ARGS=${GL_VALIDATOR_ARGS:-}
read -r -a VARGS <<< "$GL_VALIDATOR_ARGS"
TARGET=TSMC22/PAYN_SC_CSA_BP
TOP=payn_array_signed_segmented_csa_bp
TB=designs/payn/tb/test_payn_array_bp.sv
ROUTE="$REPO/apr/build/$TARGET/$ROUTE_RUN"
for f in "outputs/$TOP.apr.v" "outputs/$TOP.apr.sdf" reports/popcount_qualification.json; do
    [[ -s "$ROUTE/$f" ]] || { echo "route $ROUTE lacks $f" >&2; exit 3; }
done
python3 - "$ROUTE/reports/popcount_qualification.json" <<'PY' || { echo "route not final-qualified" >&2; exit 3; }
import json, sys
q = json.load(open(sys.argv[1]))
sys.exit(0 if q.get('qualification') == 'final' and q['setup_wns_ns'] >= 0 and q['hold_wns_ns'] >= 0 else 1)
PY
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1 NTFY_CHNL=
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30
export TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1 PERIOD=2.5
unset NETLIST_FILE SDC_FILE SDF_FILE NO_SDF VCS_ARGS
VCS_CMD='vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca $(VCS_ARGS) +incdir+$(DESIGNS_DIR) -assert svaext'

# label BA BW L MROWS NCOLS DIST SEED FLAGS EXPECT (pass | fail:CHECK); the
# labels, operands and flags are those of sweeps/run_csa_bp_rtl_checks.sh.
CASES=$(cat <<'EOF'
int8_uniform_L1024_m2n16_lapring     8 8 1024 2 16 uniform  3 LAP_RING_ONLY            pass
int8_uniform_L256_m2n16_junk_lapring 8 8  256 2 16 uniform  6 JUNK,LAP_RING_ONLY       pass
int8_uniform_L256_m2n8_modeat3_lapring 8 8 256 2 8 uniform  7 MODE_AT=3,LAP_RING_ONLY  pass
w4a8_uniform_L1024_m2n16_lapring     8 4 1024 2 16 uniform 12 LAP_RING_ONLY            pass
int4_uniform_L1024_m4n16_lapring     4 4 1024 4 16 uniform 22 LAP_RING_ONLY            pass
int4_uniform_L256_m2n16_junk_lapring 4 4  256 2 16 uniform 23 JUNK,LAP_RING_ONLY       pass
int8_uniform_L1024_m2n16             8 8 1024 2 16 uniform  3 -                        pass
neg_int8_ringstray_L256_m1n8_lapring 8 8  256 1  8 uniform 37 NEG_RING_STRAY,LAP_RING_ONLY fail:CHECK
EOF
)

mkdir -p "$OUT"
printf '%s GL_VALIDATOR_ARGS=%s route=%s\n' "$(date -Is)" "${GL_VALIDATOR_ARGS:-(none: strict)}" "$ROUTE" >> "$OUT/validator_args.txt"

compile() {   # kind (rtl|gl): build one simv, running the bench's default case
    local kind=$1 b="$OUT/build_$1"
    rm -rf "${b:?}"; mkdir -p "$b/$TB"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba 8 --bw 8 --L 128 --mrows 1 --ncols 8 \
        --dist uniform --seed 1 --out-dir "$b/$TB" > /dev/null
    if [[ "$kind" == rtl ]]; then
        make sim TOP=Top BUILD_DIR="$b" TB="$TB" USE_DW=1 NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" \
            > "$b/compile.log" 2>&1
    else
        make sim GL=apr TARGET="$TARGET" RUN="$ROUTE_RUN" TB="$TB" BUILD_DIR="$b" SDF_CORNER=max NO_SDF= \
            RTL_PREFLIGHT_CMD=true VCS_ARGS="+define+PAYN_ARRAY_DUT=$TOP +neg_tchk +sdfverbose" "VCS=$VCS_CMD" \
            NTFY_CHNL= ASTRAEA_FLOW="$ASTRAEA_FLOW" > "$b/compile.log" 2>&1
        grep -q 'sdf corner = max' "$b/compile.log"
        sed -n '1,/^Compilation finished\./p' "$b/compile.log" > "$b/compile_header.log"
        grep -q '^Compilation finished\.' "$b/compile_header.log"
    fi
    grep -q '^PASS: BP INT bench' "$b/compile.log"
}

run_case() (
    local label=$1 ba=$2 bw=$3 L=$4 mrows=$5 ncols=$6 dist=$7 seed=$8 flags=$9 expect=${10}
    local d="$OUT/cases/$label" plus=() fl x pass lap=0 junk=0 mode_at=-1 verdict
    if [[ "$flags" != - ]]; then
        IFS=, read -ra fl <<< "$flags"
        for x in "${fl[@]}"; do
            plus+=("+$x")
            case "$x" in LAP_RING_ONLY) lap=1;; JUNK) junk=1;; MODE_AT=*) mode_at=${x#MODE_AT=};; esac
        done
    fi
    rm -rf "${d:?}"; mkdir -p "$d/rtl" "$d/gl"
    python3 sweeps/int_mode/bp/gen_bp_workload.py --ba "$ba" --bw "$bw" --L "$L" --mrows "$mrows" \
        --ncols "$ncols" --dist "$dist" --seed "$seed" --out-dir "$d/rtl" > "$d/gen.log"
    cp -p "$d/rtl"/bpt_a.hex "$d/rtl"/bpt_w.hex "$d/gl/"
    local nblk=$(( (mrows / (8 / ba)) * (ncols / 8) )) nb=$((L / 128))
    pass="PASS: BP INT bench BA=$ba BW=$bw L=$L MROWS=$mrows NCOLS=$ncols blocks=$nblk edges=$((4 + nblk * bw * (nb + 8) + 3)) junk=$junk mode_at=$mode_at lap_ring_only=$lap"
    (cd "$d/rtl" && "$OUT/build_rtl/$TB/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}" \
        > sim.log 2>&1) || { echo "$label: FAIL (RTL simulation error)"; exit 1; }
    grep -Fqx "$pass" "$d/rtl/sim.log" || { echo "$label: FAIL (RTL: no '$pass')"; exit 1; }
    { cat "$OUT/build_gl/compile_header.log"
      echo "Running gate-level simulation (case $label: ${plus[*]:-no plusargs}) ..."
      (cd "$d/gl" && "$OUT/build_gl/$TB/simv" +BA="$ba" +BW="$bw" +L="$L" +MROWS="$mrows" +NCOLS="$ncols" "${plus[@]}") 2>&1
    } > "$d/gl/simulation.log" || true
    grep -Fqx "$pass" "$d/gl/simulation.log" || { echo "$label: FAIL (GL: no '$pass')"; exit 1; }
    python3 sweeps/validate_routed_gl.py "$d/gl/simulation.log" --expected-pass "$pass" "${VARGS[@]}" \
        --json "$d/gl/timing_qualification.json" > "$d/gl/timing_validation.log" 2>&1 \
        || { echo "$label: FAIL (routed timing audit: $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['rejection_reasons'])" "$d/gl/timing_qualification.json"))"; exit 1; }
    for k in rtl gl; do
        if python3 sweeps/int_mode/bp/check_bp_trace.py "$d/$k" --json "$d/$k/check.json" > "$d/$k/check.log" 2>&1; then
            verdict=pass
        else
            grep -q '^\[FAIL\]' "$d/$k/check.log" || { echo "$label: FAIL ($k checker error)"; exit 1; }
            verdict=fail:CHECK
        fi
        [[ "$verdict" == "$expect" ]] || { echo "$label: FAIL ($k checker verdict $verdict, expected $expect)"; exit 1; }
    done
    cmp -s "$d/rtl/bpt_trace.txt" "$d/gl/bpt_trace.txt" || { echo "$label: FAIL (GL trace differs from RTL)"; exit 1; }
    rm -f "$d"/{rtl,gl}/ucli.key
    echo "$label: PASS (expect $expect; routed max-SDF GL trace == RTL; timing audit $(python3 -c "
import json,sys
q=json.load(open(sys.argv[1]))
print(f\"PASS, SDF warnings {q['sdf_warning_categories']}, approved NDI {len(q['approved_negative_iopath_clamps'])}, IWSBA {len(q['approved_annotated_interconnects'])}, startup reports {q['startup_timing_violations']}, post-reset violations {q['post_reset_timing_violations']}\")" "$d/gl/timing_qualification.json"); $(tail -n 1 "$d/gl/check.log" | sed 's/^\[[A-Z]*\] //'))"
)

status=0
compile rtl & p1=$!
compile gl & p2=$!
wait $p1 || { echo "RTL compile failed: $OUT/build_rtl/compile.log"; exit 1; }
wait $p2 || { echo "GL compile failed: $OUT/build_gl/compile.log"; exit 1; }
: > "$OUT/cases.log"
while read -r label ba bw L mrows ncols dist seed flags expect; do
    [[ -n "$label" ]] || continue
    run_case "$label" "$ba" "$bw" "$L" "$mrows" "$ncols" "$dist" "$seed" "$flags" "$expect" >> "$OUT/cases.log" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do wait -n || status=1; done
done <<< "$CASES"
while (( $(jobs -rp | wc -l) > 0 )); do wait -n || status=1; done
{ echo "route $ROUTE_RUN, validator args: ${GL_VALIDATOR_ARGS:-(none: strict)}"
  sort "$OUT/cases.log"
  echo "routed functional GL: $(grep -c . <<< "$CASES") cases, status $([[ $status == 0 ]] && echo PASS || echo FAIL)"
} | tee "$OUT/summary.log"
exit "$status"
